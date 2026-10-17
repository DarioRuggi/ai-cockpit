<?php
// =============================================================================
// caps.php — Per-model usage caps
//
// Stores and retrieves spending/token limits per supplier or per model.
// Caps are advisory (UI warning + soft block) — not a billing gate.
//
// Actions:
//   ?action=get     — GET current caps config
//   ?action=set     — POST {caps: {...}} — save caps
//   ?action=check   — POST {agent, tokens_in, tokens_out, usd} — check if within cap
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

$CAPS_F = $PATHS['cockpit_data'] . '/model_caps.json';

header('Content-Type: application/json');
header('Cache-Control: no-store');

$action = $_GET['action'] ?? '';
$in = json_decode((string)file_get_contents('php://input'), true) ?: [];

function caps_load(string $f): array {
    if (!is_readable($f)) return [];
    $d = json_decode(file_get_contents($f), true);
    return is_array($d) ? $d : [];
}

function caps_save(string $f, array $data): void {
    $dir = dirname($f);
    if (!is_dir($dir)) @mkdir($dir, 0775, true);
    file_put_contents($f, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), LOCK_EX);
    @chmod($f, 0664);
}

// Default cap structure per agent
function caps_defaults(): array {
    return [
        'claude' => [
            'enabled'       => false,
            'max_tokens_day'=> 100000,
            'max_usd_day'   => 5.00,
            'max_tokens_session' => 0,
            'warn_pct'      => 80,
        ],
        'gemini' => [
            'enabled'       => false,
            'max_tokens_day'=> 200000,
            'max_usd_day'   => 5.00,
            'max_tokens_session' => 0,
            'warn_pct'      => 80,
        ],
        'ollama' => [
            'enabled'       => false,
            'max_tokens_day'=> 0,
            'max_usd_day'   => 0,
            'max_tokens_session' => 0,
            'warn_pct'      => 80,
        ],
    ];
}

if ($action === 'get') {
    $caps = caps_load($CAPS_F);
    $defaults = caps_defaults();
    foreach ($defaults as $k => $v) {
        if (!isset($caps[$k])) $caps[$k] = $v;
        else $caps[$k] = array_merge($v, $caps[$k]);
    }
    echo json_encode(['ok' => true, 'caps' => $caps], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'set') {
    auth_require_admin();
    $caps = $in['caps'] ?? [];
    if (!is_array($caps)) {
        echo json_encode(['ok' => false, 'error' => 'Invalid caps format'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    // Merge with defaults to ensure all fields exist
    $defaults = caps_defaults();
    foreach ($defaults as $k => $v) {
        if (isset($caps[$k])) {
            $caps[$k] = array_merge($v, $caps[$k]);
            $caps[$k]['max_tokens_day'] = max(0, (int)($caps[$k]['max_tokens_day'] ?? 0));
            $caps[$k]['max_usd_day']    = max(0, (float)($caps[$k]['max_usd_day'] ?? 0));
            $caps[$k]['max_tokens_session'] = max(0, (int)($caps[$k]['max_tokens_session'] ?? 0));
            $caps[$k]['warn_pct']       = max(0, min(100, (int)($caps[$k]['warn_pct'] ?? 80)));
            $caps[$k]['enabled']        = !empty($caps[$k]['enabled']);
        } else {
            $caps[$k] = $v;
        }
    }
    caps_save($CAPS_F, $caps);
    echo json_encode(['ok' => true, 'caps' => $caps], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'check') {
    $agent     = trim((string)($in['agent'] ?? ''));
    $tokens_in = (int)($in['tokens_in'] ?? 0);
    $tokens_out= (int)($in['tokens_out'] ?? 0);
    $usd       = (float)($in['usd'] ?? 0);
    $day_tokens= (int)($in['day_tokens'] ?? 0);
    $day_usd   = (float)($in['day_usd'] ?? 0);

    $caps = caps_load($CAPS_F);
    $defaults = caps_defaults();
    $cap = array_merge($defaults[$agent] ?? [], $caps[$agent] ?? []);

    if (empty($cap['enabled'])) {
        echo json_encode(['ok' => true, 'allowed' => true, 'reason' => 'caps disabled'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $blocked = false;
    $warnings = [];

    if ($cap['max_tokens_day'] > 0 && $day_tokens >= $cap['max_tokens_day']) {
        $blocked = true;
        $warnings[] = 'Daily token cap reached (' . $day_tokens . '/' . $cap['max_tokens_day'] . ')';
    } elseif ($cap['max_tokens_day'] > 0) {
        $pct = ($day_tokens / $cap['max_tokens_day']) * 100;
        if ($pct >= $cap['warn_pct']) {
            $warnings[] = 'Token usage at ' . round($pct) . '% of daily cap';
        }
    }

    if ($cap['max_usd_day'] > 0 && $day_usd >= $cap['max_usd_day']) {
        $blocked = true;
        $warnings[] = 'Daily cost cap reached ($' . number_format($day_usd, 2) . '/$' . number_format($cap['max_usd_day'], 2) . ')';
    } elseif ($cap['max_usd_day'] > 0) {
        $pct = ($day_usd / $cap['max_usd_day']) * 100;
        if ($pct >= $cap['warn_pct']) {
            $warnings[] = 'Cost at ' . round($pct) . '% of daily cap ($' . number_format($day_usd, 2) . ')';
        }
    }

    echo json_encode([
        'ok'       => true,
        'allowed'  => !$blocked,
        'blocked'  => $blocked,
        'warnings' => $warnings,
        'cap'      => $cap,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
