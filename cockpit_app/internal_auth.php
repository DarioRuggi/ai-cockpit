<?php
// =============================================================================
// internal_auth.php — lets the agent loop call a few of Cockpit's own pages without a browser login.
//
// The markers an agent writes (%%FETCH:url%%, %%SEARCH:terms%%, %%WORKER:..%%, %%TOOL:..%%, %%PROPOSE:..%%) are carried out by the loop calling
// search.php, workers.php, tools.php and library.php over loopback. Those calls carry no session, so every one was answered "Authentication
// required" and the markers never worked (found 2026-10-06 by curling the four pages as the loop does).
//
// A call is accepted as the named person when ALL of these hold:
//   * it comes from this machine (REMOTE_ADDR is loopback) and has not passed through a proxy (no X-Forwarded-For / Forwarded / X-Real-IP);
//   * it carries X-Cockpit-Internal equal to the secret in <cockpit_data>/internal_key (0640, the owner's group: the same arrangement as the
//     supervisor's token), compared in constant time;
//   * it asks for exactly one of the (page, action) pairs below, and nothing else on the site;
//   * X-Cockpit-User names a person who exists in users.json; their role is the role they have there (a viewer stays a viewer).
// The key is created by the agent loop (never by the web server), and only the loop and the web server's account can read it.
// =============================================================================

/** The only pages and actions an internal call may reach. */
function ck_internal_allowed(): array {
    return [
        'search.php'  => ['search', 'fetch'],
        'workers.php' => ['models', 'invoke'],
        'power.php'   => ['run', 'list'],
        'tools.php'   => ['presets', 'run'],
        'library.php' => ['proposal_add'],
    ];
}

/**
 * @param array  $server   $_SERVER
 * @param array  $get      $_GET
 * @param string $body     the raw request body (JSON posts carry their action there)
 * @param string $dataRoot the shared cockpit_data folder (holds internal_key and users.json)
 * @return array|null      ['user' => login, 'role' => role] when the call is accepted
 */
function ck_internal_login(array $server, array $get, string $body, string $dataRoot): ?array {
    $hdr = (string)($server['HTTP_X_COCKPIT_INTERNAL'] ?? '');
    if ($hdr === '') return null;
    if (!in_array((string)($server['REMOTE_ADDR'] ?? ''), ['127.0.0.1', '::1', '::ffff:127.0.0.1'], true)) return null;
    foreach (['HTTP_X_FORWARDED_FOR', 'HTTP_FORWARDED', 'HTTP_X_REAL_IP', 'HTTP_X_FORWARDED_HOST'] as $h) if (!empty($server[$h])) return null;
    $keyFile = rtrim($dataRoot, '/') . '/internal_key';
    $key = is_readable($keyFile) ? trim((string)@file_get_contents($keyFile)) : '';
    if (strlen($key) < 32 || !hash_equals($key, $hdr)) return null;
    $script = basename((string)($server['SCRIPT_FILENAME'] ?? ''));
    $allowed = ck_internal_allowed();
    if (!isset($allowed[$script])) return null;
    // Pages differ on whether the query or the body names the action, so when both do they must agree: nothing is approved on one and run as the other.
    $qa = (string)($get['action'] ?? ''); $ba = '';
    if ($body !== '') { $j = json_decode($body, true); if (is_array($j)) $ba = (string)($j['action'] ?? ''); }
    if ($qa !== '' && $ba !== '' && $qa !== $ba) return null;
    $action = $qa !== '' ? $qa : $ba;
    if (!in_array($action, $allowed[$script], true)) return null;
    $login = (string)($server['HTTP_X_COCKPIT_USER'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_-]{1,64}$/', $login)) return null;
    $users = json_decode((string)@file_get_contents(rtrim($dataRoot, '/') . '/users.json'), true);
    if (!is_array($users)) return null;
    foreach ($users as $u) {
        if (is_array($u) && ($u['username'] ?? null) === $login) return ['user' => $login, 'role' => (string)($u['role'] ?? 'viewer')];
    }
    return null;
}
