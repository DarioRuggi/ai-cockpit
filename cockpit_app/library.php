<?php
if (!function_exists('mb_strlen'))  { function mb_strlen($s, $e=null)  { return strlen($s); } }
if (!function_exists('mb_substr'))  { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
// =============================================================================
// library.php — Cockpit RAG backend
//
// Serves the right-panel tabs: snippets, library, sources, code.
// Also provides keyword search across all stores for RAG injection.
//
// ACTIONS (GET)
//   ?action=list&kind=snippets|library|sources|code&project=X
//   ?action=search&q=query&kind=all|snippets|library|sources&project=X&limit=10
//   ?action=read_content&kind=X&scope=global|project&id=X&project=X
//   ?action=get_paths                — returns configured folder paths
//
// ACTIONS (POST JSON body)
//   {action:add,          kind, project, scope, item, content}
//   {action:edit,         kind, project, scope, id, item}
//   {action:delete,       kind, project, scope, id}
//   {action:move,         kind, project, id, from, to}
//   {action:rescan,       kind, project, scope}   — scan folder paths, auto-index files
//   {action:set_paths,    paths:{snippets:[...], library:[...], sources:[...]}}
//   {action:upload_zip,   kind, project, scope, filename, data_b64, title}
//   {action:proposal_act, id, act:'approve'|'reject', target_scope}
//   {action:add_proposal, kind, proposer, project, payload:{title,lang,content,notes}}
//
// ACTIONS (GET — proposals)
//   ?action=proposals     — return pending proposals from proposals.json
//
// STORAGE LAYOUT
//   cockpit_data/
//     library_index.json          — global index (snippets, library, sources entries)
//     library_paths.json          — user-configured folder scan paths
//     proposals.json              — pending agent proposals (flat array)
//     projects/<name>/
//       library_index.json        — project-scoped index
//     snippets/                   — Accumulator JSON snippets (read-only here)
//     knowledge/                  — Accumulator JSON knowledge (read-only here)
//     code_blocks/                — auto-extracted code blocks from agent responses
//     sources/                    — uploaded source files / zip extracts
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
require_once __DIR__ . '/text_clean.php';  // book_clean_text() — book text is cleaned on READ (see that file)
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === 'list') {
        $kind = trim((string)($_GET['kind'] ?? ''));
        $demoItems = [
            'snippets' => [
                ['id'=>'snip-1','title'=>'Debounce helper','lang'=>'javascript','purpose'=>'rate-limit rapid calls','notes'=>'From: personal notes','scope'=>'global','source'=>'accumulator','file'=>'debounce.json','size'=>240,'updated'=>'2026-06-12'],
                ['id'=>'snip-2','title'=>'Retry with backoff','lang'=>'python','purpose'=>'resilient HTTP calls','notes'=>'From: personal notes','scope'=>'global','source'=>'accumulator','file'=>'retry.json','size'=>410,'updated'=>'2026-06-10'],
            ],
            'library' => [
                ['id'=>'lib-1','title'=>'JWT vs session cookies','location'=>'','kind'=>'knowledge','notes'=>'auth comparison notes','scope'=>'global','source'=>'accumulator','updated'=>'2026-06-14'],
                ['id'=>'lib-2','title'=>'OAuth2 PKCE flow','location'=>'','kind'=>'knowledge','notes'=>'full flow diagram','scope'=>'global','source'=>'accumulator','updated'=>'2026-06-11'],
            ],
            'sources' => [
                ['id'=>'src-1','title'=>'Project README','path'=>'/project/README.md','scope'=>'project','updated'=>'2026-06-09'],
            ],
            'code' => [
                ['id'=>'code-1','title'=>'auth.php local login','lang'=>'php','notes'=>'bcrypt password_verify() pattern','updated'=>'2026-06-08'],
            ],
        ];
        $items = $demoItems[$kind] ?? [];
        echo json_encode(['ok'=>true,'items'=>$items,'count'=>count($items)]); exit;
    }
    if ($__demoAction === 'search') {
        echo json_encode(['ok'=>true,'results'=>[
            ['title'=>'JWT vs session cookies','snippet'=>'Comparison notes on stateless vs stateful auth...','kind'=>'knowledge'],
        ]]); exit;
    }
    ed_demo_stub();
}

$SNIPPETS_DIR   = $CD . '/snippets';       // Accumulator snippets (JSON)
$KNOWLEDGE_DIR  = $CD . '/knowledge';      // Accumulator knowledge (JSON)
$CODE_DIR       = $CD . '/code_blocks';    // auto-extracted code blocks
$SOURCES_DIR    = $CD . '/sources';        // uploaded source files
$GLOBAL_IDX     = $CD . '/library_index.json';
$PATHS_F        = $CD . '/library_paths.json';
$PROJECTS_DIR   = $CD . '/projects';
$EMBED_F        = $CD . '/embeddings.json';   // C4: vector store sidecar
$LIBTEXT_DIR    = $CD . '/library_text';      // extracted text cache for library items

// Extract plain text from a library file (book/article/etc) for search+embedding.
// Uses pdftotext / pandoc when available; reads text files directly. Capped.
function lib_extract_text(string $path, string $ext, int $cap = 300000): string {
    $ext = strtolower($ext);
    if (!is_file($path) || !is_readable($path)) return '';
    $text = '';
    if (in_array($ext, ['txt','md','markdown','html','htm','csv','json','xml','log'], true)) {
        $text = (string)@file_get_contents($path, false, null, 0, $cap + 1);
    } elseif ($ext === 'pdf' && is_file('/usr/bin/pdftotext')) {
        $out = []; @exec('pdftotext -q ' . escapeshellarg($path) . ' - 2>/dev/null', $out);
        $text = implode("\n", $out);
    } elseif (in_array($ext, ['docx','odt','epub','rtf','fb2'], true) && is_file('/usr/bin/pandoc')) {
        $out = []; @exec('pandoc ' . escapeshellarg($path) . ' -t plain 2>/dev/null', $out);
        $text = implode("\n", $out);
    }
    if (strlen($text) > $cap) $text = substr($text, 0, $cap);
    return $text;
}

foreach ([$CODE_DIR, $SOURCES_DIR, $PROJECTS_DIR, $LIBTEXT_DIR] as $d) {
    if (!is_dir($d)) @mkdir($d, 0775, true);
}

// =============================================================================
// C4 — Semantic search helpers (no Python: embeddings via Ollama, math in PHP)
// =============================================================================
define('OLLAMA_EMBED_URL', 'http://127.0.0.1:11434/api/embeddings');
define('EMBED_MODEL', 'nomic-embed-text');

// Get an embedding vector for text via Ollama. Returns array<float> or null.
function embed_text(string $text): ?array {
    $text = trim($text);
    if ($text === '') return null;
    // Cap input — embedding models have context limits; 8000 chars is plenty
    if (mb_strlen($text) > 8000) $text = mb_substr($text, 0, 8000);
    $payload = json_encode(['model' => EMBED_MODEL, 'prompt' => $text], JSON_UNESCAPED_UNICODE);
    $ch = curl_init(OLLAMA_EMBED_URL);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_TIMEOUT        => 30,
        CURLOPT_CONNECTTIMEOUT => 5,
    ]);
    $resp = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($code !== 200 || !$resp) return null;
    $j = json_decode($resp, true);
    if (!is_array($j) || empty($j['embedding']) || !is_array($j['embedding'])) return null;
    return $j['embedding'];
}

// Cosine similarity between two equal-length vectors.
function cosine_sim(array $a, array $b): float {
    $n = min(count($a), count($b));
    if ($n === 0) return 0.0;
    $dot = 0.0; $na = 0.0; $nb = 0.0;
    for ($i = 0; $i < $n; $i++) {
        $dot += $a[$i] * $b[$i];
        $na  += $a[$i] * $a[$i];
        $nb  += $b[$i] * $b[$i];
    }
    if ($na <= 0 || $nb <= 0) return 0.0;
    return $dot / (sqrt($na) * sqrt($nb));
}

// =============================================================================
// Helpers
// =============================================================================
function load_json(string $path, $default = []) {
    if (!is_file($path)) return $default;
    $j = json_decode((string)file_get_contents($path), true);
    return is_array($j) ? $j : $default;
}

function save_json(string $path, $data): bool {
    // Atomic write with .tmp + rename to prevent partial-write corruption.
    $dir = dirname($path);
    if (!is_dir($dir)) @mkdir($dir, 0775, true);
    $tmp = $path . '.tmp';
    $ok = @file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    if ($ok === false) return false;
    @chmod($tmp, 0664);
    if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
    return true;
}

function make_id(): string {
    return date('Ymd_His') . '_' . substr(bin2hex(random_bytes(3)), 0, 6);
}

// Get the index file path for a given scope/project
function idx_path(string $scope, string $project, string $PROJECTS_DIR, string $GLOBAL_IDX): string {
    if ($scope === 'project' && $project && $project !== '_standalone') {
        return $PROJECTS_DIR . '/' . $project . '/library_index.json';
    }
    return $GLOBAL_IDX;
}

// Load configured scan paths
function load_paths(string $PATHS_F): array {
    $defaults = ['snippets' => [], 'library' => [], 'sources' => []];
    $saved = load_json($PATHS_F, []);
    return array_merge($defaults, $saved);
}

// Simple keyword scorer — returns 0..100
function keyword_score(array $item, string $q): int {
    if ($q === '') return 0;
    $words  = preg_split('/\s+/', strtolower(trim($q)));
    $haystack = strtolower(implode(' ', array_filter([
        $item['title'] ?? $item['name'] ?? '',
        $item['purpose'] ?? '',
        $item['language'] ?? $item['lang'] ?? '',
        $item['notes'] ?? '',
        $item['from_book'] ?? '',
        $item['book_slug'] ?? '',
        implode(' ', $item['tags'] ?? []),
    ])));
    // The body too: a snippet's code, a library note's text, a source file — the
    // metadata alone never matched the fact the person was looking for (QA, b87).
    // Capped so a book does not dominate; a body hit scores below a title hit.
    $body = (string)($item['content'] ?? '');
    if ($body === '' && !empty($item['file_path']) && is_file($item['file_path'])) $body = (string)@file_get_contents($item['file_path'], false, null, 0, 50000);
    $body = strtolower(substr($body, 0, 50000));
    $score = 0;
    foreach ($words as $w) {
        if ($w === '') continue;
        if (strpos($haystack, $w) !== false) $score += 20;
        // Exact word boundary match scores higher
        if (preg_match('/\b' . preg_quote($w, '/') . '\b/', $haystack)) $score += 10;
        elseif ($body !== '' && strpos($body, $w) !== false) $score += 8;
    }
    return min(100, $score);
}

// =============================================================================
// Determine action
// =============================================================================
$method  = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$action  = '';
$in      = [];

if ($method === 'POST') {
    $in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
    // Accept action from body OR query string (Deep Search posts ?action=… with empty body)
    $action = trim((string)($in['action'] ?? $_GET['action'] ?? ''));
    // The agent loop's names for the same thing (crud_cli.php / crud_executor.sh send action proposal_add + propose_kind; the page says add_proposal + kind).
    if ($action === 'proposal_add') { $action = 'add_proposal'; if (!isset($in['kind']) && isset($in['propose_kind'])) $in['kind'] = $in['propose_kind']; }
} else {
    $action = trim((string)($_GET['action'] ?? 'list'));
}

$project = trim((string)($_GET['project'] ?? $in['project'] ?? ''));
$scope   = trim((string)($_GET['scope']   ?? $in['scope']   ?? 'global'));

// =============================================================================
// ACTION: get_paths
// =============================================================================
if ($action === 'get_paths') {
    echo json_encode(['ok' => true, 'paths' => load_paths($PATHS_F)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: set_paths
// =============================================================================
if ($action === 'set_paths') {
    $paths = $in['paths'] ?? [];
    if (!is_array($paths)) { echo json_encode(['ok'=>false,'error'=>'Invalid paths'], JSON_UNESCAPED_UNICODE); exit; }
    // Validate: each must be an array of strings
    $clean = ['snippets'=>[], 'library'=>[], 'sources'=>[]];
    foreach (['snippets','library','sources'] as $k) {
        if (!empty($paths[$k]) && is_array($paths[$k])) {
            foreach ($paths[$k] as $p) {
                $p = trim((string)$p);
                if ($p !== '') $clean[$k][] = $p;
            }
        }
    }
    save_json($PATHS_F, $clean);
    echo json_encode(['ok' => true, 'paths' => $clean], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: list — return items for a panel
// =============================================================================
if ($action === 'list') {
    $kind = trim((string)($_GET['kind'] ?? ''));
    $items = [];

    if ($kind === 'snippets') {
        // 1. Accumulator snippets (global, read-only)
        foreach (glob($SNIPPETS_DIR . '/*.json') ?: [] as $f) {
            $j = load_json($f);
            if (!$j || empty($j['id'])) continue;
            $items[] = [
                'id'       => $j['id'],
                'title'    => $j['name'] ?? 'Untitled',
                'lang'     => $j['language'] ?? '',
                'purpose'  => $j['purpose'] ?? '',
                'notes'    => 'From: ' . ($j['from_book'] ?? ''),
                'scope'    => 'global',
                'source'   => 'accumulator',
                'file'     => basename($f),
                'size'     => strlen($j['source_code'] ?? ''),
                'updated'  => $j['extracted_at'] ?? '',
            ];
        }
        // 2. User index entries (global + project)
        foreach (['global', 'project'] as $sc) {
            $idx = load_json(idx_path($sc, $project, $PROJECTS_DIR, $GLOBAL_IDX));
            foreach (($idx['snippets'] ?? []) as $entry) {
                $entry['scope'] = $sc;
                $items[] = $entry;
            }
        }

    } elseif ($kind === 'library') {
        // 1. Accumulator knowledge items
        foreach (glob($KNOWLEDGE_DIR . '/*.json') ?: [] as $f) {
            $j = load_json($f);
            if (!$j || empty($j['id'])) continue;
            $items[] = [
                'id'       => $j['id'],
                'title'    => $j['name'] ?? 'Untitled',
                'location' => '',
                'kind'     => 'knowledge',
                'notes'    => ($j['purpose'] ?? '') . ' | From: ' . ($j['from_book'] ?? ''),
                'scope'    => 'global',
                'source'   => 'accumulator',
                'updated'  => $j['extracted_at'] ?? '',
            ];
        }
        // 2. User-registered library paths/URLs
        foreach (['global', 'project'] as $sc) {
            $idx = load_json(idx_path($sc, $project, $PROJECTS_DIR, $GLOBAL_IDX));
            foreach (($idx['library'] ?? []) as $entry) {
                $entry['scope'] = $sc;
                $items[] = $entry;
            }
        }

    } elseif ($kind === 'sources') {
        foreach (['global', 'project'] as $sc) {
            $idx = load_json(idx_path($sc, $project, $PROJECTS_DIR, $GLOBAL_IDX));
            foreach (($idx['sources'] ?? []) as $entry) {
                $entry['scope'] = $sc;
                $items[] = $entry;
            }
        }

    } elseif ($kind === 'code') {
        // Auto-extracted code blocks — stored as individual files in code_blocks/
        foreach (glob($CODE_DIR . '/*.json') ?: [] as $f) {
            $j = load_json($f);
            if (!$j) continue;
            $items[] = $j;
        }
    }

    // Sort by updated desc
    usort($items, fn($a,$b) => strcmp($b['updated']??'', $a['updated']??''));
    echo json_encode(['ok' => true, 'items' => $items, 'count' => count($items)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: search — keyword RAG search across all stores
// =============================================================================
if ($action === 'search') {
    $q     = trim((string)($_GET['q'] ?? $in['q'] ?? ''));
    $kind  = trim((string)($_GET['kind'] ?? 'all'));
    $limit = max(1, min(20, (int)($_GET['limit'] ?? 5)));

    if ($q === '') { echo json_encode(['ok'=>false,'error'=>'Missing query'], JSON_UNESCAPED_UNICODE); exit; }

    $results = [];

    // Search Accumulator snippets
    if (in_array($kind, ['all','snippets'])) {
        foreach (glob($SNIPPETS_DIR . '/*.json') ?: [] as $f) {
            $j = load_json($f);
            if (!$j) continue;
            $item = [
                'kind'     => 'snippet',
                'id'       => $j['id'] ?? '',
                'title'    => $j['name'] ?? '',
                'language' => $j['language'] ?? '',
                'purpose'  => $j['purpose'] ?? '',
                'content'  => $j['source_code'] ?? '',
                'from_book'=> $j['from_book'] ?? '',
                'scope'    => 'global',
                'source'   => 'accumulator',
            ];
            $score = keyword_score($item, $q);
            if ($score > 0) $results[] = array_merge($item, ['score' => $score]);
        }
    }

    // Search Accumulator knowledge
    if (in_array($kind, ['all','library'])) {
        foreach (glob($KNOWLEDGE_DIR . '/*.json') ?: [] as $f) {
            $j = load_json($f);
            if (!$j) continue;
            $item = [
                'kind'     => 'knowledge',
                'id'       => $j['id'] ?? '',
                'title'    => $j['name'] ?? '',
                'language' => $j['language'] ?? '',
                'purpose'  => $j['purpose'] ?? '',
                'content'  => $j['content'] ?? '',
                'from_book'=> $j['from_book'] ?? '',
                'scope'    => 'global',
                'source'   => 'accumulator',
            ];
            $score = keyword_score($item, $q);
            if ($score > 0) $results[] = array_merge($item, ['score' => $score]);
        }
    }

    // Search user index entries (snippets + sources + library paths)
    foreach (['global', 'project'] as $sc) {
        $idx = load_json(idx_path($sc, $project, $PROJECTS_DIR, $GLOBAL_IDX));
        foreach (['snippets','library','sources'] as $k) {
            if ($kind !== 'all' && $kind !== $k) continue;
            foreach (($idx[$k] ?? []) as $entry) {
                // Library: fold in extracted text so keyword search hits book/article content.
                if ($k === 'library' && empty($entry['content']) && !empty($entry['id'])) {
                    $cf = $LIBTEXT_DIR . '/' . $entry['id'] . '.txt';
                    // Cleaned on read: books ingested before the cleaner existed still
                    // carry calibre markup on disk, and here it would also skew scoring
                    // -- {.calibre3} spans are tokens keyword_score has to weigh.
                    if (is_file($cf)) $entry['content'] = book_clean_text((string)@file_get_contents($cf, false, null, 0, 50000));
                }
                $score = keyword_score($entry, $q);
                if ($score > 0) {
                    $entry['kind']  = $k;
                    $entry['scope'] = $sc;
                    $results[] = array_merge($entry, ['score' => $score]);
                }
            }
        }
    }

    // Sort by score desc, take top N
    usort($results, fn($a,$b) => $b['score'] <=> $a['score']);
    $results = array_slice($results, 0, $limit);

    echo json_encode([
        'ok'      => true,
        'query'   => $q,
        'count'   => count($results),
        'results' => $results,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: read_content — return full content for prompt injection
// =============================================================================
if ($action === 'read_content') {
    $kind    = trim((string)($_GET['kind'] ?? ''));
    $id      = trim((string)($_GET['id']   ?? ''));
    $scope   = trim((string)($_GET['scope'] ?? 'global'));

    if (!$kind || !$id) { echo json_encode(['ok'=>false,'error'=>'Missing kind/id'], JSON_UNESCAPED_UNICODE); exit; }

    // Accumulator snippets
    if ($kind === 'snippets') {
        $f = $SNIPPETS_DIR . '/' . $id . '.json';
        if (is_file($f)) {
            $j = load_json($f);
            $code = $j['source_code'] ?? '';
            $lang = $j['language'] ?? '';
            $name = $j['name'] ?? $id;
            $content = "**{$name}** (snippet · {$lang} · from {$j['from_book']})\n\n```{$lang}\n{$code}\n```";
            echo json_encode(['ok'=>true,'content'=>$content], JSON_UNESCAPED_UNICODE); exit;
        }
    }

    // Accumulator knowledge
    if ($kind === 'library') {
        $f = $KNOWLEDGE_DIR . '/' . $id . '.json';
        if (is_file($f)) {
            $j = load_json($f);
            $content = "**{$j['name']}** (knowledge · from {$j['from_book']})\n\n{$j['content']}";
            echo json_encode(['ok'=>true,'content'=>$content], JSON_UNESCAPED_UNICODE); exit;
        }
    }

    // User index entries — read the associated file
    $idx   = load_json(idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX));
    $entry = null;
    foreach (($idx[$kind] ?? []) as $e) {
        if (($e['id'] ?? '') === $id) { $entry = $e; break; }
    }
    if (!$entry) { echo json_encode(['ok'=>false,'error'=>'Item not found'], JSON_UNESCAPED_UNICODE); exit; }

    // Library: prefer the extracted text cache (a PDF/epub read raw is binary garbage).
    if ($kind === 'library' && !empty($entry['id'])) {
        $cf = $LIBTEXT_DIR . '/' . $entry['id'] . '.txt';
        if (is_file($cf)) { echo json_encode(['ok'=>true,'content'=>book_clean_text((string)file_get_contents($cf))], JSON_UNESCAPED_UNICODE); exit; }
    }

    // Read the file from disk
    $file_path = $entry['file_path'] ?? '';
    if ($file_path && is_file($file_path)) {
        $content = file_get_contents($file_path);
        echo json_encode(['ok'=>true,'content'=>$content], JSON_UNESCAPED_UNICODE); exit;
    }
    if (!empty($entry['content'])) {
        echo json_encode(['ok'=>true,'content'=>$entry['content']], JSON_UNESCAPED_UNICODE); exit;
    }

    echo json_encode(['ok'=>false,'error'=>'No content available for this item'], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: add — add an item to the index
// =============================================================================
if ($action === 'add') {
    $kind    = trim((string)($in['kind']  ?? ''));
    $scope   = trim((string)($in['scope'] ?? 'global'));
    $item    = is_array($in['item'] ?? null) ? $in['item'] : [];
    $content = (string)($in['content'] ?? '');

    if (!$kind || !$item) { echo json_encode(['ok'=>false,'error'=>'Missing kind/item'], JSON_UNESCAPED_UNICODE); exit; }

    $item['id']      = make_id();
    $item['updated'] = date('c');
    $item['scope']   = $scope;

    // Save content to disk for snippets/sources
    if (in_array($kind, ['snippets','sources']) && $content !== '') {
        $ext = $item['lang'] ?? 'txt';
        $fn  = $item['id'] . '.' . $ext;
        $dir = ($kind === 'snippets') ? $SNIPPETS_DIR : $SOURCES_DIR;
        file_put_contents($dir . '/' . $fn, $content);
        @chmod($dir . '/' . $fn, 0664);
        $item['file_path'] = $dir . '/' . $fn;
        $item['file']      = $fn;
        $item['size']      = strlen($content);
    }
    // A library entry typed in by hand (no path/url) keeps its text where search and
    // read_content already look for extracted book text: library_text/<id>.txt.
    if ($kind === 'library' && $content !== '') {
        if (!is_dir($LIBTEXT_DIR)) @mkdir($LIBTEXT_DIR, 0775, true);
        file_put_contents($LIBTEXT_DIR . '/' . $item['id'] . '.txt', $content);
        @chmod($LIBTEXT_DIR . '/' . $item['id'] . '.txt', 0664);
        $item['size'] = strlen($content);
    }

    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    if (!isset($idx[$kind])) $idx[$kind] = [];
    $idx[$kind][] = $item;
    save_json($idx_f, $idx);

    echo json_encode(['ok'=>true,'id'=>$item['id']], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: edit — update an existing index entry
// =============================================================================
if ($action === 'edit') {
    $kind    = trim((string)($in['kind']  ?? ''));
    $scope   = trim((string)($in['scope'] ?? 'global'));
    $id      = trim((string)($in['id']    ?? ''));
    $item    = is_array($in['item'] ?? null) ? $in['item'] : [];
    $content = array_key_exists('content', $in) ? (string)$in['content'] : null;

    if (!$kind || !$id) { echo json_encode(['ok'=>false,'error'=>'Missing kind/id'], JSON_UNESCAPED_UNICODE); exit; }

    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    $found = false;
    foreach (($idx[$kind] ?? []) as $i => $e) {
        if (($e['id'] ?? '') === $id) {
            $merged = array_merge($e, $item, ['id'=>$id,'updated'=>date('c')]);

            // Snippets/sources: when content is supplied, rewrite the file on disk.
            // Reuse the existing file_path; if the language (extension) changed,
            // write the new file and remove the stale one.
            if ($content !== null && in_array($kind, ['snippets','sources'], true)) {
                $dir     = ($kind === 'snippets') ? $SNIPPETS_DIR : $SOURCES_DIR;
                $ext     = $merged['lang'] ?? ($e['lang'] ?? 'txt');
                if ($ext === '') $ext = 'txt';
                $oldPath = $e['file_path'] ?? '';
                $newName = $id . '.' . $ext;
                $newPath = $dir . '/' . $newName;
                if (file_put_contents($newPath, $content) !== false) {
                    @chmod($newPath, 0664);
                    if ($oldPath && $oldPath !== $newPath && is_file($oldPath)) @unlink($oldPath);
                    $merged['file_path'] = $newPath;
                    $merged['file']      = $newName;
                    $merged['size']      = strlen($content);
                } else {
                    echo json_encode(['ok'=>false,'error'=>'Could not write content file (check permissions on '.$dir.')'], JSON_UNESCAPED_UNICODE);
                    exit;
                }
            }

            $idx[$kind][$i] = $merged;
            $found = true; break;
        }
    }
    if (!$found) { echo json_encode(['ok'=>false,'error'=>'Item not found'], JSON_UNESCAPED_UNICODE); exit; }
    save_json($idx_f, $idx);
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: delete
// =============================================================================
// =============================================================================
// ACTION: delete_book — remove every chapter of one book in a single step
//
// Bookshelf files a book as N library entries tagged ['book', <book title>].
// Deleting them one at a time is not a real option: a novel is 20-40 rows, and
// the reason you want them gone is usually that the split went wrong, which is
// exactly when you are in a hurry. The tag was written for this from the start.
// =============================================================================
if ($action === 'delete_book') {
    $book  = trim((string)($in['book']  ?? ''));
    $scope = trim((string)($in['scope'] ?? 'global'));
    if ($book === '') { echo json_encode(['ok'=>false,'error'=>'Missing book'], JSON_UNESCAPED_UNICODE); exit; }

    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    $keep = []; $gone = 0;
    $LIBTEXT = rtrim((string)$PATHS['cockpit_data'], '/') . '/library_text';
    foreach (($idx['library'] ?? []) as $e) {
        $tags = $e['tags'] ?? [];
        if (in_array('book', $tags, true) && in_array($book, $tags, true)) {
            // The chapter text lives beside the index; remove it too, or the
            // entry disappears from the UI while its file stays on disk forever.
            $f = $e['file_path'] ?? ($LIBTEXT . '/' . ($e['id'] ?? '') . '.txt');
            if ($f && is_file($f) && str_starts_with(realpath($f) ?: '', realpath($LIBTEXT) ?: "\0")) @unlink($f);
            $gone++;
            continue;
        }
        $keep[] = $e;
    }
    if (!$gone) { echo json_encode(['ok'=>false,'error'=>'No chapters found for that book'], JSON_UNESCAPED_UNICODE); exit; }
    $idx['library'] = $keep;
    save_json($idx_f, $idx);
    echo json_encode(['ok'=>true, 'removed'=>$gone], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'delete') {
    $kind  = trim((string)($in['kind']  ?? ''));
    $scope = trim((string)($in['scope'] ?? 'global'));
    $id    = trim((string)($in['id']    ?? ''));

    if (!$kind || !$id) { echo json_encode(['ok'=>false,'error'=>'Missing kind/id'], JSON_UNESCAPED_UNICODE); exit; }

    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    $deleted = false;
    foreach (($idx[$kind] ?? []) as $i => $e) {
        if (($e['id'] ?? '') === $id) {
            // Delete file on disk for snippets/sources
            if (!empty($e['file_path']) && is_file($e['file_path'])) {
                @unlink($e['file_path']);
            }
            array_splice($idx[$kind], $i, 1);
            $deleted = true; break;
        }
    }
    if (!$deleted) { echo json_encode(['ok'=>false,'error'=>'Item not found'], JSON_UNESCAPED_UNICODE); exit; }
    save_json($idx_f, $idx);
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: move — change scope (global ↔ project)
// =============================================================================
if ($action === 'move') {
    $kind = trim((string)($in['kind'] ?? ''));
    $id   = trim((string)($in['id']   ?? ''));
    $from = trim((string)($in['from'] ?? 'global'));
    $to   = trim((string)($in['to']   ?? 'project'));

    if (!$kind || !$id) { echo json_encode(['ok'=>false,'error'=>'Missing kind/id'], JSON_UNESCAPED_UNICODE); exit; }

    $from_f = idx_path($from, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $to_f   = idx_path($to,   $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $from_idx = load_json($from_f, []);
    $to_idx   = load_json($to_f,   []);

    $item = null;
    foreach (($from_idx[$kind] ?? []) as $i => $e) {
        if (($e['id'] ?? '') === $id) {
            $item = $e;
            array_splice($from_idx[$kind], $i, 1);
            break;
        }
    }
    if (!$item) { echo json_encode(['ok'=>false,'error'=>'Item not found'], JSON_UNESCAPED_UNICODE); exit; }

    $item['scope'] = $to;
    if (!isset($to_idx[$kind])) $to_idx[$kind] = [];
    $to_idx[$kind][] = $item;

    save_json($from_f, $from_idx);
    save_json($to_f,   $to_idx);
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: rescan — scan configured folder paths and auto-index new files
// =============================================================================
if ($action === 'rescan') {
    $kind  = trim((string)($in['kind']  ?? ''));
    $scope = trim((string)($in['scope'] ?? 'global'));

    $paths     = load_paths($PATHS_F);
    $scan_dirs = $paths[$kind] ?? [];

    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    if (!isset($idx[$kind])) $idx[$kind] = [];

    // Build set of already-indexed file paths to avoid duplicates
    $known = [];
    foreach ($idx[$kind] as $e) {
        if (!empty($e['file_path'])) $known[$e['file_path']] = true;
    }

    // Extension whitelists per kind
    $ext_map = [
        'snippets' => ['pas','pp','lpr','php','py','js','ts','sh','bash','c','cpp','h','cs','go','rb','rs','java','sql'],
        'sources'  => ['pas','pp','lpr','php','py','js','ts','sh','c','cpp','h','cs','go','rb','java','sql','md','txt'],
        'library'  => ['pdf','epub','chm','docx','odt','html','htm','txt','md'],
    ];
    $allowed_exts = $ext_map[$kind] ?? [];

    $added = 0;
    foreach ($scan_dirs as $dir) {
        $dir = rtrim($dir, '/');
        if (!is_dir($dir)) continue;

        $iter = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($dir, RecursiveDirectoryIterator::SKIP_DOTS),
            RecursiveIteratorIterator::LEAVES_ONLY
        );
        foreach ($iter as $file) {
            $path = (string)$file;
            $ext  = strtolower(pathinfo($path, PATHINFO_EXTENSION));
            if (!in_array($ext, $allowed_exts, true)) continue;
            if (isset($known[$path])) continue;

            $name    = pathinfo($path, PATHINFO_FILENAME);
            $entry   = [
                'id'        => make_id(),
                'title'     => $name,
                'lang'      => $ext,
                'file_path' => $path,
                'file'      => basename($path),
                'size'      => filesize($path),
                'notes'     => 'auto-scanned from ' . $dir,
                'scope'     => $scope,
                'updated'   => date('c', filemtime($path)),
                'source'    => 'scan',
            ];
            // Library: extract text content so it's keyword- + semantically searchable.
            if ($kind === 'library') {
                $txt = lib_extract_text($path, $ext);
                if ($txt !== '') {
                    @file_put_contents($LIBTEXT_DIR . '/' . $entry['id'] . '.txt', $txt);
                    $entry['preview'] = mb_substr(trim(preg_replace('/\s+/', ' ', $txt)), 0, 300);
                    $entry['text_cached'] = true;
                }
            }
            $idx[$kind][] = $entry;
            $known[$path] = true;
            $added++;
        }
    }

    save_json($idx_f, $idx);
    $total = count($idx[$kind]);
    echo json_encode(['ok'=>true,'added'=>$added,'total'=>$total,'count'=>$total], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: add_file — index a single library file picked via the Cockpit picker
// (extracts text so it's searchable). For books/articles/magazines.
// =============================================================================
if ($action === 'add_file') {
    $pathIn = trim((string)($in['path'] ?? ''));
    $scope  = trim((string)($in['scope'] ?? 'global'));
    $real   = realpath($pathIn);
    if ($real === false || !is_file($real)) { echo json_encode(['ok'=>false,'error'=>'file not found'], JSON_UNESCAPED_UNICODE); exit; }
    $ext = strtolower(pathinfo($real, PATHINFO_EXTENSION));
    $libexts = ['pdf','epub','chm','docx','odt','rtf','fb2','html','htm','txt','md','csv'];
    if (!in_array($ext, $libexts, true)) { echo json_encode(['ok'=>false,'error'=>'unsupported type for library: .'.$ext], JSON_UNESCAPED_UNICODE); exit; }

    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    if (!isset($idx['library'])) $idx['library'] = [];
    foreach ($idx['library'] as $e) {
        if (($e['file_path'] ?? '') === $real) { echo json_encode(['ok'=>false,'error'=>'already in library'], JSON_UNESCAPED_UNICODE); exit; }
    }
    $entry = [
        'id'=>make_id(), 'title'=>pathinfo($real, PATHINFO_FILENAME), 'lang'=>$ext,
        'file_path'=>$real, 'file'=>basename($real), 'size'=>filesize($real),
        'notes'=>'added via picker', 'scope'=>$scope, 'updated'=>date('c'), 'source'=>'picker',
    ];
    $txt = lib_extract_text($real, $ext);
    if ($txt !== '') {
        @file_put_contents($LIBTEXT_DIR . '/' . $entry['id'] . '.txt', $txt);
        $entry['preview'] = mb_substr(trim(preg_replace('/\s+/', ' ', $txt)), 0, 300);
        $entry['text_cached'] = true;
    }
    $idx['library'][] = $entry;
    save_json($idx_f, $idx);
    echo json_encode(['ok'=>true, 'id'=>$entry['id'], 'extracted'=>($txt !== '')], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: upload_zip — extract a ZIP and index its contents (sources only)
// =============================================================================
if ($action === 'upload_zip') {
    $kind     = trim((string)($in['kind']     ?? 'sources'));
    $scope    = trim((string)($in['scope']    ?? 'global'));
    $filename = trim((string)($in['filename'] ?? 'upload.zip'));
    $title    = trim((string)($in['title']    ?? $filename));
    $b64      = (string)($in['data_b64'] ?? '');

    if (!$b64) { echo json_encode(['ok'=>false,'error'=>'No data'], JSON_UNESCAPED_UNICODE); exit; }

    $zip_data = base64_decode($b64, true);
    if (!$zip_data) { echo json_encode(['ok'=>false,'error'=>'Invalid base64'], JSON_UNESCAPED_UNICODE); exit; }

    // Write ZIP to temp
    $tmp_zip = sys_get_temp_dir() . '/cockpit_upload_' . getmypid() . '.zip';
    file_put_contents($tmp_zip, $zip_data);

    // Extract to sources dir
    $dest = $SOURCES_DIR . '/' . preg_replace('/[^a-zA-Z0-9_\-]/', '_', $title);
    @mkdir($dest, 0775, true);

    $zip = new ZipArchive();
    if ($zip->open($tmp_zip) !== true) {
        @unlink($tmp_zip);
        echo json_encode(['ok'=>false,'error'=>'Could not open ZIP'], JSON_UNESCAPED_UNICODE); exit;
    }
    $zip->extractTo($dest);
    $zip->close();
    @unlink($tmp_zip);

    // Index the extraction dir as a single source entry
    $idx_f = idx_path($scope, $project, $PROJECTS_DIR, $GLOBAL_IDX);
    $idx   = load_json($idx_f, []);
    if (!isset($idx[$kind])) $idx[$kind] = [];
    $idx[$kind][] = [
        'id'        => make_id(),
        'title'     => $title,
        'lang'      => 'zip',
        'file_path' => $dest,
        'file'      => basename($dest),
        'size'      => strlen($zip_data),
        'notes'     => 'extracted from ' . $filename,
        'scope'     => $scope,
        'updated'   => date('c'),
        'source'    => 'upload',
    ];
    save_json($idx_f, $idx);

    echo json_encode(['ok'=>true,'dest'=>$dest], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: add_proposal — append one entry to proposals.json
//
// Called by the JS addProposal() whenever an agent emits %%PROPOSE:kind%%
// or _ragOfferAsProposals() offers RAG results as proposals.
//
// Entry written:
//   { id, kind, proposer, ts, project, payload:{title,lang,content,notes} }
// =============================================================================
if ($action === 'add_proposal') {
    $kind     = trim((string)($in['kind']     ?? 'snippet'));
    $proposer = trim((string)($in['proposer'] ?? 'agent'));
    $proj     = trim((string)($in['project']  ?? ''));
    $payload  = is_array($in['payload'] ?? null) ? $in['payload'] : [];

    $valid_kinds = ['snippet', 'source', 'library'];
    if (!in_array($kind, $valid_kinds, true)) {
        echo json_encode(['ok'=>false,'error'=>'Invalid kind: '.$kind], JSON_UNESCAPED_UNICODE); exit;
    }

    // HIGH-80: cap content at 1MB to prevent runaway agent submissions
    $content_raw = (string)($payload['content'] ?? '');
    if (strlen($content_raw) > 1048576) {
        echo json_encode(['ok'=>false,'error'=>'Proposal content exceeds 1MB'], JSON_UNESCAPED_UNICODE); exit;
    }

    // ── Dedup + naming ──────────────────────────────────────────────────────
    // A snippet is identified by its CODE + LANGUAGE only (NOT its name). So the
    // same code proposed twice — even under different names — collapses to one;
    // the same NAME over different code is allowed (and the new title is
    // disambiguated below). The hash is checked against BOTH pending proposals
    // and the snippet indexes, so a duplicate in either store blocks re-adding.
    $lang_norm = strtolower(trim((string)($payload['lang'] ?? '')));
    $hash      = sha1($content_raw . "\x00" . $lang_norm);
    $title_in  = trim((string)($payload['title'] ?? ''));

    $seen_hashes = [];   // hash => true
    $seen_titles = [];   // title => hash (for name-collision detection)
    $collectIdx  = function($idxFile) use (&$seen_hashes, &$seen_titles) {
        $idx = load_json($idxFile, []);
        foreach (['snippets', 'code'] as $k) {
            foreach (($idx[$k] ?? []) as $e) {
                if (!empty($e['hash']))   $seen_hashes[$e['hash']] = true;
                if (isset($e['title']))   $seen_titles[$e['title']] = ($e['hash'] ?? '');
            }
        }
    };
    $collectIdx($GLOBAL_IDX);
    if ($proj !== '') $collectIdx(idx_path('project', $proj, $PROJECTS_DIR, $GLOBAL_IDX));
    $existing_props = load_json($CD . '/proposals.json', []);
    if (is_array($existing_props)) {
        foreach ($existing_props as $e) {
            $h = $e['payload']['hash'] ?? '';
            if ($h) $seen_hashes[$h] = true;
            $t = $e['payload']['title'] ?? '';
            if ($t !== '') $seen_titles[$t] = $h;
        }
    }

    // Exact code+language already present → skip silently (not an error).
    if (isset($seen_hashes[$hash])) {
        echo json_encode(['ok'=>true,'duplicate'=>true,'skipped'=>true,'hash'=>$hash], JSON_UNESCAPED_UNICODE); exit;
    }
    // Same name but DIFFERENT code → keep both; disambiguate the new title with
    // a short hash suffix so the two are distinguishable in the list.
    if ($title_in !== '' && isset($seen_titles[$title_in]) && $seen_titles[$title_in] !== $hash) {
        $title_in .= ' #' . substr($hash, 0, 6);
    }

    $entry = [
        'id'       => make_id(),
        'kind'     => $kind,
        'proposer' => $proposer ?: 'agent',
        'ts'       => date('c'),
        'project'  => $proj,
        'payload'  => [
            'title'   => $title_in,
            'lang'    => trim((string)($payload['lang']    ?? '')),
            'content' => $content_raw,
            'notes'   => trim((string)($payload['notes']   ?? '')),
            'hash'    => $hash,
        ],
    ];

    // HIGH-77: flock to prevent lost updates when multiple agents submit
    // proposals concurrently. The lock file is the proposals.json itself.
    $proposals_file = $CD . '/proposals.json';
    if (!is_file($proposals_file)) @file_put_contents($proposals_file, '[]');
    $lock_fh = @fopen($proposals_file, 'c+');
    if ($lock_fh && flock($lock_fh, LOCK_EX)) {
        $proposals = load_json($proposals_file, []);
        if (!is_array($proposals) || !array_is_list($proposals)) $proposals = [];
        $proposals[] = $entry;
        save_json($proposals_file, $proposals);
        flock($lock_fh, LOCK_UN);
    }
    if ($lock_fh) fclose($lock_fh);

    echo json_encode(['ok' => true, 'id' => $entry['id']], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: proposals — return all pending proposals from proposals.json
// =============================================================================
if ($action === 'proposals') {
    $proposals_file = $CD . '/proposals.json';
    $proposals = load_json($proposals_file, []);
    // Ensure it's a flat array (not an object)
    if (!array_is_list($proposals)) $proposals = array_values($proposals);
    echo json_encode(['ok' => true, 'proposals' => $proposals, 'count' => count($proposals)], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// ACTION: proposal_act — approve or reject a pending proposal
//
// On approve: moves the proposal's payload into the appropriate library index
//             (same as ?action=add) then removes it from proposals.json.
// On reject:  simply removes it from proposals.json.
// =============================================================================
if ($action === 'proposal_act') {
    $id           = trim((string)($in['id']           ?? ''));
    $act          = trim((string)($in['act']          ?? ''));  // 'approve' | 'reject'
    $target_scope = trim((string)($in['target_scope'] ?? 'global'));

    if (!$id || !in_array($act, ['approve','reject'], true)) {
        echo json_encode(['ok'=>false,'error'=>'Missing id or invalid act'], JSON_UNESCAPED_UNICODE); exit;
    }

    $proposals_file = $CD . '/proposals.json';
    $proposals = load_json($proposals_file, []);
    if (!array_is_list($proposals)) $proposals = array_values($proposals);

    // Find the proposal
    $found = null;
    $found_idx = -1;
    foreach ($proposals as $i => $p) {
        if (($p['id'] ?? '') === $id) { $found = $p; $found_idx = $i; break; }
    }
    if ($found === null) {
        echo json_encode(['ok'=>false,'error'=>'Proposal not found: ' . $id], JSON_UNESCAPED_UNICODE); exit;
    }

    if ($act === 'approve') {
        // Build the library index entry from the proposal payload
        $payload = is_array($found['payload'] ?? null) ? $found['payload'] : [];
        $kind    = trim((string)($found['kind'] ?? ''));

        // Normalise kind: proposal uses 'snippet'/'source', index uses 'snippets'/'sources'
        $kind_map = ['snippet'=>'snippets', 'source'=>'sources', 'library'=>'library'];
        $index_kind = $kind_map[$kind] ?? $kind;

        if (!$index_kind) {
            echo json_encode(['ok'=>false,'error'=>'Unknown proposal kind: ' . $kind], JSON_UNESCAPED_UNICODE); exit;
        }

        $proj = trim((string)($found['project'] ?? ''));

        // HIGH-81: validate extension — was user-controlled (lang field).
        // An attacker could pass lang: "../../etc/passwd" as the "extension".
        $lang_raw = (string)($payload['lang'] ?? '');
        $ext = preg_match('/^[a-z0-9]{1,8}$/', strtolower($lang_raw)) ? strtolower($lang_raw) : 'txt';

        $item = [
            'id'      => make_id(),
            'title'   => $payload['title']   ?? 'Untitled',
            'lang'    => $lang_raw,
            'notes'   => $payload['notes']    ?? '',
            'purpose' => $payload['purpose']  ?? '',
            'scope'   => $target_scope,
            'source'  => 'proposal',
            'updated' => date('c'),
            'hash'    => (string)($payload['hash'] ?? ''),   // code+lang identity (dedup)
        ];

        // For library kind, carry location
        if ($index_kind === 'library') {
            $item['location'] = $payload['location'] ?? '';
        }

        // HIGH-78: prepare content path and write order:
        //   1. Validate content (already done)
        //   2. Add file path to index entry
        //   3. Save index FIRST — if this fails, no orphan file on disk
        //   4. Then write content file — if this fails, index has a missing
        //      file_path that the UI can detect/clean up
        $content = (string)($payload['content'] ?? '');
        $content_path = null;
        if (in_array($index_kind, ['snippets','sources'], true) && $content !== '') {
            $dir = ($index_kind === 'snippets') ? $SNIPPETS_DIR : $SOURCES_DIR;
            if (!is_dir($dir)) @mkdir($dir, 0775, true);
            $fn  = $item['id'] . '.' . $ext;
            $content_path = $dir . '/' . $fn;
            $item['file_path'] = $content_path;
            $item['file']      = $fn;
            $item['size']      = strlen($content);
        }

        // Write into the index FIRST
        $idx_f = idx_path($target_scope, $proj, $PROJECTS_DIR, $GLOBAL_IDX);
        $idx   = load_json($idx_f, []);
        if (!isset($idx[$index_kind])) $idx[$index_kind] = [];
        $idx[$index_kind][] = $item;
        if (!save_json($idx_f, $idx)) {
            echo json_encode(['ok'=>false,'error'=>'Failed to save index'], JSON_UNESCAPED_UNICODE); exit;
        }

        // Now write content file (atomic via .tmp + rename)
        if ($content_path !== null) {
            $tmp = $content_path . '.tmp';
            if (@file_put_contents($tmp, $content) !== false) {
                @chmod($tmp, 0664);
                @rename($tmp, $content_path);
            }
        }
    }

    // Remove the proposal from the list (both approve and reject) — under flock
    $lock_fh = @fopen($proposals_file, 'c+');
    if ($lock_fh && flock($lock_fh, LOCK_EX)) {
        // Re-read inside the lock to get latest state
        $proposals = load_json($proposals_file, []);
        if (!array_is_list($proposals)) $proposals = array_values($proposals);
        // Re-find by id since indices may have shifted
        foreach ($proposals as $i => $p) {
            if (($p['id'] ?? '') === $id) { array_splice($proposals, $i, 1); break; }
        }
        save_json($proposals_file, array_values($proposals));
        flock($lock_fh, LOCK_UN);
    }
    if ($lock_fh) fclose($lock_fh);

    echo json_encode(['ok' => true, 'act' => $act, 'id' => $id], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// C4 — build_embeddings: embed all snippets + knowledge + sources, store vectors
// =============================================================================
if ($action === 'build_embeddings') {
    // Verify Ollama + model first
    $probe = embed_text('test');
    if ($probe === null) {
        echo json_encode(['ok'=>false,'error'=>'Embedding failed — is Ollama running and "'.EMBED_MODEL.'" pulled? (ollama pull '.EMBED_MODEL.')'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $store = load_json($EMBED_F, ['model'=>EMBED_MODEL, 'items'=>[]]);
    if (!is_array($store) || ($store['model'] ?? '') !== EMBED_MODEL) {
        $store = ['model'=>EMBED_MODEL, 'items'=>[]];   // model changed → rebuild
    }
    $byId = [];
    foreach ($store['items'] as $it) { if (!empty($it['id'])) $byId[$it['id']] = $it; }

    $indexed = 0; $skipped = 0;
    $sources = [
        ['dir'=>$SNIPPETS_DIR,  'kind'=>'snippet',   'textf'=>['name','purpose','source_code']],
        ['dir'=>$KNOWLEDGE_DIR, 'kind'=>'knowledge', 'textf'=>['name','purpose','content']],
        ['dir'=>$SOURCES_DIR,   'kind'=>'source',    'textf'=>['name','purpose','content']],
    ];
    foreach ($sources as $src) {
        foreach (glob($src['dir'] . '/*.json') ?: [] as $f) {
            $j = load_json($f);
            if (!$j) continue;
            $id = $src['kind'] . ':' . ($j['id'] ?? basename($f, '.json'));
            $parts = [];
            foreach ($src['textf'] as $tf) { if (!empty($j[$tf])) $parts[] = (string)$j[$tf]; }
            $text = trim(implode("\n", $parts));
            if ($text === '') { $skipped++; continue; }
            $hash = md5($text);
            // Skip if already embedded with same content hash
            if (isset($byId[$id]) && ($byId[$id]['hash'] ?? '') === $hash) { $skipped++; continue; }
            $vec = embed_text($text);
            if ($vec === null) { $skipped++; continue; }
            $byId[$id] = [
                'id'    => $id,
                'kind'  => $src['kind'],
                'title' => $j['name'] ?? ($j['id'] ?? ''),
                'lang'  => $j['language'] ?? '',
                'hash'  => $hash,
                'vec'   => $vec,
            ];
            $indexed++;
        }
    }
    // Index chat exchanges (one vector per chat, concatenated text, capped)
    $chatRoot = $PATHS['projects_root'];
    if (is_dir($chatRoot)) {
        foreach (scandir($chatRoot) as $proj) {
            if ($proj[0] === '.') continue;
            $projDir = $chatRoot . '/' . $proj;
            if (!is_dir($projDir)) continue;
            foreach (glob($projDir . '/chat_*.json') ?: [] as $cf) {
                $cd = load_json($cf);
                if (!is_array($cd) || empty($cd['exchanges'])) continue;
                $slug = preg_replace('/^chat_|\.json$/', '', basename($cf));
                $id = 'chat:' . $proj . '/' . $slug;
                $parts = [];
                foreach ($cd['exchanges'] as $ex) {
                    if (!empty($ex['text'])) $parts[] = $ex['text'];
                }
                $text = trim(implode("\n", $parts));
                if ($text === '') { $skipped++; continue; }
                $hash = md5($text);
                if (isset($byId[$id]) && ($byId[$id]['hash'] ?? '') === $hash) { $skipped++; continue; }
                $vec = embed_text($text);
                if ($vec === null) { $skipped++; continue; }
                $byId[$id] = [
                    'id'    => $id,
                    'kind'  => 'chat',
                    'title' => ($cd['chat'] ?? $slug) . ' (' . $proj . ')',
                    'lang'  => '',
                    'hash'  => $hash,
                    'vec'   => $vec,
                ];
                $indexed++;
            }
        }
    }

    // Library — embed extracted text of indexed books/articles/magazines.
    $gidx = load_json($GLOBAL_IDX, []);
    foreach (($gidx['library'] ?? []) as $li) {
        if (empty($li['id'])) continue;
        $lid = 'library:' . $li['id'];
        $cachef = $LIBTEXT_DIR . '/' . $li['id'] . '.txt';
        $text = '';
        if (is_file($cachef)) {
            $text = book_clean_text((string)@file_get_contents($cachef, false, null, 0, 60000));
        } elseif (!empty($li['file_path'])) {
            $ext = $li['lang'] ?? strtolower(pathinfo($li['file_path'], PATHINFO_EXTENSION));
            $text = lib_extract_text($li['file_path'], $ext, 60000);
            if ($text !== '') @file_put_contents($cachef, $text);   // backfill cache
        }
        $text = trim(($li['title'] ?? '') . "\n" . ($li['notes'] ?? '') . "\n" . $text);
        if ($text === '') { $skipped++; continue; }
        $embIn = mb_substr($text, 0, 8000);
        $hash = md5($embIn);
        if (isset($byId[$lid]) && ($byId[$lid]['hash'] ?? '') === $hash) { $skipped++; continue; }
        $vec = embed_text($embIn);
        if ($vec === null) { $skipped++; continue; }
        $byId[$lid] = ['id'=>$lid, 'kind'=>'library', 'title'=>$li['title'] ?? ($li['file'] ?? ''),
                       'lang'=>$li['lang'] ?? '', 'hash'=>$hash, 'vec'=>$vec];
        $indexed++;
    }

    $store['items'] = array_values($byId);
    $store['built_at'] = date('c');
    save_json($EMBED_F, $store);
    echo json_encode(['ok'=>true, 'indexed'=>$indexed, 'skipped'=>$skipped,
                       'total'=>count($store['items']), 'model'=>EMBED_MODEL], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// C4 — semantic_search: embed the query, rank stored vectors by cosine similarity
// =============================================================================
if ($action === 'semantic_search') {
    $q     = trim((string)($_GET['q'] ?? $in['q'] ?? ''));
    $limit = max(1, min(20, (int)($_GET['limit'] ?? 8)));
    if ($q === '') { echo json_encode(['ok'=>false,'error'=>'Missing query'], JSON_UNESCAPED_UNICODE); exit; }
    $store = load_json($EMBED_F, null);
    if (!is_array($store) || empty($store['items'])) {
        echo json_encode(['ok'=>false,'error'=>'No embeddings yet — click "Build index" first.'], JSON_UNESCAPED_UNICODE); exit;
    }
    $qvec = embed_text($q);
    if ($qvec === null) {
        echo json_encode(['ok'=>false,'error'=>'Query embedding failed — is Ollama running?'], JSON_UNESCAPED_UNICODE); exit;
    }
    $scored = [];
    foreach ($store['items'] as $it) {
        if (empty($it['vec'])) continue;
        $sim = cosine_sim($qvec, $it['vec']);
        $scored[] = [
            'id'    => $it['id'],
            'kind'  => $it['kind'],
            'title' => $it['title'] ?? '',
            'lang'  => $it['lang'] ?? '',
            'score' => round($sim, 4),
        ];
    }
    usort($scored, fn($a,$b) => $b['score'] <=> $a['score']);
    $scored = array_slice($scored, 0, $limit);
    echo json_encode(['ok'=>true, 'query'=>$q, 'model'=>$store['model'] ?? EMBED_MODEL,
                       'results'=>$scored, 'indexed'=>count($store['items'])], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Catch-all
// =============================================================================
echo json_encode(['ok'=>false,'error'=>'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
