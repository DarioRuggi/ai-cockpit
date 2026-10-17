#!/usr/bin/env bash
# garden_tools_test.sh — the Gardening tools (cockpit_app/garden_tool, tools_builtins/garden.json, kinds/gardening.json): the sowing and harvest calendar for either hemisphere, bed
# counts, the garden-log check, the to-do list, refusals.   bash tests/garden_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; GT="$ROOT/cockpit_app/garden_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "garden_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > plants.csv <<'CSV'
name,sow_from,sow_to,harvest_days,spacing_cm,hemisphere
Carrot,3,7,80,5,north
Lettuce,Feb,Sep,55,25,
Spinach,10,2,45,10,north
Tomato,04-01,05-15,100,50,north
Radis,mars,juin,30,3,
CSV
cat > log.csv <<'CSV'
date,bed,plant,action
2026-03-10,A,Carrot,sow
2026-04-20,A,Carrot,harvest
2026-04-01,B,Tomato,sow
2026-02-30,B,Lettuce,sow
2999-01-01,B,Lettuce,sow
2026-05-01,C,Radish,harvest
2026-03-10,A,Carrot,sow
2026-06-01,A,Carrot,mulch
2026-07-01,B,Lettuce,water
CSV
sum0=$(md5sum plants.csv log.csv)
G() { php "$GT" "$@"; }
# calendar
G calendar plants.csv c.md start=2026-04-10 hemisphere=north >/dev/null; [ $? = 0 ] && ok || bad "calendar exited non-zero"
grep -q "^| Carrot | 2026-03-01 | 2026-07-31 | open now, closes in 112 days | 2026-06-29 | 2026-10-19 | 5 cm |" c.md && ok || bad "carrot row: $(grep Carrot c.md)"
grep -q "^| Tomato | 2026-04-01 | 2026-05-15 | open now, closes in 35 days | 2026-07-19 | 2026-08-23 | 50 cm |" c.md && ok || bad "tomato MM-DD window and 50 cm: $(grep Tomato c.md)"
grep -q "^| Spinach | 2026-10-01 | 2027-02-28 | opens in 174 days" c.md && ok || bad "a window wrapping the year: $(grep Spinach c.md)"
grep -q "^| Radis | 2026-03-01 | 2026-06-30 | open now" c.md && ok || bad "French month names: $(grep Radis c.md)"
G calendar plants.csv c2.md start=2026-04-10 hemisphere=south >/dev/null
grep -q "^| Spinach (months moved 6) | 2026-04-01 | 2026-08-31 | open now" c2.md && has "moved by six" c2.md && ok || bad "southern hemisphere shifts a northern row: $(grep Spinach c2.md)"
grep -q "^| Lettuce | 2026-02-01" c2.md && ok || bad "a row with no hemisphere is taken as written"
has "(south hemisphere, autumn)" c2.md && has "(north hemisphere, spring)" c.md && ok || bad "season by hemisphere"
G calendar plants.csv c3.md start=2026-10-15 hemisphere=north >/dev/null; grep -q "^| Carrot | 2027-03-01 | 2027-07-31 | opens in" c3.md && ok || bad "next year's window: $(grep Carrot c3.md)"
G calendar plants.csv x.md start=2026-04-10 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "calendar without hemisphere was not refused (none may be assumed)"
G calendar plants.csv x.md hemisphere=north >/dev/null 2>&1; [ $? = 2 ] && ok || bad "calendar without start was not refused"
# spacing
G spacing plants.csv s.md bed=240x120 >/dev/null; has "| Lettuce | 25 cm | 36 | 45 | +9 by staggering |" s.md && has "| Tomato | 50 cm | 8 | 8 |" s.md && ok || bad "spacing counts: $(sed -n 6,10p s.md)"
G spacing plants.csv s2.md bed=2.4x1.2 unit=m plant=tom >/dev/null; has "| Tomato | 50 cm | 8 | 8 |" s2.md && has "240 x 120 cm" s2.md && ok || bad "unit=m and plant filter: $(sed -n 1,8p s2.md)"
G spacing plants.csv s3.md bed=40x40 plant=tomato >/dev/null; has "does not fit even one plant" s3.md && ok || bad "a bed too small: $(sed -n 6,8p s3.md)"
G spacing plants.csv x.md bed=big >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a bad bed size was not refused"
G spacing plants.csv x.md bed=100x100 plant=nothing >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown plant was not refused"
# logcheck
G logcheck log.csv l.md plants=plants.csv hemisphere=north >/dev/null; [ $? = 0 ] && ok || bad "logcheck exited non-zero"
has "log.csv(5) Error: the date \"2026-02-30\" cannot be read" l.md && ok || bad "an impossible date: $(sed -n 5,12p l.md)"
has "log.csv(6) Warning: the date 2999-01-01 is in the future" l.md && has "Lettuce sown on 2999-01-01, outside its sowing window" l.md && ok || bad "future date and out-of-season sowing"
has "log.csv(8) Warning: looks like a duplicate of line 2" l.md && ok || bad "duplicate row"
has "log.csv(3) Warning: Carrot harvested 41 days after sowing; the plant file says about 80" l.md && ok || bad "harvest far too soon: $(grep -n harvested l.md)"
has "Radish in C harvested on 2026-05-01 with no sowing" l.md && has "Note: the action \"mulch\"" l.md && has "[exit code 1]" l.md && ok || bad "harvest with no sowing / unknown action / exit code line"
printf 'date,plant,action\n2026-03-01,Carrot,sow\n2026-07-01,Carrot,harvest\n' > good.csv; G logcheck good.csv l2.md plants=plants.csv >/dev/null; has "No problems found." l2.md && has "[exit code 0]" l2.md && ok || bad "a clean log: $(cat l2.md)"
printf 'day,what\n1,2\n' > nocols.csv; G logcheck nocols.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a log without date/plant/action columns was not refused"
# todo
G todo plants.csv t.md start=2026-04-10 hemisphere=north days=10 log=log.csv water=3 >/dev/null; [ $? = 0 ] && ok || bad "todo exited non-zero"
has "## 2026-04-10 (Fri)" t.md && has "Sowing window for Carrot is open (closes 2026-07-31, 112 days)" t.md && ok || bad "todo sowing: $(sed -n 1,8p t.md)"
has "Water Tomato (B) (every 3 days)" t.md && has "## 2026-04-13 (Mon)" t.md && has "## 2026-04-19 (Sun)" t.md && ok || bad "watering every 3 days for what is in the ground: $(grep -n Water t.md)"
grep -q "Water Carrot" t.md && bad "a harvested bed is still being watered" || ok
G todo plants.csv t2.md start=2026-05-10 hemisphere=north days=10 >/dev/null; has "LAST DAY to sow Tomato" t2.md && has "No log given" t2.md && ok || bad "last day to sow: $(sed -n 1,10p t2.md)"
G todo plants.csv t3.md start=2026-07-20 hemisphere=north days=5 log=log.csv >/dev/null; has "Harvest overdue or ready: Tomato (B) (sown 2026-04-01" t3.md && ok || bad "a harvest due from the log: $(sed -n 1,8p t3.md)"
G todo plants.csv x.md start=2026-04-10 hemisphere=north days=0 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "days=0 was not refused"
# general
printf 'name,sow_from\nA,3\n' > badp.csv; G calendar badp.csv x.md start=2026-04-10 hemisphere=north >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a plant file without sow_to was not refused"
G calendar nope.csv x.md start=2026-04-10 hemisphere=north >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
G frob plants.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(md5sum plants.csv log.csv)" = "$sum0" ] && ok || bad "an original file was changed"
head -30 "$GT" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/garden_tool (calendar|spacing|logcheck|todo) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/garden.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "garden.json presets: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $j=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/gardening.json"),true); $e=""; $v=kind_validate($j,$e); if(!$v){echo $e; exit(1);} if(($v["group"]??"")!=="Home & life"||empty($v["examples"])||empty($v["verify"])||mb_strlen($v["note"])<mb_strlen($j["note"])) {echo "fields"; exit(1);} echo "ok";' "$ROOT" > kv 2>&1; [ "$(cat kv)" = ok ] && ok || bad "gardening.json does not pass kinds_lib validation: $(cat kv)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/gardening.json")" = garden ] && ok || bad "the kind does not name the tool"
echo "garden_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
