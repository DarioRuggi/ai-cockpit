#!/bin/bash
# =============================================================================
# relay_start.sh — start the Everywhere relay poller (home rig side).
# Location: ~/scripts/relay_start.sh
# No-ops cleanly if the account isn't signed in / not entitled — safe to
# call unconditionally from cockpit_start.sh once Everywhere ships.
# =============================================================================
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PID_FILE="$SCRIPT_DIR/cockpit_data/.relay_poller.pid"
LOG_FILE="$SCRIPT_DIR/cockpit_data/relay_poller.log"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "[RELAY] Already running (PID $(cat "$PID_FILE"))."
    exit 0
fi

mkdir -p "$SCRIPT_DIR/cockpit_data"
nohup php "$SCRIPT_DIR/relay_poller.php" >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"
echo "[RELAY] Started (PID $!). Log: $LOG_FILE"
