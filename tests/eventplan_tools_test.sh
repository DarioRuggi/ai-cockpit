#!/usr/bin/env bash
# eventplan_tools_test.sh — the Non-profit and events tools (cockpit_app/eventplan_tool, tools_builtins/eventplan.json, kinds/nonprofit-events.json): volunteer roster, run-of-show timeline,
# budget against actual, grant draft against a checklist, refusals.   bash tests/eventplan_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ET="$ROOT/cockpit_app/eventplan_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "eventplan_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { n=$((n+1)); echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
t() { if eval "$1"; then ok; else bad "$2"; fi; }
cd "$T" || exit 1
cat > r.csv <<'TXT'
person,date,start,end,role,needed
Anna,2026-06-01,09:00,13:00,Entrance,2
Ben,2026-06-01,09:00,13:00,Entrance,2
Anna,2026-06-01,12:00,15:00,Kitchen,1
,2026-06-01,13:00,17:00,Cleanup,1
Cy,2026-06-01,14:00,18:00,Stage,2
Cy,2026-06-02,9am,5pm,Stage,1
TXT
cat > tl.csv <<'TXT'
start,end,item
18:00,18:30,Doors
18:25,19:00,Welcome
19:00,19:45,Talk
20:15,21:00,Music
TXT
printf 'start,minutes,item\n10:00,30,Setup\n10:30,60,Main\n11:30,15,Close\n' > tl_ok.csv
cat > b.csv <<'TXT'
line,budget,actual,category
Venue,"1,000.00",980,Space
Printing,100,150,Marketing
Food,300,,Catering
Gifts,0,40,Other
TXT
printf 'line;budget;actual\nA;10,50;10,50\nB;20;abc\n' > b2.csv
printf '# Summary\nWe do good things for the town.\n\n# Need\nTODO\n\n# Budget\nOne two three four five six seven eight nine ten eleven twelve.\n\n# Extra\nhello\n' > d.md
printf 'Summary | 5 words\nNeed | 300\nBudget | 10\nEvaluation | 200\n' > cl.txt
printf 'Summary | 50\nBudget: 20\n' > cl_ok.txt
sum0=$(md5sum r.csv tl.csv b.csv d.md cl.txt | md5sum)
# roster
php "$ET" roster r.csv ro.md maxday=7 >/dev/null; t "[ \$? = 0 ]" "roster exited non-zero"
t "has 'r.csv(4) Error: double-booked: Anna on 2026-06-01 12:00-15:00 overlaps the shift on line 2' ro.md" "double-booking: \$(grep Error ro.md)"
t "has 'r.csv(5) Error: uncovered shift: 2026-06-01 13:00-17:00 (Cleanup) has nobody assigned' ro.md" "an uncovered shift"
t "has 'r.csv(6) Error: understaffed: 2026-06-01 14:00-18:00 (Stage): 1 of 2 needed' ro.md" "an understaffed shift"
t "has '| Anna | 2 | 7h00 |' ro.md && has '| Cy | 2 | 12h00 |' ro.md" "hours per person (am/pm times too): \$(grep '^| ' ro.md)"
t "has 'Cy works 8h00 on 2026-06-02, more than 7 hours' ro.md" "the longest-day warning with maxday=7"
t "! has 'maxday' ro.md || has 'more than 7 hours' ro.md" "maxday argument"
php "$ET" roster r.csv ro2.md >/dev/null; t "! grep -q 'Warning: Cy works' ro2.md" "a default 8-hour day flagged 8 hours"
printf 'person,date,start\nA,2026-01-01,09:00\n' > badr.csv; php "$ET" roster badr.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a roster without an end column was not refused"
# timeline
php "$ET" timeline tl.csv ti.md >/dev/null
t "has 'tl.csv(3) Error: overlap: \"Welcome\" starts at 18:25 before \"Doors\" (line 2) ends at 18:30 (5 min)' ti.md" "an overlap: \$(grep -E 'Error|Warning' ti.md)"
t "has 'tl.csv(5) Warning: gap of 30 min between 19:45 and 20:15' ti.md" "a gap"
t "has 'total length 3h00 (180 min)' ti.md" "total length"
php "$ET" timeline tl_ok.csv ti2.md >/dev/null; t "has '0 errors, 0 warnings' ti2.md && has 'total length 1h45 (105 min)' ti2.md" "a run of show with minutes: \$(tail -8 ti2.md)"
# budget
php "$ET" budget b.csv bu.md >/dev/null
t "has '| Printing | 100.00 | 150.00 | +50.00 | 50% |' bu.md" "variance by line: \$(grep '^| ' bu.md)"
t "has '| **Total** | 1,400.00 | 1,170.00 | -230.00 | -16.4% |' bu.md" "totals"
t "has 'b.csv(3) Warning: \"Printing\" is over budget by 50.00 (50%)' bu.md" "an over-budget line"
t "has 'b.csv(5) Warning: \"Gifts\" has no budget but 40.00 was spent' bu.md" "spending without a budget"
t "has 'b.csv(4) Note: no actual yet for \"Food\"' bu.md" "no actual yet"
t "has '| Marketing | 100.00 | 150.00 | +50.00 |' bu.md" "totals by category"
php "$ET" budget b2.csv bu2.md >/dev/null; t "has 'b2.csv(3) Error: the actual \"abc\" of \"B\" is not a number' bu2.md && has '| A | 10.50 | 10.50 |' bu2.md" "decimal commas and a bad number: \$(cat bu2.md | head -12)"
# grant
php "$ET" grant d.md g.md cl.txt >/dev/null
t "has 'd.md(1) Error: \"Summary\" has 7 words, 2 over the limit of 5' g.md" "over the word limit: \$(grep -E 'Error|Warning' g.md)"
t "has 'Error: the draft has no section \"Evaluation\"' g.md" "a missing section"
t "has 'Warning: \"Need\" still contains a placeholder' g.md && has 'Warning: \"Need\" has only 1 of 300' g.md" "placeholder / too short"
t "has 'Note: the draft section \"Extra\" is not on the checklist' g.md" "an extra section"
php "$ET" grant d.md g2.md cl_ok.txt >/dev/null; t "! grep -q 'Error' g2.md || ! has 'Error: \"Summary\"' g2.md" "a passing section was flagged"
php "$ET" grant d.md g3.md >/dev/null 2>&1; t "[ \$? = 2 ]" "grant without a checklist was not refused"
printf 'plain text with no headings at all\n' > nohead.md; php "$ET" grant nohead.md g4.md cl.txt >/dev/null 2>&1; t "[ \$? = 1 ]" "a draft with no headings was not refused"
# refusals, untouched, guard, json
printf '\xF9\xEC\n' > ansi.csv; php "$ET" roster ansi.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a non-UTF-8 file was not refused"
: > empty.csv; php "$ET" budget empty.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "an empty file was not refused"
php "$ET" budget nope.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a missing file was not refused"
php "$ET" frob r.csv x.md >/dev/null 2>&1; t "[ \$? = 2 ]" "an unknown subcommand was not refused"
t "[ \"\$(md5sum r.csv tl.csv b.csv d.md cl.txt | md5sum)\" = \"$sum0\" ]" "an original was changed"
t "head -20 '$ET' | grep -q \"PHP_SAPI !== 'cli'\"" "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/eventplan_tool (roster|timeline|budget|grant) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/eventplan.json" > pc 2>&1; t "[ \"\$(cat pc)\" = 4 ]" "eventplan.json presets: \$(cat pc)"
cat > kv.php <<'PHP'
<?php require $argv[1] . '/cockpit_app/kinds_lib.php'; $k = json_decode(file_get_contents($argv[2]), true); $e = ''; $v = kind_validate($k, $e); if (!$v) { echo "invalid: $e"; exit(1); } foreach (['id','name','icon','description','note','verify','group','details','examples','tools'] as $f) if (empty($v[$f])) { echo "missing $f"; exit(1); } if ($v['note'] !== $k['note'] || $v['details'] !== $k['details']) { echo 'text too long'; exit(1); } echo 'ok';
PHP
php kv.php "$ROOT" "$ROOT/cockpit_app/kinds/nonprofit-events.json" > kc 2>&1; t "[ \"\$(cat kc)\" = ok ]" "the nonprofit-events kind: \$(cat kc)"
t "[ \"\$(jq -r '.tools[0].tool' '$ROOT/cockpit_app/kinds/nonprofit-events.json')\" = eventplan ] && [ \"\$(jq -r .group '$ROOT/cockpit_app/kinds/nonprofit-events.json')\" = 'Work & community' ]" "the kind does not name the tool / group"
echo "eventplan_tools_test: $((n-fails)) passed, $fails failed"; [ "$fails" = 0 ]
