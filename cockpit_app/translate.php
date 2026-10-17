<?php
require_once __DIR__ . "/auth.php";

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'languages') {
        echo json_encode(['ok'=>true,'languages'=>[
            ['code'=>'en','name'=>'English'],['code'=>'fr','name'=>'French'],
            ['code'=>'de','name'=>'German'],['code'=>'es','name'=>'Spanish'],
        ]]); exit;
    }
    if ($__demoAction === 'health') { echo json_encode(['ok'=>false,'error'=>'Not available in the web demo']); exit; }
    ed_demo_stub();
}
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// translate.php — local LibreTranslate proxy for AI Cockpit
//
// Offline-first translation via a local LibreTranslate instance (default
// http://localhost:5000). No cloud, no API key. Matches the cockpit's
// local-first stack rules.
//
// Endpoints (JSON):
//   GET  ?action=languages          — list supported languages (proxied)
//   GET  ?action=health             — is LibreTranslate reachable?
//   POST ?action=translate          — { q, source?, target } → { translatedText }
//        source defaults to "auto" (LibreTranslate auto-detects)
//
// Config: override the base URL via paths.json "libretranslate" key, else
// the LIBRETRANSLATE_URL env var, else the default below.
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

$LT_URL = 'http://localhost:5000';
$pf = __DIR__ . '/paths.json';
if (is_file($pf)) {
    $j = json_decode((string)file_get_contents($pf), true);
    if (is_array($j) && !empty($j['libretranslate'])) {
        $LT_URL = rtrim($j['libretranslate'], '/');
    }
}
$envUrl = getenv('LIBRETRANSLATE_URL');
if ($envUrl) $LT_URL = rtrim($envUrl, '/');

// Optional API key (most local instances need none)
$LT_KEY = '';
if (is_file($pf)) {
    $j = json_decode((string)file_get_contents($pf), true);
    if (is_array($j) && !empty($j['libretranslate_key'])) $LT_KEY = (string)$j['libretranslate_key'];
}

$action = $_GET['action'] ?? '';
$in = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $raw = json_decode((string)file_get_contents('php://input'), true);
    if (is_array($raw)) $in = $raw;
    if ($action === '') $action = $in['action'] ?? '';
}
if ($action === '') $action = 'translate';

// Small cURL helper
function lt_request($url, $method = 'GET', $payload = null, $timeout = 20) {
    $ch = curl_init($url);
    $opts = [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => $timeout,
        CURLOPT_CONNECTTIMEOUT => 5,
    ];
    if ($method === 'POST') {
        $opts[CURLOPT_POST] = true;
        $opts[CURLOPT_HTTPHEADER] = ['Content-Type: application/json'];
        $opts[CURLOPT_POSTFIELDS] = json_encode($payload, JSON_UNESCAPED_UNICODE);
    }
    curl_setopt_array($ch, $opts);
    $body = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err  = curl_error($ch);
    curl_close($ch);
    return [$code, $body, $err];
}

// ── health ───────────────────────────────────────────────────────────────────
if ($action === 'health') {
    list($code, $body, $err) = lt_request($LT_URL . '/languages', 'GET', null, 6);
    $ok = ($code === 200 && $body);
    echo json_encode(['ok'=>$ok, 'url'=>$LT_URL,
                       'error'=> $ok ? null : ($err ?: ('HTTP ' . $code))], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── languages ─────────────────────────────────────────────────────────────────
if ($action === 'languages') {
    list($code, $body, $err) = lt_request($LT_URL . '/languages', 'GET', null, 8);
    if ($code !== 200 || !$body) {
        echo json_encode(['ok'=>false, 'error'=> $err ?: ('LibreTranslate unreachable (HTTP ' . $code . ')'),
                          'url'=>$LT_URL], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $langs = json_decode((string)$body, true);
    echo json_encode(['ok'=>true, 'languages'=> is_array($langs) ? $langs : []], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── manage_langs ──────────────────────────────────────────────────────────────
// Returns the currently-loaded language codes plus a curated list of installable
// languages, for the in-app language manager.
$_owner = function_exists('cockpit_owner_user') ? cockpit_owner_user() : 'dario';
$_ohome = '/home/' . $_owner;
if (function_exists('posix_getpwnam')) { $pw = @posix_getpwnam($_owner); if (!empty($pw['dir'])) $_ohome = $pw['dir']; }
$_langsFile  = $_ohome . '/scripts/cockpit_data/libretranslate_langs';
$_cachedFile = $_ohome . '/scripts/cockpit_data/libretranslate_cached';
$_manager    = $_ohome . '/scripts/libretranslate_langs.sh';
// Curated set LibreTranslate/argos supports well (code => English name).
$LT_SUPPORTED = [
    'en'=>'English','ar'=>'Arabic','az'=>'Azerbaijani','zh'=>'Chinese','cs'=>'Czech',
    'nl'=>'Dutch','eo'=>'Esperanto','fi'=>'Finnish','fr'=>'French','de'=>'German',
    'el'=>'Greek','he'=>'Hebrew','hi'=>'Hindi','hu'=>'Hungarian','id'=>'Indonesian',
    'ga'=>'Irish','it'=>'Italian','ja'=>'Japanese','ko'=>'Korean','fa'=>'Persian',
    'pl'=>'Polish','pt'=>'Portuguese','ru'=>'Russian','sk'=>'Slovak','es'=>'Spanish',
    'sv'=>'Swedish','tr'=>'Turkish','uk'=>'Ukrainian','vi'=>'Vietnamese',
];
if ($action === 'manage_langs') {
    // Loaded set = the config file (source of truth), falling back to /languages.
    $loaded = [];
    if (is_readable($_langsFile)) {
        $loaded = array_values(array_filter(preg_split('/[,\s]+/', trim((string)@file_get_contents($_langsFile)))));
    }
    if (!$loaded) {
        list($c,$b) = lt_request($LT_URL . '/languages', 'GET', null, 6);
        if ($c === 200 && $b) { $j = json_decode($b, true); if (is_array($j)) foreach ($j as $x) if (!empty($x['code'])) $loaded[] = $x['code']; }
    }
    // Caged = model on disk but hidden (removed from the loaded set); re-adding is instant.
    $cached = [];
    if (is_readable($_cachedFile)) {
        $cached = array_values(array_filter(preg_split('/[,\s]+/', trim((string)@file_get_contents($_cachedFile)))));
    }
    echo json_encode(['ok'=>true, 'loaded'=>$loaded, 'cached'=>$cached, 'supported'=>$LT_SUPPORTED,
                      'manageable'=> is_file($_manager)], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── set_langs ─────────────────────────────────────────────────────────────────
// Writes the language set (via the owner's manager script, run through sudo) and
// restarts LibreTranslate. New languages download on next use.
if ($action === 'set_langs') {
    $want = $in['langs'] ?? [];
    if (is_string($want)) $want = preg_split('/[,\s]+/', $want);
    $codes = [];
    foreach ((array)$want as $c) {
        $c = strtolower(trim((string)$c));
        if (isset($LT_SUPPORTED[$c])) $codes[$c] = true;   // whitelist against curated set
    }
    if (empty($codes)) { echo json_encode(['ok'=>false,'error'=>'No valid languages'], JSON_UNESCAPED_UNICODE); exit; }
    if (!is_file($_manager)) { echo json_encode(['ok'=>false,'error'=>'LibreTranslate not installed'], JSON_UNESCAPED_UNICODE); exit; }
    $csv = implode(',', array_keys($codes));
    // sudo -n: needs the NOPASSWD entry in /etc/sudoers.d/cockpit-launch-cli.
    $cmd = cockpit_as_owner(true) . escapeshellarg($_manager) . ' set ' . escapeshellarg($csv) . ' 2>&1';
    @exec($cmd, $out, $rc);
    echo json_encode(['ok'=> ($rc === 0), 'langs'=>$csv,
        'restarting'=> ($rc === 0),
        'error'=> $rc === 0 ? null : ('manager failed (rc=' . $rc . '): ' . implode(' ', array_slice($out, -3)))],
        JSON_UNESCAPED_UNICODE);
    exit;
}

// ── translate ─────────────────────────────────────────────────────────────────
if ($action === 'translate') {
    $q      = (string)($in['q'] ?? '');
    $source = trim((string)($in['source'] ?? 'auto')) ?: 'auto';
    $target = trim((string)($in['target'] ?? ''));
    if ($q === '')      { echo json_encode(['ok'=>false,'error'=>'Empty text'], JSON_UNESCAPED_UNICODE); exit; }
    if ($target === '') { echo json_encode(['ok'=>false,'error'=>'Missing target language'], JSON_UNESCAPED_UNICODE); exit; }
    // LibreTranslate caps payloads; chunk very large inputs (~4000 chars per call)
    $CHUNK = 4000;
    if (mb_strlen($q) <= $CHUNK) {
        $payload = ['q'=>$q, 'source'=>$source, 'target'=>$target, 'format'=>'text'];
        if ($LT_KEY !== '') $payload['api_key'] = $LT_KEY;
        list($code, $body, $err) = lt_request($LT_URL . '/translate', 'POST', $payload);
        if ($code !== 200 || !$body) {
            echo json_encode(['ok'=>false,'error'=> $err ?: ('Translate failed (HTTP ' . $code . ')')], JSON_UNESCAPED_UNICODE);
            exit;
        }
        $d = json_decode((string)$body, true);
        echo json_encode(['ok'=>true,
            'translatedText' => $d['translatedText'] ?? '',
            'detected'       => $d['detectedLanguage'] ?? null], JSON_UNESCAPED_UNICODE);
        exit;
    }
    // Multi-chunk: split on paragraph boundaries, translate each, rejoin
    $parts = preg_split('/(\n{2,})/u', $q, -1, PREG_SPLIT_DELIM_CAPTURE);
    $out = '';
    $detected = null;
    foreach ($parts as $part) {
        if ($part === '' || preg_match('/^\n{2,}$/u', $part)) { $out .= $part; continue; }
        // Further split a giant paragraph if needed
        $buf = $part;
        while (mb_strlen($buf) > $CHUNK) {
            $slice = mb_substr($buf, 0, $CHUNK);
            $buf   = mb_substr($buf, $CHUNK);
            $payload = ['q'=>$slice, 'source'=>$source, 'target'=>$target, 'format'=>'text'];
            if ($LT_KEY !== '') $payload['api_key'] = $LT_KEY;
            list($code, $body) = lt_request($LT_URL . '/translate', 'POST', $payload);
            if ($code === 200 && $body) {
                $d = json_decode((string)$body, true);
                $out .= ($d['translatedText'] ?? '');
                if (!$detected && isset($d['detectedLanguage'])) $detected = $d['detectedLanguage'];
            }
        }
        if ($buf !== '') {
            $payload = ['q'=>$buf, 'source'=>$source, 'target'=>$target, 'format'=>'text'];
            if ($LT_KEY !== '') $payload['api_key'] = $LT_KEY;
            list($code, $body) = lt_request($LT_URL . '/translate', 'POST', $payload);
            if ($code === 200 && $body) {
                $d = json_decode((string)$body, true);
                $out .= ($d['translatedText'] ?? '');
                if (!$detected && isset($d['detectedLanguage'])) $detected = $d['detectedLanguage'];
            }
        }
    }
    echo json_encode(['ok'=>true, 'translatedText'=>$out, 'detected'=>$detected, 'chunked'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
