#!/bin/bash
# =============================================================================
# cockpit_sup_autostart.sh — start AI Cockpit's supervisor (and with it the three agent loops and the scheduler tick) by itself
# at login, as a systemd USER service. Opt-in; nothing here needs administrator rights.
#
#   cockpit_sup_autostart.sh install [--edition v2|v1]   write the unit, enable and start it, and turn the supervisor switch on
#   cockpit_sup_autostart.sh remove  [--edition v2|v1]   stop and disable it, delete the unit (the switch file is left as it is)
#   cockpit_sup_autostart.sh status  [--edition v2|v1]
#   cockpit_sup_autostart.sh print   [--edition v2|v1]   show the unit that install would write; changes nothing
#
# The unit regenerates the supervisor's configuration before every start (cockpit_sup_config.php --auto), so an upgrade or a moved
# web root never leaves it stale. Stopping everything with cockpit_stop.sh stops the supervisor cleanly (exit 0), which systemd does
# not restart; the next login starts it again. To have it start at BOOT without anyone logged in, one administrator command is
# needed once (this script never runs it):  sudo loginctl enable-linger $USER
# =============================================================================
set -u
ACTION="${1:-status}"; shift || true
EDITION="${COCKPIT_EDITION:-v2}"
while [ $# -gt 0 ]; do
    case "$1" in
        --edition) EDITION="${2:-}"; shift 2 ;;
        --edition=*) EDITION="${1#--edition=}"; shift ;;
        *) echo "cockpit_sup_autostart: unknown argument '$1'"; exit 2 ;;
    esac
done
case "$EDITION" in v1|v2) ;; *) echo "cockpit_sup_autostart: --edition must be v1 or v2"; exit 2 ;; esac
case "$ACTION" in install|remove|status|print) ;; *) echo "usage: $0 install|remove|status|print [--edition v2|v1]"; exit 2 ;; esac

HOME_DIR="${HOME:?}"
case "$EDITION" in v1) DATA="$HOME_DIR/scripts/cockpit_data_v1" ;; *) DATA="$HOME_DIR/scripts/cockpit_data" ;; esac
NAME="aicockpit-supervisor-$EDITION"
UNIT_DIR="${COCKPIT_UNIT_DIR:-$HOME_DIR/.config/systemd/user}"
UNIT="$UNIT_DIR/$NAME.service"
SUP="${COCKPIT_SUP_BIN:-$HOME_DIR/scripts/aicsupervisor}"
CFGPHP="$HOME_DIR/scripts/cockpit_sup_config.php"
PHP_BIN="$(command -v php || true)"
ED_UC="$(printf %s "$EDITION" | tr "[:lower:]" "[:upper:]")"

unit_text() {
    cat <<UNIT
# $UNIT   (systemctl --user enable --now $NAME)
# Written by cockpit_sup_autostart.sh for AI Cockpit $ED_UC. Remove with: cockpit_sup_autostart.sh remove --edition $EDITION
[Unit]
Description=AI Cockpit supervisor ($ED_UC: agent loops and scheduler tick)
After=network.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p $DATA/supervisor
ExecStartPre=$PHP_BIN $CFGPHP --auto --edition $EDITION --out $DATA/supervisor/cockpit.supervisor.json
ExecStart=$SUP run --config $DATA/supervisor/cockpit.supervisor.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3
# the supervisor stops its services itself, in order; only SIGTERM it, and give it time
KillMode=mixed
TimeoutStopSec=60

[Install]
WantedBy=default.target
UNIT
}

need() {
    [ -x "$SUP" ] || { echo "cockpit_sup_autostart: $SUP is missing (deploy a build that ships it)"; exit 3; }
    [ -f "$CFGPHP" ] || { echo "cockpit_sup_autostart: $CFGPHP is missing"; exit 3; }
    [ -n "$PHP_BIN" ] || { echo "cockpit_sup_autostart: php is not installed"; exit 3; }
}
sctl() { systemctl --user "$@"; }
user_systemd() { command -v systemctl >/dev/null 2>&1 && sctl is-system-running >/dev/null 2>&1 || sctl show-environment >/dev/null 2>&1; }

case "$ACTION" in
    print) need; unit_text ;;
    install)
        need
        user_systemd || { echo "cockpit_sup_autostart: no systemd user session here (is this a desktop login?)"; exit 4; }
        mkdir -p "$UNIT_DIR" "$DATA" || exit 1
        unit_text > "$UNIT.tmp" && mv -f "$UNIT.tmp" "$UNIT" || exit 1
        touch "$DATA/use_supervisor"
        # tmux loops left from an earlier start would answer every prompt a second time next to the supervised ones: end them (the Tools session stays)
        _DOC="${COCKPIT_DOCROOT:-}"
        if [ -z "$_DOC" ]; then for _d in "$HOME/.local/share/cockpit-web" /var/www/html /srv/http /srv/www/htdocs /var/www/localhost/htdocs; do [ -f "$_d/cockpit/index.html" ] || [ -f "$_d/cockpit-v1/index.html" ] && { _DOC="$_d"; break; }; done; fi
        case "$EDITION" in v1) _TSOCK="${_DOC:-/var/www/html}/cockpit-v1/tmux.sock" ;; *) _TSOCK="${_DOC:-/var/www/html}/cockpit/tmux.sock" ;; esac
        if command -v tmux >/dev/null 2>&1 && [ -S "$_TSOCK" ]; then
            for _a in claude gemini ollama; do tmux -S "$_TSOCK" kill-session -t "cockpit_$_a" 2>/dev/null && echo "ended the tmux session cockpit_$_a (the supervisor serves that agent now)"; done
        fi
        sctl daemon-reload && sctl enable --now "$NAME" || { echo "cockpit_sup_autostart: systemctl --user could not enable $NAME"; exit 5; }
        echo "installed and started: $NAME (unit $UNIT)"
        echo "the supervisor switch is on: $DATA/use_supervisor"
        if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
            echo "note: it starts when you log in. To start at boot without logging in, run once:  sudo loginctl enable-linger $USER"
        fi
        ;;
    remove)
        user_systemd && { sctl disable --now "$NAME" 2>/dev/null; true; }
        rm -f "$UNIT"; user_systemd && sctl daemon-reload 2>/dev/null
        echo "removed: $NAME (the switch file $DATA/use_supervisor is left; delete it to go back to tmux)"
        ;;
    status)
        [ -f "$UNIT" ] && echo "unit: installed ($UNIT)" || echo "unit: not installed"
        [ -f "$DATA/use_supervisor" ] && echo "switch: on ($DATA/use_supervisor)" || echo "switch: off"
        user_systemd && echo "service: $(sctl is-active "$NAME" 2>/dev/null) / $(sctl is-enabled "$NAME" 2>/dev/null)"
        echo "linger: $(loginctl show-user "$USER" -p Linger --value 2>/dev/null)   (yes = starts at boot without a login)"
        ;;
esac
