<?php
// =============================================================================
// openlocal.php — serve a local file over http so the browser can view it
// (an http page can't open file:// via window.open). Cockpit already reads the
// filesystem; this just streams a file with the right Content-Type.
//
// Use PATH_INFO so relative assets resolve:
//   openlocal.php/home/<you>/SpeedDial/index.html
//   → its "style.css" requests openlocal.php/home/<you>/SpeedDial/style.css
//
// Localhost tool. Guarded: path must be an existing, readable regular file
// under an allowed root (home dirs / project + web trees), no traversal.
// =============================================================================

$pi = $_SERVER['PATH_INFO'] ?? '';
if ($pi === '' && isset($_GET['path'])) $pi = '/' . ltrim((string)$_GET['path'], '/');
$path = '/' . ltrim((string)$pi, '/');

$real = realpath($path);
if ($real === false || !is_file($real) || !is_readable($real)) {
    http_response_code(404); header('Content-Type: text/plain');
    echo "Not found or unreadable: " . $path; exit;
}

// Only serve from allowed roots (localhost, but avoid handing out arbitrary
// system files). Home mounts + the app/project trees.
$allowed = ['/home/', '/var/www/html/cockpit', '/media/', '/mnt/', '/srv/', '/opt/'];
$ok = false;
foreach ($allowed as $root) { if (strpos($real, $root) === 0) { $ok = true; break; } }
if (!$ok) { http_response_code(403); header('Content-Type: text/plain'); echo "Path not allowed."; exit; }

$ext = strtolower(pathinfo($real, PATHINFO_EXTENSION));
$mimes = [
    'html'=>'text/html; charset=utf-8', 'htm'=>'text/html; charset=utf-8',
    'css'=>'text/css; charset=utf-8', 'js'=>'application/javascript; charset=utf-8',
    'mjs'=>'application/javascript; charset=utf-8', 'json'=>'application/json; charset=utf-8',
    'svg'=>'image/svg+xml', 'png'=>'image/png', 'jpg'=>'image/jpeg', 'jpeg'=>'image/jpeg',
    'gif'=>'image/gif', 'webp'=>'image/webp', 'ico'=>'image/x-icon', 'bmp'=>'image/bmp',
    'pdf'=>'application/pdf', 'txt'=>'text/plain; charset=utf-8', 'md'=>'text/plain; charset=utf-8',
    'woff'=>'font/woff', 'woff2'=>'font/woff2', 'ttf'=>'font/ttf', 'otf'=>'font/otf',
    'mp4'=>'video/mp4', 'webm'=>'video/webm', 'mp3'=>'audio/mpeg', 'ogg'=>'audio/ogg', 'wav'=>'audio/wav',
];
$ctype = $mimes[$ext] ?? 'application/octet-stream';
header('Content-Type: ' . $ctype);
header('Content-Length: ' . filesize($real));
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
readfile($real);
