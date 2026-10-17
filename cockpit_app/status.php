<?php
// =============================================================================
// status.php - Live System Status (tmux-based, v3)
// Dario Ruggi / Cockpit
//
// Checks whether each agent's tmux session is alive.
// Much simpler than v2 — no need to run CLIs as www-data.
// Also reads project_state.json for the blackboard state.
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/session_backend.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
// [edition] demo: report all agents "up" with a stable shape so the status dots
// stay green and the statusbar doesn't amber-pulse/flash on every 4s poll. (The
// demo can't actually run them — the DEMO badge + per-feature chat notes cover
// that; here we just keep the bar calm instead of a flashing "not running".)
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    echo json_encode([
        'ok'     => true,
        'claude' => ['ok'=>true, 'version'=>'Claude Code'],
        'gemini' => ['ok'=>true, 'version'=>'Gemini CLI'],
        'ollama' => ['ok'=>true, 'version'=>'Ollama'],
        'project'=> ['project_name'=>'default', 'chat_name'=>'default'],
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// tmux socket — fixed path inside the cockpit web root.
// Apache can always read this path (not subject to PrivateTmp isolation).
define('TMUX_SOCKET', $PATHS['tmux_socket']);
define('TMUX_CMD', 'tmux -S ' . TMUX_SOCKET . ' ');


$status = [];

// Helper: check if a tmux session is running
// Returns ['ok'=>bool, 'version'=>string]
function checkSession(string $sessionName, string $label): array {
    // Who hosts the loop (session_backend.php): the supervisor when it is switched on and answers, tmux otherwise. $sessionName is
    // "cockpit_<agent>". tmux's answer is unchanged, text and all.
    if (function_exists('ck_agent_alive')) {
        $a = ck_agent_alive(preg_replace('/^cockpit_/', '', $sessionName));
        if ($a['via'] === 'supervisor') return ['ok' => true, 'version' => $label . ': session running'];
        if ($a['ok']) return ['ok' => true, 'version' => $label . ': session running'];
        if ($a['denied']) return ['ok' => false, 'version' => 'tmux access denied (run cockpit_start to grant www-data access)'];
        if (in_array($a['state'], ['failed', 'backoff', 'stopped'], true))
            return ['ok' => false, 'version' => 'Session not running (supervisor: ' . $a['state'] . '). Start with: ~/scripts/cockpit_start.sh'];
        return ['ok' => false, 'version' => 'Session not running. Start with: ~/scripts/cockpit_start.sh'];
    }
    // NOTE: capture stderr too (2>&1). tmux 3.3+ has a server-level access
    // control: if www-data hasn't been granted access via `server-access`,
    // tmux prints "access not allowed" to stderr BUT STILL EXITS 0. Checking
    // only the exit code therefore reported every agent as "running" forever.
    // cockpit_start.sh now grants www-data access on each start, but we also
    // guard here: a session is "running" only if the exit code is 0 AND the
    // command produced no error/diagnostic output (has-session is silent on
    // success).
    $out = [];
    $ret = null;
    exec(TMUX_CMD . 'has-session -t ' . escapeshellarg($sessionName) . ' 2>&1',
         $out, $ret);
    $noise = trim(implode('', $out));
    if ($ret === 0 && $noise === '') {
        return ['ok' => true,  'version' => $label . ': session running'];
    }
    if (stripos($noise, 'access not allowed') !== false) {
        return ['ok' => false, 'version' => 'tmux access denied (run cockpit_start to grant www-data access)'];
    }
    return ['ok' => false, 'version' => 'Session not running. Start with: ~/scripts/cockpit_start.sh'];
}

// --- 1. Check each agent tmux session ---
$status['claude'] = checkSession('cockpit_claude', 'Claude Code');
$status['gemini'] = checkSession('cockpit_gemini', 'Gemini CLI');
$status['ollama'] = checkSession('cockpit_ollama', 'Ollama');

// --- 2. Read project_state.json ---
$stateFile = __DIR__ . '/project_state.json';
if (file_exists($stateFile)) {
    $state = json_decode(file_get_contents($stateFile), true);
    $status['project'] = is_array($state) ? $state : null;
} else {
    $status['project'] = null;
}

// --- 3. Exchange count for the current chat — lets pollers (local UI,
// Everywhere relay) detect "new messages landed" without re-reading the
// whole chat file just to compare, and without a full switchToChat reload
// clobbering scroll position on every poll tick.
if (is_array($status['project'] ?? null)) {
    $proj = (string)($status['project']['project_name'] ?? 'default');
    $chat = (string)($status['project']['chat_name']    ?? 'default');
    $chatFile = $PATHS['projects_root'] . '/' . $proj . '/chat_' . $chat . '.json';
    if (is_file($chatFile)) {
        $chatData = json_decode((string)@file_get_contents($chatFile), true);
        $status['exchange_count'] = is_array($chatData['exchanges'] ?? null) ? count($chatData['exchanges']) : 0;
    } else {
        $status['exchange_count'] = 0;
    }
}

// The topbar clock's server row (2026-09-13). PHP's default zone is UTC when
// php.ini leaves date.timezone empty; the machine's own zone is what a user
// expects to see, so resolve it from the OS when PHP has none.
if (!ini_get("date.timezone") || strtoupper((string)ini_get("date.timezone")) === "UTC") {
    $tz = trim((string)@file_get_contents("/etc/timezone"));
    if ($tz === "" && ($lt = @readlink("/etc/localtime")) && preg_match("~zoneinfo/(.+)$~", $lt, $m)) $tz = $m[1];
    if ($tz !== "" && in_array($tz, timezone_identifiers_list(), true)) date_default_timezone_set($tz);
}
// What is actually running behind the agents (supervisor / tmux, shell / native loop, engine): the status bar shows it
$status["runtime"] = function_exists("ck_runtime_info") ? ck_runtime_info() : null;
$status["server_now"] = date("c");
$status["server_tz"]  = date_default_timezone_get();
// cockpit-guard's flag (a shipped file changed since the last check) — the
// client raises the Integrity modal on the next poll, no waiting for a check.
$_flag = rtrim((string)($PATHS["cockpit_data_root"] ?? $PATHS["cockpit_data"] ?? ""), "/") . "/integrity_flag.json";
if (is_file($_flag)) { $_fj = json_decode((string)@file_get_contents($_flag), true); if (is_array($_fj)) $status["integrity_flag"] = $_fj; }
echo json_encode($status, JSON_UNESCAPED_UNICODE);
?>
