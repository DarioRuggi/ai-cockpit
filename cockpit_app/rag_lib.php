<?php
require_once __DIR__ . '/text_clean.php';   // book_clean_text() on the read path
// =============================================================================
// rag_lib.php — push-RAG: the context the "RAG Search" capability promises.
//
// Until 2026-09-22 that capability toggled nothing: every agent was handed the
// %%LIB/SNIP/SRC%% markers whether it was on or off, and nothing was ever
// injected on its own. This library is the missing half — when the capability is
// enabled, the top matching snippets / library notes / sources for the person's
// prompt are prepended to the dispatch, with their titles reported back so the
// chat can say what was added.
//
// Deliberately keyword-based (same scoring family as library.php's search), not
// embeddings: it must run in milliseconds inside bridge.php on any machine, with
// no model loaded. Deep/semantic search stays a separate, explicit action.
//
// Used by: bridge.php (every prompt), workers.php (REST turns).
// =============================================================================

if (!function_exists('rag_enabled')) {

/** Is the rag_search capability on? Mirrors capabilities.php: a builtin is on
 *  unless the global override map says otherwise. */
function rag_enabled(string $CD): bool {
    $f = rtrim($CD, '/') . '/capabilities/global_caps.json';
    $map = is_readable($f) ? (json_decode((string)file_get_contents($f), true) ?: []) : [];
    if (array_key_exists('rag_search', $map)) return (bool)$map['rag_search'];
    return true;   // builtin default
}

/**
 * Is this local model a sensible thing to hand retrieved prose to?
 *
 * Measured 2026-09-29 on one retrieval of three book chapters: qwen2.5-coder:1.5b
 * answered "a small city in the city of Malenkigrad" and emitted no receipts line,
 * while llama3.2:3b answered from the text and cited it. Card 3 shipped pointing at
 * the coder model, so every Library-backed question went to the one model in the
 * list least able to answer it — and it reads as "local models are useless" rather
 * than "wrong tool, a quarter of the floor size".
 *
 * Returns null when the model is fine, else ['kind','why'] for the UI to explain.
 * Name-based on purpose: it must cost nothing, and these names are conventions the
 * whole ecosystem follows.
 */
function rag_model_fit(string $model): ?array {
    $m = mb_strtolower(trim($model));
    if ($m === '') return null;
    if (preg_match('/embed|bge-|gte-|nomic/', $m)) {
        return ['kind' => 'embedding',
                'why'  => 'an embedding model — it makes vectors, it does not answer questions'];
    }
    if (preg_match('/coder|starcoder|codellama|code-|deepseek-coder/', $m)) {
        return ['kind' => 'coder',
                'why'  => 'tuned for writing code, not for reading prose'];
    }
    // Parameter count from the conventional tag suffix (":1.5b", ":7b").
    if (preg_match('/:(\d+(?:\.\d+)?)\s*b\b/', $m, $mm) && (float)$mm[1] < 3.0) {
        return ['kind' => 'tiny',
                'why'  => $mm[1] . 'B is below the 3B floor measured for grounded answers'];
    }
    return null;
}

/** Words worth matching on: 4+ chars, no stopwords, max 12 of them. */
function rag_terms(string $prompt): array {
    $stop = ['this','that','with','from','into','your','ours','their','about','which','while','where','when','what',
             'have','has','had','will','would','could','should','please','make','made','need','want','using','use',
             'file','files','code','the','and','for','are','was','were','you','our','can','how','why','who','all',
             'chat','mode','answer','reply','write','give','show','tell','then','than','also','just','only','like',
             // REQUEST words: what the person is asking FOR, never what they are asking ABOUT.
             // They matter more than they look. The relevance floor below treats a term that
             // appears nowhere in the library as "a subject you have nothing on", and "examples"
             // or "chapters" appear in no novel — so "explain Malenkigrad, with examples" scored
             // as a question about something absent and was refused (measured 2026-10-01: 36%
             // coverage on a question whose real subject matched perfectly). Corpus statistics
             // cannot tell "aldebaran" from "examples"; both are in zero chapters. A word list can.
             'explain','explained','examples','example','summarize','summarise','summary','describe',
             'details','detail','everything','anything','something','nothing','chapter','chapters',
             'happens','happen','happened','says','said','named','called','compare','between',
             'difference','differences','mean','means','meaning','does','doing','done','know','tell',
             'take','takes','look','looks','find','help','kind','sort','type','types','thing','things',
             'good','best','better','here','there','them','they','some','more','most','much','many',
             'very','really','such','each','every','other','another','after','before','during','without',
             'within','whether','however','because','through','around','under','over','again','still',
             'even','ever','never','always','often','maybe','might','must','shall','first','second',
             'third','last','next','book','books','page','pages','text','story','part','parts',
             'section','sections','according','been','being','right','left','want','wants','able'];
    // Order matters. Dropping the style prefix uses [^\n]* to mean "the rest of
    // THAT line" — so it has to run while the newlines are still there. Collapsing
    // whitespace first turned the whole prompt into one line, and the guard then
    // ate the question along with the prefix: every prompt the UI sends carries a
    // Mode/Style prefix, so rag_terms returned NOTHING and push-RAG silently never
    // fired from the interface at all (found 2026-09-29, by asking Claude about a
    // book that was sitting in the Library).
    $p = strip_tags($prompt);
    $p = preg_replace('/\[[a-z ]+ mode\][^\n]*/i', ' ', $p);   // drop our own style prefix
    $p = preg_replace('/\(now:[^\n)]*\)/i', ' ', $p);          // and the timestamp line we append
    $p = mb_strtolower(preg_replace('/\s+/', ' ', $p));
    $words = preg_split('/[^\p{L}\p{N}_\-\.]+/u', $p, -1, PREG_SPLIT_NO_EMPTY) ?: [];
    $out = [];
    foreach ($words as $w) {
        if (mb_strlen($w) < 4) continue;
        if (in_array($w, $stop, true)) continue;
        $out[$w] = true;
        if (count($out) >= 12) break;
    }
    return array_keys($out);
}

/**
 * [score, how many distinct terms matched].
 *
 * The count matters as much as the score. A rare name — exactly the thing worth
 * retrieving — appears once and scores 8, while a common word hammered three
 * times scores 24, so "who is Zephyrine Kott" found nothing while a vaguer
 * question found plenty. Coverage of the question is judged separately below.
 */
function rag_score(array $terms, string $title, string $tags, string $body): array {
    if (!$terms) return [0, 0];
    $meta = mb_strtolower($title . ' ' . $tags);
    $body = mb_strtolower(mb_substr($body, 0, 40000));
    $score = 0; $matched = 0;
    foreach ($terms as $t) {
        if (str_contains($meta, $t)) { $score += 25; $matched++; continue; }
        if ($body === '') continue;
        // How OFTEN, not merely whether. A note titled after its subject scores on
        // the title; a book chapter is called "Chapter 6" and every match is in
        // the prose, so a single flat 8 points left real matches under the
        // threshold — filing a book in the Library found nothing at all until
        // this counted repetition. Capped at three so one hammered word cannot
        // outrank a chapter that actually covers several of the terms.
        $n = substr_count($body, $t);
        if ($n > 0) { $score += 8 * min($n, 3); $matched++; }
    }
    return [$score, $matched];
}

/** Collect candidates from the per-user store (and the project's own index). */
function rag_candidates(string $CD, string $projectsRoot, string $project): array {
    $items = [];
    $idxFiles = [rtrim($CD, '/') . '/library_index.json'];
    if ($project !== '' && $project !== '_standalone') {
        $idxFiles[] = rtrim($projectsRoot, '/') . '/' . $project . '/library_index.json';
    }
    foreach ($idxFiles as $idxF) {
        $idx = is_readable($idxF) ? (json_decode((string)file_get_contents($idxF), true) ?: []) : [];
        foreach (['snippets', 'library', 'sources'] as $kind) {
            foreach ((array)($idx[$kind] ?? []) as $e) {
                if (!is_array($e)) continue;
                $body = (string)($e['content'] ?? '');
                if ($body === '' && !empty($e['file_path']) && is_readable($e['file_path'])) {
                    $body = (string)@file_get_contents($e['file_path'], false, null, 0, 40000);
                } elseif ($body === '' && !empty($e['id'])) {
                    $tf = rtrim($CD, '/') . '/library_text/' . $e['id'] . '.txt';
                    // Clean on READ, not only at ingest. Books ingested before the
                    // cleaner existed are still on disk with their calibre markup,
                    // and they were spending ~22% of every injected passage on
                    // {.calibre3} spans. book_clean_text() is idempotent, so this
                    // is free for anything already clean.
                    if (is_readable($tf)) $body = book_clean_text((string)@file_get_contents($tf, false, null, 0, 40000));
                }
                $items[] = ['kind' => $kind, 'title' => (string)($e['title'] ?? $e['name'] ?? '(untitled)'),
                            'tags' => implode(' ', (array)($e['tags'] ?? [])), 'body' => $body];
            }
        }
    }
    // Accumulator stores (one JSON per entry)
    foreach ([['snippets', 'snippets'], ['knowledge', 'library']] as [$dir, $kind]) {
        foreach ((glob(rtrim($CD, '/') . '/' . $dir . '/*.json') ?: []) as $f) {
            $j = json_decode((string)@file_get_contents($f), true);
            if (!is_array($j)) continue;
            $items[] = ['kind' => $kind, 'title' => (string)($j['name'] ?? '(untitled)'),
                        'tags' => (string)($j['purpose'] ?? ''),
                        'body' => (string)($j['source_code'] ?? $j['content'] ?? '')];
        }
    }
    return $items;
}

/**
 * The passage worth sending, not merely the opening of the item.
 *
 * Cutting from the start is fine for a short note and wrong for a chapter: a
 * book filed by Bookshelf retrieved the correct chapter and still answered
 * nothing, because the sentence that mattered was at the end and the first 2400
 * characters went instead. This slides a window over the text and keeps the one
 * containing the most matches, with an ellipsis where text was dropped.
 */
function rag_window(string $body, array $terms, int $per): string {
    $low = mb_strtolower($body);
    $len = mb_strlen($body);
    $best = 0; $bestScore = -1;
    // Step in halves of the window: fine enough to land on a dense passage,
    // coarse enough that a long chapter costs a handful of counts.
    $step = max(200, (int)floor($per / 2));
    for ($start = 0; $start < $len; $start += $step) {
        $chunk = mb_substr($low, $start, $per);
        $score = 0;
        foreach ($terms as $t) $score += substr_count($chunk, $t);
        if ($score > $bestScore) { $bestScore = $score; $best = $start; }
        if ($start + $per >= $len) break;
    }
    // Start on a paragraph or sentence boundary when one is close by, so the
    // excerpt does not open mid-word.
    if ($best > 0) {
        $head = mb_substr($body, max(0, $best - 200), 200);
        $cut = max((int)mb_strrpos($head, "\n\n"), (int)mb_strrpos($head, '. '));
        if ($cut > 0) $best = max(0, $best - 200 + $cut + 1);
    }
    $out = mb_substr($body, $best, $per);
    if ($best > 0)             $out = "[…] " . ltrim($out);
    if ($best + $per < $len)   $out = rtrim($out) . " […]";
    return $out;
}

/**
 * The relevance floor: how much of the QUESTION must one passage cover?
 *
 * The problem it exists for: ranking is not judging. Scoring always has a best
 * item, so a library with nothing on the subject still hands over its closest
 * match, and the model uses it. Measured 2026-10-01 in production: a question
 * about an astrology dictionary was answered with chapters of a science-fiction
 * novel, because `first`, `does`, `mean`, `right` and `book` appear in nearly every
 * chapter and the old "most of the terms matched" test let them carry it — 58 of
 * 59 chapters were eligible. The same arithmetic offered 33 chapters for a question
 * about Free Pascal in a library that holds no Pascal.
 *
 * The rule, derived and verified in docs/shelf_pilot.md and re-fitted here:
 *
 *   weight(term) = ln((N + 1) / (df + 0.5))      df = items containing the term
 *   coverage(item) = sum of weight(term) matched in the item / sum of weight(all terms)
 *   an item is eligible only if coverage >= 0.50
 *
 * A term in every chapter weighs nothing; a term in none weighs the most. So an
 * item has to cover the words the corpus is NOT saturated with, which is what a
 * question is actually about. Document frequency is MEASURED against this
 * library, not taken from a stopword list: "logging" is noise on a programming
 * shelf and a subject on a philosophy one.
 *
 * Fitted on the real library (59 items, 11 questions in the exact format the app
 * sends): every genuine question reached 100% coverage; every question about
 * something absent topped out at 39% or lower. 0.50 sits 50 points above the
 * first and 11 below the second. Request words ("explain", "examples", "chapters")
 * had to be added to rag_terms' stop list first: they appear in no novel, so the
 * floor read them as a subject the library lacks, and refused a question whose real
 * subject matched perfectly.
 *
 * It is deliberately NOT a percentage of the corpus. The shelf pilot's "under
 * 0.25% of pages" is meaningful at 581,000 pages and means "exactly zero" at 59,
 * so the weight is smoothed IDF, which behaves the same at any size. Below
 * RAG_FLOOR_MIN_ITEMS the library is too small to measure what is common in it at
 * all, and the floor stands down rather than pretend: with a handful of notes a
 * wrong injection is bounded by the item limit anyway.
 *
 * Known limitation, stated rather than hidden: the request-word list is English.
 * For another language the floor is STRICTER, not looser — absent request words
 * lower coverage — so it fails toward injecting nothing, never toward the wrong book.
 *
 * Set COCKPIT_RAG_FLOOR=0 to switch it off, or to another fraction to tune it.
 */
function rag_floor(): float {
    $e = getenv('COCKPIT_RAG_FLOOR');
    if ($e !== false && $e !== '' && is_numeric($e)) return max(0.0, min(1.0, (float)$e));
    return 0.50;
}
function rag_floor_min_items(): int { return 12; }

/** ln((N+1)/(df+0.5)) per term, over the lower-cased candidate texts. */
function rag_term_weights(array $terms, array $lows): array {
    $N = count($lows); $w = [];
    foreach ($terms as $t) {
        $df = 0;
        foreach ($lows as $l) if (str_contains($l, $t)) $df++;
        $w[$t] = log(($N + 1) / ($df + 0.5));
    }
    return $w;
}

/**
 * The block to prepend, or ''. Returns [block, titles[]].
 * $budget caps the injected characters so a book cannot eat the context window.
 */
function rag_context(string $prompt, string $CD, string $projectsRoot, string $project,
                     int $limit = 3, int $budget = 2400): array {
    // [block, titles, info]. The third element is new and optional for callers
    // that destructure two: it says how many items the relevance floor turned
    // away, so the chat can explain an empty result instead of leaving it silent.
    $info = ['declined' => 0, 'best_declined' => 0.0, 'floor' => 0.0, 'items' => 0];
    if (!rag_enabled($CD)) return ['', [], $info];
    $terms = rag_terms($prompt);
    if (!$terms) return ['', [], $info];
    $hits = [];
    // Accept on EITHER strength or coverage: a strong score, or most of the
    // question's distinctive words appearing at all. Coverage is what finds a
    // person by name in a book chapter; score is what ranks a well-titled note
    // above a passing mention.
    $need = max(2, (int)ceil(count($terms) / 2));
    $cands = rag_candidates($CD, $projectsRoot, $project);
    $info['items'] = count($cands);

    // The relevance floor (see rag_floor). Weights are measured over THESE
    // candidates, once, before any item is judged.
    $floor = rag_floor(); $lows = []; $W = []; $totW = 0.0;
    $floorOn = $floor > 0 && count($cands) >= rag_floor_min_items();
    if ($floorOn) {
        foreach ($cands as $i => $it)
            $lows[$i] = mb_strtolower($it['title'] . ' ' . $it['tags'] . ' ' . mb_substr($it['body'], 0, 40000));
        $W = rag_term_weights($terms, $lows);
        $totW = array_sum($W);
        $info['floor'] = $floor;
    }

    foreach ($cands as $i => $it) {
        [$sc, $matched] = rag_score($terms, $it['title'], $it['tags'], $it['body']);
        if ($sc >= 25 || ($matched >= $need && $sc > 0) || (count($terms) === 1 && $sc > 0)) {
            $cov = 1.0;
            if ($floorOn && $totW > 0) {
                $m = 0.0;
                foreach ($terms as $t) if (str_contains($lows[$i], $t)) $m += $W[$t];
                $cov = $m / $totW;
                if ($cov < $floor) {            // matched words, but not the ones that matter
                    $info['declined']++;
                    if ($cov > $info['best_declined']) $info['best_declined'] = $cov;
                    continue;
                }
            }
            // ties broken by how much of the question is covered
            $it['score'] = $sc + $matched * 4 + (int)round($cov * 20);
            $hits[] = $it;
        }
    }
    if (!$hits) return ['', [], $info];
    usort($hits, fn($a, $b) => $b['score'] <=> $a['score']);
    $hits = array_slice($hits, 0, max(1, $limit));
    $per = (int)max(400, floor($budget / count($hits)));
    $out = "[Cockpit knowledge — top matches from this machine's library for the request below]\n";
    $titles = [];
    foreach ($hits as $h) {
        $body = trim(preg_replace('/\n{3,}/', "\n\n", (string)$h['body']));
        if ($body === '') continue;
        if (mb_strlen($body) > $per) $body = rag_window($body, $terms, $per);
        $out .= "\n--- " . strtoupper($h['kind']) . ': ' . $h['title'] . " ---\n" . $body . "\n";
        $titles[] = $h['title'];
    }
    if (!$titles) return ['', [], $info];
    // Receipts: ask for the items actually used, on a line the client can lift out
    // and turn into links back to the library. Injected context is otherwise
    // unverifiable — the person sees a confident answer and has no way to tell
    // which note it leaned on, or whether it used any of them at all.
    $out .= "\n[End Cockpit knowledge. Use it when relevant; say so if it does not apply.]"
          . "\n[If you used any of these items, end your reply with a single line:"
          . "\n SOURCES: " . implode(' | ', $titles) . "  ← keep only the ones you actually used.]";
    return [$out, $titles, $info];
}

}   // function_exists guard
