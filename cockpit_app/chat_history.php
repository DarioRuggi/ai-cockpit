<?php
// =============================================================================
// chat_history.php — selective chat history for the HTTP (Workers) path.
//
// The PHP twin of agent_loop.sh's needs_history / history_terms /
// history_select_ids / render_history_inline. The queue loops give CLI agents
// their history; Workers (REST providers called straight from workers.php)
// had none — and left none, their turns were never written to the chat file.
//
// Same rules as the loop so the two paths judge a prompt identically:
//   1. strip the client's style wrapper ("[CHAT MODE] ...") and "(Now: ...)"
//   2. gate: short prompt / continuation opener / back-reference → needs it
//   3. FTS5 MATCH on the content words (porter-stemmed index) → top pairs,
//      plus the last two pairs, id order, capped at CHAT_HISTORY_MAX_PAIRS
//   4. inline only — a REST worker cannot read files, so no pointer mode.
// Reads from the derived index after a reconcile; never parses the JSON at
// dispatch time except to rebuild the index.
// =============================================================================
require_once __DIR__ . '/chat_index.php';

const CHAT_HISTORY_MAX_PAIRS = 6;
const CHAT_HISTORY_RELEVANT  = 4;

/** The user's own words: drop the "[... MODE] ..." style line and the timestamp. */
function chat_history_user_text(string $p): string {
    $p = preg_replace('/\A\[[A-Z][A-Z ]* MODE\] [^\n]*\n*/', '', $p);
    $p = preg_replace('/\(Now: [0-9]{4}-[0-9]{2}-[0-9]{2}[^)]*\)/', '', $p);
    return trim((string)$p);
}

/** Why history is needed, or null when the prompt is self-contained. */
function chat_history_needs(string $prompt): ?string {
    $p = chat_history_user_text($prompt);
    $lower = mb_strtolower($p);
    $words = preg_match_all('/\S+/u', $p);
    if ($words < 8) return "short prompt, $words words";
    if (preg_match('/^\s*(and|but|so|then|ok|okay|yes|no|also|now|what about|how about|instead)\b/u', $lower)) return 'continuation opener';
    $back = 'those|these|previous|previously|earlier|above|before|last|again|continue|same|too|refer|recap|summari[sz]e|rewrite|redo|retry|repeat|other|another|instead'
          . '|the (file|code|function|script|output|answer|result|plan|list|error|bug|test|version)|you (said|wrote|mentioned|suggested|gave)|as (we|you|i) (said|discussed)'
          . '|this (chat|conversation|thread|session|discussion)|the (chat|conversation|thread|session|discussion)|(did|have|were|are|do) we|we (talked|discussed|said|did|were|agreed)'
          . '|so far|topic|remind|where were we|catch me up|history|summary';
    if (preg_match('/\b(' . $back . ')\b/u', $lower)) return 'back-reference';
    return null;
}

/** Content words for the FTS query — same list as the loop's history_terms. */
function chat_history_terms(string $prompt): array {
    static $stop = null;
    if ($stop === null) $stop = array_flip(explode('|',
        'this|that|what|with|from|have|were|does|about|there|their|then|than|they|them|these|those|which|would|could|should|please|tell|show|give|make|want|need|like|just|also|some|more|most|very|into|over|only|your|when|where|will|been|being|here|main|topic|chat|conversation|thread|session|earlier|before|again|same|said|talk|talked|discussed|write|explain|question|answer|really|thing|things|something|anything|everything|know|think|time|last|next|first|still|each|other|another|much|many|such|done|doing|using|used'));
    $t = strtolower(chat_history_user_text($prompt));
    $t = preg_replace('/[^a-z0-9]+/', ' ', $t);
    $out = [];
    foreach (preg_split('/\s+/', trim((string)$t)) as $w) {
        if (!preg_match('/^[a-z][a-z0-9]{3,}$/', $w) || isset($stop[$w]) || isset($out[$w])) continue;
        $out[$w] = true;
        if (count($out) >= 12) break;
    }
    return array_keys($out);
}

/**
 * Reconcile the index with the JSON (row count vs exchange count); rebuild
 * this chat's rows from the JSON when they differ. Mirrors chat_index_sync in
 * the loop. Call while holding the chat's .lock or accept a rare double
 * rebuild. Returns false when the JSON cannot be parsed even after healing.
 */
function chat_index_sync(string $chatFile): bool {
    if (!is_readable($chatFile)) return false;
    $db = chat_index_open($chatFile);
    if (!$db) return false;
    $raw = (string)file_get_contents($chatFile);
    $raw = preg_replace('/("duration_s":\s*)\.(\d)/', '${1}0.$2', $raw);   // ".9" durations from old loops: jq-valid, PHP-invalid
    $data = json_decode($raw, true);
    if (!is_array($data)) {
        // Old loop versions wrote raw control characters into strings.
        $len = strlen($raw); $fixed = ''; $inStr = false;
        for ($i = 0; $i < $len; $i++) {
            $c = $raw[$i];
            if ($c === '"' && ($i === 0 || $raw[$i-1] !== '\\')) { $inStr = !$inStr; $fixed .= $c; continue; }
            if ($inStr && ord($c) < 0x20 && $c !== "\t") $fixed .= $c === "\n" ? '\\n' : ($c === "\r" ? '\\r' : sprintf('\\u%04x', ord($c)));
            else $fixed .= $c;
        }
        $data = json_decode($fixed, true);
    }
    $exs = is_array($data) ? ($data['exchanges'] ?? null) : null;
    if (!is_array($exs)) { $db->close(); return false; }
    try {
        $st = $db->prepare('SELECT count(*) AS n FROM ex WHERE chat = :c');
        $st->bindValue(':c', $chatFile, SQLITE3_TEXT);
        $n = (int)($st->execute()->fetchArray(SQLITE3_ASSOC)['n'] ?? 0);
        if ($n === count($exs)) { $db->close(); return true; }
        $db->exec('BEGIN');
        $d = $db->prepare('DELETE FROM ex WHERE chat = :c'); $d->bindValue(':c', $chatFile, SQLITE3_TEXT); $d->execute();
        $ins = $db->prepare('INSERT INTO ex(chat,id,role,agent,ts,body) VALUES(:c,:i,:r,:a,:t,:b)');
        foreach ($exs as $k => $e) {
            $ins->reset();
            $ins->bindValue(':c', $chatFile, SQLITE3_TEXT);
            $ins->bindValue(':i', (int)($e['id'] ?? $k + 1), SQLITE3_INTEGER);
            $ins->bindValue(':r', (string)($e['role'] ?? ''), SQLITE3_TEXT);
            $ins->bindValue(':a', (string)($e['agent'] ?? ''), SQLITE3_TEXT);
            $ins->bindValue(':t', (string)($e['timestamp'] ?? $e['ts'] ?? ''), SQLITE3_TEXT);
            $ins->bindValue(':b', chat_index_norm((string)($e['text'] ?? '')), SQLITE3_TEXT);
            $ins->execute();
        }
        $db->exec('COMMIT');
        error_log('chat_history: index rebuilt ' . basename($chatFile) . " ($n -> " . count($exs) . ' rows)');
        $db->close();
        return true;
    } catch (Throwable $e) { try { @$db->exec('ROLLBACK'); $db->close(); } catch (Throwable $e2) {} return false; }
}

/** ids to send: top-ranked pairs by MATCH ∪ last two pairs, id order, capped. */
function chat_history_select_ids(string $chatFile, string $prompt): array {
    $db = chat_index_open($chatFile);
    if (!$db) return [];
    $ids = [];
    try {
        $terms = chat_history_terms($prompt);
        if ($terms) {
            $q = implode(' OR ', array_map(fn($t) => '"' . $t . '"', $terms));
            $st = $db->prepare('SELECT id FROM ex WHERE chat = :c AND ex MATCH :q ORDER BY bm25(ex) LIMIT :n');
            $st->bindValue(':c', $chatFile, SQLITE3_TEXT);
            $st->bindValue(':q', $q, SQLITE3_TEXT);
            $st->bindValue(':n', CHAT_HISTORY_RELEVANT * 2, SQLITE3_INTEGER);
            $res = $st->execute(); $top = [];
            while ($res && ($r = $res->fetchArray(SQLITE3_NUM))) {
                $i = (int)$r[0];                       // expand to the pair
                if ($i % 2 === 1) { $top[] = $i; $top[] = $i + 1; } else { $top[] = $i - 1; $top[] = $i; }
                if (count($top) >= CHAT_HISTORY_RELEVANT * 2) break;
            }
            $ids = $top;
        }
        $st = $db->prepare('SELECT id FROM ex WHERE chat = :c ORDER BY id DESC LIMIT 4');
        $st->bindValue(':c', $chatFile, SQLITE3_TEXT);
        $res = $st->execute();
        while ($res && ($r = $res->fetchArray(SQLITE3_NUM))) $ids[] = (int)$r[0];
        $db->close();
    } catch (Throwable $e) { try { $db->close(); } catch (Throwable $e2) {} return []; }
    $ids = array_values(array_unique(array_filter($ids, fn($i) => $i > 0)));
    sort($ids, SORT_NUMERIC);
    $max = CHAT_HISTORY_MAX_PAIRS * 2;
    if (count($ids) > $max) $ids = array_slice($ids, -$max);   // the last pairs win
    return $ids;
}

/** Framed inline transcript of the given ids (same header the loop uses). */
function chat_history_inline(string $chatFile, array $ids): string {
    if (!$ids) return '';
    $db = chat_index_open($chatFile);
    if (!$db) return '';
    $out = "[Transcript of THIS chat so far -- the AI Cockpit chat the user is typing in. You are one of its agents. When the user says \"this chat\", \"earlier\", \"before\", \"we\", they mean this transcript, not a session of your own. Only the exchanges relevant to the new message are shown; gaps are omitted turns.]\n";
    try {
        $in = implode(',', array_map('intval', $ids));
        $st = $db->prepare("SELECT id, role, agent, body FROM ex WHERE chat = :c AND id IN ($in) ORDER BY id");
        $st->bindValue(':c', $chatFile, SQLITE3_TEXT);
        $res = $st->execute();
        while ($res && ($r = $res->fetchArray(SQLITE3_ASSOC))) {
            $who  = $r['role'] === 'user' ? 'User' : ucfirst((string)($r['agent'] ?: 'agent'));
            $body = str_replace('\n', "\n", (string)$r['body']);
            if (mb_strlen($body) > 1500) $body = mb_substr($body, 0, 1500) . '... [truncated]';
            $out .= '#' . $r['id'] . ' ' . $who . ': ' . $body . "\n\n";
        }
        $db->close();
    } catch (Throwable $e) { try { $db->close(); } catch (Throwable $e2) {} return ''; }
    return $out . "[End of transcript. The new user message follows.]\n\n";
}

/**
 * The one entry point: '' when the prompt is self-contained or nothing usable
 * exists, else the framed block to put in front of the prompt. Logs the
 * decision the way the loop does.
 */
function chat_history_block(string $chatFile, string $prompt, string $who = 'WORKERS'): string {
    $why = chat_history_needs($prompt);
    if ($why === null) { error_log("[$who] history: skipped (self-contained prompt)"); return ''; }
    if (!is_readable($chatFile) || !chat_index_available()) { error_log("[$who] history: none (no chat file or no index)"); return ''; }
    chat_index_sync($chatFile);
    $ids = chat_history_select_ids($chatFile, $prompt);
    if (!$ids) { error_log("[$who] history: none (index empty) — needed: $why"); return ''; }
    error_log("[$who] history: inline ids=" . implode(',', $ids) . " ($why)");
    return chat_history_inline($chatFile, $ids);
}
