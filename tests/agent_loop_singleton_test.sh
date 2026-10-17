#!/bin/bash
# agent_loop_singleton_test.sh — two agent loops must never serve the same queue (they would answer every prompt twice).
# Real scripts/agent_loop.sh in a scratch tree, HOME pointing at it so the real CLI can never be reached. No tmux needed.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d) || exit 1
cleanup() { pkill -f "$T/" 2>/dev/null; sleep 0.3; rm -rf "$T"; }
trap cleanup EXIT
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
mkdir -p "$T"/{q,r,d,home/scripts}
cp "${LOOP_SRC:-$ROOT/scripts/agent_loop.sh}" "$T/home/scripts/agent_loop.sh"
LOOP="$T/home/scripts/agent_loop.sh"
run() { HOME="$T/home" COCKPIT_QUEUE_DIR="$T/q" COCKPIT_RESPONSE_DIR="$T/r" COCKPIT_DATA_DIR="$T/d" bash "$LOOP" "$1"; }
run claude > "$T/l1.out" 2>&1 &
L1=$!
for i in $(seq 1 30); do [ -s "$T/q/.loop_claude.pid" ] && break; sleep 0.2; done
LP1=$(cat "$T/q/.loop_claude.pid" 2>/dev/null)      # the loop itself (the background job is only the function wrapper around it)
ps -p "$LP1" -o args= 2>/dev/null | grep -q -e "agent_loop.sh claude" -e "aicengine loop claude" && ok "the first loop records its own pid" || bad "pid file holds '$LP1', which is not an agent_loop"
run claude > "$T/l2.out" 2>&1 &
L2=$!
for i in $(seq 1 30); do kill -0 $L2 2>/dev/null || break; sleep 0.2; done
kill -0 $L2 2>/dev/null && bad "a second loop for the same agent and queue kept running" || ok "a second loop for the same agent and queue exits at once"
grep -q "already serves" "$T/l2.out" && ok "... and says why" || bad "no explanation: $(head -2 "$T/l2.out")"
kill -0 $LP1 2>/dev/null && ok "the first loop is unaffected" || bad "the first loop died"
run gemini > "$T/l3.out" 2>&1 &
L3=$!; sleep 2
kill -0 $L3 2>/dev/null && ok "a loop for ANOTHER agent on the same queue directory is fine" || bad "the gemini loop was refused"
kill $L3 2>/dev/null
# the first loop dies: the next one may start
kill $LP1; sleep 0.7
run claude > "$T/l4.out" 2>&1 &
L4=$!; sleep 2
kill -0 $L4 2>/dev/null && ok "after the first loop is gone a new loop starts" || bad "no new loop after the first one died: $(head -2 "$T/l4.out")"
kill $L4 2>/dev/null; wait $L4 2>/dev/null
# a stale file naming a dead pid, and one naming an unrelated live process, must not block
echo 99999999 > "$T/q/.loop_claude.pid"
run claude > "$T/l5.out" 2>&1 &
L5=$!; sleep 2
kill -0 $L5 2>/dev/null && ok "a stale pid file (dead process) does not block" || bad "blocked by a stale pid file"
kill $L5 2>/dev/null; wait $L5 2>/dev/null
sleep 300 & SL=$!
echo $SL > "$T/q/.loop_claude.pid"
run claude > "$T/l6.out" 2>&1 &
L6=$!; sleep 2
kill -0 $L6 2>/dev/null && ok "a pid file naming an unrelated live process (pid reuse) does not block" || bad "blocked by an unrelated pid"
kill $L6 $SL 2>/dev/null
echo "agent_loop_singleton_test: $fails failure(s)"
exit $((fails>0))
