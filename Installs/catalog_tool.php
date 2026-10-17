#!/usr/bin/env php
<?php
// =============================================================================
// catalog_tool.php — the maker's side of the signed catalog feed (cockpit_app/catalog_feed_lib.php explains the feed).
//
//   php Installs/catalog_tool.php keygen          make the Ed25519 signing key (once). The SECRET stays in ~/.config/cockpit-catalog/signing.key (mode 0600), never in the repo and
//                                                 never printed; the PUBLIC half is appended to cockpit_app/catalog_pubkeys.txt (it ships inside Cockpit). Refuses to overwrite a key.
//   php Installs/catalog_tool.php build           stamp "as_of" (today) into cockpit_app/workers_providers.json, write the feed (api/catalog.json) from the supplier models and prices there
//                                                 (plus cockpit_app/catalog_new_providers.json, if present, as suggestions) and sign it (api/catalog.json.sig), into server_mirror/cockpit.ruggi.site/api/.
//   php Installs/catalog_tool.php verify          check that the feed in server_mirror verifies with the shipped public key(s) and matches the shipped catalog's models and prices.
//
// Losing the secret key means no new feed can be signed; the fix is a new key and a new Cockpit build that carries its public half (old public keys can stay in the file, so a key can be rotated).
// =============================================================================
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }
require_once __DIR__ . '/../cockpit_app/catalog_feed_lib.php';
$ROOT = realpath(__DIR__ . '/..'); $KEYF = (getenv('COCKPIT_CATALOG_KEY') ?: (getenv('HOME') . '/.config/cockpit-catalog/signing.key'));
$SHIP = "$ROOT/cockpit_app/workers_providers.json"; $PUB = "$ROOT/cockpit_app/catalog_pubkeys.txt"; $OUTD = "$ROOT/server_mirror/cockpit.ruggi.site/api";
function die2(string $m, int $rc = 1) { fwrite(STDERR, "catalog_tool: $m\n"); exit($rc); }
if (!function_exists('sodium_crypto_sign_keypair')) die2('PHP sodium is needed');
$cmd = $argv[1] ?? '';

/** The feed content derived from the shipped catalog: every supplier's models and prices (web workers have none), in the shipped order. */
function build_feed(string $ship, string $newf, string $asOf): array {
    $cat = json_decode((string)file_get_contents($ship), true); $prov = [];
    foreach ($cat['providers'] ?? [] as $p) {
        if (($p['type'] ?? '') === 'webworker' || empty($p['models'])) continue;
        $ms = [];
        foreach ($p['models'] as $m) { $c = array_intersect_key($m, array_flip(CATALOG_MODEL_KEYS)); if ($c) $ms[] = $c; }
        if ($ms) $prov[$p['id']] = ['models' => $ms];
    }
    $feed = ['format_version' => 1, 'as_of' => $asOf, 'providers' => $prov];
    if (is_file($newf)) { $np = json_decode((string)file_get_contents($newf), true); if (is_array($np) && $np) $feed['new_providers'] = array_values($np); }
    return $feed;
}

if ($cmd === 'keygen') {
    if (is_file($KEYF)) die2("a signing key already exists at $KEYF: not overwritten (delete it by hand only if you mean to rotate the key)");
    $kp = sodium_crypto_sign_keypair(); $sk = sodium_crypto_sign_secretkey($kp); $pk = sodium_crypto_sign_publickey($kp);
    @mkdir(dirname($KEYF), 0700, true); if (file_put_contents($KEYF, base64_encode($sk) . "\n") === false) die2("cannot write $KEYF"); chmod($KEYF, 0600);
    file_put_contents($PUB, (is_file($PUB) ? '' : "# Public keys that may sign the Cockpit catalog feed (one base64 Ed25519 key per line). Add a line to rotate; keep the old one while old builds are in use.\n") . '# added ' . date('Y-m-d') . "\n" . base64_encode($pk) . "\n", FILE_APPEND);
    echo "Signing key made: $KEYF (mode 0600; back it up somewhere safe and OFFLINE; it is never printed or committed).\nPublic key added to cockpit_app/catalog_pubkeys.txt: " . base64_encode($pk) . "\n"; exit(0);
}
if ($cmd === 'build') {
    if (!is_file($KEYF)) die2("no signing key at $KEYF: run  php Installs/catalog_tool.php keygen  first");
    $sk = base64_decode(trim((string)file_get_contents($KEYF)), true); if ($sk === false || strlen($sk) !== SODIUM_CRYPTO_SIGN_SECRETKEYBYTES) die2('the signing key file is not a valid key');
    $today = date('Y-m-d');
    // stamp as_of into the shipped catalog (one line after _comment; edited as text so the file's own formatting stays)
    $txt = (string)file_get_contents($SHIP);
    if (preg_match('/^  "as_of": "[^"]*",\n/m', $txt)) $txt = preg_replace('/^  "as_of": "[^"]*",\n/m', "  \"as_of\": \"$today\",\n", $txt, 1);
    else { $n = 0; $txt = preg_replace('/^(  "_comment": "[^\n]*",\n)/m', "\$1  \"as_of\": \"$today\",\n", $txt, 1, $n); if ($n !== 1) die2('could not place "as_of" in workers_providers.json'); }
    if (json_decode($txt, true) === null) die2('stamping as_of would break the catalog JSON: nothing written');
    file_put_contents($SHIP, $txt);
    $feed = build_feed($SHIP, "$ROOT/cockpit_app/catalog_new_providers.json", $today);
    if (($bad = catalog_feed_validate($feed)) !== null) die2("the feed built from the catalog is not acceptable: $bad");
    $bytes = json_encode($feed, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
    $sig = base64_encode(sodium_crypto_sign_detached($bytes, $sk)); @mkdir($OUTD, 0775, true);
    file_put_contents("$OUTD/catalog.json", $bytes); file_put_contents("$OUTD/catalog.json.sig", $sig . "\n");
    if (!catalog_feed_verify($bytes, $sig)) die2('the new signature does not verify with the public keys in cockpit_app/catalog_pubkeys.txt (is the key pair a different one?)');
    echo "Catalog as of $today: " . count($feed['providers']) . " suppliers, " . array_sum(array_map(fn($p) => count($p['models']), $feed['providers'])) . " models" . (isset($feed['new_providers']) ? ', ' . count($feed['new_providers']) . ' suggestions' : '') . ".\nWrote $OUTD/catalog.json and catalog.json.sig (verified).\n"; exit(0);
}
if ($cmd === 'verify') {
    $b = @file_get_contents("$OUTD/catalog.json"); $s = @file_get_contents("$OUTD/catalog.json.sig"); if ($b === false || $s === false) die2('no feed in server_mirror: run build');
    if (!catalog_feed_verify($b, $s)) die2('the feed does NOT verify with cockpit_app/catalog_pubkeys.txt');
    $feed = json_decode($b, true); if (($bad = catalog_feed_validate($feed)) !== null) die2("the feed verifies but is not acceptable: $bad");
    $cat = json_decode((string)file_get_contents($SHIP), true);
    if (($cat['as_of'] ?? '') !== $feed['as_of']) die2('the shipped catalog says as_of ' . ($cat['as_of'] ?? '(none)') . ' but the feed says ' . $feed['as_of'] . ': run build');
    $want = build_feed($SHIP, "$ROOT/cockpit_app/catalog_new_providers.json", $feed['as_of']);
    if ($want['providers'] != $feed['providers']) die2('the feed differs from the shipped catalog\'s models or prices: run build');
    echo "OK: the feed (as of {$feed['as_of']}) verifies and matches the shipped catalog.\n"; exit(0);
}
die2("usage: php Installs/catalog_tool.php keygen|build|verify", 2);
