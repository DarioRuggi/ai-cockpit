<?php
// =============================================================================
// workers.php — Cockpit Workers (online LLM providers) backend
//
// Provides access to free/cheap online LLMs as a 4th provider class alongside
// Claude / Gemini / Ollama. Workers are HTTP-only — no tmux session, no CLI.
//
// Use cases (per Dario):
//   - Specialty workers (image gen, audio, video, translation) the main 3
//     agents don't natively do
//   - Fallback when main providers run out of tokens
//   - Cost optimization (route cheap tasks to free tiers)
//
// Storage:
//   <CD>/workers_providers.json   — curated provider catalog (read-only,
//                                   shipped with cockpit, user can override
//                                   per-provider settings)
//   <CD>/workers_state.json       — user-facing state: enabled providers,
//                                   selected models, project-level overrides
//   <CD>/workers_keys.enc         — AES-256-GCM encrypted API keys
//   <CD>/workers_usage.json       — usage tracking (calls, tokens, last reset)
//
//   <CD> = ~/scripts/cockpit_data
//
// Endpoints:
//   GET  ?action=providers        — list catalog + configured state
//   GET  ?action=models           — flat list of enabled <provider:model>
//                                   pairs for the topbar dropdown
//   POST ?action=set_key          — store an API key for a provider
//   POST ?action=clear_key        — remove a stored key
//   POST ?action=enable_provider  — toggle provider on/off
//   POST ?action=invoke           — call a worker, return its response
//   GET  ?action=usage            — usage snapshot per provider
//   POST ?action=reset_usage      — reset counters for a provider
//   POST ?action=add_custom       — register a custom provider
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

register_shutdown_function(function() {
    $err = error_get_last();
    if ($err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        if (!headers_sent()) header('Content-Type: application/json');
        echo json_encode(['ok'=>false, 'error'=>'Internal: '.$err['message']], JSON_UNESCAPED_UNICODE);
    }
});

// =============================================================================
// Paths
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/webworker_lib.php';   // providers of type "webworker": a site's own web page, driven in a window nobody sees
// CLI callers (worker_relay.php) reuse this file's functions + key store but
// must skip the HTTP auth guard. Browser requests still auth-gate as before.
if (PHP_SAPI !== 'cli') require_once __DIR__ . '/auth.php';
// [edition] demo: show real provider cards for ?action=providers (first two
// pre-connected so the panel looks usable), described-modal for everything else.
// v1/v2 skip this entirely and run real dispatch (workers cap = true). CLI
// (worker_relay) also skips — it only needs the invoke_* fns + key store.
if (PHP_SAPI !== 'cli' && ed_is('demo')) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'providers') {
        $cat = load_providers_catalog(__DIR__ . '/workers_providers.json', __DIR__);
        $providers = [];
        foreach (($cat['providers'] ?? []) as $i => $p) {
            $providers[] = array_merge($p, ['enabled'=>$i<2, 'key_set'=>$i<2, 'usage'=>null]);
        }
        echo json_encode(['ok'=>true, 'providers'=>$providers, 'auto_route_projects'=>[]]); exit;
    }
    ed_gate_or_exit('workers');   // non-providers actions → described-modal
}
$PROVIDERS_F   = $CD . '/workers_providers.json';
$STATE_F       = $CD . '/workers_state.json';
$KEYS_F        = $CD . '/workers_keys.enc';
$USAGE_F       = $CD . '/workers_usage.json';
$SETTINGS_F    = $CD . '/settings.json';        // paid-spend consent + caps
$SPEND_F       = $CD . '/workers_spend.json';   // actual paid spend ledger (monthly)
$HEALTH_F      = $CD . '/workers_health.json';  // provider/model drift health (#3/#4)
// Phase 2b 2026-05-09: free-tier quota config (seeded from cockpit ship if absent)
$QUOTAS_F      = $CD . '/workers_quotas.json';
$QUOTAS_SHIP   = __DIR__ . '/workers_quotas.json';
$CATALOG_SHIP  = __DIR__ . '/workers_providers.json';

if (!is_dir($CD)) @mkdir($CD, 0775, true);

// Seed quotas file from shipped config if missing
if (!is_file($QUOTAS_F) && is_file($QUOTAS_SHIP)) {
    @copy($QUOTAS_SHIP, $QUOTAS_F);
    @chmod($QUOTAS_F, 0664);
} elseif (is_file($QUOTAS_F) && is_file($QUOTAS_SHIP)) {
    // The per-user copy was seeded once and never refreshed, so a model added
    // to the shipped file (Groq replaced its whole free line-up 2026-08-16) had
    // no limits in the copy. Additive merge: shipped provider/model limits the
    // user copy lacks are added; nothing the user has is changed or removed.
    $_qu = json_decode((string)@file_get_contents($QUOTAS_F), true);
    $_qs = json_decode((string)@file_get_contents($QUOTAS_SHIP), true);
    if (is_array($_qu) && is_array($_qs)) {
        $_changed = false;
        foreach ($_qs as $_pid => $_pv) {
            if (!is_array($_pv)) continue;
            if (!isset($_qu[$_pid])) { $_qu[$_pid] = $_pv; $_changed = true; continue; }
            foreach (($_pv['models'] ?? []) as $_mid => $_lim) {
                if (!isset($_qu[$_pid]['models'][$_mid])) { $_qu[$_pid]['models'][$_mid] = $_lim; $_changed = true; }
            }
        }
        if ($_changed) @file_put_contents($QUOTAS_F, json_encode($_qu, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE), LOCK_EX);
    }
    unset($_qu, $_qs, $_pid, $_pv, $_mid, $_lim, $_changed);
}

// =============================================================================
// Migration v2 — Tools Staleness Fix (2026-05-12)
//
// OLD behaviour: workers_providers.json was a full copy of the shipped catalog
// in cockpit_data/; user modifications (custom providers, added models) lived
// inline in that copy. Any shipped update was invisible until manually synced.
//
// NEW behaviour: cockpit_data/workers_providers.json is a thin OVERLAY:
//   { format_version:2, custom_providers:[...], user_added_models:{...} }
// The shipped file at /var/www/html/cockpit/workers_providers.json is the
// source of truth. Cockpit merges overlay on top at read time.
//
// The seeding block below is REMOVED — workers.php no longer copies the
// shipped catalog to cockpit_data/. load_providers_catalog() does the merge.
// =============================================================================
// TOOLS_DIR and BUILTINS_SHIP are tools.php-specific; pass cockpit_data paths.
// migrate_v2_run() is idempotent (no-op if marker exists). Skipped under CLI
// (worker_relay only needs the functions + key store, not config migration).
if (PHP_SAPI !== 'cli') {
    require_once __DIR__ . '/migrate_v2.php';
    $_mig_w = migrate_v2_run($CD, $CD . '/tools', __DIR__ . '/tools_builtins', $CATALOG_SHIP);
}

// =============================================================================
// Crypto — AES-256-GCM with key derived from machine-id + cockpit salt
//
// Threat model: stops casual disk-grep, accidental git-commit, shared-config
// leaks. Does NOT stop someone with shell access to the user's machine. That's
// the same security level as your SSH keys at ~/.ssh/.
// =============================================================================
function get_master_key() {
    // Stable per-machine: machine-id + cockpit salt
    $machine_id_path = '/etc/machine-id';
    $machine_id      = is_readable($machine_id_path)
        ? trim((string)file_get_contents($machine_id_path))
        : 'cockpit-default-machine';
    $salt = 'AICockpit-WorkerKeys-v1-DarioRuggi';
    return hash('sha256', $machine_id . $salt, true);   // 32 bytes
}

function encrypt_blob($plaintext) {
    if ($plaintext === '' || $plaintext === null) return '';
    $key = get_master_key();
    $iv  = random_bytes(12);
    $tag = '';
    $ct  = openssl_encrypt($plaintext, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag, '', 16);
    if ($ct === false) return '';
    // Format: base64(iv ‖ tag ‖ ciphertext)
    return base64_encode($iv . $tag . $ct);
}
function decrypt_blob($b64) {
    if ($b64 === '' || $b64 === null) return '';
    $raw = base64_decode($b64, true);
    if ($raw === false || strlen($raw) < 28) return '';
    $iv  = substr($raw, 0, 12);
    $tag = substr($raw, 12, 16);
    $ct  = substr($raw, 28);
    $key = get_master_key();
    $pt  = openssl_decrypt($ct, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag);
    return $pt === false ? '' : $pt;
}

// =============================================================================
// Helpers — load/save the four data files
// =============================================================================
function load_json_file($path, $default = []) {
    if (!is_file($path)) return $default;
    $j = json_decode((string)file_get_contents($path), true);
    return is_array($j) ? $j : $default;
}
function save_json_file($path, $data) {
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE)) === false) {
        return false;
    }
    @chmod($tmp, 0664);
    if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
    return true;
}

function load_providers($PROVIDERS_F)  {
    // Shim — all callers now use load_providers_catalog() directly.
    // This exists as a safety net; __DIR__ is always the web tier (cockpit/).
    return load_providers_catalog($PROVIDERS_F, __DIR__);
}

// load_providers_catalog() — merge shipped catalog with user overlay.
//
// Reads:
//   1. $catalog_ship — shipped workers_providers.json (source of truth, web tier)
//   2. $overlay_f    — cockpit_data/workers_providers.json (user overlay, thin)
//
// Overlay format v2:
//   { "format_version": 2,
//     "custom_providers":  [ {id, custom:true, base, ...} ],
//     "user_added_models": { "<provider_id>": [ {id, user_added:true, ...} ] }
//   }
//
// If the overlay is missing → return shipped catalog as-is.
// If the overlay has no format_version → old format (not yet migrated);
//   return shipped only (stale user copy ignored until migration runs).
// If format_version == 2 → merge: shipped providers first, then graft
//   user_added_models onto matching shipped providers, then append
//   custom_providers.
require_once __DIR__ . '/catalog_feed_lib.php';
function load_providers_catalog(string $overlay_f, string $web_tier_dir): array {
    // --- 1. Shipped catalog (source of truth) ---
    $ship_f   = $web_tier_dir . '/workers_providers.json';
    // Fallback: if workers.php is inside the web tier, __DIR__ works too.
    // We accept either an absolute path or derived from dirname($overlay_f)
    // being the cockpit_data dir (web tier is the script's own __DIR__).
    if (!is_file($ship_f)) {
        // Try resolving relative to this script's directory
        $ship_f = __DIR__ . '/workers_providers.json';
    }
    if (!is_file($ship_f)) {
        return ['providers' => []];   // nothing to serve
    }
    $catalog = json_decode((string)file_get_contents($ship_f), true);
    if (!is_array($catalog) || !isset($catalog['providers'])) {
        return ['providers' => []];
    }
    // --- 1b. The signed catalog feed (new models / prices between builds), if it is switched on AND verifies: see catalog_feed_lib.php ---
    $catalog = catalog_feed_apply($catalog, catalog_feed_load(dirname($overlay_f)));

    // --- 2. User overlay ---
    if (!is_file($overlay_f)) {
        return $catalog;   // no overlay yet — shipped is complete
    }
    $overlay = json_decode((string)file_get_contents($overlay_f), true);
    if (!is_array($overlay)) {
        return $catalog;   // unreadable overlay — use shipped
    }
    if (!isset($overlay['format_version'])) {
        // Old full-copy format — migration hasn't run yet; ignore stale overlay.
        // The migrate_v2_run() call at the top of this file will handle it.
        error_log("cockpit workers.php: workers_providers.json in old format; using shipped until migration runs");
        return $catalog;
    }

    // --- 3. Merge user_added_models into matching shipped providers ---
    if (!empty($overlay['user_added_models']) && is_array($overlay['user_added_models'])) {
        foreach ($overlay['user_added_models'] as $provider_id => $extra_models) {
            if (!is_array($extra_models)) continue;
            foreach ($catalog['providers'] as $i => $p) {
                if (($p['id'] ?? '') !== $provider_id) continue;
                // Append user-added models; shipped models stay first
                $catalog['providers'][$i]['models'] = array_merge(
                    $p['models'] ?? [],
                    $extra_models
                );
                // Refresh provider-level kinds aggregate
                $all_kinds = [];
                foreach ($catalog['providers'][$i]['models'] as $m) {
                    foreach (($m['kinds'] ?? []) as $k) $all_kinds[$k] = true;
                }
                $catalog['providers'][$i]['kinds'] = array_values(array_keys($all_kinds));
                break;
            }
        }
    }

    // --- 4. Append custom providers ---
    if (!empty($overlay['custom_providers']) && is_array($overlay['custom_providers'])) {
        // Guard against duplicates (shouldn't happen, but be safe)
        $existing_ids = [];
        foreach ($catalog['providers'] as $p) {
            if (!empty($p['id'])) $existing_ids[$p['id']] = true;
        }
        foreach ($overlay['custom_providers'] as $cp) {
            if (empty($cp['id']) || isset($existing_ids[$cp['id']])) continue;
            $catalog['providers'][] = $cp;
        }
    }

    return $catalog;
}

function load_state($STATE_F)          { return load_json_file($STATE_F, ['enabled'=>[],'auto_route_projects'=>[]]); }
function load_usage($USAGE_F)          { return load_json_file($USAGE_F, []); }

// Keys file is encrypted JSON: { "<provider_id>": "<key>", ... }
function load_keys($KEYS_F) {
    if (!is_file($KEYS_F)) return [];
    $b64 = trim((string)file_get_contents($KEYS_F));
    if ($b64 === '') return [];
    $pt  = decrypt_blob($b64);
    if ($pt === '') {
        // MED-69: decrypt failure isn't the same as "no keys". Log it so a
        // failed master key (e.g. /etc/machine-id changed) is visible in
        // server logs instead of silently appearing as "no providers".
        @error_log('[workers.php] Failed to decrypt ' . $KEYS_F . ' — master key may have changed');
        return [];
    }
    $j = json_decode($pt, true);
    return is_array($j) ? $j : [];
}
function save_keys($KEYS_F, $keys) {
    $blob = encrypt_blob(json_encode($keys, JSON_UNESCAPED_UNICODE));
    if ($blob === '') return false;
    $tmp = $KEYS_F . '.tmp';
    if (file_put_contents($tmp, $blob) === false) return false;
    // 0644: the blob is AES-256-GCM encrypted with a machine-id-derived key, and
    // /etc/machine-id is already world-readable, so file perms add no local-user
    // secrecy anyway. Readable perms let the agent user (worker_relay.php, run by
    // agent_loop as a different user) reuse the key store for the Card-2 fallback.
    @chmod($tmp, 0644);
    if (!@rename($tmp, $KEYS_F)) { @unlink($tmp); return false; }
    @chmod($KEYS_F, 0644);
    return true;
}

// =============================================================================
// Validation helpers
// =============================================================================
function safe_provider_id($s) {
    return preg_match('/^[a-z][a-z0-9_-]{0,63}$/', (string)$s) ? $s : null;
}
function safe_model_id($s) {
    // '@' is required by Cloudflare Workers AI model ids (e.g. @cf/meta/llama-3.1-8b).
    return preg_match('/^[A-Za-z0-9._\/:@\-]{1,128}$/', (string)$s) ? $s : null;
}

// =============================================================================
// Provider/model HEALTH (#3 sweep, #4 self-heal). Store keyed by "provider" and
// "provider:model". status ∈ ok|degraded|dead|auth. transient (429/timeout) is
// NOT recorded so a rate-limit blip never disables a model.
// =============================================================================
function health_load($HEALTH_F) { return is_file($HEALTH_F) ? (json_decode((string)file_get_contents($HEALTH_F), true) ?: []) : []; }
function health_save($HEALTH_F, $h) {
    $tmp = $HEALTH_F . '.tmp';
    if (@file_put_contents($tmp, json_encode($h, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) !== false) @rename($tmp, $HEALTH_F);
}
function health_mark($HEALTH_F, $pid, $model, $status, $code, $why) {
    $h = health_load($HEALTH_F);
    $entry = ['status'=>$status, 'code'=>$code, 'reason'=>$why, 'at'=>date('c')];
    if ($model !== '') $h[$pid . ':' . $model] = $entry;
    // Roll a provider-level summary: worst non-ok wins, else ok.
    if ($status !== 'ok') $h[$pid] = $entry;
    elseif (!isset($h[$pid]) || ($h[$pid]['status'] ?? '') === 'ok') $h[$pid] = $entry;
    health_save($HEALTH_F, $h);
}
// Classify a failure error string → [status, code, reason]. Drift signatures
// (gone host / 410 / 404) disable; auth flags the key; rate/timeout = transient.
function health_classify($err) {
    $e = strtolower($err);
    // Local config problems (missing/malformed key) are auth, not model drift —
    // must NOT disable the model in Auto routing.
    if (strpos($e, 'no api key') !== false || strpos($e, 'key must be') !== false)
        return ['auth', 0, 'key missing/malformed'];
    if (strpos($e, 'could not resolve host') !== false || strpos($e, 'resolve host') !== false)
        return ['dead', 0, 'endpoint host unresolved (moved/removed)'];
    if (preg_match('/http (\d{3})/', $e, $m)) {
        $c = (int)$m[1];
        if ($c === 410) return ['dead',     410, 'deprecated (410)'];
        if ($c === 404) return ['degraded', 404, 'model/path not found (404)'];
        if ($c === 401 || $c === 403) return ['auth', $c, 'auth/key rejected (' . $c . ')'];
        if ($c === 429) return ['transient', 429, 'rate limited (429)'];
        if ($c >= 500) return ['transient', $c, 'provider error (' . $c . ')'];
    }
    if (strpos($e, 'timed out') !== false || strpos($e, 'timeout') !== false) return ['transient', 0, 'timeout'];
    return ['degraded', 0, $err ? substr($err, 0, 120) : 'unknown error'];
}

// =============================================================================
// Usage tracking
// =============================================================================
function bump_usage($USAGE_F, $provider_id, $task_kind, $extra = []) {
    // HIGH-64 fix: flock to prevent TOCTOU race when parallel agent calls
    // bump counters simultaneously. Without locking, two parallel writers
    // each read N and write N+1, losing one increment.
    if (!is_file($USAGE_F)) @file_put_contents($USAGE_F, '{}');
    $lock_fh = @fopen($USAGE_F, 'c+');
    if (!$lock_fh || !flock($lock_fh, LOCK_EX)) {
        if ($lock_fh) fclose($lock_fh);
        return;   // best-effort — drop the bump rather than block forever
    }
    $usage = load_usage($USAGE_F);
    $now   = date('c');
    if (!isset($usage[$provider_id])) {
        $usage[$provider_id] = [
            'calls'         => 0,
            'errors'        => 0,
            'last_call_at'  => null,
            'last_reset_at' => $now,
            'by_kind'       => [],
            'tokens_in'     => 0,
            'tokens_out'    => 0,
        ];
    }
    $u = &$usage[$provider_id];
    $u['calls']++;
    $u['last_call_at'] = $now;
    $u['by_kind'][$task_kind] = ($u['by_kind'][$task_kind] ?? 0) + 1;
    // G6: per-model call count for pool breakdown (e.g. OpenRouter 200/day shared)
    if (!empty($extra['model'])) {
        if (!isset($u['by_model']) || !is_array($u['by_model'])) $u['by_model'] = [];
        $mdl = (string)$extra['model'];
        $u['by_model'][$mdl] = ($u['by_model'][$mdl] ?? 0) + 1;
    }
    if (!empty($extra['error'])) {
        $u['errors']++;
    }
    if (isset($extra['tokens_in']))  $u['tokens_in']  += intval($extra['tokens_in']);
    if (isset($extra['tokens_out'])) $u['tokens_out'] += intval($extra['tokens_out']);
    save_json_file($USAGE_F, $usage);
    flock($lock_fh, LOCK_UN);
    fclose($lock_fh);
}

// =============================================================================
// Provider invocation routing — one function per provider
// Each takes (model, task, prompt, key, extra) and returns
//   ['ok'=>bool, 'output'=>string, 'kind'=>string, 'tokens_in'=>?, 'tokens_out'=>?, 'error'=>?]
// =============================================================================

function invoke_groq($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    if (!in_array($task, ['text','translate','summary'], true)) {
        return ['ok'=>false, 'error'=>'Groq does not support task: '.$task];
    }
    $payload = [
        'model'      => $model,
        'messages'   => [['role'=>'user','content'=>$prompt]],
        'max_tokens' => $extra['max_tokens'] ?? 2000,
    ];
    return _http_post_json(
        ($base ?: 'https://api.groq.com/openai/v1') . '/chat/completions',
        $payload,
        ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))                 return ['ok'=>false,'error'=>'Bad JSON from Groq'];
            if (isset($j['error']))            return ['ok'=>false,'error'=>$j['error']['message'] ?? 'Groq error'];
            $msg = $j['choices'][0]['message']['content'] ?? '';
            return [
                'ok'         => true,
                'output'     => (string)$msg,
                'kind'       => 'text',
                'tokens_in'  => $j['usage']['prompt_tokens']     ?? null,
                'tokens_out' => $j['usage']['completion_tokens'] ?? null,
            ];
        }
    );
}

function invoke_huggingface($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    // HuggingFace migrated off api-inference.huggingface.co (now NXDOMAIN) to the
    // Inference Providers router. base_url comes from the catalog (#1).
    $root = $base ?: 'https://router.huggingface.co/hf-inference';
    $url = $root . '/models/' . $model;
    $payload = ['inputs' => $prompt];
    // Image generation models accept negative_prompt etc. via parameters
    if (in_array($task, ['image','image-gen'], true)) {
        $payload['parameters'] = [
            'negative_prompt' => $extra['negative_prompt'] ?? null,
            'num_inference_steps' => $extra['steps'] ?? 25,
        ];
    }
    return _http_post_json(
        $url,
        $payload,
        ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
        function($body, $hdrs) use ($task) {
            // Image models return raw bytes (image/*); text models return JSON
            $ct = '';
            foreach ($hdrs as $h) {
                if (stripos($h, 'content-type:') === 0) { $ct = trim(substr($h, 13)); break; }
            }
            if (stripos($ct, 'image/') === 0) {
                return [
                    'ok'     => true,
                    'output' => 'data:'.$ct.';base64,'.base64_encode($body),
                    'kind'   => 'image',
                ];
            }
            if (stripos($ct, 'audio/') === 0) {
                return [
                    'ok'     => true,
                    'output' => 'data:'.$ct.';base64,'.base64_encode($body),
                    'kind'   => 'audio',
                ];
            }
            $j = json_decode($body, true);
            if (!is_array($j))      return ['ok'=>false,'error'=>'Bad response from HuggingFace'];
            if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']];
            // Text response shapes vary by model
            if (isset($j[0]['generated_text'])) {
                return ['ok'=>true,'output'=>(string)$j[0]['generated_text'],'kind'=>'text'];
            }
            if (isset($j[0]['translation_text'])) {
                return ['ok'=>true,'output'=>(string)$j[0]['translation_text'],'kind'=>'text'];
            }
            return ['ok'=>true,'output'=>json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE),'kind'=>'text'];
        }
    );
}

function invoke_cloudflare($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    // Cloudflare needs an account id + a token. Stored in one field as
    // "ACCOUNT_ID:API_TOKEN" (the cockpit keeps one key per provider).
    $parts = explode(':', $key, 2);
    if (count($parts) !== 2 || $parts[0] === '' || $parts[1] === '')
        return ['ok'=>false, 'error'=>'Cloudflare key must be "ACCOUNT_ID:API_TOKEN"'];
    [$acct, $token] = $parts;
    $root = $base ?: 'https://api.cloudflare.com/client/v4';
    $url = $root . '/accounts/' . rawurlencode($acct) . '/ai/run/' . $model;
    $hdrs = ['Authorization: Bearer ' . $token, 'Content-Type: application/json'];

    if (in_array($task, ['image','image-gen'], true)) {
        $payload = ['prompt' => $prompt];
        if (isset($extra['steps'])) $payload['steps'] = (int)$extra['steps'];
        return _http_post_json($url, $payload, $hdrs, function ($body, $hdrs) {
            // Some CF models return raw image bytes; flux returns JSON {result:{image:b64}}.
            $ct = '';
            foreach ($hdrs as $h) { if (stripos($h, 'content-type:') === 0) { $ct = trim(substr($h, 13)); break; } }
            if (stripos($ct, 'image/') === 0)
                return ['ok'=>true, 'output'=>'data:'.$ct.';base64,'.base64_encode($body), 'kind'=>'image'];
            $j = json_decode($body, true);
            if (!is_array($j))        return ['ok'=>false, 'error'=>'Bad response from Cloudflare'];
            if (empty($j['success'])) return ['ok'=>false, 'error'=>($j['errors'][0]['message'] ?? 'Cloudflare error')];
            $img = $j['result']['image'] ?? '';
            if ($img === '')          return ['ok'=>false, 'error'=>'No image in Cloudflare response'];
            return ['ok'=>true, 'output'=>'data:image/png;base64,'.$img, 'kind'=>'image'];
        });
    }
    // Text/code via the chat-style run endpoint.
    $payload = ['messages' => [['role'=>'user', 'content'=>$prompt]]];
    if (isset($extra['max_tokens'])) $payload['max_tokens'] = (int)$extra['max_tokens'];
    return _http_post_json($url, $payload, $hdrs, function ($body) {
        $j = json_decode($body, true);
        if (!is_array($j))        return ['ok'=>false, 'error'=>'Bad JSON from Cloudflare'];
        if (empty($j['success'])) return ['ok'=>false, 'error'=>($j['errors'][0]['message'] ?? 'Cloudflare error')];
        return ['ok'=>true, 'output'=>(string)($j['result']['response'] ?? ''), 'kind'=>'text'];
    });
}

function invoke_openrouter($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    if (!in_array($task, ['text','translate','summary','code'], true)) {
        return ['ok'=>false, 'error'=>'OpenRouter does not support task: '.$task];
    }
    $payload = [
        'model'      => $model,
        'messages'   => [['role'=>'user','content'=>$prompt]],
        'max_tokens' => $extra['max_tokens'] ?? 2000,
    ];
    return _http_post_json(
        ($base ?: 'https://openrouter.ai/api/v1') . '/chat/completions',
        $payload,
        [
            'Authorization: Bearer '.$key,
            'Content-Type: application/json',
            'HTTP-Referer: http://localhost/cockpit/',
            'X-Title: AI Cockpit',
        ],
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))                 return ['ok'=>false,'error'=>'Bad JSON from OpenRouter'];
            if (isset($j['error']))            return ['ok'=>false,'error'=>$j['error']['message'] ?? 'OpenRouter error'];
            $msg = $j['choices'][0]['message']['content'] ?? '';
            return [
                'ok'         => true,
                'output'     => (string)$msg,
                'kind'       => 'text',
                'tokens_in'  => $j['usage']['prompt_tokens']     ?? null,
                'tokens_out' => $j['usage']['completion_tokens'] ?? null,
            ];
        }
    );
}

function invoke_together($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];

    if (in_array($task, ['image','image-gen'], true)) {
        return _http_post_json(
            ($base ?: 'https://api.together.xyz/v1') . '/images/generations',
            [
                'model'           => $model,
                'prompt'          => $prompt,
                'steps'           => $extra['steps'] ?? 4,
                'n'               => 1,
                'response_format' => 'b64_json',   // self-contained data URL (no CORS on save)
            ],
            ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
            function($body) {
                $j = json_decode($body, true);
                if (!is_array($j))      return ['ok'=>false,'error'=>'Bad response from Together'];
                if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']['message'] ?? 'Together error'];
                $url_or_b64 = $j['data'][0]['b64_json'] ?? $j['data'][0]['url'] ?? '';
                if (!$url_or_b64) return ['ok'=>false,'error'=>'No image returned'];
                $output = strpos($url_or_b64, 'http') === 0
                    ? $url_or_b64
                    : 'data:image/png;base64,'.$url_or_b64;
                return ['ok'=>true,'output'=>$output,'kind'=>'image'];
            }
        );
    }
    // Default — text
    return _http_post_json(
        ($base ?: 'https://api.together.xyz/v1') . '/chat/completions',
        [
            'model'      => $model,
            'messages'   => [['role'=>'user','content'=>$prompt]],
            'max_tokens' => $extra['max_tokens'] ?? 2000,
        ],
        ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))      return ['ok'=>false,'error'=>'Bad JSON from Together'];
            if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']['message'] ?? 'Together error'];
            $msg = $j['choices'][0]['message']['content'] ?? '';
            return [
                'ok'         => true,
                'output'     => (string)$msg,
                'kind'       => 'text',
                'tokens_in'  => $j['usage']['prompt_tokens']     ?? null,
                'tokens_out' => $j['usage']['completion_tokens'] ?? null,
            ];
        }
    );
}

function invoke_deepinfra($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    return _http_post_json(
        ($base ?: 'https://api.deepinfra.com/v1/openai') . '/chat/completions',
        [
            'model'      => $model,
            'messages'   => [['role'=>'user','content'=>$prompt]],
            'max_tokens' => $extra['max_tokens'] ?? 2000,
        ],
        ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))      return ['ok'=>false,'error'=>'Bad JSON from DeepInfra'];
            if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']['message'] ?? 'DeepInfra error'];
            $msg = $j['choices'][0]['message']['content'] ?? '';
            return [
                'ok'         => true,
                'output'     => (string)$msg,
                'kind'       => 'text',
                'tokens_in'  => $j['usage']['prompt_tokens']     ?? null,
                'tokens_out' => $j['usage']['completion_tokens'] ?? null,
            ];
        }
    );
}

// G5: Z.ai (Zhipu GLM) — OpenAI-compatible chat completions endpoint.
function invoke_zai($model, $task, $prompt, $key, $extra = [], $base = '') {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    return _http_post_json(
        ($base ?: 'https://api.z.ai/api/paas/v4') . '/chat/completions',
        [
            'model'      => $model,
            'messages'   => [['role'=>'user','content'=>$prompt]],
            'max_tokens' => $extra['max_tokens'] ?? 2000,
        ],
        ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))      return ['ok'=>false,'error'=>'Bad JSON from Z.ai'];
            if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']['message'] ?? 'Z.ai error'];
            $msg = $j['choices'][0]['message']['content'] ?? '';
            return [
                'ok'         => true,
                'output'     => (string)$msg,
                'kind'       => 'text',
                'tokens_in'  => $j['usage']['prompt_tokens']     ?? null,
                'tokens_out' => $j['usage']['completion_tokens'] ?? null,
            ];
        }
    );
}

// =============================================================================
// Generic HTTP POST helper used by all provider adapters
// =============================================================================
function _http_post_json($url, $payload, $headers, $parser) {
    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => $url,
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => is_string($payload) ? $payload : json_encode($payload, JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER     => $headers,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 60,
        CURLOPT_HEADER         => true,
        CURLOPT_FOLLOWLOCATION => true,
    ]);
    $raw = curl_exec($ch);
    $err = curl_error($ch);
    $info = curl_getinfo($ch);
    curl_close($ch);

    if ($raw === false) return ['ok'=>false, 'error'=>'curl: '.$err];
    $hdr_size = $info['header_size'] ?? 0;
    $hdr_str  = substr($raw, 0, $hdr_size);
    $body     = substr($raw, $hdr_size);
    $hdr_arr  = preg_split("/\r\n|\n|\r/", $hdr_str);

    if (($info['http_code'] ?? 0) >= 400) {
        $j = json_decode($body, true);
        $msg = is_array($j) ? ($j['error']['message'] ?? $j['error'] ?? '') : '';
        if (!$msg && is_string($body)) $msg = substr($body, 0, 300);
        return ['ok'=>false, 'error'=>'HTTP '.$info['http_code'].($msg ? ': '.$msg : '')];
    }

    return $parser($body, $hdr_arr);
}

// =============================================================================
// PAID API workers (gated by the spend-safety stack — see invoke action).
// =============================================================================

// Generic OpenAI-compatible chat invoker. Used for OpenAI itself and for Gemini
// via Google's OpenAI-compatible endpoint. Returns token counts for cost tracking.
function _invoke_openai_chat(string $url, $model, $task, $prompt, $key, $extra = []): array {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    if (!in_array($task, ['text','translate','summary'], true)) {
        return ['ok'=>false, 'error'=>'Unsupported task: '.$task];
    }
    $payload = [
        'model'      => $model,
        'messages'   => [['role'=>'user','content'=>$prompt]],
        'max_tokens' => $extra['max_tokens'] ?? 2000,
    ];
    return _http_post_json($url, $payload,
        ['Authorization: Bearer '.$key, 'Content-Type: application/json'],
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))      return ['ok'=>false,'error'=>'Bad JSON from provider'];
            if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']['message'] ?? 'API error'];
            $text = $j['choices'][0]['message']['content'] ?? '';
            return ['ok'=>true, 'output'=>$text, 'kind'=>'text',
                    'tokens_in'  => $j['usage']['prompt_tokens']     ?? null,
                    'tokens_out' => $j['usage']['completion_tokens'] ?? null];
        });
}

function invoke_openai($model, $task, $prompt, $key, $extra = [], $base = ''): array {
    return _invoke_openai_chat(($base ?: 'https://api.openai.com/v1') . '/chat/completions', $model, $task, $prompt, $key, $extra);
}

function invoke_gemini_api($model, $task, $prompt, $key, $extra = [], $base = ''): array {
    // Google's OpenAI-compatible endpoint — keeps the generic shape.
    return _invoke_openai_chat(($base ?: 'https://generativelanguage.googleapis.com/v1beta/openai') . '/chat/completions',
        $model, $task, $prompt, $key, $extra);
}

// Bespoke Anthropic Messages invoker (NOT OpenAI-shaped: x-api-key header, anthropic-version, system is a top-level field,
// usage uses input/output_tokens). Optional $extra: 'system' (string, a top-level system prompt), 'history' ([{role,content}] earlier turns),
// 'images' ([{media_type,data(base64)}], up to 5), 'cache' (bool: mark a long system prompt as cacheable), 'max_tokens'.
/** Headers for a read-only GET /models probe: Anthropic wants x-api-key + a version, everyone else a Bearer token. */
function provider_probe_headers(string $pid, string $key): array { return $pid === 'anthropic' ? ['x-api-key: ' . $key, 'anthropic-version: 2023-06-01'] : ['Authorization: Bearer ' . $key]; }
function anthropic_headers(string $key): array { return ['x-api-key: ' . $key, 'anthropic-version: 2023-06-01', 'Content-Type: application/json']; }
function anthropic_payload($model, $prompt, array $extra, bool $stream): array {
    $msgs = [];
    foreach (array_slice((array)($extra['history'] ?? []), -40) as $h) {
        $r = ($h['role'] ?? '') === 'assistant' ? 'assistant' : (($h['role'] ?? '') === 'user' ? 'user' : '');
        $c = (string)($h['content'] ?? ''); if ($r === '' || $c === '') continue;
        if ($msgs && $msgs[count($msgs) - 1]['role'] === $r) $msgs[count($msgs) - 1]['content'] .= "\n\n" . $c; else $msgs[] = ['role' => $r, 'content' => $c];
    }
    if ($msgs && $msgs[0]['role'] !== 'user') array_shift($msgs);            // the API wants the first turn to be the user's
    $blocks = [];
    foreach (array_slice((array)($extra['images'] ?? []), 0, 5) as $im) {
        $mt = (string)($im['media_type'] ?? ''); $d = (string)($im['data'] ?? '');
        if (in_array($mt, ['image/jpeg', 'image/png', 'image/gif', 'image/webp'], true) && $d !== '' && preg_match('~^[A-Za-z0-9+/=\s]+$~', $d)) $blocks[] = ['type' => 'image', 'source' => ['type' => 'base64', 'media_type' => $mt, 'data' => preg_replace('/\s+/', '', $d)]];
    }
    $blocks[] = ['type' => 'text', 'text' => (string)$prompt]; $final = count($blocks) === 1 ? (string)$prompt : $blocks;
    if ($msgs && $msgs[count($msgs) - 1]['role'] === 'user') { $last = &$msgs[count($msgs) - 1]; $last['content'] = is_string($final) ? $last['content'] . "\n\n" . $final : array_merge([['type' => 'text', 'text' => $last['content']]], $final); unset($last); }   // two user turns in a row are one turn
    else $msgs[] = ['role' => 'user', 'content' => $final];
    $p = ['model' => $model, 'max_tokens' => (int)($extra['max_tokens'] ?? 2000), 'messages' => $msgs];
    $sys = trim((string)($extra['system'] ?? ''));
    if ($sys !== '') $p['system'] = (!empty($extra['cache']) && strlen($sys) >= 4000) ? [['type' => 'text', 'text' => $sys, 'cache_control' => ['type' => 'ephemeral']]] : $sys;   // under ~1024 tokens the API would not cache it anyway
    if ($stream) $p['stream'] = true;
    return $p;
}
function anthropic_usage(array $u): array {
    $in = (int)($u['input_tokens'] ?? 0); $cr = (int)($u['cache_read_input_tokens'] ?? 0); $cw = (int)($u['cache_creation_input_tokens'] ?? 0);
    return ['tokens_in' => ($u ? $in + $cr + $cw : null), 'tokens_out' => $u['output_tokens'] ?? null] + ($cr || $cw ? ['cache_read_tokens' => $cr, 'cache_write_tokens' => $cw] : []);
}
function invoke_anthropic($model, $task, $prompt, $key, $extra = [], $base = ''): array {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    if (!in_array($task, ['text','translate','summary'], true)) {
        return ['ok'=>false, 'error'=>'Unsupported task: '.$task];
    }
    return _http_post_json(($base ?: 'https://api.anthropic.com/v1') . '/messages', anthropic_payload($model, $prompt, $extra, false), anthropic_headers($key),
        function($body) {
            $j = json_decode($body, true);
            if (!is_array($j))      return ['ok'=>false,'error'=>'Bad JSON from Anthropic'];
            if (isset($j['error'])) return ['ok'=>false,'error'=>$j['error']['message'] ?? 'Anthropic error'];
            $text = '';
            foreach (($j['content'] ?? []) as $blk) { if (($blk['type'] ?? '')==='text') $text .= $blk['text']; }
            return ['ok'=>true, 'output'=>$text, 'kind'=>'text'] + anthropic_usage((array)($j['usage'] ?? [])) + (($j['stop_reason'] ?? '') === 'max_tokens' ? ['truncated' => true] : []);
        });
}
/** The same call, streamed: $emit(string $text) is called with each piece as it arrives; returns the same result shape as invoke_anthropic. */
function invoke_anthropic_stream($model, $task, $prompt, $key, $extra, $base, callable $emit): array {
    if (!$key) return ['ok'=>false, 'error'=>'No API key'];
    if (!in_array($task, ['text','translate','summary'], true)) return ['ok'=>false, 'error'=>'Unsupported task: '.$task];
    $st = ['buf' => '', 'raw' => '', 'text' => '', 'usage' => [], 'stop' => '', 'err' => '', 'sse' => false];
    $feed = function (string $block) use (&$st, $emit) {
        $ev = ''; $data = '';
        foreach (explode("\n", $block) as $l) { if (strncmp($l, 'event:', 6) === 0) $ev = trim(substr($l, 6)); elseif (strncmp($l, 'data:', 5) === 0) $data .= trim(substr($l, 5)); }
        $j = json_decode($data, true); if (!is_array($j)) return;
        $ev = $ev ?: (string)($j['type'] ?? '');
        if ($ev === 'message_start') $st['usage'] = array_merge($st['usage'], (array)($j['message']['usage'] ?? []));
        elseif ($ev === 'content_block_delta' && ($j['delta']['type'] ?? '') === 'text_delta') { $t = (string)($j['delta']['text'] ?? ''); if ($t !== '') { $st['text'] .= $t; $emit($t); } }
        elseif ($ev === 'message_delta') { $st['usage'] = array_merge($st['usage'], (array)($j['usage'] ?? [])); if (!empty($j['delta']['stop_reason'])) $st['stop'] = (string)$j['delta']['stop_reason']; }
        elseif ($ev === 'error') $st['err'] = (string)($j['error']['message'] ?? 'Anthropic error');
    };
    $ch = curl_init(($base ?: 'https://api.anthropic.com/v1') . '/messages');
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode(anthropic_payload($model, $prompt, $extra, true), JSON_UNESCAPED_UNICODE), CURLOPT_HTTPHEADER => anthropic_headers($key),
        CURLOPT_TIMEOUT => 300, CURLOPT_CONNECTTIMEOUT => 15, CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_WRITEFUNCTION => function ($c, $chunk) use (&$st, $feed) {
            $st['raw'] .= (strlen($st['raw']) < 4000 ? $chunk : '');
            if (curl_getinfo($c, CURLINFO_HTTP_CODE) === 200) { $st['sse'] = true; $st['buf'] .= str_replace("\r\n", "\n", $chunk); while (($p = strpos($st['buf'], "\n\n")) !== false) { $feed(substr($st['buf'], 0, $p)); $st['buf'] = substr($st['buf'], $p + 2); } }
            return strlen($chunk);
        }]);
    curl_exec($ch); $err = curl_error($ch); $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    if ($code >= 400 || ($code === 0 && $err !== '')) {
        $j = json_decode((string)$st['raw'], true); $msg = is_array($j) ? ($j['error']['message'] ?? '') : '';
        return ['ok' => false, 'error' => $code ? 'HTTP ' . $code . ($msg ? ': ' . $msg : '') : 'curl: ' . $err];
    }
    if ($st['buf'] !== '') $feed($st['buf']);
    if ($st['err'] !== '') return ['ok' => false, 'error' => $st['err']];
    if (!$st['sse']) return ['ok' => false, 'error' => 'Anthropic did not answer with a stream'];
    return ['ok' => true, 'output' => $st['text'], 'kind' => 'text'] + anthropic_usage($st['usage']) + ($st['stop'] === 'max_tokens' ? ['truncated' => true] : []);
}

// =============================================================================
// CLI-based free workers — route through bridge.php (tmux sessions)
// =============================================================================
// ---- Streaming for the OpenAI-compatible workers (one parser for all of them) -------------------------------------------------------------------------
// Providers whose chat endpoint is POST <base>/chat/completions with the OpenAI body and the OpenAI stream (data: {"choices":[{"delta":{"content":"…"}}]} … data: [DONE]).
// 'usage' = the provider accepts stream_options.include_usage (the last chunk then carries the real token counts); without it the output size is estimated and flagged.
const OPENAI_STREAM_CFG = [
    'openai'        => ['base' => 'https://api.openai.com/v1',                                   'usage' => true],
    'groq'          => ['base' => 'https://api.groq.com/openai/v1',                              'usage' => true],
    'openrouter'    => ['base' => 'https://openrouter.ai/api/v1',                                'usage' => true, 'headers' => ['HTTP-Referer: http://localhost/cockpit/', 'X-Title: AI Cockpit']],
    'together'      => ['base' => 'https://api.together.xyz/v1',                                 'usage' => false],
    'deepinfra'     => ['base' => 'https://api.deepinfra.com/v1/openai',                         'usage' => true],
    'zai'           => ['base' => 'https://api.z.ai/api/paas/v4',                                'usage' => false],
    'google_gemini' => ['base' => 'https://generativelanguage.googleapis.com/v1beta/openai',     'usage' => false],
];
/** Feed one SSE block of an OpenAI-style stream into $st; calls $emit(text) for each piece. */
function openai_sse_block(string $block, array &$st, callable $emit): void {
    foreach (explode("\n", $block) as $l) {
        if (strncmp($l, 'data:', 5) !== 0) continue;
        $d = trim(substr($l, 5)); if ($d === '') continue;
        if ($d === '[DONE]') { $st['done'] = true; continue; }
        $j = json_decode($d, true); if (!is_array($j)) continue;
        if (isset($j['error'])) { $st['err'] = is_array($j['error']) ? (string)($j['error']['message'] ?? 'API error') : (string)$j['error']; continue; }
        $t = (string)($j['choices'][0]['delta']['content'] ?? ''); if ($t !== '') { $st['text'] .= $t; $emit($t); }
        if (!empty($j['choices'][0]['finish_reason'])) $st['finish'] = (string)$j['choices'][0]['finish_reason'];
        if (!empty($j['usage']) && is_array($j['usage'])) $st['usage'] = $j['usage'];
    }
}
function invoke_openai_compat_stream(string $pid, $model, $task, $prompt, $key, $extra, $base, callable $emit): array {
    $cfg = OPENAI_STREAM_CFG[$pid] ?? null;
    if (!$cfg) return ['ok' => false, 'error' => 'No streaming for ' . $pid];
    if (!$key) return ['ok' => false, 'error' => 'No API key'];
    if (!in_array($task, ['text', 'translate', 'summary', 'code'], true)) return ['ok' => false, 'error' => 'Unsupported task: ' . $task];
    $payload = ['model' => $model, 'messages' => [['role' => 'user', 'content' => (string)$prompt]], 'max_tokens' => (int)($extra['max_tokens'] ?? 2000), 'stream' => true];
    if (!empty($cfg['usage'])) $payload['stream_options'] = ['include_usage' => true];
    $st = ['buf' => '', 'raw' => '', 'text' => '', 'usage' => [], 'finish' => '', 'err' => '', 'sse' => false, 'done' => false];
    $ch = curl_init(rtrim($base ?: $cfg['base'], '/') . '/chat/completions');
    curl_setopt_array($ch, [CURLOPT_POST => true, CURLOPT_POSTFIELDS => json_encode($payload, JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER => array_merge(['Authorization: Bearer ' . $key, 'Content-Type: application/json'], $cfg['headers'] ?? []),
        CURLOPT_TIMEOUT => 300, CURLOPT_CONNECTTIMEOUT => 15, CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_HEADERFUNCTION => function ($c, $line) use (&$st) { if (stripos($line, 'content-type:') === 0) $st['ct'] = strtolower(trim(substr($line, 13))); return strlen($line); },
        CURLOPT_WRITEFUNCTION => function ($c, $chunk) use (&$st, $emit) {
            if (strlen($st['raw']) < 4000 || empty($st['sse'])) $st['raw'] .= $chunk;      // a non-stream answer is kept whole
            if (curl_getinfo($c, CURLINFO_HTTP_CODE) === 200 && strpos((string)($st['ct'] ?? ''), 'text/event-stream') !== false) {
                $st['sse'] = true; $st['buf'] .= str_replace("\r\n", "\n", $chunk);
                while (($p = strpos($st['buf'], "\n\n")) !== false) { openai_sse_block(substr($st['buf'], 0, $p), $st, $emit); $st['buf'] = substr($st['buf'], $p + 2); }
            }
            return strlen($chunk);
        }]);
    curl_exec($ch); $err = curl_error($ch); $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    if ($code >= 400 || ($code === 0 && $err !== '')) {
        $j = json_decode((string)$st['raw'], true); $msg = is_array($j) ? ($j['error']['message'] ?? (is_string($j['error'] ?? null) ? $j['error'] : '')) : '';
        return ['ok' => false, 'error' => $code ? 'HTTP ' . $code . ($msg ? ': ' . $msg : '') : 'curl: ' . $err];
    }
    if ($st['buf'] !== '') openai_sse_block($st['buf'], $st, $emit);
    if ($st['err'] !== '') return ['ok' => false, 'error' => $st['err']];
    if (!$st['sse']) {   // the provider ignored stream:true and answered in one piece: use that answer
        $j = json_decode((string)$st['raw'], true); $t = is_array($j) ? (string)($j['choices'][0]['message']['content'] ?? '') : '';
        if ($t === '') return ['ok' => false, 'error' => 'The provider did not answer with a stream'];
        $emit($t); return ['ok' => true, 'output' => $t, 'kind' => 'text', 'tokens_in' => $j['usage']['prompt_tokens'] ?? null, 'tokens_out' => $j['usage']['completion_tokens'] ?? null];
    }
    if (!$st['done'] && $st['finish'] === '') return ['ok' => false, 'error' => 'The answer stream ended before it was complete'];
    $u = $st['usage'];
    $r = ['ok' => true, 'output' => $st['text'], 'kind' => 'text'];
    if ($u) { $r['tokens_in'] = $u['prompt_tokens'] ?? null; $r['tokens_out'] = $u['completion_tokens'] ?? null; }
    else { $r['tokens_in'] = null; $r['tokens_out'] = (int)ceil(strlen($st['text']) / 4); $r['tokens_estimated'] = true; }   // no usage chunk: say so rather than invent exact numbers
    if ($st['finish'] === 'length') $r['truncated'] = true;
    return $r;
}
function invoke_cli_agent(string $agent, $model, $task, $prompt, $key, $extra, $base): array {
    if ($task !== 'text') return ['ok' => false, 'error' => $agent . ' CLI only supports text'];

    $bridge = 'http://127.0.0.1' . ($_SERVER['SERVER_PORT'] == 80 ? '' : ':' . $_SERVER['SERVER_PORT'])
              . dirname($_SERVER['SCRIPT_NAME']) . '/bridge.php';
    $payload = json_encode([
        'mode'   => 'sync',
        'agent'  => $agent,
        'prompt' => $prompt,
    ], JSON_UNESCAPED_UNICODE);

    $ch = curl_init($bridge);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 420,
    ]);
    $raw = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $err = curl_error($ch);
    curl_close($ch);

    if ($err) return ['ok' => false, 'error' => 'CLI bridge error: ' . $err];
    $d = json_decode($raw, true);
    if (!is_array($d) || !empty($d['error']))
        return ['ok' => false, 'error' => $d['response'] ?? $d['error'] ?? 'Unknown bridge error'];

    $text = $d['response'] ?? '';
    return ['ok' => true, 'output' => $text, 'kind' => 'text', 'tokens_in' => null, 'tokens_out' => null];
}

function invoke_cli_claude($model, $task, $prompt, $key = '', $extra = [], $base = ''): array {
    return invoke_cli_agent('claude', $model, $task, $prompt, $key, $extra, $base);
}
function invoke_cli_gemini($model, $task, $prompt, $key = '', $extra = [], $base = ''): array {
    return invoke_cli_agent('gemini', $model, $task, $prompt, $key, $extra, $base);
}

// Same "[Identity]" preamble agent_loop.sh injects for CLI dispatch (claude/
// gemini/fallback/ollama) — Workers-card direct invokes went through a
// SEPARATE path and never got it (deferred item from 2026-06-28, built now).
// Stops a model claiming to be a different provider/company when asked.
function worker_identity_line(?array $provDef, string $pid, string $model): string {
    $name = $provDef['name'] ?? $pid;
    $modelPart = $model !== '' ? " (model: {$model})" : '';
    return "[Identity] You are running inside AI Cockpit on {$name}{$modelPart}. "
         . "If asked which model or company you are, answer truthfully with this; "
         . "do not claim to be a different model or company.\n\n";
}

// =============================================================================
// Routing table — provider_id → handler function
// =============================================================================
$INVOKERS = [
    'groq'          => 'invoke_groq',
    'cloudflare'    => 'invoke_cloudflare',
    'huggingface'   => 'invoke_huggingface',
    'openrouter'    => 'invoke_openrouter',
    'together'      => 'invoke_together',
    'deepinfra'     => 'invoke_deepinfra',
    'openai'        => 'invoke_openai',
    'anthropic'     => 'invoke_anthropic',
    'google_gemini' => 'invoke_gemini_api',
    'zai'           => 'invoke_zai',
    'cli_claude'    => 'invoke_cli_claude',
    'cli_gemini'    => 'invoke_cli_gemini',
];

// =============================================================================
// Action dispatcher
// =============================================================================
// CLI callers only want the functions + key store above — stop before the
// HTTP dispatch so requiring this file from worker_relay.php is side-effect free.
// Providers of type "webworker" (workers_providers.json): the invoker runs the site's own page (webworker_lib.php). Same signature as the others.
foreach ((load_providers_catalog($PROVIDERS_F, __DIR__)['providers'] ?? []) as $__p) {
    if (($__p['type'] ?? '') === 'webworker' && !empty($__p['id']) && !empty($__p['url']) && is_array($__p['adapter'] ?? null)) {
        $INVOKERS[$__p['id']] = (function (array $p) { return function ($model, $task, $prompt, $key = '', $extra = [], $base = '') use ($p) {
            if (!in_array($task, ['text', 'translate', 'summary', 'code'], true)) return ['ok' => false, 'error' => 'A web page worker only does text, not: ' . $task];
            return ww_run($p['id'], $p['url'], $p['adapter'], (string)$prompt, null);
        }; })($__p);
    }
}
unset($__p);
/** The invoker for a provider: its own, or - for a custom provider the person added - the one of the API shape ('base') it speaks, called with the provider's own base_url. */
function resolve_invoker(string $pid, ?array $provDef) {
    global $INVOKERS;
    if (isset($INVOKERS[$pid])) return $INVOKERS[$pid];
    $b = (string)($provDef['base'] ?? '');
    if (!empty($provDef['custom']) && $b !== '' && !empty($provDef['base_url']) && isset($INVOKERS[$b])) return $INVOKERS[$b];
    return null;
}
/** An address a custom provider may use: https anywhere, or plain http only on this machine / a private network (a local model server). null = fine, else the reason. */
function custom_base_url_problem(string $u): ?string {
    if (!preg_match('#^(https?)://([A-Za-z0-9.-]+|\[[0-9a-fA-F:]+\])(:\d{1,5})?(/[^\s?\#]*)?$#', $u, $m)) return 'The address must look like https://host/v1';
    if ($m[1] === 'http' && !preg_match('/^(localhost|127\.\d+\.\d+\.\d+|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+|\[::1\])$/i', $m[2])) return 'Plain http is only allowed for this machine or a private network; use https';
    return null;
}
if (PHP_SAPI === 'cli') return;

$action = $_GET['action'] ?? '';
$in     = json_decode(file_get_contents('php://input'), true) ?: [];

// =============================================================================
// Action: providers — return catalog + state (with key-set bool, no key value)
// =============================================================================
if ($action === 'providers') {
    $cat   = load_providers_catalog($PROVIDERS_F, __DIR__);
    $state = load_state($STATE_F);
    $keys  = load_keys($KEYS_F);
    $usage = load_usage($USAGE_F);
    $providers = [];
    foreach (($cat['providers'] ?? []) as $p) {
        $pid = $p['id'];
        $providers[] = array_merge($p, [
            'enabled'   => !empty($state['enabled'][$pid]),
            'key_set'   => !empty($keys[$pid]),
            'usage'     => $usage[$pid] ?? null,
        ]);
    }
    echo json_encode([
        'ok'                  => true,
        'providers'           => $providers,
        'auto_route_projects' => $state['auto_route_projects'] ?? [],
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: models — flat list of <provider:model> strings for the topbar
// =============================================================================
if ($action === 'models') {
    $cat   = load_providers_catalog($PROVIDERS_F, __DIR__);
    $state = load_state($STATE_F);
    $keys  = load_keys($KEYS_F);
    $store = health_load($HEALTH_F);
    $models = [];
    foreach (($cat['providers'] ?? []) as $p) {
        $pid = $p['id'];
        if (empty($state['enabled'][$pid])) continue;
        if (empty($keys[$pid]) && empty($p['no_key_required'])) continue;
        foreach (($p['models'] ?? []) as $m) {
            $mk   = $pid . ':' . $m['id'];
            // Self-heal (#4): a model marked dead/degraded is flagged so Auto
            // routing skips it (provider-level death taints all its models too).
            $st   = $store[$mk]['status'] ?? ($store[$pid]['status'] ?? 'ok');
            $bad  = in_array($st, ['dead','degraded'], true);
            $models[] = [
                'value'    => $mk,
                'label'    => $p['name'] . ' · ' . ($m['label'] ?? $m['id']),
                'provider' => $pid,
                'model'    => $m['id'],
                'kinds'    => $m['kinds']    ?? ['text'],
                'free'     => !empty($m['free']),
                'degraded' => $bad,
                'health'   => $st,
            ];
        }
    }
    echo json_encode(['ok'=>true,'models'=>$models], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: set_key — store an API key (encrypted)
//
// NOTE (2026-05-07 fix): Also auto-enable the provider in workers_state.json.
// Saving a key is an act of intent — the user wants to use this provider — so
// we mark it enabled by default. Without this, the UI's `providers` action
// returned key_set=true but enabled=false, causing the WORKERS panel to render
// "no provider configured" even though the encrypted key was on disk.
// Power users can still call enable_provider with enabled=false to disable a
// keyed provider without deleting the key.
// =============================================================================
if ($action === 'set_key') {
    $pid = safe_provider_id($in['provider'] ?? '');
    $key = trim((string)($in['key'] ?? ''));
    if (!$pid || $key === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing provider/key'], JSON_UNESCAPED_UNICODE); exit;
    }
    $keys = load_keys($KEYS_F);
    $keys[$pid] = $key;
    if (!save_keys($KEYS_F, $keys)) {
        echo json_encode(['ok'=>false,'error'=>'Failed to write keys file'], JSON_UNESCAPED_UNICODE); exit;
    }

    // Auto-enable: if this provider has no explicit state yet, mark it enabled.
    // Preserves an explicit enabled=false set later by the user.
    $state = load_state($STATE_F);
    if (!isset($state['enabled']) || !is_array($state['enabled'])) {
        $state['enabled'] = [];
    }
    if (!array_key_exists($pid, $state['enabled'])) {
        $state['enabled'][$pid] = true;
        save_json_file($STATE_F, $state);
    }

    echo json_encode([
        'ok'       => true,
        'provider' => $pid,
        'enabled'  => !empty($state['enabled'][$pid]),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: clear_key — delete a stored key
//
// NOTE (2026-05-07 fix): Also disable the provider in workers_state.json.
// Symmetric with set_key — clearing the key is intent to stop using the
// provider, so we flip enabled=false. The state entry stays present (just set
// to false) rather than being deleted, so the user's explicit choice is
// preserved across future set_key calls.
// =============================================================================
if ($action === 'clear_key') {
    $pid = safe_provider_id($in['provider'] ?? '');
    if (!$pid) { echo json_encode(['ok'=>false,'error'=>'Missing provider'], JSON_UNESCAPED_UNICODE); exit; }
    $keys = load_keys($KEYS_F);
    unset($keys[$pid]);
    save_keys($KEYS_F, $keys);

    $state = load_state($STATE_F);
    if (!isset($state['enabled']) || !is_array($state['enabled'])) {
        $state['enabled'] = [];
    }
    $state['enabled'][$pid] = false;
    save_json_file($STATE_F, $state);

    echo json_encode(['ok'=>true,'provider'=>$pid,'enabled'=>false], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: enable_provider — toggle on/off
// =============================================================================
if ($action === 'enable_provider') {
    $pid    = safe_provider_id($in['provider'] ?? '');
    $on     = !empty($in['enabled']);
    if (!$pid) { echo json_encode(['ok'=>false,'error'=>'Missing provider'], JSON_UNESCAPED_UNICODE); exit; }
    // Gate 1 of 2: a paid provider can't be ENABLED while the global master is OFF.
    if ($on) {
        $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
        $def     = find_provider_def($catalog, $pid);
        if (!empty($def['incurs_cost'])) {
            $settings = load_settings($SETTINGS_F);
            if (empty($settings['allow_paid_api_spend'])) {
                echo json_encode(['ok'=>false,'gate'=>'consent',
                    'error'=>'Enable paid API spend in Settings first (this provider costs money per call).'], JSON_UNESCAPED_UNICODE); exit;
            }
        }
    }
    $state = load_state($STATE_F);
    $state['enabled'][$pid] = $on;
    save_json_file($STATE_F, $state);
    echo json_encode(['ok'=>true,'provider'=>$pid,'enabled'=>$on], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// F4 — Action: test_key — verify a stored key against the provider's models endpoint
//
// Sends a minimal GET to {base}/models with the bearer token. 200 → active,
// 401/403 → invalid, anything else → unknown. Result is added to the response
// but NOT persisted (status drift can come from network blips; treat it as a
// snapshot the UI can show).
// =============================================================================
if ($action === 'test_key') {
    $pid = safe_provider_id($in['provider'] ?? '');
    if (!$pid) { echo json_encode(['ok'=>false,'error'=>'Missing provider'], JSON_UNESCAPED_UNICODE); exit; }
    $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
    $prov = null;
    foreach (($catalog['providers'] ?? []) as $p) {
        if (($p['id'] ?? '') === $pid) { $prov = $p; break; }
    }
    if (!$prov) { echo json_encode(['ok'=>false,'error'=>'Unknown provider'], JSON_UNESCAPED_UNICODE); exit; }
    $keys = load_keys($KEYS_F);
    $key  = $keys[$pid] ?? '';
    if ($key === '') { echo json_encode(['ok'=>true,'status'=>'no_key'], JSON_UNESCAPED_UNICODE); exit; }
    $base = rtrim((string)($prov['base'] ?? $prov['base_url'] ?? ''), '/');
    if ($base === '') { echo json_encode(['ok'=>true,'status'=>'unknown', 'note'=>'No base URL'], JSON_UNESCAPED_UNICODE); exit; }
    $url = $base . '/models';
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_HTTPHEADER     => provider_probe_headers((string)$pid, (string)$key),
        CURLOPT_TIMEOUT        => 10,
        CURLOPT_CONNECTTIMEOUT => 5,
    ]);
    $resp  = curl_exec($ch);
    $code  = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $cerr  = curl_error($ch);
    curl_close($ch);
    $status = 'unknown';
    if ($code === 200)      $status = 'active';
    else if ($code === 401) $status = 'invalid';
    else if ($code === 403) $status = 'invalid';
    else if ($code >= 400)  $status = 'unknown';
    else if ($cerr)         $status = 'unknown';
    echo json_encode(['ok'=>true, 'provider'=>$pid, 'status'=>$status,
                       'http_code'=>$code, 'error'=>$cerr ?: null], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// F4 — Action: test_all_keys — sweep every provider that has a stored key and
// report each one's status (active / invalid / unknown). Vault hardening: a
// one-click health check across all credentials.
// =============================================================================
// ── Web page workers: self-test, probe (what the page looks like, to tune an adapter), show / hide / stop the window ──────────────────────────────
if (in_array($action, ['ww_test', 'ww_probe', 'ww_show', 'ww_hide', 'ww_stop'], true)) {
    $wpid = safe_provider_id($in['provider'] ?? $_GET['provider'] ?? '');
    $wdef = $wpid ? find_provider_def(load_providers_catalog($PROVIDERS_F, __DIR__), $wpid) : null;
    if (!$wdef || ($wdef['type'] ?? '') !== 'webworker') { echo json_encode(['ok' => false, 'error' => 'Not a web page worker'], JSON_UNESCAPED_UNICODE); exit; }
    if (function_exists('session_status') && session_status() === PHP_SESSION_ACTIVE) session_write_close();
    if ($action === 'ww_test')  { $r = ww_selftest($wpid, (string)$wdef['url'], (array)$wdef['adapter']); if ($r['status'] === 'ok') health_mark($HEALTH_F, $wpid, 'web', 'ok', 0, ''); echo json_encode($r, JSON_UNESCAPED_UNICODE); exit; }
    if ($action === 'ww_probe') { echo json_encode(ww_probe($wpid, (string)$wdef['url']), JSON_UNESCAPED_UNICODE); exit; }
    if ($action === 'ww_stop')  { ww_stop($wpid); echo json_encode(['ok' => true]); exit; }
    $e = ww_ensure($wpid, (string)$wdef['url']); if ($e !== null) { echo json_encode(['ok' => false, 'error' => $e], JSON_UNESCAPED_UNICODE); exit; }
    ww_cmd(ww_dir($wpid), ['cmd' => $action === 'ww_show' ? 'show' : 'hide']); echo json_encode(['ok' => true]); exit;
}

if ($action === 'test_all_keys') {
    $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
    $keys    = load_keys($KEYS_F);
    $out = [];
    foreach (($catalog['providers'] ?? []) as $p) {
        $pid = $p['id'] ?? '';
        if ($pid === '') continue;
        $key = $keys[$pid] ?? '';
        if ($key === '') { $out[$pid] = 'no_key'; continue; }
        $base = rtrim((string)($p['base'] ?? $p['base_url'] ?? ''), '/');
        if ($base === '') { $out[$pid] = 'unknown'; continue; }
        $ch = curl_init($base . '/models');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER     => provider_probe_headers((string)$pid, (string)$key),
            CURLOPT_TIMEOUT        => 8,
            CURLOPT_CONNECTTIMEOUT => 4,
        ]);
        curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        if ($code === 200)               $out[$pid] = 'active';
        else if ($code===401||$code===403) $out[$pid] = 'invalid';
        else                              $out[$pid] = 'unknown';
    }
    echo json_encode(['ok'=>true, 'statuses'=>$out, 'tested_at'=>date('c')], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// F9 — Action: discover — probe every provider that has a stored key, hit its
// /models endpoint, and report reachability + a sample of available model ids.
// Read-only; does not modify state. Helps spot when a provider added new free
// models or when a key has expired.
// =============================================================================
if ($action === 'discover') {
    $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
    $keys    = load_keys($KEYS_F);
    $report  = [];
    foreach (($catalog['providers'] ?? []) as $p) {
        $pid  = $p['id'] ?? '';
        if ($pid === '') continue;
        $key  = $keys[$pid] ?? '';
        $base = rtrim((string)($p['base'] ?? $p['base_url'] ?? ''), '/');
        $entry = ['id'=>$pid, 'name'=>$p['name'] ?? $pid, 'has_key'=>($key!==''),
                  'reachable'=>false, 'model_count'=>0, 'sample'=>[], 'note'=>''];
        if ($key === '') { $entry['note'] = 'no key'; $report[] = $entry; continue; }
        if ($base === '') { $entry['note'] = 'no base URL'; $report[] = $entry; continue; }
        $ch = curl_init($base . '/models');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER     => provider_probe_headers((string)$pid, (string)$key),
            CURLOPT_TIMEOUT        => 10,
            CURLOPT_CONNECTTIMEOUT => 5,
        ]);
        $resp = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        if ($code === 200 && $resp) {
            $j = json_decode($resp, true);
            // OpenAI-style: { data: [ {id}, ... ] }; some return { models: [...] }
            $models = [];
            if (isset($j['data']) && is_array($j['data'])) {
                foreach ($j['data'] as $m) { if (!empty($m['id'])) $models[] = $m['id']; }
            } else if (isset($j['models']) && is_array($j['models'])) {
                foreach ($j['models'] as $m) { $models[] = is_array($m) ? ($m['id'] ?? ($m['name'] ?? '')) : (string)$m; }
            }
            $entry['reachable']   = true;
            $entry['model_count'] = count($models);
            $entry['sample']      = array_slice(array_filter($models), 0, 12);
            // Full list (capped) so the UI can offer a searchable pick-and-add.
            $entry['models']      = array_values(array_slice(array_filter($models), 0, 1000));
        } else if ($code === 401 || $code === 403) {
            $entry['note'] = 'key rejected (HTTP ' . $code . ')';
        } else {
            $entry['note'] = 'HTTP ' . $code;
        }
        $report[] = $entry;
    }
    echo json_encode(['ok'=>true, 'providers'=>$report], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// PAID-SPEND SAFETY STACK — settings, pricing, spend ledger, cost helpers.
// =============================================================================
function load_settings(string $f): array {
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    if (!is_array($j)) $j = [];
    return [
        'allow_paid_api_spend' => !empty($j['allow_paid_api_spend']),
        'caps' => [
            'global_monthly_usd'    => (float)($j['caps']['global_monthly_usd'] ?? 0),
            'per_model_monthly_usd' => is_array($j['caps']['per_model_monthly_usd'] ?? null) ? $j['caps']['per_model_monthly_usd'] : [],
        ],
    ];
}
function find_provider_def(array $catalog, string $pid): ?array {
    foreach (($catalog['providers'] ?? []) as $p) if (($p['id'] ?? '') === $pid) return $p;
    return null;
}

// ── Workers cascade helpers (Auto mode) ─────────────────────────────────────
// The set of a provider's free models (ids), for cascade eligibility.
function cascade_free_model_ids(?array $provDef): array {
    $ids = [];
    foreach (($provDef['models'] ?? []) as $m) if (!empty($m['free'])) $ids[] = (string)($m['id'] ?? '');
    return array_values(array_filter($ids));
}

// Default cascade order when the user hasn't set one: every enabled provider's
// free models, in catalog order, as "pid:model" strings. Paid providers excluded.
function cascade_default_order(array $catalog, array $state): array {
    $order = [];
    foreach (($catalog['providers'] ?? []) as $p) {
        $pid = (string)($p['id'] ?? '');
        if ($pid === '' || empty($state['enabled'][$pid]) || !empty($p['incurs_cost'])) continue;
        foreach (cascade_free_model_ids($p) as $mid) $order[] = $pid . ':' . $mid;
    }
    return $order;
}

// Remaining daily requests for a provider:model, or null when no daily cap is
// tracked (then we rely on a live 429 to detect exhaustion). Uses per-model
// call counts when available, else the provider-level count (matches
// usage_with_quota's approximation).
function cascade_remaining_rpd(string $pid, string $model, array $usage, array $quotas): ?int {
    $q = $quotas[$pid] ?? null;
    if (!$q || ($q['kind'] ?? '') !== 'daily_requests') return null;
    $mq    = $q['models'] ?? [];
    $limit = $mq[$model]['rpd'] ?? ($mq['*']['rpd'] ?? null);
    if ($limit === null) return null;
    $u = $usage[$pid] ?? [];
    $shared = !empty($mq['*']['shared_across_models']);
    if ($shared) {
        $used = (int)($u['calls'] ?? 0);
    } else {
        $used = isset($u['by_model'][$model]['calls'])
            ? (int)$u['by_model'][$model]['calls']
            : (int)($u['calls'] ?? 0);
    }
    return max(0, (int)$limit - $used);
}

// When a worker's quota window resets, as an ISO timestamp, from its anchor.
function cascade_reset_iso(array $quotas, string $pid): string {
    $anchor = $quotas[$pid]['anchor'] ?? 'midnight_utc';
    $utc = new DateTimeZone('UTC');
    $now = new DateTime('now', $utc);
    if ($anchor === 'calendar_first_of_month') return (clone $now)->modify('first day of next month 00:00')->format('c');
    if ($anchor === 'rolling_24h')             return (clone $now)->modify('+24 hours')->format('c');
    return (clone $now)->modify('tomorrow 00:00')->format('c');   // midnight_utc default
}

// Drop expired exhaustion marks. Returns [prunedState, changed].
function cascade_prune_exhausted(array $state): array {
    $ex = $state['exhausted'] ?? [];
    if (!is_array($ex) || !$ex) return [$state, false];
    $now = time(); $changed = false;
    foreach ($ex as $key => $iso) {
        if (strtotime((string)$iso) <= $now) { unset($ex[$key]); $changed = true; }
    }
    if ($changed) $state['exhausted'] = $ex;
    return [$state, $changed];
}
// [input_rate, output_rate] per 1M tokens (model override → provider → 0).
// $tin (the prompt size in tokens, when known) picks a model's long-context price: pricing.long_context = {over_tokens, input_per_mtok, output_per_mtok} (Haiku 5.5 costs more above 100,000 prompt tokens).
function model_rates(?array $prov, string $model, int $tin = 0): array {
    if (!$prov) return [0.0, 0.0];
    foreach (($prov['models'] ?? []) as $m) {
        if (($m['id'] ?? '') === $model && isset($m['pricing'])) {
            $lc = $m['pricing']['long_context'] ?? null;
            if (is_array($lc) && $tin > (int)($lc['over_tokens'] ?? PHP_INT_MAX)) return [(float)($lc['input_per_mtok'] ?? 0), (float)($lc['output_per_mtok'] ?? 0)];
            return [(float)($m['pricing']['input_per_mtok'] ?? 0), (float)($m['pricing']['output_per_mtok'] ?? 0)];
        }
    }
    if (isset($prov['pricing'])) return [(float)($prov['pricing']['input_per_mtok'] ?? 0), (float)($prov['pricing']['output_per_mtok'] ?? 0)];
    return [0.0, 0.0];
}
function cost_usd(int $tin, int $tout, float $in_rate, float $out_rate): float {
    return ($tin / 1e6) * $in_rate + ($tout / 1e6) * $out_rate;
}
function estimate_cost(string $prompt, array $extra, float $in_rate, float $out_rate): float {
    $tin  = (int)ceil(strlen($prompt) / 4);     // rough chars→tokens
    $tout = (int)($extra['max_tokens'] ?? 2000); // assume full output
    return cost_usd($tin, $tout, $in_rate, $out_rate);
}
function load_spend(string $f): array {
    $month = date('Y-m');
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    if (!is_array($j) || ($j['month'] ?? '') !== $month) return ['month'=>$month, 'global_usd'=>0.0, 'by_model'=>[]]; // monthly rollover
    return ['month'=>$month, 'global_usd'=>(float)($j['global_usd'] ?? 0), 'by_model'=>is_array($j['by_model'] ?? null) ? $j['by_model'] : []];
}
function bump_spend(string $f, string $modelKey, float $usd): void {
    $lock = @fopen($f, 'c+'); if (!$lock) return;
    if (!flock($lock, LOCK_EX)) { fclose($lock); return; }
    $s = load_spend($f);
    $s['global_usd'] = round($s['global_usd'] + $usd, 6);
    $s['by_model'][$modelKey] = round(($s['by_model'][$modelKey] ?? 0) + $usd, 6);
    ftruncate($lock, 0); rewind($lock);
    fwrite($lock, json_encode($s, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    fflush($lock); flock($lock, LOCK_UN); fclose($lock);
}

// Atomic cap-check + reservation. The old code checked the caps and *then*
// (after a multi-second API call) recorded the spend — a check-then-act race:
// two parallel paid calls could both read spend under the cap, both pass, and
// both spend, overshooting the cap by the sum of their estimates. We can't
// hold a file lock across the API call (it'd serialize every paid call and
// risk stale locks), so instead we RESERVE the estimated cost up front, under
// one lock, atomically with the check. A concurrent call then sees the
// reservation and is blocked correctly. reconcile_spend() below fixes the
// reserved estimate up to the real cost afterward (or refunds it on failure).
// Returns ['ok'=>true] on reservation, or ['ok'=>false,'gate'=>...] if capped.
function reserve_spend(string $f, string $modelKey, float $est, float $gCap, float $mCap): array {
    $lock = @fopen($f, 'c+');
    if (!$lock) return ['ok' => true]; // can't lock → fail open (matches prior best-effort posture)
    if (!flock($lock, LOCK_EX)) { fclose($lock); return ['ok' => true]; }
    $s = load_spend($f);
    if ($gCap > 0 && ($s['global_usd'] + $est) > $gCap) {
        flock($lock, LOCK_UN); fclose($lock);
        return ['ok' => false, 'gate' => 'global_cap'];
    }
    if ($mCap > 0 && (($s['by_model'][$modelKey] ?? 0) + $est) > $mCap) {
        flock($lock, LOCK_UN); fclose($lock);
        return ['ok' => false, 'gate' => 'model_cap'];
    }
    $s['global_usd']          = round($s['global_usd'] + $est, 6);
    $s['by_model'][$modelKey] = round(($s['by_model'][$modelKey] ?? 0) + $est, 6);
    ftruncate($lock, 0); rewind($lock);
    fwrite($lock, json_encode($s, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    fflush($lock); flock($lock, LOCK_UN); fclose($lock);
    return ['ok' => true];
}

// Adjust a prior reservation to the real cost. delta may be negative (real
// cost < estimate, or the call failed → pass $actual = 0.0 to refund the
// whole reservation). Clamps at 0 so a refund can never drive a total below 0.
function reconcile_spend(string $f, string $modelKey, float $reserved, float $actual): void {
    $delta = round($actual - $reserved, 6);
    if ($delta === 0.0) return;
    $lock = @fopen($f, 'c+'); if (!$lock) return;
    if (!flock($lock, LOCK_EX)) { fclose($lock); return; }
    $s = load_spend($f);
    $s['global_usd']          = round(max(0.0, $s['global_usd'] + $delta), 6);
    $s['by_model'][$modelKey] = round(max(0.0, ($s['by_model'][$modelKey] ?? 0) + $delta), 6);
    ftruncate($lock, 0); rewind($lock);
    fwrite($lock, json_encode($s, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    fflush($lock); flock($lock, LOCK_UN); fclose($lock);
}

// =============================================================================
// Action: invoke — call a worker (with the paid-spend safety gate)
// =============================================================================
// ── Chat context for the Workers path ────────────────────────────────────
// The queue loops give CLI agents their history (agent_loop.sh); a REST worker
// called from here got none and left none. With project+chat in the request,
// a text task gets the same gated, index-selected transcript in front of the
// prompt, and the exchange is written to the chat file afterwards (same
// writer the combos use, so the index stays current).
function workers_chat_file(array $in): string {
    global $PATHS;
    $project = str_replace(['/', '\\', '..'], '', (string)($in['project'] ?? ''));
    $chat    = str_replace(['/', '\\', '..'], '', (string)($in['chat'] ?? ''));
    if ($project === '' || $chat === '' || empty($PATHS['projects_root'])) return '';
    return rtrim((string)$PATHS['projects_root'], '/') . '/' . $project . '/chat_' . $chat . '.json';
}
function workers_history_block(array $in, string $task, string $prompt): string {
    if ($task !== 'text') return '';
    $f = workers_chat_file($in);
    if ($f === '') return '';
    require_once __DIR__ . '/chat_history.php';
    return chat_history_block($f, $prompt, 'WORKERS');
}
// One line per call in <cockpit_data>/workers_activity.log — what the Workers
// card's "open" button tails (2026-09-13). Never the prompt or the answer.
function workers_activity(string $what, string $task, array $result, int $elapsed): void {
    global $CD;
    $line = sprintf("%s  %-32s %-9s %-4s %6d ms  in=%s out=%s%s\n", date('Y-m-d H:i:s'), $what, $task,
        !empty($result['ok']) ? 'ok' : 'ERR', $elapsed,
        $result['tokens_in'] ?? '-', $result['tokens_out'] ?? '-',
        !empty($result['ok']) ? '' : '  ' . mb_substr((string)($result['error'] ?? ''), 0, 120));
    @file_put_contents($CD . '/workers_activity.log', $line, FILE_APPEND | LOCK_EX);
}
function workers_save_turn(array $in, string $task, string $prompt, array $result, string $model): void {
    global $PATHS;
    if ($task !== 'text' || empty($result['ok']) || workers_chat_file($in) === '') return;
    $out = (string)($result['output'] ?? '');
    if ($out === '') return;
    require_once __DIR__ . '/combos_core.php';
    $san = fn($v) => preg_replace('/[^a-z]/', '', strtolower((string)$v));
    combos_append_chat((string)$PATHS['projects_root'], (string)$in['project'], (string)$in['chat'], $prompt, $out, $model, 'workers',
        ['mode' => $san($in['ma_mode'] ?? ''), 'style' => $san($in['style'] ?? ''), 'supplier' => 'workers']);
}

if ($action === 'invoke') {
    $pid    = safe_provider_id($in['provider'] ?? '');
    $model  = safe_model_id($in['model'] ?? '');
    $task   = trim((string)($in['task']   ?? 'text'));
    $prompt = (string)($in['prompt'] ?? '');
    $extra  = is_array($in['extra'] ?? null) ? $in['extra'] : [];
    // pictures: only the Anthropic worker takes them, at most 5, each at most ~5 MB of base64, and only real image types; anything else from the client is dropped
    if ($pid !== 'anthropic') unset($extra['images']);
    else if (isset($extra['images'])) $extra['images'] = array_values(array_filter(array_slice((array)$extra['images'], 0, 5), fn($im) => is_array($im) && in_array((string)($im['media_type'] ?? ''), ['image/jpeg', 'image/png', 'image/gif', 'image/webp'], true) && is_string($im['data'] ?? null) && strlen($im['data']) > 0 && strlen($im['data']) <= 7000000));
    // The client sends prompt = what the worker should receive (directive preamble,
    // caveman compression) and user_text = the user's own words. Gate, keyword
    // query and the chat file all use the latter.
    $userText = (string)($in['user_text'] ?? $prompt);
    $history  = workers_history_block($in, $task, $userText);   // '' when not needed
    // Push-RAG, same as the CLI/local path in bridge.php: when the capability is on,
    // the best library matches for this prompt ride along (2026-09-22).
    $ragTitles = [];
    if ($task === 'text') {
        require_once __DIR__ . '/rag_lib.php';
        [$ragBlock, $ragTitles] = rag_context($userText, (string)$PATHS['cockpit_data'],
            (string)($PATHS['projects_root'] ?? ''), (string)($in['project'] ?? ''));
        if ($ragBlock !== '') $prompt = $ragBlock . "\n\n" . $prompt;
    }

    if (!$pid || !$model || $prompt === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing provider/model/prompt'], JSON_UNESCAPED_UNICODE); exit;
    }
    if (resolve_invoker($pid, find_provider_def(load_providers_catalog($PROVIDERS_F, __DIR__), $pid)) === null) {
        echo json_encode(['ok'=>false,'error'=>'Unknown provider: '.$pid], JSON_UNESCAPED_UNICODE); exit;
    }

    $state = load_state($STATE_F);
    if (empty($state['enabled'][$pid])) {
        echo json_encode(['ok'=>false,'error'=>'Provider not enabled: '.$pid], JSON_UNESCAPED_UNICODE); exit;
    }

    // ── Paid-spend safety gate (server-side; cannot be bypassed by the UI) ──
    $catalog  = load_providers_catalog($PROVIDERS_F, __DIR__);
    $provDef  = find_provider_def($catalog, $pid);
    $incurs   = !empty($provDef['incurs_cost']);
    $modelKey = $pid . ':' . $model;
    $rates    = [0.0, 0.0];
    $spend_reserved = 0.0; // >0 once reserve_spend() has debited an estimate
    if ($incurs) {
        $settings = load_settings($SETTINGS_F);
        if (empty($settings['allow_paid_api_spend'])) {
            echo json_encode(['ok'=>false,'error'=>'Paid API spend is OFF. Enable it in Settings (with consent) first.','gate'=>'consent'], JSON_UNESCAPED_UNICODE); exit;
        }
        $rates    = model_rates($provDef, $model, (int)ceil(strlen($prompt) / 4));
        if (($rates[0] + $rates[1]) <= 0 && ((float)$settings['caps']['global_monthly_usd'] > 0 || (float)($settings['caps']['per_model_monthly_usd'][$modelKey] ?? 0) > 0)) {
            echo json_encode(['ok'=>false,'gate'=>'no_price','error'=>'No price is known for '.$modelKey.', so the monthly cap cannot be enforced on it. Add its price to the provider list, or turn the cap off.'], JSON_UNESCAPED_UNICODE); exit;
        }
        $est      = estimate_cost($prompt, $extra, $rates[0], $rates[1]);
        $gCap     = (float)$settings['caps']['global_monthly_usd'];
        $mCap     = (float)($settings['caps']['per_model_monthly_usd'][$modelKey] ?? 0);
        // Atomic cap-check + reservation (see reserve_spend): closes the
        // check-then-act race where parallel calls could both pass the cap.
        $reserve = reserve_spend($SPEND_F, $modelKey, $est, $gCap, $mCap);
        if (empty($reserve['ok'])) {
            if (($reserve['gate'] ?? '') === 'global_cap') {
                echo json_encode(['ok'=>false,'gate'=>'global_cap',
                    'error'=>'Monthly global paid-API cap ($'.rtrim(rtrim(number_format($gCap,2),'0'),'.').') would be exceeded. Raise it in Settings or wait for reset.'], JSON_UNESCAPED_UNICODE); exit;
            }
            echo json_encode(['ok'=>false,'gate'=>'model_cap',
                'error'=>'Monthly cap for '.$modelKey.' ($'.rtrim(rtrim(number_format($mCap,2),'0'),'.').') would be exceeded.'], JSON_UNESCAPED_UNICODE); exit;
        }
        $spend_reserved = $est; // reconcile to the real cost after the call
    }

    $keys = load_keys($KEYS_F);
    $key  = $keys[$pid] ?? '';

    // Dispatch — pass the catalog base_url (#1) so a host change is a JSON edit.
    $handler = resolve_invoker($pid, $provDef);
    $base    = (string)($provDef['base_url'] ?? '');
    $start   = microtime(true);
    $stream = false; $streamFn = null;
    if ($pid === 'anthropic') {
        // Anthropic takes the identity line and the earlier conversation as a real system prompt (cacheable when long), not glued to the user's words.
        $promptWithIdentity = $prompt;
        $extra['system'] = trim(worker_identity_line($provDef, $pid, $model) . $history);
        $extra['cache']  = true;
        $stream = !empty($in['stream']) && $task === 'text';
    } else {
        $promptWithIdentity = worker_identity_line($provDef, $pid, $model) . $history . $prompt;
        $stream = !empty($in['stream']) && $task === 'text' && (isset(OPENAI_STREAM_CFG[$pid]) || ($provDef['type'] ?? '') === 'webworker');
    }
    if ($stream) {
        // Server-sent events: data: {"chunk":"..."} per piece, then data: {"final":{...the usual result...}} and data: [DONE]
        if (function_exists('session_status') && session_status() === PHP_SESSION_ACTIVE) session_write_close();
        header('Content-Type: text/event-stream'); header('Cache-Control: no-cache'); header('X-Accel-Buffering: no');
        while (ob_get_level() > 0) @ob_end_flush();
        $emitSse = function (string $piece) { echo 'data: ' . json_encode(['chunk' => $piece], JSON_UNESCAPED_UNICODE) . "\n\n"; @flush(); };
        if ($pid === 'anthropic') $result = invoke_anthropic_stream($model, $task, $promptWithIdentity, $key, $extra, $base, $emitSse);
        elseif (($provDef['type'] ?? '') === 'webworker') $result = ww_run($pid, (string)$provDef['url'], (array)$provDef['adapter'], (string)$promptWithIdentity, $emitSse);
        else $result = invoke_openai_compat_stream($pid, $model, $task, $promptWithIdentity, $key, $extra, $base, $emitSse);
    } else {
        $result  = $handler($model, $task, $promptWithIdentity, $key, $extra, $base);
    }
    $elapsed = round((microtime(true) - $start) * 1000);
    workers_activity($pid . ':' . $model, $task, $result, (int)$elapsed);

    // Self-heal (#4): classify failures and record provider/model health so Auto
    // routing can skip dead/degraded models. Success clears the mark.
    if (!empty($result['ok'])) {
        health_mark($HEALTH_F, $pid, $model, 'ok', 0, '');
    } else {
        [$st, $code, $why] = health_classify((string)($result['error'] ?? ''));
        if ($st !== 'transient' && empty($result['needs_login']) && empty($result['blocked'])) health_mark($HEALTH_F, $pid, $model, $st, $code, $why);   // a login or a check is not a broken model
    }

    // Track usage. G6: include model for per-model pool breakdown.
    bump_usage($USAGE_F, $pid, $task, [
        'tokens_in'  => $result['tokens_in']  ?? null,
        'tokens_out' => $result['tokens_out'] ?? null,
        'error'      => empty($result['ok']),
        'model'      => $model,
    ]);

    // Reconcile the reservation made before the call (see reserve_spend). On
    // success: adjust the reserved estimate up/down to the real cost. On
    // failure: refund the whole reservation (actual = 0). Either way the cap
    // stays correctly enforced against concurrent calls, since the estimate
    // was already debited atomically at the gate.
    if ($incurs && $spend_reserved > 0.0) {
        if (!empty($result['ok'])) {
            $tin    = (int)($result['tokens_in']  ?? ceil(strlen($prompt) / 4));
            $tout   = (int)($result['tokens_out'] ?? ($extra['max_tokens'] ?? 2000));
            $ra     = model_rates($provDef, $model, $tin);   // the real prompt size decides the tier
            $actual = cost_usd($tin, $tout, $ra[0], $ra[1]);
            reconcile_spend($SPEND_F, $modelKey, $spend_reserved, $actual);
            $result['cost_usd'] = round($actual, 6);
        } else {
            // Call failed — refund the reservation so a failed call costs nothing.
            reconcile_spend($SPEND_F, $modelKey, $spend_reserved, 0.0);
        }

        // 80% spend-cap warning (on success only — a refunded failure won't trip it)
        if (!empty($result['ok'])) {
            $freshSpend = load_spend($SPEND_F);
            $warnings = [];
            if ($gCap > 0) {
                $pct = $freshSpend['global_usd'] / $gCap;
                if ($pct >= 0.8) $warnings[] = 'Global spend at '.round($pct*100).'% of $'.number_format($gCap,2).' cap';
            }
            if ($mCap > 0) {
                $mPct = ($freshSpend['by_model'][$modelKey] ?? 0) / $mCap;
                if ($mPct >= 0.8) $warnings[] = $modelKey.' spend at '.round($mPct*100).'% of $'.number_format($mCap,2).' cap';
            }
            if ($warnings) $result['spend_warnings'] = $warnings;
        }
    }

    $result['provider']      = $pid;
    $result['model']         = $model;
    $result['elapsed_ms']    = $elapsed;
    workers_save_turn($in, $task, $userText, $result, $pid . ':' . $model);
    $result['history_used']  = $history !== '';
    if ($ragTitles) $result["rag"] = $ragTitles;   // say what push-RAG added
    if ($stream) { echo 'data: ' . json_encode(['final' => $result], JSON_UNESCAPED_UNICODE) . "\n\ndata: [DONE]\n\n"; exit; }
    echo json_encode($result, JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: cascade_invoke — "Auto (cascade)" mode.
// Walk the priority-ordered list of enabled FREE workers; skip any that are
// health-dead, quota-exhausted (preflight), or marked exhausted from a prior
// 429 (until their reset window). Invoke the first eligible one; on a live 429
// mark it exhausted and continue to the next. Returns the first success plus an
// `attempts` trace, or a summary when everything is exhausted.
// Input: { task?, prompt, extra? }
// =============================================================================
if ($action === 'cascade_invoke') {
    $task   = trim((string)($in['task'] ?? 'text'));
    $prompt = (string)($in['prompt'] ?? '');
    $extra  = is_array($in['extra'] ?? null) ? $in['extra'] : [];
    if ($prompt === '') { echo json_encode(['ok'=>false,'error'=>'Missing prompt'], JSON_UNESCAPED_UNICODE); exit; }
    $userText = (string)($in['user_text'] ?? $prompt);
    $history  = workers_history_block($in, $task, $userText);

    $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
    $state   = load_state($STATE_F);
    [$state, $pruned] = cascade_prune_exhausted($state);
    $usage   = load_usage($USAGE_F);
    $quotas  = is_file($QUOTAS_F) ? (json_decode((string)file_get_contents($QUOTAS_F), true) ?: []) : [];
    $health  = health_load($HEALTH_F);
    $keys    = load_keys($KEYS_F);

    $order = (isset($state['cascade_order']) && is_array($state['cascade_order']) && $state['cascade_order'])
        ? $state['cascade_order'] : [];
    // A saved order can name models the catalog no longer has (Groq retired its
    // llama-3.x line). Drop those; if nothing usable remains, fall back to the
    // default order so the cascade does not report "no workers" while an
    // enabled provider with live models sits right there.
    $order = array_values(array_filter($order, function ($e) use ($catalog) {
        $pos = strpos((string)$e, ':'); if ($pos === false) return false;
        $p = find_provider_def($catalog, substr($e, 0, $pos)); if (!$p) return false;
        return in_array(substr($e, $pos + 1), cascade_free_model_ids($p), true);
    }));
    if (!$order) $order = cascade_default_order($catalog, $state);
    // web page workers are the slowest and least reliable: always after every API worker, whatever the saved order says
    $isWw = function ($e) use ($catalog) { $p = find_provider_def($catalog, (string)strstr((string)$e, ':', true)); return ($p['type'] ?? '') === 'webworker'; };
    $order = array_merge(array_values(array_filter($order, fn($e) => !$isWw($e))), array_values(array_filter($order, $isWw)));

    $now = time();
    $attempts = [];
    $earliest_reset = null;

    foreach ($order as $entry) {
        $entry = (string)$entry;
        $pos   = strpos($entry, ':');
        if ($pos === false) continue;
        $pid   = safe_provider_id(substr($entry, 0, $pos));
        $model = safe_model_id(substr($entry, $pos + 1));
        if (!$pid || !$model) continue;

        $provDef = find_provider_def($catalog, $pid);
        if (!$provDef) { $attempts[] = ['worker'=>$entry,'skipped'=>'unknown']; continue; }
        if (empty($state['enabled'][$pid])) { $attempts[] = ['worker'=>$entry,'skipped'=>'disabled']; continue; }
        if (resolve_invoker($pid, $provDef) === null) { $attempts[] = ['worker'=>$entry,'skipped'=>'no_invoker']; continue; }
        if (!empty($provDef['incurs_cost'])) { $attempts[] = ['worker'=>$entry,'skipped'=>'paid']; continue; }
        if (!in_array($model, cascade_free_model_ids($provDef), true)) { $attempts[] = ['worker'=>$entry,'skipped'=>'not_free']; continue; }

        // Health: skip dead provider or model.
        $pdead = (($health[$pid]['status'] ?? 'ok') === 'dead');
        $mdead = (($health[$pid.':'.$model]['status'] ?? 'ok') === 'dead');
        if ($pdead || $mdead) { $attempts[] = ['worker'=>$entry,'skipped'=>'dead']; continue; }

        // Exhausted from a prior 429, still within its reset window.
        $exIso = $state['exhausted'][$entry] ?? null;
        if ($exIso && strtotime((string)$exIso) > $now) {
            $attempts[] = ['worker'=>$entry,'skipped'=>'exhausted','resets_at'=>$exIso];
            $earliest_reset = ($earliest_reset === null) ? $exIso : min($earliest_reset, $exIso);
            continue;
        }

        // Preflight daily quota.
        $rem = cascade_remaining_rpd($pid, $model, $usage, $quotas);
        if ($rem !== null && $rem <= 0) {
            $reset = cascade_reset_iso($quotas, $pid);
            $state['exhausted'][$entry] = $reset;
            $attempts[] = ['worker'=>$entry,'skipped'=>'quota','resets_at'=>$reset];
            $earliest_reset = ($earliest_reset === null) ? $reset : min($earliest_reset, $reset);
            continue;
        }

        // Invoke this worker.
        $key    = $keys[$pid] ?? '';
        $base   = (string)($provDef['base_url'] ?? '');
        $handler= resolve_invoker($pid, $provDef);
        $start  = microtime(true);
        $result = $handler($model, $task, worker_identity_line($provDef, $pid, $model) . $history . $prompt, $key, $extra, $base);
        $elapsed= round((microtime(true) - $start) * 1000);
        workers_activity($entry . " (cascade)", $task, $result, (int)$elapsed);

        bump_usage($USAGE_F, $pid, $task, [
            'tokens_in'=>$result['tokens_in'] ?? null, 'tokens_out'=>$result['tokens_out'] ?? null,
            'error'=>empty($result['ok']), 'model'=>$model,
        ]);

        if (!empty($result['ok'])) {
            health_mark($HEALTH_F, $pid, $model, 'ok', 0, '');
            save_json_file($STATE_F, $state);   // persist any exhaustion marks + prunes
            $result['provider']   = $pid;
            $result['model']      = $model;
            $result['served_by']  = $entry;
            $result['elapsed_ms'] = $elapsed;
            $result['attempts']   = $attempts;
            workers_save_turn($in, $task, $userText, $result, $entry);
            $result['history_used'] = $history !== '';
            echo json_encode($result, JSON_UNESCAPED_UNICODE); exit;
        }

        if (!empty($result['needs_login']) || !empty($result['blocked'])) {   // the person has to do something at the site: do not ask again for 30 minutes
            $state['exhausted'][$entry] = gmdate('c', $now + 1800);
            $attempts[] = ['worker'=>$entry,'failed'=>!empty($result['blocked']) ? 'needs_check' : 'needs_login'];
            continue;
        }
        // Failure — classify. Rate-limit → mark exhausted + advance; other →
        // record health (non-transient) and advance best-effort.
        [$st, $code, $why] = health_classify((string)($result['error'] ?? ''));
        if ($code === 429 || $st === 'transient') {
            $reset = cascade_reset_iso($quotas, $pid);
            $state['exhausted'][$entry] = $reset;
            $attempts[] = ['worker'=>$entry,'failed'=>'rate_limited','resets_at'=>$reset];
            $earliest_reset = ($earliest_reset === null) ? $reset : min($earliest_reset, $reset);
        } else {
            health_mark($HEALTH_F, $pid, $model, $st, $code, $why);
            $attempts[] = ['worker'=>$entry,'failed'=>$why];
        }
    }

    // Nothing served.
    save_json_file($STATE_F, $state);
    echo json_encode([
        'ok'=>false,
        'error'=>'All workers are exhausted or unavailable right now.',
        'cascade_empty'=>empty($attempts),
        'attempts'=>$attempts,
        'next_available_at'=>$earliest_reset,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: get_cascade_order / set_cascade_order — the Auto-mode priority list.
// Order is an array of "provider:model" strings. get returns the saved order or
// the default (enabled free models, catalog order) so the UI can render + edit.
// =============================================================================
if ($action === 'get_cascade_order') {
    $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
    $state   = load_state($STATE_F);
    $saved   = (isset($state['cascade_order']) && is_array($state['cascade_order'])) ? $state['cascade_order'] : [];
    $default = cascade_default_order($catalog, $state);
    // Merge: keep saved entries still valid (in default set), then append any
    // newly-available workers not yet in the saved order.
    $validSet = array_flip($default);
    $order = [];
    foreach ($saved as $e) { $e=(string)$e; if (isset($validSet[$e]) && !in_array($e,$order,true)) $order[] = $e; }
    foreach ($default as $e) if (!in_array($e, $order, true)) $order[] = $e;
    echo json_encode(['ok'=>true, 'order'=>$order, 'is_custom'=>!empty($saved)], JSON_UNESCAPED_UNICODE);
    exit;
}
if ($action === 'set_cascade_order') {
    $order = is_array($in['order'] ?? null) ? $in['order'] : [];
    $clean = [];
    foreach ($order as $e) {
        $e = (string)$e; $pos = strpos($e, ':'); if ($pos === false) continue;
        $pid = safe_provider_id(substr($e,0,$pos)); $model = safe_model_id(substr($e,$pos+1));
        if ($pid && $model) $clean[] = $pid.':'.$model;
    }
    $state = load_state($STATE_F);
    $state['cascade_order'] = $clean;
    save_json_file($STATE_F, $state);
    echo json_encode(['ok'=>true, 'order'=>$clean], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: usage — usage snapshot per provider
// =============================================================================
if ($action === 'usage') {
    echo json_encode(['ok'=>true, 'usage' => load_usage($USAGE_F)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: health — active drift sweep (#3). DNS-resolves each enabled provider's
// base_url host (catches the HF-style "host removed" death cheaply, no paid gen)
// and merges the passive per-model marks recorded on invoke. Updates the store.
// =============================================================================
if ($action === 'health') {
    $catalog = load_providers_catalog($PROVIDERS_F, __DIR__);
    $state   = load_state($STATE_F);
    $store   = health_load($HEALTH_F);
    $rows    = [];
    foreach (($catalog['providers'] ?? []) as $p) {
        $pid = $p['id'] ?? ''; if ($pid === '') continue;
        $enabled = !empty($state['enabled'][$pid]);
        $base = (string)($p['base_url'] ?? '');
        $host = $base ? parse_url($base, PHP_URL_HOST) : '';
        $dns_ok = $host ? (bool)@gethostbynamel($host) : null;
        // Active DNS failure on an enabled provider = dead endpoint.
        if ($enabled && $host && $dns_ok === false) {
            health_mark($HEALTH_F, $pid, '', 'dead', 0, 'host ' . $host . ' unresolved');
        }
        $store = health_load($HEALTH_F);   // re-read (mark above may have written)
        $pstat = $store[$pid]['status'] ?? 'ok';
        // Per-model passive marks.
        $models = [];
        foreach (($p['models'] ?? []) as $m) {
            $mk = $pid . ':' . ($m['id'] ?? '');
            if (isset($store[$mk])) $models[$m['id']] = $store[$mk];
        }
        $rows[] = [
            'provider' => $pid, 'name' => $p['name'] ?? $pid, 'enabled' => $enabled,
            'host' => $host, 'dns_ok' => $dns_ok,
            'status' => $enabled ? $pstat : 'ok',
            'reason' => $store[$pid]['reason'] ?? '', 'at' => $store[$pid]['at'] ?? '',
            'models' => $models,
        ];
    }
    echo json_encode(['ok'=>true, 'rows'=>$rows, 'checked_at'=>date('c')], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: reset_usage — wipe usage counters for one provider
//
// 2026-05-09 fix: previously this `unset()`-ed the entire entry, which
// meant `last_reset_at` either disappeared or was repopulated by the next
// bump_usage() call (showing first-call-after-reset time, not the reset
// time itself). Now we zero counters in place and stamp last_reset_at
// with the actual reset moment, preserving any custom fields and giving
// the UI an accurate "since last reset" anchor.
// =============================================================================
if ($action === 'reset_usage') {
    $pid = safe_provider_id($in['provider'] ?? '');
    if (!$pid) { echo json_encode(['ok'=>false,'error'=>'Missing provider'], JSON_UNESCAPED_UNICODE); exit; }
    $usage = load_usage($USAGE_F);
    $now = date('c');
    $usage[$pid] = [
        'calls'         => 0,
        'errors'        => 0,
        'last_call_at'  => null,
        'last_reset_at' => $now,
        'by_kind'       => [],
        'tokens_in'     => 0,
        'tokens_out'    => 0,
    ];
    save_json_file($USAGE_F, $usage);
    echo json_encode(['ok'=>true, 'reset_at'=>$now], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: reset_all_usage — wipe ALL providers' usage counters
// Phase 2b 2026-05-09. Keeps the same in-place pattern as reset_usage; just
// applies it to every provider that already has a usage entry.
// =============================================================================
if ($action === 'reset_all_usage') {
    $usage = load_usage($USAGE_F);
    $now = date('c');
    $count = 0;
    foreach ($usage as $pid => $_) {
        $usage[$pid] = [
            'calls'         => 0,
            'errors'        => 0,
            'last_call_at'  => null,
            'last_reset_at' => $now,
            'by_kind'       => [],
            'tokens_in'     => 0,
            'tokens_out'    => 0,
        ];
        $count++;
    }
    save_json_file($USAGE_F, $usage);
    echo json_encode(['ok'=>true, 'reset_at'=>$now, 'reset_count'=>$count], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: usage_with_quota — joined usage + quota view
//
// Phase 2b 2026-05-09. Returns a structured payload combining:
//   - workers_usage.json (consumption counters, already maintained by
//     bump_usage on each invoke)
//   - workers_state.json (which providers are enabled — only enabled ones
//     are included in the response)
//   - workers_providers.json (catalog: which models are individually free)
//   - workers_quotas.json (quota limits per provider/model + reset anchor)
//
// Per-row output structure:
//   {
//     provider: "groq",
//     name: "Groq",
//     enabled: true,
//     kind: "daily_requests" | "consumption_only",
//     anchor: "midnight_utc" | null,
//     last_verified_at: "2026-05-09",
//     verified_age_days: <int>,
//     usage: { calls, tokens_in, tokens_out, errors, last_call_at, last_reset_at },
//     quota: {                          // omitted when kind = consumption_only
//       rpd, rpm, tpm,                  // per-model numbers (or wildcard fallback)
//       used_today: <calls>,            // best-effort: calls since last_reset_at
//       remaining_rpd: <int|null>,
//       cycle_resets_at: "<ISO time>",
//       seconds_to_reset: <int>,
//     }
//   }
//
// Frontend uses this for the inline indicator on the Workers card and the
// detailed Usage Stats side-panel. The 4-second status poll picks it up
// so countdowns stay live without dedicated polling logic.
// =============================================================================
if ($action === 'usage_with_quota') {
    $usage    = load_usage($USAGE_F);
    $state    = load_state($STATE_F);
    $catalog  = load_providers_catalog($PROVIDERS_F, __DIR__);
    $quotas   = is_file($QUOTAS_F)
                    ? (json_decode((string)file_get_contents($QUOTAS_F), true) ?: [])
                    : [];

    $now_ts   = time();
    // MED-70: use UTC for "today" to match the UTC quota reset anchor below.
    // Otherwise users in non-UTC timezones see "today" cross at local midnight
    // but quotas reset at UTC midnight — making the displayed counter wrong.
    $today    = gmdate('Y-m-d');
    $rows     = [];

    // Compute next midnight UTC ISO timestamp (used by daily_* quota kinds)
    $tz_utc        = new DateTimeZone('UTC');
    $now_utc       = new DateTime('now', $tz_utc);
    $next_midnight = (clone $now_utc)->modify('tomorrow 00:00');
    $next_midnight_iso     = $next_midnight->format('c');
    $secs_to_midnight      = $next_midnight->getTimestamp() - $now_utc->getTimestamp();

    // Walk catalog providers; include only enabled ones
    foreach ($catalog['providers'] as $prov) {
        $pid = $prov['id'];
        if (empty($state['enabled'][$pid])) continue;

        // Filter model list to only those individually marked free
        $free_models = [];
        foreach (($prov['models'] ?? []) as $m) {
            if (!empty($m['free'])) $free_models[] = $m;
        }
        // Provider has zero free models — skip entirely (per the design:
        // "those with no free tier should be excluded")
        if (count($free_models) === 0) continue;

        $u = $usage[$pid] ?? [
            'calls'=>0, 'errors'=>0,
            'last_call_at'=>null, 'last_reset_at'=>null,
            'by_kind'=>[], 'tokens_in'=>0, 'tokens_out'=>0,
        ];

        $q = $quotas[$pid] ?? null;
        $kind = $q['kind'] ?? 'consumption_only';

        // Verified-age computation for the amber-when-stale UI hint
        $verified_age_days = null;
        if (!empty($q['last_verified_at'])) {
            $vts = strtotime($q['last_verified_at']);
            if ($vts !== false) {
                $verified_age_days = (int)floor(($now_ts - $vts) / 86400);
            }
        }

        $row = [
            'provider'           => $pid,
            'name'               => $prov['name'] ?? $pid,
            'enabled'            => true,
            'kind'               => $kind,
            'anchor'             => $q['anchor'] ?? null,
            'last_verified_at'   => $q['last_verified_at'] ?? null,
            'verified_age_days'  => $verified_age_days,
            'free_model_count'   => count($free_models),
            'free_models'        => array_values(array_map(function($m){
                return ['id'=>$m['id'], 'label'=>$m['label'] ?? $m['id']];
            }, $free_models)),
            'usage'              => [
                'calls'           => intval($u['calls'] ?? 0),
                'errors'          => intval($u['errors'] ?? 0),
                'tokens_in'       => intval($u['tokens_in'] ?? 0),
                'tokens_out'      => intval($u['tokens_out'] ?? 0),
                'last_call_at'    => $u['last_call_at'] ?? null,
                'last_reset_at'   => $u['last_reset_at'] ?? null,
                'by_kind'         => $u['by_kind'] ?? [],
                'by_model'        => $u['by_model'] ?? [],   // G6: per-model breakdown for pool quotas
            ],
        ];

        // Quota math — only meaningful for daily_requests kind in v1
        if ($kind === 'daily_requests') {
            // Pick a representative limit set: prefer wildcard '*' for the
            // top-level summary; per-model breakdowns happen in the UI.
            $models_q = $q['models'] ?? [];
            $wild     = $models_q['*'] ?? null;

            // For OpenRouter style: if shared_across_models, the quota
            // applies pool-wide regardless of which model was called.
            $is_shared = !empty($wild['shared_across_models']);

            // Used-today: best-effort. We don't have per-day call counts;
            // approximate via "calls since last_reset_at" if reset is today,
            // otherwise total calls. Imperfect but useful for trend display.
            $used_today = intval($u['calls'] ?? 0);
            if (!empty($u['last_reset_at'])) {
                $reset_day = substr($u['last_reset_at'], 0, 10);
                if ($reset_day !== $today) {
                    // Calls accumulated across multiple days — show total
                    // but flag the imprecision in the response.
                    $used_today = intval($u['calls'] ?? 0);
                }
            }

            $rpd_limit = $wild['rpd'] ?? null;
            $remaining = ($rpd_limit !== null) ? max(0, $rpd_limit - $used_today) : null;

            $row['quota'] = [
                'rpd'                => $rpd_limit,
                'rpm'                => $wild['rpm'] ?? null,
                'tpm'                => $wild['tpm'] ?? null,
                'shared_across_models' => $is_shared,
                'used_today'         => $used_today,
                'remaining_rpd'      => $remaining,
                'cycle_resets_at'    => $next_midnight_iso,
                'seconds_to_reset'   => $secs_to_midnight,
                'per_model'          => $models_q,  // full per-model table for UI
            ];
        }

        $rows[] = $row;
    }

    echo json_encode([
        'ok'          => true,
        'rows'        => $rows,
        'server_time' => date('c'),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: update_quota — edit a provider's quota config from the UI
//
// Phase 2b 2026-05-09. Used by the Edit Quota dialog to persist hand-tuned
// limits back into workers_quotas.json. Caller passes the entire provider
// block; we replace the existing entry verbatim and stamp last_verified_at
// to today (since the user just verified by editing).
//
// Validation: provider id must match catalog; quota fields are loosely
// validated (non-negative ints, allowed kinds). The schema is permissive
// because providers may evolve (new metering kinds in future) and we
// don't want to fight every edit through strict validation.
// =============================================================================
if ($action === 'update_quota') {
    $pid    = safe_provider_id($in['provider'] ?? '');
    $config = is_array($in['config'] ?? null) ? $in['config'] : null;
    if (!$pid || !$config) {
        echo json_encode(['ok'=>false, 'error'=>'Missing provider or config'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Light validation: kind must be one of known values
    $allowed_kinds = ['daily_requests', 'monthly_requests', 'consumption_only', 'monthly_dollars'];
    if (isset($config['kind']) && !in_array($config['kind'], $allowed_kinds, true)) {
        echo json_encode(['ok'=>false, 'error'=>'Unknown kind: ' . $config['kind']], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Stamp the verification date — user just edited, so it counts as verified
    $config['last_verified_at'] = date('Y-m-d');

    // Load existing, replace this provider's block, save
    $quotas = is_file($QUOTAS_F)
                ? (json_decode((string)file_get_contents($QUOTAS_F), true) ?: [])
                : [];
    $quotas[$pid] = $config;
    save_json_file($QUOTAS_F, $quotas);

    echo json_encode(['ok'=>true, 'last_verified_at'=>$config['last_verified_at']], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: add_custom — register a user-provided custom provider
//
// NEW BEHAVIOUR (Tools Staleness Fix 2026-05-12):
//   Appends the new provider to overlay.custom_providers.
//   The shipped catalog is never touched.
// =============================================================================
if ($action === 'add_custom') {
    $pid    = safe_provider_id($in['provider'] ?? '');
    $name   = trim((string)($in['name'] ?? ''));
    $models = is_array($in['models'] ?? null) ? $in['models'] : [];
    if (!$pid || $name === '' || !$models) {
        echo json_encode(['ok'=>false,'error'=>'Missing provider/name/models'], JSON_UNESCAPED_UNICODE); exit;
    }
    // Custom providers must use a base provider's API shape
    $base = safe_provider_id($in['base'] ?? '');
    if (!isset($INVOKERS[$base])) {
        echo json_encode(['ok'=>false,'error'=>'Custom needs valid base provider id'], JSON_UNESCAPED_UNICODE); exit;
    }
    $base_url = trim((string)($in['base_url'] ?? ''));
    if ($base_url === '') { echo json_encode(['ok'=>false,'error'=>"The supplier's address (base URL) is required, e.g. https://api.example.com/v1"], JSON_UNESCAPED_UNICODE); exit; }
    if (($bad_url = custom_base_url_problem($base_url)) !== null) { echo json_encode(['ok'=>false,'error'=>$bad_url], JSON_UNESCAPED_UNICODE); exit; }
    $base_url = rtrim($base_url, '/');
    // models: keep only the known fields; a price, if given, must be sane
    $clean_models = [];
    foreach ($models as $m) {
        if (!is_array($m) || !preg_match('/^[A-Za-z0-9._:@+\/-]{1,100}$/', (string)($m['id'] ?? ''))) { echo json_encode(['ok'=>false,'error'=>'A model id may only use letters, digits and . _ : @ + / -'], JSON_UNESCAPED_UNICODE); exit; }
        $cm = ['id' => (string)$m['id'], 'label' => trim((string)($m['label'] ?? $m['id'])), 'kinds' => is_array($m['kinds'] ?? null) ? array_values(array_filter($m['kinds'], fn($k) => is_string($k) && preg_match('/^[a-z0-9_-]{1,32}$/', $k))) : ['text'], 'free' => !empty($m['free'])];
        if (!$cm['kinds']) $cm['kinds'] = ['text'];
        if (isset($m['pricing']) && is_array($m['pricing'])) {
            $pi = $m['pricing']['input_per_mtok'] ?? null; $po = $m['pricing']['output_per_mtok'] ?? null;
            if (!is_numeric($pi) || !is_numeric($po) || $pi < 0 || $po < 0 || $pi > 10000 || $po > 10000) { echo json_encode(['ok'=>false,'error'=>'Prices must be numbers between 0 and 10000 (USD per million tokens)'], JSON_UNESCAPED_UNICODE); exit; }
            $cm['pricing'] = ['input_per_mtok' => (float)$pi, 'output_per_mtok' => (float)$po];
        }
        $clean_models[] = $cm;
    }
    $models = $clean_models;
    // Check merged catalog for id collision
    $merged = load_providers_catalog($PROVIDERS_F, __DIR__);
    foreach ($merged['providers'] as $p) {
        if (($p['id'] ?? '') === $pid) {
            echo json_encode(['ok'=>false,'error'=>'Provider id already exists'], JSON_UNESCAPED_UNICODE); exit;
        }
    }

    // Load/init overlay
    $overlay = is_file($PROVIDERS_F)
        ? json_decode((string)file_get_contents($PROVIDERS_F), true)
        : [];
    if (!is_array($overlay) || !isset($overlay['format_version'])) {
        $overlay = ['format_version' => 2, 'custom_providers' => [], 'user_added_models' => []];
    }
    if (!isset($overlay['custom_providers']) || !is_array($overlay['custom_providers'])) {
        $overlay['custom_providers'] = [];
    }

    $new_provider = [
        'id'      => $pid,
        'name'    => $name,
        'base'    => $base,
        'base_url' => $base_url,
        'models'  => $models,
        'custom'  => true,
        'free'    => !array_filter($models, fn($m) => empty($m['free'])),
        'incurs_cost' => (bool)array_filter($models, fn($m) => empty($m['free'])),   // any paid model: the consent gate and the monthly cap apply
        'kinds'   => array_unique(array_merge(...array_map(fn($m) => $m['kinds'] ?? ['text'], $models))),
        'website' => $in['website'] ?? null,
        'limits'  => $in['limits']  ?? null,
    ];
    $overlay['custom_providers'][] = $new_provider;
    save_json_file($PROVIDERS_F, $overlay);
    @chmod($PROVIDERS_F, 0664);
    echo json_encode(['ok'=>true,'provider'=>$pid], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: delete_provider — remove a custom-added provider
//
// NEW BEHAVIOUR (Tools Staleness Fix 2026-05-12):
//   Removes the provider from overlay.custom_providers.
//   Shipped providers cannot be deleted (same policy as before).
//   Also cleans up: enabled state, saved key, usage, quota config.
// =============================================================================
if ($action === 'delete_provider') {
    $pid = safe_provider_id($in['provider'] ?? '');
    if (!$pid) { echo json_encode(['ok'=>false,'error'=>'Missing provider'], JSON_UNESCAPED_UNICODE); exit; }

    // Check merged catalog to decide if provider exists and is custom
    $merged = load_providers_catalog($PROVIDERS_F, __DIR__);
    $found     = false;
    $is_custom = false;
    foreach ($merged['providers'] as $p) {
        if (($p['id'] ?? '') !== $pid) continue;
        $found     = true;
        $is_custom = !empty($p['custom']);
        break;
    }
    if (!$found) { echo json_encode(['ok'=>false,'error'=>'Provider not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (!$is_custom) {
        echo json_encode(['ok'=>false,'error'=>'Cannot delete shipped provider — only custom (user-added) providers can be removed'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Load overlay and remove from custom_providers
    $overlay = is_file($PROVIDERS_F)
        ? json_decode((string)file_get_contents($PROVIDERS_F), true)
        : [];
    if (!is_array($overlay) || !isset($overlay['format_version'])) {
        echo json_encode(['ok'=>false,'error'=>'Overlay not in expected format; please reload cockpit to trigger migration'], JSON_UNESCAPED_UNICODE); exit;
    }
    $removed = false;
    foreach (($overlay['custom_providers'] ?? []) as $i => $cp) {
        if (($cp['id'] ?? '') !== $pid) continue;
        array_splice($overlay['custom_providers'], $i, 1);
        $removed = true;
        break;
    }
    // Also clean up any user_added_models that reference this provider
    if (isset($overlay['user_added_models'][$pid])) {
        unset($overlay['user_added_models'][$pid]);
    }
    if ($removed) {
        save_json_file($PROVIDERS_F, $overlay);
        @chmod($PROVIDERS_F, 0664);
    }

    // Full unroot: state, key, usage, quota
    $state = load_state($STATE_F);
    if (isset($state['enabled'][$pid])) { unset($state['enabled'][$pid]); save_json_file($STATE_F, $state); }
    if (is_file($KEYS_F)) {
        $keys = load_keys($KEYS_F);
        if (isset($keys[$pid])) { unset($keys[$pid]); save_keys($KEYS_F, $keys); }
    }
    $usage = load_usage($USAGE_F);
    if (isset($usage[$pid])) { unset($usage[$pid]); save_json_file($USAGE_F, $usage); }
    $quotas = is_file($QUOTAS_F)
                  ? (json_decode((string)file_get_contents($QUOTAS_F), true) ?: [])
                  : [];
    if (isset($quotas[$pid])) { unset($quotas[$pid]); save_json_file($QUOTAS_F, $quotas); }

    echo json_encode(['ok'=>true,'deleted'=>$pid], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: add_model — append a model to any provider (shipped or custom).
//
// NEW BEHAVIOUR (Tools Staleness Fix 2026-05-12):
//   Shipped providers: model appended to overlay.user_added_models[provider_id].
//   Custom providers: model appended to overlay.custom_providers[i].models.
//   The shipped catalog is NEVER written; only the overlay changes.
// =============================================================================
if ($action === 'add_model') {
    $pid    = safe_provider_id($in['provider'] ?? '');
    $mid    = trim((string)($in['model_id'] ?? ''));
    $label  = trim((string)($in['label'] ?? '')) ?: $mid;
    $kinds  = is_array($in['kinds'] ?? null) ? $in['kinds'] : ['text'];
    $free   = !empty($in['free']);
    $pricing = null;   // optional price per million tokens: lets a monthly cap work on a model the person adds
    if (isset($in['pricing']) && is_array($in['pricing'])) {
        $pi = $in['pricing']['input_per_mtok'] ?? null; $po = $in['pricing']['output_per_mtok'] ?? null;
        if (!is_numeric($pi) || !is_numeric($po) || $pi < 0 || $po < 0 || $pi > 10000 || $po > 10000) { echo json_encode(['ok'=>false,'error'=>'Prices must be numbers between 0 and 10000 (USD per million tokens)'], JSON_UNESCAPED_UNICODE); exit; }
        $pricing = ['input_per_mtok' => (float)$pi, 'output_per_mtok' => (float)$po];
    }
    if (!$pid || $mid === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing provider or model_id'], JSON_UNESCAPED_UNICODE); exit;
    }
    // Sanitize kinds (allow alphanum + dash/underscore; lowercase)
    $kinds = array_values(array_filter(array_map(function($k){
        $k = strtolower(trim((string)$k));
        return preg_match('/^[a-z0-9_-]{1,32}$/', $k) ? $k : null;
    }, $kinds)));
    if (!$kinds) $kinds = ['text'];

    // Verify provider exists in merged catalog (shipped + overlay)
    $merged = load_providers_catalog($PROVIDERS_F, __DIR__);
    $provider_found   = false;
    $provider_custom  = false;
    foreach ($merged['providers'] as $p) {
        if (($p['id'] ?? '') !== $pid) continue;
        $provider_found  = true;
        $provider_custom = !empty($p['custom']);
        // Reject duplicate model id within fully-merged provider
        foreach (($p['models'] ?? []) as $m) {
            if (($m['id'] ?? '') === $mid) {
                echo json_encode(['ok'=>false,'error'=>'Model id already exists for this provider'], JSON_UNESCAPED_UNICODE); exit;
            }
        }
        break;
    }
    if (!$provider_found) { echo json_encode(['ok'=>false,'error'=>'Provider not found'], JSON_UNESCAPED_UNICODE); exit; }

    // Load the overlay file (or start fresh overlay if missing/old)
    $overlay = is_file($PROVIDERS_F)
        ? json_decode((string)file_get_contents($PROVIDERS_F), true)
        : [];
    if (!is_array($overlay) || !isset($overlay['format_version'])) {
        // No valid overlay yet — start a clean one (migration should already
        // have run; this is a safety net for a fresh install)
        $overlay = ['format_version' => 2, 'custom_providers' => [], 'user_added_models' => []];
    }

    $new_model = [
        'id'         => $mid,
        'label'      => $label,
        'kinds'      => $kinds,
        'free'       => $free,
        'user_added' => true,
    ];
    if ($pricing) $new_model['pricing'] = $pricing;

    if ($provider_custom) {
        // Custom provider lives entirely in overlay.custom_providers
        foreach ($overlay['custom_providers'] as $i => $cp) {
            if (($cp['id'] ?? '') !== $pid) continue;
            $overlay['custom_providers'][$i]['models'][] = $new_model;
            // Refresh kinds aggregate
            $all_kinds = [];
            foreach ($overlay['custom_providers'][$i]['models'] as $m) {
                foreach (($m['kinds'] ?? []) as $k) $all_kinds[$k] = true;
            }
            $overlay['custom_providers'][$i]['kinds'] = array_values(array_keys($all_kinds));
            break;
        }
    } else {
        // Shipped provider — append to overlay.user_added_models[pid]
        if (!isset($overlay['user_added_models']) || !is_array($overlay['user_added_models'])) {
            $overlay['user_added_models'] = [];
        }
        if (!isset($overlay['user_added_models'][$pid])) {
            $overlay['user_added_models'][$pid] = [];
        }
        $overlay['user_added_models'][$pid][] = $new_model;
    }

    save_json_file($PROVIDERS_F, $overlay);
    @chmod($PROVIDERS_F, 0664);
    echo json_encode(['ok'=>true,'provider'=>$pid,'model_id'=>$mid], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: remove_model — drop a user-added model from a provider.
//
// NEW BEHAVIOUR (Tools Staleness Fix 2026-05-12):
//   Shipped provider → remove from overlay.user_added_models[pid].
//   Custom provider  → remove from overlay.custom_providers[i].models.
//   Cannot remove shipped (non-user_added) models in either case.
// =============================================================================
if ($action === 'remove_model') {
    $pid = safe_provider_id($in['provider'] ?? '');
    $mid = trim((string)($in['model_id'] ?? ''));
    if (!$pid || $mid === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing provider or model_id'], JSON_UNESCAPED_UNICODE); exit;
    }

    // First verify the model exists at all (check merged view)
    $merged = load_providers_catalog($PROVIDERS_F, __DIR__);
    $found        = false;
    $is_user_added = false;
    $is_custom_prov = false;
    foreach ($merged['providers'] as $p) {
        if (($p['id'] ?? '') !== $pid) continue;
        $is_custom_prov = !empty($p['custom']);
        foreach (($p['models'] ?? []) as $m) {
            if (($m['id'] ?? '') !== $mid) continue;
            $found        = true;
            $is_user_added = !empty($m['user_added']);
            break 2;
        }
    }
    if (!$found)       { echo json_encode(['ok'=>false,'error'=>'Model not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (!$is_user_added) {
        echo json_encode(['ok'=>false,'error'=>'Cannot remove shipped model — only user-added models can be removed'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Load overlay and remove the model from the right bucket
    $overlay = is_file($PROVIDERS_F)
        ? json_decode((string)file_get_contents($PROVIDERS_F), true)
        : [];
    if (!is_array($overlay) || !isset($overlay['format_version'])) {
        echo json_encode(['ok'=>false,'error'=>'Overlay not in expected format; please reload cockpit to trigger migration'], JSON_UNESCAPED_UNICODE); exit;
    }

    $removed = false;
    if ($is_custom_prov) {
        // Remove from custom_providers[i].models
        foreach (($overlay['custom_providers'] ?? []) as $i => $cp) {
            if (($cp['id'] ?? '') !== $pid) continue;
            foreach (($cp['models'] ?? []) as $j => $m) {
                if (($m['id'] ?? '') !== $mid) continue;
                array_splice($overlay['custom_providers'][$i]['models'], $j, 1);
                // Refresh kinds aggregate
                $all_kinds = [];
                foreach ($overlay['custom_providers'][$i]['models'] as $mm) {
                    foreach (($mm['kinds'] ?? []) as $k) $all_kinds[$k] = true;
                }
                $overlay['custom_providers'][$i]['kinds'] = array_values(array_keys($all_kinds));
                $removed = true;
                break 2;
            }
        }
    } else {
        // Remove from user_added_models[pid]
        if (isset($overlay['user_added_models'][$pid]) && is_array($overlay['user_added_models'][$pid])) {
            foreach ($overlay['user_added_models'][$pid] as $j => $m) {
                if (($m['id'] ?? '') !== $mid) continue;
                array_splice($overlay['user_added_models'][$pid], $j, 1);
                // Clean up empty array to keep overlay tidy
                if (empty($overlay['user_added_models'][$pid])) {
                    unset($overlay['user_added_models'][$pid]);
                }
                $removed = true;
                break;
            }
        }
    }

    if (!$removed) {
        echo json_encode(['ok'=>false,'error'=>'Model not found in overlay (may already be removed)'], JSON_UNESCAPED_UNICODE); exit;
    }

    save_json_file($PROVIDERS_F, $overlay);
    @chmod($PROVIDERS_F, 0664);
    echo json_encode(['ok'=>true,'removed'=>$mid], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: test_key — tiny ping to verify a provider's API key works.
//
// Phase 2b 2026-05-09. Sends a single token-tiny prompt ("hi") to the
// first available free model on the provider, returns success/error.
// Used by the "Test" button in the Workers settings dialog. No usage
// counting (this is a smoke test, not user activity).
// =============================================================================
if ($action === 'test_key') {
    $pid = safe_provider_id($in['provider'] ?? '');
    if (!$pid) { echo json_encode(['ok'=>false,'error'=>'Missing provider'], JSON_UNESCAPED_UNICODE); exit; }
    $cat   = load_providers_catalog($PROVIDERS_F, __DIR__);
    $prov  = null;
    foreach ($cat['providers'] as $p) {
        if ($p['id'] === $pid) { $prov = $p; break; }
    }
    if (!$prov) { echo json_encode(['ok'=>false,'error'=>'Provider not found'], JSON_UNESCAPED_UNICODE); exit; }
    $keys = load_keys($KEYS_F);
    if (empty($keys[$pid])) {
        echo json_encode(['ok'=>false,'error'=>'No API key saved for this provider'], JSON_UNESCAPED_UNICODE); exit;
    }
    $api_key = $keys[$pid];

    // Phase 2b 2026-05-10 — frontend now passes the user-selected model
    // (chosen by clicking a chip in the settings panel). Validate it
    // exists on this provider; if absent or invalid, fall back to
    // first-free-text default for backward compatibility.
    $requested_model = trim((string)($in['model'] ?? ''));
    $test_model = null;
    if ($requested_model !== '') {
        foreach (($prov['models'] ?? []) as $m) {
            if (($m['id'] ?? '') === $requested_model) { $test_model = $requested_model; break; }
        }
    }
    if (!$test_model) {
        // Fallback: first free text-capable model
        foreach (($prov['models'] ?? []) as $m) {
            if (!empty($m['free']) && in_array('text', $m['kinds'] ?? [], true)) { $test_model = $m['id']; break; }
        }
    }
    if (!$test_model) {
        // Last resort: first model period
        foreach (($prov['models'] ?? []) as $m) { $test_model = $m['id']; break; }
    }
    if (!$test_model) {
        echo json_encode(['ok'=>false,'error'=>'No models configured for this provider'], JSON_UNESCAPED_UNICODE); exit;
    }

    // Determine which invoker to use (custom providers have a 'base' field)
    $base_id = $prov['base'] ?? $pid;
    if (!isset($INVOKERS[$base_id])) {
        echo json_encode(['ok'=>false,'error'=>'No invoker available for '.$base_id], JSON_UNESCAPED_UNICODE); exit;
    }
    $invoker = $INVOKERS[$base_id];
    $t0 = microtime(true);
    try {
        // Invoker signature is ($model, $task, $prompt, $key, $extra) — fixed
        // 2026-05-10 from earlier (incorrect) ($task, $model, ...) order
        $r = $invoker($test_model, 'text', 'hi', $api_key, []);
        $dt = round((microtime(true) - $t0) * 1000);
        if (!empty($r['ok'])) {
            echo json_encode([
                'ok'          => true,
                'model'       => $test_model,
                'latency_ms'  => $dt,
                'sample_text' => substr((string)($r['output'] ?? ''), 0, 80),
            ], JSON_UNESCAPED_UNICODE);
        } else {
            echo json_encode([
                'ok'         => false,
                'error'      => 'API returned: ' . ($r['error'] ?? 'unknown'),
                'latency_ms' => $dt,
            ], JSON_UNESCAPED_UNICODE);
        }
    } catch (Throwable $e) {
        echo json_encode(['ok'=>false,'error'=>'Test failed: '.$e->getMessage()], JSON_UNESCAPED_UNICODE);
    }
    exit;
}

// =============================================================================
// Action: set_auto_route — toggle auto-route for a project
// =============================================================================
if ($action === 'set_auto_route') {
    $project = trim((string)($in['project'] ?? ''));
    $on      = !empty($in['enabled']);
    if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
    $state = load_state($STATE_F);
    if (!isset($state['auto_route_projects']) || !is_array($state['auto_route_projects'])) {
        $state['auto_route_projects'] = [];
    }
    if ($on) {
        if (!in_array($project, $state['auto_route_projects'], true)) {
            $state['auto_route_projects'][] = $project;
        }
    } else {
        $state['auto_route_projects'] = array_values(array_filter(
            $state['auto_route_projects'], fn($p) => $p !== $project));
    }
    save_json_file($STATE_F, $state);
    echo json_encode(['ok'=>true,'project'=>$project,'enabled'=>$on], JSON_UNESCAPED_UNICODE);
    exit;
}

// A7: read-only auto-route status for a given project
if ($action === 'auto_route_status') {
    $project = trim((string)($in['project'] ?? ($_GET['project'] ?? '')));
    $state = load_state($STATE_F);
    $list  = (is_array($state['auto_route_projects'] ?? null)) ? $state['auto_route_projects'] : [];
    echo json_encode(['ok'=>true, 'project'=>$project, 'enabled'=>in_array($project, $list, true)], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false,'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);
