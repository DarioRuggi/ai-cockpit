<?php
// =============================================================================
// combos.php — Power Combos engine (TIER 0), non-streaming JSON endpoint.
//   GET  ?action=list  → registry + per-combo availability.
//   POST ?action=run   → {combo_id, prompt, project?, chat?, rag_context?}.
// Shared logic lives in combos_core.php (also used by combos_stream.php).
// Live token streaming: combos_stream.php (SSE).
// =============================================================================
require_once __DIR__ . '/combos_core.php';

// Combos can run several models back-to-back; never let PHP kill mid-run.
@set_time_limit(0);
@ini_set('max_execution_time', '0');

// ── HTTP entry (CLI bypasses this so unit tests skip auth) ───────────────────
if (php_sapi_name() !== 'cli') {
    require_once __DIR__ . '/auth.php';   // top-level guard: 401 if not logged in
    ed_gate_or_exit('combos');            // HTTP-only; CLI lib use unaffected. demo: described-modal
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $action = $_GET['action'] ?? 'list';
    // Explicit per-column backend override for the dual-mode two-column
    // picker — ?backend=ollama|localai. Anything else (missing, typo, an
    // unsupported provider name) falls through to the normal
    // combos_active_backend() default, same as before this existed.
    $backendOverride = $_GET['backend'] ?? null;
    if (!in_array($backendOverride, ['ollama', 'localai'], true)) $backendOverride = null;
    if (in_array($action, ['list', 'run'], true) && !combos_active_backend() && $backendOverride === null) {
        echo json_encode(['ok' => false, 'error' => 'Power Combos work with Ollama or LocalAI as Card 3 — switch back in Supplier Slots to use them.']);
        exit;
    }
    if ($action === 'list') {
        // combos_list() already returns {ok, combos:[...], locked:[...]} directly.
        echo json_encode(combos_list($backendOverride), JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
        exit;
    }
    // Raw installed-Ollama-models list — used by the Marketplace to show
    // "needed vs. installed" BEFORE downloading a combo, not just after.
    if ($action === 'installed_models') {
        echo json_encode(['ok'=>true, 'models'=>array_keys(combos_installed_models($backendOverride))]);
        exit;
    }
    if ($action === 'run') {
        $in = json_decode((string)file_get_contents('php://input'), true) ?: [];
        $id     = trim((string)($in['combo_id'] ?? ''));
        $prompt = (string)($in['prompt'] ?? '');
        $rag    = (string)($in['rag_context'] ?? '');
        // 'run' is POST-only, so its backend override travels in the body,
        // not the query string like 'list'/'installed_models' use.
        $bodyBackend = $in['backend'] ?? null;
        if (in_array($bodyBackend, ['ollama', 'localai'], true)) $backendOverride = $bodyBackend;
        // Optional: base64 image(s) for a vision-capable step (no "data:" prefix
        // — strip that client-side if it came from a FileReader data URL).
        // Ignored harmlessly by any step whose model isn't vision-capable.
        $images = array_values(array_filter((array)($in['images'] ?? []), 'is_string'));
        if ($id === '' || $prompt === '') { echo json_encode(['ok'=>false,'error'=>'combo_id and prompt required']); exit; }
        $res = combos_run($id, $prompt, $rag, $backendOverride, $images);
        if (($res['ok'] ?? false) && isset($PATHS['projects_root'])) {
            $res['saved'] = combos_append_chat(
                (string)$PATHS['projects_root'],
                (string)($in['project'] ?? 'default'),
                (string)($in['chat'] ?? 'default'),
                $prompt, combos_flatten($res), 'combo:' . $id);
        }
        echo json_encode($res, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
        exit;
    }
    // Install downloaded combo(s): merge into (or overwrite) combos_<scope>.enc,
    // encrypted per-user (machine + account bound). The marketplace download
    // flow posts one combo at a time (merge=1, default); bulk register-flow can
    // post the whole pack at once (merge=0). scope: 'base' (free 50) | 'store' (premium).
    if ($action === 'install') {
        $in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
        $scope  = ($in['scope'] ?? 'base') === 'store' ? 'store' : 'base';
        $combos = $in['combos'] ?? null;
        $merge  = !isset($in['merge']) || !empty($in['merge']);
        if (!is_array($combos)) { echo json_encode(['ok'=>false,'error'=>'combos array required']); exit; }
        // Backend-aware: installing a LocalAI pack must not overwrite Ollama's
        // combos_base.enc/combos_store.enc (or vice versa) — see combos_enc_path().
        $f = combos_enc_path($scope);
        $final = $combos;
        if ($merge) {
            $existing = combos_decrypt_file($f, $scope);
            $byId = [];
            foreach (($existing['combos'] ?? []) as $c) if (($c['id'] ?? '') !== '') $byId[$c['id']] = $c;
            foreach ($combos as $c) if (($c['id'] ?? '') !== '') $byId[$c['id']] = $c;
            $final = array_values($byId);
        }
        $blob = combos_encrypt_blob(json_encode(['version'=>2,'combos'=>$final], JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES), $scope);
        if ($blob === '') { echo json_encode(['ok'=>false,'error'=>'encrypt failed']); exit; }
        $ok  = @file_put_contents($f, $blob) !== false;
        @chmod($f, 0644);
        echo json_encode(['ok'=>$ok, 'scope'=>$scope, 'count'=>count($final)]);
        exit;
    }

    // ── User-authored combos ─────────────────────────────────────────────────
    // Plain JSON, never encrypted — the author already holds the plaintext,
    // there's nothing to protect them from (COCKPIT_COMBO_PROTECTION_DESIGN.md
    // §7). Stored separately from the hub registry so it's never confused with
    // downloaded/protected content and never accidentally overwritten by a
    // Combo Store sync.
    if ($action === 'user_list') {
        $f = dirname(combos_registry_path()) . '/combos_user.json';
        $j = is_readable($f) ? json_decode((string)file_get_contents($f), true) : null;
        echo json_encode(['ok'=>true, 'combos'=>$j['combos'] ?? []]);
        exit;
    }
    if ($action === 'user_save') {
        $in = json_decode((string)file_get_contents('php://input'), true) ?: [];
        $c  = $in['combo'] ?? null;
        if (!is_array($c) || empty($c['id']) || empty($c['name']) || empty($c['steps']))
            { echo json_encode(['ok'=>false,'error'=>'id, name, and at least one step required']); exit; }
        $id = preg_replace('/[^a-z0-9_-]/', '', strtolower((string)$c['id']));
        if ($id === '') { echo json_encode(['ok'=>false,'error'=>'invalid id']); exit; }
        // Refuse to shadow a hub combo id — user combos are a distinct namespace.
        $hub = combos_load();
        foreach (($hub['combos'] ?? []) as $h) {
            if (($h['id'] ?? '') === $id && ($h['origin'] ?? '') !== 'user')
                { echo json_encode(['ok'=>false,'error'=>'id already used by a hub combo']); exit; }
        }
        $c['id'] = $id;
        $c['pattern'] = in_array($c['pattern'] ?? '', ['parallel','sequential','judge'], true) ? $c['pattern'] : 'parallel';
        $c['steps'] = array_values(array_filter((array)$c['steps'], fn($s) => !empty($s['model'])));
        if (!count($c['steps'])) { echo json_encode(['ok'=>false,'error'=>'at least one step needs a model']); exit; }

        $f = dirname(combos_registry_path()) . '/combos_user.json';
        $j = is_readable($f) ? json_decode((string)file_get_contents($f), true) : ['version'=>2,'combos'=>[]];
        if (!is_array($j)) $j = ['version'=>2,'combos'=>[]];
        $byId = [];
        foreach (($j['combos'] ?? []) as $existing) if (($existing['id'] ?? '') !== '') $byId[$existing['id']] = $existing;
        $byId[$id] = $c;
        $j['combos'] = array_values($byId);
        $ok = @file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES)) !== false;
        echo json_encode(['ok'=>$ok, 'id'=>$id]);
        exit;
    }
    if ($action === 'user_delete') {
        $in = json_decode((string)file_get_contents('php://input'), true) ?: [];
        $id = trim((string)($in['id'] ?? ''));
        if ($id === '') { echo json_encode(['ok'=>false,'error'=>'id required']); exit; }
        $f = dirname(combos_registry_path()) . '/combos_user.json';
        $j = is_readable($f) ? json_decode((string)file_get_contents($f), true) : null;
        if (!is_array($j)) { echo json_encode(['ok'=>true]); exit; }
        $j['combos'] = array_values(array_filter($j['combos'] ?? [], fn($c) => ($c['id'] ?? '') !== $id));
        @file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES));
        echo json_encode(['ok'=>true]);
        exit;
    }

    echo json_encode(['ok'=>false,'error'=>'unknown action']);
}
