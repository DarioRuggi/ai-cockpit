<?php
// =============================================================================
// catalog_feed.php — the Workers panel's "Models and prices" line: is the signed catalog feed on, how old is the catalog, check now, suggestions for new suppliers.
// The feed itself (what it may change, how it is verified) is described in catalog_feed_lib.php.
//
//   GET  ?action=status   → { ok, enabled, auto, as_of, shipped_as_of, feed_as_of, age_days, stale, last_check, last_result, can_verify, suggestions:[…] }
//   POST {action:set, enabled?:bool, auto?:bool}   switch the feed on/off (OFF = nothing is ever fetched), and the once-a-day automatic check
//   POST {action:check}   fetch + verify + store now (only while the feed is ON)
// Needs a signed-in session like every other endpoint; never reachable without one.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/catalog_feed_lib.php';
header('Content-Type: application/json'); header('Cache-Control: no-store');

$CD = rtrim((string)($PATHS['cockpit_data'] ?? ''), '/');
if ($CD === '' || !is_dir($CD)) { echo json_encode(['ok' => false, 'error' => 'no data folder']); exit; }
$SF = $CD . '/catalog_feed_settings.json';
function cf_settings(string $f): array { $j = is_file($f) ? json_decode((string)@file_get_contents($f), true) : null; return is_array($j) ? $j + ['enabled' => false, 'auto' => false] : ['enabled' => false, 'auto' => false]; }
function cf_save(string $f, array $s): void { $t = $f . '.tmp' . getmypid(); @file_put_contents($t, json_encode($s, JSON_PRETTY_PRINT)); @rename($t, $f); }
// the catalog as workers.php serves it (shipped + verified feed + overlay): its date and the suggestions
function cf_catalog(string $cd): array {
    $ship = json_decode((string)@file_get_contents(__DIR__ . '/workers_providers.json'), true); if (!is_array($ship)) $ship = ['providers' => []];
    $feed = catalog_feed_load($cd);
    return [$ship, $feed, catalog_feed_apply($ship, $feed)];
}

$in = json_decode((string)file_get_contents('php://input'), true) ?: [];
$action = $_GET['action'] ?? ($in['action'] ?? 'status');
$s = cf_settings($SF);

if ($action === 'set') {
    if (isset($in['enabled'])) $s['enabled'] = (bool)$in['enabled'];
    if (isset($in['auto']))    $s['auto']    = (bool)$in['auto'];
    if (!$s['enabled']) $s['auto'] = false;
    cf_save($SF, $s);
    $action = 'status';
}
if ($action === 'check') {
    if (empty($s['enabled'])) { echo json_encode(['ok' => false, 'error' => 'the catalog feed is switched off: nothing is fetched until you switch it on']); exit; }
    $r = catalog_feed_fetch_and_store($CD);
    $s['last_check'] = date('c'); $s['last_result'] = $r['ok'] ? ('ok, catalog as of ' . $r['as_of']) : ('not used: ' . $r['error']); cf_save($SF, $s);
    $action = 'status';
}
if ($action === 'status') {
    [$ship, $feed, $merged] = cf_catalog($CD);
    $asOf = catalog_as_of($merged); $age = catalog_age_days($asOf);
    echo json_encode(['ok' => true, 'enabled' => !empty($s['enabled']), 'auto' => !empty($s['auto']), 'as_of' => $asOf, 'shipped_as_of' => (string)($ship['as_of'] ?? ''), 'feed_as_of' => $feed ? $feed['as_of'] : null,
        'age_days' => $age, 'stale' => $age !== null && $age > CATALOG_STALE_DAYS, 'stale_after_days' => CATALOG_STALE_DAYS, 'last_check' => $s['last_check'] ?? null, 'last_result' => $s['last_result'] ?? null,
        'can_verify' => catalog_feed_can_verify(), 'suggestions' => catalog_feed_suggestions(load_overlay_merged($CD, $merged), $feed)], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
echo json_encode(['ok' => false, 'error' => 'unknown action']);

// providers the person already has (custom ones live in the overlay): a suggestion for one of those is not a suggestion
function load_overlay_merged(string $cd, array $merged): array {
    $o = json_decode((string)@file_get_contents($cd . '/workers_providers.json'), true);
    foreach (is_array($o) ? ($o['custom_providers'] ?? []) : [] as $cp) if (!empty($cp['id'])) $merged['providers'][] = ['id' => $cp['id']];
    return $merged;
}
