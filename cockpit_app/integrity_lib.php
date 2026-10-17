<?php
// integrity_lib.php — manifest reading and build_id computation, shared by the
// integrity.php endpoint and saas.php (which attaches the id to every request
// to ruggi.site). No output, no auth: pure functions.
require_once __DIR__ . '/paths.php';

// Mirror of build_integrity.sh's exclusions — files the install owns or the
// user may edit are never reported as "changed".
const INTEGRITY_SKIP = ['integrity.json', 'MANIFEST.txt', 'config.php', 'paths.json', '.edition'];

function integrity_manifest(): ?array {
    $f = __DIR__ . '/integrity.json';
    if (!is_readable($f)) return null;
    $m = json_decode((string)file_get_contents($f), true);
    return (is_array($m) && isset($m['files']) && is_array($m['files'])) ? $m : null;
}
/** Where the shipped scripts live: scripts/ beside web/ in an extracted bundle or
 *  docker image; ~/scripts of the login user on an installed machine. */
function integrity_scripts_dir(): string {
    global $PATHS;
    $sib = dirname(__DIR__) . '/scripts';
    if (is_file($sib . '/agent_loop.sh')) return $sib;
    $home = (string)($PATHS['home'] ?? '');
    if ($home === '' && function_exists('cockpit_owner_user')) { $pw = @posix_getpwnam(cockpit_owner_user()); $home = $pw['dir'] ?? ''; }
    return rtrim($home, '/') . '/scripts';
}
/** Recompute the build_id from the files on disk, the way the build script does. */
function integrity_compute(array $m, array &$changed, array &$missing): string {
    $lines = [];
    foreach ($m['files'] as $rel => $sha) {
        if (in_array(basename($rel), INTEGRITY_SKIP, true)) continue;
        $p = str_starts_with($rel, 'scripts/') ? integrity_scripts_dir() . '/' . substr($rel, 8) : __DIR__ . '/' . $rel;
        if (!is_file($p)) { $missing[] = $rel; continue; }
        $h = hash_file('sha256', $p);
        if ($h !== $sha) $changed[] = $rel;
        $lines[] = $h . '  ' . $rel . "\n";
    }
    // the build script hashes the sorted "sha  path" list (LC_ALL=C order)
    usort($lines, fn($a, $b) => strcmp(substr($a, 66), substr($b, 66)));
    return hash('sha256', implode('', $lines));
}
/** The id this install presents to ruggi.site: computed from disk, never read from the manifest. */
function integrity_build_id(): string {
    $m = integrity_manifest(); if (!$m) return '';
    $c = []; $x = [];
    return integrity_compute($m, $c, $x);
}
function integrity_bundle_kept(): ?string {
    global $PATHS;
    // the installer keeps the bundle at the SHARED root (machine-wide); with a
    // local user signed in, cockpit_data is that user's folder — the report
    // said "no kept bundle" on the Fedora VM while it sat one level up
    $cd = rtrim((string)($PATHS['cockpit_data'] ?? ''), '/');
    $cr = rtrim((string)($PATHS['cockpit_data_root'] ?? $cd), '/');
    foreach ([$cr . '/install_src/cockpit_install.tar.gz', $cd . '/install_src/cockpit_install.tar.gz',
              $cr . '/install_src/cockpit_app.tar.gz', $cd . '/install_src/cockpit_app.tar.gz',
              dirname(__DIR__) . '/dist/cockpit_v2.tar.gz', dirname(__DIR__) . '/dist/cockpit_v1.tar.gz'] as $p) if (is_file($p)) return $p;
    return null;
}
function integrity_seen_file(): string {
    global $PATHS;
    return rtrim((string)($PATHS['cockpit_data'] ?? sys_get_temp_dir()), '/') . '/first_use_seen.json';
}

