<?php
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// attachments.php — Per-chat file attachments for the AI Cockpit
//
// Storage layout:
//   <projects_root>/<project>/chat_<chat>_contexts/
//       <safe-filename>            ← the saved file (text or binary)
//       _meta.json                 ← index of attachments with metadata
//
//   For standalone (_standalone) chats:
//   <cockpit_data>/contexts/<chat>/
//
// ACTIONS (POST JSON body unless noted):
//   {action:save,   project, chat, filename, data_b64, mime?}
//                                  → save a file; returns absolute path + size
//   ?action=list&project=&chat=    → list attachments + metadata (GET)
//   {action:delete, project, chat, filename}
//                                  → delete one attachment
//   {action:clear,  project, chat} → delete all attachments for this chat
//   ?action=view&project=&chat=&filename=
//                                  → stream the file content (GET, binary-safe)
//
// All paths are validated:
//   - project must match /^[A-Za-z0-9 _.\-]+$/  (or _standalone)
//   - chat name must match /^[A-Za-z0-9 _.\-]+$/
//   - filename is basename-only, no slashes, max 200 chars
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$LOCAL_PROJ_ROOT     = $PATHS['projects_root'];
$STANDALONE_CTX_ROOT = $PATHS['cockpit_data'] . '/contexts';

// =============================================================================
// Helpers
// =============================================================================

function jerr($msg, $code = 400) {
    http_response_code($code);
    header('Content-Type: application/json');
    echo json_encode(['ok' => false, 'error' => $msg], JSON_UNESCAPED_UNICODE);
    exit;
}

function jok($payload) {
    header('Content-Type: application/json');
    echo json_encode(['ok' => true] + $payload, JSON_UNESCAPED_UNICODE);
    exit;
}

// Sanitize a project/chat identifier — allow Unicode letters/digits + space/_/-/.
// Blocks path separators and control bytes. The /u flag enables Unicode-aware
// regex. XCUT-5 fix: previously stripped Hebrew/Spanish accents to garbage.
function clean_id($s) {
    $s = (string)$s;
    if ($s === '_standalone') return $s;
    // Reject only path separators, control chars, leading/trailing dots
    if (preg_match('/[\/\\\\\x00-\x1f]/u', $s)) return false;
    $s = (string)preg_replace('/\.\.+/u', '.', $s);  // collapse .. to .
    $s = trim($s);
    if ($s === '' || $s === '.' || $s === '..') return false;
    if (mb_strlen($s) > 128) return false;
    return $s;
}

// Sanitize a filename — basename only, conservative but Unicode-friendly
function clean_filename($s) {
    $s = (string)$s;
    if ($s === '' || strlen($s) > 200) return false;
    $s = basename($s);
    if ($s === '.' || $s === '..' || $s === '') return false;
    // Reject path separators and control bytes (incl. NUL) outright
    if (preg_match('/[\/\\\\\x00-\x1f]/u', $s)) return false;
    return $s;
}

// Resolve the contexts directory for a (project, chat) pair. Creates if missing.
function ctx_dir($project, $chat) {
    global $LOCAL_PROJ_ROOT, $STANDALONE_CTX_ROOT;
    if ($project === '_standalone') {
        $dir = $STANDALONE_CTX_ROOT . '/' . $chat;
    } else {
        $dir = $LOCAL_PROJ_ROOT . '/' . $project . '/chat_' . $chat . '_contexts';
    }
    if (!is_dir($dir)) {
        @mkdir($dir, 0775, true);
    }
    return $dir;
}

// Load the _meta.json index for a contexts dir
function load_meta($dir) {
    $f = $dir . '/_meta.json';
    if (!is_file($f)) return [];
    $j = @json_decode(@file_get_contents($f), true);
    return is_array($j) ? $j : [];
}

function save_meta($dir, $meta) {
    $f = $dir . '/_meta.json';
    // Atomic write: .tmp + rename. Prevents partial-write corruption if
    // a parallel request hits during the write.
    $tmp = $f . '.tmp';
    if (@file_put_contents($tmp, json_encode(array_values($meta), JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE)) === false) return;
    @chmod($tmp, 0664);
    @rename($tmp, $f);
}

// Map an extension to an "output_kind" hint that the router uses
function ext_kind($ext) {
    $ext = strtolower($ext);
    $map = [
        'mp3'=>'audio','wav'=>'audio','flac'=>'audio','ogg'=>'audio','m4a'=>'audio','opus'=>'audio',
        'mp4'=>'video','webm'=>'video','mkv'=>'video','mov'=>'video','avi'=>'video',
        'png'=>'image','jpg'=>'image','jpeg'=>'image','webp'=>'image','gif'=>'image','bmp'=>'image',
        'pdf'=>'document','docx'=>'document','odt'=>'document','rtf'=>'document',
        'epub'=>'document','chm'=>'document','mobi'=>'document',
        'srt'=>'subtitle','vtt'=>'subtitle','ass'=>'subtitle',
        'zip'=>'archive','tar'=>'archive','gz'=>'archive','7z'=>'archive','rar'=>'archive',
    ];
    return $map[$ext] ?? 'text';
}

// =============================================================================
// Parse input — JSON body for write actions, querystring for read actions
// =============================================================================

$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action = $_GET['action'] ?? '';
$in     = [];

// Files arrive as base64 inside a JSON body, so memory_limit (not upload_max_filesize) is the ceiling: the base64
// text, its decoded copy and the decoded JSON array are alive together, about 3.7x the file. The distribution's 128M
// died with an empty 500 at ~35 MB although the documented cap is 50 MB. Raise it for THIS request only.
@ini_set('memory_limit', '768M');
if ($method === 'POST') {
    $raw = file_get_contents('php://input');
    $in  = @json_decode($raw, true);
    unset($raw);                                    // one copy less while the file is decoded
    if (!is_array($in)) $in = $_POST;
    if (empty($action)) $action = $in['action'] ?? '';
}

// =============================================================================
// ACTION: save — store an uploaded attachment
// =============================================================================
if ($action === 'save') {
    $project  = clean_id($in['project'] ?? '');
    $chat     = clean_id($in['chat']    ?? '');
    $filename = clean_filename($in['filename'] ?? '');
    $data_b64 = (string)($in['data_b64'] ?? '');
    $mime     = (string)($in['mime']     ?? '');

    if ($project === false || $chat === false || $filename === false || $data_b64 === '') {
        jerr('Missing or invalid: project, chat, filename, data_b64');
    }

    $bin = base64_decode($data_b64, true);
    if ($bin === false) jerr('Bad base64 data');

    // 50 MB safety cap on a single attachment
    if (strlen($bin) > 50 * 1024 * 1024) jerr('File too large (max 50MB)', 413);

    $dir = ctx_dir($project, $chat);
    if (!$dir || !is_dir($dir)) jerr('Could not create contexts dir', 500);

    // Avoid collisions — if a file with this name exists, suffix with -N
    $base = pathinfo($filename, PATHINFO_FILENAME);
    $ext  = pathinfo($filename, PATHINFO_EXTENSION);
    $tryName = $filename;
    $n = 1;
    while (file_exists($dir . '/' . $tryName)) {
        $tryName = $base . '-' . $n . ($ext ? '.' . $ext : '');
        $n++;
        if ($n > 999) jerr('Could not pick a unique name', 500);
    }
    $finalPath = $dir . '/' . $tryName;

    if (file_put_contents($finalPath, $bin) === false) {
        jerr('Failed to write file', 500);
    }
    @chmod($finalPath, 0664);

    // Update _meta.json
    $meta = load_meta($dir);
    $entry = [
        'filename' => $tryName,
        'size'     => strlen($bin),
        'mime'     => $mime,
        'ext'      => strtolower($ext),
        'kind'     => ext_kind($ext),
        'created'  => date('c'),
        'path'     => $finalPath,
    ];
    $meta[] = $entry;
    save_meta($dir, $meta);

    jok([
        'filename' => $tryName,
        'path'     => $finalPath,
        'size'     => strlen($bin),
        'kind'     => $entry['kind'],
        'ext'      => $entry['ext'],
    ]);
}

// =============================================================================
// ACTION: ingest_path — attach a file already on the server (by absolute path).
// Used by the Cockpit file picker (no browser upload). Copies it into the
// chat's attachment store. Returns the same shape as 'save' (+ content for
// small text files so the client can inline without a second round-trip).
// =============================================================================
if ($action === 'ingest_path') {
    $project = clean_id($in['project'] ?? '');
    $chat    = clean_id($in['chat']    ?? '');
    $src     = (string)($in['path'] ?? '');
    if ($project === false || $chat === false || $src === '') jerr('Missing project/chat/path');

    $real = realpath($src);
    if ($real === false || !is_file($real)) jerr('File not found: ' . $src);
    if (!is_readable($real)) jerr('File not readable');
    $size = (int)filesize($real);
    if ($size > 50 * 1024 * 1024) jerr('File too large (max 50MB)', 413);

    $filename = clean_filename(basename($real));
    if ($filename === false) jerr('Bad filename');
    $dir = ctx_dir($project, $chat);
    if (!$dir || !is_dir($dir)) jerr('Could not create contexts dir', 500);

    $base = pathinfo($filename, PATHINFO_FILENAME);
    $ext  = pathinfo($filename, PATHINFO_EXTENSION);
    $tryName = $filename; $n = 1;
    while (file_exists($dir . '/' . $tryName)) {
        $tryName = $base . '-' . $n . ($ext ? '.' . $ext : ''); $n++;
        if ($n > 999) jerr('Could not pick a unique name', 500);
    }
    $finalPath = $dir . '/' . $tryName;
    if (!@copy($real, $finalPath)) jerr('Failed to copy file', 500);
    @chmod($finalPath, 0664);

    $mime = function_exists('mime_content_type') ? (@mime_content_type($real) ?: '') : '';
    $meta = load_meta($dir);
    $entry = ['filename'=>$tryName,'size'=>$size,'mime'=>$mime,'ext'=>strtolower($ext),
              'kind'=>ext_kind($ext),'created'=>date('c'),'path'=>$finalPath];
    $meta[] = $entry; save_meta($dir, $meta);

    $resp = ['filename'=>$tryName,'path'=>$finalPath,'size'=>$size,'kind'=>$entry['kind'],
             'ext'=>$entry['ext'],'mime'=>$mime];
    // include content for small text-ish files (client inline route)
    $textExts = ['txt','md','markdown','json','jsonl','csv','tsv','xml','yaml','yml','ini','conf','cfg',
                 'log','html','htm','css','js','ts','php','py','sh','bash','pas','pp','c','h','cpp','sql','env'];
    if ($size <= 1024 * 1024 && in_array(strtolower($ext), $textExts, true)) {
        $resp['content'] = (string)@file_get_contents($finalPath);
    }
    jok($resp);
}

// =============================================================================
// ACTION: list — return all attachments for a chat
// =============================================================================
if ($action === 'list') {
    $project = clean_id($_GET['project'] ?? '');
    $chat    = clean_id($_GET['chat']    ?? '');
    if ($project === false || $chat === false) jerr('Invalid project/chat');

    $dir = ctx_dir($project, $chat);
    $meta = load_meta($dir);

    // Refresh from disk: drop entries whose file is gone, add files not yet in meta
    $known = [];
    $cleaned = [];
    foreach ($meta as $e) {
        $fp = $dir . '/' . $e['filename'];
        if (is_file($fp)) {
            $e['size'] = filesize($fp);
            $cleaned[] = $e;
            $known[$e['filename']] = true;
        }
    }
    foreach (glob($dir . '/*') ?: [] as $fp) {
        $fn = basename($fp);
        if ($fn === '_meta.json' || isset($known[$fn]) || !is_file($fp)) continue;
        $ext = strtolower(pathinfo($fn, PATHINFO_EXTENSION));
        $cleaned[] = [
            'filename' => $fn,
            'size'     => filesize($fp),
            'mime'     => '',
            'ext'      => $ext,
            'kind'     => ext_kind($ext),
            'created'  => date('c', filemtime($fp)),
            'path'     => $fp,
        ];
    }
    if (count($cleaned) !== count($meta)) save_meta($dir, $cleaned);

    jok(['attachments' => $cleaned, 'count' => count($cleaned), 'dir' => $dir]);
}

// =============================================================================
// ACTION: delete — remove one attachment
// =============================================================================
if ($action === 'delete') {
    $project  = clean_id($in['project']  ?? '');
    $chat     = clean_id($in['chat']     ?? '');
    $filename = clean_filename($in['filename'] ?? '');
    if ($project === false || $chat === false || $filename === false) jerr('Invalid args');

    $dir = ctx_dir($project, $chat);
    $fp  = $dir . '/' . $filename;
    if (!is_file($fp)) jerr('Not found', 404);
    @unlink($fp);

    $meta = load_meta($dir);
    $meta = array_values(array_filter($meta, fn($e) => $e['filename'] !== $filename));
    save_meta($dir, $meta);

    jok(['filename' => $filename]);
}

// =============================================================================
// ACTION: clear — delete all attachments for a chat
// =============================================================================
if ($action === 'clear') {
    $project = clean_id($in['project'] ?? '');
    $chat    = clean_id($in['chat']    ?? '');
    if ($project === false || $chat === false) jerr('Invalid project/chat');

    $dir = ctx_dir($project, $chat);
    foreach (glob($dir . '/*') ?: [] as $fp) {
        if (is_file($fp)) @unlink($fp);
    }
    jok(['cleared' => $dir]);
}

// =============================================================================
// ACTION: view — stream the file content (binary-safe)
// =============================================================================
if ($action === 'view') {
    $project  = clean_id($_GET['project']  ?? '');
    $chat     = clean_id($_GET['chat']     ?? '');
    $filename = clean_filename($_GET['filename'] ?? '');
    if ($project === false || $chat === false || $filename === false) jerr('Invalid args');

    $dir = ctx_dir($project, $chat);
    $fp  = $dir . '/' . $filename;
    if (!is_file($fp)) jerr('Not found', 404);

    // Guess content-type from extension
    $ext  = strtolower(pathinfo($filename, PATHINFO_EXTENSION));
    $mime = [
        'png'=>'image/png','jpg'=>'image/jpeg','jpeg'=>'image/jpeg','webp'=>'image/webp','gif'=>'image/gif',
        'mp3'=>'audio/mpeg','wav'=>'audio/wav','ogg'=>'audio/ogg',
        'mp4'=>'video/mp4','webm'=>'video/webm',
        'pdf'=>'application/pdf','txt'=>'text/plain; charset=utf-8',
        'json'=>'application/json','md'=>'text/markdown; charset=utf-8','html'=>'text/html; charset=utf-8',
    ][$ext] ?? 'application/octet-stream';

    header('Content-Type: ' . $mime);
    header('Content-Length: ' . filesize($fp));
    header('Content-Disposition: inline; filename="' . $filename . '"');
    readfile($fp);
    exit;
}

jerr('Unknown action: ' . $action);
