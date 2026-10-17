<?php
// =============================================================================
// standards.php — run the Pascal/Lazarus standards check (tools/standards/pascal_standards.php) on a project.
//
//   GET ?project=NAME[&resources=1]     findings JSON, or (resources=1) a generated resourcestring unit as text
//
// Read-only. The scan never changes the project; the resourcestring unit is only returned.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
ed_gate_or_exit('export');   // demo: described-modal; v1/v2: real
define('PASCAL_STANDARDS_LIB', 1);
require_once __DIR__ . '/pascal_standards.php';

if (session_status() === PHP_SESSION_ACTIVE) session_write_close();
$proj = preg_replace('/[^a-zA-Z0-9_\-]/', '', (string)($_GET['project'] ?? ''));
$dir = rtrim($PATHS['projects_root'], '/') . '/' . $proj;
if (!auth_is_valid()) { http_response_code(401); header('Content-Type: application/json'); echo '{"ok":false,"error":"sign in"}'; exit; }
if ($proj === '' || !is_dir($dir)) { header('Content-Type: application/json'); echo json_encode(['ok' => false, 'error' => 'no such project']); exit; }
@set_time_limit(60);
$r = ps_scan($dir);
if (!empty($_GET['resources'])) { header('Content-Type: text/plain; charset=utf-8'); echo ps_resources($r['strings']); exit; }
header('Content-Type: application/json; charset=utf-8');
$r['findings'] = array_slice($r['findings'], 0, 300); unset($r['strings']);
echo json_encode(['ok' => true] + $r, JSON_UNESCAPED_UNICODE);
