<?php
// =============================================================================
// cmd.php — the command window's backend. ONE simple command line at a time, run by the native engine as the owner of this Cockpit under the
// kernel's Landlock sandbox: it can write only in the person's Public folder, read their read-only areas and the system's programs, nothing
// else. If the machine cannot confine commands, nothing is run. Viewers cannot run commands.
//   GET  ?action=info                      engine answering? sandbox available? the zones
//   POST {action:"run", cmd:"ls -l", cwd:"public:sub"}
// =============================================================================
header('Content-Type: application/json');
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/engine_client.php';
ed_gate_or_exit('cmdpanel');

function cmd_out(array $a, int $code = 200): void { http_response_code($code); echo json_encode($a, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); exit; }
$in = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') { $in = json_decode((string)file_get_contents('php://input'), true); if (!is_array($in)) $in = []; }
$action = (string)($in['action'] ?? $_GET['action'] ?? '');
if (!ck_fm_zones()) cmd_out(['ok' => false, 'error' => 'No projects folder is set up for this account.']);

if ($action === 'info') {
    $s = ck_engine_call(['op' => 'sandbox'], 3.0);
    cmd_out(['ok' => true, 'engine' => $s !== null, 'sandbox' => (int)($s['abi'] ?? 0) > 0, 'viewer' => (string)($_SESSION['cockpit_role'] ?? 'admin') === 'viewer']);
}
if ($action === 'run') {
    if ((string)($_SESSION['cockpit_role'] ?? 'admin') === 'viewer') cmd_out(['ok' => false, 'error' => 'Your account cannot run commands.'], 403);
    $cmd = (string)($in['cmd'] ?? '');
    $r = ck_engine_call(ck_fm_req('exec', 'run', ['cmd' => $cmd, 'cwd' => (string)($in['cwd'] ?? 'public:'), 'timeout_s' => 20, 'max_output_kb' => 256]), 40.0);
    if ($r === null) cmd_out(['ok' => false, 'engine' => false, 'error' => 'The command service is not running. Start the agents (the supervisor hosts it) and try again.']);
    unset($r['type']);
    cmd_out($r);
}
cmd_out(['ok' => false, 'error' => 'unknown action'], 400);
