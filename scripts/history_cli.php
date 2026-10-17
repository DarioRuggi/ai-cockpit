<?php
// =============================================================================
// history_cli.php — the chat-history half of agent_loop.sh, as PHP.
//
// agent_loop.sh decides whether a prompt needs the earlier turns of the chat, picks the relevant ones from a
// derived SQLite/FTS5 index, renders them (inline transcript, pointer block, or a JSON messages array) and keeps
// that index in step with the chat JSON. It did all of it in Bash with `sqlite3`, `jq`, `awk`, `sed` and
// `python3` (the zero-Python policy's last holdout in the loop). This is the same logic with none of them.
//
//   php history_cli.php needs --agent UC                         prompt on stdin; exit 0 = include history, 1 = skip
//   php history_cli.php build --chat F --format text|json --mode inline|pointer --agent UC     prompt on stdin
//   php history_cli.php sync  --chat F --agent UC                reconcile the index with the chat JSON
//   php history_cli.php add   --chat F --id N --role R --agent A --ts T --text-file F
//   php history_cli.php append --chat F --project P --chat-name N --user-file F --agent-file F --model M --duration D
//                              --style S --mode M --agent A --supplier S --agent-uc UC
//        (append_to_chat: writes one user + one agent exchange into the chat JSON and the index; exit 3 = nothing was
//         written, the caller may use the Bash instead — any other non-zero status means it may have been)
//
// Exit 0/1 = answered (build returns 1 where the Bash does: a text request for a chat file that does not exist).
// Exit 2 = bad usage. Everything else is "answered": a missing index is not an error, it is the whole-tail
// fallback the Bash also has. The loop falls back to its own Bash only when this file cannot be run at all.
//
// THE BASH IS THE REFERENCE. Every rule below (the gate's word lists, the stop list, the SQL, the header text,
// which characters get escaped where) is copied from agent_loop.sh and checked against it, byte for byte, on
// real-format chat files by tests/history_parity.sh. Where the Bash has a quirk it is reproduced and marked.
//
// Environment (read the same way the loop reads it): COCKPIT_HISTORY=auto|always|never, MAX_HISTORY (default 6).
// =============================================================================

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

const HISTORY_RELEVANT = 4;                           // top-ranked pairs to pull by keyword (besides the last 2)
const FRAME_INLINE = '[Transcript of THIS chat so far -- the AI Cockpit chat the user is typing in. You are one of its agents. When the user says "this chat", "earlier", "before", "we", they mean this transcript, not your own CLI session. Only the exchanges relevant to the new message are shown; gaps are omitted turns.]';
const FRAME_TAIL   = '[Transcript of THIS chat so far -- the AI Cockpit chat the user is typing in. You are one of its agents. When the user says "this chat", "earlier", "before", "we", they mean this transcript, not your own CLI session.]';
const FRAME_END    = '[End of transcript. The new user message follows.]';

$MAX_HISTORY = (int)(getenv('MAX_HISTORY') ?: 6);
if ($MAX_HISTORY < 1) $MAX_HISTORY = 6;

function opt(string $name, string $def = ''): string {
    global $argv;
    for ($i = 2; $i < count($argv) - 1; $i++) if ($argv[$i] === $name) return $argv[$i + 1];
    return $def;
}
function stdin_all(): string { return (string)stream_get_contents(STDIN); }
function out(string $s): void { fwrite(STDOUT, $s); }
function err(string $s): void { fwrite(STDERR, $s); }

// ---- the prompt's own words ------------------------------------------------------------------------------
// sed -E '1{/^\[[A-Z][A-Z ]* MODE\] /d}' | sed -E 's/\(Now: ...\)//g'  — both work LINE BY LINE.
function user_text(string $p): string {
    $lines = explode("\n", $p);
    if (preg_match('/^\[[A-Z][A-Z ]* MODE\] /', $lines[0])) array_shift($lines);
    foreach ($lines as &$l) $l = preg_replace('/\(Now: [0-9]{4}-[0-9]{2}-[0-9]{2}[^)]*\)/', '', $l);
    return implode("\n", $lines);
}

// GNU wc -w in a UTF-8 locale (measured, coreutils 9.4): a word is a run of characters that are neither white space nor
// unprintable. Control characters, unassigned code points and bytes that are not UTF-8 are simply ignored (they neither
// start a word nor end one: "a<ctrl>b" is one word); white space is the ASCII set plus NBSP, the Ogham space, U+2000-200A,
// U+202F, U+205F, U+3000 and U+2060.
function wc_words(string $s): int {
    $s = (string)@iconv('UTF-8', 'UTF-8//IGNORE', $s);                       // drop bytes that are not UTF-8
    $s = (string)preg_replace('/(?![\t\n\x0b\x0c\r])[\p{Cc}\p{Cn}\p{Cs}\p{Zl}\p{Zp}\x{180E}]/u', '', $s);
    $parts = preg_split('/[ \t\n\x0b\x0c\r\x{00A0}\x{1680}\x{2000}-\x{200A}\x{202F}\x{205F}\x{3000}\x{2060}]+/u', $s, -1, PREG_SPLIT_NO_EMPTY);
    return $parts === false ? 0 : count($parts);
}

// ---- the gate ------------------------------------------------------------------------------------------------
function needs(string $prompt, string $uc): int {
    $p = rtrim(user_text($prompt), "\n");                     // $(...) strips trailing newlines
    switch (getenv('COCKPIT_HISTORY') ?: 'auto') {
        case 'always': out("[$uc] history: included (COCKPIT_HISTORY=always)\n"); return 0;
        case 'never':  out("[$uc] history: skipped (COCKPIT_HISTORY=never)\n");  return 1;
    }
    $lower = strtolower($p);                                   // tr 'A-Z' 'a-z': ASCII only
    $words = wc_words($p);                                    // wc -w
    if ($words < 8) { out("[$uc] history: included (short prompt, $words words)\n"); return 0; }
    // grep works per line: ^ anchors at the start of EVERY line of a multi-line prompt (the Bash does the same)
    $lines = explode("\n", $lower);
    $cont = '/^[ \t\r\f\v]*(?:and|but|so|then|ok|okay|yes|no|also|now|what about|how about|instead)\b/';
    foreach ($lines as $l) if (preg_match($cont, $l)) { out("[$uc] history: included (continuation opener)\n"); return 0; }
    $back = 'those|these|previous|previously|earlier|above|before|last|again|continue|same|too|refer|recap|summari[sz]e|rewrite|redo|retry|repeat|other|another|instead|the (?:file|code|function|script|output|answer|result|plan|list|error|bug|test|version)|you (?:said|wrote|mentioned|suggested|gave)|as (?:we|you|i) (?:said|discussed)|this (?:chat|conversation|thread|session|discussion)|the (?:chat|conversation|thread|session|discussion)|(?:did|have|were|are|do) we|we (?:talked|discussed|said|did|were|agreed)|so far|topic|remind|where were we|catch me up|history|summary';
    $re = '/(?<![A-Za-z0-9_])(?:' . $back . ')(?![A-Za-z0-9_])/';   // grep -w
    foreach ($lines as $l) if (preg_match($re, $l)) { out("[$uc] history: included (back-reference)\n"); return 0; }
    out("[$uc] history: skipped (self-contained prompt, $words words)\n");
    return 1;
}

// ---- FTS query -----------------------------------------------------------------------------------------------
function terms(string $prompt): string {
    static $stop = null;
    if ($stop === null) $stop = array_flip(explode('|', 'this|that|what|with|from|have|were|does|about|there|their|then|than|they|them|these|those|which|would|could|should|please|tell|show|give|make|want|need|like|just|also|some|more|most|very|into|over|only|your|when|where|will|been|being|here|main|topic|chat|conversation|thread|session|earlier|before|again|same|said|talk|talked|discussed|write|explain|question|answer|really|thing|things|something|anything|everything|know|think|time|last|next|first|still|each|other|another|much|many|such|does|done|doing|using|used'));
    $t = preg_replace('/[^a-z0-9\n]/', ' ', strtolower(user_text($prompt)));    // tr -c 'a-z0-9\n' ' ' works on bytes
    $seen = []; $keep = [];
    foreach (preg_split('/[ \n]+/', $t, -1, PREG_SPLIT_NO_EMPTY) as $w) {
        if (!preg_match('/^[a-z][a-z0-9]{3,}$/', $w) || isset($stop[$w]) || isset($seen[$w])) continue;
        $seen[$w] = true; $keep[] = '"' . $w . '"';
        if (count($keep) >= 12) break;                          // head -12
    }
    return implode(' OR ', $keep);
}

// ---- the index -------------------------------------------------------------------------------------------------
function db_path(string $chat): string { return dirname(dirname($chat)) . '/.chat_index.db'; }

function index_ready(): bool {
    static $ok = null;
    if ($ok !== null) return $ok;
    if (getenv('HISTORY_CLI_NO_INDEX')) return $ok = false;      // test hook: exercise the whole-tail fallbacks
    if (!class_exists('SQLite3')) return $ok = false;
    try { $m = new SQLite3(':memory:'); $ok = (bool)@$m->exec('CREATE VIRTUAL TABLE t USING fts5(x)'); $m->close(); }
    catch (Throwable $e) { $ok = false; }
    return $ok;
}

// Shared with Apache (www-data): SQLite creates 0644 files, which would lock the other writer out.
function share_files(string $db): void {
    $grp = @filegroup(dirname($db));
    foreach ([$db, "$db-wal", "$db-shm"] as $p) {
        if (!file_exists($p)) continue;
        @chmod($p, 0664);
        if ($grp !== false && @filegroup($p) !== $grp) @chgrp($p, $grp);
    }
}
function open_db(string $chat): ?SQLite3 {
    if (!index_ready()) return null;
    try {
        $path = db_path($chat);
        $db = new SQLite3($path);
        $db->busyTimeout(3000);                                   // sq() = sqlite3 -cmd '.timeout 3000'
        @$db->exec('PRAGMA journal_mode=WAL');
        @$db->exec('CREATE VIRTUAL TABLE IF NOT EXISTS ex USING fts5(chat UNINDEXED, id UNINDEXED, role UNINDEXED, agent UNINDEXED, ts UNINDEXED, body, tokenize="porter unicode61")');
        share_files($path);
        return $db;
    } catch (Throwable $e) { return null; }
}

// chat_index_extract: every exchange of a chat as [id, role, agent, ts, body]. json.loads first; when the file is
// not strict JSON (raw newlines from old loops) a lenient regex over the text. In the REGEX path values are
// kept exactly as written in the file (escapes like \" and א are NOT decoded) and a missing id is 0 —
// both are what the Python did, and both are why the index body can differ between the two writers.
function chat_rows(string $chat): array {
    $raw = is_readable($chat) ? (string)file_get_contents($chat) : '';
    $raw = mb_convert_encoding($raw, 'UTF-8', 'UTF-8');
    $rows = [];
    $d = json_decode($raw, true);
    if (is_array($d) && array_key_exists('exchanges', $d) && is_array($d['exchanges'])) {
        foreach ($d['exchanges'] as $i => $e) {
            if (!is_array($e)) continue;
            $text = $e['text'] ?? '';
            $rows[] = [(string)($e['id'] ?? ($i + 1)), (string)($e['role'] ?? ''), (string)($e['agent'] ?? ''),
                       (string)(($e['timestamp'] ?? '') ?: ($e['ts'] ?? '')), is_scalar($text) ? (string)$text : json_encode($text)];
        }
    } elseif (is_array($d)) {
        // valid JSON without an "exchanges" list: Python's d.get('exchanges', []) -> nothing
    } else {
        if (preg_match_all('/\{[^{}]*?"role"\s*:\s*"([^"]+)"[^{}]*?\}/s', $raw, $mm)) {
            foreach ($mm[0] as $blk) {
                $g = function (string $k) use ($blk) { return preg_match('/"' . $k . '"\s*:\s*"((?:[^"\\\\]|\\\\.)*)"/s', $blk, $m) ? $m[1] : ''; };
                $id = preg_match('/"id"\s*:\s*(\d+)/', $blk, $mi) ? (int)$mi[1] : 0;
                $rows[] = [(string)$id, $g('role'), $g('agent'), $g('timestamp'), $g('text')];
            }
        }
    }
    // the unit separator, tabs and newlines would break the row format: \x1f and \t -> space, newline -> literal \n
    foreach ($rows as &$r) $r[4] = str_replace("\n", '\\n', str_replace(["\x1f", "\t"], ' ', $r[4]));
    return $rows;
}

// Returns the log line when it rebuilt, '' otherwise (the caller decides where the line goes).
function sync(string $chat, string $uc): string {
    if (!index_ready()) return '';
    $db = open_db($chat);
    if (!$db) return '';
    $rows = chat_rows($chat);
    $nj = count($rows);
    $st = $db->prepare('SELECT count(*) FROM ex WHERE chat = :c'); $st->bindValue(':c', $chat, SQLITE3_TEXT);
    $nd = (int)($st->execute()->fetchArray(SQLITE3_NUM)[0] ?? 0);
    if ($nj === $nd) { $db->close(); return ''; }
    $db->exec('BEGIN');
    $d = $db->prepare('DELETE FROM ex WHERE chat = :c'); $d->bindValue(':c', $chat, SQLITE3_TEXT); $d->execute();
    $ins = $db->prepare('INSERT INTO ex(chat,id,role,agent,ts,body) VALUES(:c,:i,:r,:a,:t,:b)');
    foreach ($rows as $r) {
        $ins->reset();
        $ins->bindValue(':c', $chat, SQLITE3_TEXT); $ins->bindValue(':i', (int)($r[0] ?: 0), SQLITE3_INTEGER);
        $ins->bindValue(':r', $r[1], SQLITE3_TEXT); $ins->bindValue(':a', $r[2], SQLITE3_TEXT);
        $ins->bindValue(':t', $r[3], SQLITE3_TEXT); $ins->bindValue(':b', $r[4], SQLITE3_TEXT);
        $ins->execute();
    }
    $db->exec('COMMIT');
    $st = $db->prepare('SELECT count(*) FROM ex WHERE chat = :c'); $st->bindValue(':c', $chat, SQLITE3_TEXT);
    $now = (int)($st->execute()->fetchArray(SQLITE3_NUM)[0] ?? 0);
    $db->close();
    return "[$uc] chat index: rebuilt " . basename($chat) . " ($nd -> $now rows, json has $nj)\n";
}

// chat_index_add: the fast path after an append. The Bash normalises the body with
//   tr '\t' ' ' | sed ':a;N;$!ba;s/\n/\\n/g'
// i.e. tabs -> space, and the text's final newline (a line terminator for sed) is dropped before the rest become \n.
// Quirk kept: unlike the sync path it does NOT replace \x1f.
function add(string $chat, int $id, string $role, string $agent, string $ts, string $text): void {
    if (strncmp(basename($chat), 'chat__', 6) === 0) return;                // scratch chats stay out of history
    $db = open_db($chat);
    if (!$db) return;
    $body = str_replace("\t", ' ', $text);
    if (substr($body, -1) === "\n") $body = substr($body, 0, -1);
    $body = str_replace("\n", '\\n', $body);
    $st = $db->prepare('INSERT INTO ex(chat,id,role,agent,ts,body) VALUES(:c,:i,:r,:a,:t,:b)');
    $st->bindValue(':c', $chat, SQLITE3_TEXT); $st->bindValue(':i', $id, SQLITE3_INTEGER);
    $st->bindValue(':r', $role, SQLITE3_TEXT); $st->bindValue(':a', $agent, SQLITE3_TEXT);
    $st->bindValue(':t', $ts, SQLITE3_TEXT); $st->bindValue(':b', $body, SQLITE3_TEXT);
    @$st->execute();
    $db->close();
}


// ---- append_to_chat -------------------------------------------------------------------------------------------------
// The loop's way of saving a turn: two exchange objects inserted before the closing bracket of the "exchanges" array,
// under the chat's flock, with the derived index reconciled first and the two new rows added after. All of it was
// awk/sed/mktemp/bc in Bash; the layout of the file it writes is the contract other readers rely on.
//
// Quirks reproduced from the Bash (each one is tested):
//  * json_escape ends in `echo "$s"`, so a text that is exactly -n / -e / -E (or a mix like -ne) comes out EMPTY;
//  * only \ " \n \r \t are escaped; the other control bytes (0x00-0x08, 0x0b, 0x0c, 0x0e-0x1f) are deleted;
//  * the project and chat names, and the agent name, go into the file UNESCAPED;
//  * the next id is the number of LINES containing "role", plus one;
//  * the insertion looks for a line that is just ] or ], — and a project name that contains "role" makes the empty
//    array look non-empty (a comma is written first);
//  * an existing empty file stays empty; a file with no closing bracket line is rewritten unchanged but the two rows
//    are still added to the index.
function loop_json_escape(string $s): string {
    $s = str_replace(["\\", '"', "\n", "\r", "\t"], ["\\\\", '\\"', '\\n', '\\r', '\\t'], $s);
    $s = preg_replace('/[\x00-\x08\x0b\x0c\x0e-\x1f]/', '', $s);
    if (preg_match('/^-[neE]+$/', $s)) return '';                              // echo "$s" taking it for options
    return rtrim($s, "\n");
}
function cmd_subst(string $s): string {                                       // $(cat file): no NUL, no trailing newlines
    return rtrim(str_replace("\0", '', $s), "\n");
}
function dur_json(string $d): string {
    // [ -n "$DURATION" ] && bc says "$DURATION > 0" is 1  ->  the number, with a leading "." made "0."; else null
    if ($d === '' || !preg_match('/^[0-9]*\.?[0-9]*$/', $d) || $d === '.' || !preg_match('/[0-9]/', $d)) return 'null';
    if ((float)$d <= 0) return 'null';
    return preg_replace('/^\./', '0.', $d);
}
function append_chat(array $o): int {
    $chat = $o['chat'];
    $now = getenv('CHAT_CLI_NOW') ?: gmdate('Y-m-d\TH:i:s\Z');
    $userText = cmd_subst((string)@file_get_contents($o['user-file']));
    $agentText = cmd_subst((string)@file_get_contents($o['agent-file']));
    $userEsc = loop_json_escape($userText); $agentEsc = loop_json_escape($agentText); $modelEsc = loop_json_escape($o['model']);
    $agent = $o['agent'];
    $lk = @fopen($chat . '.lock', 'c');
    if (!$lk) return 3;                                                        // cannot lock: nothing has been touched
    flock($lk, LOCK_EX);
    $written = false;
    try {
        if (is_file($chat)) out(sync($chat, $o['agent-uc']));        // the Bash prints its 'index rebuilt' line on stdout here
        if (!is_file($chat)) {
            @mkdir(dirname($chat), 0777, true);
            $tpl = "{\n  \"schema_version\": 1,\n  \"project\": \"{$o['project']}\",\n  \"chat\": \"{$o['chat-name']}\",\n  \"created\": \"$now\",\n  \"updated\": \"$now\",\n  \"exchanges\": [\n  ]\n}\n";
            if (@file_put_contents($chat, $tpl) === false) return 3;
            @chmod($chat, 0664);
        }
        $content = (string)@file_get_contents($chat);
        $rawCount = 0;
        foreach (explode("\n", $content) as $l) if (strpos($l, '"role"') !== false) $rawCount++;
        $nextId = $rawCount + 1;
        $modelJson = $modelEsc !== '' ? '"' . $modelEsc . '"' : 'null';
        $durJson = dur_json($o['duration']);
        $new = "    {\n      \"id\": $nextId,\n      \"timestamp\": \"$now\",\n      \"role\": \"user\",\n      \"text\": \"$userEsc\"\n    },\n"
             . "    {\n      \"id\": " . ($nextId + 1) . ",\n      \"timestamp\": \"$now\",\n      \"role\": \"agent\",\n      \"agent\": \"$agent\",\n"
             . "      \"supplier\": \"" . loop_json_escape($o['supplier']) . "\",\n      \"model\": $modelJson,\n      \"duration_s\": $durJson,\n"
             . "      \"style\": \"" . loop_json_escape($o['style']) . "\",\n      \"mode\": \"" . loop_json_escape($o['mode']) . "\",\n      \"text\": \"$agentEsc\"\n    }";
        // heal: an empty array written on one line ("exchanges": [] or [],) is opened up so the insertion can find its bracket
        $ws = '[ \t\n\v\f\r]';
        $healed = [];
        foreach (explode("\n", $content) as $l) $healed[] = preg_replace('/"exchanges":' . $ws . '*\[\](' . $ws . '*,?)' . $ws . '*$/', "\"exchanges\": [\n  ]\$1", $l, 1);
        $healedLines = explode("\n", implode("\n", $healed));
        if (substr($content, -1) === "\n" && end($healedLines) === '') array_pop($healedLines);   // awk: no phantom last record
        if ($content === '') $healedLines = [];
        // the awk insertion
        $out = []; $done = false; $foundOpen = false; $hasItems = false;
        foreach ($healedLines as $l) {
            if (!$done && preg_match('/^' . $ws . '*\],?' . $ws . '*$/', $l)) {
                if ($foundOpen && !$hasItems) $out[] = $new;
                elseif ($foundOpen) { $out[] = ','; $out[] = $new; }
                $done = true;
            }
            $out[] = $l;
            if (strpos($l, '"exchanges"') !== false) $foundOpen = true;
            if (strpos($l, '"role"') !== false) $hasItems = true;
        }
        // the "updated" stamp, first occurrence on each line
        $text = '';
        foreach (explode("\n", implode("\n", $out)) as $l) $text .= preg_replace('/"updated":' . $ws . '*"[^"]*"/', '"updated": "' . $now . '"', $l, 1) . "\n";
        if ($out === []) $text = '';
        $tmp = $chat . '.tmp' . getmypid();
        if (@file_put_contents($tmp, $text) === false) return 3;
        if (!@rename($tmp, $chat)) { @unlink($tmp); return 3; }
        $written = true;                                                         // from here on the file HAS changed
        @chmod($chat, 0664);
        add($chat, $nextId, 'user', '', $now, $userText);
        add($chat, $nextId + 1, 'agent', $agent, $now, $agentText);
    } catch (Throwable $e) {
        return $written ? 0 : 3;
    } finally {
        flock($lk, LOCK_UN); fclose($lk);
    }
    return 0;
}
// ---- which exchanges ------------------------------------------------------------------------------------------
function select_ids(string $chat, string $prompt, int $maxHistory): array {
    $db = open_db($chat);
    if (!$db) return [];
    $q = terms($prompt);
    $top = [];
    if ($q !== '') {
        $st = $db->prepare('SELECT id FROM ex WHERE chat = :c AND ex MATCH :q ORDER BY bm25(ex) LIMIT ' . (HISTORY_RELEVANT * 2));
        $st->bindValue(':c', $chat, SQLITE3_TEXT); $st->bindValue(':q', $q, SQLITE3_TEXT);
        $res = @$st->execute();
        while ($res && ($r = $res->fetchArray(SQLITE3_NUM))) $top[] = (int)$r[0];
    }
    $st = $db->prepare('SELECT id FROM ex WHERE chat = :c ORDER BY id DESC LIMIT 4');
    $st->bindValue(':c', $chat, SQLITE3_TEXT);
    $last = []; $res = $st->execute();
    while ($res && ($r = $res->fetchArray(SQLITE3_NUM))) $last[] = (int)$r[0];
    $db->close();
    // every id becomes its pair: a user row (odd id) owns the next row, an agent row (even) the one before; head -n 8
    $pairs = [];
    foreach ($top as $i) { if ($i % 2 === 1) { $pairs[] = $i; $pairs[] = $i + 1; } else { $pairs[] = $i - 1; $pairs[] = $i; } }
    $pairs = array_slice($pairs, 0, HISTORY_RELEVANT * 2);
    $ids = array_values(array_unique(array_merge($pairs, $last)));
    sort($ids, SORT_NUMERIC);
    $max = $maxHistory * 2;
    if (count($ids) > $max) $ids = array_slice($ids, -$max);                 // the last pairs win
    return $ids;
}

function rows_for(string $chat, array $ids): array {
    $db = open_db($chat);
    if (!$db || !$ids) return [];
    $in = implode(',', array_map('intval', $ids));
    $st = $db->prepare("SELECT id, role, agent, body FROM ex WHERE chat = :c AND id IN ($in) ORDER BY id");
    $st->bindValue(':c', $chat, SQLITE3_TEXT);
    $rows = []; $res = $st->execute();
    while ($res && ($r = $res->fetchArray(SQLITE3_ASSOC))) $rows[] = $r;
    $db->close();
    return $rows;
}

function cap(string $s): string { return mb_strlen($s) > 1500 ? mb_substr($s, 0, 1500) . '... [truncated]' : $s; }
function ucfirst_mb(string $s): string { return $s === '' ? '' : mb_strtoupper(mb_substr($s, 0, 1)) . mb_substr($s, 1); }

// ---- renderers --------------------------------------------------------------------------------------------------
function render_inline(string $chat, array $ids): string {
    if (!$ids) return '';
    $o = FRAME_INLINE . "\n";
    foreach (rows_for($chat, $ids) as $r) {
        $who = $r['role'] === 'user' ? 'User' : ucfirst_mb((string)($r['agent'] !== '' && $r['agent'] !== null ? $r['agent'] : 'agent'));
        // sed 's/\\n/\n/g' then $(...) strips trailing newlines
        $body = rtrim(str_replace('\\n', "\n", (string)$r['body']), "\n");
        $o .= '#' . $r['id'] . ' ' . $who . ': ' . cap($body) . "\n\n";
    }
    return $o . FRAME_END . "\n\n";
}

// jq -c string escaping: quote, backslash, short control escapes, other control bytes (and DEL) as \u00xx
function jq_str(string $s): string {
    $o = '"';
    for ($i = 0, $n = strlen($s); $i < $n; $i++) {
        $c = $s[$i]; $b = ord($c);
        if ($c === '"') $o .= '\\"'; elseif ($c === '\\') $o .= '\\\\';
        elseif ($c === "\n") $o .= '\\n'; elseif ($c === "\r") $o .= '\\r'; elseif ($c === "\t") $o .= '\\t';
        elseif ($b === 8) $o .= '\\b'; elseif ($b === 12) $o .= '\\f';
        elseif ($b < 32 || $b === 127) $o .= sprintf('\\u%04x', $b);
        else $o .= $c;
    }
    return $o . '"';
}
function render_json(string $chat, array $ids): string {
    if (!$ids) return "[]\n";
    $rows = rows_for($chat, $ids);
    if (!$rows) return '';                                                    // sqlite3 -json prints nothing for no rows; so did jq
    $items = [];
    foreach ($rows as $r) {
        $content = str_replace('\\n', "\n", (string)$r['body']);              // jq gsub: no trailing-newline stripping here
        if ($content === '') continue;
        $items[] = '{"role":' . jq_str($r['role'] === 'user' ? 'user' : 'assistant') . ',"content":' . jq_str($content) . '}';
    }
    return '[' . implode(',', $items) . "]\n";
}
function render_pointer(string $chat, array $ids): string {
    sort($ids, SORT_NUMERIC);
    $n = count($ids); $rest = [];
    if ($n >= 2) { $rest = array_slice($ids, 0, $n - 2); $lastpair = array_slice($ids, -2); } else { $lastpair = $ids; }
    $o = $lastpair ? render_inline($chat, $lastpair) : '';
    if ($rest) {
        $list = implode(',', $rest);
        $o .= "[Earlier turns of this chat that look relevant to the new message (by keyword index): exchange ids $list. The full transcript is the JSON file $chat -- .exchanges[] items carry id, role, agent, text. Read only those turns, and only if the new message depends on them:\n";
        $o .= "  jq '.exchanges[] | select(.id as \$i | [$list] | index(\$i)) | {id,role,text}' '$chat'\n]\n\n";
    }
    return $o;
}

// ---- the whole-tail fallbacks (no index, or nothing in it) ----------------------------------------------------
// read_history (awk): walks the chat file line by line and expects the loop's own pretty-printed layout.
function whole_tail_text(string $chat, int $maxHistory): string {
    if (!is_file($chat)) return '';
    $inEx = false; $depth = 0; $role = $text = $agent = $model = '';
    $ex = [];
    $field = function (string $line, string $key): string {          // sub(/.*"key"[^"]*"/, "") ; sub(/".*/, "")
        $s = preg_replace('/^.*"' . $key . '"[^"]*"/s', '', $line, 1);
        return preg_replace('/".*$/s', '', $s, 1);
    };
    foreach (preg_split('/\n/', (string)file_get_contents($chat)) as $line) {
        if (strpos($line, '"exchanges"') !== false && strpos($line, '[') !== false) { $inEx = true; continue; }
        if ($inEx && (preg_match('/^\{/', $line) || preg_match('/^  \{/', $line) || preg_match('/^    \{/', $line))) { $depth++; $role = $text = $agent = $model = ''; }
        if ($inEx && $depth === 1) {
            if (strpos($line, '"role"') !== false) $role = $field($line, 'role');
            if (strpos($line, '"agent"') !== false) $agent = $field($line, 'agent');
            if (strpos($line, '"model"') !== false && strpos($line, 'null') === false) $model = $field($line, 'model');
            if (strpos($line, '"text"') !== false) {
                $s = preg_replace('/^.*"text"[^"]*"/s', '', $line, 1);
                $s = preg_replace('/"[,]?[ \t]*$/', '', $s, 1);
                $text = str_replace(['\\n', '\\t'], ' ', $s);
            }
        }
        if ($inEx && $depth === 1 && preg_match('/^[ \t\r\n\f\v]*\}/', $line)) {
            $depth--;
            if ($role !== '') $ex[] = [$role, $text, $agent, $model];
        }
        if ($inEx && preg_match('/^[ \t\r\n\f\v]*\]/', $line)) $inEx = false;
    }
    if (!$ex) return '';
    $start = max(0, count($ex) - $maxHistory * 2);
    $o = FRAME_TAIL . "\n";
    for ($i = $start; $i < count($ex); $i++) {
        [$r, $t, $a, $m] = $ex[$i];
        if ($r === 'user') $who = 'User';
        else { $who = ucfirst_mb($a); if ($m !== '') $who .= " ($m)"; }
        if (mb_strlen($t) > 1500) $t = mb_substr($t, 0, 1500) . '... [truncated]';
        $o .= "$who: $t\n\n";
    }
    return $o . FRAME_END . "\n\n";
}
// read_history_json (python regex): the last N exchanges as a messages array. json.dumps default separators.
function whole_tail_json(string $chat, int $maxHistory): string {
    if (!is_file($chat)) return "[]\n";
    $raw = mb_convert_encoding((string)file_get_contents($chat), 'UTF-8', 'UTF-8');
    $msgs = [];
    if (preg_match_all('/"role"\s*:\s*"([^"]+)".*?"text"\s*:\s*"(.*?)"\s*(?:,\s*"[a-z_]+"\s*:|,?\s*\})/s', $raw, $mm, PREG_SET_ORDER)) {
        foreach ($mm as $m) {
            $text = $m[2];
            foreach ([['\\n', "\n"], ['\\t', "\t"], ['\\r', "\r"], ['\\"', '"'], ['\\\\', '\\']] as [$a, $b]) $text = str_replace($a, $b, $text);
            if (trim($text) === '') continue;
            $msgs[] = [$m[1] === 'user' ? 'user' : 'assistant', $text];
        }
    }
    $msgs = array_slice($msgs, -$maxHistory * 2);
    $enc = function (string $s): string {                              // python json.dumps(ensure_ascii=False)
        $o = '"';
        for ($i = 0, $n = strlen($s); $i < $n; $i++) {
            $c = $s[$i]; $b = ord($c);
            if ($c === '"') $o .= '\\"'; elseif ($c === '\\') $o .= '\\\\'; elseif ($c === "\n") $o .= '\\n'; elseif ($c === "\r") $o .= '\\r';
            elseif ($c === "\t") $o .= '\\t'; elseif ($b === 8) $o .= '\\b'; elseif ($b === 12) $o .= '\\f';
            elseif ($b < 32) $o .= sprintf('\\u%04x', $b); else $o .= $c;
        }
        return $o . '"';
    };
    $items = array_map(fn($m) => '{"role": ' . $enc($m[0]) . ', "content": ' . $enc($m[1]) . '}', $msgs);
    return '[' . implode(', ', $items) . "]\n";
}

// ---- build_history ------------------------------------------------------------------------------------------------
function build(string $chat, string $prompt, string $fmt, string $mode, string $uc, int $maxHistory): int {
    if (!index_ready() || !is_file($chat)) {
        err("[$uc] history: whole tail (no index)\n");
        out($fmt === 'json' ? whole_tail_json($chat, $maxHistory) : whole_tail_text($chat, $maxHistory));
        return ($fmt !== 'json' && !is_file($chat)) ? 1 : 0;      // read_history returns the failed [ -f ] test's status (1) for a missing file
    }
    // the reconcile runs under the chat's own lock, the same file the writers take
    $lk = @fopen($chat . '.lock', 'c');
    if ($lk) flock($lk, LOCK_EX);
    $log = sync($chat, $uc);
    if ($lk) { flock($lk, LOCK_UN); fclose($lk); }
    err((string)$log);
    $ids = select_ids($chat, $prompt, $maxHistory);
    if (!$ids) {
        err("[$uc] history: whole tail (index empty)\n");
        out($fmt === 'json' ? whole_tail_json($chat, $maxHistory) : whole_tail_text($chat, $maxHistory));
        return 0;
    }
    if ($fmt === 'json') {
        err("[$uc] history: inline-json ids=" . implode(',', $ids) . "\n");
        out(render_json($chat, $ids));
        return 0;
    }
    err("[$uc] history: $mode ids=" . implode(',', $ids) . "\n");
    out($mode === 'pointer' ? render_pointer($chat, $ids) : render_inline($chat, $ids));
    return 0;
}

// ---- main ---------------------------------------------------------------------------------------------------------
$cmd = $argv[1] ?? '';
$uc = opt('--agent', 'AGENT');
switch ($cmd) {
    case 'append':
        $o = [];
        foreach (['chat', 'project', 'chat-name', 'user-file', 'agent-file', 'model', 'duration', 'style', 'mode', 'agent', 'supplier', 'agent-uc'] as $k) $o[$k] = opt('--' . $k);
        if ($o['chat'] === '' || $o['user-file'] === '' || $o['agent-file'] === '') { err("append needs --chat --user-file --agent-file\n"); exit(2); }
        exit(append_chat($o));
    case 'needs':
        exit(needs(stdin_all(), $uc));
    case 'build':
        if (opt('--chat') === '') { err("build needs --chat\n"); exit(2); }
        exit(build(opt('--chat'), stdin_all(), opt('--format', 'text'), opt('--mode', 'inline'), $uc, $MAX_HISTORY));
    case 'sync':
        if (opt('--chat') === '') { err("sync needs --chat\n"); exit(2); }
        // the Bash prints its log line on stdout only when it rebuilt
        out(sync(opt('--chat'), $uc));
        exit(0);
    case 'add':
        if (opt('--chat') === '' || opt('--text-file') === '') { err("add needs --chat and --text-file\n"); exit(2); }
        add(opt('--chat'), (int)opt('--id', '0'), opt('--role'), opt('--agent'), opt('--ts'), (string)@file_get_contents(opt('--text-file')));
        exit(0);
}
err("usage: history_cli.php needs|build|sync|add ...\n");
exit(2);
