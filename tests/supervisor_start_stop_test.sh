#!/bin/bash
# supervisor_start_stop_test.sh — the supervisor branches of cockpit_start.sh and cockpit_stop.sh, in a scratch tree.
#
# cockpit_start.sh opens windows, talks to the web server and the other edition; it is not run here. Its supervisor helpers
# (use_supervisor, sup_ensure, sup_start_agent, ...) are extracted from the real file and exercised. cockpit_stop.sh IS run, with
# COCKPIT_DOCROOT and HOME pointing into the scratch tree, so it can only ever see this tree's (non-existent) tmux server.
#   Exit 0 = pass; SKIPPED (exit 0) when aicsupervisor or php is missing.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUP="${AICSUP_BIN:-}"
for c in "$SUP" "$HOME/scripts/aicsupervisor" $HOME/aicockpit-runtime/aicsupervisor/bin/aicsupervisor; do [ -n "$c" ] && [ -x "$c" ] && { SUP="$c"; break; }; done
[ -x "$SUP" ] || { echo "supervisor_start_stop_test: aicsupervisor not found - SKIPPED"; exit 0; }
command -v php >/dev/null 2>&1 || { echo "supervisor_start_stop_test: php not found - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1
cleanup() { "$SUP" ctl --socket "$T/home/scripts/cockpit_data/supervisor/sup.sock" --token-file "$T/home/scripts/cockpit_data/supervisor/token" shutdown >/dev/null 2>&1; sleep 0.5; pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
mkdir -p "$T/home/scripts/cockpit_data" "$T/web/queue" "$T/web/responses" "$T/proj" "$T/docroot/cockpit"
cp "$ROOT/scripts/cockpit_sup_config.php" "$T/home/scripts/"
# a stand-in loop: stays alive and answers nothing (this test is about hosting, not about requests)
cat > "$T/home/scripts/agent_loop.sh" <<'LOOP'
#!/bin/bash
echo "loop $1 started $$"
while true; do sleep 1; done
LOOP
chmod +x "$T/home/scripts/agent_loop.sh"
# ---- the helpers, extracted from the real cockpit_start.sh ------------------------------------------------------------------
awk '/^# ── Supervisor mode \(opt-in\)/{p=1} /^# ── Mutual exclusion/{p=0} p' "$ROOT/scripts/cockpit_start.sh" > "$T/helpers.sh"
[ -s "$T/helpers.sh" ] && grep -q "sup_ensure()" "$T/helpers.sh" && ok "the supervisor helpers were found in cockpit_start.sh" || { bad "no supervisor helpers in cockpit_start.sh"; exit 1; }
cat > "$T/run.sh" <<RUN
#!/bin/bash
export HOME="$T/home" COCKPIT_SUP_BIN="\${SUP_OVERRIDE:-$SUP}"
EDITION=v2; COCKPIT_DATA_DIR="$T/home/scripts/cockpit_data"; WEB_ROOT="$T/web"; COCKPIT_ROOT="$T/proj"; _SELF_DIR="$ROOT/scripts"
SOCKET="$T/tmux.sock"; session_exists() { tmux -S "\$SOCKET" has-session -t "\$1" 2>/dev/null; }
. "$T/helpers.sh"
"\$@"
RUN
chmod +x "$T/run.sh"
H() { bash "$T/run.sh" "$@"; }
H use_supervisor && bad "use_supervisor is true without the switch" || ok "switch off: use_supervisor is false (the tmux path stays)"
touch "$T/home/scripts/cockpit_data/use_supervisor"
H use_supervisor && ok "switch on (file use_supervisor): use_supervisor is true" || bad "use_supervisor false with the switch on"
SUP_OVERRIDE=/nonexistent H use_supervisor && bad "use_supervisor true without a binary" || ok "no binary: use_supervisor is false (falls back to tmux)"
H sup_ensure && ok "sup_ensure: configuration written and a supervisor started" || bad "sup_ensure failed: $(tail -3 "$T/home/scripts/cockpit_data/supervisor/supervisor.out" 2>/dev/null)"
S="$T/home/scripts/cockpit_data/supervisor"
for i in $(seq 1 30); do H eval 'sup_ctl status' 2>/dev/null | grep -Eq '^cockpit_claude +running' && break; sleep 0.3; done
H eval 'sup_ctl status' | grep -Eq '^cockpit_(claude|gemini|ollama) +running' && ok "the agent loops are running under it" || bad "no agent running"
H sup_up && ok "sup_up answers" || bad "sup_up does not answer"
H sup_any_running && ok "sup_any_running sees them (used by the already-open guard)" || bad "sup_any_running blind"
PID1=$(H eval 'sup_ctl status' | awk '/^cockpit_claude/ {print $3}')
H sup_start_agent claude; rc=$?
[ $rc -eq 1 ] && ok "sup_start_agent on a running agent leaves it alone (returns 1, like start_session)" || bad "sup_start_agent returned $rc on a running agent"
FORCE_RESTART=1 H sup_start_agent claude; rc=$?
for i in $(seq 1 20); do PID2=$(H eval 'sup_ctl status' | awk '/^cockpit_claude/ {print $3}'); [ -n "$PID2" ] && [ "$PID2" != "$PID1" ] && break; sleep 0.4; done
[ "$rc" = 0 ] && [ "$PID2" != "$PID1" ] && ok "FORCE_RESTART restarts it (new pid)" || bad "FORCE_RESTART: rc=$rc pid $PID1 -> $PID2"
H eval 'sup_ctl stop cockpit_gemini' >/dev/null; sleep 1.5
H sup_start_agent gemini; rc=$?
sleep 1.5
[ $rc -eq 0 ] && H eval 'sup_ctl status' | grep -Eq '^cockpit_gemini +running' && ok "a stopped agent is started again" || bad "gemini was not started again (rc=$rc)"
# a tmux loop left from an earlier start must go when the supervisor takes the agent over (it would answer every prompt twice)
if command -v tmux >/dev/null 2>&1; then
    tmux -S "$T/tmux.sock" new-session -d -s cockpit_ollama -x 80 -y 24 "sleep 300" 2>/dev/null; tmux -S "$T/tmux.sock" new-session -d -s cockpit_tools -x 80 -y 24 "sleep 300" 2>/dev/null
    H sup_ctl_dummy >/dev/null 2>&1; H eval 'sup_ctl stop cockpit_ollama' >/dev/null; sleep 1.5
    H sup_start_agent ollama
    tmux -S "$T/tmux.sock" has-session -t cockpit_ollama 2>/dev/null && bad "a tmux session for the supervised agent was left running" || ok "sup_start_agent ends a leftover tmux session of that agent"
    tmux -S "$T/tmux.sock" has-session -t cockpit_tools 2>/dev/null && ok "... and leaves the Tools session alone" || bad "the Tools session was killed"
    tmux -S "$T/tmux.sock" kill-server 2>/dev/null
fi
CFG1=$(md5sum "$S/cockpit.supervisor.json" | cut -c1-32); H sup_ensure; CFG2=$(md5sum "$S/cockpit.supervisor.json" | cut -c1-32)
[ "$CFG1" = "$CFG2" ] && H sup_up && ok "a second sup_ensure keeps the running supervisor and an identical configuration" || bad "second sup_ensure changed something"
# ---- cockpit_stop.sh (the real file, confined to the scratch tree) ---------------------------------------------------------------------
OUT=$(HOME="$T/home" COCKPIT_DOCROOT="$T/docroot" COCKPIT_SUP_BIN="$SUP" bash "$ROOT/scripts/cockpit_stop.sh" claude 2>&1)
echo "$OUT" | grep -q "Session stopped" && ok "cockpit_stop.sh claude stops that service ($(echo "$OUT" | tr -d '\n' | head -c 60))" || bad "stop claude: $OUT"
for i in $(seq 1 25); do H eval 'sup_ctl status' | grep -Eq '^cockpit_claude +stopped' && break; sleep 0.3; done
H eval 'sup_ctl status' | grep -Eq '^cockpit_claude +stopped' && H eval 'sup_ctl status' | grep -Eq '^cockpit_ollama +running' && ok "... and only that one (ollama still runs)" || bad "stop claude touched the wrong services"
OUT=$(HOME="$T/home" COCKPIT_DOCROOT="$T/docroot" COCKPIT_SUP_BIN="$SUP" bash "$ROOT/scripts/cockpit_stop.sh" all 2>&1)
sleep 1.5
H sup_up && bad "the supervisor still runs after 'stop all'" || ok "cockpit_stop.sh all: the supervisor and its services are gone"
pgrep -f "$T/home/scripts/agent_loop.sh" >/dev/null && bad "an agent loop is still running after 'stop all'" || ok "... no loop process is left"
echo "supervisor_start_stop_test: $fails failure(s)"
exit $((fails>0))
