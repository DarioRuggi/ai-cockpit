<?php
// =============================================================================
// kinds_lib.php — the parts of the project kinds that more than one endpoint needs: where the person's own kinds live, the one validator
// every kind goes through (the wizard, an import, the marketplace), and writing them. files.php loads and merges kinds; mkt_install.php installs
// a marketplace kind with the same rules.
// =============================================================================
function kinds_user_dir(): string {
    global $PATHS;
    return rtrim((string)($PATHS['cockpit_data'] ?? ''), '/') . '/kinds';
}
/**
 * Check and clean one kind (the same rules for the wizard, for import and for files found in the user folder). Only known fields survive.
 * Returns the cleaned kind, or null with $err set. Inline tool definitions are NOT accepted (a command line from a file is a decision, not a field).
 */
function kind_validate($k, string &$err): ?array {
    $err = '';
    if (!is_array($k)) { $err = 'not an object'; return null; }
    $str = function ($v, int $max) { return mb_substr(trim((string)(is_scalar($v) ? $v : '')), 0, $max); };
    $id = $str($k['id'] ?? '', 40);
    if (!preg_match('/^[a-z0-9\-]{1,40}$/', $id)) { $err = 'the id must be 1-40 characters: lower-case letters, digits and -'; return null; }
    $name = $str($k['name'] ?? '', 80);
    if ($name === '') { $err = 'the kind needs a name'; return null; }
    $icon = $str($k['icon'] ?? 'folder', 40); if (!preg_match('/^[a-z0-9_]{1,40}$/', $icon)) $icon = 'folder';
    $out = ['id' => $id, 'name' => $name, 'icon' => $icon, 'description' => $str($k['description'] ?? '', 300),
            'note' => $str($k['note'] ?? '', 900), 'verify' => $str($k['verify'] ?? '', 120)];
    $detect = [];
    foreach (array_slice((array)($k['detect'] ?? []), 0, 10) as $pat) {
        $pat = trim((string)$pat);
        if ($pat === '') continue;
        if (!preg_match('/^[A-Za-z0-9*?._\-\/]{1,60}$/', $pat) || strpos($pat, '..') !== false || $pat[0] === '/') { $err = 'detect pattern not accepted: ' . mb_substr($pat, 0, 40); return null; }
        $detect[] = $pat;
    }
    $out['detect'] = $detect;
    $grp = $str($k['group'] ?? '', 40); if ($grp !== '') { if (!preg_match('/^[\\p{L}\\p{N} &\/,.-]{1,40}$/u', $grp)) { $err = 'the group name is not accepted'; return null; } $out['group'] = $grp; }
    $det = $str($k['details'] ?? '', 1500); if ($det !== '') $out['details'] = $det;
    $ex = []; foreach (array_slice((array)($k['examples'] ?? []), 0, 6) as $x) { $x = $str($x, 160); if ($x !== '') $ex[] = $x; }
    if ($ex) $out['examples'] = $ex;
    $tools = [];
    foreach (array_slice((array)($k['tools'] ?? []), 0, 12) as $t) {
        if (is_string($t)) $t = ['tool' => $t];
        if (!is_array($t)) { $err = 'a tools entry is not an object'; return null; }
        if (isset($t['definition']) || isset($t['presets']) || isset($t['command'])) { $err = 'a kind cannot carry a tool definition or a command yet; name an installed tool instead'; return null; }
        $tid = $str($t['tool'] ?? '', 64);
        if (!preg_match('/^[a-z][a-z0-9_-]{0,63}$/', $tid)) { $err = 'tool id not accepted: ' . mb_substr($tid, 0, 40); return null; }
        $e = ['tool' => $tid];
        $pr = $str($t['preset'] ?? '', 64); if ($pr !== '') { if (!preg_match('/^[a-z0-9][a-z0-9_-]{0,63}$/', $pr)) { $err = 'preset id not accepted: ' . mb_substr($pr, 0, 40); return null; } $e['preset'] = $pr; }
        $why = $str($t['why'] ?? '', 160); if ($why !== '') $e['why'] = $why;
        $tools[] = $e;
    }
    if ($tools) $out['tools'] = $tools;
    $kn = [];
    foreach (array_slice((array)($k['knowledge'] ?? []), 0, 10) as $x) { $x = $str($x, 200); if ($x !== '') $kn[] = $x; }
    if ($kn) $out['knowledge'] = $kn;
    $td = [];
    foreach (array_slice((array)($k['tool_defs'] ?? []), 0, 4) as $d) { $te = ''; $c = kind_tooldef_validate($d, $te); if ($c === null) { $err = $te; return null; } $td[$c['id']] = $c; }
    if ($td) { $out['tool_defs'] = array_values($td); $have = array_column($out['tools'] ?? [], 'tool'); foreach ($td as $tid => $_) if (!in_array($tid, $have, true)) $out['tools'][] = ['tool' => $tid, 'why' => 'carried by this kind']; }
    $st = [];
    foreach (array_slice((array)($k['starter'] ?? []), 0, 12) as $f) {
        if (!is_array($f)) { $err = 'a starter entry is not an object'; return null; }
        $sp = trim((string)($f['path'] ?? '')); $sc = (string)($f['content'] ?? '');
        if (!preg_match('~^[A-Za-z0-9_][A-Za-z0-9_. /-]{0,119}$~', $sp) || strpos($sp, '..') !== false || strpos($sp, '//') !== false || substr($sp, -1) === '/') { $err = 'starter file path not accepted: ' . mb_substr($sp, 0, 40); return null; }
        if (mb_strlen($sc) > 20000) { $err = 'starter file too long (20000 characters at most): ' . $sp; return null; }
        $st[] = ['path' => $sp, 'content' => $sc];
    }
    if ($st) $out['starter'] = $st;
    if (isset($k['version']) && is_numeric($k['version'])) $out['version'] = (int)$k['version'];
    $au = $str($k['author'] ?? '', 80); if ($au !== '') $out['author'] = $au;
    return $out;
}
function kind_user_save(array $k): bool {
    $d = kinds_user_dir();
    if (!is_dir($d) && !@mkdir($d, 0775, true)) return false;
    $tmp = $d . '/.' . $k['id'] . '.tmp' . getmypid();
    if (file_put_contents($tmp, json_encode($k, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n") === false) return false;
    @chmod($tmp, 0664);
    if (!@rename($tmp, $d . '/' . $k['id'] . '.json')) { @unlink($tmp); return false; }
    return true;
}

// ---- Tool definitions carried by a kind (a kind with its own command-line tool needs no Cockpit code) ----------------------------------------
// A kind may carry up to 4 tool definitions in the format of tools_builtins/*.json, but only the NARROW form: a binary on the PATH, up to 8 presets, and for
// each a command that is the binary, plain arguments and the placeholders {INPUT} {OUTPUT} {ARGS} {NAME} -- no shell syntax at all (no ; | & < > $ ` ( ) quotes
// or backslashes), no helper scripts ({WEBROOT}), no interpreters or launchers. They are registered only after the person has been shown every command and
// agreed (files.php: confirm_tools; the marketplace install is the same path), into the user's own tool store, and never replace a built-in tool.
const KIND_TOOL_DENY = ['sh', 'bash', 'dash', 'zsh', 'ksh', 'fish', 'csh', 'tcsh', 'env', 'sudo', 'su', 'doas', 'pkexec', 'xargs', 'nohup', 'setsid', 'timeout', 'nice', 'time', 'exec', 'eval',
    'python', 'python3', 'perl', 'ruby', 'node', 'php', 'lua', 'tclsh', 'awk', 'gawk', 'mawk', 'expect', 'osascript', 'powershell', 'pwsh', 'cmd', 'rm', 'dd', 'mkfs', 'chmod', 'chown', 'mount', 'umount', 'kill', 'pkill', 'ssh', 'scp', 'nc', 'ncat', 'socat', 'telnet', 'curl', 'wget'];
function kind_tooldef_validate($d, string &$err): ?array {
    $err = '';
    if (!is_array($d)) { $err = 'a tool definition is not an object'; return null; }
    $str = fn($v, int $max) => mb_substr(trim((string)(is_scalar($v) ? $v : '')), 0, $max);
    $id = $str($d['id'] ?? '', 40);
    if (!preg_match('/^[a-z][a-z0-9_-]{1,39}$/', $id)) { $err = 'tool id not accepted: ' . mb_substr($id, 0, 40); return null; }
    if (is_file(__DIR__ . '/tools_builtins/' . $id . '.json')) { $err = "a tool called '$id' ships with Cockpit; choose another id"; return null; }
    $name = $str($d['name'] ?? '', 80); if ($name === '') $name = $id;
    $bin = $str($d['binary'] ?? '', 40);
    if (!preg_match('/^[a-z0-9][a-z0-9._+-]{0,39}$/', $bin)) { $err = "tool $id: the binary must be a plain program name (no path)"; return null; }
    if (in_array(strtolower($bin), KIND_TOOL_DENY, true)) { $err = "tool $id: '$bin' is a shell, interpreter or launcher and cannot be a kind's tool"; return null; }
    $out = ['id' => $id, 'name' => $name, 'description' => $str($d['description'] ?? '', 600), 'binary' => $bin];
    $va = $str($d['version_args'] ?? '--version', 40); if (!preg_match('/^[-A-Za-z0-9 ]{0,40}$/', $va)) $va = '--version'; $out['version_args'] = $va;
    $web = $str($d['website'] ?? '', 200); if ($web !== '' && preg_match('~^https://[A-Za-z0-9._~:/?#@!$&()*+,;=%-]+$~', $web)) $out['website'] = $web;
    $pk = [];
    foreach ((array)($d['packages'] ?? []) as $mgr => $pkgs) { if (preg_match('/^(apt|dnf|pacman|zypper|brew)$/', (string)$mgr) && preg_match('/^[a-z0-9][a-z0-9 ._+-]{0,120}$/', (string)$pkgs)) $pk[$mgr] = (string)$pkgs; }
    if ($pk) $out['packages'] = $pk;
    $presets = [];
    foreach (array_slice((array)($d['presets'] ?? []), 0, 8) as $p) {
        if (!is_array($p)) { $err = "tool $id: a preset is not an object"; return null; }
        $pid = $str($p['id'] ?? '', 40);
        if (!preg_match('/^[a-z0-9][a-z0-9_-]{0,39}$/', $pid)) { $err = "tool $id: preset id not accepted: " . mb_substr($pid, 0, 40); return null; }
        $cmd = trim((string)($p['command'] ?? ''));
        if ($cmd === '' || strlen($cmd) > 400) { $err = "tool $id, preset $pid: the command is empty or longer than 400 characters"; return null; }
        if (!preg_match('~^[A-Za-z0-9 _.,:=+/@%{}-]+$~', $cmd) || strpos($cmd, '..') !== false) { $err = "tool $id, preset $pid: the command may only hold plain words, - and the placeholders; no quotes, pipes, redirects, substitutions or '..'"; return null; }
        if (preg_match_all('/\{[^}]*\}/', $cmd, $m)) foreach ($m[0] as $ph) if (!in_array($ph, ['{INPUT}', '{OUTPUT}', '{ARGS}', '{NAME}'], true)) { $err = "tool $id, preset $pid: unknown placeholder $ph"; return null; }
        if (preg_match('/(^|\s)(-exec|-execdir|--exec|--to-command|-c|-e|--eval|--command)(\s|=|$)/', $cmd)) { $err = "tool $id, preset $pid: an option that runs another command is not accepted"; return null; }
        if (strpos($cmd, '{INPUT}') === false || strpos($cmd, '{OUTPUT}') === false) { $err = "tool $id, preset $pid: the command needs both {INPUT} and {OUTPUT}"; return null; }
        $first = preg_split('/\s+/', $cmd)[0];
        if ($first !== $bin) { $err = "tool $id, preset $pid: the command must start with the tool's binary ($bin)"; return null; }
        $ik = array_values(array_intersect((array)($p['input_kinds'] ?? ['file']), ['file', 'text', 'document', 'folder', 'image', 'audio', 'video'])) ?: ['file'];
        $oe = strtolower($str($p['output_ext'] ?? 'out', 8)); if (!preg_match('/^[a-z0-9]{1,8}$/', $oe)) $oe = 'out';
        $os = $str($p['output_stem'] ?? '{NAME}_' . $pid, 60); if (!preg_match('/^[A-Za-z0-9_{}-]{1,60}$/', $os)) $os = '{NAME}_' . $pid;
        $ok = $str($p['output_kind'] ?? 'text', 20); if (!preg_match('/^[a-z-]{1,20}$/', $ok)) $ok = 'text';
        $to = (int)($p['timeout_seconds'] ?? 300); if ($to < 1 || $to > 3600) $to = 300;
        $presets[] = ['id' => $pid, 'label' => $str($p['label'] ?? $pid, 100) ?: $pid, 'description' => $str($p['description'] ?? '', 400), 'input_kinds' => $ik, 'output_kind' => $ok,
                      'output_ext' => $oe, 'output_stem' => $os, 'command' => $cmd, 'timeout_seconds' => $to];
    }
    if (!$presets) { $err = "tool $id: at least one preset is needed"; return null; }
    $out['presets'] = $presets;
    return $out;
}
/** Write the tools a kind carries into the person's own tool store. Never replaces a tool that came from elsewhere. Returns null, or an error message. */
function kind_register_tools(array $defs, string $kindId): ?string {
    global $PATHS;
    $dir = rtrim((string)($PATHS['cockpit_data'] ?? ''), '/') . '/tools';
    if (!is_dir($dir) && !@mkdir($dir, 0775, true)) return 'could not create the tools folder';
    foreach ($defs as $t) {
        $dest = $dir . '/' . $t['id'] . '.json';
        if (is_file($dest)) { $old = json_decode((string)@file_get_contents($dest), true); if (!is_array($old) || ($old['_from_kind'] ?? '') !== $kindId) return "a tool called '{$t['id']}' is already in your tools and does not belong to this kind";  }
        $t['custom'] = true; $t['_from_kind'] = $kindId;
        if (@file_put_contents($dest, json_encode($t, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n") === false) return 'could not write the tool ' . $t['id'];
    }
    return null;
}
