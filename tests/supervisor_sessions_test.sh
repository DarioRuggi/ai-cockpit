#!/bin/bash
# supervisor_sessions_test.sh — the agent loops under aicsupervisor, end to end, in a scratch tree (nothing real is touched).
#
# Real pieces: aicsupervisor, scripts/cockpit_sup_config.php (the generated configuration), scripts/agent_loop.sh (the real loop),
# cockpit_app/session_backend.php + status.php (the web side). Fake piece: the claude CLI (HOME points at the scratch tree and
# agent_loop.sh puts $HOME/.npm-global/bin first on its PATH, so the real CLI is never called).
#
#   bash tests/supervisor_sessions_test.sh              needs aicsupervisor (AICSUP_BIN, else ~/scripts/aicsupervisor, else the runtime repo's bin/)
# Exit 0 = pass; prints SKIPPED (exit 0) when the binary or php/curl is missing.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUP="${AICSUP_BIN:-}"
for c in "$SUP" "$HOME/scripts/aicsupervisor" $HOME/aicockpit-runtime/aicsupervisor/bin/aicsupervisor; do [ -n "$c" ] && [ -x "$c" ] && { SUP="$c"; break; }; done
[ -x "$SUP" ] || { echo "supervisor_sessions_test: aicsupervisor not found - SKIPPED"; exit 0; }
for t in php curl; do command -v $t >/dev/null 2>&1 || { echo "supervisor_sessions_test: $t not found - SKIPPED"; exit 0; }; done
T=$(mktemp -d) || exit 1
PORT=$((18700 + RANDOM % 200))
cleanup() { [ -f "$T/server.pid" ] && kill "$(cat "$T/server.pid")" 2>/dev/null; "$SUP" ctl --socket "$T/data/supervisor/sup.sock" --token-file "$T/data/supervisor/token" shutdown >/dev/null 2>&1; sleep 0.5; pkill -f "$T/" 2>/dev/null; rm -rf "$T"; }
[ -n "${KEEP:-}" ] || trap cleanup EXIT
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
mkdir -p "$T"/{home/scripts,home/.npm-global/bin,web/queue,web/responses,data,proj,app}
cp "${LOOP_SRC:-$ROOT/scripts/agent_loop.sh}" "$T/home/scripts/agent_loop.sh"; cp "$ROOT/scripts/cockpit_sup_config.php" "$T/home/scripts/"
cat > "$T/home/.npm-global/bin/claude" <<FAKE
#!/bin/bash
n=\$(wc -l < "$T/fake_claude.log" 2>/dev/null || echo 0)
echo "\$(date +%s.%N) \$\$ \$(echo "\$*" | head -c 40 | tr "\\n" " ")" >> "$T/fake_claude.log"
# the first call is slow (so Stop has something to interrupt); later calls answer at once
[ "\$n" -lt 1 ] && for i in \$(seq 1 25); do echo "partial line \$i"; sleep 1; done
echo "fake answer"
FAKE
chmod +x "$T/home/.npm-global/bin/claude"
rsync -a --exclude=.user.ini "$ROOT/cockpit_app/" "$T/app/" 2>/dev/null || cp -r "$ROOT/cockpit_app/." "$T/app/"
echo "{\"home\":\"$T/home\",\"cockpit_data\":\"$T/data\",\"projects_root\":\"$T/proj\"}" > "$T/app/paths.json"

# a stand-in scheduler.php: the tick only proves it ran
echo "<?php file_put_contents('$T/heartbeat', date('c') . \"\\n\", FILE_APPEND);" > "$T/web/scheduler.php"
# ---- the generated configuration, then the supervisor on it ---------------------------------------------------------------------
GRP="$(id -gn)"
HOME="$T/home" php "$T/home/scripts/cockpit_sup_config.php" --edition v2 --web-root "$T/web" --data-dir "$T/data" --projects-root "$T/proj" \
    --loop "$T/home/scripts/agent_loop.sh" --group "$GRP" --out "$T/data/supervisor/cockpit.supervisor.json" || bad "the configuration was not written"
"$SUP" check --config "$T/data/supervisor/cockpit.supervisor.json" >/dev/null 2>&1 && ok "the generated configuration validates" || bad "the generated configuration is invalid"
touch "$T/data/use_supervisor"
( HOME="$T/home" setsid "$SUP" run --config "$T/data/supervisor/cockpit.supervisor.json" >"$T/sup.out" 2>&1 < /dev/null & )
ctl() { "$SUP" ctl --socket "$T/data/supervisor/sup.sock" --token-file "$T/data/supervisor/token" "$@"; }
for i in $(seq 1 40); do ctl ping >/dev/null 2>&1 && break; sleep 0.25; done
for i in $(seq 1 40); do ctl status 2>/dev/null | grep -Eq '^cockpit_claude +running' && break; sleep 0.25; done
ctl status 2>/dev/null | grep -Eq '^cockpit_claude +running' && ok "cockpit_claude is running under the supervisor" || { bad "cockpit_claude did not start"; cat "$T/sup.out" | tail -5; }
ctl status 2>/dev/null | grep -Eq '^cockpit_gemini +running' && ctl status 2>/dev/null | grep -Eq '^cockpit_ollama +running' && ok "all three agent loops run" || bad "not all three loops run"
for i in $(seq 1 30); do [ -s "$T/heartbeat" ] && break; sleep 0.3; done
[ -s "$T/heartbeat" ] && ctl status | grep -E '^scheduler ' | grep -q ok && ok "the scheduler job ran at start (the cron tick, now a supervised job)" || bad "the scheduler job did not run: $(ctl status | grep -E '^scheduler')"
[ "$(stat -c %a "$T/data/supervisor/sup.sock")" = "660" ] && [ "$(stat -c %a "$T/data/supervisor/token")" = "640" ] && ok "socket 0660, token 0640 (the web account's group can reach them)" || bad "socket/token modes"

# ---- the web side: session_backend.php through PHP, and status.php through a real web server --------------------------------------
PHPT="$T/t.php"
cat > "$PHPT" <<EOF
<?php
\$PATHS = ['cockpit_data_root' => '$T/data', 'tmux_socket' => '$T/web/tmux.sock'];
require '$ROOT/cockpit_app/session_backend.php';
\$a = \$argv[1] ?? '';
if (\$a === 'alive')     { \$r = ck_agent_alive('claude'); echo (\$r['ok'] ? 'ALIVE' : 'DEAD') . ' via ' . \$r['via'] . "\n"; }
if (\$a === 'interrupt') { echo ck_agent_interrupt('claude') . "\n"; }
if (\$a === 'log')       { echo (string)ck_agent_logfile('claude') . "\n"; }
EOF
[ "$(php "$PHPT" alive)" = "ALIVE via supervisor" ] && ok "session_backend: the agent is alive via the supervisor" || bad "session_backend alive: $(php "$PHPT" alive)"
[ "$(php "$PHPT" log)" = "$T/data/supervisor/logs/cockpit_claude.log" ] && ok "session_backend: the log of a supervised agent is found" || bad "session_backend log: $(php "$PHPT" log)"
( cd "$T/app" && setsid php -S 127.0.0.1:$PORT >"$T/server.log" 2>&1 < /dev/null & echo $! > "$T/server.pid" )
for i in $(seq 1 20); do curl -s -o /dev/null "http://127.0.0.1:$PORT/index.html" && break; sleep 0.25; done
ST=$(curl -s "http://127.0.0.1:$PORT/status.php")
echo "$ST" | php -r '$d=json_decode(stream_get_contents(STDIN),true); exit((($d["claude"]["ok"]??false)===true && strpos($d["claude"]["version"]??"","session running")!==false && ($d["gemini"]["ok"]??false)===true)?0:1);' && ok "status.php reports the supervised agents as running (through a real web server)" || { bad "status.php: $(echo "$ST" | head -c 300)"; }

# the native window asks launch_cli.php how an agent is hosted before it opens a terminal on it (a supervised agent has no tmux pane)
SK=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"agent":"claude","mode":"session_kind"}' "http://127.0.0.1:$PORT/launch_cli.php")
echo "$SK" | grep -q '"supervised":true' && ok "launch_cli session_kind: a supervised agent is reported as supervised (the window then shows the log, not tmux)" || bad "session_kind: $SK"
rm -f "$T/data/use_supervisor"
SK=$(curl -s -X POST -H 'Content-Type: application/json' -d '{"agent":"claude","mode":"session_kind"}' "http://127.0.0.1:$PORT/launch_cli.php")
echo "$SK" | grep -q '"supervised":false' && ok "... and with the switch off it says tmux" || bad "session_kind switch off: $SK"
touch "$T/data/use_supervisor"

# ---- a request, the Stop button, the next request ----------------------------------------------------------------------------------
meta() { printf '{"project":"p","chat":"c","model":"","agent":"claude"}' > "$T/web/queue/$1_meta.json"; }
LOOP_PID_BEFORE=$(ctl status | awk '/^cockpit_claude/ {print $3}')
printf 'first prompt' > "$T/web/queue/claude_prompt_tokA.txt"; meta tokA
for i in $(seq 1 40); do [ -s "$T/fake_claude.log" ] && break; sleep 0.5; done
[ -s "$T/fake_claude.log" ] && ok "a request reached the (fake) CLI through the supervised loop" || bad "the request never reached the CLI"
CLI_PID=$(tail -1 "$T/fake_claude.log" | awk '{print $2}')
sleep 1
R=$(php "$PHPT" interrupt)
[ "$R" = "supervisor" ] && ok "Stop: ck_agent_interrupt went through the supervisor (not tmux)" || bad "Stop answered '$R'"
for i in $(seq 1 20); do kill -0 "$CLI_PID" 2>/dev/null || break; sleep 0.25; done
kill -0 "$CLI_PID" 2>/dev/null && bad "the running CLI is still alive after Stop" || ok "Stop ended the running CLI"
sleep 2
LOOP_PID_AFTER=$(ctl status | awk '/^cockpit_claude/ {print $3}')
[ "$LOOP_PID_BEFORE" = "$LOOP_PID_AFTER" ] && ctl status | grep -Eq '^cockpit_claude +running' && ok "the loop itself survived (same pid, still running, no restart)" || bad "the loop did not survive Stop: pid $LOOP_PID_BEFORE -> $LOOP_PID_AFTER"
printf 'second prompt' > "$T/web/queue/claude_prompt_tokB.txt"; meta tokB
for i in $(seq 1 40); do [ -f "$T/web/responses/tokB.done" ] && break; sleep 0.5; done
[ -f "$T/web/responses/tokB.done" ] && ok "the next request was served after Stop" || bad "the next request was never served"

# ---- the loop dies by itself: the supervisor brings it back -------------------------------------------------------------------------
kill -9 "$LOOP_PID_AFTER" 2>/dev/null
for i in $(seq 1 40); do NEW=$(ctl status | awk '/^cockpit_claude/ {print $3}'); [ -n "$NEW" ] && [ "$NEW" != "$LOOP_PID_AFTER" ] && ctl status | grep -Eq '^cockpit_claude +running' && break; sleep 0.5; done
[ -n "$NEW" ] && [ "$NEW" != "$LOOP_PID_AFTER" ] && ok "a killed loop is restarted by the supervisor (new pid $NEW)" || bad "the killed loop was not restarted"
printf 'third prompt' > "$T/web/queue/claude_prompt_tokC.txt"; meta tokC
for i in $(seq 1 60); do [ -f "$T/web/responses/tokC.done" ] && break; sleep 0.5; done
[ -f "$T/web/responses/tokC.done" ] && ok "the restarted loop serves requests" || bad "the restarted loop did not serve a request"

# ---- the switch off / supervisor gone: tmux answers, as before ------------------------------------------------------------------------
rm -f "$T/data/use_supervisor"
[ "$(php "$PHPT" alive)" = "DEAD via tmux" ] && ok "switch off: the answer comes from tmux again (no tmux session here = dead)" || bad "switch off: $(php "$PHPT" alive)"
touch "$T/data/use_supervisor"
ctl shutdown >/dev/null 2>&1; sleep 2
[ "$(php "$PHPT" alive)" = "DEAD via tmux" ] && ok "supervisor gone: falls back to tmux without an error" || bad "supervisor gone: $(php "$PHPT" alive)"
[ "$(php "$PHPT" interrupt)" = "none" ] && ok "supervisor gone and no tmux session: Stop reports 'none' (no crash)" || bad "interrupt without any backend: $(php "$PHPT" interrupt)"

echo "supervisor_sessions_test: $fails failure(s)"
exit $((fails>0))
