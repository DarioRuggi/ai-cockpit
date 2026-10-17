#!/usr/bin/env bash
# openai_stream_test.sh — the shared stream parser for the OpenAI-compatible workers (cockpit_app/workers.php: invoke_openai_compat_stream) against a FAKE server:
# pieces in order, split UTF-8 and split events, usage chunk, no-usage estimate, [DONE], finish_reason=length, mid-stream error, 401/429, wrong provider, request shape.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v php >/dev/null 2>&1 && php -m | grep -qi '^curl$' || { echo "openai_stream_test: php with curl is needed - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/os_XXXX) || exit 1; PID=0; trap '[ $PID != 0 ] && kill $PID 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
cat > "$T/fake.php" <<'PHP'
<?php
$h = array_change_key_case(getallheaders(), CASE_LOWER); $body = file_get_contents('php://input'); file_put_contents(__DIR__ . '/last_body.json', $body); file_put_contents(__DIR__ . '/last_headers.json', json_encode($h));
if (($h['authorization'] ?? '') !== 'Bearer sk-test') { http_response_code(401); header('Content-Type: application/json'); echo json_encode(['error' => ['message' => 'bad key']]); exit; }
$j = json_decode($body, true); $m = $j['model'] ?? '';
if ($m === 'limited') { http_response_code(429); header('Content-Type: application/json'); echo json_encode(['error' => ['message' => 'Rate limit reached']]); exit; }
if ($m === 'notstream') { header('Content-Type: application/json'); echo json_encode(['choices' => [['message' => ['content' => 'x']]]]); exit; }
header('Content-Type: text/event-stream');
$c = fn($t, $extra = []) => 'data: ' . json_encode(['choices' => [['delta' => ['content' => $t]] + $extra]]) . "\n\n";
$w = function ($s) { echo $s; flush(); usleep(20000); };
if ($m === 'split') {            // an event cut in the middle, and a multi-byte character cut in the middle
    $e = $c('Grüße ');  $mid = intdiv(strlen($e), 2); $w(substr($e, 0, $mid)); $w(substr($e, $mid));
    $e = $c('日本語');  $cut = strpos($e, '本') + 1; $w(substr($e, 0, $cut)); $w(substr($e, $cut));
    $w("data: " . json_encode(['choices' => [['delta' => [], 'finish_reason' => 'stop']]]) . "\n\n"); $w("data: [DONE]\n\n"); exit;
}
if ($m === 'cut') { $w($c('Par')); $w('data: ' . json_encode(['error' => ['message' => 'upstream blew up']]) . "\n\n"); exit; }
if ($m === 'dropped') { $w($c('half an ans')); exit; }     // connection ends with no [DONE] and no finish_reason
$w($c('Hel')); $w($c('lo '));
$w($c('wor', [])); $w($c('ld', ['finish_reason' => $m === 'trunc' ? 'length' : 'stop']));
if (!empty($j['stream_options']['include_usage'])) $w('data: ' . json_encode(['choices' => [], 'usage' => ['prompt_tokens' => 11, 'completion_tokens' => 5]]) . "\n\n");
$w("data: [DONE]\n\n");
PHP
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT "$T/fake.php" >"$T/srv.log" 2>&1 & PID=$!
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
cat > "$T/drive.php" <<PHP
<?php
require '$ROOT/cockpit_app/workers.php';
\$B = 'http://127.0.0.1:$PORT/v1'; \$T = '$T'; \$out = [];
function run(\$pid, \$model, \$key = 'sk-test', \$task = 'text', &\$pieces = null) { global \$B; \$pieces = []; return invoke_openai_compat_stream(\$pid, \$model, \$task, 'Question', \$key, ['max_tokens' => 33], \$B, function (\$p) use (&\$pieces) { \$pieces[] = \$p; }); }
\$r = run('groq', 'plain', 'sk-test', 'text', \$pc); \$out['plain'] = \$r + ['pieces' => \$pc, 'body' => json_decode(file_get_contents("\$T/last_body.json"), true), 'hdr' => json_decode(file_get_contents("\$T/last_headers.json"), true)];
\$r = run('together', 'plain', 'sk-test', 'text', \$pc); \$out['nousage'] = \$r + ['body' => json_decode(file_get_contents("\$T/last_body.json"), true)];
\$r = run('openrouter', 'plain', 'sk-test', 'text', \$pc); \$out['or'] = ['hdr' => json_decode(file_get_contents("\$T/last_headers.json"), true)];
\$r = run('openai', 'split', 'sk-test', 'text', \$pc); \$out['split'] = \$r + ['pieces' => \$pc];
\$out['trunc'] = run('openai', 'trunc'); \$r = run('openai', 'cut', 'sk-test', 'text', \$pc); \$out['cut'] = \$r + ['pieces' => \$pc];
\$out['dropped'] = run('openai', 'dropped'); \$out['badkey'] = run('openai', 'plain', 'wrong'); \$out['limited'] = run('openai', 'limited'); \$out['notstream'] = run('openai', 'notstream');
\$out['unknown'] = run('nosuch', 'plain'); \$out['nokey'] = run('openai', 'plain', ''); \$out['task'] = run('openai', 'plain', 'sk-test', 'image');
\$out['cfg'] = array_keys(OPENAI_STREAM_CFG);
echo json_encode(\$out);
PHP
php "$T/drive.php" > "$T/out.json" 2>"$T/err.txt"; jq -e . "$T/out.json" >/dev/null 2>&1 || { echo "driver failed: $(head -c 600 "$T/err.txt") $(head -c 300 "$T/out.json")"; exit 1; }
q() { jq -r "$1" "$T/out.json"; }
[ "$(q .plain.ok)" = true ] && [ "$(q '.plain.pieces|join("|")')" = "Hel|lo |wor|ld" ] && [ "$(q .plain.output)" = "Hello world" ] && ok || bad "plain stream: $(q .plain -c)"
[ "$(q .plain.tokens_in)" = 11 ] && [ "$(q .plain.tokens_out)" = 5 ] && [ "$(q '.plain.tokens_estimated // false')" = false ] && ok || bad "real usage from the last chunk"
[ "$(q .plain.body.stream)" = true ] && [ "$(q .plain.body.stream_options.include_usage)" = true ] && [ "$(q .plain.body.max_tokens)" = 33 ] && [ "$(q '.plain.body.messages[0].content')" = Question ] && ok || bad "request shape: $(q .plain.body -c)"
[ "$(q '.nousage.body|has("stream_options")')" = false ] && [ "$(q .nousage.tokens_estimated)" = true ] && [ "$(q .nousage.tokens_out)" = 3 ] && [ "$(q .nousage.tokens_in)" = null ] && ok || bad "a provider without usage: estimate flagged, no stream_options sent: $(q .nousage -c)"
[ "$(q '.or.hdr["x-title"]')" = "AI Cockpit" ] && ok || bad "OpenRouter's extra headers"
[ "$(q .split.ok)" = true ] && [ "$(q .split.output)" = "Grüße 日本語" ] && ok || bad "split events and split UTF-8: $(q .split -c)"
[ "$(q .trunc.truncated)" = true ] && ok || bad "finish_reason length must be reported as truncated"
[ "$(q .cut.ok)" = false ] && q .cut.error | grep -q "upstream blew up" && [ "$(q '.cut.pieces|join("")')" = Par ] && ok || bad "error mid-stream: $(q .cut -c)"
[ "$(q .dropped.ok)" = false ] && q .dropped.error | grep -q "ended before it was complete" && ok || bad "a stream that just stops must not be success: $(q .dropped -c)"
q .badkey.error | grep -q "HTTP 401: bad key" && ok || bad "401: $(q .badkey -c)"
q .limited.error | grep -q "HTTP 429: Rate limit reached" && ok || bad "429: $(q .limited -c)"
[ "$(q .notstream.ok)" = true ] && [ "$(q .notstream.output)" = x ] && ok || bad "a provider that ignores stream:true must still give its one-piece answer: $(q .notstream -c)"
q .unknown.error | grep -q "No streaming for nosuch" && q .nokey.error | grep -q "No API key" && q .task.error | grep -q "Unsupported task" && ok || bad "guards"
[ "$(q '.cfg|sort|join(",")')" = "deepinfra,google_gemini,groq,openai,openrouter,together,zai" ] && ok || bad "provider list: $(q .cfg -c)"
echo "openai_stream_test: $n passed, $fails failed"; [ "$fails" = 0 ]
