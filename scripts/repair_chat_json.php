#!/usr/bin/env php
<?php
// repair_chat_json.php — re-escape raw control characters inside JSON strings
// of chat_*.json files written by old agent_loop versions (before json_escape
// handled newlines). Same algorithm as files.php::healJson, applied on disk so
// strict readers (PHP json_decode, jq, the chat index) can parse the file.
//
// Usage:  php scripts/repair_chat_json.php [--dry-run] <projects_root>
// Writes <file>.bak next to each repaired file. Never touches a file that
// already parses, and never writes a result that does not parse.
$dry = false; $root = '';
foreach (array_slice($argv, 1) as $a) { if ($a === '--dry-run') $dry = true; else $root = $a; }
if ($root === '' || !is_dir($root)) { fwrite(STDERR, "usage: repair_chat_json.php [--dry-run] <projects_root>\n"); exit(2); }

function heal(string $raw): string {
    $len = strlen($raw); $out = ''; $inStr = false;
    for ($i = 0; $i < $len; $i++) {
        $c = $raw[$i];
        if ($c === '"' && ($i === 0 || $raw[$i-1] !== '\\')) { $inStr = !$inStr; $out .= $c; continue; }
        if ($inStr && ord($c) < 0x20 && $c !== "\t") {
            if ($c === "\n") $out .= '\\n';
            elseif ($c === "\r") $out .= '\\r';
            else $out .= sprintf('\\u%04x', ord($c));
        } else { $out .= $c; }
    }
    return $out;
}

$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS));
$seen = $bad = $fixed = $failed = 0;
foreach ($it as $f) {
    $p = $f->getPathname();
    if (!preg_match('~/chat_[^/]+\.json$~', $p)) continue;
    $seen++;
    $raw = (string)file_get_contents($p);
    if (json_decode($raw, true) !== null) continue;
    $bad++;
    $healed = heal($raw);
    if (json_decode($healed, true) === null) { $failed++; echo "FAILED  $p (" . json_last_error_msg() . ")\n"; continue; }
    if ($dry) { echo "WOULD FIX $p\n"; continue; }
    copy($p, "$p.bak");
    file_put_contents($p, $healed, LOCK_EX);
    $fixed++; echo "FIXED   $p\n";
}
echo "chat files: $seen  invalid: $bad  fixed: $fixed  unfixable: $failed" . ($dry ? "  (dry-run)" : '') . "\n";
exit($failed ? 1 : 0);
