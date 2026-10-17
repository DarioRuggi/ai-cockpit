<?php
// =============================================================================
// auth.php — Cockpit access control
//
// Include at top of every PHP backend: require_once __DIR__ . '/auth.php';
// Handles: login, logout, check, user management, session validation.
//
// Actions (when called directly via GET/POST):
//   ?action=check          — is session valid? {ok, user, role}
//   ?action=login           — POST {username, password} → start session
//   ?action=logout          — destroy session
//   ?action=setup           — POST {username, password} — first-run admin creation
//   ?action=change_password — POST {current, new_password}
//   ?action=list_users      — admin only
//   ?action=add_user        — POST {username, password, role} — admin only
//   ?action=remove_user     — POST {username} — admin only
//
// When included by another file: validates session silently. If invalid,
// returns 401 JSON and exits. The including file never runs.
// =============================================================================

// paths.php now owns session_start() (+ its cookie/lifetime ini_set calls) —
// it needs the session early to resolve the per-user data root, and every
// backend requires paths.php before anything else anyway.
require_once __DIR__ . '/paths.php';

// ── Demo edition: auto-authenticate as a throwaway 'demo' admin so the public
// web demo isn't blocked by the login wall. Real dispatch/filesystem are still
// muted per-endpoint (ed_gate_or_exit / ed_demo_stub); this only grants a
// session so those endpoints reach their described-modal instead of a 401. ──
if (ed_is('demo')) {
    if (empty($_SESSION['cockpit_user'])) {
        $_SESSION['cockpit_user']     = 'demo';
        $_SESSION['cockpit_role']     = 'admin';
        $_SESSION['cockpit_id']       = 1;
        $_SESSION['cockpit_login_at'] = time();
    }
    // Only answer auth's OWN ?action= when auth.php is the requested endpoint —
    // NOT when another file merely requires it (that would hijack its ?action=).
    $__isDirectAuthRequest = isset($_SERVER['SCRIPT_FILENAME'])
        && realpath($_SERVER['SCRIPT_FILENAME']) === __FILE__;
    if ($__isDirectAuthRequest) {
        $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
        header('Content-Type: application/json');
        if ($__demoAction === 'check') {
            echo json_encode(['ok'=>true,'user'=>'demo','role'=>'admin']);
        } elseif ($__demoAction === 'logout') {
            echo json_encode(['ok'=>true]); // no-op — demo re-auths itself next request
        } else {
            echo json_encode(['ok'=>false,'error'=>'not available in the web demo']);
        }
        exit;
    }
    return; // included by another file — session valid, let it proceed
}

// users.json (the login list ITSELF) lives at the SHARED root, never per-user
// — you need it to know who's who before any per-user scoping makes sense.
$USERS_F = $PATHS['cockpit_data_root'] . '/users.json';

// ── Helpers ─────────────────────────────────────────────────────────────────

// ── "Keep me signed in" tokens (2026-09-16) ──────────────────────────────────
// A long random token per device, stored HASHED in the user's entry with an
// expiry and a label; the raw token is returned once at login and the native
// window keeps it in the OS keyring (libsecret). ?action=remember turns a valid
// token into a session; logout revokes the one it is given. Never written to
// logs. Expired entries are pruned whenever the user's entry is touched.
const AUTH_REMEMBER_DAYS = 90;
function auth_remember_hash(string $tok): string { return hash('sha256', $tok); }
function auth_remember_prune(array $u): array {
    $u['remember'] = array_values(array_filter((array)($u['remember'] ?? []), fn($r) => is_array($r) && (int)($r['exp'] ?? 0) > time()));
    if (!$u['remember']) unset($u['remember']);
    return $u;
}
function auth_remember_issue(array &$users, string $username, string $label): string {
    $tok = bin2hex(random_bytes(32));
    foreach ($users as &$u) {
        if (($u['username'] ?? '') !== $username) continue;
        $u = auth_remember_prune($u);
        $u['remember'][] = ['h' => auth_remember_hash($tok), 'exp' => time() + AUTH_REMEMBER_DAYS * 86400, 'label' => mb_substr($label, 0, 40), 'at' => time()];
        $u['remember'] = array_slice($u['remember'], -10);   // at most 10 devices
    }
    unset($u);
    return $tok;
}
function auth_remember_find(array $users, string $tok): ?array {
    $h = auth_remember_hash($tok);
    foreach ($users as $u) foreach ((array)($u['remember'] ?? []) as $r)
        if (is_array($r) && hash_equals((string)($r['h'] ?? ''), $h) && (int)($r['exp'] ?? 0) > time()) return $u;
    return null;
}
function auth_remember_revoke(array &$users, string $tok): void {
    $h = auth_remember_hash($tok);
    foreach ($users as &$u) {
        if (empty($u['remember'])) continue;
        $u['remember'] = array_values(array_filter((array)$u['remember'], fn($r) => !hash_equals((string)($r['h'] ?? ''), $h)));
        if (!$u['remember']) unset($u['remember']);
    }
    unset($u);
}
function auth_remember_start_session(array $found): void {
    session_regenerate_id(true);
    $_SESSION['cockpit_user'] = $found['username'];
    $_SESSION['cockpit_role'] = $found['role'] ?? 'viewer';
    $_SESSION['cockpit_id']   = $found['id'] ?? null;
    $_SESSION['cockpit_login_at'] = time();
}

function auth_load_users(string $f): array {
    if (!is_readable($f)) return [];
    $raw = file_get_contents($f);
    $d = json_decode($raw, true);
    $users = is_array($d) ? $d : [];
    // Self-heal: assign a stable short id to any entry that predates this field
    // (2026-07-02 — shown as "username (id)" in the UI so two accounts that
    // happen to share a display name are still distinguishable at a glance).
    $maxId = 0;
    foreach ($users as $u) $maxId = max($maxId, (int)($u['id'] ?? 0));
    $changed = false;
    foreach ($users as &$u) {
        if (empty($u['id'])) { $u['id'] = ++$maxId; $changed = true; }
    }
    unset($u);
    if ($changed) auth_save_users($f, $users);
    return $users;
}

function auth_save_users(string $f, array $users): void {
    $dir = dirname($f);
    if (!is_dir($dir)) @mkdir($dir, 0775, true);
    file_put_contents($f, json_encode($users, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), LOCK_EX);
    @chmod($f, 0660);
}

// Stand-alone edition (installer's "Stand-alone" choice, no account ever)
// writes this marker into cockpit_data root — its whole promise is zero
// network calls to our server, so anything that phones home must check it
// first. Full edition (default; also covers pre-unification installs that
// never wrote the marker) has it absent.
function auth_is_standalone_edition(): bool {
    global $_cockpit_data_root;
    return is_file(($_cockpit_data_root ?? '') . '/.edition_standalone');
}

// Anonymous install-funnel signal — no username, email, or IP in the payload.
// Best-effort only: short connect/total timeouts, every failure mode (curl
// missing, DNS down, server unreachable) is swallowed so this can never block
// or fail first-run setup. Full edition only — see auth_is_standalone_edition().
function ck_ping_setup_complete(): void { return;   // the open-source release never calls our servers
    if (auth_is_standalone_edition()) return;
    if (!function_exists('curl_init')) return;
    $ch = curl_init('https://cockpit.ruggi.site/api/setup_ping.php');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode(['event' => 'first_account_created', 'edition' => 'v2']),
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_TIMEOUT_MS     => 1500,
        CURLOPT_CONNECTTIMEOUT_MS => 800,
        CURLOPT_RETURNTRANSFER => true,
    ]);
    @curl_exec($ch);
    curl_close($ch);
}

// Fire cockpit_stop.sh in the background (redirected + backgrounded with `&`,
// so this returns immediately — does NOT block the login/logout response, and
// deliberately does NOT also start anything back up: the next user sees a
// clean stopped state and starts sessions themselves via the existing
// Start/Restart button. Mirrors the command session.php's 'stop' action uses.
function auth_stop_agent_sessions_bg(): void {
    global $PATHS;
    $stopScript = ($PATHS['home'] ?? '') . '/scripts/cockpit_stop.sh';
    if (!is_file($stopScript)) return;
    $owner = function_exists('cockpit_owner_user') ? cockpit_owner_user() : 'dario';
    $cmd = cockpit_as_owner() . escapeshellarg($stopScript) . ' > /dev/null 2>&1 &';
    @exec($cmd);
}

function auth_json(array $data): void {
    header('Content-Type: application/json');
    echo json_encode($data, JSON_UNESCAPED_UNICODE);
    exit;
}

function auth_needs_setup(string $f): bool {
    $users = auth_load_users($f);
    return empty($users);
}

function auth_is_valid(): bool {
    return !empty($_SESSION['cockpit_user']) && !empty($_SESSION['cockpit_role']);
}

function auth_current_user(): ?array {
    if (!auth_is_valid()) return null;
    return [
        'username' => $_SESSION['cockpit_user'],
        'role'     => $_SESSION['cockpit_role'],
    ];
}

// ── Direct access (action dispatch) ─────────────────────────────────────────

// Only dispatch auth actions when auth.php is the directly-requested script
$_auth_is_direct = (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === realpath(__FILE__));
$_auth_action = $_auth_is_direct ? ($_GET['action'] ?? ($_POST['action'] ?? '')) : '';

if ($_auth_action !== '') {
    $in = json_decode(file_get_contents('php://input'), true) ?: $_POST;

    // --- check: is session valid? ---
    if ($_auth_action === 'check') {
        if (auth_needs_setup($USERS_F)) {
            auth_json(['ok' => false, 'needs_setup' => true]);
        }
        if (auth_is_valid()) {
            auth_json(['ok' => true, 'user' => $_SESSION['cockpit_user'], 'role' => $_SESSION['cockpit_role'], 'id' => $_SESSION['cockpit_id'] ?? null]);
        }
        auth_json(['ok' => false]);
    }

    // --- setup: create first admin ---
    if ($_auth_action === 'setup') {
        $users = auth_load_users($USERS_F);
        if (!empty($users)) {
            auth_json(['ok' => false, 'error' => 'Setup already completed']);
        }
        $username = trim((string)($in['username'] ?? ''));
        $password = (string)($in['password'] ?? '');
        if (strlen($username) < 2 || strlen($username) > 32) {
            auth_json(['ok' => false, 'error' => 'Username must be 2-32 characters']);
        }
        if (strlen($password) < 6) {
            auth_json(['ok' => false, 'error' => 'Password must be at least 6 characters']);
        }
        // Full edition: the first local login on a machine IS the person's Cockpit
        // account name (Dario, 2026-09-19). The account step runs before this one
        // (first-run lets saas.php through), leaving the account file at the
        // shared root; its username is the only one accepted here, and the file
        // then moves into that user's own data folder. Extra local logins later
        // may use any name. Stand-alone: no account, any name.
        $_firstAcct = $PATHS['cockpit_data_root'] . '/saas_account.json';
        $_acctName = '';
        if (!auth_is_standalone_edition() && is_file($_firstAcct)) {
            $_a = json_decode((string)@file_get_contents($_firstAcct), true);
            $_acctName = is_array($_a) ? (string)($_a['username'] ?? '') : '';
        }
        if ($_acctName !== '' && strcasecmp($_acctName, $username) !== 0) {
            auth_json(['ok' => false, 'error' => 'The first login on this machine is your Cockpit account name: ' . $_acctName, 'account_username' => $_acctName]);
        }
        $newId = 1;
        foreach ($users as $u) $newId = max($newId, (int)($u['id'] ?? 0) + 1);
        $users[] = [
            'id'         => $newId,
            'username'   => $username,
            'hash'       => password_hash($password, PASSWORD_BCRYPT),
            'role'       => 'admin',
            'created_at' => date('c'),
        ];
        auth_save_users($USERS_F, $users);
        if ($_acctName !== '') {
            $_udir = $PATHS['cockpit_data_root'] . '/users/' . $username;
            @mkdir($_udir, 0775, true);
            foreach (['saas_account.json', 'accounts_roster.json'] as $_f) {
                if (is_file($PATHS['cockpit_data_root'] . '/' . $_f)) @rename($PATHS['cockpit_data_root'] . '/' . $_f, $_udir . '/' . $_f);
            }
        }
        $_SESSION['cockpit_user'] = $username;
        $_SESSION['cockpit_role'] = 'admin';
        $_SESSION['cockpit_id']   = $newId;
        $_SESSION['cockpit_login_at'] = time();

        // Anonymous, best-effort funnel signal — no username/email/IP payload,
        // just "a first account got created". No-ops entirely on the
        // stand-alone edition (see ck_ping_setup_complete()).
        ck_ping_setup_complete();

        auth_json(['ok' => true, 'user' => $username, 'role' => 'admin', 'id' => $newId]);
    }

    // --- login ---
    if ($_auth_action === 'login') {
        if (auth_needs_setup($USERS_F)) {
            auth_json(['ok' => false, 'error' => 'No users configured — run setup first']);
        }
        $username = trim((string)($in['username'] ?? ''));
        $password = (string)($in['password'] ?? '');
        if (!$username || !$password) {
            auth_json(['ok' => false, 'error' => 'Missing username or password']);
        }
        $users = auth_load_users($USERS_F);
        $found = null;
        foreach ($users as $u) {
            if (($u['username'] ?? '') === $username) { $found = $u; break; }
        }
        if (!$found || !password_verify($password, $found['hash'] ?? '')) {
            usleep(random_int(200000, 500000));
            auth_json(['ok' => false, 'error' => 'Invalid credentials']);
        }
        // Different local user logging in → tear down whatever agent sessions
        // were left running (data folders are per-user now; live tmux agent
        // sessions are still machine-wide, so don't let the incoming user land
        // in the middle of the outgoing user's live conversation). Fire-and-
        // forget, non-blocking — the new user gets a clean "sessions off" state
        // and clicks Start themselves (that's the "ask before start" the user wanted).
        if (!empty($_SESSION['cockpit_user']) && $_SESSION['cockpit_user'] !== $found['username']) {
            auth_stop_agent_sessions_bg();
        }
        auth_remember_start_session($found);
        $out = ['ok' => true, 'user' => $found['username'], 'role' => $found['role'] ?? 'viewer', 'id' => $found['id'] ?? null];
        if (!empty($in['remember'])) {
            $out['remember_token'] = auth_remember_issue($users, $found['username'], (string)($in['device'] ?? 'this computer'));
            auth_save_users($USERS_F, $users);
        }
        auth_json($out);
    }

    // --- relay_token: authorise THIS machine's Everywhere poller ---
    // The relay poller runs session-less in the background and used to need the
    // account password in a plaintext file (cockpit_data/relay_poller_credentials.json)
    // to call bridge.php. Instead it now gets a remember token minted here, from an
    // already signed-in session, and written where the poller reads it. The raw
    // token is never echoed back to the browser — it goes straight to the file.
    if ($_auth_action === 'relay_token' || $_auth_action === 'relay_token_revoke') {
        auth_require_writer();
        $users = auth_load_users($USERS_F);
        $me    = (string)($_SESSION['cockpit_user'] ?? '');
        $file  = rtrim((string)$PATHS['cockpit_data'], '/') . '/relay_poller_token.json';
        if ($_auth_action === 'relay_token_revoke') {
            $old = is_readable($file) ? (json_decode((string)file_get_contents($file), true) ?: []) : [];
            if (!empty($old['token']) && preg_match('/^[a-f0-9]{64}$/', (string)$old['token'])) {
                auth_remember_revoke($users, (string)$old['token']);
                auth_save_users($USERS_F, $users);
            }
            @unlink($file);
            auth_json(['ok' => true, 'revoked' => true]);
        }
        $tok = auth_remember_issue($users, $me, 'Everywhere relay');
        auth_save_users($USERS_F, $users);
        @mkdir(dirname($file), 0775, true);
        $wrote = @file_put_contents($file, json_encode(
            ['token' => $tok, 'user' => $me, 'issued_at' => gmdate('c')], JSON_PRETTY_PRINT));
        if ($wrote === false) auth_json(['ok' => false, 'error' => 'could not write ' . $file]);
        // 0640, not 0600: the web user writes this file but the RELAY POLLER runs as
        // the person who owns the data dir, and that dir is setgid to their group —
        // with 0600 the poller could not read its own token.
        @chmod($file, 0640);
        auth_json(['ok' => true, 'user' => $me, 'file' => $file,
                   'expires_at' => gmdate('c', time() + AUTH_REMEMBER_DAYS * 86400)]);
    }

    // --- remember: a keyring-held token → a session (no password) ---
    if ($_auth_action === 'remember') {
        $tok = (string)($in['token'] ?? '');
        if (!preg_match('/^[a-f0-9]{64}$/', $tok)) auth_json(['ok' => false, 'error' => 'bad token']);
        $users = auth_load_users($USERS_F);
        $found = auth_remember_find($users, $tok);
        if (!$found) { usleep(random_int(100000, 300000)); auth_json(['ok' => false, 'error' => 'expired']); }
        if (!empty($_SESSION['cockpit_user']) && $_SESSION['cockpit_user'] !== $found['username']) auth_stop_agent_sessions_bg();
        auth_remember_start_session($found);
        auth_json(['ok' => true, 'user' => $found['username'], 'role' => $found['role'] ?? 'viewer', 'id' => $found['id'] ?? null]);
    }

    // --- logout ---
    if ($_auth_action === 'logout') {
        auth_stop_agent_sessions_bg();
        $tok = (string)($in['remember_token'] ?? '');
        if (preg_match('/^[a-f0-9]{64}$/', $tok)) { $users = auth_load_users($USERS_F); auth_remember_revoke($users, $tok); auth_save_users($USERS_F, $users); }
        $_SESSION = [];
        if (ini_get('session.use_cookies')) {
            $p = session_get_cookie_params();
            setcookie(session_name(), '', time() - 42000, $p['path'], $p['domain'], $p['secure'], $p['httponly']);
        }
        session_destroy();
        auth_json(['ok' => true]);
    }

    // --- change_password ---
    if ($_auth_action === 'change_password') {
        if (!auth_is_valid()) auth_json(['ok' => false, 'error' => 'Not authenticated']);
        $current = (string)($in['current'] ?? '');
        $newPass = (string)($in['new_password'] ?? '');
        if (strlen($newPass) < 6) auth_json(['ok' => false, 'error' => 'New password must be at least 6 characters']);
        $users = auth_load_users($USERS_F);
        $idx = null;
        foreach ($users as $i => $u) {
            if (($u['username'] ?? '') === $_SESSION['cockpit_user']) { $idx = $i; break; }
        }
        if ($idx === null) auth_json(['ok' => false, 'error' => 'User not found']);
        if (!password_verify($current, $users[$idx]['hash'] ?? '')) {
            auth_json(['ok' => false, 'error' => 'Current password incorrect']);
        }
        $users[$idx]['hash'] = password_hash($newPass, PASSWORD_BCRYPT);
        auth_save_users($USERS_F, $users);
        auth_json(['ok' => true]);
    }

    // --- list_users (admin only) ---
    if ($_auth_action === 'list_users') {
        if (!auth_is_valid() || $_SESSION['cockpit_role'] !== 'admin') {
            auth_json(['ok' => false, 'error' => 'Admin required']);
        }
        $users = auth_load_users($USERS_F);
        $list = [];
        foreach ($users as $u) {
            $list[] = ['id' => $u['id'] ?? null, 'username' => $u['username'], 'role' => $u['role'] ?? 'viewer', 'created_at' => $u['created_at'] ?? ''];
        }
        auth_json(['ok' => true, 'users' => $list]);
    }

    // --- add_user (admin only) ---
    if ($_auth_action === 'add_user') {
        if (!auth_is_valid() || $_SESSION['cockpit_role'] !== 'admin') {
            auth_json(['ok' => false, 'error' => 'Admin required']);
        }
        $username = trim((string)($in['username'] ?? ''));
        $password = (string)($in['password'] ?? '');
        $role     = in_array($in['role'] ?? '', ['admin', 'normal', 'viewer']) ? $in['role'] : 'viewer';
        if (strlen($username) < 2 || strlen($username) > 32) auth_json(['ok' => false, 'error' => 'Username must be 2-32 characters']);
        if (strlen($password) < 6) auth_json(['ok' => false, 'error' => 'Password must be at least 6 characters']);
        $users = auth_load_users($USERS_F);
        foreach ($users as $u) {
            if (($u['username'] ?? '') === $username) auth_json(['ok' => false, 'error' => 'Username already exists']);
        }
        $newId = 1;
        foreach ($users as $u) $newId = max($newId, (int)($u['id'] ?? 0) + 1);
        $users[] = [
            'id'         => $newId,
            'username'   => $username,
            'hash'       => password_hash($password, PASSWORD_BCRYPT),
            'role'       => $role,
            'created_at' => date('c'),
        ];
        auth_save_users($USERS_F, $users);
        auth_json(['ok' => true, 'id' => $newId]);
    }

    // --- edit_user (admin only) ---
    if ($_auth_action === 'edit_user') {
        if (!auth_is_valid() || $_SESSION['cockpit_role'] !== 'admin') {
            auth_json(['ok' => false, 'error' => 'Admin required']);
        }
        $target   = trim((string)($in['target'] ?? ''));
        $newUser  = trim((string)($in['new_username'] ?? ''));
        $newPass  = (string)($in['new_password'] ?? '');
        $newRole  = (string)($in['new_role'] ?? '');
        if (!$target) auth_json(['ok' => false, 'error' => 'Missing target username']);
        $users = auth_load_users($USERS_F);
        $idx = null;
        foreach ($users as $i => $u) {
            if (($u['username'] ?? '') === $target) { $idx = $i; break; }
        }
        if ($idx === null) auth_json(['ok' => false, 'error' => 'User not found']);
        if ($newUser !== '' && $newUser !== $target) {
            if (strlen($newUser) < 2 || strlen($newUser) > 32) auth_json(['ok' => false, 'error' => 'Username must be 2-32 characters']);
            foreach ($users as $u) {
                if (($u['username'] ?? '') === $newUser) auth_json(['ok' => false, 'error' => 'Username already exists']);
            }
            $users[$idx]['username'] = $newUser;
            if ($target === $_SESSION['cockpit_user']) $_SESSION['cockpit_user'] = $newUser;
        }
        if ($newPass !== '') {
            if (strlen($newPass) < 6) auth_json(['ok' => false, 'error' => 'Password must be at least 6 characters']);
            $users[$idx]['hash'] = password_hash($newPass, PASSWORD_BCRYPT);
        }
        if ($newRole !== '' && in_array($newRole, ['admin', 'normal', 'viewer'])) {
            if ($target === $_SESSION['cockpit_user'] && $newRole !== 'admin') {
                auth_json(['ok' => false, 'error' => 'Cannot demote yourself']);
            }
            $users[$idx]['role'] = $newRole;
        }
        auth_save_users($USERS_F, $users);
        auth_json(['ok' => true]);
    }

    // --- remove_user (admin only, can't remove self) ---
    if ($_auth_action === 'remove_user') {
        if (!auth_is_valid() || $_SESSION['cockpit_role'] !== 'admin') {
            auth_json(['ok' => false, 'error' => 'Admin required']);
        }
        $username = trim((string)($in['username'] ?? ''));
        if ($username === $_SESSION['cockpit_user']) auth_json(['ok' => false, 'error' => 'Cannot remove yourself']);
        $users = auth_load_users($USERS_F);
        $newUsers = [];
        $removed = false;
        foreach ($users as $u) {
            if (($u['username'] ?? '') === $username) { $removed = true; continue; }
            $newUsers[] = $u;
        }
        if (!$removed) auth_json(['ok' => false, 'error' => 'User not found']);
        auth_save_users($USERS_F, $newUsers);
        auth_json(['ok' => true]);
    }

    // Unknown action when called directly
    auth_json(['ok' => false, 'error' => 'Unknown auth action']);
}

function auth_require_admin(): void {
    if (!auth_is_valid() || ($_SESSION['cockpit_role'] ?? '') !== 'admin') {
        http_response_code(403);
        header('Content-Type: application/json');
        echo json_encode(['ok' => false, 'error' => 'Admin access required'], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

function auth_require_writer(): void {
    if (!auth_is_valid() || ($_SESSION['cockpit_role'] ?? '') === 'viewer') {
        http_response_code(403);
        header('Content-Type: application/json');
        echo json_encode(['ok' => false, 'error' => 'Write access denied for viewers'], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

// ── Guard mode (included by another file) ───────────────────────────────────
// If users.json is empty (no setup done), allow access so first-run works.
// Once at least one user exists, require valid session.

if (!auth_needs_setup($USERS_F) && !auth_is_valid()) {
    http_response_code(401);
    header('Content-Type: application/json');
    echo json_encode(['ok' => false, 'error' => 'Authentication required'], JSON_UNESCAPED_UNICODE);
    exit;
}
