<?php
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// tools.php — Cockpit Tools (local binaries) backend
//
// Runs local CLI binaries as a 5th provider class alongside Claude / Gemini /
// Ollama / Workers. Tools are deterministic file→file transformations:
// ffmpeg converts media, whisper transcribes audio, pandoc converts documents.
// No internet, no API keys, no usage tracking.
//
// Storage:
//   <CD>/tools/<id>.json          — tool definition (binary + presets)
//   <CD>/tools_state.json         — per-tool: enabled, binary override path,
//                                   output_dir override, last_detected_at
//   <CD>/tools_outputs/           — default output root if user doesn't set one
//
// Per-project overrides:
//   <project>/tools.json          — overrides for this project
//
// Endpoints:
//   GET  ?action=tools                  — list tool definitions + state
//   GET  ?action=presets                — flat list of <tool>:<preset> pairs
//   POST ?action=set_state              — toggle enabled / set bin / set outdir
//   POST ?action=detect                 — re-run binary auto-detection
//   POST ?action=run                    — execute a preset on an input path
//   POST ?action=set_auto_route         — toggle auto-route per project
//   POST ?action=add_custom             — register a user-created tool
//   POST ?action=delete                 — remove a user tool
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
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'tools') {
        echo json_encode(['ok'=>true,'tools'=>[
            ['id'=>'ffmpeg','name'=>'ffmpeg','binary'=>'ffmpeg','binary_available'=>true,'binary_resolved'=>'/usr/bin/ffmpeg','enabled'=>true,'custom'=>false,'presets'=>[
                ['id'=>'to_mp4','label'=>'Convert to MP4','output_kind'=>'video','output_ext'=>'mp4','command'=>'ffmpeg -i {input} {output}.mp4'],
                ['id'=>'extract_audio','label'=>'Extract audio','output_kind'=>'audio','output_ext'=>'mp3','command'=>'ffmpeg -i {input} -q:a 0 -map a {output}.mp3'],
            ]],
            ['id'=>'pandoc','name'=>'pandoc','binary'=>'pandoc','binary_available'=>true,'binary_resolved'=>'/usr/bin/pandoc','enabled'=>true,'custom'=>false,'presets'=>[
                ['id'=>'to_pdf','label'=>'Convert to PDF','output_kind'=>'document','output_ext'=>'pdf','command'=>'pandoc {input} -o {output}.pdf'],
                ['id'=>'to_docx','label'=>'Convert to DOCX','output_kind'=>'document','output_ext'=>'docx','command'=>'pandoc {input} -o {output}.docx'],
            ]],
        ],'auto_route_projects'=>[]]); exit;
    }
    if ($__demoAction === 'presets') {
        echo json_encode(['ok'=>true,'presets'=>['ffmpeg:to_mp4','ffmpeg:extract_audio','pandoc:to_pdf','pandoc:to_docx']]); exit;
    }
    ed_demo_stub();
}
// $CD and $PATHS already set by paths.php
$TOOLS_DIR     = $CD . '/tools';                    // user-facing definitions
$STATE_F       = $CD . '/tools_state.json';
$OUTPUTS_DIR   = $CD . '/tools_outputs';            // default output root
$JOBS_DIR      = $CD . '/tools_jobs';               // async run records (job.json/.log/.rc)
$BUILTINS_SHIP = __DIR__ . '/tools_builtins';       // shipped definitions

if (!is_dir($CD))           @mkdir($CD,         0775, true);
if (!is_dir($TOOLS_DIR))    @mkdir($TOOLS_DIR,  0775, true);
if (!is_dir($OUTPUTS_DIR))  @mkdir($OUTPUTS_DIR, 0775, true);

// =============================================================================
// Migration v2 — Tools Staleness Fix (2026-05-12)
//
// OLD behaviour: shipped built-in JSONs were copied to cockpit_data/tools/ on
// first run; the user-side copy then silently shadowed any future shipped
// updates. This caused bugs like ffmpeg's version_args fix being invisible.
//
// NEW behaviour: shipped JSONs in tools_builtins/ are the sole source of
// truth for built-in tools. User customisations (presets, binary overrides)
// live in tools_state.json. Custom (user-created) tools still get their own
// JSON in cockpit_data/tools/. The migration script below detects and converts
// old-style user-side copies on the first cockpit load after upgrade.
//
// The old "seed on first run" block is REMOVED — we no longer copy shipped
// JSONs to the user directory. load_tools() below reads shipped + state
// directly.
// =============================================================================
require_once __DIR__ . '/tools_lib.php';
require_once __DIR__ . '/migrate_v2.php';
$_mig = migrate_v2_run($CD, $TOOLS_DIR, $BUILTINS_SHIP, __DIR__ . '/workers_providers.json');
// $_mig['notify'] is true when a banner should be shown; index.html polls
// ?action=migration_status (below) to pick it up without blocking this request.

// =============================================================================
// Helpers
// =============================================================================

function safe_id($s)        { return preg_match('/^[a-z][a-z0-9_-]{0,63}$/', (string)$s) ? $s : null; }
function safe_preset($s)    { return preg_match('/^[a-z0-9][a-z0-9_-]{0,63}$/', (string)$s) ? $s : null; }
// Project / chat names: any script (Hebrew project folders exist), digits, _ . - and
// spaces; no path separators, no .., no leading dot. Was ASCII-only, which silently
// skipped recording tool runs in non-Latin projects (2026-09-13).
function safe_project($s)   { return preg_match('/^(?!.*\\.\\.)(?![.])[\\p{L}\\p{N}_][\\p{L}\\p{N}\\p{M}_. -]{0,127}$/u', (string)$s) ? $s : null; }
function safe_chat($s)      { return preg_match('/^(?!.*\\.\\.)(?![.])[\\p{L}\\p{N}_][\\p{L}\\p{N}\\p{M}_. -]{0,127}$/u', (string)$s) ? $s : null; }

function load_json_file($p, $d=[]) {
    if (!is_file($p)) return $d;
    $raw = (string)file_get_contents($p);
    $j = json_decode($raw, true);
    if (!is_array($j)) {
        // HIGH-56: surface malformed JSON instead of silently dropping it.
        // The caller can decide whether to warn or fail; default behaviour is
        // unchanged (return default) but we log to error_log for diagnostics.
        @error_log('[tools.php] Malformed JSON in ' . $p . ': ' . json_last_error_msg());
        return $d;
    }
    return $j;
}
function save_json_file($p, $data) {
    $tmp = $p . '.tmp';
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) return false;
    @chmod($tmp, 0664);
    if (!@rename($tmp, $p)) { @unlink($tmp); return false; }
    return true;
}

// load_tools() — Returns the complete set of tool definitions.
//
// Built-in tools: read from BUILTINS_SHIP (source of truth).
//   User-added presets for a built-in are merged in from tools_state.json
//   (key: tools.<id>.user_presets). No user-side JSON copy is used for
//   built-ins; after migration there should be none.
//
// Custom tools (custom:true): read from TOOLS_DIR/<id>.json (user-defined).
//   These never live in BUILTINS_SHIP; they're wholly owned by the user.
//
// If a stale non-custom user-side copy still exists (migration not yet run,
// or migration skipped due to lock), it is silently ignored for built-ins.
function load_tools($TOOLS_DIR, $BUILTINS_SHIP = null, $STATE_F = null) {
    $out = [];

    // --- 1. Load all built-in tools from shipped directory ---
    if ($BUILTINS_SHIP && is_dir($BUILTINS_SHIP)) {
        // Load state once for the whole batch (user_presets overlay)
        $state = ($STATE_F && is_file($STATE_F))
            ? (json_decode((string)file_get_contents($STATE_F), true) ?: [])
            : [];

        foreach (glob($BUILTINS_SHIP . '/*.json') ?: [] as $f) {
            $def = load_json_file($f);
            if (!is_array($def) || empty($def['id'])) continue;
            $tid = $def['id'];

            // Merge user-added presets from state
            $user_presets = $state['tools'][$tid]['user_presets'] ?? [];
            if ($user_presets && is_array($user_presets)) {
                // Append after shipped presets; never overwrite shipped ones
                $def['presets'] = array_merge($def['presets'] ?? [], $user_presets);
            }
            $out[$tid] = $def;
        }
    }

    // --- 2. Load custom (user-created) tools from user dir ---
    // Any file in TOOLS_DIR with custom:true is a user-added tool.
    // Files without custom:true in TOOLS_DIR are stale built-in copies
    // (migration should have removed them); skip them here.
    foreach (glob($TOOLS_DIR . '/*.json') ?: [] as $f) {
        $def = load_json_file($f);
        if (!is_array($def) || empty($def['id'])) continue;
        if (empty($def['custom'])) continue;   // skip stale built-in copies
        $tid = $def['id'];
        $out[$tid] = $def;   // custom tool overrides nothing (unique ids)
    }

    ksort($out);
    return $out;
}


// Output path resolver. Order:
//   1. preset output_dir override (rare)
//   2. tool state output_dir override
//   3. project_dir if specified (for per-chat output)
//   4. default OUTPUTS_DIR/<tool>/<timestamp>/
function resolve_output_path($tool, $preset, $state, $input, $project_dir, $OUTPUTS_DIR) {
    $tid = $tool['id'];
    $base_name = pathinfo($input, PATHINFO_FILENAME);

    // Determine output directory
    $out_dir = null;
    if (!empty($preset['output_dir'])) {
        $out_dir = $preset['output_dir'];
    } elseif (!empty($state['tools'][$tid]['output_dir'])) {
        $out_dir = $state['tools'][$tid]['output_dir'];
    } elseif ($project_dir && is_dir($project_dir)) {
        $out_dir = $project_dir;
    } else {
        $out_dir = $OUTPUTS_DIR . '/' . $tid . '/' . date('Ymd_His');
    }

    if (!is_dir($out_dir)) @mkdir($out_dir, 0775, true);

    // Build output filename
    $ext       = $preset['output_ext'] ?? 'out';
    $stem      = $preset['output_stem'] ?? '{NAME}';
    $stem      = str_replace('{NAME}', $base_name, $stem);
    $stem      = str_replace('{TS}', date('Ymd_His'), $stem);
    $stem      = preg_replace('/[^A-Za-z0-9._\-]/', '_', $stem);

    $candidate = $out_dir . '/' . $stem . '.' . $ext;
    // If exists, suffix _2, _3, ...
    $i = 2;
    while (file_exists($candidate)) {
        $candidate = $out_dir . '/' . $stem . '_' . $i . '.' . $ext;
        $i++;
        if ($i > 999) break;
    }
    return $candidate;
}

// =============================================================================
// Action dispatcher
// =============================================================================

$action = $_GET['action'] ?? '';
$in     = json_decode(file_get_contents('php://input'), true) ?: [];

// =============================================================================
// Action: tools — list tool definitions + state (binary detected, etc.)
// =============================================================================
if ($action === 'tools') {
    // Pass BUILTINS_SHIP + STATE_F so load_tools can merge shipped + user_presets
    $tools = load_tools($TOOLS_DIR, $BUILTINS_SHIP, $STATE_F);
    $state = load_json_file($STATE_F, ['tools'=>[], 'auto_route_projects'=>[]]);
    $out   = [];
    foreach ($tools as $tid => $t) {
        $bin   = resolve_binary($t, $state);
        $st    = $state['tools'][$tid] ?? [];
        $enabled = isset($st['enabled']) ? (bool)$st['enabled'] : (bool)$bin;   // auto-enable if detected
        $out[] = array_merge($t, [
            'binary_resolved'  => $bin,
            'binary_available' => (bool)$bin,
            'enabled'          => $enabled,
            'binary_override'  => $st['binary_override'] ?? null,
            'output_dir'       => $st['output_dir']      ?? null,
        ]);
    }
    echo json_encode([
        'ok'                  => true,
        'tools'               => $out,
        'auto_route_projects' => $state['auto_route_projects'] ?? [],
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: presets — flat list for the topbar dropdown
// =============================================================================
if ($action === 'presets') {
    $tools = load_tools($TOOLS_DIR, $BUILTINS_SHIP, $STATE_F);
    $state = load_json_file($STATE_F, ['tools'=>[]]);
    $out   = [];
    foreach ($tools as $tid => $t) {
        $bin = resolve_binary($t, $state);
        $st  = $state['tools'][$tid] ?? [];
        $enabled = isset($st['enabled']) ? (bool)$st['enabled'] : (bool)$bin;
        if (!$enabled || !$bin) continue;
        foreach (($t['presets'] ?? []) as $p) {
            $out[] = [
                'value'         => $tid . ':' . $p['id'],
                'label'         => ($t['name'] ?? $tid) . ' · ' . ($p['label'] ?? $p['id']),
                'tool'          => $tid,
                'preset'        => $p['id'],
                'description'   => $p['description'] ?? '',
                'input_kinds'   => $p['input_kinds']  ?? [],
                'output_kind'   => $p['output_kind']  ?? '',
                'output_ext'    => $p['output_ext']   ?? '',
                'optional_input'=> ($p['optional_input'] ?? false) === true ? true : ((is_string($p['optional_input'] ?? null) && $p['optional_input'] !== '') ? $p['optional_input'] : false),
            ];
        }
    }
    echo json_encode(['ok'=>true, 'presets'=>$out], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: set_state — toggle enabled, override binary path or output dir
// =============================================================================
if ($action === 'set_state') {
    $tid = safe_id($in['tool'] ?? '');
    if (!$tid) { echo json_encode(['ok'=>false,'error'=>'Missing tool'], JSON_UNESCAPED_UNICODE); exit; }
    $state = load_json_file($STATE_F, ['tools'=>[]]);
    if (!isset($state['tools'][$tid])) $state['tools'][$tid] = [];
    if (isset($in['enabled']))         $state['tools'][$tid]['enabled']         = (bool)$in['enabled'];
    if (array_key_exists('binary_override', $in)) {
        $bo = trim((string)$in['binary_override']);
        $state['tools'][$tid]['binary_override'] = ($bo === '') ? null : $bo;
    }
    if (array_key_exists('output_dir', $in)) {
        $od = trim((string)$in['output_dir']);
        $state['tools'][$tid]['output_dir'] = ($od === '') ? null : $od;
    }
    save_json_file($STATE_F, $state);
    echo json_encode(['ok'=>true,'state'=>$state['tools'][$tid]], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: detect — re-run binary detection for all tools (or one)
// =============================================================================
if ($action === 'detect') {
    $tools = load_tools($TOOLS_DIR, $BUILTINS_SHIP, $STATE_F);
    $state = load_json_file($STATE_F, ['tools'=>[]]);
    $only  = safe_id($in['tool'] ?? '');
    $now   = date('c');
    $report = [];
    foreach ($tools as $tid => $t) {
        if ($only && $tid !== $only) continue;
        $bin = resolve_binary($t, $state);
        if (!isset($state['tools'][$tid])) $state['tools'][$tid] = [];
        $state['tools'][$tid]['last_detected_at'] = $now;
        $state['tools'][$tid]['detected_path']    = $bin;
        // Auto-enable on first detection (don't re-enable if user disabled)
        if ($bin && !isset($state['tools'][$tid]['enabled'])) {
            $state['tools'][$tid]['enabled'] = true;
        }
        $report[$tid] = ['available' => (bool)$bin, 'path' => $bin];
    }
    save_json_file($STATE_F, $state);
    echo json_encode(['ok'=>true,'report'=>$report], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: read_output — fetch the textual content of a tool-produced file
//
// Used by index.html's _attachRunTool to inline transcripts (whisper output,
// pandoc markdown, ffmpeg log) into the prompt block. Security: only files
// under the projects root or the cockpit_data tree are readable, and only
// text-ish extensions. Size cap 256 KB (B2 inlines up to ~50 KB; the cap
// gives slack for whisper SRT files).
// =============================================================================
if ($action === 'read_output') {
    $path = trim((string)($in['path'] ?? ($_GET['path'] ?? '')));
    if ($path === '') { echo json_encode(['ok'=>false,'error'=>'Missing path'], JSON_UNESCAPED_UNICODE); exit; }
    // Whitelist extensions
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    if (!in_array($ext, ['txt','md','markdown','srt','vtt','json','jsonl','csv','tsv','log','html','htm','xml','yaml','yml','svg'], true)) {
        echo json_encode(['ok'=>false,'error'=>'Unsupported extension: '.$ext], JSON_UNESCAPED_UNICODE); exit;
    }
    // Path must resolve under an allowed root
    $real = realpath($path);
    if (!$real || !is_file($real)) { echo json_encode(['ok'=>false,'error'=>'File not found'], JSON_UNESCAPED_UNICODE); exit; }
    $allowed = [$PATHS['projects_root'], $PATHS['cockpit_data']];
    $ok = false;
    foreach ($allowed as $base) {
        if (strpos($real, $base . '/') === 0 || $real === $base) { $ok = true; break; }
    }
    if (!$ok) { echo json_encode(['ok'=>false,'error'=>'Path outside allowed roots'], JSON_UNESCAPED_UNICODE); exit; }
    $size = (int)@filesize($real);
    if ($size > 262144) {
        echo json_encode(['ok'=>true, 'truncated'=>true, 'size'=>$size,
            'content'=>(string)@file_get_contents($real, false, null, 0, 262144)], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok'=>true, 'truncated'=>false, 'size'=>$size,
        'content'=>(string)@file_get_contents($real)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: list_output — list files in a tool output directory
// Used by video-vision to enumerate extracted keyframe images.
// =============================================================================
if ($action === 'list_output') {
    $path = trim((string)($in['path'] ?? ($_GET['path'] ?? '')));
    if ($path === '') { echo json_encode(['ok'=>false,'error'=>'Missing path'], JSON_UNESCAPED_UNICODE); exit; }

    // For image sequences, the output path is a pattern like /dir/name_key_%03d.jpg
    // Resolve the directory from the pattern
    $dir = dirname($path);
    $real = realpath($dir);
    if (!$real || !is_dir($real)) {
        echo json_encode(['ok'=>false,'error'=>'Directory not found: '.$dir], JSON_UNESCAPED_UNICODE); exit;
    }
    $allowed = [$PATHS['projects_root'], $PATHS['cockpit_data']];
    $ok = false;
    foreach ($allowed as $base) {
        if (strpos($real, $base . '/') === 0 || $real === $base) { $ok = true; break; }
    }
    if (!$ok) { echo json_encode(['ok'=>false,'error'=>'Path outside allowed roots'], JSON_UNESCAPED_UNICODE); exit; }

    // Get the filename stem pattern to filter by
    $stem = pathinfo($path, PATHINFO_FILENAME);
    // Strip the printf-style format specifier (e.g. _key_%03d → _key_)
    $prefix = preg_replace('/%\d*d/', '', $stem);
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));

    $files = [];
    foreach (scandir($real) as $f) {
        if ($f === '.' || $f === '..') continue;
        if ($prefix && strpos($f, $prefix) !== 0) continue;
        if ($ext && strtolower(pathinfo($f, PATHINFO_EXTENSION)) !== $ext) continue;
        $files[] = $real . '/' . $f;
    }
    sort($files);
    echo json_encode(['ok'=>true, 'files'=>$files, 'count'=>count($files)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: run — execute a preset on an input path
//
// The preset's command template uses placeholders:
//   {WEBROOT} — this install's web root (escaped), for shipped helper scripts
//   {INPUT}   — the input file path (escaped)
//   {OUTPUT}  — auto-resolved output path
//   {ARGS}    — extra arguments from the request (escaped, optional)
//
// Returns the resolved output path on success. The output is created on disk;
// the chat can link to it.
// =============================================================================
if ($action === 'run') {
    $tid    = safe_id($in['tool'] ?? '');
    $pid    = safe_preset($in['preset'] ?? '');
    $input  = trim((string)($in['input'] ?? ''));
    $extra  = trim((string)($in['extra_args'] ?? ''));
    $project= safe_project($in['project'] ?? '');
    $chat   = safe_chat($in['chat'] ?? '');

    if (!$tid || !$pid || $input === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing tool/preset/input'], JSON_UNESCAPED_UNICODE); exit;
    }

    $tools = load_tools($TOOLS_DIR, $BUILTINS_SHIP, $STATE_F);
    if (!isset($tools[$tid])) {
        echo json_encode(['ok'=>false,'error'=>'Tool not found: '.$tid], JSON_UNESCAPED_UNICODE); exit;
    }
    $tool = $tools[$tid];
    $preset = null;
    foreach (($tool['presets'] ?? []) as $p) {
        if (($p['id'] ?? '') === $pid) { $preset = $p; break; }
    }
    if (!$preset) {
        echo json_encode(['ok'=>false,'error'=>'Preset not found: '.$pid], JSON_UNESCAPED_UNICODE); exit;
    }

    $state = load_json_file($STATE_F, ['tools'=>[]]);
    $bin   = resolve_binary($tool, $state);
    if (!$bin) {
        echo json_encode(['ok'=>false, 'not_installed'=>true, 'tool'=>$tid, 'binary'=>($tool['binary'] ?? $tid),
            'install_hint'=>tools_install_hint($tool),
            'error'=>($tool['name'] ?? $tid).' is not installed on this machine ("'.($tool['binary'] ?? $tid).'" not found). Install it: '.tools_install_hint($tool).' — or set the binary override in Tools settings.'], JSON_UNESCAPED_UNICODE); exit;
    }

    // Validate input exists. URLs (yt-dlp etc.) bypass this.
    $is_url = (bool)preg_match('#^https?://#i', $input);
    // A relative path means "in the current project" (the Run dialog says "paste a path");
    // resolved against Apache's cwd it was never found (rig, b86).
    if (!$is_url && $input !== '' && $input[0] !== '/' && $project !== '' && !empty($PATHS['projects_root'])) {
        $cand = rtrim((string)$PATHS['projects_root'], '/') . '/' . $project . '/' . $input;
        if (file_exists($cand)) $input = $cand;
    }
    if (!$is_url && !file_exists($input)) {
        echo json_encode(['ok'=>false,'error'=>'Input file not found: '.$input], JSON_UNESCAPED_UNICODE); exit;
    }

    // Resolve output path
    $project_dir = null;
    if ($project) {
        // HIGH-54 fix: read paths.json for the real root, with fallback for
        // legacy installs that have either path.
        $candidates = [$PATHS['projects_root']];
        foreach ($candidates as $c) {
            if (is_dir($c . '/' . $project)) { $project_dir = $c . '/' . $project; break; }
        }
    }
    $output = resolve_output_path($tool, $preset, $state, $input, $project_dir, $OUTPUTS_DIR);

    // Build the command from the template
    $template = $preset['command'] ?? '';
    if ($template === '') {
        echo json_encode(['ok'=>false,'error'=>'Preset has no command template'], JSON_UNESCAPED_UNICODE); exit;
    }

    // The template's first token is the binary name — replace with resolved path
    // Example template: "ffmpeg -i {INPUT} -vn ... {OUTPUT} -y"
    // We replace the leading binary name with the resolved $bin so users with
    // overrides get the right executable.
    $tokens = explode(' ', $template, 2);
    if (count($tokens) === 2 && $tokens[0] === ($tool['binary'] ?? $tid)) {
        $template = escapeshellarg($bin) . ' ' . $tokens[1];
    }

    // {ARGS} is user-supplied — must be tokenized + escaped or a malicious
    // arg can run arbitrary shell commands as www-data (CRIT-53 fix).
    // Split on whitespace, drop empties, escapeshellarg each token, rejoin.
    $extra_safe = '';
    if ($extra !== '') {
        // whitespace separates tokens, except inside "double" or 'single' quotes (a path with a space: with="/home/me/My Project/want.csv"
        // or name="a b"); the quotes themselves are dropped. A token is never interpreted by a shell: each is escapeshellarg'd below.
        $tokens = [];
        if (preg_match_all('/(?:[^\s"\']+|"[^"]*"|\'[^\']*\'|["\'])+/u', trim($extra), $tm)) {
            foreach ($tm[0] as $t) {
            // only the quotes of a name="a b" argument are dropped; every other quote stays (a bare 'Eilat' or "a b" belongs to SQL or to the tool); quotes inside a token stay (SQL such as CAST("sales total" AS REAL) must reach the tool as typed)
            if (preg_match('/^([A-Za-z_][\w.-]*=)"([^"]*)"$/u', $t, $q) || preg_match('/^([A-Za-z_][\w.-]*=)\'([^\']*)\'$/u', $t, $q)) $t = $q[1] . $q[2];
            $tokens[] = $t;
        }
        }
        $tokens = array_filter($tokens, fn($t) => $t !== '');
        $extra_safe = implode(' ', array_map('escapeshellarg', $tokens));
    }
    // {WEBROOT} is where this install actually lives. Shipped presets used to
    // hardcode /var/www/html/cockpit, so a helper script beside them was
    // unreachable on any other layout — Fedora's /srv/http, or the user-mode
    // install under ~/.local/share. __DIR__ is the one path that is always right.
    $cmd = strtr($template, [
        '{INPUT}'   => escapeshellarg($input),
        '{OUTPUT}'  => escapeshellarg($output),
        '{WEBROOT}' => escapeshellarg(__DIR__),
        '{ARGS}'    => $extra_safe,
    ]);
    // Run from the input's own folder, so a relative file named in the extra arguments (with=wanted.csv, plants=list.txt) is found next to it,
    // as the Run dialog's wording implies; before, it was looked for in the web server's working directory.
    if (!$is_url && is_file($input) && $input[0] === '/') $cmd = 'cd ' . escapeshellarg(dirname($input)) . ' && ' . $cmd;

    // ── Execute ──────────────────────────────────────────────────────────
    // Bounded time (MED-59: per preset, default 300s). Two modes:
    //   sync  — the caller waits for the result (media pipeline callers).
    //   async — {async:true}: the process is started detached, a job record is
    //           written, and the caller polls ?action=job_status, can
    //           ?action=job_kill it, and ?action=jobs lists what is running.
    //           Added 2026-09-12 after a run sat as "running" in the UI with no
    //           way to see, stop, or even know whether anything was running.
    $timeout_secs = (int)($preset['timeout_seconds'] ?? 300);
    if ($timeout_secs < 1) $timeout_secs = 300;
    $job = [
        'tool' => $tid, 'preset' => $pid, 'label' => (string)($preset['label'] ?? $pid),
        'binary' => $bin, 'input' => $input, 'output' => $output, 'is_url' => $is_url,
        'expected_output_glob' => (string)($preset['expected_output_glob'] ?? ''),
        // Some tools treat {OUTPUT} as a PREFIX and name the real files
        // themselves: pdftoppm writes <prefix>-01.png, -02.png … so the declared
        // output path never exists and the run was reported as a failure even
        // when every page rendered. Unlike expected_output_glob (yt-dlp), the
        // declared path must be KEPT here — list_output filters by its stem and
        // extension to find the whole sequence, so rewriting it to one matched
        // file would return a single page.
        'output_is_prefix' => !empty($preset['output_is_prefix']),
        'extra' => $extra, 'cmd' => $cmd, 'timeout_seconds' => $timeout_secs,
        'project' => (string)($project ?? ''), 'chat' => (string)($chat ?? ''),
        'user' => (string)($_SESSION['cockpit_user'] ?? ''),
        'started' => microtime(true),
    ];
    $timeout_prefix = cockpit_timeout_cmd($timeout_secs);

    if (!empty($in['async'])) {
        $jid = tools_job_start($JOBS_DIR, $job, $timeout_prefix);
        if ($jid === null) { echo json_encode(['ok'=>false,'error'=>'Could not start the job (jobs dir not writable?)'], JSON_UNESCAPED_UNICODE); exit; }
        echo json_encode(['ok'=>true, 'job'=>$jid, 'tool'=>$tid, 'preset'=>$pid, 'label'=>$job['label'],
                          'timeout_seconds'=>$timeout_secs, 'output'=>$output], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $logFile = tempnam(sys_get_temp_dir(), 'cockpit_tool_');
    $wrapped = 'umask 002; ' . $timeout_prefix . 'bash -c ' . escapeshellarg($cmd . ' 2>&1') . ' < /dev/null > ' . escapeshellarg($logFile) . ' 2>&1; echo $?';
    $rc_raw  = shell_exec($wrapped);
    // HIGH-55: shell_exec returns NULL on failure (e.g. disabled in php.ini).
    // Empty string is NOT a successful "0" — distinguish them.
    if ($rc_raw === null) {
        $rc = -1;
    } else {
        $rc_str = trim((string)$rc_raw);
        $rc = ($rc_str === '') ? -1 : intval($rc_str);
    }
    $log = (string)file_get_contents($logFile);
    @unlink($logFile);
    $result = tools_finish($job, $rc, $log, false);
    echo json_encode($result, JSON_UNESCAPED_UNICODE);
    exit;
}

// ── Job helpers (async runs) ─────────────────────────────────────────────
// The Cockpit tmux server (the one the three agent sessions live in). Reachable
// from Apache because cockpit_start grants www-data server-access.
function tools_tmux(): string {
    global $PATHS;
    $sock = (string)($PATHS['tmux_socket'] ?? '');
    if ($sock === '' || !file_exists($sock)) return '';
    $bin = trim((string)shell_exec('command -v tmux 2>/dev/null'));
    if ($bin === '') return '';
    return $bin . ' -S ' . escapeshellarg($sock);
}
// Make sure the cockpit_tools session exists (idempotent). Returns the tmux
// command prefix, or '' when tmux is not usable here.
function tools_tmux_ensure(): string {
    $t = tools_tmux();
    if ($t === '') return '';
    @shell_exec($t . ' has-session -t cockpit_tools 2>/dev/null || ' . $t . ' new-session -d -s cockpit_tools -x 220 -y 50 bash 2>/dev/null');
    $ok = trim((string)shell_exec($t . ' has-session -t cockpit_tools 2>/dev/null; echo $?'));
    return $ok === '0' ? $t : '';
}
// The rc file marks a finished job. It is pre-created (see below), so "exists"
// is not enough: finished means non-empty.
function tools_rc_ready(string $rcf): bool { return is_file($rcf) && filesize($rcf) > 0; }
function tools_job_start(string $dir, array $job, string $timeout_prefix): ?string {
    if (!is_dir($dir) && !@mkdir($dir, 0775, true)) return null;
    $jid = bin2hex(random_bytes(6));
    $log = "$dir/$jid.log"; $rcf = "$dir/$jid.rc"; $jf = "$dir/$jid.json";
    // Two users meet here: this code runs as the web user, the tmux job as the
    // login user. The web user created tools_jobs/ 0755, so the job could not
    // write its rc or log, and a finished run read as "stopped" once the window
    // closed (live, 2026-09-13). Make the directory group-owned by the data
    // tree's group and group-writable, and pre-create both files 0664 in that
    // group; the job only needs to write into them.
    $grp = @filegroup(dirname($dir));
    // On this layout the per-user data dir belongs to the web user; the group
    // both sides share is the login user's (the web user is a member of it, so
    // it may chgrp to it). Use it when we can name it.
    if (function_exists('cockpit_owner_user')) { $g = @posix_getgrnam(cockpit_owner_user()); if ($g) $grp = (int)$g['gid']; }
    @chmod($dir, 0775); if ($grp !== false && @filegroup($dir) !== $grp) @chgrp($dir, $grp);
    foreach ([$log, $rcf] as $p) { @touch($p); @chmod($p, 0664); if ($grp !== false) @chgrp($p, $grp); }
    $t = tools_tmux_ensure();
    if ($t !== '') {
        // Preferred: a window in the cockpit_tools tmux session, so the Tools
        // card's "open session" button shows the command running live, like
        // the agent cards. Output is tee'd to the log the poller reads; the
        // window lingers 20s after the end so a watcher sees how it finished.
        // The command runs as the tmux server's user (the login user), which
        // is also why job_kill uses tmux rather than a signal from www-data.
        $inner = 'umask 002; ' . $timeout_prefix . 'bash -c ' . escapeshellarg($job['cmd'] . ' 2>&1') . ' < /dev/null 2>&1 | tee ' . escapeshellarg($log) . '; echo ${PIPESTATUS[0]} > ' . escapeshellarg($rcf) . '; date +%s.%N > ' . escapeshellarg($rcf . '.t');
        $shown = 'echo; echo "[cockpit tools] ' . addslashes($job['label']) . '"; echo "[cockpit tools] ' . addslashes($job['cmd']) . '"; echo; ' . $inner . '; echo; echo "[cockpit tools] finished rc=$(cat ' . escapeshellarg($rcf) . ' 2>/dev/null) -- this window closes in 20s"; sleep 20';
        $pane = trim((string)shell_exec($t . ' new-window -d -t cockpit_tools -n ' . escapeshellarg('job_' . $jid) . ' -P -F "#{pane_pid}" ' . escapeshellarg('bash -c ' . escapeshellarg($shown)) . ' 2>/dev/null'));
        if ($pane !== '' && ctype_digit($pane)) {
            $job['id'] = $jid; $job['pid'] = (int)$pane; $job['tmux_window'] = 'job_' . $jid;
            $job['log_file'] = $log; $job['rc_file'] = $rcf; $job['status'] = 'running';
            file_put_contents($jf, json_encode($job, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_PRETTY_PRINT), LOCK_EX);
            return $jid;
        }
        // tmux refused (no access?) -- fall through to the detached run.
    }
    // setsid: the tool becomes its own process group, so job_kill can take the
    // whole tree (a pandoc that spawned pdflatex, an ffmpeg pipeline) with one
    // signal, and Apache's request ending does not touch it.
    $inner = 'umask 002; ' . $timeout_prefix . 'bash -c ' . escapeshellarg($job['cmd'] . ' 2>&1') . ' < /dev/null > ' . escapeshellarg($log) . ' 2>&1; echo $? > ' . escapeshellarg($rcf) . '; date +%s.%N > ' . escapeshellarg($rcf . '.t');
    $pid = trim((string)shell_exec('setsid nohup bash -c ' . escapeshellarg($inner) . ' >/dev/null 2>&1 & echo $!'));
    if ($pid === '' || !ctype_digit($pid)) return null;
    $job['id'] = $jid; $job['pid'] = (int)$pid; $job['log_file'] = $log; $job['rc_file'] = $rcf; $job['status'] = 'running';
    file_put_contents($jf, json_encode($job, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_PRETTY_PRINT), LOCK_EX);
    return $jid;
}
function tools_job_load(string $dir, string $jid): ?array {
    if (!preg_match('/^[0-9a-f]{12}$/', $jid)) return null;
    $j = json_decode((string)@file_get_contents("$dir/$jid.json"), true);
    return is_array($j) ? $j : null;
}
function tools_job_save(string $dir, array $job): void {
    file_put_contents("$dir/{$job['id']}.json", json_encode($job, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES|JSON_PRETTY_PRINT), LOCK_EX);
}
function tools_pid_alive(int $pid): bool {
    if ($pid <= 0) return false;
    if (is_dir("/proc/$pid")) return true;          // works across users (posix_kill would say EPERM)
    if (function_exists('posix_kill')) return @posix_kill($pid, 0);
    return false;
}
function tools_job_alive(array $job): bool {
    if (!empty($job['tmux_window'])) {
        $t = tools_tmux(); if ($t === '') return false;
        $w = trim((string)shell_exec($t . ' list-windows -t cockpit_tools -F "#{window_name}" 2>/dev/null'));
        return in_array($job['tmux_window'], preg_split('/\R/', $w) ?: [], true);
    }
    return tools_pid_alive((int)$job['pid']);
}
// Result assembly shared by the sync path and job completion; records the run
// in the chat (once) when project+chat are known.
function tools_finish(array $job, int $rc, string $log, bool $killed): array {
    global $PATHS;
    $output  = $job['output'];
    $elapsed = (int)round((microtime(true) - (float)$job['started']) * 1000);
    if (isset($job['finished'])) $elapsed = (int)round(((float)$job['finished'] - (float)$job['started']) * 1000);
    $ok = !$killed && ($rc === 0) && (file_exists($output) || !empty($job['is_url']));
    // Some tools (yt-dlp) name the output themselves; presets declare a glob.
    if (!$ok && !$killed && $job['expected_output_glob'] !== '') {
        $found = glob(dirname($output) . '/' . $job['expected_output_glob']);
        if (!empty($found)) { $output = end($found); $ok = true; }
    }
    // A prefix preset (pdftoppm): the sequence exists, the declared path does
    // not. Succeed on the sequence and keep the declared path, which is what
    // list_output needs to find every page rather than one.
    $seq = [];
    if (!$ok && !$killed && $rc === 0 && !empty($job['output_is_prefix'])) {
        $seq = glob(dirname($output) . '/' . pathinfo($output, PATHINFO_FILENAME) . '*') ?: [];
        if ($seq) $ok = true;
    }
    // The output must be editable like everything else in the tree. A run as
    // www-data (the detached fallback) left a 0644 file the login user could
    // only read (2026-09-13). Copy the mode of the parent directory's files —
    // group-writable in the installer's shared-group layout — and its group.
    if ($ok && file_exists($output)) tools_share_output($output);
    foreach ($seq as $f) if (is_file($f)) tools_share_output($f);   // the rendered pages
    $result = [
        'ok'         => $ok,
        'tool'       => $job['tool'],
        'preset'     => $job['preset'],
        'binary'     => $job['binary'],
        'input'      => $job['input'],
        'output'     => $ok ? $output : null,
        'output_size'=> $ok && file_exists($output) ? filesize($output) : null,
        'rc'         => $rc,
        'log'        => mb_substr($log, 0, 4096),
        'elapsed_ms' => $elapsed,
        'cmd'        => $job['cmd'],   // for transparency / debugging
        'killed'     => $killed,
    ];
    if ($killed) $result['error'] = 'Stopped by user after ' . round($elapsed / 1000) . 's.';
    elseif (!$ok && $rc === 124) $result['error'] = 'Timed out after ' . $job['timeout_seconds'] . 's (rc=124).';
    elseif (!$ok && $rc !== 0) $result['error'] = 'Tool failed (rc=' . $rc . '). See log.';

    // Record the run in the chat (2026-09-12). Until now a tool run lived only
    // in the live view and vanished on reload. As a chat turn it survives, and
    // it becomes context the agents can find ("the file we converted earlier"
    // — the turn carries the input and output paths). Same writer the combos
    // and workers use, so the chat index is updated too. Failures and kills
    // are recorded as well: they are part of the story.
    if ($job['project'] !== '' && $job['chat'] !== '' && !empty($PATHS['projects_root'])) {
        require_once __DIR__ . '/combos_core.php';
        $userLine  = $job['label'] . ' ⟶ ' . $job['input'] . ($job['extra'] !== '' ? '  [' . $job['extra'] . ']' : '');
        $logTail   = trim(mb_substr($log, -600));
        if ($ok)          $agentLine = 'Output: ' . $output . ($result['output_size'] !== null ? ' (' . round($result['output_size'] / 1024, 1) . ' KB)' : '') . ' — ' . $elapsed . ' ms';
        elseif ($killed)  $agentLine = 'STOPPED by user — ' . $elapsed . ' ms';
        else              $agentLine = 'FAILED (rc=' . $rc . ') — ' . $elapsed . ' ms';
        if ($logTail !== '') $agentLine .= "\n\nlog tail:\n" . $logTail;
        $result['saved'] = combos_append_chat((string)$PATHS['projects_root'], $job['project'], $job['chat'], $userLine, $agentLine, $job['tool'] . ':' . $job['preset'], 'tools');
    }
    return $result;
}
// Give an output file the tree's permissions: 0664 (or the parent dir's mode
// minus execute bits when that is more permissive), the parent's group.
function tools_share_output(string $path): void {
    $dir = dirname($path);
    $mode = 0664;
    $dm = @fileperms($dir);
    if ($dm !== false && (($dm & 0777) & 0020)) $mode = 0664;   // group-writable tree
    @chmod($path, $mode);
    $grp = @filegroup($dir);
    if ($grp !== false && @filegroup($path) !== $grp) @chgrp($path, $grp);
}
// Poll one job. Finalises (result + chat record) exactly once, on the first
// poll that sees the process gone.
function tools_job_status(string $dir, string $jid): array {
    $job = tools_job_load($dir, $jid);
    if (!$job) return ['ok'=>false, 'error'=>'Unknown job'];
    if (isset($job['result'])) return ['ok'=>true, 'status'=>$job['status'], 'job'=>$jid, 'result'=>$job['result'], 'elapsed_ms'=>$job['result']['elapsed_ms']];
    $rcFile = $job['rc_file']; $alive = tools_job_alive($job);
    if (!tools_rc_ready($rcFile) && $alive) {
        $log = (string)@file_get_contents($job['log_file']);
        return ['ok'=>true, 'status'=>'running', 'job'=>$jid, 'pid'=>$job['pid'],
                'elapsed_ms'=>(int)round((microtime(true) - (float)$job['started']) * 1000),
                'timeout_seconds'=>$job['timeout_seconds'], 'label'=>$job['label'],
                'log_tail'=>mb_substr($log, -800)];
    }
    // Finished (rc written), or vanished (killed by something else, or the
    // rig rebooted): finalise from what is there.
    $rc = tools_rc_ready($rcFile) ? intval(trim((string)file_get_contents($rcFile))) : -1;
    $killed = !empty($job['killed']) || (!tools_rc_ready($rcFile) && !$alive);
    $log = (string)@file_get_contents($job['log_file']);
    // the moment the command really ended (written by the wrapper), not the moment this poll noticed: otherwise every run reads ~1.5 s
    $tEnd = (float)trim((string)@file_get_contents($rcFile . '.t'));
    $job['finished'] = ($tEnd >= (float)$job['started'] && $tEnd <= microtime(true) + 1) ? $tEnd : microtime(true);
    @unlink($rcFile . '.t');
    $job['status'] = $killed ? 'killed' : ($rc === 0 ? 'done' : 'failed');
    $job['result'] = tools_finish($job, $rc, $log, $killed);
    tools_job_save($dir, $job);
    @unlink($job['log_file']); @unlink($rcFile);
    return ['ok'=>true, 'status'=>$job['status'], 'job'=>$jid, 'result'=>$job['result'], 'elapsed_ms'=>$job['result']['elapsed_ms']];
}
function tools_job_kill(string $dir, string $jid): array {
    $job = tools_job_load($dir, $jid);
    if (!$job) return ['ok'=>false, 'error'=>'Unknown job'];
    if (isset($job['result'])) return ['ok'=>true, 'status'=>$job['status'], 'already_finished'=>true];
    $pid = (int)$job['pid'];
    if (!empty($job['tmux_window'])) {
        // The command runs as the tmux server's user; killing the window takes
        // its whole pane process group with it (tmux sends SIGHUP to the pty).
        $t = tools_tmux();
        if ($t !== '') @shell_exec($t . ' kill-window -t ' . escapeshellarg('cockpit_tools:' . $job['tmux_window']) . ' 2>/dev/null');
    } elseif (tools_pid_alive($pid)) {
        // Whole process group (setsid made $pid its leader): TERM, then KILL.
        @shell_exec('kill -TERM -- -' . $pid . ' 2>/dev/null; kill -TERM ' . $pid . ' 2>/dev/null');
        usleep(400000);
        if (tools_pid_alive($pid)) @shell_exec('kill -KILL -- -' . $pid . ' 2>/dev/null; kill -KILL ' . $pid . ' 2>/dev/null');
    }
    $job['killed'] = true; tools_job_save($dir, $job);
    return tools_job_status($dir, $jid);
}
// Running jobs (optionally only this user's).
function tools_jobs_running(string $dir, string $user = ''): array {
    $out = [];
    foreach (glob("$dir/*.json") ?: [] as $jf) {
        $j = json_decode((string)@file_get_contents($jf), true);
        if (!is_array($j) || isset($j['result'])) continue;
        if ($user !== '' && ($j['user'] ?? '') !== $user) continue;
        if (!tools_job_alive($j) && !tools_rc_ready($j['rc_file'])) { tools_job_status($dir, $j['id']); continue; }
        if (tools_rc_ready($j['rc_file'])) { tools_job_status($dir, $j['id']); continue; }
        $out[] = ['job'=>$j['id'], 'tool'=>$j['tool'], 'preset'=>$j['preset'], 'label'=>$j['label'], 'input'=>$j['input'],
                  'pid'=>$j['pid'], 'elapsed_ms'=>(int)round((microtime(true) - (float)$j['started']) * 1000),
                  'timeout_seconds'=>$j['timeout_seconds'], 'chat'=>$j['chat'], 'project'=>$j['project']];
    }
    return $out;
}

// =============================================================================
// Action: job_status / job_kill / jobs / kill_all — async tool runs
// =============================================================================
if ($action === 'ensure_session') {   // Tools card "open session" button calls this before attaching
    echo json_encode(['ok'=>tools_tmux_ensure() !== '', 'session'=>'cockpit_tools'], JSON_UNESCAPED_UNICODE); exit;
}
if ($action === 'job_status') {
    echo json_encode(tools_job_status($JOBS_DIR, (string)($in['job'] ?? $_GET['job'] ?? '')), JSON_UNESCAPED_UNICODE); exit;
}
if ($action === 'job_kill') {
    echo json_encode(tools_job_kill($JOBS_DIR, (string)($in['job'] ?? '')), JSON_UNESCAPED_UNICODE); exit;
}
if ($action === 'jobs') {
    echo json_encode(['ok'=>true, 'jobs'=>tools_jobs_running($JOBS_DIR, (string)($_SESSION['cockpit_user'] ?? ''))], JSON_UNESCAPED_UNICODE); exit;
}
if ($action === 'kill_all') {
    $killed = [];
    foreach (tools_jobs_running($JOBS_DIR, (string)($_SESSION['cockpit_user'] ?? '')) as $j) { tools_job_kill($JOBS_DIR, $j['job']); $killed[] = $j['job']; }
    echo json_encode(['ok'=>true, 'killed'=>$killed], JSON_UNESCAPED_UNICODE); exit;
}

// =============================================================================
// Action: check — is the tool's binary present? With an install hint when not.
// =============================================================================
if ($action === 'check') {
    $tid   = safe_id($in['tool'] ?? $_GET['tool'] ?? '');
    $tools = load_tools($TOOLS_DIR, $BUILTINS_SHIP, $STATE_F);
    if (!$tid || !isset($tools[$tid])) { echo json_encode(['ok'=>false,'error'=>'Tool not found'], JSON_UNESCAPED_UNICODE); exit; }
    $state = load_json_file($STATE_F, ['tools'=>[]]);
    $bin   = resolve_binary($tools[$tid], $state);
    echo json_encode(['ok'=>true, 'tool'=>$tid, 'installed'=>(bool)$bin, 'binary'=>$bin,
                      'install_hint'=>$bin ? '' : tools_install_hint($tools[$tid])], JSON_UNESCAPED_UNICODE); exit;
}

// =============================================================================
// Action: set_auto_route — toggle for project
// =============================================================================
if ($action === 'set_auto_route') {
    $project = trim((string)($in['project'] ?? ''));
    $on      = !empty($in['enabled']);
    if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
    $state = load_json_file($STATE_F, ['tools'=>[],'auto_route_projects'=>[]]);
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
    $state = load_json_file($STATE_F, ['tools'=>[],'auto_route_projects'=>[]]);
    $list  = (is_array($state['auto_route_projects'] ?? null)) ? $state['auto_route_projects'] : [];
    echo json_encode(['ok'=>true, 'project'=>$project, 'enabled'=>in_array($project, $list, true)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: add_custom — register a user tool definition
// =============================================================================
if ($action === 'add_custom') {
    $tid    = safe_id($in['id'] ?? '');
    $name   = trim((string)($in['name'] ?? ''));
    $binary = trim((string)($in['binary'] ?? ''));
    $presets = is_array($in['presets'] ?? null) ? $in['presets'] : [];
    if (!$tid || $name === '' || $binary === '' || !$presets) {
        echo json_encode(['ok'=>false,'error'=>'Missing id/name/binary/presets'], JSON_UNESCAPED_UNICODE); exit;
    }
    $dest = $TOOLS_DIR . '/' . $tid . '.json';
    if (is_file($dest)) {
        echo json_encode(['ok'=>false,'error'=>'Tool with this id already exists'], JSON_UNESCAPED_UNICODE); exit;
    }
    $tool = [
        'id'          => $tid,
        'name'        => $name,
        'description' => $in['description'] ?? '',
        'binary'      => $binary,
        'website'     => $in['website'] ?? null,
        'custom'      => true,
        'presets'     => array_map(function($p) {
            return [
                'id'          => safe_preset($p['id'] ?? '') ?: 'preset',
                'label'       => trim((string)($p['label'] ?? '')),
                'description' => trim((string)($p['description'] ?? '')),
                'input_kinds' => is_array($p['input_kinds'] ?? null) ? $p['input_kinds'] : ['file'],
                'output_kind' => trim((string)($p['output_kind'] ?? '')),
                'output_ext'  => trim((string)($p['output_ext']  ?? 'out')),
                'command'     => trim((string)($p['command']     ?? '')),
            ];
        }, $presets),
    ];
    save_json_file($dest, $tool);
    echo json_encode(['ok'=>true,'tool'=>$tid], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: delete — remove a custom tool
// =============================================================================
if ($action === 'delete') {
    $tid = safe_id($in['tool'] ?? $_GET['tool'] ?? '');
    if (!$tid) { echo json_encode(['ok'=>false,'error'=>'Missing tool'], JSON_UNESCAPED_UNICODE); exit; }
    $path = $TOOLS_DIR . '/' . $tid . '.json';
    $j = load_json_file($path);
    if (!is_array($j)) { echo json_encode(['ok'=>false,'error'=>'Not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (empty($j['custom'])) {
        echo json_encode(['ok'=>false,'error'=>'Cannot delete built-in tool. Disable it instead.'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    @unlink($path);
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: add_preset — append a preset to any tool (built-in or custom).
//
// NEW BEHAVIOUR (Tools Staleness Fix 2026-05-12):
//   - Built-in tools: preset stored in tools_state.json under
//     tools.<id>.user_presets[]. The shipped JSON is never touched.
//   - Custom tools: preset appended to cockpit_data/tools/<id>.json
//     (the whole custom-tool definition lives there).
//
// In both cases the new preset is tagged user_added:true so it can be
// removed later via remove_preset.
// =============================================================================
if ($action === 'add_preset') {
    $tid    = safe_id($in['tool'] ?? '');
    $pid    = safe_preset($in['preset_id'] ?? '');
    $label  = trim((string)($in['label'] ?? '')) ?: $pid;
    $desc   = trim((string)($in['description'] ?? ''));
    $cmd    = trim((string)($in['command'] ?? ''));
    $oext   = trim((string)($in['output_ext'] ?? 'out'));
    $okind  = trim((string)($in['output_kind'] ?? 'file'));
    $ikinds = is_array($in['input_kinds'] ?? null) ? $in['input_kinds'] : ['file'];

    if (!$tid || !$pid || $cmd === '') {
        echo json_encode(['ok'=>false,'error'=>'Missing tool/preset_id/command'], JSON_UNESCAPED_UNICODE); exit;
    }
    // Sanitize input_kinds (lowercase alphanum/dash/underscore, max 32 chars)
    $ikinds = array_values(array_filter(array_map(function($k){
        $k = strtolower(trim((string)$k));
        return preg_match('/^[a-z0-9_-]{1,32}$/', $k) ? $k : null;
    }, $ikinds)));
    if (!$ikinds) $ikinds = ['file'];

    $ship_path = $BUILTINS_SHIP . '/' . $tid . '.json';
    $user_path = $TOOLS_DIR    . '/' . $tid . '.json';
    $is_builtin = is_file($ship_path);

    // The preset data we'll store
    $new_preset = [
        'id'          => $pid,
        'label'       => $label,
        'description' => $desc,
        'input_kinds' => $ikinds,
        'output_kind' => $okind,
        'output_ext'  => $oext,
        'command'     => $cmd,
        'user_added'  => true,
    ];

    if ($is_builtin) {
        // --- Built-in tool: write to tools_state.json user_presets ---
        $state = load_json_file($STATE_F, ['tools' => []]);
        if (!isset($state['tools'][$tid])) $state['tools'][$tid] = [];
        if (!isset($state['tools'][$tid]['user_presets']) || !is_array($state['tools'][$tid]['user_presets'])) {
            $state['tools'][$tid]['user_presets'] = [];
        }
        // Reject duplicate preset id (check both shipped presets and user_presets)
        $shipped_def = load_json_file($ship_path);
        foreach (($shipped_def['presets'] ?? []) as $p) {
            if (($p['id'] ?? '') === $pid) {
                echo json_encode(['ok'=>false,'error'=>'Preset id already exists as a shipped preset on this tool'], JSON_UNESCAPED_UNICODE); exit;
            }
        }
        foreach ($state['tools'][$tid]['user_presets'] as $p) {
            if (($p['id'] ?? '') === $pid) {
                echo json_encode(['ok'=>false,'error'=>'Preset id already exists in user presets for this tool'], JSON_UNESCAPED_UNICODE); exit;
            }
        }
        $state['tools'][$tid]['user_presets'][] = $new_preset;
        save_json_file($STATE_F, $state);
        echo json_encode(['ok'=>true,'tool'=>$tid,'preset'=>$pid,'stored_in'=>'state'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // --- Custom tool: append to the user-side JSON ---
    if (!is_file($user_path)) {
        echo json_encode(['ok'=>false,'error'=>'Tool not found: '.$tid], JSON_UNESCAPED_UNICODE); exit;
    }
    $tool_def = load_json_file($user_path);
    if (!is_array($tool_def)) {
        echo json_encode(['ok'=>false,'error'=>'Tool definition unreadable'], JSON_UNESCAPED_UNICODE); exit;
    }
    // Reject duplicate preset id
    foreach (($tool_def['presets'] ?? []) as $p) {
        if (($p['id'] ?? '') === $pid) {
            echo json_encode(['ok'=>false,'error'=>'Preset id already exists for this tool'], JSON_UNESCAPED_UNICODE); exit;
        }
    }
    $tool_def['presets'][] = $new_preset;
    save_json_file($user_path, $tool_def);
    echo json_encode(['ok'=>true,'tool'=>$tid,'preset'=>$pid,'stored_in'=>'user_json'], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: remove_preset — drop a user-added preset from a tool.
//
// NEW BEHAVIOUR (Tools Staleness Fix 2026-05-12):
//   - Built-in tools: removes from tools_state.json user_presets[].
//   - Custom tools: removes from cockpit_data/tools/<id>.json.
//   - Only presets with user_added:true can be removed either way.
// =============================================================================
if ($action === 'remove_preset') {
    $tid = safe_id($in['tool'] ?? '');
    $pid = safe_preset($in['preset_id'] ?? '');
    if (!$tid || !$pid) {
        echo json_encode(['ok'=>false,'error'=>'Missing tool/preset_id'], JSON_UNESCAPED_UNICODE); exit;
    }

    $ship_path  = $BUILTINS_SHIP . '/' . $tid . '.json';
    $user_path  = $TOOLS_DIR     . '/' . $tid . '.json';
    $is_builtin = is_file($ship_path);

    if ($is_builtin) {
        // Built-in tool: remove from tools_state.json user_presets
        $state = load_json_file($STATE_F, ['tools' => []]);
        $user_presets = $state['tools'][$tid]['user_presets'] ?? [];
        $found = false;
        $is_user_added = false;
        foreach ($user_presets as $i => $p) {
            if (($p['id'] ?? '') !== $pid) continue;
            $found = true;
            $is_user_added = !empty($p['user_added']);
            if ($is_user_added) {
                array_splice($state['tools'][$tid]['user_presets'], $i, 1);
            }
            break;
        }
        if (!$found) {
            // Could also be a shipped preset (not removable)
            $shipped_def = load_json_file($ship_path);
            foreach (($shipped_def['presets'] ?? []) as $p) {
                if (($p['id'] ?? '') === $pid) {
                    echo json_encode(['ok'=>false,'error'=>'Cannot remove built-in shipped preset'], JSON_UNESCAPED_UNICODE); exit;
                }
            }
            echo json_encode(['ok'=>false,'error'=>'Preset not found'], JSON_UNESCAPED_UNICODE); exit;
        }
        if (!$is_user_added) {
            echo json_encode(['ok'=>false,'error'=>'Cannot remove built-in preset — only user-added presets can be removed'], JSON_UNESCAPED_UNICODE); exit;
        }
        save_json_file($STATE_F, $state);
        echo json_encode(['ok'=>true,'removed'=>$pid,'from'=>'state'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Custom tool: remove from user-side JSON
    if (!is_file($user_path)) {
        echo json_encode(['ok'=>false,'error'=>'No user-side definition for this tool'], JSON_UNESCAPED_UNICODE); exit;
    }
    $tool_def = load_json_file($user_path);
    if (!is_array($tool_def)) {
        echo json_encode(['ok'=>false,'error'=>'Tool definition unreadable'], JSON_UNESCAPED_UNICODE); exit;
    }
    $found = false;
    $is_user_added = false;
    foreach (($tool_def['presets'] ?? []) as $i => $p) {
        if (($p['id'] ?? '') !== $pid) continue;
        $found = true;
        $is_user_added = !empty($p['user_added']);
        if ($is_user_added) array_splice($tool_def['presets'], $i, 1);
        break;
    }
    if (!$found) { echo json_encode(['ok'=>false,'error'=>'Preset not found'], JSON_UNESCAPED_UNICODE); exit; }
    if (!$is_user_added) {
        echo json_encode(['ok'=>false,'error'=>'Cannot remove built-in preset — only user-added presets can be removed'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    save_json_file($user_path, $tool_def);
    echo json_encode(['ok'=>true,'removed'=>$pid,'from'=>'user_json'], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: test_binary — run "<binary> <version_args>" and return output.
//
// Phase 2b 2026-05-09. Used by the Test button in the Tools settings
// dialog. By default runs `<binary> --version`, but each tool's JSON
// can specify a different test command via the optional `version_args`
// field. This handles tools like ffmpeg that use `-version` (single
// dash) instead of `--version`. Tools without a working version flag
// can specify any short command that exits 0 on success.
//
// Updated 2026-05-10 to support per-tool version_args after ffmpeg's
// non-standard CLI broke the assumption that --version is universal.
// =============================================================================
if ($action === 'test_binary') {
    $tid = safe_id($in['tool'] ?? '');
    if (!$tid) { echo json_encode(['ok'=>false,'error'=>'Missing tool'], JSON_UNESCAPED_UNICODE); exit; }
    // Find the resolved binary path
    $user_path = $TOOLS_DIR . '/' . $tid . '.json';
    $ship_path = $BUILTINS_SHIP . '/' . $tid . '.json';
    $tool_def  = is_file($user_path) ? load_json_file($user_path)
               : (is_file($ship_path) ? load_json_file($ship_path) : null);
    if (!is_array($tool_def)) { echo json_encode(['ok'=>false,'error'=>'Tool not found'], JSON_UNESCAPED_UNICODE); exit; }

    $state = is_file($STATE_F) ? load_json_file($STATE_F) : [];
    $override = $state['tools'][$tid]['binary_override'] ?? '';
    $bin = $override !== '' ? $override : ($tool_def['binary'] ?? '');
    if ($bin === '') { echo json_encode(['ok'=>false,'error'=>'No binary configured'], JSON_UNESCAPED_UNICODE); exit; }

    // version_args is the part of the command after the binary. Default
    // is '--version' (POSIX standard); tool JSONs can override for
    // non-standard CLIs. We split on whitespace and escapeshellarg each
    // piece so users can write multi-arg tests like "info -v".
    $version_args = trim((string)($tool_def['version_args'] ?? '--version'));
    $args_escaped = '';
    if ($version_args !== '') {
        $parts = preg_split('/\s+/', $version_args);
        $args_escaped = ' ' . implode(' ', array_map('escapeshellarg', $parts));
    }
    $cmd = escapeshellarg($bin) . $args_escaped . ' 2>&1';
    $t0 = microtime(true);
    @exec($cmd, $out, $rc);
    $dt = round((microtime(true) - $t0) * 1000);
    $first = is_array($out) && count($out) ? $out[0] : '';

    echo json_encode([
        'ok'         => $rc === 0,
        'binary'     => $bin,
        'rc'         => $rc,
        'first_line' => $first,
        'latency_ms' => $dt,
        'cmd_used'   => trim($bin . ' ' . $version_args),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Action: migration_status — lets the UI poll for migration banner
//
// Returns {ok:true, migration_notify:true/false}. If the notify flag file
// exists, it is consumed (deleted) and the caller shows a one-time banner.
// =============================================================================
if ($action === 'migration_status') {
    $notify_f = $CD . '/.migration_v2_notify';
    $done_f   = $CD . '/.migration_v2_completed';
    $notify   = is_file($notify_f);
    if ($notify) @unlink($notify_f);
    echo json_encode([
        'ok'               => true,
        'migration_notify' => $notify,
        'migration_done'   => is_file($done_f),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false,'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);
