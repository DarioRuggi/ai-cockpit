<?php
// =============================================================================
// time.php — Time tracking for AI Cockpit
//
// Tracks time spent per project/chat. A single "active" timer at a time; start
// stops any running one first. Entries are appended to time_log.json.
//
// Schema:
//   time_log.json = { active: {project,chat,label,started} | null,
//                     entries: [ {id,project,chat,label,started,ended,seconds} ] }
//
// Endpoints (JSON):
//   GET  ?action=status                       — current active timer (if any)
//   POST ?action=start { project, chat, label } — start (stops any running)
//   POST ?action=stop                          — stop the active timer
//   GET  ?action=report&range=today|week|month|all[&project=X]
//   POST ?action=add_manual { project, chat, label, seconds }
//   POST ?action=delete { id }
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
if (!is_dir($CD)) @mkdir($CD, 0775, true);
$LOG_F = $CD . '/time_log.json';

$action = $_GET['action'] ?? '';
$in = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $raw = json_decode((string)file_get_contents('php://input'), true);
    if (is_array($raw)) $in = $raw;
    if ($action === '') $action = $in['action'] ?? '';
}
if ($action === '') $action = 'status';

function tl_load($f) {
    if (!is_file($f)) return ['active'=>null, 'entries'=>[]];
    $j = json_decode((string)file_get_contents($f), true);
    if (!is_array($j)) return ['active'=>null, 'entries'=>[]];
    if (!isset($j['entries']) || !is_array($j['entries'])) $j['entries'] = [];
    if (!array_key_exists('active', $j)) $j['active'] = null;
    return $j;
}
function tl_save_atomic($f, $data) {
    // Use flock — start/stop can race with the UI's status poll
    $fp = @fopen($f, 'c+');
    if (!$fp) return false;
    if (!flock($fp, LOCK_EX)) { fclose($fp); return false; }
    ftruncate($fp, 0); rewind($fp);
    fwrite($fp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);
    @chmod($f, 0664);
    return true;
}

// ── status ────────────────────────────────────────────────────────────────────
if ($action === 'status') {
    $log = tl_load($LOG_F);
    $active = $log['active'];
    $elapsed = null;
    if ($active && !empty($active['started'])) {
        $elapsed = time() - (int)$active['started'];
    }
    echo json_encode(['ok'=>true, 'active'=>$active, 'elapsed'=>$elapsed], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── start ─────────────────────────────────────────────────────────────────────
if ($action === 'start') {
    $log = tl_load($LOG_F);
    $now = time();
    // Stop any running timer first (auto-close into an entry)
    if (!empty($log['active']) && !empty($log['active']['started'])) {
        $a = $log['active'];
        $log['entries'][] = [
            'id'      => uniqid('t_', true),
            'project' => $a['project'] ?? '',
            'chat'    => $a['chat'] ?? '',
            'label'   => $a['label'] ?? '',
            'started' => (int)$a['started'],
            'ended'   => $now,
            'seconds' => max(0, $now - (int)$a['started']),
        ];
    }
    $log['active'] = [
        'project' => trim((string)($in['project'] ?? '')),
        'chat'    => trim((string)($in['chat'] ?? '')),
        'label'   => trim((string)($in['label'] ?? '')),
        'started' => $now,
    ];
    tl_save_atomic($LOG_F, $log);
    echo json_encode(['ok'=>true, 'active'=>$log['active']], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── stop ──────────────────────────────────────────────────────────────────────
if ($action === 'stop') {
    $log = tl_load($LOG_F);
    if (empty($log['active']) || empty($log['active']['started'])) {
        echo json_encode(['ok'=>true, 'stopped'=>false, 'note'=>'No active timer'], JSON_UNESCAPED_UNICODE); exit;
    }
    $now = time();
    $a = $log['active'];
    $entry = [
        'id'      => uniqid('t_', true),
        'project' => $a['project'] ?? '',
        'chat'    => $a['chat'] ?? '',
        'label'   => $a['label'] ?? '',
        'started' => (int)$a['started'],
        'ended'   => $now,
        'seconds' => max(0, $now - (int)$a['started']),
    ];
    $log['entries'][] = $entry;
    $log['active'] = null;
    tl_save_atomic($LOG_F, $log);
    echo json_encode(['ok'=>true, 'stopped'=>true, 'entry'=>$entry], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── add_manual ────────────────────────────────────────────────────────────────
if ($action === 'add_manual') {
    $seconds = max(0, (int)($in['seconds'] ?? 0));
    if ($seconds <= 0) { echo json_encode(['ok'=>false,'error'=>'seconds must be > 0'], JSON_UNESCAPED_UNICODE); exit; }
    $log = tl_load($LOG_F);
    $now = time();
    $log['entries'][] = [
        'id'      => uniqid('t_', true),
        'project' => trim((string)($in['project'] ?? '')),
        'chat'    => trim((string)($in['chat'] ?? '')),
        'label'   => trim((string)($in['label'] ?? '')),
        'started' => $now - $seconds,
        'ended'   => $now,
        'seconds' => $seconds,
        'manual'  => true,
    ];
    tl_save_atomic($LOG_F, $log);
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── delete ──────────────────────────────────────────────────────────────────
if ($action === 'delete') {
    $id = trim((string)($in['id'] ?? ''));
    if (!$id) { echo json_encode(['ok'=>false,'error'=>'Missing id'], JSON_UNESCAPED_UNICODE); exit; }
    $log = tl_load($LOG_F);
    $log['entries'] = array_values(array_filter($log['entries'], fn($e) => ($e['id'] ?? '') !== $id));
    tl_save_atomic($LOG_F, $log);
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── report ──────────────────────────────────────────────────────────────────
if ($action === 'report') {
    $range   = $_GET['range'] ?? 'all';
    $project = trim((string)($_GET['project'] ?? ''));
    $log = tl_load($LOG_F);
    $now = time();
    // Range cutoff (local midnight-ish using server time)
    $cutoff = 0;
    if ($range === 'today')      $cutoff = strtotime('today 00:00');
    else if ($range === 'week')  $cutoff = strtotime('-7 days');
    else if ($range === 'month') $cutoff = strtotime('-30 days');
    else $cutoff = 0;

    $entries = $log['entries'];
    $byProject = [];
    $total = 0;
    $list = [];
    foreach ($entries as $e) {
        if (($e['ended'] ?? 0) < $cutoff) continue;
        if ($project !== '' && ($e['project'] ?? '') !== $project) continue;
        $secs = (int)($e['seconds'] ?? 0);
        $total += $secs;
        $p = $e['project'] ?: '(none)';
        $byProject[$p] = ($byProject[$p] ?? 0) + $secs;
        $list[] = $e;
    }
    // Include the running timer's elapsed time in totals (not in entries list)
    if (!empty($log['active']) && !empty($log['active']['started'])) {
        $a = $log['active'];
        if (($project === '' || ($a['project'] ?? '') === $project)) {
            $secs = $now - (int)$a['started'];
            $total += $secs;
            $p = $a['project'] ?: '(none)';
            $byProject[$p] = ($byProject[$p] ?? 0) + $secs;
        }
    }
    arsort($byProject);
    // newest entries first
    usort($list, fn($a,$b) => ($b['ended'] ?? 0) - ($a['ended'] ?? 0));
    echo json_encode([
        'ok'=>true, 'range'=>$range, 'total_seconds'=>$total,
        'by_project'=>$byProject, 'entries'=>array_slice($list, 0, 200),
        'active'=>$log['active'],
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
