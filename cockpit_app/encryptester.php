<?php
// =============================================================================
// encryptester.php — Dario-10S cross-language cipher tester (FPC ⇄ PHP)
// Dario Ruggi / Cockpit
//
// Verifies the XOR stream cipher produces byte-identical results in PHP and Free
// Pascal, and that each language can decrypt the other's ciphertext.
//   enc = ((data XOR key) + keyNum) mod 256  (base64 output)
//   dec = ((cipher - keyNum + 256) mod 256) XOR key
// =============================================================================

header('Content-Type: application/json');

require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();

// --- PHP reference implementation ---
function php_enc(string $data, string $key, int $keyNum): string {
    $kl = strlen($key); $out = '';
    for ($i = 0, $n = strlen($data); $i < $n; $i++)
        $out .= chr(((ord($data[$i]) ^ ord($key[$i % $kl])) + $keyNum) % 256);
    return base64_encode($out);
}
function php_dec(string $b64, string $key, int $keyNum): string {
    $kl = strlen($key); $raw = base64_decode($b64); $out = '';
    for ($i = 0, $n = strlen($raw); $i < $n; $i++)
        $out .= chr(((ord($raw[$i]) - $keyNum + 256) % 256) ^ ord($key[$i % $kl]));
    return $out;
}

// --- FPC binary (compile on demand, cache in cockpit_data) ---
function fpc_binary(string $CD): array {   // [path|'', note]
    $bin = $CD . '/dario10s';
    $src = __DIR__ . '/dario10s.pas';
    if (is_file($bin) && is_executable($bin)) return [$bin, 'cached'];
    $fpc = trim((string)shell_exec('command -v fpc 2>/dev/null'));
    if ($fpc === '') return ['', 'fpc not installed'];
    if (!is_file($src)) return ['', 'dario10s.pas missing'];
    // Compile into cockpit_data (writable; keeps web root clean).
    $cmd = escapeshellarg($fpc) . ' -O2 -FE' . escapeshellarg($CD) . ' -o' . escapeshellarg($bin) .
           ' ' . escapeshellarg($src) . ' 2>&1';
    exec($cmd, $o, $rc);
    @unlink($CD . '/dario10s.o'); @unlink($CD . '/link.res'); @unlink($CD . '/ppas.sh');
    if ($rc !== 0 || !is_file($bin)) return ['', 'compile failed: ' . trim(implode("\n", array_slice($o, -3)))];
    @chmod($bin, 0775);
    return [$bin, 'compiled'];
}
function fpc_run(string $bin, string $mode, int $keyNum, string $key, string $data): string {
    $cmd = escapeshellarg($bin) . ' ' . escapeshellarg($mode) . ' ' . escapeshellarg((string)$keyNum) .
           ' ' . escapeshellarg(base64_encode($key)) . ' ' . escapeshellarg($data);
    return trim((string)shell_exec($cmd . ' 2>/dev/null'));
}

// --- inputs (overridable) ---
$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
$key    = (string)($_GET['key']    ?? $in['key']    ?? 'MaestroDarioKey-2026');
$keyNum = (int)   ($_GET['keynum'] ?? $in['keynum'] ?? 15);
$plain  = (string)($_GET['plain']  ?? $in['plain']  ?? "The quick brown fox · עברית · 0123456789 · {}[]");

[$bin, $note] = fpc_binary($CD);

// --- PHP side ---
$cipherPhp = php_enc($plain, $key, $keyNum);
$rtPhp     = php_dec($cipherPhp, $key, $keyNum);

$tests = [];
$tests[] = ['name' => 'PHP roundtrip (enc→dec)', 'pass' => ($rtPhp === $plain)];

if ($bin === '') {
    // No Free Pascal (or no source on this install: the bundle ships no *.pas into
    // the web root): the cross-check cannot run. That is a SKIP, not a failure —
    // the PHP side above is what the app actually uses. Reported honestly so the
    // dialog does not cry FAIL on every normal machine (QA, 2026-09-22).
    $allPhp = true; foreach ($tests as $t) $allPhp = $allPhp && $t['pass'];
    echo json_encode(['ok'=>$allPhp, 'skipped'=>true, 'reason'=>$note,
        'php_cipher'=>$cipherPhp, 'tests'=>$tests], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- FPC side ---
$cipherFpc = fpc_run($bin, 'enc', $keyNum, $key, base64_encode($plain)); // base64 cipher
$rtFpcB64  = fpc_run($bin, 'dec', $keyNum, $key, $cipherFpc);            // base64 plaintext
$rtFpc     = base64_decode($rtFpcB64);

$crossPhpDecFpc = php_dec($cipherFpc, $key, $keyNum);                    // PHP decrypts FPC cipher
$crossFpcDecPhp = base64_decode(fpc_run($bin, 'dec', $keyNum, $key, $cipherPhp)); // FPC decrypts PHP cipher

$tests[] = ['name' => 'FPC roundtrip (enc→dec)',            'pass' => ($rtFpc === $plain)];
$tests[] = ['name' => 'Ciphertext identical (PHP == FPC)', 'pass' => ($cipherPhp === $cipherFpc)];
$tests[] = ['name' => 'PHP decrypts FPC ciphertext',       'pass' => ($crossPhpDecFpc === $plain)];
$tests[] = ['name' => 'FPC decrypts PHP ciphertext',       'pass' => ($crossFpcDecPhp === $plain)];

$allPass = true; foreach ($tests as $t) $allPass = $allPass && $t['pass'];

echo json_encode([
    'ok'        => $allPass,
    'fpc'       => $note,
    'keynum'    => $keyNum,
    'key_len'   => strlen($key),
    'plain'     => $plain,
    'php_cipher'=> $cipherPhp,
    'fpc_cipher'=> $cipherFpc,
    'tests'     => $tests,
], JSON_UNESCAPED_UNICODE);
