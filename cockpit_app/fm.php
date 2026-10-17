<?php
// =============================================================================
// fm.php — the file window's backend. Everything is done by the native engine (engine_client.php); this file checks who is asking, picks their
// zones and relays. Read-write only in their Public folder; everything else is read-only (look, download, copy out).
//
//   GET  ?action=zones                 the zones and whether the engine answers
//   GET  ?action=list&path=zone:dir    ?action=stat&path=...
//   GET  ?action=download&path=...[&inline=1]     streams a file (Range supported; never served as active content)
//   POST {action:mkdir|newfile|rename|move|copy|delete|empty_trash|open|write, ...}
//   POST {action:areas_get|areas_set, areas:[{name,path}]}      admin only: extra read-only areas
// Viewers (the read-only role) can list, look and download, nothing else.
// =============================================================================
header('Content-Type: application/json');
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/engine_client.php';
ed_gate_or_exit('fileman');

function fm_out(array $a, int $code = 200): void { http_response_code($code); echo json_encode($a, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); exit; }
function fm_role(): string { return (string)($_SESSION['cockpit_role'] ?? 'admin'); }

$in = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') { $in = json_decode((string)file_get_contents('php://input'), true); if (!is_array($in)) $in = []; }
$action = (string)($in['action'] ?? $_GET['action'] ?? '');
$READ = ['zones', 'list', 'stat', 'download', 'areas_get'];
if (!in_array($action, $READ, true) && fm_role() === 'viewer') fm_out(['ok' => false, 'error' => 'Your account can look at files but not change them.'], 403);

$zones = ck_fm_zones();
if (!$zones) fm_out(['ok' => false, 'error' => 'No projects folder is set up for this account.']);

/** relay one file operation; null from the engine = the service is not running */
function fm_call(string $sub, array $f): array {
    $r = ck_engine_call(ck_fm_req('fs', $sub, $f), 60.0);
    if ($r === null) return ['ok' => false, 'engine' => false, 'error' => 'The file service is not running. Start the agents (the supervisor hosts it) and try again.'];
    unset($r['type']);
    return $r;
}
function fm_path(array $src, string $key = 'path'): string { return (string)($src[$key] ?? ''); }

if ($action === 'zones') {
    $s = ck_engine_call(['op' => 'sandbox'], 3.0);
    $zl = [];
    foreach ($zones as $z) $zl[] = ['name' => $z['name'], 'label' => ck_fm_label($z['name']), 'rw' => $z['rw']];
    $local = in_array($_SERVER['REMOTE_ADDR'] ?? '', ['127.0.0.1', '::1'], true);
    fm_out(['ok' => true, 'engine' => $s !== null, 'sandbox' => (int)($s['abi'] ?? 0) > 0, 'zones' => $zl, 'can_open' => $local, 'viewer' => fm_role() === 'viewer', 'admin' => fm_role() === 'admin']);
}
if ($action === 'list' || $action === 'stat') fm_out(fm_call($action, ['path' => fm_path($_GET)]));

if ($action === 'download') {
    $path = fm_path($_GET);
    $st = fm_call('stat', ['path' => $path]);
    if (empty($st['ok'])) { header('Content-Type: application/json'); fm_out($st, 404); }
    if (($st['stat']['type'] ?? '') !== 'file') fm_out(['ok' => false, 'error' => 'That is not a file.'], 400);
    $size = (int)$st['stat']['size']; $name = (string)$st['stat']['name'];
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    $inlineTypes = ['png' => 'image/png', 'jpg' => 'image/jpeg', 'jpeg' => 'image/jpeg', 'gif' => 'image/gif', 'webp' => 'image/webp', 'bmp' => 'image/bmp',
        'pdf' => 'application/pdf', 'mp3' => 'audio/mpeg', 'ogg' => 'audio/ogg', 'wav' => 'audio/wav', 'flac' => 'audio/flac', 'm4a' => 'audio/mp4',
        'mp4' => 'video/mp4', 'webm' => 'video/webm', 'mkv' => 'video/x-matroska', 'txt' => 'text/plain; charset=utf-8', 'md' => 'text/plain; charset=utf-8',
        'json' => 'text/plain; charset=utf-8', 'log' => 'text/plain; charset=utf-8', 'csv' => 'text/plain; charset=utf-8', 'sh' => 'text/plain; charset=utf-8',
        'php' => 'text/plain; charset=utf-8', 'py' => 'text/plain; charset=utf-8', 'js' => 'text/plain; charset=utf-8', 'css' => 'text/plain; charset=utf-8',
        'html' => 'text/plain; charset=utf-8', 'xml' => 'text/plain; charset=utf-8', 'pas' => 'text/plain; charset=utf-8', 'c' => 'text/plain; charset=utf-8'];
    $inline = !empty($_GET['inline']) && isset($inlineTypes[$ext]);
    $start = 0; $end = $size - 1; $code = 200;
    if ($size > 0 && preg_match('/^bytes=(\d*)-(\d*)$/', (string)($_SERVER['HTTP_RANGE'] ?? ''), $m) && ($m[1] !== '' || $m[2] !== '')) {
        if ($m[1] === '') { $start = max(0, $size - (int)$m[2]); } else { $start = (int)$m[1]; if ($m[2] !== '') $end = min($end, (int)$m[2]); }
        if ($start > $end || $start >= $size) { header('Content-Range: bytes */' . $size); http_response_code(416); exit; }
        $code = 206;
    }
    http_response_code($code);
    header('Content-Type: ' . ($inline ? $inlineTypes[$ext] : 'application/octet-stream'));
    header('Content-Disposition: ' . ($inline ? 'inline' : 'attachment') . "; filename*=UTF-8''" . rawurlencode($name));
    header('X-Content-Type-Options: nosniff');
    // a file in Public is never a page of this site. (A PDF is not a page, and a browser will not draw one under a sandboxed policy.)
    if ($ext !== 'pdf') header("Content-Security-Policy: sandbox; default-src 'none'; img-src 'self' data:; media-src 'self'; style-src 'unsafe-inline'");
    header('Accept-Ranges: bytes');
    header('Cache-Control: private, no-cache');
    if ($code === 206) header('Content-Range: bytes ' . $start . '-' . $end . '/' . $size);
    header('Content-Length: ' . ($size > 0 ? $end - $start + 1 : 0));
    session_write_close();
    $off = $start; $left = $size > 0 ? $end - $start + 1 : 0;
    while ($left > 0) {
        $r = ck_engine_call(ck_fm_req('fs', 'read', ['path' => $path, 'offset' => $off, 'length' => min($left, 1048576)]), 30.0);
        if (!$r || empty($r['ok'])) break;
        $data = base64_decode((string)($r['data_b64'] ?? ''), true);
        if ($data === false || $data === '') break;
        echo $data; $off += strlen($data); $left -= strlen($data);
        if (connection_aborted()) break;
        flush();
    }
    exit;
}

if ($action === 'areas_get') fm_out(['ok' => true, 'areas' => ck_fm_extra_areas(), 'admin' => fm_role() === 'admin']);
if ($action === 'areas_set') {
    if (fm_role() !== 'admin') fm_out(['ok' => false, 'error' => 'Only an admin can change the read-only areas.'], 403);
    $clean = [];
    foreach ((array)($in['areas'] ?? []) as $a) {
        if (!is_array($a)) continue;
        $n = (string)($a['name'] ?? ''); $p = (string)($a['path'] ?? '');
        if (!preg_match('/^[a-z][a-z0-9_]{0,23}$/', $n) || $n === 'public' || $n === 'projects' || $p === '' || $p[0] !== '/' || strpos($p, '..') !== false || strpos($p, "\0") !== false) fm_out(['ok' => false, 'error' => 'Bad area: names are lower-case letters/digits, paths absolute.']);
        $clean[] = ['name' => $n, 'path' => rtrim($p, '/') ?: '/'];
    }
    if (file_put_contents(ck_fm_areas_file(), json_encode($clean, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n") === false) fm_out(['ok' => false, 'error' => 'Could not save.']);
    fm_out(['ok' => true, 'areas' => $clean, 'note' => 'An area this account does not own is not shown.']);
}

if (in_array($action, ['mkdir', 'newfile', 'rename', 'move', 'copy', 'delete', 'empty_trash', 'write'], true)) {
    $f = [];
    foreach (['path', 'to_dir', 'name', 'zone'] as $k) if (isset($in[$k])) $f[$k] = (string)$in[$k];
    if ($action === 'write') {
        $f['data_b64'] = (string)($in['data_b64'] ?? ''); $f['offset'] = (int)($in['offset'] ?? 0);
        if (!empty($in['create_only'])) $f['create_only'] = true;
        if (strlen($f['data_b64']) > 12 * 1048576) fm_out(['ok' => false, 'error' => 'That piece is too large.']);
    }
    fm_out(fm_call($action, $f));
}
if ($action === 'open') {
    if (!in_array($_SERVER['REMOTE_ADDR'] ?? '', ['127.0.0.1', '::1'], true)) fm_out(['ok' => false, 'error' => 'Opening in the default application only works at this machine; download the file instead.']);
    fm_out(fm_call('open', ['path' => fm_path($in), 'display' => getenv('DISPLAY') ?: ':0']));
}
fm_out(['ok' => false, 'error' => 'unknown action'], 400);
