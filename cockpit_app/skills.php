<?php
// =============================================================================
// skills.php — Skills system for AI Cockpit
//
// A "skill" is a named, reusable prompt template invoked with /trigger in the
// prompt box. The skill body is expanded (with {arg} substitution) into the
// agent-bound prompt before dispatch. Skills are stored as JSON, one per file,
// in cockpit_data/skills/<id>.json.
//
// Schema (per skill):
//   { id, name, trigger, description, body, args:[{name,desc}], created, updated }
//
// Endpoints (JSON):
//   GET  ?action=list                — all skills
//   GET  ?action=get&id=X            — one skill
//   POST ?action=save  { ...skill }  — create or update (id required)
//   POST ?action=delete{ id }        — delete
//   POST ?action=expand{ trigger, args:{} } — server-side expansion (optional;
//          the UI usually expands client-side, but this allows agents/tools to
//          request an expansion too)
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) {
    header('Content-Type: application/json');
    $__demoAction = $_GET['action'] ?? $_POST['action'] ?? '';
    if ($__demoAction === '' || $__demoAction === 'list') {
        echo json_encode(['ok'=>true,'skills'=>[
            ['id'=>'pdf-processing','name'=>'PDF Processing','trigger'=>'pdf-processing','description'=>'Merge, split, extract text/tables from PDFs.','args'=>[],'updated'=>'2026-06-01'],
            ['id'=>'code-review','name'=>'Code Review','trigger'=>'code-review','description'=>'Structured severity-tagged review of a diff or file.','args'=>[],'updated'=>'2026-05-20'],
        ]]); exit;
    }
    ed_demo_stub();
}
$SKILLS_DIR = $CD . '/skills';
if (!is_dir($SKILLS_DIR)) @mkdir($SKILLS_DIR, 0775, true);

$action = $_GET['action'] ?? '';
$in = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $raw = json_decode((string)file_get_contents('php://input'), true);
    if (is_array($raw)) $in = $raw;
    if ($action === '') $action = $in['action'] ?? '';
}
if ($action === '') $action = 'list';

function skill_safe_id($s) {
    return preg_replace('/[^a-z0-9_\-]/', '', strtolower(trim((string)$s)));
}
function skill_load($path) {
    if (!is_file($path)) return null;
    $j = json_decode((string)file_get_contents($path), true);
    return is_array($j) ? $j : null;
}
function skill_save_atomic($path, $data) {
    $tmp = $path . '.tmp';
    if (file_put_contents($tmp, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) return false;
    @chmod($tmp, 0664);
    if (!@rename($tmp, $path)) { @unlink($tmp); return false; }
    return true;
}

// =============================================================================
// Claude Skills folder model (SKILL.md + progressive disclosure). A folder skill
// lives at <SKILLS_DIR>/<kebab-name>/SKILL.md (+ optional references/ assets/
// scripts/). Coexists with legacy <id>.json snippets. See design doc.
// =============================================================================
if (!function_exists('mb_strlen')) { function mb_strlen($s,$e=null){ return strlen($s); } }

// Minimal YAML-ish frontmatter parser (no yaml ext dependency). Returns
// [front(assoc, 1-level nesting), body, raw_front].
function skill_parse_frontmatter($md) {
    if (!preg_match('/^---\s*\n(.*?)\n---\s*\n?(.*)$/s', $md, $m)) return [[], $md, ''];
    $raw = $m[1]; $body = $m[2]; $front = []; $cur = null;
    foreach (preg_split('/\r\n|\n/', $raw) as $line) {
        if (preg_match('/^([A-Za-z0-9_-]+):\s*(.*)$/', $line, $mm)) {
            $k = $mm[1]; $v = trim($mm[2]);
            if ($v === '') { $front[$k] = []; $cur = $k; }
            else { $front[$k] = trim($v, "\"'"); $cur = null; }
        } elseif ($cur !== null && preg_match('/^\s+([A-Za-z0-9_-]+):\s*(.*)$/', $line, $mm)) {
            if (!is_array($front[$cur])) $front[$cur] = [];
            $front[$cur][$mm[1]] = trim($mm[2], "\"'");
        }
    }
    return [$front, $body, $raw];
}

// A directory is a folder-skill if it holds a SKILL.md (exact case).
function skill_is_folder($dir) { return is_dir($dir) && is_file($dir . '/SKILL.md'); }

// Strict validation (silent-failure rules from §3/§6). Returns [errors, warnings, parsed|null].
function skill_validate_folder($dir) {
    $errs = []; $warns = []; $name = basename($dir);
    if (!is_file($dir . '/SKILL.md')) {
        foreach (glob($dir . '/*') ?: [] as $f)
            if (strtolower(basename($f)) === 'skill.md' && basename($f) !== 'SKILL.md')
                $errs[] = 'SKILL.md has wrong case: ' . basename($f) . ' (must be exactly SKILL.md)';
        if (!$errs) $errs[] = 'No SKILL.md in folder';
        return [$errs, $warns, null];
    }
    if (!preg_match('/^[a-z0-9]+(?:-[a-z0-9]+)*$/', $name))
        $errs[] = 'Folder name not kebab-case (lowercase + hyphens only): ' . $name;
    if (preg_match('/claude|anthropic/i', $name))
        $errs[] = 'Skill name cannot contain "claude" or "anthropic"';
    if (is_file($dir . '/README.md'))
        $errs[] = 'README.md not allowed inside a skill folder (use SKILL.md or references/)';
    [$front, $body, $raw] = skill_parse_frontmatter((string)file_get_contents($dir . '/SKILL.md'));
    if (preg_match('/[<>]/', $raw))
        $errs[] = 'Angle brackets (< >) in frontmatter are forbidden (prompt-injection risk)';
    $fname = is_string($front['name'] ?? null) ? $front['name'] : '';
    if ($fname === '')            $errs[] = 'frontmatter "name" missing';
    elseif ($fname !== $name)     $errs[] = 'frontmatter name ("' . $fname . '") must equal folder name ("' . $name . '")';
    $desc = is_string($front['description'] ?? null) ? $front['description'] : '';
    if ($desc === '')             $errs[] = 'frontmatter "description" missing (the #1 reason skills do not trigger)';
    elseif (mb_strlen($desc) > 1024) $errs[] = 'description exceeds 1024 chars (' . mb_strlen($desc) . ')';
    $comp = $front['compatibility'] ?? '';
    if (is_string($comp) && mb_strlen($comp) > 500) $errs[] = 'compatibility exceeds 500 chars';
    if ($desc !== '' && !preg_match('/\b(use when|when (the )?user|when you|trigger|use this)\b/i', $desc))
        $warns[] = 'description has no trigger phrase ("Use when…") — weak triggering';
    return [$errs, $warns, ['name'=>$fname ?: $name, 'description'=>$desc, 'body'=>$body, 'front'=>$front]];
}

// Kebab-case an id (folder skills require lowercase + hyphens, no underscores).
function skill_kebab($s) {
    $s = strtolower(trim((string)$s));
    $s = preg_replace('/[^a-z0-9]+/', '-', $s);
    return trim($s, '-');
}
// Serialize frontmatter + body back into a SKILL.md string.
function skill_build_md($front, $body) {
    $lines = ['---', 'name: ' . $front['name'], 'description: ' . $front['description']];
    foreach (['license','compatibility'] as $k)
        if (!empty($front[$k]) && is_string($front[$k])) $lines[] = $k . ': ' . $front[$k];
    if (!empty($front['metadata']) && is_array($front['metadata'])) {
        $lines[] = 'metadata:';
        foreach ($front['metadata'] as $k => $v) if (is_string($v) || is_numeric($v)) $lines[] = '  ' . $k . ': ' . $v;
    }
    $lines[] = '---';
    return implode("\n", $lines) . "\n" . $body;
}

// Resolve a Tier-3 reference path safely under the skill dir (no traversal).
function skill_safe_ref($dir, $rel) {
    $rel = ltrim(str_replace('\\', '/', (string)$rel), '/');
    if ($rel === '' || strpos($rel, '..') !== false) return null;
    $full = $dir . '/' . $rel;
    $rp = realpath($full); $base = realpath($dir);
    if ($rp === false || $base === false || strpos($rp, $base . '/') !== 0) return null;
    return $rp;
}

// ── list ──────────────────────────────────────────────────────────────────────
if ($action === 'list') {
    $skills = [];
    foreach (glob($SKILLS_DIR . '/*.json') ?: [] as $f) {
        $s = skill_load($f);
        if ($s) {
            // Don't ship the full body in the list — keep it light
            $skills[] = [
                'id'          => $s['id'] ?? basename($f, '.json'),
                'name'        => $s['name'] ?? '',
                'trigger'     => $s['trigger'] ?? '',
                'description' => $s['description'] ?? '',
                'args'        => $s['args'] ?? [],
                'updated'     => $s['updated'] ?? '',
            ];
        }
    }
    // Tier 1 — also surface folder skills (SKILL.md), name+description only.
    foreach (glob($SKILLS_DIR . '/*', GLOB_ONLYDIR) ?: [] as $dir) {
        if (!skill_is_folder($dir)) continue;
        [$errs, $warns, $p] = skill_validate_folder($dir);
        $name = $p['name'] ?? basename($dir);
        $skills[] = [
            'id'          => basename($dir),
            'name'        => $name,
            'trigger'     => basename($dir),
            'description' => $p['description'] ?? '',
            'args'        => [],
            'updated'     => date('c', (int)@filemtime($dir . '/SKILL.md')),
            'format'      => 'folder',
            'has_refs'    => is_dir($dir . '/references') || is_dir($dir . '/assets'),
            'has_scripts' => is_dir($dir . '/scripts'),
            'valid'       => empty($errs),
            'errors'      => $errs,
            'warnings'    => $warns,
        ];
    }
    usort($skills, fn($a,$b) => strcasecmp($a['name'], $b['name']));
    echo json_encode(['ok'=>true, 'skills'=>$skills], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── body (Tier 2) — full SKILL.md body for a folder skill ───────────────────
if ($action === 'body') {
    $id = skill_safe_id($in['id'] ?? ($_GET['id'] ?? ''));
    $dir = $SKILLS_DIR . '/' . $id;
    if (!$id || !skill_is_folder($dir)) { echo json_encode(['ok'=>false,'error'=>'Folder skill not found'], JSON_UNESCAPED_UNICODE); exit; }
    [$errs, $warns, $p] = skill_validate_folder($dir);
    // List referenced files (Tier 3 catalog) so the agent/UI knows what it can pull.
    $refs = [];
    foreach (['references','assets'] as $sub)
        foreach (glob($dir . '/' . $sub . '/*') ?: [] as $f)
            if (is_file($f)) $refs[] = $sub . '/' . basename($f);
    echo json_encode(['ok'=>true, 'name'=>$p['name'] ?? $id, 'description'=>$p['description'] ?? '',
        'body'=>$p['body'] ?? '', 'front'=>$p['front'] ?? [], 'refs'=>$refs,
        'errors'=>$errs, 'warnings'=>$warns], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ref (Tier 3) — one referenced file's contents, loaded on demand ─────────
if ($action === 'ref') {
    $id   = skill_safe_id($in['id'] ?? ($_GET['id'] ?? ''));
    $path = (string)($in['path'] ?? ($_GET['path'] ?? ''));
    $dir  = $SKILLS_DIR . '/' . $id;
    if (!$id || !skill_is_folder($dir)) { echo json_encode(['ok'=>false,'error'=>'Folder skill not found'], JSON_UNESCAPED_UNICODE); exit; }
    $rp = skill_safe_ref($dir, $path);
    if ($rp === null) { echo json_encode(['ok'=>false,'error'=>'Invalid or unsafe ref path'], JSON_UNESCAPED_UNICODE); exit; }
    // Never serve scripts/ contents through ref-as-text execution; reading is fine.
    if (filesize($rp) > 512 * 1024) { echo json_encode(['ok'=>false,'error'=>'Ref file too large (>512KB)'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true, 'path'=>$path, 'content'=>(string)file_get_contents($rp)], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── validate — run strict rules against a folder skill ──────────────────────
if ($action === 'validate') {
    $id = skill_safe_id($in['id'] ?? ($_GET['id'] ?? ''));
    $dir = $SKILLS_DIR . '/' . $id;
    if (!$id || !is_dir($dir)) { echo json_encode(['ok'=>false,'error'=>'Folder not found'], JSON_UNESCAPED_UNICODE); exit; }
    [$errs, $warns, $p] = skill_validate_folder($dir);
    echo json_encode(['ok'=>true, 'valid'=>empty($errs), 'errors'=>$errs, 'warnings'=>$warns,
        'has_scripts'=>is_dir($dir . '/scripts')], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── export — zip a folder skill (portable to Claude.ai / Claude Code) ────────
if ($action === 'export') {
    $id = skill_safe_id($in['id'] ?? ($_GET['id'] ?? ''));
    $dir = $SKILLS_DIR . '/' . $id;
    if (!$id || !skill_is_folder($dir)) { echo json_encode(['ok'=>false,'error'=>'Folder skill not found'], JSON_UNESCAPED_UNICODE); exit; }
    // Shell out to `zip` (no php-zip dep). -X drops extra attrs for clean portability.
    $cmd = 'cd ' . escapeshellarg($SKILLS_DIR) . ' && zip -rqX - ' . escapeshellarg($id) . ' 2>/dev/null';
    $bin = shell_exec($cmd);
    if ($bin === null || $bin === '') { echo json_encode(['ok'=>false,'error'=>'zip failed (is "zip" installed?)'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true, 'filename'=>$id . '.zip', 'zip_b64'=>base64_encode($bin)], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── import — accept a skill zip; validate + sanitize; gate scripts ──────────
if ($action === 'import') {
    $b64 = (string)($in['zip_b64'] ?? '');
    $bin = base64_decode($b64, true);
    if ($bin === false || $bin === '') { echo json_encode(['ok'=>false,'error'=>'Bad zip data'], JSON_UNESCAPED_UNICODE); exit; }
    if (strlen($bin) > 10 * 1024 * 1024) { echo json_encode(['ok'=>false,'error'=>'Zip too large (>10MB)'], JSON_UNESCAPED_UNICODE); exit; }
    $tmpzip = tempnam(sys_get_temp_dir(), 'imp') . '.zip';
    file_put_contents($tmpzip, $bin);
    // Zip-slip guard: reject any entry with '..' before extracting.
    $listing = (string)shell_exec('unzip -Z1 ' . escapeshellarg($tmpzip) . ' 2>/dev/null');
    $root = null;
    foreach (preg_split('/\r\n|\n/', $listing) as $n) {
        $n = trim($n); if ($n === '') continue;
        if (strpos($n, '..') !== false) { @unlink($tmpzip); echo json_encode(['ok'=>false,'error'=>'Unsafe path in zip'], JSON_UNESCAPED_UNICODE); exit; }
        if (basename($n) === 'SKILL.md') $root = rtrim(dirname($n), '/.');
    }
    if ($root === null) { @unlink($tmpzip); echo json_encode(['ok'=>false,'error'=>'No SKILL.md in zip'], JSON_UNESCAPED_UNICODE); exit; }
    // Extract INSIDE the skills dir (same filesystem) so the final install is a
    // rename, not a cross-device move (which fails EXDEV from /tmp).
    $extract = $SKILLS_DIR . '/.import_' . bin2hex(random_bytes(4));
    @mkdir($extract, 0775, true);
    shell_exec('unzip -qo ' . escapeshellarg($tmpzip) . ' -d ' . escapeshellarg($extract) . ' 2>/dev/null');
    @unlink($tmpzip);
    $srcDir = $root === '' || $root === '.' ? $extract : $extract . '/' . $root;
    [$errs, $warns, $p] = skill_validate_folder($srcDir);
    if (!empty($errs)) { _rrm($extract); echo json_encode(['ok'=>false,'error'=>'Validation failed','errors'=>$errs], JSON_UNESCAPED_UNICODE); exit; }
    $name = $p['name'];
    $dest = $SKILLS_DIR . '/' . $name;
    if (is_dir($dest) && empty($in['overwrite'])) { _rrm($extract); echo json_encode(['ok'=>false,'error'=>'Skill "'.$name.'" already exists','exists'=>true], JSON_UNESCAPED_UNICODE); exit; }
    // Safe overwrite: stash the old copy, install new, only then drop the stash —
    // so a failed move never destroys the existing skill.
    $bak = null;
    if (is_dir($dest)) { $bak = $dest . '.bak.' . bin2hex(random_bytes(3)); @rename($dest, $bak); }
    if (!@rename($srcDir, $dest)) {
        if ($bak) @rename($bak, $dest);   // roll back
        _rrm($extract);
        echo json_encode(['ok'=>false,'error'=>'Install move failed (is the skills dir writable by Apache/www-data?)'], JSON_UNESCAPED_UNICODE); exit;
    }
    if ($bak) _rrm($bak);
    _rrm($extract);
    $hasScripts = is_dir($dest . '/scripts');
    echo json_encode(['ok'=>true, 'name'=>$name, 'warnings'=>$warns,
        'has_scripts'=>$hasScripts,
        'note'=>$hasScripts ? 'Imported skill bundles scripts/ — NOT auto-run. Review before executing (untrusted code).' : ''], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── save_folder — create/update a folder skill's SKILL.md (preserves metadata) ─
if ($action === 'save_folder') {
    $id   = skill_kebab($in['id'] ?? '');
    $desc = trim(str_replace(["\r","\n"], ' ', (string)($in['description'] ?? '')));
    $body = (string)($in['body'] ?? '');
    if ($id === '')                 { echo json_encode(['ok'=>false,'error'=>'Missing or invalid (kebab) id'], JSON_UNESCAPED_UNICODE); exit; }
    if (preg_match('/claude|anthropic/i', $id)) { echo json_encode(['ok'=>false,'error'=>'Name cannot contain "claude"/"anthropic"'], JSON_UNESCAPED_UNICODE); exit; }
    if ($desc === '')               { echo json_encode(['ok'=>false,'error'=>'description required (what + when to use)'], JSON_UNESCAPED_UNICODE); exit; }
    if (mb_strlen($desc) > 1024)    { echo json_encode(['ok'=>false,'error'=>'description exceeds 1024 chars'], JSON_UNESCAPED_UNICODE); exit; }
    if (preg_match('/[<>]/', $desc)) { echo json_encode(['ok'=>false,'error'=>'angle brackets not allowed in description'], JSON_UNESCAPED_UNICODE); exit; }
    $dir = $SKILLS_DIR . '/' . $id;
    $front = ['name'=>$id, 'description'=>$desc];
    if (skill_is_folder($dir)) {   // preserve license/compatibility/metadata
        [$ef] = skill_parse_frontmatter((string)file_get_contents($dir . '/SKILL.md'));
        foreach (['license','compatibility','metadata'] as $k) if (isset($ef[$k])) $front[$k] = $ef[$k];
    }
    @mkdir($dir, 0775, true);
    if (is_file($dir . '/README.md')) @unlink($dir . '/README.md');   // not allowed inside skill
    $md = skill_build_md($front, $body);
    $tmp = $dir . '/SKILL.md.tmp';
    if (file_put_contents($tmp, $md) === false || !@rename($tmp, $dir . '/SKILL.md')) {
        @unlink($tmp); echo json_encode(['ok'=>false,'error'=>'Write failed (skills dir writable by Apache?)'], JSON_UNESCAPED_UNICODE); exit;
    }
    @chmod($dir . '/SKILL.md', 0664);
    [$errs, $warns] = skill_validate_folder($dir);
    echo json_encode(['ok'=>true, 'id'=>$id, 'valid'=>empty($errs), 'errors'=>$errs, 'warnings'=>$warns], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── delete_folder — remove a folder skill entirely ─────────────────────────
if ($action === 'delete_folder') {
    $id = skill_kebab($in['id'] ?? '');
    $dir = $SKILLS_DIR . '/' . $id;
    if (!$id || !skill_is_folder($dir)) { echo json_encode(['ok'=>false,'error'=>'Folder skill not found'], JSON_UNESCAPED_UNICODE); exit; }
    _rrm($dir);
    echo json_encode(['ok'=>true, 'id'=>$id], JSON_UNESCAPED_UNICODE);
    exit;
}

function _rrm($path) {
    if (is_file($path)) { @unlink($path); return; }
    if (!is_dir($path)) return;
    foreach (glob($path . '/*') ?: [] as $f) _rrm($f);
    @rmdir($path);
}

// ── get ───────────────────────────────────────────────────────────────────────
if ($action === 'get') {
    $id = skill_safe_id($in['id'] ?? ($_GET['id'] ?? ''));
    if (!$id) { echo json_encode(['ok'=>false,'error'=>'Missing id'], JSON_UNESCAPED_UNICODE); exit; }
    $s = skill_load($SKILLS_DIR . '/' . $id . '.json');
    if (!$s) { echo json_encode(['ok'=>false,'error'=>'Skill not found'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode(['ok'=>true, 'skill'=>$s], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── save (create or update) ─────────────────────────────────────────────────
if ($action === 'save') {
    $id      = skill_safe_id($in['id'] ?? '');
    $name    = trim((string)($in['name'] ?? ''));
    $trigger = skill_safe_id($in['trigger'] ?? $id);   // trigger defaults to id
    $desc    = trim((string)($in['description'] ?? ''));
    $body    = (string)($in['body'] ?? '');
    $args    = is_array($in['args'] ?? null) ? $in['args'] : [];

    if (!$id)      { echo json_encode(['ok'=>false,'error'=>'Missing or invalid id'], JSON_UNESCAPED_UNICODE); exit; }
    if (!$name)    { echo json_encode(['ok'=>false,'error'=>'Missing name'], JSON_UNESCAPED_UNICODE); exit; }
    if (!$trigger) { echo json_encode(['ok'=>false,'error'=>'Missing or invalid trigger'], JSON_UNESCAPED_UNICODE); exit; }
    if ($body === '') { echo json_encode(['ok'=>false,'error'=>'Skill body is empty'], JSON_UNESCAPED_UNICODE); exit; }
    if (strlen($body) > 65536) { echo json_encode(['ok'=>false,'error'=>'Body exceeds 64 KB'], JSON_UNESCAPED_UNICODE); exit; }

    // Ensure trigger is unique across other skills
    foreach (glob($SKILLS_DIR . '/*.json') ?: [] as $f) {
        $other = skill_load($f);
        if ($other && ($other['id'] ?? '') !== $id && ($other['trigger'] ?? '') === $trigger) {
            echo json_encode(['ok'=>false,'error'=>'Trigger "/'.$trigger.'" already used by skill "'.($other['name']??'').'"'], JSON_UNESCAPED_UNICODE); exit;
        }
    }

    // Normalize args to [{name, desc}]
    $cleanArgs = [];
    foreach ($args as $a) {
        if (is_string($a)) { $cleanArgs[] = ['name'=>preg_replace('/[^a-zA-Z0-9_]/','',$a), 'desc'=>'']; }
        else if (is_array($a) && !empty($a['name'])) {
            $cleanArgs[] = ['name'=>preg_replace('/[^a-zA-Z0-9_]/','',$a['name']), 'desc'=>trim((string)($a['desc'] ?? ''))];
        }
    }

    $path = $SKILLS_DIR . '/' . $id . '.json';
    $existing = skill_load($path);
    $skill = [
        'id'          => $id,
        'name'        => $name,
        'trigger'     => $trigger,
        'description' => $desc,
        'body'        => $body,
        'args'        => $cleanArgs,
        'created'     => $existing['created'] ?? date('c'),
        'updated'     => date('c'),
    ];
    if (!skill_save_atomic($path, $skill)) {
        echo json_encode(['ok'=>false,'error'=>'Save failed'], JSON_UNESCAPED_UNICODE); exit;
    }
    echo json_encode(['ok'=>true, 'id'=>$id, 'trigger'=>$trigger], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── delete ──────────────────────────────────────────────────────────────────
if ($action === 'delete') {
    $id = skill_safe_id($in['id'] ?? '');
    if (!$id) { echo json_encode(['ok'=>false,'error'=>'Missing id'], JSON_UNESCAPED_UNICODE); exit; }
    $path = $SKILLS_DIR . '/' . $id . '.json';
    if (is_file($path)) @unlink($path);
    echo json_encode(['ok'=>true, 'id'=>$id], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── expand (server-side; substitutes {arg} placeholders) ─────────────────────
if ($action === 'expand') {
    $trigger = skill_safe_id($in['trigger'] ?? '');
    $args    = is_array($in['args'] ?? null) ? $in['args'] : [];
    if (!$trigger) { echo json_encode(['ok'=>false,'error'=>'Missing trigger'], JSON_UNESCAPED_UNICODE); exit; }
    $found = null;
    foreach (glob($SKILLS_DIR . '/*.json') ?: [] as $f) {
        $s = skill_load($f);
        if ($s && ($s['trigger'] ?? '') === $trigger) { $found = $s; break; }
    }
    if (!$found) { echo json_encode(['ok'=>false,'error'=>'No skill for trigger /'.$trigger], JSON_UNESCAPED_UNICODE); exit; }
    $body = (string)$found['body'];
    foreach ($args as $k => $v) {
        $k = preg_replace('/[^a-zA-Z0-9_]/','',(string)$k);
        $body = str_replace('{'.$k.'}', (string)$v, $body);
    }
    echo json_encode(['ok'=>true, 'expanded'=>$body, 'skill'=>['id'=>$found['id'],'name'=>$found['name']]], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── match — auto-trigger: find skills whose descriptions match a user prompt ──
// Returns matched skill IDs ranked by relevance. Caller loads Tier 2 for top matches.
if ($action === 'match') {
    $query = strtolower(trim((string)($in['query'] ?? '')));
    $limit = max(1, min(5, (int)($in['limit'] ?? 3)));
    if ($query === '') { echo json_encode(['ok'=>true, 'matches'=>[]], JSON_UNESCAPED_UNICODE); exit; }

    // Build index of all skills (legacy JSON + folder)
    $index = [];
    foreach (glob($SKILLS_DIR . '/*.json') ?: [] as $f) {
        $s = skill_load($f);
        if (!$s) continue;
        $index[] = [
            'id'   => $s['id'] ?? basename($f, '.json'),
            'name' => $s['name'] ?? '',
            'desc' => strtolower($s['description'] ?? ''),
            'trigger' => $s['trigger'] ?? '',
            'format' => 'json',
        ];
    }
    foreach (glob($SKILLS_DIR . '/*', GLOB_ONLYDIR) ?: [] as $dir) {
        if (!skill_is_folder($dir)) continue;
        [$errs, , $p] = skill_validate_folder($dir);
        if (!empty($errs)) continue;
        $index[] = [
            'id'   => basename($dir),
            'name' => $p['name'] ?? basename($dir),
            'desc' => strtolower($p['description'] ?? ''),
            'trigger' => basename($dir),
            'format' => 'folder',
        ];
    }

    // Score each skill against the query using keyword overlap + trigram similarity
    $query_words = array_unique(preg_split('/\s+/', $query));
    $query_words = array_filter($query_words, fn($w) => mb_strlen($w) > 2);

    $scored = [];
    foreach ($index as $sk) {
        $desc = $sk['desc'];
        if ($desc === '') continue;

        $score = 0.0;

        // Word overlap scoring
        foreach ($query_words as $w) {
            if (strpos($desc, $w) !== false) $score += 1.0;
            if (strpos(strtolower($sk['name']), $w) !== false) $score += 0.5;
        }

        // Trigram similarity boost
        similar_text($query, $desc, $pct);
        $score += ($pct / 100.0) * 0.5;

        // Bonus for trigger phrase patterns matching query keywords
        // e.g. desc says "Use when user asks to write a blog" and query contains "blog"
        if (preg_match('/use when.*(' . implode('|', array_map('preg_quote', $query_words)) . ')/i', $desc)) {
            $score += 2.0;
        }

        if ($score > 0.3) {
            $scored[] = ['id'=>$sk['id'], 'name'=>$sk['name'], 'trigger'=>$sk['trigger'],
                'format'=>$sk['format'], 'score'=>round($score, 3)];
        }
    }

    usort($scored, fn($a, $b) => $b['score'] <=> $a['score']);
    $matches = array_slice($scored, 0, $limit);

    echo json_encode(['ok'=>true, 'matches'=>$matches, 'query'=>$query], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
