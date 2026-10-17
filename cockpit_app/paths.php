<?php
require_once __DIR__ . '/edition.php';   // edition tag + gate helpers (choke-point)

// ── posix_* without the extension ────────────────────────────────────────
// Fedora/RHEL ship it as a separate package (php-process); without it every
// backend that maps uids to names died with a 500 on the first Fedora install.
// These read /etc/passwd and /etc/group the way the C functions do.
if (!function_exists('posix_getpwuid')) {
    function _ck_passwd_rows(): array { return (array)@file('/etc/passwd', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES); }
    function _ck_pw_entry(array $p): array { return ['name'=>$p[0], 'passwd'=>$p[1] ?? 'x', 'uid'=>(int)($p[2] ?? 0), 'gid'=>(int)($p[3] ?? 0), 'gecos'=>$p[4] ?? '', 'dir'=>$p[5] ?? '', 'shell'=>$p[6] ?? '']; }
    function posix_getpwuid($uid) { foreach (_ck_passwd_rows() as $l) { $p = explode(':', $l); if (isset($p[2]) && (int)$p[2] === (int)$uid) return _ck_pw_entry($p); } return false; }
    function posix_getpwnam($name) { foreach (_ck_passwd_rows() as $l) { $p = explode(':', $l); if (isset($p[0]) && $p[0] === (string)$name) return _ck_pw_entry($p); } return false; }
    function posix_getgrgid($gid) { foreach ((array)@file('/etc/group', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) { $p = explode(':', $l); if (isset($p[2]) && (int)$p[2] === (int)$gid) return ['name'=>$p[0], 'passwd'=>$p[1] ?? 'x', 'members'=>array_filter(explode(',', $p[3] ?? '')), 'gid'=>(int)$p[2]]; } return false; }
    function posix_geteuid() { return function_exists('getmyuid') ? (int)getmyuid() : 0; }
    function posix_getuid()  { return posix_geteuid(); }
}
// =============================================================================
// paths.php — Cockpit path resolution & OS detection (single include)
//
// Every PHP backend should:   require_once __DIR__ . '/paths.php';
// Then use:                   $PATHS['cockpit_data'], $PATHS['web_root'], etc.
//
// Reads paths.json for user-configurable overrides, fills defaults per OS,
// and feature-detects binaries. No hardcoded paths should appear anywhere else.
// =============================================================================

// Prevent double-include from clobbering
if (defined('COCKPIT_PATHS_LOADED')) return;
define('COCKPIT_PATHS_LOADED', true);

// --- OS detection -----------------------------------------------------------

function cockpit_detect_os(): string {
    if (PHP_OS_FAMILY === 'Windows')  return 'windows';
    if (PHP_OS_FAMILY === 'Darwin')   return 'macos';
    // Check for Termux (Android)
    if (getenv('PREFIX') && strpos(getenv('PREFIX'), 'com.termux') !== false) return 'android';
    return 'linux';
}

define('COCKPIT_OS', cockpit_detect_os());

// --- Platform profile (Phase 5: cross-platform object metadata) --------------
function cockpit_platform_profile(): array {
    static $p = null;
    if ($p !== null) return $p;
    $os     = COCKPIT_OS;
    $family = ($os === 'windows') ? 'windows' : 'unix';
    $p = [
        'os'        => $os,
        'family'    => $family,
        'arch'      => strtolower(trim((string)php_uname('m')) ?: 'unknown'),
        'path_sep'  => ($family === 'windows') ? '\\' : '/',
        'list_sep'  => ($family === 'windows') ? ';'  : ':',
        'shell'     => ($family === 'windows') ? 'cmd' : (getenv('SHELL') ?: 'sh'),
        'has_bash'  => (bool) cockpit_find_binary('bash'),
        'is_mobile' => ($os === 'android'),
    ];
    return $p;
}

// --- Binary resolver --------------------------------------------------------

function cockpit_find_binary(string $name, array $extra_paths = []): ?string {
    // 1. Check extra paths first (per-OS overrides)
    foreach ($extra_paths as $p) {
        $full = rtrim($p, '/') . '/' . $name;
        if (is_file($full) && is_executable($full)) return $full;
    }
    // 2. command -v (works on all Unix, not Windows)
    if (COCKPIT_OS !== 'windows') {
        $resolved = trim((string)shell_exec('command -v ' . escapeshellarg($name) . ' 2>/dev/null'));
        if ($resolved && is_file($resolved) && is_executable($resolved)) return $resolved;
    }
    // 3. Common absolute paths per OS
    $search = [];
    switch (COCKPIT_OS) {
        case 'linux':   $search = ['/usr/bin', '/usr/local/bin', '/opt/bin']; break;
        case 'macos':   $search = ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin']; break;
        case 'android': $search = [getenv('PREFIX') . '/bin']; break;
        case 'windows': break; // relies on PATH via command -v equivalent
    }
    foreach ($search as $dir) {
        $full = $dir . '/' . $name;
        if (is_file($full) && is_executable($full)) return $full;
    }
    return null;
}

// Resolve timeout binary (Linux/macOS have /usr/bin/timeout or gtimeout)
function cockpit_timeout_cmd(int $seconds): string {
    static $bin = null;
    if ($bin === null) {
        $bin = cockpit_find_binary('timeout') ?: cockpit_find_binary('gtimeout') ?: '';
    }
    if ($bin === '') return '';
    return escapeshellarg($bin) . ' ' . $seconds . ' ';
}

// --- Load paths.json --------------------------------------------------------

$_paths_file = __DIR__ . '/paths.json';
$_paths_json = [];
if (is_readable($_paths_file)) {
    $_raw = file_get_contents($_paths_file);
    if ($_raw !== false) {
        $_parsed = json_decode($_raw, true);
        if (is_array($_parsed)) $_paths_json = $_parsed;
    }
}

// --- Build $PATHS with defaults per OS --------------------------------------

$_web_root = __DIR__;  // wherever this file lives IS the web root

// Home dir: paths.json > environment > OS default.
// cockpit_home() is the ONE definition of the environment/OS half, so callers
// that need a home dir before (or without) $PATHS don't invent their own. It
// used to be copy-pasted around the tree as `getenv('HOME') ?: '/home/user'`,
// which shipped the build machine's username to every install and pointed at a
// directory that does not exist on anyone else's.
if (!function_exists('cockpit_home')) {
    function cockpit_home(): string {
        $h = getenv('HOME');
        if ($h) return rtrim($h, '/');
        $up = getenv('USERPROFILE');                       // Windows
        if ($up) return rtrim($up, '/');
        if (function_exists('posix_geteuid')) {            // real passwd entry
            $pw = @posix_getpwuid(posix_geteuid());
            if (!empty($pw['dir'])) return rtrim($pw['dir'], '/');
        }
        $u = get_current_user();                           // owner of this file
        if ($u !== '') return '/home/' . $u;
        return rtrim(sys_get_temp_dir(), '/') . '/cockpit'; // never return '/home/'
    }
    // Under the web server, $HOME is the SERVER's home (/var/www) and the file
    // owner is root after lockdown — neither is the person who installed
    // Cockpit. When the guessed home has no scripts/cockpit_start.sh, the one
    // /home/*/ that does is the install (single-user machines, i.e. nearly all).
    // Found on ck-ubuntu2404: sudo asked for /var/www/scripts/cockpit_start.sh as root.
    function cockpit_home_checked(): string {
        $h = cockpit_home();
        if (is_file($h . '/scripts/cockpit_start.sh')) return $h;
        $hits = array_filter(glob('/home/*/scripts/cockpit_start.sh') ?: [], 'is_file');
        if (count($hits) === 1) return dirname(dirname(reset($hits)));
        return $h;
    }
}
$_home = ($_paths_json['home'] ?? '') ?: cockpit_home_checked();   // empty string in paths.json = unset, as before

// cockpit_data: paths.json > per-OS default
$_cd_defaults = [
    'linux'   => $_home . '/scripts/cockpit_data',
    'macos'   => $_home . '/Library/Application Support/Cockpit',
    'windows' => (getenv('APPDATA') ?: $_home . '/AppData/Roaming') . '/Cockpit',
    'android' => $_home . '/cockpit_data',
];
$_cockpit_data_root = $_paths_json['cockpit_data'] ?? ($_cd_defaults[COCKPIT_OS] ?? $_cd_defaults['linux']);

// --- Per-user data scoping ---------------------------------------------------
// Everything under cockpit_data (tools/skills/combos/chats/library/SaaS
// account…) is scoped to the LOGGED-IN LOCAL APP USER, so several people on
// one machine (family members, work profiles) get separate data + separate
// subscriptions, sharing only the install itself. Started here (not left to
// auth.php) because every backend needs $PATHS before auth.php's own checks
// run. users.json (the login list itself) deliberately stays at the SHARED
// root — you need it to know who's logging in before you can scope anything.
// No session user yet (not logged in / setup) → falls back to the shared root
// itself, same behavior as before this existed.
// Session config lives HERE (not auth.php) so it's consistent no matter which
// file requires paths.php first — ini_set() after session_start() is a no-op,
// so this must run before the session actually starts.
// The agent loop's own calls to a few pages (internal_auth.php): accepted as the named person for THIS request only, with no session and no cookie.
require_once __DIR__ . '/internal_auth.php';
$_ck_internal = (PHP_SAPI !== 'cli' && !empty($_SERVER['HTTP_X_COCKPIT_INTERNAL']))
    ? ck_internal_login($_SERVER, $_GET, (string)@file_get_contents('php://input'), (string)$_cockpit_data_root) : null;
if ($_ck_internal !== null) {
    $_SESSION = ['cockpit_user' => $_ck_internal['user'], 'cockpit_role' => $_ck_internal['role'], 'cockpit_internal' => true];
} elseif (session_status() === PHP_SESSION_NONE) {
    // "Remember me" by default (2026-07-02, user request — repeated logins were
    // annoying, especially now that the SaaS account is nested under the
    // per-user data path and effectively logs out WITH the local session).
    // 90 days on a personal/family machine; explicit Sign out still clears it
    // immediately regardless of this window. gc_maxlifetime must be >= the
    // cookie lifetime or PHP could GC the session server-side before the
    // cookie itself expires.
    $_cockpit_session_days = 90;
    $_cockpit_session_ttl  = $_cockpit_session_days * 86400;
    ini_set('session.gc_maxlifetime', (string)$_cockpit_session_ttl);
    ini_set('session.cookie_lifetime', (string)$_cockpit_session_ttl);
    ini_set('session.cookie_httponly', '1');
    ini_set('session.cookie_samesite', 'Lax');
    ini_set('session.use_strict_mode', '1');
    session_name('cockpit_sid');
    @session_start();
}
$_cockpit_user = null;
if (!empty($_SESSION['cockpit_user'])) {
    $_cockpit_user = preg_replace('/[^A-Za-z0-9_-]/', '', (string)$_SESSION['cockpit_user']);
}
$_cockpit_data = ($_cockpit_user !== null && $_cockpit_user !== '')
    ? $_cockpit_data_root . '/users/' . $_cockpit_user
    : $_cockpit_data_root;
if ($_cockpit_data !== $_cockpit_data_root && !is_dir($_cockpit_data)) {
    @mkdir($_cockpit_data, 0775, true);
    // Created by the web user, it ended up www-data:www-data 755 — so the owner's
    // own processes (the cron tick, scripts from a terminal) could not write their
    // own data. Give it the OWNER's group (read from the home directory; the parent
    // carries the WEB group, so copying that changes nothing) and setgid, so both
    // sides can write everything created inside (2026-09-22).
    $_homeGid = @filegroup((string)($_paths_json['home'] ?? dirname($_cockpit_data_root, 2)));
    if ($_homeGid !== false) @chgrp($_cockpit_data, (int)$_homeGid);
    @chmod($_cockpit_data, 02775);
}

// projects_root (chat history) — same per-user scoping as cockpit_data above
// (2026-07-02). No shared-file concern here (unlike cockpit_data_root's
// users.json), so no companion "_root" key is needed — just the active path.
$_projects_root_shared = $_paths_json['projects_root'] ?? $_home . '/Projects';
$_projects_root = ($_cockpit_user !== null && $_cockpit_user !== '')
    ? $_projects_root_shared . '/users/' . $_cockpit_user
    : $_projects_root_shared;
if ($_projects_root !== $_projects_root_shared && !is_dir($_projects_root)) {
    @mkdir($_projects_root, 0775, true);
}

$PATHS = [
    // Core directories
    'os'             => COCKPIT_OS,
    'platform'       => cockpit_platform_profile(),   // Phase 5
    'home'           => $_home,
    'web_root'       => $_web_root,
    'cockpit_data'      => $_cockpit_data,        // ACTIVE (per-user if logged in) data root
    'cockpit_data_root' => $_cockpit_data_root,    // SHARED machine root (users.json, Ollama config…)
    'cockpit_user'      => $_cockpit_user,          // sanitized logged-in username, or null
    'projects_root'         => $_projects_root,         // ACTIVE (per-user if logged in)
    'projects_root_shared'  => $_projects_root_shared,  // unscoped root, rarely needed directly

    // Data subdirectories
    'library'        => $_paths_json['library']   ?? $_cockpit_data . '/library',
    'snippets'       => $_paths_json['snippets']  ?? $_cockpit_data . '/snippets',
    'sources'        => $_paths_json['sources']   ?? $_cockpit_data . '/sources',
    'code'           => $_paths_json['code']      ?? $_cockpit_data . '/code',
    'approvals'      => $_paths_json['approvals'] ?? $_cockpit_data . '/approvals',

    // Runtime directories (relative to web_root)
    'queue_dir'      => $_paths_json['queue_dir']      ?? $_web_root . '/queue',
    'response_dir'   => $_paths_json['response_dir']   ?? $_web_root . '/responses',
    'tmux_socket'    => $_paths_json['tmux_socket']     ?? $_web_root . '/tmux.sock',
    'ollama_log'     => $_paths_json['ollama_log']     ?? $_web_root . '/ollama_usage.jsonl',

    // Resolved binaries (cached)
    'ollama_binary'  => $_paths_json['ollama_binary']  ?? cockpit_find_binary('ollama'),
    'php_binary'     => $_paths_json['php_binary']     ?? cockpit_find_binary('php'),
    // Order matters, and PATH order is not good enough here.
    //   1. paths.json override, always wins.
    //   2. /usr/local/bin/yt-dlp -- the SELF-CONTAINED build the installer places
    //      (Python bundled inside, nothing needed on the host). Since 2026-09-24
    //      this is the supported copy; it replaced a venv install, which is how
    //      yt-dlp used to drag the Transcriber into depending on Python.
    //   3. the old shared-venv copy, so installs made before that keep working.
    //   4. whatever is on PATH -- last, because a distro apt yt-dlp goes stale and
    //      YouTube breaks it within months.
    'yt_dlp'         => $_paths_json['yt_dlp']
                        ?? (is_executable('/usr/local/bin/yt-dlp')
                             ? '/usr/local/bin/yt-dlp'
                             : ((is_file($_cockpit_data_root . '/venv/bin/yt-dlp') && is_executable($_cockpit_data_root . '/venv/bin/yt-dlp'))
                                 ? $_cockpit_data_root . '/venv/bin/yt-dlp'
                                 : cockpit_find_binary('yt-dlp'))),
];

// Convenience: $CD shorthand used by most backends
$CD = $PATHS['cockpit_data'];

// --- Web user (for permission fixing) ---------------------------------------

// The web server's own account: www-data (Debian family), apache (Fedora/RHEL),
// http (Arch), wwwrun (openSUSE). When PHP runs under it, that is the answer;
// otherwise (CLI) the first such account that exists.
function cockpit_web_user(): ?string {
    if (COCKPIT_OS !== 'linux') return null;
    static $u = null; if ($u !== null) return $u;
    $me = function_exists('posix_getpwuid') ? (posix_getpwuid(posix_geteuid())['name'] ?? '') : '';
    if (in_array($me, ['www-data', 'apache', 'http', 'wwwrun', 'nginx'], true)) return $u = $me;
    foreach (['www-data', 'apache', 'http', 'wwwrun'] as $c) if (function_exists('posix_getpwnam') && posix_getpwnam($c)) return $u = $c;
    return $u = 'www-data';
}
// The GROUP the web server runs with — not always the user's own name (openSUSE:
// wwwrun:www, and the worker's supplementary groups do not include wwwrun). The
// effective gid of this very process is the truth; the installer's chowns and
// sudoers rule use the same value (APACHE_GROUP).
function cockpit_web_group(): string {
    static $g = null; if ($g !== null) return $g;
    if (function_exists('posix_getegid') && function_exists('posix_getgrgid')) {
        $gr = @posix_getgrgid(posix_getegid());
        if (is_array($gr) && !empty($gr['name'])) return $g = (string)$gr['name'];
    }
    return $g = (string)(cockpit_web_user() ?? 'www-data');
}

function cockpit_owner_user(): string {
    // The human OS user to sudo to for launching GUI apps (terminal, file
    // manager, browser, agent tmux sessions) — completely separate from which
    // LOCAL APP LOGIN's per-user data folder happens to be active. Stats
    // $PATHS['home'] (always owned by the real OS account, not the web-server user),
    // NOT cockpit_data — that can now be a per-user subfolder that got
    // created by www-data itself (e.g. on first login as a new local user),
    // which would make this return "www-data" and break every sudo launch.
    global $PATHS;
    $probe = $PATHS['home'] ?? null;
    if ($probe && is_dir($probe)) {
        $stat = stat($probe);
        if ($stat) {
            // posix_* is a separate package on Fedora/RHEL (php-process) — without
            // it every sudo launch died with a 500 (first Fedora VM). Fall back to
            // reading /etc/passwd for the uid.
            if (function_exists('posix_getpwuid')) {
                $info = posix_getpwuid($stat['uid']);
                if ($info) return $info['name'];
            }
            foreach ((array)@file('/etc/passwd', FILE_IGNORE_NEW_LINES) as $_l) {
                $_p = explode(':', $_l);
                if (isset($_p[2]) && (int)$_p[2] === (int)$stat['uid'] && $_p[0] !== '') return $_p[0];
            }
        }
    }
    return getenv('USER') ?: getenv('USERNAME') ?: 'nobody';
}

/**
 * Does PHP already run as the person who owns this Cockpit? True in the self-contained mode (the supervisor runs php-cgi as the owner) and
 * under `php -S` started by the owner; false under Apache (www-data), where every launch goes through sudo.
 */
function cockpit_runs_as_owner(): bool {
    static $r = null;
    if ($r !== null) return $r;
    global $PATHS;
    $probe = $PATHS['home'] ?? null;
    $me = function_exists('posix_geteuid') ? posix_geteuid() : (int)trim((string)@shell_exec('id -u 2>/dev/null'));
    $st = ($probe && is_dir($probe)) ? @stat($probe) : false;
    return $r = ($st && $me > 0 && (int)$st['uid'] === (int)$me);
}

/**
 * The command prefix that runs something AS THE OWNER: nothing when PHP already is the owner (no sudo, no sudoers entry needed: this is what
 * lets the self-contained mode work on a machine where the installer never touched /etc/sudoers.d), otherwise `sudo -u <owner> `
 * (`sudo -n -u <owner> ` with $noPrompt, for calls that must never wait for a password). The prefix ends in a space when it is not empty.
 */
function cockpit_as_owner(bool $noPrompt = false): string {
    if (cockpit_runs_as_owner()) return '';
    return 'sudo ' . ($noPrompt ? '-n ' : '') . '-u ' . escapeshellarg(cockpit_owner_user()) . ' ';
}

// -----------------------------------------------------------------------------
// Upload limits, explained. When a multipart upload is bigger than upload_max_filesize
// or post_max_size, PHP does not fail loudly: $_FILES simply arrives EMPTY, and every
// endpoint then said "No audio uploaded" / "No file uploaded" — for a perfectly good
// 3 MB voice note on a stock install (limits 2M / 8M). This returns the real reason,
// or '' when the upload was not blocked by a PHP limit.
// -----------------------------------------------------------------------------
function cockpit_ini_bytes(string $v): int {
    $v = trim($v); if ($v === '') return 0;
    $n = (float)$v; $u = strtolower(substr($v, -1));
    if ($u === 'g') $n *= 1073741824; elseif ($u === 'm') $n *= 1048576; elseif ($u === 'k') $n *= 1024;
    return (int)$n;
}
function cockpit_upload_limit_message(): string {
    $len = (int)($_SERVER['CONTENT_LENGTH'] ?? 0);
    $maxPost = cockpit_ini_bytes((string)ini_get('post_max_size'));
    $maxFile = cockpit_ini_bytes((string)ini_get('upload_max_filesize'));
    $tooBig = ($maxPost > 0 && $len > $maxPost);
    if (!$tooBig) foreach ($_FILES as $f) if (is_array($f) && ($f['error'] ?? 0) === UPLOAD_ERR_INI_SIZE) $tooBig = true;
    if (!$tooBig) return '';
    return sprintf('This upload (%.1f MB) is larger than the web server\'s PHP limits allow (upload_max_filesize=%s, post_max_size=%s). '
        . 'Raise them: Setup Guide, "Raising the upload size limit".', $len / 1048576, ini_get('upload_max_filesize'), ini_get('post_max_size'));
}
