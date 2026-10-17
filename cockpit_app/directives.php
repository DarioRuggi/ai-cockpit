<?php
// =============================================================================
// directives.php — Unified Directive Layer backend
// Dario Ruggi / Cockpit
//
// Stores the GLOBAL directive block applied to every supplier (Claude, Gemini,
// Ollama, Workers) at dispatch by agent_loop.sh. Two text variants plus a small
// config:
//   directives_global.md          — full directive block (default suppliers)
//   directives_global_compact.md  — short variant for tiny models
//   directives_config.json        — { enabled, compact_suppliers:[...] }
//
// Per-project directives are NOT handled here — those remain each project's
// COCKPIT.md (edited via the existing files/saver flow). agent_loop merges:
//   operational protocol -> GLOBAL directives -> project COCKPIT.md -> ... -> task
// =============================================================================

header('Content-Type: application/json');

// --- Locate the shared cockpit_data dir (same convention as workers.php) ---
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$FULL_F      = $CD . '/directives_global.md';
$COMPACT_F   = $CD . '/directives_global_compact.md';
$CONFIG_F    = $CD . '/directives_config.json';

define('MAX_DIRECTIVE_BYTES', 8192); // mirrors agent_loop's head -c 8192 cap

function read_cfg(string $f): array {
    $defaults = ['enabled' => true, 'compact_suppliers' => ['ollama']];
    if (!is_file($f)) return $defaults;
    $j = json_decode((string)file_get_contents($f), true);
    if (!is_array($j)) return $defaults;
    return [
        'enabled'           => array_key_exists('enabled', $j) ? (bool)$j['enabled'] : true,
        'compact_suppliers' => isset($j['compact_suppliers']) && is_array($j['compact_suppliers'])
                                 ? array_values(array_filter(array_map('strval', $j['compact_suppliers'])))
                                 : ['ollama'],
    ];
}

// Read request: action may come from GET (read) or JSON body (write).
$raw    = file_get_contents('php://input');
$in     = json_decode($raw, true);
if (!is_array($in)) $in = [];
$action = $_GET['action'] ?? ($in['action'] ?? '');

switch ($action) {

    case 'get':
        // Per-supplier overrides — directives_<supplier>.md (optional; if present
        // and non-empty, used instead of full/compact for that supplier).
        $overrides = [];
        foreach (['claude','gemini','ollama','workers'] as $sup) {
            $of = $CD . '/directives_' . $sup . '.md';
            if (is_file($of)) $overrides[$sup] = (string)file_get_contents($of);
        }
        echo json_encode([
            'ok'        => true,
            'full'      => is_file($FULL_F)    ? file_get_contents($FULL_F)    : '',
            'compact'   => is_file($COMPACT_F) ? file_get_contents($COMPACT_F) : '',
            'overrides' => $overrides,
            'config'    => read_cfg($CONFIG_F),
            'limit'     => MAX_DIRECTIVE_BYTES,
        ], JSON_UNESCAPED_UNICODE);
        break;

    case 'save':
        $full    = (string)($in['full']    ?? '');
        $compact = (string)($in['compact'] ?? '');

        // Guard the context budget: refuse blocks larger than the dispatch cap
        // (agent_loop truncates at 8 KB anyway — fail loudly instead of silently
        // dropping the tail).
        if (strlen($full) > MAX_DIRECTIVE_BYTES || strlen($compact) > MAX_DIRECTIVE_BYTES) {
            echo json_encode(['ok' => false, 'error' =>
                'Directive too long (max ' . MAX_DIRECTIVE_BYTES . ' bytes; agent_loop truncates beyond that).'],
                JSON_UNESCAPED_UNICODE);
            exit;
        }

        $cfgIn   = is_array($in['config'] ?? null) ? $in['config'] : [];
        $cfg = [
            'enabled'           => array_key_exists('enabled', $cfgIn) ? (bool)$cfgIn['enabled'] : true,
            'compact_suppliers' => isset($cfgIn['compact_suppliers']) && is_array($cfgIn['compact_suppliers'])
                                     ? array_values(array_filter(array_map('strval', $cfgIn['compact_suppliers'])))
                                     : ['ollama'],
        ];

        // Per-supplier overrides (each ≤ cap; empty string → remove the override).
        $ovIn = is_array($in['overrides'] ?? null) ? $in['overrides'] : [];
        foreach (['claude','gemini','ollama','workers'] as $sup) {
            if (!array_key_exists($sup, $ovIn)) continue;
            $txt = (string)$ovIn[$sup];
            if (strlen($txt) > MAX_DIRECTIVE_BYTES) {
                echo json_encode(['ok'=>false,'error'=>$sup.' override too long (max '.MAX_DIRECTIVE_BYTES.' bytes).'], JSON_UNESCAPED_UNICODE); exit;
            }
            $of = $CD . '/directives_' . $sup . '.md';
            if (trim($txt) === '') { @unlink($of); }
            else                   { file_put_contents($of, $txt); }
        }

        $okF = file_put_contents($FULL_F,    $full)    !== false;
        $okC = file_put_contents($COMPACT_F, $compact) !== false;
        $okJ = file_put_contents($CONFIG_F,
                   json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n") !== false;

        if ($okF && $okC && $okJ) {
            echo json_encode(['ok' => true, 'config' => $cfg], JSON_UNESCAPED_UNICODE);
        } else {
            echo json_encode(['ok' => false, 'error' =>
                'Write failed (check permissions on ' . $CD . ').'], JSON_UNESCAPED_UNICODE);
        }
        break;

    default:
        echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
}
