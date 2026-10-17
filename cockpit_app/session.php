<?php
// =============================================================================
// session.php - Cockpit session control (start/stop tmux agent sessions)
// Called by the frontend Stop and Restart buttons.
// Runs the cockpit scripts as dario via sudo.
//
// 2026-05-09 fix #1: starts now run with COCKPIT_INVOKED_FROM_WEB=1 in the
// environment so cockpit_start.sh can skip its brave-browser launch step.
// Without this, calling brave-browser via sudo (with no DISPLAY/XAUTHORITY)
// can affect existing Brave windows, including closing the one that just
// clicked the START/RESTART button.
//
// 2026-05-09 fix #2: after a successful start, www-data fixes the tmux
// socket permissions itself (chown dario:www-data, chmod 660) using
// www-data's own sudoers entries for /bin/chown and /bin/chmod. The
// cockpit_start.sh script tries to do this internally, but its inner
// `sudo chown` / `sudo chmod` calls fail silently when the script is
// invoked via web (no TTY, dario has no passwordless sudo for those
// commands). Without this, status.php (running as www-data) cannot read
// the tmux socket and reports all sessions as "not running" forever —
// even though the sessions ARE running, just inaccessible to Apache.
//
// Sudoers note: this requires an additional NOPASSWD entry for the env-form
// of the start command. See /etc/sudoers.d/cockpit-session-env for the entry,
// or add to /etc/sudoers via visudo:
//
//   www-data ALL=(dario) NOPASSWD: /usr/bin/env COCKPIT_INVOKED_FROM_WEB=1 \
//                                  <home>/scripts/cockpit_start.sh
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();

header('Content-Type: application/json');

$action = $_POST['action'] ?? $_GET['action'] ?? '';

// Optional per-supplier target. Whitelist-validated; anything else (or empty)
// falls back to 'all', preserving the original whole-cockpit behavior.
// The per-agent forms require matching NOPASSWD sudoers entries — see
// /etc/sudoers.d/cockpit-session-env.
$target = $_POST['target'] ?? $_GET['target'] ?? 'all';
if (!in_array($target, ['claude', 'gemini', 'ollama', 'all'], true)) {
    $target = 'all';
}

$scripts = [
    'stop'    => $PATHS['home'] . '/scripts/cockpit_stop.sh',
    'start'   => $PATHS['home'] . '/scripts/cockpit_start.sh',
];

$tmuxSock = $PATHS['tmux_socket'];

// For 'all' we keep the original argument-less invocation (matches the
// existing sudoers entries). For a specific agent we append the validated
// target as a single literal argument.
$argSuffix = ($target === 'all') ? '' : (' ' . $target);

// Which edition is asking. `sudo -u <owner>` strips the environment, so
// COCKPIT_EDITION never reached the scripts and both of them fell back to their
// v2 default: every Start and Stop issued from the V1 app acted on V2. Found
// 2026-09-26 — "Terminate and leave" in V1 reported success while all four V1
// sessions kept running, and the next V2 launch then correctly said V1 was busy.
// Passed as an argument because sudoers already allows `cockpit_*.sh *`; an env
// var would have needed a sudoers change, i.e. a reinstall for existing users.
$_ed = (defined('COCKPIT_EDITION') && COCKPIT_EDITION === 'v1') ? 'v1' : 'v2';
$edArg = ' --edition ' . $_ed;

// Build the start invocation: prefix with `env COCKPIT_INVOKED_FROM_WEB=1`
// so the script knows it's being called from the web UI and should skip
// the brave-browser launch step. Stop doesn't launch a browser, so it
// doesn't need the env var.
$_owner = cockpit_owner_user();
$_selfEnv = (strpos((string)($_SERVER['SERVER_SOFTWARE'] ?? ''), 'aicserver') === 0) ? ' COCKPIT_SELF=1' : '';   // served by the self-contained front: the launcher must not go looking for Apache
$startCmd = cockpit_as_owner() . '/usr/bin/env COCKPIT_INVOKED_FROM_WEB=1' . $_selfEnv . ' ' . $scripts['start'] . $edArg . $argSuffix;
// Served by the self-contained front (aicserver, run by the supervisor): Stop and Restart must stop the AGENTS only, or the page dies with them.
// Only "Terminate and leave" (leave=1) shuts everything down.
$_keepWeb = (strpos((string)($_SERVER['SERVER_SOFTWARE'] ?? ''), 'aicserver') === 0) && cockpit_runs_as_owner() && empty($_POST['leave']) && empty($_GET['leave']);
$stopCmd  = cockpit_as_owner() . ($_keepWeb ? '/usr/bin/env COCKPIT_KEEP_WEB=1 ' : '') . $scripts['stop'] . $edArg . $argSuffix;

// Helper: fix the tmux socket permissions so Apache (www-data) can talk
// to it. Called after every successful start (covers both 'start' and the
// start half of 'restart'). Uses www-data's own NOPASSWD entries for
// /bin/chown and /bin/chmod — no additional sudoers config needed.
// Failures are swallowed: if the socket isn't there yet or the perms
// can't be set for any reason, it's not fatal at this layer; the next
// status poll will surface the real problem to the user.
function fix_tmux_socket_perms($tmuxSock) {
    if (!file_exists($tmuxSock)) return;
    if (cockpit_runs_as_owner()) return;     // PHP is the owner: the socket is already ours and no web account needs to reach it
    // the web user's name differs per distro (apache on Fedora) — a hard-coded
    // www-data left the socket fedora:fedora and status.php locked out
    @exec('sudo /bin/chown ' . escapeshellarg(cockpit_owner_user()) . ':' . escapeshellarg(cockpit_web_group()) . ' ' . escapeshellarg($tmuxSock) . ' 2>&1', $o1, $r1);
    @exec('sudo /bin/chmod 660 ' . escapeshellarg($tmuxSock) . ' 2>&1', $o2, $r2);
}

switch ($action) {
    case 'stop':
        exec($stopCmd . ' 2>&1', $out, $ret);
        echo json_encode(['ok' => $ret === 0, 'output' => implode("\n", $out)], JSON_UNESCAPED_UNICODE);
        break;

    case 'start':
        exec($startCmd . ' 2>&1', $out, $ret);
        if ($ret === 0) fix_tmux_socket_perms($tmuxSock);
        echo json_encode(['ok' => $ret === 0, 'output' => implode("\n", $out)], JSON_UNESCAPED_UNICODE);
        break;

    case 'restart':
        // Stop first
        exec($stopCmd . ' 2>&1', $out1, $ret1);
        sleep(4);
        // Then start (with env var so browser launch is skipped)
        exec($startCmd . ' 2>&1', $out2, $ret2);
        if ($ret2 === 0) fix_tmux_socket_perms($tmuxSock);
        echo json_encode([
            'ok'     => $ret2 === 0,
            'output' => implode("\n", array_merge($out1, ['---'], $out2))
        ], JSON_UNESCAPED_UNICODE);
        break;

    default:
        echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
}
?>
