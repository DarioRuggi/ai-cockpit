<?php
// =============================================================================
// launch_cli.php — spawn graphical apps as the dario user from Apache/PHP
//
// MODES:
//   cli      — independent CLI (claude, gemini, ollama run <model>)
//   attach   — attach to existing cockpit tmux session
//   terminal — open gnome-terminal in a specific directory
//   files    — open Nemo file browser in a specific directory
//   browser  — open Brave browser
//
// Requires sudoers /etc/sudoers.d/cockpit-launch-cli:
//   www-data ALL=(dario) NOPASSWD: /usr/bin/gnome-terminal
//   www-data ALL=(dario) NOPASSWD: /usr/bin/nemo
//   www-data ALL=(dario) NOPASSWD: /usr/bin/brave-browser
//   Defaults!/usr/bin/gnome-terminal env_keep += "DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS"
//   Defaults!/usr/bin/nemo           env_keep += "DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS"
//   Defaults!/usr/bin/brave-browser  env_keep += "DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS"
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
$agent  = trim((string)($in['agent']   ?? ''));
$model  = trim((string)($in['model']   ?? 'qwen2.5-coder:1.5b'));
$mode   = trim((string)($in['mode']    ?? 'cli'));
$session= trim((string)($in['session'] ?? ''));
$socket = trim((string)($in['socket']  ?? ''));
$dir    = trim((string)($in['dir']     ?? ''));
$url    = trim((string)($in['url']     ?? ''));

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();
$home    = $PATHS['home'];
$npm_bin = $home . '/.npm-global/bin';

// Sanitize directory path — allow base dirs from paths.json projects_root too,
// plus all cockpit-managed locations (web_root, cockpit_data + subdirs, runtime
// dirs) so the "open in file manager" buttons can reach configured sections.
$allowed_bases = [$home];
foreach (['projects_root','web_root','cockpit_data','library','snippets',
          'sources','code','approvals','queue_dir','response_dir'] as $_pk) {
    if (!empty($PATHS[$_pk])) $allowed_bases[] = $PATHS[$_pk];
}
$allowed_bases = array_values(array_unique($allowed_bases));
if ($dir !== '') {
    $real = realpath($dir);
    $ok   = false;
    if ($real) {
        foreach ($allowed_bases as $base) {
            if (str_starts_with($real, $base)) { $ok = true; break; }
        }
    }
    if (!$ok || !is_dir($dir)) $dir = $home;
} else {
    $dir = $home;
}

// Sanitize model
$model = preg_replace('/[^a-zA-Z0-9:.\-_\/]/', '', $model);
if (!$model) $model = 'qwen2.5-coder:1.5b';

// Sanitize session + socket
$session = preg_replace('/[^a-zA-Z0-9_\-]/', '', $session) ?: ('cockpit_' . $agent);
$socket  = preg_replace('/[^a-zA-Z0-9_\-\/.]/', '', $socket) ?: $PATHS['tmux_socket'];

// Display environment vars passed to sudo. Build dynamically so XAUTHORITY
// resolves correctly when user is not "dario". DBUS path uses the effective
// uid of the home dir's owner.
$_uid = function_exists('fileowner') ? @fileowner($home) : 1000;
if (!$_uid) $_uid = 1000;
// sudo resets the environment, so the launched terminal/file-manager get no
// locale → C/POSIX → zsh/bash choke on UTF-8 chars in .zshrc ("character not in
// range"). Pass the system locale (UTF-8) so the user's shell loads correctly.
$_sys_locale = '';
if (is_readable('/etc/default/locale') &&
    preg_match('/^\s*LANG=("?)([^"\n]+)\1/m', (string)@file_get_contents('/etc/default/locale'), $_lm)) {
    $_sys_locale = trim($_lm[2]);
}
if ($_sys_locale === '') $_sys_locale = getenv('LANG') ?: 'C.UTF-8';
// Session backend: probe the user's runtime dir for a Wayland socket. On
// Wayland the launched app needs WAYLAND_DISPLAY + XDG_RUNTIME_DIR (and the app
// runs AS the user via sudo -u, so it can read that user-owned socket); on X11
// it needs DISPLAY + XAUTHORITY. We pass both sets when detected so the target
// app picks whichever it supports (Chromium honours --ozone-platform; toolkit
// apps auto-detect). NOTE: the sudoers rule's env_keep must include
// WAYLAND_DISPLAY and XDG_RUNTIME_DIR for these to survive sudo (installer adds
// them; on an older install update the /etc/sudoers.d rule to match).
$_runtime_dir = '/run/user/' . (int)$_uid;
$_wl_socket   = '';
foreach ((@glob($_runtime_dir . '/wayland-*') ?: []) as $_w) {
    if (strpos($_w, '.lock') === false) { $_wl_socket = basename($_w); break; }
}
$_is_wayland = ($_wl_socket !== '') || (strtolower((string)getenv('XDG_SESSION_TYPE')) === 'wayland');

$display_env = 'XDG_RUNTIME_DIR=' . escapeshellarg($_runtime_dir) . ' '
             . 'DBUS_SESSION_BUS_ADDRESS=' . escapeshellarg('unix:path=' . $_runtime_dir . '/bus') . ' '
             . 'LANG=' . escapeshellarg($_sys_locale) . ' ';
// The desktop's identity (XDG_CURRENT_DESKTOP, XDG_SESSION_TYPE, DESKTOP_SESSION,
// BROWSER…) as cockpit_start.sh saw it inside the real session. Without these,
// xdg-open in the launched terminal runs in generic mode: a CLI's login URL
// opened in a text editor on ck-ubuntu2404. Names only, never secrets.
$_senv_file = rtrim((string)($PATHS['home'] ?? $home), '/') . '/scripts/cockpit_data/session_env';
foreach ((is_readable($_senv_file) ? file($_senv_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : []) as $_l) {
    if (!preg_match('/^(XDG_CURRENT_DESKTOP|XDG_SESSION_TYPE|XDG_SESSION_DESKTOP|DESKTOP_SESSION|GDMSESSION|BROWSER)=([\x21-\x7e]{1,120})$/', $_l, $_m)) continue;
    $display_env .= $_m[1] . '=' . escapeshellarg($_m[2]) . ' ';
}
// The real session's DISPLAY / WAYLAND_DISPLAY / XAUTHORITY, recorded by
// cockpit_start.sh from inside the session. Apache cannot list /run/user/<uid>
// (mode 0700), and Plasma's XWayland is :1 — the glob above and the :0 default
// both missed on the Manjaro KDE VM. Names/paths only; they override the guesses.
$_s_display = ''; $_s_wl = ''; $_s_xauth = '';
foreach ((is_readable($_senv_file) ? file($_senv_file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) : []) as $_l) {
    if (preg_match('/^DISPLAY=(:[0-9]+(?:\.[0-9]+)?)$/', $_l, $_m)) $_s_display = $_m[1];
    elseif (preg_match('/^WAYLAND_DISPLAY=([A-Za-z0-9_.\/-]{1,120})$/', $_l, $_m)) $_s_wl = $_m[1];
    elseif (preg_match('/^XAUTHORITY=(\/[\x21-\x7e]{1,200})$/', $_l, $_m)) $_s_xauth = $_m[1];
}
if ($_s_wl !== '') { $_is_wayland = true; $_wl_socket = $_s_wl; }
$_x_display = $_s_display !== '' ? $_s_display : ':0';
$_x_auth    = $_s_xauth !== '' ? $_s_xauth : $home . '/.Xauthority';
if ($_is_wayland) {
    $display_env .= 'WAYLAND_DISPLAY=' . escapeshellarg($_wl_socket ?: 'wayland-0') . ' '
                 // Keep DISPLAY too so XWayland-only apps still work.
                 . 'DISPLAY=' . escapeshellarg($_x_display) . ' XAUTHORITY=' . escapeshellarg($_x_auth);
} else {
    $display_env .= 'DISPLAY=' . escapeshellarg($_x_display) . ' XAUTHORITY=' . escapeshellarg($_x_auth);
}

// ── Configurable apps (terminal / files / browser) ─────────────────────────────
// The three toolbar buttons default to the RIG's default apps and can be changed
// by the user from the "Apps" panel. Choices are stored per-user in
// launch_apps.json and must be one of the DETECTED installed candidates (so the
// fixed sudoers allowlist — which covers installed binaries — still authorizes
// them). An empty/absent choice means "system default".
$IS_MAC = (PHP_OS_FAMILY === 'Darwin');

function _launch_which(array $names): array {
    $out = [];
    foreach ($names as $n) {
        foreach (['/usr/bin/', '/usr/local/bin/', '/bin/', '/snap/bin/'] as $p) {
            if (is_file($p . $n)) { $out[] = $p . $n; break; }
        }
    }
    return $out;
}
// Installed candidates per category (absolute binary paths on Linux; app names on mac).
function _launch_candidates(bool $isMac): array {
    if ($isMac) {
        $app = fn($p) => is_dir($p);
        return [
            'terminal' => array_values(array_filter([
                ($app('/System/Applications/Utilities/Terminal.app') || $app('/Applications/Utilities/Terminal.app')) ? 'Terminal' : null,
                $app('/Applications/iTerm.app') ? 'iTerm' : null,
            ])),
            'files'    => ['Finder'],
            'browser'  => array_values(array_filter([
                $app('/Applications/Safari.app') ? 'Safari' : null,
                $app('/Applications/Google Chrome.app') ? 'Google Chrome' : null,
                $app('/Applications/Firefox.app') ? 'Firefox' : null,
                $app('/Applications/Brave Browser.app') ? 'Brave Browser' : null,
            ])),
        ];
    }
    return [
        'terminal' => _launch_which(['gnome-terminal','ptyxis','kgx','konsole','xfce4-terminal','mate-terminal','tilix','kitty','alacritty','xterm']),
        'files'    => _launch_which(['nemo','nautilus','dolphin','thunar','pcmanfm','caja']),
        'browser'  => array_values(array_unique(array_merge(_launch_which(['brave-browser','firefox','chromium','chromium-browser','google-chrome','google-chrome-stable']),
                        // the Cockpit window as a plain browser (cockpit_shell --browser) — always offered, even beside a real browser
                        array_filter([is_executable($h = rtrim((string)($GLOBALS['PATHS']['home'] ?? ''), '/') . '/scripts/cockpit_shell') ? $h : ''])))),
    ];
}
// System default launcher per category.
function _launch_default(string $cat, bool $isMac): string {
    if ($isMac) return 'open';
    if ($cat === 'files')    { $x = _launch_which(['xdg-open']);           return $x[0] ?? (_launch_candidates(false)['files'][0]    ?? ''); }
    if ($cat === 'terminal') {
        // Prefer a known terminal we have a working-directory invocation for
        // (gnome-terminal, konsole, …) over the x-terminal-emulator wrapper,
        // whose flag support varies by distro. Fall back to the wrapper.
        $known = _launch_candidates(false)['terminal'];
        if (!empty($known)) return $known[0];
        $x = _launch_which(['x-terminal-emulator']);
        return $x[0] ?? '';
    }
    // browser: resolve the actual default-browser binary so we can force a new
    // window (xdg-open can't take flags and tends to hijack cockpit's own tab).
    $cands = _launch_candidates(false)['browser'];
    // DECISION 2026-10-12: the Cockpit Browser (cockpit_shell --browser) is the default on every system; the system's own browser is only the fallback when the shell is missing.
    // (An explicit choice in the Apps panel still wins: that is _launch_resolve, before this function.)
    foreach ($cands as $c) if (basename($c) === 'cockpit_shell') return $c;
    $def = @shell_exec('xdg-settings get default-web-browser 2>/dev/null');
    if ($def) {
        $def = trim($def);                 // e.g. "brave-browser.desktop"
        $stem = preg_replace('/\.desktop$/', '', $def);
        if ($stem === 'cockpit-browser') { foreach ($cands as $c) if (basename($c) === 'cockpit_shell') return $c; }   // the Cockpit Browser is the system default
        foreach ($cands as $c) { if (str_contains(basename($c), $stem) || str_contains($stem, basename($c))) return $c; }
    }
    return $cands[0] ?? '';
}
// Resolve the app to actually launch for a category (config choice if valid, else default).
function _launch_resolve(string $cat, string $cd, bool $isMac): string {
    $cfg = @json_decode((string)@file_get_contents($cd . '/launch_apps.json'), true) ?: [];
    $choice = trim((string)($cfg[$cat] ?? ''));
    if ($choice !== '') {
        $valid = _launch_candidates($isMac)[$cat] ?? [];
        if (in_array($choice, $valid, true)) return $choice;
    }
    return _launch_default($cat, $isMac);
}
// Build the per-terminal invocation that opens an interactive shell in $dir.
// sudo -u resets the environment (secure_path), so a plain terminal would miss
// the user's session PATH (~/.local/bin etc. added by ~/.profile). We therefore
// run a LOGIN bash first (`bash -lc` sources /etc/profile + ~/.profile), which
// restores that PATH, then exec the user's own interactive shell.
function _term_invocation(string $bin, string $dir, string $shell, bool $isMac): string {
    if ($isMac) return 'open -a ' . escapeshellarg($bin) . ' ' . escapeshellarg($dir);
    $d     = escapeshellarg($dir);
    $login = 'bash -lc ' . escapeshellarg('exec ' . escapeshellarg($shell) . ' -i');       // login PATH → interactive shell
    $loginCd = 'bash -lc ' . escapeshellarg('cd ' . escapeshellarg($dir) . '; exec ' . escapeshellarg($shell) . ' -i');
    switch (basename($bin)) {
        case 'konsole':        return escapeshellarg($bin) . ' --workdir ' . $d . ' -e ' . $login;
        case 'kitty':          return escapeshellarg($bin) . ' --directory ' . $d . ' ' . $login;
        case 'xterm':          return escapeshellarg($bin) . ' -e ' . $loginCd;
        case 'xfce4-terminal': return escapeshellarg($bin) . ' --working-directory=' . $d . ' -x ' . $login;
        case 'mate-terminal':  return escapeshellarg($bin) . ' --working-directory=' . $d . ' -x ' . $login;   // '--' is not "run this" for mate-terminal (Arch/MATE VM)
        case 'tilix':          return escapeshellarg($bin) . ' --working-directory=' . $d . ' -e ' . $login;
        case 'alacritty':      return escapeshellarg($bin) . ' --working-directory ' . $d . ' -e ' . $login;
        case 'ptyxis':         return escapeshellarg($bin) . ' --working-directory ' . $d . ' -- ' . $login;
        default:               return escapeshellarg($bin) . ' --working-directory=' . $d . ' -- ' . $login; // gnome/x-terminal-emulator/mate/tilix
    }
}


// Open the person's terminal (the one chosen in the Apps panel, else the first
// installed candidate) and run $bash_cmd in it, titled $title. Every emulator
// spells "run this command" differently; gnome-terminal was hard-coded here
// until the Fedora VM (Ptyxis, no gnome-terminal) showed the button doing
// nothing — and the `&` meant rc was 0 whatever happened. Returns the JSON
// fields for the caller to echo: ok, or error naming the missing terminal.
function _term_run(string $title, string $bash_cmd, string $display_env, bool $isMac): array {
    $bin = _launch_resolve('terminal', $GLOBALS['PATHS']['cockpit_data'], $isMac);
    if ($bin === '' || !is_executable($bin)) {
        return ['ok' => false, 'error' => 'No terminal emulator found (looked for gnome-terminal, ptyxis, kgx, konsole, xfce4-terminal, mate-terminal, tilix, kitty, alacritty, xterm). Install one, or pick it in Apps.'];
    }
    $b = escapeshellarg($bin); $t = escapeshellarg($title);
    // A window started by a background process (here: Apache, through sudo) carries no startup notification, so the window
    // manager does not raise it: it opens BEHIND the maximised Cockpit window and looks minimised (seen on Linux Mint /
    // Muffin, 2026-10-05). The terminal raises itself first thing — inside the terminal, as the user, so no sudoers rule is
    // needed. Best effort: it needs wmctrl or xdotool, and without either nothing changes.
    if (!$isMac) {
        $qt = escapeshellarg($title);
        $raise = 'sleep 0.4; (command -v wmctrl >/dev/null 2>&1 && wmctrl -a ' . $qt . '; command -v xdotool >/dev/null 2>&1 && xdotool search --name ' . $qt . ' windowactivate) >/dev/null 2>&1; exec ' . $bash_cmd;
        $bash_cmd = 'bash -c ' . escapeshellarg($raise);
    }
    switch (basename($bin)) {
        case 'konsole':        $inv = "$b --title $t -e $bash_cmd"; break;
        case 'xfce4-terminal': $inv = "$b --title=$t -x $bash_cmd"; break;
        case 'mate-terminal':  $inv = "$b --title=$t -x $bash_cmd"; break;
        case 'tilix':          $inv = "$b --title=$t -e $bash_cmd"; break;
        case 'kitty':          $inv = "$b --title $t $bash_cmd"; break;
        case 'alacritty':      $inv = "$b --title $t -e $bash_cmd"; break;
        case 'xterm':          $inv = "$b -T $t -e $bash_cmd"; break;
        case 'ptyxis':         $inv = "$b --title $t -- $bash_cmd"; break;
        default:               $inv = "$b --title=$t -- $bash_cmd"; break;   // gnome-terminal, kgx, x-terminal-emulator
    }
    $cmd = sprintf('%s %s%s >/dev/null 2>&1 &', $display_env, cockpit_as_owner(), $inv);
    exec($cmd, $out, $rc);
    return ['ok' => ($rc === 0), 'error' => $rc ? basename($bin) . ' failed (rc=' . $rc . '). Check sudoers.' : null];
}
// ── MODE: list_apps — detected candidates + current choices (for the Apps panel) ─
if ($mode === 'list_apps') {
    $cfg = @json_decode((string)@file_get_contents($PATHS['cockpit_data'] . '/launch_apps.json'), true) ?: [];
    $cands = _launch_candidates($IS_MAC);
    $resp = [];
    foreach (['terminal','files','browser'] as $cat) {
        $resp[$cat] = [
            'candidates' => $cands[$cat],
            'choice'     => trim((string)($cfg[$cat] ?? '')),
            'default'    => _launch_default($cat, $IS_MAC),
        ];
    }
    echo json_encode(['ok' => true, 'apps' => $resp], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: set_apps — persist the user's choices (validated against candidates) ──
if ($mode === 'set_apps') {
    $want  = is_array($in['apps'] ?? null) ? $in['apps'] : [];
    $cands = _launch_candidates($IS_MAC);
    $save  = [];
    foreach (['terminal','files','browser'] as $cat) {
        $v = trim((string)($want[$cat] ?? ''));
        // '' = system default; otherwise must be a detected candidate.
        if ($v !== '' && in_array($v, $cands[$cat], true)) $save[$cat] = $v;
        else $save[$cat] = '';
    }
    $f = $PATHS['cockpit_data'] . '/launch_apps.json';
    @file_put_contents($f, json_encode($save, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    @chmod($f, 0664);
    echo json_encode(['ok' => true, 'saved' => $save], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: terminal ────────────────────────────────────────────────────────────
if ($mode === 'terminal') {
    $bin = _launch_resolve('terminal', $PATHS['cockpit_data'], $IS_MAC);
    if ($bin === '') { echo json_encode(['ok'=>false,'error'=>'No terminal found'], JSON_UNESCAPED_UNICODE); exit; }
    // The owner's login shell (so the terminal opens the shell they actually use).
    $login_shell = '/bin/bash';
    if (function_exists('posix_getpwuid')) {
        $pw = @posix_getpwuid((int)@fileowner($home));
        if (!empty($pw['shell']) && is_file($pw['shell'])) $login_shell = $pw['shell'];
    }
    $inv = _term_invocation($bin, $dir, $login_shell, $IS_MAC);
    $cmd = sprintf('%s ' . cockpit_as_owner() . '%s >/dev/null 2>&1 &',
        $display_env, $inv);
    exec($cmd, $out, $rc);
    echo json_encode(['ok' => ($rc === 0), 'dir' => $dir, 'app' => basename($bin),
        'error' => $rc ? basename($bin).' failed (rc='.$rc.')' : null], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: paths ───────────────────────────────────────────────────────────────
// Returns the resolved cockpit-managed locations so the UI can render
// "open in file manager" buttons for each section. Read-only.
if ($mode === 'paths') {
    $locs = [];
    foreach (['home','web_root','cockpit_data','projects_root','library',
              'snippets','sources','code','approvals','queue_dir','response_dir'] as $k) {
        if (!empty($PATHS[$k])) $locs[$k] = ['path'=>$PATHS[$k], 'exists'=>is_dir($PATHS[$k])];
    }
    echo json_encode(['ok'=>true, 'locations'=>$locs], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: files ───────────────────────────────────────────────────────────────
// A path the two chat buttons may open: absolute, existing, inside the projects
// tree or cockpit_data (tool outputs, attachments, uploads live there).
function _launch_path_ok(string $p): bool {
    global $PATHS;
    if ($p === '' || $p[0] !== '/' || strpos($p, '/../') !== false) return false;
    $real = realpath($p); if ($real === false) return false;
    foreach ([(string)($PATHS['projects_root'] ?? ''), (string)($PATHS['cockpit_data'] ?? '')] as $root) {
        $root = $root !== '' ? realpath($root) : false;
        if ($root !== false && strpos($real . '/', rtrim($root, '/') . '/') === 0) return true;
    }
    return false;
}
// ── MODE: restore — cockpit_restore.sh in a terminal (integrity modal) ────────
if ($mode === 'restore') {
    $home = $home ?? (posix_getpwnam(cockpit_owner_user())['dir'] ?? '');
    $script = rtrim((string)$home, '/') . '/scripts/cockpit_restore.sh';
    if (!is_file($script)) { echo json_encode(['ok'=>false,'error'=>'cockpit_restore.sh not found under ' . dirname($script)], JSON_UNESCAPED_UNICODE); exit; }
    $bash_cmd = sprintf('bash -i -c %s', escapeshellarg('bash ' . escapeshellarg($script) . ' --web ' . escapeshellarg(__DIR__) . '; echo; echo "[done — this window stays open; close it when read]"; exec bash'));
    echo json_encode(_term_run('Cockpit — restore shipped files', $bash_cmd, $display_env, $IS_MAC), JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: open — open ONE file with the desktop's default application ───────
// ── MODE: lazarus_info / lazarus — open a Pascal/Lazarus file (and its project) in the Lazarus IDE ────
// Lazarus stays the IDE; Cockpit is beside it. This is the "open in Lazarus" half of that: the Files
// viewer offers it for Pascal files. Needs a sudoers grant for the binary (install_cockpit.sh writes it
// for new installs; deploy step 7a2 adds it on an existing rig). Without the grant we SAY so — a click
// that silently does nothing is the failure to avoid.
function _lazarus_bin(): string {
    foreach (['/usr/bin/startlazarus', '/usr/bin/lazarus-ide', '/usr/local/bin/startlazarus', '/usr/local/bin/lazarus-ide'] as $b) if (is_executable($b)) return $b;
    return '';
}
if ($mode === 'lazarus_info') {
    $bin = $IS_MAC ? '' : _lazarus_bin();
    echo json_encode(['ok' => true, 'available' => $bin !== ''], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($mode === 'lazarus') {
    $bin = $IS_MAC ? '' : _lazarus_bin();
    if ($bin === '') { echo json_encode(['ok' => false, 'error' => 'Lazarus is not installed on this machine (no startlazarus / lazarus-ide found).'], JSON_UNESCAPED_UNICODE); exit; }
    $rel  = trim((string)($in['path'] ?? ''));
    $proj = trim((string)($in['project'] ?? ''));
    if ($proj !== '' && $rel !== '' && $rel[0] !== '/') {
        $rel = ltrim(str_replace(['../', '..\\'], '', $rel), '/');
        $full = realpath(rtrim((string)$PATHS['projects_root'], '/') . '/' . $proj . '/' . $rel);
    } else { $full = realpath($rel); }
    if ($full === false || !is_file($full) || !_launch_path_ok($full)) { echo json_encode(['ok' => false, 'error' => 'Not an openable file.'], JSON_UNESCAPED_UNICODE); exit; }
    $ext = strtolower(pathinfo($full, PATHINFO_EXTENSION));
    if (!in_array($ext, ['pas', 'pp', 'inc', 'lpr', 'lpi', 'lpk', 'lfm', 'lrs', 'dpr', 'dfm'], true)) { echo json_encode(['ok' => false, 'error' => 'Not a Pascal/Lazarus file (.' . $ext . ').'], JSON_UNESCAPED_UNICODE); exit; }
    // The project the file belongs to: the lone .lpi beside it (or the .lpi sharing a .lpr's name).
    $args = [$full];
    if (!in_array($ext, ['lpi', 'lpk'], true)) {
        $lpis = glob(dirname($full) . '/*.lpi') ?: [];
        $same = dirname($full) . '/' . pathinfo($full, PATHINFO_FILENAME) . '.lpi';
        $pick = ($ext === 'lpr' && is_file($same)) ? $same : (count($lpis) === 1 ? $lpis[0] : '');
        if ($pick !== '') $args = [$pick, $full];
    }
    $argStr = implode(' ', array_map('escapeshellarg', $args));
    if (!empty($in['dry'])) { echo json_encode(['ok' => true, 'dry' => true, 'bin' => $bin, 'args' => $args], JSON_UNESCAPED_UNICODE); exit; }
    if (cockpit_runs_as_owner()) { $_rc = 0; }      // already the owner: nothing to be allowed
    else exec('sudo -n -u ' . escapeshellarg(cockpit_owner_user()) . ' -l ' . escapeshellarg($bin) . ' >/dev/null 2>&1', $_o, $_rc);
    if ($_rc !== 0) {
        echo json_encode(['ok' => false, 'error' => 'Lazarus is installed, but Cockpit is not yet allowed to start it. Re-run the installer, or the next Cockpit deploy, to grant it.'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    exec(sprintf('%s %s%s %s >/dev/null 2>&1 &', $display_env, cockpit_as_owner(), escapeshellarg($bin), $argStr), $out, $rc);
    echo json_encode(['ok' => ($rc === 0), 'opened' => array_map('basename', $args), 'error' => $rc ? 'launch failed (rc=' . $rc . ')' : null], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($mode === 'open') {
    $path = trim((string)($in['path'] ?? ''));
    if (!_launch_path_ok($path) || !is_file($path)) { echo json_encode(['ok'=>false,'error'=>'Not an openable file: '.$path], JSON_UNESCAPED_UNICODE); exit; }
    $opener = $IS_MAC ? '/usr/bin/open' : (is_executable('/usr/bin/xdg-open') ? '/usr/bin/xdg-open' : '');
    if ($opener === '') { echo json_encode(['ok'=>false,'error'=>'xdg-open not available'], JSON_UNESCAPED_UNICODE); exit; }
    $cmd = sprintf('%s ' . cockpit_as_owner() . '%s %s >/dev/null 2>&1 &',
        $display_env, escapeshellarg($opener), escapeshellarg($path));
    exec($cmd, $out, $rc);
    echo json_encode(['ok' => ($rc === 0), 'path' => $path, 'error' => $rc ? 'open failed (rc='.$rc.')' : null], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($mode === 'files') {
    // A file path is accepted too: its folder opens (file managers that take a
    // file select it — nemo and nautilus do).
    if ($dir !== '' && is_file($dir) && !_launch_path_ok($dir)) { echo json_encode(['ok'=>false,'error'=>'Not allowed: '.$dir], JSON_UNESCAPED_UNICODE); exit; }
    $fm = _launch_resolve('files', $PATHS['cockpit_data'], $IS_MAC);
    if ($fm === '') { echo json_encode(['ok'=>false,'error'=>'No file manager found'], JSON_UNESCAPED_UNICODE); exit; }
    // Default dispatcher (xdg-open / mac open) and every file manager accept the
    // target directory as a plain positional argument.
    $cmd = sprintf('%s ' . cockpit_as_owner() . '%s %s >/dev/null 2>&1 &',
        $display_env, escapeshellarg($fm), escapeshellarg($dir));
    exec($cmd, $out, $rc);
    echo json_encode(['ok' => ($rc === 0), 'dir' => $dir, 'fm' => basename($fm),
        'error' => $rc ? basename($fm).' failed (rc='.$rc.')' : null], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: browser ─────────────────────────────────────────────────────────────
if ($mode === 'browser') {
    $browser = _launch_resolve('browser', $PATHS['cockpit_data'], $IS_MAC);
    if ($browser === '') { echo json_encode(['ok'=>false,'error'=>'No browser found'], JSON_UNESCAPED_UNICODE); exit; }
    // Optional URL to open directly. Scheme-restricted — escapeshellarg stops
    // shell injection, but a bare "--flag"-shaped string would still reach the
    // browser's OWN argv parser as a flag, so require a real http(s) URL.
    $hasUrl  = (bool)preg_match('#^(https?|file)://#i', $url);
    // A bare --new-window with no URL lets Brave/Chromium reuse (and hijack) the
    // window Cockpit runs in; an explicit page forces a real separate window.
    // about:blank is a hardcoded constant (no user input → no shell risk).
    $urlArg  = $hasUrl ? ' ' . escapeshellarg($url) : ' about:blank';
    if ($IS_MAC) {
        // mac 'open' — -n forces a new instance/window; -a targets the chosen app.
        $target = ($browser === 'open') ? '' : (' -a ' . escapeshellarg($browser));
        $cmd = sprintf('%s -n%s%s >/dev/null 2>&1 &', escapeshellarg('/usr/bin/open'), $target, $urlArg);
    } else {
        // --new-window opens a SEPARATE window in the user's existing browser
        // session instead of hijacking (or restarting) the window Cockpit runs
        // in. All chromium-family browsers + firefox accept it.
        if (basename($browser) === 'cockpit_shell') {
            // Cockpit Browser: the native window in plain-browser mode
            $cmd = sprintf('%s ' . cockpit_as_owner() . '%s --browser --url%s >/dev/null 2>&1 &', $display_env, escapeshellarg($browser), $urlArg);
        } else
        $cmd = sprintf('%s ' . cockpit_as_owner() . '%s --new-window%s >/dev/null 2>&1 &',
            $display_env, escapeshellarg($browser), $urlArg);
    }
    exec($cmd, $out, $rc);
    echo json_encode(['ok' => ($rc === 0), 'browser' => basename($browser), 'url' => $hasUrl ? $url : null,
        'error' => $rc ? basename($browser).' failed (rc='.$rc.')' : null], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: attach ──────────────────────────────────────────────────────────────
// ── MODE: workers_log — a terminal tailing the Workers activity log ─────────
// The Workers card has no tmux session (calls are HTTP from workers.php), so
// its "open" button shows the next best thing: the per-user activity log that
// workers.php appends to on every call. Path is resolved here, never taken
// from the client.
if ($mode === 'workers_log') {
    $logf = rtrim((string)$PATHS['cockpit_data'], '/') . '/workers_activity.log';
    if (!file_exists($logf)) { @touch($logf); @chmod($logf, 0664); }
    $title = 'Cockpit — WORKERS activity';
    $bash_cmd = sprintf('bash -i -c %s', escapeshellarg(
        'echo "Workers activity log: ' . $logf . '"; echo "(every call: time · provider:model · task · ok/err · ms · tokens; Ctrl-C to stop)"; echo; ' .
        'tail -n 40 -f ' . escapeshellarg($logf) . '; exec bash'));
    echo json_encode(_term_run($title, $bash_cmd, $display_env, $IS_MAC), JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: session_kind — is this agent's loop hosted by the supervisor (live log) or by tmux? ─────────────
// The native window used to attach to tmux by itself for "open session" and never asked, so with the supervisor on it showed a stale tmux pane
// (found 2026-10-06). It now asks here first; a supervised agent is opened through the 'attach' mode below, which tails its log.
if ($mode === 'session_kind') {
    require_once __DIR__ . '/session_backend.php';
    $_k = in_array($agent, ['claude', 'gemini', 'ollama'], true) && ck_agent_logfile($agent) !== null;
    echo json_encode(['ok' => true, 'agent' => $agent, 'supervised' => $_k, 'via' => $_k ? 'supervisor' : 'tmux'], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($mode === 'attach') {
    $title   = 'Cockpit — ' . strtoupper($agent);
    // A supervised agent has no tmux pane: show its log, live (the same lines a pane would have shown).
    require_once __DIR__ . '/session_backend.php';
    $_log = in_array($agent, ['claude', 'gemini', 'ollama'], true) ? ck_agent_logfile($agent) : null;
    if ($_log !== null)
        $cli_cmd = sprintf('echo "%s (supervised: live log, Ctrl-C to close)"; tail -n 200 -F %s', strtoupper($agent), escapeshellarg($_log));
    else
    $cli_cmd = sprintf('/usr/bin/tmux -S %s attach -t %s',
        escapeshellarg($socket), escapeshellarg($session));
    $bash_cmd = sprintf('bash -i -c %s',
        escapeshellarg(
            'export PATH=' . escapeshellarg($npm_bin.':/usr/local/bin:/usr/bin:/bin') . ':$PATH; ' .
            'cd ' . escapeshellarg($home) . '; ' .
            $cli_cmd . '; echo; echo "[Session ended — shell stays open]"; exec bash'));
    echo json_encode(['agent' => $agent] + _term_run($title, $bash_cmd, $display_env, $IS_MAC), JSON_UNESCAPED_UNICODE);
    exit;
}

// ── MODE: cli (default) ───────────────────────────────────────────────────────
if (!in_array($agent, ['claude','gemini','ollama'], true)) {
    echo json_encode(['ok' => false, 'error' => 'Unknown agent: ' . $agent], JSON_UNESCAPED_UNICODE);
    exit;
}

// Card 1 (claude role) / Card 2 (gemini role) can be aliased to a different
// paid CLI supplier (cli_suppliers.json, e.g. codex/qwen_code) via
// supplier_slots.json's primary/fallback — de-hardwired for agent_loop.sh
// dispatch already (2026-06-28), but this DIRECT terminal-launch path still
// always opened the literal claude/gemini npm binaries regardless. Fixed
// 2026-07-02: resolve the actually-assigned supplier's binary when it's a
// paid_cli kind; falls back to the original hardcoded binary otherwise
// (default config, or a REST-only alias with no CLI binary to open).
function resolve_cli_supplier(string $role, string $cd): ?array {
    $slotsF = $cd . '/supplier_slots.json';
    $catF   = $cd . '/cli_suppliers.json';
    if (!is_readable($slotsF)) return null;
    $slots = json_decode((string)file_get_contents($slotsF), true) ?: [];
    // The catalog: the shared defaults (always present), merged over by the saved
    // cli_suppliers.json override IF it exists. load_cli_catalog() never persists the
    // defaults, so this override file is usually absent — before, that made every free_cli
    // alias (opencode/aider/goose) unresolvable here and fall back to the literal gemini
    // binary. Fixed by folding in $CLI_CATALOG_DEFAULT.
    require __DIR__ . '/cli_catalog_default.php';   // $CLI_CATALOG_DEFAULT
    $cat = $CLI_CATALOG_DEFAULT;
    if (is_readable($catF)) {
        $saved = json_decode((string)file_get_contents($catF), true);
        if (is_array($saved)) $cat = array_merge($cat, $saved);
    }
    $slotKey = $role === 'claude' ? 'primary' : 'fallback';   // Card1/Card2
    $supId = (string)($slots[$slotKey] ?? '');
    if ($supId === '' || $supId === $role) return null;        // unchanged from default
    $sup = $cat[$supId] ?? null;
    // Accept both paid CLIs (Claude/Codex/Qwen) and free local agents (Aider/Goose/
    // opencode) so "open CLI in a new terminal" opens the actual assigned supplier.
    if (!$sup || !in_array($sup['kind'] ?? '', ['paid_cli', 'free_cli'], true) || empty($sup['binary'])) return null;
    return $sup;
}

// Build the interactive command + extra env for an alias supplier. Free agents
// carry an `interactive` spec (REPL/TUI form + backend env); %MODEL% → the chosen
// model, %OLLAMA% → the local Ollama base. Paid CLIs just run their bare binary.
function cli_interactive(array $sup, string $model): array {
    $ollama = 'http://127.0.0.1:11434';
    $inter  = $sup['interactive'] ?? null;
    if (is_array($inter) && !empty($inter['cmd'])) {
        $sub = ['%MODEL%' => $model, '%OLLAMA%' => $ollama];
        $cmd = strtr($inter['cmd'], $sub);
        $env = strtr((string)($inter['env'] ?? ''), $sub);
        return ['cmd' => $cmd, 'env' => $env];
    }
    return ['cmd' => $sup['binary'], 'env' => ''];
}

$extra_env = '';
switch ($agent) {
    case 'claude': {
        $alias = resolve_cli_supplier('claude', $PATHS['cockpit_data']);
        if ($alias) { $title = $alias['name'] . ' CLI'; $ci = cli_interactive($alias, $model); $cli_cmd = $ci['cmd']; $extra_env = $ci['env']; }
        else        { $title = 'Claude Code CLI'; $cli_cmd = $npm_bin . '/claude'; }
        break;
    }
    case 'gemini': {
        $alias = resolve_cli_supplier('gemini', $PATHS['cockpit_data']);
        if ($alias) { $title = $alias['name'] . ' CLI'; $ci = cli_interactive($alias, $model); $cli_cmd = $ci['cmd']; $extra_env = $ci['env']; }
        else        { $title = 'Gemini CLI'; $cli_cmd = $npm_bin . '/gemini'; }
        break;
    }
    case 'ollama': {
        // Card 3: interactive REPL for the chosen local backend. Ollama has a native
        // `run` REPL; LocalAI (OpenAI-compatible, no REPL) gets a tiny written chat
        // script. Dual → the Ollama side.
        $prov = 'ollama';
        $slF  = $PATHS['cockpit_data'] . '/supplier_slots.json';
        if (is_readable($slF)) { $sl = json_decode((string)file_get_contents($slF), true) ?: []; $prov = (string)($sl['local']['provider'] ?? 'ollama'); }
        if ($prov === 'localai') {
            $title = 'LocalAI — ' . $model;
            $repl  = $PATHS['cockpit_data'] . '/localai_repl.py';
            @file_put_contents($repl,
                "import sys,json,urllib.request\n" .
                "m,b=(sys.argv[1] if len(sys.argv)>1 else ''),'http://127.0.0.1:8080'\n" .
                "print('LocalAI chat ('+m+') — Ctrl+D to exit')\n" .
                "while True:\n" .
                "  try: q=input('you> ')\n" .
                "  except EOFError: break\n" .
                "  if not q.strip(): continue\n" .
                "  d=json.dumps({'model':m,'messages':[{'role':'user','content':q}]}).encode()\n" .
                "  try:\n" .
                "    r=urllib.request.urlopen(urllib.request.Request(b+'/v1/chat/completions',d,{'Content-Type':'application/json'}),timeout=300)\n" .
                "    print(json.load(r)['choices'][0]['message']['content'])\n" .
                "  except Exception as e: print('[error] '+str(e))\n");
            $cli_cmd = 'python3 ' . escapeshellarg($repl) . ' ' . escapeshellarg($model);
        } else {
            $title   = 'Ollama — ' . $model;
            $cli_cmd = escapeshellarg($PATHS['ollama_binary']) . ' run ' . escapeshellarg($model);
        }
        break;
    }
    default: $title = $agent; $cli_cmd = 'bash';
}

$bash_cmd = sprintf('bash -i -c %s',
    escapeshellarg(
        ($extra_env !== '' ? 'export ' . $extra_env . '; ' : '') .
        'export PATH=' . escapeshellarg($npm_bin.':' . $home . '/.local/bin:' . $home . '/.opencode/bin:/usr/local/bin:/usr/bin:/bin') . ':$PATH; ' .
        'cd ' . escapeshellarg($home) . '; ' .
        $cli_cmd . '; echo; echo "[Session ended — shell stays open]"; exec bash'));

echo json_encode(['agent' => $agent] + _term_run($title, $bash_cmd, $display_env, $IS_MAC), JSON_UNESCAPED_UNICODE);
