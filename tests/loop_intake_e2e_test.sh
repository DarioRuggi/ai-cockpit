#!/bin/bash
# loop_intake_e2e_test.sh — the real agent_loop.sh, with a FAKE claude CLI, answers one request twice: once on the Bash path and once with
# the native engine's intake (COCKPIT_ENGINE=1). The fake CLI echoes the prompt it received, so the two runs must show the same prompt reaching
# the agent, the same answer in the response file, and the same exchange saved into the chat file. (HOME is a scratch tree, so the real CLI is never called.)
#   bash tests/loop_intake_e2e_test.sh      ENGINE=<aicengine>      Exit 0 = pass; SKIPPED without an engine that has `intake`.
LOOP="$(cd "$(dirname "$0")/.." && pwd)/scripts/agent_loop.sh"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q intake || { echo "loop_intake_e2e_test: no engine with 'intake' - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; LP=""
trap '[ -n "$LP" ] && kill $LP 2>/dev/null; [ -n "$KEEP" ] || rm -rf "$T"; [ -n "$KEEP" ] && echo "kept $T"' EXIT
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
EFF=$(printf 'Think hard. ' | base64 -w0)
run_side() {   # $1 = side name, $2 = engine flag (1/0)
    local S="$T/$1"; mkdir -p "$S"/{web/queue,web/responses,data,home/.npm-global/bin,proj}
    printf '{"projects_root":"%s"}' "$S/proj" > "$S/web/paths.json"
    cat > "$S/home/.npm-global/bin/claude" <<'FAKE'
#!/bin/bash
p=""; while [ $# -gt 0 ]; do [ "$1" = "-p" ] && p="$2"; shift; done
jq -n --arg r "FAKE-ANSWER got: $(printf "%s" "$p" | tail -c 300)" '{result:$r}'
FAKE
    chmod +x "$S/home/.npm-global/bin/claude"
    mkdir -p "$S/home/scripts"; ln -sf "$(dirname "$LOOP")/crud_executor.sh" "$S/home/scripts/crud_executor.sh"; ln -sf "$(dirname "$LOOP")/crud_cli.php" "$S/home/scripts/crud_cli.php"
    printf 'what is two plus two\n' > "$S/web/queue/claude_prompt_tokE.txt"
    printf '{"project":"pe","chat":"ce","style":"chat","mode":"single","projects_root":"%s","cockpit_data":"%s","claude_model":"claude-opus-4-8","claude_effort":"%s"}' "$S/proj" "$S/data" "$EFF" > "$S/web/queue/tokE_meta.json"
    ( HOME="$S/home" COCKPIT_ENGINE="$2" COCKPIT_ENGINE_BIN="$ENG" COCKPIT_QUEUE_DIR="$S/web/queue" COCKPIT_RESPONSE_DIR="$S/web/responses" COCKPIT_DATA_DIR="$S/data" \
      exec bash "$LOOP" claude ) >"$S/loop.log" 2>&1 &
    LP=$!
    for i in $(seq 1 60); do [ -f "$S/web/responses/tokE.done" ] && break; sleep 0.5; done
    kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=""
}
run_side bash 0; run_side engine 1
for s in bash engine; do
    [ -f "$T/$s/web/responses/tokE.done" ] && ok "$s path: the request was answered" || { bad "$s path: never answered"; tail -5 "$T/$s/loop.log"; }
done
grep -q "intake" "$T/engine/loop.log" && bad "engine path logged an intake problem"
cmp -s "$T/bash/web/responses/tokE.out" "$T/engine/web/responses/tokE.out" && ok "same answer file on both paths" || { bad "the answer files differ"; diff "$T/bash/web/responses/tokE.out" "$T/engine/web/responses/tokE.out" | head -5; }
for s in bash engine; do grep -q "FAKE-ANSWER" "$T/$s/web/responses/tokE.out" && ok "$s: the fake CLI's answer is in the response" || bad "$s: no CLI answer"; done
# the saved exchange, without the timestamps and the duration
norm() { jq -S 'walk(if type=="object" then del(.ts, .time, .timestamp, .duration, .id, .date, .created, .updated) else . end)' "$1" 2>/dev/null; }
cb="$T/bash/proj/pe/chat_ce.json"; ce="$T/engine/proj/pe/chat_ce.json"
[ -s "$cb" ] && [ -s "$ce" ] && ok "both paths saved the chat file in the project folder" || bad "the chat file is missing (bash: $(ls "$T/bash/proj/pe" 2>&1 | tr '\n' ' ') engine: $(ls "$T/engine/proj/pe" 2>&1 | tr '\n' ' '))"
[ "$(norm "$cb")" = "$(norm "$ce")" ] && [ -n "$(norm "$cb")" ] && ok "the saved exchange is the same on both paths" || { bad "the saved exchanges differ"; diff <(norm "$cb") <(norm "$ce") | head -8; }
grep -q "Think hard. what is two plus two" "$cb" && ok "the effort text was put in front of the prompt that was saved" || bad "the effort text is not in the saved prompt"
[ ! -e "$T/engine/web/queue/claude_prompt_tokE.txt" ] && [ ! -e "$T/engine/web/queue/tokE_meta.json" ] && ok "the engine path removed the prompt and meta files" || bad "queue files left behind"
echo "loop_intake_e2e_test: $fails failure(s)"; exit $((fails>0))
