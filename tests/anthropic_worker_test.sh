#!/usr/bin/env bash
# anthropic_worker_test.sh — the Anthropic Workers provider (cockpit_app/workers.php) against a FAKE Anthropic server (php -S): request shape (system, history, images, caching),
# usage incl. cache tokens, streaming events, 401/429/529, and the key probes that must send x-api-key (not Bearer).   bash tests/anthropic_worker_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v php >/dev/null 2>&1 && php -m | grep -qi '^curl$' || { echo "anthropic_worker_test: php with curl is needed - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/aw_XXXX) || exit 1; PID=0; trap '[ $PID != 0 ] && kill $PID 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
cat > "$T/fake.php" <<'PHP'
<?php
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH); $h = array_change_key_case(getallheaders(), CASE_LOWER);
file_put_contents(__DIR__ . '/last_headers.json', json_encode($h)); $body = file_get_contents('php://input'); if ($body !== '') file_put_contents(__DIR__ . '/last_body.json', $body);
if (($h['x-api-key'] ?? '') !== 'sk-test' || ($h['anthropic-version'] ?? '') === '') { http_response_code(401); header('Content-Type: application/json'); echo json_encode(['type' => 'error', 'error' => ['type' => 'authentication_error', 'message' => 'invalid x-api-key']]); exit; }
if ($path === '/v1/models') { header('Content-Type: application/json'); echo json_encode(['data' => [['id' => 'claude-fake-1'], ['id' => 'claude-fake-2']]]); exit; }
$j = json_decode($body, true); $m = $j['model'] ?? '';
if ($m === 'overload') { http_response_code(529); header('Content-Type: application/json'); echo json_encode(['type' => 'error', 'error' => ['type' => 'overloaded_error', 'message' => 'Overloaded']]); exit; }
if ($m === 'limited') { http_response_code(429); header('Content-Type: application/json'); echo json_encode(['type' => 'error', 'error' => ['type' => 'rate_limit_error', 'message' => 'rate limited']]); exit; }
if (!empty($j['stream'])) {
    header('Content-Type: text/event-stream');
    $ev = function ($e, $d) { echo "event: $e\ndata: " . json_encode($d) . "\n\n"; flush(); };
    $ev('message_start', ['type' => 'message_start', 'message' => ['usage' => ['input_tokens' => 10, 'cache_read_input_tokens' => 5, 'output_tokens' => 1]]]);
    echo "event: ping\ndata: {\"type\": \"ping\"}\n\n"; flush();
    $ev('content_block_start', ['type' => 'content_block_start', 'index' => 0, 'content_block' => ['type' => 'text', 'text' => '']]);
    $ev('content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'text_delta', 'text' => 'Hel']]);
    if ($m === 'cut') { $ev('error', ['type' => 'error', 'error' => ['type' => 'overloaded_error', 'message' => 'Overloaded mid-answer']]); exit; }
    $ev('content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'text_delta', 'text' => 'lo wörld']]);
    $ev('message_delta', ['type' => 'message_delta', 'delta' => ['stop_reason' => $m === 'trunc' ? 'max_tokens' : 'end_turn'], 'usage' => ['output_tokens' => 7]]);
    $ev('message_stop', ['type' => 'message_stop']); exit;
}
header('Content-Type: application/json');
echo json_encode(['content' => [['type' => 'text', 'text' => 'Plain answer']], 'stop_reason' => 'end_turn', 'usage' => ['input_tokens' => 12, 'output_tokens' => 4, 'cache_creation_input_tokens' => 3]]);
PHP
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT "$T/fake.php" >"$T/srv.log" 2>&1 & PID=$!
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/models" && break; sleep 0.2; done
cat > "$T/drive.php" <<PHP
<?php
require '$ROOT/cockpit_app/workers.php';        // CLI: the invoke_* functions only
\$B = 'http://127.0.0.1:$PORT/v1'; \$T = '$T'; \$out = []; \$last = fn() => json_decode(file_get_contents("\$T/last_body.json"), true);
\$r = invoke_anthropic('claude-fake', 'text', 'Question?', 'sk-test', [], \$B); \$out['plain'] = \$r + ['body' => \$last()];
\$r = invoke_anthropic('claude-fake', 'text', 'Now?', 'sk-test', ['system' => 'You are X.', 'history' => [['role' => 'user', 'content' => 'earlier q'], ['role' => 'assistant', 'content' => 'earlier a']], 'max_tokens' => 50], \$B); \$out['ctx'] = \$r + ['body' => \$last()];
\$r = invoke_anthropic('claude-fake', 'text', 'Look', 'sk-test', ['images' => [['media_type' => 'image/png', 'data' => 'iVBORw0KGgo='], ['media_type' => 'text/html', 'data' => 'PGI+'], ['media_type' => 'image/png', 'data' => 'not base64!!']]], \$B); \$out['img'] = \$r + ['body' => \$last()];
\$r = invoke_anthropic('claude-fake', 'text', 'Big', 'sk-test', ['system' => str_repeat('stable context ', 400), 'cache' => true], \$B); \$out['cache'] = ['body' => \$last()];
\$r = invoke_anthropic('claude-fake', 'text', 'Small', 'sk-test', ['system' => 'short', 'cache' => true], \$B); \$out['nocache'] = ['body' => \$last()];
\$r = invoke_anthropic('claude-fake', 'text', 'q', 'wrong-key', [], \$B); \$out['badkey'] = \$r;
\$r = invoke_anthropic('overload', 'text', 'q', 'sk-test', [], \$B); \$out['overload'] = \$r;
\$r = invoke_anthropic('limited', 'text', 'q', 'sk-test', [], \$B); \$out['limited'] = \$r;
\$r = invoke_anthropic('claude-fake', 'image', 'q', 'sk-test', [], \$B); \$out['task'] = \$r;
\$pieces = []; \$r = invoke_anthropic_stream('claude-fake', 'text', 'Stream me', 'sk-test', ['system' => 'S'], \$B, function (\$p) use (&\$pieces) { \$pieces[] = \$p; }); \$out['stream'] = \$r + ['pieces' => \$pieces, 'body' => \$last()];
\$pieces = []; \$r = invoke_anthropic_stream('trunc', 'text', 'q', 'sk-test', [], \$B, function (\$p) {}); \$out['trunc'] = \$r;
\$pieces = []; \$r = invoke_anthropic_stream('cut', 'text', 'q', 'sk-test', [], \$B, function (\$p) use (&\$pieces) { \$pieces[] = \$p; }); \$out['cut'] = \$r + ['pieces' => \$pieces];
\$r = invoke_anthropic_stream('overload', 'text', 'q', 'sk-test', [], \$B, function (\$p) {}); \$out['s529'] = \$r;
\$r = invoke_anthropic_stream('claude-fake', 'text', 'q', 'wrong-key', [], \$B, function (\$p) {}); \$out['s401'] = \$r;
\$out['probe_h'] = [provider_probe_headers('anthropic', 'K'), provider_probe_headers('groq', 'K')];
\$ch = curl_init("\$B/models"); curl_setopt_array(\$ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => provider_probe_headers('anthropic', 'sk-test')]); curl_exec(\$ch); \$out['probe_code'] = curl_getinfo(\$ch, CURLINFO_HTTP_CODE); curl_close(\$ch);
\$ch = curl_init("\$B/models"); curl_setopt_array(\$ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_HTTPHEADER => provider_probe_headers('groq', 'sk-test')]); curl_exec(\$ch); \$out['probe_code_bearer'] = curl_getinfo(\$ch, CURLINFO_HTTP_CODE); curl_close(\$ch);
echo json_encode(\$out);
PHP
php "$T/drive.php" > "$T/out.json" 2>"$T/err.txt"; jq -e . "$T/out.json" >/dev/null 2>&1 || { echo "driver failed: $(head -c 600 "$T/err.txt") $(head -c 300 "$T/out.json")"; exit 1; }
q() { jq -r "$1" "$T/out.json"; }
[ "$(q .plain.ok)" = true ] && [ "$(q .plain.output)" = "Plain answer" ] && ok || bad "plain call"
[ "$(q .plain.tokens_in)" = 15 ] && [ "$(q .plain.tokens_out)" = 4 ] && [ "$(q .plain.cache_write_tokens)" = 3 ] && ok || bad "usage (12 input + 3 cache write = 15 in): $(q '.plain|{tokens_in,tokens_out,cache_write_tokens}')"
[ "$(q '.plain.body.messages[0].content')" = "Question?" ] && [ "$(q '.plain.body|has("system")')" = false ] && [ "$(q '.plain.body|has("stream")')" = false ] && ok || bad "plain request shape: $(q .plain.body -c)"
[ "$(q '.ctx.body.system')" = "You are X." ] && [ "$(q '.ctx.body.messages|length')" = 3 ] && [ "$(q '.ctx.body.messages[1].role')" = assistant ] && [ "$(q '.ctx.body.messages[2].content')" = "Now?" ] && [ "$(q '.ctx.body.max_tokens')" = 50 ] && ok || bad "system + history: $(q .ctx.body -c)"
[ "$(q '.img.body.messages[0].content|length')" = 2 ] && [ "$(q '.img.body.messages[0].content[0].source.media_type')" = image/png ] && [ "$(q '.img.body.messages[0].content[1].text')" = Look ] && ok || bad "images: only the valid png goes (not text/html, not bad base64): $(q .img.body -c)"
[ "$(q '.cache.body.system[0].cache_control.type')" = ephemeral ] && ok || bad "a long system prompt must be marked cacheable"
[ "$(q '.nocache.body.system')" = short ] && ok || bad "a short system prompt must stay a plain string: $(q .nocache.body -c)"
[ "$(q .badkey.ok)" = false ] && q .badkey.error | grep -q "HTTP 401: invalid x-api-key" && ok || bad "401: $(q .badkey -c)"
q .overload.error | grep -q "HTTP 529: Overloaded" && ok || bad "529: $(q .overload -c)"
q .limited.error | grep -q "HTTP 429" && ok || bad "429"
q .task.error | grep -q "Unsupported task" && ok || bad "an image task must be refused"
[ "$(q .stream.ok)" = true ] && [ "$(q '.stream.pieces|join("|")')" = "Hel|lo wörld" ] && [ "$(q .stream.output)" = "Hello wörld" ] && ok || bad "stream pieces/output: $(q .stream -c)"
[ "$(q .stream.tokens_in)" = 15 ] && [ "$(q .stream.tokens_out)" = 7 ] && [ "$(q .stream.cache_read_tokens)" = 5 ] && ok || bad "stream usage (10 + 5 cache read in, 7 out): $(q '.stream|{tokens_in,tokens_out,cache_read_tokens}' -c)"
[ "$(q '.stream.body.stream')" = true ] && [ "$(q '.stream.body.system')" = S ] && ok || bad "stream request must say stream:true"
[ "$(q .trunc.truncated)" = true ] && ok || bad "stop_reason max_tokens must be reported as truncated"
[ "$(q .cut.ok)" = false ] && q .cut.error | grep -q "Overloaded mid-answer" && [ "$(q '.cut.pieces|join("")')" = Hel ] && ok || bad "an error event in the stream: $(q .cut -c)"
q .s529.error | grep -q "HTTP 529: Overloaded" && ok || bad "stream: 529 before the stream starts: $(q .s529 -c)"
q .s401.error | grep -q "HTTP 401" && ok || bad "stream: 401"
[ "$(q '.probe_h[0][0]')" = "x-api-key: K" ] && [ "$(q '.probe_h[1][0]')" = "Authorization: Bearer K" ] && ok || bad "probe headers: $(q .probe_h -c)"
[ "$(q .probe_code)" = 200 ] && [ "$(q .probe_code_bearer)" = 401 ] && ok || bad "a Bearer probe is what Anthropic rejects (the old bug): $(q '{probe_code,probe_code_bearer}' -c)"
grep -q "provider_probe_headers" "$ROOT/cockpit_app/workers.php" && ! grep -q "CURLOPT_HTTPHEADER     => \['Authorization: Bearer ' . \$key\]," "$ROOT/cockpit_app/workers.php" && ok || bad "a key probe still hard-codes a Bearer header"
echo "anthropic_worker_test: $n passed, $fails failed"; [ "$fails" = 0 ]
