#!/usr/bin/env bash
# =============================================================================
# cockpit_cron.sh — the scheduler's heartbeat line in the OWNER's crontab.
# Jobs (scheduler.php) only run when something ticks them every minute; without
# this line the Jobs panel sits at "cron not firing" forever and nothing fires
# unless a page happens to call ?action=tick (found in the 2026-09-22 audit).
#
#   cockpit_cron.sh install   — add the line (idempotent)
#   cockpit_cron.sh remove    — take it out
#   cockpit_cron.sh status    — print installed|absent + the line
#
# Runs as the person who owns the install. The app calls it through the same
# sudo -u allowlist the toolbar launchers use.
# =============================================================================
set -u
ACTION="${1:-status}"
WEB_ROOT="${COCKPIT_WEB_ROOT:-}"
if [ -z "$WEB_ROOT" ]; then
    for d in "$HOME/.local/share/cockpit-web/cockpit" /var/www/html/cockpit /srv/http/cockpit /srv/www/htdocs/cockpit; do
        [ -f "$d/scheduler.php" ] && { WEB_ROOT="$d"; break; }
    done
fi
[ -n "$WEB_ROOT" ] || { echo "cockpit_cron: cannot find the web root (set COCKPIT_WEB_ROOT)"; exit 2; }
PHP_BIN="$(command -v php || echo /usr/bin/php)"
MARK="# AI Cockpit scheduler"
LINE="*/1 * * * * $PHP_BIN $WEB_ROOT/scheduler.php >/dev/null 2>&1 $MARK"

command -v crontab >/dev/null 2>&1 || { echo "cockpit_cron: crontab not installed (package cron/cronie)"; exit 3; }
current="$(crontab -l 2>/dev/null)"; st=$?
[ $st -ne 0 ] && current=""

case "$ACTION" in
    install)
        if printf '%s\n' "$current" | grep -qF "$MARK"; then
            # Refresh it in place: the web root or php path may have changed.
            printf '%s\n' "$current" | grep -vF "$MARK" > /tmp/ck_cron.$$ || true
        else
            printf '%s\n' "$current" > /tmp/ck_cron.$$
        fi
        # Drop a trailing blank line, append ours, install.
        # BSD sed (macOS) reads the next argument as a backup suffix, so the
        # GNU form would eat the script. Pick the right one.
        if sed --version >/dev/null 2>&1; then sed -i '/^[[:space:]]*$/d' /tmp/ck_cron.$$
        else sed -i '' '/^[[:space:]]*$/d' /tmp/ck_cron.$$; fi
        printf '%s\n' "$LINE" >> /tmp/ck_cron.$$
        crontab /tmp/ck_cron.$$ && echo "installed: $LINE" || { echo "crontab refused the line"; rm -f /tmp/ck_cron.$$; exit 4; }
        rm -f /tmp/ck_cron.$$
        ;;
    remove)
        printf '%s\n' "$current" | grep -vF "$MARK" > /tmp/ck_cron.$$ || true
        crontab /tmp/ck_cron.$$ && echo removed || echo "nothing to remove"
        rm -f /tmp/ck_cron.$$
        ;;
    status|*)
        if printf '%s\n' "$current" | grep -qF "$MARK"; then echo "installed"; printf '%s\n' "$current" | grep -F "$MARK"
        else echo "absent"; echo "$LINE"; fi
        ;;
esac
