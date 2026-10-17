<?php
require_once __DIR__ . "/auth.php";

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();
// =============================================================================
// caveman.php — token-compression ("caveman speak") for outgoing prompts.
// Dario Ruggi / AI Cockpit.
//
// Two chained passes, both local/free:
//   1. Deterministic strip — drop articles/filler/politeness + collapse
//      whitespace. Fenced and inline code are protected (never touched).
//   2. Optional Ollama rewrite — a LOCAL model (never a paid one) rewrites the
//      text in ultra-terse telegraphic style. Costs zero paid tokens.
//
// POST JSON: { text, llm:0|1, model:"<ollama model>" }
// Returns:   { ok, text, tokens_before, tokens_after, saved, pct, llm, llm_error }
// =============================================================================
header('Content-Type: application/json');
require_once __DIR__ . '/ollama_guard.php';

if (!function_exists('mb_strlen')) { function mb_strlen($s,$e=null){ return strlen($s); } }

$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
$text   = (string)($in['text'] ?? '');
$useLlm = !empty($in['llm']);
$model  = preg_replace('/[^A-Za-z0-9_.:\/\-]/', '', (string)($in['model'] ?? ''));

if (trim($text) === '') { echo json_encode(['ok'=>false, 'error'=>'empty text'], JSON_UNESCAPED_UNICODE); exit; }

// Rough token estimate (~4 chars/token) — good enough for a savings readout.
function tok_est(string $s): int { return (int)ceil(mb_strlen($s) / 4); }
$before = tok_est($text);

// --- Pass 1: deterministic local strip --------------------------------------
function caveman_strip(string $t): string {
    // Protect code so compression never corrupts it.
    $blocks = [];
    $stash = function ($m) use (&$blocks) { $blocks[] = $m[0]; return "\x00" . (count($blocks) - 1) . "\x00"; };
    $t = preg_replace_callback('/```.*?```/s', $stash, $t);   // fenced code
    $t = preg_replace_callback('/`[^`]+`/',   $stash, $t);    // inline code

    // Multi-word politeness/filler first.
    $multi = ['could you','can you','would you','i want you to','i would like to',
              'i would like','i need you to','make sure to','make sure that',
              'in order to','as well','if you could','please can you'];
    foreach ($multi as $w) $t = preg_replace('/\b' . preg_quote($w, '/') . '\b/i', '', $t);

    // Single-word fillers — articles, politeness, intensifiers ONLY.
    // Deliberately NOT touching be-verbs / "not" / "no" (meaning-bearing).
    $single = ['the','a','an','please','kindly','just','really','very','actually',
               'basically','simply','quite','rather','somewhat','that','this'];
    $t = preg_replace('/\b(' . implode('|', array_map(fn($w) => preg_quote($w, '/'), $single)) . ')\b/i', '', $t);

    // Tidy whitespace + punctuation spacing.
    $t = preg_replace('/[ \t]+/', ' ', $t);
    $t = preg_replace('/\s+([,.;:!?])/', '$1', $t);
    $t = preg_replace('/ *\n */', "\n", $t);
    $t = preg_replace('/\n{3,}/', "\n\n", $t);
    $t = trim($t);

    // Restore protected code.
    $t = preg_replace_callback('/\x00(\d+)\x00/', fn($m) => $blocks[(int)$m[1]] ?? '', $t);
    return $t;
}
$out = caveman_strip($text);

// --- Pass 2: optional LOCAL Ollama rewrite ----------------------------------
// Caveman is an automatic task → never auto-load a >4B model. Clamp to a safe
// small model if the requested one is too big (or unknown size).
$modelClamped = false;
if ($useLlm) {
    $safe = ollama_auto_model($model, null, 'qwen2.5:3b');   // '' if nothing ≤4B is available
    if ($safe !== $model) { $modelClamped = ($model !== ''); $model = $safe; }
}
$llmUsed = false; $llmErr = '';
if ($useLlm && $model !== '') {
    $sys = "Rewrite the user's text in ultra-terse 'caveman' telegraphic style to minimize token count. "
         . "Drop articles, filler and politeness. KEEP every fact, name, number, path, URL and code block EXACTLY. "
         . "Output ONLY the rewritten text — no preamble, no explanation, no quotes.";
    $payload = json_encode([
        'model'      => $model,
        'prompt'     => $sys . "\n\nTEXT:\n" . $out,
        'stream'     => false,
        'keep_alive' => '90s',   // brief warm window; frees shared 4GB VRAM for sd-cli
        'options'    => ['temperature' => 0.2],
    ], JSON_UNESCAPED_UNICODE);
    // Use 127.0.0.1 (not "localhost") so we never hit IPv6 ::1, where Ollama
    // isn't listening. Generous timeout covers a cold model load (~30s+).
    $ch = curl_init('http://127.0.0.1:11434/api/generate');
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => $payload,
        CURLOPT_HTTPHEADER     => ['Content-Type: application/json'],
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT        => 120,
    ]);
    $resp = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($resp !== false && $code === 200) {
        $j = json_decode((string)$resp, true);
        $r = trim((string)($j['response'] ?? ''));
        if ($r !== '') { $out = $r; $llmUsed = true; }
        else $llmErr = 'empty llm response';
    } else {
        $llmErr = 'ollama http ' . $code;
    }
}

$after = tok_est($out);
echo json_encode([
    'ok'            => true,
    'text'          => $out,
    'tokens_before' => $before,
    'tokens_after'  => $after,
    'saved'         => max(0, $before - $after),
    'pct'           => $before > 0 ? (int)round(100 * ($before - $after) / $before) : 0,
    'llm'           => $llmUsed,
    'llm_error'     => $llmErr,
    'model_used'    => $model,
    'model_clamped' => $modelClamped,
], JSON_UNESCAPED_UNICODE);
