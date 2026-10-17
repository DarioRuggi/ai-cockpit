<?php
// =============================================================================
// session_backend.php — the one place that knows HOW the agent loops are hosted.
//
//   tmux        (default, how it has always been)  one tmux session per agent: cockpit_claude / cockpit_gemini / cockpit_ollama
//   supervisor  (opt-in)  the same loops as services of aicsupervisor, restarted if they die, stopped from the Stop button by a
//               signal to the running CLI only (not Ctrl-C into a pane). Switched on by a file called use_supervisor in the edition's
//               cockpit_data folder (or COCKPIT_SUPERVISOR=1), and only while the supervisor actually answers.
//
// Callers (status.php, bridge.php, launch_cli.php) ask THIS file: is the agent alive, interrupt it, where is its log. In supervisor mode
// each answer comes from the supervisor; whenever it does not answer (not running, no permission, switch off) the tmux answer is used,
// so a switch left on can never make an agent look dead that is alive in tmux, and the tmux path behaves exactly as before.
//
// The supervisor's state folder is <cockpit_data>/supervisor (socket sup.sock, file token). cockpit_start.sh creates it; the web server's
// account reaches it through the owner's group (socket 0660, token 0640), the same arrangement as the tmux socket.
// =============================================================================
if (defined('CK_SESSION_BACKEND')) return;
define('CK_SESSION_BACKEND', 1);

function ck_sup_data_root(): string {
    global $PATHS;
    return rtrim((string)($PATHS['cockpit_data_root'] ?? $PATHS['cockpit_data'] ?? ''), '/');
}
function ck_sup_dir(): string { return ck_sup_data_root() . '/supervisor'; }
function ck_sup_enabled(): bool {
    return getenv('COCKPIT_SUPERVISOR') === '1' || (ck_sup_data_root() !== '' && is_file(ck_sup_data_root() . '/use_supervisor'));
}

/** One control request. Returns the decoded reply, or null when nobody answered (not running, no permission, bad token, timeout). */
function ck_sup_call(array $req, float $timeout = 2.0): ?array {
    $dir = ck_sup_dir();
    $token = is_readable($dir . '/token') ? trim((string)@file_get_contents($dir . '/token')) : '';
    if ($token === '' || !file_exists($dir . '/sup.sock')) return null;
    $fp = @stream_socket_client('unix://' . $dir . '/sup.sock', $en, $es, $timeout);
    if (!$fp) return null;
    stream_set_timeout($fp, max(1, (int)ceil($timeout)));
    fwrite($fp, json_encode(['token' => $token] + $req) . "\n");
    $line = fgets($fp);
    fclose($fp);
    $j = json_decode((string)$line, true);
    return is_array($j) ? $j : null;
}

/** name => row (state, pid, restarts ...) of the supervised services; [] when the switch is off or the supervisor does not answer. */
function ck_sup_services(): array {
    static $cache = null;
    if ($cache !== null) return $cache;
    $cache = [];
    if (!ck_sup_enabled()) return $cache;
    $r = ck_sup_call(['op' => 'status']);
    foreach (($r['services'] ?? []) as $s) if (isset($s['name'])) $cache[$s['name']] = $s;
    return $cache;
}

/** tmux's answer, as status.php always gave it (tmux 3.3 prints "access not allowed" on stderr yet exits 0, so silence is part of "alive"). */
function ck_tmux_alive(string $session): array {
    global $PATHS;
    $sock = (string)($PATHS['tmux_socket'] ?? '');
    $out = []; $ret = null;
    exec('tmux -S ' . $sock . ' has-session -t ' . escapeshellarg($session) . ' 2>&1', $out, $ret);
    $noise = trim(implode('', $out));
    return ['ok' => ($ret === 0 && $noise === ''), 'noise' => $noise, 'denied' => stripos($noise, 'access not allowed') !== false];
}

/**
 * Is the agent's loop alive?  ['ok' => bool, 'via' => 'supervisor'|'tmux', 'state' => supervisor state or '', 'noise' => tmux noise, 'denied' => bool]
 * Supervisor first (when it is switched on and answers); otherwise tmux.
 */
function ck_agent_alive(string $agent): array {
    $svc = ck_sup_services()['cockpit_' . $agent] ?? null;
    if ($svc !== null && in_array($svc['state'] ?? '', ['running', 'starting'], true) && (int)($svc['pid'] ?? 0) > 1)
        return ['ok' => true, 'via' => 'supervisor', 'state' => (string)$svc['state'], 'noise' => '', 'denied' => false];
    $t = ck_tmux_alive('cockpit_' . $agent);
    return ['ok' => $t['ok'], 'via' => 'tmux', 'state' => (string)($svc['state'] ?? ''), 'noise' => $t['noise'], 'denied' => $t['denied']];
}

/**
 * The Stop button: end what the agent is doing right now, keep the agent.
 *   supervisor: SIGINT to the loop's whole process group, which is exactly what Ctrl-C in a terminal does (the running CLI, its helpers
 *               AND the loop, whose INT handler keeps it alive). Signalling only the CLI was tried and is worse: the loop never learns it
 *               was interrupted and starts the same request again. An older loop without the handler dies from it and the supervisor
 *               restarts it, so Stop can no longer leave an agent dead;
 *   tmux:       Ctrl-C into the pane (as before; agent_loop.sh's INT handler keeps the loop alive).
 * Returns 'supervisor', 'tmux' or 'none'.
 */
function ck_agent_interrupt(string $agent): string {
    $svc = ck_sup_services()['cockpit_' . $agent] ?? null;
    if ($svc !== null && ($svc['state'] ?? '') === 'running') {
        $r = ck_sup_call(['op' => 'signal', 'name' => 'cockpit_' . $agent, 'sig' => 'INT', 'scope' => 'group']);
        if (($r['ok'] ?? false) === true) return 'supervisor';
    }
    global $PATHS;
    $sock = (string)($PATHS['tmux_socket'] ?? '');
    if ($sock === '') return 'none';
    @exec('tmux -S ' . $sock . ' send-keys -t ' . escapeshellarg('cockpit_' . $agent) . ' C-c 2>/dev/null', $o, $rc);
    return $rc === 0 ? 'tmux' : 'none';
}

/** The log of a supervised agent (what a tmux pane would show), or null when that agent is not supervised. */
function ck_agent_logfile(string $agent): ?string {
    if (ck_sup_services()['cockpit_' . $agent] ?? null) {
        $f = ck_sup_dir() . '/logs/cockpit_' . $agent . '.log';
        return is_file($f) ? $f : null;
    }
    return null;
}

/**
 * What is ACTUALLY running behind the agents, for the status bar's runtime indicator. Read from the processes themselves, not from the switch
 * files: a switch can be on while the loop that is running still started before it was turned on.
 *   host     'supervisor' | 'tmux' | 'none'   (who keeps the agent loops alive)
 *   agents   claude|gemini|ollama => ['host'=>..., 'loop'=>'native'|'shell'|'none', 'pid'=>int]
 *   engine   the engine's switch (use_engine) and whether the program is installed
 *   switches the files that ask for the native loop (all agents, or one)
 *   scheduler  'supervisor' (a supervised job) | 'cron/other'
 * Cheap enough for the 4-second status poll: one control-socket call and three /proc reads.
 */
function ck_runtime_info(): array {
    global $PATHS;
    $root = ck_sup_data_root();
    $user = rtrim((string)($PATHS['cockpit_data'] ?? ''), '/');
    $svcs = ck_sup_services();
    $info = ['host' => 'none', 'agents' => [], 'engine' => [], 'switches' => [], 'scheduler' => 'cron/other'];
    $cmdline = function (int $pid): string {
        $c = $pid > 1 ? @file_get_contents('/proc/' . $pid . '/cmdline') : false;
        return $c === false ? '' : str_replace("\0", ' ', $c);
    };
    $anySup = false; $anyTmux = false;
    foreach (['claude', 'gemini', 'ollama'] as $a) {
        $row = ['host' => 'none', 'loop' => 'none', 'pid' => 0];
        $svc = $svcs['cockpit_' . $a] ?? null;
        if ($svc !== null && in_array($svc['state'] ?? '', ['running', 'starting'], true) && (int)($svc['pid'] ?? 0) > 1) {
            $row['host'] = 'supervisor'; $row['pid'] = (int)$svc['pid']; $anySup = true;
            $cl = $cmdline($row['pid']);
            $row['loop'] = strpos($cl, 'aicengine') !== false ? 'native' : (strpos($cl, 'agent_loop.sh') !== false ? 'shell' : 'none');
        } else {
            $out = []; exec('pgrep -f ' . escapeshellarg('(agent_loop.sh|aicengine loop) ' . $a . '$') . ' 2>/dev/null', $out);
            $pid = (int)($out[0] ?? 0);
            if ($pid > 1) {
                $cl = $cmdline($pid);
                $row['pid'] = $pid; $row['loop'] = strpos($cl, 'aicengine') !== false ? 'native' : 'shell';
                $t = ck_tmux_alive('cockpit_' . $a);
                $row['host'] = $t['ok'] ? 'tmux' : 'other'; if ($t['ok']) $anyTmux = true;
            }
        }
        $info['agents'][$a] = $row;
    }
    $info['host'] = $anySup && $anyTmux ? 'mixed' : ($anySup ? 'supervisor' : ($anyTmux ? 'tmux' : 'none'));
    $info['supervisor_switch'] = ck_sup_enabled();
    // the web server that answered THIS request (Apache by default; the optional aicserver front; PHP's own server in a test)
    $ss = (string)($_SERVER['SERVER_SOFTWARE'] ?? '');
    $info['web'] = stripos($ss, 'aicserver') === 0 ? 'aicserver' : (stripos($ss, 'apache') !== false ? 'apache' : (stripos($ss, 'php') !== false ? 'php' : ($ss === '' ? 'none' : 'other')));
    // the engine's own service (the file window and the command window)
    $es = $svcs['cockpit_engine'] ?? null;
    $info['files_service'] = ($es !== null && in_array($es['state'] ?? '', ['running', 'starting'], true)) ? 'supervisor' : (file_exists(ck_sup_dir() . '/engine.sock') ? 'other' : 'none');
    foreach (['use_engine' => 'engine'] as $f => $k) {
        $info['engine']['on'] = (is_file($root . '/' . $f) || ($user !== '' && is_file($user . '/' . $f)));
    }
    $home = rtrim((string)($PATHS['home'] ?? ''), '/');
    $info['engine']['installed'] = $home !== '' && is_file($home . '/scripts/aicengine');
    foreach (['use_native_loop', 'use_native_loop_claude', 'use_native_loop_gemini', 'use_native_loop_ollama'] as $f)
        if (is_file($root . '/' . $f)) $info['switches'][] = $f;
    $r = $svcs ? ck_sup_call(['op' => 'status']) : null;
    foreach (($r['jobs'] ?? []) as $j) if (($j['name'] ?? '') === 'scheduler') $info['scheduler'] = 'supervisor';
    return $info;
}
