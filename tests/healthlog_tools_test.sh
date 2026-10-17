#!/usr/bin/env bash
# healthlog_tools_test.sh — the Health and fitness log tools (cockpit_app/healthlog_tool, tools_builtins/healthlog.json, kinds/health-log.json): the training-plan check, meal totals,
# appointments, measurement trends, refusals, the not-medical-advice statement.   bash tests/healthlog_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; HT="$ROOT/cockpit_app/healthlog_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "healthlog_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > plan.csv <<'CSV'
date,activity,minutes
2026-03-02,Run,30
2026-03-03,Run,30
2026-03-04,Rest,
2026-03-05,Run,30
2026-03-07,Long run,40
2026-03-09,Run,40
2026-03-10,Run,40
2026-03-11,Gym,40
2026-03-12,Run,40
2026-03-13,Run,40
2026-03-14,Run,40
2026-03-15,Run,40
2026-03-16,Run,20
2026-03-17,Run,abc
CSV
cat > diary.csv <<'CSV'
date,meal,item,kcal,protein_g,carbs_g,fat_g
2026-04-01,breakfast,Oats,150,5,27,3
2026-04-01,lunch,Sandwich,400,20,45,15
2026-04-01,snack,Crisps,,2,15,10
2026-04-01,dinner,Pasta,600,5,10,1
2026-04-02,breakfast,Oats,150,5,27,3
2026-04-02,lunch,Soup,x,,,
CSV
cat > appts.csv <<'CSV'
date,time,title,who,done
2026-04-01,10:00,Dentist,Dr A,yes
2026-04-10,09:00,Check-up,Dr B,
2026-04-25,14:30,Eye test,,
2026-04-25,14:30,Physio,,
2026-06-30,,Blood test,,
2026-04-18,25:00,Yoga,,
CSV
cat > meas.csv <<'CSV'
date,weight,waist,note
2026-01-01,80.0,90,start
2026-02-01,79.0,89,
2026-03-01,78.2,89,
2026-04-01,77.5,87,x
CSV
sum0=$(md5sum plan.csv diary.csv appts.csv meas.csv)
H() { php "$HT" "$@"; }
# plan
H plan plan.csv p.md >/dev/null; [ $? = 0 ] && ok || bad "plan exited non-zero"
has "| 2026-03-09 | 7 | 7 | 0 | 280 | +115.4% |" p.md && has "| 2026-03-02 (may be partial) | 4 | 4 | 3 | 130 |  |" p.md && ok || bad "weekly table: $(sed -n 6,10p p.md)"
has "above the 10% rule of thumb" p.md && ok || bad "the jump above 10%: $(grep -n 'rule of thumb' p.md | head -3)"
has "week of 2026-03-09 has 0 rest days (fewer than 1)" p.md && has "8 training days in a row, ending 2026-03-16" p.md && ok || bad "rest days / streak: $(grep -n Warning p.md)"
has "Error: minutes \"abc\" is not a number" p.md && has "[exit code 1]" p.md && ok || bad "a bad volume cell"
has "Not medical advice" p.md && ok || bad "the not-medical-advice statement is missing"
H plan plan.csv p2.md threshold=200 min_rest=0 max_streak=20 >/dev/null; grep -q "Warning" p2.md && bad "thresholds were not honoured: $(grep Warning p2.md)" || ok
printf 'date,activity,km\n2026-03-02,Run,10\n2026-03-04,Run,11\n2026-03-09,Run,11.5\n2026-03-11,Run,12\n' > km.csv; H plan km.csv p3.md >/dev/null; has "| 2026-03-02 (may be partial) | 2 | 2 | 5 | 21 |" p3.md && has "| 2026-03-09 (may be partial) | 2 | 2 | 5 | 23.5 | +11.9% |" p3.md && has "above the 10% rule" p3.md && ok || bad "km column found by name, 11.9% rise: $(sed -n 6,9p p3.md)"
H plan km.csv p4.md metric=km >/dev/null && ok || bad "metric=km"
H plan km.csv x.md metric=nothing >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown metric column was not refused"
printf 'date,activity\n2026-03-02,Run\n' > novol.csv; H plan novol.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a plan with no volume column was not refused"
# meals
H meals diary.csv m.md target=2000 >/dev/null; [ $? = 0 ] && ok || bad "meals exited non-zero"
has "| 2026-04-01 | 4 | 1150 | 32 | 97 | 29 | -850 |" m.md && ok || bad "daily totals and target difference: $(sed -n 5,8p m.md)"
has "Crisps has macros but no kcal: not counted in kcal (about 158 kcal" m.md && has "Pasta: 600 kcal written, but protein, carbs and fat add up to about 69 kcal" m.md && ok || bad "meal notes: $(grep -n Note m.md)"
has "Error: \"x\" in the kcal column is not a number" m.md && ok || bad "a bad kcal cell"
has "| dinner | 600 |" m.md && has "Daily average: 650 kcal" m.md && ok || bad "by-meal table and average"
has "this tool does not know what is right for you" m.md && ok || bad "target disclaimer"
H meals diary.csv x.md target=zero >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a bad target was not refused"
printf 'date,item\n2026-01-01,Apple\n' > nocal.csv; H meals nocal.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a diary with no numbers column was not refused"
# appointments
H appointments appts.csv a.md today=2026-04-15 >/dev/null; [ $? = 0 ] && ok || bad "appointments exited non-zero"
has "- 2026-04-10 09:00 Check-up (Dr B) (5 days ago)" a.md && has "- 2026-04-18 Yoga (in 3 days)" a.md && has "- 2026-06-30 Blood test (in 76 days)" a.md && ok || bad "overdue / upcoming / later: $(sed -n 5,20p a.md)"
has "clashes with line 4: both on 2026-04-25 at 14:30" a.md && has "the time \"25:00\" is not HH:MM" a.md && ok || bad "clash and bad time"
grep -q "Dentist" a.md && bad "a done appointment is listed" || ok
H appointments appts.csv a2.md today=2026-04-15 within=100 >/dev/null; has "Coming up in the next 100 days: 4" a2.md && ok || bad "within= widens the list"
H appointments appts.csv x.md today=15-april >/dev/null 2>&1; [ $? = 2 ] && ok || bad "a bad today= was not refused"
printf 'date,time\n2026-01-01,10:00\n' > notitle.csv; H appointments notitle.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a list without titles was not refused"
# trend
H trend meas.csv t.md >/dev/null; has "- First 80, last 77.5: -2.5 (-3.1%)" t.md && has "- About -0.83 per 30 days" t.md && has "- Last three readings: falling" t.md && ok || bad "weight trend: $(sed -n 5,12p t.md)"
has "## waist" t.md && has "- Last three readings: mixed" t.md && ok || bad "the waist column"
grep -q "## note" t.md && bad "a text column was treated as a measure" || ok
has "says nothing by itself about health" t.md && has "Not medical advice" t.md && ok || bad "trend disclaimers"
printf 'date,notes\n2026-01-01,a\n' > nonum.csv; H trend nonum.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a file with no numeric column was not refused"
# general
printf 'a,b\n1,2\n' > nodate.csv; H trend nodate.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a file with no date column was not refused"
H plan nope.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
H frob plan.csv x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(md5sum plan.csv diary.csv appts.csv meas.csv)" = "$sum0" ] && ok || bad "an original file was changed"
head -30 "$HT" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/healthlog_tool (plan|meals|appointments|trend) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/healthlog.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "healthlog.json presets: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $j=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/health-log.json"),true); $e=""; $v=kind_validate($j,$e); if(!$v){echo $e; exit(1);} if(($v["group"]??"")!=="Home & life"||empty($v["examples"])||empty($v["verify"])||mb_strlen($v["note"])<mb_strlen($j["note"])||stripos($j["note"],"NOT medical advice")===false) {echo "fields"; exit(1);} echo "ok";' "$ROOT" > kv 2>&1; [ "$(cat kv)" = ok ] && ok || bad "health-log.json does not pass kinds_lib validation: $(cat kv)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/health-log.json")" = healthlog ] && ok || bad "the kind does not name the tool"
echo "healthlog_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
