<?php
// =============================================================================
// help.php — serves & saves the JSON help content (cockpit_data/help.json)
// Dario Ruggi / Cockpit
//
// { "welcome": {title, body}, "topics": { "<id>": {title, body}, ... } }
// body is trusted local HTML rendered into the help modal. Edit in-app via the
// floating editor (no recompile to add/adjust help).
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$F = $CD . '/help.json';

$raw = file_get_contents('php://input');
$in  = json_decode($raw, true); if (!is_array($in)) $in = [];
$action = $_GET['action'] ?? ($in['action'] ?? 'get');

if ($action === 'get') {
    $content = is_file($F) ? file_get_contents($F) : '';
    // Seed from the bundled default (help_default.json) when there is no per-user
    // copy — and RE-SEED whenever the bundled default changes, as long as the
    // user's copy is still the one we seeded (sha kept in help.json.seed). A copy
    // the user edited in the Help editor is left alone. Before 2026-09-13 the seed
    // happened once, so every shipped help update was invisible to existing
    // installs (a user saw broken guide tables for a day after they were fixed).
    $def = __DIR__ . '/help_default.json';
    $seedF = $F . '.seed';
    if (is_file($def)) {
        $defC = (string)file_get_contents($def);
        $defSha = sha1($defC);
        $seeded = is_file($seedF) ? trim((string)file_get_contents($seedF)) : '';
        $userSha = ($content !== '' && $content !== false) ? sha1((string)$content) : '';
        // No seed marker = a copy from before the marker existed: unmodified unless the
        // Help editor ever saved it (help.json.edited, written by action=save below).
        $unmodified = ($userSha === '') || ($seeded !== '' ? $userSha === $seeded : !is_file($F . '.edited'));
        if ($defC !== '' && $unmodified && $userSha !== $defSha) {
            $content = $defC;
            if (@file_put_contents($F, $content) !== false) @file_put_contents($seedF, $defSha);
        } elseif ($seeded === '' && $userSha === $defSha) {
            @file_put_contents($seedF, $defSha);   // adopt: an existing identical copy is "seeded"
        }
    }
    echo json_encode([
        'ok'      => true,
        'content' => $content,
        'help'    => $content ? json_decode($content, true) : null,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'save') {
    $content = (string)($in['content'] ?? '');
    $parsed  = json_decode($content, true);
    if (!is_array($parsed) || !isset($parsed['topics']) || !is_array($parsed['topics'])) {
        echo json_encode(['ok' => false, 'error' => 'Invalid JSON: needs a "topics" object'], JSON_UNESCAPED_UNICODE); exit;
    }
    if (strlen($content) > 524288) { echo json_encode(['ok' => false, 'error' => 'Too large'], JSON_UNESCAPED_UNICODE); exit; }
    if (file_put_contents($F, $content) === false) {
        echo json_encode(['ok' => false, 'error' => 'Write failed (permissions on ' . $CD . ')'], JSON_UNESCAPED_UNICODE); exit;
    }
    @file_put_contents($F . '.edited', date('c'));   // the user's copy is theirs now: no re-seeding
    echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
