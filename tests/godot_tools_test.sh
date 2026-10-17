#!/usr/bin/env bash
# godot_tools_test.sh — the Godot tools (cockpit_app/godot_tool, tools_builtins/godot.json, the user-space lookup in tools_lib.php) on tiny
# projects with the real Godot binary: a script with two errors, a clean one, a Godot 3 project, export presets.   bash tests/godot_tools_test.sh
# SKIPPED when no Godot binary is installed (fetch it as docs/user_space_tools.md says).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; GT="$ROOT/cockpit_app/godot_tool"
G="${GODOT:-}"; [ -x "$G" ] || G="$(command -v godot 2>/dev/null)"; [ -x "$G" ] || G="$HOME/.local/share/cockpit/tools/godot/godot"
[ -x "$G" ] || { echo "godot_tools_test: no Godot binary - SKIPPED"; exit 0; }
export GODOT="$G"
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
P="$T/proj"; mkdir -p "$P/sub" "$P/addons/x"
printf 'config_version=5\n\n[application]\nconfig/name="T"\nrun/main_scene="res://main.tscn"\nconfig/features=PackedStringArray("4.7")\n' > "$P/project.godot"
printf 'extends Node\nfunc _ready():\n\tvar x: int = "text"\n\tprint(undefined_thing)\n' > "$P/bad.gd"
printf 'extends Node\nfunc _ready():\n\tprint("hello from main")\n' > "$P/sub/good.gd"
printf 'extends Node\nfunc _ready():\n\tvar q: int = "no"\n' > "$P/addons/x/skipped.gd"
printf '[gd_scene format=3]\n[ext_resource type="Script" path="res://sub/good.gd" id="1"]\n[node name="Main" type="Node"]\nscript = ExtResource("1")\n' > "$P/main.tscn"
# check: the whole project
bash "$GT" check "$P" "$T/c.txt"; [ $? = 0 ] && ok || bad "check exited non-zero"
has "bad.gd(3) Error: Cannot assign a value of type" "$T/c.txt" && has "bad.gd(4) Error: Identifier \"undefined_thing\" not declared" "$T/c.txt" && ok || bad "check: the two errors with their lines: $(cat "$T/c.txt")"
[ "$(grep -c '^bad.gd(3)' "$T/c.txt")" = 1 ] && ok || bad "check: line 3 reported twice"
has "2 script(s) checked, 1 with errors." "$T/c.txt" && has "[exit code 1]" "$T/c.txt" && ok || bad "check: summary/exit line"
grep -q "skipped.gd" "$T/c.txt" && bad "check looked inside addons/" || ok
grep -q "good.gd(" "$T/c.txt" && bad "check: the clean script was reported" || ok
# check: one clean file, then one bad file
bash "$GT" check "$P/sub/good.gd" "$T/g.txt"; has "1 script(s) checked, 0 with errors." "$T/g.txt" && has "[exit code 0]" "$T/g.txt" && ok || bad "check of a clean file: $(cat "$T/g.txt")"
bash "$GT" check "$P/bad.gd" "$T/b.txt"; has "[exit code 1]" "$T/b.txt" && ok || bad "check of a bad file"
bash "$GT" check "$P/sub" "$T/s.txt"; has "2 script(s) checked" "$T/s.txt" && ok || bad "a folder inside a project checks the whole project"
# the parser the build summary uses reads these lines (same regex as _pascalParseMessages)
[ "$(grep -cE '^(.+?)\([0-9]+(,[0-9]+)?\) (Error|Fatal|Warning|Hint|Note): ' "$T/c.txt")" = 2 ] && ok || bad "summary parser does not match the lines"
# nothing but .godot is written into the project
[ -z "$(cd "$P" && find . -newer "$P/project.godot" -type f -not -path './.godot/*' | head -1)" ] && ok || bad "check wrote into the project: $(cd "$P" && find . -newer project.godot -type f -not -path './.godot/*')"
# refusals
bash "$GT" check "$T" "$T/r.txt" 2>/dev/null; [ $? = 1 ] && has "no project.godot" "$T/r.txt" && ok || bad "a folder with no project was not refused"
bash "$GT" check "$P/main.tscn" "$T/r2.txt" 2>/dev/null; [ $? = 1 ] && ok || bad "a .tscn was not refused by check"
bash "$GT" check "$T/nope" "$T/r3.txt" 2>/dev/null; [ $? = 1 ] && ok || bad "a missing input was not refused"
bash "$GT" frob "$P" "$T/r4.txt" 2>/dev/null; [ $? = 1 ] && ok || bad "an unknown subcommand was not refused"
# run
bash "$GT" run "$P" "$T/r.run" 2; has "hello from main" "$T/r.run" && has "[exit code 0]" "$T/r.run" && ok || bad "run: $(cat "$T/r.run")"
# exports
bash "$GT" exports "$P" "$T/e.md"; has "No export_presets.cfg" "$T/e.md" && ok || bad "exports with none"
printf '[preset.0]\n\nname="Linux"\nplatform="Linux"\nexport_path="build/game.x86_64"\n\n[preset.1]\n\nname="Web"\nplatform="Web"\nexport_path=""\n' > "$P/export_presets.cfg"
bash "$GT" exports "$P" "$T/e2.md"; has "- Linux  (Linux)  ->  build/game.x86_64" "$T/e2.md" && has "- Web  (Web)  ->  no path set" "$T/e2.md" && ok || bad "exports list: $(cat "$T/e2.md")"
# version
bash "$GT" version "$P" "$T/v.md"; has "Godot 4.x" "$T/v.md" && has "is a Godot 4 project and so is the installed binary" "$T/v.md" && ok || bad "version (4): $(cat "$T/v.md")"
P3="$T/p3"; mkdir -p "$P3"; printf 'config_version=4\n[application]\nconfig/name="Old"\n' > "$P3/project.godot"
bash "$GT" version "$P3" "$T/v3.md"; has "Godot 3.x" "$T/v3.md" && has "NOT a Godot 4 project" "$T/v3.md" && ok || bad "version (3): $(cat "$T/v3.md")"
# the binary lookup: not on the PATH, found in the owner's home through paths.json (the web server's own HOME is not the owner's)
H="$T/home"; mkdir -p "$H/.local/share/cockpit/tools/godot"; ln -s "$G" "$H/.local/share/cockpit/tools/godot/godot"
W="$T/web"; mkdir -p "$W"; cp "$GT" "$W/godot_tool"; printf '{ "home": "%s" }\n' "$H" > "$W/paths.json"
( unset GODOT; PATH=/usr/bin:/bin HOME=/nonexistent bash "$W/godot_tool" version "$P" "$T/lk.md" ) ; has "Godot 4.x" "$T/lk.md" && ok || bad "binary lookup through paths.json: $(cat "$T/lk.md" 2>&1)"
( unset GODOT; PATH=/usr/bin:/bin HOME=/nonexistent bash "$GT" version "$P" "$T/nb.md" 2>/dev/null )
# resolve_binary finds it in user space too
if command -v php >/dev/null 2>&1; then
  r=$(PATH=/usr/bin:/bin php -r 'define("COCKPIT_OS","linux"); $PATHS=["home"=>$argv[1]]; require $argv[2]; echo resolve_binary(["id"=>"godot","binary"=>"godot"], ["tools"=>[]]);' "$H" "$ROOT/cockpit_app/tools_lib.php" 2>/dev/null)
  [ "$r" = "$H/.local/share/cockpit/tools/godot/godot" ] && ok || bad "resolve_binary user-space lookup gave '$r'"
fi
# the tool definition and the kind
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^bash \{WEBROOT\}/godot_tool (check|run|exports|version) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/godot.json" > "$T/pc" 2>&1; [ "$(cat "$T/pc")" = 4 ] && ok || bad "godot.json presets: $(cat "$T/pc")"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/game-godot.json")" = godot ] && ok || bad "the Godot kind does not name the tool"
echo "godot_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
