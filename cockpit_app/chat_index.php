<?php
// =============================================================================
// chat_index.php — PHP side of the derived chat index.
//
// scripts/agent_loop.sh keeps <user root>/.chat_index.db, one SQLite FTS5 table
// `ex`, as a REBUILDABLE cache of every exchange in every chat under that root.
// The chat JSON is canonical; the index exists so retrieval can be one FTS
// MATCH instead of "the last six exchanges, blind".
//
// The loop reconciles the index against the JSON on every turn, so it repairs
// itself even if nothing here ever runs. This file lets PHP writers keep the
// index current IMMEDIATELY instead of one turn late — combos_core.php is the
// one PHP path that appends exchanges — and gives files.php a query helper.
//
// Fails SOFT everywhere: no sqlite extension, no FTS5, a locked file, a broken
// db — every function returns false/[] and the caller carries on. An index
// problem must never break a chat write.
//
// Schema and body normalisation MUST match agent_loop.sh exactly, or the
// loop's count-based reconcile would keep "repairing" rows PHP wrote:
//   ex(chat UNINDEXED, id UNINDEXED, role UNINDEXED, agent UNINDEXED,
//      ts UNINDEXED, body)        body: tabs -> space, newline -> literal \n
// =============================================================================

function chat_index_available(): bool {
    static $ok = null;
    if ($ok !== null) return $ok;
    if (!class_exists('SQLite3')) return $ok = false;
    try {
        $m = new SQLite3(':memory:');
        $ok = (bool)@$m->exec('CREATE VIRTUAL TABLE t USING fts5(x)');
        $m->close();
    } catch (Throwable $e) { $ok = false; }
    return $ok;
}

/** Index db for the chat file at $chatFile (<root>/<project>/chat_x.json). */
function chat_index_path(string $chatFile): string {
    return dirname(dirname($chatFile)) . '/.chat_index.db';
}

/**
 * Two users write this database: the agent loops (the login user) and Apache
 * (www-data). SQLite creates its files 0644, so whichever side created the
 * db, or its -wal/-shm, locked the other out — inserts failed silently and the
 * index fell behind (live, 2026-09-12). Every open makes the three files
 * group-writable and gives them the parent directory's group, which the
 * installer sets up as the group both users share.
 */
function chat_index_share(string $dbPath): void {
    $grp = @filegroup(dirname($dbPath));
    foreach ([$dbPath, $dbPath . '-wal', $dbPath . '-shm'] as $p) {
        if (!file_exists($p)) continue;
        @chmod($p, 0664);
        if ($grp !== false && @filegroup($p) !== $grp) @chgrp($p, $grp);
    }
}

/** Open (creating schema if needed). Returns SQLite3 or null. */
function chat_index_open(string $chatFile): ?SQLite3 {
    if (!chat_index_available()) return null;
    try {
        $path = chat_index_path($chatFile);
        $db = new SQLite3($path);
        // Three bash loops and Apache can write this file. WAL lets readers and
        // one writer coexist; the busy timeout makes a second writer wait
        // instead of failing with SQLITE_BUSY.
        $db->busyTimeout(3000);
        @$db->exec('PRAGMA journal_mode=WAL');
        @$db->exec('CREATE VIRTUAL TABLE IF NOT EXISTS ex USING fts5(chat UNINDEXED, id UNINDEXED, role UNINDEXED, agent UNINDEXED, ts UNINDEXED, body, tokenize=\'porter unicode61\')');
        chat_index_share($path);
        return $db;
    } catch (Throwable $e) { return null; }
}

function chat_index_norm(string $text): string {
    return str_replace(["\x1f", "\t", "\n"], [' ', ' ', '\n'], $text);
}

/**
 * Add one exchange row. Call while holding the chat's .lock (the caller already
 * does for the JSON write). Returns false on any failure — the loop's next
 * reconcile pass will repair the index from the JSON.
 */
function chat_index_add(string $chatFile, int $id, string $role, string $agent, string $ts, string $text): bool {
    $db = chat_index_open($chatFile);
    if (!$db) return false;
    try {
        $st = $db->prepare('INSERT INTO ex(chat,id,role,agent,ts,body) VALUES(:c,:i,:r,:a,:t,:b)');
        $st->bindValue(':c', $chatFile, SQLITE3_TEXT);
        $st->bindValue(':i', $id,       SQLITE3_INTEGER);
        $st->bindValue(':r', $role,     SQLITE3_TEXT);
        $st->bindValue(':a', $agent,    SQLITE3_TEXT);
        $st->bindValue(':t', $ts,       SQLITE3_TEXT);
        $st->bindValue(':b', chat_index_norm($text), SQLITE3_TEXT);
        $ok = $st->execute() !== false;
        $db->close();
        return $ok;
    } catch (Throwable $e) { try { $db->close(); } catch (Throwable $e2) {} return false; }
}

/**
 * Full-text search within one chat. Returns [{id, role, agent, ts, body}, ...]
 * best-match first, at most $limit. Empty on any failure.
 */
function chat_index_search(string $chatFile, string $query, int $limit = 6): array {
    $db = chat_index_open($chatFile);
    if (!$db || trim($query) === '') return [];
    try {
        // Quote every term so punctuation in a prompt cannot become FTS syntax.
        $terms = preg_split('/\s+/', trim($query));
        $q = implode(' OR ', array_map(fn($t) => '"' . str_replace('"', '""', $t) . '"', $terms));
        $st = $db->prepare('SELECT id, role, agent, ts, body FROM ex WHERE ex MATCH :q AND chat = :c ORDER BY rank LIMIT :n');
        $st->bindValue(':q', $q, SQLITE3_TEXT);
        $st->bindValue(':c', $chatFile, SQLITE3_TEXT);
        $st->bindValue(':n', $limit, SQLITE3_INTEGER);
        $res = $st->execute(); $out = [];
        while ($res && ($row = $res->fetchArray(SQLITE3_ASSOC))) $out[] = $row;
        $db->close();
        return $out;
    } catch (Throwable $e) { try { $db->close(); } catch (Throwable $e2) {} return []; }
}
