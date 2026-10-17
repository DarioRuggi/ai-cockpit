#!/usr/bin/env bash
# office_tools_test.sh — the Document formats tools (cockpit_app/office_tool, lo_lib.php, vba_lib.php, tools_builtins/office.json, kinds/document-formats.json): the
# macro safeguard (a conversion that would lose VBA is REFUSED), macros listed/extracted/injected, inspect, verify, kind-of-document refusals, nothing left behind.
# Macro-carrying files are made by tests/macro_fixture.php (our own writer, validated by LibreOffice: no Office on the rig).
#   bash tests/office_tools_test.sh     SKIPPED without php (zip, dom, mbstring) or LibreOffice
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; OT="$ROOT/cockpit_app/office_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^zip$' && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "office_tools_test: php with zip + mbstring is needed - SKIPPED"; exit 0; }
command -v soffice >/dev/null 2>&1 || { echo "office_tools_test: LibreOffice (soffice) is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
php "$ROOT/tests/macro_fixture.php" fx >/dev/null; [ -f fx/macro.xlsm ] && [ -f fx/macro.docm ] && ok || bad "fixture not written"
cp fx/macro.xlsm fx/macro.docm . ; sum0=$(md5sum macro.xlsm macro.docm | md5sum)
# macros: listed, never run
php "$OT" macros macro.xlsm m.md >/dev/null; has "Module1" m.md && has "auto_open" m.md && has "CreateObject" m.md && has "VBA (Microsoft)" m.md && ok || bad "macros report: $(sed -n 5,9p m.md)"
printf 'a,b\n1,2\n' > plain.csv; php "$OT" macros plain.csv m2.md >/dev/null; has "No macros found." m2.md && ok || bad "a file with no macros"
php "$OT" extract macro.xlsm e.bas >/dev/null; has "Module: Module1" e.bas && has "Cálculo del IVA: ¿cuánto es?" e.bas && has "Public Function Iva" e.bas && ok || bad "extract (UTF-8 accents): $(head -8 e.bas)"
php "$OT" extract plain.csv e2.bas >/dev/null 2>&1; [ $? = 1 ] && ok || bad "extract of a file with no macros must fail"
# the safeguard: refused conversions write NOTHING
for pair in "macro.xlsm x.xlsx" "macro.docm x.doc" "macro.docm x.docx"; do set -- $pair; rm -f "$2"; php "$OT" convert "$1" "$2" >/dev/null 2>r.err; rc=$?; [ $rc = 1 ] && [ ! -f "$2" ] && grep -q "REFUSED" r.err && ok || bad "$1 -> $2 must be refused with nothing written (rc=$rc): $(head -c 160 r.err)"; done
grep -q "drop-macros" r.err && ok || bad "the refusal does not say how to override it"
# the conversions that keep the macros
for pair in "macro.xlsm x.xls" "macro.xlsm x.ods" "macro.docm x.odt"; do set -- $pair; rm -f "$2"; out=$(php "$OT" convert "$1" "$2" 2>&1); [ -f "$2" ] && echo "$out" | grep -q "MACROS:" && ok || bad "$1 -> $2 should convert and report the macros: $out"; done
php "$OT" macros x.xls xm.md >/dev/null; has "Module1" xm.md && ok || bad "the .xls lost the VBA"
php "$OT" macros x.ods om.md >/dev/null; has "Module1" om.md && has "basic" om.md && ok || bad "the .ods has no Basic module"
# drop-macros: allowed only when asked
out=$(php "$OT" convert macro.xlsm d.xlsx drop-macros 2>&1); [ -f d.xlsx ] && echo "$out" | grep -q "NONE (dropped, as you asked)" && ok || bad "drop-macros: $out"
php "$OT" macros d.xlsx dm.md >/dev/null; has "No macros found." dm.md && ok || bad "d.xlsx should have no macros"
# kinds of document
php "$OT" convert macro.docm bad.xlsx >/dev/null 2>r.err; [ $? = 1 ] && grep -q "cannot become a spreadsheet" r.err && ok || bad "document -> spreadsheet must be refused"
php "$OT" convert plain.csv p.docx >/dev/null 2>r.err; [ $? = 1 ] && ok || bad "spreadsheet -> document must be refused"
php "$OT" convert plain.csv p.xyz >/dev/null 2>r.err; [ $? = 1 ] && ok || bad "an unknown output format must be refused"
echo hi > a.zzz; php "$OT" convert a.zzz a.pdf >/dev/null 2>r.err; [ $? = 1 ] && ok || bad "an unreadable kind of file must be refused"
# plain conversions with no macros, text and values survive
printf 'name,qty,price\nfoo,2,1.5\nbar,3,2.25\n' > s.csv
php "$OT" convert s.csv s.xlsx >/dev/null && php "$OT" convert s.xlsx s2.ods >/dev/null && php "$OT" convert s2.ods s3.csv >/dev/null; [ "$(tr -d '"' < s3.csv | tr -d '\r')" = "$(cat s.csv)" ] && ok || bad "csv -> xlsx -> ods -> csv changed the values: $(cat s3.csv 2>/dev/null)"
if command -v ssconvert >/dev/null 2>&1; then php "$OT" convert s.csv s.gnumeric >/dev/null 2>&1 && [ -f s.gnumeric ] && php "$OT" convert s.gnumeric sg.xlsx >/dev/null 2>&1 && [ -f sg.xlsx ] && ok || bad "csv -> gnumeric -> xlsx"; fi
if command -v pandoc >/dev/null 2>&1; then
  printf '# Título\n\nHola **mundo** שלום\n\n| a | b |\n|---|---|\n| 1 | 2 |\n' > t.md; pandoc t.md -o t.docx
  php "$OT" convert t.docx t.odt >/dev/null && php "$OT" convert t.odt t.rtf >/dev/null && php "$OT" convert t.rtf t2.docx >/dev/null && php "$OT" convert t2.docx t.txt >/dev/null; grep -q "שלום" t.txt && grep -q "Título" t.txt && ok || bad "docx -> odt -> rtf -> docx -> txt lost the Hebrew or the accents: $(head -3 t.txt)"
  php "$OT" convert t.docx t.pdf >/dev/null; head -c 4 t.pdf | grep -q '%PDF' && ok || bad "docx -> pdf"
  php "$OT" inspect t.docx i.md >/dev/null; has "| Tables | 1 |" i.md && has "Macros: none" i.md && ok || bad "inspect of a docx: $(sed -n 5,12p i.md)"
  php "$OT" convert t.docx t.doc >/dev/null; php "$OT" inspect t.doc il.md >/dev/null; has "Older format" il.md && has "| Tables |" il.md && ok || bad "inspect of a legacy .doc: $(head -8 il.md)"
fi
# inspect an xlsm
php "$OT" inspect macro.xlsm im.md >/dev/null; has "| Formulas | 1 |" im.md && has "Macros: 1 module(s), VBA: Module1" im.md && has "At risk in a conversion" im.md && ok || bad "inspect xlsm: $(cat im.md | head -30)"
# inject (ODF): a new module, never replacing one, and LibreOffice must open it
printf 'Function Doble(x As Double) As Double\n  Doble = x * 2\nEnd Function\n' > doble.bas
php "$OT" inject x.ods inj.ods doble.bas >/dev/null; php "$OT" macros inj.ods ij.md >/dev/null; has "doble" ij.md && has "Module1" ij.md && ok || bad "inject: the new module or the old one is missing: $(sed -n 5,10p ij.md)"
php "$OT" inject inj.ods inj2.ods doble.bas >/dev/null; php "$OT" macros inj2.ods ij2.md >/dev/null; has "doble2" ij2.md && ok || bad "a second injection must get a new name, not replace"
soffice --headless --convert-to csv --outdir lo inj2.ods >/dev/null 2>&1; [ -s lo/inj2.csv ] && ok || bad "LibreOffice cannot open the injected file"
php "$OT" inject s.xlsx bad.xlsx doble.bas >/dev/null 2>&1; [ $? = 1 ] && ok || bad "inject into an .xlsx must be refused"
printf 'Sub Auto_Open()\n MsgBox "x"\nEnd Sub\n' > v.bas; php "$OT" inject x.ods injv.ods v.bas >/dev/null; unzip -p injv.ods Basic/Standard/v.xml | grep -q "Option VBASupport 1" && ok || bad "VBA-looking source did not get Option VBASupport 1"
# verify: round trips
if command -v pandoc >/dev/null 2>&1; then php "$OT" verify t.docx v1.md odt >/dev/null; has "**identical**" v1.md && has "[exit code 0]" v1.md && ok || bad "docx -> odt -> docx must be identical: $(cat v1.md | head -12)"; fi
php "$OT" verify s.xlsx v2.md ods >/dev/null; has "**identical**" v2.md && ok || bad "xlsx -> ods -> xlsx cells: $(cat v2.md | head -10)"
php "$OT" verify macro.xlsm v3.md ods >/dev/null; has "**LOST**" v3.md && has "[exit code 1]" v3.md && ok || bad "xlsm -> ods -> xlsm must report the macros LOST: $(cat v3.md | head -12)"
php "$OT" verify macro.xlsm v4.md xls >/dev/null; has "[exit code 0]" v4.md && ok || bad "xlsm -> xls -> xlsm keeps the VBA: $(cat v4.md | head -12)"
# the originals, no leftovers, the web guard, the definitions
[ "$(md5sum macro.xlsm macro.docm | md5sum)" = "$sum0" ] && ok || bad "an original changed"
ls -d /tmp/lo_* /tmp/office_* 2>/dev/null | grep -q . && bad "a scratch file or folder was left in /tmp: $(ls -d /tmp/lo_* /tmp/office_* 2>/dev/null | head -3)" || ok
head -20 "$ROOT/cockpit_app/office_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/office_tool (convert|macros|extract|inject|inspect|verify) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/office.json" > pc 2>&1; [ "$(cat pc)" = 22 ] && ok || bad "office.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/document-formats.json")" = office ] && ok || bad "the kind does not name the tool"
echo "office_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
