<?php
// =============================================================================
// capabilities.php — Cockpit universal capability registry
//
// Capabilities are cross-agent features: things any agent can use if enabled.
// Each capability has a manifest (CAP.json) and optional per-agent wiring.
//
// CAPABILITY TYPES:
//   tool_shim  — a local binary invoked via shell (ffmpeg, whisper, pandoc...)
//   mcp_server — an MCP server accessible to Claude and/or Gemini
//   api_call   — a remote API (Brave Search, HuggingFace inference...)
//   rag_search — search cockpit's own library/snippets/sources
//   builtin    — baked into cockpit itself (no external binary needed)
//
// STORAGE:
//   cockpit_data/capabilities/<id>/CAP.json   — manifest
//   cockpit_data/capabilities/<id>/README.md  — human-readable docs
//   cockpit_data/capabilities/project_caps.json — per-project state
//
// ACTIONS (GET):
//   ?action=list                          — all capabilities
//   ?action=get&id=X                      — one capability + readme
//   ?action=project_caps&project=X       — enabled/disabled for project
//   ?action=registry                      — suggested installable capabilities
//
// ACTIONS (POST):
//   {action:project_set, project, cap_id, state:enabled|disabled|default}
//   {action:create, id, name, description}
//   {action:delete, id}
//   {action:apply, project}  — write agent config fragments
//
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

// =============================================================================
// Paths
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'list') {
        $caps = [
            ['id'=>'web-search','name'=>'Web Search','description'=>'Search the web and pull real results into context.','builtin'=>true],
            ['id'=>'file-tools','name'=>'File Tools','description'=>'Read/write/edit local project files.','builtin'=>true],
        ];
        echo json_encode(['ok'=>true,'capabilities'=>$caps,'count'=>count($caps)]); exit;
    }
    ed_demo_stub();
}
$HOME = $PATHS['home'];
$COCKPIT_ROOT = $PATHS['projects_root'];

$CAP_DIR      = $CD . '/capabilities';
$PROJ_CAPS_F  = $CAP_DIR . '/project_caps.json';   // legacy per-project (kept, unused)
$GLOBAL_CAPS_F = $CAP_DIR . '/global_caps.json';   // { "<id>": true|false } global overrides

// Effective enablement (GLOBAL model): explicit override wins; otherwise built-ins
// default ON, user capabilities default OFF. Applies to every project AND free chats.
function cap_is_enabled(array $cap, array $globalMap): bool {
    $id = $cap['id'] ?? '';
    if (array_key_exists($id, $globalMap)) return (bool)$globalMap[$id];
    // A builtin may opt out of the on-by-default rule ('default_off'): some
    // builtins hand the agents something of the user's rather than something of
    // Cockpit's, and those must be chosen, not inherited silently.
    if (!empty($cap['default_off'])) return false;
    return !empty($cap['_builtin']);
}

if (!is_dir($CAP_DIR)) @mkdir($CAP_DIR, 0775, true);

// =============================================================================
// Built-in capabilities — always present, cannot be deleted
// =============================================================================
$BUILTINS = [
    [
        'id'          => 'rag_search',
        'name'        => 'RAG Search',
        'description' => 'Before each prompt, pull the best matching snippets, library notes and sources from this machine and put them in front of the agent (push-RAG). Off = nothing is injected; the %%LIB/SNIP/SRC%% markers still work on request.',
        'type'        => 'builtin',
        '_builtin'    => true,
        'implementations' => [
            'claude' => ['type' => 'builtin'],
            'gemini' => ['type' => 'builtin'],
            'ollama' => ['type' => 'builtin'],
        ],
    ],
    [
        // OFF by default, deliberately. A CLI agent Cockpit starts otherwise
        // inherits the whole personal Claude Code / Gemini config of whoever
        // runs the machine — hooks, plugins, skills, global memory. That was
        // found the hard way: a caveman-mode SessionStart hook rewrote every
        // Cockpit answer on this rig while Cockpit's own Mode/Style said
        // nothing of the sort, and the same hook class had already broken the
        // NDJSON parser in agent_loop. Isolated is the predictable default;
        // turn this on to deliberately share your own config with the agents.
        'id'          => 'inherit_cli_config',
        'name'        => 'Use my global CLI config',
        'description' => 'Let CLI agents started by Cockpit read your personal ~/.claude config — hooks, '
                       . 'plugins, skills, global memory. OFF (recommended) gives them an isolated '
                       . 'Cockpit-owned config, so only Cockpit shapes the answers; your login is used '
                       . 'either way, so you never sign in twice. Applies to Claude Code.',
        'type'        => 'builtin',
        '_builtin'    => true,
        'default_off' => true,
        'implementations' => [
            'claude' => ['type' => 'builtin'],
        ],
    ],
    [
        // Off by default: rendering and looking at pages costs time, and on an
        // agent without native image support every page becomes a separate
        // local vision call. Text extraction alone is right for most documents —
        // this is for the ones where it returns little or nothing.
        'id'          => 'pdf_vision',
        'name'        => 'PDF Vision',
        'description' => 'When a PDF is attached, also render its first pages as images so the agent can SEE charts, '
                       . 'diagrams and scans. Text extraction misses those entirely — a page that is one chart '
                       . 'extracts as an empty string.',
        'type'        => 'builtin',
        '_builtin'    => true,
        'default_off' => true,
        'implementations' => [
            'claude' => ['type' => 'builtin'],
            'gemini' => ['type' => 'builtin'],
            'ollama' => ['type' => 'builtin'],
        ],
    ],
    [
        'id'          => 'web_search',
        'name'        => 'Web Search',
        'description' => 'Search the web via Brave Search API (or DuckDuckGo fallback).',
        'type'        => 'builtin',
        '_builtin'    => true,
        'implementations' => [
            'claude' => ['type' => 'builtin'],
            'gemini' => ['type' => 'builtin'],
            'ollama' => ['type' => 'builtin'],
        ],
    ],
    [
        'id'          => 'ffmpeg',
        'name'        => 'FFmpeg',
        'description' => 'Audio/video conversion, extraction, and processing.',
        'type'        => 'tool_shim',
        '_builtin'    => true,
        'binary'      => 'ffmpeg',
        'implementations' => [
            'claude' => ['type' => 'tool_shim', 'command' => 'ffmpeg'],
            'gemini' => ['type' => 'tool_shim', 'command' => 'ffmpeg'],
            'ollama' => ['type' => 'tool_shim', 'command' => 'ffmpeg'],
        ],
    ],
    [
        'id'          => 'whisper',
        'name'        => 'Whisper (speech-to-text)',
        'description' => 'Transcribe audio files using whisper.cpp with GPU acceleration.',
        'type'        => 'tool_shim',
        '_builtin'    => true,
        'binary'      => 'whisper',
        'implementations' => [
            'claude' => ['type' => 'tool_shim', 'command' => 'whisper'],
            'gemini' => ['type' => 'tool_shim', 'command' => 'whisper'],
            'ollama' => ['type' => 'tool_shim', 'command' => 'whisper'],
        ],
    ],
    [
        'id'          => 'pandoc',
        'name'        => 'Pandoc (document conversion)',
        'description' => 'Convert between document formats: DOCX, PDF, HTML, Markdown, EPUB and more.',
        'type'        => 'tool_shim',
        '_builtin'    => true,
        'binary'      => 'pandoc',
        'implementations' => [
            'claude' => ['type' => 'tool_shim', 'command' => 'pandoc'],
            'gemini' => ['type' => 'tool_shim', 'command' => 'pandoc'],
            'ollama' => ['type' => 'tool_shim', 'command' => 'pandoc'],
        ],
    ],
    [
        'id'          => 'ollama_vision',
        'name'        => 'Vision (Ollama)',
        'description' => 'Describe, analyse and extract text from images using local vision models (gemma3:4b).',
        'type'        => 'tool_shim',
        '_builtin'    => true,
        'binary'      => 'ollama',
        'implementations' => [
            'claude' => ['type' => 'tool_shim', 'command' => 'ollama run gemma3:4b'],
            'gemini' => ['type' => 'tool_shim', 'command' => 'ollama run gemma3:4b'],
            'ollama' => ['type' => 'tool_shim', 'command' => 'ollama run gemma3:4b'],
        ],
    ],
    [
        'id'          => 'accumulator',
        'name'        => 'Accumulator',
        'description' => 'Extract reusable snippets and knowledge from PDF, DOCX, EPUB, HTML, TXT and CHM files.',
        'type'        => 'builtin',
        '_builtin'    => true,
        'implementations' => [
            'claude' => ['type' => 'builtin'],
            'gemini' => ['type' => 'builtin'],
            'ollama' => ['type' => 'builtin'],
        ],
    ],
    [
        'id'          => 'code_execution',
        'name'        => 'Code Execution',
        'description' => 'Run Pascal (fpc), PHP, Bash and other scripts locally and return output.',
        'type'        => 'tool_shim',
        '_builtin'    => true,
        'implementations' => [
            'claude' => ['type' => 'tool_shim', 'command' => 'bash'],
            'gemini' => ['type' => 'tool_shim', 'command' => 'bash'],
            'ollama' => ['type' => 'tool_shim', 'command' => 'bash'],
        ],
    ],
    [
        'id'          => 'libre_translate',
        'name'        => 'LibreTranslate',
        'description' => 'Local offline translation service for subtitles and text.',
        'type'        => 'api_call',
        '_builtin'    => true,
        'endpoint'    => 'http://localhost:5000',
        'implementations' => [
            'claude' => ['type' => 'api_call', 'endpoint' => 'http://localhost:5000'],
            'gemini' => ['type' => 'api_call', 'endpoint' => 'http://localhost:5000'],
            'ollama' => ['type' => 'api_call', 'endpoint' => 'http://localhost:5000'],
        ],
    ],
];

// =============================================================================
// Helpers
// =============================================================================
function load_json_cap(string $path, $default = []) {
    if (!is_file($path)) return $default;
    $j = json_decode((string)file_get_contents($path), true);
    return is_array($j) ? $j : $default;
}

function save_json_cap(string $path, $data): bool {
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) return false;
    @chmod($tmp, 0664);
    if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
    return true;
}

// Check if a binary is available on the system
function binary_available(string $bin): bool {
    $which = trim((string)shell_exec('which ' . escapeshellarg($bin) . ' 2>/dev/null'));
    return $which !== '';
}

// Load user-created capabilities from disk
function load_user_caps(string $CAP_DIR): array {
    $caps = [];
    foreach (glob($CAP_DIR . '/*/CAP.json') ?: [] as $f) {
        $j = load_json_cap($f);
        if (!$j || empty($j['id'])) continue;
        $j['_builtin'] = false;
        $caps[] = $j;
    }
    return $caps;
}

// Merge builtins + user caps, annotate availability
function all_caps(array $builtins, string $CAP_DIR): array {
    $user = load_user_caps($CAP_DIR);
    $all  = array_merge($builtins, $user);

    // Annotate each with binary availability
    foreach ($all as &$cap) {
        if (!empty($cap['binary'])) {
            $cap['_available'] = binary_available($cap['binary']);
        } else {
            $cap['_available'] = true;
        }
    }
    unset($cap);
    return $all;
}

// =============================================================================
// Routing
// =============================================================================
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$in     = [];
$action = '';

if ($method === 'POST') {
    $in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
    // Action may arrive in the JSON body OR the query string (several callers,
    // e.g. capToggle, POST to ?action=… with the params in the body). Accept both.
    $action = trim((string)($in['action'] ?? $_GET['action'] ?? ''));
} else {
    $action = trim((string)($_GET['action'] ?? 'list'));
}

// =============================================================================
// ACTION: list
// =============================================================================
if ($action === 'list') {
    $caps = all_caps($BUILTINS, $CAP_DIR);
    echo json_encode(['ok' => true, 'capabilities' => $caps, 'count' => count($caps)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: get — return full detail for one capability
// =============================================================================
if ($action === 'get') {
    $id   = trim((string)($_GET['id'] ?? ''));
    $caps = all_caps($BUILTINS, $CAP_DIR);

    $cap = null;
    foreach ($caps as $c) { if ($c['id'] === $id) { $cap = $c; break; } }

    if (!$cap) { echo json_encode(['ok'=>false,'error'=>'Capability not found: '.$id], JSON_UNESCAPED_UNICODE); exit; }

    // Load README if present
    $readme_f = $CAP_DIR . '/' . $id . '/README.md';
    $readme   = is_file($readme_f) ? file_get_contents($readme_f) : '';

    echo json_encode(['ok'=>true, 'manifest'=>$cap, 'readme'=>$readme], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: get_raw — return the raw CAP.json text for a USER capability (for the
// editor). Built-ins are read-only and rejected.
// =============================================================================
if ($action === 'get_raw') {
    $id = preg_replace('/[^a-z0-9_\-]/', '', strtolower(trim((string)($_GET['id'] ?? ''))));
    if (!$id) { echo json_encode(['ok'=>false,'error'=>'Missing ID'], JSON_UNESCAPED_UNICODE); exit; }
    foreach ($BUILTINS as $b) {
        if ($b['id'] === $id) { echo json_encode(['ok'=>false,'error'=>'Built-in capabilities are read-only'], JSON_UNESCAPED_UNICODE); exit; }
    }
    $f = $CAP_DIR . '/' . $id . '/CAP.json';
    if (!is_file($f)) { echo json_encode(['ok'=>false,'error'=>'CAP.json not found for '.$id], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true, 'id'=>$id, 'content'=>file_get_contents($f)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: save_raw — write edited CAP.json for a USER capability. Validates JSON,
// keeps the manifest id pinned to the folder, rejects built-ins & path escapes.
// =============================================================================
if ($action === 'save_raw') {
    $id      = preg_replace('/[^a-z0-9_\-]/', '', strtolower(trim((string)($in['id'] ?? ''))));
    $content = (string)($in['content'] ?? '');
    if (!$id) { echo json_encode(['ok'=>false,'error'=>'Missing ID'], JSON_UNESCAPED_UNICODE); exit; }
    foreach ($BUILTINS as $b) {
        if ($b['id'] === $id) { echo json_encode(['ok'=>false,'error'=>'Built-in capabilities are read-only'], JSON_UNESCAPED_UNICODE); exit; }
    }
    $parsed = json_decode($content, true);
    if (!is_array($parsed)) {
        echo json_encode(['ok'=>false,'error'=>'Invalid JSON: '.json_last_error_msg()], JSON_UNESCAPED_UNICODE); exit;
    }
    // The manifest id must match the folder — prevents renaming/relocating via edit.
    if (isset($parsed['id']) && $parsed['id'] !== $id) {
        echo json_encode(['ok'=>false,'error'=>'Manifest "id" must stay "'.$id.'"'], JSON_UNESCAPED_UNICODE); exit;
    }
    $cap_dir = $CAP_DIR . '/' . $id;
    $real    = realpath($cap_dir);
    $rootR   = realpath($CAP_DIR);
    if ($real === false || $rootR === false || strpos($real, $rootR) !== 0 || !is_dir($real)) {
        echo json_encode(['ok'=>false,'error'=>'Capability not found: '.$id], JSON_UNESCAPED_UNICODE); exit;
    }
    // Preserve the user's exact (already-valid) text rather than re-encoding.
    if (file_put_contents($real . '/CAP.json', $content) === false) {
        echo json_encode(['ok'=>false,'error'=>'Write failed (permissions on '.$cap_dir.')'], JSON_UNESCAPED_UNICODE); exit;
    }
    echo json_encode(['ok'=>true, 'id'=>$id], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: project_caps — return enabled/disabled state for a project
// =============================================================================
if ($action === 'project_caps') {
    $project = trim((string)($_GET['project'] ?? 'default'));
    $state   = load_json_cap($PROJ_CAPS_F, []);
    $proj    = $state[$project] ?? ['enabled'=>[], 'disabled'=>[]];
    echo json_encode(['ok'=>true, 'enabled'=>$proj['enabled']??[], 'disabled'=>$proj['disabled']??[]], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: project_set — toggle a capability for a project
// =============================================================================
if ($action === 'project_set') {
    $project = trim((string)($in['project'] ?? 'default'));
    $cap_id  = trim((string)($in['cap_id']  ?? ''));
    $new_state = trim((string)($in['state'] ?? 'default'));

    if (!$cap_id) { echo json_encode(['ok'=>false,'error'=>'Missing cap_id'], JSON_UNESCAPED_UNICODE); exit; }

    $state = load_json_cap($PROJ_CAPS_F, []);
    if (!isset($state[$project])) $state[$project] = ['enabled'=>[],'disabled'=>[]];

    // Remove from both lists first
    $state[$project]['enabled']  = array_values(array_filter($state[$project]['enabled'],  fn($x) => $x !== $cap_id));
    $state[$project]['disabled'] = array_values(array_filter($state[$project]['disabled'], fn($x) => $x !== $cap_id));

    // Add to appropriate list
    if ($new_state === 'enabled')  $state[$project]['enabled'][]  = $cap_id;
    if ($new_state === 'disabled') $state[$project]['disabled'][] = $cap_id;

    save_json_cap($PROJ_CAPS_F, $state);
    echo json_encode(['ok'=>true, 'cap_id'=>$cap_id, 'state'=>$new_state], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: global_caps — return the global on/off map + computed effective state
// for every capability (the GLOBAL enablement model: one switch, all projects,
// all suppliers, free chats included).
// =============================================================================
if ($action === 'global_caps') {
    $map  = load_json_cap($GLOBAL_CAPS_F, []);
    $caps = all_caps($BUILTINS, $CAP_DIR);
    $effective = [];
    foreach ($caps as $c) { $effective[$c['id']] = cap_is_enabled($c, $map); }
    echo json_encode(['ok'=>true, 'overrides'=>(object)$map, 'enabled'=>(object)$effective], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: global_set — flip one capability ON/OFF globally.
// body: { cap_id, enabled: bool }
// =============================================================================
if ($action === 'global_set') {
    $cap_id  = trim((string)($in['cap_id'] ?? ''));
    $enabled = !empty($in['enabled']);
    if (!$cap_id) { echo json_encode(['ok'=>false,'error'=>'Missing cap_id'], JSON_UNESCAPED_UNICODE); exit; }
    $map = load_json_cap($GLOBAL_CAPS_F, []);
    $map[$cap_id] = $enabled;
    save_json_cap($GLOBAL_CAPS_F, $map);
    echo json_encode(['ok'=>true, 'cap_id'=>$cap_id, 'enabled'=>$enabled], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: create — create a new user capability
// =============================================================================
if ($action === 'create') {
    $id   = preg_replace('/[^a-z0-9_\-]/', '', strtolower(trim((string)($in['id'] ?? ''))));
    $name = trim((string)($in['name'] ?? ''));
    $desc = trim((string)($in['description'] ?? ''));
    // A3: optional wiring fields from the creation form
    $cap_type = trim((string)($in['cap_type'] ?? 'tool_shim'));
    if (!in_array($cap_type, ['tool_shim','mcp_server','prompt_shim'], true)) $cap_type = 'tool_shim';
    $command  = trim((string)($in['command'] ?? ''));
    $args_raw = $in['args'] ?? [];
    if (is_string($args_raw)) {
        // accept space- or newline-separated string
        $args_raw = preg_split('/\s+/', trim($args_raw)) ?: [];
    }
    $args = is_array($args_raw) ? array_values(array_filter(array_map('strval', $args_raw), fn($s)=>$s!=='')) : [];

    if (!$id)   { echo json_encode(['ok'=>false,'error'=>'Missing or invalid ID'], JSON_UNESCAPED_UNICODE); exit; }
    if (!$name) { echo json_encode(['ok'=>false,'error'=>'Missing name'], JSON_UNESCAPED_UNICODE); exit; }

    // Check not a builtin
    foreach ($BUILTINS as $b) {
        if ($b['id'] === $id) { echo json_encode(['ok'=>false,'error'=>'ID conflicts with a built-in capability'], JSON_UNESCAPED_UNICODE); exit; }
    }

    $cap_dir = $CAP_DIR . '/' . $id;
    if (!is_dir($cap_dir)) @mkdir($cap_dir, 0775, true);

    // Build implementations array if a command was supplied
    $implementations = [];
    if ($command !== '') {
        $implementations[] = [
            'platform' => 'linux',
            'command'  => $command,
            'args'     => $args,
        ];
    }

    $manifest = [
        'id'          => $id,
        'name'        => $name,
        'description' => $desc,
        'type'        => $cap_type,
        '_builtin'    => false,
        'implementations' => $implementations,
    ];
    save_json_cap($cap_dir . '/CAP.json', $manifest);

    // Create a README template
    $cmdline = $command !== '' ? ($command . ' ' . implode(' ', $args)) : '(none yet)';
    $readme = "# {$name}\n\n{$desc}\n\n## Setup\n\nType: {$cap_type}\nCommand: {$cmdline}\n\nEdit `CAP.json` to adjust implementations.\n";
    file_put_contents($cap_dir . '/README.md', $readme);

    echo json_encode(['ok'=>true,'id'=>$id,'path'=>$cap_dir,'wired'=>($command!=='')], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: delete — delete a user capability
// =============================================================================
if ($action === 'delete') {
    $id = preg_replace('/[^a-z0-9_\-]/', '', trim((string)($_GET['id'] ?? $in['id'] ?? '')));
    if (!$id) { echo json_encode(['ok'=>false,'error'=>'Missing ID'], JSON_UNESCAPED_UNICODE); exit; }

    // Cannot delete builtins
    foreach ($BUILTINS as $b) {
        if ($b['id'] === $id) { echo json_encode(['ok'=>false,'error'=>'Cannot delete built-in capability'], JSON_UNESCAPED_UNICODE); exit; }
    }

    $cap_dir = $CAP_DIR . '/' . $id;
    if (!is_dir($cap_dir)) { echo json_encode(['ok'=>false,'error'=>'Capability not found'], JSON_UNESCAPED_UNICODE); exit; }

    // Delete directory
    $iter = new RecursiveIteratorIterator(
        new RecursiveDirectoryIterator($cap_dir, RecursiveDirectoryIterator::SKIP_DOTS),
        RecursiveIteratorIterator::CHILD_FIRST
    );
    foreach ($iter as $f) { $f->isDir() ? @rmdir($f) : @unlink($f); }
    @rmdir($cap_dir);

    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: registry — suggest installable capabilities
// =============================================================================
if ($action === 'registry') {
    $suggestions = [
        ['id'=>'brave_search',    'name'=>'Brave Search API',       'desc'=>'Web search via Brave Search REST API (needs API key)',             'pkg'=>'n/a — set BRAVE_API_KEY in workers.php'],
        ['id'=>'tesseract',       'name'=>'Tesseract OCR',          'desc'=>'Extract text from images and scanned PDFs',                        'pkg'=>'sudo nala install tesseract-ocr'],
        ['id'=>'piper_tts',       'name'=>'Piper TTS',              'desc'=>'Local text-to-speech synthesis',                                   'pkg'=>'https://github.com/rhasspy/piper'],
        ['id'=>'stable_diffusion','name'=>'Stable Diffusion',       'desc'=>'Local image generation via stable-diffusion-cpp',                  'pkg'=>'https://github.com/leejet/stable-diffusion.cpp'],
        ['id'=>'gensrt',          'name'=>'GenSRT (subtitle gen)',   'desc'=>'Generate and translate subtitles using whisper.cpp + LibreTranslate','pkg'=>'~/scripts/gensrt/'],
        ['id'=>'fpc_compiler',    'name'=>'Free Pascal Compiler',    'desc'=>'Compile FPC/Lazarus Pascal source files',                          'pkg'=>'sudo nala install fpc'],
        ['id'=>'git',             'name'=>'Git',                    'desc'=>'Version control operations on source projects',                     'pkg'=>'sudo nala install git'],
        ['id'=>'imagemagick',     'name'=>'ImageMagick',            'desc'=>'Image resizing, conversion and manipulation',                       'pkg'=>'sudo nala install imagemagick'],
    ];
    echo json_encode(['ok'=>true, 'suggestions'=>$suggestions], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: apply — write agent configuration fragments
// =============================================================================
if ($action === 'apply') {
    $project = trim((string)($in['project'] ?? $_GET['project'] ?? 'default'));
    $state   = load_json_cap($PROJ_CAPS_F, []);
    $proj    = $state[$project] ?? ['enabled'=>[],'disabled'=>[]];

    $all_caps  = all_caps($BUILTINS, $CAP_DIR);

    // GLOBAL enablement: a single on/off map decides for ALL projects and free
    // chats. (Per-project $proj state is ignored now — kept only for back-compat.)
    $globalMap = load_json_cap($GLOBAL_CAPS_F, []);
    $effective = [];
    foreach ($all_caps as $cap) {
        if (cap_is_enabled($cap, $globalMap)) $effective[] = $cap;
    }

    // Count by type
    $counts = [
        'enabled_count'    => count($effective),
        'claude_mcp_count' => 0,
        'gemini_mcp_count' => 0,
        'claude_skill_count' => 0,
        'ollama_shim_count' => 0,
    ];

    // Type matchers — manifests use "mcp"/"tool-shim"/"claude-skill"; the create
    // form historically wrote "mcp_server"/"tool_shim". Accept all spellings.
    $is_mcp   = fn($t) => in_array($t, ['mcp','mcp_server','mcp-server'], true);
    $is_shim  = fn($t) => in_array($t, ['tool-shim','tool_shim'], true);
    $is_skill = fn($t) => in_array($t, ['claude-skill','claude_skill'], true);

    // ── Stage the actual agent configs that agent_loop.sh consumes ───────────
    // agent_loop reads $PROJECT_DIR/.cockpit_caps/{claude_mcp.json, gemini_mcp.json,
    // ollama_system_prompt.txt}. Build them here from the effective capability set.
    $proj_name = ($project === '' ? '_standalone' : $project);
    $proj_dir  = $COCKPIT_ROOT . '/' . $proj_name;
    $stage     = $proj_dir . '/.cockpit_caps';
    @mkdir($stage, 0775, true);

    $resolve = function($v) use ($proj_dir, $HOME) {
        return str_replace(['${PROJECT_DIR}', '${HOME}'], [$proj_dir, $HOME], (string)$v);
    };
    $mk_server = function($impl) use ($resolve) {
        $entry = [
            'command' => $resolve($impl['command'] ?? ''),
            'args'    => array_values(array_map($resolve, $impl['args'] ?? [])),
        ];
        // Only pass real env values (skip placeholder markers like "optional").
        if (!empty($impl['env']) && is_array($impl['env'])) {
            $env = [];
            foreach ($impl['env'] as $k => $v) {
                if ($v !== '' && strtolower((string)$v) !== 'optional') $env[$k] = $resolve($v);
            }
            if ($env) $entry['env'] = $env;
        }
        return $entry;
    };

    $claudeServers = [];
    $geminiServers = [];
    $ollamaPrompt  = '';
    foreach ($effective as $cap) {
        $impls = $cap['implementations'] ?? [];
        $id    = $cap['id'];
        $cImpl = $impls['claude'] ?? null;
        $gImpl = $impls['gemini'] ?? null;
        $oImpl = $impls['ollama'] ?? null;

        if ($cImpl && $is_mcp($cImpl['type'] ?? '')) { $claudeServers[$id] = $mk_server($cImpl); $counts['claude_mcp_count']++; }
        if ($gImpl && $is_mcp($gImpl['type'] ?? '')) { $geminiServers[$id] = $mk_server($gImpl); $counts['gemini_mcp_count']++; }
        if ($cImpl && $is_skill($cImpl['type'] ?? '')) $counts['claude_skill_count']++;
        if ($oImpl && $is_shim($oImpl['type'] ?? '') && !empty($oImpl['system_prompt_addition'])) {
            $ollamaPrompt .= '- ' . trim($oImpl['system_prompt_addition']) . "\n";
            $counts['ollama_shim_count']++;
        }
    }

    // Always write (even empty) so toggling a capability OFF clears it next run.
    $jflags = JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE;
    @file_put_contents($stage . '/claude_mcp.json', json_encode(['mcpServers' => (object)$claudeServers], $jflags, JSON_UNESCAPED_UNICODE));
    @file_put_contents($stage . '/gemini_mcp.json', json_encode(['mcpServers' => (object)$geminiServers], $jflags, JSON_UNESCAPED_UNICODE));
    @file_put_contents($stage . '/ollama_system_prompt.txt',
        $ollamaPrompt === '' ? '' : ("[Capabilities available — use these markers when helpful]\n" . $ollamaPrompt));

    // Also keep the per-project manifest (stats / introspection).
    $manifest_path = $CD . '/projects/' . $proj_name . '/active_capabilities.json';
    @mkdir(dirname($manifest_path), 0775, true);
    save_json_cap($manifest_path, [
        'project'   => $proj_name,
        'applied_at'=> date('c'),
        'capabilities' => array_column($effective, null, 'id'),
    ]);

    echo json_encode(array_merge(['ok'=>true, 'staged_to'=>$stage], $counts), JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Catch-all
// =============================================================================
echo json_encode(['ok'=>false,'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);
