#!/bin/bash
# =============================================================================
# cockpit_start.sh — AI Cockpit session launcher (edition-aware: V2 or V1).
# Location: ~/scripts/cockpit_start.sh
#
# Edition is chosen by COCKPIT_EDITION (v2 default; the cockpit-v1-start wrapper
# sets v1). Each edition has its own web root, tmux socket, queue/responses,
# data dir, splash and app URL, so V1 and V2 never share agent state. Only one
# edition runs at a time — launching the other while one is up prompts to switch.
#
# Usage:  cockpit-start [claude|gemini|ollama|all] [--force]
#         COCKPIT_EDITION=v1 cockpit_start.sh ...   (or the cockpit-v1-start cmd)
#   --force / COCKPIT_FORCE_RESTART=1 : recreate sessions even if already up.
#   COCKPIT_INVOKED_FROM_WEB=1        : skip browser launch (web UI already open).
# =============================================================================

LAUNCH_BROWSER=1
[ "$COCKPIT_INVOKED_FROM_WEB" = "1" ] && LAUNCH_BROWSER=0

# --toggle: what a DESKTOP shortcut calls. A running window is raised (or put
# down when it is already in front); nothing running starts Cockpit normally.
# The app's own key grab cannot do the second half — it only exists while the
# app runs — so the desktop keeps one shortcut and the shell skips its grab.
# --edition v1|v2: which edition this invocation is for. Taken off the argument
# list here, before anything else parses "$@". The WEB path needs it because
# session.php runs this through `sudo -u <owner>`, which strips the environment,
# so COCKPIT_EDITION never arrives and every start from the V1 app would act on
# V2. sudoers already permits `cockpit_start.sh *`, so an argument costs nothing;
# an env var would need a sudoers change. See the matching note in cockpit_stop.sh.
_ED_ARG=""
_keep=""
SELF_WEB="${COCKPIT_SELF:-0}"     # --self: this run is the SELF-CONTAINED one (aicserver + php-cgi on a side port, no Apache); see the block after the supervisor helpers
while [ $# -gt 0 ]; do
    case "$1" in
        --edition) _ED_ARG="$2"; shift 2 ;;
        --edition=*) _ED_ARG="${1#--edition=}"; shift ;;
        --self) SELF_WEB=1; shift ;;
        *) _keep="$_keep $1"; shift ;;
    esac
done
# shellcheck disable=SC2086
set -- $_keep
case "$_ED_ARG" in v1|v2) ;; *) _ED_ARG="" ;; esac

COCKPIT_TOGGLE=0
case " $* " in *" --toggle "*) COCKPIT_TOGGLE=1 ;; esac
if [ "$COCKPIT_TOGGLE" = "1" ]; then
    _win_title="AI Cockpit"; [ "${COCKPIT_EDITION:-v2}" = "v1" ] && _win_title="AI Cockpit V1"
    if command -v wmctrl >/dev/null 2>&1 && wmctrl -l 2>/dev/null | grep -qE "[[:space:]]${_win_title}\$"; then
        _wid=$(wmctrl -l | grep -E "[[:space:]]${_win_title}\$" | head -1 | awk '{print $1}')
        _act=$(xdotool getactivewindow 2>/dev/null || echo 0)
        if [ "$(printf '%d' "$_act" 2>/dev/null)" = "$(printf '%d' "$_wid" 2>/dev/null)" ]; then
            xdotool windowminimize "$_wid" 2>/dev/null || wmctrl -i -r "$_wid" -b add,hidden 2>/dev/null
        else
            wmctrl -i -a "$_wid" 2>/dev/null
        fi
        exit 0
    fi
    set -- $(printf '%s ' "$@" | sed 's/--toggle//')
fi

# GUI launch (no tty) → log to file so only the splash + app window show.
if [ ! -t 1 ] && [ "$COCKPIT_INVOKED_FROM_WEB" != "1" ]; then
    mkdir -p "$HOME/.cache" 2>/dev/null
    exec >>"$HOME/.cache/cockpit_start.log" 2>&1
fi

# ── Edition config ───────────────────────────────────────────────────────────
# Web docroot differs per distro (Debian/Fedora /var/www/html, Arch /srv/http,
# openSUSE /srv/www/htdocs, Gentoo /var/www/localhost/htdocs). Probe for the
# installed app rather than assume Debian's — the Manjaro VM's window refused to
# start: 'no manifest (/var/www/html/cockpit/integrity.json)'.
DOCROOT="${COCKPIT_DOCROOT:-}"
if [ -z "$DOCROOT" ]; then
    for _d in "$HOME/.local/share/cockpit-web" /var/www/html /srv/http /srv/www/htdocs /var/www/localhost/htdocs; do
        if [ -f "$_d/cockpit/index.html" ] || [ -f "$_d/cockpit-v1/index.html" ]; then DOCROOT="$_d"; break; fi
    done
    DOCROOT="${DOCROOT:-/var/www/html}"
fi
EDITION="${_ED_ARG:-${COCKPIT_EDITION:-v2}}"
case "$EDITION" in
    v1) WEB_ROOT="$DOCROOT/cockpit-v1"; APP_URL="http://localhost/cockpit-v1/"
        COCKPIT_DATA_DIR="$HOME/scripts/cockpit_data_v1"; SPLASH_FILE="cockpit_splash_v1.html"
        WIN_TITLE="AI Cockpit V1"; ED_LABEL="V1"
        OTHER_SOCKET="$DOCROOT/cockpit/tmux.sock"; OTHER_LABEL="V2" ;;
    *)  EDITION="v2"; WEB_ROOT="$DOCROOT/cockpit"; APP_URL="http://localhost/cockpit/"
        COCKPIT_DATA_DIR="$HOME/scripts/cockpit_data"; SPLASH_FILE="cockpit_splash.html"
        WIN_TITLE="AI Cockpit"; ED_LABEL="V2"
        OTHER_SOCKET="$DOCROOT/cockpit-v1/tmux.sock"; OTHER_LABEL="V1" ;;
esac
SOCKET="$WEB_ROOT/tmux.sock"
RESPONSE_DIR="$WEB_ROOT/responses"
QUEUE_DIR="$WEB_ROOT/queue"
# Passed into each agent_loop via send-keys so it watches THIS edition's dirs.
AGENT_ENV="COCKPIT_QUEUE_DIR='$QUEUE_DIR' COCKPIT_RESPONSE_DIR='$RESPONSE_DIR' COCKPIT_DATA_DIR='$COCKPIT_DATA_DIR'"

# Projects root from this edition's paths.json (fallback sane default).
COCKPIT_ROOT=""
_PATHS_JSON="$WEB_ROOT/paths.json"
if [ -f "$_PATHS_JSON" ] && command -v jq >/dev/null 2>&1; then
    COCKPIT_ROOT="$(jq -r '.projects_root // empty' "$_PATHS_JSON" 2>/dev/null)"
fi
[ -z "$COCKPIT_ROOT" ] && COCKPIT_ROOT="$HOME/Software/Programing/LocalAIProjs"

BLUE='\033[0;34m'; YELLOW='\033[1;33m'; ORANGE='\033[0;33m'; RESET='\033[0m'

# Browser + Ozone backend (shared by splash + app launch).
OZ="${XDG_SESSION_TYPE:-x11}"; [ "$OZ" = "wayland" ] || OZ="x11"
_def_browser="$(xdg-settings get default-web-browser 2>/dev/null | sed 's/\.desktop$//')"
BROWSER=""
for _b in "$_def_browser" brave-browser brave google-chrome google-chrome-stable \
          chromium chromium-browser microsoft-edge vivaldi-stable firefox; do
    [ -n "$_b" ] && command -v "$_b" >/dev/null 2>&1 && { BROWSER="$_b"; break; }
done
# No fake default: a machine without any of these gets an empty BROWSER (the
# Arch/MATE VM carried "brave-browser" into session_env and the Browser button).
GPUFLAG="--disable-gpu-compositing"   # AMD/Chromium click-offset workaround

# Native shell (scripts/cockpit_shell, sources in scripts/cockpit_shell_src/):
# the ONLY launcher when it can run here. It owns the window, so the close
# button / Alt+F4 / dock Quit run the app's exit procedure instead of just
# closing. The browser --app window below is the fallback (binary missing or
# the WebKitGTK runtime not installed).
# readlink -f is GNU; BSD readlink (macOS) has no -f. Resolve by walking instead,
# so the script finds its own directory on both systems.
rlf() {
    local t="$1"
    while [ -L "$t" ]; do
        local d; d="$(cd "$(dirname "$t")" && pwd)"
        t="$(readlink "$t")"
        case "$t" in /*) ;; *) t="$d/$t" ;; esac
    done
    printf '%s' "$t"
}

_SELF_DIR="$( cd "$( dirname "$( rlf "${BASH_SOURCE[0]}" )" )" && pwd )"
SHELL_BIN="$_SELF_DIR/cockpit_shell"
USE_SHELL=0
if [ "$LAUNCH_BROWSER" = "1" ] && [ -x "$SHELL_BIN" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] \
   && "$SHELL_BIN" --check >/dev/null 2>&1; then
    USE_SHELL=1
fi
SHELL_READY="${XDG_RUNTIME_DIR:-/tmp}/cockpit_shell_ready_$EDITION"
# The shell checks the build manifest before it loads the app: a changed
# index.html/auth.php/paths.php/integrity_lib.php means the window shows what
# happened instead of running it. COCKPIT_NO_VERIFY=1 skips the check,
# COCKPIT_KIOSK=1 runs fullscreen and undecorated (dedicated screen).
SHELL_EXTRA=""
[ "${COCKPIT_NO_VERIFY:-0}" = "1" ] || SHELL_EXTRA="--verify $WEB_ROOT"
[ "${COCKPIT_KIOSK:-0}" = "1" ] && SHELL_EXTRA="$SHELL_EXTRA --kiosk"
# One global key combination summons the window from any app (X11 only):
# COCKPIT_HOTKEY="super+c", or "none" to grab nothing.
# A desktop shortcut (scripts/install_hotkey.sh) owns the combination when it is
# registered — two owners of one key is one too many, so the shell grabs nothing
# then. COCKPIT_HOTKEY="super+c" still gives the shell its own key.
_hk="${COCKPIT_HOTKEY:-}"
if [ -z "$_hk" ]; then
    if command -v gsettings >/dev/null 2>&1 && gsettings list-recursively 2>/dev/null | grep -q "cockpit-start --toggle"; then _hk=none; else _hk=ctrl+alt+c; fi
fi
SHELL_EXTRA="$SHELL_EXTRA --hotkey $_hk"

session_exists() { tmux -S "$SOCKET" has-session -t "$1" 2>/dev/null; }

# ── Supervisor mode (opt-in) ─────────────────────────────────────────────────
# With a file called use_supervisor in this edition's cockpit_data folder (or COCKPIT_SUPERVISOR=1) AND the aicsupervisor binary beside
# the scripts, the three agent loops run as services of aicsupervisor instead of tmux panes: restarted if they die, stopped from the
# Stop button by a signal to the running CLI only. Anything missing = the tmux path below, unchanged. The Tools session stays in tmux.
# State (control socket, token, logs): $COCKPIT_DATA_DIR/supervisor; the web server's account reaches it through the owner's group.
SUP_BIN="${COCKPIT_SUP_BIN:-$HOME/scripts/aicsupervisor}"
SUP_DIR="$COCKPIT_DATA_DIR/supervisor"
use_supervisor() {
    [ -x "$SUP_BIN" ] || return 1
    [ "${COCKPIT_SUPERVISOR:-}" = "1" ] || [ -f "$COCKPIT_DATA_DIR/use_supervisor" ]
}
sup_ctl() { "$SUP_BIN" ctl --socket "$SUP_DIR/sup.sock" --token-file "$SUP_DIR/token" "$@"; }
sup_up()  { [ -S "$SUP_DIR/sup.sock" ] && [ -r "$SUP_DIR/token" ] && sup_ctl ping >/dev/null 2>&1; }
# the supervisor of the OTHER edition (for the one-edition-at-a-time rule): its data dir is the mirror of ours
if [ "$EDITION" = "v1" ]; then OTHER_SUP_DIR="$HOME/scripts/cockpit_data/supervisor"; else OTHER_SUP_DIR="$HOME/scripts/cockpit_data_v1/supervisor"; fi
other_sup_up() { [ -x "$SUP_BIN" ] && [ -S "$OTHER_SUP_DIR/sup.sock" ] && [ -r "$OTHER_SUP_DIR/token" ] && "$SUP_BIN" ctl --socket "$OTHER_SUP_DIR/sup.sock" --token-file "$OTHER_SUP_DIR/token" ping >/dev/null 2>&1; }
# is some agent of THIS edition running under the supervisor?
sup_any_running() { sup_up && sup_ctl status 2>/dev/null | grep -Eq '^cockpit_[a-z]+ +running'; }
# write the configuration and make sure a supervisor is running on it; 0 = ready
sup_ensure() {
    local _grp="" _wu _cfgargs
    for _wu in www-data apache http wwwrun; do id -u "$_wu" >/dev/null 2>&1 && { _grp="$(id -gn)"; break; }; done   # the web account shares the owner's group (as for tmux.sock)
    mkdir -p "$SUP_DIR" 2>/dev/null
    php "$_SELF_DIR/cockpit_sup_config.php" --edition "$EDITION" --web-root "$WEB_ROOT" --data-dir "$COCKPIT_DATA_DIR" \
        --projects-root "$COCKPIT_ROOT" --loop "$HOME/scripts/agent_loop.sh" ${_grp:+--group "$_grp"} --out "$SUP_DIR/cockpit.supervisor.json" || return 1
    "$SUP_BIN" check --config "$SUP_DIR/cockpit.supervisor.json" >/dev/null 2>&1 || { echo "supervisor: the generated configuration is invalid"; return 1; }
    if sup_up; then
        sup_ctl reload >/dev/null 2>&1 || true                       # an unchanged file restarts nothing
        return 0
    fi
    rm -f "$SUP_DIR/sup.sock"
    ( setsid "$SUP_BIN" run --config "$SUP_DIR/cockpit.supervisor.json" >>"$SUP_DIR/supervisor.out" 2>&1 < /dev/null & )
    local _i; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do sup_up && return 0; sleep 0.25; done
    echo "supervisor: did not start (see $SUP_DIR/supervisor.out)"; return 1
}
# start one agent under the supervisor; returns 1 when it was already running and left alone (like start_session)
sup_start_agent() {
    local _n="cockpit_$1"
    # the supervisor takes over this agent: a tmux loop left from an earlier start would answer every prompt a second time
    session_exists "$_n" && tmux -S "$SOCKET" kill-session -t "$_n" 2>/dev/null
    if sup_ctl status 2>/dev/null | grep -Eq "^$_n +running"; then
        if [ "${FORCE_RESTART:-0}" = "1" ]; then sup_ctl restart "$_n" >/dev/null 2>&1; sleep 1; return 0; fi
        return 1
    fi
    sup_ctl start "$_n" >/dev/null 2>&1; sleep 1; return 0
}

# ── Self-contained mode (--self / COCKPIT_SELF=1) ───────────────────────────────────────────────────────────────────────────────────────
# The same Cockpit, served WITHOUT Apache: the supervisor runs aicserver (a small Free Pascal web server) and php-cgi as you, on a side port
# (8081 for V2, 8082 for V1, or the number written in the file use_aicserver), and the window opens there. Needs aicserver, php-cgi and the
# supervisor; when one is missing this run falls back to Apache. The mode is two empty files in this edition's data folder
# (use_supervisor, use_aicserver): --self makes sure they exist. The ordinary start keeps opening the Apache address; both can coexist.
SELF_PORT=""
self_prepare() {
    [ "$SELF_WEB" = "1" ] || return 0
    local _bin="${COCKPIT_AICSERVER_BIN:-$HOME/scripts/aicserver}" _pn _mnt
    if [ ! -x "$_bin" ] || ! command -v php-cgi >/dev/null 2>&1 || [ ! -x "$SUP_BIN" ]; then
        echo "NOTE: the self-contained mode needs aicserver, php-cgi and the supervisor, and one is missing: using Apache this time"
        SELF_WEB=0; return 0
    fi
    mkdir -p "$COCKPIT_DATA_DIR" 2>/dev/null
    [ -f "$COCKPIT_DATA_DIR/use_supervisor" ] || : > "$COCKPIT_DATA_DIR/use_supervisor"
    [ -f "$COCKPIT_DATA_DIR/use_aicserver" ] || : > "$COCKPIT_DATA_DIR/use_aicserver"
    _pn="$(tr -dc '0-9' < "$COCKPIT_DATA_DIR/use_aicserver" 2>/dev/null)"
    if [ -n "$_pn" ] && [ "$_pn" -ge 1024 ] 2>/dev/null && [ "$_pn" -le 65535 ] 2>/dev/null; then SELF_PORT="$_pn"
    elif [ "$EDITION" = "v1" ]; then SELF_PORT=8082; else SELF_PORT=8081; fi
    case "$EDITION" in v1) _mnt="cockpit-v1" ;; *) _mnt="cockpit" ;; esac
    APP_URL="http://127.0.0.1:$SELF_PORT/$_mnt/"
}
self_prepare

# ── Mutual exclusion: only one edition at a time ─────────────────────────────
# If the OTHER edition has live sessions, offer to switch (stop it) or cancel.
# A third option matters because the other edition's own window may not be able
# to close its sessions itself: before the sudoers fix, V1 could start and stop
# sessions but never SEE them, so its session count was empty and there was
# nothing to click. This dialog is then the only place to shut them down.
stop_other_edition() {
    tmux -S "$OTHER_SOCKET" kill-server 2>/dev/null || true
    other_sup_up && "$SUP_BIN" ctl --socket "$OTHER_SUP_DIR/sup.sock" --token-file "$OTHER_SUP_DIR/token" shutdown >/dev/null 2>&1
    pkill -f "cockpit_shell --url" 2>/dev/null   # sessions are gone; no modal to show
    command -v wmctrl >/dev/null 2>&1 && wmctrl -c "AI Cockpit $OTHER_LABEL" 2>/dev/null
    [ "$OTHER_LABEL" = "V2" ] && command -v wmctrl >/dev/null 2>&1 && wmctrl -c "AI Cockpit" 2>/dev/null
    return 0
}

if tmux -S "$OTHER_SOCKET" has-session 2>/dev/null || other_sup_up; then
    _switch=0
    _closeall=0
    _CLOSE_LABEL="Close all running sessions"
    if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        # --extra-button returns rc=1 like Cancel does, but prints its own label
        # on stdout — that is the only way to tell the two apart.
        _ans="$(zenity --question --no-wrap --title="AI Cockpit" \
            --text="AI Cockpit $OTHER_LABEL is currently running.\n\nOnly one edition can run at a time.\nStop $OTHER_LABEL and start $ED_LABEL?" \
            --ok-label="Switch to $ED_LABEL" --cancel-label="Cancel" \
            --extra-button="$_CLOSE_LABEL" 2>/dev/null)"; _rc=$?
        if [ "$_rc" = 0 ]; then _switch=1
        elif [ "$_ans" = "$_CLOSE_LABEL" ]; then _closeall=1
        fi
    elif [ -t 0 ]; then
        printf "AI Cockpit %s is running. [s]witch to %s, [c]lose all sessions, or cancel? [s/c/N] " "$OTHER_LABEL" "$ED_LABEL"
        read -r _a
        case "$_a" in
            s|S|y|Y|yes) _switch=1 ;;
            c|C)         _closeall=1 ;;
        esac
    fi
    if [ "$_closeall" = "1" ]; then
        # Shut everything down and start nothing — the escape hatch when an
        # edition is running that the user cannot reach any other way.
        stop_other_edition
        tmux -S "$SOCKET" kill-server 2>/dev/null || true
        sup_up && sup_ctl shutdown >/dev/null 2>&1
        echo "Closed all running sessions. Nothing started."
        exit 0
    fi
    if [ "$_switch" = "1" ]; then
        stop_other_edition
        sleep 1
    else
        echo "Cancelled — $OTHER_LABEL left running."
        exit 0
    fi
fi

# ── Already-open guard (same edition) ────────────────────────────────────────
# WIN_OPEN=1 means this edition's window is already up → don't open a second one
# (just focus it). We only EXIT early when the window AND its sessions are both
# up (nothing to do). If the window is up but sessions are down, we proceed to
# (re)start the sessions and reuse the existing window.
case "$*" in *--force*) _skip_guard=1 ;; *) _skip_guard=0 ;; esac
WIN_OPEN=0
if [ "$LAUNCH_BROWSER" = "1" ] && [ "${XDG_SESSION_TYPE:-x11}" != "wayland" ] \
   && command -v wmctrl >/dev/null 2>&1; then
    if wmctrl -l 2>/dev/null | grep -qE "[[:space:]]${WIN_TITLE}\$"; then
        WIN_OPEN=1
        wmctrl -a "$WIN_TITLE" 2>/dev/null || true
        if [ "$_skip_guard" = "0" ] && { tmux -S "$SOCKET" has-session 2>/dev/null || sup_any_running; }; then
            # Fully up already — nothing to do.
            if command -v zenity >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
                ( zenity --info --no-wrap --title="$WIN_TITLE" --timeout=4 \
                    --text="$WIN_TITLE is already open.\nBrought its window to the front." >/dev/null 2>&1 & )
            fi
            exit 0
        fi
    fi
fi

# ── Loading splash (GUI only) ────────────────────────────────────────────────
SCRIPT_DIR_SELF="$( cd "$( dirname "$( rlf "${BASH_SOURCE[0]}" )" )" && pwd )"
SPLASH_HTML="$SCRIPT_DIR_SELF/$SPLASH_FILE"
SPLASH_PROFILE="$HOME/.cache/cockpit-splash-profile-$EDITION"
SPLASH_MIN_SECS=4
SPLASH_PID=""; SPLASH_STARTED=0
splash_start() {
    [ "$LAUNCH_BROWSER" = "1" ] || return 0
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || return 0
    if [ "$USE_SHELL" = "1" ]; then
        # One window for the whole run: splash now, the app once the ready file
        # appears (splash_stop touches it). Nothing to kill later.
        [ "$WIN_OPEN" = "1" ] && return 0
        rm -f "$SHELL_READY"
        _icon="$HOME/.local/share/icons/ai-cockpit.png"; [ -f "$_icon" ] || _icon="$WEB_ROOT/assets/logo_512.png"
        setsid "$SHELL_BIN" --url "$APP_URL" --title "$WIN_TITLE" --icon "$_icon" $SHELL_EXTRA \
            --splash "$SPLASH_HTML" --ready "$SHELL_READY" --start "$_SELF_DIR/$(basename "${BASH_SOURCE[0]}")" \
            >>"$HOME/.cache/cockpit_shell.log" 2>&1 < /dev/null &
        SPLASH_STARTED=$(date +%s); SPLASH_SHELL=1
        return 0
    fi
    [ -f "$SPLASH_HTML" ] || return 0
    case "$BROWSER" in ""|*firefox*) return 0 ;; esac   # no browser at all: no splash either
    mkdir -p "$SPLASH_PROFILE/Default" 2>/dev/null
    rm -f "$SPLASH_PROFILE"/Singleton* 2>/dev/null
    [ -f "$SPLASH_PROFILE/Default/Preferences" ] || printf '%s' \
      '{"brave":{"p3a":{"enabled":false,"notice_acknowledged":true},"stats":{"reporting_enabled":false},"rewards":{"enabled":false}},"browser":{"has_seen_welcome_page":true}}' \
      > "$SPLASH_PROFILE/Default/Preferences" 2>/dev/null
    [ -f "$SPLASH_PROFILE/Local State" ] || printf '%s' \
      '{"brave":{"p3a":{"enabled":false,"notice_acknowledged":true},"p3a_enabled":false}}' \
      > "$SPLASH_PROFILE/Local State" 2>/dev/null
    local _pos="" _sw _sh _px _py
    if command -v xdotool >/dev/null 2>&1; then
        set -- $(xdotool getdisplaygeometry 2>/dev/null); _sw="$1"; _sh="$2"
        if [ -n "$_sw" ] && [ -n "$_sh" ]; then
            _px=$(( (_sw - 440) / 2 )); _py=$(( (_sh - 780) / 2 ))
            [ "$_px" -lt 0 ] && _px=0; [ "$_py" -lt 0 ] && _py=0
            _pos="--window-position=${_px},${_py}"
        fi
    fi
    "$BROWSER" --ozone-platform="$OZ" $GPUFLAG --user-data-dir="$SPLASH_PROFILE" \
        --no-first-run --no-default-browser-check --disable-extensions \
        --disable-background-networking --disable-sync --disable-brave-update \
        --disable-features=BraveP3A,BraveRewards,BraveAds,BraveWelcomeUI \
        $_pos --window-size=440,780 --app="file://$SPLASH_HTML" >/dev/null 2>&1 &
    SPLASH_PID=$!; SPLASH_STARTED=$(date +%s)
}
SPLASH_SHELL=0
splash_stop() {
    if [ "$SPLASH_SHELL" = "1" ]; then
        local shown=$(( $(date +%s) - SPLASH_STARTED ))
        [ "$shown" -lt "$SPLASH_MIN_SECS" ] && sleep $(( SPLASH_MIN_SECS - shown ))
        touch "$SHELL_READY"; SPLASH_SHELL=0
        return 0
    fi
    [ -n "$SPLASH_PID" ] || return 0
    local shown=$(( $(date +%s) - SPLASH_STARTED ))
    [ "$shown" -lt "$SPLASH_MIN_SECS" ] && sleep $(( SPLASH_MIN_SECS - shown ))
    pkill -f -- "--user-data-dir=$SPLASH_PROFILE" 2>/dev/null
    kill "$SPLASH_PID" 2>/dev/null
    SPLASH_PID=""
}
trap 'splash_stop' EXIT
splash_start
[ -n "$SPLASH_PID" ] && sleep 1.5

# Response dir: dario owns it, www-data shares the group → 775, no sudo.
mkdir -p "$RESPONSE_DIR"
chmod 775 "$RESPONSE_DIR" 2>/dev/null || true

# ── Session helpers ──────────────────────────────────────────────────────────
start_session() {
    local NAME="$1" COLOR="$2" LABEL="$3"
    if session_exists "$NAME"; then
        if [ "${FORCE_RESTART:-0}" = "1" ]; then
            tmux -S "$SOCKET" kill-session -t "$NAME"; sleep 0.5
        else
            return 1   # already running — leave it (skip agent-loop resend)
        fi
    fi
    tmux -S "$SOCKET" new-session -d -s "$NAME" -x 220 -y 50 bash
    sleep 0.3
    tmux -S "$SOCKET" send-keys -t "$NAME" "cd \"$COCKPIT_ROOT\"" Enter
    sleep 0.2
}
start_claude() {
    if use_supervisor && sup_ensure; then sup_start_agent claude; return 0; fi
    start_session "cockpit_claude" "$YELLOW" "CLAUDE" || return 0
    tmux -S "$SOCKET" send-keys -t "cockpit_claude" "$AGENT_ENV $HOME/scripts/agent_loop.sh claude" Enter
    sleep 1
}
start_gemini() {
    if use_supervisor && sup_ensure; then sup_start_agent gemini; return 0; fi
    start_session "cockpit_gemini" "$BLUE" "GEMINI" || return 0
    tmux -S "$SOCKET" send-keys -t "cockpit_gemini" "$AGENT_ENV $HOME/scripts/agent_loop.sh gemini" Enter
    sleep 1
}
# Tools card (2026-09-13): tool runs (ffmpeg, pandoc, ...) run as windows of this
# session, so the card's "open session" button shows the live command exactly
# like the three agent cards. tools.php creates the session on demand too; this
# only makes it there from boot. No loop runs in it.
start_tools() {
    start_session "cockpit_tools" "$ORANGE" "TOOLS" || return 0
    tmux -S "$SOCKET" send-keys -t "cockpit_tools" "echo 'Cockpit TOOLS session -- each tool run opens as a window here (Ctrl-b n / p to switch).'" Enter
}
start_ollama() {
    if use_supervisor && sup_ensure; then sup_start_agent ollama; return 0; fi
    start_session "cockpit_ollama" "$ORANGE" "OLLAMA" || return 0
    tmux -S "$SOCKET" send-keys -t "cockpit_ollama" "$AGENT_ENV $HOME/scripts/agent_loop.sh ollama" Enter
    sleep 1
}

FORCE_RESTART="${COCKPIT_FORCE_RESTART:-0}"
TARGET="all"
for _a in "$@"; do
    case "$_a" in
        --force) FORCE_RESTART=1 ;;
        claude|gemini|ollama|tools|all) TARGET="$_a" ;;
    esac
done

case "$TARGET" in
    claude) start_claude ;;
    gemini) start_gemini ;;
    ollama) start_ollama ;;
    tools)  start_tools ;;
    all)
        start_claude; start_gemini; start_ollama; start_tools
        if [ -x "$HOME/scripts/libretranslate_start.sh" ]; then
            "$HOME/scripts/libretranslate_start.sh" >/dev/null 2>&1 || true
        fi
        ;;
    *) echo "Usage: $0 [claude|gemini|ollama|tools|all] [--force]"; exit 1 ;;
esac

# Snapshot the desktop session's identity for launch_cli.php. Terminals and
# browsers it opens run through sudo with a reset environment; without
# XDG_CURRENT_DESKTOP & co. xdg-open runs in generic mode and a login URL from
# a CLI landed in a text editor (ck-ubuntu2404). This script runs inside the
# real session, so it knows. World-readable on purpose: only names, no secrets.
# WSLg has a display but none of the desktop-identity variables, so DISPLAY/WAYLAND_DISPLAY count too.
if [ -n "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}${XDG_SESSION_TYPE:-}${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    _senv="$HOME/scripts/cockpit_data/session_env"
    mkdir -p "$(dirname "$_senv")" 2>/dev/null
    {
        # DISPLAY/WAYLAND_DISPLAY/XAUTHORITY too: Apache cannot glob /run/user/<uid> (0700), and Plasma's XWayland is :1, not :0 (Manjaro KDE VM: Konsole never opened)
        for _v in XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION GDMSESSION BROWSER DISPLAY WAYLAND_DISPLAY XAUTHORITY; do
            eval "_val=\${$_v:-}"; [ -n "$_val" ] && printf '%s=%s\n' "$_v" "$_val"
        done; true
    } > "$_senv.tmp" 2>/dev/null && mv -f "$_senv.tmp" "$_senv" && chmod 644 "$_senv" 2>/dev/null
fi

# Ensure the web server is up. The unit is apache2 on Debian/Ubuntu/Mint and
# httpd on Fedora/RHEL/Arch — a hard-coded apache2 on Fedora meant "not active",
# a sudo password prompt with no tty, and that prompt text landing inside
# session.php's JSON (first Fedora VM). The installer grants NOPASSWD for the
# real unit; -n means never prompt, just say so.
WEB_SVC=apache2; systemctl list-unit-files httpd.service >/dev/null 2>&1 && WEB_SVC=httpd
if [ "$SELF_WEB" != "1" ] && ! systemctl is-active --quiet "$WEB_SVC"; then
    sudo -n systemctl start "$WEB_SVC" 2>/dev/null || echo "NOTE: the web server ($WEB_SVC) is not running and could not be started without a password — run: sudo systemctl start $WEB_SVC"
    sleep 2
fi

# Self-contained: wait until aicserver answers (any HTTP answer will do) before the window is switched from the splash to the app.
if [ "$SELF_WEB" = "1" ]; then
    _i=0; while [ $_i -lt 40 ]; do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SELF_PORT/" && break; _i=$((_i + 1)); sleep 0.5; done
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$SELF_PORT/" || echo "NOTE: aicserver did not answer on port $SELF_PORT (see $SUP_DIR/logs)"
fi
sleep 3

# Socket perms: www-data shares dario's group → 660, no sudo/chgrp needed.
if [ -S "$SOCKET" ]; then
    chmod 660 "$SOCKET" 2>/dev/null || true
else
    echo "Warning: tmux socket not found at $SOCKET"
fi

# tmux 3.3+ server-access grant for www-data (silent; old tmux no-ops).
# the web server account differs per distro (www-data / apache / http / wwwrun)
for _wu in www-data apache http wwwrun; do id -u "$_wu" >/dev/null 2>&1 && { tmux -S "$SOCKET" server-access -aw "$_wu" 2>/dev/null || true; break; }; done

# Everywhere relay poller (self-gates on entitlement; V2 only in practice).
if [ -x "$SCRIPT_DIR_SELF/relay_start.sh" ]; then
    "$SCRIPT_DIR_SELF/relay_start.sh" || true
fi

# ── Open the app (chromeless --app window) ───────────────────────────────────
if [ "$LAUNCH_BROWSER" = "1" ]; then
    splash_stop
    if [ "$WIN_OPEN" = "1" ]; then
        # Window already open (sessions were just (re)started) — reuse it; the
        # web UI picks up the live sessions on its next status poll.
        command -v wmctrl >/dev/null 2>&1 && wmctrl -a "$WIN_TITLE" 2>/dev/null || true
    elif [ "$USE_SHELL" = "1" ]; then
        : # the shell window switched from the splash to the app in splash_stop
    else
        if [ -z "$BROWSER" ]; then echo "No browser found and the native window cannot run here — open http://localhost/cockpit/ in any browser."; else
        case "$BROWSER" in
            *firefox*)
                [ "$OZ" = "wayland" ] && export MOZ_ENABLE_WAYLAND=1
                "$BROWSER" "$APP_URL" >/dev/null 2>&1 &
                ;;
            *)
                "$BROWSER" --ozone-platform="$OZ" $GPUFLAG --app="$APP_URL" >/dev/null 2>&1 &
                ;;
        esac
        fi
    fi
fi
