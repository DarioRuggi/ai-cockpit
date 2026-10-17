#!/bin/bash
# cli_isolate_parity.sh — the Claude CLI's private config folder (cockpit_cli_isolate in agent_loop.sh vs CliIsolate in aicengine loop): what each loop leaves
# in CLAUDE_CONFIG_DIR before the CLI starts. A FAKE claude records the environment and the folder; real credentials are never involved (scratch HOME with a dummy file).
#   bash tests/cli_isolate_parity.sh     ENGINE=<aicengine>     Exit 0 = pass; SKIPPED without an engine with `loop`, jq or php.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$ROOT/scripts/agent_loop.sh"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
for c in jq php; do command -v $c >/dev/null 2>&1 || { echo "cli_isolate_parity: $c is needed - SKIPPED"; exit 0; }; done
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " loop" || { echo "cli_isolate_parity: no engine with 'loop' - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; LP=""
trap '[ -n "$LP" ] && kill $LP 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
M='{"project":"p1","chat":"c1","projects_root":"@PROJ@","cockpit_data":"@DATA@/users/dario","claude_model":"claude-opus-4-8"}'
run_side() {   # $1 side  $2 setup (eval'd with S, HOME-relative helpers)
    local side="$1" S="$T/$1"
    rm -rf "${S:?}"; mkdir -p "$S"/{web/queue,web/responses,data/users/dario,home/.npm-global/bin,home/scripts,home/.claude,proj}
    printf '{"projects_root":"%s"}' "$S/proj" > "$S/web/paths.json"
    for f in history_cli.php crud_cli.php crud_executor.sh; do ln -sf "$ROOT/scripts/$f" "$S/home/scripts/$f"; done
    echo '{"claudeAiOauth":"DUMMY"}' > "$S/home/.claude/.credentials.json"; chmod 600 "$S/home/.claude/.credentials.json"
    cat > "$S/home/.npm-global/bin/claude" <<FAKE
#!/bin/bash
{ echo "CLAUDE_CONFIG_DIR=\${CLAUDE_CONFIG_DIR-UNSET}"
  echo "INTERNAL_USER=\${COCKPIT_INTERNAL_USER-UNSET} KEYLEN=\${#COCKPIT_INTERNAL_KEY} BASE=\${COCKPIT_BASE_URL-UNSET} COLOR=\${NO_COLOR-UNSET} TERM=\${TERM-UNSET} MODELS=\${OLLAMA_MODELS-UNSET}"
  if [ -n "\${CLAUDE_CONFIG_DIR:-}" ]; then
    cd "\$CLAUDE_CONFIG_DIR" && for f in \$(ls -A | sort); do
      if [ -L "\$f" ]; then echo "L \$f -> \$(readlink "\$f")"; else echo "F \$f mode=\$(stat -c %a "\$f")"; fi
    done
    for j in .claude.json settings.json; do [ -f "\$j" ] && { echo "== \$j"; jq -S . "\$j"; }; done
  fi; } > "$S/report.txt"
jq -n '{result:"ok"}'
FAKE
    chmod +x "$S/home/.npm-global/bin/claude"
    printf 'hello\n' > "$S/web/queue/claude_prompt_tokI.txt"
    printf '%s' "$M" | sed "s|@PROJ@|$S/proj|g; s|@DATA@|$S/data|g" > "$S/web/queue/tokI_meta.json"
    ( eval "$2" )
    local envs=(HOME="$S/home" COCKPIT_QUEUE_DIR="$S/web/queue" COCKPIT_RESPONSE_DIR="$S/web/responses" COCKPIT_DATA_DIR="$S/data" COCKPIT_ENGINE_BIN="$ENG")
    if [ "$side" = bash ]; then ( exec env "${envs[@]}" COCKPIT_ENGINE=1 bash "$LOOP" claude ) >"$S/loop.log" 2>&1 &
    else ( exec env "${envs[@]}" "$ENG" loop claude ) >"$S/loop.log" 2>&1 & fi
    LP=$!
    for i in $(seq 1 80); do [ -f "$S/web/responses/tokI.done" ] && break; sleep 0.25; done
    kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=""
}
norm() { sed "s|$T/$1|@S@|g; s|HOME=[^ ]*||" "$T/$1/report.txt"; }
check() {   # label setup
    run_side bash "$2"; run_side native "$2"
    [ -n "$DEBUGREP" ] && { echo "--- bash report"; cat "$T/bash/report.txt"; echo "--- native report"; cat "$T/native/report.txt"; echo "--- native log"; cat "$T/native/loop.log"; }
    if [ -s "$T/bash/report.txt" ] && [ "$(norm bash)" = "$(norm native)" ]; then ok "$1"
    else bad "$1"; diff <(norm bash) <(norm native) | head -12; fi
}
check "a first run: private folder, login linked, empty settings, trust records" ':'
check "a second run on an existing folder (login link already there)" 'mkdir -p "$S/data/users/dario/cli_config/claude"; ln -s "$S/home/.claude/.credentials.json" "$S/data/users/dario/cli_config/claude/.credentials.json"; echo "{\"projects\":{}}" > "$S/data/users/dario/cli_config/claude/.claude.json"; echo "{}" > "$S/data/users/dario/cli_config/claude/settings.json"'
check "a refreshed login that became a real file is tightened to 600" 'mkdir -p "$S/data/users/dario/cli_config/claude"; echo "{\"fresh\":1}" > "$S/data/users/dario/cli_config/claude/.credentials.json"; chmod 660 "$S/data/users/dario/cli_config/claude/.credentials.json"'
check "existing settings are kept" 'mkdir -p "$S/data/users/dario/cli_config/claude"; echo "{\"theme\":\"dark\"}" > "$S/data/users/dario/cli_config/claude/settings.json"'
check "existing trust records are kept and extended" 'mkdir -p "$S/data/users/dario/cli_config/claude"; echo "{\"projects\":{\"/other\":{\"hasTrustDialogAccepted\":true}},\"keep\":1}" > "$S/data/users/dario/cli_config/claude/.claude.json"'
check "the global CLI config is inherited when the capability asks (no private folder)" 'mkdir -p "$S/data/users/dario/capabilities"; echo "{\"inherit_cli_config\":true}" > "$S/data/users/dario/capabilities/global_caps.json"'
check "inherit false behaves as isolated" 'mkdir -p "$S/data/users/dario/capabilities"; echo "{\"inherit_cli_config\":false}" > "$S/data/users/dario/capabilities/global_caps.json"'
check "no login on this machine (no credentials file)" 'rm -f "$S/home/.claude/.credentials.json"'
echo "cli_isolate_parity: $n passed, $fails failed"; [ "$fails" = 0 ]
