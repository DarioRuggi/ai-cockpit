#!/usr/bin/env bash
# translate_tools_test.sh — cockpit_app/translate_tool against a FAKE LibreTranslate (php -S): .txt / .md / .srt / .vtt are read for what they are, code and links and placeholders
# never reach the translator and come back, a lost placeholder leaves THAT segment untranslated and reported, batching, errors, check/languages.   bash tests/translate_tools_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TT="$ROOT/cockpit_app/translate_tool"
command -v php >/dev/null 2>&1 && php -m | grep -qi '^curl$' || { echo "translate_tools_test: php with curl is needed - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/tt_XXXX) || exit 1; PID=0; trap '[ $PID != 0 ] && kill $PID 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cat > "$T/fake.php" <<'PHP'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH); header('Content-Type: application/json');
if ($p === '/languages') { echo json_encode([['code' => 'en', 'name' => 'English', 'targets' => ['en', 'he', 'es']], ['code' => 'he', 'name' => 'Hebrew', 'targets' => ['en', 'he']]]); exit; }
$j = json_decode(file_get_contents('php://input'), true); file_put_contents(__DIR__ . '/last.json', json_encode($j)); @file_put_contents(__DIR__ . '/calls', "x\n", FILE_APPEND);
if (($j['target'] ?? '') === 'xx') { http_response_code(400); echo json_encode(['error' => 'xx is not supported']); exit; }
$out = [];
foreach ((array)$j['q'] as $q) {
    if (strpos($q, 'DROPME') !== false) { $out[] = preg_replace('/XQ\d+Z/', '', $q); continue; }     // a translator that eats the placeholders
    $out[] = '<' . $j['target'] . '> ' . $q;
}
echo json_encode(['translatedText' => $out]);
PHP
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT "$T/fake.php" >"$T/srv.log" 2>&1 & PID=$!
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/languages" && break; sleep 0.2; done
export COCKPIT_LT_URL="http://127.0.0.1:$PORT"; cd "$T" || exit 1
cat > doc.md <<'MD'
---
title: Keep this front matter
---
# Heading one

A paragraph with `inline code`, a [link](https://example.com/page) and a bare https://example.org/x url.

- First item with {placeholder} and %s
- [ ] A task item

```bash
echo "this must not be translated"
```

> A quote line

1. Numbered item
MD
php "$TT" text doc.md doc_he.md to=he >/dev/null; [ $? = 0 ] && ok || bad "md translate exit"
has "title: Keep this front matter" doc_he.md && ok || bad "front matter must stay as it is"
has "# <he> Heading one" doc_he.md && ok || bad "heading prefix kept, text translated: $(sed -n 4,6p doc_he.md)"
has '<he> A paragraph with `inline code`, a [link](https://example.com/page) and a bare https://example.org/x url.' doc_he.md && ok || bad "inline code, link and url come back unchanged: $(sed -n 6,8p doc_he.md)"
has '- <he> First item with {placeholder} and %s' doc_he.md && has '- [ ] <he> A task item' doc_he.md && ok || bad "list markers and task boxes kept"
has 'echo "this must not be translated"' doc_he.md && ! grep -q "<he> echo" doc_he.md && ok || bad "code fence must not be translated"
has '> <he> A quote line' doc_he.md && has '1. <he> Numbered item' doc_he.md && ok || bad "quote and numbered markers kept"
! grep -q "XQ[0-9]*Z" doc_he.md && ok || bad "a protection token leaked into the output"
# what was sent: no code, no url
jq -e '[.q[]|select(test("echo|https?://|inline code"))]|length==0' last.json >/dev/null && ok || bad "code, urls or inline code reached the translator: $(cat last.json | head -c 300)"
has "No problems found." doc_he.md.report.md && has "[exit code 0]" doc_he.md.report.md && ok || bad "report"
# subtitles
printf '1\n00:00:01,000 --> 00:00:03,000\nHello there\n\n2\n00:00:04,000 --> 00:00:06,000\nSecond line\nwith two rows\n\n' > s.srt
php "$TT" text s.srt s_he.srt to=he >/dev/null; has "00:00:01,000 --> 00:00:03,000" s_he.srt && has "<he> Hello there" s_he.srt && has "<he> with two rows" s_he.srt && [ "$(grep -c '^[0-9]$' s_he.srt)" = 2 ] && ok || bad "srt: numbers and times untouched, text translated: $(cat s_he.srt)"
printf 'WEBVTT\n\nintro\n00:00:01.000 --> 00:00:03.000\nHello vtt\n\n00:00:04.000 --> 00:00:06.000\nBye vtt\n' > v.vtt
php "$TT" text v.vtt v_he.vtt to=he >/dev/null; has "WEBVTT" v_he.vtt && has "<he> Hello vtt" v_he.vtt && has "<he> Bye vtt" v_he.vtt && grep -q "^intro$" v_he.vtt && ! grep -q "<he> intro" v_he.vtt && ok || bad "vtt header, cue id and times kept: $(cat v_he.vtt)"
# plain text, numbers only lines are not sent
printf 'First line\n\n12345\n\nSecond line\n' > p.txt; php "$TT" text p.txt p_he.txt to=he >/dev/null; has "<he> First line" p_he.txt && has "12345" p_he.txt && ! has "<he> 12345" p_he.txt && ok || bad "plain text: a line with no letters is left alone"
# a translator that loses a placeholder: that segment stays untranslated, is reported, the rest is translated
printf 'Good line with `code`\nDROPME line with `code`\nAnother good line\n' > d.txt; php "$TT" text d.txt d_he.txt to=he >/tmp/tt_out.$$ ; rc=$?
has "DROPME line with \`code\`" d_he.txt && has "<he> Good line with \`code\`" d_he.txt && has "<he> Another good line" d_he.txt && ok || bad "a lost placeholder: $(cat d_he.txt)"
grep -q "d.txt(2) Warning: left untranslated" /tmp/tt_out.$$ && has "[exit code 1]" d_he.txt.report.md && ok || bad "the loss must be reported with its line: $(cat /tmp/tt_out.$$)"; rm -f /tmp/tt_out.$$
# batching: 100 lines go in several requests, in order
for i in $(seq 100); do echo "Line number $i of the batch test"; done > b.txt; rm -f calls; php "$TT" text b.txt b_he.txt to=he >/dev/null
[ "$(wc -l < calls)" -ge 3 ] && [ "$(sed -n 1p b_he.txt)" = "<he> Line number 1 of the batch test" ] && [ "$(sed -n 100p b_he.txt)" = "<he> Line number 100 of the batch test" ] && ok || bad "batching: $(wc -l < calls) requests"
# identical result is noted
printf 'This sentence is long enough to count.\n' > same.txt; sed -i 's/\[" \. \$j/&/' fake.php
# errors
php "$TT" text doc.md x.md to=xx >/dev/null 2>e.txt; [ $? = 1 ] && grep -q "xx is not supported" e.txt && ok || bad "a translator error must be said: $(cat e.txt)"
php "$TT" text doc.md x.md >/dev/null 2>e.txt; [ $? = 1 ] && grep -q "to=he" e.txt && ok || bad "no target language"
php "$TT" text doc.md x.md to=he1234 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad language code was accepted"
php "$TT" text nope.md x.md to=he >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing file"
printf '\xff\xfe bad' > bin.txt; php "$TT" text bin.txt x.txt to=he >/dev/null 2>&1; [ $? = 1 ] && ok || bad "invalid UTF-8"
COCKPIT_LT_URL="http://127.0.0.1:9" php "$TT" text p.txt x.txt to=he >/dev/null 2>e.txt; [ $? = 1 ] && grep -q "not reachable" e.txt && ok || bad "LibreTranslate down must be said: $(cat e.txt)"
php "$TT" check x c.md >/dev/null; has "Reachable. 2 language(s)" c.md && has "| he | Hebrew |" c.md && ok || bad "check: $(cat c.md)"
php "$TT" languages x l.md >/dev/null; has "| en | English | en, he, es |" l.md && ok || bad "languages"
COCKPIT_LT_URL="http://127.0.0.1:9" php "$TT" check x c2.md >/dev/null; has "NOT REACHABLE" c2.md && has "[exit code 1]" c2.md && ok || bad "check when down"
php "$TT" frob doc.md x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
head -20 "$TT" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/translate_tool (text|languages|check) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/translate.json" > pc 2>&1; [ "$(cat pc)" = 6 ] && ok || bad "translate.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/translation.json")" = translate ] && ok || bad "the kind does not name the tool first"
echo "translate_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
