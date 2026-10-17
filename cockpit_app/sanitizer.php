<?php
// =============================================================================
// sanitizer.php — Cockpit Sanitizer: book/document → snippets + knowledge
//
// INVOCATION MODES
// ─────────────────
// 1. CLI (from scheduler.php or direct terminal test):
//      php sanitizer.php --input=/path/to/book.pdf --slug=my-book --job_id=san_...
//    Exits 0 on success, 1 on failure.
//
// 2. HTTP (from UI run-now or Sanitizer panel):
//      POST sanitizer.php
//      Body: {"input_file":"/path/...", "book_slug":"auto", "job_id":"...",
//             "language":"pascal", "provider":"ollama", "model":"qwen2.5-coder:7b"}
//    Returns JSON {ok, job_id, snippets_written, knowledge_written, errors, ...}
//
// PROVIDER LADDER (local-first)
// ──────────────────────────────
//   1. Ollama qwen2.5-coder:7b   — local, code-aware, DEFAULT
//   2. Ollama qwen2.5-coder:1.5b   — local fallback (faster, lighter)
//   3. Groq   openai/gpt-oss-20b   — remote fallback (needs internet+key)
//   4. Groq   openai/gpt-oss-120b  — last resort
//   User can override preferred provider/model in the Sanitizer UI.
//
// OUTPUT
// ───────
//   cockpit_data/snippets/<snip_id>.json   — reusable code units
//   cockpit_data/knowledge/<kn_id>.json    — conceptual / prose units
//   cockpit_data/sanitizer_jobs/<id>.json  — per-run progress state
//
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);

// =============================================================================
// Paths
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'list_jobs') {
        echo json_encode(['ok'=>true,'jobs'=>[
            ['id'=>'job-1','status'=>'complete','started_at'=>'2026-06-12T10:00:00Z','finished_at'=>'2026-06-12T10:02:00Z','total'=>18,'flagged'=>2],
        ]]); exit;
    }
    ed_demo_stub();
}
$SNIPPETS_DIR  = $CD . '/snippets';
$KNOWLEDGE_DIR = $CD . '/knowledge';
$JOBS_DIR      = $CD . '/sanitizer_jobs';
$KEYS_F        = $CD . '/workers_keys.enc';

foreach ([$SNIPPETS_DIR, $KNOWLEDGE_DIR, $JOBS_DIR] as $d) {
    if (!is_dir($d)) @mkdir($d, 0775, true);
}

// Ollama base URL — standard local install
define('OLLAMA_URL', 'http://127.0.0.1:11434');

// Vision model for PDF image-based code extraction (pdftoppm → image → OCR).
// gemma3:4b fits in 4GB VRAM (3.3GB model), runs on GPU, supports vision.
// POLICY: automatic tasks never auto-load a >4B model, so there is no auto
// fallback to gemma3:12b — that only runs if the user explicitly selects it.
define('VISION_MODEL_PRIMARY',  'gemma3:4b');
define('VISION_MODEL_FALLBACK', '');   // no automatic >4B escalation

// Default provider ladder — local Ollama first, Groq remote fallback.
// NOTE: qwen2.5-coder:7b is intentionally skipped — on the RX 6500 XT
// (4GB VRAM) the 7b model overflows into CPU RAM and runs very slowly.
// qwen2.5-coder:1.5b fits entirely in VRAM and handles JSON classification
// tasks well. Groq is the remote fallback when Ollama is unavailable.
define('DEFAULT_PROVIDER_LADDER', [
    ['provider' => 'ollama', 'model' => 'qwen2.5-coder:1.5b'],    // local, fast, fits in 4GB VRAM
    ['provider' => 'groq',   'model' => 'openai/gpt-oss-20b'],       // remote fallback
    ['provider' => 'groq',   'model' => 'openai/gpt-oss-120b'],      // last resort
]);

// =============================================================================
// Dependencies
// =============================================================================
require_once __DIR__ . '/chunk_pipeline.php';

// =============================================================================
// Determine invocation mode + parse inputs
// =============================================================================
$is_http = isset($_SERVER['REQUEST_METHOD']);

if ($is_http) {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $in         = json_decode((string)file_get_contents('php://input'), true) ?: [];
    $input_file = trim((string)($in['input_file'] ?? ''));
    $book_slug  = trim((string)($in['book_slug']  ?? 'auto'));
    $job_id     = trim((string)($in['job_id']     ?? ''));
    $lang_hint  = trim((string)($in['language']   ?? ''));
    // User-preferred provider/model (optional — falls back to ladder)
    $pref_provider = trim((string)($in['provider'] ?? ''));
    $pref_model    = trim((string)($in['model']    ?? ''));
} else {
    // CLI — parse --key=value arguments
    $args = [];
    foreach (array_slice($argv ?? [], 1) as $arg) {
        if (preg_match('/^--([a-z_A-Z]+)=(.*)$/s', $arg, $m)) {
            $args[$m[1]] = $m[2];
        }
    }
    $input_file    = trim($args['input']    ?? '');
    $book_slug     = trim($args['slug']     ?? 'auto');
    $job_id        = trim($args['job_id']   ?? '');
    $lang_hint     = trim($args['language'] ?? '');
    $pref_provider = trim($args['provider'] ?? '');
    $pref_model    = trim($args['model']    ?? '');
}

// =============================================================================
// HTTP action dispatcher — handle read-only actions before input validation
// (list_jobs and list_results don't need an input file)
// =============================================================================
if ($is_http) {
    $action = $_GET['action'] ?? '';

    // C5: ping — pipeline health check. Reports which extractors are present
    // and which Ollama models are available. Lets the user verify the
    // sanitizer chain end-to-end without uploading a real document.
    if ($action === 'ping') {
        $bins = [];
        foreach (['pdftotext', 'pdfinfo', 'pdftoppm', 'pandoc', 'archmage'] as $b) {
            $which = trim((string)shell_exec('which ' . escapeshellarg($b) . ' 2>/dev/null'));
            $bins[$b] = $which ?: false;
        }
        // Probe Ollama (host/port unchanged from default)
        $ollama_ok = false;
        $models    = [];
        $ch = curl_init('http://127.0.0.1:11434/api/tags');
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 4,
        ]);
        $resp = curl_exec($ch);
        $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);
        if ($code === 200 && $resp) {
            $j = json_decode((string)$resp, true);
            if (is_array($j) && isset($j['models'])) {
                $ollama_ok = true;
                foreach ($j['models'] as $m) {
                    if (!empty($m['name'])) $models[] = $m['name'];
                }
            }
        }
        // Dirs status
        $dirs = [];
        foreach (['snippets'=>$SNIPPETS_DIR, 'knowledge'=>$KNOWLEDGE_DIR, 'jobs'=>$JOBS_DIR] as $k => $d) {
            $dirs[$k] = ['path'=>$d, 'exists'=>is_dir($d), 'writable'=>is_writable($d)];
        }
        echo json_encode([
            'ok'         => true,
            'binaries'   => $bins,
            'ollama'     => $ollama_ok,
            'models'     => $models,
            'dirs'       => $dirs,
            'note'       => 'sanitizer is ready when all binaries are present and ollama is reachable',
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($action === 'list_jobs') {
        $jobs = [];
        foreach (glob($JOBS_DIR . '/*.json') ?: [] as $f) {
            $j = json_decode((string)file_get_contents($f), true);
            if (is_array($j)) $jobs[] = $j;
        }
        usort($jobs, fn($a,$b) => strcmp($b['started_at']??'', $a['started_at']??''));
        echo json_encode(['ok' => true, 'jobs' => $jobs], JSON_UNESCAPED_UNICODE);
        exit;
    }

    if ($action === 'list_results') {
        $filter = trim((string)($_GET['filter'] ?? 'all'));
        $items  = [];
        if ($filter !== 'knowledge') {
            foreach (glob($SNIPPETS_DIR . '/*.json') ?: [] as $f) {
                $j = json_decode((string)file_get_contents($f), true);
                if (!is_array($j)) continue;
                $items[] = [
                    'kind'        => 'snippet',
                    'id'          => $j['id'] ?? '',
                    'name'        => $j['name'] ?? '',
                    'language'    => $j['language'] ?? '',
                    'purpose'     => $j['purpose'] ?? '',
                    'source_code' => $j['source_code'] ?? '',
                    'content'     => '',
                    'from_book'   => $j['from_book'] ?? '',
                    'book_slug'   => $j['book_slug'] ?? '',
                    'extracted_at'=> $j['extracted_at'] ?? '',
                ];
            }
        }
        if ($filter !== 'snippet') {
            foreach (glob($KNOWLEDGE_DIR . '/*.json') ?: [] as $f) {
                $j = json_decode((string)file_get_contents($f), true);
                if (!is_array($j)) continue;
                $items[] = [
                    'kind'        => 'knowledge',
                    'id'          => $j['id'] ?? '',
                    'name'        => $j['name'] ?? '',
                    'language'    => $j['language'] ?? '',
                    'purpose'     => $j['purpose'] ?? '',
                    'source_code' => '',
                    'content'     => $j['content'] ?? '',
                    'from_book'   => $j['from_book'] ?? '',
                    'book_slug'   => $j['book_slug'] ?? '',
                    'extracted_at'=> $j['extracted_at'] ?? '',
                ];
            }
        }
        usort($items, fn($a,$b) => strcmp($b['extracted_at']??'', $a['extracted_at']??''));
        echo json_encode(['ok' => true, 'items' => $items, 'count' => count($items)], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

// =============================================================================
// Validate inputs (only needed for pipeline runs)
// =============================================================================
if (!$input_file) {
    _san_exit('Missing input_file / --input', $is_http);
}
if (!is_file($input_file)) {
    _san_exit('Input file not found: ' . $input_file, $is_http);
}

// Auto-generate job_id if not provided
if (!$job_id) {
    $job_id = 'san_' . date('Y-m-d_H-i') . '_' . substr(bin2hex(random_bytes(4)), 0, 6);
}

// Sanitize book_slug
if ($book_slug === 'auto') {
    $book_slug = _san_slug(pathinfo($input_file, PATHINFO_FILENAME));
}
$book_slug = _san_slug($book_slug);

// =============================================================================
// Build provider ladder for this run
// =============================================================================
// If user specified a preferred provider+model, put it first in the ladder,
// then fall through to the rest of the defaults.
$ladder = DEFAULT_PROVIDER_LADDER;
if ($pref_provider && $pref_model) {
    // Remove any existing entry matching the preference to avoid duplicate
    $ladder = array_values(array_filter($ladder, function($e) use ($pref_provider, $pref_model) {
        return !($e['provider'] === $pref_provider && $e['model'] === $pref_model);
    }));
    // Prepend user preference
    array_unshift($ladder, ['provider' => $pref_provider, 'model' => $pref_model]);
}

// =============================================================================
// Build provider ladder for this run
// =============================================================================
$result = sanitize_file(
    $input_file, $book_slug, $job_id, $lang_hint,
    $ladder, $CD, $SNIPPETS_DIR, $KNOWLEDGE_DIR, $JOBS_DIR, $KEYS_F
);

if ($is_http) {
    echo json_encode($result, JSON_UNESCAPED_UNICODE);
} else {
    if ($result['ok']) {
        $e = count($result['errors'] ?? []);
        echo "[sanitizer] Done. Snippets: {$result['snippets_written']}, Knowledge: {$result['knowledge_written']}, Skipped: {$result['skipped_chunks']}, Errors: {$e}\n";
        exit(0);
    } else {
        echo "[sanitizer] FAILED: " . ($result['error'] ?? 'unknown') . "\n";
        exit(1);
    }
}

// =============================================================================
// MAIN PIPELINE
// =============================================================================
function sanitize_file(
    string $input_file,
    string $book_slug,
    string $job_id,
    string $lang_hint,
    array  $ladder,
    string $CD,
    string $SNIPPETS_DIR,
    string $KNOWLEDGE_DIR,
    string $JOBS_DIR,
    string $KEYS_F
): array {

    $started_at = date('c');

    // Load Groq key (needed only if Groq appears in ladder and Ollama fails)
    $groq_key = _san_load_groq_key($KEYS_F);

    // Initialise job state file
    _san_job_save($JOBS_DIR, $job_id, [
        'job_id'       => $job_id,
        'input_file'   => $input_file,
        'input_format' => strtolower(pathinfo($input_file, PATHINFO_EXTENSION)),
        'book_slug'    => $book_slug,
        'started_at'   => $started_at,
        'updated_at'   => $started_at,
        'completed_at' => null,
        'status'       => 'running',
        'phase'        => 'extracting',
        'book_title'   => '',
        'provider_used'=> '',
        'progress'     => [
            'total_chunks'        => 0,
            'processed_chunks'    => 0,
            'snippets_extracted'  => 0,
            'knowledge_extracted' => 0,
            'skipped_chunks'      => 0,
            'errors'              => [],
        ],
    ]);

    // ── Step 1: Extract + chunk ──────────────────────────────────────────────
    $pipeline = chunk_pipeline($input_file, $lang_hint);

    if ($pipeline['error'] !== null) {
        _san_job_update($JOBS_DIR, $job_id, [
            'status' => 'failed', 'phase' => 'extracting',
            'error'  => $pipeline['error'], 'completed_at' => date('c'),
        ]);
        return ['ok' => false, 'error' => $pipeline['error'], 'job_id' => $job_id];
    }

    $chunks     = $pipeline['chunks'];
    $book_title = $pipeline['book_title'] ?: $book_slug;
    $total      = count($chunks);

    _san_job_update($JOBS_DIR, $job_id, [
        'phase'      => 'classifying',
        'book_title' => $book_title,
        'progress'   => [
            'total_chunks'        => $total,
            'processed_chunks'    => 0,
            'snippets_extracted'  => 0,
            'knowledge_extracted' => 0,
            'skipped_chunks'      => 0,
            'errors'              => [],
        ],
    ]);

    if ($total === 0) {
        _san_job_update($JOBS_DIR, $job_id, [
            'status' => 'done', 'phase' => 'done', 'completed_at' => date('c'),
        ]);
        return [
            'ok' => true, 'job_id' => $job_id,
            'snippets_written' => 0, 'knowledge_written' => 0,
            'skipped_chunks' => 0, 'errors' => [],
            'note' => 'No chunks extracted — PDF may be image-only or empty',
        ];
    }

    // ── Step 2: Classify each chunk ──────────────────────────────────────────
    $snippets_written  = 0;
    $knowledge_written = 0;
    $skipped           = 0;
    $errors            = [];
    $provider_used     = '';

    foreach ($chunks as $idx => $chunk) {
        $chunk_text = $chunk['text']    ?? '';
        $section    = $chunk['section'] ?? '';

        $prompt = _san_build_prompt($chunk_text, $book_title, $lang_hint ?: 'unknown');

        // Try provider ladder
        $llm = _san_call_ladder($ladder, $prompt, $groq_key);

        if (!$llm['ok']) {
            $err = "Chunk {$idx}: all providers failed — " . ($llm['error'] ?? 'unknown');
            $errors[] = $err;
            $skipped++;
            _san_job_update($JOBS_DIR, $job_id, [
                'progress' => [
                    'processed_chunks'    => $idx + 1,
                    'skipped_chunks'      => $skipped,
                    'errors'              => $errors,
                    // preserve existing counts
                    'total_chunks'        => $total,
                    'snippets_extracted'  => $snippets_written,
                    'knowledge_extracted' => $knowledge_written,
                ],
            ]);
            continue;
        }

        // Record which provider actually worked (first successful one)
        if (!$provider_used && !empty($llm['provider_used'])) {
            $provider_used = $llm['provider_used'];
            _san_job_update($JOBS_DIR, $job_id, ['provider_used' => $provider_used]);
        }

        // Parse LLM response — retry once with stricter prompt on failure
        $units = _san_parse_response($llm['output']);
        if ($units === null) {
            $strict_prompt = _san_build_prompt($chunk_text, $book_title,
                                               $lang_hint ?: 'unknown', true);
            $retry = _san_call_ladder($ladder, $strict_prompt, $groq_key);
            if ($retry['ok']) {
                $units = _san_parse_response($retry['output']);
            }
        }

        if ($units === null) {
            $errors[] = "Chunk {$idx}: unparseable LLM response after retry — skipped";
            $skipped++;
            _san_job_update($JOBS_DIR, $job_id, [
                'progress' => [
                    'total_chunks'        => $total,
                    'processed_chunks'    => $idx + 1,
                    'snippets_extracted'  => $snippets_written,
                    'knowledge_extracted' => $knowledge_written,
                    'skipped_chunks'      => $skipped,
                    'errors'              => $errors,
                ],
            ]);
            continue;
        }

        // Write extracted units
        foreach ($units as $unit_idx => $unit) {
            $kind = $unit['kind'] ?? '';
            if ($kind === 'snippet') {
                if (_san_write_snippet($unit, $book_title, $book_slug, $section,
                                       $idx, $unit_idx, $lang_hint, $SNIPPETS_DIR)) {
                    $snippets_written++;
                }
            } elseif ($kind === 'knowledge') {
                if (_san_write_knowledge($unit, $book_title, $book_slug, $section,
                                         $KNOWLEDGE_DIR)) {
                    $knowledge_written++;
                }
            }
            // Unknown kind → skip silently
        }

        // Update progress after each processed chunk
        _san_job_update($JOBS_DIR, $job_id, [
            'progress' => [
                'total_chunks'        => $total,
                'processed_chunks'    => $idx + 1,
                'snippets_extracted'  => $snippets_written,
                'knowledge_extracted' => $knowledge_written,
                'skipped_chunks'      => $skipped,
                'errors'              => $errors,
            ],
        ]);
    }

    // Surface the silent-zero case: chunks processed but nothing extracted is
    // almost always a too-weak model (e.g. a 3B returns []). Don't fail quietly.
    $note = null;
    if ($total > 0 && ($snippets_written + $knowledge_written) === 0) {
        $note = '0 units extracted from ' . $total . ' chunk(s). The model "' . $provider_used .
                '" may be too weak for classification — try qwen2.5-coder:7b (the default).';
    }

    // ── Done ─────────────────────────────────────────────────────────────────
    _san_job_update($JOBS_DIR, $job_id, [
        'status'       => 'done',
        'phase'        => 'done',
        'completed_at' => date('c'),
        'updated_at'   => date('c'),
        'note'         => $note,
    ]);

    return [
        'ok'               => true,
        'job_id'           => $job_id,
        'book_title'       => $book_title,
        'book_slug'        => $book_slug,
        'total_chunks'     => $total,
        'snippets_written' => $snippets_written,
        'knowledge_written'=> $knowledge_written,
        'skipped_chunks'   => $skipped,
        'errors'           => $errors,
        'provider_used'    => $provider_used,
        'note'             => $note,
    ];
}

// =============================================================================
// LLM INVOCATION
// =============================================================================

// Try each provider in the ladder until one succeeds.
// Returns ['ok'=>bool, 'output'=>string, 'provider_used'=>string, 'error'=>string]
function _san_call_ladder(array $ladder, string $prompt, string $groq_key): array {
    $last_error = 'No providers in ladder';
    foreach ($ladder as $entry) {
        $provider = $entry['provider'] ?? '';
        $model    = $entry['model']    ?? '';

        if ($provider === 'ollama') {
            $r = _san_call_ollama($model, $prompt);
        } elseif ($provider === 'groq') {
            if (!$groq_key) {
                $last_error = 'Groq skipped — no API key configured';
                continue;
            }
            $r = _san_call_groq($model, $prompt, $groq_key);
        } else {
            $last_error = "Unknown provider: {$provider}";
            continue;
        }

        if ($r['ok']) {
            $r['provider_used'] = "{$provider}:{$model}";
            return $r;
        }
        $last_error = "[{$provider}:{$model}] " . ($r['error'] ?? 'failed');
        // Small pause between attempts to avoid hammering
        usleep(300000);   // 300ms
    }
    return ['ok' => false, 'error' => $last_error];
}

// Call local Ollama via its REST API
function _san_call_ollama(string $model, string $prompt): array {
    $payload = [
        'model'  => $model,
        'prompt' => $prompt,
        'stream' => false,
        'options'=> [
            'temperature' => 0.1,    // low temp for consistent JSON
            'num_predict' => 4096,
            'num_ctx'     => 8192,   // force larger context window
        ],
    ];

    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => OLLAMA_URL . '/api/generate',
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode($payload, JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 300,   // local models can be slow on big chunks
        CURLOPT_HEADER         => false,
    ]);
    $body = curl_exec($ch);
    $err  = curl_error($ch);
    $http = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($body === false) {
        return ['ok' => false, 'error' => 'Ollama curl error: ' . $err];
    }
    if ($http >= 400) {
        return ['ok' => false, 'error' => "Ollama HTTP {$http}"];
    }

    $j = json_decode($body, true);
    if (!is_array($j)) {
        return ['ok' => false, 'error' => 'Ollama bad JSON response'];
    }
    if (!empty($j['error'])) {
        return ['ok' => false, 'error' => 'Ollama: ' . $j['error']];
    }

    $text = $j['response'] ?? '';
    if (trim($text) === '') {
        return ['ok' => false, 'error' => 'Ollama returned empty response'];
    }

    return ['ok' => true, 'output' => $text];
}

// Call Groq cloud API
function _san_call_groq(string $model, string $prompt, string $api_key): array {
    $payload = [
        'model'       => $model,
        'messages'    => [['role' => 'user', 'content' => $prompt]],
        'max_tokens'  => 4000,
        'temperature' => 0.1,
    ];

    $ch = curl_init();
    curl_setopt_array($ch, [
        CURLOPT_URL            => 'https://api.groq.com/openai/v1/chat/completions',
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode($payload, JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER     => [
            'Authorization: Bearer ' . $api_key,
            'Content-Type: application/json',
        ],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 90,
        CURLOPT_HEADER         => false,
    ]);
    $body = curl_exec($ch);
    $err  = curl_error($ch);
    $http = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);

    if ($body === false) {
        return ['ok' => false, 'error' => 'Groq curl error: ' . $err];
    }
    if ($http >= 400) {
        $j = json_decode($body, true);
        $msg = is_array($j) ? ($j['error']['message'] ?? '') : '';
        return ['ok' => false, 'error' => "Groq HTTP {$http}" . ($msg ? ": {$msg}" : '')];
    }

    $j = json_decode($body, true);
    if (!is_array($j)) {
        return ['ok' => false, 'error' => 'Groq bad JSON response'];
    }
    if (isset($j['error'])) {
        return ['ok' => false, 'error' => 'Groq: ' . ($j['error']['message'] ?? 'unknown')];
    }

    $text = $j['choices'][0]['message']['content'] ?? '';
    if (trim($text) === '') {
        return ['ok' => false, 'error' => 'Groq returned empty response'];
    }

    return ['ok' => true, 'output' => $text];
}

// =============================================================================
// PROMPT BUILDER
// =============================================================================
function _san_build_prompt(string $chunk, string $book_title,
                           string $lang_hint, bool $strict = false): string {
    $strictness = $strict
        ? "\nCRITICAL: Your response must start with [ and end with ]. No other text whatsoever."
        : '';

    return <<<PROMPT
You are extracting reusable knowledge from a programming book.

The chunk below is from "{$book_title}".
Language hint: {$lang_hint}

Identify each EXTRACTION UNIT in this chunk. Classify each as either:

  "snippet" — ready-to-use code: a block, function, procedure, class, or method
              that could be reused as-is. Must have a clear language.

  "knowledge" — informational content WITHOUT a complete code implementation:
                techniques, how-tos, principles, design discussions, caveats.

For each unit, emit a JSON object.

For snippets:
{
  "kind": "snippet",
  "name": "<short descriptive name, ~5 words, or null if unnamed>",
  "language": "<language, lowercase>",
  "source_code": "<the code, verbatim>",
  "purpose": "<one-sentence purpose>",
  "arguments": [{"name":"...", "type":"...", "description":"..."}],
  "short_description": "<optional one-sentence description>"
}

For knowledge:
{
  "kind": "knowledge",
  "name": "<short descriptive name, ~5 words>",
  "purpose": "<one-sentence purpose>",
  "language": "<language if applicable, else null>",
  "content": "<the prose, markdown-formatted>",
  "parameters": [{"name":"...", "value":"..."}]
}

Return ONLY a JSON array. No prose. No explanation. No markdown fences.
If no units found, return [].{$strictness}

CHUNK:
---
{$chunk}
---
PROMPT;
}

// =============================================================================
// RESPONSE PARSER
// =============================================================================
// Attempt to extract a JSON array from LLM output.
// LLMs sometimes wrap their response in ```json fences or add prose —
// we strip common patterns before parsing.
// Returns array of unit objects, or null if unparseable.
function _san_parse_response(string $text): ?array {
    $text = trim($text);

    // Strip markdown code fences (```json ... ``` or ``` ... ```)
    $text = preg_replace('/^```(?:json)?\s*/i', '', $text);
    $text = preg_replace('/\s*```\s*$/i', '', $text);
    $text = trim($text);

    // If the text doesn't start with [ find the first [ and extract from there
    $bracket_pos = strpos($text, '[');
    if ($bracket_pos === false) {
        return null;   // no JSON array found at all
    }
    if ($bracket_pos > 0) {
        $text = substr($text, $bracket_pos);
    }

    // Find matching closing ] — handles nested brackets
    $depth  = 0;
    $end    = -1;
    $in_str = false;
    $escape = false;
    for ($i = 0, $n = strlen($text); $i < $n; $i++) {
        $c = $text[$i];
        if ($escape)            { $escape = false; continue; }
        if ($c === '\\')        { $escape = true;  continue; }
        if ($c === '"')         { $in_str = !$in_str; continue; }
        if ($in_str)            { continue; }
        if ($c === '[')         { $depth++; }
        elseif ($c === ']')     { $depth--; if ($depth === 0) { $end = $i; break; } }
    }

    if ($end === -1) {
        // No balanced closing bracket — try parsing as-is anyway
        $json_str = $text;
    } else {
        $json_str = substr($text, 0, $end + 1);
    }

    $parsed = json_decode($json_str, true);
    if (!is_array($parsed)) return null;

    // Validate: each element must be an array (object) with a 'kind' key
    $valid = [];
    foreach ($parsed as $item) {
        if (!is_array($item)) continue;
        $kind = $item['kind'] ?? '';
        if (!in_array($kind, ['snippet', 'knowledge'], true)) continue;
        $valid[] = $item;
    }

    return $valid;   // may be empty array — that's fine (chunk had nothing useful)
}

// =============================================================================
// WRITEBACK — snippets
// =============================================================================
function _san_write_snippet(
    array  $unit,
    string $book_title,
    string $book_slug,
    string $section,
    int    $chunk_idx,
    int    $unit_idx,
    string $lang_hint,
    string $SNIPPETS_DIR
): bool {
    $source_code = trim((string)($unit['source_code'] ?? ''));
    if ($source_code === '') return false;   // no code = not a real snippet

    $id   = 'snip_' . date('Y-m-d') . '_' . substr(bin2hex(random_bytes(5)), 0, 8);
    $name = trim((string)($unit['name'] ?? ''));

    // Placeholder name if unnamed
    if ($name === '' || strtolower($name) === 'null') {
        $name = "Untitled snippet from {$book_slug} §{$chunk_idx}";
    }

    // Language: LLM answer → lang_hint fallback → 'unknown'
    $language = strtolower(trim((string)($unit['language'] ?? '')));
    if ($language === '' || $language === 'null') {
        $language = $lang_hint ?: 'unknown';
    }

    $snippet = [
        'id'                => $id,
        'name'              => $name,
        'language'          => $language,
        'source_code'       => $source_code,
        'purpose'           => trim((string)($unit['purpose'] ?? '')),
        'arguments'         => is_array($unit['arguments'] ?? null) ? $unit['arguments'] : [],
        'short_description' => trim((string)($unit['short_description'] ?? '')),
        'from_book'         => $book_title,
        'from_section'      => $section,
        'book_slug'         => $book_slug,
        'unnamed'           => (trim((string)($unit['name'] ?? '')) === ''
                                || strtolower(trim((string)($unit['name'] ?? ''))) === 'null'),
        'extracted_at'      => date('c'),
    ];

    $path = $SNIPPETS_DIR . '/' . $id . '.json';
    return _san_save_json($path, $snippet);
}

// =============================================================================
// WRITEBACK — knowledge
// =============================================================================
function _san_write_knowledge(
    array  $unit,
    string $book_title,
    string $book_slug,
    string $section,
    string $KNOWLEDGE_DIR
): bool {
    $content = trim((string)($unit['content'] ?? ''));
    if ($content === '') return false;   // empty content = nothing to store

    $name = trim((string)($unit['name'] ?? ''));
    if ($name === '') $name = "Knowledge from {$book_slug}";

    $id = 'kn_' . date('Y-m-d') . '_' . substr(bin2hex(random_bytes(5)), 0, 8);

    $knowledge = [
        'id'           => $id,
        'name'         => $name,
        'purpose'      => trim((string)($unit['purpose'] ?? '')),
        'language'     => trim((string)($unit['language'] ?? '')) ?: null,
        'parameters'   => is_array($unit['parameters'] ?? null) ? $unit['parameters'] : [],
        'content'      => $content,
        'from_book'    => $book_title,
        'from_section' => $section,
        'book_slug'    => $book_slug,
        'extracted_at' => date('c'),
    ];

    $path = $KNOWLEDGE_DIR . '/' . $id . '.json';
    return _san_save_json($path, $knowledge);
}

// =============================================================================
// JOB STATE
// =============================================================================

// Write (overwrite) a full job state file
function _san_job_save(string $JOBS_DIR, string $job_id, array $state): void {
    $path = $JOBS_DIR . '/' . $job_id . '.json';
    _san_save_json($path, $state);
    @chmod($path, 0664);
}

// Merge partial updates into an existing job state file
function _san_job_update(string $JOBS_DIR, string $job_id, array $updates): void {
    $path  = $JOBS_DIR . '/' . $job_id . '.json';
    $state = [];
    if (is_file($path)) {
        $j = json_decode((string)file_get_contents($path), true);
        if (is_array($j)) $state = $j;
    }
    // Deep-merge 'progress' sub-key if present
    if (isset($updates['progress']) && isset($state['progress'])) {
        $state['progress'] = array_merge($state['progress'], $updates['progress']);
        unset($updates['progress']);
    }
    $state = array_merge($state, $updates);
    $state['updated_at'] = date('c');
    _san_save_json($path, $state);
    @chmod($path, 0664);
}

// =============================================================================
// HELPERS
// =============================================================================

function _san_save_json(string $path, array $data): bool {
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) {
        return false;
    }
    return rename($tmp, $path);
}

// Load Groq API key from workers_keys.enc
// Uses the same AES-256-GCM scheme as workers.php
function _san_load_groq_key(string $keys_f): string {
    if (!is_file($keys_f)) return '';

    // Derive same master key as workers.php
    $machine_id_path = '/etc/machine-id';
    $machine_id      = is_readable($machine_id_path)
        ? trim((string)file_get_contents($machine_id_path))
        : 'cockpit-default-machine';
    $salt       = 'AICockpit-WorkerKeys-v1-DarioRuggi';
    $master_key = hash('sha256', $machine_id . $salt, true);

    $b64 = trim((string)file_get_contents($keys_f));
    if ($b64 === '') return '';
    $raw = base64_decode($b64, true);
    if ($raw === false || strlen($raw) < 28) return '';
    $iv  = substr($raw, 0, 12);
    $tag = substr($raw, 12, 16);
    $ct  = substr($raw, 28);
    $pt  = openssl_decrypt($ct, 'aes-256-gcm', $master_key, OPENSSL_RAW_DATA, $iv, $tag);
    if ($pt === false) return '';

    $keys = json_decode($pt, true);
    return is_array($keys) ? (string)($keys['groq'] ?? '') : '';
}

// Convert a string to a safe slug (lowercase, hyphens, no special chars)
function _san_slug(string $s): string {
    $s = strtolower($s);
    $s = preg_replace('/[^a-z0-9]+/', '-', $s);
    $s = trim($s, '-');
    return $s ?: 'book';
}

// Exit with error in the appropriate mode
function _san_exit(string $msg, bool $is_http): void {
    if ($is_http) {
        echo json_encode(['ok' => false, 'error' => $msg], JSON_UNESCAPED_UNICODE);
    } else {
        echo "[sanitizer] ERROR: {$msg}\n";
    }
    exit(1);
}
