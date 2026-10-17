<?php
// =============================================================================
// dual_model.php — regular (non-combo) chat with Ollama + LocalAI models
// loaded side by side. Dario Ruggi / AI Cockpit.
//
//   GET  ?action=list_models  → merged Ollama+LocalAI model list, tagged.
//   POST ?action=select       → {runner, model} set/swap one backend's slot,
//                                fit-checks and auto-clears the other slot
//                                when both wouldn't fit in detected VRAM.
//   POST ?action=score        → {prompt} — self-assessment pre-check, only
//                                valid when both slots are filled.
//   POST ?action=send         → {prompt, mode, judge_runner?} — real
//                                generation: mode=winner (+runner) for a
//                                single answer, or parallel/sequential/judge
//                                to run both slots as an ad-hoc 2-step combo.
//
// State: cockpit_data/dual_model_state.json — {"ollama": name|null,
// "localai": name|null}, same shape/pattern as ollama_config.json.
//
// KNOWN LIMITATION: Ollama has a real explicit unload (keep_alive:0). LocalAI
// does not — /backend/monitor was found unimplemented for the gguf backend
// during testing. Clearing LocalAI's slot here updates our own state/UI
// honestly but can't guarantee the model actually leaves LocalAI's memory.
// =============================================================================
require_once __DIR__ . '/combos_core.php';

// Same param-count parser as ollama_guard.php's ollama_param_b() — not
// require_once'd from there since that file hard-gates on auth.php with no
// CLI bypass (unlike combos_core.php), which would break this file's own
// CLI testability for one small pure function.
function dual_param_b(string $name): float {
    $tag = $name;
    if (strpos($name, ':') !== false) { $p = explode(':', $name); $tag = end($p); }
    if (preg_match('/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i', $tag, $m) ||
        preg_match('/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i', $name, $m)) {
        $n = (float)$m[1];
        return strtolower($m[2]) === 'm' ? $n / 1000.0 : $n;
    }
    return -1.0;
}
// Same ratio as ollama_guard.php's model_vram_estimate_mb() — kept in sync
// by hand (both derive from ollama_hardware_cap()'s ~1.5 GB/B rule of thumb).
function dual_vram_estimate_mb(string $modelName): int {
    $b = dual_param_b($modelName);
    if ($b < 0) return 0;
    return (int) round($b * 1024 * 1.5);
}

if (php_sapi_name() !== 'cli') {
    require_once __DIR__ . '/auth.php';
    ed_gate_or_exit('dual');   // HTTP-only; CLI lib/test use unaffected. demo: described-modal
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
}

function dual_state_path(): string {
    return $GLOBALS['CD'] . '/dual_model_state.json';
}
function dual_state_load(): array {
    $p = dual_state_path();
    if (is_readable($p)) {
        $j = json_decode((string)file_get_contents($p), true);
        if (is_array($j)) return ['ollama' => $j['ollama'] ?? null, 'localai' => $j['localai'] ?? null];
    }
    return ['ollama' => null, 'localai' => null];
}
function dual_state_save(array $state): void {
    @file_put_contents(dual_state_path(), json_encode($state, JSON_UNESCAPED_UNICODE));
}

// Total detected VRAM, MB — same cache ollama_hardware_cap() reads. That
// cache is normally populated lazily by ollama_hardware_cap() itself the
// first time anything calls it — but dual_model.php never requires
// ollama_guard.php (see the CLI/auth-coupling note above), so on a fresh
// per-user data dir where no chat has triggered that yet, the cache simply
// wouldn't exist and this would silently return 0 — skipping the fit-check
// entirely rather than refusing it. Self-populate here instead.
function dual_total_vram_mb(): int {
    $cacheFile = $GLOBALS['CD'] . '/hardware_scan.json';
    $hw = null;
    if (is_readable($cacheFile)) {
        $hw = json_decode((string)file_get_contents($cacheFile), true);
    }
    if (!is_array($hw)) {
        $script = $GLOBALS['PATHS']['home'] . '/scripts/hardware_scan.sh';
        if (is_file($script) && is_executable($script)) {
            $out = @shell_exec(escapeshellarg($script) . ' 2>/dev/null');
            $hw = json_decode(trim((string)$out), true);
            if (is_array($hw) && !empty($hw['ok'])) {
                @file_put_contents($cacheFile, json_encode($hw, JSON_UNESCAPED_UNICODE));
            }
        }
    }
    return is_array($hw) ? (int)($hw['gpu_vram_mb'] ?? 0) : 0;
}

// Real VRAM if Ollama currently has this model loaded, else an estimate.
function dual_model_vram_mb(string $runner, string $model): int {
    if ($runner === 'ollama') {
        $status = combos_dual_status();
        foreach ($status['ollama']['models'] ?? [] as $m) {
            if (($m['name'] ?? '') === $model) return (int)round($m['size_mb'] ?? 0);
        }
    }
    return dual_vram_estimate_mb($model);
}

function dual_list_models(): array {
    $out = [];
    // Real installed models via Ollama's own HTTP API — NOT shell_exec('ollama
    // list'), which silently returns empty here: the web server user (www-data
    // etc) usually has no 'ollama' on PATH even when the CLI user does, and
    // shell_exec is disabled outright on plenty of hardened PHP installs
    // either way. combos_dual_status()['ollama'] already solves this correctly
    // (HTTP /api/ps), but that only lists what's currently LOADED, not every
    // installed model — /api/tags is the one that returns everything pulled.
    $status = combos_dual_status();
    if (!empty($status['ollama']['ok'])) {
        $ch = curl_init(combos_ollama_base() . '/api/tags');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 4]);
        $raw = curl_exec($ch); curl_close($ch);
        if ($raw !== false) {
            $j = json_decode($raw, true);
            foreach (($j['models'] ?? []) as $m) {
                if (!empty($m['name'])) $out[] = ['name' => $m['name'], 'runner' => 'ollama'];
            }
        }
    }
    foreach ($status['localai']['models'] ?? [] as $m) {
        if (!empty($m['name']) && $m['name'] !== '?') $out[] = ['name' => $m['name'], 'runner' => 'localai'];
    }
    return $out;
}

if (php_sapi_name() !== 'cli') {
    $action = $_GET['action'] ?? '';

    // list_models is read-only and genuinely needed regardless of Card 3's
    // current provider — the Combo Editor calls it to populate step/judge
    // model pickers no matter which backend is active (or none), so it must
    // NOT be gated behind Dual mode. Every other action here actually
    // orchestrates live dual dispatch and stays gated below.
    if ($action === 'list_models') {
        echo json_encode(['ok' => true, 'models' => dual_list_models()], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Defense in depth — the UI only calls this file when dualModeActive()
    // is true client-side, but a stray request (stale tab, leftover client
    // state) shouldn't be able to touch the dual system unless Card 3's
    // provider is genuinely set to "Dual" server-side too.
    if (!combos_dual_mode_active()) {
        echo json_encode(['ok' => false, 'error' => 'Dual mode is off — set Card 3 to "Dual — Ollama + LocalAI" in Supplier Slots to use this.']);
        exit;
    }

    if ($action === 'status') {
        echo json_encode(['ok' => true, 'state' => dual_state_load()], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $in = json_decode((string)file_get_contents('php://input'), true) ?: [];

    if ($action === 'select') {
        $runner = ($in['runner'] ?? '') === 'localai' ? 'localai' : 'ollama';
        $model  = trim((string)($in['model'] ?? ''));

        if ($model === '') {
            // Explicit clear — no fit-check needed, freeing a slot never conflicts.
            $state = dual_state_load();
            $state[$runner] = null;
            dual_state_save($state);
            echo json_encode(['ok'=>true, 'state'=>$state, 'note'=>'']); exit;
        }

        $state = dual_state_load();
        $other = $runner === 'ollama' ? 'localai' : 'ollama';
        $note  = '';

        if (!empty($state[$other])) {
            $totalVram = dual_total_vram_mb();
            $otherMb   = dual_model_vram_mb($other, $state[$other]);
            $newMb     = dual_model_vram_mb($runner, $model);
            if ($totalVram > 0 && $otherMb > 0 && $newMb > 0 && ($otherMb + $newMb) > $totalVram) {
                $note = "Unloaded {$other}'s " . $state[$other] . " — didn't fit alongside " . $model . " in detected VRAM ({$totalVram} MB).";
                $state[$other] = null;
            }
        }
        $state[$runner] = $model;
        dual_state_save($state);
        echo json_encode(['ok'=>true, 'state'=>$state, 'note'=>$note], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($action === 'score') {
        $state = dual_state_load();
        if (empty($state['ollama']) || empty($state['localai'])) {
            echo json_encode(['ok'=>false,'error'=>'both slots must be filled to score']); exit;
        }
        $prompt = (string)($in['prompt'] ?? '');
        if ($prompt === '') { echo json_encode(['ok'=>false,'error'=>'missing prompt']); exit; }
        $meta = "Rate 1-10 how well you could answer this prompt. Reply with ONLY the number, nothing else.\n\nPrompt: " . $prompt;
        $jobs = [
            ['id'=>'ollama',  'model'=>$state['ollama'],  'runner'=>'ollama',  'prompt'=>$meta],
            ['id'=>'localai', 'model'=>$state['localai'], 'runner'=>'localai', 'prompt'=>$meta],
        ];
        $res = ollama_broadcast($jobs, ['timeout' => 30]);
        $parseScore = function(array $r): int {
            if (empty($r['ok'])) return 0;
            if (preg_match('/([0-9]{1,2})/', $r['text'], $m)) return max(1, min(10, (int)$m[1]));
            return 5;
        };
        echo json_encode(['ok'=>true,
            'ollama'  => ['model'=>$state['ollama'],  'score'=>$parseScore($res['ollama'] ?? [])],
            'localai' => ['model'=>$state['localai'], 'score'=>$parseScore($res['localai'] ?? [])],
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($action === 'send') {
        $state  = dual_state_load();
        $prompt = (string)($in['prompt'] ?? '');
        $mode   = (string)($in['mode'] ?? 'winner');
        if ($prompt === '') { echo json_encode(['ok'=>false,'error'=>'missing prompt']); exit; }

        if ($mode === 'winner') {
            $runner = ($in['runner'] ?? '') === 'localai' ? 'localai' : 'ollama';
            $model  = $state[$runner] ?? '';
            if ($model === '') { echo json_encode(['ok'=>false,'error'=>"no model selected for $runner"]); exit; }
            $r = ollama_generate($model, $prompt, ['runner'=>$runner]);
            echo json_encode(['ok'=>$r['ok'], 'text'=>$r['text'], 'error'=>$r['error'], 'model'=>$model, 'runner'=>$runner], JSON_UNESCAPED_UNICODE);
            exit;
        }

        if (in_array($mode, ['parallel','sequential','judge'], true)) {
            if (empty($state['ollama']) || empty($state['localai'])) {
                echo json_encode(['ok'=>false,'error'=>'both slots must be filled for '.$mode]); exit;
            }
            $combo = [
                'pattern' => $mode,
                'steps' => [
                    ['model'=>$state['ollama'],  'runner'=>'ollama',  'role'=>'Ollama'],
                    ['model'=>$state['localai'], 'runner'=>'localai', 'role'=>'LocalAI'],
                ],
            ];
            if ($mode === 'judge') {
                $judgeRunner = ($in['judge_runner'] ?? '') === 'localai' ? 'localai' : 'ollama';
                $combo['judge'] = ['model' => $state[$judgeRunner], 'runner' => $judgeRunner];
            }
            $r = combos_run_combo($combo, $prompt, '', 'dual-model');
            echo json_encode($r, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
            exit;
        }

        echo json_encode(['ok'=>false,'error'=>'unknown mode: '.$mode]);
        exit;
    }

    echo json_encode(['ok'=>false,'error'=>'unknown action']);
    exit;
}
