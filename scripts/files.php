<?php
// =============================================================================
// files.php - Filesystem API for the Cockpit sidebar
// Dario Ruggi / Cockpit
//
// GET actions:
//   ?action=projects           — list all project folders
//   ?action=chats&project=X   — list chat JSON files in a project
//   ?action=chat&project=X&chat=Y — load full chat JSON content
//   ?action=tree&project=X    — get file tree of a project folder
//
// POST actions (JSON body):
//   {action:"new_project", name:"X"}
//   {action:"new_chat", project:"X", name:"Y"}
//   {action:"rename_chat", project:"X", old:"Y", new:"Z"}
//   {action:"new_file", project:"X", path:"subdir/file.txt"}
//   {action:"new_folder", project:"X", path:"subdir/newfolder"}
//   {action:"delete", project:"X", path:"relative/path"}
//   {action:"set_active", project:"X", chat:"Y"}
// =============================================================================

header('Content-Type: application/json');

$__pj = '/var/www/html/cockpit/paths.json';
$__pr = '';
if (is_file($__pj)) { $__d = json_decode(@file_get_contents($__pj), true); if (is_array($__d) && !empty($__d['projects_root'])) $__pr = $__d['projects_root']; }
if ($__pr === '') { $__pr = (getenv('HOME') ?: '/home') . '/Software/Programing/LocalAIProjs'; }
define('COCKPIT_ROOT', $__pr);
// NOTE: www-data needs sudo access to chown for fixPerms() to work.
// Add to sudoers: www-data ALL=(root) NOPASSWD: /bin/chown, /bin/chmod
define('STATE_FILE',   '/var/www/html/cockpit/project_state.json');

// ── Helpers ──────────────────────────────────────────────────────────────────

// Sanitize a project or chat name — alphanumeric, spaces, dashes, underscores
function safeName(string $name): string {
    $name = trim($name);
    $name = preg_replace('/[^a-zA-Z0-9 _\-]/', '', $name);
    $name = preg_replace('/\s+/', ' ', $name);
    return substr($name, 0, 64);
}

// Sanitize a relative path — no traversal, no absolute paths
function safePath(string $path, string $project): string {
    $path = str_replace(['..', "\0"], '', $path);
    $path = ltrim($path, '/');
    return COCKPIT_ROOT . '/' . $project . '/' . $path;
}

// Read project_state.json
function readState(): array {
    if (file_exists(STATE_FILE)) {
        $d = json_decode(file_get_contents(STATE_FILE), true);
        if (is_array($d)) return $d;
    }
    return ['project_name' => 'default', 'chat_name' => 'default'];
}

// Write project_state.json
function writeState(array $state): void {
    $state['last_updated'] = date('Y-m-d H:i:s');
    file_put_contents(STATE_FILE, json_encode($state, JSON_PRETTY_PRINT));
}

// Fix ownership and permissions on a path so both dario and www-data can access it.
// Uses sudo — www-data must have NOPASSWD for chown in sudoers.
function fixPerms(string $path): void {
    if (!file_exists($path) && !is_dir($path)) return;
    // chown to dario:www-data and chmod 775 (dirs) or 664 (files)
    shell_exec('sudo chown -R dario:www-data ' . escapeshellarg($path) . ' 2>/dev/null');
    if (is_dir($path)) {
        shell_exec('sudo chmod -R 775 ' . escapeshellarg($path) . ' 2>/dev/null');
    } else {
        shell_exec('sudo chmod 664 ' . escapeshellarg($path) . ' 2>/dev/null');
    }
}

// Get behaviour-affecting config files from a directory
// These are files agents read as instructions/context
function getConfigFiles(string $dir): array {
    if (!is_dir($dir)) return [];
    $configs = [];
    foreach (scandir($dir) as $entry) {
        if ($entry[0] === '.') continue;
        $full = $dir . '/' . $entry;
        if (is_dir($full)) continue;
        $ext  = strtolower(pathinfo($entry, PATHINFO_EXTENSION));
        $base = strtolower(pathinfo($entry, PATHINFO_FILENAME));
        // Include: all .md, .yaml, .yml files
        // Include: .txt and .json files with behaviour-related names
        $behaviourNames = ['context','instructions','knowledge','rules','prompt',
                           'system','config','settings','notes','readme'];
        $isBehaviour = in_array($ext, ['md','yaml','yml']) ||
            (in_array($ext, ['txt','json']) && in_array($base, $behaviourNames));
        // Exclude chat JSON files
        $isChatFile = ($ext === 'json' && strpos($entry, 'chat_') === 0);
        if ($isBehaviour && !$isChatFile) {
            $configs[] = [
                'name'     => $entry,
                'ext'      => $ext,
                'size'     => filesize($full),
                'modified' => date('Y-m-d H:i', filemtime($full))
            ];
        }
    }
    usort($configs, fn($a,$b) => strcasecmp($a['name'], $b['name']));
    return $configs;
}

// Build a file tree array for a directory (max 3 levels deep)
function buildTree(string $dir, int $depth = 0, bool $rootLevel = true): array {
    if ($depth > 3 || !is_dir($dir)) return [];
    $items = [];
    $entries = @scandir($dir);
    if (!$entries) return [];
    foreach ($entries as $entry) {
        if ($entry === '.' || $entry === '..') continue;
        if ($entry[0] === '.') continue;
        $full = $dir . '/' . $entry;
        // At root level, hide chat_*.json (they appear in Chats tab)
        if ($rootLevel && !is_dir($full) &&
            pathinfo($entry, PATHINFO_EXTENSION) === 'json' &&
            strpos($entry, 'chat_') === 0) continue;
        $isDir = is_dir($full);
        $items[] = [
            'name'     => $entry,
            'type'     => $isDir ? 'dir' : 'file',
            'ext'      => $isDir ? '' : pathinfo($entry, PATHINFO_EXTENSION),
            'size'     => $isDir ? 0 : filesize($full),
            'modified' => date('Y-m-d H:i', filemtime($full)),
            'children' => $isDir ? buildTree($full, $depth + 1, false) : []
        ];
    }
    // Dirs first, then files, both alphabetical
    usort($items, function($a, $b) {
        if ($a['type'] !== $b['type']) return $a['type'] === 'dir' ? -1 : 1;
        return strcasecmp($a['name'], $b['name']);
    });
    return $items;
}

// ── Route request ─────────────────────────────────────────────────────────────
$method = $_SERVER['REQUEST_METHOD'];

if ($method === 'GET') {
    $action  = $_GET['action']  ?? '';
    $project = safeName($_GET['project'] ?? '');
    $chat    = safeName($_GET['chat']    ?? '');

    switch ($action) {

        // List all project folders with their chats and config files
        case 'projects':
            $dirs  = [];
            $state = readState();
            foreach (scandir(COCKPIT_ROOT) as $entry) {
                if ($entry[0] === '.') continue;
                if ($entry === '_standalone') continue; // handled separately
                $full = COCKPIT_ROOT . '/' . $entry;
                if (!is_dir($full)) continue;
                // Get chats
                $chats = [];
                foreach (glob($full . '/chat_*.json') ?: [] as $cf) {
                    $raw  = @file_get_contents($cf);
                    $data = $raw ? json_decode($raw, true) : [];
                    $exch = $data['exchanges'] ?? [];
                    $slug = str_replace(['chat_','.json'], '', basename($cf));
                    $chats[] = [
                        'slug'      => $slug,
                        'display'   => $data['chat'] ?? $slug,
                        'exchanges' => intdiv(count($exch), 2),
                        'updated'   => $data['updated'] ?? date('Y-m-d H:i', filemtime($cf)),
                        'empty'     => count($exch) === 0
                    ];
                }
                usort($chats, fn($a,$b) => strcmp($b['updated'], $a['updated']));
                $dirs[] = [
                    'name'     => $entry,
                    'active'   => ($entry === $state['project_name']),
                    'chats'    => $chats,
                    'configs'  => getConfigFiles($full),
                    'modified' => date('Y-m-d', filemtime($full))
                ];
            }
            echo json_encode(['ok' => true, 'projects' => $dirs]);
            break;

        // List all chats: project-owned + standalone, with config files per chat
        case 'chats':
            $state    = readState();
            $sections = [];

            // Helper to read chats from a directory
            $readChats = function(string $dir, string $ownerProject) use ($state): array {
                $chats = [];
                foreach (glob($dir . '/chat_*.json') ?: [] as $file) {
                    $raw  = @file_get_contents($file);
                    $data = $raw ? json_decode($raw, true) : [];
                    $slug = str_replace(['chat_','.json'], '', basename($file));
                    $exch = $data['exchanges'] ?? [];
                    $lastAgent = 'unknown';
                    for ($i = count($exch)-1; $i >= 0; $i--) {
                        if (($exch[$i]['role'] ?? '') === 'agent') {
                            $lastAgent = $exch[$i]['agent'] ?? 'unknown';
                            break;
                        }
                    }
                    $chats[] = [
                        'slug'       => $slug,
                        'display'    => $data['chat'] ?? $slug,
                        'project'    => $ownerProject,
                        'active'     => ($ownerProject === $state['project_name'] &&
                                        $slug === ($state['chat_name'] ?? 'default')),
                        'exchanges'  => intdiv(count($exch), 2),
                        'last_agent' => $lastAgent,
                        'updated'    => $data['updated'] ?? date('Y-m-d H:i', filemtime($file)),
                        'configs'    => getConfigFiles($dir)
                    ];
                }
                usort($chats, fn($a,$b) => strcmp($b['updated'], $a['updated']));
                return $chats;
            };

            // Standalone chats
            $standaloneDir = COCKPIT_ROOT . '/_standalone';
            if (!is_dir($standaloneDir)) { mkdir($standaloneDir, 0775, true); fixPerms($standaloneDir); }
            $standaloneChats = $readChats($standaloneDir, '_standalone');
            if ($standaloneChats) {
                $sections[] = ['label' => 'Free', 'project' => '_standalone',
                               'chats' => $standaloneChats];
            }

            // Project chats
            foreach (scandir(COCKPIT_ROOT) as $entry) {
                if ($entry[0] === '.' || $entry === '_standalone') continue;
                $full = COCKPIT_ROOT . '/' . $entry;
                if (!is_dir($full)) continue;
                $pChats = $readChats($full, $entry);
                if ($pChats) {
                    $sections[] = ['label' => $entry, 'project' => $entry,
                                   'chats' => $pChats];
                }
            }

            echo json_encode(['ok' => true, 'sections' => $sections]);
            break;

        // Load full chat content for console replay
        case 'chat':
            if (!$project || !$chat) { echo json_encode(['ok'=>false,'error'=>'Missing params']); exit; }
            $file = COCKPIT_ROOT . '/' . $project . '/chat_' . $chat . '.json';
            if (!file_exists($file)) { echo json_encode(['ok'=>false,'error'=>'Chat not found']); exit; }
            $data = json_decode(file_get_contents($file), true);
            echo json_encode(['ok' => true, 'chat' => $data]);
            break;

        // Get file tree
        case 'tree':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $dir = COCKPIT_ROOT . '/' . $project;
            echo json_encode(['ok' => true, 'tree' => buildTree($dir)]);
            break;

        default:
            echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action]);
    }

} elseif ($method === 'POST') {
    $raw = file_get_contents('php://input');
    $in  = json_decode($raw, true);
    if (!is_array($in)) { echo json_encode(['ok'=>false,'error'=>'Invalid JSON']); exit; }

    $action  = $in['action']  ?? '';
    $project = safeName($in['project'] ?? '');

    switch ($action) {

        case 'new_project':
            $name = safeName($in['name'] ?? '');
            if (!$name) $name = 'New Project';
            // Make unique
            $base = $name; $i = 2;
            while (is_dir(COCKPIT_ROOT . '/' . $name)) $name = $base . ' ' . $i++;
            $newPath = COCKPIT_ROOT . '/' . $name;
            mkdir($newPath, 0775, true);
            fixPerms($newPath);
            echo json_encode(['ok' => true, 'name' => $name]);
            break;

        case 'new_chat':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $name = safeName($in['name'] ?? '');
            if (!$name) $name = 'New Chat';
            // Make unique filename
            $slug = strtolower(str_replace(' ', '_', $name));
            $base = $slug; $i = 2;
            $dir  = $project === '_standalone'
                ? COCKPIT_ROOT . '/_standalone'
                : COCKPIT_ROOT . '/' . $project;
            if (!is_dir($dir)) mkdir($dir, 0775, true);
            while (file_exists($dir . '/chat_' . $slug . '.json')) $slug = $base . '_' . $i++;
            // Create empty chat JSON
            $chatData = [
                'project'   => $project,
                'chat'      => $name,
                'created'   => date('c'),
                'updated'   => date('c'),
                'exchanges' => []
            ];
            $chatPath = $dir . '/chat_' . $slug . '.json';
            file_put_contents($chatPath, json_encode($chatData, JSON_PRETTY_PRINT));
            fixPerms($chatPath);
            echo json_encode(['ok' => true, 'slug' => $slug, 'name' => $name]);
            break;

        case 'rename_chat':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $old  = safeName($in['old'] ?? '');
            $new  = safeName($in['new'] ?? '');
            if (!$old || !$new) { echo json_encode(['ok'=>false,'error'=>'Missing names']); exit; }
            $dir  = COCKPIT_ROOT . '/' . $project;
            $oldFile = $dir . '/chat_' . strtolower(str_replace(' ','_',$old)) . '.json';
            $newSlug = strtolower(str_replace(' ','_',$new));
            $newFile = $dir . '/chat_' . $newSlug . '.json';
            if (!file_exists($oldFile)) { echo json_encode(['ok'=>false,'error'=>'Chat not found']); exit; }
            // Update display name inside JSON
            $data = json_decode(file_get_contents($oldFile), true);
            $data['chat'] = $new;
            file_put_contents($oldFile, json_encode($data, JSON_PRETTY_PRINT));
            if ($oldFile !== $newFile) rename($oldFile, $newFile);
            echo json_encode(['ok' => true, 'slug' => $newSlug]);
            break;

        case 'set_active':
            $chat  = safeName($in['chat'] ?? 'default');
            $state = readState();
            $state['project_name'] = $project ?: $state['project_name'];
            $state['chat_name']    = strtolower(str_replace(' ','_',$chat));
            writeState($state);
            echo json_encode(['ok' => true]);
            break;

        case 'new_file':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $path = safePath($in['path'] ?? 'new_file.txt', $project);
            if (file_exists($path)) { echo json_encode(['ok'=>false,'error'=>'File exists']); exit; }
            file_put_contents($path, '');
            fixPerms($path);
            echo json_encode(['ok' => true]);
            break;

        case 'new_folder':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $path = safePath($in['path'] ?? 'new_folder', $project);
            mkdir($path, 0775, true);
            fixPerms($path);
            echo json_encode(['ok' => true]);
            break;

        case 'move_chat':
            // Move a chat from one project/standalone to another
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $targetProject = safeName($in['target'] ?? '');
            $chatSlug      = safeName($in['chat']   ?? '');
            if (!$targetProject || !$chatSlug) {
                echo json_encode(['ok'=>false,'error'=>'Missing target or chat']); exit;
            }
            $srcDir = $project === '_standalone'
                ? COCKPIT_ROOT . '/_standalone'
                : COCKPIT_ROOT . '/' . $project;
            $dstDir = $targetProject === '_standalone'
                ? COCKPIT_ROOT . '/_standalone'
                : COCKPIT_ROOT . '/' . $targetProject;
            if (!is_dir($dstDir)) mkdir($dstDir, 0775, true);
            $srcFile = $srcDir . '/chat_' . $chatSlug . '.json';
            $dstFile = $dstDir . '/chat_' . $chatSlug . '.json';
            if (!file_exists($srcFile)) {
                echo json_encode(['ok'=>false,'error'=>'Chat not found']); exit;
            }
            // Update project field inside the JSON
            $data = json_decode(file_get_contents($srcFile), true);
            $data['project'] = $targetProject;
            file_put_contents($srcFile, json_encode($data, JSON_PRETTY_PRINT));
            rename($srcFile, $dstFile);
            fixPerms($dstFile);
            echo json_encode(['ok' => true]);
            break;

        case 'delete':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project']); exit; }
            $path = safePath($in['path'] ?? '', $project);
            // Double-check path is inside cockpit root
            if (strpos(realpath($path) ?: '', COCKPIT_ROOT) !== 0) {
                echo json_encode(['ok'=>false,'error'=>'Path outside cockpit root']); exit;
            }
            if (is_dir($path)) {
                // Recursive delete
                $it = new RecursiveIteratorIterator(
                    new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS),
                    RecursiveIteratorIterator::CHILD_FIRST
                );
                foreach ($it as $f) $f->isDir() ? rmdir($f) : unlink($f);
                rmdir($path);
            } elseif (file_exists($path)) {
                unlink($path);
            }
            echo json_encode(['ok' => true]);
            break;

        default:
            echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action]);
    }
}
?>
