#!/bin/bash
# loop_native_test.sh — the native loop (aicengine loop) against the real agent_loop.sh (engine on), on the same requests: a stand-in CLI for
# Claude, a stand-in catalog CLI for card 2, a mock Ollama server for card 3. For each scenario both loops serve a fresh copy of the same
# queue; the answer file, the saved chat, the files the %%markers%% created and the log lines must match.
#   bash tests/loop_native_test.sh     ENGINE=<aicengine>      Exit 0 = pass; SKIPPED without an engine that has `loop`, or without jq/php.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$ROOT/scripts/agent_loop.sh"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
for c in jq php; do command -v $c >/dev/null 2>&1 || { echo "loop_native_test: $c is needed - SKIPPED"; exit 0; }; done
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " loop" || { echo "loop_native_test: no engine with 'loop' - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; LP=""; MS=""
trap '[ -n "$LP" ] && kill $LP 2>/dev/null; [ -n "$MS" ] && kill $MS 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# a mock Ollama: /api/tags lists model m1, /api/chat streams two lines (or an error for model "bad")
mkdir -p "$T/mock"
cat > "$T/mock/r.php" <<'PHP'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if ($p === '/api/tags') { echo json_encode(['models' => [['name' => 'm1:latest']]]); return; }
if ($p === '/api/chat') {
    $b = json_decode(file_get_contents('php://input'), true);
    file_put_contents(getenv('MOCK_LOG'), json_encode($b) . "\n", FILE_APPEND);
    $last = end($b['messages'])['content'] ?? '';
    echo json_encode(['message' => ['content' => 'MOCK-OLLAMA says: ']]) . "\n" . json_encode(['message' => ['content' => substr($last, 0, 20)]]) . "\n" . json_encode(['done' => true]) . "\n";
    return;
}
if ($p === '/chat/completions') {
    $b = json_decode(file_get_contents('php://input'), true);
    file_put_contents(getenv('MOCK_LOG'), json_encode(['groq' => $b, 'auth' => $_SERVER['HTTP_AUTHORIZATION'] ?? null]) . "\n", FILE_APPEND);
    echo json_encode(['choices' => [['message' => ['content' => 'GROQ-MOCK ok']]]]);
    return;
}
http_response_code(404);
PHP
PORT=$((20000 + RANDOM % 20000))
MOCK_LOG="$T/mock.log" php -S 127.0.0.1:$PORT -t "$T/mock" "$T/mock/r.php" >/dev/null 2>&1 & MS=$!
for i in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/api/tags" && break; sleep 0.2; done

run_side() {   # $1 side (bash|native)  $2 agent  $3 meta  $4 prompt  $5 setup-extra (eval'd with S=side dir)
    local side="$1" agent="$2" S="$T/$1"
    rm -rf "${S:?}"; mkdir -p "$S"/{web/queue,web/responses,data,home/.npm-global/bin,home/scripts,proj}
    printf '{"projects_root":"%s"}' "$S/proj" > "$S/web/paths.json"
    for f in history_cli.php crud_cli.php crud_executor.sh; do ln -sf "$ROOT/scripts/$f" "$S/home/scripts/$f"; done
    cat > "$S/home/.npm-global/bin/claude" <<'FAKE'
#!/bin/bash
p=""; while [ $# -gt 0 ]; do [ "$1" = "-p" ] && p="$2"; shift; done
case "$p" in
  *MAKEFILE*) jq -n '{result:"Creating.\n%%CREATE:made.txt%%\nhello from the marker\n%%END%%\nDone."}' ;;
  *NOTLOGGED*) jq -n '{result:"Not logged in · Please run /login"}' ;;
  *) jq -n --arg r "FAKE-CLAUDE got: $(printf '%s' "$p" | tail -c 120 | tr '\n' ' ') md5=$(printf '%s' "$p" | md5sum | cut -c1-12)" '{result:$r}' ;;
esac
FAKE
    cat > "$S/home/.npm-global/bin/fakecli" <<'FAKE'
#!/bin/bash
echo "FAKECLI args: $*" | head -c 300
FAKE
    chmod +x "$S/home/.npm-global/bin/claude" "$S/home/.npm-global/bin/fakecli"
    printf '%s' "$4" > "$S/web/queue/${agent}_prompt_tokN.txt"
    printf '%s' "$3" | sed "s|@PROJ@|$S/proj|g; s|@DATA@|$S/data|g" > "$S/web/queue/tokN_meta.json"
    ( eval "$5" )
    local envs=(COCKPIT_WORKER_BASE="http://127.0.0.1:$PORT" HOME="$S/home" COCKPIT_QUEUE_DIR="$S/web/queue" COCKPIT_RESPONSE_DIR="$S/web/responses" COCKPIT_DATA_DIR="$S/data" COCKPIT_ENGINE_BIN="$ENG" MOCK_LOG="$T/mock.log")
    if [ "$side" = bash ]; then ( exec env "${envs[@]}" COCKPIT_ENGINE=1 bash "$LOOP" "$agent" ) >"$S/loop.log" 2>&1 &
    else ( exec env "${envs[@]}" "$ENG" loop "$agent" ) >"$S/loop.log" 2>&1 & fi
    LP=$!
    for i in $(seq 1 80); do [ -f "$S/web/responses/tokN.done" ] && break; sleep 0.25; done
    kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=""
}
norm_chat() { jq -S 'walk(if type=="object" then del(.ts,.time,.timestamp,.duration_s,.created,.updated) else . end)' "$1" 2>/dev/null; }
norm_log() { sed -E 's/\([0-9.]+s\)/(Ns)/; s/pid [0-9]+/pid N/' "$1" | grep -v "Watching:\|history:"; }

# scenario LABEL AGENT META PROMPT [SETUP]
scenario() {
    local label="$1" agent="$2"
    : > "$T/mock.log"; run_side bash "$2" "$3" "$4" "$5"; cp "$T/mock.log" "$T/mock.bash"; : > "$T/mock.log"; run_side native "$2" "$3" "$4" "$5"; cp "$T/mock.log" "$T/mock.native"
    local good=1 why=""
    [ -f "$T/bash/web/responses/tokN.done" ] || { good=0; why="$why bash: never answered;"; }
    [ -f "$T/native/web/responses/tokN.done" ] || { good=0; why="$why native: never answered;"; }
    cmp -s "$T/bash/web/responses/tokN.out" "$T/native/web/responses/tokN.out" || { good=0; why="$why answer files differ;"; }
    local cb cn; cb=$(ls "$T"/bash/proj/*/chat_*.json 2>/dev/null | head -1); cn=$(ls "$T"/native/proj/*/chat_*.json 2>/dev/null | head -1)
    if [ -n "$cb" ] || [ -n "$cn" ]; then
        [ "$(norm_chat "$cb")" = "$(norm_chat "$cn")" ] && [ -n "$(norm_chat "$cb")" ] || { good=0; why="$why saved chats differ;"; }
    else good=0; why="$why no chat file;"; fi
    [ "$(cd "$T/bash/proj" && find . -type f ! -name 'chat_*' ! -name '.*' | sort | xargs -r md5sum)" = "$(cd "$T/native/proj" && find . -type f ! -name 'chat_*' ! -name '.*' | sort | xargs -r md5sum)" ] || { good=0; why="$why project files differ;"; }
    [ "$(norm_log "$T/bash/loop.log")" = "$(norm_log "$T/native/loop.log")" ] || { good=0; why="$why log lines differ;"; }
    cmp -s "$T/mock.bash" "$T/mock.native" || { good=0; why="$why requests to the mock differ;"; }
    [ -z "${EXPECT:-}" ] || grep -qF -- "$EXPECT" "$T/native/web/responses/tokN.out" || { good=0; why="$why native answer lacks: $EXPECT;"; }
    [ -z "${EXPECT_FILE:-}" ] || [ -f "$T/native/proj/p1/$EXPECT_FILE" ] || { good=0; why="$why native did not create $EXPECT_FILE;"; }
    if [ $good = 1 ]; then ok "$label"; else
        bad "$label:$why"; tail -4 "$T/bash/loop.log" "$T/native/loop.log" 2>/dev/null
        diff "$T/bash/web/responses/tokN.out" "$T/native/web/responses/tokN.out" 2>&1 | head -6
        diff <(norm_log "$T/bash/loop.log") <(norm_log "$T/native/loop.log") | head -6
        [ -n "$cb" ] && [ -n "$cn" ] && diff <(norm_chat "$cb") <(norm_chat "$cn") | head -8
        diff "$T/mock.bash" "$T/mock.native" | head -4
    fi
}
M='{"project":"p1","chat":"c1","style":"chat","mode":"single","projects_root":"@PROJ@","cockpit_data":"@DATA@/users/dario","claude_model":"claude-opus-4-8","gemini_model":"auto"}'
mkdir -p "$T/seed"
SETUP_USER='mkdir -p "$S/data/users/dario"'

EXPECT="FAKE-CLAUDE got" scenario "claude: a plain question" claude "$M" 'what is two plus two' "$SETUP_USER"
EXPECT_FILE="made.txt" EXPECT="[CRUD" scenario "claude: a marker creates a file" claude "$M" 'MAKEFILE please' "$SETUP_USER"
EXPECT="not signed in" scenario "claude: not signed in gets the hint" claude "$M" 'NOTLOGGED test' "$SETUP_USER"
EXPECT="Think hard." scenario "claude: effort text and clean args" claude "${M%\}},\"claude_effort\":\"$(printf 'Think hard. ' | base64 -w0)\",\"claude_args\":\"$(printf -- '--effort high' | base64 -w0)\"}" 'do it' "$SETUP_USER"
scenario "claude: an old alias model" claude "${M%\}},\"claude_model\":\"opus\"}" 'hello' "$SETUP_USER"
scenario "claude: no meta file" claude "" 'no meta here' ''
EXPECT="FAKECLI args" scenario "claude: card 1 is a catalog CLI" claude "$M" 'to the generic cli' 'mkdir -p "$S/data/users/dario"; printf %s "{\"primary\":\"fakecli\"}" > "$S/data/users/dario/supplier_slots.json"; printf %s "{\"fakecli\":{\"binary\":\"fakecli\",\"cli_flag\":\"-p\",\"parse\":\"text\"}}" > "$S/data/users/dario/cli_catalog.json"'
EXPECT="FAKECLI args" scenario "gemini: card 2 is a catalog CLI" gemini "$M" 'to card two' 'mkdir -p "$S/data/users/dario"; printf %s "{\"fallback\":\"fakecli\"}" > "$S/data/users/dario/supplier_slots.json"; printf %s "{\"fakecli\":{\"binary\":\"fakecli\",\"cli_flag\":\"-p\",\"parse\":\"text\"}}" > "$S/data/users/dario/cli_catalog.json"'
groq_setup() { mkdir -p "$S/data/users/dario"; printf %s '{"fallback":"groq_build"}' > "$S/data/users/dario/supplier_slots.json"; php -r 'require $argv[1]; file_put_contents($argv[2]."/workers_keys.enc", encrypt_blob($argv[3]));' "$ROOT/cockpit_app/workers.php" "$S/data/users/dario" '{"groq":"gsk_E2E"}' 2>/dev/null; }
EXPECT="GROQ-MOCK ok" scenario "gemini: card 2 is the free-REST groq relay (keys decrypted in the engine)" gemini "${M%\}},\"web_root\":\"$ROOT/cockpit_app\"}" 'to groq' groq_setup
EXPECT="No API key" scenario "gemini: no API key" gemini "$M" 'hello gemini' "$SETUP_USER"
EXPECT="MOCK-OLLAMA says" scenario "ollama: a streamed answer" ollama "$M" 'tell me something' 'mkdir -p "$S/data/users/dario"; printf %s "{\"local\":{\"provider\":\"ollama\",\"base_url\":\"http://127.0.0.1:'$PORT'\"}}" > "$S/data/users/dario/supplier_slots.json"; printf m1 > "$S/web/queue/tokN_model.txt"'
EXPECT="MOCK-OLLAMA says" scenario "ollama: a long prompt (history gate says no)" ollama "$M" 'Write a detailed explanation of how the quick sort algorithm works, covering the pivot choice and complexity analysis please.' 'mkdir -p "$S/data/users/dario"; printf %s "{\"local\":{\"provider\":\"ollama\",\"base_url\":\"http://127.0.0.1:'$PORT'\"}}" > "$S/data/users/dario/supplier_slots.json"; printf m1 > "$S/web/queue/tokN_model.txt"'
SEED='mkdir -p "$S/data/users/dario" "$S/proj/p1"; printf %s "{\"schema_version\":1,\"project\":\"p1\",\"chat\":\"c1\",\"created\":\"2026-01-01T00:00:00Z\",\"updated\":\"2026-01-01T00:00:00Z\",\"exchanges\":[{\"id\":1,\"timestamp\":\"2026-01-01T00:00:00Z\",\"role\":\"user\",\"text\":\"my favourite colour is teal\"},{\"id\":2,\"timestamp\":\"2026-01-01T00:00:01Z\",\"role\":\"agent\",\"agent\":\"claude\",\"model\":\"x\",\"text\":\"noted: teal\"}]}" > "$S/proj/p1/chat_c1.json"'
EXPECT="FAKE-CLAUDE got" scenario "claude: a follow-up with earlier turns in the chat" claude "$M" 'and what was it again?' "$SEED"
EXPECT="MOCK-OLLAMA says" scenario "ollama: a follow-up with earlier turns in the chat" ollama "$M" 'and what was it again?' "$SEED; "'printf %s "{\"local\":{\"provider\":\"ollama\",\"base_url\":\"http://127.0.0.1:'$PORT'\"}}" > "$S/data/users/dario/supplier_slots.json"; printf m1 > "$S/web/queue/tokN_model.txt"'
EXPECT="FAKE-CLAUDE got" scenario "claude: a follow-up with NO PHP history helper (the native history alone vs the Bash)" claude "$M" 'and what was it again?' "$SEED; rm -f \"\$S/home/scripts/history_cli.php\""
echo "loop_native_test: $n passed, $fails failed"; [ "$fails" = 0 ]
