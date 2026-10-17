<?php
// =============================================================================
// power.php — Power Buttons: one click runs a saved prompt on what you copied, with the supplier you chose, and puts the answer where you want it.
// The design, the safety rules and the steps are in plans/PLAN_3_power_buttons.md; the library is power_lib.php; `power_run` is the command-line client that launchers use.
//
//   GET  ?action=list                 → { ok, buttons:[…mine], starters:[…], ollama:{up,models,default}, history:[last 20] }
//   GET  ?action=get&id=X             → { ok, button }
//   POST {action:save, button:{…}}    → create or update (the id comes from the name if absent)
//   POST {action:delete, id}          → remove one of mine
//   POST {action:add_starter, id}     → copy a starter into mine
//   POST {action:run, id|name, input?, image?:{b64}, supplier?, confirmed?, allow_secrets_once?}
//                                     → run it: { ok, output, supplier, model, ms, truncated }  or  { ok:false, gate:'need_input'|'confirm'|'secret'|'empty'|'no_local'|'no_vision'|…, error }
//                                       Send no `input` and no `image` and a button that needs one answers gate:'need_input' with want:'clipboard'|'selection'|'image'|'file' (a launcher then reads that and asks again).
//                                       allow_secrets_once (the panel only, never the internal key) lets text that looks like a secret go to a cloud supplier for this one run.
//   GET  ?action=launch_spec&id=X[&platform=linux|macos|windows] → { ok, platform, files:[{name, content, mode}], cmd }   the launcher files for one button (the panel installs them through the Cockpit window, or offers them as a download)
//   GET  ?action=fm_integration       → { ok, nautilus:[{name,content}], dolphin }   right-click actions for the system file manager (one per button; the selected files are the input)
//   GET  ?action=cli_script           → { ok, name:'cockpit-run', content }   the command-line tool for scripts
//   GET  ?action=shell_sync           → { ok, hotkeys:[{key,cmd}], menu:[{name,cmd}] }   what the Cockpit window grabs as global hotkeys, and lists in a Browser window's ⚡ menu (X11 only)
//   POST {action:pack_export, ids?:[…], name?}  → { ok, pack }        POST {action:pack_import, pack:'<json>', apply?:bool} → preview, or save (a pack always runs on a model on this computer)
//   GET  ?action=rules_list · POST {action:rule_save, rule} · POST {action:rule_delete, id}   watched folders / daily / repeating buttons (power_sched_lib.php)
//   POST {action:history_clear}       → forget the run history (session only)
//   POST {action:consent, supplier}   → remember that this cloud supplier may receive what you copy (first-run confirmation); needs a signed-in session, never internal
// Cloud suppliers (workers) are called through workers.php?action=invoke, so the paid-spend consent, the monthly caps and the usage meter apply exactly as in chat.
// A local model (Ollama) is called directly: nothing leaves the machine, so it needs no confirmation and no secret check.
// Storage: <cockpit_data>/power_buttons/<id>.json (mine), power_buttons.history.jsonl (one line per run, no content), power_consent.json.
// =============================================================================
ini_set('display_errors', '0'); error_reporting(0);
header('Content-Type: application/json'); header('Cache-Control: no-store');
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
require_once __DIR__ . '/power_lib.php';
require_once __DIR__ . '/power_sched_lib.php';

if (ed_is('demo') && ed_is_direct(__FILE__)) {   // the web demo has no real suppliers
    $a = $_GET['action'] ?? 'list';
    if ($a === 'list') { echo json_encode(['ok' => true, 'buttons' => [], 'starters' => [], 'ollama' => ['up' => false, 'models' => [], 'default' => null], 'history' => [], 'demo' => true]); exit; }
    ed_demo_stub();
}
$DIR = $CD . '/power_buttons'; $HIST = $CD . '/power_buttons.history.jsonl'; $CONSENT = $CD . '/power_consent.json'; $STARTERS = __DIR__ . '/power_starters';
if (!is_dir($DIR)) @mkdir($DIR, 0775, true);

$action = $_GET['action'] ?? ''; $in = [];
if ($_SERVER['REQUEST_METHOD'] === 'POST') { $raw = json_decode((string)file_get_contents('php://input'), true); if (is_array($raw)) $in = $raw; if ($action === '') $action = (string)($in['action'] ?? ''); }
if ($action === '') $action = 'list';

function pw_out(array $a, int $code = 200): void { if ($code !== 200) http_response_code($code); echo json_encode($a, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); exit; }
function pw_read(string $f): ?array { $j = is_file($f) ? json_decode((string)@file_get_contents($f), true) : null; return is_array($j) ? $j : null; }
function pw_write(string $f, array $d): bool { $t = $f . '.tmp' . getmypid(); if (@file_put_contents($t, json_encode($d, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) return false; @chmod($t, 0664); return @rename($t, $f); }
function pw_all(string $dir): array { $o = []; foreach (glob($dir . '/*.json') ?: [] as $f) { $b = pw_read($f); if ($b && isset($b['id'])) $o[] = $b; } usort($o, fn($a, $b) => strcasecmp($a['name'] ?? '', $b['name'] ?? '')); return $o; }
function pw_find(string $dir, string $starters, string $key): ?array {
    $key = trim($key); if ($key === '') return null;
    foreach ([$dir, $starters] as $d) foreach (pw_all($d) as $b) if (($b['id'] ?? '') === $key || strcasecmp($b['name'] ?? '', $key) === 0) return $b;
    return null;
}
function pw_is_internal(): bool { return !empty($_SERVER['HTTP_X_COCKPIT_INTERNAL']); }

if ($action === 'list') {
    $o = power_ollama_models(); $hist = [];
    if (is_file($HIST)) foreach (array_slice(@file($HIST, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [], -50) as $l) { $j = json_decode($l, true); if (is_array($j)) $hist[] = $j; }
    pw_out(['ok' => true, 'buttons' => pw_all($DIR), 'starters' => pw_all($STARTERS), 'ollama' => ['up' => $o['up'], 'models' => array_map(fn($m) => ['name' => $m['name'] ?? '', 'size' => $m['size'] ?? 0], $o['models']), 'default' => power_ollama_pick($o['models']), 'vision' => power_pick_vision($o['models']), 'vision_models' => array_values(array_filter(array_map(fn($m) => $m['name'] ?? '', $o['models']), 'power_is_vision_model'))],
            'consent' => (pw_read($CONSENT)['suppliers'] ?? []), 'history' => array_reverse($hist)]);
}
if ($action === 'get') { $b = pw_find($DIR, $STARTERS, (string)($_GET['id'] ?? '')); pw_out($b ? ['ok' => true, 'button' => $b] : ['ok' => false, 'error' => 'No such button'], $b ? 200 : 404); }
if ($action === 'save') {
    $v = power_validate_button(is_array($in['button'] ?? null) ? $in['button'] : []);
    if (is_string($v)) pw_out(['ok' => false, 'error' => $v], 400);
    if ($v['hotkey'] !== '') foreach (pw_all($DIR) as $o) if ($o['id'] !== $v['id'] && strtolower((string)($o['hotkey'] ?? '')) === $v['hotkey']) pw_out(['ok' => false, 'error' => 'The hotkey ' . $v['hotkey'] . ' is already used by "' . $o['name'] . '".'], 400);
    if (!is_file($DIR . '/' . $v['id'] . '.json') && count(glob($DIR . '/*.json') ?: []) >= 200) pw_out(['ok' => false, 'error' => 'Too many buttons (200 at most).'], 400);
    $old = pw_read($DIR . '/' . $v['id'] . '.json'); if ($old && isset($old['created'])) $v['created'] = $old['created']; else $v['created'] = gmdate('c');
    pw_out(pw_write($DIR . '/' . $v['id'] . '.json', $v) ? ['ok' => true, 'button' => $v] : ['ok' => false, 'error' => 'Could not save'], 200);
}
if ($action === 'delete') { $id = (string)($in['id'] ?? ''); if (!preg_match('/^[a-z0-9][a-z0-9_-]{0,47}$/', $id) || !is_file($DIR . '/' . $id . '.json')) pw_out(['ok' => false, 'error' => 'No such button'], 404); @unlink($DIR . '/' . $id . '.json'); pw_out(['ok' => true]); }
if ($action === 'add_starter') {
    $s = pw_read($STARTERS . '/' . preg_replace('/[^a-z0-9_-]/', '', (string)($in['id'] ?? '')) . '.json'); if (!$s) pw_out(['ok' => false, 'error' => 'No such starter'], 404);
    $id = $s['id']; $n = 2; while (is_file($DIR . '/' . $id . '.json')) { $id = $s['id'] . '-' . $n++; }
    $s['id'] = $id; $v = power_validate_button($s); if (is_string($v)) pw_out(['ok' => false, 'error' => $v], 400); $v['created'] = gmdate('c');
    pw_out(pw_write($DIR . '/' . $id . '.json', $v) ? ['ok' => true, 'button' => $v] : ['ok' => false, 'error' => 'Could not save']);
}
if ($action === 'history_clear') { if (pw_is_internal()) pw_out(['ok' => false, 'error' => 'Do this in Cockpit itself.'], 403); @unlink($HIST); pw_out(['ok' => true]); }
if ($action === 'consent') {
    if (pw_is_internal()) pw_out(['ok' => false, 'error' => 'Confirm this in Cockpit itself.'], 403);
    $p = (string)($in['supplier'] ?? ''); if (!preg_match('/^[a-z0-9_-]{1,40}$/', $p)) pw_out(['ok' => false, 'error' => 'Bad supplier'], 400);
    $c = pw_read($CONSENT) ?: ['suppliers' => []]; if (!in_array($p, $c['suppliers'], true)) $c['suppliers'][] = $p; pw_write($CONSENT, $c); pw_out(['ok' => true, 'consent' => $c['suppliers']]);
}

// ── how to start power_run from outside: the launch spec ────────────────────────────────────────────────────────────────────────────────────────
function pw_platform(string $asked): string {
    if (in_array($asked, ['linux', 'macos', 'windows'], true)) { if ($asked === 'linux' && pw_is_wsl()) return 'wsl'; return $asked; }
    if (PHP_OS_FAMILY === 'Darwin') return 'macos'; if (PHP_OS_FAMILY === 'Windows') return 'windows'; return pw_is_wsl() ? 'wsl' : 'linux';
}
function pw_is_wsl(): bool { return getenv('WSL_DISTRO_NAME') !== false && getenv('WSL_DISTRO_NAME') !== '' || stripos((string)@file_get_contents('/proc/version'), 'microsoft') !== false; }
function pw_spec(): array {
    global $PATHS, $CD;
    $php = PHP_BINARY; if ($php === '' || !is_executable($php) || !preg_match('/^php[0-9.]*$/', basename($php))) $php = is_executable(PHP_BINDIR . '/php') ? PHP_BINDIR . '/php' : 'php';
    $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http';
    $login = (string)($_SESSION['cockpit_user'] ?? ($_SERVER['HTTP_X_COCKPIT_USER'] ?? ''));
    $spec = ['php' => $php, 'run' => realpath(__DIR__ . '/power_run') ?: (__DIR__ . '/power_run'), 'base' => $scheme . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost') . rtrim(dirname($_SERVER['SCRIPT_NAME'] ?? '/'), '/'),
        'user' => preg_match('/^[A-Za-z0-9_-]{1,64}$/', $login) ? $login : '', 'data_root' => rtrim((string)($PATHS['cockpit_data_root'] ?? $CD), '/'), 'wsl_distro' => (string)getenv('WSL_DISTRO_NAME')];
    return $spec;
}
if ($action === 'launch_spec') {
    $b = pw_find($DIR, $STARTERS, (string)($_GET['id'] ?? '')); if (!$b) pw_out(['ok' => false, 'error' => 'No such button'], 404);
    $spec = pw_spec(); $plat = pw_platform((string)($_GET['platform'] ?? '')); $files = [];
    foreach (power_launcher_files($plat, $b, $spec) as $n => $c) $files[] = ['name' => $n, 'content' => $c[0], 'mode' => $c[1]];
    if (!$files) pw_out(['ok' => false, 'error' => 'No launcher for this system.'], 400);
    pw_out(['ok' => true, 'platform' => $plat, 'files' => $files, 'cmd' => power_command_line($spec, $b['name']), 'cli' => $spec['run']]);
}
if ($action === 'fm_integration') {   // the right-click actions for the system file manager (Nautilus/Nemo scripts, a Dolphin menu)
    $f = power_fm_files(pw_all($DIR), pw_spec()); $n = []; foreach ($f['nautilus'] as $name => $c) $n[] = ['name' => $name, 'content' => $c];
    pw_out(['ok' => true, 'nautilus' => array_slice($n, 0, 40), 'dolphin' => $f['dolphin'], 'count' => count($n)]);
}
if ($action === 'cli_script') pw_out(['ok' => true, 'name' => 'cockpit-run', 'content' => power_cli_script(pw_spec())]);
if ($action === 'shell_sync') {
    $spec = pw_spec(); $hot = []; $menu = [];
    foreach (pw_all($DIR) as $b) {
        if (($b['hotkey'] ?? '') !== '') $hot[] = ['key' => $b['hotkey'], 'cmd' => power_command_line($spec, $b['name'])];
        if (($b['input'] ?? '') === 'selection' || ($b['input'] ?? '') === 'clipboard') $menu[] = ['name' => $b['name'], 'icon' => $b['icon'] ?? 'bolt', 'cmd' => power_command_line($spec, $b['name'], ['--from', 'selection'])];
    }
    pw_out(['ok' => true, 'hotkeys' => $hot, 'menu' => array_slice($menu, 0, 30)]);
}

// ── packs: share buttons as one file ───────────────────────────────────────────────────────────────────────────────────────────────────────────
if ($action === 'pack_export') {
    $ids = is_array($in['ids'] ?? null) ? array_map('strval', $in['ids']) : null; $sel = [];
    foreach (pw_all($DIR) as $b) if ($ids === null || in_array($b['id'], $ids, true)) $sel[] = $b;
    if (!$sel) pw_out(['ok' => false, 'error' => 'There are no buttons to put in a pack.'], 400);
    pw_out(['ok' => true, 'pack' => power_pack_export($sel, (string)($in['name'] ?? '')), 'count' => count($sel)]);
}
if ($action === 'pack_import') {
    [$ok, $err, $btns, $skip] = power_pack_parse((string)($in['pack'] ?? '')); if (!$ok) pw_out(['ok' => false, 'error' => $err], 400);
    $have = array_column(pw_all($DIR), 'name', 'id'); $rows = [];
    foreach ($btns as $b) $rows[] = ['id' => $b['id'], 'name' => $b['name'], 'icon' => $b['icon'], 'description' => $b['description'], 'prompt' => mb_substr($b['prompt'], 0, 400), 'input' => $b['input'], 'output' => $b['output'], 'exists' => isset($have[$b['id']])];
    if (empty($in['apply'])) pw_out(['ok' => true, 'preview' => $rows, 'skipped' => $skip]);
    $pick = is_array($in['ids'] ?? null) ? array_map('strval', $in['ids']) : null; $saved = [];
    foreach ($btns as $b) {
        if ($pick !== null && !in_array($b['id'], $pick, true)) continue;
        if (count(glob($DIR . '/*.json') ?: []) >= 200) break;
        $id = $b['id']; $n = 2; while (is_file($DIR . '/' . $id . '.json')) $id = substr($b['id'], 0, 44) . '-' . $n++;   // never overwrite one of mine
        $b['id'] = $id; $b['created'] = gmdate('c'); if (pw_write($DIR . '/' . $id . '.json', $b)) $saved[] = ['id' => $id, 'name' => $b['name']];
    }
    pw_out(['ok' => true, 'saved' => $saved, 'skipped' => $skip]);
}

// ── automation rules ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
if ($action === 'rules_list') {
    $log = is_file($CD . '/power_rules.log') ? array_slice(@file($CD . '/power_rules.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [], -15) : [];
    pw_out(['ok' => true, 'rules' => power_rules_read($CD), 'log' => $log]);
}
if ($action === 'rule_save') {
    if (pw_is_internal()) pw_out(['ok' => false, 'error' => 'Do this in Cockpit itself.'], 403);
    $r = is_array($in['rule'] ?? null) ? $in['rule'] : []; $v = power_rule_validate($r); if (is_string($v)) pw_out(['ok' => false, 'error' => $v], 400);
    if (!pw_find($DIR, $STARTERS, $v['button'])) pw_out(['ok' => false, 'error' => 'There is no button called "' . $v['button'] . '".'], 400);
    $rules = power_rules_read($CD); $found = false;
    foreach ($rules as $i => $o) if (($o['id'] ?? '') === $v['id']) { $v['created'] = $o['created'] ?? $v['created']; $rules[$i] = $v; $found = true; }
    if (!$found) { if (count($rules) >= POWER_RULES_MAX) pw_out(['ok' => false, 'error' => 'Too many rules (' . POWER_RULES_MAX . ' at most).'], 400); $rules[] = $v; }
    pw_out(power_rules_write($CD, $rules) ? ['ok' => true, 'rule' => $v] : ['ok' => false, 'error' => 'Could not save'], 200);
}
if ($action === 'rule_delete') {
    if (pw_is_internal()) pw_out(['ok' => false, 'error' => 'Do this in Cockpit itself.'], 403);
    $id = (string)($in['id'] ?? ''); $rules = array_values(array_filter(power_rules_read($CD), fn($o) => ($o['id'] ?? '') !== $id)); pw_out(['ok' => power_rules_write($CD, $rules)]);
}

if ($action === 'run') {
    $t0 = microtime(true);
    $b = pw_find($DIR, $STARTERS, (string)($in['id'] ?? $in['name'] ?? ''));
    if (!$b) pw_out(['ok' => false, 'error' => 'No such button: ' . (string)($in['id'] ?? $in['name'] ?? '')], 404);
    $want = (string)($b['input'] ?? 'clipboard'); $imgIn = $in['image'] ?? null;
    if ($want !== 'none' && !array_key_exists('input', $in) && $imgIn === null) pw_out(['ok' => false, 'gate' => 'need_input', 'want' => $want, 'name' => $b['name'], 'error' => 'This button needs the ' . $want . '.']);
    $image = null;
    if ($want === 'image') { $chk = power_check_image($imgIn); if (is_string($chk)) pw_out(['ok' => false, 'gate' => 'empty', 'error' => $imgIn === null ? 'There is nothing to work on: no picture was found.' : $chk]); $image = $chk; }
    $input = (string)($in['input'] ?? '');
    if ($want !== 'none' && $want !== 'image' && trim($input) === '') pw_out(['ok' => false, 'gate' => 'empty', 'error' => 'There is nothing to work on: the ' . ($b['input'] ?? 'clipboard') . ' is empty.']);
    // which supplier: the button's own, or (for "ask me each time") the caller's, or — for a launcher with nobody to ask — the local model
    $sup = $b['supplier'] ?? ['type' => 'ollama'];
    if (($sup['type'] ?? '') === 'ask') { $sup = is_array($in['supplier'] ?? null) ? $in['supplier'] : ['type' => 'ollama']; if (!in_array($sup['type'] ?? '', ['ollama', 'worker'], true)) $sup = ['type' => 'ollama']; }
    elseif (is_array($in['supplier'] ?? null) && !pw_is_internal()) { $sup = $in['supplier']; }   // an override from the panel's Test row
    $skillBody = null; if (($b['skill'] ?? '') !== '') { $sk = pw_read($CD . '/skills/' . preg_replace('/[^A-Za-z0-9_-]/', '', $b['skill']) . '.json'); $skillBody = is_array($sk) ? (string)($sk['body'] ?? '') : null; }
    [$prompt, $truncated] = power_build_prompt($b, $input, $skillBody, null, $image !== null);   // one message, the same for a model on this computer and for a cloud supplier
    $meta = ['id' => $b['id'], 'name' => $b['name'], 'chars_in' => mb_strlen($input)] + ($image !== null ? ['image' => true] : []);
    if (($sup['type'] ?? '') === 'ollama') {
        $model = trim((string)($sup['model'] ?? ''));
        if ($model === '') { $o = power_ollama_models(); if (!$o['up']) { power_history_append($HIST, $meta + ['supplier' => 'ollama', 'ok' => false, 'error' => 'no local model server']); pw_out(['ok' => false, 'gate' => 'no_local', 'error' => 'No local model server is running (Ollama). Start it, or choose a cloud supplier for this button.']); } $model = power_ollama_pick($o['models']) ?? ''; if ($model === '') pw_out(['ok' => false, 'gate' => 'no_local', 'error' => 'No local model is installed. Pull one with Ollama, or choose a cloud supplier for this button.']); }
        if ($image !== null) {   // a picture needs a model that can look at one
            $o2 = power_ollama_models(); if (!$o2['up']) pw_out(['ok' => false, 'gate' => 'no_local', 'error' => 'No local model server is running (Ollama).']);
            $model = power_is_vision_model($model) ? $model : (power_pick_vision($o2['models']) ?? '');
            if ($model === '') { power_history_append($HIST, $meta + ['supplier' => 'ollama', 'ok' => false, 'error' => 'no picture-capable local model']); pw_out(['ok' => false, 'gate' => 'no_vision', 'error' => 'No model on this computer can look at pictures (for example llava or gemma3). Install one with Ollama, or choose Anthropic for this button.']); }
        }
        $r = power_ollama_chat($model, $prompt, 180, $image !== null ? [$image['b64']] : []); $supName = 'ollama'; $mName = $model;
    } else {
        $prov = (string)($sup['provider'] ?? ''); $mName = (string)($sup['model'] ?? ''); $supName = $prov;
        if (!preg_match('/^[a-z0-9_-]{1,40}$/', $prov) || $mName === '') pw_out(['ok' => false, 'error' => 'This button has no usable cloud supplier.'], 400);
        if ($image !== null && $prov !== 'anthropic') pw_out(['ok' => false, 'gate' => 'no_vision', 'error' => 'Among the cloud suppliers only Anthropic can look at a picture here. Choose it, or a picture-capable model on this computer.']);
        // a cloud supplier gets a copy of what you copied: a first-run confirmation, and a stop for text that looks like a secret
        $cons = pw_read($CONSENT)['suppliers'] ?? []; $mode = $b['confirm'] ?? 'first';
        if ($mode === 'always' ? empty($in['confirmed']) : ($mode === 'first' && !in_array($prov, $cons, true))) pw_out(['ok' => false, 'gate' => 'confirm', 'supplier' => $prov, 'model' => $mName, 'mode' => $mode, 'image' => $image !== null, 'chars' => mb_strlen($input), 'preview' => mb_substr($input, 0, 200), 'error' => 'This sends ' . ($image !== null ? 'the picture you copied' : 'the text you copied') . ' to ' . $prov . '. Confirm once in Cockpit (Power Buttons) to allow it.']);
        if (empty($b['allow_secrets']) && !(!pw_is_internal() && !empty($in['allow_secrets_once'])) && ($kind = power_detect_secret($input)) !== null) { power_history_append($HIST, $meta + ['supplier' => $prov, 'model' => $mName, 'ok' => false, 'error' => 'looks like a secret']); pw_out(['ok' => false, 'gate' => 'secret', 'kind' => $kind, 'error' => 'The text looks like ' . $kind . ', so it was NOT sent to ' . $prov . '. Use a local model for this, or turn on "allow secrets" for the button.']); }
        // through the same door as the chat, so the spend consent, the caps and the meter apply
        $scheme = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') ? 'https' : 'http'; $base = $scheme . '://' . ($_SERVER['HTTP_HOST'] ?? 'localhost') . rtrim(dirname($_SERVER['SCRIPT_NAME'] ?? '/'), '/');
        $hdr = ['Content-Type: application/json'];
        if (pw_is_internal()) { $hdr[] = 'X-Cockpit-Internal: ' . $_SERVER['HTTP_X_COCKPIT_INTERNAL']; $hdr[] = 'X-Cockpit-User: ' . ($_SERVER['HTTP_X_COCKPIT_USER'] ?? ''); }
        else { if (session_status() === PHP_SESSION_ACTIVE) session_write_close(); $hdr[] = 'Cookie: ' . ($_SERVER['HTTP_COOKIE'] ?? ''); }
        $ch = curl_init($base . '/workers.php?action=invoke');
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_POST => true, CURLOPT_TIMEOUT => 240, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_HTTPHEADER => $hdr,
            CURLOPT_POSTFIELDS => json_encode(['provider' => $prov, 'model' => $mName, 'task' => 'text', 'prompt' => $prompt, 'user_text' => $input] + ($image !== null ? ['extra' => ['images' => [['media_type' => $image['mime'], 'data' => $image['b64']]]]] : []), JSON_UNESCAPED_UNICODE)]);
        $resp = curl_exec($ch); $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); $cerr = curl_error($ch); curl_close($ch);
        $j = $resp !== false ? json_decode((string)$resp, true) : null;
        if (!is_array($j)) { $r = ['ok' => false, 'error' => 'The supplier call failed (' . ($cerr ?: "HTTP $code") . ').']; }
        elseif (empty($j['ok'])) { $r = ['ok' => false, 'error' => (string)($j['error'] ?? 'The supplier refused.'), 'gate' => $j['gate'] ?? null]; }
        else { $r = ['ok' => true, 'output' => (string)($j['output'] ?? ''), 'tokens_in' => $j['tokens_in'] ?? null, 'tokens_out' => $j['tokens_out'] ?? null, 'cost_usd' => $j['cost_usd'] ?? null]; }
    }
    $ms = (int)round((microtime(true) - $t0) * 1000);
    if (empty($r['ok'])) { power_history_append($HIST, $meta + ['supplier' => $supName, 'model' => $mName, 'ms' => $ms, 'ok' => false, 'error' => mb_substr((string)($r['error'] ?? ''), 0, 160)]); pw_out(['ok' => false, 'gate' => $r['gate'] ?? null, 'error' => (string)($r['error'] ?? 'failed'), 'supplier' => $supName, 'model' => $mName]); }
    $out = (string)$r['output']; $outTrunc = false; if (mb_strlen($out) > POWER_MAX_OUTPUT) { $out = mb_substr($out, 0, POWER_MAX_OUTPUT); $outTrunc = true; }
    $out = power_clean_output($out);
    power_history_append($HIST, $meta + ['supplier' => $supName, 'model' => $mName, 'ms' => $ms, 'chars_out' => mb_strlen($out), 'ok' => true]);
    pw_out(['ok' => true, 'output' => $out, 'supplier' => $supName, 'model' => $mName, 'ms' => $ms, 'truncated_input' => $truncated, 'truncated_output' => $outTrunc, 'cost_usd' => $r['cost_usd'] ?? null, 'output_to' => $b['output'] ?? 'clipboard', 'name' => $b['name']]);
}
pw_out(['ok' => false, 'error' => 'Unknown action'], 400);
