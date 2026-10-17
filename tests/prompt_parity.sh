#!/bin/bash
# prompt_parity.sh — assemble_prompt of agent_loop.sh: the Bash path vs `aicengine prompt`, byte for byte, on fixture trees.
#
# The function is extracted from the real scripts/agent_loop.sh (with dialect_open/close, engine_bin/engine_enabled and the CRUD system text)
# and run twice per case: engine off (the Bash path), engine on. Both PROMPT_TMP and SYS_TMP must match. Cases cover every input of the
# prompt: the goal / kind / description files (cut at 600 / 900 / 300 / 60 bytes, multibyte cut points, non-string values, invalid JSON),
# COCKPIT.md (8 KB cut, trailing newlines, NUL bytes), the profile and its marker, the directives (full, compact, per-agent override, config
# off / invalid / odd types), the identity line for every supplier, the xml / plain dialect, history / RAG / workers / tools / caps blocks.
#   bash tests/prompt_parity.sh        ENGINE=<aicengine> to choose the binary.   Exit 0 = pass; SKIPPED without a `prompt`-capable engine or jq.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
command -v jq >/dev/null 2>&1 || { echo "prompt_parity: jq not found (the Bash path needs it) - SKIPPED"; exit 0; }
[ -x "$ENG" ] && "$ENG" prompt 2>&1 | grep -q "prompt needs" || { echo "prompt_parity: $ENG has no 'prompt' command - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# ---- the functions, from the real file --------------------------------------------------------------------------------------------------
{
  awk '/^dialect_open\(\)/{print} /^dialect_close\(\)/{print}' "$ROOT/scripts/agent_loop.sh"
  awk '/^engine_bin\(\) \{/{p=1} p{print} p&&/^}/{c++; if(c==2){p=0}}' "$ROOT/scripts/agent_loop.sh"
  awk '/^CRUD_SYSTEM_PROMPT=/{p=1} p{print} p&&/^\[END SYSTEM\]/{p=0}' "$ROOT/scripts/agent_loop.sh"
  awk '/^assemble_prompt\(\) \{/{p=1} /^# The Gemini REST branch/{p=0} p{print}' "$ROOT/scripts/agent_loop.sh"
} > "$T/fn.sh"
grep -q "^assemble_prompt()" "$T/fn.sh" && grep -q "^CRUD_SYSTEM_PROMPT=" "$T/fn.sh" && grep -q "^dialect_open()" "$T/fn.sh" || { bad "could not extract the functions"; exit 1; }
cat > "$T/run.sh" <<'RUN'
#!/bin/bash
. "$1/fn.sh"
PROMPT_TMP=; SYS_TMP=
assemble_prompt
cp "$PROMPT_TMP" "$2"; cp "$SYS_TMP" "$3"
rm -f "$PROMPT_TMP" "$SYS_TMP"
RUN

# ---- a fresh case: directories and the default environment ------------------------------------------------------------------------------
reset_case() {
    rm -rf "$T/case"; mkdir -p "$T/case/proj/.chat_meta" "$T/case/data"
    export PROJECT_DIR="$T/case/proj" REQ_DATA="$T/case/data" _DATA="$T/nonexistent"
    export AGENT=claude PROJECT=myproj CHAT_NAME="My Chat" CLI_SUPPLIER= CLAUDE_MODEL=claude-sonnet-4-6 GEMINI_MODEL=auto MODEL= CLI_PROMPT_STYLE=plain
    export USER_PROMPT="hello there" HISTORY= RAG_B64= WORKERS_AUTO_PROMPT= TOOLS_AUTO_PROMPT= OLLAMA_CAPS_PROMPT=
}
P="$T/case/proj"; D="$T/case/data"
check() { # $1 = case name
    rm -f "$T"/b_p "$T"/b_s "$T"/e_p "$T"/e_s
    env -u COCKPIT_ENGINE bash "$T/run.sh" "$T" "$T/b_p" "$T/b_s" 2>/dev/null
    COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$ENG" bash "$T/run.sh" "$T" "$T/e_p" "$T/e_s" 2>/dev/null
    if cmp -s "$T/b_p" "$T/e_p" && cmp -s "$T/b_s" "$T/e_s"; then ok "$1"
    else bad "$1"; cmp "$T/b_p" "$T/e_p" 2>&1 | head -1; cmp "$T/b_s" "$T/e_s" 2>&1 | head -1
         diff <(cat "$T/b_p") <(cat "$T/e_p") | head -6; fi
}
for ag in claude gemini ollama workers; do for st in plain xml; do
    reset_case; export AGENT=$ag CLI_PROMPT_STYLE=$st; check "plain case: agent $ag, style $st"
done; done

# ---- the optional text blocks ------------------------------------------------------------------------------------------------------------
for ag in claude gemini ollama; do
    reset_case; export AGENT=$ag HISTORY=$'[Earlier in this chat]\nUser: hi\nAssistant: hello' RAG_B64=$(printf 'retrieved text\nwith lines\n\n\n' | base64 -w0) \
        WORKERS_AUTO_PROMPT=$'[Workers]\nuse them' TOOLS_AUTO_PROMPT=$'[Tools]\nuse them too' OLLAMA_CAPS_PROMPT=$'[Caps]\nFETCH: ok'
    for st in plain xml; do export CLI_PROMPT_STYLE=$st; check "all blocks: $ag/$st"; done
    export HISTORY= ; check "rag + workers + tools + caps without history: $ag"
    export RAG_B64= ; check "workers + tools + caps only: $ag"
done
reset_case; export USER_PROMPT=$'multi\nline\n\nprompt with "quotes" and \\ backslash and שלום and 😀'; check "a multi-line unicode prompt (claude)"
export AGENT=ollama MODEL=llama3.2:3b; check "a multi-line unicode prompt (ollama)"
reset_case; export USER_PROMPT=$'-x leading dash text'; check "a prompt starting with a dash (not an echo option)"
for dash in -n -e -E -ne '-n x'; do reset_case; export USER_PROMPT="$dash"; check "a prompt that is exactly $dash (echo would take it for an option; printf does not)"; export AGENT=gemini; check "... gemini"; done
reset_case; export USER_PROMPT='%%CREATE:a.txt%% x %%END%% $HOME $(whoami) `id`'; check "shell metacharacters in the prompt"

# ---- the identity line, every supplier ---------------------------------------------------------------------------------------------------------
for sup in "" gemini groq groq_build huggingface hf my-huggingface-x cloudflare-ai some-cloudflare-thing codex "my supplier"; do
    for gm in auto "" gemini-2.5-flash "Llama 3.1"; do
        reset_case; export AGENT=gemini CLI_SUPPLIER="$sup" GEMINI_MODEL="$gm"; check "identity: gemini supplier '$sup' model '$gm'"
    done
done
reset_case; export AGENT=claude CLAUDE_MODEL=auto; check "identity: claude model auto"
reset_case; export AGENT=claude CLAUDE_MODEL=; check "identity: claude without a model"
reset_case; export AGENT=ollama MODEL=qwen2.5:7b; check "identity: ollama with a model"
reset_case; export AGENT=ollama MODEL=; check "identity: ollama without a model"

# ---- goal, kind, descriptions -------------------------------------------------------------------------------------------------------------------
reset_case; echo '{"goal":"Ship the thing"}' > "$P/.cockpit_project.json"; check "project goal only"
reset_case; echo '{"goal":"Project goal","kind":"research","kind_name":"Research","kind_note":"Cite sources."}' > "$P/.cockpit_project.json"; check "project goal + kind"
reset_case; echo '{"kind":"research","kind_note":"Cite sources."}' > "$P/.cockpit_project.json"; check "kind without kind_name (falls back to the id)"
reset_case; echo '{"kind_name":null,"kind":"lazarus","kind_note":"Build with fpc."}' > "$P/.cockpit_project.json"; check "kind_name null -> kind"
reset_case; echo '{"kind_name":"","kind":"lazarus","kind_note":"Note"}' > "$P/.cockpit_project.json"; check "kind_name empty string (jq keeps it)"
reset_case; echo '{"kind_note":"Note without any name"}' > "$P/.cockpit_project.json"; check "kind note without a name or id"
reset_case; echo '{"goal":"Project default goal"}' > "$P/.cockpit_project.json"; echo '{"goal":"This chat goal"}' > "$P/.chat_meta/my_chat.json"; check "the chat goal wins over the project goal"
reset_case; echo '{"goal":"Project default goal"}' > "$P/.cockpit_project.json"; echo '{"goal":""}' > "$P/.chat_meta/my_chat.json"; check "an empty chat goal falls back to the project goal"
reset_case; echo '{"goal":"Project default goal"}' > "$P/.cockpit_project.json"; echo '{"description":"x"}' > "$P/.chat_meta/my_chat.json"; check "chat meta without a goal: the project goal"
reset_case; export PROJECT=_standalone; echo '{"goal":"Free goal","kind":"learning","kind_name":"Study","kind_note":"Explain simply."}' > "$P/.chat_meta/my_chat.json"
echo '{"goal":"IGNORED","kind_note":"IGNORED"}' > "$P/.cockpit_project.json"; check "a free chat: goal and kind from its own file only"
reset_case; export PROJECT=_standalone; check "a free chat without any meta"
reset_case; echo '{"goal":"G","description":"Project note","desc_send":true}' > "$P/.cockpit_project.json"; echo '{"description":"Chat note","desc_send":true}' > "$P/.chat_meta/my_chat.json"; check "both descriptions sent"
reset_case; echo '{"description":"Project note","desc_send":false}' > "$P/.cockpit_project.json"; echo '{"description":"Chat note","desc_send":false}' > "$P/.chat_meta/my_chat.json"; check "descriptions NOT sent (desc_send false)"
reset_case; echo '{"description":"Project note","desc_send":"true"}' > "$P/.cockpit_project.json"; echo '{"description":"Chat note","desc_send":1}' > "$P/.chat_meta/my_chat.json"; check "desc_send must be the boolean true (a string / a number is not)"
reset_case; echo '{"description":"Only project","desc_send":true}' > "$P/.cockpit_project.json"; check "only the project description sent"
reset_case; export PROJECT=_standalone; echo '{"description":"Free chat note","desc_send":true}' > "$P/.chat_meta/my_chat.json"; echo '{"description":"IGNORED","desc_send":true}' > "$P/.cockpit_project.json"; check "free chat: its description only"
LONG=$(head -c 700 /dev/zero | tr '\0' 'g'); reset_case; echo "{\"goal\":\"$LONG\"}" > "$P/.cockpit_project.json"; check "a 700-byte goal is cut at 600 bytes"
MB=$(printf 'é%.0s' $(seq 1 400)); reset_case; echo "{\"goal\":\"$MB\"}" > "$P/.cockpit_project.json"; check "a multibyte goal is cut mid-character at 600 bytes (as head -c does)"
reset_case; echo "{\"kind_name\":\"$MB\",\"kind_note\":\"$MB$MB\"}" > "$P/.cockpit_project.json"; check "kind name cut at 60 bytes, note at 900"
reset_case; echo "{\"description\":\"$MB\",\"desc_send\":true}" > "$P/.cockpit_project.json"; check "description cut at 300 bytes"
reset_case; echo '{"goal":42,"kind_note":true}' > "$P/.cockpit_project.json"; check "non-string goal / note values (jq prints them as JSON)"
reset_case; echo '{"goal":{"a":1,"b":[1,2]},"kind_note":[1,{"x":2}]}' > "$P/.cockpit_project.json"; check "object / array values (jq prints them pretty)"
reset_case; echo '{"goal":null,"kind_note":false}' > "$P/.cockpit_project.json"; check "null / false values are empty"
reset_case; echo '{"goal": broken' > "$P/.cockpit_project.json"; echo 'also {{ broken' > "$P/.chat_meta/my_chat.json"; check "invalid JSON in both files"
reset_case; echo '[1,2,3]' > "$P/.cockpit_project.json"; check "a JSON array where an object belongs"
reset_case; echo '"just a string"' > "$P/.cockpit_project.json"; check "a JSON string where an object belongs"
reset_case; printf '{"goal":"line1\\nline2\\tTab \\"q\\" \\\\"}' > "$P/.cockpit_project.json"; check "escapes inside the goal"
reset_case; echo '{"goal":"G","kind_note":"N"}' > "$P/.cockpit_project.json"; export CHAT_NAME="Chat With UPPER Case"; echo '{"goal":"slugged"}' > "$P/.chat_meta/chat_with_upper_case.json"; check "the chat file name: uppercase and spaces become a slug"

# ---- COCKPIT.md ----------------------------------------------------------------------------------------------------------------------------------
reset_case; printf '# Conventions\nUse tabs.\n' > "$P/COCKPIT.md"; check "COCKPIT.md small"
reset_case; printf '# Conventions\nUse tabs.\n\n\n\n' > "$P/COCKPIT.md"; check "COCKPIT.md with trailing newlines"
reset_case; : > "$P/COCKPIT.md"; check "COCKPIT.md empty"
reset_case; head -c 8192 /dev/zero | tr '\0' 'm' > "$P/COCKPIT.md"; check "COCKPIT.md exactly 8192 bytes (no notice)"
reset_case; head -c 8193 /dev/zero | tr '\0' 'm' > "$P/COCKPIT.md"; check "COCKPIT.md 8193 bytes (notice)"
reset_case; { head -c 8191 /dev/zero | tr '\0' 'm'; printf 'é-more text after'; } > "$P/COCKPIT.md"; check "COCKPIT.md cut through a multibyte character"
reset_case; { head -c 8100 /dev/zero | tr '\0' 'm'; printf '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\nmore'; } > "$P/COCKPIT.md"; check "COCKPIT.md whose cut ends in newlines (stripped before the notice)"
reset_case; printf 'before\0after\0end\n' > "$P/COCKPIT.md"; check "COCKPIT.md with NUL bytes (a shell cannot hold them)"
reset_case; printf 'שלום עולם\n😀 emoji\n' > "$P/COCKPIT.md"; check "COCKPIT.md unicode"

# ---- profile ---------------------------------------------------------------------------------------------------------------------------------------
reset_case; printf 'Units: metric.\nLanguage: English.\n' > "$D/profile.md"; check "profile"
reset_case; printf 'Units: metric.\n' > "$D/profile.md"; touch "$D/profile_enabled"; check "profile with the profile_enabled marker file (the Bash reads it as 'off')"
reset_case; : > "$D/profile.md"; check "an empty profile"
reset_case; head -c 5000 /dev/zero | tr '\0' 'p' > "$D/profile.md"; check "a profile over 4096 bytes is cut"
reset_case; printf '\n\n\n' > "$D/profile.md"; check "a profile of only newlines"
reset_case; export _DATA="$T/case/shared"; mkdir -p "$_DATA"; export REQ_DATA=; printf 'Shared profile\n' > "$_DATA/profile.md"; check "no per-user data dir: the shared one"

# ---- directives ------------------------------------------------------------------------------------------------------------------------------------
reset_case; printf 'Always be kind.\nNo emoji.\n' > "$D/directives_global.md"; check "global directives"
reset_case; head -c 9000 /dev/zero | tr '\0' 'd' > "$D/directives_global.md"; check "directives over 8192 bytes are cut"
reset_case; printf 'Full text\n' > "$D/directives_global.md"; printf 'Compact text\n' > "$D/directives_global_compact.md"; echo '{"enabled":true,"compact_suppliers":["ollama","other"]}' > "$D/directives_config.json"
for ag in claude gemini ollama; do export AGENT=$ag; check "compact directives for the listed supplier only: $ag"; done
reset_case; printf 'Full text\n' > "$D/directives_global.md"; printf 'Compact text\n' > "$D/directives_global_compact.md"; echo '{"compact_suppliers":["ollama"]}' > "$D/directives_config.json"; export AGENT=ollama; check "compact list without an 'enabled' key"
reset_case; printf 'Full text\n' > "$D/directives_global.md"; echo '{"compact_suppliers":["ollama"]}' > "$D/directives_config.json"; export AGENT=ollama; check "listed as compact but no compact file: the full text"
reset_case; printf 'Full\n' > "$D/directives_global.md"; printf 'Compact\n' > "$D/directives_global_compact.md"; printf 'Per-agent override\n' > "$D/directives_ollama.md"; echo '{"compact_suppliers":["ollama"]}' > "$D/directives_config.json"; export AGENT=ollama; check "the per-agent override beats compact and full"
reset_case; printf 'Full\n' > "$D/directives_global.md"; : > "$D/directives_gemini.md"; export AGENT=gemini; check "an empty per-agent file is ignored"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo '{"enabled":false}' > "$D/directives_config.json"; check "directives switched off in the config"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo '{"enabled":"false"}' > "$D/directives_config.json"; check "enabled as the STRING false is not false"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo '{"enabled":0}' > "$D/directives_config.json"; check "enabled 0 is not false"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo '{"enabled": broken' > "$D/directives_config.json"; check "an invalid config disables the directives (jq prints nothing)"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo '[1,2]' > "$D/directives_config.json"; check "a config that is an array"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo 'null' > "$D/directives_config.json"; check "a config that is null"
reset_case; printf 'Full\n' > "$D/directives_global.md"; echo '{}' > "$D/directives_config.json"; check "an empty config object"
reset_case; printf 'Full\n' > "$D/directives_global.md"; printf 'Compact\n' > "$D/directives_global_compact.md"; export AGENT=ollama
for cs in '"ollama"' '["x",5,true,null,"ollama"]' '[["a"]]' '[{"a":1}]' '[]' 'null' '5' '["  ollama  "]' '["olla","ma"]'; do
    echo "{\"compact_suppliers\":$cs}" > "$D/directives_config.json"; check "compact_suppliers = $cs"
done
reset_case; printf 'Full\n' > "$D/directives_global.md"; printf 'Profile text\n' > "$D/profile.md"; printf 'Kind\n' > "$P/COCKPIT.md"; echo '{"goal":"G","kind_note":"N","description":"D","desc_send":true}' > "$P/.cockpit_project.json"
for ag in claude gemini ollama; do for st in plain xml; do export AGENT=$ag CLI_PROMPT_STYLE=$st HISTORY=$'hist' RAG_B64=$(printf 'rag' | base64 -w0) WORKERS_AUTO_PROMPT=w TOOLS_AUTO_PROMPT=t OLLAMA_CAPS_PROMPT=c; check "everything at once: $ag/$st"; done; done
echo "prompt_parity: $n cases identical, $fails failure(s)"
exit $((fails>0))
