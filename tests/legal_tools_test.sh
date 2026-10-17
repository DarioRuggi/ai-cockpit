#!/usr/bin/env bash
# legal_tools_test.sh — the Legal review tools (cockpit_app/legal_tool, tools_builtins/legal.json, kinds/legal-review.json) on two versions of a small contract: the comparison and the
# changes that matter, the document check, clauses, key terms, text from docx/pdf.   bash tests/legal_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LT="$ROOT/cockpit_app/legal_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "legal_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > v1.txt <<'TXT'
SERVICES AGREEMENT

This Agreement is made on 15/03/2026 between Acme Ltd. (the "Company") and Beta Inc. (the "Supplier").

1. Definitions

"Services" means the services described in Schedule A.

"Fee" means the amount of $10,000 per month.

2. Payment

2.1 The Company shall pay the Fee within thirty (30) days of each invoice.

2.2 Late payments bear interest at 5% per year.

3. Term

3.1 This Agreement continues for twelve (12) months and may be terminated by either party on 30 days notice.

4. Liability

4.1 The Supplier shall be liable for all damages arising from the Services, see Section 6.

5. Confidentiality

5.1 Each party shall keep the other's information confidential.

Signed: ____________   Date: [•]
TXT
sed -e 's/thirty (30) days/sixty (30) days/' -e 's/The Supplier shall be liable for all damages/The Supplier may be liable for damages/' -e 's/on 30 days notice/on 90 days notice/' v1.txt | awk '/^5\. Confidentiality/{print "4A. Non-compete\n\n4A.1 The Supplier shall not compete with the Company during the term.\n"} {print}' | grep -v "^2.2" > v2.txt
sum0=$(md5sum v1.txt v2.txt | md5sum)
# compare
php "$LT" compare v1.txt c.md with=v2.txt >/dev/null; [ $? = 0 ] && ok || bad "compare exited non-zero"
has "unchanged 11, changed 3, removed 1, added 2" c.md && ok || bad "paragraph counts: $(sed -n 3p c.md)"
has "~~thirty~~ **sixty**" c.md && has "~~30~~ **90**" c.md && ok || bad "word-level redline: $(grep -E 'sixty|90' c.md | head -3)"
has "~~shall~~ **may**" c.md && ok || bad "shall -> may"
has "### Removed — clause 2.2" c.md && has "### Added — clause 4A" c.md && ok || bad "removed / added with clause labels"
has 'Warning: clause 2.1: "thirty" became "sixty" (a figure or date)' c.md && ok || bad "number words must count as a figure change: $(grep -E '2.1' c.md | tail -2)"
has 'Warning: clause 3.1: "30" became "90"' c.md && has '"shall" became "may" (changes who must, may or is excluded)' c.md && ok || bad "risky changes listed"
has "v2.txt(13) Warning" c.md && ok || bad "points carry the line in the NEW document"
grep -qE '^v2.txt\(0\)' c.md && bad "a removed paragraph has line 0" || ok
[ "$(grep -cE '^(.+?)\([0-9]+\) (Warning|Note): ' c.md)" -ge 6 ] && ok || bad "the summary lines"
php "$LT" compare v1.txt same.md with=v1.txt >/dev/null; has "No differences in the text." same.md && ok || bad "identical documents"
php "$LT" compare v1.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "compare without with= was not refused"
php "$LT" compare v1.txt x.md with=nope.txt >/dev/null 2>&1; [ $? = 1 ] && ok || bad "compare with a missing file was not refused"
# check
php "$LT" check v2.txt k.md >/dev/null; has "[exit code 1]" k.md && ok || bad "check of v2 must exit 1"
has "refers to clause 6, which does not exist" k.md && ok || bad "missing cross-reference: $(grep -E 'Error|Warning' k.md)"
has 'the words say "sixty" (60) but the figure is (30)' k.md && ok || bad "words against figure"
has "a placeholder is left in" k.md && ok || bad "placeholder"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' k.md)" -ge 3 ] && ok || bad "summary-box regex"
php "$LT" check v1.txt k1.md >/dev/null; has "the words say" k1.md && bad "v1 'thirty (30)' is consistent" || ok
printf '1. First\n\n2. Second\n\n4. Fourth\n\n"Widget" means a thing.\n\nThe parties agree.\n' > gap.txt; php "$LT" check gap.txt kg.md >/dev/null; has "clause 3 is missing from the numbering" kg.md && has 'the defined term "Widget" is never used' kg.md && ok || bad "numbering gap / unused definition: $(grep -E 'Warning' kg.md)"
# clauses, terms
php "$LT" clauses v2.txt cl.md >/dev/null; has "| 4A.1 |" cl.md && has "| 2.1 |" cl.md && ok || bad "clauses: $(sed -n 5,9p cl.md)"
php "$LT" terms v2.txt tm.md >/dev/null; has '$10,000' tm.md && has "90 days" tm.md && has "15/03/2026" tm.md && has "## Governing law and disputes (0 paragraph(s))" tm.md && has "Nothing found: is it missing?" tm.md && ok || bad "key terms: $(sed -n 3,16p tm.md)"
# text from docx and pdf
if command -v pandoc >/dev/null 2>&1; then pandoc v1.txt -f markdown -o v1.docx 2>/dev/null; php "$LT" text v1.docx t.txt >/dev/null; has "SERVICES AGREEMENT" t.txt && ok || bad "text of a docx"; php "$LT" compare v1.docx dc.md with=v2.txt >/dev/null 2>&1; has "Comparison:" dc.md && ok || bad "compare a docx with a txt"; fi
if command -v soffice >/dev/null 2>&1 && command -v pdftotext >/dev/null 2>&1; then soffice --headless --convert-to pdf --outdir pd v1.txt >/dev/null 2>&1; [ -f pd/v1.pdf ] && { php "$LT" text pd/v1.pdf p.txt >/dev/null; has "SERVICES AGREEMENT" p.txt && ok || bad "text of a PDF"; }; fi
printf '\xE2\x80\x9CS\xE9rvice\xE2\x80\x9D' > /dev/null
: > empty.txt; php "$LT" check empty.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an empty document was not refused"
php "$LT" check nope.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
php "$LT" frob v1.txt x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(md5sum v1.txt v2.txt | md5sum)" = "$sum0" ] && ok || bad "an original changed"
ls -d /tmp/legal_* 2>/dev/null | grep -q . && bad "scratch files left in /tmp" || ok
head -20 "$ROOT/cockpit_app/legal_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/legal_tool (compare|check|clauses|terms|text) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/legal.json" > pc 2>&1; [ "$(cat pc)" = 5 ] && ok || bad "legal.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/legal-review.json")" = legal ] && ok || bad "the kind does not name the tool"
echo "legal_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
