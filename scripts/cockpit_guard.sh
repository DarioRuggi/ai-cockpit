#!/usr/bin/env bash
# =============================================================================
# cockpit_guard.sh — watches the shipped files of an AI Cockpit install and
# reacts the moment one changes.
#
# Runs as root under systemd (cockpit-guard.service). inotifywait (inotify-tools,
# native .deb) reports every write / move / delete under the web root(s) and the
# shipped scripts. For each event on a file the manifest lists, the guard hashes
# the file against integrity.json:
#   · matches         → nothing (a deploy rewrote it identically, or a false alarm)
#   · differs/missing → appends a dated line to <cockpit_data>/guard.log, writes
#                       <cockpit_data>/integrity_flag.json (the app shows the
#                       Integrity modal on its next poll) and, when a kept bundle
#                       exists and GUARD_RESTORE=1 (default), puts the shipped
#                       file back through cockpit_restore.sh and logs that too.
#
# It cannot prevent a change — root can stop this unit — but it turns one into
# a dated, logged, self-healed event. Deploys stop the unit first (deploy_rig.sh
# does), so intended updates are not reverted.
#
#   GUARD_WEBS="/var/www/html/cockpit /var/www/html/cockpit-v1"  (auto-detected)
#   GUARD_USER=dario   GUARD_RESTORE=1
# =============================================================================
set -u
GUARD_USER="${GUARD_USER:-${SUDO_USER:-}}"
[ -n "$GUARD_USER" ] || GUARD_USER=$(stat -c %U /var/www/html/cockpit/.edition 2>/dev/null || echo root)
HOME_DIR=$(getent passwd "$GUARD_USER" | cut -d: -f6)
WEBS="${GUARD_WEBS:-}"
[ -n "$WEBS" ] || for c in /var/www/html/cockpit /var/www/html/cockpit-v1 /srv/http/cockpit; do [ -f "$c/integrity.json" ] && WEBS="$WEBS $c"; done
[ -n "$WEBS" ] || { echo "cockpit-guard: no web root with integrity.json"; exit 1; }
command -v inotifywait >/dev/null || { echo "cockpit-guard: inotifywait missing (apt install inotify-tools)"; exit 1; }
CD=$(cd "$(echo $WEBS | cut -d' ' -f1)" && php -r 'require "paths.php"; echo $PATHS["cockpit_data_root"] ?? $PATHS["cockpit_data"];' 2>/dev/null || echo "$HOME_DIR/scripts/cockpit_data")
LOG="$CD/guard.log"; FLAG="$CD/integrity_flag.json"
log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; chown "$GUARD_USER" "$LOG" 2>/dev/null || true; chmod 0664 "$LOG" 2>/dev/null || true; }
manifest_sha(){ jq -r --arg f "$2" '.files[$f] // empty' "$1/integrity.json" 2>/dev/null; }
# which web root + manifest key does an absolute path belong to?
resolve(){  # $1 = abs path → prints "<web>\t<rel>" or nothing
    local p="$1" w
    for w in $WEBS; do case "$p" in "$w"/*) printf '%s\t%s\n' "$w" "${p#$w/}"; return ;; esac; done
    case "$p" in "$HOME_DIR"/scripts/*) printf '%s\t%s\n' "$(echo $WEBS | cut -d' ' -f1)" "scripts/${p#$HOME_DIR/scripts/}" ;; esac
}
log "guard started — watching:$WEBS $HOME_DIR/scripts (restore=${GUARD_RESTORE:-1})"
inotifywait -m -r -q -e close_write -e moved_to -e delete -e create --format '%w%f %e' $WEBS "$HOME_DIR/scripts" 2>/dev/null | while read -r path ev; do
    r=$(resolve "$path"); [ -n "$r" ] || continue
    web=${r%%	*}; rel=${r#*	}
    [ "$rel" = integrity.json ] && continue          # the manifest itself (deploys replace it)
    want=$(manifest_sha "$web" "$rel"); [ -n "$want" ] || continue   # not a shipped file
    if [ -f "$path" ]; then have=$(sha256sum "$path" | cut -d' ' -f1); else have=missing; fi
    [ "$have" = "$want" ] && continue
    owner=$(stat -c '%U' "$path" 2>/dev/null || echo '-')
    log "CHANGED  $rel  event=$ev  owner=$owner  sha=${have:0:12}  expected=${want:0:12}"
    printf '{"changed_at":"%s","file":"%s","event":"%s","owner":"%s"}\n' "$(date -Iseconds)" "$rel" "$ev" "$owner" > "$FLAG"; chown "$GUARD_USER" "$FLAG" 2>/dev/null; chmod 0664 "$FLAG" 2>/dev/null
    if [ "${GUARD_RESTORE:-1}" = 1 ] && [ -x "$HOME_DIR/scripts/cockpit_restore.sh" ]; then
        if out=$(HOME="$HOME_DIR" bash "$HOME_DIR/scripts/cockpit_restore.sh" --web "$web" "$rel" 2>&1); then
            log "RESTORED $rel  ($(echo "$out" | grep -c '^restored:') file)"
            # keep root ownership + read-only after the restore (lockdown layout)
            chown root:root "$path" 2>/dev/null; [ -x "$path" ] && chmod 0755 "$path" 2>/dev/null || chmod 0644 "$path" 2>/dev/null
        else
            log "RESTORE FAILED $rel: $(echo "$out" | tail -1)"
        fi
    fi
done
log "guard stopped"
