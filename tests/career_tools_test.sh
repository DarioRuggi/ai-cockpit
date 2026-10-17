#!/usr/bin/env bash
# career_tools_test.sh — the Job search and CV tools (cockpit_app/career_tool, tools_builtins/career.json, kinds/job-search.json): CV check, CV against an ad (no invention),
# application tracker, interview question bank, refusals.   bash tests/career_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; CT="$ROOT/cockpit_app/career_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "career_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { n=$((n+1)); echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
t() { if eval "$1"; then ok; else bad "$2"; fi; }
cd "$T" || exit 1
cat > cv.md <<'TXT'
# Jane Doe
jane@example.org

## Experience

### Engineer, Acme
Jan 2015 - Dec 2017
- Responsible for the build system
- Was promoted by the board

### Analyst, Beta
03/2018 - 06/2019
- Worked on reports

### Lead, Gamma
2019 - Present
- Handled deployments
TXT
cat > gap.md <<'TXT'
Pat Example, pat@example.com, +44 20 7946 0958, https://example.com/pat
## Experience
Cashier, Shop. March 2012 to May 2014
Clerk, Office. Jan 2016 - Dec 2018
Driver, Firm. Dec 2017 - Oct 2020
Verantwortlich für die Kasse.
responsable de la caisse.
Bad dates: Jun 2020 - Jan 2019
TXT
cat > ad.txt <<'TXT'
Senior Python Developer

Requirements:
- 5 years of Python development
- Experience with Kubernetes and Docker
- Strong communication skills

Responsibilities:
- Build services
TXT
printf 'I know Python and Docker, and I write well. python, docker, communication.\nmail@x.org\n' > cv2.md
cat > tr.csv <<'TXT'
company,role,applied,status,follow-up
Acme,Dev,2026-09-01,Applied,
Beta,Ops,2026-10-01,Interview,2026-10-10
Gamma,QA,2026-09-20,Rejected,
Delta,PM,2026-10-12,Applied,2026-10-20
Eps,UX,13/10/2026,Applied,
Zeta,SRE,2026-13-45,Applied,
TXT
sum0=$(md5sum cv.md gap.md ad.txt tr.csv | md5sum)
# cv
php "$CT" cv cv.md c.md >/dev/null; t "[ \$? = 0 ]" "cv exited non-zero"
t "has 'Dated entries found: 3' c.md" "dated entries: \$(head -5 c.md)"
t "has 'cv.md(16) Note: overlaps the entry on line 12 by 6 months' c.md" "an overlap: \$(grep -E 'Note|Warning' c.md)"
t "has 'cv.md(8) Warning: weak phrase \"responsible for\"' c.md && has 'cv.md(13) Warning: weak phrase \"worked on\"' c.md" "weak phrases with their lines"
t "has 'passive phrasing (\"Was promoted by\")' c.md" "passive phrasing"
t "grep -q 'Warning: date written as .* while most are' c.md" "mixed date formats"
t "! grep -q 'Error: no e-mail' c.md" "the e-mail was not found"
t "has 'Warning: no phone number found' c.md" "a missing phone number"
php "$CT" cv gap.md g.md >/dev/null
t "has 'gap.md(4) Warning: a gap of 19 months before this entry' g.md" "a date gap (May 2014 to Jan 2016): \$(grep -E 'Error|Warning|Note' g.md)"
t "has 'gap.md(5) Note: overlaps the entry on line 4 by 13 months' g.md || has 'gap.md(5) Note: overlaps' g.md" "an overlap between two jobs"
t "has 'gap.md(8) Error: the end (Jan 2019) is before the start (Jun 2020)' g.md" "an end before its start"
t "has 'weak phrase \"verantwortlich für\"' g.md" "a German weak phrase"
t "! grep -qE 'Error: no e-mail|Warning: no phone|Note: no web' g.md" "contact details were not recognised"
# match
php "$CT" match cv2.md m.md ad.txt >/dev/null; t "has 'never add a skill' m.md || has 'never add a skill, tool' m.md || has 'never add a skill' m.md" "the no-invention rule is not in the output"
t "has 'python' m.md && grep -A3 'Found in the CV' m.md | grep -q 'python' && grep -A6 'Not found in the CV' m.md | grep -q 'kubernetes'" "found/missing: \$(sed -n 7,16p m.md)"
t "! grep -A6 'Found in the CV' m.md | grep -q kubernetes" "kubernetes was reported as found"
php "$CT" match cv2.md m2.md >/dev/null 2>&1; t "[ \$? = 2 ]" "match without an ad was not refused"
# tracker
php "$CT" tracker tr.csv tk.md today=2026-10-14 >/dev/null; t "has 'Applications: 6' tk.md" "applications counted: \$(sed -n 5,8p tk.md)"
t "has 'Acme (Dev): applied 43 days ago, no reply and no follow-up date' tk.md" "a follow-up due by age: \$(grep -A5 'Follow-ups due' tk.md)"
t "has 'Beta (Ops): follow-up date 2026-10-10 (4 days ago)' tk.md" "a follow-up due by date"
t "! grep -qE 'Gamma \(|Delta \(' tk.md" "a rejected or not-yet-due row was listed as due"
t "has 'response rate: 33%' tk.md" "response rate (2 of 6): \$(grep 'response rate' tk.md)"
t "has '| applied | 4 |' tk.md && has '| rejected | 1 |' tk.md" "status counts"
t "has 'tr.csv(7) Error: the application date' tk.md || has 'tr.csv(7) Error' tk.md" "an unreadable date: \$(grep Error tk.md)"
php "$CT" tracker tr.csv tk2.md today=2026-10-25 >/dev/null; t "has 'Delta (PM): follow-up date 2026-10-20 (5 days ago)' tk2.md" "a later 'today'"
php "$CT" tracker tr.csv x.md today=nonsense >/dev/null 2>&1; t "[ \$? = 2 ]" "a bad today was not refused"
printf 'a,b\n1,2\n' > nocol.csv; php "$CT" tracker nocol.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a tracker without a company/status column was not refused"
# questions
php "$CT" questions ad.txt q.md >/dev/null; t "has '## 1. 5 years of Python development' q.md && has '## 2. Experience with Kubernetes and Docker' q.md && has '## 3. Strong communication skills' q.md" "requirements to questions: \$(grep '^## ' q.md)"
t "! has 'Build services' q.md" "a responsibilities bullet became a requirement"
t "has 'My answer (true examples only):' q.md && has 'Tell me about yourself.' q.md" "answer fields and standard questions"
printf 'We are a nice company.\n' > noreq.txt; php "$CT" questions noreq.txt x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "an ad with no requirements was not refused"
# refusals, untouched, guard, json
printf '\xF9\xEC\n' > ansi.txt; php "$CT" cv ansi.txt x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a non-UTF-8 file was not refused"
: > empty.md; php "$CT" cv empty.md x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "an empty file was not refused"
php "$CT" cv nope.md x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a missing file was not refused"
php "$CT" frob cv.md x.md >/dev/null 2>&1; t "[ \$? = 2 ]" "an unknown subcommand was not refused"
t "[ \"\$(md5sum cv.md gap.md ad.txt tr.csv | md5sum)\" = \"$sum0\" ]" "an original was changed"
t "head -20 '$CT' | grep -q \"PHP_SAPI !== 'cli'\"" "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/career_tool (cv|match|tracker|questions) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/career.json" > pc 2>&1; t "[ \"\$(cat pc)\" = 4 ]" "career.json presets: \$(cat pc)"
cat > kv.php <<'PHP'
<?php require $argv[1] . '/cockpit_app/kinds_lib.php'; $k = json_decode(file_get_contents($argv[2]), true); $e = ''; $v = kind_validate($k, $e); if (!$v) { echo "invalid: $e"; exit(1); } foreach (['id','name','icon','description','note','verify','group','details','examples','tools'] as $f) if (empty($v[$f])) { echo "missing $f"; exit(1); } if ($v['note'] !== $k['note'] || $v['details'] !== $k['details']) { echo 'text too long'; exit(1); } echo 'ok';
PHP
php kv.php "$ROOT" "$ROOT/cockpit_app/kinds/job-search.json" > kc 2>&1; t "[ \"\$(cat kc)\" = ok ]" "the job-search kind: \$(cat kc)"
t "[ \"\$(jq -r '.tools[0].tool' '$ROOT/cockpit_app/kinds/job-search.json')\" = career ] && [ \"\$(jq -r .group '$ROOT/cockpit_app/kinds/job-search.json')\" = 'Work & community' ]" "the kind does not name the tool / group"
t "jq -r .note '$ROOT/cockpit_app/kinds/job-search.json' | grep -q 'Never add a skill'" "the kind note lacks the no-invention rule"
echo "career_tools_test: $((n-fails)) passed, $fails failed"; [ "$fails" = 0 ]
