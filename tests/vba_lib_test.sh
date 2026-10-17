#!/usr/bin/env bash
# vba_lib_test.sh — cockpit_app/vba_lib.php (the VBA container reader and writer): MS-OVBA compression, OLE2 compound files of every stream size, the VBA project,
# and — as an INDEPENDENT reader — LibreOffice: it must find our generated project and recover the exact source. There is no Office on the rig, so
# real Office files are tested by hand (see docs/kinds_tools_plan.md 10.4b).   bash tests/vba_lib_test.sh     SKIPPED without php; the LibreOffice part without soffice
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v php >/dev/null 2>&1 || { echo "vba_lib_test: php is needed - SKIPPED"; exit 0; }
php -m 2>/dev/null | grep -qi '^zip$' && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "vba_lib_test: php zip + mbstring are needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
# 1. the pure-PHP parts, in one PHP program that prints one "ok"/"FAIL ..." line per check
php "$ROOT/tests/vba_lib_checks.php" "$ROOT" > "$T/pure.txt" 2>&1
while IFS= read -r l; do case "$l" in ok*) ok ;; FAIL*) bad "${l#FAIL }" ;; *) bad "unexpected output: $l" ;; esac; done < "$T/pure.txt"
[ "$(grep -c '^ok' "$T/pure.txt")" -ge 15 ] && ok || bad "too few checks ran: $(grep -c '^ok' "$T/pure.txt")"
# 2. the fixture and LibreOffice as the independent reader
php "$ROOT/tests/macro_fixture.php" "$T/fx" >/dev/null 2>&1; [ -f "$T/fx/macro.xlsm" ] && [ -f "$T/fx/macro.docm" ] && ok || bad "fixture not written"
if command -v soffice >/dev/null 2>&1; then
  ( cd "$T/fx" && soffice --headless --convert-to ods --outdir lo macro.xlsm >/dev/null 2>&1; soffice --headless --convert-to odt --outdir lo macro.docm >/dev/null 2>&1 )
  for f in ods odt; do
    got=$(unzip -p "$T/fx/lo/macro.$f" Basic/VBAProject/Module1.xml 2>/dev/null | sed 's/&quot;/"/g')
    echo "$got" | grep -q 'Iva = importe \* 0.21' && echo "$got" | grep -q 'MsgBox "Hola desde la macro"' && ok || bad "LibreOffice did not recover the macro from the generated file (-> $f)"
    echo "$got" | grep -q "Cálculo del IVA: ¿cuánto es?" && ok || bad "the accents did not survive (-> $f)"
  done
  # what LibreOffice keeps and drops (documented behaviour of 24.2: re-check on a LibreOffice upgrade)
  ( cd "$T/fx" && soffice --headless --convert-to xlsx --outdir lo macro.xlsm >/dev/null 2>&1; soffice --headless --convert-to xls --outdir lo macro.xlsm >/dev/null 2>&1; soffice --headless --convert-to "xlsm:Calc MS Excel 2007 VBA XML" --outdir lo2 macro.xlsm >/dev/null 2>&1 )
  unzip -l "$T/fx/lo/macro.xlsx" 2>/dev/null | grep -qi vbaProject && bad "xlsx kept a macro (LibreOffice behaviour changed: update the plan)" || ok
  php -r 'require $argv[1]."/cockpit_app/vba_lib.php"; $m=vba_extract(file_get_contents($argv[2])); exit(is_array($m)&&count($m)==1?0:1);' "$ROOT" "$T/fx/lo/macro.xls" && ok || bad "xlsm -> xls lost the VBA (LibreOffice behaviour changed)"
  z=$(cd "$T/fx/lo2" && unzip -p macro.xlsm xl/vbaProject.bin 2>/dev/null | wc -c); [ "$z" -gt 100 ] && ok || bad "xlsm -> xlsm lost the VBA"
else echo "  (soffice missing: the LibreOffice checks were skipped)"; fi
# 3. never reachable over the web
head -12 "$ROOT/cockpit_app/vba_lib.php" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "vba_lib.php has no command-line-only guard"
echo "vba_lib_test: $n passed, $fails failed"; [ "$fails" = 0 ]
