<?php
// =============================================================================
// webworker_lib.php — "web workers": an AI site that has no API (or whose API you do not have a key for), used through its own web page.
//
// A page is loaded in a window of cockpit_shell (--worker DIR) that nobody sees: it is kept just off-screen. Cockpit writes the prompt into the site's own
// box, presses the site's own send button and reads the answer from the page, exactly as a person would, then shows it in the chat. If the site wants a
// login, or shows a bot check, the window is brought on screen for the person to deal with; Cockpit never types a password and never tries to pass a
// check. The conversation is always a fresh page (Cockpit already puts the earlier turns into the prompt), so nothing accumulates on the site's side.
//
// This is a provider type in workers_providers.json:  { "id": "ww_duckai", "type": "webworker", "url": "https://duck.ai/", "adapter": { …see webworkers/_engine.js… },
//   "free": true, "incurs_cost": false }.  It is experimental by nature: a site can change its page at any time, so every adapter has a self-test (ww_selftest).
// Files in <cockpit_data>/webworkers/<id>/ :  cmd.*.json (to the window)  events.ndjson (from the window)  alive  profile/ (the cookie jar).
// =============================================================================

function ww_dir(string $id): string {
    global $PATHS;
    return rtrim((string)($PATHS['cockpit_data'] ?? sys_get_temp_dir()), '/') . '/webworkers/' . preg_replace('/[^a-z0-9_-]/', '', strtolower($id));
}
function ww_shell_bin(): ?string {
    global $PATHS;
    $c = array_filter([getenv('COCKPIT_SHELL_BIN') ?: '', rtrim((string)($PATHS['home'] ?? ''), '/') . '/scripts/cockpit_shell', '/usr/local/bin/cockpit_shell']);
    foreach ($c as $p) if ($p !== '' && is_executable($p)) return $p;
    return null;
}
function ww_alive(string $dir): bool { $f = $dir . '/alive'; clearstatcache(true, $f); return is_file($f) && (time() - (int)@filemtime($f)) < 6; }
function ww_cmd(string $dir, array $cmd): void {
    $tmp = $dir . '/.cmd.' . getmypid() . '.tmp';
    @file_put_contents($tmp, json_encode($cmd, JSON_UNESCAPED_UNICODE)); @chmod($tmp, 0666);
    @rename($tmp, $dir . '/cmd.' . sprintf('%.6f', microtime(true)) . '.json');
}
/** New events since $offset (bytes); advances $offset. */
function ww_events(string $dir, int &$offset): array {
    $f = $dir . '/events.ndjson'; clearstatcache(true, $f);
    if (!is_file($f) || filesize($f) <= $offset) return [];
    $h = @fopen($f, 'rb'); if (!$h) { $GLOBALS['ww_last_error'] = 'the window writes its events where this server cannot read them (file permissions)'; return []; }
    fseek($h, $offset); $data = (string)stream_get_contents($h); fclose($h);
    $end = strrpos($data, "\n"); if ($end === false) return [];
    $offset += $end + 1; $out = [];
    foreach (explode("\n", substr($data, 0, $end)) as $l) { $j = json_decode($l, true); if (is_array($j)) $out[] = $j; }
    return $out;
}
function ww_events_end(string $dir): int { $f = $dir . '/events.ndjson'; clearstatcache(true, $f); return is_file($f) ? (int)filesize($f) : 0; }

/** Start the window for this site if it is not running. Returns null, or an error message. */
function ww_ensure(string $id, string $url): ?string {
    $dir = ww_dir($id);
    if (!is_dir($dir) && !@mkdir($dir, 0777, true)) return 'could not create ' . $dir;
    @chmod($dir, 0777);
    if (ww_alive($dir)) return null;
    $bin = ww_shell_bin(); if ($bin === null) return 'cockpit_shell is not installed (web workers need it: it is the window the page runs in)';
    @unlink($dir . '/events.ndjson'); foreach (glob($dir . '/cmd.*.json') ?: [] as $f) @unlink($f);
    $env = ''; if (!getenv('DISPLAY')) $env .= 'DISPLAY=:0 '; if (!getenv('XAUTHORITY') && is_file(($h = getenv('HOME') ?: '') . '/.Xauthority')) $env .= 'XAUTHORITY=' . escapeshellarg($h . '/.Xauthority') . ' ';
    if (!function_exists('cockpit_as_owner')) { $p = __DIR__ . '/paths.php'; if (is_file($p)) require_once $p; }
    $own = function_exists('cockpit_as_owner') ? cockpit_as_owner(true) : '';
    // the launcher's own words (sudo refusing, no display...) go to start.log so a failure can say why instead of guessing
    $log = $dir . '/start.log'; @unlink($log);
    $cmd = sprintf('%s%s%s --worker %s --url %s --title %s >%s 2>&1 &', $env, $own, escapeshellarg($bin), escapeshellarg($dir), escapeshellarg($url), escapeshellarg('Cockpit web worker: ' . $id), escapeshellarg($log));
    exec($cmd);
    for ($i = 0; $i < 100; $i++) { if (ww_alive($dir)) return null; usleep(100000); }
    $said = trim((string)@file_get_contents($log)); $who = function_exists('cockpit_owner_user') ? cockpit_owner_user() : (getenv('USER') ?: 'you');
    $hint = stripos($said, 'password is required') !== false ? ' The web server is not allowed to start the Cockpit window as ' . $who . ': add the sudoers rule  www-data ALL=(' . $who . ') NOPASSWD: ' . $bin . '  (re-running the Cockpit installer does it, or Installs/fix_sudoers_cockpit_shell.sh).' : '';
    return 'the web worker window did not start (is a desktop session running for ' . $who . '?)' . ($said !== '' ? ' The launcher said: ' . mb_substr($said, 0, 300) . $hint : ' The launcher said nothing (command: ' . mb_substr($cmd, 0, 160) . ')');
}
function ww_stop(string $id): void { $d = ww_dir($id); if (is_dir($d)) ww_cmd($d, ['cmd' => 'quit']); }

/**
 * Send $prompt through the site and return the usual worker result. $emit(string $delta) is called with the new text as it appears (only when the page
 * grows the answer at its end; if the site rewrites what it already showed, the whole answer arrives once at the end).
 * Results: ['ok'=>true,'output'=>…] | ['ok'=>false,'error'=>…,'needs_login'=>true] | ['ok'=>false,'error'=>…,'blocked'=>true]
 */
function ww_run(string $id, string $url, array $adapter, string $prompt, ?callable $emit = null, int $timeout = 200): array {
    $err = ww_ensure($id, $url); if ($err !== null) return ['ok' => false, 'error' => $err];
    $dir = ww_dir($id); $off = ww_events_end($dir); $rid = bin2hex(random_bytes(4));
    $engine = (string)@file_get_contents(__DIR__ . '/webworkers/_engine.js'); if ($engine === '') return ['ok' => false, 'error' => 'webworkers/_engine.js is missing'];
    // a fresh conversation every time: load the start page, wait for it, then run the engine
    ww_cmd($dir, ['cmd' => 'load', 'url' => $url]);
    $t0 = microtime(true); $loaded = false;
    while (microtime(true) - $t0 < 40 && !$loaded) { usleep(150000); foreach (ww_events($dir, $off) as $e) if (($e['t'] ?? '') === 'loaded' && strpos((string)($e['url'] ?? ''), 'about:blank') !== 0) $loaded = true; }
    if (!$loaded) return ['ok' => false, 'error' => 'the page did not load (offline?)' . (isset($GLOBALS['ww_last_error']) ? ' - ' . $GLOBALS['ww_last_error'] : '')];
    // a site may load a second page right after the first (a redirect to another start page, a login check): anything typed into the first one is wiped by the second load.
    // So wait until no new page has loaded for 2 seconds (at most 20 s) before the engine goes in.
    $quiet = microtime(true); $t2 = microtime(true);
    while (microtime(true) - $quiet < 2.0 && microtime(true) - $t2 < 20) { usleep(150000); foreach (ww_events($dir, $off) as $e) if (($e['t'] ?? '') === 'loaded') $quiet = microtime(true); }
    $js = $engine . "\n;window.__ww.send(" . json_encode($rid) . ',' . json_encode($prompt) . ',' . json_encode($adapter) . ');';
    ww_cmd($dir, ['cmd' => 'eval', 'js' => $js]);
    $sent = ''; $last = ''; $t1 = microtime(true);
    while (microtime(true) - $t1 < $timeout) {
        usleep(120000);
        foreach (ww_events($dir, $off) as $e) {
            if (($e['id'] ?? '') !== $rid) continue;
            $t = (string)($e['t'] ?? '');
            if ($t === 'text') {
                $cur = (string)($e['text'] ?? ''); $last = $cur;
                if ($emit && strncmp($cur, $sent, strlen($sent)) === 0 && strlen($cur) > strlen($sent)) { $emit(substr($cur, strlen($sent))); $sent = $cur; }
            } elseif ($t === 'final') {
                $out = (string)($e['text'] ?? $last);
                if ($emit && strncmp($out, $sent, strlen($sent)) === 0 && strlen($out) > strlen($sent)) $emit(substr($out, strlen($sent)));
                ww_cmd($dir, ['cmd' => 'hide']);
                return ['ok' => true, 'output' => $out, 'kind' => 'text', 'tokens_in' => null, 'tokens_out' => (int)ceil(strlen($out) / 4), 'tokens_estimated' => true, 'via' => 'web'];
            } elseif ($t === 'login') {
                ww_cmd($dir, ['cmd' => 'show']);
                return ['ok' => false, 'needs_login' => true, 'error' => 'This site wants you to log in. Its window is on screen now: log in there, then send again.'];
            } elseif ($t === 'blocked') {
                ww_cmd($dir, ['cmd' => 'show']);
                return ['ok' => false, 'blocked' => true, 'error' => 'The site is showing a check to prove you are a person. Its window is on screen: complete the check there, then send again.'];
            } elseif ($t === 'error') {
                return ['ok' => false, 'error' => (string)($e['msg'] ?? 'the page reported an error') . (($e['text'] ?? '') !== '' ? ' (partial answer: ' . mb_substr((string)$e['text'], 0, 200) . ')' : '')];
            }
        }
        if (!ww_alive($dir)) return ['ok' => false, 'error' => 'the web worker window stopped'];
    }
    return ['ok' => false, 'error' => 'timed out waiting for the site'];
}
/** Ask the page what it looks like (for tuning an adapter): returns the probe event or an error. */
function ww_probe(string $id, string $url, int $wait = 20): array {
    $err = ww_ensure($id, $url); if ($err !== null) return ['ok' => false, 'error' => $err];
    $dir = ww_dir($id); $off = ww_events_end($dir); $rid = bin2hex(random_bytes(4));
    $engine = (string)@file_get_contents(__DIR__ . '/webworkers/_engine.js');
    ww_cmd($dir, ['cmd' => 'load', 'url' => $url]); sleep(6);
    ww_cmd($dir, ['cmd' => 'eval', 'js' => $engine . "\n;window.__ww.probe(" . json_encode($rid) . ');']);
    $t0 = microtime(true);
    while (microtime(true) - $t0 < $wait) { usleep(150000); foreach (ww_events($dir, $off) as $e) if (($e['id'] ?? '') === $rid && ($e['t'] ?? '') === 'probe') return ['ok' => true] + $e; }
    return ['ok' => false, 'error' => 'no answer from the page'];
}
/** The adapter's self-test: a fixed question, and the answer must contain the fixed word. */
function ww_selftest(string $id, string $url, array $adapter): array {
    $r = ww_run($id, $url, $adapter, 'Reply with only the single word: pong', null, 120);
    if (empty($r['ok'])) return ['ok' => false, 'status' => !empty($r['needs_login']) ? 'login' : (!empty($r['blocked']) ? 'blocked' : 'broken'), 'detail' => $r['error'] ?? ''];
    $good = stripos((string)$r['output'], 'pong') !== false;
    return ['ok' => $good, 'status' => $good ? 'ok' : 'broken', 'detail' => $good ? '' : 'the answer did not contain "pong": ' . mb_substr((string)$r['output'], 0, 120)];
}
