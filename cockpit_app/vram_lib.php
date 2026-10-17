<?php
// =============================================================================
// vram_lib.php — shared VRAM-budget helpers, lifted from dual_model.php so the
// multi-agent dispatch (Broadcast) can check whether the selected LOCAL models
// co-fit in GPU VRAM before firing them in parallel. Pure functions, no entry
// side-effects — safe to require from any backend.
//
// Why this matters: paid CLI agents (Claude/Codex) are cloud → 0 VRAM. Free
// agents pointed at local Ollama/LocalAI load a full model into the SAME GPU as
// Card 3. Two local agents at once thrash/OOM. This lib feeds the guard that
// degrades the local subset of a Broadcast to sequential while cloud stays parallel.
// =============================================================================
if (defined('COCKPIT_VRAM_LIB')) return;
define('COCKPIT_VRAM_LIB', true);

// Parse a model's parameter count in billions from its name/tag (e.g. "…:7b"→7.0,
// "…-32b"→32.0, "…-1.5b"→1.5, "…-800m"→0.8). -1 when unknown.
function vram_param_b(string $name): float {
    $tag = $name;
    if (strpos($name, ':') !== false) { $p = explode(':', $name); $tag = end($p); }
    if (preg_match('/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i', $tag, $m) ||
        preg_match('/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i', $name, $m)) {
        $n = (float)$m[1];
        return strtolower($m[2]) === 'm' ? $n / 1000.0 : $n;
    }
    return -1.0;
}

// Rough VRAM footprint estimate in MB (~1.5 GB per billion params — same rule of
// thumb as ollama_guard/dual_model). 0 when the size can't be parsed.
function vram_estimate_mb(string $modelName): int {
    $b = vram_param_b($modelName);
    if ($b < 0) return 0;
    return (int) round($b * 1024 * 1.5);
}

// The machine-wide hardware scan (cpu_model, cpu_cores, ram_mb, gpu_name,
// gpu_vram_mb). Reads the SHARED root first (hardware is per-machine, not
// per-user), then a per-user fallback; self-populates via hardware_scan.sh when
// neither cache exists. A cache without cpu_model predates that field and is
// rescanned once. [] when nothing is detectable.
function hw_scan(): array {
    static $cached = null;
    if ($cached !== null) return $cached;
    $paths = $GLOBALS['PATHS'] ?? [];
    $roots = array_values(array_unique(array_filter([
        $paths['cockpit_data_root'] ?? null,
        $GLOBALS['CD'] ?? null,
        $paths['cockpit_data'] ?? null,
    ])));
    foreach ($roots as $r) {
        $f = $r . '/hardware_scan.json';
        if (is_readable($f)) {
            $hw = json_decode((string)file_get_contents($f), true);
            if (is_array($hw) && isset($hw['gpu_vram_mb']) && array_key_exists('cpu_model', $hw)) return $cached = $hw;
        }
    }
    // No (current) cache yet — run the scan once and cache it at the shared root.
    $script = ($paths['home'] ?? '') . '/scripts/hardware_scan.sh';
    if (is_file($script) && is_executable($script)) {
        $out = @shell_exec(escapeshellarg($script) . ' 2>/dev/null');
        $hw  = json_decode(trim((string)$out), true);
        if (is_array($hw) && !empty($hw['ok'])) {
            $dest = ($paths['cockpit_data_root'] ?? ($GLOBALS['CD'] ?? '')) . '/hardware_scan.json';
            if ($dest !== '/hardware_scan.json') @file_put_contents($dest, json_encode($hw, JSON_UNESCAPED_UNICODE));
            return $cached = $hw;
        }
    }
    return $cached = [];
}

// Total detected GPU VRAM in MB. 0 if nothing is detectable (→ caller should
// skip the fit-check rather than block).
function vram_total_mb(): int {
    return (int)(hw_scan()['gpu_vram_mb'] ?? 0);
}

// Budget check: given a list of [runner, model] the caller wants to run AT ONCE,
// return whether their combined estimated VRAM fits detected VRAM. Unknown sizes
// contribute 0 (can't estimate → don't block on them). detected==0 → fits=true
// (undetectable hardware → don't refuse; let Ollama manage).
//   $locals = [ ['runner'=>'ollama','model'=>'qwen2.5-coder:7b'], ... ]
function vram_budget(array $locals): array {
    $detected = vram_total_mb();
    $per = []; $need = 0;
    foreach ($locals as $l) {
        $model = (string)($l['model'] ?? '');
        if ($model === '') continue;
        $mb = vram_estimate_mb($model);
        $need += $mb;
        $per[] = ['runner' => $l['runner'] ?? '', 'model' => $model, 'est_mb' => $mb];
    }
    $fits = ($detected <= 0) ? true : ($need <= $detected);
    return [
        'ok'             => true,
        'fits'           => $fits,
        'total_needed_mb'=> $need,
        'detected_mb'    => $detected,
        'models'         => $per,
    ];
}
