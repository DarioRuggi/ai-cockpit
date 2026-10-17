#!/usr/bin/env bash
# family_tools_test.sh — the Genealogy tools (cockpit_app/family_tool, tools_builtins/family.json, kinds/genealogy.json): check, duplicates, tree, report, CSV and GEDCOM, refusals.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; FT="$ROOT/cockpit_app/family_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "family_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > p.csv <<'CSV'
id,name,sex,born,died,father,mother,spouse,married,source
I1,Anna Rossi,F,12 Mar 1850,1920,,,I2,1870,Parish register
I2,Karl Weber,M,1845,1900,,,I1,1870,Census 1880
I3,Marie Weber,F,1872,1950,I2,I1,,,Birth certificate
I4,Jean Weber,M,1866,1930,I2,I1,,,Register
I5,Paul Dupont,M,1840,1860,,,I3,1869,Register
I6,Rossi Anna,F,1850,,,,,,Register
I7,Lena Dupont,F,1895,,I5,I3,,,Register
I8,Odd Child,M,1861,1899,I2,I9,,,Register
I9,Old Mum,F,ca 1800,1890,,,,,Register
I10,Kid Early,M,1860,,I4,,,,Register
I11,Dead First,F,1900,1890,,,,,Register
I12,Loop One,M,1900,,I13,,,,Register
I13,Loop Two,M,1880,,I12,,,,Register
I14,Ghost Child,M,1901,,I99,,,,
I15,Young Dad,M,1880,,,,,,Register
I16,Boy Dad,M,1888,,I15,,,,Register
CSV
before=$(md5sum p.csv)
php "$FT" check p.csv c.md >/dev/null; [ $? = 0 ] && ok || bad "check rc"
has "died (1890) before being born (1900)" c.md && ok || bad "death before birth: $(cat c.md)"
has "was born before their father Jean Weber [I4]" c.md && ok || bad "child born before parent"
has "Lena Dupont [I7] (born 1895) was born after their father Paul Dupont [I5] died (1860" c.md && ok || bad "born after father's death"
has "marriage of Paul Dupont [I5] and Marie Weber [I3] (1869) is before Marie Weber [I3] was born" c.md && ok || bad "marriage before a birth"
has "is after Paul Dupont [I5] died" c.md && ok || bad "marriage after a death"
has "Old Mum [I9] would have been over 50" c.md && ok || bad "mother too old"
has "Young Dad [I15] would have been under 15" c.md && ok || bad "father too young: $(grep -n 'Kid Early\|under 15' c.md)"
has 'names father "I99" who is not in the file' c.md && ok || bad "unknown parent id"
has "is their own ancestor" c.md && ok || bad "loop"
has "Ghost Child [I14] cites no source" c.md && ok || bad "missing source"
has "p.csv(2) Note" c.md || has "p.csv(15) Note" c.md && ok
php "$FT" check p.csv c2.md mother_max=70 >/dev/null; has "Old Mum [I9] would have been over" c2.md && bad "mother_max option ignored" || ok
php "$FT" duplicates p.csv d.md >/dev/null; has "Anna Rossi [I1]" d.md && has "Rossi Anna [I6]" d.md && has "overlapping birth dates" d.md && ok || bad "duplicates: $(cat d.md)"
php "$FT" tree p.csv t.md person=I1 >/dev/null; has "  - Marie Weber (1872-1950) [I3]" t.md && has "    - Lena Dupont (1895-) [I7]" t.md && has "{src: Register}" t.md && ok || bad "descendants: $(cat t.md)"
php "$FT" tree p.csv ta.md person=Lena dir=ancestors >/dev/null; has "- Lena Dupont" ta.md && has "    - Anna Rossi" ta.md && ok || bad "ancestors: $(cat ta.md)"
php "$FT" tree p.csv x.md person=Rossi >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an ambiguous name was not refused"
php "$FT" tree p.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "tree without person must exit 2"
php "$FT" tree p.csv x.md person=Nobody >/dev/null 2>&1; [ $? = 1 ] && ok || bad "unknown person not refused"
php "$FT" report p.csv r.md asof=2025-06-30 >/dev/null; has "- 03-12 birth: Anna Rossi [I1] (1850, 175 years)" r.md && has "would be 129, so probably died" r.md && ok || bad "report: $(head -30 r.md)"
php "$FT" report p.csv x.md asof=2025 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a partial asof was not refused"
# GEDCOM
cat > g.ged <<'GED'
0 HEAD
0 @I1@ INDI
1 NAME Ann /Smith/
1 BIRT
2 DATE 5 MAY 1900
1 SOUR @S1@
0 @I2@ INDI
1 NAME Bob /Smith/
1 BIRT
2 DATE 1925
0 @I3@ INDI
1 NAME Cy /Smith/
1 BIRT
2 DATE 1890
0 @S1@ SOUR
1 TITL Family Bible
0 @F1@ FAM
1 WIFE @I1@
1 CHIL @I2@
1 CHIL @I3@
1 MARR
2 DATE 1922
0 TRLR
GED
php "$FT" check g.ged gc.md >/dev/null; has "Cy Smith [I3] (born 1890) was born before their mother Ann Smith [I1]" gc.md && ok || bad "gedcom check: $(cat gc.md)"
php "$FT" tree g.ged gt.md person=I1 >/dev/null; has "  - Bob Smith (1925-) [I2]" gt.md && ok || bad "gedcom tree"; has "{src: Family Bible}" gt.md && ok || bad "gedcom source title"
# refusals, original untouched
php "$FT" check nope.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing file not refused"
: > e.csv; php "$FT" check e.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "empty file not refused"
php "$FT" frob p.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
[ "$(md5sum p.csv)" = "$before" ] && ok || bad "the original changed"
head -20 "$ROOT/cockpit_app/family_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no CLI guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/family_tool (check|duplicates|tree|report) \{INPUT\} \{OUTPUT\}~",$p["command"])) {echo "bad";exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/family.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "family.json: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $k=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/genealogy.json"),true); $e=""; $r=kind_validate($k,$e); exit($r&&$r["group"]==="Home & life"&&$r["tools"][0]["tool"]==="family"?0:1);' "$ROOT" >/dev/null 2>&1 && ok || bad "kind fails kind_validate"
echo "family_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
