<?php
// =============================================================================
// profile.php — Profile: what every agent should know about you.
//
// Global directives (directives.php) say how agents should BEHAVE. This is the
// other half: durable facts about the person — units, language, timezone, how
// they like answers, what they are working on. Separate file, separate editor,
// because the two are edited on different occasions and mixing them makes both
// harder to read.
//
//   GET  ?action=get                  → { ok, text, bytes, enabled }
//   POST {action:'save', text, enabled}
//   POST {action:'remember', text}    → append one line (the "remember this" path)
//
// Stored as Markdown in the per-user cockpit_data, so it is readable and
// editable outside Cockpit like everything else here.
// =============================================================================
require_once __DIR__ . '/paths.php';
require_once __DIR__ . '/auth.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

const PROFILE_MAX_BYTES = 4096;   // a profile is a short standing note, not a file

// A first-time profile is a blank box with a tooltip, and a blank box does not
// explain what belongs in it. So the editor opens on a sample instead — but the
// sample is NOT written to disk, because agent_loop.sh injects whatever is in
// profile.md and an unedited sample would put invented facts in front of every
// agent. It becomes real only when the user saves it deliberately.
//
// It still has to be safe if someone saves it verbatim, so it says plainly what
// it is and tells the reader to ignore it until replaced.
const PROFILE_SAMPLE = <<<MD
# Profile

This is the sample profile Cockpit ships, not facts about this person. The lines
below are examples. Ignore them until they have been replaced.

- Example: reply in English; keep answers short and concrete.
- Example: I work mostly in PHP, bash and Free Pascal — avoid Python unless I ask.
- Example: this machine has a small GPU, so prefer local models under 4B.
- Example: I am in the Europe/London timezone and use metric units.
MD;

$CDp      = rtrim((string)$PATHS['cockpit_data'], '/');
$PROF_F   = $CDp . '/profile.md';
$PROF_CFG = $CDp . '/profile_enabled';       // presence of this file = switched off

$in     = json_decode((string)file_get_contents('php://input'), true) ?: [];
$action = $_GET['action'] ?? ($in['action'] ?? 'get');

function prof_out(array $a) { echo json_encode($a, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); exit; }

if ($action === 'get') {
    $sample = false;
    if (is_readable($PROF_F)) {
        $text = (string)file_get_contents($PROF_F);
    } else {
        $text   = PROFILE_SAMPLE;   // shown, never stored until the user saves
        $sample = true;
    }
    prof_out(['ok' => true, 'text' => $text, 'bytes' => strlen($text), 'sample' => $sample,
              'enabled' => !is_file($PROF_CFG), 'limit' => PROFILE_MAX_BYTES]);
}

if ($action === 'save') {
    auth_require_writer();
    $text = (string)($in['text'] ?? '');
    if (strlen($text) > PROFILE_MAX_BYTES) {
        prof_out(['ok' => false, 'error' => 'Too long: ' . strlen($text) . ' bytes, the limit is ' . PROFILE_MAX_BYTES .
                                            '. A profile every prompt carries has to stay short.']);
    }
    if (@file_put_contents($PROF_F, $text, LOCK_EX) === false) prof_out(['ok' => false, 'error' => 'Could not write ' . $PROF_F]);
    @chmod($PROF_F, 0664);
    // Off is recorded by a marker file rather than inside the profile itself, so
    // switching it off never edits the text you wrote.
    if (array_key_exists('enabled', $in)) {
        if ($in['enabled']) @unlink($PROF_CFG);
        else                @file_put_contents($PROF_CFG, "off\n");
    }
    prof_out(['ok' => true, 'bytes' => strlen($text)]);
}

if ($action === 'remember') {
    auth_require_writer();
    $line = trim((string)($in['text'] ?? ''));
    $line = preg_replace('/\s+/u', ' ', $line);
    if ($line === '') prof_out(['ok' => false, 'error' => 'Nothing to remember']);
    if (mb_strlen($line) > 300) $line = mb_substr($line, 0, 300) . '…';
    $cur = is_readable($PROF_F) ? (string)file_get_contents($PROF_F) : '';
    // Don't add the same fact twice — this path is one click and people click twice.
    if ($cur !== '' && str_contains($cur, $line)) prof_out(['ok' => true, 'duplicate' => true, 'bytes' => strlen($cur)]);
    $add = ($cur === '' ? "# Profile\n\n" : rtrim($cur) . "\n") . '- ' . $line . "\n";
    if (strlen($add) > PROFILE_MAX_BYTES) {
        prof_out(['ok' => false, 'error' => 'The profile is full (' . PROFILE_MAX_BYTES . ' bytes). Open it and prune before adding more.']);
    }
    if (@file_put_contents($PROF_F, $add, LOCK_EX) === false) prof_out(['ok' => false, 'error' => 'Could not write the profile']);
    @chmod($PROF_F, 0664);
    prof_out(['ok' => true, 'bytes' => strlen($add), 'line' => $line]);
}

prof_out(['ok' => false, 'error' => 'Unknown action: ' . $action]);
