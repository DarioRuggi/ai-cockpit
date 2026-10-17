<?php
// =============================================================================
// catalog_feed_lib.php — the signed catalog feed: new models and new prices WITHOUT a new Cockpit build.
//
// What it is. The Cockpit site publishes api/catalog.json (+ catalog.json.sig, an Ed25519 signature over its exact bytes). With the feed switched ON, Cockpit fetches the pair,
// checks the signature against the public key(s) shipped in catalog_pubkeys.txt, validates the content, keeps the verified copy in <cockpit_data>/catalog_feed.json(+.sig) and layers it
// between the shipped catalog and the user's own overlay:   shipped  →  verified feed  →  the user's additions (which always win).
//
// What it may change. For a supplier Cockpit already has: its models (add one, or update label / kinds / free / pricing / context / note of one, retire one) and the order they are listed
// in. That is all. It can NOT change a supplier's address (base_url), its kind of API, its key handling or its limits: an address that moved could send your API key somewhere else.
// A brand-new supplier is never merged: it is only offered as a SUGGESTION (with its address in plain sight) that the person adds with one click, like any custom supplier.
//
// Fail closed. No sodium, no public key, a bad or missing signature, a malformed feed, a negative or absurd price: the feed is ignored as a whole and the shipped catalog is used.
// The verified copy is verified AGAIN on every read, so a file that was edited in cockpit_data afterwards stops counting.
// =============================================================================

const CATALOG_FEED_URL   = 'https://cockpit.ruggi.site/api/catalog.json';
const CATALOG_FEED_MAX   = 524288;        // bytes: a feed larger than this is refused
const CATALOG_STALE_DAYS = 90;            // the panel turns amber after this many days without a newer catalog
const CATALOG_MODEL_KEYS = ['id', 'label', 'kinds', 'free', 'pricing', 'context', 'note', 'deprecated'];   // the only model fields a feed may carry

function catalog_feed_pubkeys(): array {
    $f = __DIR__ . '/catalog_pubkeys.txt'; $out = [];
    foreach (is_file($f) ? (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: []) : [] as $l) {
        $l = trim($l); if ($l === '' || $l[0] === '#') continue;
        $raw = base64_decode($l, true); if ($raw !== false && strlen($raw) === 32) $out[] = $raw;
    }
    return $out;
}
function catalog_feed_can_verify(): bool { return function_exists('sodium_crypto_sign_verify_detached') && catalog_feed_pubkeys() !== []; }

/** True only if $sig_b64 is a valid Ed25519 signature of exactly $bytes by one of the shipped public keys. */
function catalog_feed_verify(string $bytes, string $sig_b64): bool {
    if (!function_exists('sodium_crypto_sign_verify_detached')) return false;
    $sig = base64_decode(trim($sig_b64), true); if ($sig === false || strlen($sig) !== SODIUM_CRYPTO_SIGN_BYTES) return false;
    foreach (catalog_feed_pubkeys() as $pk) { try { if (sodium_crypto_sign_verify_detached($sig, $bytes, $pk)) return true; } catch (Throwable $e) {} }
    return false;
}

function _catalog_price_ok($v): bool { return (is_int($v) || is_float($v)) && $v >= 0 && $v <= 10000; }

/** null when the decoded feed is acceptable, else the reason it is not. */
function catalog_feed_validate($feed): ?string {
    if (!is_array($feed)) return 'the feed is not a JSON object';
    if ((int)($feed['format_version'] ?? 0) !== 1) return 'unknown feed format';
    if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', (string)($feed['as_of'] ?? '')) || !strtotime((string)$feed['as_of'])) return 'the feed has no valid date (as_of)';
    if (!is_array($feed['providers'] ?? null)) return 'the feed has no providers';
    foreach ($feed['providers'] as $pid => $p) {
        if (!is_string($pid) || !preg_match('/^[a-z0-9_-]{1,40}$/', $pid) || !is_array($p)) return 'bad provider entry';
        foreach (($p['models'] ?? []) as $m) {
            if (!is_array($m) || !preg_match('/^[A-Za-z0-9._:@+\/-]{1,100}$/', (string)($m['id'] ?? ''))) return "$pid: a model without a valid id";
            if (isset($m['pricing'])) {
                $pr = $m['pricing']; if (!is_array($pr) || !_catalog_price_ok($pr['input_per_mtok'] ?? null) || !_catalog_price_ok($pr['output_per_mtok'] ?? null)) return "$pid/{$m['id']}: bad price";
                if (isset($pr['long_context']) && (!is_array($pr['long_context']) || !_catalog_price_ok($pr['long_context']['input_per_mtok'] ?? null) || !_catalog_price_ok($pr['long_context']['output_per_mtok'] ?? null) || !is_int($pr['long_context']['over_tokens'] ?? null))) return "$pid/{$m['id']}: bad long-context price";
            }
            if (isset($m['kinds']) && (!is_array($m['kinds']) || array_filter($m['kinds'], fn($k) => !is_string($k) || !preg_match('/^[a-z0-9_-]{1,32}$/', $k)))) return "$pid/{$m['id']}: bad kinds";
        }
        foreach (($p['retire'] ?? []) as $r) if (!is_string($r)) return "$pid: bad retire list";
    }
    foreach (($feed['new_providers'] ?? []) as $np) {
        if (!is_array($np) || !preg_match('/^[a-z0-9_-]{1,40}$/', (string)($np['id'] ?? '')) || !preg_match('#^https://[A-Za-z0-9.-]+(:\d+)?(/[^\s]*)?$#', (string)($np['base_url'] ?? ''))) return 'bad new-provider suggestion (its address must be https)';
        if (!preg_match('/^[a-z0-9_-]{1,40}$/', (string)($np['base'] ?? ''))) return 'bad new-provider suggestion (base)';
    }
    return null;
}

/** The verified feed from <cockpit_data>, or null (switched off, no file, no way to verify, bad signature, invalid content). Verified again on every call. */
function catalog_feed_load(string $cd): ?array {
    $f = rtrim($cd, '/') . '/catalog_feed.json'; $s = $f . '.sig';
    $st = json_decode((string)@file_get_contents(rtrim($cd, '/') . '/catalog_feed_settings.json'), true);
    if (empty($st['enabled'])) return null;   // switched off = the stored copy does not count either
    if (!is_file($f) || !is_file($s)) return null;
    $bytes = (string)@file_get_contents($f); if ($bytes === '' || strlen($bytes) > CATALOG_FEED_MAX) return null;
    if (!catalog_feed_verify($bytes, (string)@file_get_contents($s))) return null;
    $feed = json_decode($bytes, true);
    return catalog_feed_validate($feed) === null ? $feed : null;
}

/** Merge a verified feed into the shipped catalog (see the header for what it may touch). */
function catalog_feed_apply(array $catalog, ?array $feed): array {
    if (!$feed) return $catalog;
    foreach ($catalog['providers'] ?? [] as $i => $p) {
        $fp = $feed['providers'][$p['id'] ?? ''] ?? null; if (!is_array($fp)) continue;
        $models = $p['models'] ?? []; $idx = []; foreach ($models as $k => $m) $idx[$m['id'] ?? ''] = $k;
        $order = [];
        foreach (($fp['models'] ?? []) as $fm) {
            $clean = array_intersect_key($fm, array_flip(CATALOG_MODEL_KEYS)); $id = $fm['id']; $order[] = $id;
            if (isset($idx[$id])) { $models[$idx[$id]] = array_merge($models[$idx[$id]], $clean); }
            else { $clean += ['label' => $id, 'kinds' => ($p['kinds'] ?? ['text']), 'free' => !empty($p['free'])]; $clean['from_feed'] = true; $models[] = $clean; $idx[$id] = count($models) - 1; }
        }
        foreach (($fp['retire'] ?? []) as $rid) if (isset($idx[$rid])) $models[$idx[$rid]]['deprecated'] = true;
        if ($order) {   // the feed's own order first (the cheapest model is the default pick), then whatever else the provider has
            $pos = array_flip($order); $rest = [];
            usort($models, function ($a, $b) use ($pos) { $x = $pos[$a['id'] ?? ''] ?? PHP_INT_MAX; $y = $pos[$b['id'] ?? ''] ?? PHP_INT_MAX; return $x <=> $y; });
        }
        $catalog['providers'][$i]['models'] = array_values($models);
        $all = []; foreach ($catalog['providers'][$i]['models'] as $m) foreach (($m['kinds'] ?? []) as $k) $all[$k] = true;
        if ($all) $catalog['providers'][$i]['kinds'] = array_keys($all);
    }
    $catalog['feed_as_of'] = $feed['as_of'];
    return $catalog;
}

/** Suggestions for suppliers the catalog does not have yet (never merged: the person adds one, seeing its address). */
function catalog_feed_suggestions(array $catalog, ?array $feed): array {
    if (!$feed) return [];
    $have = []; foreach ($catalog['providers'] ?? [] as $p) $have[$p['id'] ?? ''] = true;
    $out = [];
    foreach (($feed['new_providers'] ?? []) as $np) if (empty($have[$np['id']])) $out[] = array_intersect_key($np, array_flip(['id', 'name', 'base', 'base_url', 'website', 'key_url', 'note', 'models']));
    return $out;
}

/** The date the catalog in use is current as of: the newer of the shipped catalog's and a verified feed's. */
function catalog_as_of(array $catalog): string {
    $a = (string)($catalog['as_of'] ?? ''); $b = (string)($catalog['feed_as_of'] ?? '');
    return max($a, $b);
}
function catalog_age_days(string $as_of): ?int { $t = $as_of !== '' ? strtotime($as_of) : false; return $t ? (int)floor((time() - $t) / 86400) : null; }

/** Fetch feed + signature over https (or the test override), verify, validate, store. Returns ['ok'=>bool,'error'=>?,'as_of'=>?]. */
function catalog_feed_fetch_and_store(string $cd, ?string $url = null): array {
    $url = $url ?? (getenv('COCKPIT_CATALOG_FEED_URL') ?: CATALOG_FEED_URL);
    if (!catalog_feed_can_verify()) return ['ok' => false, 'error' => 'this install cannot check signatures (the PHP sodium module or the public key is missing), so the feed is not used'];
    $get = function (string $u) {
        $ch = curl_init($u);
        curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => 10, CURLOPT_CONNECTTIMEOUT => 5, CURLOPT_FOLLOWLOCATION => false, CURLOPT_MAXFILESIZE => CATALOG_FEED_MAX,
            CURLOPT_PROTOCOLS => getenv('COCKPIT_CATALOG_FEED_URL') ? (CURLPROTO_HTTP | CURLPROTO_HTTPS) : CURLPROTO_HTTPS, CURLOPT_USERAGENT => 'AICockpit-catalog-feed']);
        $b = curl_exec($ch); $c = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE); $e = curl_error($ch); curl_close($ch);
        return [$b, $c, $e];
    };
    [$bytes, $code, $err] = $get($url); if ($bytes === false || $code !== 200) return ['ok' => false, 'error' => 'could not fetch the feed (' . ($err ?: "HTTP $code") . ')'];
    [$sig, $code2, $err2] = $get($url . '.sig'); if ($sig === false || $code2 !== 200) return ['ok' => false, 'error' => 'could not fetch the feed signature (' . ($err2 ?: "HTTP $code2") . ')'];
    if (strlen($bytes) > CATALOG_FEED_MAX) return ['ok' => false, 'error' => 'the feed is too large'];
    if (!catalog_feed_verify($bytes, $sig)) return ['ok' => false, 'error' => 'the feed signature does not match: the feed was NOT used'];
    $feed = json_decode($bytes, true); $bad = catalog_feed_validate($feed); if ($bad !== null) return ['ok' => false, 'error' => "the feed was signed but is not acceptable: $bad"];
    $cur = catalog_feed_load($cd); if ($cur && strcmp($feed['as_of'], $cur['as_of']) < 0) return ['ok' => false, 'error' => 'the feed is older than the one already in use (' . $cur['as_of'] . '): kept the newer one', 'as_of' => $cur['as_of']];
    $dir = rtrim($cd, '/'); if (!is_dir($dir)) return ['ok' => false, 'error' => 'no data folder'];
    $t1 = $dir . '/.catalog_feed.json.tmp' . getmypid(); $t2 = $dir . '/.catalog_feed.json.sig.tmp' . getmypid();
    if (@file_put_contents($t1, $bytes) === false || @file_put_contents($t2, trim($sig)) === false) return ['ok' => false, 'error' => 'could not write the data folder'];
    @rename($t2, $dir . '/catalog_feed.json.sig'); @rename($t1, $dir . '/catalog_feed.json');
    return ['ok' => true, 'as_of' => $feed['as_of']];
}
