<?php
// =============================================================================
// transcribe.php — offline voice-input transcription (local whisper.cpp)
// Dario Ruggi / Cockpit
//
// POST an audio blob (field "audio"); we transcode to 16 kHz mono WAV with
// ffmpeg, run whisper.cpp locally, and return the transcript. Fully offline —
// no audio ever leaves the machine.
//
// Config (optional): cockpit_data/whisper_config.json
//   { "bin": "/path/to/whisper-cli", "model": "/path/to/ggml-base.bin",
//     "language": "auto" }
// If absent, we auto-detect the binary on PATH and search common model dirs.
// =============================================================================

header('Content-Type: application/json');

function fail($msg, $hint = '') {
    echo json_encode(['ok' => false, 'error' => $msg, 'hint' => $hint], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- locate cockpit_data (centralized paths.php) ---
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
ed_gate_or_exit('transcribe');   // demo: described-modal; v1/v2: real
$HOME = $PATHS['home'];

// --- config ---
$cfg = [];
$cfgF = $CD . '/whisper_config.json';
if (is_file($cfgF)) $cfg = json_decode((string)file_get_contents($cfgF), true) ?: [];

function find_bin(array $cands): string {
    foreach ($cands as $c) {
        $p = trim((string)shell_exec('command -v ' . escapeshellarg($c) . ' 2>/dev/null'));
        if ($p !== '') return $p;
    }
    return '';
}

// List installed models as { shortName => path }, e.g. { "base":..., "small":... }.
function list_models(string $HOME): array {
    $out = [];
    // ai-tools first: that is where the installer's own completion check looks
    // (and where transcriber.php reads), so voice input and the Trans panel now
    // agree. $HOME/whisper.cpp stays for installs that built it there.
    foreach (["$HOME/ai-tools/whisper.cpp/models", "$HOME/whisper.cpp/models",
              "$HOME/.cache/whisper", "$HOME/.local/share/whisper",
              '/usr/local/share/whisper', '/usr/share/whisper'] as $d) {
        foreach (glob($d . '/ggml-*.bin') ?: [] as $m) {
            // whisper.cpp ships 'for-tests-*' stubs of a few hundred KB that load
            // and transcribe into nonsense. Never offer one as a real model.
            if (str_starts_with(basename($m), 'for-tests-')) continue;
            if ((int)@filesize($m) < 5 * 1024 * 1024) continue;
            $name = preg_replace('/^ggml-|\.bin$/', '', basename($m));
            if (!isset($out[$name])) $out[$name] = $m;
        }
    }
    return $out;
}

// Resolve whisper binary + default model (shared by info + run path).
function detect_whisper(array $cfg, string $HOME): array {
    $bin = (string)($cfg['bin'] ?? '');
    if ($bin === '' || !is_file($bin)) {
        // Built from source it is not on PATH, so look where the installer puts
        // it before falling back to PATH (this rig had a working whisper-cli the
        // whole time and voice input still reported 'not installed').
        foreach (["$HOME/ai-tools/whisper.cpp/build/bin/whisper-cli",
                  "$HOME/whisper.cpp/build/bin/whisper-cli",
                  "$HOME/ai-tools/whisper.cpp/main",
                  "$HOME/whisper.cpp/main"] as $c) {
            if (is_file($c) && is_executable($c)) { $bin = $c; break; }
        }
    }
    if ($bin === '' || !is_file($bin)) $bin = find_bin(['whisper-cli', 'whisper-cpp', 'whisper', 'main']);
    $model = (string)($cfg['model'] ?? '');
    if ($model === '' || !is_file($model)) {
        // "auto": largest installed model wins (bigger = better, esp. Hebrew).
        $best = ''; $bestSize = -1;
        foreach (list_models($HOME) as $m) {
            $sz = filesize($m);
            if ($sz > $bestSize) { $bestSize = $sz; $best = $m; }
        }
        if ($best !== '') $model = $best;
    }
    return [$bin, $model];
}

// --- info endpoint: active model + the list of installed models (for the picker) ---
if (($_GET['action'] ?? '') === 'info') {
    [$ibin, $imodel] = detect_whisper($cfg, $HOME);
    $mname  = $imodel ? preg_replace('/^ggml-|\.bin$/', '', basename($imodel)) : '';
    // Sort installed model names by size so the dropdown reads small → large.
    $models = list_models($HOME);
    uasort($models, fn($a, $b) => filesize($a) <=> filesize($b));
    echo json_encode([
        'ok'        => ($ibin !== '' && $imodel !== ''),
        'available' => ($ibin !== '' && $imodel !== ''),
        'model'     => $mname,                 // currently-active (when "auto")
        'models'    => array_keys($models),    // installed, small→large
        'bin'       => $ibin ? basename($ibin) : '',
        'engine'    => 'whisper.cpp',
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 1. receive audio ---
if (empty($_FILES['audio']) || !is_uploaded_file($_FILES['audio']['tmp_name'])) {
    fail(cockpit_upload_limit_message() ?: 'No audio uploaded');
}
if (($_FILES['audio']['size'] ?? 0) > 25 * 1024 * 1024) fail('Audio too large (25 MB cap)');

$base = sys_get_temp_dir() . '/cockpit_voice_' . bin2hex(random_bytes(6));
$rawf = $base . '.input';
$wavf = $base . '.wav';
if (!move_uploaded_file($_FILES['audio']['tmp_name'], $rawf)) fail('Could not stage upload');

$cleanup = function () use ($base) {
    foreach (glob($base . '*') ?: [] as $f) @unlink($f);
};

// --- 2. ffmpeg → 16 kHz mono WAV (whisper.cpp wants PCM 16 kHz) ---
$ffmpeg = find_bin(['ffmpeg']);
if ($ffmpeg === '') { $cleanup(); fail('ffmpeg not found', 'Install ffmpeg (sudo nala install ffmpeg)'); }
exec(escapeshellarg($ffmpeg) . ' -y -i ' . escapeshellarg($rawf) .
     ' -ar 16000 -ac 1 -f wav ' . escapeshellarg($wavf) . ' 2>/dev/null', $o1, $rc1);
if ($rc1 !== 0 || !is_file($wavf)) { $cleanup(); fail('Audio decode failed (ffmpeg)'); }

// --- 3. locate whisper.cpp binary + model ---
[$bin, $model] = detect_whisper($cfg, $HOME);
// Per-request model override from the mic-bar picker ("auto" → keep detected).
$reqModel = preg_replace('/[^a-z0-9._-]/i', '', (string)($_POST['model'] ?? ''));
if ($reqModel !== '' && strtolower($reqModel) !== 'auto') {
    $models = list_models($HOME);
    if (isset($models[$reqModel])) $model = $models[$reqModel];
}

if ($bin === '') {
    $cleanup();
    fail('whisper.cpp not installed',
         'Build whisper.cpp, then set "bin" (and "model") in ' . $cfgF);
}
if ($model === '') {
    $cleanup();
    fail('No whisper model found',
         'Download a ggml model (e.g. ggml-base.bin) and set "model" in ' . $cfgF);
}

// --- 4. run whisper.cpp ---
// Per-request language override (from the mic-bar selector) beats the config.
// Whisper's auto-detect often mistakes Hebrew for Arabic, so letting the user
// force "he" is the reliable fix. Whitelist to keep it to an ISO-ish code.
$lang = (string)($cfg['language'] ?? 'auto');
$reqLang = strtolower(trim((string)($_POST['language'] ?? '')));
if ($reqLang !== '' && preg_match('/^(auto|[a-z]{2,3})$/', $reqLang)) $lang = $reqLang;
$outbase = $base . '_out';
$cmd = escapeshellarg($bin) . ' -m ' . escapeshellarg($model) . ' -f ' . escapeshellarg($wavf) .
       ' -l ' . escapeshellarg($lang) . ' -otxt -nt -of ' . escapeshellarg($outbase) . ' 2>/dev/null';
exec($cmd, $o2, $rc2);

$txtf = $outbase . '.txt';
$text = is_file($txtf) ? trim((string)file_get_contents($txtf)) : '';
$cleanup();

if ($rc2 !== 0 && $text === '') {
    fail('whisper transcription failed', 'Verify "bin"/"model" in ' . $cfgF);
}
// Say which model ACTUALLY ran. The info endpoint names the detected one, but a pick
// in the picker can override it, and a pick that silently fell back (a name that is
// not installed) was indistinguishable from one that worked: the result line said only
// "whisper.cpp". Reporting what was really used makes a model choice checkable.
echo json_encode(['ok' => true, 'text' => $text, 'engine' => 'whisper.cpp',
                  'model' => preg_replace('/^ggml-|\.bin$/', '', basename($model))], JSON_UNESCAPED_UNICODE);
