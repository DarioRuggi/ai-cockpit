#!/usr/bin/env bash
# craft_tools_test.sh — the Hobby crafts tools (cockpit_app/craft_tool, tools_builtins/craft.json, kinds/hobby-crafts.json): cut list, yarn, fabric, pattern rows, materials, refusals.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CT="$ROOT/cockpit_app/craft_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "craft_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
printf 'name,length,qty,material\nRail,36 1/2,4,Pine\nLeg,720,4,Pine\nShelf,600,3,Pine\nTrim,3/4,2,Oak\nTooLong,3000,1,Pine\n' > parts.csv
printf 'name,length,qty\nA,1000,2\nB,1000,1\nC,400,1\n' > p2.csv
printf 'name,width,height,qty\nFront,50,60,1\nSleeve,20,45,2\n' > pc.csv
printf 'item,qty,unit,unit cost,supplier,have\nWool,5,skein,4.50,ShopA,2\nButtons,6,pcs,0.30,ShopB,0\nNeedle,1,pc,,ShopA,0\n' > m.csv
cat > pat.md <<'MD'
# Scarf
Row 1: (k2, p2) x 6 (24 sts)
Row 2: (p2, k2) x 6 (24 sts)
Rows 3-4: *k2, p2; rep from * 6 times (24 sts)
Row 5: k2tog, k22 (24 sts)
Row 7: k to end
Repeat rows 1-4 x 5
Repeat rows 1-9 x 2
MD
printf 'Row 1: k24 (24 sts)\nRow 2: p24 (24 sts)\nRow 3: k2tog, k22 (23 sts)\nRow 4: p23 (23 sts)\nRepeat rows 1-4 3 times\n' > good.md
before=$(md5sum parts.csv p2.csv pc.csv m.csv pat.md)
# cutlist
php "$CT" cutlist p2.csv c.md stock=2400 kerf=3 >/dev/null; [ $? = 0 ] && ok || bad "cutlist rc"
php "$CT" cutlist p2.csv c1.md stock=2400 kerf=3 >/dev/null
has "Board 1: 1,000 (A) + 1,000 (A) | used 2,003, offcut 397" c1.md && has "Board 2: 1,000 (B) + 400 (C) | used 1,403, offcut 997" c1.md && ok || bad "FFD with kerf: $(cat c1.md)"
php "$CT" cutlist p2.csv c2.md stock=2400 kerf=0 >/dev/null; has "Board 1: 1,000 (A) + 1,000 (A) + 400 (C) | used 2,400, offcut 0" c2.md && ok || bad "exact fit without kerf"
php "$CT" cutlist p2.csv c3.md stock=2400 kerf=3 boards=1 >/dev/null; has "did not fit in the 1 board(s) allowed" c3.md && ok || bad "boards limit"
php "$CT" cutlist parts.csv c4.md stock=2400 kerf=3 >/dev/null; has "## Material: Oak" c4.md && has "0.75 (Trim)" c4.md && has "36.5 (Rail)" c4.md && has "longer than the stock length" c4.md && ok || bad "materials, fractions, too-long part: $(cat c4.md)"
php "$CT" cutlist p2.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "cutlist without stock must exit 2"
# yarn
php "$CT" yarn pc.csv y.md swatch=10x10 swatch_yarn=18 swatch_g=25 skein=100 skein_g=50 >/dev/null; has "Total area 4,800 cm2" y.md && has "864 m of yarn" y.md && has "950.4 m" y.md && has "skeins of 100 m: 10" y.md && has "1,200 g" y.md && ok || bad "yarn: $(cat y.md)"
php "$CT" yarn pc.csv y2.md gauge=20x28 stitch_length=1.2 skein=100 >/dev/null; has "26,880 stitches" y2.md && has "322.6 m" y2.md && ok || bad "yarn from gauge: $(cat y2.md)"
php "$CT" yarn pc.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "yarn with no measurement must be refused (exit 2)"
printf 'name,width,height,qty\nBad,0,5,1\n' > badp.csv; php "$CT" yarn badp.csv x.md swatch=10x10 swatch_yarn=18 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "only unusable pieces must be refused"
# fabric
php "$CT" fabric pc.csv f.md fabric_width=140 margin=10 >/dev/null; has "34.3 cm" f.md && has "37.7 cm (0.38 m" f.md && has "LOWER BOUND" f.md && ok || bad "fabric: $(cat f.md)"
php "$CT" fabric pc.csv f2.md fabric_width=55 unit=in >/dev/null; has "139.7 cm wide" f2.md && ok || bad "fabric in inches"
php "$CT" fabric pc.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "fabric without width must exit 2"
# rows
php "$CT" rows pat.md r.md >/dev/null; has "pat.md(2) Error: row 6 is missing" r.md || has "Error: row 6 is missing" r.md; ok
has "row 5: the instructions make 23 stitches, but you wrote (24 sts)" r.md && ok || bad "stitch count: $(cat r.md)"
has "rows 1-4 (4 rows) repeated 5 times = 20 more rows" r.md && ok || bad "repeat count"
has "repeat of rows 1-9 names a row that does not exist" r.md && ok || bad "repeat of a missing row"
has 'row 7: stitch count cannot be worked out' r.md && ok || bad "to end is skipped, not guessed"
php "$CT" rows good.md g.md >/dev/null; has "No problems found." g.md && has "= 12 more rows" g.md && ok || bad "a correct pattern gives no errors: $(cat g.md)"
printf 'Row 1: k24 (24 sts)\nRow 2: k20 (20 sts)\n' > cons.md; php "$CT" rows cons.md cs.md >/dev/null; has "work 20 stitches but the previous row ended with 24" cs.md && ok || bad "consumed vs previous: $(cat cs.md)"
printf 'Row 1: k2\nRow 1: p2\nRow 3: k2\n' > dup.md; php "$CT" rows dup.md d.md >/dev/null; has "row 1 is written twice" d.md && has "row 2 is missing" d.md && ok || bad "duplicate/missing rows: $(cat d.md)"
printf 'no rows here\n' > nor.md; php "$CT" rows nor.md x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a text with no rows was not refused"
# materials
php "$CT" materials m.csv mm.md currency=EUR >/dev/null; has "Total of everything listed: 24.3 EUR" mm.md && has "still to buy (after what you have): **15.3 EUR" mm.md && has "ShopA: 22.5 EUR" mm.md && has 'no unit cost for "Needle"' mm.md && ok || bad "materials: $(cat mm.md)"
printf 'thing,price\nX,1\n' > nq.csv; php "$CT" materials nq.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "materials without qty column not refused"
# refusals, original untouched
php "$CT" cutlist nope.csv x.md stock=10 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing file not refused"
: > e.csv; php "$CT" cutlist e.csv x.md stock=10 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "empty file not refused"
php "$CT" frob p2.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
[ "$(md5sum parts.csv p2.csv pc.csv m.csv pat.md)" = "$before" ] && ok || bad "an original changed"
head -20 "$ROOT/cockpit_app/craft_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no CLI guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/craft_tool (cutlist|yarn|fabric|rows|materials) \{INPUT\} \{OUTPUT\}~",$p["command"])) {echo "bad";exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/craft.json" > pc.out 2>&1; [ "$(cat pc.out)" = 5 ] && ok || bad "craft.json: $(cat pc.out)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $k=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/hobby-crafts.json"),true); $e=""; $r=kind_validate($k,$e); exit($r&&$r["group"]==="Home & life"&&$r["tools"][0]["tool"]==="craft"?0:1);' "$ROOT" >/dev/null 2>&1 && ok || bad "kind fails kind_validate"
echo "craft_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
