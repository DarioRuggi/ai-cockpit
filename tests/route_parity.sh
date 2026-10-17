#!/bin/bash
# route_parity.sh — capabilities apply + the Workers and Tools auto-route prompts of agent_loop.sh, the Bash path (real jq, curl, ln, cp) vs
# `aicengine route`: the three prompt variables, the files written (.mcp.json, the skill links) and the headers the two requests carried, on a
# table of project states. The Bash is cut out of the real loop; the pages are a small PHP server answering from files.
#   bash tests/route_parity.sh     ENGINE=<aicengine>      Exit 0 = pass; SKIPPED without an engine with `route`, jq, curl or php.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$ROOT/scripts/agent_loop.sh"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
for c in jq curl php; do command -v $c >/dev/null 2>&1 || { echo "route_parity: $c is needed - SKIPPED"; exit 0; }; done
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q route || { echo "route_parity: $ENG has no 'route' command - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; SRV=""
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
wipe() { rm -rf "${T:?}/p" "${T:?}/dt" "${T:?}/hm" "${T:?}/resp" "${T:?}/sk"; mkdir -p "$T/p" "$T/dt" "$T/hm" "$T/resp" "$T/sk"; : > "$T/srv.log"; echo skill-body > "$T/sk/real.md"; }

{ awk '/^engine_bin\(\) \{/{p=1} p{print} p&&/^}/{c++; if(c==2){p=0}}' "$LOOP"
  awk '/^route_engine\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$LOOP"
  awk '/^_ck_hdr\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$LOOP"; } > "$T/fn.sh"
awk '/^        CAPS_STAGE=/{p=1} /^        fi   # ROUTE_DONE/{p=0} p{print}' "$LOOP" > "$T/region.sh"
for f in fn region; do [ -s "$T/$f.sh" ] || { bad "could not cut $f out of the loop"; exit 1; }; done

# the pages: answer from files, log the key header they were sent
mkdir -p "$T/web"
cat > "$T/web/router.php" <<'PHP'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
file_put_contents(getenv('SRV_LOG'), $p . ' key=' . ($_SERVER['HTTP_X_COCKPIT_INTERNAL'] ?? '-') . ' user=' . ($_SERVER['HTTP_X_COCKPIT_USER'] ?? '-') . "\n", FILE_APPEND);
$f = getenv('SRV_DIR') . '/' . str_replace('/', '_', $p);
if (is_file($f . '.status')) http_response_code((int)file_get_contents($f . '.status'));
if (is_file($f)) readfile($f);
PHP
PORT=$((20000 + RANDOM % 20000))
SRV_DIR="$T/resp" SRV_LOG="$T/srv.log" php -S 127.0.0.1:$PORT -t "$T/web" "$T/web/router.php" >/dev/null 2>&1 & SRV=$!
mkdir -p "$T/resp"; for i in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/x" && break; sleep 0.2; done
BASE="http://127.0.0.1:$PORT"

cat > "$T/run.sh" <<'RUN'
#!/bin/bash
# usage: run.sh DIR bash|engine   — the project state is already laid out under DIR/p (project), DIR/dt (shared data), DIR/hm (home)
D="$1"; AGENT="${AGENT:-claude}"; PROJECT="${PROJECT:-pr}"; PROJECT_DIR="$D/p"; _DATA="$D/dt"; HOME="$D/hm"
export COCKPIT_INTERNAL_KEY=k123 COCKPIT_INTERNAL_USER=dario COCKPIT_BASE_URL="$BASEURL"
. "$D/fn.sh"
WORKERS_AUTO_PROMPT=LEAK; TOOLS_AUTO_PROMPT=LEAK; OLLAMA_CAPS_PROMPT=LEAK
if [ "$2" = engine ]; then
    export COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$ENGBIN"
    route_engine || { echo "ENGINE REFUSED" > "$D/$2.vars"; exit 0; }
else
    . "$D/region.sh"
fi
{ printf 'CAPS=[%s]\nWORKERS=[%s]\nTOOLS=[%s]\n' "$OLLAMA_CAPS_PROMPT" "$WORKERS_AUTO_PROMPT" "$TOOLS_AUTO_PROMPT"
  [ -f "$PROJECT_DIR/.mcp.json" ] && { echo "MCP:"; cat "$PROJECT_DIR/.mcp.json"; }
  [ -d "$HOME/.claude/skills" ] && { echo "SKILLS:"; ( cd "$HOME/.claude/skills" && for f in * .[!.]*; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s -> %s\n' "$f" "$(readlink "$f")"; done ); }
  [ -f "$HOME/.gemini/settings.json" ] && { echo "GEMINI:"; cat "$HOME/.gemini/settings.json"; }
} > "$D/$2.vars" 2>&1
RUN

# a case:  check LABEL AGENT SETUP   (setup sees S=caps dir W=workers answer TL=tools answer D=shared data PD=project SK=skill files)
check() {
    local label="$1" agent="$2" setup="$3" side
    for side in bash engine; do
        wipe
        ( S="$T/p/.cockpit_caps"; PD="$T/p"; D="$T/dt"; W="$T/resp/_workers.php"; TL="$T/resp/_tools.php"; SK="$T/sk"; HOME="$T/hm"; eval "$setup" )
        AGENT="$agent" ENGBIN="$ENG" BASEURL="$BASE" bash "$T/run.sh" "$T" "$side" >/dev/null 2>&1
        cp "$T/srv.log" "$T/$side.srv"
    done
    if cmp -s "$T/bash.vars" "$T/engine.vars" && cmp -s "$T/bash.srv" "$T/engine.srv"; then ok "$label"
    else bad "$label"; diff "$T/bash.vars" "$T/engine.vars" | head -8; diff "$T/bash.srv" "$T/engine.srv" | head -4; fi
}
st() { printf '%s' "$1" > "$D/workers_state.json"; }
sT() { printf '%s' "$1" > "$D/tools_state.json"; }
WOK='{"models":[{"provider":"groq"},{"provider":"huggingface"},{"provider":"groq"},{"provider":"cloudflare"}]}'
TOK='{"presets":[{"value":"ffmpeg:mp3"},{"value":"pandoc:docx"}]}'
ON='{"auto_route_projects":["pr"]}'

check "nothing configured at all" claude ':'
check "workers on, pages answer" claude 'st "$ON"; printf %s "$WOK" > "$W"'
check "workers providers sorted and unique" claude 'st "$ON"; printf %s "{\"models\":[{\"provider\":\"zeta\"},{\"provider\":\"alpha\"},{\"provider\":\"Mid\"},{\"provider\":\"alpha\"}]}" > "$W"'
check "workers: unicode providers" claude 'st "$ON"; printf %s "{\"models\":[{\"provider\":\"é\"},{\"provider\":\"z\"},{\"provider\":\"ש\"}]}" > "$W"'
check "workers: a null provider sorts first" claude 'st "$ON"; printf %s "{\"models\":[{\"provider\":\"b\"},{\"provider\":null},{\"x\":1}]}" > "$W"'
check "workers: only null providers" claude 'st "$ON"; printf %s "{\"models\":[{\"provider\":null}]}" > "$W"'
check "workers: the literal provider null" claude 'st "$ON"; printf %s "{\"models\":[{\"provider\":\"null\"}]}" > "$W"'
check "workers: empty models list" claude 'st "$ON"; printf %s "{\"models\":[]}" > "$W"'
check "workers: models missing" claude 'st "$ON"; printf %s "{\"ok\":true}" > "$W"'
check "workers: models null" claude 'st "$ON"; printf %s "{\"models\":null}" > "$W"'
check "workers: models false" claude 'st "$ON"; printf %s "{\"models\":false}" > "$W"'
check "workers: models a string" claude 'st "$ON"; printf %s "{\"models\":\"x\"}" > "$W"'
check "workers: models an object of objects" claude 'st "$ON"; printf %s "{\"models\":{\"a\":{\"provider\":\"p2\"},\"b\":{\"provider\":\"p1\"}}}" > "$W"'
check "workers: a model entry that is a string" claude 'st "$ON"; printf %s "{\"models\":[\"x\"]}" > "$W"'
check "workers: the answer is an array" claude 'st "$ON"; printf %s "[1,2]" > "$W"'
check "workers: the answer is not JSON" claude 'st "$ON"; printf %s "<html>no</html>" > "$W"'
check "workers: the answer is empty" claude 'st "$ON"; : > "$W"'
check "workers: the page answers 401 with an error body" claude 'st "$ON"; printf %s "{\"error\":\"Authentication required\"}" > "$W"; echo 401 > "$W.status"'
check "workers: the page answers 500 with models in the body" claude 'st "$ON"; printf %s "$WOK" > "$W"; echo 500 > "$W.status"'
check "workers: the page is missing (404)" claude 'st "$ON"; echo 404 > "$W.status"'
check "workers: this project is not listed" claude 'st "{\"auto_route_projects\":[\"other\"]}"; printf %s "$WOK" > "$W"'
check "workers: the project is listed twice (count 2, off)" claude 'st "{\"auto_route_projects\":[\"pr\",\"pr\"]}"; printf %s "$WOK" > "$W"'
check "workers: the list has other values too" claude 'st "{\"auto_route_projects\":[\"a\",\"pr\",5,null]}"; printf %s "$WOK" > "$W"'
check "workers: auto_route_projects is an object" claude 'st "{\"auto_route_projects\":{\"x\":\"pr\"}}"; printf %s "$WOK" > "$W"'
check "workers: auto_route_projects is a string" claude 'st "{\"auto_route_projects\":\"pr\"}"; printf %s "$WOK" > "$W"'
check "workers: auto_route_projects is null" claude 'st "{\"auto_route_projects\":null}"; printf %s "$WOK" > "$W"'
check "workers: auto_route_projects is missing" claude 'st "{}"; printf %s "$WOK" > "$W"'
check "workers: the state file is not JSON" claude 'st "{ broken"; printf %s "$WOK" > "$W"'
check "workers: the state file is an array" claude 'st "[\"pr\"]"; printf %s "$WOK" > "$W"'
check "workers: the state file is empty" claude 'st ""; printf %s "$WOK" > "$W"'
check "workers: no state file" claude 'printf %s "$WOK" > "$W"'
check "tools on, pages answer" claude 'sT "$ON"; printf %s "$TOK" > "$TL"'
check "tools: order and repeats are kept" claude 'sT "$ON"; printf %s "{\"presets\":[{\"value\":\"z\"},{\"value\":\"a\"},{\"value\":\"z\"}]}" > "$TL"'
check "tools: a null value is an empty slot" claude 'sT "$ON"; printf %s "{\"presets\":[{\"value\":\"a\"},{\"value\":null},{\"x\":1},{\"value\":\"b\"}]}" > "$TL"'
check "tools: only null values" claude 'sT "$ON"; printf %s "{\"presets\":[{\"value\":null}]}" > "$TL"'
check "tools: empty presets" claude 'sT "$ON"; printf %s "{\"presets\":[]}" > "$TL"'
check "tools: answer not JSON" claude 'sT "$ON"; printf %s "oops" > "$TL"'
check "tools: this project not listed" claude 'sT "{\"auto_route_projects\":[\"x\"]}"; printf %s "$TOK" > "$TL"'
check "workers and tools both on" claude 'st "$ON"; sT "$ON"; printf %s "$WOK" > "$W"; printf %s "$TOK" > "$TL"'
check "both on, for the ollama agent" ollama 'st "$ON"; sT "$ON"; printf %s "$WOK" > "$W"; printf %s "$TOK" > "$TL"'
check "both on, for the gemini agent" gemini 'st "$ON"; sT "$ON"; printf %s "$WOK" > "$W"; printf %s "$TOK" > "$TL"'
# capabilities
check "caps folder present but empty" claude 'mkdir -p "$S"'
check "claude: MCP file copied" claude 'mkdir -p "$S"; printf %s "{\"mcpServers\":{\"a\":{}}}" > "$S/claude_mcp.json"'
check "claude: MCP file replaces an old one" claude 'mkdir -p "$S"; printf old > "$PD/.mcp.json"; printf %s "{\"new\":1}" > "$S/claude_mcp.json"'
check "claude: an empty MCP file is not copied" claude 'mkdir -p "$S"; : > "$S/claude_mcp.json"'
check "claude: MCP with newlines and no final newline" claude 'mkdir -p "$S"; printf "{\n  \"a\": 1\n}" > "$S/claude_mcp.json"'
check "claude: skills linked" claude 'mkdir -p "$S"; printf %s "{\"skills\":{\"s1\":\"$SK/real.md\",\"s2\":\"$SK/real.md\"}}" > "$S/claude_skills.json"'
check "claude: a skill whose file is missing is skipped" claude 'mkdir -p "$S"; printf %s "{\"skills\":{\"s1\":\"$SK/none.md\",\"s2\":\"$SK/real.md\"}}" > "$S/claude_skills.json"'
check "claude: an old link is replaced" claude 'mkdir -p "$S" "$HOME/.claude/skills"; ln -s /nowhere "$HOME/.claude/skills/s1.md"; printf %s "{\"skills\":{\"s1\":\"$SK/real.md\"}}" > "$S/claude_skills.json"'
check "claude: a real file in the way is replaced" claude 'mkdir -p "$S" "$HOME/.claude/skills"; echo x > "$HOME/.claude/skills/s1.md"; printf %s "{\"skills\":{\"s1\":\"$SK/real.md\"}}" > "$S/claude_skills.json"'
check "claude: skills empty object" claude 'mkdir -p "$S"; printf %s "{\"skills\":{}}" > "$S/claude_skills.json"'
check "claude: skills file not JSON" claude 'mkdir -p "$S"; printf %s "{ nope" > "$S/claude_skills.json"'
check "claude: a path with spaces" claude 'mkdir -p "$S"; echo b > "$SK/a b.md"; printf %s "{\"skills\":{\"x y\":\"$SK/a b.md\"}}" > "$S/claude_skills.json"'

check "claude: an empty path" claude 'mkdir -p "$S"; printf %s "{\"skills\":{\"e\":\"\"}}" > "$S/claude_skills.json"'
check "claude: MCP and skills together, with auto-route" claude 'mkdir -p "$S"; printf %s "{\"m\":1}" > "$S/claude_mcp.json"; printf %s "{\"skills\":{\"s\":\"$SK/real.md\"}}" > "$S/claude_skills.json"; st "$ON"; printf %s "$WOK" > "$W"'
check "claude: the files of another agent are ignored" claude 'mkdir -p "$S"; printf %s "{\"m\":1}" > "$S/gemini_mcp.json"; printf hi > "$S/ollama_system_prompt.txt"'
check "ollama: system prompt text" ollama 'mkdir -p "$S"; printf "Use the tools.\nCarefully.\n" > "$S/ollama_system_prompt.txt"'
check "ollama: text without a newline" ollama 'mkdir -p "$S"; printf "no newline" > "$S/ollama_system_prompt.txt"'
check "ollama: several trailing newlines" ollama 'mkdir -p "$S"; printf "x\n\n\n" > "$S/ollama_system_prompt.txt"'
check "ollama: an empty file" ollama 'mkdir -p "$S"; : > "$S/ollama_system_prompt.txt"'
check "ollama: non-ASCII text" ollama 'mkdir -p "$S"; printf "שלום é\n" > "$S/ollama_system_prompt.txt"'
check "gemini: nothing staged for it" gemini 'mkdir -p "$S"'
check "gemini: an empty MCP file" gemini 'mkdir -p "$S"; : > "$S/gemini_mcp.json"'

# what the engine must refuse (the Bash then does it): nothing written, and the Bash path still works
refuse() {
    wipe
    ( S="$T/p/.cockpit_caps"; PD="$T/p"; D="$T/dt"; W="$T/resp/_workers.php"; TL="$T/resp/_tools.php"; SK="$T/sk"; HOME="$T/hm"; eval "$3" )
    AGENT="$2" ENGBIN="$ENG" BASEURL="$BASE" bash "$T/run.sh" "$T" engine >/dev/null 2>&1
    if head -1 "$T/engine.vars" | grep -q "ENGINE REFUSED" && [ ! -e "$T/p/.mcp.json" ] && [ ! -d "$T/hm/.claude" ]; then ok "$1"
    else bad "$1: not refused cleanly"; head -3 "$T/engine.vars"; fi
}
refuse "an empty skill id" claude 'mkdir -p "$S"; printf %s "{\"skills\":{\"\":\"$SK/real.md\"}}" > "$S/claude_skills.json"'
refuse "gemini MCP merge is left to the Bash" gemini 'mkdir -p "$S"; printf %s "{\"mcpServers\":{}}" > "$S/gemini_mcp.json"'
refuse "a skill path that is not a string" claude 'mkdir -p "$S"; printf %s "{\"m\":1}" > "$S/claude_mcp.json"; printf %s "{\"skills\":{\"a\":5}}" > "$S/claude_skills.json"'
refuse "skills that is not an object" claude 'mkdir -p "$S"; printf %s "{\"skills\":[\"a\"]}" > "$S/claude_skills.json"'
refuse "a provider that is not a string" claude 'printf %s "$ON" > "$D/workers_state.json"; printf %s "{\"models\":[{\"provider\":5}]}" > "$W"; mkdir -p "$S"; printf %s "{\"m\":1}" > "$S/claude_mcp.json"'
refuse "a skill id with a control character" claude 'mkdir -p "$S"; printf %s "{\"skills\":{\"a\\tb\":\"$SK/real.md\"}}" > "$S/claude_skills.json"'
echo "route_parity: $n passed, $fails failed"; [ "$fails" = 0 ]
