<?php
// =============================================================================
// integrity.php — is this install the build it claims to be?
//
// integrity.json (written by Installs/build_integrity.sh at build time) lists
// the sha256 of every shipped file and one build_id over the list. This
// endpoint recomputes both from the files on disk:
//
//   GET  ?action=status    → { ok, has_manifest, build_id (manifest), computed_id,
//                              intact, changed:[], missing:[], version, built,
//                              bundle_kept: path|null, first_use: bool }
//   POST {action:seen}     → records that the current account saw the first-use
//                              notice (terms + integrity) — per user
//   GET  ?action=license   → the LICENSE text shipped with this build
//
// What it is: a way to notice a half-finished upgrade, a corrupted disk, or a
// file someone edited, and to point at the kept bundle for a restore. What it
// is not: protection. The manifest and this file sit in the same tree as the
// files they describe; a modified build can carry a modified manifest. The
// line that holds is on ruggi.site, whose account services answer only to
// official build_ids (see saas.php srv_post + api/official_builds.json).
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
header('Content-Type: application/json');
header('Cache-Control: no-store');

require_once __DIR__ . '/integrity_lib.php';

function integrity_guard_info(): array {
    global $PATHS; $root = rtrim((string)($PATHS['cockpit_data_root'] ?? $PATHS['cockpit_data'] ?? ''), '/');
    $flag = is_file($root . '/integrity_flag.json') ? json_decode((string)@file_get_contents($root . '/integrity_flag.json'), true) : null;
    $log = is_file($root . '/guard.log') ? array_slice(file($root . '/guard.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [], -12) : [];
    $active = trim((string)@shell_exec('systemctl is-active cockpit-guard 2>/dev/null'));
    $locked = (function_exists('posix_getpwuid') && ($st = @stat(__DIR__ . '/index.html'))) ? ((posix_getpwuid($st['uid'])['name'] ?? '') === 'root') : null;
    return ['active' => $active === 'active', 'state' => $active ?: 'not installed', 'flag' => $flag, 'log' => $log, 'locked' => $locked];
}

$action = $_GET['action'] ?? '';
$in = json_decode((string)file_get_contents('php://input'), true) ?: [];
if ($action === '' && isset($in['action'])) $action = (string)$in['action'];

if ($action === 'status') {
    $m = integrity_manifest();
    if (!$m) { echo json_encode(['ok'=>true, 'has_manifest'=>false, 'intact'=>null, 'first_use'=>!is_file(integrity_seen_file())]); exit; }
    $changed = []; $missing = [];
    $computed = integrity_compute($m, $changed, $missing);
    echo json_encode([
        'ok' => true, 'has_manifest' => true,
        'version' => (string)($m['version'] ?? ''), 'build' => (int)($m['build'] ?? 0), 'built' => (string)($m['built'] ?? ''),
        'build_id' => (string)($m['build_id'] ?? ''), 'computed_id' => $computed,
        'intact' => ($computed === ($m['build_id'] ?? '') && !$changed && !$missing),
        'changed' => $changed, 'missing' => $missing, 'files' => count($m['files']),
        'bundle_kept' => integrity_bundle_kept(),
        'first_use' => !is_file(integrity_seen_file()),
        'guard' => integrity_guard_info(),
    ], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
if ($action === 'ack_flag') {   // the user has seen the guard's report
    global $PATHS; $root = rtrim((string)($PATHS['cockpit_data_root'] ?? $PATHS['cockpit_data'] ?? ''), '/');
    @unlink($root . '/integrity_flag.json'); echo json_encode(['ok'=>true]); exit;
}
if ($action === 'seen') {
    @file_put_contents(integrity_seen_file(), json_encode(['seen'=>date('c'), 'user'=>(string)($_SESSION['cockpit_user'] ?? '')]));
    echo json_encode(['ok'=>true]); exit;
}
if ($action === 'license') {   // the Terms of Use (accepted on first use) + the licence, one text
    $out = '';
    foreach (['TERMS.md', 'LICENSE.md'] as $n) foreach ([__DIR__ . '/' . $n, dirname(__DIR__) . '/' . $n] as $p) {
        if (is_readable($p)) { $out .= ($out ? "\n\n---\n\n" : '') . file_get_contents($p); break; }
    }
    if ($out !== '') { echo json_encode(['ok'=>true, 'text'=>$out], JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES); exit; }
    echo json_encode(['ok'=>false, 'error'=>'TERMS.md / LICENSE.md not found']); exit;
}
echo json_encode(['ok'=>false, 'error'=>'Unknown action']);
