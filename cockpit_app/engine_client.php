<?php
// =============================================================================
// engine_client.php — talks to the native engine's service (aicengine serve, hosted by the process supervisor as service cockpit_engine) for the
// file window (fm.php) and the command window (cmd.php). The engine runs as the OWNER of this Cockpit, does every file action with confinement
// and every command under the kernel's Landlock sandbox; this file only decides WHO is asking and WHICH zones they may see:
//
//   public     <their projects root>/Public      read-write  (their own folder; everything works there)
//   projects   <their projects root>             read-only   (look at and copy out of)
//   <others>   fm_areas.json in the shared data folder, set by an admin; read-only; the engine refuses any that this account does not own
//
// Socket and token: <cockpit_data root>/supervisor/engine.sock and engine_token (0660 / 0640, the owner's group: the web account reaches them the
// same way it reaches the supervisor's own socket).
// =============================================================================
require_once __DIR__ . '/session_backend.php';

function ck_engine_dir(): string { return ck_sup_dir(); }

/** One request to the engine service. Returns the decoded reply, or null when it cannot be reached. */
function ck_engine_call(array $req, float $timeout = 30.0): ?array {
    $dir = ck_engine_dir();
    $token = is_readable($dir . '/engine_token') ? trim((string)@file_get_contents($dir . '/engine_token')) : '';
    if ($token === '' || !file_exists($dir . '/engine.sock')) return null;
    $fp = @stream_socket_client('unix://' . $dir . '/engine.sock', $en, $es, 3.0);
    if (!$fp) return null;
    stream_set_timeout($fp, max(1, (int)ceil($timeout)));
    $line = json_encode(['token' => $token] + $req, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
    $left = strlen($line);
    while ($left > 0) { $w = fwrite($fp, $line); if ($w === false || $w === 0) { fclose($fp); return null; } $line = substr($line, $w); $left -= $w; }
    $resp = '';
    while (($chunk = fgets($fp)) !== false) { $resp .= $chunk; if (substr($chunk, -1) === "\n") break; }
    fclose($fp);
    $j = json_decode(trim($resp), true);
    return is_array($j) ? $j : null;
}

function ck_fm_user(): string {
    global $PATHS;
    return (string)($PATHS['cockpit_user'] ?? ($_SESSION['cockpit_user'] ?? ''));
}

function ck_fm_areas_file(): string { return ck_sup_data_root() . '/fm_areas.json'; }

/** [{name, path}] extra read-only areas an admin added. */
function ck_fm_extra_areas(): array {
    $j = json_decode((string)@file_get_contents(ck_fm_areas_file()), true);
    $out = [];
    foreach ((is_array($j) ? $j : []) as $a) {
        if (!is_array($a) || !preg_match('/^[a-z][a-z0-9_]{0,23}$/', (string)($a['name'] ?? '')) || ($a['name'] === 'public' || $a['name'] === 'projects')) continue;
        $p = (string)($a['path'] ?? '');
        if ($p === '' || $p[0] !== '/' || strpos($p, "\0") !== false) continue;
        $out[] = ['name' => $a['name'], 'path' => $p];
    }
    return $out;
}

/** The zones of the person asking: Public (read-write) first, then read-only areas. */
function ck_fm_zones(): array {
    global $PATHS;
    $root = rtrim((string)($PATHS['projects_root'] ?? ''), '/');
    if ($root === '') return [];
    $z = [['name' => 'public', 'path' => $root . '/Public', 'rw' => true], ['name' => 'projects', 'path' => $root, 'rw' => false]];
    foreach (ck_fm_extra_areas() as $a) $z[] = ['name' => $a['name'], 'path' => $a['path'], 'rw' => false];
    return $z;
}

function ck_fm_label(string $name): string {
    return ['public' => 'Public', 'projects' => 'Projects'][$name] ?? ucfirst(str_replace('_', ' ', $name));
}

/** A request for the engine with the caller's zones, name and the audit file filled in. */
function ck_fm_req(string $service, string $sub, array $fields): array {
    return ['op' => $service, 'fsop' => $sub, 'zones' => ck_fm_zones(), 'user' => ck_fm_user(), 'audit' => ck_sup_data_root() . '/fm_audit.jsonl'] + $fields;
}
