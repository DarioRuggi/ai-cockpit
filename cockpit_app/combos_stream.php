<?php
// =============================================================================
// combos_stream.php — Power Combos with LIVE token streaming (SSE).
// GET ?combo_id=&prompt=&project=&chat=&rag=
// Events:
//   init      {combo, pattern, steps:[{id,role,model}], judge?:{id,role,model}}
//   token     {step, t}                — a chunk of text for a step
//   step_done {step, ms}
//   done      {ok, saved, error?}
// Sequential streams one model at a time; parallel/judge stream concurrently
// via curl_multi with per-handle write callbacks. Falls back gracefully.
// =============================================================================
require_once __DIR__ . '/combos_core.php';
require_once __DIR__ . '/auth.php';   // 401 if not logged in (before stream opens)
ed_gate_or_exit('combos');            // demo: described-modal (JSON, before SSE opens); v1/v2: real

@set_time_limit(0);
@ini_set('max_execution_time', '0');
while (ob_get_level() > 0) ob_end_flush();
header('Content-Type: text/event-stream');
header('Cache-Control: no-cache');
header('X-Accel-Buffering: no');   // disable nginx/proxy buffering

function sse(string $event, array $data): void {
    echo 'event: ' . $event . "\n";
    echo 'data: ' . json_encode($data, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES) . "\n\n";
    @flush();
}

$id     = trim((string)($_GET['combo_id'] ?? ''));
$prompt = (string)($_GET['prompt'] ?? '');
$rag    = (string)($_GET['rag'] ?? '');
$project= (string)($_GET['project'] ?? 'default');
$chat   = (string)($_GET['chat'] ?? 'default');

$combo = $id === '' ? null : combos_find($id);
if (!$combo) { sse('done', ['ok'=>false, 'error'=>'unknown combo']); exit; }
$pattern = $combo['pattern'] ?? 'parallel';
$steps   = $combo['steps'] ?? [];
if (!$steps) { sse('done', ['ok'=>false, 'error'=>'combo has no steps']); exit; }

// Announce the steps so the client can build the grid before tokens arrive.
$initSteps = array_map(fn($s) => ['id'=>$s['id'] ?? $s['model'], 'role'=>$s['role'] ?? '', 'model'=>$s['model']], $steps);
$init = ['combo'=>$id, 'pattern'=>$pattern, 'steps'=>$initSteps];
if ($pattern === 'judge' && !empty($combo['judge']['model'])) {
    $init['judge'] = ['id'=>'__judge__', 'role'=>'Judge', 'model'=>$combo['judge']['model']];
}
sse('init', $init);

$base = combos_ollama_base();

// Stream one model; emit token events tagged with $stepId; return full text.
function stream_one(string $base, string $stepId, string $model, string $prompt, string $system, array $options): string {
    $payload = ['model'=>$model, 'prompt'=>$prompt, 'stream'=>true, 'options'=>array_merge(['num_ctx'=>4096], $options)];
    if ($system !== '') $payload['system'] = $system;
    $buf = ''; $text = '';
    $ch = curl_init($base . '/api/generate');
    curl_setopt_array($ch, [
        CURLOPT_POST=>true, CURLOPT_POSTFIELDS=>json_encode($payload),
        CURLOPT_HTTPHEADER=>['Content-Type: application/json'], CURLOPT_TIMEOUT=>180,
        CURLOPT_WRITEFUNCTION=>function($ch, $chunk) use (&$buf, &$text, $stepId) {
            $buf .= $chunk;
            while (($nl = strpos($buf, "\n")) !== false) {
                $line = trim(substr($buf, 0, $nl)); $buf = substr($buf, $nl + 1);
                if ($line === '') continue;
                $j = json_decode($line, true);
                if (isset($j['response']) && $j['response'] !== '') { $text .= $j['response']; sse('token', ['step'=>$stepId, 't'=>$j['response']]); }
                if (isset($j['error'])) { sse('token', ['step'=>$stepId, 't'=>'[error] '.$j['error']]); }
            }
            return strlen($chunk);
        },
    ]);
    curl_exec($ch); curl_close($ch);
    return $text;
}

$results = [];
$t0 = microtime(true);

if ($pattern === 'sequential') {
    $prev = '';
    foreach ($steps as $s) {
        $job = combos_step_job($s, $prompt, $rag, $prev);
        $st = microtime(true);
        $text = stream_one($base, $job['id'], $job['model'], $job['prompt'], $job['system'], $job['options']);
        $ms = (int)round((microtime(true) - $st) * 1000);
        sse('step_done', ['step'=>$job['id'], 'ms'=>$ms]);
        $results[] = ['id'=>$job['id'],'role'=>$job['role'],'model'=>$job['model'],'ok'=>($text!==''),'text'=>$text,'ms'=>$ms,'error'=>($text===''?'empty':'')];
        $prev = $text;
    }
} else {
    // Optional shared SEED (parallel cohesion) — run once before broadcasting.
    $seedText = '';
    if (!empty($combo['seed']['model'])) {
        $sp = combos_fill((string)($combo['seed']['prompt'] ?? '{{PROMPT}}'), $prompt, $rag, '');
        $seedText = stream_one($base, '__seed__', $combo['seed']['model'], $sp, $combo['seed']['system'] ?? '', []);
        sse('step_done', ['step'=>'__seed__', 'ms'=>(int)round((microtime(true)-$t0)*1000)]);
    }
    // parallel + judge: stream all steps concurrently with curl_multi.
    $mh = curl_multi_init(); $handles = []; $bufs = []; $texts = []; $meta = [];
    foreach ($steps as $s) {
        $job = combos_step_job($s, $prompt, $rag, '');
        if ($seedText !== '') $job['prompt'] = "Shared premise (build on this, stay consistent with it):\n" . $seedText . "\n\n" . $job['prompt'];
        $sid = $job['id']; $bufs[$sid] = ''; $texts[$sid] = ''; $meta[$sid] = $job;
        $payload = ['model'=>$job['model'],'prompt'=>$job['prompt'],'stream'=>true,'options'=>array_merge(['num_ctx'=>4096],$job['options'])];
        if ($job['system'] !== '') $payload['system'] = $job['system'];
        $ch = curl_init($base . '/api/generate');
        curl_setopt_array($ch, [
            CURLOPT_POST=>true, CURLOPT_POSTFIELDS=>json_encode($payload),
            CURLOPT_HTTPHEADER=>['Content-Type: application/json'], CURLOPT_TIMEOUT=>180,
            CURLOPT_WRITEFUNCTION=>function($c, $chunk) use ($sid, &$bufs, &$texts) {
                $bufs[$sid] .= $chunk;
                while (($nl = strpos($bufs[$sid], "\n")) !== false) {
                    $line = trim(substr($bufs[$sid], 0, $nl)); $bufs[$sid] = substr($bufs[$sid], $nl + 1);
                    if ($line === '') continue;
                    $j = json_decode($line, true);
                    if (isset($j['response']) && $j['response'] !== '') { $texts[$sid] .= $j['response']; sse('token', ['step'=>$sid, 't'=>$j['response']]); }
                    if (isset($j['error'])) sse('token', ['step'=>$sid, 't'=>'[error] '.$j['error']]);
                }
                return strlen($chunk);
            },
        ]);
        curl_multi_add_handle($mh, $ch); $handles[$sid] = $ch;
    }
    $running = null;
    do { curl_multi_exec($mh, $running); if ($running > 0) curl_multi_select($mh, 1.0); } while ($running > 0);
    foreach ($handles as $sid => $ch) {
        $ms = (int)round((microtime(true) - $t0) * 1000);
        sse('step_done', ['step'=>$sid, 'ms'=>$ms]);
        $j = $meta[$sid];
        $results[] = ['id'=>$sid,'role'=>$j['role'],'model'=>$j['model'],'ok'=>($texts[$sid]!==''),'text'=>$texts[$sid],'ms'=>$ms,'error'=>($texts[$sid]===''?'empty':'')];
        curl_multi_remove_handle($mh, $ch); curl_close($ch);
    }
    curl_multi_close($mh);

    // Judge: stream the verdict after the candidates.
    if ($pattern === 'judge' && !empty($combo['judge']['model'])) {
        $parts = [];
        foreach ($results as $r) $parts[] = strtoupper($r['role'] ?: $r['id']) . ":\n" . $r['text'];
        $jprompt = "User request:\n$prompt\n\nCandidate answers:\n" . implode("\n\n", $parts);
        $st = microtime(true);
        $jtext = stream_one($base, '__judge__', $combo['judge']['model'], $jprompt, $combo['judge']['system'] ?? '', ['temperature'=>0.3]);
        sse('step_done', ['step'=>'__judge__', 'ms'=>(int)round((microtime(true)-$st)*1000)]);
        $judge = ['model'=>$combo['judge']['model'],'ok'=>($jtext!==''),'text'=>$jtext];
    }
}

// Build the result shape combos_flatten expects, persist to chat, finish.
$result = ['ok'=>true, 'combo'=>$id, 'pattern'=>$pattern, 'steps'=>$results];
if (isset($judge)) { $result['judge'] = $judge; $result['final'] = $judge['text']; }
elseif ($pattern === 'sequential' && $results) { $result['final'] = end($results)['text']; }

$saved = false;
if (isset($PATHS['projects_root'])) {
    $saved = combos_append_chat((string)$PATHS['projects_root'], $project, $chat, $prompt, combos_flatten($result), 'combo:' . $id);
}
sse('done', ['ok'=>true, 'saved'=>$saved]);
