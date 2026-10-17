<?php
// =============================================================================
// settings.php — global cockpit settings: paid-API spend consent + spend caps
// Dario Ruggi / Cockpit
//
// settings.json: {
//   "allow_paid_api_spend": false,           // GLOBAL master consent (default OFF)
//   "caps": { "global_monthly_usd": 0,       // 0 = no ceiling
//             "per_model_monthly_usd": { "<provider>:<model>": 5.0 } }
// }
// Spend is tracked separately in workers_spend.json (by workers.php, monthly).
// The invoke-time guard in workers.php enforces all of this server-side.
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$SETTINGS_F = $CD . '/settings.json';
$SPEND_F    = $CD . '/workers_spend.json';

function _read_settings(string $f): array {
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    if (!is_array($j)) $j = [];
    return [
        'allow_paid_api_spend' => !empty($j['allow_paid_api_spend']),
        'caps' => [
            'global_monthly_usd'    => (float)($j['caps']['global_monthly_usd'] ?? 0),
            'per_model_monthly_usd' => is_array($j['caps']['per_model_monthly_usd'] ?? null) ? $j['caps']['per_model_monthly_usd'] : [],
        ],
    ];
}
function _read_spend(string $f): array {
    $month = date('Y-m');
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    if (!is_array($j) || ($j['month'] ?? '') !== $month) return ['month'=>$month, 'global_usd'=>0.0, 'by_model'=>[]];
    return ['month'=>$month, 'global_usd'=>(float)($j['global_usd'] ?? 0), 'by_model'=>is_array($j['by_model'] ?? null) ? $j['by_model'] : []];
}
function _write_settings(string $f, array $s): bool {
    return file_put_contents($f, json_encode($s, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)) !== false;
}

$raw = file_get_contents('php://input');
$in  = json_decode($raw, true); if (!is_array($in)) $in = [];
$action = $_GET['action'] ?? ($in['action'] ?? 'get');

if ($action === 'get') {
    echo json_encode(['ok'=>true, 'settings'=>_read_settings($SETTINGS_F), 'spend'=>_read_spend($SPEND_F)], JSON_UNESCAPED_UNICODE);
    exit;
}

// Turn the global paid-spend master ON/OFF. Turning ON REQUIRES explicit consent.
if ($action === 'set_allow') {
    $allow   = !empty($in['allow']);
    $consent = !empty($in['consent']);
    if ($allow && !$consent) {
        echo json_encode(['ok'=>false, 'error'=>'Explicit consent required to enable paid API spend.'], JSON_UNESCAPED_UNICODE); exit;
    }
    $s = _read_settings($SETTINGS_F);
    $s['allow_paid_api_spend'] = $allow;
    if (!_write_settings($SETTINGS_F, $s)) { echo json_encode(['ok'=>false,'error'=>'Write failed'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true, 'settings'=>$s], JSON_UNESCAPED_UNICODE);
    exit;
}

// Update spend caps.
if ($action === 'set_caps') {
    $s = _read_settings($SETTINGS_F);
    $s['caps']['global_monthly_usd'] = max(0, (float)($in['global_monthly_usd'] ?? $s['caps']['global_monthly_usd']));
    if (isset($in['per_model_monthly_usd']) && is_array($in['per_model_monthly_usd'])) {
        $clean = [];
        foreach ($in['per_model_monthly_usd'] as $k => $v) {
            $k = preg_replace('/[^A-Za-z0-9_.:\-]/', '', (string)$k);
            $v = max(0, (float)$v);
            if ($k !== '' && $v > 0) $clean[$k] = $v;
        }
        $s['caps']['per_model_monthly_usd'] = $clean;
    }
    if (!_write_settings($SETTINGS_F, $s)) { echo json_encode(['ok'=>false,'error'=>'Write failed'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true, 'settings'=>$s], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);
