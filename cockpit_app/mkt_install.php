<?php
// =============================================================================
// mkt_install.php — Phase 6: install a downloaded marketplace object into the
// matching LOCAL store, so it shows up in the Skills / Tools / Capabilities
// panels instead of just landing as a file.
//
//   POST JSON: { kind, slug, content_b64 }
//   → { ok, kind, slug, installed_to } | { ok:false, error }
//
// JSON kinds (tool/skill/capability) are validated + written into their store.
// Other kinds (theme/prompt/zip/folder) fall back to a downloads folder with a
// hint (full per-kind import is a follow-up). Additive: never overwrites a
// built-in; user objects live in cockpit_data.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/kinds_lib.php';

ed_require_saas();   // 404 in v1/demo, pass-through in v2

header('Content-Type: application/json');
header('Cache-Control: no-store');

$in   = json_decode((string)file_get_contents('php://input'), true) ?: [];
$kind = (string)($in['kind'] ?? '');
$slug = preg_replace('/[^a-z0-9_\-]/', '', strtolower((string)($in['slug'] ?? '')));
$raw  = base64_decode((string)($in['content_b64'] ?? ''), true);

if ($slug === '')          { echo json_encode(['ok'=>false,'error'=>'bad slug']); exit; }
if ($raw === false || $raw === '') { echo json_encode(['ok'=>false,'error'=>'empty payload']); exit; }

$CD = $PATHS['cockpit_data'];
$ok_json = function (string $s) { $d = json_decode($s, true); return is_array($d) ? $d : null; };

function _w(string $path, string $data): bool {
    @mkdir(dirname($path), 0775, true);
    return @file_put_contents($path, $data) !== false;
}

switch ($kind) {
    case 'tool': {
        $def = $ok_json($raw);
        if ($def === null) { echo json_encode(['ok'=>false,'error'=>'tool is not valid JSON']); exit; }
        $def['id'] = $slug; $def['custom'] = true;           // user tool, unique id
        $dest = $CD . '/tools/' . $slug . '.json';
        if (!_w($dest, json_encode($def, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)))
            { echo json_encode(['ok'=>false,'error'=>'write failed']); exit; }
        echo json_encode(['ok'=>true,'kind'=>$kind,'slug'=>$slug,'installed_to'=>'Tools']); exit;
    }
    case 'kind': {
        // A project kind: the same validator as the wizard and the import (kinds_lib.php). Its tools, if it carries any, are registered with it; the
        // marketplace screens what is published, and the install click is the person's consent, so the commands are listed in the answer.
        $def = $ok_json($raw);
        if ($def === null) { echo json_encode(['ok'=>false,'error'=>'kind is not valid JSON']); exit; }
        $def['id'] = $slug; $err = '';
        $k = kind_validate($def, $err);
        if ($k === null) { echo json_encode(['ok'=>false,'error'=>$err]); exit; }
        if (!empty($k['tool_defs'])) { $terr = kind_register_tools($k['tool_defs'], $k['id']); if ($terr !== null) { echo json_encode(['ok'=>false,'error'=>$terr]); exit; } }
        if (!kind_user_save($k)) { echo json_encode(['ok'=>false,'error'=>'write failed']); exit; }
        echo json_encode(['ok'=>true,'kind'=>$kind,'slug'=>$slug,'installed_to'=>'Project kinds','tools'=>array_map(fn($t) => $t['id'], $k['tool_defs'] ?? [])]); exit;
    }
    case 'capability': {
        $def = $ok_json($raw);
        if ($def === null) { echo json_encode(['ok'=>false,'error'=>'capability is not valid JSON']); exit; }
        $def['id'] = $slug;
        $dest = $CD . '/capabilities/' . $slug . '/CAP.json';
        if (!_w($dest, json_encode($def, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)))
            { echo json_encode(['ok'=>false,'error'=>'write failed']); exit; }
        echo json_encode(['ok'=>true,'kind'=>$kind,'slug'=>$slug,'installed_to'=>'Capabilities']); exit;
    }
    case 'user_combo': {
        // User-authored combo, downloaded from the Marketplace — plain JSON,
        // merges into the SAME store as locally-authored combos
        // (combos_user.json). Never routed through the admin-only encrypted
        // combos_store.enc pipeline — see COCKPIT_COMBO_PROTECTION_DESIGN.md §7.
        $def = $ok_json($raw);
        if ($def === null) { echo json_encode(['ok'=>false,'error'=>'combo is not valid JSON']); exit; }
        $def['id'] = $slug;
        // Marketplace linkage: content_id (for usage-reporting on run) + author
        // nickname (attribution). Own-authored combos publish via combos.php's
        // user_save instead, which never sets these — only a DOWNLOAD does.
        if (!empty($in['content_id'])) $def['_content_id'] = (int)$in['content_id'];
        if (!empty($in['author']))     $def['_author']      = (string)$in['author'];
        $dest = $CD . '/combos_user.json';
        $reg = is_readable($dest) ? $ok_json((string)file_get_contents($dest)) : null;
        if (!is_array($reg)) $reg = ['version'=>2,'combos'=>[]];
        $byId = [];
        foreach (($reg['combos'] ?? []) as $c) if (($c['id'] ?? '') !== '') $byId[$c['id']] = $c;
        $byId[$slug] = $def;
        $reg['combos'] = array_values($byId);
        if (!_w($dest, json_encode($reg, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)))
            { echo json_encode(['ok'=>false,'error'=>'write failed']); exit; }
        echo json_encode(['ok'=>true,'kind'=>$kind,'slug'=>$slug,'installed_to'=>'Power Combos (Tier 0)']); exit;
    }
    case 'skill': {
        // JSON skill → <slug>.json in the skills store. (Folder/zip skills are a
        // follow-up: they need unzip into <slug>/SKILL.md.)
        $def = $ok_json($raw);
        if ($def === null) { echo json_encode(['ok'=>false,'error'=>'skill is not valid JSON (folder/zip skills not yet auto-installed)']); exit; }
        $def['id'] = $slug;
        $dest = $CD . '/skills/' . $slug . '.json';
        if (!_w($dest, json_encode($def, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)))
            { echo json_encode(['ok'=>false,'error'=>'write failed']); exit; }
        echo json_encode(['ok'=>true,'kind'=>$kind,'slug'=>$slug,'installed_to'=>'Skills']); exit;
    }
    default: {
        // theme / prompt / tool_preset / worker_card / pipeline / unknown →
        // save to a downloads folder for manual import (per-kind = follow-up).
        $dest = $CD . '/marketplace_downloads/' . $slug . '-' . $kind;
        if (!_w($dest, $raw)) { echo json_encode(['ok'=>false,'error'=>'write failed']); exit; }
        echo json_encode(['ok'=>true,'kind'=>$kind,'slug'=>$slug,
                          'installed_to'=>'marketplace_downloads (import manually)']); exit;
    }
}
