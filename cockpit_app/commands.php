<?php
// =============================================================================
// commands.php — discover each CLI agent's slash-commands so the UI can offer a
// "/" palette (e.g. Claude's /caveman, /btw; opencode's; aider's built-ins).
//
//   GET ?action=list&supplier=<id>  → { ok, supplier, commands:[{name,desc,source}] }
//
// Sources, merged (later wins on name collisions):
//   • plugin commands — ~/.claude/plugins/cache/…/plugins/<agent>/commands/*.md
//     (plugins ship per-agent command sets; the caveman plugin is one)
//   • user commands   — ~/.claude/commands/*.md            (claude only)
//   • project commands— <project>/.claude/commands/*.md    (claude only, if CWD known)
//   • built-ins       — curated per-agent (aider/goose/opencode have native ones)
// Read-only; local data. No secrets.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
header('Content-Type: application/json');
header('Cache-Control: no-store');

$supplier = preg_replace('/[^a-z0-9_]/', '', strtolower((string)($_GET['supplier'] ?? '')));
if ($supplier === '') { echo json_encode(['ok' => false, 'error' => 'Missing supplier']); exit; }

$home = $PATHS['home'] ?? cockpit_home();

// Which per-agent plugin dir to read. Suppliers that reuse Claude's command set
// (its plugins ship a claude/ dir) map to 'claude'; others to their own key.
$agentMap = [
    'claude' => 'claude', 'codex' => 'codex', 'gemini' => 'gemini',
    'opencode' => 'opencode', 'goose' => 'goose', 'qwen_code' => 'gemini', // qwen-code is a gemini-cli fork
];
$agentKey = $agentMap[$supplier] ?? $supplier;

// Pull a one-line description from a command file. Handles Markdown frontmatter
// (`description: …`) and Claude's TOML plugin format (`description = "…"`), else
// the first prose line.
$descOf = function (string $file): string {
    $fh = @fopen($file, 'r'); if (!$fh) return '';
    $desc = ''; $n = 0;
    while (($ln = fgets($fh)) !== false && $n++ < 25) {
        if (preg_match('/^\s*description\s*[:=]\s*(.+?)\s*$/i', $ln, $m)) { $desc = trim($m[1], " \"'"); break; }
    }
    if ($desc === '') {
        rewind($fh); $n = 0; $infm = false;
        while (($ln = fgets($fh)) !== false && $n++ < 40) {
            $t = trim($ln);
            if ($t === '---') { $infm = !$infm; continue; }
            if ($infm || $t === '' || $t[0] === '#' || $t[0] === '<' || strpos($t, '=') !== false && preg_match('/^\w+\s*=/', $t)) continue;
            $desc = $t; break;
        }
    }
    fclose($fh);
    return mb_substr($desc, 0, 140);
};

$cmds = [];
$isClaudeFamily = in_array($agentKey, ['claude', 'codex', 'gemini'], true);

// Recursively find every commands/<name>.{md,toml} under a root.
$scan = function (string $root): array {
    $files = [];
    if (!is_dir($root)) return $files;
    try {
        $it = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS | FilesystemIterator::FOLLOW_SYMLINKS),
            RecursiveIteratorIterator::LEAVES_ONLY);
        foreach ($it as $f) {
            $p = $f->getPathname();
            if (preg_match('#/commands/[^/]+\.(md|toml)$#', $p)) $files[] = $p;
        }
    } catch (\Throwable $e) {}
    return $files;
};
$add = function (string $f, string $source) use (&$cmds, $descOf) {
    $name = pathinfo($f, PATHINFO_FILENAME);
    if ($name === '') return;
    if (!isset($cmds[$name])) $cmds[$name] = ['name' => $name, 'desc' => $descOf($f), 'source' => $source];
};

// 1. Every plugin command file, classified: a `.../plugins/<agent>/commands/…` path
//    belongs to that agent; a bare `.../commands/…` (plugin root) is a general Claude
//    Code command (shared by the claude/codex/gemini family).
foreach ($scan("$home/.claude/plugins") as $f) {
    if (preg_match('#/plugins/([a-z0-9_+-]+)/commands/#', $f, $m)) {
        if ($m[1] === $agentKey) $add($f, 'plugin');       // agent-specific
    } elseif ($isClaudeFamily) {
        $add($f, 'plugin');                                 // general → claude family
    }
}
// 2. User + project custom commands (claude family).
if ($isClaudeFamily) {
    foreach ($scan("$home/.claude/commands") as $f) $add($f, 'user');
    $proj = $PATHS['projects_root'] ?? '';
    if ($proj) foreach (glob(rtrim($proj, '/') . '/*/.claude', GLOB_ONLYDIR) as $pd) {
        foreach ($scan($pd . '/commands') as $f) $add($f, 'project');
    }
}

// 3. Built-in commands the agents ship natively (not files on disk). Some are
//    interactive-only (marked); the file-discovered ones above are the ones that
//    also work headless via -p. This list is for reference in the help/palette.
$BUILTINS = [
    'claude' => [
        ['name'=>'help','desc'=>'List available commands'],
        ['name'=>'model','desc'=>'Switch the Claude model'],
        ['name'=>'compact','desc'=>'Summarise + compact the conversation'],
        ['name'=>'clear','desc'=>'Clear conversation history (interactive)'],
        ['name'=>'review','desc'=>'Review a PR / the current changes'],
        ['name'=>'agents','desc'=>'Manage subagents'],
        ['name'=>'mcp','desc'=>'Manage MCP servers'],
        ['name'=>'init','desc'=>'Generate a CLAUDE.md for the project'],
        ['name'=>'memory','desc'=>'Edit memory files'],
        ['name'=>'cost','desc'=>'Show token cost/usage'],
        ['name'=>'config','desc'=>'Open settings (interactive)'],
        ['name'=>'add-dir','desc'=>'Add a working directory'],
        ['name'=>'rewind','desc'=>'Rewind to an earlier checkpoint'],
        ['name'=>'resume','desc'=>'Resume a previous session'],
    ],
    'codex' => [
        ['name'=>'help','desc'=>'Show Codex help'],
        ['name'=>'model','desc'=>'Switch model / reasoning effort'],
        ['name'=>'approvals','desc'=>'Set the sandbox / approval mode'],
        ['name'=>'init','desc'=>'Create an AGENTS.md for the project'],
        ['name'=>'compact','desc'=>'Compact the conversation'],
    ],
    'gemini' => [
        ['name'=>'help','desc'=>'List Gemini CLI commands'],
        ['name'=>'chat','desc'=>'Manage chat sessions'],
        ['name'=>'compress','desc'=>'Compress the context'],
        ['name'=>'mcp','desc'=>'Manage MCP servers'],
        ['name'=>'tools','desc'=>'List available tools'],
    ],
    'aider' => [
        ['name'=>'add','desc'=>'Add files to the chat context'],
        ['name'=>'drop','desc'=>'Remove files from the chat'],
        ['name'=>'run','desc'=>'Run a shell command and add its output'],
        ['name'=>'test','desc'=>'Run the test command, add failures to chat'],
        ['name'=>'diff','desc'=>'Show pending diff'],
        ['name'=>'commit','desc'=>'Commit edits made outside the chat'],
        ['name'=>'undo','desc'=>'Undo the last aider commit'],
        ['name'=>'ask','desc'=>'Ask a question without editing files'],
        ['name'=>'architect','desc'=>'Plan/architect mode'],
        ['name'=>'model','desc'=>'Switch the main model'],
        ['name'=>'web','desc'=>'Fetch a URL into the chat'],
        ['name'=>'tokens','desc'=>'Report token usage/cost'],
    ],
    'goose' => [
        ['name'=>'help','desc'=>'List Goose commands'],
        ['name'=>'exit','desc'=>'End the session'],
        ['name'=>'extension','desc'=>'Enable/disable MCP extensions'],
        ['name'=>'mode','desc'=>'Switch approval mode'],
        ['name'=>'recipe','desc'=>'Run a saved recipe'],
    ],
    'opencode' => [
        ['name'=>'init','desc'=>'Initialize opencode in the project'],
        ['name'=>'help','desc'=>'Show help'],
        ['name'=>'models','desc'=>'List/switch models'],
        ['name'=>'share','desc'=>'Share the session'],
    ],
];
foreach (($BUILTINS[$supplier] ?? []) as $b) {
    if (!isset($cmds[$b['name']])) $cmds[$b['name']] = $b + ['source' => 'builtin'];
}

ksort($cmds);
echo json_encode(['ok' => true, 'supplier' => $supplier, 'agent_key' => $agentKey,
    'commands' => array_values($cmds), 'count' => count($cmds)], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
