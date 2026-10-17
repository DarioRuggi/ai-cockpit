<?php
// =============================================================================
// combos_lib.php — shared REST helpers for the Power Combos engine.
//
// Pure PHP + cURL, bypassing the tmux/bridge CLI path — the only way to run
// several models concurrently. Talks to whichever backend Card 3 is actually
// configured as (via supplier_slots.json), currently Ollama (native REST) or
// LocalAI (OpenAI-compatible Chat Completions). LM Studio/llama.cpp aren't
// wired up — same idea, just not built yet.
//   ollama_generate()  — one non-streaming completion.
//   ollama_broadcast() — N completions in parallel via curl_multi.
//   ollama_ps()        — loaded models + VRAM footprint (Ollama-only; no
//                         generic equivalent exists for OpenAI-compatible
//                         servers, degrades to a plain model list elsewhere).
// Function names kept as "ollama_*" even though they now serve multiple
// backends — every caller in this codebase already uses these names, and
// renaming them would touch far more files than the actual behavior change
// requires. What changed is internal: request/response shape now branches
// on combos_active_backend().
// All return plain arrays; callers (combos.php / ollama_ps.php) JSON-encode.
// =============================================================================

// $PATHS + cockpit_home() — this file already read $PATHS without loading it,
// relying on every caller having done so. Make the dependency explicit; the
// guard keeps it safe if paths.php is ever loaded after this file.
if (!function_exists("cockpit_home")) { require_once __DIR__ . "/paths.php"; }

if (!function_exists('combos_ollama_base')) {

function combos_ollama_base(): string {
    global $PATHS;
    static $b = null;
    if ($b !== null) return $b;
    $b = 'http://127.0.0.1:11434';
    // Optional override from ollama_config.json {"base_url": "..."}. The Ollama
    // daemon is a machine-wide resource (one install, shared by every local
    // user), so this reads the SHARED root, not the per-user data dir.
    if (!empty($PATHS['cockpit_data_root'])) {
        $cfg = $PATHS['cockpit_data_root'] . '/ollama_config.json';
    } else {
        $home = cockpit_home();
        $cfg  = $home . '/scripts/cockpit_data/ollama_config.json';
    }
    if (is_readable($cfg)) {
        $j = json_decode((string)file_get_contents($cfg), true);
        if (!empty($j['base_url'])) $b = rtrim((string)$j['base_url'], '/');
    }
    return $b;
}

// LocalAI's base URL — deliberately NOT read from supplier_slots.json's
// local.base_url. That field means "whatever Card 3's single slot is
// CURRENTLY set to's URL", which is only LocalAI's address when Card 3
// happens to be pointed at LocalAI right now. Dual-mode needs LocalAI's
// address regardless of what Card 3 is set to (same reasoning as Ollama's
// own separate ollama_config.json below) — found this the hard way: an
// earlier version of this function read supplier_slots.json and, with Card 3
// set to Ollama, silently queried Ollama's server while labeling the results
// "localai". Own dedicated override file instead, same pattern as Ollama's.
function combos_localai_base(): string {
    global $PATHS;
    $b = 'http://127.0.0.1:8080';   // suppliers.php's LOCAL_SERVERS default for localai
    $cfg = ($PATHS['cockpit_data_root'] ?? (cockpit_home()) . '/scripts/cockpit_data') . '/localai_config.json';
    if (is_readable($cfg)) {
        $j = json_decode((string)file_get_contents($cfg), true);
        if (!empty($j['base_url'])) $b = rtrim((string)$j['base_url'], '/');
    }
    return $b;
}

// Dispatch to whichever backend is actually active. Falls back to Ollama's
// base if the active backend is somehow neither (shouldn't happen — callers
// are expected to check combos_active_backend() isn't null first). Pass an
// explicit $runner to address a specific backend regardless of what's
// globally active — needed for dual-mode combos, where one step's Ollama
// call and another step's LocalAI call happen in the SAME run.
function combos_backend_base(?string $runner = null): string {
    $runner = $runner ?? combos_active_backend();
    return $runner === 'localai' ? combos_localai_base() : combos_ollama_base();
}

// Builds the OpenAI-style "content" array for a vision-capable chat message —
// a text block plus one block per image (base64, no "data:" prefix — caller
// strips that if it came from a browser <input type=file> FileReader result).
// Shared by ollama_generate()/ollama_broadcast()'s LocalAI branch.
function combos_vision_content(string $text, array $images): array {
    $content = [['type' => 'text', 'text' => $text]];
    foreach ($images as $img) {
        $content[] = ['type' => 'image_url', 'image_url' => ['url' => 'data:image/jpeg;base64,' . $img]];
    }
    return $content;
}

// One non-streaming completion. $opts: system, options[], keep_alive, timeout,
// runner ('ollama'|'localai', defaults to the globally active backend — set
// explicitly for a dual-mode step that needs a specific one regardless),
// images (array of base64-encoded image bytes, no "data:" prefix — only
// meaningful with a vision-capable model; a non-vision model just ignores or
// errors on it same as it would if you sent it through curl by hand, this
// isn't validated here).
// → ['ok'=>bool, 'text'=>string, 'error'=>string, 'ms'=>int].
function ollama_generate(string $model, string $prompt, array $opts = []): array {
    $backend = $opts['runner'] ?? combos_active_backend() ?? 'ollama';
    $images  = $opts['images'] ?? [];
    $t0 = microtime(true);

    if ($backend === 'localai') {
        $messages = [];
        if (!empty($opts['system'])) $messages[] = ['role' => 'system', 'content' => (string)$opts['system']];
        $messages[] = ['role' => 'user', 'content' => $images ? combos_vision_content($prompt, $images) : $prompt];
        $payload = ['model' => $model, 'messages' => $messages, 'stream' => false];
        $ch = curl_init(combos_backend_base($backend) . '/v1/chat/completions');
    } else {
        $payload = [
            'model'   => $model,
            'prompt'  => $prompt,
            'stream'  => false,
            'options' => array_merge(['num_ctx' => 4096], $opts['options'] ?? []),
        ];
        if (!empty($opts['system']))    $payload['system']     = (string)$opts['system'];
        if (isset($opts['keep_alive'])) $payload['keep_alive'] = $opts['keep_alive'];
        if ($images)                    $payload['images']     = $images; // Ollama's own native vision field
        $ch = curl_init(combos_backend_base($backend) . '/api/generate');
    }

    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode($payload),
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_TIMEOUT        => (int)($opts['timeout'] ?? 180),
    ]);
    $raw = curl_exec($ch);
    $err = curl_error($ch);
    curl_close($ch);
    $ms = (int)round((microtime(true) - $t0) * 1000);

    if ($raw === false) return ['ok'=>false, 'text'=>'', 'error'=>$err ?: 'curl failed', 'ms'=>$ms];
    $j = json_decode($raw, true);
    if (!is_array($j))  return ['ok'=>false, 'text'=>'', 'error'=>'bad JSON from server', 'ms'=>$ms];

    if ($backend === 'localai') {
        if (isset($j['error'])) return ['ok'=>false, 'text'=>'', 'error'=>is_array($j['error']) ? ($j['error']['message'] ?? 'error') : (string)$j['error'], 'ms'=>$ms];
        $text = (string)($j['choices'][0]['message']['content'] ?? '');
        return ['ok'=>true, 'text'=>$text, 'error'=>'', 'ms'=>$ms];
    }
    if (isset($j['error'])) return ['ok'=>false, 'text'=>'', 'error'=>(string)$j['error'], 'ms'=>$ms];
    return ['ok'=>true, 'text'=>(string)($j['response'] ?? ''), 'error'=>'', 'ms'=>$ms];
}

// Parallel broadcast. $jobs = [ ['id'=>?, 'model'=>.., 'prompt'=>.., 'system'=>?,
// 'options'=>?, 'runner'=>?, 'images'=>?], ... ]. Each job may specify its OWN 'runner'
// ('ollama'|'localai') — this is what makes a dual-mode combo work: one job
// in the same batch can hit Ollama while another hits LocalAI, genuinely
// concurrently, since each curl_multi handle already has its own URL. A job
// with no 'runner' falls back to the globally active backend, same as before.
// → [ id => ['ok','text','error','ms','model','runner'] ].
// (needs OLLAMA_NUM_PARALLEL / OLLAMA_MAX_LOADED_MODELS ≥ job count on Ollama;
// LocalAI's own concurrency config plays the equivalent role there).
function ollama_broadcast(array $jobs, array $opts = []): array {
    $defaultBackend = combos_active_backend() ?? 'ollama';

    $mh = curl_multi_init();
    $handles = [];
    $models  = [];
    $runners = [];
    $t0 = microtime(true);

    foreach ($jobs as $i => $j) {
        $id = (string)($j['id'] ?? ($j['model'] ?? $i));
        $runner = $j['runner'] ?? $defaultBackend;
        $url = combos_backend_base($runner) . ($runner === 'localai' ? '/v1/chat/completions' : '/api/generate');

        $images = $j['images'] ?? [];
        if ($runner === 'localai') {
            $messages = [];
            if (!empty($j['system'])) $messages[] = ['role' => 'system', 'content' => (string)$j['system']];
            $messages[] = ['role' => 'user', 'content' => $images ? combos_vision_content($j['prompt'], $images) : $j['prompt']];
            $payload = ['model' => $j['model'], 'messages' => $messages, 'stream' => false];
        } else {
            $payload = [
                'model'   => $j['model'],
                'prompt'  => $j['prompt'],
                'stream'  => false,
                'options' => array_merge(['num_ctx' => 4096], $j['options'] ?? []),
            ];
            if (!empty($j['system']))    $payload['system']     = (string)$j['system'];
            if (isset($j['keep_alive'])) $payload['keep_alive'] = $j['keep_alive'];
            if ($images)                 $payload['images']     = $images;
        }

        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_POST           => true,
            CURLOPT_POSTFIELDS     => json_encode($payload),
            CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
            CURLOPT_TIMEOUT        => (int)($opts['timeout'] ?? 180),
        ]);
        curl_multi_add_handle($mh, $ch);
        $handles[$id] = $ch;
        $models[$id]  = (string)$j['model'];
        $runners[$id] = $runner;
    }

    // Drive all transfers concurrently.
    $running = null;
    do {
        curl_multi_exec($mh, $running);
        if ($running > 0) curl_multi_select($mh, 1.0);
    } while ($running > 0);

    $out = [];
    foreach ($handles as $id => $ch) {
        $raw = curl_multi_getcontent($ch);
        $err = curl_error($ch);
        $ms  = (int)round((microtime(true) - $t0) * 1000);
        curl_multi_remove_handle($mh, $ch);
        curl_close($ch);
        $runner = $runners[$id];

        if ($raw === false || $raw === '') { $out[$id] = ['ok'=>false,'text'=>'','error'=>$err ?: 'no response','ms'=>$ms,'model'=>$models[$id],'runner'=>$runner]; continue; }
        $j = json_decode($raw, true);
        if (!is_array($j)) { $out[$id] = ['ok'=>false,'text'=>'','error'=>'bad JSON','ms'=>$ms,'model'=>$models[$id],'runner'=>$runner]; continue; }

        if ($runner === 'localai') {
            if (isset($j['error'])) { $out[$id] = ['ok'=>false,'text'=>'','error'=>is_array($j['error']) ? ($j['error']['message'] ?? 'error') : (string)$j['error'],'ms'=>$ms,'model'=>$models[$id],'runner'=>$runner]; continue; }
            $out[$id] = ['ok'=>true,'text'=>(string)($j['choices'][0]['message']['content'] ?? ''),'error'=>'','ms'=>$ms,'model'=>$models[$id],'runner'=>$runner];
            continue;
        }
        if (isset($j['error'])) { $out[$id] = ['ok'=>false,'text'=>'','error'=>(string)$j['error'],'ms'=>$ms,'model'=>$models[$id],'runner'=>$runner]; continue; }
        $out[$id] = ['ok'=>true,'text'=>(string)($j['response'] ?? ''),'error'=>'','ms'=>$ms,'model'=>$models[$id],'runner'=>$runner];
    }
    curl_multi_close($mh);
    return $out;
}

// Loaded models + VRAM footprint (for the monitor). Ollama's /api/ps has no
// standard equivalent in the OpenAI API spec — LocalAI's /v1/models lists
// what's AVAILABLE, not what's currently loaded/how much VRAM it's using, so
// this degrades gracefully there: a plain name list, size/quant/processor
// fields left as '?' rather than guessed.
// → ['ok'=>bool, 'models'=>[{name,size_mb,param,quant,processor}], 'total_mb'=>float].
function ollama_ps(): array {
    $backend = combos_active_backend() ?? 'ollama';

    if ($backend === 'localai') {
        $ch = curl_init(combos_backend_base() . '/v1/models');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 3]);
        $raw = curl_exec($ch);
        $err = curl_error($ch);
        curl_close($ch);
        if ($raw === false) return ['ok'=>false, 'error'=>$err ?: 'LocalAI offline', 'models'=>[], 'total_mb'=>0];
        $j = json_decode($raw, true);
        if (!is_array($j)) return ['ok'=>false, 'error'=>'bad JSON', 'models'=>[], 'total_mb'=>0];
        $models = [];
        foreach (($j['data'] ?? []) as $m) {
            $models[] = ['name' => (string)($m['id'] ?? '?'), 'size_mb' => 0, 'param' => '?', 'quant' => '?', 'processor' => '?'];
        }
        return ['ok'=>true, 'models'=>$models, 'total_mb'=>0];
    }

    $ch = curl_init(combos_backend_base() . '/api/ps');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 3]);
    $raw = curl_exec($ch);
    $err = curl_error($ch);
    curl_close($ch);
    if ($raw === false) return ['ok'=>false, 'error'=>$err ?: 'ollama offline', 'models'=>[], 'total_mb'=>0];

    $j = json_decode($raw, true);
    if (!is_array($j))  return ['ok'=>false, 'error'=>'bad JSON', 'models'=>[], 'total_mb'=>0];

    $models = [];
    $total  = 0.0;
    foreach (($j['models'] ?? []) as $m) {
        $mb = round((int)($m['size'] ?? 0) / 1048576, 1);
        $total += $mb;
        $proc = '?';
        if (isset($m['size']) && (int)$m['size'] > 0) {
            $sv  = (int)($m['size_vram'] ?? 0);
            $pct = (int)round($sv / (int)$m['size'] * 100);
            $proc = $pct >= 100 ? '100% GPU' : ($pct <= 0 ? '100% CPU' : ($pct . '% GPU'));
        }
        $vram_mb = round((int)($m['size_vram'] ?? 0) / 1048576, 1);
        // keep-alive: seconds until Ollama unloads this model from memory.
        $keep = null;
        if (!empty($m['expires_at'])) {
            $exp = strtotime((string)$m['expires_at']);
            if ($exp) $keep = max(0, $exp - time());
        }
        $models[] = [
            'name'        => (string)($m['name'] ?? '?'),
            'size_mb'     => $mb,
            'vram_mb'     => $vram_mb,
            'param'       => (string)($m['details']['parameter_size'] ?? '?'),
            'quant'       => (string)($m['details']['quantization_level'] ?? '?'),
            'processor'   => $proc,
            'keep_alive_s'=> $keep,
        ];
    }
    $total_vram = 0.0; foreach ($models as $mm) $total_vram += (float)$mm['vram_mb'];
    return ['ok'=>true, 'models'=>$models, 'total_mb'=>round($total, 1), 'total_vram_mb'=>round($total_vram, 1)];
}

// Combined status across BOTH servers, regardless of which one Card 3 is
// currently set to — dual-mode combos need to know if both are actually up
// before running, not just the active one.
//
// Data quality is genuinely asymmetric and reported honestly as such, not
// smoothed over: Ollama's /api/ps gives real per-model VRAM usage for what's
// CURRENTLY LOADED. LocalAI's /v1/models only lists what's AVAILABLE to
// load, not what's presently loaded or how much memory it's using — its
// /backend/monitor endpoint exists but returned "Unimplemented" for the
// gguf/llama.cpp backend when actually tested (2026-07-28), so it isn't
// used here. ram_mb is always 0 for LocalAI entries, not a placeholder for
// "we'll fill this in" — there's currently no reliable source for it.
// → ['ollama'=>['ok','running','models','total_mb'], 'localai'=>['ok','running','models']].
function combos_dual_status(): array {
    $out = ['ollama' => ['ok' => false, 'running' => false, 'models' => [], 'total_mb' => 0],
            'localai' => ['ok' => false, 'running' => false, 'models' => []]];

    $ch = curl_init(combos_ollama_base() . '/api/ps');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 3]);
    $raw = curl_exec($ch); curl_close($ch);
    if ($raw !== false) {
        $j = json_decode($raw, true);
        if (is_array($j)) {
            $out['ollama']['ok'] = true;
            $out['ollama']['running'] = true;
            $total = 0.0;
            foreach (($j['models'] ?? []) as $m) {
                $mb = round((int)($m['size'] ?? 0) / 1048576, 1);
                $total += $mb;
                $out['ollama']['models'][] = ['name' => (string)($m['name'] ?? '?'), 'size_mb' => $mb];
            }
            $out['ollama']['total_mb'] = round($total, 1);
        }
    }

    $ch = curl_init(combos_localai_base() . '/v1/models');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 3]);
    $raw = curl_exec($ch); curl_close($ch);
    if ($raw !== false) {
        $j = json_decode($raw, true);
        if (is_array($j)) {
            $out['localai']['ok'] = true;
            $out['localai']['running'] = true;
            foreach (($j['data'] ?? []) as $m) {
                $out['localai']['models'][] = ['name' => (string)($m['id'] ?? '?')];
            }
        }
    }

    return $out;
}

} // function guard
