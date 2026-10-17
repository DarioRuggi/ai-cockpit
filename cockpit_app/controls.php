<?php
// =============================================================================
// controls.php — per-supplier control definitions (model, effort, …)
// Dario Ruggi / Cockpit
//
// Serves & saves cockpit_data/{claude,gemini}_controls.json so the supplier
// cards can render their dropdowns from JSON (add a control = edit JSON, no
// recompile). Each control: { id, label, inject, default, options:[{name,value}] }
//   inject: "model"         → the value is the CLI model string (-m / --model)
//           "prompt_prefix" → the value is text prepended to the prompt
//           "cli_args"      → the value is extra args appended to the CLI
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$raw = file_get_contents('php://input');
$in  = json_decode($raw, true); if (!is_array($in)) $in = [];
$action   = $_GET['action']   ?? ($in['action']   ?? '');
// Any supplier id (claude/gemini/codex/qwen_code/aider/goose/opencode/…). Controls
// are per-SUPPLIER now (not per-slot), so a slot running Codex edits codex_controls.json.
$supplier = preg_replace('/[^a-z0-9_]/', '', strtolower((string)($_GET['supplier'] ?? ($in['supplier'] ?? ''))));

if ($supplier === '') { echo json_encode(['ok' => false, 'error' => 'Missing supplier'], JSON_UNESCAPED_UNICODE); exit; }
$f = $CD . '/' . $supplier . '_controls.json';

if ($action === 'get') {
    $content = is_file($f) ? file_get_contents($f) : '';
    echo json_encode([
        'ok'       => true,
        'supplier' => $supplier,
        'content'  => $content,
        'config'   => $content ? json_decode($content, true) : null,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'save') {
    $content = (string)($in['content'] ?? '');
    $parsed  = json_decode($content, true);
    if (!is_array($parsed) || !isset($parsed['controls']) || !is_array($parsed['controls'])) {
        echo json_encode(['ok' => false, 'error' => 'Invalid JSON: needs a "controls" array'], JSON_UNESCAPED_UNICODE); exit;
    }
    if (strlen($content) > 65536) { echo json_encode(['ok' => false, 'error' => 'Too large'], JSON_UNESCAPED_UNICODE); exit; }
    if (file_put_contents($f, $content) === false) {
        echo json_encode(['ok' => false, 'error' => 'Write failed (permissions on ' . $CD . ')'], JSON_UNESCAPED_UNICODE); exit;
    }
    echo json_encode(['ok' => true, 'supplier' => $supplier], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
