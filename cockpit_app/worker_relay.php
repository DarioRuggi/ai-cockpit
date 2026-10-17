<?php
// =============================================================================
// worker_relay.php — CLI bridge so agent_loop (bash) can use the Workers engine
// for the free-REST fallback (Card 2). Reuses workers.php's invoke_* functions
// and its ENCRYPTED key store (no duplicate plaintext key file).
//
//   php worker_relay.php <provider> <model> <prompt_file>
//
// Prints the response text to stdout (or "[<PROVIDER> ERROR] ..."). Requiring
// workers.php in CLI loads its functions + $KEYS_F but skips auth + dispatch.
// =============================================================================
// A command-line helper only (agent_loop runs it with php-cli): over the web it answers 403 before it loads anything.
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require __DIR__ . '/workers.php';
// NOT saas-gated: pure LOCAL dispatch via invoke_* on the user's own decrypted
// keys (no ruggi relay server). real_dispatch infra — v1 needs it; agent_loop
// (its only caller) is edition-gated at its own entry, so demo never reaches here.

// agent_loop passes the requesting user's per-user cockpit_data dir here (it runs
// session-less, so workers.php resolved $KEYS_F to the SHARED root). Re-point the
// key/provider/state files at the user's dir so their saved worker keys are found.
$_ovr = getenv('COCKPIT_DATA_OVERRIDE');
if ($_ovr && is_dir($_ovr)) {
    $KEYS_F      = rtrim($_ovr, '/') . '/workers_keys.enc';
    $PROVIDERS_F = rtrim($_ovr, '/') . '/workers_providers.json';
    $STATE_F     = rtrim($_ovr, '/') . '/workers_state.json';
}

$provider = $argv[1] ?? '';
$model    = $argv[2] ?? '';
$pfile    = $argv[3] ?? '';
$prompt   = ($pfile !== '' && is_readable($pfile)) ? (string)file_get_contents($pfile) : '';

if ($provider === '' || $prompt === '') {
    fwrite(STDERR, "usage: worker_relay.php <provider> <model> <prompt_file>\n");
    echo '[RELAY ERROR] missing provider or prompt';
    exit(1);
}
$fn = 'invoke_' . $provider;
if (!function_exists($fn)) { echo '[RELAY ERROR] unknown provider: ' . $provider; exit(1); }

$keys = load_keys($KEYS_F);            // decrypted via machine-id master key
$key  = $keys[$provider] ?? '';

$_base = (string)getenv('COCKPIT_WORKER_BASE');   // test hook: the engine's relay (aicengine relay) has the same one
$r = $fn($model, 'text', $prompt, $key, [], $_base);
if (!empty($r['ok'])) {
    echo (string)($r['output'] ?? '');
} else {
    echo '[' . strtoupper($provider) . ' ERROR] ' . ($r['error'] ?? 'request failed');
}
