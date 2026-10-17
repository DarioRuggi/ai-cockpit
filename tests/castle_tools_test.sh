#!/usr/bin/env bash
# castle_tools_test.sh — the Castle Game Engine tools (cockpit_app/castle_tool, tools_builtins/castle.json, the release-folder lookup in tools_lib.php)
# with the real engine: create a project, check it (clean and broken), leave nothing behind, compile, clean, version, refusals.
#   bash tests/castle_tools_test.sh     SKIPPED without the engine (fetch it as docs/user_space_tools.md says) or without fpc. Takes about two minutes.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CT="$ROOT/cockpit_app/castle_tool"
E="${CASTLE_ENGINE_PATH:-$HOME/.local/share/cockpit/tools/castle/castle_game_engine}"
[ -x "$E/bin/castle-engine" ] || { echo "castle_tools_test: no Castle Game Engine - SKIPPED"; exit 0; }
command -v fpc >/dev/null 2>&1 || { echo "castle_tools_test: no fpc - SKIPPED"; exit 0; }
export CASTLE_ENGINE_PATH="$E"
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
# new
bash "$CT" new "$T" "$T/n.txt" demo; has "[exit code 0]" "$T/n.txt" && [ -f "$T/demo/CastleEngineManifest.xml" ] && ok || bad "new: $(cat "$T/n.txt")"
bash "$CT" new "$T" "$T/n2.txt" demo 2>/dev/null; [ $? = 1 ] && has "already exists" "$T/n2.txt" && ok || bad "new over an existing folder was not refused"
bash "$CT" new "$T" "$T/n3.txt" "" 2>/dev/null; [ $? = 1 ] && ok || bad "new without a name was not refused"
bash "$CT" new "$T" "$T/n4.txt" '../evil' 2>/dev/null; [ ! -e "$T/../evil" ] && [ -d "$T/evil" ] && ok || bad "a path in the name was not stripped to a plain name"
P="$T/demo"
before=$(cd "$P" && find . -type f | sort | md5sum)
# check, clean source
bash "$CT" check "$P" "$T/c.txt"; has "[exit code 0]" "$T/c.txt" && has "lines compiled" "$T/c.txt" && ok || bad "check (clean): $(tail -5 "$T/c.txt")"
grep -q "^Compiling \|Writing Resource String" "$T/c.txt" && bad "check output still has per-unit noise" || ok
after=$(cd "$P" && find . -type f | sort | md5sum); [ "$before" = "$after" ] && [ ! -e "$P/castle-engine-output" ] && ok || bad "check left files behind"
# check, broken source: the messages carry file(line,col) and the summary box regex reads them
cp "$P/code/gameviewmain.pas" "$T/ok.pas"
sed -i '0,/^implementation/s//implementation\nvar zz: Integer = '"'x'"';/' "$P/code/gameviewmain.pas"
bash "$CT" check "$P/code" "$T/b.txt"     # a folder inside the project finds the project
has "[exit code 1]" "$T/b.txt" && grep -qE 'gameviewmain\.pas\([0-9]+,[0-9]+\) Error: Incompatible types' "$T/b.txt" && ok || bad "check (broken): $(tail -6 "$T/b.txt")"
cp "$T/ok.pas" "$P/code/gameviewmain.pas"
# compile, then clean
bash "$CT" compile "$P" "$T/k.txt"; has "[exit code 0]" "$T/k.txt" && [ -x "$P/demo" ] && ok || bad "compile: $(tail -4 "$T/k.txt")"
bash "$CT" clean "$P" "$T/l.txt"; has "[exit code 0]" "$T/l.txt" && [ ! -e "$P/castle-engine-output" ] && ok || bad "clean: $(cat "$T/l.txt")"
# version
bash "$CT" version "$P" "$T/v.md"; has "castle-engine 7." "$T/v.md" && has "Free Pascal 3." "$T/v.md" && has "<project" "$T/v.md" && ok || bad "version: $(head -5 "$T/v.md")"
# refusals
bash "$CT" check "$T" "$T/r.txt" 2>/dev/null; [ $? = 1 ] && ok || bad "a folder with no manifest at or above was not refused" 
bash "$CT" frob "$P" "$T/r2.txt" 2>/dev/null; [ $? = 1 ] && ok || bad "an unknown subcommand was not refused"
# the engine lookup through paths.json (the web server's HOME is not the owner's) and resolve_binary's release-folder lookup
H="$T/home"; mkdir -p "$H/.local/share/cockpit/tools/castle"; ln -s "$(dirname "$E")/castle_game_engine" "$H/.local/share/cockpit/tools/castle/castle_game_engine" 2>/dev/null || ln -s "$E" "$H/.local/share/cockpit/tools/castle/castle_game_engine"
W="$T/web"; mkdir -p "$W"; cp "$CT" "$W/castle_tool"; printf '{ "home": "%s" }\n' "$H" > "$W/paths.json"
( unset CASTLE_ENGINE_PATH; HOME=/nonexistent bash "$W/castle_tool" version "$P" "$T/lk.md" ); has "castle-engine 7." "$T/lk.md" && ok || bad "engine lookup through paths.json: $(head -3 "$T/lk.md")"
if command -v php >/dev/null 2>&1; then
  r=$(PATH=/usr/bin:/bin php -r 'define("COCKPIT_OS","linux"); $PATHS=["home"=>$argv[1]]; require $argv[2]; echo resolve_binary(["id"=>"castle","binary"=>"castle-engine"], ["tools"=>[]]);' "$H" "$ROOT/cockpit_app/tools_lib.php" 2>/dev/null)
  [ "$r" = "$H/.local/share/cockpit/tools/castle/castle_game_engine/bin/castle-engine" ] && ok || bad "resolve_binary release-folder lookup gave '$r'"
  php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^bash \{WEBROOT\}/castle_tool (new|check|compile|clean|package|version) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/castle.json" > "$T/pc" 2>&1; [ "$(cat "$T/pc")" = 6 ] && ok || bad "castle.json presets: $(cat "$T/pc")"
fi
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/game-castle.json")" = castle ] && ok || bad "the Castle kind does not name the tool"
echo "castle_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
