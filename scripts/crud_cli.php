<?php
// =============================================================================
// crud_cli.php — crud_executor.sh as PHP.
//
//   php crud_cli.php PROJECT_DIR RESPONSE_FILE [PROPOSER] [PROJECT_NAME]
//
// Reads an agent's response, carries out the %%COMMAND%% markers in it inside the project directory and prints one
// result line (or block) per command — exactly what crud_executor.sh prints, which agent_loop.sh captures and shows
// the agent on its next turn. The Bash used `jq`, `awk`, `sed`, `curl`, `head`, `realpath`; this uses none of them
// except `ls` (for LIST, to keep its exact format) and PHP's own curl.
//
// THE BASH IS THE REFERENCE and tests/crud_parity.sh compares the two on the same inputs: output, files written, and the
// requests sent to the web endpoints. Its quirks are reproduced and marked "QUIRK". DELIBERATE DIFFERENCES (a safer
// answer than the Bash gave) are marked "DIFFERENCE" and listed at the end of this header:
//   * %%DELETE:%% of the project directory itself (".", "./", "sub/..") is refused. The Bash resolved it to the project
//     root, which passed its own containment test, and `rm -rf`'d the whole project.
//
// Markers (case-insensitive): CREATE/UPDATE/APPEND:path ... %%END%%, PROPOSE:snippet|source|library ... %%END%%,
// READ, DELETE (needs %%CONFIRM:DELETE%% anywhere in the response), MKDIR, LIST, FETCH, SEARCH, WORKER, TOOL,
// LOAD_SKILL, LIB, SNIP, SRC.
//
// Environment: HOME, COCKPIT_ROOT, COCKPIT_DATA_USER (the user's cockpit_data, for LIB/SNIP/SRC and library text),
// COCKPIT_BASE_URL (default http://localhost/cockpit — the web endpoints FETCH/SEARCH/WORKER/TOOL/PROPOSE call).
// =============================================================================

if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }

const READ_MAX = 16384;                                         // READ cap (HIGH-31): matches the SNIP/SRC caps

$PROJECT_DIR   = $argv[1] ?? '';
$RESPONSE_FILE = $argv[2] ?? '';
$PROPOSER      = ($argv[3] ?? '') !== '' ? $argv[3] : 'unknown';
$PROJECT_NAME  = ($argv[4] ?? '') !== '' ? $argv[4] : 'default';

if ($PROJECT_DIR === '' || !is_dir($PROJECT_DIR)) exit(0);
if ($RESPONSE_FILE === '' || !is_file($RESPONSE_FILE)) exit(0);

$raw = (string)file_get_contents($RESPONSE_FILE);
if (strpos($raw, '%%') === false) exit(0);                       // quick check: no markers, nothing to do

$PROJECT_DIR = realpath($PROJECT_DIR);
$HOME = getenv('HOME') ?: '';
$COCKPIT_DATA = $HOME . '/scripts/cockpit_data';
@mkdir($COCKPIT_DATA, 0777, true);
$DATA_USER = getenv('COCKPIT_DATA_USER') ?: '';
$BASE = rtrim(getenv('COCKPIT_BASE_URL') ?: 'http://localhost/cockpit', '/');
// The loop's own credential for the four pages it calls (internal_auth.php); without it those pages answer 401, as before.
$INTERNAL_HDRS = (getenv('COCKPIT_INTERNAL_KEY') !== false && getenv('COCKPIT_INTERNAL_KEY') !== '' && (string)getenv('COCKPIT_INTERNAL_USER') !== '')
    ? ['X-Cockpit-Internal: ' . getenv('COCKPIT_INTERNAL_KEY'), 'X-Cockpit-User: ' . getenv('COCKPIT_INTERNAL_USER')] : [];

function out(string $s): void { fwrite(STDOUT, $s); }
function line_out(string $s): void { fwrite(STDOUT, $s . "\n"); }

// ---- reading like `while IFS= read -r line || [ -n "$line" ]` ---------------------------------------------------
// Lines split on LF; a final line without LF is still a line when non-empty; NUL bytes are dropped; CR stays.
function bash_lines(string $raw): array {
    $raw = str_replace("\0", '', $raw);
    $parts = explode("\n", $raw);
    if (end($parts) === '') array_pop($parts);
    return $parts;
}

// ---- the sandbox ----------------------------------------------------------------------------------------------------
// realpath -m: symlinks in the parts that exist are followed, parts that do not exist are resolved lexically.
function realpath_m(string $path): string {
    $todo = array_reverse(explode('/', $path));
    $cur = '';                                                    // the resolved path so far ('' = root)
    $links = 0;
    while ($todo) {
        $c = array_pop($todo);
        if ($c === '' || $c === '.') continue;
        if ($c === '..') { $cur = dirname($cur === '' ? '/' : $cur); if ($cur === '/') $cur = ''; continue; }
        $cand = $cur . '/' . $c;
        if (is_link($cand)) {
            if (++$links > 40) return $path;                      // ELOOP: realpath fails, the Bash then keeps the unresolved path
            $t = readlink($cand);
            if ($t === false) return $path;
            if ($t !== '' && $t[0] === '/') $cur = '';
            foreach (array_reverse(explode('/', $t)) as $tc) $todo[] = $tc;
            continue;
        }
        $cur = $cand;
    }
    return $cur === '' ? '/' : $cur;
}

// safe_path: the full path, or '' when it leaves the project. "$resolved/" must start with "$PROJECT_DIR/".
function safe_path(string $rel): string {
    global $PROJECT_DIR;
    if ($rel !== '' && $rel[0] === '/') $rel = substr($rel, 1);     // strip ONE leading /
    // QUIRK: the Bash passes it through `echo "$rel" | sed`, and echo takes -n / -e / -E for options
    if (preg_match('/^-[neE]+$/', $rel)) $rel = '';
    $rel = preg_replace('~\.\./~', '', $rel);                       // strip traversal (one pass, as sed 's|\.\./||g')
    $resolved = realpath_m($PROJECT_DIR . '/' . $rel);
    return strncmp($resolved . '/', $PROJECT_DIR . '/', strlen($PROJECT_DIR) + 1) === 0 ? $resolved : '';
}

// ---- helpers shared by the web-calling markers ----------------------------------------------------------------
function curl_run(string $url, int $maxTime, ?string $postBody = null, bool $follow = false, bool $internal = true): ?string {
    if (!function_exists('curl_init')) return null;
    $ch = curl_init($url);
    curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => $maxTime, CURLOPT_CONNECTTIMEOUT => $maxTime, CURLOPT_FOLLOWLOCATION => $follow]);
    global $INTERNAL_HDRS;
    $hdrs = ($internal && strpos($url, $GLOBALS['BASE'] . '/') === 0) ? $INTERNAL_HDRS : [];     // never hand the key to a URL an agent chose, or to a catalog entry's URL
    if ($postBody !== null) { curl_setopt($ch, CURLOPT_POST, true); curl_setopt($ch, CURLOPT_POSTFIELDS, $postBody); $hdrs[] = 'Content-Type: application/json'; }
    if ($hdrs) curl_setopt($ch, CURLOPT_HTTPHEADER, $hdrs);
    $r = curl_exec($ch);
    curl_close($ch);
    return $r === false ? '' : (string)$r;                           // a failed request is an empty answer, as with curl -s
}
function trim_nl(string $s): string { return rtrim($s, "\n"); }     // what $( ... ) does to the end of what it captures

// jq -r '.key // "default"' on a decoded JSON object: null/false -> default; strings raw; anything else as JSON text
function jq_alt($data, string $key, string $default): string {
    if (!is_array($data) || array_is_list($data) && $data !== []) return $default;
    $v = $data[$key] ?? null;
    if ($v === null || $v === false) return $default;
    if (is_string($v)) return $v;
    if ($v === true) return 'true';
    if (is_int($v) || is_float($v)) return (string)json_encode($v);
    return (string)json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_PRETTY_PRINT);
}
function decode_obj(string $s) { $d = json_decode($s, true); return is_array($d) ? $d : null; }
function mb_cap(string $s, int $n): string { return mb_strlen($s) > $n ? mb_substr($s, 0, $n) : $s; }

function json_esc(string $s): string {                               // ${s//\\/\\\\} ${s//\"/\\\"} then \n \r \t
    return str_replace(["\\", '"', "\n", "\r", "\t"], ["\\\\", '\\"', '\\n', '\\r', '\\t'], $s);
}

// ---- pass 1: the multi-line blocks ------------------------------------------------------------------------------------
$lines = bash_lines($raw);
$HAS_CONFIRM = strpos($raw, '%%CONFIRM:DELETE%%') !== false;

$mode = 'scan'; $cmd = ''; $cmd_path = ''; $collected = ''; $propose_kind = '';
foreach ($lines as $line) {
    if ($mode === 'scan') {
        if (preg_match('/%%([Cc][Rr][Ee][Aa][Tt][Ee]|[Uu][Pp][Dd][Aa][Tt][Ee]|[Aa][Pp][Pp][Ee][Nn][Dd]):([^%]+)%%/', $line, $m)) {
            $cmd = strtoupper($m[1]); $cmd_path = $m[2]; $collected = ''; $mode = 'collect';
            continue;
        }
        if (preg_match('/%%[Pp][Rr][Oo][Pp][Oo][Ss][Ee]:([Ss][Nn][Ii][Pp][Pp][Ee][Tt]|[Ss][Oo][Uu][Rr][Cc][Ee]|[Ll][Ii][Bb][Rr][Aa][Rr][Yy])%%/', $line, $m)) {
            $cmd = 'PROPOSE'; $propose_kind = strtolower($m[1]); $collected = ''; $mode = 'collect';
            continue;
        }
        continue;
    }
    // collect
    if (strpos($line, '%%END%%') === false) {
        // QUIRK: "if [ -z $collected ]" — while nothing but empty lines has been seen, an empty line is simply dropped
        $collected = $collected === '' ? $line : $collected . "\n" . $line;
        continue;
    }
    // %%END%% anywhere in the line closes the block (the whole line, including text before the marker, is discarded)
    if ($cmd === 'PROPOSE') {
        $title = $lang = $location = $kind_kv = $notes = $content_buf = ''; $in_content = false;
        $kv = $collected === '' ? [''] : explode("\n", $collected);     // <<< "$collected": the here-string adds the final newline
        if ($collected === '') $kv = [''];
        foreach ($kv as $kvline) {
            if ($in_content) { $content_buf = $content_buf === '' ? $kvline : $content_buf . "\n" . $kvline; continue; }
            $val = function (string $key) use ($kvline): string {
                $v = substr($kvline, strlen($key));
                if ($v !== '' && $v[0] === ' ') $v = substr($v, 1);        // ${v# }
                if ($v !== '' && substr($v, -1) === "\r") $v = substr($v, 0, -1);   // ${v%$'\r'}
                return $v;
            };
            if (strncmp($kvline, 'title:', 6) === 0) $title = $val('title:');
            elseif (strncmp($kvline, 'lang:', 5) === 0) $lang = $val('lang:');
            elseif (strncmp($kvline, 'location:', 9) === 0) $location = $val('location:');
            elseif (strncmp($kvline, 'kind:', 5) === 0) $kind_kv = $val('kind:');
            elseif (strncmp($kvline, 'notes:', 6) === 0) $notes = $val('notes:');
            elseif (strncmp($kvline, 'content:', 8) === 0) {
                $in_content = true;
                $rest = substr($kvline, 8); if ($rest !== '' && $rest[0] === ' ') $rest = substr($rest, 1);
                if ($rest !== '') $content_buf = $rest;
            }
        }
        $t = json_esc($title); $l = json_esc($lang); $loc = json_esc($location); $kk = json_esc($kind_kv); $n = json_esc($notes); $c = json_esc($content_buf);
        $payload = '';
        if ($propose_kind === 'library') $payload = '{"title":"' . $t . '","location":"' . $loc . '","kind":"' . ($kk !== '' ? $kk : 'path') . '","notes":"' . $n . '"}';
        elseif ($propose_kind === 'snippet' || $propose_kind === 'source') $payload = '{"title":"' . $t . '","lang":"' . $l . '","notes":"' . $n . '","content":"' . $c . '"}';
        $body = '{"action":"proposal_add","propose_kind":"' . $propose_kind . '","proposer":"' . $PROPOSER . '","project":"' . $PROJECT_NAME . '","payload":' . $payload . '}';
        if (function_exists('curl_init')) {
            // curl -s ... && OK || ERR: only a failure to connect makes curl fail; any HTTP answer counts as OK
            $ch = curl_init($BASE . '/library.php');
            curl_setopt_array($ch, [CURLOPT_RETURNTRANSFER => true, CURLOPT_POST => true, CURLOPT_POSTFIELDS => $body, CURLOPT_HTTPHEADER => array_merge(['Content-Type: application/json'], $INTERNAL_HDRS), CURLOPT_TIMEOUT => 60]);
            $r = curl_exec($ch); curl_close($ch);
            if ($r !== false) line_out("[CRUD:OK] PROPOSE $propose_kind: \"$title\" — pending approval");
            else line_out("[CRUD:ERR] PROPOSE $propose_kind: failed to enqueue");
        } else line_out("[CRUD:ERR] PROPOSE $propose_kind: curl unavailable, cannot enqueue");
    } else {
        $full = safe_path($cmd_path);
        if ($full === '') line_out("[CRUD:ERR] $cmd rejected — path outside project: $cmd_path");
        else {
            @mkdir(dirname($full), 0777, true);
            if ($cmd === 'CREATE' || $cmd === 'UPDATE') {
                if (@file_put_contents($full, $collected . "\n") === false) fwrite(STDERR, "crud_cli: cannot write $full\n");
                @chmod($full, 0664);
                clearstatcache(); $size = is_file($full) ? filesize($full) : '?';
                line_out("[CRUD:OK] CREATE $cmd_path ($size bytes)");            // QUIRK: UPDATE is reported as CREATE
            } else {   // APPEND
                if (@file_put_contents($full, $collected . "\n", FILE_APPEND) === false) fwrite(STDERR, "crud_cli: cannot append to $full\n");
                clearstatcache(); $size = is_file($full) ? filesize($full) : '?';
                line_out("[CRUD:OK] APPEND $cmd_path ($size bytes)");
            }
        }
    }
    $mode = 'scan'; $cmd = ''; $cmd_path = ''; $collected = ''; $propose_kind = '';
}

// ---- pass 2: the single-line commands ----------------------------------------------------------------------------------
// QUIRK: this pass reads EVERY line of the response, including the lines inside the CREATE/APPEND/PROPOSE blocks above,
// so a %%READ:x%% inside a file's content runs as well. Kept.
foreach ($lines as $line) {

    // %%FETCH:url%%
    if (preg_match('/%%[Ff][Ee][Tt][Cc][Hh]:([^%]+)%%/', $line, $m)) {
        $furl = $m[1];
        if (!function_exists('curl_init')) { line_out("[CRUD:ERR] FETCH \"$furl\" — curl unavailable"); continue; }
        $enc = $furl;
        if (preg_match('/^-[neE]+$/', $enc)) $enc = '';                         // QUIRK: echo "$furl" | sed
        $enc = trim_nl(str_replace(['&', '?', ' '], ['%26', '%3F', '%20'], $enc));
        $result = trim_nl((string)curl_run($BASE . '/search.php?action=fetch&url=' . $enc, 20));
        if ($result === '') { line_out("[CRUD:ERR] FETCH \"$furl\" — no response"); continue; }
        line_out("[CRUD:INFO] FETCH $furl:");
        // awk: on each line holding "text": drop everything up to the value, unescape \n \t \" \\ (in that order), drop the closing quote
        foreach (explode("\n", $result) as $rl) {
            if (strpos($rl, '"text"') === false) continue;
            $s = preg_replace('/^.*"text"[^"]*"/s', '', $rl, 1);
            $s = str_replace('\\n', "\n", $s); $s = str_replace('\\t', "\t", $s); $s = str_replace('\\"', '"', $s); $s = str_replace('\\\\', '\\', $s);
            $s = preg_replace('/"[,}]?[ \t\r\n\f\v]*$/', '', $s, 1);
            line_out($s);
        }
        line_out('');
        continue;
    }

    // %%LOAD_SKILL:id%%
    if (preg_match('/%%[Ll][Oo][Aa][Dd]_[Ss][Kk][Ii][Ll][Ll]:([^%]+)%%/', $line, $m)) {
        $sk_id = preg_replace('/[^a-zA-Z0-9._-]/', '', $m[1]);
        $sk_file = $COCKPIT_DATA . '/skills/' . $sk_id . '/SKILL.md';
        if ($sk_id !== '' && is_file($sk_file)) {
            line_out("[CRUD:INFO] LOAD_SKILL $sk_id:");
            // awk: drop a leading --- ... --- front matter (line 1 opens it, the next --- closes it); then head -c READ_MAX.
            // awk prints every kept line with a newline, also a final line that had none.
            $content = (string)file_get_contents($sk_file);
            $kept = '';
            if ($content !== '') {
                $all = explode("\n", $content);
                if (substr($content, -1) === "\n") array_pop($all);
                $fm = false;
                foreach ($all as $i => $sline) {
                    if ($i === 0 && preg_match('/^---[ \t\r\n\f\v]*$/', $sline)) { $fm = true; continue; }
                    if ($fm && preg_match('/^---[ \t\r\n\f\v]*$/', $sline)) { $fm = false; continue; }
                    if (!$fm) $kept .= $sline . "\n";
                }
            }
            out(substr($kept, 0, READ_MAX));
            line_out('');
        } else line_out('[CRUD:ERR] LOAD_SKILL ' . ($sk_id !== '' ? $sk_id : '?') . ' — skill not found');
        continue;
    }

    // %%READ:path%%
    if (preg_match('/%%[Rr][Ee][Aa][Dd]:([^%]+)%%/', $line, $m)) {
        $rel = $m[1];
        $full = safe_path($rel);
        if ($full === '') line_out("[CRUD:ERR] READ rejected — path outside project: $rel");
        elseif (!is_file($full)) line_out("[CRUD:ERR] READ $rel — file not found");
        else {
            line_out("[CRUD:INFO] READ $rel:");
            $data = (string)file_get_contents($full);
            out(substr($data, 0, READ_MAX));
            line_out('');
            if (strlen($data) > READ_MAX) line_out('[... truncated to first ' . READ_MAX . ' bytes]');
        }
        continue;
    }

    // %%SEARCH:query%%
    if (preg_match('/%%[Ss][Ee][Aa][Rr][Cc][Hh]:([^%]+)%%/', $line, $m)) {
        $sq = $m[1];
        if (!function_exists('curl_init')) { line_out("[CRUD:ERR] SEARCH \"$sq\" — curl unavailable"); continue; }
        $enc = $sq;
        if (preg_match('/^-[neE]+$/', $enc)) $enc = '';
        $enc = trim_nl(str_replace([' ', '&', '?'], ['+', '%26', '%3F'], $enc));
        $result = trim_nl((string)curl_run($BASE . '/search.php?action=search&n=5&q=' . $enc, 12));
        if ($result === '') { line_out("[CRUD:ERR] SEARCH \"$sq\" — no response"); continue; }
        line_out("[CRUD:INFO] SEARCH \"$sq\":");
        // awk with RS=",": every comma-separated record is tested for "title", "url" and "snippet"; a snippet record prints
        $title = $url = ''; $n = 0;
        foreach (explode(',', $result . "\n") as $rec) {
            if (strpos($rec, '"title"') !== false) { $s = preg_replace('/^.*"title"[^"]*"/s', '', $rec, 1); $title = preg_replace('/".*$/s', '', $s, 1); $n++; }
            if (strpos($rec, '"url"') !== false) { $s = preg_replace('/^.*"url"[^"]*"/s', '', $rec, 1); $url = preg_replace('/".*$/s', '', $s, 1); }
            if (strpos($rec, '"snippet"') !== false) {
                $s = preg_replace('/^.*"snippet"[^"]*"/s', '', $rec, 1); $snip = preg_replace('/".*$/s', '', $s, 1);
                line_out($n . '. ' . $title);
                line_out('   ' . $url);
                if (strlen($snip) > 0) line_out('   ' . $snip);
                line_out('');
            }
        }
        continue;
    }

    // %%WORKER:provider:task:prompt%%
    if (preg_match('/%%[Ww][Oo][Rr][Kk][Ee][Rr]:([^:]+):([^:]+):([^%]+)%%/', $line, $m)) {
        [, $w_provider, $w_task, $w_prompt] = $m;
        if (!function_exists('curl_init')) { line_out("[CRUD:ERR] WORKER \"$w_provider\" — curl unavailable"); continue; }
        $models = trim_nl((string)curl_run($BASE . '/workers.php?action=models', 6));
        $w_model = '';
        // grep -oE '"provider":"<provider>","model":"[^"]+"' | head -1 | sed 's/.*"model":"\([^"]*\)".*/\1/'
        if (@preg_match_all('/"provider":"' . str_replace('/', '\\/', $w_provider) . '","model":"[^"]+"/', $models, $mm) && $mm[0]) {
            $w_model = preg_replace('/^.*"model":"([^"]*)".*$/s', '$1', $mm[0][0]);
        }
        if ($w_model === '') { line_out("[CRUD:ERR] WORKER $w_provider — no enabled model. Configure provider via WORKERS settings."); continue; }
        $payload = json_encode(['provider' => $w_provider, 'model' => $w_model, 'task' => $w_task, 'prompt' => $w_prompt, 'extra' => new stdClass()], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        $result = trim_nl((string)curl_run($BASE . '/workers.php?action=invoke', 90, $payload));
        if ($result === '') { line_out("[CRUD:ERR] WORKER $w_provider — no response"); continue; }
        $d = decode_obj($result);
        $ok = $d === null ? '' : jq_alt($d, 'ok', 'false');                       // jq on text that is not JSON: no output at all
        if ($ok === 'true') {
            $kind = jq_alt($d, 'kind', 'text');
            $output = trim_nl(jq_alt($d, 'output', ''));
            if (mb_strlen($output) > 4096) $output = mb_substr($output, 0, 4096) . '... [truncated, ' . (mb_strlen($output) - 4096) . ' more chars]';
            line_out("[CRUD:INFO] WORKER $w_provider · $w_model · $kind:");
            line_out($output);
            line_out("[CRUD:OK] %%WORKER_RESULT:$w_provider:$kind:done%%");
        } else {
            $err = $d === null ? '' : jq_alt($d, 'error', 'unknown');
            line_out("[CRUD:ERR] WORKER $w_provider — $err");
        }
        continue;
    }

    // %%TOOL:tool:preset:input[|extra]%%
    if (preg_match('/%%[Tt][Oo][Oo][Ll]:([^:]+):([^:]+):([^%]+)%%/', $line, $m)) {
        [, $t_tool, $t_preset, $t_rest] = $m;
        $p = strpos($t_rest, '|');
        if ($p !== false) { $t_input = substr($t_rest, 0, $p); $t_extra = substr($t_rest, $p + 1); } else { $t_input = $t_rest; $t_extra = ''; }
        if (!function_exists('curl_init')) { line_out("[CRUD:ERR] TOOL \"$t_tool\" — curl unavailable"); continue; }
        $payload = json_encode(['tool' => $t_tool, 'preset' => $t_preset, 'input' => $t_input, 'extra_args' => $t_extra, 'project' => $PROJECT_NAME], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
        $result = trim_nl((string)curl_run($BASE . '/tools.php?action=run', 320, $payload));
        if ($result === '') { line_out("[CRUD:ERR] TOOL $t_tool — no response"); continue; }
        $d = decode_obj($result);
        if ($d === null) { line_out("[CRUD:ERR] TOOL $t_tool — the tools page did not answer in the expected form (wrong address or not signed in): " . substr(preg_replace('/[ \\n]+/', ' ', $result . "\n"), 0, 160)); continue; }
        $ok = jq_alt($d, 'ok', 'false');
        if ($ok === 'true') {
            $output = trim_nl(jq_alt($d, 'output', ''));
            $size = trim_nl(jq_alt($d, 'output_size', '0'));
            $ms = trim_nl(jq_alt($d, 'elapsed_ms', '0'));
            line_out("[CRUD:INFO] TOOL $t_tool · $t_preset done in {$ms}ms ({$size} bytes):");
            line_out("  Output: $output");
            line_out("[CRUD:OK] %%TOOL_RESULT:$t_tool:$output%%");
        } else {
            $err = $d === null ? '' : jq_alt($d, 'error', 'unknown');
            $rc = $d === null ? '' : jq_alt($d, 'rc', '-1');
            line_out("[CRUD:ERR] TOOL $t_tool — $err (rc=$rc)");
            $log = $d === null ? '' : substr(trim_nl(jq_alt($d, 'log', '')) . "\n", 0, 400);   // | head -c 400 (of text that ends in a newline)
            $log = trim_nl($log);
            if ($log !== '') line_out("  Log: $log");
        }
        continue;
    }

    // %%LIB:..%% %%SNIP:..%% %%SRC:..%%
    $cat_kind = ''; $cq = '';
    if (preg_match('/%%[Ll][Ii][Bb]:([^%]+)%%/', $line, $m)) { $cat_kind = 'library'; $cq = $m[1]; }
    elseif (preg_match('/%%[Ss][Nn][Ii][Pp]:([^%]+)%%/', $line, $m)) { $cat_kind = 'snippets'; $cq = $m[1]; }
    elseif (preg_match('/%%[Ss][Rr][Cc]:([^%]+)%%/', $line, $m)) { $cat_kind = 'sources'; $cq = $m[1]; }
    if ($cat_kind !== '') {
        $tag = $cat_kind === 'library' ? 'LIB' : ($cat_kind === 'snippets' ? 'SNIP' : 'SRC');
        $cq_lc = trim(strtr($cq, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), " \t\n\r\f\v");
        $hit = null;
        foreach ([$DATA_USER . '/library_index.json', $COCKPIT_DATA . '/library_index.json', $PROJECT_DIR . '/library_index.json'] as $idx) {
            if (!is_file($idx)) continue;
            $hit = catalog_find((string)file_get_contents($idx), $cat_kind, $cq_lc);
            if ($hit !== null) break;
        }
        if ($hit === null) { line_out("[CRUD:ERR] $tag \"$cq\" — no entry found"); line_out(''); continue; }
        $m_id = jq_alt($hit, 'id', ''); $m_title = jq_alt($hit, 'title', ''); $m_file = jq_alt($hit, 'file_path', '');
        $m_url = jq_alt($hit, 'url', ''); $m_path = jq_alt($hit, 'path', '');
        if ($m_file === '' && $cat_kind === 'library' && $m_id !== '')
            foreach ([$DATA_USER, $COCKPIT_DATA] as $d) if (is_file($d . '/library_text/' . $m_id . '.txt')) { $m_file = $d . '/library_text/' . $m_id . '.txt'; break; }
        if ($m_file === '' && $m_path !== '' && is_file($m_path)) $m_file = $m_path;
        line_out("[CRUD:INFO] $tag \"$m_title\":");
        if ($m_file !== '' && is_file($m_file)) {
            $data = (string)file_get_contents($m_file);
            out(substr($data, 0, 16384)); line_out('');
            if (strlen($data) > 16384) line_out('[... truncated to first 16KB]');
        } elseif ($m_url !== '' && function_exists('curl_init')) {
            $body = (string)curl_run($m_url, 20, null, true, false);
            $txt = preg_replace('/<[^>]*>/', ' ', $body);                 // sed 's/<[^>]*>/ /g'  (per line: a tag never spans lines)
            $txt = preg_replace('/([ \n])\1+/', '$1', $txt);              // tr -s ' \n': squeeze runs of the SAME character
            out(substr($txt, 0, 8192)); line_out('');
        } else line_out("[CRUD:ERR] $tag \"$m_title\" — nothing stored to read (no file, path or url)");
        line_out('');
        continue;
    }

    // %%DELETE:path%%
    if (preg_match('/%%[Dd][Ee][Ll][Ee][Tt][Ee]:([^%]+)%%/', $line, $m)) {
        $rel = $m[1];
        if (!$HAS_CONFIRM) { line_out("[CRUD:ERR] DELETE $rel — missing %%CONFIRM:DELETE%% in response"); continue; }
        $full = safe_path($rel);
        if ($full === '') line_out("[CRUD:ERR] DELETE rejected — path outside project: $rel");
        elseif ($full === $PROJECT_DIR) line_out("[CRUD:ERR] DELETE rejected — that is the project directory itself: $rel");   // DIFFERENCE
        elseif (!file_exists($full) && !is_link($full)) line_out("[CRUD:ERR] DELETE $rel — not found");
        else { rm_rf($full); line_out("[CRUD:OK] DELETE $rel"); }
        continue;
    }

    // %%MKDIR:path%%
    if (preg_match('/%%[Mm][Kk][Dd][Ii][Rr]:([^%]+)%%/', $line, $m)) {
        $rel = $m[1];
        $full = safe_path($rel);
        if ($full === '') line_out("[CRUD:ERR] MKDIR rejected — path outside project: $rel");
        else { @mkdir($full, 0777, true); @chmod($full, 0775); line_out("[CRUD:OK] MKDIR $rel"); }
        continue;
    }

    // %%LIST:subpath%%  /  %%LIST%%
    if (preg_match('/%%[Ll][Ii][Ss][Tt]:([^%]*)%%/', $line, $m)) {
        $rel = $m[1];
        if ($rel === '') { $dir = $PROJECT_DIR; $label = '.'; } else { $dir = safe_path($rel); $label = $rel; }
        if ($dir === '' || !is_dir($dir)) line_out('[CRUD:ERR] LIST ' . ($rel !== '' ? $rel : '.') . ' — directory not found');
        else { line_out("[CRUD:INFO] LIST $label:"); out((string)shell_exec('ls -la ' . escapeshellarg($dir) . ' | tail -n +4')); line_out(''); }
        continue;
    }
    if (preg_match('/%%[Ll][Ii][Ss][Tt]%%/', $line)) {
        line_out('[CRUD:INFO] LIST .:'); out((string)shell_exec('ls -la ' . escapeshellarg($PROJECT_DIR) . ' | tail -n +4')); line_out('');
        continue;
    }
}
exit(0);

// ---- helpers used above (defined after the main flow, hoisted by PHP) ---------------------------------------------------
function rm_rf(string $p): void {
    if (is_link($p) || is_file($p)) { @unlink($p); return; }
    foreach (scandir($p) ?: [] as $e) { if ($e === '.' || $e === '..') continue; rm_rf($p . '/' . $e); }
    @rmdir($p);
}

// jq -c --arg k KIND --arg q QUERY '(.[$k] // [])[] | select(id == q or title lowercased == q or title lowercased contains q)' | head -1
// A runtime error in jq (a title that is not a string) ends the scan: what matched before it still counts.
function catalog_find(string $json, string $kind, string $q): ?array {
    $d = json_decode($json, true);
    if (!is_array($d)) return null;
    $arr = $d[$kind] ?? null;
    if ($arr === null || $arr === false) return null;
    if (!is_array($arr)) return null;                              // iterating a non-array is a jq error: nothing
    foreach ($arr as $it) {
        if (!is_array($it) || array_is_list($it) && $it !== []) return null;     // .id on a non-object: jq error
        $id = $it['id'] ?? null; if ($id === null || $id === false) $id = '';
        if ($id === $q) return $it;
        $t = $it['title'] ?? null; if ($t === null || $t === false) $t = '';
        if (!is_string($t)) return null;                                          // ascii_downcase on a non-string: error, stop
        $tl = strtr($t, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz');
        if ($tl === $q || strpos($tl, $q) !== false) return $it;
    }
    return null;
}
