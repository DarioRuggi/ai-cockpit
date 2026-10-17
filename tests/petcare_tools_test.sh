#!/usr/bin/env bash
# petcare_tools_test.sh — the Pets tools (cockpit_app/petcare_tool, tools_builtins/petcare.json, kinds/pets.json): reminders, the vaccination/treatment check, the weight trend, the feeding
# amount from a package table, refusals, the not-veterinary-advice statement.   bash tests/petcare_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; PT="$ROOT/cockpit_app/petcare_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "petcare_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > care.csv <<'CSV'
date,pet,task,interval_days,weight_kg,notes
2025-10-01,Rex,Rabies vaccination,365,,
2026-01-10,Rex,Flea treatment,30,,
2026-02-10,Rex,Flea treatment,30,,
2026-03-12,Rex,Flea treatment,30,,
2026-01-05,Rex,Weight,,22.0,
2026-03-05,Rex,Weight,,24.0,
2026-04-05,Rex,Weight,,25.5,
2026-04-05,Mia,Weight,,4.2,
2026-03-01,Mia,Worming,90,,
2026-03-01,Mia,Worming,90,,
2026-03-20,Mia,Grooming,,,
13/45/2026,Mia,Vet,,,
CSV
printf 'task,interval_days\nRabies vaccination,365\nBooster,365\nWorming,90\n' > sch.csv
sum0=$(md5sum care.csv sch.csv)
P() { php "$PT" "$@"; }
# due
P due care.csv d.md today=2026-04-20 >/dev/null; [ $? = 0 ] && ok || bad "due exited non-zero"
has "| Rex: Flea treatment | 2026-03-12 | 30 days | 2026-04-11 | OVERDUE by 9 days |" d.md && ok || bad "the overdue row: $(sed -n 6,9p d.md)"
has "| Mia: Worming | 2026-03-01 | 90 days | 2026-05-30 | fine (in 40 days) |" d.md && has "| Rex: Rabies vaccination | 2025-10-01 | 365 days | 2026-10-01 | fine (in 164 days) |" d.md && ok || bad "the fine rows"
has "- Mia: Grooming last done 2026-03-20 (31 days ago)" d.md && ok || bad "a task with no interval is listed apart"
grep -q "Rex: Weight last done" d.md && bad "weigh-ins listed as tasks without an interval" || ok
has "care.csv(13) Error: the date \"13/45/2026\" cannot be read" d.md && has "care.csv(11) Warning: looks like a duplicate of line 10" d.md && has "[exit code 1]" d.md && ok || bad "log problems: $(grep -n 'care.csv' d.md)"
has "not veterinary advice" d.md && ok || bad "the not-veterinary-advice statement is missing"
P due care.csv d2.md today=2026-04-20 within=200 >/dev/null; has "due in 164 days" d2.md && ok || bad "within= widens 'due soon'"
P due care.csv d3.md today=2026-05-30 >/dev/null; has "due TODAY" d3.md && ok || bad "due on the day itself"
P due care.csv x.md today=tomorrow >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a bad today= was not refused"
# vaccines
P vaccines care.csv v.md today=2026-04-20 >/dev/null; has "Warning: Rex: Flea treatment is overdue: last 2026-03-12, every 30 days, was due 2026-04-11 (9 days ago)" v.md && has "Rex: Rabies vaccination is up to date (next 2026-10-01)" v.md && ok || bad "vaccines from the log: $(sed -n 5,9p v.md)"
grep -q "Grooming\|Weight" v.md && bad "a task that is not a vaccination or treatment was checked" || ok
P vaccines care.csv v2.md today=2026-04-20 schedule=sch.csv >/dev/null
has "Mia: Rabies vaccination is in the schedule but was never recorded" v2.md && has "Rex: Booster is in the schedule but was never recorded" v2.md && has "Mia: Worming: two doses 0 days apart" v2.md && ok || bad "schedule check: $(sed -n 5,12p v2.md)"
has "Mia: Worming is up to date (next 2026-05-30)" v2.md && ok || bad "an up-to-date task against the schedule"
printf 'date,pet,task\n2026-01-01,Rex,Walk\n' > nov.csv; P vaccines nov.csv v3.md today=2026-04-20 >/dev/null; has "nothing to check" v3.md && ok || bad "a log with no vaccination rows"
printf 'a,b\n1,2\n' > nocols.csv; P due nocols.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a log without date/task columns was not refused"
printf 'task,x\nA,1\n' > badsch.csv; P vaccines care.csv x.md schedule=badsch.csv >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a schedule without interval_days was not refused"
# weight
P weight care.csv w.md today=2026-04-20 >/dev/null; has "- First 22 kg, last 25.5 kg: +3.5 kg (+15.9%)" w.md && has "- The last three readings are rising" w.md && ok || bad "weight figures: $(sed -n 5,10p w.md)"
has "NOTE: up 15.9% since 2026-01-05 (more than 10%): worth mentioning at the next vet visit" w.md && ok || bad "a large change is mentioned, without diagnosis"
has "- 1 reading, 2026-04-05" w.md && ok || bad "a single reading"
P weight care.csv w2.md threshold=20 >/dev/null; grep -q "NOTE:" w2.md && bad "threshold=20 should silence a 15.9% change" || ok
P weight care.csv w3.md unit=lb >/dev/null; has "First 48.5 lb, last 56.22 lb" w3.md && ok || bad "unit=lb: $(grep First w3.md)"
printf 'date,pet,task\n2026-01-01,Rex,Walk\n' > now.csv; P weight now.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a log with no weights was not refused"
P weight care.csv x.md unit=stone >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a bad unit was not refused"
# feeding
P feeding care.csv f.md guide=5:80,10:140,20:230,30:300 kcal=380 meals=2 pet=Rex >/dev/null; [ $? = 0 ] && ok || bad "feeding exited non-zero"
has "| Rex | 25.5 kg | 269 g | 134 g | 1020 kcal |" f.md && ok || bad "interpolation 230 + 70*5.5/10 = 268.5: $(sed -n 5,8p f.md)"
P feeding care.csv f2.md guide=5:80,10:140 weight=7.5 pet=Cat >/dev/null; has "| Cat | 7.5 kg | 110 g | 55 g |" f2.md && ok || bad "weight= overrides the log: $(sed -n 5,8p f2.md)"
P feeding care.csv f3.md guide=5:80,10:140 weight=3 >/dev/null 2>&1; rc=$?; has "outside the table" f3.md && [ $rc = 1 ] && ok || bad "a weight outside the table must be refused, not extrapolated (rc=$rc)"
has "ask the vet" f.md && has "Not veterinary advice" f.md && ok || bad "feeding disclaimer"
P feeding care.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "feeding without guide= was not refused"
P feeding care.csv x.md guide=5-80 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a malformed guide was not refused"
P feeding care.csv x.md guide=5:80 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a one-row guide was not refused"
# general
P due nope.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
P frob care.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(md5sum care.csv sch.csv)" = "$sum0" ] && ok || bad "an original file was changed"
head -30 "$PT" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/petcare_tool (due|vaccines|weight|feeding) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/petcare.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "petcare.json presets: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $j=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/pets.json"),true); $e=""; $v=kind_validate($j,$e); if(!$v){echo $e; exit(1);} if(($v["group"]??"")!=="Home & life"||empty($v["examples"])||empty($v["verify"])||mb_strlen($v["note"])<mb_strlen($j["note"])||stripos($j["note"],"NOT veterinary advice")===false) {echo "fields"; exit(1);} echo "ok";' "$ROOT" > kv 2>&1; [ "$(cat kv)" = ok ] && ok || bad "pets.json does not pass kinds_lib validation: $(cat kv)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/pets.json")" = petcare ] && ok || bad "the kind does not name the tool"
echo "petcare_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
