#!/usr/bin/env bash
# collect_tools_test.sh — the Collections tools (cockpit_app/collect_tool, tools_builtins/collect.json, kinds/collections.json): check, want-list, summary, valuation, refusals.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CT="$ROOT/cockpit_app/collect_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "collect_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > c.csv <<'CSV'
title,year,catalogue_number,category,condition,value,quantity
The Blue Penny,1901,A-1,Stamps,Mint,"1,200.50",1
blue penny,1901,A-9,Stamps,mint,100,1
Red Mail,1950,B-2,Stamps,Used,15,3
Old Coin,abc,C-3,Coins,Fine,,1
,1980,A-1,Coins,,40,1
Grey Card,1999,D-4,Cards,Fine,12.5,2
CSV
cat > w.csv <<'CSV'
title,year,catalogue_number
Blue Penny,1901,
Red Mail,1950,B-2
Green Leaf,1960,G-7
Grey Card,1999,
CSV
before=$(md5sum c.csv w.csv)
php "$CT" check c.csv k.md >/dev/null; [ $? = 0 ] && ok || bad "check rc"
has 'c.csv(5) Error: year "abc"' k.md && ok || bad "bad year: $(cat k.md)"
has 'c.csv(6) Warning: missing title' k.md && ok || bad "missing title"
has 'possible duplicate of line 2' k.md && ok || bad "duplicate by title+year ('The' ignored, case ignored)"
has 'catalogue number "A-1" already used on line 2' k.md && ok || bad "duplicate catalogue number"
has 'inconsistent condition spelling: "Mint" / "mint"' k.md && ok || bad "condition spelling"
php "$CT" wanted c.csv wl.md with=w.csv >/dev/null; has "## You have (3 of 4)" wl.md && has "Green Leaf (1960) #G-7" wl.md && ok || bad "wanted: $(cat wl.md)"
has "Red Mail (1950) #B-2 (catalogue line 4; 3 copies)" wl.md && has "## You hold more than once (3)" wl.md && ok || bad "wanted copies"
php "$CT" wanted c.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "wanted without with= must exit 2"
php "$CT" summary c.csv s.md >/dev/null; has "| Stamps | 5 |" s.md && has "| 1950s | 3 |" s.md && has "| Fine | 3 |" s.md && ok || bad "summary: $(cat s.md)"
php "$CT" valuation c.csv v.md >/dev/null; has "| Stamps |" v.md && has "**1,410.50**" v.md && ok || bad "valuation total: $(cat v.md)"
has "line 5: Old Coin" v.md && has "Nothing has been looked up or estimated" v.md && ok || bad "unvalued row listed"
printf 'title,year\nA,1900\n' > nov.csv; php "$CT" valuation nov.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "valuation without a value column was not refused"
php "$CT" check nope.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing file not refused"
: > e.csv; php "$CT" check e.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "empty file not refused"
php "$CT" frob c.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
[ "$(md5sum c.csv w.csv)" = "$before" ] && ok || bad "an original changed"
head -20 "$ROOT/cockpit_app/collect_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no CLI guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/collect_tool (check|wanted|summary|valuation) \{INPUT\} \{OUTPUT\}~",$p["command"])) {echo "bad";exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/collect.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "collect.json: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $k=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/collections.json"),true); $e=""; $r=kind_validate($k,$e); exit($r&&$r["group"]==="Home & life"&&$r["tools"][0]["tool"]==="collect"?0:1);' "$ROOT" >/dev/null 2>&1 && ok || bad "kind fails kind_validate"
echo "collect_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
