#!/usr/bin/env bash
# =============================================================================
# cockpit_lockdown.sh — shipped files owned by root, read-only for everyone else.
#
# Every file listed in the install's integrity.json (web root + the shipped
# scripts) becomes root:root 0644 (0755 where it was executable). Apache and the
# login user keep reading; only sudo writes. Files the install owns or the user
# edits (config.php, paths.json, .edition, cockpit_data/, projects, queue/,
# responses/) are not in the manifest and are not touched. Directories are not
# touched either: runtime files are created in them at run time.
#
# A casual edit now fails; a deliberate one needs sudo — which is the point:
# nobody changes an official build by accident, and a changed one is a chosen
# act (see LICENSE.md §2). The integrity check and cockpit-guard still watch.
#
#   sudo Installs/cockpit_lockdown.sh [--web /var/www/html/cockpit]... [--user dario]
#   sudo Installs/cockpit_lockdown.sh --unlock [--web ...] [--user dario]   # back to user-owned (dev)
# =============================================================================
set -euo pipefail
MODE=lock; WEBS=(); USER_NAME=""
while [ $# -gt 0 ]; do case "$1" in --unlock) MODE=unlock; shift ;; --web) WEBS+=("$2"); shift 2 ;; --user) USER_NAME="$2"; shift 2 ;; *) echo "unknown arg: $1"; exit 2 ;; esac; done
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
[ ${#WEBS[@]} -gt 0 ] || for c in /var/www/html/cockpit /var/www/html/cockpit-v1 /srv/http/cockpit; do [ -f "$c/integrity.json" ] && WEBS+=("$c"); done
[ ${#WEBS[@]} -gt 0 ] || { echo "no web root with integrity.json (use --web)"; exit 1; }
[ -n "$USER_NAME" ] || USER_NAME="${SUDO_USER:-$(stat -c %U "${WEBS[0]}")}"
HOME_DIR=$(getent passwd "$USER_NAME" | cut -d: -f6)
n=0
for WEB in "${WEBS[@]}"; do
    echo "== $WEB ($MODE)"
    while IFS= read -r rel; do
        case "$rel" in scripts/*) p="$HOME_DIR/scripts/${rel#scripts/}" ;; *) p="$WEB/$rel" ;; esac
        [ -f "$p" ] || continue
        if [ "$MODE" = lock ]; then
            if [ -x "$p" ]; then chmod 0755 "$p"; else chmod 0644 "$p"; fi
            chown root:root "$p"
        else
            chown "$USER_NAME:$USER_NAME" "$p"
            if [ -x "$p" ]; then chmod 0775 "$p"; else chmod 0664 "$p"; fi
        fi
        n=$((n+1))
    done < <(jq -r '.files | keys[]' "$WEB/integrity.json")
done
echo "$n file(s) $([ "$MODE" = lock ] && echo 'locked: root:root, read-only for others' || echo "unlocked: $USER_NAME-owned, group-writable")"
