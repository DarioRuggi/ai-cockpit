#!/bin/bash
# =============================================================================
# relay_stop.sh — stop the Everywhere relay poller (home rig side).
# Location: ~/scripts/relay_stop.sh
# =============================================================================
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PID_FILE="$SCRIPT_DIR/cockpit_data/.relay_poller.pid"

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    kill "$(cat "$PID_FILE")"
    rm -f "$PID_FILE"
    echo "[RELAY] Stopped."
else
    echo "[RELAY] Was not running."
    rm -f "$PID_FILE"
fi
