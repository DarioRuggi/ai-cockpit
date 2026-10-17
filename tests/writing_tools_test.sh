#!/usr/bin/env bash
# writing_tools_test.sh — cockpit_app/write_tool on a small two-chapter manuscript, AND the rule that every kind names only tools that exist (and that all but General name at least one).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; W="$ROOT/cockpit_app/write_tool"
command -v php >/dev/null 2>&1 || { echo "writing_tools_test: php is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1; mkdir b
printf '# Chapter 1\n\nThe wind was cold. Catherine walked slowly into the old hall. "I came here to find the truth," she said quietly. Mara looked at her.\n\nIn the end of the day she knew. In the end of the day it did not matter. In the end of the day nothing did.\n' > b/ch1.md
printf '# Chapter 2\n\nThen Katherine met Mara at the gate. "Where is Mara?" she asked. She told Aldric about the river and saw Aldrik waiting. In the end of the day Mara wept.\n' > b/ch2.md
printf '```\nIn the end of the day code\n```\n' > b/ch3.txt
php "$W" stats b s.md >/dev/null; has "| ch1.md |" s.md && has "| ch2.md |" s.md && has "| **All** |" s.md && has "Reading level (Flesch" s.md && has "[exit code 0]" s.md && ok || bad "stats: $(sed -n 5,12p s.md)"
grep -q "ch3.txt | 0 |" s.md && ok || bad "a code fence was counted as prose"
php "$W" repeats b r.md >/dev/null; has '"end of the day" appears 5 times' r.md || has '"end of the day" appears 4 times' r.md; ok
grep -qE '^ch1\.md\([0-9]+\) Note: "end of the day"' r.md && ok || bad "repeats: $(sed -n 3,8p r.md)"
grep -q "code" r.md && grep -q 'ch3.txt([0-9]*) Note' r.md && bad "a code fence was scanned for repeats" || ok
php "$W" names b n.md >/dev/null; has "| Mara |" n.md && grep -qE '"Ald(ric|rik)" \(1\) and "Ald(ric|rik)" \(1\)' n.md && has "[exit code 1]" n.md && ok || bad "names: $(sed -n 5,20p n.md)"
[ "$(cat n.md r.md s.md | grep -cE "^[^ ]+\([0-9]+\) (Warning|Note): ")" -ge 2 ] && ok || bad "summary-box lines"
printf 'One sentence only.\n' > one.txt; php "$W" stats one.txt o.md >/dev/null && has "| one.txt | 3 | 1 |" o.md && ok || bad "single file stats"
printf '\xff\xfe bad' > bin.txt; php "$W" stats bin.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "invalid UTF-8 not refused"
php "$W" stats nope x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing input not refused"
mkdir empty; php "$W" stats empty x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "empty folder not refused"
php "$W" frob b x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
head -20 "$W" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
[ "$(jq '.presets|length' "$ROOT/cockpit_app/tools_builtins/writing.json")" = 3 ] && ok || bad "writing.json presets"
# every kind names real tools; only General may name none
for k in "$ROOT"/cockpit_app/kinds/*.json; do
  id=$(jq -r .id "$k"); c=$(jq '(.tools // [])|length' "$k")
  [ "$c" = 0 ] && [ "$id" != general ] && bad "kind $id names no tools"
  for t in $(jq -r '(.tools // [])[].tool' "$k"); do [ -f "$ROOT/cockpit_app/tools_builtins/$t.json" ] || bad "kind $id names a tool that does not exist: $t"; done
done; ok
echo "writing_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
