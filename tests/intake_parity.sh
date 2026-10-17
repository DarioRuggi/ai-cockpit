#!/bin/bash
# intake_parity.sh — the first half of a turn in agent_loop.sh (token, meta file, model file, paths, the prompt with its effort text, the
# extra CLI arguments), the Bash path vs `aicengine intake`: every variable the loop goes on to use, the prompt, the files left in the
# queue folder and the working directory, on a table of requests.
#
# The Bash is cut out of the real scripts/agent_loop.sh (the inline block, between its markers); the engine side is the real intake_engine
# function. Both run under LC_ALL=C. The loop's own helpers that need the web server (internal_setup, resolve_supplier/local) are stubs that record
# that they were called.   bash tests/intake_parity.sh     ENGINE=<aicengine>.   Exit 0 = pass; SKIPPED without an `intake`-capable engine.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$ROOT/scripts/agent_loop.sh"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q intake || { echo "intake_parity: $ENG has no 'intake' command - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }

{
  awk '/^engine_bin\(\) \{/{p=1} p{print} p&&/^}/{c++; if(c==2){p=0}}' "$LOOP"
  awk '/^intake_engine\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$LOOP"
  awk '/^json_get\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$LOOP"
} > "$T/fn.sh"
awk '/^        TOKEN=\$\(basename/{p=1} p{print} p&&/^        cd "\$PROJECT_DIR"/{p=0}' "$LOOP" > "$T/region1.sh"
awk '/^        USER_PROMPT=\$\(cat "\$PROMPT_FILE"\)/{p=1} p{print} p&&/^        fi   # INTAKE_DONE/{p=0}' "$LOOP" | sed '$d' > "$T/region2.sh"
for f in fn region1 region2; do [ -s "$T/$f.sh" ] || { bad "could not cut $f out of the loop"; exit 1; }; done
grep -q "^intake_engine()" "$T/fn.sh" && grep -q "^json_get()" "$T/fn.sh" || { bad "could not extract the functions"; exit 1; }

cat > "$T/run.sh" <<'RUN'
#!/bin/bash
# usage: run.sh DIR bash|engine   (the case is already laid out in DIR/q)
D="$1"; AGENT="${AGENT:-claude}"; AGENT_UC=$(printf '%s' "$AGENT" | tr a-z A-Z)
QUEUE_DIR="$D/q"; RESPONSE_DIR="$D/r"; COCKPIT_ROOT="$D/projroot"; mkdir -p "$COCKPIT_ROOT" "$RESPONSE_DIR"
. "$D/fn.sh"
CALLS=""
internal_setup() { CALLS="$CALLS internal_setup(REQ_DATA=$REQ_DATA)"; }
resolve_supplier() { CALLS="$CALLS resolve_supplier($1)"; }
resolve_local() { CALLS="$CALLS resolve_local($1)"; }
MA_STYLE=LEAK; MA_MODE=LEAK; REQ_IMAGES=LEAK; REQ_DATA=LEAK; MODEL=LEAK
cd "$D"
PROMPT_FILE=$(ls "$QUEUE_DIR/${AGENT}_prompt_"*.txt 2>/dev/null | head -1)
INTAKE_DONE=0
if [ "$2" = engine ]; then
    export COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$ENGBIN"
    intake_engine "$PROMPT_FILE" && INTAKE_DONE=1
    [ "$INTAKE_DONE" = 1 ] || { echo "ENGINE REFUSED" > "$D/$2.vars"; ls "$QUEUE_DIR" >> "$D/$2.vars"; exit 0; }
else
    . "$D/region1.sh"
    . "$D/region2.sh"
fi
{
  for v in TOKEN OUT_FILE DONE_FILE META_FILE PROJECT CHAT_NAME CLAUDE_MODEL GEMINI_MODEL CLAUDE_EFFORT GEMINI_EFFORT CLAUDE_ARGS_B64 GEMINI_ARGS_B64 \
           REQ_ROOT REQ_DATA REQ_WEB RAG_B64 MA_STYLE MA_MODE REQ_IMAGES MODEL PROJECT_DIR CHAT_FILE EXTRA_CLI_ARGS CALLS; do
      printf '%s=[%s]\n' "$v" "${!v}"
  done
  printf 'PWD=[%s]\n' "$PWD"
  ls -A "$QUEUE_DIR"
} > "$D/$2.vars"
printf '%s' "$USER_PROMPT" > "$D/$2.prompt"
RUN

fresh() { rm -rf "$T/q" "$T/r" "$T/projroot"; mkdir -p "$T/q"; }

# a case:  check LABEL AGENT 'META-FILE-BODY or -' 'PROMPT-printf-format' ['MODEL-FILE-format']
check() {
    local label="$1" agent="$2" meta="$3" prompt="$4" model="${5-}" side
    for side in bash engine; do
        fresh
        printf -- "$prompt" > "$T/q/${agent}_prompt_tok1.txt"
        [ "$meta" != "-" ] && printf '%s' "$meta" | sed "s|@ROOT@|$T/projroot|g; s|@DATA@|$T/data|g" > "$T/q/tok1_meta.json"
        [ -n "$model" ] && printf "$model" > "$T/q/tok1_model.txt"
        AGENT="$agent" ENGBIN="$ENG" LC_ALL=C bash "$T/run.sh" "$T" "$side" >/dev/null 2>&1
    done
    if cmp -s "$T/bash.vars" "$T/engine.vars" && cmp -s "$T/bash.prompt" "$T/engine.prompt"; then ok "$label"
    else bad "$label"; diff "$T/bash.vars" "$T/engine.vars" | head -6; cmp "$T/bash.prompt" "$T/engine.prompt" 2>&1 | head -2
         echo "      bash prompt:   $(od -c "$T/bash.prompt" | head -2 | tr '\n' ' ')"; echo "      engine prompt: $(od -c "$T/engine.prompt" | head -2 | tr '\n' ' ')"; fi
}
B64() { printf '%s' "$1" | base64 -w0; }
M='{"project":"p1","chat":"c1","style":"chat","mode":"single","projects_root":"@ROOT@","cockpit_data":"@DATA@","web_root":"/var/www/html/cockpit","claude_model":"claude-opus-4-8","gemini_model":"auto"}'

check "plain request"                         claude "$M" 'hello there\n'
check "no trailing newline in the prompt"     claude "$M" 'hello'
check "several trailing newlines stripped"    claude "$M" 'hello\n\n\n'
check "empty prompt"                          claude "$M" ''
check "only newlines"                         claude "$M" '\n\n'
check "leading and inner newlines kept"       claude "$M" '\n\nfirst\n\nsecond\n'
check "NUL bytes in the prompt are dropped"   claude "$M" 'ab\0cd\n'
check "non-ASCII prompt"                      claude "$M" 'שלום עולם é\n'
check "a prompt that is exactly -n"           claude "$M" '-n\n'
check "backslashes and dollars"               claude "$M" 'a\\\\b $HOME `x` \\\\n\n'
check "no meta file at all"                   claude -     'hi\n'
check "meta with only a project"              claude '{"project":"only"}' 'hi\n'
check "empty project and chat get defaults"   claude '{"project":"","chat":"","claude_model":"","gemini_model":""}' 'hi\n'
check "the _standalone project"               claude '{"project":"_standalone","chat":"x","projects_root":"@ROOT@"}' 'hi\n'
check "spaces around the colon"               claude '{"project" : "sp","chat"   :   "c2","projects_root":"@ROOT@"}' 'hi\n'
check "tab around the colon"                  claude "$(printf '{"project"\t:\t"tb","projects_root":"@ROOT@"}')" 'hi\n'
check "pretty-printed meta (one key per line)" claude "$(printf '{\n  "project": "pp",\n  "chat": "cc",\n  "projects_root": "@ROOT@",\n  "cockpit_data": "@DATA@"\n}\n')" 'hi\n'
check "the first of two equal keys wins"      claude '{"project":"first","project":"second","projects_root":"@ROOT@"}' 'hi\n'
check "escaped slash is unescaped"            claude '{"project":"a\/b","projects_root":"@ROOT@"}' 'hi\n'
check "other escapes stay as written"         claude '{"project":"a\\nb","chat":"q\\u00e9","projects_root":"@ROOT@"}' 'hi\n'
check "key text inside a value is not a key"  claude '{"chat":"x \"project\": \"no\"","project":"real","projects_root":"@ROOT@"}' 'hi\n'
check "a non-string value is not read"        claude '{"project":5,"chat":"c","projects_root":"@ROOT@"}' 'hi\n'
check "key with a longer name is not matched" claude '{"my_project":"no","projects_root":"@ROOT@"}' 'hi\n'
check "value with a colon and spaces"         claude '{"project":"a: b","chat":"c d","projects_root":"@ROOT@"}' 'hi\n'
check "unicode values"                        claude '{"project":"פרויקט","chat":"שיחה","projects_root":"@ROOT@"}' 'hi\n'
check "CRLF meta file"                        claude "$(printf '{\r\n"project":"crlf",\r\n"projects_root":"@ROOT@"\r\n}\r\n')" 'hi\n'
check "images and rag"                        claude '{"project":"p","projects_root":"@ROOT@","images":"/a.png|/b.png","rag":"QUJD"}' 'hi\n'
check "meta with empty file"                  claude '' 'hi\n'
check "gemini agent"                          gemini "$M" 'hi gemini\n'
check "ollama agent with a model file"        ollama "$M" 'hi ollama\n' 'llama3.2:3b\n'
check "model file without newline"            ollama "$M" 'hi\n' 'qwen2.5-coder:7b'
check "empty model file"                      ollama "$M" 'hi\n' ''
check "a model file that holds only a newline" ollama "$M" 'hi\n' '\n'
# the supplier controls
check "effort text in front (claude)"         claude "${M%\}},\"claude_effort\":\"$(B64 'Think hard. ')\"}" 'do it\n'
check "effort text with a trailing newline"   claude "${M%\}},\"claude_effort\":\"$(B64 $'Think hard.\n')\"}" 'do it\n'
check "effort for the other agent is ignored" claude "${M%\}},\"gemini_effort\":\"$(B64 'GEM ')\"}" 'do it\n'
check "effort text in front (gemini)"         gemini "${M%\}},\"gemini_effort\":\"$(B64 'Be brief. ')\"}" 'do it\n'
check "effort text and an empty prompt"       claude "${M%\}},\"claude_effort\":\"$(B64 'only effort')\"}" ''
check "an empty effort value"                 claude "${M%\}},\"claude_effort\":\"\"}" 'do it\n'
check "multi-line effort text"                claude "${M%\}},\"claude_effort\":\"$(B64 $'line1\nline2\n\n')\"}" 'p\n'
check "non-ASCII effort text"                 claude "${M%\}},\"claude_effort\":\"$(B64 'חשוב היטב. ')\"}" 'p\n'
check "args whitelisted (claude)"             claude "${M%\}},\"claude_args\":\"$(B64 '--effort high')\"}" 'p\n'
check "args with a shell metacharacter"       claude "${M%\}},\"claude_args\":\"$(B64 '--effort high; echo hi')\"}" 'p\n'
check "args with a dollar"                    claude "${M%\}},\"claude_args\":\"$(B64 '--x $HOME')\"}" 'p\n'
check "args: a clean line and a dirty line"   claude "${M%\}},\"claude_args\":\"$(B64 $'--ok\n--bad;')\"}" 'p\n'
check "args: a dirty line then a clean one"   claude "${M%\}},\"claude_args\":\"$(B64 $'--bad;\n--ok')\"}" 'p\n'
check "args: a dirty line then a blank one"   claude "${M%\}},\"claude_args\":\"$(B64 $'--bad;\n')\"}" 'p\n'
check "args: only newlines"                   claude "${M%\}},\"claude_args\":\"$(B64 $'\n\n')\"}" 'p\n'
check "args: all allowed characters"          claude "${M%\}},\"claude_args\":\"$(B64 '-a_B.c:d=e/f 9')\"}" 'p\n'
check "args for gemini"                       gemini "${M%\}},\"gemini_args\":\"$(B64 '--model x')\"}" 'p\n'
check "args for ollama are ignored"           ollama "${M%\}},\"claude_args\":\"$(B64 '--x')\"}" 'p\n'

# inputs the engine does not copy: it must refuse BEFORE removing anything, and the Bash path must then be able to run
refuse() {   # label meta
    fresh; printf 'hello\n' > "$T/q/claude_prompt_tok1.txt"
    printf '%s' "$2" | sed "s|@ROOT@|$T/projroot|g; s|@DATA@|$T/data|g" > "$T/q/tok1_meta.json"
    AGENT=claude ENGBIN="$ENG" LC_ALL=C bash "$T/run.sh" "$T" engine >/dev/null 2>&1
    if head -1 "$T/engine.vars" | grep -q "ENGINE REFUSED" && [ "$(ls "$T/q" | sort | tr '\n' ' ')" = "claude_prompt_tok1.txt tok1_meta.json " ]; then ok "$1"
    else bad "$1: the engine did not refuse cleanly"; head -5 "$T/engine.vars"; fi
}
refuse "effort that is not valid base64"      "${M%\}},\"claude_effort\":\"!!!notbase64\"}"
refuse "effort with a bad length"             "${M%\}},\"claude_effort\":\"QUJDRA\"}"
refuse "args that decode to a NUL byte"       "${M%\}},\"claude_args\":\"$(printf 'a\0b' | base64 -w0)\"}"

# a prompt file name that is not this agent's
fresh; printf 'x\n' > "$T/q/gemini_prompt_t.txt"
"$ENG" intake --agent claude --queue-dir "$T/q" --response-dir "$T/r" --prompt-file "$T/q/gemini_prompt_t.txt" --root "$T/projroot" --prompt-out "$T/po" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && [ -f "$T/q/gemini_prompt_t.txt" ] && ok "another agent's prompt file is refused and left alone" || bad "another agent's prompt file (rc=$rc)"
rm -f "$T/q/gemini_prompt_t.txt"
"$ENG" intake --agent claude --queue-dir "$T/q" --response-dir "$T/r" --prompt-file "$T/q/claude_prompt_gone.txt" --root "$T/projroot" --prompt-out "$T/po" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "a vanished prompt file is refused" || bad "a vanished prompt file (rc=$rc)"

echo "intake_parity: $n passed, $fails failed"; [ "$fails" = 0 ]
