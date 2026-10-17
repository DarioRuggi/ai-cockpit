<?php
// =============================================================================
// models.php — Ollama model management for AI Cockpit
//
// Endpoints (all return JSON):
//   GET  /                          — list installed models (default)
//   GET  /?action=list              — same as default
//   POST /?action=pull              — { model } — start background pull
//   GET  /?action=pull_status       — { model } — read pull progress log
//   POST /?action=remove            — { model } — remove a model
//   GET  /?action=details           — { model } — `ollama show <model>` output
//
// All shell-out via escapeshellarg. Pull runs detached so the HTTP request
// returns immediately; UI polls pull_status to update progress.
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === '' || $__demoAction === 'list') {
        echo json_encode(['ok'=>true,'models'=>[
            ['name'=>'qwen2.5-coder:7b','id'=>'a1b2c3d4','size'=>'4.7 GB','modified'=>'3 days ago','is_variant'=>false],
            ['name'=>'llama3.2:3b','id'=>'e5f6a7b8','size'=>'2.0 GB','modified'=>'1 week ago','is_variant'=>false],
            ['name'=>'deepseek-r1:8b','id'=>'c9d0e1f2','size'=>'4.9 GB','modified'=>'2 weeks ago','is_variant'=>false],
        ]]); exit;
    }
    ed_demo_stub();
}

$OLLAMA = $PATHS['ollama_binary'] ?? '';
if (!$OLLAMA || !is_file($OLLAMA)) {
    $alt = trim((string)shell_exec('which ollama 2>/dev/null'));
    if ($alt) $OLLAMA = $alt;
}

$LOG_DIR = '/tmp/cockpit_ollama_pulls';
if (!is_dir($LOG_DIR)) @mkdir($LOG_DIR, 0775, true);

$action = $_GET['action'] ?? '';
if (empty($action) && $_SERVER['REQUEST_METHOD'] === 'POST') {
    $in = json_decode((string)file_get_contents('php://input'), true);
    if (is_array($in)) $action = $in['action'] ?? '';
} else {
    $in = [];
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $raw = json_decode((string)file_get_contents('php://input'), true);
        if (is_array($raw)) $in = $raw;
    }
}
if ($action === '') $action = 'list';

// Sanitize model identifier — allow lowercase letters/digits/colons/dots/dashes/slashes
function safe_model($s) {
    return preg_replace('/[^a-zA-Z0-9:.\-_\/]/', '', (string)$s);
}

// ── list: parse `ollama list` ────────────────────────────────────────────────
if ($action === 'list') {
    if (!is_file($OLLAMA)) { echo json_encode(['ok'=>false,'error'=>'ollama not found','models'=>[]], JSON_UNESCAPED_UNICODE); exit; }
    $out = (string)shell_exec(escapeshellarg($OLLAMA) . ' list 2>/dev/null');
    $lines = preg_split('/\r?\n/', $out);
    $models = [];
    foreach ($lines as $i => $ln) {
        if ($i === 0) continue;                      // header
        $ln = trim($ln);
        if ($ln === '') continue;
        // Format: NAME    ID    SIZE    MODIFIED
        $cols = preg_split('/\s{2,}|\t/', $ln);
        if (count($cols) >= 3) {
            $name = $cols[0];
            $models[] = [
                'name'     => $name,
                'id'       => $cols[1],
                'size'     => $cols[2] ?? '',
                'modified' => $cols[3] ?? '',
                'is_variant' => (bool)preg_match('/-agentic\b/', $name),
            ];
        }
    }
    echo json_encode(['ok'=>true, 'models'=>$models], JSON_UNESCAPED_UNICODE); exit;
}

// ── details: `ollama show <model>` ────────────────────────────────────────────
if ($action === 'details') {
    $m = safe_model($in['model'] ?? ($_GET['model'] ?? ''));
    if ($m === '') { echo json_encode(['ok'=>false,'error'=>'Missing model'], JSON_UNESCAPED_UNICODE); exit; }
    if (!is_file($OLLAMA)) { echo json_encode(['ok'=>false,'error'=>'ollama not found'], JSON_UNESCAPED_UNICODE); exit; }
    $out = (string)shell_exec(cockpit_timeout_cmd(10) . escapeshellarg($OLLAMA) .
        ' show ' . escapeshellarg($m) . ' 2>&1');
    echo json_encode(['ok'=>true, 'model'=>$m, 'details'=>$out], JSON_UNESCAPED_UNICODE); exit;
}

// ── pull: spawn `ollama pull` detached, write progress to /tmp ───────────────
if ($action === 'pull') {
    $m = safe_model($in['model'] ?? ($_GET['model'] ?? ''));
    if ($m === '') { echo json_encode(['ok'=>false,'error'=>'Missing model'], JSON_UNESCAPED_UNICODE); exit; }
    if (!is_file($OLLAMA)) { echo json_encode(['ok'=>false,'error'=>'ollama not found'], JSON_UNESCAPED_UNICODE); exit; }
    // Sanitize the log file name from the model
    $slug = preg_replace('/[^a-zA-Z0-9_\-]+/', '_', $m);
    $log  = $LOG_DIR . '/' . $slug . '.log';
    $done = $LOG_DIR . '/' . $slug . '.done';
    @unlink($done);
    @file_put_contents($log, "Starting pull of $m at " . date('c') . "\n");
    @chmod($log, 0664);
    // Background pull — nohup + redirect + & — wait for exit, write rc to .done
    $cmd = '(nohup ' . escapeshellarg($OLLAMA) . ' pull ' . escapeshellarg($m) .
           ' >> ' . escapeshellarg($log) . ' 2>&1; echo "rc=$?" > ' .
           escapeshellarg($done) . ') > /dev/null 2>&1 &';
    shell_exec($cmd);
    echo json_encode(['ok'=>true, 'model'=>$m, 'log'=>$log], JSON_UNESCAPED_UNICODE); exit;
}

// ── pull_status: tail the log + check for .done sentinel ─────────────────────
if ($action === 'pull_status') {
    $m = safe_model($in['model'] ?? ($_GET['model'] ?? ''));
    if ($m === '') { echo json_encode(['ok'=>false,'error'=>'Missing model'], JSON_UNESCAPED_UNICODE); exit; }
    $slug = preg_replace('/[^a-zA-Z0-9_\-]+/', '_', $m);
    $log  = $LOG_DIR . '/' . $slug . '.log';
    $done = $LOG_DIR . '/' . $slug . '.done';
    $logTxt = is_file($log) ? (string)file_get_contents($log) : '';
    // Trim to last ~4 KB so the UI doesn't grow unboundedly
    if (strlen($logTxt) > 4096) $logTxt = substr($logTxt, -4096);
    $finished = is_file($done);
    $rc = null;
    if ($finished) {
        $rcLine = trim((string)file_get_contents($done));
        if (preg_match('/rc=(-?\d+)/', $rcLine, $mm)) $rc = (int)$mm[1];
    }
    // A pull that failed may be a model the registry withdrew: the Cockpit
    // mirror (downloads/models/index.json on cockpit.ruggi.site) can hold such
    // models, and the restore path (model_manifest.sh) fetches from it. Tell the
    // page so the user gets the one-liner instead of a bare rc.
    $mirror = null;
    if ($finished && $rc !== 0) {
        $idx = @json_decode((string)@file_get_contents('https://cockpit.ruggi.site/downloads/models/index.json', false,
                    stream_context_create(['http'=>['timeout'=>6]])), true);
        if (is_array($idx) && !empty($idx['models'][$m]['url'])) $mirror = $idx['models'][$m] + ['restore' => '~/scripts/model_manifest.sh restore'];
    }
    echo json_encode(['ok'=>true, 'model'=>$m, 'log'=>$logTxt,
                       'finished'=>$finished, 'rc'=>$rc, 'mirror'=>$mirror], JSON_UNESCAPED_UNICODE); exit;
}

// ── remove: `ollama rm <model>` ──────────────────────────────────────────────
if ($action === 'remove') {
    $m = safe_model($in['model'] ?? ($_GET['model'] ?? ''));
    if ($m === '') { echo json_encode(['ok'=>false,'error'=>'Missing model'], JSON_UNESCAPED_UNICODE); exit; }
    if (!is_file($OLLAMA)) { echo json_encode(['ok'=>false,'error'=>'ollama not found'], JSON_UNESCAPED_UNICODE); exit; }
    $out = (string)shell_exec(cockpit_timeout_cmd(30) . escapeshellarg($OLLAMA) .
        ' rm ' . escapeshellarg($m) . ' 2>&1');
    echo json_encode(['ok'=>true, 'model'=>$m, 'output'=>$out], JSON_UNESCAPED_UNICODE); exit;
}

// ── search: filter a curated catalog of popular Ollama models ─────────────────
// Ollama has no public search API, so we ship a curated list of commonly-used
// models (skewed toward coding + small models that fit a 4 GB VRAM budget) and
// filter it by the query. Any model id can still be pulled directly via the
// pull action even if it isn't in this list.
if ($action === 'search') {
    $q = strtolower(trim((string)($in['q'] ?? ($_GET['q'] ?? ''))));
    $catalog = [
        ['id'=>'qwen2.5-coder:1.5b',  'size'=>'~2 GB',  'note'=>'Fast local coder, fits 4 GB VRAM'],
        ['id'=>'glm4',              'size'=>'~5.5 GB','note'=>'GLM-4 9B — strong CRUD/context/agentic. >4B: manual/scheduled only. On 4 GB VRAM run the one-click tuned model (glm4-cockpit).', 'auto_eligible'=>false],
        ['id'=>'qwen2.5-coder:7b',  'size'=>'~4.7 GB','note'=>'Stronger coder, tight on 4 GB VRAM'],
        ['id'=>'qwen2.5-coder:14b', 'size'=>'~9 GB',  'note'=>'Best Qwen coder, needs more VRAM/CPU'],
        ['id'=>'qwen2.5:3b',        'size'=>'~2 GB',  'note'=>'General small model'],
        ['id'=>'qwen2.5:7b',        'size'=>'~4.7 GB','note'=>'General mid model'],
        ['id'=>'llama3.2:1b',       'size'=>'~1.3 GB','note'=>'Tiny, very fast'],
        ['id'=>'llama3.2:3b',       'size'=>'~2 GB',  'note'=>'Small general model'],
        ['id'=>'llama3.1:8b',       'size'=>'~4.7 GB','note'=>'Solid general 8B'],
        ['id'=>'gemma3:4b',         'size'=>'~3.3 GB','note'=>'Vision-capable, used by Cockpit vision'],
        ['id'=>'gemma3:12b',        'size'=>'~8 GB',  'note'=>'Larger vision/general'],
        ['id'=>'mistral:7b',        'size'=>'~4.1 GB','note'=>'Popular general 7B'],
        ['id'=>'phi3:mini',         'size'=>'~2.3 GB','note'=>'Small, strong reasoning'],
        ['id'=>'deepseek-r1:7b',    'size'=>'~4.7 GB','note'=>'Reasoning-focused'],
        ['id'=>'deepseek-r1:8b',    'size'=>'~5 GB',  'note'=>'Reasoning-focused, larger'],
        ['id'=>'codellama:7b',      'size'=>'~3.8 GB','note'=>'Code-specialized Llama'],
        ['id'=>'nomic-embed-text',  'size'=>'~274 MB','note'=>'Embeddings (used by Deep Search)'],
        ['id'=>'starcoder2:3b',     'size'=>'~1.7 GB','note'=>'Code completion'],
        ['id'=>'smollm2:1.7b',      'size'=>'~1 GB',  'note'=>'Very small general'],
    ];
    $results = $catalog;
    if ($q !== '') {
        $results = array_values(array_filter($catalog, function($m) use ($q) {
            return strpos(strtolower($m['id']), $q) !== false
                || strpos(strtolower($m['note']), $q) !== false;
        }));
    }
    echo json_encode(['ok'=>true, 'query'=>$q, 'models'=>$results,
        'note'=>'Curated list — any model id can also be pulled directly.'], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── probe: tool-call round-trip verification for a model ─────────────────────
// Tests whether a model can emit valid tool_use JSON — the gate for agentic use.
// Sends a simple prompt requesting a tool call and checks the response format.
if ($action === 'probe') {
    $m = safe_model($in['model'] ?? ($_GET['model'] ?? ''));
    if ($m === '') { echo json_encode(['ok'=>false,'error'=>'Missing model'], JSON_UNESCAPED_UNICODE); exit; }

    $checks = [];

    // Check 1: Ollama reachable
    $health = @file_get_contents('http://localhost:11434/api/tags');
    if ($health === false) {
        echo json_encode(['ok'=>false, 'error'=>'Ollama not reachable at :11434',
            'checks'=>[['name'=>'ollama_health','pass'=>false,'detail'=>'Connection refused']]], JSON_UNESCAPED_UNICODE); exit;
    }
    $checks[] = ['name'=>'ollama_health','pass'=>true,'detail'=>'Ollama responding'];

    // Check 2: Model loaded
    $tags = json_decode($health, true);
    $found = false;
    foreach (($tags['models'] ?? []) as $t) {
        if (($t['name'] ?? '') === $m || ($t['model'] ?? '') === $m) { $found = true; break; }
    }
    // Also accept partial match (tag without :latest)
    if (!$found) {
        foreach (($tags['models'] ?? []) as $t) {
            $n = $t['name'] ?? '';
            if (strpos($n, $m) === 0 || strpos($m, explode(':', $n)[0]) === 0) { $found = true; break; }
        }
    }
    $checks[] = ['name'=>'model_present','pass'=>$found,'detail'=>$found ? 'Model found' : 'Model not in ollama list'];
    if (!$found) {
        echo json_encode(['ok'=>false, 'error'=>'Model not installed', 'checks'=>$checks], JSON_UNESCAPED_UNICODE); exit;
    }

    // Check 3: Anthropic Messages API (native endpoint)
    $msg_payload = json_encode([
        'model' => $m,
        'max_tokens' => 100,
        'messages' => [['role'=>'user','content'=>'Reply with exactly: hello']],
    ], JSON_UNESCAPED_UNICODE);
    $ch = curl_init('http://localhost:11434/v1/messages');
    curl_setopt_array($ch, [
        CURLOPT_POST => true,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json', 'x-api-key: ollama'],
        CURLOPT_POSTFIELDS => $msg_payload,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 60,
    ]);
    $msg_resp = curl_exec($ch);
    $msg_code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    $msg_ok = $msg_code >= 200 && $msg_code < 400;
    $checks[] = ['name'=>'messages_api','pass'=>$msg_ok,
        'detail'=>$msg_ok ? 'Anthropic Messages endpoint OK' : 'Messages API returned HTTP '.$msg_code];
    // If Messages API fails, try OpenAI-compat as fallback check
    if (!$msg_ok) {
        $oai_payload = json_encode([
            'model' => $m,
            'messages' => [['role'=>'user','content'=>'Reply with exactly: hello']],
            'max_tokens' => 100,
        ], JSON_UNESCAPED_UNICODE);
        $ch2 = curl_init('http://localhost:11434/v1/chat/completions');
        curl_setopt_array($ch2, [
            CURLOPT_POST => true,
            CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
            CURLOPT_POSTFIELDS => $oai_payload,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 60,
        ]);
        $oai_resp = curl_exec($ch2);
        $oai_code = curl_getinfo($ch2, CURLINFO_HTTP_CODE);
        curl_close($ch2);
        $oai_ok = $oai_code >= 200 && $oai_code < 400;
        $checks[] = ['name'=>'openai_compat_fallback','pass'=>$oai_ok,
            'detail'=>$oai_ok ? 'OpenAI-compat endpoint OK (Messages API unavailable)' : 'Both APIs failed'];
        if (!$oai_ok) {
            echo json_encode(['ok'=>false, 'error'=>'Model cannot serve chat completions', 'checks'=>$checks], JSON_UNESCAPED_UNICODE); exit;
        }
    }

    // Check 4: Tool-call round-trip — the critical test
    $tool_payload = json_encode([
        'model' => $m,
        'messages' => [['role'=>'user','content'=>'What is the weather in Paris? Use the get_weather tool.']],
        'max_tokens' => 300,
        'temperature' => 0.1,
        'tools' => [[
            'type' => 'function',
            'function' => [
                'name' => 'get_weather',
                'description' => 'Get current weather for a city',
                'parameters' => [
                    'type' => 'object',
                    'properties' => [
                        'city' => ['type'=>'string','description'=>'City name'],
                    ],
                    'required' => ['city'],
                ],
            ],
        ]],
    ], JSON_UNESCAPED_UNICODE);
    $ch3 = curl_init('http://localhost:11434/v1/chat/completions');
    curl_setopt_array($ch3, [
        CURLOPT_POST => true,
        CURLOPT_HTTPHEADER => ['Content-Type: application/json'],
        CURLOPT_POSTFIELDS => $tool_payload,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 120,
    ]);
    $tool_resp = curl_exec($ch3);
    $tool_code = curl_getinfo($ch3, CURLINFO_HTTP_CODE);
    curl_close($ch3);

    $tool_ok = false;
    $tool_detail = 'No tool_calls in response';
    if ($tool_code >= 200 && $tool_code < 400) {
        $tj = json_decode($tool_resp, true);
        $choices = $tj['choices'] ?? [];
        foreach ($choices as $c) {
            $tc = $c['message']['tool_calls'] ?? [];
            foreach ($tc as $call) {
                $fn = $call['function']['name'] ?? '';
                $args = $call['function']['arguments'] ?? '';
                if (is_string($args)) $args = json_decode($args, true);
                if ($fn === 'get_weather' && is_array($args) && !empty($args['city'])) {
                    $tool_ok = true;
                    $tool_detail = 'Valid tool_call: get_weather(city="'.($args['city'] ?? '').'")';
                    break 2;
                }
                if ($fn !== '') {
                    $tool_detail = 'Tool call emitted but unexpected: '.$fn;
                }
            }
        }
    } else {
        $tool_detail = 'HTTP '.$tool_code;
    }
    $checks[] = ['name'=>'tool_call_roundtrip','pass'=>$tool_ok,'detail'=>$tool_detail];

    $all_pass = true;
    foreach ($checks as $c) if (!$c['pass']) $all_pass = false;

    echo json_encode([
        'ok'     => $all_pass,
        'model'  => $m,
        'agentic_capable' => $tool_ok,
        'checks' => $checks,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── create_variant: build a Modelfile-based variant for agentic use ──────────
if ($action === 'create_variant') {
    $base = safe_model($in['base'] ?? '');
    $name = safe_model($in['name'] ?? '');
    $num_ctx = max(2048, min(131072, (int)($in['num_ctx'] ?? 32768)));
    $temperature = max(0.0, min(2.0, (float)($in['temperature'] ?? 0.2)));
    $repeat_penalty = max(1.0, min(2.0, (float)($in['repeat_penalty'] ?? 1.15)));
    // Optional GPU-layer offload (for split GPU/CPU on low-VRAM cards, e.g. GLM-4
    // on a 4 GB GPU). 0/absent = let Ollama decide.
    $num_gpu = isset($in['num_gpu']) ? max(0, min(999, (int)$in['num_gpu'])) : null;

    if (!$base || !$name) { echo json_encode(['ok'=>false,'error'=>'Missing base or name'], JSON_UNESCAPED_UNICODE); exit; }
    if (!is_file($OLLAMA)) { echo json_encode(['ok'=>false,'error'=>'ollama not found'], JSON_UNESCAPED_UNICODE); exit; }

    $modelfile = "FROM {$base}\n";
    $modelfile .= "PARAMETER num_ctx {$num_ctx}\n";
    $modelfile .= "PARAMETER temperature {$temperature}\n";
    $modelfile .= "PARAMETER top_p 0.9\n";
    $modelfile .= "PARAMETER repeat_penalty {$repeat_penalty}\n";
    $modelfile .= "PARAMETER num_predict 4096\n";
    if ($num_gpu !== null) $modelfile .= "PARAMETER num_gpu {$num_gpu}\n";
    $modelfile .= "SYSTEM \"You are a precise coding assistant. Read files before editing. Make one change at a time. If a tool call fails, diagnose the error before retrying. Never retry the same failing call unchanged.\"\n";

    $tmp = tempnam(sys_get_temp_dir(), 'mf_');
    file_put_contents($tmp, $modelfile);

    $cmd = sprintf('%s%s create %s -f %s 2>&1',
        cockpit_timeout_cmd(120),
        escapeshellarg($OLLAMA), escapeshellarg($name), escapeshellarg($tmp));
    $output = [];
    $rc = 0;
    exec($cmd, $output, $rc);
    @unlink($tmp);

    $out_str = implode("\n", $output);
    echo json_encode([
        'ok'        => $rc === 0,
        'model'     => $name,
        'base'      => $base,
        'modelfile' => $modelfile,
        'output'    => $out_str,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ollama_config: get/set operational knobs ─────────────────────────────────
$OLLAMA_CFG = $PATHS['cockpit_data'] . '/ollama_config.json';

if ($action === 'config_get') {
    $cfg = is_file($OLLAMA_CFG) ? json_decode((string)file_get_contents($OLLAMA_CFG), true) : [];
    if (!is_array($cfg)) $cfg = [];
    $defaults = [
        'keep_alive'     => '5m',
        'num_ctx'        => 4096,
        'num_parallel'   => 1,
        'max_loaded'     => 1,
    ];
    echo json_encode(['ok'=>true, 'config'=>array_merge($defaults, $cfg)], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'config_set') {
    $cfg = is_file($OLLAMA_CFG) ? json_decode((string)file_get_contents($OLLAMA_CFG), true) : [];
    if (!is_array($cfg)) $cfg = [];
    $allow = ['keep_alive','num_ctx','num_parallel','max_loaded'];
    foreach ($allow as $k) {
        if (array_key_exists($k, $in)) {
            if ($k === 'keep_alive') {
                $cfg[$k] = preg_replace('/[^0-9smh]/', '', (string)$in[$k]) ?: '5m';
            } else {
                $cfg[$k] = max(1, (int)$in[$k]);
            }
        }
    }
    file_put_contents($OLLAMA_CFG, json_encode($cfg, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
    echo json_encode(['ok'=>true, 'config'=>$cfg], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
