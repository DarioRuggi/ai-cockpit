<?php
// =============================================================================
// models_dev.php — live model metadata from models.dev (context windows,
// pricing, capabilities). Fetched on a schedule (cron, every ~2 days), slimmed
// to the providers cockpit uses, cached cockpit_data/models_dev.json.
//
//   CLI:  php models_dev.php refresh     (cron — no auth)
//   HTTP: ?action=refresh | ?action=get  (auth-gated)
//
// Consumers: token estimate (real ctx), paid-spend gate (real rates), model
// capability hints. Ollama (local) isn't on models.dev — keep /api/tags for it.
// =============================================================================
require_once __DIR__ . '/paths.php';
if (PHP_SAPI !== 'cli') require_once __DIR__ . '/auth.php';
// NOT saas-gated: public models.dev metadata (ctx windows, pricing) feeding
// token-estimate + paid-spend gate. Infra — v1 needs it. Harmless in demo.
header('Content-Type: application/json');

// Model metadata is machine-wide, not per-user. Store it at the SHARED root so the
// CLI/cron refresh (no session → shared) and authed client reads (per-user $CD) agree.
$CACHE = ($PATHS['cockpit_data_root'] ?? $CD) . '/models_dev.json';
$action = $_GET['action'] ?? ($argv[1] ?? 'get');

// models.dev provider ids cockpit maps to (claude→anthropic, gemini→google, …).
$WANT = ['anthropic','google','groq','openai','cloudflare-workers-ai','huggingface','mistral','deepseek','xai','together','openrouter'];

function modelsdev_slim(string $raw, array $want): ?array {
    $j = json_decode($raw, true);
    if (!is_array($j)) return null;
    $out = ['updated' => gmdate('c'), 'providers' => []];
    foreach ($want as $pid) {
        if (empty($j[$pid]['models'])) continue;
        $models = [];
        foreach ($j[$pid]['models'] as $mid => $m) {
            $models[$mid] = [
                'name'      => $m['name'] ?? $mid,
                'ctx'       => $m['limit']['context'] ?? null,
                'max_out'   => $m['limit']['output'] ?? null,
                'in'        => $m['cost']['input'] ?? null,    // USD / 1M tokens
                'out'       => $m['cost']['output'] ?? null,
                'vision'    => !empty($m['attachment']),
                'tools'     => !empty($m['tool_call']),
                'reasoning' => !empty($m['reasoning']),
                // output modality lets consumers keep only text-generation models
                // (drops embeddings / TTS / image / video / clip models).
                'out_modal' => $m['modalities']['output'] ?? null,
            ];
        }
        $out['providers'][$pid] = $models;
    }
    return $out;
}

if ($action === 'refresh') {
    $ch = curl_init('https://models.dev/api.json');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>30, CURLOPT_FOLLOWLOCATION=>true]);
    $raw  = curl_exec($ch);
    $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($raw === false || $code !== 200) { echo json_encode(['ok'=>false, 'error'=>"fetch failed ($code)"]); exit; }
    $slim = modelsdev_slim($raw, $WANT);
    if (!$slim) { echo json_encode(['ok'=>false, 'error'=>'parse failed']); exit; }
    @file_put_contents($CACHE, json_encode($slim, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE));
    @chmod($CACHE, 0664);
    $n = 0; foreach ($slim['providers'] as $p) $n += count($p);
    echo json_encode(['ok'=>true, 'providers'=>count($slim['providers']), 'models'=>$n, 'updated'=>$slim['updated']]);
    exit;
}

// get (default) — return the cache for the client to use.
$cache = is_readable($CACHE) ? json_decode((string)file_get_contents($CACHE), true) : null;
echo json_encode(['ok'=>true, 'cache'=>$cache], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
