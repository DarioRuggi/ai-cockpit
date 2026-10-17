<?php
require_once __DIR__ . "/auth.php";

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();
// =============================================================================
// ollama_guard.php — shared policy for LOCAL Ollama model selection.
// Dario Ruggi / AI Cockpit.
//
// RULE: automatic/background tasks must NEVER auto-load a local model larger
// than 4B parameters. Only an explicit user selection (the chat model picker)
// may run bigger models. This caps surprise VRAM/CPU blowups on the 4GB box.
// =============================================================================
if (!defined('OLLAMA_AUTO_MAX_B')) define('OLLAMA_AUTO_MAX_B', 4.0);

// Estimate parameter count (in billions) from an Ollama model name/tag.
// Returns -1.0 when the size can't be determined from the name.
//   olmo-3:7b → 7 | gemma3:12b → 12 | qwen2.5:1.5b → 1.5
//   smollm2:360m → 0.36 | gemma4:e2b → 2 | phi:latest → -1 (unknown)
function ollama_param_b(string $name): float {
    $tag = $name;
    if (strpos($name, ':') !== false) { $p = explode(':', $name); $tag = end($p); }
    if (preg_match('/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i', $tag, $m) ||
        preg_match('/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i', $name, $m)) {
        $n = (float)$m[1];
        return strtolower($m[2]) === 'm' ? $n / 1000.0 : $n;
    }
    return -1.0;
}

// True if a model is safe for an AUTOMATIC task (known size AND ≤ 4B).
// Unknown size → false (conservative: don't auto-load something we can't size).
function ollama_auto_ok(string $name): bool {
    $b = ollama_param_b($name);
    return $b >= 0 && $b <= OLLAMA_AUTO_MAX_B + 0.001;
}

// Fetch currently-available local model names from Ollama (empty on failure).
function ollama_available_models(): array {
    $ch = curl_init('http://127.0.0.1:11434/api/tags');
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_CONNECTTIMEOUT => 3, CURLOPT_TIMEOUT => 5]);
    $body = curl_exec($ch); curl_close($ch);
    if (!$body) return [];
    $j = json_decode((string)$body, true);
    if (!is_array($j)) return [];
    $out = [];
    foreach (($j['models'] ?? []) as $m) { if (!empty($m['name'])) $out[] = $m['name']; }
    return $out;
}

// Return a model safe for automatic use: the requested model if it's ≤4B,
// otherwise the best ≤4B model available (preferring $prefer), else ''.
// $available may be passed in to avoid a redundant /api/tags call.
function ollama_auto_model(string $requested, ?array $available = null, string $prefer = 'llama3.2:1b'): string {
    if ($requested !== '' && ollama_auto_ok($requested)) return $requested;
    if ($available === null) $available = ollama_available_models();
    foreach ($available as $a) {                       // preferred small model first
        if ($a !== '' && stripos($a, $prefer) === 0 && ollama_auto_ok($a)) return $a;
    }
    $best = ''; $bestB = -1.0;                          // else largest model still ≤4B
    foreach ($available as $a) {
        if ($a === '' || !ollama_auto_ok($a)) continue;
        $b = ollama_param_b($a);
        if ($b > $bestB) { $bestB = $b; $best = $a; }
    }
    return $best;
}
