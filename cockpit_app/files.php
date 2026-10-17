<?php
if (!function_exists('mb_strlen'))    { function mb_strlen($s, $e=null)           { return strlen($s); } }
if (!function_exists('mb_substr'))    { function mb_substr($s,$st,$l=null,$e=null) { return $l===null ? substr($s,$st) : substr($s,$st,$l); } }
if (!function_exists('mb_strtolower')){ function mb_strtolower($s, $e=null)        { return strtolower($s); } }
if (!function_exists('mb_strpos'))    { function mb_strpos($h,$n,$o=0,$e=null)     { return strpos($h,$n,$o); } }
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

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

ed_gate_or_exit('files');   // demo: described-modal; v1/v2: real

define('COCKPIT_ROOT', $PATHS['projects_root']);

// Heal malformed JSON: escape raw control chars inside string values
function healJson(string $raw): ?array {
    // agent_loop.sh before build 87 wrote sub-second durations as ".9" (bc's output):
    // fine for jq, a syntax error for PHP. Old chat files keep them; mend on read.
    $raw = preg_replace('/("duration_s":\s*)\.(\d)/', '${1}0.$2', $raw);
    $data = json_decode($raw, true);
    if ($data !== null || $raw === '' || $raw === 'null') return $data;
    $len = strlen($raw); $out = ''; $inStr = false;
    for ($i = 0; $i < $len; $i++) {
        $c = $raw[$i];
        if ($c === '"' && ($i === 0 || $raw[$i-1] !== '\\')) { $inStr = !$inStr; $out .= $c; continue; }
        if ($inStr && ord($c) < 0x20 && $c !== "\t") {
            if ($c === "\n") $out .= '\\n';
            elseif ($c === "\r") $out .= '\\r';
            else $out .= sprintf('\\u%04x', ord($c));
        } else { $out .= $c; }
    }
    return json_decode($out, true);
}

// ── Project metadata (.cockpit_project.json) ────────────────────────────────
// goal  — one sentence: what this project is for. agent_loop.sh prepends it to
//         every dispatch, the info bar shows it, the Artifacts tab captions it.
// icon/color — cosmetic, for the projects list.
function project_meta_load(string $projDir): array {
    $f = rtrim($projDir, '/') . '/.cockpit_project.json';
    $j = is_readable($f) ? json_decode((string)file_get_contents($f), true) : null;
    return is_array($j) ? $j : [];
}
// ── Chat metadata (<project>/.chat_meta/<chat>.json), 2026-10-06 ─────────────────────────────────────────────────
// Scope rules: the KIND belongs to the PROJECT (every chat in it inherits it); the GOAL belongs to the CHAT. A free (standalone)
// chat has no project to hold a kind, so it keeps both goal and kind of its own here. A project's own goal (.cockpit_project.json,
// written before this) is still honoured as the fallback for chats that have none, so nothing already written is lost.
function chat_meta_path(string $projDir, string $chat): string {
    return rtrim($projDir, '/') . '/.chat_meta/' . strtolower(str_replace(' ', '_', safeName($chat === '' ? 'default' : $chat))) . '.json';   // the same slug rule as chat_<slug>.json
}
function chat_meta_load(string $projDir, string $chat): array {
    $f = chat_meta_path($projDir, $chat);
    $j = is_readable($f) ? json_decode((string)file_get_contents($f), true) : null;
    return is_array($j) ? $j : [];
}
function chat_meta_save(string $projDir, string $chat, array $patch): bool {
    $f = chat_meta_path($projDir, $chat); $d = dirname($f);
    if (!is_dir($d) && !@mkdir($d, 0775, true) && !is_dir($d)) return false;
    $meta = array_merge(chat_meta_load($projDir, $chat), $patch); $meta['updated'] = date('c');
    $ok = @file_put_contents($f, json_encode($meta, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), LOCK_EX) !== false;
    if ($ok) @chmod($f, 0664);
    return $ok;
}
/** What applies to one chat: goal (chat's own, else the project's older one) and kind (project's; a free chat's own). */
function chat_effective(string $projDir, string $project, string $chat): array {
    $pm = project_meta_load($projDir); $cm = $chat === '' ? [] : chat_meta_load($projDir, $chat);
    $free = ($project === '' || $project === '_standalone');
    $kindSrc = $free ? $cm : $pm;
    return ['goal' => (string)($cm['goal'] ?? ($free ? '' : ($pm['goal'] ?? ''))),
            'goal_inherited' => !isset($cm['goal']) && !$free && !empty($pm['goal']),
            'description' => (string)($cm['description'] ?? ''), 'desc_send' => !empty($cm['desc_send']),
            'project_description' => $free ? '' : (string)($pm['description'] ?? ''), 'project_desc_send' => !$free && !empty($pm['desc_send']),
            'kind' => (string)($kindSrc['kind'] ?? 'general'), 'kind_name' => (string)($kindSrc['kind_name'] ?? ''), 'kind_note' => (string)($kindSrc['kind_note'] ?? '')];
}
// ---- Project kinds: what a project IS (a Lazarus app, a VB6 migration, a game…).
// Two sources, merged: the SHIPPED kinds in kinds/*.json (replaced by every update), and the person's OWN kinds in
// <cockpit_data>/kinds/*.json (per login, never touched by an update). A user kind with the id of a shipped one OVERRIDES it.
// A kind carries a one-paragraph standing note that rides on every prompt in the project, beside the goal
// (agent_loop.sh reads it from .cockpit_project.json), a hint of what will judge the work, and (schema v2, optional) the tools it uses.
require_once __DIR__ . '/tools_lib.php';
require_once __DIR__ . '/kinds_lib.php';   // kinds_user_dir, kind_validate, kind_user_save, kind tool definitions
/** All kinds: shipped, then the person's own on top. Each carries _source ('shipped' | 'user') and, for a user kind with a shipped id, _overrides. */
function kinds_load(?array &$problems = null): array {
    $out = []; $problems = [];
    foreach (glob(__DIR__ . '/kinds/*.json') ?: [] as $f) {
        $k = json_decode((string)@file_get_contents($f), true);
        if (is_array($k) && !empty($k['id']) && preg_match('/^[a-z0-9\-]{1,40}$/', $k['id'])) { $k['_source'] = 'shipped'; $out[$k['id']] = $k; }
    }
    $ud = kinds_user_dir();
    foreach (is_dir($ud) ? (glob($ud . '/*.json') ?: []) : [] as $f) {
        $raw = json_decode((string)@file_get_contents($f), true);
        $err = ''; $k = kind_validate($raw, $err);
        if ($k === null) { $problems[] = ['file' => basename($f), 'error' => $err]; continue; }
        if (basename($f) !== $k['id'] . '.json') { $problems[] = ['file' => basename($f), 'error' => 'the file name must be the id (' . $k['id'] . '.json)']; continue; }
        $k['_source'] = 'user'; if (isset($out[$k['id']])) $k['_overrides'] = true;
        $out[$k['id']] = $k;
    }
    ksort($out); if (isset($out['general'])) { $g = ['general' => $out['general']]; unset($out['general']); $out = $g + $out; }
    return $out;
}
/** What the kind's tools are on THIS machine: known, installed, how to install. */
function kind_tools_report(array $k): array {
    global $PATHS;
    $data = rtrim((string)($PATHS['cockpit_data'] ?? ''), '/');
    $state = json_decode((string)@file_get_contents($data . '/tools_state.json'), true); if (!is_array($state)) $state = ['tools' => []];
    $rep = [];
    foreach ((array)($k['tools'] ?? []) as $t) {
        $def = tools_def_find((string)$t['tool'], $data, __DIR__ . '/tools_builtins');
        $row = ['tool' => $t['tool'], 'why' => $t['why'] ?? '', 'known' => $def !== null, 'installed' => false, 'name' => $def['name'] ?? $t['tool'], 'hint' => ''];
        if (!empty($t['preset'])) $row['preset'] = $t['preset'];
        if ($def !== null) { $row['installed'] = resolve_binary($def, $state) !== null; if (!$row['installed']) $row['hint'] = tools_install_hint($def); }
        else $row['hint'] = 'This tool is not known on this machine.';
        $rep[] = $row;
    }
    return $rep;
}
/** Suggest a kind by looking for its marker files in the project folder (and one folder down). */
function kind_detect(string $dir): ?array {
    foreach (kinds_load() as $id => $k) {
        foreach ((array)($k['detect'] ?? []) as $pat) {
            $hit = glob($dir . '/' . $pat) ?: glob($dir . '/*/' . $pat) ?: [];
            if ($hit) return ['kind' => $id, 'name' => $k['name'], 'found' => basename($hit[0])];
        }
    }
    return null;
}
/** One sentence for the standing note naming the kind's tools that are installed here, in the form an agent can run (%%TOOL:id:preset:input%%). */
function kind_tools_hint(array $k): string {
    global $PATHS;
    if (empty($k['tools'])) return '';
    $data = rtrim((string)($PATHS['cockpit_data'] ?? ''), '/');
    $bits = [];
    foreach (kind_tools_report($k) as $t) {
        if (!$t['installed']) continue;
        $def = tools_def_find((string)$t['tool'], $data, __DIR__ . '/tools_builtins');
        $presets = !empty($t['preset']) ? [$t['preset']] : array_slice(array_map(fn($p) => (string)($p['id'] ?? ''), (array)($def['presets'] ?? [])), 0, 4);
        foreach ($presets as $p) if ($p !== '') $bits[] = $t['tool'] . ':' . $p;
    }
    if (!$bits) return '';
    return mb_substr('Tools you can run here (as %%TOOL:id:preset:path%%, or %%TOOL:id:preset:path|name=value%% when a preset needs arguments): ' . implode(', ', $bits) . '.', 0, 420);
}
function kind_meta_patch(string $id): ?array {   // what to store for a kind id, or null when unknown
    $all = kinds_load(); if (!isset($all[$id])) return null;
    $k = $all[$id];
    $note = mb_substr((string)($k['note'] ?? ''), 0, 900);
    $hint = kind_tools_hint($k);
    return ['kind' => $id, 'kind_name' => (string)$k['name'], 'kind_note' => $note . ($hint !== '' ? ' ' . $hint : '')];
}
function project_meta_save(string $projDir, array $patch): bool {
    $f = rtrim($projDir, '/') . '/.cockpit_project.json';
    $meta = array_merge(project_meta_load($projDir), $patch);
    $meta['updated'] = date('c');
    $ok = @file_put_contents($f, json_encode($meta, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), LOCK_EX) !== false;
    if ($ok) @chmod($f, 0664);
    return $ok;
}
// HIGH-121: STATE_FILE derived from script dir so it stays alongside bridge.php
// regardless of where the cockpit web root is.
define('STATE_FILE',   __DIR__ . '/project_state.json');

// H3: raw — stream a project file with a proper content-type (for <img> in the
// gallery). Must run before any JSON output. Images only, capped at 8 MB.
if (($_GET['action'] ?? '') === 'raw') {
    $project = $_GET['project'] ?? '';
    $rawPath = ltrim((string)($_GET['path'] ?? ''), '/');
    $rawPath = str_replace(['../', '..\\'], '', $rawPath);
    $root    = $GLOBALS['COCKPIT_ROOT_OVERRIDE'] ?? COCKPIT_ROOT;
    $projDir = realpath($root . '/' . $project);
    $full    = realpath($root . '/' . $project . '/' . $rawPath);
    if (!$full || !$projDir || strpos($full, $projDir) !== 0 || !is_file($full)) {
        header('Content-Type: text/plain'); http_response_code(404); echo 'Not found'; exit;
    }
    $ext = strtolower(pathinfo($full, PATHINFO_EXTENSION));
    $types = ['png'=>'image/png','jpg'=>'image/jpeg','jpeg'=>'image/jpeg','gif'=>'image/gif',
              'webp'=>'image/webp','bmp'=>'image/bmp','svg'=>'image/svg+xml'];
    if (!isset($types[$ext])) { header('Content-Type: text/plain'); http_response_code(415); echo 'Unsupported'; exit; }
    if (filesize($full) > 8*1024*1024) { header('Content-Type: text/plain'); http_response_code(413); echo 'Too large'; exit; }
    header('Content-Type: ' . $types[$ext]);
    header('Cache-Control: private, max-age=300');
    readfile($full);
    exit;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

// Sanitize a project or chat name — allow Unicode letters/digits + space/_/-/.
// XCUT-5 fix: previously stripped Hebrew/Spanish to empty. The /u flag enables
// Unicode property classes; we block only path separators, control bytes,
// and reserved filesystem chars.
function safeName(string $name): string {
    $name = trim($name);
    // Block path separators, control bytes, NUL, and Windows-reserved chars
    $name = (string)preg_replace('/[\/\\\\\x00-\x1f<>:"|?*]/u', '', $name);
    // Collapse consecutive dots to prevent .. traversal in slugs
    $name = (string)preg_replace('/\.\.+/u', '.', $name);
    // No leading dot: "../../x" collapsed to ".x", which made a HIDDEN project folder that no list shows
    // and nothing can delete (found 2026-10-02).
    $name = ltrim($name, '.');
    // Collapse whitespace
    $name = (string)preg_replace('/\s+/u', ' ', $name);
    return mb_substr($name, 0, 64);
}

// Sanitize a relative path — no traversal, no absolute paths
function safePath(string $path, string $project): string {
    // First line of defence: strip traversal sequences and leading slashes.
    // ($project is already safeName()-sanitized by every caller.)
    $path = str_replace(['..', "\0"], '', $path);
    $path = ltrim($path, '/');
    $candidate = COCKPIT_ROOT . '/' . $project . '/' . $path;

    // Second line: realpath containment, matching the read handlers and the
    // delete case (so every write path is guarded the same way, not just
    // some). The target file often doesn't exist yet, so resolve the deepest
    // ANCESTOR that does exist and confirm IT sits under COCKPIT_ROOT — that
    // catches symlink-out and any escape the string strip above missed.
    // Returns '' on any violation; every caller treats '' as an error.
    $rootReal = realpath(COCKPIT_ROOT);
    if ($rootReal === false) return '';
    $probe = $candidate;
    while ($probe !== '' && $probe !== '/' && !file_exists($probe)) {
        $parent = dirname($probe);
        if ($parent === $probe) break;
        $probe = $parent;
    }
    $anchorReal = realpath($probe);
    if ($anchorReal === false) return '';
    if ($anchorReal !== $rootReal
        && strpos($anchorReal, $rootReal . '/') !== 0) {
        return '';
    }
    return $candidate;
}

// Read project_state.json
function readState(): array {
    if (file_exists(STATE_FILE)) {
        $d = json_decode(file_get_contents(STATE_FILE), true);
        if (is_array($d)) return $d;
    }
    return ['project_name' => 'default', 'chat_name' => 'default'];
}

// Write project_state.json — atomic .tmp + rename to prevent corruption
// when two set_active requests race (HIGH-107).
function writeState(array $state): void {
    $state['last_updated'] = date('Y-m-d H:i:s');
    $json = json_encode($state, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);
    // Write IN PLACE (the state file is group-writable). The old tmp+rename put
    // the tmp in the docroot, which www-data cannot write (dir is 755) — so the
    // write silently failed and set_active never persisted, making the status
    // poll revert every selection back to the stale default/default state.
    if (@file_put_contents(STATE_FILE, $json, LOCK_EX) !== false) { @chmod(STATE_FILE, 0664); return; }
    // Fallback (e.g. file missing): tmp+rename, which needs a writable dir.
    $tmp = STATE_FILE . '.tmp';
    if (@file_put_contents($tmp, $json) !== false) { @chmod($tmp, 0664); @rename($tmp, STATE_FILE); }
}

// Fix ownership and permissions on a path so both dario and www-data can access it.
// MED-110: only run sudo when ownership is actually wrong, and use -n (non-interactive)
// so we never hang waiting for a password if sudoers isn't configured. If the file
// is already owned by dario:www-data (typical) we just chmod (no sudo needed).
// Chat names are GLOBALLY unique (one name = one chat, across every project and
// the Free store) — simpler and collision-proof for move/detach. Returns true if
// a chat_<slug>.json already exists anywhere under the projects root.
function chatSlugTaken(string $slug): bool {
    if ($slug === '') return false;
    $dirs = [COCKPIT_ROOT . '/_standalone'];
    foreach (scandir(COCKPIT_ROOT) ?: [] as $e) {
        if ($e[0] === '.' || $e === '_standalone' || $e === 'Public') continue;
        $d = COCKPIT_ROOT . '/' . $e;
        if (is_dir($d)) $dirs[] = $d;
    }
    foreach ($dirs as $d) {
        if (file_exists($d . '/chat_' . $slug . '.json')) return true;
    }
    return false;
}

function fixPerms(string $path): void {
    if (!file_exists($path) && !is_dir($path)) return;
    // Web (this, www-data) and the agent daemon (dario) share files. The
    // installer puts www-data in dario's group, so we make everything group-owned
    // by the OWNER's group (dario) and group-writable — then BOTH can read+write
    // without any sudo. Directories get setgid so children inherit the group.
    // (The old design chown'd to dario:www-data via sudo, which had no NOPASSWD
    //  entry and silently failed → www-data-created chats stayed unwritable by the
    //  agent, so its appended responses were lost.)
    static $ogrp = null;
    if ($ogrp === null) {
        $ogrp = cockpit_owner_user();   // fallback: user-private-group name
        if (function_exists('posix_getpwnam')) {
            $pw = @posix_getpwnam(cockpit_owner_user());
            if ($pw && function_exists('posix_getgrgid')) {
                $g = @posix_getgrgid($pw['gid']);
                if ($g && !empty($g['name'])) $ogrp = $g['name'];
            }
        }
    }
    @chgrp($path, $ogrp);   // www-data is a member of this group → allowed, no sudo
    if (is_dir($path)) @chmod($path, 02775);   // setgid: new children inherit the group
    else               @chmod($path, 0664);
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
                if ($entry === '_standalone' || $entry === 'Public') continue; // handled separately
                $full = COCKPIT_ROOT . '/' . $entry;
                if (!is_dir($full)) continue;
                // Get chats
                $chats = [];
                foreach (glob($full . '/chat_*.json') ?: [] as $cf) {
                    $raw  = @file_get_contents($cf);
                    $data = $raw ? json_decode($raw, true) : [];
                    $exch = $data['exchanges'] ?? [];
                    $_bn = basename($cf, '.json');
                    $slug = (strpos($_bn, 'chat_') === 0) ? substr($_bn, 5) : $_bn;
                    $chats[] = [
                        'slug'      => $slug,
                        'display'   => $data['chat'] ?? $slug,
                        'exchanges' => intdiv(count($exch), 2),
                        'description' => (string)(chat_meta_load($full, $slug)['description'] ?? ''),
                        'updated'   => $data['updated'] ?? date('Y-m-d H:i', filemtime($cf)),
                        'empty'     => count($exch) === 0
                    ];
                }
                usort($chats, fn($a,$b) => strcmp($b['updated'], $a['updated']));
                $dirs[] = [
                    'name'     => $entry,
                    'description' => (string)(project_meta_load($full)['description'] ?? ''),
                    'active'   => ($entry === $state['project_name']),
                    'chats'    => $chats,
                    'configs'  => getConfigFiles($full),
                    'modified' => date('Y-m-d', filemtime($full))
                ];
            }
            echo json_encode(['ok' => true, 'projects' => $dirs], JSON_UNESCAPED_UNICODE);
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
                    $data = $raw ? (healJson($raw) ?? []) : [];
                    $bn = basename($file, '.json');
                    $slug = (strpos($bn, 'chat_') === 0) ? substr($bn, 5) : $bn;
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
                        'description'=> (string)(chat_meta_load($dir, $slug)['description'] ?? ''),
                        'empty'      => count($exch) === 0,   // raw: any message (incl. lone intro) counts
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
                if ($entry[0] === '.' || $entry === '_standalone' || $entry === 'Public') continue;
                $full = COCKPIT_ROOT . '/' . $entry;
                if (!is_dir($full)) continue;
                $pChats = $readChats($full, $entry);
                if ($pChats) {
                    $sections[] = ['label' => $entry, 'project' => $entry,
                                   'chats' => $pChats];
                }
            }

            echo json_encode(['ok' => true, 'sections' => $sections], JSON_UNESCAPED_UNICODE);
            break;

        // E5: minimal list of chat slugs for a single project (used by auto-naming)
        case 'list_chats':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); break; }
            $dir = ($project === '_standalone')
                 ? COCKPIT_ROOT . '/_standalone'
                 : COCKPIT_ROOT . '/' . $project;
            $chats = [];
            if (is_dir($dir)) {
                foreach (glob($dir . '/chat_*.json') ?: [] as $cf) {
                    $_bn = basename($cf, '.json');
                    $chats[] = (strpos($_bn, 'chat_') === 0) ? substr($_bn, 5) : $_bn;
                }
            }
            echo json_encode(['ok'=>true, 'project'=>$project, 'chats'=>$chats], JSON_UNESCAPED_UNICODE);
            break;

        // Load full chat content for console replay
        case 'chat':
            if (!$project || !$chat) { echo json_encode(['ok'=>false,'error'=>'Missing params'], JSON_UNESCAPED_UNICODE); exit; }
            $file = COCKPIT_ROOT . '/' . $project . '/chat_' . $chat . '.json';
            if (!file_exists($file)) { echo json_encode(['ok'=>false,'error'=>'Chat not found'], JSON_UNESCAPED_UNICODE); exit; }
            $data = healJson(file_get_contents($file));
            echo json_encode(['ok' => true, 'chat' => $data], JSON_UNESCAPED_UNICODE);
            break;

        // Get file tree
        case 'tree':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $dir = COCKPIT_ROOT . '/' . $project;
            echo json_encode(['ok' => true, 'tree' => buildTree($dir)], JSON_UNESCAPED_UNICODE);
            break;

        // E7: search across all conversation history. Scans chat_*.json in every
        // project (and _standalone), matches query terms against exchange text,
        // returns ranked hits with a snippet around the match.
        case 'search_history':
            $q = trim((string)($_GET['q'] ?? ''));
            if ($q === '') { echo json_encode(['ok'=>false,'error'=>'Empty query'], JSON_UNESCAPED_UNICODE); exit; }
            $qLower = mb_strtolower($q);
            $terms  = array_values(array_filter(preg_split('/\s+/u', $qLower)));
            $scopeProject = trim((string)($_GET['project'] ?? ''));  // optional: limit to one project
            $root = $GLOBALS['COCKPIT_ROOT_OVERRIDE'] ?? COCKPIT_ROOT;
            $hits = [];
            $maxHits = 100;

            // Gather chat files: each project dir + _standalone
            $chatFiles = [];
            $dirs = [];
            if ($scopeProject !== '') {
                $dirs[] = [$scopeProject, $root . '/' . $scopeProject];
            } else {
                foreach (@scandir($root) ?: [] as $e) {
                    if ($e === '.' || $e === '..' || $e[0] === '.') continue;
                    $pd = $root . '/' . $e;
                    if (is_dir($pd)) $dirs[] = [$e, $pd];
                }
            }
            foreach ($dirs as [$projName, $pd]) {
                foreach (glob($pd . '/chat_*.json') ?: [] as $cf) {
                    if (strpos(basename($cf), 'chat__') === 0) continue;   // scratch chats (Summarize) are not history
                    $chatFiles[] = [$projName, $cf];
                }
            }

            foreach ($chatFiles as [$projName, $cf]) {
                if (count($hits) >= $maxHits) break;
                $raw = @file_get_contents($cf);
                if ($raw === false) continue;
                $json = json_decode($raw, true);
                if (!is_array($json) || empty($json['exchanges'])) continue;
                $_bn = basename($cf, '.json');
                $chatSlug = (strpos($_bn, 'chat_') === 0) ? substr($_bn, 5) : $_bn;
                foreach ($json['exchanges'] as $ex) {
                    if (count($hits) >= $maxHits) break;
                    $text = (string)($ex['text'] ?? '');
                    if ($text === '') continue;
                    $tLower = mb_strtolower($text);
                    // All terms must be present (AND match)
                    $score = 0; $firstPos = -1;
                    $allFound = true;
                    foreach ($terms as $term) {
                        $pos = mb_strpos($tLower, $term);
                        if ($pos === false) { $allFound = false; break; }
                        $score++;
                        if ($firstPos < 0 || $pos < $firstPos) $firstPos = $pos;
                    }
                    if (!$allFound) continue;
                    // Build a snippet around the first match
                    $start = max(0, $firstPos - 60);
                    $snippet = mb_substr($text, $start, 200);
                    if ($start > 0) $snippet = '…' . $snippet;
                    if (mb_strlen($text) > $start + 200) $snippet .= '…';
                    $hits[] = [
                        'project' => $projName,
                        'chat'    => $chatSlug,
                        'role'    => $ex['role']  ?? '',
                        'agent'   => $ex['agent'] ?? '',
                        'ts'      => $ex['ts']    ?? ($ex['timestamp'] ?? ''),
                        'snippet' => $snippet,
                        'score'   => $score,
                    ];
                }
            }
            // Sort by score desc, then most recent ts desc
            usort($hits, function($a, $b) {
                if ($a['score'] !== $b['score']) return $b['score'] - $a['score'];
                return strcmp((string)$b['ts'], (string)$a['ts']);
            });
            echo json_encode(['ok'=>true, 'query'=>$q, 'count'=>count($hits), 'hits'=>$hits], JSON_UNESCAPED_UNICODE);
            break;

        case 'project_meta':      // read-only, for the goal label and the kind badge. (Until 2026-10-03 this existed
                                  // only under POST while the JS asked with GET, so a saved goal never showed after a reload.)
            $pd = ($project === '' || $project === '_standalone') ? COCKPIT_ROOT . '/_standalone' : COCKPIT_ROOT . '/' . $project;
            $ch = (string)($_GET['chat'] ?? '');
            echo json_encode(['ok' => true, 'project' => $project, 'chat' => $ch, 'meta' => project_meta_load($pd), 'effective' => chat_effective($pd, $project, $ch)], JSON_UNESCAPED_UNICODE);
            break;

        case 'kinds':
            $list = []; $bad = [];
            foreach (kinds_load($bad) as $id => $k) {
                $row = ['id' => $id, 'name' => $k['name'], 'icon' => $k['icon'] ?? 'folder', 'description' => $k['description'] ?? '', 'verify' => $k['verify'] ?? '',
                        'source' => $k['_source'] ?? 'shipped', 'overrides' => !empty($k['_overrides'])];
                $row['group'] = $k['group'] ?? (($k['_source'] ?? '') === 'user' ? 'My kinds' : 'Other'); $row['details'] = $k['details'] ?? ''; $row['examples'] = $k['examples'] ?? []; $row['detect'] = $k['detect'] ?? [];
                if (!empty($k['starter'])) $row['starter'] = array_map(fn($x) => $x['path'], $k['starter']);
                $row['note'] = $k['note'] ?? '';   // the wizard prefills from it (edit, or duplicate a shipped kind into your own)
                if (!empty($k['tools'])) { $row['tools'] = kind_tools_report($k); $row['tools_missing'] = count(array_filter($row['tools'], fn($t) => !$t['installed'])); }
                $list[] = $row;
            }
            echo json_encode(['ok' => true, 'kinds' => $list, 'problems' => $bad], JSON_UNESCAPED_UNICODE);
            break;

        case 'kind_export':     // one kind as plain JSON (what the wizard saves), to share
            $kid = (string)($_GET['id'] ?? ''); $all = kinds_load();
            if (!isset($all[$kid])) { echo json_encode(['ok' => false, 'error' => 'No such kind'], JSON_UNESCAPED_UNICODE); break; }
            $e = $all[$kid]; unset($e['_source'], $e['_overrides']); $err = ''; $clean = kind_validate($e, $err);
            echo json_encode(['ok' => $clean !== null, 'kind' => $clean, 'error' => $err], JSON_UNESCAPED_UNICODE);
            break;

        case 'detect_kind':
            if (!$project) { echo json_encode(['ok' => false, 'error' => 'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $pdir = realpath(COCKPIT_ROOT . '/' . $project);
            echo json_encode(['ok' => true, 'suggest' => ($pdir && is_dir($pdir)) ? kind_detect($pdir) : null], JSON_UNESCAPED_UNICODE);
            break;

        case 'stat':
            // Cheap change check for the viewer's file watcher: size + mtime, no content.
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $path = str_replace(['../', '..\\'], '', ltrim($_GET['path'] ?? '', '/'));
            $full = realpath(COCKPIT_ROOT . '/' . $project . '/' . $path);
            $projectDir = realpath(COCKPIT_ROOT . '/' . $project);
            if (!$full || !$projectDir || strpos($full, $projectDir) !== 0 || !is_file($full)) {
                echo json_encode(['ok'=>false,'error'=>'gone'], JSON_UNESCAPED_UNICODE); exit;
            }
            clearstatcache(true, $full);
            // mtime has one-second granularity, and an editor that saves twice in a second (or replaces the file
            // by rename, as most do) would look unchanged: size and inode go into the signature too.
            echo json_encode(['ok'=>true, 'size'=>filesize($full), 'mtime'=>filemtime($full), 'sig'=>filemtime($full) . ':' . filesize($full) . ':' . (int)@fileinode($full)], JSON_UNESCAPED_UNICODE);
            break;

        case 'read':
            // Read file contents — used by sidebar click to show in viewer
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $path = $_GET['path'] ?? '';
            // Sanitize: no leading slash, no .. traversal
            $path = ltrim($path, '/');
            $path = str_replace(['../', '..\\'], '', $path);
            $full = realpath(COCKPIT_ROOT . '/' . $project . '/' . $path);
            // Security: must stay inside the project directory
            $projectDir = realpath(COCKPIT_ROOT . '/' . $project);
            if (!$full || !$projectDir || strpos($full, $projectDir) !== 0) {
                echo json_encode(['ok'=>false,'error'=>'Path outside project'], JSON_UNESCAPED_UNICODE); exit;
            }
            if (!is_file($full)) {
                echo json_encode(['ok'=>false,'error'=>'Not a file'], JSON_UNESCAPED_UNICODE); exit;
            }
            // Limit to 2MB to avoid choking the browser
            $size = filesize($full);
            if ($size > 2 * 1024 * 1024) {
                echo json_encode(['ok'=>false,'error'=>'File too large (>2MB)'], JSON_UNESCAPED_UNICODE); exit;
            }
            $content = file_get_contents($full);
            echo json_encode([
                'ok'      => true,
                'path'    => $path,
                'size'    => $size,
                'mtime'   => filemtime($full),
                'content' => $content
            ], JSON_UNESCAPED_UNICODE);
            break;

        default:
            echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
    }

} elseif ($method === 'POST') {
    $raw = file_get_contents('php://input');
    $in  = json_decode($raw, true);
    if (!is_array($in)) { echo json_encode(['ok'=>false,'error'=>'Invalid JSON'], JSON_UNESCAPED_UNICODE); exit; }

    $action  = $in['action']  ?? '';
    $project = safeName($in['project'] ?? '');

    switch ($action) {

        case 'new_project':
            $name = safeName($in['name'] ?? '');
            if (!$name) $name = 'New Project';
            // Make unique
            $base = $name; $i = 2;
            while (is_dir(COCKPIT_ROOT . '/' . $name) || strcasecmp($name, 'Public') === 0) $name = $base . ' ' . $i++;   // "Public" is the file window's folder, never a project
            $newPath = COCKPIT_ROOT . '/' . $name;
            mkdir($newPath, 0775, true);
            fixPerms($newPath);
            // A project's GOAL: one sentence saying what this project is for. Stored in
            // .cockpit_project.json beside the chats and prepended to every dispatch by
            // agent_loop.sh, so every agent knows the point of the folder it works in.
            $goal = trim((string)($in['goal'] ?? ''));
            if ($goal !== '') project_meta_save($newPath, ['goal' => mb_substr($goal, 0, 600)]);
            if (!empty($in['kind']) && ($kp = kind_meta_patch((string)$in['kind'])) !== null) project_meta_save($newPath, $kp);
            echo json_encode(['ok' => true, 'name' => $name, 'goal' => $goal], JSON_UNESCAPED_UNICODE);
            break;

        case 'project_meta':      // read  {project}
            $pn = safeName($in['project'] ?? $_GET['project'] ?? '');
            $pd = ($pn === '' || $pn === '_standalone') ? COCKPIT_ROOT . '/_standalone' : COCKPIT_ROOT . '/' . $pn;
            $ch = (string)($in['chat'] ?? '');
            echo json_encode(['ok' => true, 'project' => $pn, 'chat' => $ch, 'meta' => project_meta_load($pd), 'effective' => chat_effective($pd, $pn, $ch)], JSON_UNESCAPED_UNICODE);
            break;

        case 'kind_save':      // the wizard: create or edit one of the person's own kinds
        case 'kind_import':    // the same, from the JSON of an exported kind
            auth_require_writer();
            $raw = $action === 'kind_import' ? json_decode((string)($in['json'] ?? ''), true) : ($in['kind'] ?? null);
            $err = ''; $k = kind_validate($raw, $err);
            if ($k === null) { echo json_encode(['ok' => false, 'error' => $err ?: 'not valid JSON'], JSON_UNESCAPED_UNICODE); break; }
            $ex = kinds_load(); $mine = isset($ex[$k['id']]) && ($ex[$k['id']]['_source'] ?? '') === 'user';
            if ($action === 'kind_import' && isset($ex[$k['id']]) && empty($in['overwrite'])) {
                echo json_encode(['ok' => false, 'exists' => true, 'id' => $k['id'], 'mine' => $mine, 'error' => 'A kind with this id already exists'], JSON_UNESCAPED_UNICODE); break;
            }
            // a kind keeps the tools it carries when the wizard re-saves it (the wizard has no field for them)
            $keptTools = false;
            if (empty($k['tool_defs']) && $action === 'kind_save' && empty($in['drop_tools']) && $mine && !empty($ex[$k['id']]['tool_defs'])) { $keptTools = true; $k['tool_defs'] = $ex[$k['id']]['tool_defs']; $have = array_column($k['tools'] ?? [], 'tool'); foreach ($k['tool_defs'] as $t) if (!in_array($t['id'], $have, true)) $k['tools'][] = ['tool' => $t['id'], 'why' => 'carried by this kind']; }
            if (!empty($k['tool_defs']) && !$keptTools) {   // tools already agreed to and registered are not asked about again
                if (empty($in['confirm_tools'])) {   // a command line from a file is a decision: show every command and ask first
                    echo json_encode(['ok' => false, 'needs_confirm_tools' => true, 'id' => $k['id'], 'tools' => array_map(fn($t) => ['id' => $t['id'], 'name' => $t['name'], 'binary' => $t['binary'], 'commands' => array_map(fn($p) => $p['command'], $t['presets'])], $k['tool_defs']),
                                      'error' => 'This kind carries its own tools; they run commands on your files'], JSON_UNESCAPED_UNICODE); break;
                }
                $terr = kind_register_tools($k['tool_defs'], $k['id']);
                if ($terr !== null) { echo json_encode(['ok' => false, 'error' => $terr], JSON_UNESCAPED_UNICODE); break; }
            }
            if (!kind_user_save($k)) { echo json_encode(['ok' => false, 'error' => 'Could not save the kind (is the data folder writable?)'], JSON_UNESCAPED_UNICODE); break; }
            echo json_encode(['ok' => true, 'kind' => $k, 'overrides_shipped' => isset($ex[$k['id']]) && !$mine], JSON_UNESCAPED_UNICODE);
            break;

        case 'kind_starter':    // starter files of a kind into a project: confirm=false lists what would happen, confirm=true writes ONLY the files that do not exist yet
            auth_require_writer();
            $kid = (string)($in['id'] ?? ''); $pj = safeName($in['project'] ?? ''); $all = kinds_load();
            if (!isset($all[$kid]) || empty($all[$kid]['starter'])) { echo json_encode(['ok' => false, 'error' => 'That kind has no starter files'], JSON_UNESCAPED_UNICODE); break; }
            $pdir = $pj !== '' && $pj !== '_standalone' ? realpath(COCKPIT_ROOT . '/' . $pj) : false;
            if (!$pdir || !is_dir($pdir)) { echo json_encode(['ok' => false, 'error' => 'Starter files go into a project folder: open a project first'], JSON_UNESCAPED_UNICODE); break; }
            $confirm = !empty($in['confirm']); $res = [];
            foreach ($all[$kid]['starter'] as $sf) {
                $rel = (string)$sf['path']; $full = $pdir . '/' . $rel; $dir = dirname($full);
                $e = ['path' => $rel, 'status' => 'new'];
                // the nearest existing parent must really be inside the project (no symlink out of it)
                $p = $dir; while (!file_exists($p) && $p !== $pdir && strlen($p) > strlen($pdir)) $p = dirname($p);
                $rp = realpath($p);
                if ($rp === false || ($rp !== $pdir && strpos($rp, $pdir . '/') !== 0)) { $e['status'] = 'refused'; }
                elseif (file_exists($full) || is_link($full)) { $e['status'] = 'exists'; }
                elseif ($confirm) {
                    if ((!is_dir($dir) && !@mkdir($dir, 0775, true)) || @file_put_contents($full, (string)$sf['content'], LOCK_EX) === false) $e['status'] = 'failed'; else $e['status'] = 'created';
                }
                $res[] = $e;
            }
            echo json_encode(['ok' => true, 'confirm' => $confirm, 'files' => $res, 'project' => $pj], JSON_UNESCAPED_UNICODE);
            break;
        case 'kind_delete':     // only the person's own file; deleting an override brings the shipped kind back
            auth_require_writer();
            $kid = (string)($in['id'] ?? '');
            $f = kinds_user_dir() . '/' . $kid . '.json';
            if (!preg_match('/^[a-z0-9\-]{1,40}$/', $kid) || !is_file($f)) { echo json_encode(['ok' => false, 'error' => 'That is not one of your own kinds'], JSON_UNESCAPED_UNICODE); break; }
            echo json_encode(['ok' => @unlink($f)], JSON_UNESCAPED_UNICODE);
            break;

        case 'set_project_meta':  // write {project, goal, icon, color}
            $pn = safeName($in['project'] ?? '');
            $ch = (string)($in['chat'] ?? '');
            if ($pn === '' && $ch !== '') $pn = '_standalone';
            if ($pn === '') { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); break; }
            $pd = COCKPIT_ROOT . '/' . $pn;
            if ($pn === '_standalone' && !is_dir($pd)) @mkdir($pd, 0775, true);
            if (!is_dir($pd)) { echo json_encode(['ok'=>false,'error'=>'No such project'], JSON_UNESCAPED_UNICODE); break; }
            // with a chat: the goal is that chat's; the kind is the project's (global), except in a free chat, which keeps its own
            if ($ch !== '') {
                $cp = [];
                if (isset($in['goal'])) $cp['goal'] = mb_substr(trim((string)$in['goal']), 0, 600);
                if (isset($in['description'])) $cp['description'] = mb_substr(trim((string)$in['description']), 0, 300);
                if (isset($in['desc_send']))   $cp['desc_send']   = (bool)$in['desc_send'];
                if (isset($in['kind']) && $pn === '_standalone') {
                    $kp = kind_meta_patch((string)$in['kind']);
                    if ($kp === null) { echo json_encode(['ok'=>false,'error'=>'Unknown project kind'], JSON_UNESCAPED_UNICODE); break; }
                    $cp += $kp;
                }
                $ok = $cp ? chat_meta_save($pd, $ch, $cp) : true;
                if (isset($in['kind']) && $pn !== '_standalone') {
                    $kp = kind_meta_patch((string)$in['kind']);
                    if ($kp === null) { echo json_encode(['ok'=>false,'error'=>'Unknown project kind'], JSON_UNESCAPED_UNICODE); break; }
                    $ok = project_meta_save($pd, $kp) && $ok;
                }
                echo json_encode(['ok' => $ok, 'meta' => project_meta_load($pd), 'effective' => chat_effective($pd, $pn, $ch)], JSON_UNESCAPED_UNICODE);
                break;
            }
            $meta = [];
            if (isset($in['goal']))  $meta['goal']  = mb_substr(trim((string)$in['goal']), 0, 600);
            if (isset($in['description'])) $meta['description'] = mb_substr(trim((string)$in['description']), 0, 300);
            if (isset($in['desc_send']))   $meta['desc_send']   = (bool)$in['desc_send'];
            if (isset($in['icon']))  $meta['icon']  = preg_replace('/[^a-z0-9_]/', '', strtolower((string)$in['icon']));
            if (isset($in['color'])) $meta['color'] = preg_replace('/[^#a-zA-Z0-9]/', '', (string)$in['color']);
            if (isset($in['kind'])) {
                $kp = kind_meta_patch((string)$in['kind']);
                if ($kp === null) { echo json_encode(['ok'=>false,'error'=>'Unknown project kind'], JSON_UNESCAPED_UNICODE); break; }
                $meta += $kp;
            }
            $ok = project_meta_save($pd, $meta);
            echo json_encode(['ok' => $ok, 'meta' => project_meta_load($pd)], JSON_UNESCAPED_UNICODE);
            break;

        case 'delete_project':
            // Permanently remove a project folder and everything inside it.
            // Guards: name must sanitize to non-empty, must resolve to a real
            // directory directly under COCKPIT_ROOT, and must not be the
            // standalone store. Path is canonicalized with realpath() and
            // re-checked against COCKPIT_ROOT to block traversal.
            $name = safeName($in['project'] ?? '');
            if (!$name || $name === '_standalone') {
                echo json_encode(['ok'=>false,'error'=>'Invalid project'], JSON_UNESCAPED_UNICODE); break;
            }
            $target = COCKPIT_ROOT . '/' . $name;
            $real   = realpath($target);
            $rootR  = realpath(COCKPIT_ROOT);
            if ($real === false || !is_dir($real) ||
                strpos($real, $rootR . '/') !== 0 ||
                dirname($real) !== $rootR) {
                echo json_encode(['ok'=>false,'error'=>'Project not found'], JSON_UNESCAPED_UNICODE); break;
            }
            // Guard: never delete the LAST remaining project.
            $projCount = 0;
            foreach (scandir(COCKPIT_ROOT) ?: [] as $e) {
                if ($e[0] === '.' || $e === '_standalone' || $e === 'Public') continue;
                if (is_dir(COCKPIT_ROOT . '/' . $e)) $projCount++;
            }
            if ($projCount <= 1) {
                echo json_encode(['ok'=>false,'error'=>'last-project',
                    'message'=>'Cannot delete the last project.'], JSON_UNESCAPED_UNICODE); break;
            }
            // Recursive delete, counting files removed for the UI message.
            $removed = 0;
            $it = new RecursiveIteratorIterator(
                new RecursiveDirectoryIterator($real, FilesystemIterator::SKIP_DOTS),
                RecursiveIteratorIterator::CHILD_FIRST
            );
            foreach ($it as $f) {
                if ($f->isDir()) { @rmdir($f->getPathname()); }
                else { if (@unlink($f->getPathname())) $removed++; }
            }
            $ok = @rmdir($real);
            echo json_encode(['ok'=>$ok, 'removed'=>$removed,
                              'error'=>$ok?null:'Could not remove folder'], JSON_UNESCAPED_UNICODE);
            break;

        case 'new_chat':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $name = safeName($in['name'] ?? '');
            if (!$name) $name = 'New Chat';
            // Make unique filename
            $slug = strtolower(str_replace(' ', '_', $name));
            $base = $slug; $i = 2;
            $dir  = $project === '_standalone'
                ? COCKPIT_ROOT . '/_standalone'
                : COCKPIT_ROOT . '/' . $project;
            if (!is_dir($dir)) { mkdir($dir, 0775, true); fixPerms($dir); }
            // Unique within THIS container (project or Free) — a project and Free
            // may each have their own "Welcome".
            while (file_exists($dir . '/chat_' . $slug . '.json')) $slug = $base . '_' . $i++;
            // Optional intro: seed the chat with one system message so first-run
            // "welcome" chats are never empty (and thus visible + not auto-cleaned).
            $intro = (string)($in['intro'] ?? '');
            $exchanges = [];
            if ($intro !== '') {
                $exchanges[] = [
                    'id' => 1, 'timestamp' => date('c'),
                    'role' => 'agent', 'agent' => 'system', 'model' => null,
                    'text' => $intro,
                ];
            }
            $chatData = [
                'project'   => $project,
                'chat'      => $name,
                'created'   => date('c'),
                'updated'   => date('c'),
                'exchanges' => $exchanges
            ];
            $chatPath = $dir . '/chat_' . $slug . '.json';
            file_put_contents($chatPath, json_encode($chatData, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            fixPerms($chatPath);
            echo json_encode(['ok' => true, 'slug' => $slug, 'name' => $name], JSON_UNESCAPED_UNICODE);
            break;

        case 'rename_chat':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $old  = safeName($in['old'] ?? '');
            $new  = safeName($in['new'] ?? '');
            if (!$old || !$new) { echo json_encode(['ok'=>false,'error'=>'Missing names'], JSON_UNESCAPED_UNICODE); exit; }
            $dir  = COCKPIT_ROOT . '/' . $project;
            $oldSlug = strtolower(str_replace(' ','_',$old));
            $oldFile = $dir . '/chat_' . $oldSlug . '.json';
            $newSlug = strtolower(str_replace(' ','_',$new));
            $newFile = $dir . '/chat_' . $newSlug . '.json';
            if (!file_exists($oldFile)) { echo json_encode(['ok'=>false,'error'=>'Chat not found'], JSON_UNESCAPED_UNICODE); exit; }
            // Reject if another chat in THIS SAME container already has the name.
            if ($newSlug !== $oldSlug && file_exists($newFile)) {
                echo json_encode(['ok'=>false,'error'=>'name-taken',
                    'message'=>'A chat named "' . $new . '" already exists here. Pick another name.'], JSON_UNESCAPED_UNICODE); exit;
            }
            // Update display name inside JSON
            $data = json_decode(file_get_contents($oldFile), true);
            $data['chat'] = $new;
            file_put_contents($oldFile, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            if ($oldFile !== $newFile) {
                rename($oldFile, $newFile);
                $om = chat_meta_path($dir, $oldSlug); if (is_file($om)) @rename($om, chat_meta_path($dir, $newSlug));      // the chat's goal follows it
            }
            echo json_encode(['ok' => true, 'slug' => $newSlug], JSON_UNESCAPED_UNICODE);
            break;

        case 'set_active':
            $chat  = safeName($in['chat'] ?? 'default');
            $state = readState();
            $state['project_name'] = $project ?: $state['project_name'];
            $state['chat_name']    = strtolower(str_replace(' ','_',$chat));
            writeState($state);
            echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
            break;

        case 'new_file':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $path = safePath($in['path'] ?? 'new_file.txt', $project);
            if (!$path) { echo json_encode(['ok'=>false,'error'=>'Invalid path'], JSON_UNESCAPED_UNICODE); exit; }
            if (file_exists($path)) { echo json_encode(['ok'=>false,'error'=>'File exists'], JSON_UNESCAPED_UNICODE); exit; }
            file_put_contents($path, '');
            fixPerms($path);
            echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
            break;

        // E1: write_file — create-or-overwrite a text file (used for COCKPIT.md).
        // Atomic .tmp + rename. Path stays inside the project (safePath enforces).
        case 'write_file':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $path = safePath($in['path'] ?? '', $project);
            if (!$path) { echo json_encode(['ok'=>false,'error'=>'Invalid path'], JSON_UNESCAPED_UNICODE); exit; }
            $content = (string)($in['content'] ?? '');
            if (strlen($content) > 1048576) { echo json_encode(['ok'=>false,'error'=>'Content exceeds 1MB'], JSON_UNESCAPED_UNICODE); exit; }
            $dir = dirname($path);
            if (!is_dir($dir)) @mkdir($dir, 0775, true);
            $tmp = $path . '.tmp';
            if (@file_put_contents($tmp, $content) === false) {
                echo json_encode(['ok'=>false,'error'=>'Write failed'], JSON_UNESCAPED_UNICODE); exit;
            }
            if (!@rename($tmp, $path)) { @unlink($tmp); echo json_encode(['ok'=>false,'error'=>'Rename failed'], JSON_UNESCAPED_UNICODE); exit; }
            fixPerms($path);
            echo json_encode(['ok'=>true, 'size'=>strlen($content)], JSON_UNESCAPED_UNICODE);
            break;

        case 'new_folder':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $path = safePath($in['path'] ?? 'new_folder', $project);
            if (!$path) { echo json_encode(['ok'=>false,'error'=>'Invalid path'], JSON_UNESCAPED_UNICODE); exit; }
            mkdir($path, 0775, true);
            fixPerms($path);
            echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
            break;

        case 'move_chat':
            // Move a chat from one project/standalone to another
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $targetProject = safeName($in['target'] ?? '');
            $chatSlug      = safeName($in['chat']   ?? '');
            if (!$targetProject || !$chatSlug) {
                echo json_encode(['ok'=>false,'error'=>'Missing target or chat'], JSON_UNESCAPED_UNICODE); exit;
            }
            $srcDir = $project === '_standalone'
                ? COCKPIT_ROOT . '/_standalone'
                : COCKPIT_ROOT . '/' . $project;
            $dstDir = $targetProject === '_standalone'
                ? COCKPIT_ROOT . '/_standalone'
                : COCKPIT_ROOT . '/' . $targetProject;
            if (!is_dir($dstDir)) mkdir($dstDir, 0775, true);
            $srcFile = $srcDir . '/chat_' . $chatSlug . '.json';
            if (!file_exists($srcFile)) {
                echo json_encode(['ok'=>false,'error'=>'Chat not found'], JSON_UNESCAPED_UNICODE); exit;
            }
            // Collision guard: if the target already has a chat with this slug,
            // pick a unique one (chat2 → chat2_2) instead of overwriting it.
            $dstSlug = $chatSlug; $base = $chatSlug; $i = 2;
            while (file_exists($dstDir . '/chat_' . $dstSlug . '.json')) $dstSlug = $base . '_' . $i++;
            $dstFile = $dstDir . '/chat_' . $dstSlug . '.json';
            // Update project field inside the JSON
            $data = json_decode(file_get_contents($srcFile), true);
            $data['project'] = $targetProject;
            file_put_contents($srcFile, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
            rename($srcFile, $dstFile);
            fixPerms($dstFile);
            echo json_encode(['ok' => true, 'slug' => $dstSlug,
                'renamed' => ($dstSlug !== $chatSlug)], JSON_UNESCAPED_UNICODE);
            break;

        case 'delete':
            if (!$project) { echo json_encode(['ok'=>false,'error'=>'Missing project'], JSON_UNESCAPED_UNICODE); exit; }
            $path = safePath($in['path'] ?? '', $project);
            // Double-check path is inside cockpit root.
            // Use realpath on the parent dir (file may not exist yet for race conditions).
            $real = realpath($path) ?: realpath(dirname($path)) . '/' . basename($path);
            if (strpos($real, realpath(COCKPIT_ROOT)) !== 0) {
                echo json_encode(['ok'=>false,'error'=>'Path outside cockpit root'], JSON_UNESCAPED_UNICODE); exit;
            }
            // Guard: never delete the LAST remaining chat in a project or in the
            // free (_standalone) store — the app should always have somewhere to talk.
            $bn = basename($path);
            if (strpos($bn, 'chat_') === 0 && substr($bn, -5) === '.json') {
                $pdir = dirname($path);
                if (count(glob($pdir . '/chat_*.json') ?: []) <= 1) {
                    $where = (basename($pdir) === '_standalone') ? 'free chat' : 'chat in this project';
                    echo json_encode(['ok'=>false,'error'=>'last-chat',
                        'message'=>'Cannot delete the last ' . $where . '.'], JSON_UNESCAPED_UNICODE); exit;
                }
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
            echo json_encode(['ok' => true], JSON_UNESCAPED_UNICODE);
            break;

        default:
            echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
    }
}
?>
