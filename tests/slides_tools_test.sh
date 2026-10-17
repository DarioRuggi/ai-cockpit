#!/usr/bin/env bash
# slides_tools_test.sh — the Presentation tools (cockpit_app/slides_tool, lo_lib.php, tools_builtins/slides.json, kinds/presentation.json): decks built with
# pandoc, checked, outlined, drawn as PDF and as a contact sheet, read through LibreOffice when they are .odp or .ppt, refusals, the original untouched.
#   bash tests/slides_tools_test.sh     SKIPPED without php (zip, dom), pandoc; the LibreOffice parts without soffice
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/cockpit_app/slides_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^zip$' && php -m 2>/dev/null | grep -qi '^dom$' || { echo "slides_tools_test: php with zip + dom is needed - SKIPPED"; exit 0; }
command -v pandoc >/dev/null 2>&1 || { echo "slides_tools_test: pandoc is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
command -v convert >/dev/null 2>&1 && convert -size 120x60 xc:blue pic.png || printf '\x89PNG\r\n\x1a\n' > pic.png
LONG=$(printf 'word%.0s ' $(seq 1 70))
cat > deck.md <<MD
---
title: Demo deck
---

# Intro

- one
- two

::: notes
Intro notes
:::

# Wall

$LONG

# Intro

![](pic.png)

---

- a slide with no heading at all

# Pic with alt

![A blue box](pic.png)
MD
pandoc deck.md -t pptx -o deck.pptx 2>"$T/pandoc.err"; [ -f deck.pptx ] && ok || bad "pandoc did not build the deck: $(cat "$T/pandoc.err")"
sum0=$(md5sum deck.pptx | cut -c1-32)
# check
php "$ST" check deck.pptx c.md >/dev/null; [ $? = 0 ] && ok || bad "check exited non-zero"
has "- Slides: 6" c.md && ok || bad "slide count: $(sed -n 3p c.md)"
has "deck.pptx(3) Warning: 71 words on one slide" c.md && ok || bad "wall of text: $(grep '(3)' c.md)"
has "deck.pptx(3) Warning: a paragraph of 70 words" c.md && ok || bad "long paragraph"
has "deck.pptx(5) Warning: the slide has no title" c.md && ok || bad "slide with no title"
has "deck.pptx(4) Warning: picture 'Picture 1' has no description" c.md && ok || bad "picture with a file name as its description must count as undescribed"
has "deck.pptx(6) Warning: picture" c.md && ok || bad "slide 6 picture (no real alt) not flagged: $(grep '(6)' c.md)"
has "deck.pptx(4) Note: the title 'Intro' repeats slide 2" c.md && ok || bad "repeated title"
has "5 of 6 slides have no speaker notes" c.md && ok || bad "notes count"
has "[exit code 0]" c.md && has "(0 errors, 5 warnings)" c.md && ok || bad "counts: $(grep -E 'Problems|exit' c.md)"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md)" = 5 ] && ok || bad "summary-box regex does not match the five lines"
# outline
php "$ST" outline deck.pptx o.md >/dev/null; has "## 2. Intro" o.md && has "> Notes: Intro notes" o.md && has "## 5. (no title)" o.md && has "no description" o.md && ok || bad "outline: $(head -12 o.md)"
# tiny text, many fonts, macros
php "$ROOT/tests/slides_fixture.php" deck.pptx fx >/dev/null
php "$ST" check fx/tiny.pptx t.md >/dev/null; has "text as small as 10 pt" t.md && has "4 different fonts" t.md && ok || bad "tiny text / fonts: $(grep -E 'small|fonts' t.md)"
php "$ST" check fx/macro.pptm m.md >/dev/null; has "contains macros" m.md && ok || bad "macro note"
# an empty deck and a damaged file
printf 'not a zip' > broken.pptx; php "$ST" check broken.pptx r.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a damaged deck was not refused"
php "$ST" check nope.pptx r.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
echo hi > a.txt; php "$ST" check a.txt r.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-presentation was not refused"
php "$ST" frob deck.pptx r.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
# a missing picture stops pandoc, with its name
printf '# A\n\n![](missing.png)\n' > miss.md; pandoc miss.md -t pptx -o miss.pptx 2>miss.err; [ ! -f miss.pptx ] && grep -qi "missing.png" miss.err && ok || bad "a missing picture did not stop pandoc with its name"
# LibreOffice parts
if command -v soffice >/dev/null 2>&1; then
  php "$ST" topdf deck.pptx deck.pdf >/dev/null; head -c 4 deck.pdf | grep -q '%PDF' && ok || bad "pdf not written"
  command -v pdfinfo >/dev/null 2>&1 && { [ "$(pdfinfo deck.pdf 2>/dev/null | awk '/^Pages:/{print $2}')" = 6 ] && ok || bad "the PDF has the wrong number of pages"; }
  if command -v montage >/dev/null 2>&1 && command -v pdftoppm >/dev/null 2>&1; then
    php "$ST" sheet deck.pptx sheet.png >/dev/null; head -c 8 sheet.png | grep -q PNG && ok || bad "contact sheet not a PNG"
    w=$(identify -format %w sheet.png 2>/dev/null); [ "${w:-0}" -gt 800 ] && ok || bad "the contact sheet is too small (${w:-?} px wide)"
  fi
  # .odp: made by the convert preset, then read by the odp reader; and back to .pptx
  php "$ST" convert deck.pptx deck.odp >/dev/null; [ -f deck.odp ] && { php "$ST" check deck.odp od.md >/dev/null; has "- Slides: 6" od.md && has "deck.odp(3) Warning: 71 words" od.md && ok || bad "odp read: $(head -8 od.md)"; } || bad "convert to odp failed"
  php "$ST" convert deck.odp back.pptx >/dev/null; [ -f back.pptx ] && php "$ST" outline back.pptx ob.md >/dev/null && has "## 3. Wall" ob.md && ok || bad "odp back to pptx"
  php "$ST" convert deck.pptx deck.txt >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown deck format was not refused"
  php "$ST" convert fx/macro.pptm nomacro.odp 2>&1 | grep -q . ; ok
  # an older .ppt is read through LibreOffice
  soffice --headless --convert-to ppt --outdir old deck.pptx >/dev/null 2>&1
  [ -f old/deck.ppt ] && { php "$ST" check old/deck.ppt p.md >/dev/null; has "- Slides: 6" p.md && ok || bad "ppt read: $(head -4 p.md)"; }
  ls -d /tmp/lo_* 2>/dev/null | grep -q . && bad "a LibreOffice scratch folder was left in /tmp" || ok
else echo "  (soffice missing: the LibreOffice checks were skipped)"; fi
[ "$(md5sum deck.pptx | cut -c1-32)" = "$sum0" ] && ok || bad "the original deck changed"
# the definitions
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^(php \{WEBROOT\}/slides_tool (check|outline|sheet|topdf|convert)|pandoc \{INPUT\} -t pptx) ~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/slides.json" > pc 2>&1; [ "$(cat pc)" = 7 ] && ok || bad "slides.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/presentation.json")" = slides ] && ok || bad "the kind does not name the tool"
head -20 "$ROOT/cockpit_app/lo_lib.php" | grep -q "PHP_SAPI !== 'cli'" && head -20 "$ROOT/cockpit_app/slides_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "a library or tool has no command-line-only guard"
echo "slides_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
