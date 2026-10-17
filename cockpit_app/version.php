<?php
require_once __DIR__ . "/auth.php";
// =============================================================================
// version.php — Returns the cockpit version string.
//
// Resolution order:
//   1. __DIR__ . '/VERSION'  (file written by build_cockpit_tarball.sh)
//   2. Hardcoded fallback below
//
// Output: JSON  { "ok": true, "version": "1.0.0", "source": "file"|"fallback" }
// =============================================================================

header('Content-Type: application/json');
header('Cache-Control: no-store');   // was max-age=300: the window kept showing the previous build number after a deploy

$FALLBACK_VERSION = '2.0.0';
$VERSION_FILE     = __DIR__ . '/VERSION';
// Build number (sequential, stamped by rebuild_tarballs into integrity.json).
$_build = 0; $_im = @json_decode((string)@file_get_contents(__DIR__ . '/integrity.json'), true);
if (is_array($_im) && isset($_im['build'])) $_build = (int)$_im['build'];
// Release-candidate number, stamped from Installs/RC_NUMBER at build time.
// Absent (the normal case) means this build is not a declared candidate — the
// app shows nothing rather than inventing a stage it has not reached.
$_rc = (is_array($_im) && !empty($_im['rc'])) ? (int)$_im['rc'] : 0;
// Release stage, stamped from Installs/STAGE at build time: 'beta',
// 'pre-release' or '' (a final release shows no badge). The badge is a fact
// about this build, so every edition can read it -- Stand-alone has no cloud
// account to ask, which is why it never showed one before.
$_stage = ''; 
if (is_array($_im) && !empty($_im['stage'])) {
    $_s = (string)$_im['stage'];
    if ($_s === 'beta' || $_s === 'pre-release') $_stage = $_s;
}

if (is_file($VERSION_FILE)) {
    $v = trim((string)file_get_contents($VERSION_FILE));
    if ($v !== '' && strlen($v) < 32) {
        // `version` is what to SHOW: Stand-alone displays one major lower, because
        // the published scheme steps majors by two (odd Stand-alone, even Full).
        // `version_internal` is the real one every machine-readable thing uses --
        // integrity.json, official_builds.json, telemetry, the update check --
        // so a caller that needs the truth is never left guessing which it got.
        echo json_encode(['ok'=>true, 'version'=>ed_display_version($v), 'version_internal'=>$v,
                          'build'=>$_build, 'rc'=>$_rc, 'stage'=>$_stage, 'source'=>'file'], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

echo json_encode(['ok'=>true, 'version'=>ed_display_version($FALLBACK_VERSION), 'version_internal'=>$FALLBACK_VERSION,
                  'build'=>$_build, 'rc'=>$_rc, 'stage'=>$_stage, 'source'=>'fallback'], JSON_UNESCAPED_UNICODE);
