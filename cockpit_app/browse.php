<?php
// =============================================================================
// browse.php — generic server-side filesystem browser for the Cockpit path/file
// picker. Lists directories (always) and optionally files, for a given path.
// Auth-guarded (same as every cockpit backend). Local app → the user browses
// their own machine, same trust level as the Files panel.
//
// POST/GET ?action=list { path?, files?:bool, hidden?:bool, exts?:["md","txt"] }
//   → { ok, path, parent, writable, dirs:[{name,path,readable}], files:[{name,path,size}] }
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

ed_require_saas();   // 404 in v1/demo, pass-through in v2

header('Content-Type: application/json');
header('Cache-Control: no-store');

$in = json_decode((string)file_get_contents('php://input'), true) ?: [];
$action = $_GET['action'] ?? ($in['action'] ?? 'list');

function bjson($a){ echo json_encode($a, JSON_UNESCAPED_UNICODE); exit; }

if ($action === 'list') {
    $path = trim((string)($in['path'] ?? $_GET['path'] ?? ''));
    if ($path === '') $path = getenv('HOME') ?: '/home';
    $real = realpath($path);
    if ($real === false || !is_dir($real)) bjson(['ok'=>false,'error'=>'not a directory','path'=>$path]);
    if (!is_readable($real)) bjson(['ok'=>false,'error'=>'not readable','path'=>$real]);

    $wantFiles = !empty($in['files']) || !empty($_GET['files']);
    $showHidden = !empty($in['hidden']) || !empty($_GET['hidden']);
    $exts = is_array($in['exts'] ?? null) ? array_map('strtolower', $in['exts']) : [];

    $dirs = []; $files = [];
    foreach (scandir($real) ?: [] as $e) {
        if ($e === '.' || $e === '..') continue;
        if (!$showHidden && $e[0] === '.') continue;
        $full = $real . '/' . $e;
        if (is_dir($full)) {
            $dirs[] = ['name'=>$e, 'path'=>$full, 'readable'=>is_readable($full)];
        } elseif ($wantFiles && is_file($full)) {
            if ($exts) { $ext = strtolower(pathinfo($e, PATHINFO_EXTENSION)); if (!in_array($ext, $exts, true)) continue; }
            $files[] = ['name'=>$e, 'path'=>$full, 'size'=>(int)@filesize($full)];
        }
    }
    usort($dirs,  fn($a,$b)=>strcasecmp($a['name'],$b['name']));
    usort($files, fn($a,$b)=>strcasecmp($a['name'],$b['name']));
    $parent = dirname($real);
    bjson(['ok'=>true,'path'=>$real,'parent'=>($parent!==$real?$parent:null),
           'writable'=>is_writable($real),'dirs'=>$dirs,'files'=>$files]);
}

// Read a server file's bytes (base64) so the client can feed it to existing
// import handlers — lets the Cockpit picker replace native file dialogs.
if ($action === 'read') {
    $path = trim((string)($in['path'] ?? $_GET['path'] ?? ''));
    $real = realpath($path);
    if ($real === false || !is_file($real)) bjson(['ok'=>false,'error'=>'not found']);
    if (!is_readable($real)) bjson(['ok'=>false,'error'=>'not readable']);
    $size = (int)filesize($real);
    if ($size > 50 * 1024 * 1024) bjson(['ok'=>false,'error'=>'too large (max 50MB)']);
    $mime = function_exists('mime_content_type') ? (@mime_content_type($real) ?: '') : '';
    bjson(['ok'=>true,'name'=>basename($real),'size'=>$size,'mime'=>$mime,
           'b64'=>base64_encode((string)@file_get_contents($real))]);
}

// Write a text file by absolute path (the floating editor's Save for files
// opened from outside a project — dropped on the window, for instance). Same
// reach as 'read': whatever the web server user can write. Writers only.
if ($action === 'write') {
    auth_require_writer();
    $path = trim((string)($in['path'] ?? ''));
    $content = (string)($in['content'] ?? '');
    $real = realpath($path);
    if ($real === false || !is_file($real)) bjson(['ok'=>false,'error'=>'not found']);
    if (!is_writable($real)) bjson(['ok'=>false,'error'=>'not writable']);
    if (strlen($content) > 50 * 1024 * 1024) bjson(['ok'=>false,'error'=>'too large (max 50MB)']);
    if (@file_put_contents($real, $content, LOCK_EX) === false) bjson(['ok'=>false,'error'=>'write failed']);
    bjson(['ok'=>true,'size'=>strlen($content)]);
}

// Create a new sub-folder (for the picker's "New Folder" button).
if ($action === 'mkdir') {
    $path = trim((string)($in['path'] ?? ''));   // parent dir
    $name = trim((string)($in['name'] ?? ''));
    $real = realpath($path);
    if ($real === false || !is_dir($real)) bjson(['ok'=>false,'error'=>'parent not found']);
    if (!is_writable($real)) bjson(['ok'=>false,'error'=>'parent not writable']);
    // safe single-segment name
    if ($name === '' || strpbrk($name, "/\\\0") !== false || $name === '.' || $name === '..')
        bjson(['ok'=>false,'error'=>'invalid folder name']);
    $full = $real . '/' . $name;
    if (file_exists($full)) bjson(['ok'=>false,'error'=>'already exists','path'=>$full]);
    if (!@mkdir($full, 0775)) bjson(['ok'=>false,'error'=>'mkdir failed']);
    bjson(['ok'=>true,'path'=>$full]);
}

bjson(['ok'=>false,'error'=>'unknown action: '.$action]);
