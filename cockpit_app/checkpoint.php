<?php
// =============================================================================
// checkpoint.php — snapshot a project's files before a risky step, and put them back.
//
//   GET  ?action=list&project=P
//   POST {action:'create',  project, label}     tar.gz of the project (see excludes) -> cockpit_data/checkpoints/P/
//   POST {action:'restore', project, name, confirm:true}
//                         first makes a "before-restore" checkpoint, then makes the project
//                         match the snapshot: files changed since come back, files ADDED since
//                         are removed (only ones that are not in the excludes), nothing else is touched
//   POST {action:'delete',  project, name}
//
// Not git: the person's own repository is never touched. Left out of a snapshot (rebuildable or
// not ours): .git, lib/, backup/, *.o *.ppu *.a *.compiled, node_modules, .cockpit. A project over
// 300 MB is refused with a clear message instead of silently filling the disk.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
ed_gate_or_exit('export');

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
if (session_status() === PHP_SESSION_ACTIVE) session_write_close();
@set_time_limit(300);

const CK_MAX = 300 * 1048576;
const CK_EXCL = ['.git', 'lib', 'backup', 'node_modules', '.cockpit', '*.o', '*.ppu', '*.a', '*.compiled', '*.or'];

function ck_out(array $a, int $code = 200): void { http_response_code($code); echo json_encode($a, JSON_UNESCAPED_UNICODE); exit; }
function ck_proj(string $p): string { return preg_replace('/[^a-zA-Z0-9_\-]/', '', $p); }
function ck_name_ok(string $n): bool { return (bool)preg_match('/^[0-9]{8}-[0-9]{6}-[a-z0-9-]{0,40}\.tar\.gz$/', $n); }
function ck_excluded(string $rel): bool {
    foreach (explode('/', $rel) as $part) foreach (CK_EXCL as $pat) if (fnmatch($pat, $part)) return true;
    return false;
}
function ck_files(string $root): array {
    $o = []; if (!is_dir($root)) return $o;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) { if ($f->isLink() || !$f->isFile()) continue; $rel = ltrim(substr($f->getPathname(), strlen($root)), '/'); if (!ck_excluded($rel)) $o[$rel] = $f->getSize(); }
    return $o;
}
function ck_make(string $proj, string $root, string $dir, string $label): array {
    $files = ck_files($root); $bytes = array_sum($files);
    if ($bytes > CK_MAX) return ['ok' => false, 'error' => 'the project is ' . round($bytes / 1048576) . ' MB of source files — over the 300 MB checkpoint limit'];
    if (!is_dir($dir) && !@mkdir($dir, 0775, true)) return ['ok' => false, 'error' => 'cannot create ' . $dir];
    $name = gmdate('Ymd-His') . '-' . (trim(preg_replace('/[^a-z0-9]+/', '-', strtolower($label)), '-') ?: 'checkpoint');
    $name = substr($name, 0, 60) . '.tar.gz';
    $list = tempnam(sys_get_temp_dir(), 'ck'); file_put_contents($list, implode("\n", array_keys($files)) . "\n");
    $o = []; exec('tar -czf ' . escapeshellarg("$dir/$name") . ' -C ' . escapeshellarg($root) . ' -T ' . escapeshellarg($list) . ' 2>&1', $o, $rc); @unlink($list);
    if ($rc !== 0 || !is_file("$dir/$name")) { @unlink("$dir/$name"); return ['ok' => false, 'error' => 'tar failed: ' . implode(' ', array_slice($o, 0, 2))]; }
    file_put_contents("$dir/$name.json", json_encode(['label' => $label, 'files' => count($files), 'bytes' => $bytes]));
    return ['ok' => true, 'name' => $name, 'files' => count($files), 'size_mb' => round(filesize("$dir/$name") / 1048576, 2)];
}

$in = json_decode((string)file_get_contents('php://input'), true); if (!is_array($in)) $in = [];
$action = (string)($_GET['action'] ?? ($in['action'] ?? 'list'));
$proj = ck_proj((string)($_GET['project'] ?? ($in['project'] ?? '')));
$root = rtrim($PATHS['projects_root'], '/') . '/' . $proj;
$dir  = rtrim($PATHS['cockpit_data'], '/') . '/checkpoints/' . $proj;
if ($proj === '' || !is_dir($root)) ck_out(['ok' => false, 'error' => 'no such project']);

if ($action === 'list') {
    $r = [];
    foreach ((array)glob("$dir/*.tar.gz") as $f) { $m = json_decode((string)@file_get_contents("$f.json"), true) ?: []; $r[] = ['name' => basename($f), 'label' => $m['label'] ?? '', 'files' => $m['files'] ?? null, 'made' => gmdate('c', filemtime($f))]; }
    usort($r, fn($a, $b) => strcmp($b['name'], $a['name'])); ck_out(['ok' => true, 'checkpoints' => $r]);
}
auth_require_writer();
if ($action === 'create') ck_out(ck_make($proj, $root, $dir, (string)($in['label'] ?? 'checkpoint')));
if ($action === 'delete') { $n = (string)($in['name'] ?? ''); if (!ck_name_ok($n) || !is_file("$dir/$n")) ck_out(['ok' => false, 'error' => 'no such checkpoint']); @unlink("$dir/$n"); @unlink("$dir/$n.json"); ck_out(['ok' => true]); }
if ($action === 'restore') {
    $n = (string)($in['name'] ?? '');
    if (empty($in['confirm'])) ck_out(['ok' => false, 'error' => 'confirm required'], 400);
    if (!ck_name_ok($n) || !is_file("$dir/$n")) ck_out(['ok' => false, 'error' => 'no such checkpoint']);
    $mem = []; exec('tar -tzf ' . escapeshellarg("$dir/$n") . ' 2>&1', $mem, $rc);
    if ($rc !== 0) ck_out(['ok' => false, 'error' => 'the checkpoint is damaged; nothing was changed']);
    foreach ($mem as $m) if ($m === '' || $m[0] === '/' || strpos($m, '..') !== false) ck_out(['ok' => false, 'error' => 'refusing a checkpoint with unsafe paths']);
    $pre = ck_make($proj, $root, $dir, 'before-restore');
    if (empty($pre['ok'])) ck_out(['ok' => false, 'error' => 'could not save the current state first, so nothing was changed: ' . ($pre['error'] ?? '')]);
    $keep = array_flip($mem); $removed = 0;
    foreach (ck_files($root) as $rel => $_) if (!isset($keep[$rel])) { @unlink("$root/$rel"); $removed++; }
    $o = []; exec('tar -xzf ' . escapeshellarg("$dir/$n") . ' --no-same-owner -C ' . escapeshellarg($root) . ' 2>&1', $o, $rc);
    ck_out(['ok' => $rc === 0, 'restored' => count($mem), 'removed' => $removed, 'safety' => $pre['name'],
            'message' => $rc === 0 ? 'The project is back to that checkpoint (' . count($mem) . ' files restored, ' . $removed . ' added since removed). The state before is saved as ' . $pre['name'] . '.' : 'extract failed: ' . implode(' ', array_slice($o, 0, 2))]);
}
ck_out(['ok' => false, 'error' => 'unknown action'], 400);
