<?php
// =============================================================================
// policy.php — Privacy & spending: settings, this month's usage, a scan for the test box,
// and a pre-flight check for routes that do not go through bridge.php (Workers).
//
//   GET  ?action=get                      settings + month usage + the agents on the cards
//   POST {action:'set', gate:{enabled,action}, free_only, budget:{paid_prompts_per_month}}
//   POST {action:'scan',  text}           what the gate WOULD find (previews only; nothing stored)
//   POST {action:'check', agent, text, policy:{gate,spend_ok}}   the same decision bridge.php makes
//
// The rules live in policy_lib.php; bridge.php enforces them for the agent cards.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/policy_lib.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
if (session_status() === PHP_SESSION_ACTIVE) session_write_close();   // read-mostly; never hold the lock

$in = json_decode((string)file_get_contents('php://input'), true);
if (!is_array($in)) $in = [];
$action = (string)($_GET['action'] ?? ($in['action'] ?? 'get'));

if ($action === 'get') {
    $pol = policy_load();
    $agents = [];
    foreach (['claude', 'gemini', 'ollama'] as $a) $agents[$a] = policy_agent_info($a);
    echo json_encode(['ok' => true, 'policy' => $pol, 'month' => gmdate('Y-m'), 'paid_used' => policy_month_used(),
                      'agents' => $agents], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'set') {
    auth_require_writer();
    $pol = policy_update($in);
    echo json_encode(['ok' => true, 'policy' => $pol, 'paid_used' => policy_month_used()], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'scan') {
    $text = (string)($in['text'] ?? '');
    if (strlen($text) > 200000) $text = substr($text, 0, 200000);
    $f = policy_detect($text);
    echo json_encode(['ok' => true, 'count' => count($f), 'findings' => policy_summarise($f),
                      'redacted' => policy_redact($text, $f)], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'check') {
    auth_require_writer();
    $agent = preg_replace('/[^a-z0-9_]/', '', strtolower((string)($in['agent'] ?? '')));
    $r = policy_check((string)($in['text'] ?? ''), $agent, (array)($in['policy'] ?? []));
    echo json_encode($r['allow']
        ? ['ok' => true, 'text' => $r['prompt'], 'notes' => $r['notes']]
        : ['ok' => false, 'policy' => $r['policy']], JSON_UNESCAPED_UNICODE);
    exit;
}
http_response_code(400);
echo json_encode(['ok' => false, 'error' => 'Unknown action']);
