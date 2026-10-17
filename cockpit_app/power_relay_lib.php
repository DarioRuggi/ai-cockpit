<?php
// =============================================================================
// power_relay_lib.php — Power Buttons from your phone (Everywhere). The relay page sends a prompt to this machine like any other; when that prompt starts with  /power  it is NOT given to the
// chat: it names a Power Button and carries the text to work on, and the button runs HERE with the home machine's own supplier, consent and caps (via power_run → power.php).
//
//   /power                      → the list of your buttons
//   /power Proofread            → (the text follows on the next lines, or the same line after the name when it is one word / an id)
//   Hello wrold, how are you
//   /power "Make it polite" text on the same line
//
// Nothing about a button travels from the phone but its name: the prompt, the supplier and the safety rules are all on the home machine. A button that needs a confirmation (a cloud supplier
// for the first time) or that sees a secret in the text stops and says so in the answer - the phone cannot confirm it, that happens at the home machine in Cockpit.
// =============================================================================

/** → null when the prompt is not a /power command, else ['list'=>true] or ['button'=>name,'text'=>…]. */
function relay_power_parse(string $prompt): ?array {
    $p = ltrim($prompt); if (!preg_match('/^\/power(?:\s|$)/i', $p)) return null;
    $rest = ltrim(substr($p, 6)); if ($rest === '') return ['list' => true];
    if (strtolower($rest) === 'list') return ['list' => true];
    $btn = ''; $text = '';
    if ($rest[0] === '"' || $rest[0] === "'") { $q = $rest[0]; $end = strpos($rest, $q, 1); if ($end === false) return ['error' => 'A quote was opened and never closed after /power.']; $btn = substr($rest, 1, $end - 1); $text = substr($rest, $end + 1); }
    else { $nl = strpos($rest, "\n"); $first = $nl === false ? $rest : substr($rest, 0, $nl); if (preg_match('/^(\S+)(?:[ \t]+(.*))?$/s', $first, $m)) { $btn = $m[1]; $text = (isset($m[2]) ? $m[2] : '') . ($nl === false ? '' : substr($rest, $nl)); } }
    $text = preg_replace('/^[ \t]*\n/', '', $text, 1); $text = ltrim($text, " \t");
    if ($btn === '') return ['list' => true];
    return ['button' => $btn, 'text' => rtrim($text, "\n")];
}
/** Run it: power_run reads the text from stdin and prints the answer. → the text to send back to the phone. $run: a command prefix (php + power_run), $extra: --data-root etc. */
function relay_power_run(array $cmd, string $runPhp, array $extra = []): string {
    $argv = array_merge([PHP_BINARY ?: 'php', $runPhp], isset($cmd['list']) ? ['--list'] : [$cmd['button'], '--from', 'stdin', '--to', 'stdout', '--quiet'], $extra);
    $p = @proc_open($argv, [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pp); if (!is_resource($p)) return 'Could not start the Power Button runner on the home machine.';
    fwrite($pp[0], (string)($cmd['text'] ?? '')); fclose($pp[0]);
    $out = stream_get_contents($pp[1]); $err = stream_get_contents($pp[2]); fclose($pp[1]); fclose($pp[2]); $rc = proc_close($p);
    if ($rc === 0) { $out = trim((string)$out); return isset($cmd['list']) ? ($out === '' ? 'You have no Power Buttons yet. Add some in Cockpit.' : "Your Power Buttons:\n" . $out . "\n\nSend  /power NAME  and then the text.") : $out; }
    return 'The button did not run: ' . trim(preg_replace('/^power_run:\s*/', '', (string)$err)) . ($rc === 2 ? ' (open Cockpit on the home machine to answer this)' : '');
}
