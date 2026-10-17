<?php
// =============================================================================
// dossier.php — Dossier: the gathering half of a research run.
//
// Searches several angles on a question, fetches the pages that come back, and
// returns a NUMBERED source pack. It does not write the report: the synthesis
// goes through the normal prompt path, so the answer streams into the chat like
// any other, carries the usual costs and history, and can be argued with.
//
// Gathering is done HERE, in PHP, rather than by asking the agent to emit
// %%SEARCH%% and %%FETCH%% markers in a loop. Marker loops depend on the model
// following instructions for several turns; a 1.5B local model will not, and a
// large one costs a round trip per page. Deterministic gathering means the same
// question fetches the same pages whichever agent writes the report.
//
//   POST {question, angles?, pages?}  →  {ok, sources:[{n,title,url,text}], ...}
//
// Network: every request goes through search.php, which already picks an engine,
// blocks SSRF to private addresses and caps page size.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

// Let go of the session lock before calling ourselves. search.php runs auth.php,
// which opens the SAME session file — and PHP holds that file exclusively for the
// life of a request, so the inner call blocks until this one finishes and the
// outer one waits for the inner. The first deployed run returned "read 0,
// skipped 0" with no error at all: every search had silently timed out.
if (session_status() === PHP_SESSION_ACTIVE) session_write_close();

$in       = json_decode((string)file_get_contents('php://input'), true) ?: [];
$question = trim((string)($in['question'] ?? ''));
$angles   = max(1, min(6, (int)($in['angles'] ?? 4)));     // how many searches
$pages    = max(1, min(12, (int)($in['pages'] ?? 6)));     // how many pages to read

if ($question === '' || mb_strlen($question) > 400) {
    echo json_encode(['ok' => false, 'error' => 'Ask a question (up to 400 characters).']); exit;
}

// Dossier reaches the open internet, so it honours the same switch as the rest
// of the web features rather than quietly having its own policy.
$capsF = rtrim((string)$PATHS['cockpit_data'], '/') . '/capabilities/global_caps.json';
$caps  = is_readable($capsF) ? (json_decode((string)file_get_contents($capsF), true) ?: []) : [];
if (array_key_exists('web_search', $caps) && !$caps['web_search']) {
    echo json_encode(['ok' => false, 'error' => 'Web Search is switched off in Capabilities — Dossier needs it.']); exit;
}

/** Call our own search.php, carrying the session cookie through. */
function dossier_call(string $qs): array {
    $url = 'http://127.0.0.1' . dirname($_SERVER['SCRIPT_NAME']) . '/search.php?' . $qs;
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 45,
        CURLOPT_HTTPHEADER     => ['Cookie: ' . ($_SERVER['HTTP_COOKIE'] ?? '')],
    ]);
    $raw = curl_exec($ch);
    curl_close($ch);
    unset($ch);   // PHP 8: the handle is freed on destruction, not by curl_close
    $d = json_decode((string)$raw, true);
    return is_array($d) ? $d : ['ok' => false];
}

// Angles: the question itself, then framings that surface material a single
// phrasing misses — the comparison, the criticism, the date. Deliberately
// mechanical: a model-written expansion is better prose and no more reliable,
// and this way the same question always gathers the same way.
$queries = [$question];
$extra = [
    $question . ' comparison',
    $question . ' criticism OR limitations OR problems',
    $question . ' ' . date('Y'),
    $question . ' how it works explained',
    $question . ' alternatives',
];
foreach ($extra as $e) { if (count($queries) >= $angles) break; $queries[] = $e; }

$seen = []; $hits = []; $searchFails = []; $t0 = microtime(true);
foreach ($queries as $q) {
    // A whole-run budget: six searches plus twelve fetches can outlive the PHP
    // time limit, and dying mid-way returns nothing at all rather than less.
    if (microtime(true) - $t0 > 150) { $searchFails[] = 'time budget reached'; break; }
    $r = dossier_call('action=search&n=6&q=' . urlencode($q));
    if (empty($r['ok'])) { $searchFails[] = (string)($r['error'] ?? 'search failed'); }
    foreach ((array)($r['results'] ?? []) as $res) {
        $u = (string)($res['url'] ?? '');
        if ($u === '' || isset($seen[$u])) continue;
        // One page per host: ten pages from one site is not research, and the
        // second page rarely adds anything the first did not.
        // Normalise the host before comparing: www.example.com and example.com
        // are the same site, and a probe returned the same lilypond.org page
        // twice because they compared as different hosts.
        $host = strtolower((string)parse_url($u, PHP_URL_HOST));
        $host = preg_replace('/^www\./', '', $host);
        if ($host === '' || isset($seen['host:' . $host])) continue;
        $seen[$u] = true; $seen['host:' . $host] = true;
        $hits[] = ['title' => (string)($res['title'] ?? $u), 'url' => $u, 'query' => $q];
    }
}

$sources = []; $n = 0; $failed = [];
foreach ($hits as $h) {
    if (count($sources) >= $pages) break;
    if (microtime(true) - $t0 > 170) { $failed[] = 'time budget reached'; break; }
    $f = dossier_call('action=fetch&url=' . urlencode($h['url']));
    $text = trim((string)($f['content'] ?? $f['text'] ?? ''));
    if (!($f['ok'] ?? false) || mb_strlen($text) < 200) { $failed[] = $h['url']; continue; }
    $sources[] = [
        'n'     => ++$n,
        'title' => mb_substr($h['title'], 0, 160),
        'url'   => $h['url'],
        'query' => $h['query'],
        // Enough to reason from, not so much that six pages bury the question.
        'text'  => mb_substr($text, 0, 6000),
    ];
}

echo json_encode([
    'ok'      => true,
    'question'=> $question,
    'queries' => $queries,
    'sources' => $sources,
    'read'    => count($sources),
    'skipped' => count($failed),
    'hits'    => count($hits),
    'errors'  => array_slice(array_unique(array_merge($searchFails, $failed)), 0, 5),
    'seconds' => round(microtime(true) - $t0, 1),
    'note'    => $sources ? '' : ($hits
                   ? 'Found ' . count($hits) . ' page(s) but none could be read — see errors.'
                   : 'No search results at all — the engines returned nothing, or the network is unreachable.'),
], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
