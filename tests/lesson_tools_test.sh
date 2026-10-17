#!/usr/bin/env bash
# lesson_tools_test.sh — the Teaching tools (cockpit_app/lesson_tool, tools_builtins/lesson.json, kinds/teaching.json): lesson-plan check, rubric, gradebook, answer key, refusals.
#   bash tests/lesson_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LT="$ROOT/cockpit_app/lesson_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "lesson_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { n=$((n+1)); echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
t() { if eval "$1"; then ok; else bad "$2"; fi; }
cd "$T" || exit 1
cat > plan.md <<'TXT'
# Fractions

Length: 50 minutes

## Objectives
- Students will be able to add fractions with unlike denominators
- Compare two decimals by place value

## Activities
- 10 min: warm-up quiz
- 25 min: adding fractions practice
- 20 min: group game

## Assessment
- Exit ticket: add three fractions with unlike denominators
TXT
cat > good.md <<'TXT'
# Decimals
## Goals
- Round a decimal to the nearest tenth
## Schedule
- 20 minutes: rounding demo
- 30 minutes: rounding worksheet
## Evaluation
- Rounding worksheet marked against the key
TXT
printf 'Criterion,Weight,Excellent,Good,Poor\nContent,50,Deep,Fine,Thin\nStyle,30,Clear,Ok,\nSources,30,Many,Some,None\n' > rub.csv
printf 'Criterion;Weight;Top;Low\nIdeas;60;Rich;Poor\nForm;40;Neat;Messy\n' > rub_ok.csv
printf 'student,quiz,essay,exam\nweight,20,30,50\nmax,10,100,100\nAna,8,75,82\nBen,6,,40\nCy,x,50,55\nDee,10,100,100\n' > g.csv
printf '1. What is 2+2?\n   a) 3\n   b) 4\n2. Name a prime.\n4. Capital?\n5. Another?\n\n## Answer key\n1. C\n2. 7\n3. blah\n4. Paris\n' > w.md
printf '1. Q one\n2. Q two\n\nAnswers\n1. a\n2. b\n' > w_ok.md
sum0=$(md5sum plan.md rub.csv g.csv w.md | md5sum)
# plan
php "$LT" plan plan.md p.md >/dev/null; t "[ \$? = 1 ]" "a lesson plan with errors must exit 1, like the other checks"
t "has 'plan.md(9) Error: the activities add up to 55 minutes, 5 more than the lesson of 50' p.md" "minutes over the length: \$(grep Error p.md)"
t "grep -q 'Warning: nothing in the Assessment mentions \"Compare two decimals' p.md" "an objective with no assessment keyword: \$(grep Warning p.md)"
t "! grep -q 'add fractions' p.md || ! grep -q 'Warning: nothing in the Assessment mentions \"Students will be able to add' p.md" "an objective that the assessment does mention was flagged"
php "$LT" plan good.md pg.md minutes=50 >/dev/null; t "has '0 errors, 0 warnings' pg.md && has 'Lesson length: 50 minutes' pg.md" "minutes=50 as an argument: \$(grep -E 'Error|Warning' pg.md)"
php "$LT" plan good.md pg.md minutes=60 >/dev/null; t "has '10 short of the lesson of 60' pg.md" "activities short of the length"
printf '# Plan\n## Activities\n- 10 min: x\n- no minutes here\n' > bare.md; php "$LT" plan bare.md pb.md >/dev/null; t "has 'no Objectives section' pb.md && has 'no minutes given for this activity' pb.md && has 'no Assessment' pb.md" "a bare plan: \$(grep -E 'Error|Warning' pb.md)"
# rubric
php "$LT" rubric rub.csv r.md >/dev/null; t "has 'the weights add up to 110, not 100' r.md && has 'no description for the level \"Poor\" of \"Style\"' r.md" "rubric weights/empty cell: \$(grep -E 'Error|Warning' r.md)"
t "has '| Content | 50 | Deep (50 pts) | Fine (33.33 pts) | Thin (16.67 pts) |' r.md" "points per level: \$(grep Content r.md)"
php "$LT" rubric rub_ok.csv r2.md >/dev/null; t "has '0 errors, 0 warnings' r2.md && has 'Ideas | 60 | Rich (60 pts) | Poor (30 pts)' r2.md" "a good semicolon rubric: \$(cat r2.md | head -12)"
# grades
php "$LT" grades g.csv gr.md below=60 >/dev/null; t "has '| Ana | 79.5 |' gr.md && has '| Dee | 100 |' gr.md" "weighted averages: \$(sed -n 8,14p gr.md)"
t "has '| Ben | 45.7 |' gr.md" "average of the grades that exist (Ben, missing essay)"
t "has 'g.csv(5) Warning: Ben has no grade for: essay' gr.md" "missing grade named with its line"
t "has 'g.csv(6) Error: the grade \"x\" of Cy in \"quiz\" is not a number' gr.md" "a non-numeric grade"
t "has '- Ben: 45.7' gr.md && has '- Cy: 53.1' gr.md && ! has '- Ana:' gr.md" "students below 60: \$(grep -A4 'Below 60' gr.md)"
t "has '| below 50 | 1 |' gr.md && has '| 90-100 | 1 |' gr.md" "distribution: \$(grep -A9 Distribution gr.md)"
php "$LT" grades g.csv gr2.md below=80 >/dev/null; t "has '- Ana: 79.5' gr2.md" "threshold argument"
# answers
php "$LT" answers w.md a.md >/dev/null
t "has 'answer 1 is \"C\" but question 1 only offers A, B' a.md" "multiple-choice letter outside the options: \$(grep -E 'Error|Warning' a.md)"
t "has 'question 5 has no answer in the key' a.md && has 'the key has an answer 3 but the worksheet has no question 3' a.md" "missing and extra answers"
t "has 'the question numbers skip 3' a.md" "numbering gap"
php "$LT" answers w_ok.md a2.md >/dev/null; t "has '0 errors, 0 warnings' a2.md" "a consistent worksheet: \$(grep -E 'Error|Warning' a2.md)"
# refusals, original untouched, guard, json
printf '\xF9\xEC\n' > ansi.txt; php "$LT" plan ansi.txt x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a non-UTF-8 file was not refused"
: > empty.md; php "$LT" plan empty.md x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "an empty file was not refused"
php "$LT" plan nope.md x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a missing file was not refused"
php "$LT" frob plan.md x.md >/dev/null 2>&1; t "[ \$? = 2 ]" "an unknown subcommand was not refused"
printf 'a,b\n' > one.csv; php "$LT" rubric one.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a rubric with no level column was not refused"
t "[ \"\$(md5sum plan.md rub.csv g.csv w.md | md5sum)\" = \"$sum0\" ]" "an original was changed"
t "head -20 '$LT' | grep -q \"PHP_SAPI !== 'cli'\"" "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/lesson_tool (plan|rubric|grades|answers) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/lesson.json" > pc 2>&1; t "[ \"\$(cat pc)\" = 4 ]" "lesson.json presets: \$(cat pc)"
cat > kv.php <<'PHP'
<?php require $argv[1] . '/cockpit_app/kinds_lib.php'; $k = json_decode(file_get_contents($argv[2]), true); $e = ''; $v = kind_validate($k, $e); if (!$v) { echo "invalid: $e"; exit(1); } foreach (['id','name','icon','description','note','verify','group','details','examples','tools'] as $f) if (empty($v[$f])) { echo "missing $f"; exit(1); } if ($v['note'] !== $k['note'] || $v['details'] !== $k['details']) { echo 'text too long'; exit(1); } echo 'ok';
PHP
php kv.php "$ROOT" "$ROOT/cockpit_app/kinds/teaching.json" > kc 2>&1; t "[ \"\$(cat kc)\" = ok ]" "the teaching kind: \$(cat kc)"
t "[ \"\$(jq -r '.tools[0].tool' '$ROOT/cockpit_app/kinds/teaching.json')\" = lesson ] && [ \"\$(jq -r .group '$ROOT/cockpit_app/kinds/teaching.json')\" = 'Research & learning' ]" "the kind does not name the tool / group"
echo "lesson_tools_test: $((n-fails)) passed, $fails failed"; [ "$fails" = 0 ]
