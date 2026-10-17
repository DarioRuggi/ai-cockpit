<?php
// =============================================================================
// latency.php — network latency probe (one ping) for the topbar monitor
// Dario Ruggi / Cockpit
//
// GET ?host=<hostname|ip>  (validated; default from cockpit_data/latency_config.json
// or this machine's own default gateway, else 127.0.0.1: never a public address unless the person chooses one). Returns { ok, host, ms }. Offline-first: returns ok:false when the
// host is unreachable so the UI can show "offline".
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();
$cfgF = $CD . '/latency_config.json';

// Default: the router on the local network (what "is my network up and how fast" means) — a ping to a public address would be
// a call out of the machine that nobody asked for. Linux reads /proc/net/route; macOS asks `route`; otherwise this machine itself.
function latency_default_host(): string {
    $rt = @file('/proc/net/route', FILE_IGNORE_NEW_LINES);
    if (is_array($rt)) foreach ($rt as $i => $l) { if ($i === 0) continue; $f = preg_split('/\s+/', trim($l)); if (isset($f[1], $f[2]) && $f[1] === '00000000' && strlen($f[2]) === 8) { $b = array_reverse(str_split($f[2], 2)); $ip = implode('.', array_map('hexdec', $b)); if ($ip !== '0.0.0.0') return $ip; } }
    if (PHP_OS_FAMILY === 'Darwin') { $o = (string)@shell_exec('route -n get default 2>/dev/null'); if (preg_match('/gateway:\s*([0-9.]+)/', $o, $m)) return $m[1]; }
    return '127.0.0.1';
}
$host = latency_default_host();
if (is_file($cfgF)) {
    $c = json_decode((string)file_get_contents($cfgF), true);
    if (is_array($c) && !empty($c['host'])) $host = (string)$c['host'];
}
// Per-request override (also persisted via ?set=1).
$req = (string)($_GET['host'] ?? '');
if ($req !== '' && preg_match('/^[A-Za-z0-9._\-]{1,253}$/', $req)) {
    $host = $req;
    if (!empty($_GET['set'])) {
        @file_put_contents($cfgF, json_encode(['host' => $host], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    }
}
if (!preg_match('/^[A-Za-z0-9._\-]{1,253}$/', $host)) $host = '1.1.1.1';

// One ping, 1s timeout. Parse "time=XX ms".
$out = []; $rc = 0;
exec('ping -c 1 -W 1 ' . escapeshellarg($host) . ' 2>/dev/null', $out, $rc);
$ms = null;
foreach ($out as $line) {
    if (preg_match('/time[=<]\s*([0-9.]+)\s*ms/', $line, $m)) { $ms = (float)$m[1]; break; }
}
echo json_encode(['ok' => $ms !== null, 'host' => $host, 'ms' => $ms], JSON_UNESCAPED_UNICODE);
