<?php
// =============================================================================
// export.php — Cockpit chat export (single + batch)
//
// Single chat:  ?project=X&chat=Y          → ZIP with JSON + MD + manifest
// Batch project: ?scope=project&project=X  → ZIP with all chats in project
// Batch all:     ?scope=all                → ZIP with all projects/chats
//
// Uses shell `zip` (no php-zip extension needed).
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

ed_gate_or_exit('export');   // demo: described-modal; v1/v2: real

$COCKPIT_ROOT = $PATHS['projects_root'];

function safeName($s) {
    return preg_replace('/[^a-zA-Z0-9_\-]/', '', (string)$s);
}

function chatToMarkdown($data, $chat) {
    $md  = "# Chat: " . ($data['chat'] ?? $chat) . "\n\n";
    $md .= "**Project:** " . ($data['project'] ?? 'unknown') . "  \n";
    $md .= "**Created:** " . ($data['created'] ?? 'unknown') . "  \n";
    $md .= "**Updated:** " . ($data['updated'] ?? 'unknown') . "  \n";
    $md .= "**Exchanges:** " . count($data['exchanges'] ?? []) . "\n\n---\n\n";

    foreach ($data['exchanges'] ?? [] as $e) {
        $role  = $e['role']      ?? 'unknown';
        $ts    = $e['timestamp'] ?? '';
        $agent = $e['agent']     ?? null;
        $model = $e['model']     ?? null;
        $dur   = $e['duration_s'] ?? null;
        $text  = $e['text']      ?? '';

        if ($role === 'user') {
            $md .= "## USER · `$ts`\n\n";
        } else {
            $extras = [];
            if ($agent) $extras[] = strtoupper($agent);
            if ($model) $extras[] = $model;
            if ($dur)   $extras[] = $dur . 's';
            $tag = $extras ? ' · ' . implode(' · ', $extras) : '';
            $md .= "## AGENT$tag · `$ts`\n\n";
        }
        $md .= $text . "\n\n---\n\n";
    }
    return $md;
}

function jsonErr($msg) {
    header('Content-Type: application/json');
    echo json_encode(['ok' => false, 'error' => $msg], JSON_UNESCAPED_UNICODE);
    exit;
}

function sendZip($zipPath, $filename) {
    if (!is_file($zipPath) || filesize($zipPath) === 0) {
        @unlink($zipPath);
        jsonErr('ZIP creation failed');
    }
    header('Content-Type: application/zip');
    header('Content-Disposition: attachment; filename="' . $filename . '"');
    header('Content-Length: ' . filesize($zipPath));
    header('Cache-Control: no-store');
    readfile($zipPath);
    @unlink($zipPath);
    exit;
}

// Write files to a temp dir, then shell-zip them.
function buildZip(array $files): string {
    $tmpDir = sys_get_temp_dir() . '/cockpit_export_' . uniqid();
    @mkdir($tmpDir, 0700, true);
    foreach ($files as $name => $content) {
        $full = $tmpDir . '/' . $name;
        $dir  = dirname($full);
        if (!is_dir($dir)) @mkdir($dir, 0700, true);
        file_put_contents($full, $content);
    }
    $zipPath = $tmpDir . '.zip';
    $cmd = 'cd ' . escapeshellarg($tmpDir) . ' && zip -r ' . escapeshellarg($zipPath) . ' . 2>&1';
    exec($cmd, $out, $ret);
    // Cleanup temp dir
    exec('rm -rf ' . escapeshellarg($tmpDir));
    if ($ret !== 0 || !is_file($zipPath)) {
        jsonErr('zip command failed: ' . implode("\n", $out));
    }
    return $zipPath;
}

function addChatFiles(array &$files, string $prefix, string $jsonPath, string $chatSlug): int {
    $raw = file_get_contents($jsonPath);
    $data = json_decode(preg_replace('/("duration_s":\s*)\.(\d)/', '${1}0.$2', $raw), true);   // ".9" durations, see below
    if (!is_array($data)) return 0;

    $files[$prefix . $chatSlug . '.json'] =
        json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    $files[$prefix . $chatSlug . '.md'] = chatToMarkdown($data, $chatSlug);
    return count($data['exchanges'] ?? []);
}

// ── Routing ─────────────────────────────────────────────────────────────────

$scope   = $_GET['scope']   ?? '';
$project = $_GET['project'] ?? '';
$chat    = safeName($_GET['chat'] ?? '');

// ── Single chat export ──────────────────────────────────────────────────────
if (!$scope && $project && $chat) {
    $projDir = realpath($COCKPIT_ROOT . '/' . $project);
    if (!$projDir || strpos($projDir, realpath($COCKPIT_ROOT)) !== 0) jsonErr('Invalid project');

    $jsonPath = $projDir . '/chat_' . $chat . '.json';
    if (!is_file($jsonPath)) jsonErr('Chat not found');

    // ".9" durations from agent_loop.sh before build 87 are not JSON to PHP; mend on read
    $data = json_decode(preg_replace('/("duration_s":\s*)\.(\d)/', '${1}0.$2', file_get_contents($jsonPath)), true);
    if (!is_array($data)) jsonErr('Corrupt chat file');

    $files = [];
    $files[$chat . '.json'] = json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    $files[$chat . '.md']   = chatToMarkdown($data, $chat);
    $files['manifest.json'] = json_encode([
        'cockpit_export'  => true,
        'export_version'  => 2,
        'scope'           => 'chat',
        'exported_at'     => date('c'),
        'project'         => $project,
        'chat'            => $chat,
        'exchanges_count' => count($data['exchanges'] ?? []),
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);

    $safeProjName = safeName($project) ?: 'project';
    sendZip(buildZip($files), 'cockpit_' . $safeProjName . '_' . $chat . '_' . date('Ymd-His') . '.zip');
}

// ── Batch: one project ──────────────────────────────────────────────────────
if ($scope === 'project') {
    if (!$project) jsonErr('Missing project');
    $projDir = realpath($COCKPIT_ROOT . '/' . $project);
    if (!$projDir || strpos($projDir, realpath($COCKPIT_ROOT)) !== 0) jsonErr('Invalid project');

    $chatFiles = glob($projDir . '/chat_*.json') ?: [];
    if (!$chatFiles) jsonErr('No chats in project');

    $files = [];
    $totalExchanges = 0;
    $chatCount = 0;
    foreach ($chatFiles as $f) {
        $slug = preg_replace('/^chat_|\.json$/', '', basename($f));
        $totalExchanges += addChatFiles($files, '', $f, $slug);
        $chatCount++;
    }
    $files['manifest.json'] = json_encode([
        'cockpit_export'      => true,
        'export_version'      => 2,
        'scope'               => 'project',
        'exported_at'         => date('c'),
        'project'             => $project,
        'chats_count'         => $chatCount,
        'total_exchanges'     => $totalExchanges,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);

    $safeProjName = safeName($project) ?: 'project';
    sendZip(buildZip($files), 'cockpit_' . $safeProjName . '_all_' . date('Ymd-His') . '.zip');
}

// ── Batch: everything ───────────────────────────────────────────────────────
if ($scope === 'all') {
    $files = [];
    $totalExchanges = 0;
    $chatCount = 0;
    $projectCount = 0;

    foreach (scandir($COCKPIT_ROOT) as $entry) {
        if ($entry[0] === '.') continue;
        $dir = $COCKPIT_ROOT . '/' . $entry;
        if (!is_dir($dir)) continue;

        $chatJsons = glob($dir . '/chat_*.json') ?: [];
        if (!$chatJsons) continue;

        $projectCount++;
        $prefix = $entry . '/';
        foreach ($chatJsons as $f) {
            $slug = preg_replace('/^chat_|\.json$/', '', basename($f));
            $totalExchanges += addChatFiles($files, $prefix, $f, $slug);
            $chatCount++;
        }
    }

    if ($chatCount === 0) jsonErr('No chats found');

    $files['manifest.json'] = json_encode([
        'cockpit_export'      => true,
        'export_version'      => 2,
        'scope'               => 'all',
        'exported_at'         => date('c'),
        'projects_count'      => $projectCount,
        'chats_count'         => $chatCount,
        'total_exchanges'     => $totalExchanges,
    ], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE);

    sendZip(buildZip($files), 'cockpit_full_export_' . date('Ymd-His') . '.zip');
}

jsonErr('Missing required parameters');
