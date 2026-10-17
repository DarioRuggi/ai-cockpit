#!/usr/bin/env bash
# lang_tools_test.sh — the Language study tools (cockpit_app/lang_tool, tools_builtins/lang.json, kinds/language-study.json): vocabulary check, Anki cards, frequency, spoken list (eSpeak/Piper),
# the speech comparison through Whisper (when it is installed).   bash tests/lang_tools_test.sh     SKIPPED without php (mbstring); the audio parts without ffmpeg/espeak-ng; the comparison without whisper
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LT="$ROOT/cockpit_app/lang_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "lang_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
printf 'term;translation;example;tags\nhola;hello;Hola, ¿cómo estás?;greetings\ngracias;thank you;;polite\nhola;hello;;dup\nadiós;goodbye;Adiós amigo;greetings\nvacío;;;\nsol;sol;;\nשלום;peace;שלום עולם;he\nmañana;tomorrow;;time\nmañana;morning;;time\n' > v.csv
sum0=$(md5sum v.csv | cut -c1-32)
# check
php "$LT" check v.csv c.md >/dev/null; has "v.csv(4) Warning: 'hola' repeats line 2" c.md && ok || bad "duplicate: $(grep -E 'Warning|Error' c.md)"
has "v.csv(6) Error: 'vacío' has no translation" c.md && ok || bad "empty translation"
has "v.csv(7) Warning: the term and the translation are the same: 'sol'" c.md && ok || bad "same on both sides"
has "v.csv(10) Note: 'mañana' also has another translation on line 9" c.md && ok || bad "second translation"
has "- Entries: 9" c.md && has "[exit code 1]" c.md && ok || bad "entries / exit"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md)" = 3 ] && ok || bad "summary-box regex"
printf 'a\xE2\x80\x8Bb;x\n' > inv.csv; php "$LT" check inv.csv i.md >/dev/null; has "an invisible character" i.md && ok || bad "a zero-width space was not flagged"
printf 'dog - perro\ncat = gato\nbird: pájaro\n' > dash.txt; php "$LT" cards dash.txt d.txt >/dev/null; [ "$(grep -c '	' d.txt)" = 3 ] && has "dog	perro" d.txt && has "cat	gato" d.txt && has "bird	pájaro" d.txt && ok || bad "' - ', ' = ' and ': ' separators: $(cat d.txt)"
printf 'term\ttranslation\nhund\tdog\n' > tab.tsv; php "$LT" cards tab.tsv t.txt >/dev/null; has "hund	dog" t.txt && ok || bad "a tab-separated list with a header"
# cards
php "$LT" cards v.csv k.txt both >/dev/null; has "#separator:tab" k.txt && has "#html:true" k.txt && ok || bad "Anki header lines"
has "hola	hello<br><i>Hola, ¿cómo estás?</i>	greetings" k.txt && has "hello	hola	greetings" k.txt && ok || bad "card and reverse card: $(sed -n 4,6p k.txt)"
[ "$(grep -c '^hola	' k.txt)" = 1 ] && ok || bad "a repeated entry became two cards"
grep -q '^vacío' k.txt && bad "an entry with no translation became a card" || ok
[ "$(grep -c '^sol	sol' k.txt)" = 1 ] && ok || bad "a term equal to its translation gets one card, not a reverse twin"
php "$LT" cards v.csv k2.txt >/dev/null; has "hello	hola" k2.txt && bad "reverse cards without 'both'" || ok
printf '<b>x</b>;a & b\n' > html.csv; php "$LT" cards html.csv h.txt >/dev/null; has "&lt;b&gt;x&lt;/b&gt;	a &amp; b" h.txt && ok || bad "HTML in the list was not escaped"
# frequency (Hebrew vowel marks ignored; one-letter words count too)
printf 'the cat sat on the mat. The cat saw the dog. A dog is a dog; the mat is red.\n' > t.txt; php "$LT" freq t.txt f.md >/dev/null; has "| 1 | the | 5 |" f.md && has "| 2 | dog | 3 |" f.md && has "Words: 20; different words: 10" f.md && ok || bad "frequency: $(sed -n 3,10p f.md)"
printf 'שָׁלוֹם שלום שלום עולם\n' > he.txt; php "$LT" freq he.txt fh.md >/dev/null; has "| 1 | שלום | 3 |" fh.md && ok || bad "Hebrew vowel marks must not split a word: $(sed -n 7,10p fh.md)"
# audio
if command -v ffmpeg >/dev/null 2>&1 && command -v espeak-ng >/dev/null 2>&1; then
  printf 'hola;hello\ngracias;thank you\n' > sp.csv; php "$LT" speak sp.csv sp.mp3 term=es trans=en pause=1 >/dev/null; d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 sp.mp3 2>/dev/null); awk -v d="${d:-0}" 'BEGIN{exit !(d > 4)}' && ok || bad "the spoken list is only ${d:-0} s long"
  printf 'שלום;peace\n' > he.csv; php "$LT" speak he.csv he.mp3 term=he trans=en pause=1 >/dev/null 2>&1; [ -s he.mp3 ] && ok || bad "a Hebrew term could not be spoken"
  php "$LT" speak sp.csv x.ogg >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unsupported output was not refused"
  php "$LT" speak sp.csv x.mp3 'term=../x' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad language code was not refused"
  ls -d /tmp/lang_sp_* 2>/dev/null | grep -q . && bad "a scratch folder was left in /tmp" || ok
  # compare through whisper, only when it is installed
  if [ -x "$HOME/ai-tools/whisper.cpp/build/bin/whisper-cli" ] && ls "$HOME"/ai-tools/whisper.cpp/models/ggml-*.bin >/dev/null 2>&1; then
    espeak-ng -v en -s 150 -w say.wav "The quick brown fox jumps over the lazy dog. Today we will practise speaking English clearly." 2>/dev/null
    printf 'The quick brown cat jumps over the lazy dog. Today we will practise speaking English clearly and slowly.\n' > exp.txt
    php "$LT" compare say.wav cmp.md "text=$T/exp.txt" lang=en >/dev/null 2>&1; has "Accuracy: **" cmp.md && has "| cat | fox |" cmp.md && has "slowly" cmp.md && ok || bad "compare: $(head -16 cmp.md)"
    php "$LT" compare say.wav x.md "text=/nonexistent" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing expected text was not refused"
    php "$LT" compare say.wav x.md "text=$T/exp.txt" "lang=en;rm -rf" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad language value was not refused"
  else echo "  (whisper.cpp or its model is missing: the comparison was skipped)"; fi
else echo "  (ffmpeg / espeak-ng missing: the audio checks were skipped)"; fi
# refusals, the original, the guard, the definitions
printf '\xF9\xEC\xE5\xED;x\n' > ansi.csv; php "$LT" check ansi.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-UTF-8 list was not refused"
: > empty.csv; php "$LT" cards empty.csv x.txt >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an empty list was not refused"
php "$LT" check nope.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
[ "$(md5sum v.csv | cut -c1-32)" = "$sum0" ] && ok || bad "the original changed"
head -20 "$ROOT/cockpit_app/lang_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/lang_tool (check|cards|freq|speak|compare) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/lang.json" > pc 2>&1; [ "$(cat pc)" = 5 ] && ok || bad "lang.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/language-study.json")" = lang ] && ok || bad "the kind does not name the tool"
echo "lang_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
