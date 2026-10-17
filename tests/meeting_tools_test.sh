#!/usr/bin/env bash
# meeting_tools_test.sh — the Meeting notes tools (cockpit_app/meeting_tool, tools_builtins/meeting.json, kinds/meeting-notes.json): candidates in English, Spanish and Hebrew,
# owners, deadlines, questions, statistics, the cleaned transcript, the minutes skeleton, refusals.   bash tests/meeting_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; MT="$ROOT/cockpit_app/meeting_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "meeting_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > m.txt <<'TXT'
Anna: Okay, um, let's start. The budget is, uh, the first item.
Ben: We decided last week to go with the cloud vendor. Is that still the plan?
Anna: Yes. Ben will send the contract to legal by Friday.
Carlos: Tenemos que revisar el presupuesto antes del lunes.
Anna: Who can prepare the slides? I'll prepare the slides for the board.
Ben: The the deadline is 15/03 I think.
דנה: צריך לסגור את התקציב עד יום ראשון.
Carlos: Acordamos mantener el proveedor actual.
TXT
printf '1\n00:00:01,000 --> 00:00:04,000\nAnna: Welcome everyone, um, thanks for coming.\n\n2\n00:00:04,500 --> 00:00:09,000\nWe need to finish the report by Friday.\n\n3\n00:00:20,000 --> 00:00:25,000\nBen: I will send the draft tomorrow. Is that fine?\n\n4\n00:00:25,500 --> 00:00:30,000\nAnna: We agreed on that. uh the the next meeting is Monday.\n' > m.srt
sum0=$(md5sum m.txt m.srt | md5 2>/dev/null || md5sum m.txt m.srt | md5sum)
php "$MT" actions m.txt a.md >/dev/null; [ $? = 0 ] && ok || bad "actions exited non-zero"
has "## Decisions (2)" a.md && has "We decided last week to go with the cloud vendor." a.md && has "Acordamos mantener el proveedor actual." a.md && ok || bad "decisions (en + es): $(sed -n 5,12p a.md)"
has "**Ben**: Ben will send the contract to legal by Friday." a.md && ok || bad "owner named in the sentence"
has "**Carlos**: Tenemos que revisar el presupuesto antes del lunes." a.md && ok || bad "Spanish action with the speaker as owner"
has "**דנה**: צריך לסגור את התקציב עד יום ראשון." a.md && ok || bad "Hebrew speaker label and action"
has "## Deadlines mentioned (3)" a.md && ok || bad "deadlines (by Friday, antes del lunes, עד יום ראשון): $(grep -A5 'Deadlines' a.md)"
has "**Anna**: Who can prepare the slides?" a.md && ok || bad "a question's speaker (\"Who\" must not be taken for a name)"
has "m.txt(2) Note: [Decision]" a.md && ok || bad "the file(line) Note lines"
php "$MT" actions m.srt as.md >/dev/null; has "[00:20]" as.md && has "I will send the draft tomorrow." as.md && ok || bad "an .srt gives times, not lines: $(sed -n 5,14p as.md)"
# stats
php "$MT" stats m.srt s.md >/dev/null; has "Length: 00:30" s.md && has "| Anna | 2 |" s.md && has "| Ben | 1 |" s.md && ok || bad "stats: $(cat s.md | head -14)"
php "$MT" stats m.txt s2.md >/dev/null; has "Length: unknown" s2.md && has "| Carlos |" s2.md && ok || bad "stats of plain text"
# clean
php "$MT" clean m.srt c.md >/dev/null; has "**[00:01]** Anna: Welcome everyone, thanks for coming. We need to finish the report by Friday." c.md && ok || bad "a paragraph joins the cues of one speaker, without the filler: $(sed -n 3,5p c.md)"
has "**[00:20]** Ben:" c.md && has "**[00:25]** Anna: We agreed on that. The next meeting is Monday." c.md && ok || bad "a new paragraph at a pause or a new speaker, and the stutter 'the the' collapsed: $(sed -n 5,9p c.md)"
grep -qE '\bum\b|\buh\b' c.md && bad "fillers left in the cleaned transcript" || ok
php "$MT" clean m.txt c2.md >/dev/null; grep -q "Okay, let's start" c2.md && ok || bad "plain-text clean: $(sed -n 3,4p c2.md)"
# minutes
php "$MT" minutes m.txt mn.md "Budget meeting" >/dev/null; has "# Budget meeting" mn.md && has "## Attendees" mn.md && has "- Anna" mn.md && has "- דנה" mn.md && ok || bad "minutes header / attendees: $(head -14 mn.md)"
has "| Ben | Ben will send the contract to legal by Friday." mn.md && has "| by Friday" mn.md || has "Friday" mn.md; ok
has "## Open questions" mn.md && has "## Decisions" mn.md && has "## Action items" mn.md && ok || bad "minutes sections"
# refusals
printf '\xF9\xEC\xE5\xED\n' > ansi.txt; php "$MT" actions ansi.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-UTF-8 transcript was not refused"
: > empty.txt; php "$MT" actions empty.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an empty transcript was not refused"
php "$MT" actions nope.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
php "$MT" frob m.txt x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(md5sum m.txt m.srt | md5sum)" = "$(md5sum m.txt m.srt | md5sum)" ] && ok
php -r 'exit(0);'; head -20 "$ROOT/cockpit_app/meeting_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/meeting_tool (clean|actions|stats|minutes) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/meeting.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "meeting.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/meeting-notes.json")" = meeting ] && ok || bad "the kind does not name the tool"
# a stutter with a comma between the repeats is collapsed, and a sentence that began with a filler gets its capital
printf "Anna: Okay, um, let's start. Uh, the release is, is on Friday.\n" > st.txt
php "$MT" clean st.txt st_out.txt >/dev/null 2>&1; has "let's start. The release is on Friday." st_out.txt && ok || bad "comma stutter or capital after a filler: $(cat st_out.txt)"
echo "meeting_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
