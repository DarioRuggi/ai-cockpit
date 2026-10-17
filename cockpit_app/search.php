<?php
require_once __DIR__ . "/auth.php";

// [edition] demo canned/stub — ported from demo fork, keyed on ed_is('demo')
if (ed_is('demo') && ed_is_direct(__FILE__)) ed_demo_stub();
// =============================================================================
// search.php — Cockpit Web Search backend
//
// Endpoints:
//   GET  ?action=search&q=...&n=8        Search the web, return N results
//   GET  ?action=fetch&url=...           Fetch a URL's content (text-extracted)
//   GET  ?action=ask&q=...               AI answer via DuckDuckGo's chat (best-effort)
//   GET  ?action=health                  Test if the network is reachable
//
// Search engines tried (in order):
//   1. search.brave.com
//   2. lite.duckduckgo.com — no-JS DDG, fallback
//   3. html.duckduckgo.com — full DDG HTML, fallback
//
// 2026-09-30: all three now challenge automated queries. Measured from one rig:
// Brave 429, both DDG endpoints 202 with an anomaly page and zero results, and
// the same for Mojeek (a CAPTCHA), Marginalia and three SearXNG instances. This
// header used to call Brave "scrape-friendly, no captchas"; that was true when
// it was written and is not true now. Free scraped web search has closed as a
// category, so a caller must treat an empty result as NORMAL and say which
// engine refused — see the 'errors' field, which exists for exactly that.
//
// The fix is a key: api.search.brave.com answers 422 asking for a token from the
// same IP that search.brave.com refuses with 429, so the keyed door is open. An
// API path is planned — docs/dossier_deferred.md has the measurements and plan.
//
// All HTTP via curl. Pure PHP DOMDocument for parsing. No Python.
// =============================================================================

ini_set('display_errors', '0');
error_reporting(0);
header('Content-Type: application/json');
header('Cache-Control: no-store');

// Make sure even fatal errors return JSON
register_shutdown_function(function() {
    $err = error_get_last();
    if ($err && in_array($err['type'], [E_ERROR, E_PARSE, E_CORE_ERROR, E_COMPILE_ERROR], true)) {
        if (!headers_sent()) header('Content-Type: application/json');
        echo json_encode(['ok'=>false, 'error'=>'Internal: ' . $err['message']], JSON_UNESCAPED_UNICODE);
    }
});

$action = $_GET['action'] ?? '';

// Real Chrome UA — accepted by all three engines
$REAL_UA = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

// =============================================================================
// Health check
// =============================================================================
if ($action === 'health') {
    // Brave first — it's our primary engine now
    $cmd  = 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 ' . escapeshellarg('https://search.brave.com/') . ' 2>&1';
    $code = trim((string)shell_exec($cmd));
    if ($code !== '200') {
        // Fall back to checking DDG
        $cmd  = 'curl -s -o /dev/null -w "%{http_code}" --max-time 5 https://duckduckgo.com 2>&1';
        $ddg  = trim((string)shell_exec($cmd));
        echo json_encode([
            'ok'     => ($ddg === '200'),
            'http'   => 'brave=' . $code . ', ddg=' . $ddg,
            'engine' => 'duckduckgo (fallback)',
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }
    echo json_encode(['ok'=>true, 'http'=>$code, 'engine'=>'brave'], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Search
// =============================================================================
if ($action === 'search') {
    $q = trim($_GET['q'] ?? '');
    $n = max(1, min(10, intval($_GET['n'] ?? 8)));
    if ($q === '') { echo json_encode(['ok'=>false, 'error'=>'Missing query'], JSON_UNESCAPED_UNICODE); exit; }

    $tried   = [];
    $results = searchBrave($q, $n, $REAL_UA, $tried);
    $engine  = 'brave';
    if (empty($results)) {
        $results = searchDdgLite($q, $n, $REAL_UA, $tried);
        $engine  = 'ddg-lite';
    }
    if (empty($results)) {
        $results = searchDdgHtml($q, $n, $REAL_UA, $tried);
        $engine  = 'ddg-html';
    }

    if (empty($results)) {
        echo json_encode([
            'ok'     => false,
            'error'  => 'All engines failed: ' . implode('; ', array_map(
                            fn($t) => ($t['engine'] ?? '?') . ' ' . ($t['why'] ?? ''), $tried)),
            'q'      => $q,
            'tried'  => $tried,
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }

    echo json_encode([
        'ok'      => true,
        'q'       => $q,
        'count'   => count($results),
        'results' => $results,
        'engine'  => $engine,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Fetch — get a URL's text content (HTML stripped)
// =============================================================================
if ($action === 'fetch') {
    $url = trim($_GET['url'] ?? '');
    if (!preg_match('#^https?://#i', $url)) {
        echo json_encode(['ok'=>false, 'error'=>'Invalid URL'], JSON_UNESCAPED_UNICODE); exit;
    }
    // CRIT-83 fix: block SSRF to localhost/private IPs. An agent could
    // otherwise fetch http://localhost/cockpit/workers_keys.enc etc.
    $host = parse_url($url, PHP_URL_HOST);
    if (!$host) { echo json_encode(['ok'=>false,'error'=>'Invalid host'], JSON_UNESCAPED_UNICODE); exit; }
    $ip = filter_var($host, FILTER_VALIDATE_IP) ? $host : gethostbyname($host);
    if (!filter_var($ip, FILTER_VALIDATE_IP,
            FILTER_FLAG_IPV4 | FILTER_FLAG_NO_PRIV_RANGE | FILTER_FLAG_NO_RES_RANGE)) {
        // Either resolution failed OR resolved to private/reserved range
        if (filter_var($ip, FILTER_VALIDATE_IP)) {
            echo json_encode(['ok'=>false,'error'=>'Blocked internal/private destination'], JSON_UNESCAPED_UNICODE); exit;
        }
        // Allow IPv6 only if not loopback/link-local — quick check
        if (!filter_var($ip, FILTER_VALIDATE_IP, FILTER_FLAG_IPV6) ||
            stripos($ip, '::1') === 0 || stripos($ip, 'fe80:') === 0 || stripos($ip, 'fc00:') === 0) {
            echo json_encode(['ok'=>false,'error'=>'Unable to resolve or blocked host'], JSON_UNESCAPED_UNICODE); exit;
        }
    }
    $cmd = sprintf(
        'curl -sL --max-time 15 --max-filesize 524288 -A %s %s 2>/dev/null',
        escapeshellarg($REAL_UA),
        escapeshellarg($url)
    );
    $body_raw = shell_exec($cmd);
    if ($body_raw === null) { echo json_encode(['ok'=>false,'error'=>'curl unavailable'], JSON_UNESCAPED_UNICODE); exit; }
    $body = (string)$body_raw;
    if ($body === '') { echo json_encode(['ok'=>false, 'error'=>'No response'], JSON_UNESCAPED_UNICODE); exit; }

    $text = strip_tags(preg_replace('#<(script|style)[^>]*>.*?</\1>#is', '', $body));
    $text = html_entity_decode($text, ENT_QUOTES | ENT_HTML5, 'UTF-8');
    $text = preg_replace('/[ \t]+/', ' ', $text);
    $text = preg_replace('/\n{3,}/', "\n\n", $text);
    $text = trim($text);
    if (strlen($text) > 16384) $text = substr($text, 0, 16384) . "\n\n[... truncated to 16KB]";

    echo json_encode([
        'ok'    => true,
        'url'   => $url,
        'bytes' => strlen($body),
        'text'  => $text,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// =============================================================================
// Ask — opens the DDG AI chat URL for the query (returns the URL to open)
// We don't try to scrape the chat response (it's behind auth + websocket). The
// frontend should open this URL in a new tab.
// =============================================================================
if ($action === 'ask') {
    $q = trim($_GET['q'] ?? '');
    if ($q === '') { echo json_encode(['ok'=>false, 'error'=>'Missing query'], JSON_UNESCAPED_UNICODE); exit; }
    echo json_encode([
        'ok'  => true,
        'q'   => $q,
        // Both engines have an Ask URL — Brave summary mode and DDG's chat
        // (Duck.ai). DDG's chat reads the query from URL fragment + path; the
        // ?ia=chat opens the chat page only — the query goes in via hash.
        'urls' => [
            'duckduckgo' => 'https://duckduckgo.com/?q=' . urlencode($q) . '&ia=chat&duckai=1',
            'brave'      => 'https://search.brave.com/search?q=' . urlencode($q) . '&summary=1',
        ],
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

echo json_encode(['ok'=>false, 'error'=>'Unknown action: ' . $action], JSON_UNESCAPED_UNICODE);
exit;

// =============================================================================
// ── Engine implementations ──────────────────────────────────────────────────
// =============================================================================

function searchBrave($q, $n, $ua, &$tried) {
    $url  = 'https://search.brave.com/search?q=' . urlencode($q) . '&source=web';
    $html = fetchHtml($url, $ua, 'GET');
    $tried[] = ['engine'=>'brave', 'url'=>$url, 'len'=>strlen((string)$html),
                'why'=>searchBlockReason($html)];
    if (!$html) return [];

    // Use DOM if available, otherwise fall back to regex
    if (class_exists('DOMDocument')) {
        return parseBraveDom($html, $n);
    }
    return parseBraveRegex($html, $n);
}

// DOM-based parser for Brave (preferred — more accurate)
function parseBraveDom($html, $n) {
    $results = [];
    libxml_use_internal_errors(true);
    $doc = new DOMDocument();
    $doc->loadHTML('<?xml encoding="UTF-8">' . $html);
    libxml_clear_errors();
    $xpath = new DOMXPath($doc);

    // Look for the outer result containers — divs whose class includes
    // "snippet" or "fdb" (Brave's result block class). Each container has
    // an anchor (the link), a title, and a description as descendants.
    $containers = $xpath->query("//div[contains(concat(' ', @class, ' '), ' snippet ') or contains(@class, 'fdb-')]");
    if (!$containers || $containers->length === 0) {
        // Fallback: any div whose class string contains "snippet"
        $containers = $xpath->query("//div[contains(@class, 'snippet')]");
    }

    $seen = [];
    if ($containers) {
        foreach ($containers as $box) {
            if (count($results) >= $n) break;

            // Find the result link — first <a> with an http(s) href inside the box
            $aNode = null;
            $links = $xpath->query(".//a[@href]", $box);
            foreach ($links as $a) {
                $href = $a->getAttribute('href');
                if (strpos($href, 'http') === 0) { $aNode = $a; break; }
            }
            if (!$aNode) continue;

            $href = $aNode->getAttribute('href');
            if (stripos($href, 'brave.com')      !== false) continue;
            if (stripos($href, 'duckduckgo.com') !== false) continue;
            if (isset($seen[$href]))                        continue;

            // Title — first descendant whose class contains "title"
            $titleNode = $xpath->query(".//*[contains(@class,'title')]", $box)->item(0);
            $title     = $titleNode ? trim(preg_replace('/\s+/', ' ', $titleNode->textContent)) : '';
            if (!$title) {
                $title = trim(preg_replace('/\s+/', ' ', $aNode->textContent));
            }
            if (!$title) continue;

            // Snippet — descendant with class containing "description" or "snippet-description"
            $snippet  = '';
            $descNode = $xpath->query(".//*[contains(@class,'description') or contains(@class,'snippet-description') or contains(@class,'snippet-content')]", $box)->item(0);
            if ($descNode) {
                $snippet = trim(preg_replace('/\s+/', ' ', $descNode->textContent));
            }

            $seen[$href] = true;
            $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>$snippet];
        }
    }
    return $results;
}

// Regex fallback parser for Brave (no DOM extension required)
//
// Brave's result HTML has shape (simplified):
//   <div class="snippet ...">
//     <a href="https://..." class="...">
//       <div class="title">TITLE</div>
//     </a>
//     <div class="snippet-description">SNIPPET</div>
//   </div>
// The snippet is a SIBLING of the anchor, not inside it. So we match the
// outer .snippet div, then extract the link, title, and description from
// within that block.
function parseBraveRegex($html, $n) {
    $results = [];
    $seen    = [];

    // Approach 1: match outer snippet/result containers, then pull pieces from within.
    // Container starts with <div class="...snippet..." or <div class="...result..."
    // and ends at the matching </div>. Since regex can't do balanced matching,
    // we use a non-greedy match on a generous size and rely on the fact that
    // each result block is typically < 8KB.
    if (preg_match_all('#<div\s+[^>]*class="[^"]*\b(?:snippet|fdb|result-row)\b[^"]*"[^>]*>(.{0,12000}?)</div>\s*(?=<div\s+[^>]*class="[^"]*\b(?:snippet|fdb|result-row|footer|sidebar)\b|<footer|<aside|$)#is',
                       $html, $blockMatches, PREG_SET_ORDER)) {

        foreach ($blockMatches as $bm) {
            if (count($results) >= $n) break;
            $block = $bm[1];

            // Find the result link — first <a> with an http(s) href
            if (!preg_match('#<a\s[^>]*href="(https?://[^"]+)"#i', $block, $hm)) continue;
            $href = html_entity_decode($hm[1], ENT_QUOTES, 'UTF-8');

            if (stripos($href, 'brave.com')      !== false) continue;
            if (stripos($href, 'duckduckgo.com') !== false) continue;
            if (isset($seen[$href]))                        continue;

            // Title — first <div|span|h3> with class containing "title"
            $title = '';
            if (preg_match('#<(?:div|span|h\d)[^>]*class="[^"]*\btitle\b[^"]*"[^>]*>(.*?)</(?:div|span|h\d)>#is', $block, $tm)) {
                $title = trim(preg_replace('/\s+/', ' ',
                    html_entity_decode(strip_tags($tm[1]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
            }
            if (!$title) {
                // Fallback: use the anchor's text
                if (preg_match('#<a\s[^>]*href="' . preg_quote($hm[1], '#') . '"[^>]*>(.*?)</a>#is', $block, $am)) {
                    $title = trim(preg_replace('/\s+/', ' ',
                        html_entity_decode(strip_tags($am[1]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
                }
            }
            if (!$title) continue;

            // Snippet — element with class "description" or "snippet-description"
            $snippet = '';
            if (preg_match('#<(?:div|span|p)[^>]*class="[^"]*\b(?:description|snippet-description|snippet-content)\b[^"]*"[^>]*>(.*?)</(?:div|span|p)>#is', $block, $sm)) {
                $snippet = trim(preg_replace('/\s+/', ' ',
                    html_entity_decode(strip_tags($sm[1]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
            }

            $seen[$href] = true;
            $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>$snippet];
        }
    }

    // Approach 2 (fallback): if container matching didn't yield enough, fall
    // back to the original anchor-body scan. Some Brave layouts put the title
    // inside the anchor element itself.
    if (count($results) < $n) {
        if (preg_match_all('#<a\s[^>]*href="(https?://[^"]+)"[^>]*>(.{0,4000}?)</a>#is', $html, $matches, PREG_SET_ORDER)) {
            foreach ($matches as $m) {
                if (count($results) >= $n) break;
                $href = html_entity_decode($m[1], ENT_QUOTES, 'UTF-8');
                $body = $m[2];

                if (stripos($href, 'brave.com')      !== false) continue;
                if (stripos($href, 'duckduckgo.com') !== false) continue;
                if (isset($seen[$href]))                        continue;

                if (!preg_match('#class="[^"]*\btitle\b[^"]*"#i', $body)) continue;

                $title = '';
                if (preg_match('#<[^>]+class="[^"]*\btitle\b[^"]*"[^>]*>(.*?)</#is', $body, $tm)) {
                    $title = trim(preg_replace('/\s+/', ' ',
                        html_entity_decode(strip_tags($tm[1]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
                }
                if (!$title) continue;

                $seen[$href] = true;
                $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>''];
            }
        }
    }

    return $results;
}

function searchDdgLite($q, $n, $ua, &$tried) {
    $url  = 'https://lite.duckduckgo.com/lite/';
    $html = fetchHtml($url, $ua, 'POST', 'q=' . urlencode($q));
    $tried[] = ['engine'=>'ddg-lite', 'url'=>$url, 'len'=>strlen((string)$html),
                'why'=>searchBlockReason($html)];
    if (!$html) return [];

    if (class_exists('DOMDocument')) {
        return parseDdgLiteDom($html, $n);
    }
    return parseDdgLiteRegex($html, $n);
}

function parseDdgLiteDom($html, $n) {
    $results = [];
    libxml_use_internal_errors(true);
    $doc = new DOMDocument();
    $doc->loadHTML('<?xml encoding="UTF-8">' . $html);
    libxml_clear_errors();
    $xpath = new DOMXPath($doc);

    $links = $xpath->query("//a[@rel='nofollow']");
    if ($links) {
        foreach ($links as $a) {
            if (count($results) >= $n) break;
            $title = trim(preg_replace('/\s+/', ' ', $a->textContent));
            $href  = $a->getAttribute('href');
            if (preg_match('#uddg=([^&]+)#', $href, $m)) $href = urldecode($m[1]);
            if (strpos($href, '//') === 0) $href = 'https:' . $href;
            if ($title && $href && stripos($href, 'duckduckgo.com') === false) {
                $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>''];
            }
        }
    }
    return $results;
}

/**
 * Why did an engine return no results? "0 results" and "the engine refused us"
 * look identical from the parse, and they need opposite reactions: one is a bad
 * query, the other is a rate limit that clears on its own. Brave answers 429 all
 * day on some IPs and DuckDuckGo serves an "anomaly" page once a machine has
 * asked too often — and Dossier fires four to six searches per run, so it walks
 * into that by design.
 */
function searchBlockReason(?string $html): string {
    if ($html === null || $html === '') return 'no response';
    if (preg_match('/unusual traffic|anomaly|captcha|are you a robot|rate.?limit/i', $html)) {
        return 'refused us — looks rate-limited, try again in a few minutes';
    }
    if (strlen($html) < 1000) return 'empty response';
    return 'returned a page with no results in it';
}

function parseDdgLiteRegex($html, $n) {
    $results = [];
    if (!preg_match_all('#<a\s[^>]*rel=[\'"]nofollow[\'"][^>]*href="([^"]+)"[^>]*>(.*?)</a>#is', $html, $matches, PREG_SET_ORDER)) {
        return [];
    }
    foreach ($matches as $m) {
        if (count($results) >= $n) break;
        $href = html_entity_decode($m[1], ENT_QUOTES, 'UTF-8');
        if (preg_match('#uddg=([^&]+)#', $href, $u)) $href = urldecode($u[1]);
        if (strpos($href, '//') === 0) $href = 'https:' . $href;
        if (stripos($href, 'duckduckgo.com') !== false) continue;
        $title = trim(preg_replace('/\s+/', ' ',
            html_entity_decode(strip_tags($m[2]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
        if (!$title) continue;
        $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>''];
    }
    return $results;
}

function searchDdgHtml($q, $n, $ua, &$tried) {
    $url  = 'https://html.duckduckgo.com/html/';
    $html = fetchHtml($url, $ua, 'POST', 'q=' . urlencode($q));
    $tried[] = ['engine'=>'ddg-html', 'url'=>$url, 'len'=>strlen((string)$html),
                'why'=>searchBlockReason($html)];
    if (!$html) return [];

    if (class_exists('DOMDocument')) {
        return parseDdgHtmlDom($html, $n);
    }
    return parseDdgHtmlRegex($html, $n);
}

function parseDdgHtmlDom($html, $n) {
    $results = [];
    libxml_use_internal_errors(true);
    $doc = new DOMDocument();
    $doc->loadHTML('<?xml encoding="UTF-8">' . $html);
    libxml_clear_errors();
    $xpath    = new DOMXPath($doc);
    $links    = $xpath->query("//a[contains(@class,'result__a')]");
    $snippets = $xpath->query("//a[contains(@class,'result__snippet')]");

    if ($links) {
        $i = 0;
        foreach ($links as $a) {
            if ($i >= $n) break;
            $title = trim(preg_replace('/\s+/', ' ', $a->textContent));
            $href  = $a->getAttribute('href');
            if (preg_match('#uddg=([^&]+)#', $href, $m)) $href = urldecode($m[1]);
            if (strpos($href, '//') === 0) $href = 'https:' . $href;
            $sn = '';
            if ($snippets && $snippets->item($i)) {
                $sn = trim(preg_replace('/\s+/', ' ', $snippets->item($i)->textContent));
            }
            if ($title && $href && stripos($href, 'duckduckgo.com') === false) {
                $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>$sn];
                $i++;
            }
        }
    }
    return $results;
}

function parseDdgHtmlRegex($html, $n) {
    $results = [];
    // Result link: <a class="...result__a..." href="...">TITLE</a>
    if (!preg_match_all('#<a\s[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>#is', $html, $linkMatches, PREG_SET_ORDER)) {
        return [];
    }
    // Result snippet: <a class="...result__snippet...">SNIPPET</a>
    preg_match_all('#<a\s[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>#is', $html, $snipMatches);

    foreach ($linkMatches as $i => $m) {
        if (count($results) >= $n) break;
        $href = html_entity_decode($m[1], ENT_QUOTES, 'UTF-8');
        if (preg_match('#uddg=([^&]+)#', $href, $u)) $href = urldecode($u[1]);
        if (strpos($href, '//') === 0) $href = 'https:' . $href;
        if (stripos($href, 'duckduckgo.com') !== false) continue;
        $title = trim(preg_replace('/\s+/', ' ',
            html_entity_decode(strip_tags($m[2]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
        if (!$title) continue;
        $sn = '';
        if (isset($snipMatches[1][$i])) {
            $sn = trim(preg_replace('/\s+/', ' ',
                html_entity_decode(strip_tags($snipMatches[1][$i]), ENT_QUOTES | ENT_HTML5, 'UTF-8')));
        }
        $results[] = ['title'=>$title, 'url'=>$href, 'snippet'=>$sn];
    }
    return $results;
}

// Generic curl helper — returns response body or null on failure
function fetchHtml($url, $ua, $method = 'GET', $postData = '') {
    $hdrs = [
        '-H', 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9',
        '-H', 'Accept-Language: en-US,en;q=0.9',
    ];
    if ($method === 'POST') {
        $cmd = sprintf(
            'curl -sL --max-time 12 -A %s %s -d %s %s 2>/dev/null',
            escapeshellarg($ua),
            implode(' ', array_map('escapeshellarg', $hdrs)),
            escapeshellarg($postData),
            escapeshellarg($url)
        );
    } else {
        $cmd = sprintf(
            'curl -sL --max-time 12 -A %s %s %s 2>/dev/null',
            escapeshellarg($ua),
            implode(' ', array_map('escapeshellarg', $hdrs)),
            escapeshellarg($url)
        );
    }
    $body = (string)shell_exec($cmd);
    if (!$body || strlen($body) < 200) return null;
    return $body;
}
