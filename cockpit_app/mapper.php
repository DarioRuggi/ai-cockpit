<?php
require_once __DIR__ . "/auth.php";
// =============================================================================
// mapper.php — FPC/PHP structural Unit Mapper
// Dario Ruggi / Cockpit
//
// Walks a project's source files (.pas/.pp/.lpr/.inc and .php) and emits a
// structural map (units/classes/procedures/functions) as Markdown + JSON, to
// give an LLM navigational context of a codebase.
//
// GET ?action=map&project=<name>[&subdir=<rel>]
// =============================================================================

header('Content-Type: application/json');

// auth.php (required above) already loaded paths.php — use the resolved,
// per-user-scoped $PATHS instead of re-reading paths.json raw (that bypassed
// scoping entirely, same bug class fixed in combos_core.php earlier).
$COCKPIT_ROOT = rtrim($PATHS['projects_root'], '/');

function safe_seg(string $s): string { return preg_replace('#[^A-Za-z0-9_.\- ]#', '', $s); }

$action = $_GET['action'] ?? 'map';
if ($action !== 'map') { echo json_encode(['ok'=>false,'error'=>'Unknown action'], JSON_UNESCAPED_UNICODE); exit; }

$project = safe_seg((string)($_GET['project'] ?? 'default')) ?: 'default';
$subdir  = (string)($_GET['subdir'] ?? '');
$root    = $COCKPIT_ROOT . '/' . $project . ($subdir !== '' ? '/' . trim($subdir, '/') : '');
$real    = realpath($root);
$base    = realpath($COCKPIT_ROOT);
if ($real === false || $base === false || strpos($real, $base) !== 0 || !is_dir($real)) {
    echo json_encode(['ok'=>false,'error'=>'Path not found / outside cockpit root'], JSON_UNESCAPED_UNICODE); exit;
}

// --- gather source files (capped) ---
$exts = ['pas','pp','lpr','inc','php','phtml'];
$files = [];
$it = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($real, FilesystemIterator::SKIP_DOTS),
    RecursiveIteratorIterator::SELF_FIRST
);
foreach ($it as $f) {
    if (!$f->isFile()) continue;
    $ext = strtolower($f->getExtension());
    if (!in_array($ext, $exts, true)) continue;
    if ($f->getSize() > 2 * 1024 * 1024) continue;     // skip huge files
    $files[] = $f->getPathname();
    if (count($files) >= 400) break;                   // cap
}
sort($files);

// --- parsers ---
function parse_pascal(string $src): array {
    $o = ['unit'=>null, 'uses'=>[], 'types'=>[], 'routines'=>[]];
    if (preg_match('/^\s*(unit|program|library)\s+([A-Za-z_][\w.]*)/im', $src, $m)) $o['unit'] = $m[2];
    if (preg_match('/\buses\b([^;]+);/is', $src, $m)) {
        foreach (preg_split('/[,\s]+/', trim($m[1])) as $u) { $u = trim($u); if ($u !== '' && stripos($u,'in')!==0) $o['uses'][] = $u; }
        $o['uses'] = array_values(array_unique(array_filter($o['uses'])));
    }
    if (preg_match_all('/^\s*([A-Za-z_]\w*)\s*=\s*(class|object|record|interface)\b/im', $src, $mm, PREG_SET_ORDER)) {
        foreach ($mm as $m) $o['types'][] = ['name'=>$m[1], 'kind'=>strtolower($m[2])];
    }
    if (preg_match_all('/^\s*(procedure|function|constructor|destructor)\s+([A-Za-z_][\w.]*)/im', $src, $mm, PREG_SET_ORDER)) {
        foreach ($mm as $m) $o['routines'][] = ['kind'=>strtolower($m[1]), 'name'=>$m[2]];
    }
    return $o;
}
function parse_php(string $src): array {
    $o = ['namespace'=>null, 'types'=>[], 'functions'=>[]];
    if (preg_match('/^\s*namespace\s+([^;]+);/im', $src, $m)) $o['namespace'] = trim($m[1]);
    if (preg_match_all('/\b(class|interface|trait|enum)\s+([A-Za-z_]\w*)/i', $src, $mm, PREG_SET_ORDER)) {
        foreach ($mm as $m) $o['types'][] = ['name'=>$m[2], 'kind'=>strtolower($m[1])];
    }
    if (preg_match_all('/\bfunction\s+([A-Za-z_]\w*)\s*\(/i', $src, $mm, PREG_SET_ORDER)) {
        foreach ($mm as $m) $o['functions'][] = $m[1];
    }
    return $o;
}

// --- build map ---
$rootLen = strlen($real) + 1;
$mapJson = [];
$md = "# Unit map — $project" . ($subdir !== '' ? "/$subdir" : '') . "\n\n" .
      count($files) . " source file(s).\n";
foreach ($files as $path) {
    $rel = substr($path, $rootLen);
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    $src = (string)file_get_contents($path);
    if (in_array($ext, ['php','phtml'], true)) {
        $p = parse_php($src);
        $mapJson[$rel] = ['lang'=>'php'] + $p;
        $md .= "\n## $rel" . ($p['namespace'] ? "  _(namespace {$p['namespace']})_" : '') . "\n";
        foreach ($p['types'] as $t)     $md .= "- {$t['kind']} **{$t['name']}**\n";
        foreach ($p['functions'] as $fn) $md .= "- function `$fn()`\n";
        if (!$p['types'] && !$p['functions']) $md .= "- _(no top-level symbols)_\n";
    } else {
        $p = parse_pascal($src);
        $mapJson[$rel] = ['lang'=>'pascal'] + $p;
        $md .= "\n## $rel" . ($p['unit'] ? "  _(unit {$p['unit']})_" : '') . "\n";
        if ($p['uses']) $md .= "- uses: " . implode(', ', array_slice($p['uses'], 0, 40)) . "\n";
        foreach ($p['types'] as $t)    $md .= "- {$t['kind']} **{$t['name']}**\n";
        foreach ($p['routines'] as $r) $md .= "- {$r['kind']} `{$r['name']}`\n";
        if (!$p['types'] && !$p['routines']) $md .= "- _(no routines/types found)_\n";
    }
}

echo json_encode(['ok'=>true, 'project'=>$project, 'files'=>count($files), 'markdown'=>$md, 'map'=>$mapJson], JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
