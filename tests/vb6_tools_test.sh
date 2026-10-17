#!/usr/bin/env bash
# vb6_tools_test.sh — the VB6 migration tools (cockpit_app/vb_tool, vb_encoding.php, vb6_cheatsheet.md, tools_builtins/vb6.json) on a small project
# written in the real code pages (Spanish in Windows-1252, Hebrew in Windows-1255): detection, UTF-8 copies that read right, the originals untouched,
# the round trip, a tampered copy caught, the inventory and its port order, the cheat sheet.   bash tests/vb6_tools_test.sh   SKIPPED without php.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; VT="$ROOT/cockpit_app/vb_tool"
command -v php >/dev/null 2>&1 || { echo "vb6_tools_test: php is needed - SKIPPED"; exit 0; }
php -m 2>/dev/null | grep -qi '^iconv$' && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "vb6_tools_test: php iconv + mbstring are needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
php "$ROOT/tests/vb6_fixture.php" "$T/proj"
before=$(cd "$T/proj" && find . -type f | sort | xargs md5sum | md5sum)
has() { grep -qF -- "$1" "$2"; }
# detect
php "$VT" detect "$T/proj" "$T/det.md" >/dev/null; [ $? = 0 ] && ok || bad "detect failed"
has "4 text files: ascii 2, windows-1252 1, windows-1255 1" "$T/det.md" && ok || bad "detect counts: $(sed -n 3p "$T/det.md")"
grep -E '^\| frmPrincipal.frm' "$T/det.md" | grep -q 'windows-1255' && grep -E '^\| modUtil.bas' "$T/det.md" | grep -q 'windows-1252' && ok || bad "detect encodings"
[ ! -d "$T/proj_utf8" ] && ok || bad "detect wrote a copy"
# convert
php "$VT" to-utf8 "$T/proj" "$T/conv.md" >/dev/null; [ $? = 0 ] && [ -d "$T/proj_utf8" ] && ok || bad "to-utf8 failed"
grep -q "שלום - מלאי" "$T/proj_utf8/frmPrincipal.frm" && grep -q "אישור" "$T/proj_utf8/frmPrincipal.frm" && ok || bad "the Hebrew did not survive into UTF-8"
grep -q "Año" "$T/proj_utf8/modUtil.bas" && grep -q "¿cómo estás?" "$T/proj_utf8/modUtil.bas" && ok || bad "the Spanish did not survive into UTF-8"
cmp -s "$T/proj/frmPrincipal.frx" "$T/proj_utf8/frmPrincipal.frx" && ok || bad "the .frx binary was not copied unchanged"
after=$(cd "$T/proj" && find . -type f | sort | xargs md5sum | md5sum); [ "$before" = "$after" ] && ok || bad "an ORIGINAL file changed"
[ "$(ls "$T/proj" | wc -l)" = 5 ] && ok || bad "something was written into the original folder"
php "$VT" to-utf8 "$T/proj" "$T/conv2.md" >/dev/null 2>"$T/err"; [ $? = 1 ] && grep -q "already exists" "$T/err" && ok || bad "a second conversion was not refused"
# verify
php "$VT" verify "$T/proj" "$T/ver.md" >/dev/null; has "**4 files identical**, 0 differ" "$T/ver.md" && has "Nothing was lost" "$T/ver.md" && ok || bad "verify: $(sed -n 3,5p "$T/ver.md")"
sed -i 's/שלום - מלאי/שלום - מלאי!/' "$T/proj_utf8/frmPrincipal.frm"
php "$VT" verify "$T/proj" "$T/ver2.md" >/dev/null; has "3 files identical" "$T/ver2.md" && grep -q '^| frmPrincipal.frm | windows-1255 |' "$T/ver2.md" && ok || bad "a tampered copy was not caught: $(sed -n 3,8p "$T/ver2.md")"
rm -rf "$T/proj_utf8"; php "$VT" verify "$T/proj" "$T/ver3.md" >/dev/null 2>"$T/err"; [ $? = 1 ] && grep -q "run \"Convert" "$T/err" && ok || bad "verify without a copy must say what to do"
# inventory
php "$VT" inventory "$T/proj" "$T/inv.md" >/dev/null; [ $? = 0 ] && ok || bad "inventory failed"
for want in "3 source files (1 forms, 1 modules, 1 classes), 1 .frx/.ctx binaries" "- Startup: \"frmPrincipal\"" "- reference: Microsoft ActiveX Data Objects 6.1 Library (msado15.dll, version 6.1)" "- OCX control: MSCOMCTL.OCX" '- `kernel32`: GetTickCount' "| TextBox | 1 | TEdit / TMemo |" "| MSComctlLib.ListView | 1 | look it up (a third-party control) |" "On Error Resume Next" "16-bit Integer" "database objects x2" "OCX MSComctlLib.ListView" "Hebrew / right-to-left"; do has "$want" "$T/inv.md" && ok || bad "inventory lacks: $want"; done
a=$(grep -n '^| [0-9] | modUtil.bas' "$T/inv.md" | cut -d: -f1); b=$(grep -n '^| [0-9] | Cliente.cls' "$T/inv.md" | cut -d: -f1); c=$(grep -n '^| [0-9] | frmPrincipal.frm' "$T/inv.md" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok || bad "the port order is not modules, classes, forms: $a $b $c"
# cheat sheet, and bad input
php "$VT" cheatsheet "$T/proj" "$T/cs.md" >/dev/null; has "# VB6 → Free Pascal / Lazarus cheat sheet" "$T/cs.md" && has 'InStr(s, t)' "$T/cs.md" && has "VB6 True = -1" "$T/cs.md" && ok || bad "cheat sheet"
mkdir -p "$T/empty"; php "$VT" inventory "$T/empty" "$T/x.md" >/dev/null 2>"$T/err"; [ $? = 1 ] && grep -q "no VB6 text files" "$T/err" && ok || bad "a folder without VB6 files must fail clearly"
php "$VT" detect "$T/nofolder" "$T/x.md" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing folder must fail"
php "$ROOT/cockpit_app/vb_encoding.php" scan "$T/proj" >/dev/null 2>&1; [ $? = 0 ] && ok || bad "vb_encoding.php no longer works as a program"
# the tool definition
jq -e '.id=="vb6" and .binary=="php" and ([.presets[]|.id and .label and .command and .output_ext and .timeout_seconds]|all) and ([.presets[].id]|sort)==["cheatsheet","encoding-detect","inventory","to-utf8","verify"]' "$ROOT/cockpit_app/tools_builtins/vb6.json" >/dev/null 2>&1 && ok || bad "vb6.json is incomplete (needs jq)"
echo "vb6_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
