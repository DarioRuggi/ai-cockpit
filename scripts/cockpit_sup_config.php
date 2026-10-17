<?php
// =============================================================================
// cockpit_sup_config.php — writes the aicsupervisor configuration for one Cockpit edition: the three agent loops
// (cockpit_claude, cockpit_gemini, cockpit_ollama) as supervised services, exactly what cockpit_start.sh types into tmux panes today
// (agent_loop.sh <agent> with the edition's queue / response / data directories), but restarted if it ever dies.
//
//   php cockpit_sup_config.php --edition v2|v1 --web-root DIR --data-dir DIR --projects-root DIR [--loop FILE]
//                              [--group NAME] [--agents claude,gemini,ollama] [--engine-bin FILE] [--out FILE]
//   php cockpit_sup_config.php --auto --edition v2|v1 [--out FILE]
//        --auto works the directories out itself, the way cockpit_start.sh does (document root probe, ~/scripts/cockpit_data[_v1],
//        projects_root from the edition's paths.json, the owner's group when a web-server account exists): for a systemd unit that
//        has to regenerate the file before every start.
//
// The engine's service (cockpit_engine: the file window and the command window) is added when the engine program exists (~/scripts/aicengine, or --engine-bin).
//
// The web root's scheduler.php, when it exists, becomes the job "scheduler" (every 60 s, run at start, never two at once): the same tick the
// crontab line gives today. scheduler.php takes a non-blocking lock, so a crontab line ticking as well is harmless.
//
// Without --out the JSON goes to standard output. With --out it is written atomically (temp file + rename), and only when it changed,
// so a running supervisor that gets SIGHUP re-reads an identical file and restarts nothing.
//
// The state directory (control socket, token, pid files, logs) is <data-dir>/supervisor. With --group (the group the web server's
// account shares with the owner, the same arrangement as the tmux socket today) the socket is 0660 and the token 0640, so the web
// pages can ask for status and send the Stop signal; without it everything stays private to the owner.
// =============================================================================

function opt(array $argv, string $name, string $default = ''): string {
    foreach ($argv as $i => $a) {
        if ($a === $name && isset($argv[$i + 1])) return $argv[$i + 1];
        if (strpos($a, $name . '=') === 0) return substr($a, strlen($name) + 1);
    }
    return $default;
}

function sup_config(array $o): array {
    $agents = $o['agents'];
    $services = [];
    foreach ($agents as $agent) {
        $services[] = [
            'name'    => 'cockpit_' . $agent,                 // the same names as the tmux sessions: callers map 1:1
            'command' => '/bin/bash',
            'args'    => [$o['loop'], $agent],
            'cwd'     => $o['projects_root'],                 // cockpit_start.sh does: cd "$COCKPIT_ROOT"
            'env'     => [
                'COCKPIT_QUEUE_DIR'    => $o['web_root'] . '/queue',
                'COCKPIT_RESPONSE_DIR' => $o['web_root'] . '/responses',
                'COCKPIT_DATA_DIR'     => $o['data_dir'],
            ],
            // A loop that exits is a loop that stopped answering: always bring it back (with a growing pause), and give up
            // only if it dies more than 10 times in two minutes (then it shows as "failed" instead of spinning).
            'restart'        => 'always',
            'backoff_min_s'  => 1,
            'backoff_max_s'  => 30,
            'stable_after_s' => 20,
            'max_restarts'   => 10,
            'restart_window_s' => 120,
            'stop_timeout_s' => 8,
            'log_max_kb'     => 4096,
        ];
    }
    // The engine's own service for the file window and the command window (fm.php, cmd.php): it runs as the owner, does the file actions with
    // confinement and the commands under the kernel sandbox. Socket 0660 / token 0640 in the owner's group, like the supervisor's own.
    if (!empty($o['engine_bin'])) {
        $st = $o['data_dir'] . '/supervisor';
        $args = ['serve', '--socket', $st . '/engine.sock', '--state', $st . '/engine_state', '--token-file', $st . '/engine_token',
                 '--socket-mode', $o['group'] !== '' ? '660' : '600', '--allowed-roots', $o['projects_root'], '--max-runs', '8'];
        if ($o['group'] !== '') { $args[] = '--socket-group'; $args[] = $o['group']; }
        $services[] = ['name' => 'cockpit_engine', 'command' => $o['engine_bin'], 'args' => $args, 'cwd' => $o['projects_root'],
                       'env' => [], 'restart' => 'always', 'backoff_min_s' => 1, 'backoff_max_s' => 30, 'stable_after_s' => 20,
                       'max_restarts' => 10, 'restart_window_s' => 120, 'stop_timeout_s' => 8, 'log_max_kb' => 2048];
    }
    // The web front (opt-in: a file called use_aicserver in the data folder): php-cgi as a FastCGI pool on a private socket, and aicserver in front of it
    // on a side port next to Apache (8081 for V2, 8082 for V1, or the number written in the file). Both run as the owner. Apache is not touched.
    if (!empty($o['web'])) {
        $w = $o['web']; $st = $o['data_dir'] . '/supervisor';
        $common = ['restart' => 'always', 'backoff_min_s' => 1, 'backoff_max_s' => 30, 'stable_after_s' => 20, 'max_restarts' => 10, 'restart_window_s' => 120, 'stop_timeout_s' => 8, 'log_max_kb' => 2048];
        $services[] = ['name' => 'cockpit_phpcgi', 'command' => $w['php_cgi'], 'args' => ['-b', $st . '/php.sock', '-d', 'session.save_path=' . $st . '/sessions'], 'cwd' => $o['web_root'],
                       'env' => ['PHP_FCGI_CHILDREN' => '6', 'PHP_FCGI_MAX_REQUESTS' => '0']] + $common;
        $services[] = ['name' => 'cockpit_web', 'command' => $w['aicserver'], 'args' => ['run', '--config', $st . '/web.json'], 'cwd' => $o['web_root'], 'env' => []] + $common;
    }
    $control = ['socket' => '${STATE}/sup.sock', 'mode' => $o['group'] !== '' ? '660' : '600'];
    if ($o['group'] !== '') $control['group'] = $o['group'];
    $jobs = [];
    if (!empty($o['scheduler'])) {
        $jobs[] = ['name' => 'scheduler', 'schedule' => 'every 60s', 'command' => 'php', 'args' => [$o['scheduler']],
                   'timeout_s' => 55, 'overlap' => 'skip', 'run_at_start' => true, 'log_max_kb' => 512];
    }
    $cfg = [
        '_comment'  => 'Written by cockpit_sup_config.php for Cockpit ' . strtoupper($o['edition']) . '. Do not edit: it is regenerated on every start.',
        'state_dir' => $o['data_dir'] . '/supervisor',
        'control'   => $control,
        'services'  => $services,
    ];
    if ($jobs) $cfg['jobs'] = $jobs;
    return $cfg;
}

/** The aicserver configuration for one edition: its mount, the private FastCGI socket, the rules Apache enforces today (cockpit-security.conf). */
function web_config(array $o): array {
    $mount = $o['edition'] === 'v1' ? '/cockpit-v1' : '/cockpit';
    $home = rtrim((string)getenv('HOME'), '/');
    return [
        '_comment' => 'Written by cockpit_sup_config.php (use_aicserver). Do not edit: it is regenerated on every start.',
        'listen' => ['host' => '127.0.0.1', 'port' => $o['web']['port']],
        'server_name' => '',
        'allowed_hosts' => ['localhost', '127.0.0.1', '[::1]'],
        'mounts' => [['prefix' => $mount, 'root' => $o['web_root'], 'index' => ['index.php', 'index.html'],
                        'static_only_dirs' => ['attachments', 'uploads', 'generated', 'queue', 'responses'],
                        // what Apache refuses today (Installs/apache/cockpit-security.conf): state files, logs, locks, and the queue and response folders
                        'deny' => ['paths.json', 'project_state.json', 'workers_quotas.json', '*.jsonl', '*.lock', '*.sock', 'queue', 'queue/*', 'responses', 'responses/*']]],
        'root_redirect' => $mount . '/',
        'php' => ['extensions' => ['.php'], 'fastcgi' => 'unix:' . $o['data_dir'] . '/supervisor/php.sock', 'connect_timeout_s' => 3, 'idle_timeout_s' => 600],
        'deny' => ['.*', '*~', '*.bak', '*.orig', '*.swp', '*.pas', '*.lpr', '*.sh'],
        'allow' => ['.well-known'],
        'cache_rules' => [['match' => '*.html', 'value' => 'no-cache, must-revalidate'], ['match' => '*.js', 'value' => 'no-cache, must-revalidate'],
                          ['match' => '*.css', 'value' => 'no-cache, must-revalidate'], ['match' => '*.json', 'value' => 'no-cache, must-revalidate']],
        'headers' => ['X-Content-Type-Options' => 'nosniff', 'X-Frame-Options' => 'SAMEORIGIN', 'Referrer-Policy' => 'same-origin'],
        'limits' => ['max_body_mb' => 1024, 'header_timeout_s' => 10, 'body_idle_s' => 30, 'keepalive_s' => 5, 'write_timeout_s' => 30, 'max_connections' => 64, 'max_requests_per_connection' => 1000],
        'access_log' => $o['data_dir'] . '/supervisor/web_access.log',
        // answered by the server itself when it can prove what PHP would answer (srv_native); the sessions are the ones php-cgi writes
        'native' => ['bridge_poll' => true, 'session_dir' => $o['data_dir'] . '/supervisor/sessions', 'supervisor_dir' => $o['data_dir'] . '/supervisor', 'session_days' => 90],
    ];
}

/** The directories cockpit_start.sh would use for this edition. */
function auto_dirs(string $edition): array {
    $home = rtrim((string)getenv('HOME'), '/');
    $doc = (string)getenv('COCKPIT_DOCROOT');
    if ($doc === '') {
        foreach ([$home . '/.local/share/cockpit-web', '/var/www/html', '/srv/http', '/srv/www/htdocs', '/var/www/localhost/htdocs'] as $d)
            if (is_file($d . '/cockpit/index.html') || is_file($d . '/cockpit-v1/index.html')) { $doc = $d; break; }
        if ($doc === '') $doc = '/var/www/html';
    }
    $web = $doc . ($edition === 'v1' ? '/cockpit-v1' : '/cockpit');
    $projects = '';
    $pj = @json_decode((string)@file_get_contents($web . '/paths.json'), true);
    if (is_array($pj) && !empty($pj['projects_root'])) $projects = (string)$pj['projects_root'];
    if ($projects === '') $projects = $home . '/Software/Programing/LocalAIProjs';
    $group = '';
    foreach (['www-data', 'apache', 'http', 'wwwrun'] as $u) { exec('id -u ' . escapeshellarg($u) . ' 2>/dev/null', $o, $rc); if ($rc === 0) { $group = trim((string)shell_exec('id -gn')); break; } }
    return ['web_root' => $web, 'data_dir' => $home . '/scripts/' . ($edition === 'v1' ? 'cockpit_data_v1' : 'cockpit_data'), 'projects_root' => $projects, 'group' => $group];
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === realpath(__FILE__)) {
    $edition = opt($argv, '--edition', 'v2');
    if (!in_array($edition, ['v1', 'v2'], true)) { fwrite(STDERR, "cockpit_sup_config: --edition must be v1 or v2\n"); exit(2); }
    $auto = in_array('--auto', $argv, true) ? auto_dirs($edition) : null;
    $webRoot = rtrim(opt($argv, '--web-root', $auto['web_root'] ?? ''), '/');
    $dataDir = rtrim(opt($argv, '--data-dir', $auto['data_dir'] ?? ''), '/');
    $projects = rtrim(opt($argv, '--projects-root', $auto['projects_root'] ?? ''), '/');
    if ($webRoot === '' || $dataDir === '' || $projects === '') { fwrite(STDERR, "cockpit_sup_config: --web-root, --data-dir and --projects-root are required\n"); exit(2); }
    $home = getenv('HOME') ?: '';
    $loop = opt($argv, '--loop', $home . '/scripts/agent_loop.sh');
    $agents = array_values(array_filter(array_map('trim', explode(',', opt($argv, '--agents', 'claude,gemini,ollama')))));
    foreach ($agents as $a) if (!in_array($a, ['claude', 'gemini', 'ollama'], true)) { fwrite(STDERR, "cockpit_sup_config: unknown agent '$a'\n"); exit(2); }
    $engineBin = opt($argv, '--engine-bin', is_file($home . '/scripts/aicengine') ? $home . '/scripts/aicengine' : '');
    if ($engineBin !== '' && !is_file($engineBin)) $engineBin = '';
    $group = opt($argv, '--group', $auto['group'] ?? '');
    if ($group !== '' && !preg_match('/^[A-Za-z0-9_.-]{1,64}$/', $group)) { fwrite(STDERR, "cockpit_sup_config: bad group name\n"); exit(2); }
    foreach (['web_root' => $webRoot, 'data_dir' => $dataDir, 'projects_root' => $projects, 'loop' => $loop] as $k => $v)
        if (!preg_match('/^[\x20-\x7E\x{80}-\x{10FFFF}]+$/u', $v) || strpos($v, '${') !== false) { fwrite(STDERR, "cockpit_sup_config: unsafe value for $k\n"); exit(2); }
    // the web front: opt-in by a file called use_aicserver in the data folder (its content, when it is a port number, is the port)
    $web = null;
    $swf = $dataDir . '/use_aicserver';
    $aicsrv = opt($argv, '--aicserver-bin', is_file($home . '/scripts/aicserver') ? $home . '/scripts/aicserver' : '');
    $phpcgi = opt($argv, '--php-cgi', trim((string)shell_exec('command -v php-cgi 2>/dev/null')));
    if (is_file($swf) && $aicsrv !== '' && is_file($aicsrv) && $phpcgi !== '' && is_file($phpcgi)) {
        $pn = (int)trim((string)@file_get_contents($swf));
        $web = ['aicserver' => $aicsrv, 'php_cgi' => $phpcgi, 'port' => ($pn >= 1024 && $pn <= 65535) ? $pn : ($edition === 'v1' ? 8082 : 8081)];
    }
    $json = json_encode(sup_config(['edition' => $edition, 'web_root' => $webRoot, 'data_dir' => $dataDir, 'projects_root' => $projects,
        'loop' => $loop, 'agents' => $agents, 'group' => $group, 'engine_bin' => $engineBin, 'web' => $web,
        'scheduler' => is_file($webRoot . '/scheduler.php') ? $webRoot . '/scheduler.php' : '']), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) . "\n";
    if ($web) { @mkdir($dataDir . '/supervisor/sessions', 0700, true); }
    $webJson = $web ? json_encode(web_config(['edition' => $edition, 'web_root' => $webRoot, 'data_dir' => $dataDir, 'web' => $web]), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) . "\n" : '';
    $out = opt($argv, '--out');
    if ($webJson !== '' && $out !== '') {
        @mkdir(dirname($out), 0755, true);
        $wf = dirname($out) . '/web.json';
        if (!is_file($wf) || (string)@file_get_contents($wf) !== $webJson) {
            $tmpw = $wf . '.tmp' . getmypid();
            if (file_put_contents($tmpw, $webJson) === false || !@rename($tmpw, $wf)) { @unlink($tmpw); fwrite(STDERR, "cockpit_sup_config: cannot write $wf\n"); exit(1); }
        }
    }
    if ($out === '') { echo $json; exit(0); }
    if (is_file($out) && (string)@file_get_contents($out) === $json) exit(0);              // unchanged: leave the file (and its mtime) alone
    @mkdir(dirname($out), 0755, true);
    $tmp = $out . '.tmp' . getmypid();
    if (file_put_contents($tmp, $json) === false || !@rename($tmp, $out)) { @unlink($tmp); fwrite(STDERR, "cockpit_sup_config: cannot write $out\n"); exit(1); }
    @chmod($out, 0644);
    exit(0);
}
