<?php
// =============================================================================
// generate.php — local multimodal generation (Image / Sound / Video)
// Dario Ruggi / Cockpit  — Phase 2c
//
// Offline generators, all local:
//   image  → sd-cli (stable-diffusion.cpp, Vulkan/GPU)
//   sound  → piper  (local TTS; speaks the prompt text)
//   video  → sd-cli frames (varying seed) → ffmpeg → animated GIF
//
// Async job model (generation takes ~20s+):
//   POST ?action=start  {kind, prompt, preset}     → { ok, id }
//   GET  ?action=status&id=<id>                     → { state, ... }
//   GET  ?action=file&id=<id>                       → streams the output file
//
// Degrades gracefully: if a binary/model is missing, status returns a clear hint.
// =============================================================================

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';
ed_gate_or_exit('generate');   // demo: described-modal; v1/v2: real
$HOME = $PATHS['home'];
$GEN_DIR = $CD . '/generated';
@mkdir($GEN_DIR, 0775, true);

// stable-diffusion.cpp builds a binary named `sd`; older builds/our installer
// also expose an `sd-cli` symlink. Accept whichever exists.
$SD_BIN = '';
foreach ([$HOME.'/ai-tools/sd.cpp/build/bin/sd-cli', $HOME.'/ai-tools/sd.cpp/build/bin/sd'] as $_cand) {
    if (is_file($_cand) && is_executable($_cand)) { $SD_BIN = $_cand; break; }
}
if ($SD_BIN === '') $SD_BIN = $HOME . '/ai-tools/sd.cpp/build/bin/sd-cli';   // default for the "not built" message
// First .safetensors/.gguf model found in models/ (any SD checkpoint works).
$SD_MODEL = $HOME . '/ai-tools/sd.cpp/models/sd-v1-5.safetensors';
if (!is_file($SD_MODEL)) {
    foreach (glob($HOME . '/ai-tools/sd.cpp/models/*.{safetensors,gguf,ckpt}', GLOB_BRACE) ?: [] as $_m) { $SD_MODEL = $_m; break; }
}
$PIPER_BIN  = $HOME . '/ai-tools/piper/piper';
$PIPER_DIR  = $HOME . '/ai-tools/piper';
function _ffmpeg(): string { $p = trim((string)shell_exec('command -v ffmpeg 2>/dev/null')); return $p; }
// Auto-detect a piper voice for a language by filename prefix (en_*, es_*, he_*).
function piper_voice(string $dir, string $lang): string {
    $g = glob($dir . '/' . preg_replace('/[^a-z]/', '', $lang) . '_*.onnx');
    return $g ? $g[0] : '';
}

$raw = file_get_contents('php://input');
$in  = json_decode($raw, true); if (!is_array($in)) $in = [];
$action = $_GET['action'] ?? ($in['action'] ?? '');

// ── file passthrough (serves the generated media; cockpit_data isn't web-served) ──
if ($action === 'file') {
    $id  = preg_replace('/[^a-f0-9]/', '', (string)($_GET['id'] ?? ''));
    foreach (['png'=>'image/png','gif'=>'image/gif','wav'=>'audio/wav','mp4'=>'video/mp4'] as $ext=>$mime) {
        $f = $GEN_DIR . '/' . $id . '.' . $ext;
        if ($id !== '' && is_file($f)) { header('Content-Type: '.$mime); header('Content-Length: '.filesize($f)); readfile($f); exit; }
    }
    http_response_code(404); echo 'not found'; exit;
}

header('Content-Type: application/json');

// ── presets ──
function _image_preset(string $p): array {  // [promptSuffix, W, H]
    switch ($p) {
        case 'logo':       return [', flat vector logo, centered, simple, solid dark background', 512, 512];
        case 'icon':       return [', app icon, flat, simple, centered, solid background', 512, 512];
        case 'favicon':    return [', tiny simple icon, flat, single subject, solid background', 512, 512];
        case 'background':  return [', wallpaper, scenic, detailed, wide', 768, 512];
        default:           return ['', 512, 512];   // 'image'
    }
}


// The GPU is shared with Ollama. A loaded chat model (3–8 GB) plus SD-1.5 on a 4 GB card
// ends in "vk::DeviceLostError" at the VAE decode (rig, 2026-09-21). Before an image or
// video job, ask Ollama to drop what it holds (keep_alive 0); it reloads on the next prompt.
function _gpu_release_ollama(): string {
    $base = 'http://127.0.0.1:11434';
    $ctx  = stream_context_create(['http' => ['timeout' => 2]]);
    $ps   = @file_get_contents($base . '/api/ps', false, $ctx);
    $j    = $ps ? json_decode($ps, true) : null;
    $freed = [];
    foreach ((array)($j['models'] ?? []) as $m) {
        $name = (string)($m['name'] ?? $m['model'] ?? ''); if ($name === '') continue;
        $opts = ['http' => ['method' => 'POST', 'timeout' => 5, 'header' => "Content-Type: application/json\r\n",
                 'content' => json_encode(['model' => $name, 'keep_alive' => 0])]];
        @file_get_contents($base . '/api/generate', false, stream_context_create($opts));
        $freed[] = $name;
    }
    if ($freed) usleep(1500000);   // give the driver a moment to hand the memory back
    return $freed ? ('released from Ollama: ' . implode(', ', $freed)) : 'ollama held no model';
}

if ($action === 'start') {
    $kind   = preg_replace('/[^a-z]/', '', (string)($in['kind'] ?? 'image'));
    $preset = preg_replace('/[^a-z0-9_]/', '', (string)($in['preset'] ?? ''));
    $prompt = trim((string)($in['prompt'] ?? ''));
    if ($prompt === '') { echo json_encode(['ok'=>false,'error'=>'Empty prompt'], JSON_UNESCAPED_UNICODE); exit; }
    $id  = bin2hex(random_bytes(8));
    $log = $GEN_DIR . '/' . $id . '.log';

    if ($kind === 'image') {
        if (!is_file($SD_BIN) || !is_executable($SD_BIN)) { echo json_encode(['ok'=>false,'error'=>'sd-cli not built','hint'=>'build stable-diffusion.cpp'], JSON_UNESCAPED_UNICODE); exit; }
        if (!is_file($SD_MODEL)) { echo json_encode(['ok'=>false,'error'=>'no SD model','hint'=>'download sd-v1-5.safetensors into sd.cpp/models'], JSON_UNESCAPED_UNICODE); exit; }
        [$suf, $w, $h] = _image_preset($preset);
        // Cap dimensions — SD-1.5 on a small (≤4GB) GPU OOMs above ~512²; keep it safe.
        $w = max(256, min(512, (int)$w));
        $h = max(256, min(512, (int)$h));
        $out = $GEN_DIR . '/' . $id . '.png';
        $gpuNote = _gpu_release_ollama();
        // --vae-tiling + --diffusion-fa keep VRAM/latency down so it fits a 4GB
        // GPU (VAE decode was the OOM point at full frame). Harmless on CPU too.
        $cmd = escapeshellarg($SD_BIN) . ' -M img_gen -m ' . escapeshellarg($SD_MODEL) .
               ' -p ' . escapeshellarg($prompt . $suf) . ' -o ' . escapeshellarg($out) .
               ' --steps 20 -W ' . $w . ' -H ' . $h . ' --seed -1 -t 8' .
               ' --diffusion-fa --vae-tiling';
    } elseif ($kind === 'sound') {
        $stype = preg_replace('/[^a-z]/', '', (string)($in['sound_type'] ?? 'speech')) ?: 'speech';
        $lang  = preg_replace('/[^a-z]/', '', (string)($in['language'] ?? 'auto')) ?: 'auto';
        $out   = $GEN_DIR . '/' . $id . '.wav';
        if ($stype === 'speech') {
            if (!is_file($PIPER_BIN) || !is_executable($PIPER_BIN)) { echo json_encode(['ok'=>false,'error'=>'piper not installed'], JSON_UNESCAPED_UNICODE); exit; }
            // Auto-detect language from the text when set to "auto".
            if ($lang === 'auto') {
                if (preg_match('/[\x{0590}-\x{05FF}]/u', $prompt))      $lang = 'he';
                elseif (preg_match('/[ñ¿¡áéíóúü]/iu', $prompt))         $lang = 'es';
                else                                                    $lang = 'en';
            }
            if ($lang === 'he') {
                // Hebrew: piper has no Hebrew voice, so a wrapper script handles it
                // (espeak-ng backend by default; swap in israwave later if desired).
                $HEB = $HOME . '/ai-tools/israwave/heb-tts.sh';
                if (!is_file($HEB) || !is_executable($HEB)) {
                    echo json_encode(['ok'=>false, 'error'=>'The voice for this language is not installed',
                        'hint'=>'Run Installs/install_piper.sh --voices he (needs: sudo apt install espeak-ng)'], JSON_UNESCAPED_UNICODE);
                    exit;
                }
                $cmd = escapeshellarg($HEB) . ' ' . escapeshellarg($prompt) . ' ' . escapeshellarg($out);
            } else {
                $voice = piper_voice($PIPER_DIR, $lang);
                if ($voice === '') {
                    // No voice for this language. Do NOT silently fall back to English —
                    // that just mangles non-Latin scripts into noise.
                    echo json_encode(['ok'=>false, 'error'=>'No "' . $lang . '" speech voice installed',
                        'hint'=>'No ' . $lang . ' voice — drop a ' . $lang . '_*.onnx voice into ~/ai-tools/piper.'], JSON_UNESCAPED_UNICODE);
                    exit;
                }
                $cmd = 'printf %s ' . escapeshellarg($prompt) . ' | ' . escapeshellarg($PIPER_BIN) .
                       ' -m ' . escapeshellarg($voice) . ' -f ' . escapeshellarg($out);
            }
        } else {
            // Procedural audio via ffmpeg synthesis (no model needed).
            $ff = _ffmpeg();
            if ($ff === '') { echo json_encode(['ok'=>false,'error'=>'ffmpeg missing'], JSON_UNESCAPED_UNICODE); exit; }
            if ($stype === 'effect') {                 // short descending "zap"
                $cmd = escapeshellarg($ff) . ' -y -f lavfi -i ' .
                       escapeshellarg("aevalsrc='0.4*sin(2*PI*t*(1500-1200*t/0.4))':d=0.4:s=44100") . ' ' . escapeshellarg($out);
            } elseif ($stype === 'melody') {           // C-E-G-C arpeggio
                $notes = [523, 659, 784, 1047]; $inputs = ''; $maps = '';
                foreach ($notes as $i => $f) { $inputs .= ' -f lavfi -i ' . escapeshellarg("sine=frequency=$f:duration=0.22:sample_rate=44100"); $maps .= "[$i]"; }
                $cmd = escapeshellarg($ff) . ' -y' . $inputs . ' -filter_complex ' .
                       escapeshellarg($maps . 'concat=n=' . count($notes) . ':v=0:a=1') . ' ' . escapeshellarg($out);
            } else {                                   // background: pink noise + low pad, 6s
                $cmd = escapeshellarg($ff) . ' -y -f lavfi -i ' . escapeshellarg('anoisesrc=d=6:c=pink:a=0.04') .
                       ' -f lavfi -i ' . escapeshellarg('sine=frequency=110:duration=6') .
                       ' -filter_complex ' . escapeshellarg('[0][1]amix=inputs=2:duration=longest') . ' ' . escapeshellarg($out);
            }
        }
    } elseif ($kind === 'video') {
        $ff = _ffmpeg();
        if (!is_file($SD_BIN) || !is_file($SD_MODEL)) { echo json_encode(['ok'=>false,'error'=>'sd-cli/model missing'], JSON_UNESCAPED_UNICODE); exit; }
        if ($ff === '') { echo json_encode(['ok'=>false,'error'=>'ffmpeg missing'], JSON_UNESCAPED_UNICODE); exit; }
        $gpuNote = _gpu_release_ollama();
        // Coherent animation without a video model: generate ONE anchor frame from
        // the text, then derive every later frame via img2img on the PREVIOUS frame
        // (fixed seed + low --strength). Each frame stays on-subject and only evolves
        // a little, so playing them back reads as a short clip — not 8 random pictures.
        // Frames (clip length) + Motion (img2img strength) are user-selectable.
        // NOTE: sd-cli reloads the model per frame, so time ≈ frames × ~20s on the
        // 4GB GPU. Default kept modest; steps trimmed below to cut per-frame cost.
        $frames   = (int)($in['frames'] ?? 6);
        if ($frames < 2)  $frames = 2;
        if ($frames > 24) $frames = 24;
        $seed     = 4242;     // fixed across all frames → consistent subject/composition
        $strength = (float)($in['strength'] ?? 0.32);
        if ($strength < 0.05) $strength = 0.05;
        if ($strength > 0.90) $strength = 0.90;
        $strength = number_format($strength, 2, '.', '');  // safe shell-arg form
        $framePat = $GEN_DIR . '/' . $id . '_%03d.png';
        $out = $GEN_DIR . '/' . $id . '.gif';
        $f0 = $GEN_DIR . '/' . $id . '_000.png';
        // Frame 0 — the anchor image (text → image).
        $loop = escapeshellarg($SD_BIN) . ' -M img_gen -m ' . escapeshellarg($SD_MODEL) .
                ' -p ' . escapeshellarg($prompt . ', cinematic, smooth motion') .
                ' -o ' . escapeshellarg($f0) .
                ' --steps 14 -W 512 -H 512 --seed ' . $seed . ' -t 8 --diffusion-fa --vae-tiling ; ';
        // Frames 1..N-1 — img2img chained off the previous frame for temporal coherence.
        for ($i = 1; $i < $frames; $i++) {
            $prev = $GEN_DIR . '/' . $id . '_' . sprintf('%03d', $i - 1) . '.png';
            $fp   = $GEN_DIR . '/' . $id . '_' . sprintf('%03d', $i) . '.png';
            $loop .= escapeshellarg($SD_BIN) . ' -M img_gen -m ' . escapeshellarg($SD_MODEL) .
                     ' -i ' . escapeshellarg($prev) . ' --strength ' . $strength .
                     ' -p ' . escapeshellarg($prompt . ', cinematic, smooth motion, next moment') .
                     ' -o ' . escapeshellarg($fp) .
                     ' --steps 9 -W 512 -H 512 --seed ' . $seed . ' -t 8 --diffusion-fa --vae-tiling ; ';
        }
        // Ping-pong (forward then reverse) so the loop plays back seamlessly.
        $cmd = $loop . escapeshellarg($ff) . ' -y -framerate 8 -i ' . escapeshellarg($framePat) .
               ' -vf ' . escapeshellarg('scale=320:-1,split[a][b];[b]reverse[r];[a][r]concat=n=2:v=1:a=0') .
               ' ' . escapeshellarg($out);
    } else {
        echo json_encode(['ok'=>false,'error'=>'Unknown kind'], JSON_UNESCAPED_UNICODE); exit;
    }

    // Spawn detached in its own session (setsid → new process group) so cancel can
    // kill the whole group. The runner records its PGID, then marks .done/.err.
    $pidf  = $GEN_DIR . '/' . $id . '.pid';
    $runner = 'echo $$ > ' . escapeshellarg($pidf) . '; ' .
              (isset($gpuNote) ? 'echo ' . escapeshellarg('[gpu] ' . $gpuNote) . '; ' : '') .
              '(' . $cmd . ') && touch ' . escapeshellarg($GEN_DIR . '/' . $id . '.done') .
              ' || touch ' . escapeshellarg($GEN_DIR . '/' . $id . '.err');
    exec('setsid bash -c ' . escapeshellarg($runner) . ' > ' . escapeshellarg($log) . ' 2>&1 &');
    echo json_encode(['ok'=>true, 'id'=>$id, 'kind'=>$kind], JSON_UNESCAPED_UNICODE);
    exit;
}

// Cancel a running job — kill its process group, mark cancelled.
if ($action === 'cancel') {
    $id = preg_replace('/[^a-f0-9]/', '', (string)($_GET['id'] ?? ($in['id'] ?? '')));
    if ($id === '') { echo json_encode(['ok'=>false,'error'=>'Missing id'], JSON_UNESCAPED_UNICODE); exit; }
    $pidf = $GEN_DIR . '/' . $id . '.pid';
    if (is_file($pidf)) {
        $pid = (int)trim((string)file_get_contents($pidf));
        if ($pid > 1) { exec('kill -TERM -' . $pid . ' 2>/dev/null'); usleep(200000); exec('kill -KILL -' . $pid . ' 2>/dev/null'); }
    }
    @touch($GEN_DIR . '/' . $id . '.cancelled');
    echo json_encode(['ok'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'delete') {
    $id = preg_replace('/[^a-f0-9]/', '', (string)($_GET['id'] ?? ($in['id'] ?? '')));
    if ($id === '') { echo json_encode(['ok'=>false,'error'=>'Missing id'], JSON_UNESCAPED_UNICODE); exit; }
    // Remove the output plus every job marker/frame for this id.
    $n = 0;
    foreach (glob($GEN_DIR . '/' . $id . '*') as $f) { if (is_file($f) && @unlink($f)) $n++; }
    echo json_encode(['ok'=>true, 'removed'=>$n], JSON_UNESCAPED_UNICODE);
    exit;
}

if ($action === 'status') {
    $id = preg_replace('/[^a-f0-9]/', '', (string)($_GET['id'] ?? ''));
    if ($id === '') { echo json_encode(['ok'=>false,'error'=>'Missing id'], JSON_UNESCAPED_UNICODE); exit; }
    if (is_file($GEN_DIR . '/' . $id . '.cancelled')) { echo json_encode(['ok'=>true, 'state'=>'cancelled'], JSON_UNESCAPED_UNICODE); exit; }
    if (is_file($GEN_DIR . '/' . $id . '.err')) {
        $log = @file_get_contents($GEN_DIR . '/' . $id . '.log');
        echo json_encode(['ok'=>true, 'state'=>'error', 'log'=>substr((string)$log, -600)], JSON_UNESCAPED_UNICODE); exit;
    }
    foreach (['png','gif','wav','mp4'] as $ext) {
        if (is_file($GEN_DIR . '/' . $id . '.' . $ext) && is_file($GEN_DIR . '/' . $id . '.done')) {
            echo json_encode(['ok'=>true, 'state'=>'done', 'ext'=>$ext, 'url'=>'generate.php?action=file&id='.$id], JSON_UNESCAPED_UNICODE); exit;
        }
    }
    echo json_encode(['ok'=>true, 'state'=>'running'], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: '.$action], JSON_UNESCAPED_UNICODE);
