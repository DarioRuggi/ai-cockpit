#!/bin/bash
# stop_survival_test.sh — the Stop button must not kill the agent loop.
#
# bridge.php's cleanup (the Stop button) sends Ctrl-C to the agent's tmux pane. Run agent_loop.sh in a PRIVATE tmux server with a FAKE
# claude CLI (HOME points at a scratch tree, and agent_loop.sh puts $HOME/.npm-global/bin first on its PATH, so the real CLI is never
# called), start a slow request, press Ctrl-C mid-request, queue a second request, and require that the loop is still alive and serves it.
#
#   bash tests/stop_survival_test.sh                 # tests scripts/agent_loop.sh
#   bash tests/stop_survival_test.sh path/to/loop.sh # any other copy (mutation checks)
# Needs tmux. Exit 0 = pass.
LOOP="${1:-$(cd "$(dirname "$0")/.." && pwd)/scripts/agent_loop.sh}"
command -v tmux >/dev/null 2>&1 || { echo "stop_survival_test: tmux not found - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1
SOCK="$T/tmux.sock"
cleanup() { tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
mkdir -p "$T"/{q,r,d,home/.npm-global/bin}
cat > "$T/home/.npm-global/bin/claude" <<FAKE
#!/bin/bash
echo "\$(date +%s.%N) \$*" >> "$T/fake_claude.log"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do echo "partial line \$i"; sleep 1; done
FAKE
chmod +x "$T/home/.npm-global/bin/claude"
meta() { printf '{"project":"p","chat":"c","model":"","agent":"claude"}' > "$T/q/$1_meta.json"; }
printf 'first prompt'  > "$T/q/claude_prompt_tokA.txt"; meta tokA
tmux -S "$SOCK" new-session -d -s t -x 150 -y 40 bash || { echo "stop_survival_test: cannot start tmux"; exit 1; }
sleep 0.3
tmux -S "$SOCK" send-keys -t t "HOME='$T/home' COCKPIT_QUEUE_DIR='$T/q' COCKPIT_RESPONSE_DIR='$T/r' COCKPIT_DATA_DIR='$T/d' '$LOOP' claude" Enter
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# 1. the first request reaches the (fake) CLI and is in flight
for i in $(seq 1 30); do [ -s "$T/fake_claude.log" ] && break; sleep 0.5; done
[ -s "$T/fake_claude.log" ] && ok "request in flight (fake CLI running)" || bad "the fake CLI was never started"
sleep 2
# 2. Stop pressed
tmux -S "$SOCK" send-keys -t t C-c
sleep 3
# 3. a second request must still be served by the same loop
printf 'second prompt' > "$T/q/claude_prompt_tokB.txt"; meta tokB
served=no
for i in $(seq 1 30); do [ -f "$T/q/claude_prompt_tokB.txt" ] || { served=yes; break; }; sleep 0.5; done
[ "$served" = yes ] && ok "the loop picked up the next request after Ctrl-C" || bad "the loop did NOT pick up the next request after Ctrl-C (it died with the signal)"
[ -f "$T/r/tokB.done" ] || sleep "${STOP_EXTRA_WAIT:-3}"   # the native loop waits for the whole (invalid-JSON) fake run; the shell pipeline dies of SIGPIPE early
[ -f "$T/r/tokB.done" ] && ok "the second request was answered (its done file exists)" || bad "the second request was never answered"
[ -f "$T/r/tokA.done" ] && ok "the interrupted request was closed (done file written)" || bad "the interrupted request was left open"
echo "stop_survival_test: $fails failure(s)"
exit $((fails>0))
