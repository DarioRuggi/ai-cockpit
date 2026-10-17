<?php
// =============================================================================
// config.php — Cockpit configuration viewer
// Returns a structured snapshot of agent configs (global + project + chat meta)
// for the current project/chat, used by the right Config panel.
// =============================================================================

header('Content-Type: application/json');
header('Cache-Control: no-store');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

define('COCKPIT_ROOT', $PATHS['projects_root']);

function safeName($s) {
    return preg_replace('/[^a-zA-Z0-9_\-]/', '', (string)$s);
}

function readIfExists($path) {
    if (is_file($path) && is_readable($path)) {
        $size = filesize($path);
        if ($size > 1024 * 1024) return ['exists'=>true,'truncated'=>true,'size'=>$size,'path'=>$path,'content'=>'(file >1MB, not loaded inline)'];
        return ['exists'=>true,'size'=>$size,'mtime'=>filemtime($path),'path'=>$path,'content'=>file_get_contents($path)];
    }
    return ['exists'=>false,'path'=>$path];
}

$action  = $_GET['action']  ?? 'snapshot';
$project = safeName($_GET['project'] ?? '');
$chat    = safeName($_GET['chat'] ?? '');

// =============================================================================
// POST: save_file — write back an editable config file
// =============================================================================
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $raw = file_get_contents('php://input');
    $in  = json_decode($raw, true);
    if (!is_array($in)) { echo json_encode(['ok'=>false,'error'=>'Invalid JSON'], JSON_UNESCAPED_UNICODE); exit; }

    if (($in['action'] ?? '') !== 'save_file') {
        echo json_encode(['ok'=>false,'error'=>'Unknown POST action'], JSON_UNESCAPED_UNICODE); exit;
    }
    $path    = $in['path']    ?? '';
    $content = $in['content'] ?? '';

    // Whitelist of editable paths — only allow:
    //   ~/.claude/CLAUDE.md, ~/.claude/settings.json
    //   ~/.gemini/GEMINI.md, ~/.gemini/settings.json
    //   <project>/CLAUDE.md, <project>/GEMINI.md, <project>/AGENT.md, <project>/README.md
    $_home = $PATHS['home'];
    $allowed = [
        $_home . '/.claude/CLAUDE.md'   => true,
        $_home . '/.claude/settings.json'=> true,
        $_home . '/.gemini/GEMINI.md'   => true,
        $_home . '/.gemini/settings.json'=> true,
    ];
    // Project files: if path starts with COCKPIT_ROOT and is one of the known names
    $isProjectFile = false;
    if (strpos($path, COCKPIT_ROOT . '/') === 0) {
        $base = basename($path);
        if (in_array($base, ['CLAUDE.md','GEMINI.md','AGENT.md','README.md','opencode.json','opencode.jsonc'], true)) {
            // Also reject any .. traversal
            if (strpos($path, '..') === false) {
                $real = realpath(dirname($path));
                if ($real && strpos($real, COCKPIT_ROOT) === 0) {
                    $isProjectFile = true;
                }
            }
        }
    }

    if (!isset($allowed[$path]) && !$isProjectFile) {
        echo json_encode(['ok'=>false,'error'=>'Path not in whitelist: '.$path], JSON_UNESCAPED_UNICODE); exit;
    }
    if (!is_dir(dirname($path))) {
        @mkdir(dirname($path), 0775, true);
    }
    $bytes = file_put_contents($path, $content);
    if ($bytes === false) {
        echo json_encode(['ok'=>false,'error'=>'Write failed'], JSON_UNESCAPED_UNICODE); exit;
    }
    @chmod($path, 0664);
    echo json_encode(['ok'=>true,'bytes'=>$bytes,'path'=>$path], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'snapshot') {
    $home = $PATHS['home'];
    $result = [
        'ok' => true,
        'project' => $project,
        'chat'    => $chat,

        // ── Global per-agent configs ──────────────────────────────────────
        'globals' => [
            'claude' => [
                'CLAUDE.md (global)' => readIfExists($home . '/.claude/CLAUDE.md'),
                'settings.json'      => readIfExists($home . '/.claude/settings.json'),
            ],
            'gemini' => [
                'GEMINI.md (global)' => readIfExists($home . '/.gemini/GEMINI.md'),
                'settings.json'      => readIfExists($home . '/.gemini/settings.json'),
            ],
            'ollama' => [
                'config'        => readIfExists($home . '/.ollama/config'),
                'models path'   => ['exists'=>true, 'content' => 'OLLAMA_MODELS=' . ($home . '/ollama/models')],
            ],
            'cockpit' => [
                'project_state.json' => readIfExists($PATHS['web_root'] . '/project_state.json'),
            ],
        ],

        // ── Project-level configs (only if project specified) ─────────────
        'project' => null,

        // ── Chat metadata (only if both project + chat specified) ─────────
        'chat_meta' => null,
    ];

    if ($project) {
        $pdir = COCKPIT_ROOT . '/' . $project;
        $projConfigs = [
            'CLAUDE.md'        => readIfExists($pdir . '/CLAUDE.md'),
            'GEMINI.md'        => readIfExists($pdir . '/GEMINI.md'),
            'AGENT.md'         => readIfExists($pdir . '/AGENT.md'),
            'README.md'        => readIfExists($pdir . '/README.md'),
            'opencode.json'    => readIfExists($pdir . '/opencode.json'),
            'opencode.jsonc'   => readIfExists($pdir . '/opencode.jsonc'),
        ];
        // Also pick up any *.md / *.yaml / *.yml at root that aren't standard
        if (is_dir($pdir)) {
            foreach (glob($pdir . '/*.{md,yaml,yml}', GLOB_BRACE) as $f) {
                $base = basename($f);
                if (!isset($projConfigs[$base])) {
                    $projConfigs[$base] = readIfExists($f);
                }
            }
        }
        $result['project'] = $projConfigs;
    }

    if ($project && $chat) {
        $cf = COCKPIT_ROOT . '/' . $project . '/chat_' . $chat . '.json';
        if (is_file($cf)) {
            $j = json_decode(file_get_contents($cf), true);
            if (is_array($j)) {
                // Just return metadata, not the whole exchanges array (too big)
                $exchanges = $j['exchanges'] ?? [];
                $result['chat_meta'] = [
                    'exists'    => true,
                    'project'   => $j['project'] ?? null,
                    'chat'      => $j['chat']    ?? null,
                    'created'   => $j['created'] ?? null,
                    'updated'   => $j['updated'] ?? null,
                    'exchanges_count' => count($exchanges),
                    'first_message_at' => count($exchanges) > 0 ? ($exchanges[0]['timestamp'] ?? null) : null,
                    'last_message_at'  => count($exchanges) > 0 ? ($exchanges[count($exchanges)-1]['timestamp'] ?? null) : null,
                    'agents_used'      => array_values(array_unique(array_filter(array_map(function($e){
                        return $e['agent'] ?? null;
                    }, $exchanges)))),
                    'file_size' => filesize($cf),
                ];
            }
        }
    }

    echo json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false,'error'=>'Unknown action'], JSON_UNESCAPED_UNICODE);
