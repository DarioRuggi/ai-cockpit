<?php
// =============================================================================
// bookshelf.php — a book becomes chapters the agent can actually find.
//
// Attaching a book already worked in the sense that pandoc converts it. What
// failed was scale: over 50 KB of extracted text the agent is handed a file path
// and a 1 KB preview, so an agent with file tools can go read it and a local
// model can do nothing at all.
//
// This splits the book into chapters and files each one in the Library. From
// then on push-RAG pulls the chapter that matches the question, and Receipts
// names it — so "what does chapter 9 say about X" works on a 400-page book with
// a 7B local model, because it never sees more than the chapter it needs.
//
//   POST {action:'ingest', path, title?}   → { ok, title, chapters, ids[] }
//   POST {action:'preview', path}          → { ok, title, chapters:[{title,bytes}] }
//
// Conversion order: pandoc (epub/docx/odt/fb2), pdftotext (pdf), ebook-convert
// (mobi/azw3/chm — calibre, when installed), plain read for text.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/text_clean.php';  // book_clean_text() — shared, also used on READ
require_once __DIR__ . '/vram_lib.php';   // vram_total_mb() — the chapter cap follows the hardware
require_once __DIR__ . '/auth.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

const BOOK_MIN_CHAPTER = 400;        // bytes; smaller pieces are front matter, not chapters
// Chapter cap, sized to the hardware that will READ the chapter -- see
// book_max_chapter() below. The flat 60000 this used to be was chosen for
// retrieval quality alone and is unusable on the machines Cockpit targets:
// measured 2026-09-25, a 60 KB chapter costs 346s of prompt-eval on a 4 GB GPU
// and 309s CPU-only, i.e. 5-6 minutes before a single token comes back, past
// every timeout in the app. Chapters are only useful if the model can read one.
const BOOK_MAX_CHAPTER_FLOOR = 12000;   // no usable GPU: ~56s prompt-eval, 3B on CPU
const BOOK_MAX_CHAPTER_4GB   = 20000;   // 4 GB-class GPU: ~6.7s
const BOOK_MAX_CHAPTER_BIG   = 40000;   // 8 GB+: ~25.6s measured at 4 GB, comfortable above
const BOOK_MAX_CHAPTERS = 300;

// Files arrive as base64 inside a JSON body, so memory_limit (not upload_max_filesize) is the ceiling: the base64
// text, its decoded copy and the decoded JSON array are alive together, about 3.7x the file. The distribution's 128M
// died with an empty 500 at ~35 MB although the documented cap is 80 MB. Raise it for THIS request only.
@ini_set('memory_limit', '768M');
$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
$action = (string)($in['action'] ?? 'preview');
$path   = (string)($in['path'] ?? '');

function book_out(array $a) { echo json_encode($a, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); exit; }

$CDp_BOOK = rtrim((string)$PATHS['cockpit_data'], '/');

// Folders Bookshelf may read: the two it always owns, plus any the user has
// explicitly added. Nobody keeps their library inside a Cockpit project, so
// without this the feature reads only books it has no reason to have.
//
// The approval is RECORDED here, deliberately, rather than inferred from a
// symlink placed in an allowed folder. Agents run with a shell and the CRUD
// executor writes inside project folders, so a symlink is forgeable by anything
// already running -- and an endpoint that creates symlinks on request would
// itself become an arbitrary-read primitive. realpath() resolves links before
// the check, so a link into an approved folder is simply unnecessary.
$BOOK_ROOTS_F = $CDp_BOOK . '/bookshelf_roots.json';

function book_extra_roots(string $file): array {
    $j = is_readable($file) ? json_decode((string)@file_get_contents($file), true) : [];
    if (!is_array($j)) return [];
    $out = [];
    foreach ($j as $d) {
        $r = realpath((string)$d);
        // A root has to be a real directory, and '/' would make the whole check
        // decorative.
        if ($r && is_dir($r) && $r !== '/') $out[] = $r;
    }
    return array_values(array_unique($out));
}

// ── a book handed over by the user, as bytes ──────────────────────────────────
// The safest way to open someone's book is not to open their disk at all. The
// browser's own file dialog is the permission: the user picks a file, the bytes
// arrive, and Cockpit stores them in its own folder. No path is ever taken from
// the request, so this cannot be turned into a read-anything primitive the way
// a path parameter can. attachments.php already works exactly this way.
//
// The path field and the allowed-folder list stay for libraries too big to
// duplicate — pick whichever suits the book.
if ($action === 'upload') {
    auth_require_writer();
    $name = (string)($in['filename'] ?? '');
    $b64  = (string)($in['data_b64'] ?? '');
    $name = preg_replace('/[^A-Za-z0-9._ \-()\x{0590}-\x{05FF}]/u', '_', basename($name));
    $name = trim((string)$name, '. ');
    if ($name === '' || $b64 === '') book_out(['ok' => false, 'error' => 'Missing filename or data']);
    $ext = strtolower(pathinfo($name, PATHINFO_EXTENSION));
    $ok_ext = ['epub','pdf','docx','odt','fb2','rtf','html','htm','txt','md','mobi','azw3'];
    if (!in_array($ext, $ok_ext, true)) {
        book_out(['ok' => false, 'error' => 'Not a book format Bookshelf reads: .' . $ext]);
    }
    $bin = base64_decode($b64, true);
    if ($bin === false) book_out(['ok' => false, 'error' => 'Bad data']);
    if (strlen($bin) > 80 * 1024 * 1024) book_out(['ok' => false, 'error' => 'Too large (80 MB limit)']);

    $dir = $CDp_BOOK . '/books';
    if (!is_dir($dir) && !@mkdir($dir, 0775, true)) book_out(['ok' => false, 'error' => 'Could not create ' . $dir]);
    $base = pathinfo($name, PATHINFO_FILENAME);
    $try  = $name; $n = 1;
    while (file_exists($dir . '/' . $try)) { $try = $base . '-' . $n . '.' . $ext; if (++$n > 999) break; }
    $dest = $dir . '/' . $try;
    if (@file_put_contents($dest, $bin, LOCK_EX) === false) book_out(['ok' => false, 'error' => 'Could not write ' . $dest]);
    @chmod($dest, 0664);
    // Inside cockpit_data, so the ordinary path check admits it from here on.
    book_out(['ok' => true, 'path' => $dest, 'bytes' => strlen($bin), 'name' => $try]);
}

// ── the allowed-folder list ───────────────────────────────────────────────────
if ($action === 'roots_get' || $action === 'roots_add' || $action === 'roots_del') {
    $always = array_values(array_filter([realpath((string)$PATHS['projects_root']),
                                         realpath((string)$PATHS['cockpit_data'])]));
    if ($action !== 'roots_get') {
        auth_require_writer();
        $dir = realpath((string)($in['dir'] ?? ''));
        if (!$dir || !is_dir($dir)) book_out(['ok' => false, 'error' => 'Not a folder: ' . (string)($in['dir'] ?? '')]);
        if ($dir === '/')           book_out(['ok' => false, 'error' => 'Refusing "/" — that would allow everything.']);
        $cur = book_extra_roots($BOOK_ROOTS_F);
        if ($action === 'roots_add') {
            if (!is_readable($dir)) book_out(['ok' => false, 'error' => 'Cannot read that folder: ' . $dir]);
            if (!in_array($dir, $cur, true)) $cur[] = $dir;
        } else {
            $cur = array_values(array_filter($cur, fn($d) => $d !== $dir));
        }
        if (@file_put_contents($BOOK_ROOTS_F, json_encode(array_values($cur), JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n", LOCK_EX) === false) {
            book_out(['ok' => false, 'error' => 'Could not write ' . $BOOK_ROOTS_F]);
        }
        @chmod($BOOK_ROOTS_F, 0664);
    }
    book_out(['ok' => true, 'always' => $always, 'extra' => book_extra_roots($BOOK_ROOTS_F)]);
}

$rp = realpath($path);
$own_roots   = array_filter([realpath((string)$PATHS['projects_root']), realpath((string)$PATHS['cockpit_data'])]);
$extra_roots = book_extra_roots($BOOK_ROOTS_F);
$roots  = array_merge($own_roots, $extra_roots);
$inside = false;
foreach ($roots as $r) if ($rp && str_starts_with($rp, rtrim($r, '/') . '/')) $inside = true;
// Say which of the three it is. "File not found" for a file that plainly exists
// sends people hunting for a typo when the real answer is that Bookshelf only
// reads inside these folders.
if (!$rp || !is_file($rp)) {
    book_out(['ok' => false, 'error' => 'No such file: ' . $path]);
}
if (!$inside) {
    book_out(['ok' => false, 'roots' => $roots, 'suggest' => dirname($rp), 'error' =>
        'That file is outside the folders Bookshelf may read.']);
}

/** Convert whatever it is to Markdown/plain text. */
function book_to_text(string $file): array {
    $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
    $have = fn($b) => trim((string)@shell_exec('command -v ' . escapeshellarg($b) . ' 2>/dev/null')) !== '';
    $tmp = tempnam(sys_get_temp_dir(), 'book') . '.md';
    $run = function (string $cmd) { @shell_exec('timeout 180 ' . $cmd . ' 2>/dev/null'); };

    if (in_array($ext, ['txt', 'md', 'markdown'], true)) {
        return [(string)@file_get_contents($file), 'read directly'];
    }
    if ($ext === 'pdf' && $have('pdftotext')) {
        $run('pdftotext -layout ' . escapeshellarg($file) . ' ' . escapeshellarg($tmp));
        $t = (string)@file_get_contents($tmp); @unlink($tmp);
        return [$t, 'pdftotext'];
    }
    if (in_array($ext, ['epub', 'docx', 'odt', 'fb2', 'rtf', 'html', 'htm'], true) && $have('pandoc')) {
        $run('pandoc ' . escapeshellarg($file) . ' -t markdown --wrap=none -o ' . escapeshellarg($tmp));
        $t = (string)@file_get_contents($tmp); @unlink($tmp);
        if (trim($t) !== '') return [$t, 'pandoc'];
    }
    // calibre reads the formats pandoc will not (mobi, azw3, chm, lit, pdb)
    if ($have('ebook-convert')) {
        $run('ebook-convert ' . escapeshellarg($file) . ' ' . escapeshellarg($tmp));
        $t = (string)@file_get_contents($tmp); @unlink($tmp);
        if (trim($t) !== '') return [$t, 'calibre'];
    }
    @unlink($tmp);
    return ['', 'no converter'];
}

/**
 * Split on headings, and when a book has none, on blank-line blocks of a
 * readable size. A chapter that is too long to be a useful retrieval unit is cut
 * again — the point is that ONE piece answers a question, not that the pieces
 * match the author's table of contents exactly.
 */
// The cap depends on the machine, because the cost of a chapter is paid at READ
// time, not at split time. Measured on a 4 GB card / 12-core CPU, 3B model:
//
//   chapter   4 GB GPU    CPU-only
//    8 KB        2.8s        44.3s
//   20 KB        6.7s        95.6s
//   40 KB       25.6s       274.8s
//   60 KB      346.0s       309.2s   <- the old flat value
//
// The 60 KB cliff is the KV cache no longer fitting in VRAM, which is why the
// GPU is WORSE than the CPU there: it thrashes. Sizing by detected VRAM keeps a
// chapter readable on whatever the user actually has, instead of assuming a card
// they may not own.
function book_max_chapter(): int {
    $vram = 0;
    if (function_exists('vram_total_mb')) { $vram = (int)vram_total_mb(); }
    if ($vram >= 8000) return BOOK_MAX_CHAPTER_BIG;
    if ($vram >= 3500) return BOOK_MAX_CHAPTER_4GB;   // 4 GB cards report ~4080
    return BOOK_MAX_CHAPTER_FLOOR;                    // no GPU, or too small to help
}

/**
 * Strip the wrapper a calibre/pandoc conversion leaves behind.
 *
 * A chapter arrives as **[  text]{.calibre3}** with empty decorative spans
 * between every paragraph. Measured on one retrieval: 15% of the injected
 * context was markup and 13 of the spans carried no words at all — noise in
 * front of exactly the small models that can least afford it, and it is stored
 * that way forever, so cleaning at ingest fixes retrieval, the viewer and the
 * preview at once.
 */

function book_split(string $text): array {
    $cap  = book_max_chapter();
    $text = preg_replace("/\r\n?/", "\n", $text);
    // Calibre-made epubs indent with U+00A0, so every pattern below that expects
    // a space silently fails on them. The End of Eternity separates its chapter
    // number from its name with one, which is why the whole book came out as a
    // single unnamed part before this line existed (2026-09-27).
    $text = preg_replace('/\x{00A0}/u', ' ', $text);

    // A split counts only if it actually divides the BOOK. "Three or more parts"
    // was the old test and it was satisfied by a cover, a title and one part
    // holding 99% of the text -- which is exactly the shape of a calibre epub,
    // and why The End of Eternity came out as twenty slices of "Book Jacket".
    $total = strlen($text);
    $useful = function (array $ps) use ($total): bool {
        $big = 0; $max = 0;
        foreach ($ps as $p) { $n = strlen(trim($p)); if ($n >= BOOK_MIN_CHAPTER) $big++; if ($n > $max) $max = $n; }
        return $big >= 3 && $max < $total * 0.6;
    };

    $titled = true;
    $parts = null;
    // Calibre wraps a chapter line in emphasis and a span: the body of Fantastic
    // Voyage opens its chapters with **[Chapter 1 : PLANE]{.calibre4}**, not with
    // "Chapter 1". Every opener pattern below therefore tolerates that wrapper —
    // without it they only ever matched the table of contents, whose entries are
    // one line long and get dropped by BOOK_MIN_CHAPTER, so the book looked
    // chapterless and fell through to size slices (2026-09-29).
    $wrap = '[ \t]*[*_~]{0,3}\[?[ \t]*';
    $tries = [
        '/\n(?=#{1,3} )/',                                                      // markdown headings
        '/\n(?=' . $wrap . '(?:CHAPTER|Chapter|PART|Part)[ \t]+[0-9IVXLC]+\b)/', // "Chapter 4"
        '/\n(?=' . $wrap . '[0-9]{1,3}[ \t]+[A-Z][^\n]{0,60}\n)/',              // "1  Technician"
    ];
    foreach ($tries as $re) {
        $cand = preg_split($re, $text);
        if ($cand !== false && $useful($cand)) { $parts = $cand; break; }
    }
    if ($parts === null) $parts = [];
    if (!$parts) {
        // Nothing found: fixed-size blocks on paragraph boundaries. These have no
        // names of their own, so do not pretend they do.
        $titled = false;
        $parts = [];
        $buf = '';
        foreach (explode("\n\n", $text) as $para) {
            if (strlen($buf) + strlen($para) > $cap && $buf !== '') { $parts[] = $buf; $buf = ''; }
            $buf .= $para . "\n\n";
        }
        if (trim($buf) !== '') $parts[] = $buf;
    }

    $out = [];
    $n = 0;
    foreach ($parts as $p) {
        $p = trim($p);
        if (strlen($p) < BOOK_MIN_CHAPTER) continue;
        // Front matter is mostly markup: a cover page is an image tag and an SVG
        // block, a kilobyte of bytes with almost no words in it. Filing that as a
        // chapter puts an entry in the Library that can answer nothing.
        if (preg_match_all('/\p{L}/u', $p) < 300) continue;
        $n++;
        // The name belongs to the PART, taken from the line that opened it. A
        // chapter too long for the cap is then cut into slices that inherit it:
        // titling each slice by its own first line produced chapter names like
        // '"I understand, sir," said Harlan.' — the next sentence of the book,
        // not a heading at all (seen splitting The End of Eternity, 2026-09-27).
        $name = $titled ? book_clean_title(strtok($p, "\n")) : '';
        if ($name === '') $name = 'Part ' . $n;

        if (strlen($p) <= $cap) { $out[] = ['text' => $p, 'title' => $name]; }
        else {
            // Even slices, not "fill to the cap and leave a stub". Cutting greedily
            // gave 19.4 KB followed by 1.0 KB, and a one-kilobyte fragment is a
            // poor thing to retrieve: it answers nothing on its own.
            $want = (int)ceil(strlen($p) / $cap);
            $aim  = (int)ceil(strlen($p) / max($want, 1));
            $slices = [];
            while (strlen($p) > $cap) {
                $cut = strrpos(substr($p, 0, min($aim + 2000, $cap)), "\n\n");
                if ($cut === false || $cut < BOOK_MIN_CHAPTER) $cut = min($aim, $cap);
                $slices[] = substr($p, 0, $cut);
                $p = trim(substr($p, $cut));
            }
            if (strlen($p) >= BOOK_MIN_CHAPTER) $slices[] = $p;
            elseif ($slices && $p !== '') $slices[count($slices) - 1] .= "\n\n" . $p;
            $tot = count($slices);
            foreach ($slices as $k => $sl) {
                $out[] = ['text' => $sl,
                          'title' => $tot > 1 ? $name . ' (' . ($k + 1) . '/' . $tot . ')' : $name];
            }
        }
        if (count($out) >= BOOK_MAX_CHAPTERS) break;
    }
    return array_slice($out, 0, BOOK_MAX_CHAPTERS);
}

/**
 * Tidy a line that opened a section into a chapter name.
 *
 * pandoc writes an epub's classes into the markdown ('# Book Jacket
 * {.calibrerescale2}') and escapes quotes as \" — both were reaching the UI
 * verbatim. A line that is plainly prose rather than a heading is rejected, so
 * the caller falls back to 'Part N'.
 */
function book_clean_title(string $line): string {
    $t = trim($line);
    // Reject a link line before the brackets are stripped, or "[a](b)" survives
    // as "ab".
    if (str_contains($t, '](')) return '';
    $t = preg_replace('/^#+\s*/', '', $t);                  // heading marks
    $t = preg_replace('/\\\\(.)/', '$1', $t);                  // \\" \\* escapes
    // pandoc writes an epub's classes as attribute blocks and wraps styled runs
    // in bracketed spans, so a chapter opener arrives as
    // ***[CONVERSATION WITH A COMMISSIONER]{.calibre16}***.
    $t = preg_replace('/\{[^}]*\}/u', '', $t);               // {.calibre16} anywhere
    $t = str_replace(['[', ']'], '', $t);                    // span brackets
    $t = preg_replace('/^[*_~\s]+|[*_~\s]+$/u', '', $t);     // emphasis runs
    $t = preg_replace('/\s+/u', ' ', trim($t));
    if ($t === '' || mb_strlen($t) > 90) return '';
    if (preg_match_all('/\p{L}/u', $t) < 3) return '';       // not a name
    // Dialogue or a sentence is not a chapter name.
    if (preg_match('/^["\x{201C}\x{2018}\x{00AB}]/u', $t)) return '';
    if (preg_match('/[.!?]["\x{201D}]?$/u', $t) && str_word_count($t) > 4) return '';
    return $t;
}

[$text, $how] = book_to_text($rp);
$text = book_clean_text($text);
if (trim($text) === '') {
    book_out(['ok' => false, 'error' => 'Nothing could be extracted from this file (' . $how . ').']);
}
$chapters = book_split($text);
if (!$chapters) book_out(['ok' => false, 'error' => 'The text came out too short to split into chapters.']);

$bookTitle = trim((string)($in['title'] ?? '')) ?: pathinfo($rp, PATHINFO_FILENAME);
$bookTitle = preg_replace('/[_-]+/', ' ', $bookTitle);
// A filename's " - " turns into three spaces once the dash becomes one.
$bookTitle = trim(preg_replace('/\s+/u', ' ', $bookTitle));

if ($action === 'preview') {
    book_out(['ok' => true, 'title' => $bookTitle, 'converter' => $how,
              'chapters' => array_map(fn($c) => ['title' => $c['title'], 'bytes' => strlen($c['text'])], $chapters),
              'total_bytes' => strlen($text)]);
}

if ($action === 'ingest') {
    auth_require_writer();
    $CDb        = rtrim((string)$PATHS['cockpit_data'], '/');
    $LIBTEXT    = $CDb . '/library_text';
    $idxF       = $CDb . '/library_index.json';
    if (!is_dir($LIBTEXT)) @mkdir($LIBTEXT, 0775, true);
    $idx = is_readable($idxF) ? (json_decode((string)file_get_contents($idxF), true) ?: []) : [];
    if (!isset($idx['library']) || !is_array($idx['library'])) $idx['library'] = [];

    $ids = [];
    foreach ($chapters as $i => $chap) {
        $chunk = $chap['text'];
        $id = 'bk' . date('Ymd_His') . '_' . substr(md5($bookTitle . $i . microtime(true)), 0, 6);
        @file_put_contents($LIBTEXT . '/' . $id . '.txt', $chunk);
        @chmod($LIBTEXT . '/' . $id . '.txt', 0664);
        $idx['library'][] = [
            'id'      => $id,
            // Record where the chapter text actually is. Without it a single-item
            // delete removes the row and leaves the .txt on disk forever.
            'file_path' => $LIBTEXT . '/' . $id . '.txt',
            'title'   => $bookTitle . ' — ' . $chap['title'],
            // Tagged with the book so the whole book can be found, removed, or
            // filtered as a unit later.
            'tags'    => ['book', $bookTitle],
            'source'  => $rp,
            'chapter' => $i + 1,
            'size'    => strlen($chunk),
            'scope'   => 'global',
            'updated' => date('c'),
        ];
        $ids[] = $id;
    }
    if (@file_put_contents($idxF, json_encode($idx, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE), LOCK_EX) === false) {
        book_out(['ok' => false, 'error' => 'Could not write the library index.']);
    }
    @chmod($idxF, 0664);
    book_out(['ok' => true, 'title' => $bookTitle, 'chapters' => count($ids), 'converter' => $how, 'ids' => $ids]);
}

book_out(['ok' => false, 'error' => 'Unknown action: ' . $action]);
