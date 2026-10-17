<?php
// =============================================================================
// stats.php — hierarchical cost/usage ledger (per chat + per project)
// Dario Ruggi / Cockpit
//
// cost_stats.json: {
//   "projects": { "<project>": {tin,tout,usd,turns} },
//   "chats":    { "<project>/<chat>": {tin,tout,usd,turns} }
// }
// Session-tier totals are client-side (volatile). The status bar shows all three.
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
$F = $CD . '/cost_stats.json';

function _zero(): array { return ['tin'=>0, 'tout'=>0, 'usd'=>0.0, 'turns'=>0]; }
function _load(string $f): array {
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    if (!is_array($j)) $j = [];
    return ['projects' => is_array($j['projects'] ?? null) ? $j['projects'] : [],
            'chats'    => is_array($j['chats']    ?? null) ? $j['chats']    : []];
}
function _addinto(array &$bucket, string $k, array $delta): void {
    if (!isset($bucket[$k])) $bucket[$k] = _zero();
    $bucket[$k]['tin']   += (int)$delta['tin'];
    $bucket[$k]['tout']  += (int)$delta['tout'];
    $bucket[$k]['usd']    = round($bucket[$k]['usd'] + (float)$delta['usd'], 6);
    $bucket[$k]['turns'] += (int)$delta['turns'];
}
function _safe(string $s): string { return preg_replace('#[^A-Za-z0-9_.\-/]#', '_', $s); }

$raw = file_get_contents('php://input');
$in  = json_decode($raw, true); if (!is_array($in)) $in = [];
$action = $_GET['action'] ?? ($in['action'] ?? 'get');

if ($action === 'get') {
    $s = _load($F);
    $project = _safe((string)($_GET['project'] ?? 'default'));
    $chat    = _safe((string)($_GET['chat'] ?? 'default'));
    echo json_encode([
        'ok'      => true,
        'project' => $s['projects'][$project] ?? _zero(),
        'chat'    => $s['chats'][$project.'/'.$chat] ?? _zero(),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'add') {
    $project = _safe((string)($in['project'] ?? 'default')) ?: 'default';
    $chat    = _safe((string)($in['chat'] ?? 'default')) ?: 'default';
    $delta = ['tin'=>(int)($in['tin'] ?? 0), 'tout'=>(int)($in['tout'] ?? 0),
              'usd'=>(float)($in['usd'] ?? 0), 'turns'=>1];
    $lock = @fopen($F, 'c+'); if (!$lock || !flock($lock, LOCK_EX)) { if ($lock) fclose($lock); echo json_encode(['ok'=>false,'error'=>'lock'], JSON_UNESCAPED_UNICODE); exit; }
    $s = _load($F);
    _addinto($s['projects'], $project, $delta);
    _addinto($s['chats'], $project.'/'.$chat, $delta);
    ftruncate($lock, 0); rewind($lock);
    fwrite($lock, json_encode($s, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    fflush($lock); flock($lock, LOCK_UN); fclose($lock);
    echo json_encode(['ok'=>true, 'project'=>$s['projects'][$project], 'chat'=>$s['chats'][$project.'/'.$chat]], JSON_UNESCAPED_UNICODE);
    exit;
}

// Move a chat's accumulated cost between projects.
//   mode "transfer" → cost follows the chat into the new project.
//   mode "reset"    → chat starts fresh in the new project (old project loses it).
if ($action === 'move_chat') {
    $from = _safe((string)($in['from_project'] ?? '')) ?: 'default';
    $to   = _safe((string)($in['to_project'] ?? '')) ?: 'default';
    $slug = _safe((string)($in['slug'] ?? ''));
    $mode = ($in['mode'] ?? 'transfer') === 'reset' ? 'reset' : 'transfer';
    if (!$slug) { echo json_encode(['ok'=>false,'error'=>'Missing slug'], JSON_UNESCAPED_UNICODE); exit; }
    $lock = @fopen($F, 'c+'); if (!$lock || !flock($lock, LOCK_EX)) { if ($lock) fclose($lock); echo json_encode(['ok'=>false,'error'=>'lock'], JSON_UNESCAPED_UNICODE); exit; }
    $s = _load($F);
    $kFrom = $from.'/'.$slug; $kTo = $to.'/'.$slug;
    $cost = $s['chats'][$kFrom] ?? _zero();
    // Remove from old project total.
    if (isset($s['projects'][$from])) {
        $s['projects'][$from]['tin']   = max(0, $s['projects'][$from]['tin']   - $cost['tin']);
        $s['projects'][$from]['tout']  = max(0, $s['projects'][$from]['tout']  - $cost['tout']);
        $s['projects'][$from]['usd']   = max(0, round($s['projects'][$from]['usd'] - $cost['usd'], 6));
        $s['projects'][$from]['turns'] = max(0, $s['projects'][$from]['turns'] - $cost['turns']);
    }
    unset($s['chats'][$kFrom]);
    if ($mode === 'transfer') {
        $s['chats'][$kTo] = $cost;
        _addinto($s['projects'], $to, $cost);
    } else {
        $s['chats'][$kTo] = _zero();
        if (!isset($s['projects'][$to])) $s['projects'][$to] = _zero();
    }
    ftruncate($lock, 0); rewind($lock);
    fwrite($lock, json_encode($s, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    fflush($lock); flock($lock, LOCK_UN); fclose($lock);
    echo json_encode(['ok'=>true, 'mode'=>$mode, 'moved'=>$cost], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);
