#!/usr/bin/env bash
# tools_pascal_test.sh — the Free Pascal / Lazarus tool presets (cockpit_app/tools_builtins/fpc.json, lazarus.json): every preset's own command,
# the way tools.php builds it ({INPUT} and {OUTPUT} filled with quoted paths), run against a good and a broken source. The messages must be
# kept, with file and line, ending in "[exit code N]", the run must report success to the tool runner (exit 0) and leave nothing behind.
#   bash tests/tools_pascal_test.sh      SKIPPED without fpc, lazbuild and jq.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TB="$ROOT/cockpit_app/tools_builtins"
for c in fpc lazbuild jq; do command -v $c >/dev/null 2>&1 || { echo "tools_pascal_test: $c is needed - SKIPPED"; exit 0; }; done
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
cat > "$T/good.pas" <<'P'
program good;
begin
  WriteLn('hello');
end.
P
cat > "$T/broken.pas" <<'P'
program broken;
var n: Integer;
begin
  n := 'text';
  UndefinedThing(3);
end.
P
# a minimal Lazarus project around each source
mklpi() {   # mklpi NAME SOURCE
cat > "$T/$1.lpi" <<LPI
<?xml version="1.0" encoding="UTF-8"?>
<CONFIG>
  <ProjectOptions>
    <Version Value="12"/>
    <General><Flags><MainUnitHasCreateFormStatements Value="False"/><MainUnitHasTitleStatement Value="False"/><MainUnitHasScaledStatement Value="False"/></Flags><SessionStorage Value="InProjectDir"/><Title Value="$1"/><UseAppBundle Value="False"/><ResourceType Value="res"/></General>
    <BuildModes><Item Name="Default" Default="True"/></BuildModes>
    <PublishOptions><Version Value="2"/></PublishOptions>
    <RunParams><FormatVersion Value="2"/></RunParams>
    <Units><Unit><Filename Value="$2"/><IsPartOfProject Value="True"/></Unit></Units>
  </ProjectOptions>
  <CompilerOptions><Version Value="11"/><Target><Filename Value="$1"/></Target><SearchPaths><UnitOutputDirectory Value="lib/\$(TargetCPU)-\$(TargetOS)"/></SearchPaths></CompilerOptions>
</CONFIG>
LPI
}
cp "$T/good.pas" "$T/lgood.lpr"; sed -i 's/program good/program lgood/' "$T/lgood.lpr"; mklpi lgood lgood.lpr
cp "$T/broken.pas" "$T/lbroken.lpr"; sed -i 's/program broken/program lbroken/' "$T/lbroken.lpr"; mklpi lbroken lbroken.lpr

# run NAME PRESETFILE PRESETID INPUT  -> output text in $T/out.txt, exit code in $RC
run() {
    local tpl; tpl=$(jq -r --arg id "$3" '.presets[]|select(.id==$id)|.command' "$TB/$2.json")
    [ -n "$tpl" ] && [ "$tpl" != null ] || { bad "$1: no such preset"; return 1; }
    local inq outq; printf -v inq '%q' "$4"; printf -v outq '%q' "$T/out.txt"
    local cmd="${tpl//\{INPUT\}/$inq}"; cmd="${cmd//\{OUTPUT\}/$outq}"; cmd="${cmd//\{WEBROOT\}/$(printf '%q' "$ROOT/cockpit_app")}"; cmd="${cmd//\{ARGS\}/${ARGS:-}}"
    rm -f "$T/out.txt"; ( cd "$T" && eval "$cmd" ) >/dev/null 2>&1; RC=$?
}
before=$(ls "$T" | sort | tr '\n' ' ')
for p in check compile; do
  run "fpc $p good" fpc $p "$T/good.pas"; [ $RC = 0 ] && grep -q '^\[exit code 0\]$' "$T/out.txt" && ok || bad "fpc $p good: rc=$RC $(tail -2 "$T/out.txt" 2>/dev/null)"
  run "fpc $p broken" fpc $p "$T/broken.pas"; [ $RC = 0 ] && grep -q 'broken.pas(4,[0-9]*) Error' "$T/out.txt" && grep -q 'broken.pas(5,[0-9]*) Error' "$T/out.txt" && grep -q '^\[exit code [1-9]' "$T/out.txt" && ok || bad "fpc $p broken: rc=$RC $(cat "$T/out.txt" 2>/dev/null | tail -4)"
done
for p in build build-quiet rebuild; do
  run "lazarus $p good" lazarus $p "$T/lgood.lpi"; [ $RC = 0 ] && grep -q '^\[exit code 0\]$' "$T/out.txt" && ok || bad "lazarus $p good: rc=$RC $(tail -3 "$T/out.txt" 2>/dev/null)"
  run "lazarus $p broken" lazarus $p "$T/lbroken.lpi"; [ $RC = 0 ] && grep -q 'lbroken.lpr(4,[0-9]*) Error' "$T/out.txt" && grep -q '^\[exit code [1-9]' "$T/out.txt" && ok || bad "lazarus $p broken: rc=$RC $(tail -4 "$T/out.txt" 2>/dev/null)"
done
# fpc leaves nothing beside the source (units/objects go to a scratch folder)
run "fpc leftovers" fpc compile "$T/good.pas"
extra=$(ls "$T" | grep -E '\.(o|ppu|s|a)$|^good$' | tr '\n' ' '); [ -z "$extra" ] && ok || bad "fpc left files beside the source: $extra"
# the scaffolds (new-console, new-gui, new-unit): files written, nothing overwritten, bad names refused, and what they write builds
S="$T/scaf"; mkdir -p "$S"
ARGS="demo1"; run "new-console" lazarus new-console "$S"; [ $RC = 0 ] && [ -f "$S/demo1.lpr" ] && [ -f "$S/demo1.lpi" ] && ok || bad "new-console: rc=$RC $(cat "$T/out.txt")"
run "new-console again" lazarus new-console "$S"; [ $RC != 0 ] && grep -q "nothing written" "$T/out.txt" && ok || bad "new-console overwrote or did not refuse: rc=$RC"
run "build the console scaffold" lazarus build "$S/demo1.lpi"; [ $RC = 0 ] && grep -q '^\[exit code 0\]$' "$T/out.txt" && ok || bad "the console scaffold does not build: $(tail -5 "$T/out.txt")"
ARGS="Calc"; run "new-unit" lazarus new-unit "$S"; [ $RC = 0 ] && [ -f "$S/Calc.pas" ] && ok || bad "new-unit: rc=$RC"
run "check the unit" fpc check "$S/Calc.pas"; [ $RC = 0 ] && grep -q '^\[exit code 0\]$' "$T/out.txt" && ok || bad "the unit scaffold does not compile: $(tail -5 "$T/out.txt")"
ARGS="Gui1"; run "new-gui" lazarus new-gui "$S"; [ $RC = 0 ] && [ -f "$S/Gui1.lpi" ] && [ -f "$S/unit1.pas" ] && [ -f "$S/unit1.lfm" ] && ok || bad "new-gui: rc=$RC $(cat "$T/out.txt")"
run "build the form application" lazarus build "$S/Gui1.lpi"; [ $RC = 0 ] && grep -q '^\[exit code 0\]$' "$T/out.txt" && ok || bad "the form application does not build: $(tail -8 "$T/out.txt")"
for badname in "../x" "1abc" "a-b" ""; do ARGS="$badname"; mkdir -p "$T/s2"; run "bad name [$badname]" lazarus new-console "$T/s2"; if [ -n "$badname" ]; then [ $RC != 0 ] && [ -z "$(ls "$T/s2")" ] && ok || bad "name [$badname] was accepted"; fi; done
ARGS=""
# every preset of the two tools has what tools.php needs
for f in fpc lazarus; do
  jq -e '.id and .binary and (.presets|length>0) and ([.presets[]|.id and .label and .command and .output_ext and .timeout_seconds]|all)' "$TB/$f.json" >/dev/null && ok || bad "$f.json is missing fields"
done
echo "tools_pascal_test: $n passed, $fails failed"; [ "$fails" = 0 ]
