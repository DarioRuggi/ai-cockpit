#!/usr/bin/env bash
# diy_tools_test.sh — the Home and DIY tool (cockpit_app/diy_tool, tools_builtins/diy.json, kinds/home-diy.json): paint, floor, concrete and lumber calculators, the estimate sheet, the maintenance schedule, safety flags, refusals.   bash tests/diy_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TL="$ROOT/cockpit_app/diy_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "diy_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
rc() { php "$TL" "$@" >/dev/null 2>&1; echo $?; }
cd "$T" || exit 1
cat > jobs.txt <<'TXT'
# test
paint: room=4x3x2.5 doors=2 windows=1 coats=2 ceiling=yes
floor: room=4x3 piece=30x30 pack=11
concrete: length=3 width=2 depth=10cm bag=0.0125
lumber: need=2.4,1.8,1.8,0.6,1.2 stock=2.4,3.0 kerf=3
paint: walls=abc
roof: rewire the electrical panel
TXT
sum0=$(md5sum jobs.txt | cut -d' ' -f1)
php "$TL" calc jobs.txt j.md >/dev/null; [ $? = 0 ] && ok || bad "calc exit"
has "Paint needed: 8.52 litres" j.md && has "buy at least 9.0 litres" j.md && ok || bad "paint (30.6 + 12 m2, 2 coats, 10 m2 per litre): $(grep -i paint j.md | head -3)"
has "**147 pieces**" j.md && has "**14 boxes**" j.md && ok || bad "floor (12 m2 + 10% = 13.2 / 0.09 = 147 pieces): $(sed -n 10,16p j.md)"
has "0.630 m3" j.md && has "**51 bags**" j.md && ok || bad "concrete: $(grep -A5 'Line 4' j.md)"
has "Stock 2.40 m: **4 lengths**" j.md && has "1.80 + 0.60" j.md || has "1.20 + 0.60" j.md; ok
has "Least wood bought: stock 2.40 m" j.md && ok || bad "lumber plan"
has "jobs.txt(6) Error: walls= must be" j.md && has "jobs.txt(7) Note: this line mentions work that needs a licensed professional" j.md && has "jobs.txt(7) Error: unknown kind" j.md && ok || bad "problem lines (file(line)) and the safety note: $(tail -8 j.md)"
has "[exit code 1]" j.md && ok || bad "exit code line"
printf 'floor: area=10 waste=0 piece=0.5x0.5m\nconcrete: length=2m width=100cm depth=4in\nlumber: need=3,1 stock=2,4\n' > j2.txt; php "$TL" calc j2.txt j2.md >/dev/null
has "**40 pieces**" j2.md && has "Volume: 2.00 x 1.00 x 0.102 m = 0.203 m3" j2.md && has "Add bag=M3" j2.md && has "cannot be used" j2.md && ok || bad "units and a stock too short: $(cat j2.md | head -30)"
# estimate
cat > est.csv <<'CSV'
item,type,quantity,unit price
Paint 5L,part,3,24.90
Brushes,material,1,12
Painting,labour,10,30
Rewire kitchen sockets,labour,4,50
Mystery,thing,x,5
CSV
php "$TL" estimate est.csv e.md contingency=15 tax=20 >/dev/null; has "Parts and materials: 86.70" e.md && has "Labour: 500.00" e.md && has "Contingency at 15%" e.md && has "**Total: 809.65**" e.md && ok || bad "estimate totals: $(sed -n 10,18p e.md)"
has "est.csv(6) Error: the quantity \"x\" cannot be read" e.md && has "est.csv(5) Note:" e.md && ok || bad "estimate problem lines"
# schedule
cat > sch.csv <<'CSV'
task,last done,interval
Descale boiler,2025-01-15,1 year
Clean gutters,2025-10-01,6 months
Smoke alarm test,2026-02-20,1 month
Service mower,,1 year
Bad,notadate,1 year
Bad2,2026-01-01,often
CSV
php "$TL" schedule sch.csv s.md today=2026-03-01 >/dev/null; has "| 2 | Descale boiler | 2025-01-15 | 1 year | 2026-01-15 | 45 days overdue |" s.md && ok || bad "overdue"
has "| 3 | Clean gutters | 2025-10-01 | 6 months | 2026-04-01 | in 31 days |" s.md && has "due in 19 days" s.md && ok || bad "coming up / later"
has "sch.csv(5) Warning: \"Service mower\" has never been done" s.md && has "sch.csv(6) Error: the date" s.md && has "sch.csv(7) Error: the interval \"often\"" s.md && ok || bad "never done and unreadable lines"
php "$TL" schedule sch.csv s2.md today=2026-03-01 within=60 >/dev/null; has "| 3 | Clean gutters | 2025-10-01 | 6 months | 2026-04-01 | due in 31 days |" s2.md && ok || bad "within="
# refusals, original unchanged
printf '\xF9\xEC\n' > ansi.txt; [ "$(rc calc ansi.txt x.md)" = 1 ] && ok || bad "a non-UTF-8 file was not refused"
: > empty.txt; [ "$(rc calc empty.txt x.md)" = 1 ] && ok || bad "an empty file was not refused"
[ "$(rc estimate est.csv x.md contingency=500)" = 1 ] && ok || bad "an absurd contingency was not refused"
[ "$(rc schedule sch.csv x.md today=tomorrow)" = 1 ] && ok || bad "a bad today= was not refused"
[ "$(rc calc nope.txt x.md)" = 1 ] && ok || bad "a missing file was not refused"
[ "$(rc frob jobs.txt x.md)" = 2 ] && ok || bad "an unknown subcommand was not refused"
has "licensed professionals" j.md && has "licensed professionals" e.md && has "licensed professionals" s.md && ok || bad "the safety note is missing from an output"
[ "$(md5sum jobs.txt | cut -d' ' -f1)" = "$sum0" ] && ok || bad "the original changed"
head -20 "$TL" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r 'foreach(array_slice($argv,1) as $f){ $j=json_decode(file_get_contents($f),true); if(!is_array($j)){ echo "bad json $f"; exit(1);} } echo "ok";' "$ROOT/cockpit_app/tools_builtins/diy.json" > pc 2>&1; [ "$(cat pc)" = ok ] && ok || bad "json: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; for($i=2;$i<count($argv);$i++){ $j=json_decode(file_get_contents($argv[$i]),true); $e=""; if(kind_validate($j,$e)===null){ echo "invalid ".$argv[$i].": $e"; exit(1);} if(count($j["examples"]??[])<3||empty($j["verify"])||empty($j["group"])||empty($j["note"])||empty($j["details"])){ echo "incomplete ".$argv[$i]; exit(1);} } echo "ok";' "$ROOT" "$ROOT/cockpit_app/kinds/home-diy.json" > kc 2>&1; [ "$(cat kc)" = ok ] && ok || bad "kind: $(cat kc)"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/diy_tool [a-z]+ \{INPUT\} \{OUTPUT\}~",$p["command"])){ echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/diy.json" > pc 2>&1; [ "$(cat pc)" = 3 ] && ok || bad "presets: $(cat pc)"
echo "diy_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
