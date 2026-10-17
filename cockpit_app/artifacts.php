<?php
// =============================================================================
// artifacts.php — everything this project PRODUCED, in one list.
//
// Before 2026-09-22 the output of a session was scattered: images and audio in
// cockpit_data/<user>/generated/, tool outputs wherever the tool wrote them,
// transcripts under transcripts/, approved code in the snippet store, and files
// the agents wrote straight into the project folder. Nothing answered the plain
// question "what did this project make?".
//
// An artifact here is a FILE ON DISK (never a cloud object), listed with where it
// came from: which chat/agent/model produced it when that is knowable. Read-only
// by design except delete — it aggregates, it does not own.
//
// ACTIONS
//   ?action=list&project=X[&kind=all|image|audio|video|doc|code|data|other]
//   ?action=delete {path}            → remove one produced file (guarded)
//
// There is no 'open' action: the panel opens and reveals files through
// launch_cli.php (modes 'open' and 'files') directly. This header advertised
// one for months and nothing implemented it.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

$CD        = $PATHS['cockpit_data'];
$ROOT      = rtrim((string)($PATHS['projects_root'] ?? ''), '/');
$action    = $_GET['action'] ?? 'list';
$in        = json_decode((string)file_get_contents('php://input'), true) ?: [];
$project   = preg_replace('/[^A-Za-z0-9 _.\-]/', '', (string)($_GET['project'] ?? $in['project'] ?? ''));
if ($project === '') $project = '_standalone';
$projDir   = $ROOT . '/' . $project;

function art_kind(string $path): string {
    $e = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    if (in_array($e, ['png','jpg','jpeg','gif','webp','svg','bmp','ico'], true))      return 'image';
    if (in_array($e, ['wav','mp3','ogg','flac','m4a','opus'], true))                  return 'audio';
    if (in_array($e, ['mp4','webm','mkv','mov','avi'], true))                          return 'video';
    if (in_array($e, ['pdf','docx','odt','epub','html','htm','md','markdown','txt','text','rtf','pptx','srt','vtt'], true)) return 'doc';
    if (in_array($e, ['json','csv','tsv','xlsx','ods','xml','yaml','yml','sqlite','db'], true))           return 'data';
    // The snippet store names files after the language, not the usual file
    // extension, so a saved Python snippet lands on disk as ".python" and a
    // plain one as ".text". Both were classified 'other', and the Code filter
    // therefore returned nothing at all while three code snippets sat in the list.
    if (in_array($e, ['php','js','jsx','ts','tsx','py','python','sh','bash','zsh','pas','pascal','c','h','cpp','hpp','cs','rs','rust','go','golang','rb','ruby','java','kt','swift','lua','pl','perl','r','scala','css','scss','sql','ini','conf','toml','vb','asm','m'], true)) return 'code';
    return 'other';
}

/** Which chat/agent/model produced this file, when the chat log says so. */
function art_provenance(string $projDir, array &$cache, string $file): array {
    if (!$cache) {
        $cache = ['by_name' => []];
        foreach ((glob($projDir . '/chat_*.json') ?: []) as $cf) {
            if (str_starts_with(basename($cf), 'chat__')) continue;   // scratch chats
            $raw = (string)@file_get_contents($cf);
            $raw = preg_replace('/("duration_s":\s*)\.(\d)/', '${1}0.$2', $raw);
            $j = json_decode($raw, true);
            if (!is_array($j)) continue;
            $chat = preg_replace('/^chat_|\.json$/', '', basename($cf));
            foreach ((array)($j['exchanges'] ?? []) as $ex) {
                if (($ex['role'] ?? '') !== 'agent') continue;
                $txt = (string)($ex['text'] ?? '');
                if ($txt === '') continue;
                // file names the turn mentions (CRUD results, tool outputs, generated media)
                // This matches what a turn MENTIONS, which is weaker than what a
                // turn MADE -- it is a best-effort label, not a record. Probed on
                // a real project it had learned 57 "filenames", most of them
                // version numbers and IP addresses: 0.3b, 1.5b, qwen2.5,
                // llama3.2, 127.0.0.1, 192.168.1.105, 10245.31294. Harmless only
                // until a project contains a file actually called favicon.ico or
                // index.js -- both of which agents mention constantly -- and then
                // it attributes that file to whoever said the word.
                //
                // Two guards. The extension must be ALPHABETIC, which is what
                // kills every version number and address above. And a mention
                // that carries a directory separator (tool output says
                // "Output: /path/to/thing.html") is real evidence of writing,
                // so it outranks a bare mention and may overwrite one.
                if (preg_match_all('#[\w./\- ]+\.[A-Za-z0-9]{1,8}#', $txt, $m)) {
                    foreach ($m[0] as $cand) {
                        $cand = trim($cand);
                        $bn   = basename($cand);
                        if ($bn === '' || strlen($bn) < 4) continue;
                        $ext = pathinfo($bn, PATHINFO_EXTENSION);
                        if (!preg_match('/^[A-Za-z]{1,8}$/', $ext)) continue;   // 2.5, 1.5b, .105
                        if (!preg_match('/[A-Za-z]/', pathinfo($bn, PATHINFO_FILENAME))) continue;
                        $strength = str_contains($cand, '/') ? 2 : 1;
                        $have = $cache['by_name'][$bn]['strength'] ?? 0;
                        if ($strength <= $have) continue;
                        $cache['by_name'][$bn] = [
                            'chat'     => $chat,
                            'agent'    => (string)($ex['supplier'] ?? $ex['agent'] ?? ''),
                            'model'    => (string)($ex['model'] ?? ''),
                            'ts'       => (string)($ex['timestamp'] ?? ''),
                            'strength' => $strength,
                        ];
                    }
                }
            }
        }
    }
    return $cache['by_name'][basename($file)] ?? [];
}

if ($action === 'list') {
    $kindWanted = preg_replace('/[^a-z]/', '', strtolower((string)($_GET['kind'] ?? 'all')));
    $seen = []; $items = []; $prov = [];

    $add = function (string $path, string $source) use (&$items, &$seen, &$prov, $projDir) {
        $rp = realpath($path);
        if (!$rp || !is_file($rp) || isset($seen[$rp])) return;
        $bn = basename($rp);
        if ($bn[0] === '.' ) return;
        if (preg_match('/\.(lock|pid|log|err|done|cancelled|tmp|part)$/i', $bn)) return;
        // Conversations, not artifacts. The suffix is optional because the
        // repair script and the app both leave chat_x.json.bak beside the real
        // file, and the old anchored pattern let every backup through: a
        // conversation backup was listed as something the project produced.
        if (preg_match('/^chat_.*\.json(\.[A-Za-z0-9]+)?$/i', $bn)) return;
        if (in_array($bn, ['COCKPIT.md', 'library_index.json', '.cockpit_project.json'], true)) return;
        $seen[$rp] = true;
        $p = art_provenance($projDir, $prov, $rp);
        $items[] = [
            'name'   => $bn,
            'path'   => $rp,
            'kind'   => art_kind($rp),
            'size'   => filesize($rp) ?: 0,
            'mtime'  => date('c', filemtime($rp) ?: time()),
            'source' => $source,
            'chat'   => $p['chat']  ?? '',
            'agent'  => $p['agent'] ?? '',
            'model'  => $p['model'] ?? '',
            // Was this file NAMED WITH A PATH by the turn (tool output: real
            // evidence it wrote the file), or merely mentioned? The panel says
            // "made by" for the first and "mentioned by" for the second, rather
            // than presenting a guess as a fact.
            'sure'   => (($p['strength'] ?? 0) >= 2),
        ];
    };

    // 1. Files the agents wrote into the project (CRUD blocks, Claude's own tools, tool outputs)
    foreach ((glob($projDir . '/*') ?: []) as $f) if (is_file($f)) $add($f, 'project');
    foreach (['out', 'output', 'build', 'dist', 'exports'] as $sub) {
        foreach ((glob($projDir . '/' . $sub . '/*') ?: []) as $f) if (is_file($f)) $add($f, 'project/' . $sub);
    }
    // 2. Generated media (Image / Sound / Video buttons)
    foreach ((glob(rtrim($CD, '/') . '/generated/*') ?: []) as $f) if (is_file($f)) $add($f, 'generated');
    // 3. Transcripts (Trans) — one folder per job
    foreach ((glob(rtrim($CD, '/') . '/transcripts/*/*') ?: []) as $f) if (is_file($f)) $add($f, 'transcript');
    // 4. Saved snippets and sources (approved proposals land here)
    foreach (['snippets', 'sources'] as $sub) {
        foreach ((glob(rtrim($CD, '/') . '/' . $sub . '/*') ?: []) as $f) if (is_file($f)) $add($f, $sub);
    }

    if ($kindWanted !== '' && $kindWanted !== 'all') {
        $items = array_values(array_filter($items, fn($i) => $i['kind'] === $kindWanted));
    }
    usort($items, fn($a, $b) => strcmp($b['mtime'], $a['mtime']));
    $counts = [];
    foreach ($items as $i) $counts[$i['kind']] = ($counts[$i['kind']] ?? 0) + 1;

    echo json_encode(['ok' => true, 'project' => $project, 'count' => count($items),
                      'counts' => (object)$counts, 'items' => array_slice($items, 0, 400)], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'delete') {
    $path = (string)($in['path'] ?? '');
    $rp   = realpath($path);
    $okRoots = array_filter([realpath($projDir), realpath(rtrim($CD, '/'))]);
    $inside  = false;
    foreach ($okRoots as $r) if ($rp && str_starts_with($rp, $r . '/')) $inside = true;
    if (!$rp || !is_file($rp) || !$inside) { echo json_encode(['ok'=>false,'error'=>'Not a deletable artifact']); exit; }
    $ok = @unlink($rp);
    echo json_encode(['ok' => $ok, 'path' => $rp, 'error' => $ok ? null : 'delete failed (permissions?)'], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
