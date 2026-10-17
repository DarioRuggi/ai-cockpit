<?php
// =============================================================================
// compat_check.php — Phase 6 helper: resolve a marketplace item's portability
// metadata against THIS machine, so the marketplace UI can show a Protanopia-
// safe Ready / Needs-setup / Not-supported badge before downloading.
//
//   POST JSON: { requirements?, compatibility?, alternatives?, origin? }
//        or:   { items: [ {requirements,…}, … ] }   (batch)
//   → { ok, compat:{status,reason,missing,badge}, platform }      (single)
//   → { ok, compat:[ … ], platform }                              (batch)
//
// Read-only; touches nothing. Reuses cockpit_object_compat() (compat.php).
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/compat.php';
require_once __DIR__ . '/auth.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

$in = json_decode((string)file_get_contents('php://input'), true) ?: [];

if (isset($in['items']) && is_array($in['items'])) {
    $out = [];
    foreach ($in['items'] as $obj) {
        $out[] = cockpit_object_compat(is_array($obj) ? $obj : []);
    }
    echo json_encode(['ok'=>true, 'compat'=>$out, 'platform'=>cockpit_platform_profile()], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode([
    'ok'       => true,
    'compat'   => cockpit_object_compat($in),
    'platform' => cockpit_platform_profile(),
], JSON_UNESCAPED_UNICODE);
