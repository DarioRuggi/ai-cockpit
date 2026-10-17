#!/bin/bash
# post_parity.sh — what agent_loop.sh does with a raw answer: finish_output (strip terminal artifacts, duration, Ollama usage line) and
# signin_hint, the Bash path vs `aicengine clean` / `aicengine signin-hint`, byte for byte, on a table of inputs.
#
# The two functions are extracted from the real scripts/agent_loop.sh. The Bash path runs under LC_ALL=C (sed ranges and `.` are then plain
# bytes, the way the engine reads them); `date` is replaced by a fixed clock so the duration and the usage line's timestamp can be compared.
#   bash tests/post_parity.sh        ENGINE=<aicengine> to choose the binary.   Exit 0 = pass; SKIPPED without a `clean`-capable engine, GNU sed, bc or GNU grep.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
sed --version >/dev/null 2>&1 && command -v bc >/dev/null 2>&1 || { echo "post_parity: GNU sed and bc are needed for the Bash path - SKIPPED"; exit 0; }
[ -x "$ENG" ] && "$ENG" signin-hint 2>&1 | grep -q "needs" || { echo "post_parity: $ENG has no 'clean' / 'signin-hint' command - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }

{
  grep -E '^if sed --version|^sedi\(\)' "$ROOT/scripts/agent_loop.sh"
  awk '/^engine_bin\(\) \{/{p=1} p{print} p&&/^}/{c++; if(c==2){p=0}}' "$ROOT/scripts/agent_loop.sh"
  awk '/^finish_output\(\) \{/{p=1} /^# The "installed but not signed in" hint/{p=0} p{print}' "$ROOT/scripts/agent_loop.sh"
  awk '/^signin_hint\(\) \{/{p=1} /^# Assembling the prompt for one turn/{p=0} p{print}' "$ROOT/scripts/agent_loop.sh"
} > "$T/fn.sh"
grep -q "^finish_output()" "$T/fn.sh" && grep -q "^signin_hint()" "$T/fn.sh" && grep -q "^sedi()" "$T/fn.sh" || { bad "could not extract the functions"; exit 1; }
# the engine, with the test clock added to `clean` (the real call has no such options)
cat > "$T/engshim" <<SHIM
#!/bin/bash
if [ "\$1" = "clean" ]; then exec "$ENG" "\$@" --end-ns "\$FAKE_END" --ts "\$FAKE_TS"; fi
exec "$ENG" "\$@"
SHIM
chmod +x "$T/engshim"
cat > "$T/run.sh" <<'RUN'
#!/bin/bash
# usage: run.sh DIR what      what = finish | hint
. "$1/fn.sh"
date() { case "$*" in *%s%N*) echo "$FAKE_END" ;; *%Y-%m-%dT*) echo "$FAKE_TS" ;; *) command date "$@" ;; esac; }
PROMPT_TMP=$(mktemp); SYS_TMP=$(mktemp)
case "$2" in
  finish) finish_output; echo "$DURATION" > "$1/duration.out" ;;
  hint)   signin_hint ;;
esac
RUN
FAKE_TS="2026-10-06T12:34:56"; export FAKE_TS
START=1000000000000000000

run_finish() { # $1 agent  $2 input file  $3 elapsed ns ; sets bash/engine result files
    export FAKE_END=$((START + $3)); export START_TIME=$START AGENT=$1 QUEUE_DIR="$T/q" MODEL="${MODEL:-llama3.2:3b}" PROJECT="${PROJECT:-proj}" CHAT_NAME="${CHAT_NAME:-chat}" OLLAMA_PROMPT_CHARS="${PCH:-0}"
    mkdir -p "$T/q"; rm -f "$T/ollama_usage.jsonl"
    cp "$2" "$T/OUT"; export OUT_FILE="$T/OUT"
    LC_ALL=C env -u COCKPIT_ENGINE bash "$T/run.sh" "$T" finish 2>/dev/null; cp "$T/OUT" "$T/b_out"; cp "$T/duration.out" "$T/b_dur"; cp "$T/ollama_usage.jsonl" "$T/b_log" 2>/dev/null || : > "$T/b_log"
    rm -f "$T/ollama_usage.jsonl"; cp "$2" "$T/OUT"
    COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$T/engshim" bash "$T/run.sh" "$T" finish 2>/dev/null; cp "$T/OUT" "$T/e_out"; cp "$T/duration.out" "$T/e_dur"; cp "$T/ollama_usage.jsonl" "$T/e_log" 2>/dev/null || : > "$T/e_log"
}
check_finish() { # $1 label $2 agent $3 file $4 elapsed ns
    run_finish "$2" "$3" "$4"
    if cmp -s "$T/b_out" "$T/e_out" && cmp -s "$T/b_dur" "$T/e_dur" && cmp -s "$T/b_log" "$T/e_log"; then ok "$1"
    else bad "$1"; cmp "$T/b_out" "$T/e_out" 2>&1 | head -1; cmp "$T/b_dur" "$T/e_dur" 2>&1 | head -1; cmp "$T/b_log" "$T/e_log" 2>&1 | head -1
         echo "      bash:   $(od -c "$T/b_out" | head -2 | tr '\n' ' ') dur=$(cat "$T/b_dur") log=$(head -c 160 "$T/b_log")"; echo "      engine: $(od -c "$T/e_out" | head -2 | tr '\n' ' ') dur=$(cat "$T/e_dur") log=$(head -c 160 "$T/e_log")"; fi
}
mk() { printf "$2" > "$T/in_$1"; }     # $2 is a printf format: \n \r \033 \x.. are turned into bytes

# ---- stripping ---------------------------------------------------------------------------------------------------------------------------------
mk plain 'Hello world\nsecond line\n'; mk nonl 'Hello world\nno final newline'; mk empty ''; mk onlynl '\n'; mk blanks '\n\n a \n\n'
mk crlf 'line one\r\nline two\r\nlast\r\n'; mk cronly '\r\r\n'; mk crmid 'a\rb\rc\n'
mk ansi 'plain \033[31mred\033[0m plain\n\033[1;32mgreen\033[m\n\033[2K\033[H\033[3;4Hx\033[10Ay\n'
mk ansi_odd 'a\033[?25hb \033[5h \033[12 \033[ \033[;m\033[999999999m end \033['
mk ansi_endesc 'text\033'
mk ansi_upper 'x\033[1Zy\033[0Ez\033[7Nw\033[0lq\n'
mk spin_last 'The answer is here.\n25h tail words\n'; mk spin_last_nonl 'The answer is here.\n25h tail words'
mk spin_mid 'First\n5h timer set\nlast line\n'; mk spin_s '10s elapsed words\n'; mk spin_only '25h tail\n'
mk spin_nospace 'text\n25h\n'; mk spin_space_digits 'text\n25 h x\n'; mk spin_cr 'text\n25h tail\r\n'; mk spin_esc 'text\n\033[0m25h tail\n'; mk spin_bigdigits 'text\n123456h x\n'
mk spin_two 'a\n25h one\n30s two\n'; mk spin_upper 'a\n25H x\n'; mk spin_ws ' 25h x\n'
mk gem_noise 'real answer\nWarning: terminal does not support true color\nmore answer\n'
mk gem_all 'a\nWARNING: x COLOR y\nwarning:  no colour\nWarning: color\nWarning: nothing here\ncolor warning: x\nRipgrep is not available. Falling back to GrepTool.\nBASIC TERMINAL DETECTED\nUsing a terminal with True Color!\nTRUE COLOR\ntrue  color\nz\n'
mk gem_last_nonl 'answer\nRipgrep is not available'; mk gem_only_noise 'Ripgrep is not available\nFalling back to GrepTool\n'
mk gem_with_cr_esc 'ok\r\n\033[33mWarning:\033[0m terminal lacks \033[1mcolor\033[0m support\r\nfine\r\n'
mk unicode 'שלום עולם\n😀 emoji\n25h שלום\n'; mk invalid_utf8 'bad \xff\xfe byte\nWarning: \xc3 color\nend\n'
mk bigline "$(head -c 20000 /dev/zero | tr '\0' 'x')"'\n25h tail\n'
for ag in ollama gemini claude workers; do
    for f in plain nonl empty onlynl blanks crlf cronly crmid ansi ansi_odd ansi_endesc ansi_upper spin_last spin_last_nonl spin_mid spin_s spin_only spin_nospace spin_space_digits spin_cr spin_esc spin_bigdigits spin_two spin_upper spin_ws gem_noise gem_all gem_last_nonl gem_only_noise gem_with_cr_esc unicode invalid_utf8 bigline; do
        check_finish "strip $ag: $f" $ag "$T/in_$f" 2300000000
    done
done

# ---- durations (bc scale=1 truncates) ---------------------------------------------------------------------------------------------------------------
mk plain2 'x\n'
for ns in 0 1 99999999 100000000 100000001 199999999 999999999 1000000000 1099999999 1200000000 5000000000 5099999999 59999999999 61500000000 12345678901 3600000000000 360000000000000; do
    check_finish "duration ${ns}ns (ollama usage line too)" ollama "$T/in_plain2" $ns
    check_finish "duration ${ns}ns (gemini, no usage line)" gemini "$T/in_plain2" $ns
done
check_finish "a clock that went backwards" ollama "$T/in_plain2" -300000000

# ---- the Ollama usage line -----------------------------------------------------------------------------------------------------------------------------
head -c 4000 /dev/zero | tr '\0' 'r' > "$T/in_r4000"; head -c 3 /dev/zero | tr '\0' 'r' > "$T/in_r3"; printf 'x' > "$T/in_r1"; head -c 7 /dev/zero | tr '\0' 'r' > "$T/in_r7"
for pc in 0 1 3 4 5 399 400 4000; do PCH=$pc check_finish "prompt chars $pc" ollama "$T/in_plain2" 1200000000; done
for f in r4000 r3 r1 r7 empty; do check_finish "response size: $f" ollama "$T/in_$f" 2200000000; done
MODEL='qwen2.5-coder:1.5b' PROJECT='My Project' CHAT_NAME='chat 1' check_finish "ordinary names" ollama "$T/in_plain2" 1500000000
MODEL='we"ird' PROJECT='pro"ject' CHAT_NAME='"quoted"' check_finish "double quotes in names (the Bash escapes them)" ollama "$T/in_plain2" 1500000000
MODEL='שלום' PROJECT='פרויקט' CHAT_NAME='צ׳אט' check_finish "unicode names" ollama "$T/in_plain2" 1500000000
MODEL='' PROJECT='' CHAT_NAME='' check_finish "empty names" ollama "$T/in_plain2" 1500000000
MODEL=llama3.2:3b PROJECT=p CHAT_NAME='back\\slash' run_finish ollama "$T/in_plain2" 1500000000
if echo "{$(cat "$T/e_log" | head -c 4000)}" | php -r 'exit(json_decode(trim(stream_get_contents(STDIN)), true) !== null ? 0 : 1);' 2>/dev/null || php -r 'exit(json_decode(trim(file_get_contents($argv[1])), true) !== null ? 0 : 1);' "$T/e_log"; then ok "a backslash in a chat name: the engine's usage line is valid JSON"; else bad "backslash name gives invalid JSON from the engine: $(cat "$T/e_log")"; fi
php -r 'exit(json_decode(trim(file_get_contents($argv[1])), true) === null ? 0 : 1);' "$T/b_log" && ok "(for the record: the Bash line for that name is NOT valid JSON: only the double quote is escaped there)" || ok "(the Bash line happened to parse)"

# ---- the "not signed in" hint ------------------------------------------------------------------------------------------------------------------------
run_hint() { # $1 agent $2 file
    export AGENT=$1 AGENT_UC=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
    cp "$2" "$T/OUT"; export OUT_FILE="$T/OUT"
    LC_ALL=C env -u COCKPIT_ENGINE bash "$T/run.sh" "$T" hint 2>/dev/null; cp "$T/OUT" "$T/b_out"
    cp "$2" "$T/OUT"; COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$ENG" bash "$T/run.sh" "$T" hint 2>/dev/null; cp "$T/OUT" "$T/e_out"
}
check_hint() { run_hint "$2" "$3"; if cmp -s "$T/b_out" "$T/e_out"; then ok "$1"; else bad "$1"; echo "      bash:   $(od -c "$T/b_out" | head -3 | tr '\n' ' ')"; echo "      engine: $(od -c "$T/e_out" | head -3 | tr '\n' ' ')"; fi; }
i=0
for phrase in 'Not logged in · Please run /login' 'please RUN /LOGIN now' 'Error: not authenticated' 'Authentication required.' 'Set GEMINI_API_KEY first' 'set openai_api_key' 'run claude login' 'run gemini auth' 'run codex-login' 'run /login' 'run login' 'Run  auth' 'run qwenxlogin' 'run qwen/auth' 'RUN CLAUDE AUTH' 'not logged in' 'You are not LOGGED IN yet' 'authentication  required' 'not authenticate' 'authentication' 'please run login later' 'nothing relevant here' 'run' 'login' 'GEMINI API KEY'; do
    i=$((i+1)); printf '%s\n' "$phrase" > "$T/h_$i"
    for ag in claude gemini ollama codex; do check_hint "hint $ag: '$phrase'" $ag "$T/h_$i"; done
done
printf 'not\nlogged in\n' > "$T/h_split"; check_hint "a phrase split over two lines is not a match" claude "$T/h_split"
printf 'prefix text\nwith lines\nnot logged in\nsuffix' > "$T/h_nonl"; check_hint "a match on a middle line, no final newline" claude "$T/h_nonl"
head -c 790 /dev/zero | tr '\0' 'a' > "$T/h_790"; printf '\nnot logged in\n' >> "$T/h_790"; check_hint "799 bytes with the phrase (just under the limit)" claude "$T/h_790"
head -c 785 /dev/zero | tr '\0' 'a' > "$T/h_799"; printf '\nnot logged in\n' >> "$T/h_799"; check_hint "size 800 or a little under, with the phrase" claude "$T/h_799"
head -c 800 /dev/zero | tr '\0' 'a' > "$T/h_800"; printf 'not logged in' >> "$T/h_800"; check_hint "over 800 bytes with the phrase: no hint" claude "$T/h_800"
for sz in 780 782 783 784 785 786 787 788 789 790; do head -c $((sz - 14)) /dev/zero | tr '\0' 'a' > "$T/h_s$sz"; printf '\nnot logged in\n' >> "$T/h_s$sz"; check_hint "boundary: file of about $sz bytes" claude "$T/h_s$sz"; done
: > "$T/h_empty"; check_hint "empty answer" claude "$T/h_empty"
printf 'שלום not logged in 😀\n' > "$T/h_uni"; check_hint "unicode around the phrase" claude "$T/h_uni"
echo "post_parity: $n cases identical, $fails failure(s)"
exit $((fails>0))
