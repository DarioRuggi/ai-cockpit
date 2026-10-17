<?php
// =============================================================================
// text_clean.php — book text cleaning, shared by whoever touches book text.
//
// This lived inside bookshelf.php and ran at INGEST only. That is how 58 live
// chapters ended up in the Library still carrying their calibre markup: the
// cleaner shipped on 2026-09-29 and the books had been ingested minutes before
// it, so every retrieved passage since then has spent a fifth of its budget on
// {.calibre3} spans and escaped quotes. Nothing told anyone, because a book
// that reads slightly oddly looks like a book that reads slightly oddly.
//
// Cleaning at ingest alone cannot fix data that is already stored. So the same
// function now also runs when the text is READ, which repairs every existing
// library immediately and costs nothing: it is idempotent (running it on clean
// text changes nothing), and it is a handful of preg_replace over at most 40 KB.
//
// bookshelf.php cannot be required for this — it sends headers and dispatches
// an action on include — hence a file of its own.
// =============================================================================

if (!function_exists('book_clean_text')) {
/**
 * Strip pandoc/calibre conversion artefacts from extracted book text.
 * Safe to run repeatedly and safe to run on text that was never dirty.
 */
function book_clean_text(string $t): string {
    $t = preg_replace('/\{\.[A-Za-z0-9_-]+\}/', '', $t);         // {.calibre3}
    $t = preg_replace('/\*\*\[\s*\]\*\*/u', '', $t);             // **[ ]** decorative spacer
    $t = preg_replace('/\[\s*\]/u', '', $t);                     // leftover empty spans
    $t = preg_replace('/\[([^\]\n]{0,400})\](?!\()/u', '$1', $t); // [text] -> text, keep [a](b) links
    $t = preg_replace('/\\\\(["\'\-*_\[\]])/u', '$1', $t);        // \" \-- \* escapes
    $t = preg_replace('/^[ \t]*\*\*[ \t]*$/mu', '', $t);          // orphan emphasis on its own line
    $t = preg_replace('/\n{3,}/u', "\n\n", $t);                   // runs of blank lines
    return $t;
}
}
