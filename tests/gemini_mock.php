<?php
// gemini_mock.php — a stand-in for generativelanguage.googleapis.com over TLS, for tests/gemini_parity.sh. NOT product code.
//   php gemini_mock.php PORT CERT.pem KEY.pem LOGFILE
// One request at a time. The scenario is the first line of the PROMPT TEXT: "SCENARIO:<name>" (the clients fix the model name, so the
// URL cannot carry it). Every request is logged as one JSON line: key in the header / in the query, body length, prompt length + sha1.
[$_, $port, $cert, $key, $log] = $argv + [null, 0, '', '', '/dev/null'];
$ctx = stream_context_create(['ssl' => ['local_cert' => $cert, 'local_pk' => $key, 'verify_peer' => false, 'allow_self_signed' => true]]);
$srv = @stream_socket_server("tls://127.0.0.1:$port", $en, $es, STREAM_SERVER_BIND | STREAM_SERVER_LISTEN, $ctx);
if (!$srv) { fwrite(STDERR, "gemini_mock: cannot listen on $port: $es\n"); exit(1); }
function reply($c, int $status, string $body, array $opt = []): void {
    $txt = [200 => 'OK', 400 => 'Bad Request', 429 => 'Too Many Requests', 502 => 'Bad Gateway'][$status] ?? 'OK';
    $h = "HTTP/1.1 $status $txt\r\nContent-Type: application/json; charset=UTF-8\r\nConnection: close\r\n";
    if (($opt['mode'] ?? '') === 'chunked') {
        $h .= "Transfer-Encoding: chunked\r\n\r\n"; fwrite($c, $h);
        foreach (str_split($body, max(1, (int)ceil(strlen($body) / 3))) as $part) fwrite($c, dechex(strlen($part)) . "\r\n$part\r\n");
        fwrite($c, "0\r\n\r\n");
    } elseif (($opt['mode'] ?? '') === 'close') { fwrite($c, $h . "\r\n" . $body); }
    else { fwrite($c, $h . 'Content-Length: ' . strlen($body) . "\r\n\r\n" . $body); }
}
$t0 = time();
while (time() - $t0 < 900) {
    $c = @stream_socket_accept($srv, 5);     // a failed handshake (a port probe, a client that refuses our certificate) must not end the server
    if (!$c) continue;
    stream_set_timeout($c, 10);
    $head = '';
    while (strpos($head, "\r\n\r\n") === false) { $b = fread($c, 8192); if ($b === '' || $b === false) break; $head .= $b; }
    if (strpos($head, "\r\n\r\n") === false) { fclose($c); continue; }
    [$hdr, $rest] = explode("\r\n\r\n", $head, 2);
    preg_match('/^POST (\S+) HTTP/', $hdr, $m); $path = $m[1] ?? '';
    preg_match('/content-length:\s*(\d+)/i', $hdr, $m); $len = (int)($m[1] ?? 0);
    $body = $rest;
    while (strlen($body) < $len) { $b = fread($c, 65536); if ($b === '' || $b === false) break; $body .= $b; }
    $keyH = preg_match('/^x-goog-api-key:\s*(.*?)\s*$/mi', $hdr, $m) ? $m[1] : '';
    parse_str((string)parse_url($path, PHP_URL_QUERY), $q); $keyQ = $q['key'] ?? '';
    $j = json_decode($body, true); $text = $j['contents'][0]['parts'][0]['text'] ?? '';
    $sc = preg_match('/^SCENARIO:(\w+)/', $text, $m) ? $m[1] : 'ok1';
    file_put_contents($log, json_encode(['path' => strtok($path, '?'), 'key_header' => $keyH, 'key_query' => $keyQ, 'body_len' => strlen($body), 'text_len' => strlen($text),
        'text_sha1' => sha1($text), 'scenario' => $sc]) . "\n", FILE_APPEND);
    $cand = fn($parts, $extra = []) => json_encode(['candidates' => [['content' => ['parts' => $parts, 'role' => 'model']] + $extra]], JSON_UNESCAPED_UNICODE);
    switch ($sc) {
        case 'ok1':      reply($c, 200, $cand([['text' => 'Hello there']])); break;
        case 'ok2':      reply($c, 200, $cand([['text' => 'Hello'], ['text' => ' world']])); break;
        case 'unicode':  reply($c, 200, $cand([['text' => "שלום \"quoted\" \\ back\nline two\ttab \u{1F600} é"]])); break;
        case 'echo':     reply($c, 200, $cand([['text' => 'got ' . strlen($text) . ' bytes']])); break;
        case 'safety':   reply($c, 200, json_encode(['candidates' => [['content' => ['parts' => [], 'role' => 'model'], 'finishReason' => 'SAFETY']]])); break;
        case 'nocontent': reply($c, 200, json_encode(['candidates' => [['finishReason' => 'MAX_TOKENS']]])); break;
        case 'emptycands': reply($c, 200, json_encode(['candidates' => []])); break;
        case 'emptytext': reply($c, 200, $cand([['text' => '']])); break;
        case 'err':      reply($c, 400, json_encode(['error' => ['code' => 400, 'message' => 'API key not valid. Please pass a valid API key.', 'status' => 'INVALID_ARGUMENT']])); break;
        case 'errnomsg': reply($c, 429, json_encode(['error' => new stdClass])); break;
        case 'errnum':   reply($c, 400, json_encode(['error' => ['message' => 5]])); break;
        case 'nojson':   reply($c, 502, '<html><body>Bad gateway</body></html>'); break;
        case 'emptybody': reply($c, 200, ''); break;
        case 'nullbody': reply($c, 200, 'null'); break;
        case 'notobj':   reply($c, 200, '[1,2]'); break;
        case 'numtext':  reply($c, 200, '{"candidates":[{"content":{"parts":[{"text":5},{"text":null},{"text":false},{"text":true},{"nope":1}]}}]}'); break;
        case 'chunked':  reply($c, 200, $cand([['text' => 'chunked answer ' . str_repeat('x', 300)]]), ['mode' => 'chunked']); break;
        case 'close':    reply($c, 200, $cand([['text' => 'close-delimited answer']]), ['mode' => 'close']); break;
        case 'slow':     sleep(6); reply($c, 200, $cand([['text' => 'late']])); break;
        default:         reply($c, 200, $cand([['text' => 'Hello there']]));
    }
    @fclose($c);
}
