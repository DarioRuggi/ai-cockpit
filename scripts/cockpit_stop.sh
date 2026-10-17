#!/bin/bash
# =============================================================================
# cockpit_stop.sh — stop AI Cockpit agent sessions (edition-aware: V2 or V1).
# COCKPIT_EDITION=v2 (default) or v1 (cockpit-v1-stop wrapper).
# Usage: cockpit-stop [claude|gemini|ollama|all]
# =============================================================================
# Docroot per distro: Debian/Fedora /var/www/html, Arch /srv/http, openSUSE /srv/www/htdocs.
DOCROOT="${COCKPIT_DOCROOT:-}"
if [ -z "$DOCROOT" ]; then
    for _d in "$HOME/.local/share/cockpit-web" /var/www/html /srv/http /srv/www/htdocs /var/www/localhost/htdocs; do
        if [ -f "$_d/cockpit/index.html" ] || [ -f "$_d/cockpit-v1/index.html" ]; then DOCROOT="$_d"; break; fi
    done
    DOCROOT="${DOCROOT:-/var/www/html}"
fi
# Edition, in priority order: --edition on the command line, then
# COCKPIT_EDITION (the cockpit-v1-* wrappers set it), then v2.
#
# The argument exists because the WEB path could not set the env var: session.php
# invokes this through `sudo -u <owner>`, which strips the environment, so every
# stop from the V1 app defaulted to v2 and killed V2's socket instead. V1's
# sessions could not be stopped from V1's own UI at all — found 2026-09-26 when
# "Terminate and leave" in V1 left all four sessions running and launching V2
# then reported V1 busy. sudoers already permits `cockpit_stop.sh *`, so an
# argument needs no sudoers change; an env var would have needed one.
EDITION="${COCKPIT_EDITION:-v2}"
_args=""
while [ $# -gt 0 ]; do
    case "$1" in
        --edition) EDITION="$2"; shift 2 ;;
        --edition=*) EDITION="${1#--edition=}"; shift ;;
        *) _args="$_args $1"; shift ;;
    esac
done
# shellcheck disable=SC2086
set -- $_args
case "$EDITION" in v1|v2) ;; *) EDITION="v2" ;; esac
case "$EDITION" in
    v1) SOCKET="$DOCROOT/cockpit-v1/tmux.sock" ;;
    *)  SOCKET="$DOCROOT/cockpit/tmux.sock" ;;
esac
BLUE='\033[0;34m'; YELLOW='\033[1;33m'; ORANGE='\033[0;33m'; RESET='\033[0m'

# Supervisor mode (see cockpit_start.sh): the agent loops are services of aicsupervisor. The data dir mirrors cockpit_start.sh's.
case "$EDITION" in v1) _DATA="$HOME/scripts/cockpit_data_v1" ;; *) _DATA="$HOME/scripts/cockpit_data" ;; esac
SUP_BIN="${COCKPIT_SUP_BIN:-$HOME/scripts/aicsupervisor}"; SUP_DIR="$_DATA/supervisor"
sup_up() { [ -x "$SUP_BIN" ] && [ -S "$SUP_DIR/sup.sock" ] && [ -r "$SUP_DIR/token" ] && "$SUP_BIN" ctl --socket "$SUP_DIR/sup.sock" --token-file "$SUP_DIR/token" ping >/dev/null 2>&1; }
sup_ctl() { "$SUP_BIN" ctl --socket "$SUP_DIR/sup.sock" --token-file "$SUP_DIR/token" "$@"; }
sup_stop_agent() {   # $1 agent, $2 colour, $3 label
    if sup_ctl status 2>/dev/null | grep -Eq "^cockpit_$1 +(running|starting|backoff|failed)"; then
        sup_ctl stop "cockpit_$1" >/dev/null 2>&1
        echo -e "$2[$3]${RESET} Session stopped."
    fi
}

stop_session() {
    local NAME="$1" COLOR="$2" LABEL="$3"
    if tmux -S "$SOCKET" has-session -t "$NAME" 2>/dev/null; then
        tmux -S "$SOCKET" kill-session -t "$NAME"
        echo -e "${COLOR}[${LABEL}]${RESET} Session stopped."
    fi
}

TARGET="${1:-all}"
case "$TARGET" in
    claude) sup_up && sup_stop_agent claude "$YELLOW" "CLAUDE"; stop_session "cockpit_claude" "$YELLOW" "CLAUDE" ;;
    gemini) sup_up && sup_stop_agent gemini "$BLUE" "GEMINI"; stop_session "cockpit_gemini" "$BLUE"   "GEMINI" ;;
    ollama) sup_up && sup_stop_agent ollama "$ORANGE" "OLLAMA"; stop_session "cockpit_ollama" "$ORANGE" "OLLAMA" ;;
    all)
        if [ "${COCKPIT_KEEP_WEB:-0}" = "1" ] && sup_up; then
            # The page that asked is served by THIS supervisor (the self-contained mode: aicserver + php-cgi are its services). Shutting the supervisor
            # down would take the page with it ("Load failed" on every poll, and Restart could never reach its Start). Stop the AGENTS only; the web
            # server, PHP and the file/command service stay up. "Terminate and leave" (the Exit dialog) asks for the full shutdown.
            sup_stop_agent claude "$YELLOW" "CLAUDE"; sup_stop_agent gemini "$BLUE" "GEMINI"; sup_stop_agent ollama "$ORANGE" "OLLAMA"
            echo "Agent sessions stopped (the web server stays up)."
        else
            # the supervisor stops its services in reverse order, then exits (nothing is left running)
            if sup_up; then sup_ctl shutdown >/dev/null 2>&1 && echo "Supervisor and its sessions stopped."; fi
        fi
        stop_session "cockpit_claude" "$YELLOW" "CLAUDE"
        stop_session "cockpit_gemini" "$BLUE"   "GEMINI"
        stop_session "cockpit_ollama" "$ORANGE" "OLLAMA"
        # kill the server if now empty (frees the socket cleanly)
        tmux -S "$SOCKET" kill-server 2>/dev/null || true
        echo "All $(printf '%s' "$EDITION" | tr '[:lower:]' '[:upper:]') sessions stopped."
        ;;
    *) echo "Usage: $0 [claude|gemini|ollama|all]"; exit 1 ;;
esac
