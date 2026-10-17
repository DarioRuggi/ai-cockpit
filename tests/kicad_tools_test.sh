#!/usr/bin/env bash
# kicad_tools_test.sh — cockpit_app/kicad_tool on hand-made KiCad 7 files (tests/kicad_fixture.php); exports need the real kicad-cli.   bash tests/kicad_tools_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; K="$ROOT/cockpit_app/kicad_tool"
command -v php >/dev/null 2>&1 || { echo "kicad_tools_test: php is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1; php "$ROOT/tests/kicad_fixture.php" . >/dev/null
php "$K" check good.kicad_sch a.md >/dev/null; has "No problems found." a.md && has "Symbols (parts): 3 placed" a.md && has "[exit code 0]" a.md && ok || bad "good schematic: $(sed -n 3,12p a.md)"
php "$K" check bad.kicad_sch b.md >/dev/null; has "Error: the reference R1 is used twice" b.md && has "is not annotated" b.md && has "R? has no value" b.md && has "has no footprint assigned" b.md && has "'LONELY' appears only once" b.md && has "[exit code 1]" b.md && ok || bad "bad schematic: $(grep -E 'Error|Warning|Note' b.md)"
php "$K" check good.kicad_pcb c.md >/dev/null; has "No problems found." c.md && has "Board outline: 1 Edge.Cuts item(s), 40 x 30 mm" c.md && ok || bad "good board: $(sed -n 3,12p c.md)"
php "$K" check bad.kicad_pcb d.md >/dev/null; has "the board has no outline" d.md && has "a track only 0.1 mm wide" d.md && has "a via with a 0.15 mm drill" d.md && has "used twice" d.md && ok || bad "bad board: $(grep -E 'Error|Warning' d.md)"
php "$K" check outside.kicad_pcb e.md >/dev/null; has "R2 (at 90, 90) is outside the board outline" e.md && ok || bad "outside footprint"
[ "$(grep -cE '^[^ ]+\([0-9]+\) (Error|Warning|Note): ' b.md)" -ge 6 ] && ok || bad "summary-box lines"
php "$K" check broken.kicad_sch x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a broken file must be refused"
php "$K" check nope.kicad_sch x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file must be refused"
php "$K" check good.kicad_pcb x.md >/dev/null; php "$K" frob good.kicad_pcb x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
php "$K" info good.kicad_pcb i.md >/dev/null; has "Footprints: 2" i.md && ok || bad "info"
php "$K" bom good.kicad_sch bom.csv >/dev/null; has '"R1, R2",2,10k,Resistor_SMD:R_0805_2012Metric' bom.csv && grep -q '^R3,1,4k7' bom.csv && ok || bad "bom: $(cat bom.csv)"
if command -v kicad-cli >/dev/null 2>&1; then
  php "$K" pdf good.kicad_sch o.pdf >/dev/null; head -c 4 o.pdf | grep -q '%PDF' && ok || bad "pdf"
  php "$K" netlist good.kicad_sch o.net >/dev/null; [ -s o.net ] && grep -q "R1" o.net && ok || bad "netlist"
  php "$K" gerbers good.kicad_pcb g.zip >/dev/null; unzip -l g.zip 2>/dev/null | grep -qi "Edge_Cuts\|gm1" && unzip -l g.zip | grep -qi "drl" && ok || bad "gerbers zip: $(unzip -l g.zip 2>&1 | tail -8)"
  php "$K" pos good.kicad_pcb p.csv >/dev/null; grep -q "R1" p.csv && ok || bad "pos"
  php "$K" pdf good.kicad_pcb x.pdf >/dev/null 2>&1; head -c 4 x.pdf | grep -q "%PDF" && ok || bad "pdf of a board"
  ls /tmp | grep -q '^kicad_' && bad "scratch left in /tmp" || ok
else echo "  (kicad-cli missing: exports skipped)"; fi
head -20 "$K" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
[ "$(jq '.presets|length' "$ROOT/cockpit_app/tools_builtins/kicad.json")" = 7 ] && ok || bad "kicad.json presets"
echo "kicad_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
