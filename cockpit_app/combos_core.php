<?php
// =============================================================================
// combos_core.php — registry + run helpers shared by combos.php (non-stream)
// and combos_stream.php (SSE). No HTTP entry here, so it's safe to require from
// the streaming endpoint without triggering the JSON dispatch.
// =============================================================================
require_once __DIR__ . '/paths.php';   // for $PATHS['cockpit_data'] (per-user scoped)
require_once __DIR__ . '/combos_lib.php';

if (!function_exists('combos_run')) {

// $PATHS['cockpit_data'] is per-LOGGED-IN-LOCAL-USER (see paths.php) when a
// session exists; falls back to the shared root otherwise (CLI/tests, or no
// session) — same fallback paths.php itself already uses.
function combos_cockpit_data(): string {
    global $PATHS;
    if (!empty($PATHS['cockpit_data'])) return $PATHS['cockpit_data'];
    return (cockpit_home()) . '/scripts/cockpit_data';
}

// Combos only work against a backend that speaks a protocol combos_lib.php
// actually implements. Ollama (native REST) and LocalAI (OpenAI-compatible)
// both do; LM Studio and llama.cpp server don't have a translation built yet
// — same model-naming/API-shape problem, just not solved for those two.
// Returns 'ollama' | 'localai' | null (null = combos unavailable right now).
// 'dual' (the explicit Ollama+LocalAI Supplier Slots option) defaults to
// 'ollama' here — this function feeds every "which single backend is the
// default for this call" site (combos_registry_path(), ollama_generate(),
// etc.), and combos ARE available in dual mode, just single-catalog for now
// until the two-column dual UI exists. Use combos_dual_mode_active() for the
// real "is dual mode on" gating decision.
function combos_active_backend(): ?string {
    $provider = combos_raw_local_provider();
    if ($provider === 'dual') return 'ollama';
    return in_array($provider, ['ollama', 'localai'], true) ? $provider : null;
}
function combos_raw_local_provider(): string {
    $f = combos_cockpit_data() . '/supplier_slots.json';
    if (is_readable($f)) {
        $j = json_decode((string)file_get_contents($f), true);
        return is_array($j) ? (string)($j['local']['provider'] ?? 'dual') : 'dual';
    }
    return 'dual';   // same default as suppliers.php load_slots(): a fresh install shows DUAL
}
function combos_dual_mode_active(): bool {
    return combos_raw_local_provider() === 'dual';
}

// Each backend has its own catalog file — combos.json (Ollama) vs
// combos_localai.json (LocalAI) — since the "model" field in each is a
// different identifier for what may even be the same underlying weights.
// $backend defaults to whichever is actually active; pass it explicitly to
// address a specific backend's file regardless of what's currently selected
// (e.g. the 'install' action always writes to the backend it was told to).
function combos_registry_path(?string $backend = null): string {
    $backend = $backend ?? combos_active_backend() ?? 'ollama';
    $file = $backend === 'localai' ? 'combos_localai.json' : 'combos.json';
    return combos_cockpit_data() . '/' . $file;
}

// Encrypted pack path for a given scope ('base'|'store') — shared by
// combos_load() (reading) and combos.php's install action (writing), so the
// per-backend filename prefix only lives in one place.
function combos_enc_path(string $scope, ?string $backend = null): string {
    $backend = $backend ?? combos_active_backend() ?? 'ollama';
    $prefix = $backend === 'localai' ? 'combos_localai_' : 'combos_';
    return combos_cockpit_data() . '/' . $prefix . $scope . '.enc';
}
// ── Combo crypto — encrypted-at-rest packs (Combo Store) ─────────────────────
// AES-256-GCM. Key derived from /etc/machine-id (machine-bound). For the premium
// "store" scope the SaaS license key is mixed in too (account-bound), so a lapsed
// or copied pack can't be decrypted. Mirrors workers.php's machine-id scheme.
function combos_master_key(string $scope = 'base'): string {
    global $PATHS;
    $mid  = is_readable('/etc/machine-id') ? trim((string)file_get_contents('/etc/machine-id')) : 'cockpit-default-machine';
    $salt = 'AICockpit-Combos-v1';
    $extra = '';
    if ($scope === 'store') {
        // Bind premium packs to the signed-in account's license, if present.
        if (!empty($PATHS['cockpit_data'])) {
            $acct = $PATHS['cockpit_data'] . '/saas_account.json';
        } else {
            $home = cockpit_home();
            $acct = $home . '/scripts/cockpit_data/saas_account.json';
        }
        if (is_readable($acct)) {
            $a = json_decode((string)file_get_contents($acct), true);
            if (!empty($a['license_key'])) $extra = (string)$a['license_key'];
        }
    }
    return hash('sha256', $mid . $salt . $extra, true);   // 32 bytes
}
function combos_encrypt_blob(string $plaintext, string $scope = 'base'): string {
    $key = combos_master_key($scope);
    $iv  = random_bytes(12); $tag = '';
    $ct  = openssl_encrypt($plaintext, 'aes-256-gcm', $key, OPENSSL_RAW_DATA, $iv, $tag, '', 16);
    return $ct === false ? '' : base64_encode($iv . $tag . $ct);
}
function combos_decrypt_blob(string $b64, string $scope = 'base'): string {
    $raw = base64_decode($b64, true);
    if ($raw === false || strlen($raw) < 28) return '';
    $iv = substr($raw, 0, 12); $tag = substr($raw, 12, 16); $ct = substr($raw, 28);
    $pt = openssl_decrypt($ct, 'aes-256-gcm', combos_master_key($scope), OPENSSL_RAW_DATA, $iv, $tag);
    return $pt === false ? '' : $pt;
}
// Decrypt an encrypted combo pack file → array, or null on failure.
function combos_decrypt_file(string $path, string $scope): ?array {
    if (!is_readable($path)) return null;
    $pt = combos_decrypt_blob(trim((string)file_get_contents($path)), $scope);
    if ($pt === '') return null;
    $j = json_decode($pt, true);
    return is_array($j) ? $j : null;
}

// Load + merge combos from: encrypted base pack, encrypted store pack, the
// plaintext combos.json (dev/transition fallback), and the user's own
// unencrypted combos_user.json. Dedupe by id (first wins).
//
// $out['locked'] lists any encrypted pack that EXISTS on disk but failed to
// decrypt (wrong/missing license, moved to another machine, corrupted) — so
// the caller can show "N combos aren't available on this account/machine"
// instead of silently returning fewer combos with no explanation (per
// COCKPIT_COMBO_PROTECTION_DESIGN.md §5.4).
function combos_load(?string $backend = null): array {
    $backend = $backend ?? combos_active_backend() ?? 'ollama';
    $dir = dirname(combos_registry_path($backend));
    $out = ['version' => 2, 'backend' => $backend, 'combos' => [], 'locked' => []];
    $seen = [];
    $add = function(array $j, string $origin) use (&$out, &$seen) {
        foreach (($j['combos'] ?? []) as $c) {
            $id = $c['id'] ?? '';
            if ($id === '' || isset($seen[$id])) continue;
            $c['origin'] = $origin;
            $out['combos'][] = $c; $seen[$id] = true;
        }
    };
    // Encrypted packs are per-backend (combos_base.enc/combos_store.enc for
    // Ollama; combos_localai_base.enc/combos_localai_store.enc for LocalAI —
    // the latter don't exist yet, this just means LocalAI currently only has
    // the plaintext base-tier file below, no premium store pack).
    foreach (['base', 'store'] as $scope) {
        $path = combos_enc_path($scope, $backend);
        if (!is_readable($path)) continue;
        $j = combos_decrypt_file($path, $scope);
        if (is_array($j)) { $add($j, $scope); continue; }
        // File exists but didn't decrypt — wrong machine/license, not "no packs".
        $out['locked'][] = $scope;
    }
    $pf = combos_registry_path($backend);   // plaintext fallback (current dev file)
    if (is_readable($pf)) {
        $j = json_decode((string)file_get_contents($pf), true);
        if (is_array($j)) $add($j, 'builtin');
    }
    $uf = $dir . '/combos_user.json';   // user-authored, never encrypted (it's already theirs)
    if (is_readable($uf)) {
        $j = json_decode((string)file_get_contents($uf), true);
        if (is_array($j)) $add($j, 'user');
    }
    return $out;
}
function combos_installed_models(?string $backendOverride = null): array {
    $backend = $backendOverride ?? combos_active_backend() ?? 'ollama';
    if ($backend === 'localai') {
        $ch = curl_init(combos_localai_base() . '/v1/models');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>4]);
        $raw = curl_exec($ch); curl_close($ch);
        $set = [];
        if ($raw !== false) {
            $j = json_decode($raw, true);
            foreach (($j['data'] ?? []) as $m) if (!empty($m['id'])) $set[strtolower($m['id'])] = true;
        }
        return $set;
    }
    $ch = curl_init(combos_ollama_base() . '/api/tags');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>4]);
    $raw = curl_exec($ch); curl_close($ch);
    $set = [];
    if ($raw !== false) {
        $j = json_decode($raw, true);
        foreach (($j['models'] ?? []) as $m) if (!empty($m['name'])) $set[strtolower($m['name'])] = true;
    }
    return $set;
}
// Every model a combo references, each tagged with the backend it ACTUALLY
// runs on (a step's own runner if it has one, else the combo's catalog
// backend — same fallback convention combos_run()/combos_step_job() use).
// This matters for real: a dual (mixed-runner) combo has some steps on
// Ollama and some on LocalAI, and checking every one of those model names
// against only ONE backend's installed list (the old behavior) would wrongly
// flag a model that's genuinely installed — just on the other backend — as
// missing. → [{model, runner}], de-duplicated by (runner, model) pair.
function combos_models_of(array $combo, string $defaultBackend): array {
    $pairs = [];
    foreach (($combo['steps'] ?? []) as $s) {
        if (!empty($s['model'])) $pairs[] = ['model'=>$s['model'], 'runner'=>$s['runner'] ?? $defaultBackend];
    }
    if (!empty($combo['judge']['model'])) $pairs[] = ['model'=>$combo['judge']['model'], 'runner'=>$combo['judge']['runner'] ?? $defaultBackend];
    if (!empty($combo['seed']['model']))  $pairs[] = ['model'=>$combo['seed']['model'],  'runner'=>$combo['seed']['runner']  ?? $defaultBackend];
    $seen = []; $out = [];
    foreach ($pairs as $p) {
        $key = $p['runner'] . '|' . strtolower($p['model']);
        if (isset($seen[$key])) continue;
        $seen[$key] = true; $out[] = $p;
    }
    return $out;
}
// Repair double-encoded UTF-8 ("â€”" for "—", "Ã©" for "é"): some store packs
// were published that way and every name in the picker showed the mojibake.
// Only strings that really look double-encoded and decode to valid UTF-8 change.
function combos_fix_mojibake($v) {
    if (!is_string($v) || $v === '' || !preg_match('/[\xC2-\xC3\xE2][\x80-\xBF]/', $v)) return $v;
    // cp1252, not latin1: the em dash's 0x80 0x94 bytes live there. The round
    // trip must be lossless (every char of $v representable in cp1252) — a real
    // "→" or "é" fails it and stays; "â€”" passes and becomes "—".
    $d = @mb_convert_encoding($v, 'Windows-1252', 'UTF-8');
    if (!is_string($d) || $d === $v || !mb_check_encoding($d, 'UTF-8')) return $v;
    if (@mb_convert_encoding($d, 'UTF-8', 'Windows-1252') !== $v) return $v;
    return $d;
}
function combos_list(?string $backend = null): array {
    $reg = combos_load($backend);
    $defaultBackend = $backend ?? combos_active_backend() ?? 'ollama';
    // Lazily fetch each backend's installed-model set only if a combo
    // actually references it — most combos are single-backend, no reason to
    // hit both Ollama and LocalAI on every list request.
    $installedCache = [];
    $installedFor = function(string $rb) use (&$installedCache) {
        if (!isset($installedCache[$rb])) $installedCache[$rb] = combos_installed_models($rb);
        return $installedCache[$rb];
    };
    $out = [];
    foreach (($reg['combos'] ?? []) as $c) {
        $modelPairs = combos_models_of($c, $defaultBackend);
        $missing = [];
        foreach ($modelPairs as $mp) {
            $installed = $installedFor($mp['runner']);
            if (empty($installed[strtolower($mp['model'])])) $missing[] = ['model'=>$mp['model'], 'runner'=>$mp['runner']];
        }
        $models = array_values(array_unique(array_column($modelPairs, 'model')));
        $out[] = [
            'id'=>$c['id'] ?? '', 'name'=>combos_fix_mojibake($c['name'] ?? ($c['id'] ?? '')), 'pattern'=>$c['pattern'] ?? 'parallel',
            'category'=>$c['category'] ?? '', 'desc'=>combos_fix_mojibake($c['desc'] ?? ''), 'use_rag'=>$c['use_rag'] ?? 'never',
            'est_vram_mb'=>$c['est_vram_mb'] ?? 0, 'steps'=>count($c['steps'] ?? []), 'models'=>$models,
            // 'missing' is now [{model, runner}], not plain strings — callers
            // that just need names can array_column(missing,'model').
            'available'=>count($missing) === 0, 'missing'=>$missing,
            'origin'=>$c['origin'] ?? 'builtin',   // base | store | builtin | user (combos_load() tags it)
            // user-authored combos only: marketplace linkage for publish-state/
            // attribution/usage-reporting (COCKPIT_COMBO_PROTECTION_DESIGN.md §8.4).
            'content_id'=>$c['_content_id'] ?? null, 'author'=>$c['_author'] ?? null,
            // Which backend(s) this combo actually needs — lets the dual-mode
            // two-column UI show a combo under "needs both" when its steps
            // span Ollama and LocalAI.
            'needed_runners'=>combos_needed_runners($c, $defaultBackend),
        ];
    }
    return ['ok'=>true, 'combos'=>$out, 'locked'=>$reg['locked'] ?? []];
}
function combos_find(string $id, ?string $backend = null): ?array {
    foreach ((combos_load($backend)['combos'] ?? []) as $c) if (($c['id'] ?? '') === $id) return $c;
    return null;
}
function combos_fill(string $tpl, string $prompt, string $rag, string $prev): string {
    if ($tpl === '') return $prompt;
    return strtr($tpl, ['{{PROMPT}}'=>$prompt, '{{RAG}}'=>$rag, '{{PREV}}'=>$prev]);
}
// Normalize a step into a runnable job (id, role, model, system, prompt,
// options, runner, images). "runner" ('ollama'|'localai') is optional per-step
// — a dual-mode combo tags individual steps; a normal single-backend combo
// leaves it unset and every step falls back to the globally active backend,
// same behavior as before dual-mode existed. "images" (array of base64
// strings, no "data:" prefix) is optional per-step too — only meaningful on a
// vision-capable model; combos_run_combo() passes it straight through to
// ollama_generate()/ollama_broadcast(), which handle both backends' actual
// wire formats (Ollama's native `images` field vs. LocalAI's OpenAI-style
// image_url content blocks, see combos_vision_content() in combos_lib.php).
function combos_step_job(array $s, string $prompt, string $rag, string $prev, array $images = []): array {
    $opts = [];
    if (!empty($s['num_ctx'])) $opts['num_ctx'] = (int)$s['num_ctx'];
    return [
        'id'=>$s['id'] ?? $s['model'], 'role'=>$s['role'] ?? '', 'model'=>$s['model'],
        'system'=>$s['system'] ?? '', 'prompt'=>combos_fill((string)($s['prompt'] ?? ''), $prompt, $rag, $prev),
        'options'=>$opts, 'runner'=>$s['runner'] ?? null,
        'images'=>!empty($s['images']) ? $s['images'] : $images,
    ];
}

// Every distinct runner a combo's steps (+ seed + judge) actually reference —
// used for the pre-flight check before running it. A normal single-backend
// combo returns one entry (the globally active backend); a dual-mode combo
// can return both.
function combos_needed_runners(array $combo, ?string $defaultBackend = null): array {
    $default = $defaultBackend ?? combos_active_backend() ?? 'ollama';
    $set = [];
    foreach (($combo['steps'] ?? []) as $s) $set[$s['runner'] ?? $default] = true;
    if (!empty($combo['seed']['model']))  $set[$combo['seed']['runner'] ?? $default] = true;
    if (!empty($combo['judge']['model'])) $set[$combo['judge']['runner'] ?? $default] = true;
    return array_keys($set);
}

// Pre-flight: refuse to start a combo if any runner its steps actually need
// isn't reachable right now — better than discovering it mid-run when step 3
// of 5 times out. Returns '' if all good, or a clear error naming what's down.
function combos_preflight(array $combo): string {
    $needed = combos_needed_runners($combo);
    $status = combos_dual_status();
    $down = [];
    foreach ($needed as $r) {
        if ($r === 'localai' && empty($status['localai']['running'])) $down[] = 'LocalAI';
        if ($r === 'ollama'  && empty($status['ollama']['running']))  $down[] = 'Ollama';
    }
    if (!$down) return '';
    return implode(' and ', $down) . ' not reachable — this combo needs ' .
        (count($needed) > 1 ? 'both' : $needed[0]) . ' running.';
}

// Runs any combo array — saved (from combos.json/combos_store.enc) or an
// ad-hoc in-memory one built at runtime (e.g. dual-model regular chat's
// on-the-fly 2-step Ollama+LocalAI combo). $comboId is just a label for the
// result payload's 'combo' field, doesn't need to resolve to anything real.
function combos_run_combo(array $combo, string $prompt, string $rag = '', string $comboId = 'adhoc', array $images = []): array {
    $pfError = combos_preflight($combo);
    if ($pfError !== '') return ['ok'=>false, 'error'=>$pfError];
    $pattern = $combo['pattern'] ?? 'parallel';
    $steps   = $combo['steps'] ?? [];
    if (!$steps) return ['ok'=>false, 'error'=>'combo has no steps'];

    if ($pattern === 'sequential') {
        $results = []; $prev = '';
        foreach ($steps as $s) {
            $job = combos_step_job($s, $prompt, $rag, $prev, $images);
            $r = ollama_generate($job['model'], $job['prompt'], ['system'=>$job['system'], 'options'=>$job['options'], 'runner'=>$job['runner'], 'images'=>$job['images']]);
            $results[] = ['id'=>$job['id'],'role'=>$job['role'],'model'=>$job['model'],'runner'=>$job['runner'],'ok'=>$r['ok'],'text'=>$r['text'],'ms'=>$r['ms'],'error'=>$r['error']];
            if (!$r['ok']) return ['ok'=>false,'combo'=>$comboId,'pattern'=>$pattern,'steps'=>$results,'error'=>'step "'.$job['id'].'" failed: '.$r['error']];
            $prev = $r['text'];
        }
        return ['ok'=>true,'combo'=>$comboId,'pattern'=>$pattern,'steps'=>$results,'final'=>$prev];
    }

    // Optional shared SEED — run one model first to fix a common premise, then
    // feed it to every parallel step so they stay consistent (e.g. worldbuilder
    // models build ONE world, not four). Combo: "seed":{model,system,prompt?,runner?}.
    $seedText = '';
    if (!empty($combo['seed']['model'])) {
        $sp = combos_fill((string)($combo['seed']['prompt'] ?? '{{PROMPT}}'), $prompt, $rag, '');
        $sr = ollama_generate($combo['seed']['model'], $sp, ['system' => $combo['seed']['system'] ?? '', 'runner' => $combo['seed']['runner'] ?? null]);
        if (!empty($sr['ok'])) $seedText = (string)$sr['text'];
    }
    $jobs = [];
    foreach ($steps as $s) {
        $job = combos_step_job($s, $prompt, $rag, '', $images);
        if ($seedText !== '') $job['prompt'] = "Shared premise (build on this, stay consistent with it):\n" . $seedText . "\n\n" . $job['prompt'];
        $jobs[] = $job;
    }
    $bres = ollama_broadcast($jobs);
    $results = [];
    foreach ($jobs as $j) {
        $r = $bres[$j['id']] ?? ['ok'=>false,'text'=>'','error'=>'no result','ms'=>0,'runner'=>$j['runner']];
        $results[] = ['id'=>$j['id'],'role'=>$j['role'],'model'=>$j['model'],'runner'=>$r['runner'] ?? $j['runner'],'ok'=>$r['ok'],'text'=>$r['text'],'ms'=>$r['ms'],'error'=>$r['error']];
    }
    if ($pattern === 'judge' && !empty($combo['judge']['model'])) {
        $parts = [];
        foreach ($results as $r) $parts[] = strtoupper($r['role'] ?: $r['id']) . ":\n" . $r['text'];
        $jprompt = "User request:\n$prompt\n\nCandidate answers:\n" . implode("\n\n", $parts);
        $jr = ollama_generate($combo['judge']['model'], $jprompt, ['system'=>$combo['judge']['system'] ?? '', 'options'=>['temperature'=>0.3], 'runner'=>$combo['judge']['runner'] ?? null]);
        return ['ok'=>true,'combo'=>$comboId,'pattern'=>'judge','steps'=>$results,
                'judge'=>['model'=>$combo['judge']['model'],'runner'=>$combo['judge']['runner'] ?? null,'ok'=>$jr['ok'],'text'=>$jr['text'],'ms'=>$jr['ms'],'error'=>$jr['error']], 'final'=>$jr['text']];
    }
    return ['ok'=>true,'combo'=>$comboId,'pattern'=>'parallel','steps'=>$results];
}

function combos_run(string $id, string $prompt, string $rag = '', ?string $backend = null, array $images = []): array {
    $combo = combos_find($id, $backend);
    if (!$combo) return ['ok'=>false, 'error'=>'unknown combo: '.$id];
    if ($backend !== null) {
        // Stamp every step/seed/judge with the explicit backend so execution
        // doesn't fall through to the global active-backend default — which,
        // in dual mode, defaults to 'ollama' regardless of which catalog
        // this combo actually came from (catalogs are whole-file
        // single-backend; individual steps have no runner tag of their own).
        foreach ($combo['steps'] as &$s) { $s['runner'] = $s['runner'] ?? $backend; }
        unset($s);
        if (!empty($combo['seed']))  $combo['seed']['runner']  = $combo['seed']['runner']  ?? $backend;
        if (!empty($combo['judge'])) $combo['judge']['runner'] = $combo['judge']['runner'] ?? $backend;
    }
    return combos_run_combo($combo, $prompt, $rag, $id, $images);
}
function combos_flatten(array $r): string {
    $out = '⚡ Combo: ' . ($r['combo'] ?? '') . "\n\n";
    $step = function($s) {
        return '**' . ($s['role'] ?? $s['id'] ?? '') . '** (' . ($s['model'] ?? '') . '):' . "\n" .
               ($s['ok'] ? ($s['text'] ?: '(empty)') : ('[error] ' . ($s['error'] ?? ''))) . "\n\n";
    };
    if (($r['pattern'] ?? '') === 'judge' && !empty($r['judge'])) {
        $out .= "**Judge verdict:**\n" . ($r['final'] ?? '') . "\n\n---\n\n";
        foreach (($r['steps'] ?? []) as $s) $out .= $step($s);
        return rtrim($out);
    }
    foreach (($r['steps'] ?? []) as $s) $out .= $step($s);
    return rtrim($out);
}
function combos_heal_json(string $raw): ?array {   // same pass as files.php::healJson
    $len = strlen($raw); $out = ''; $inStr = false;
    for ($i = 0; $i < $len; $i++) {
        $c = $raw[$i];
        if ($c === '"' && ($i === 0 || $raw[$i-1] !== '\\')) { $inStr = !$inStr; $out .= $c; continue; }
        if ($inStr && ord($c) < 0x20 && $c !== "\t") $out .= $c === "\n" ? '\\n' : ($c === "\r" ? '\\r' : sprintf('\\u%04x', ord($c)));
        else $out .= $c;
    }
    $d = json_decode($out, true);
    return is_array($d) ? $d : null;
}
function combos_append_chat(string $root, string $project, string $chat, string $userText, string $agentText, string $model, string $agent = 'combo', array $extra = []): bool {
    $project = ($project === '') ? 'default' : str_replace(['/', '\\', '..'], '', $project);
    $chat    = ($chat === '')    ? 'default' : str_replace(['/', '\\', '..'], '', $chat);
    $dir = rtrim($root, '/') . '/' . $project;
    if (!is_dir($dir) && !@mkdir($dir, 0775, true)) return false;
    $file = $dir . '/chat_' . $chat . '.json';
    $lock = @fopen($file . '.lock', 'c');
    if ($lock) flock($lock, LOCK_EX);
    $raw  = is_readable($file) ? (string)file_get_contents($file) : '';
    $data = $raw !== '' ? json_decode($raw, true) : null;
    if ($raw !== '' && !is_array($data)) {
        // A chat file that exists but does not parse (old loop versions wrote raw
        // newlines into strings) must NOT be replaced by an empty one — that
        // would erase the whole history on the next combo turn. Heal it the way
        // files.php does on load; if it still does not parse, refuse the write.
        $data = combos_heal_json($raw);
        if (!is_array($data)) { if ($lock) { flock($lock, LOCK_UN); fclose($lock); } error_log("combos_append_chat: refusing to overwrite unparseable $file"); return false; }
    }
    if (!is_array($data) || !isset($data['exchanges']) || !is_array($data['exchanges'])) {
        $data = ['schema_version'=>1, 'project'=>$project, 'chat'=>$chat, 'created'=>gmdate('Y-m-d\TH:i:s\Z'), 'exchanges'=>[]];
    }
    $now = gmdate('Y-m-d\TH:i:s\Z'); $nid = count($data['exchanges']);   // Z: a naive stamp reads as local in the app
    $data['exchanges'][] = ['id'=>$nid+1, 'timestamp'=>$now, 'role'=>'user',  'text'=>$userText];
    // $extra: mode/style/supplier of the turn (labels + history), same fields agent_loop.sh writes
    $data['exchanges'][] = array_merge(['id'=>$nid+2, 'timestamp'=>$now, 'role'=>'agent', 'agent'=>$agent, 'model'=>$model, 'duration_s'=>null], $extra, ['text'=>$agentText]);
    $data['updated'] = $now;
    $ok = @file_put_contents($file, json_encode($data, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_PRETTY_PRINT)) !== false;
    @chmod($file, 0664);
    // Keep the derived chat index current now, rather than one turn late when
    // agent_loop.sh's reconcile notices the counts differ. Still under the same
    // .lock the loop uses, so the two writers cannot interleave. Fails soft:
    // an index problem never fails the chat write.
    if ($ok) {
        require_once __DIR__ . '/chat_index.php';
        chat_index_add($file, $nid + 1, 'user',  '',      $now, $userText);
        chat_index_add($file, $nid + 2, 'agent', $agent,  $now, $agentText);
    }
    if ($lock) { flock($lock, LOCK_UN); fclose($lock); }
    return $ok;
}

} // function guard
