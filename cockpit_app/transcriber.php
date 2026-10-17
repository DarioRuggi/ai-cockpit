<?php
// =============================================================================
// transcriber.php — Multimedia Transcriber & Asset Orchestrator
//
// Actions:
//   extract    — fetch YouTube transcript + metadata via yt-dlp
//   analyze    — section transcript into structural segments via LLM
//   compile    — build accessible SVG chart + HTML → PDF
//   download   — serve compiled PDF
//   status     — check job progress
//   list       — list past transcriptions
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

ed_gate_or_exit('transcribe');   // demo: described-modal; v1/v2: real

$action = $_GET['action'] ?? '';
$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];

$TRANS_DIR = $PATHS['cockpit_data'] . '/transcriptions';
if (!is_dir($TRANS_DIR)) mkdir($TRANS_DIR, 0755, true);

// ── Helpers ──────────────────────────────────────────────────────────────────

function trans_id(string $url): string {
    if (preg_match('/(?:v=|youtu\.be\/)([a-zA-Z0-9_-]{11})/', $url, $m)) return $m[1];
    return substr(md5($url), 0, 11);
}

function trans_path(string $id): string {
    global $TRANS_DIR;
    return $TRANS_DIR . '/' . preg_replace('/[^a-zA-Z0-9_-]/', '', $id);
}

function safe_exec(string $cmd, int $timeout = 60): array {
    $desc = [1 => ['pipe','w'], 2 => ['pipe','w']];
    $proc = proc_open("timeout {$timeout} " . $cmd, $desc, $pipes);
    if (!is_resource($proc)) return ['ok' => false, 'error' => 'proc_open failed'];
    $stdout = stream_get_contents($pipes[1]); fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]); fclose($pipes[2]);
    $rc = proc_close($proc);
    return ['ok' => $rc === 0, 'stdout' => $stdout, 'stderr' => $stderr, 'rc' => $rc];
}

// ── SRT / VTT helpers (for local-file transcription + SRT export) ─────────────
function _ts_to_ms(string $t): int {
    // accepts HH:MM:SS,mmm or HH:MM:SS.mmm
    if (!preg_match('/(\d{1,2}):(\d{2}):(\d{2})[.,](\d{1,3})/', $t, $m)) return 0;
    return ((int)$m[1]*3600 + (int)$m[2]*60 + (int)$m[3])*1000 + (int)str_pad($m[4], 3, '0');
}
function _ms_to_srt(int $ms): string {
    $h = intdiv($ms, 3600000); $ms %= 3600000;
    $mm = intdiv($ms, 60000);  $ms %= 60000;
    $s = intdiv($ms, 1000);    $ms %= 1000;
    return sprintf('%02d:%02d:%02d,%03d', $h, $mm, $s, $ms);
}
// Parse an .srt into [{start_ms,end_ms,text}]
function parse_srt(string $raw): array {
    $raw = str_replace("\r", '', $raw);
    $cues = [];
    foreach (preg_split('/\n\s*\n/', trim($raw)) as $block) {
        $lines = explode("\n", trim($block));
        if (count($lines) < 2) continue;
        $i = 0; if (preg_match('/^\d+$/', trim($lines[0]))) $i = 1;   // optional index line
        if (!isset($lines[$i]) || !preg_match('/(\S+)\s*-->\s*(\S+)/', $lines[$i], $m)) continue;
        $text = trim(implode("\n", array_slice($lines, $i + 1)));
        if ($text === '') continue;
        $cues[] = ['start_ms' => _ts_to_ms($m[1]), 'end_ms' => _ts_to_ms($m[2]), 'text' => $text];
    }
    return $cues;
}
function build_srt(array $cues): string {
    $out = ''; $n = 1;
    foreach ($cues as $c) {
        $out .= $n++ . "\n" . _ms_to_srt((int)$c['start_ms']) . ' --> ' . _ms_to_srt((int)$c['end_ms']) . "\n" . $c['text'] . "\n\n";
    }
    return $out;
}
function srt_to_text(string $srtFile): string {
    $t = [];
    foreach (parse_srt((string)@file_get_contents($srtFile)) as $c) $t[] = preg_replace('/\s+/', ' ', $c['text']);
    return implode(' ', $t);
}
// Convert a WebVTT file into an .srt file (keeps timestamps, dedups YT rollups).
function vtt_to_srt(string $vttFile, string $srtOut): bool {
    $raw = str_replace("\r", '', (string)@file_get_contents($vttFile));
    $cues = []; $prevText = '';
    foreach (preg_split('/\n\s*\n/', $raw) as $block) {
        if (!preg_match('/(\d{1,2}:\d{2}:\d{2}[.,]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[.,]\d{1,3})/', $block, $m)) continue;
        $lines = explode("\n", trim($block)); $txt = [];
        foreach ($lines as $ln) { if (strpos($ln, '-->') !== false || preg_match('/^\d+$/', trim($ln)) || trim($ln) === 'WEBVTT') continue; $txt[] = $ln; }
        $text = trim(preg_replace('/<[^>]+>/', '', implode(' ', $txt)));
        if ($text === '' || $text === $prevText) continue;
        $cues[] = ['start_ms' => _ts_to_ms($m[1]), 'end_ms' => _ts_to_ms($m[2]), 'text' => $text];
        $prevText = $text;
    }
    if (!$cues) return false;
    return @file_put_contents($srtOut, build_srt($cues)) !== false;
}
// LibreTranslate base URL (same resolution as translate.php).
function lt_base(): string {
    $u = 'http://localhost:5000';
    $pf = __DIR__ . '/paths.json';
    if (is_file($pf)) { $j = json_decode((string)@file_get_contents($pf), true); if (!empty($j['libretranslate'])) $u = rtrim($j['libretranslate'], '/'); }
    $e = getenv('LIBRETRANSLATE_URL'); if ($e) $u = rtrim($e, '/');
    return $u;
}
function lt_translate(string $base, string $text, string $target): string {
    if ($text === '' || $target === '') return $text;
    $ch = curl_init($base . '/translate');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>30, CURLOPT_CONNECTTIMEOUT=>5,
        CURLOPT_POST=>true, CURLOPT_HTTPHEADER=>['Content-Type: application/json'],
        CURLOPT_POSTFIELDS=>json_encode(['q'=>$text,'source'=>'auto','target'=>$target,'format'=>'text'], JSON_UNESCAPED_UNICODE)]);
    $body = curl_exec($ch); $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); curl_close($ch);
    if ($code !== 200 || !$body) return $text;
    $d = json_decode($body, true);
    return $d['translatedText'] ?? $text;
}

// ── ACTION: extract ──────────────────────────────────────────────────────────

if ($action === 'extract') {
    $url = trim($in['url'] ?? '');
    if (!$url || !preg_match('/youtu\.?be/', $url)) {
        echo json_encode(['ok' => false, 'error' => 'Valid YouTube URL required'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $vid  = trans_id($url);
    $dir  = trans_path($vid);
    if (!is_dir($dir)) mkdir($dir, 0755, true);

    // Save job state
    $state = ['id' => $vid, 'url' => $url, 'status' => 'extracting', 'created' => date('c')];
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

    // Fetch metadata
    $metaCmd = escapeshellarg($PATHS['yt_dlp'] ?? '/usr/local/bin/yt-dlp')
             . ' --dump-json --no-download ' . escapeshellarg($url);
    $metaRes = safe_exec($metaCmd, 30);

    $meta = [];
    if ($metaRes['ok'] && $metaRes['stdout']) {
        $meta = json_decode($metaRes['stdout'], true) ?: [];
    }

    $title    = $meta['title'] ?? 'Unknown';
    $channel  = $meta['channel'] ?? $meta['uploader'] ?? 'Unknown';
    $duration = (int)($meta['duration'] ?? 0);
    $date     = $meta['upload_date'] ?? '';

    // Extract subtitles — try manual subs first, then auto
    $subFile = $dir . '/subs';
    $subCmd  = escapeshellarg($PATHS['yt_dlp'] ?? '/usr/local/bin/yt-dlp')
             . ' --write-sub --write-auto-sub --sub-lang en --sub-format vtt'
             . ' --skip-download -o ' . escapeshellarg($subFile)
             . ' ' . escapeshellarg($url);
    $subRes = safe_exec($subCmd, 60);

    // Find the subtitle file (yt-dlp adds .en.vtt)
    $vttFile = null;
    foreach (glob($dir . '/subs*.vtt') as $f) { $vttFile = $f; break; }
    if (!$vttFile) {
        foreach (glob($dir . '/*.vtt') as $f) { $vttFile = $f; break; }
    }

    $transcript = '';
    if ($vttFile && file_exists($vttFile)) {
        $transcript = parse_vtt($vttFile);
    }

    if (!$transcript) {
        // Fallback: try JSON subtitles from metadata
        $subs = $meta['subtitles']['en'][0]['url'] ?? $meta['automatic_captions']['en'][0]['url'] ?? null;
        if (!$subs && isset($meta['subtitles'])) {
            foreach ($meta['subtitles'] as $lang => $tracks) {
                if (!empty($tracks[0]['url'])) { $subs = $tracks[0]['url']; break; }
            }
        }
        if ($subs) {
            $vttData = @file_get_contents($subs);
            if ($vttData) {
                file_put_contents($dir . '/fallback.vtt', $vttData);
                $transcript = parse_vtt($dir . '/fallback.vtt');
            }
        }
    }

    if (!$transcript) {
        $state['status'] = 'error';
        $state['error']  = 'No transcript available for this video';
        file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
        echo json_encode(['ok' => false, 'error' => 'No transcript available'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Save results
    $state['status']     = 'extracted';
    $state['title']      = $title;
    $state['channel']    = $channel;
    $state['duration']   = $duration;
    $state['upload_date'] = $date;
    $state['word_count'] = str_word_count($transcript);
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    file_put_contents($dir . '/transcript.txt', $transcript);

    echo json_encode([
        'ok'         => true,
        'id'         => $vid,
        'title'      => $title,
        'channel'    => $channel,
        'duration'   => $duration,
        'word_count' => str_word_count($transcript),
        'transcript' => mb_substr($transcript, 0, 2000),
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ACTION: extract_file ─────────────────────────────────────────────────────
// Transcribe a LOCAL video/audio: an uploaded file ($_FILES['video']) or a
// server-side path ($in['path']/$_POST['path']). ffmpeg → 16k mono wav →
// whisper.cpp → .srt (+ flat transcript). Optional source language hint.
if ($action === 'extract_file') {
    $lang = preg_replace('/[^a-z]/', '', (string)($in['lang'] ?? $_POST['lang'] ?? 'auto')) ?: 'auto';
    $src = ''; $vid = ''; $title = '';
    if (!empty($_FILES['video']['tmp_name']) && is_uploaded_file($_FILES['video']['tmp_name'])) {
        $title = (string)$_FILES['video']['name'];
        $vid   = substr(md5($title . microtime()), 0, 11);
        $dir   = trans_path($vid); if (!is_dir($dir)) mkdir($dir, 0755, true);
        $ext   = preg_replace('/[^a-z0-9]/', '', strtolower(pathinfo($title, PATHINFO_EXTENSION))) ?: 'mp4';
        $src   = $dir . '/source.' . $ext;
        if (!move_uploaded_file($_FILES['video']['tmp_name'], $src)) { echo json_encode(['ok'=>false,'error'=>'upload failed'], JSON_UNESCAPED_UNICODE); exit; }
    } else {
        $path = (string)($in['path'] ?? $_POST['path'] ?? '');
        $real = $path !== '' ? realpath($path) : false;
        if ($path === '' && ($lm = cockpit_upload_limit_message()) !== '') { echo json_encode(['ok'=>false,'error'=>$lm], JSON_UNESCAPED_UNICODE); exit; }
        if (!$real || !is_file($real)) { echo json_encode(['ok'=>false,'error'=>'File not found: ' . $path], JSON_UNESCAPED_UNICODE); exit; }
        $title = basename($real);
        $vid   = substr(md5($real), 0, 11);
        $dir   = trans_path($vid); if (!is_dir($dir)) mkdir($dir, 0755, true);
        $src   = $real;   // transcribe in place
    }
    $HOME = $PATHS['home'];   // was undefined here: every path became /ai-tools/… and whisper read as 'not installed' with a full build present (rig, b86)
    $WBIN = $HOME . '/ai-tools/whisper.cpp/build/bin/whisper-cli';
    $WMODEL = ''; foreach (glob($HOME . '/ai-tools/whisper.cpp/models/ggml-*.bin') ?: [] as $m) { $WMODEL = $m; break; }
    if (!is_file($WBIN) || !is_executable($WBIN) || !$WMODEL) {
        echo json_encode(['ok'=>false,'error'=>'whisper not installed','hint'=>'Run Installs/install_whisper.sh'], JSON_UNESCAPED_UNICODE); exit;
    }
    $ff = trim((string)shell_exec('command -v ffmpeg'));
    if ($ff === '') { echo json_encode(['ok'=>false,'error'=>'ffmpeg missing'], JSON_UNESCAPED_UNICODE); exit; }

    $wav = $dir . '/audio.wav';
    safe_exec(escapeshellarg($ff) . ' -y -i ' . escapeshellarg($src) . ' -ar 16000 -ac 1 -vn ' . escapeshellarg($wav), 900);
    if (!is_file($wav)) { echo json_encode(['ok'=>false,'error'=>'audio extraction failed'], JSON_UNESCAPED_UNICODE); exit; }

    $langArg = ($lang !== '' && $lang !== 'auto') ? (' -l ' . escapeshellarg($lang)) : ' -l auto';
    $base = $dir . '/subs';
    $wr = safe_exec(escapeshellarg($WBIN) . ' -m ' . escapeshellarg($WMODEL) . ' -f ' . escapeshellarg($wav) .
                    $langArg . ' -osrt -of ' . escapeshellarg($base), 7200);
    @unlink($wav);
    $srtFile = $base . '.srt';
    if (!is_file($srtFile)) { echo json_encode(['ok'=>false,'error'=>'transcription failed','detail'=>substr((string)($wr['stderr'] ?? ''), -300)], JSON_UNESCAPED_UNICODE); exit; }

    $transcript = srt_to_text($srtFile);
    $state = ['id'=>$vid, 'source'=>'file', 'title'=>$title, 'status'=>'extracted',
              'duration'=>0, 'channel'=>'local file', 'word_count'=>str_word_count($transcript), 'created'=>date('c')];
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    file_put_contents($dir . '/transcript.txt', $transcript);
    echo json_encode(['ok'=>true, 'id'=>$vid, 'title'=>$title, 'channel'=>'local file',
                      'transcript'=>$transcript, 'word_count'=>str_word_count($transcript), 'has_srt'=>true], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ACTION: srt ──────────────────────────────────────────────────────────────
// Download subtitles as .srt for a transcription. ?id=X [&lang=YY to translate
// each cue via LibreTranslate, keeping timestamps]. Builds from whisper's .srt or
// converts the YouTube .vtt.
if ($action === 'srt') {
    $id     = preg_replace('/[^a-zA-Z0-9_-]/', '', (string)($_GET['id'] ?? $in['id'] ?? ''));
    $target = preg_replace('/[^a-z]/', '', (string)($_GET['lang'] ?? $in['lang'] ?? ''));
    $dir    = trans_path($id);
    $srtFile = $dir . '/subs.srt';
    if (!is_file($srtFile)) {
        $vtt = null;
        foreach (glob($dir . '/subs*.vtt') ?: [] as $f) { $vtt = $f; break; }
        if (!$vtt) foreach (glob($dir . '/*.vtt') ?: [] as $f) { $vtt = $f; break; }
        if ($vtt) vtt_to_srt($vtt, $srtFile);
    }
    if (!is_file($srtFile)) { echo json_encode(['ok'=>false,'error'=>'No timestamped subtitles for this item'], JSON_UNESCAPED_UNICODE); exit; }
    $cues = parse_srt((string)file_get_contents($srtFile));
    $fnameLang = '';
    if ($target !== '') {
        $base = lt_base();
        foreach ($cues as &$c) { $c['text'] = lt_translate($base, $c['text'], $target); } unset($c);
        $fnameLang = '.' . $target;
    }
    header('Content-Type: application/x-subrip; charset=utf-8');
    header('Content-Disposition: attachment; filename="' . $id . $fnameLang . '.srt"');
    header('Cache-Control: no-store');
    echo build_srt($cues);
    exit;
}

// ── ACTION: analyze ──────────────────────────────────────────────────────────

if ($action === 'analyze') {
    $id    = preg_replace('/[^a-zA-Z0-9_-]/', '', $in['id'] ?? '');
    $model = trim($in['model'] ?? '');
    $dir   = trans_path($id);

    if (!$id || !is_file($dir . '/transcript.txt')) {
        echo json_encode(['ok' => false, 'error' => 'Extract transcript first'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $transcript = file_get_contents($dir . '/transcript.txt');
    $state = json_decode(file_get_contents($dir . '/state.json'), true) ?: [];
    $state['status'] = 'analyzing';
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

    $prompt = "Analyze this video transcript and create a structured breakdown.\n\n"
            . "Video: " . ($state['title'] ?? 'Unknown') . "\n"
            . "Channel: " . ($state['channel'] ?? 'Unknown') . "\n\n"
            . "TRANSCRIPT:\n" . mb_substr($transcript, 0, 12000) . "\n\n"
            . "Return a JSON object with this exact structure:\n"
            . "{\n"
            . "  \"summary\": \"2-3 sentence overview\",\n"
            . "  \"sections\": [\n"
            . "    {\n"
            . "      \"title\": \"Section name\",\n"
            . "      \"how_it_works\": \"Explanation of mechanics/process\",\n"
            . "      \"best_for\": \"Use cases and applications\",\n"
            . "      \"key_points\": [\"point1\", \"point2\"]\n"
            . "    }\n"
            . "  ],\n"
            . "  \"takeaways\": [\"key insight 1\", \"key insight 2\"]\n"
            . "}\n\n"
            . "Return ONLY valid JSON, no markdown fences.";

    // Use bridge.php to run the analysis
    $bridgePayload = [
        'mode'   => 'submit',
        'agent'  => 'ollama',
        'model'  => $model ?: 'qwen2.5-coder:1.5b',
        'prompt' => $prompt,
    ];

    $ch = curl_init('http://localhost/cockpit/bridge.php');
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode($bridgePayload, JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 10,
    ]);
    $resp = curl_exec($ch);
    curl_close($ch);

    $rd = json_decode($resp, true);
    if (!$rd || !($rd['ok'] ?? false) || empty($rd['token'])) {
        $state['status'] = 'error';
        $state['error']  = 'LLM submission failed: ' . ($rd['message'] ?? 'unknown');
        file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
        echo json_encode(['ok' => false, 'error' => $state['error']], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $state['analyze_token'] = $rd['token'];
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

    echo json_encode(['ok' => true, 'token' => $rd['token'], 'id' => $id], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ACTION: analyze_finalize ─────────────────────────────────────────────────

if ($action === 'analyze_finalize') {
    $id     = preg_replace('/[^a-zA-Z0-9_-]/', '', $in['id'] ?? '');
    $output = trim($in['output'] ?? '');
    $dir    = trans_path($id);

    if (!$id || !is_dir($dir)) {
        echo json_encode(['ok' => false, 'error' => 'Invalid transcription ID'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    // Parse LLM output as JSON
    $clean = $output;
    if (preg_match('/```(?:json)?\s*([\s\S]*?)```/', $clean, $m)) $clean = $m[1];
    $clean = trim($clean);
    $analysis = json_decode($clean, true);

    if (!$analysis) {
        // Try to extract JSON object from mixed output
        if (preg_match('/\{[\s\S]*\}/', $clean, $m2)) {
            $analysis = json_decode($m2[0], true);
        }
    }

    $state = json_decode(file_get_contents($dir . '/state.json'), true) ?: [];

    if (!$analysis) {
        $state['status'] = 'analyzed';
        $analysis = [
            'summary'   => 'Analysis could not be parsed. Raw transcript available.',
            'sections'  => [['title' => 'Full Transcript', 'how_it_works' => $output, 'best_for' => 'Reference', 'key_points' => []]],
            'takeaways' => [],
        ];
    }

    $state['status'] = 'analyzed';
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
    file_put_contents($dir . '/analysis.json', json_encode($analysis, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

    echo json_encode(['ok' => true, 'id' => $id, 'analysis' => $analysis], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ACTION: compile ──────────────────────────────────────────────────────────

if ($action === 'compile') {
    $id  = preg_replace('/[^a-zA-Z0-9_-]/', '', $in['id'] ?? '');
    $dir = trans_path($id);

    if (!$id || !is_file($dir . '/transcript.txt')) {
        echo json_encode(['ok' => false, 'error' => 'No transcript found'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $state      = json_decode(file_get_contents($dir . '/state.json'), true) ?: [];
    $transcript = file_get_contents($dir . '/transcript.txt');
    $analysis   = [];
    if (is_file($dir . '/analysis.json')) {
        $analysis = json_decode(file_get_contents($dir . '/analysis.json'), true) ?: [];
    }

    $title   = htmlspecialchars($state['title'] ?? 'Video Transcript', ENT_QUOTES);
    $channel = htmlspecialchars($state['channel'] ?? '', ENT_QUOTES);
    $date    = $state['upload_date'] ?? '';
    $dur     = $state['duration'] ?? 0;
    $durStr  = $dur ? sprintf('%d:%02d', intdiv($dur, 60), $dur % 60) : '';

    // Build SVG chart of sections
    $svg = build_section_chart($analysis['sections'] ?? []);

    // Build HTML
    $sectionsHtml = '';
    foreach (($analysis['sections'] ?? []) as $i => $sec) {
        $sTitle = htmlspecialchars($sec['title'] ?? 'Section ' . ($i+1), ENT_QUOTES);
        $howIt  = htmlspecialchars($sec['how_it_works'] ?? '', ENT_QUOTES);
        $bestF  = htmlspecialchars($sec['best_for'] ?? '', ENT_QUOTES);
        $points = '';
        foreach (($sec['key_points'] ?? []) as $p) {
            $points .= '<li>' . htmlspecialchars($p, ENT_QUOTES) . '</li>';
        }
        $sectionsHtml .= <<<SECT
        <div class="section-card">
            <h3>{$sTitle}</h3>
            <div class="field"><span class="label">How it Works:</span> {$howIt}</div>
            <div class="field"><span class="label">Best For:</span> {$bestF}</div>
            {($points ? "<ul>{$points}</ul>" : '')}
        </div>
SECT;
    }

    $takeawaysHtml = '';
    foreach (($analysis['takeaways'] ?? []) as $t) {
        $takeawaysHtml .= '<li>' . htmlspecialchars($t, ENT_QUOTES) . '</li>';
    }

    $summaryHtml = htmlspecialchars($analysis['summary'] ?? '', ENT_QUOTES);
    $transcriptHtml = nl2br(htmlspecialchars($transcript, ENT_QUOTES));

    $html = <<<HTML
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>{$title}</title>
<style>
@page { size: A4; margin: 15mm; }
body {
    background: #0f141c; color: #cbd5e0; font-family: 'Segoe UI', Arial, sans-serif;
    margin: 0; padding: 20px; line-height: 1.5;
}
h1 { color: #ffa500; font-size: 22px; border-bottom: 2px solid #2b6cb0; padding-bottom: 8px; }
h2 { color: #00e5ff; font-size: 16px; margin-top: 24px; }
h3 { color: #ffa500; font-size: 14px; margin: 0 0 8px 0; }
.meta { color: #718096; font-size: 12px; margin-bottom: 16px; }
.summary { background: #1a202c; border-left: 3px solid #2b6cb0; padding: 12px 16px; margin: 16px 0; border-radius: 4px; }
.section-card {
    background: #1a202c; border: 1px solid #2b6cb0; border-radius: 6px;
    padding: 14px 16px; margin: 10px 0; page-break-inside: avoid;
}
.field { margin: 6px 0; font-size: 13px; }
.label { color: #00e5ff; font-weight: bold; }
ul { margin: 8px 0; padding-left: 20px; }
li { margin: 4px 0; font-size: 13px; }
.chart-wrap { margin: 20px 0; text-align: center; }
.transcript-block {
    background: #121824; border: 1px solid #2d3748; border-radius: 4px;
    padding: 16px; font-size: 12px; line-height: 1.6; margin-top: 12px;
    max-height: none;
}
.takeaways { background: #1a202c; border: 1px dashed #ffa500; border-radius: 6px; padding: 12px 16px; margin: 16px 0; }
.footer { text-align: center; color: #4a5568; font-size: 10px; margin-top: 30px; border-top: 1px solid #2d3748; padding-top: 8px; }
</style>
</head>
<body>
<h1>{$title}</h1>
<div class="meta">{$channel} | {$date} | {$durStr}</div>

<div class="summary"><strong>Summary:</strong> {$summaryHtml}</div>

<h2>Structural Breakdown</h2>
<div class="chart-wrap">{$svg}</div>
{$sectionsHtml}

{($takeawaysHtml ? "<div class=\"takeaways\"><h2>Key Takeaways</h2><ul>{$takeawaysHtml}</ul></div>" : '')}

<h2>Full Transcript</h2>
<div class="transcript-block">{$transcriptHtml}</div>

<div class="footer">Generated by AI Cockpit Multimedia Transcriber | {$date}</div>
</body>
</html>
HTML;

    file_put_contents($dir . '/document.html', $html);

    // Try PDF compilation via brave headless
    $pdfPath = $dir . '/document.pdf';
    $htmlPath = $dir . '/document.html';
    $pdfOk = false;

    // Method 1: brave --headless
    $braveCmd = '/usr/bin/brave-browser --headless --disable-gpu --no-sandbox'
              . ' --print-to-pdf=' . escapeshellarg($pdfPath)
              . ' ' . escapeshellarg('file://' . realpath($htmlPath));
    $pdfRes = safe_exec($braveCmd, 30);
    if ($pdfRes['ok'] && file_exists($pdfPath) && filesize($pdfPath) > 100) {
        $pdfOk = true;
    }

    // Method 2: pandoc fallback
    if (!$pdfOk) {
        $pandocCmd = 'pandoc ' . escapeshellarg($htmlPath) . ' -o ' . escapeshellarg($pdfPath)
                   . ' --pdf-engine=pdflatex 2>&1';
        $pdfRes = safe_exec($pandocCmd, 30);
        if (file_exists($pdfPath) && filesize($pdfPath) > 100) $pdfOk = true;
    }

    $state['status'] = 'compiled';
    $state['has_pdf'] = $pdfOk;
    file_put_contents($dir . '/state.json', json_encode($state, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));

    echo json_encode([
        'ok'       => true,
        'id'       => $id,
        'has_pdf'  => $pdfOk,
        'has_html' => true,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ACTION: download ─────────────────────────────────────────────────────────

if ($action === 'download') {
    $id   = preg_replace('/[^a-zA-Z0-9_-]/', '', $_GET['id'] ?? '');
    $fmt  = ($_GET['format'] ?? 'pdf') === 'html' ? 'html' : 'pdf';
    $dir  = trans_path($id);

    $file = $dir . '/document.' . $fmt;
    if (!$id || !file_exists($file)) {
        header('Content-Type: application/json');
        echo json_encode(['ok' => false, 'error' => 'File not found'], JSON_UNESCAPED_UNICODE);
        exit;
    }

    $state = json_decode(file_get_contents($dir . '/state.json'), true) ?: [];
    $name  = preg_replace('/[^a-zA-Z0-9_ -]/', '', $state['title'] ?? 'transcript');
    $name  = trim($name) ?: 'transcript';

    if ($fmt === 'pdf') {
        header('Content-Type: application/pdf');
    } else {
        header('Content-Type: text/html; charset=utf-8');
    }
    header('Content-Disposition: attachment; filename="' . $name . '.' . $fmt . '"');
    header('Content-Length: ' . filesize($file));
    readfile($file);
    exit;
}

// ── ACTION: status ───────────────────────────────────────────────────────────

if ($action === 'status') {
    $id  = preg_replace('/[^a-zA-Z0-9_-]/', '', $_GET['id'] ?? $in['id'] ?? '');
    $dir = trans_path($id);
    if (!$id || !is_file($dir . '/state.json')) {
        echo json_encode(['ok' => false, 'error' => 'Not found'], JSON_UNESCAPED_UNICODE);
        exit;
    }
    $state = json_decode(file_get_contents($dir . '/state.json'), true) ?: [];
    echo json_encode(['ok' => true] + $state, JSON_UNESCAPED_UNICODE);
    exit;
}

// ── ACTION: list ─────────────────────────────────────────────────────────────

if ($action === 'list') {
    $items = [];
    foreach (glob($TRANS_DIR . '/*/state.json') as $sf) {
        $s = json_decode(file_get_contents($sf), true) ?: [];
        $items[] = [
            'id'      => $s['id'] ?? basename(dirname($sf)),
            'title'   => $s['title'] ?? '?',
            'channel' => $s['channel'] ?? '',
            'status'  => $s['status'] ?? 'unknown',
            'created' => $s['created'] ?? '',
            'has_pdf' => $s['has_pdf'] ?? false,
        ];
    }
    usort($items, fn($a,$b) => strcmp($b['created'], $a['created']));
    echo json_encode(['ok' => true, 'items' => $items], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok' => false, 'error' => 'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);

// =============================================================================
// VTT subtitle parser — extracts plain text from WebVTT
// =============================================================================

function parse_vtt(string $file): string {
    $lines = file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    if (!$lines) return '';

    $text = [];
    $prev = '';
    foreach ($lines as $line) {
        $line = trim($line);
        if ($line === 'WEBVTT' || $line === '') continue;
        if (preg_match('/^\d{2}:\d{2}/', $line)) continue;  // timestamp line
        if (preg_match('/^NOTE\b/', $line)) continue;
        if (preg_match('/^STYLE\b/', $line)) continue;
        if (preg_match('/^\d+$/', $line)) continue;  // cue number
        // Strip VTT tags
        $clean = preg_replace('/<[^>]+>/', '', $line);
        $clean = trim($clean);
        if ($clean && $clean !== $prev) {
            $text[] = $clean;
            $prev = $clean;
        }
    }
    return implode(' ', $text);
}

// =============================================================================
// SVG chart builder — protanopia-safe section overview
// =============================================================================

function build_section_chart(array $sections): string {
    $count = count($sections);
    if ($count === 0) return '';

    $boxW   = 160;
    $boxH   = 50;
    $gapX   = 30;
    $cols   = min($count, 3);
    $rows   = (int)ceil($count / $cols);
    $padX   = 20;
    $padY   = 20;
    $w      = $padX * 2 + $cols * $boxW + ($cols - 1) * $gapX;
    $h      = $padY * 2 + $rows * ($boxH + 20);

    $svg = '<svg viewBox="0 0 ' . $w . ' ' . $h . '" xmlns="http://www.w3.org/2000/svg" '
         . 'style="max-width:100%;height:auto;">';
    $svg .= '<rect width="100%" height="100%" fill="#121824" rx="6"/>';

    foreach ($sections as $i => $sec) {
        $col = $i % $cols;
        $row = intdiv($i, $cols);
        $x   = $padX + $col * ($boxW + $gapX);
        $y   = $padY + $row * ($boxH + 20);
        $label = htmlspecialchars(mb_substr($sec['title'] ?? 'Section ' . ($i+1), 0, 22), ENT_XML1);

        $svg .= '<rect x="' . $x . '" y="' . $y . '" width="' . $boxW . '" height="' . $boxH . '" '
              . 'rx="4" fill="#1a202c" stroke="#2b6cb0" stroke-width="1.5"/>';
        $svg .= '<text x="' . ($x + $boxW/2) . '" y="' . ($y + 20) . '" '
              . 'text-anchor="middle" fill="#ffa500" font-size="11" font-weight="bold">'
              . ($i+1) . '. ' . $label . '</text>';

        $bestFor = htmlspecialchars(mb_substr($sec['best_for'] ?? '', 0, 28), ENT_XML1);
        $svg .= '<text x="' . ($x + $boxW/2) . '" y="' . ($y + 36) . '" '
              . 'text-anchor="middle" fill="#00e5ff" font-size="9">' . $bestFor . '</text>';

        // Arrow to next
        if ($i < $count - 1 && $col < $cols - 1) {
            $ax = $x + $boxW + 2;
            $ay = $y + $boxH / 2;
            $svg .= '<line x1="' . $ax . '" y1="' . $ay . '" x2="' . ($ax + $gapX - 4) . '" y2="' . $ay . '" '
                  . 'stroke="#ffa500" stroke-width="1.5" marker-end="url(#arrow)"/>';
        }
    }

    $svg .= '<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" '
          . 'markerWidth="6" markerHeight="6" orient="auto-start-reverse">'
          . '<path d="M 0 0 L 10 5 L 0 10 z" fill="#ffa500"/></marker></defs>';
    $svg .= '</svg>';

    return $svg;
}
