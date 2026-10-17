<?php
require_once __DIR__ . "/auth.php";
// =============================================================================
// saver.php - Transcript Saver (Dario Ruggi / Cockpit v2)
// Saves the current console session to a timestamped .txt file on the HDD.
// Fixes applied:
//   - file_put_contents failure (disk full, bad permissions, missing mount) is now
//     caught and returned as a clear error message instead of silently succeeding.
//   - mkdir failure is also caught.
//   - Empty-text check now distinguishes "nothing to save" from write errors.
// =============================================================================

header('Content-Type: application/json');

// --- 1. Parse and validate input ---
$raw = file_get_contents('php://input');
$in  = json_decode($raw, true);

if (!is_array($in) || empty($in['text'])) {
    // Nothing was sent or JSON was broken — nothing to save.
    echo json_encode(['message' => 'Nothing to save. Console appears to be empty.', 'error' => false], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 2. Ensure the transcript directory exists ---
// Default: <cockpit_root>/cockpit_data/transcripts/
// Override: add  TRANSCRIPT_DIR /your/path  to COCKPIT.md
$dir = __DIR__ . '/cockpit_data/transcripts/';
$cockpitMd = __DIR__ . '/COCKPIT.md';
if (is_readable($cockpitMd)) {
    foreach (file($cockpitMd, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
        if (preg_match('/^\s*TRANSCRIPT_DIR\s+(.+)$/i', $line, $m)) {
            $dir = rtrim(trim($m[1]), '/') . '/';
            break;
        }
    }
}

if (!is_dir($dir)) {
    // mkdir with recursive=true creates all parent directories.
    // 0775 gives owner+group full access, others read+execute (www-data compatible).
    if (!mkdir($dir, 0775, true)) {
        echo json_encode([
            'message' => '[WARN] Could not create transcript directory: ' . $dir . '. To set a custom path add  TRANSCRIPT_DIR /your/path  to COCKPIT.md.',
            'error'   => false
        ], JSON_UNESCAPED_UNICODE);
        exit;
    }
}

// --- 3. Check directory is writable before attempting write ---
if (!is_writable($dir)) {
    echo json_encode([
        'message' => '[WARN] Transcript directory is not writable: ' . $dir . '. Run: sudo chown -R www-data ' . $dir,
        'error'   => false
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 4. Build filename with timestamp and write ---
// Format: Session_20260425_143022.txt — sortable and unique per second.
$filename = "Session_" . date('Ymd_His') . ".txt";
$fullPath = $dir . $filename;

// file_put_contents returns the number of bytes written, or FALSE on failure.
$bytesWritten = file_put_contents($fullPath, $in['text']);

if ($bytesWritten === false) {
    // Write failed — disk full, permissions changed mid-run, etc.
    echo json_encode([
        'message' => '[ERROR] Write failed for file: ' . $fullPath . '. Disk may be full or permissions changed.',
        'error'   => true
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

// --- 5. Success ---
echo json_encode([
    'message' => 'Transcript saved: ' . $filename . ' (' . $bytesWritten . ' bytes written to ' . $dir . ')',
    'error'   => false
], JSON_UNESCAPED_UNICODE);
?>
