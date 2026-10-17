<?php
// =============================================================================
// lang_annotate_js.php — makes the messages Cockpit's scripts show translatable.
//
//   php Installs/lang_annotate_js.php           rewrite in place (idempotent — safe to re-run)
//   php Installs/lang_annotate_js.php --dry     report only
//
// Converts the FIRST argument of appendError( appendSystem( alert( confirm( when it is a string
// literal or a chain of literals and expressions joined by +:
//
//   appendError('Could not save ' + name + ': ' + e.message)
//     -> appendError(T('msg.could.not.save.name.message', 'Could not save {name}: {message}', {name: name, message: e.message}))
//
// plus  x.textContent = 'literal'   x.title = 'literal'   x.placeholder = 'literal'.
//
// Mechanical and exact: the literal parts and the placeholders are concatenated in the same order,
// so the English output is byte-identical. It SKIPS (leaves as it was) anything it cannot be sure of:
// a regex literal, a comment, a ternary / || / && at the top level of the argument, a template
// literal, a call with no letters in its text. Every file it touches is then `node --check`ed; one
// that fails is restored and reported. The report lists what was skipped, so nothing is silently lost.
// =============================================================================
$APP = dirname(__DIR__) . '/cockpit_app';
$dry = in_array('--dry', $argv, true);
$FUNCS = ['appendError', 'appendSystem', 'alert', 'confirm'];
$pairs = []; $keys = []; $stat = ['conv' => 0, 'lit' => 0, 'assign' => 0, 'skip' => []];

function slug(string $s, int $max = 44): string {
    $s = strtolower(preg_replace('/[^a-z0-9]+/i', '.', $s)); $s = trim($s, '.'); $s = rtrim(substr($s, 0, $max), '.');
    return $s === '' ? 'x' : $s;
}
function key_for(string $english): string {
    global $keys;
    $k = 'msg.' . slug(str_replace(['{', '}'], '', $english));
    if (isset($keys[$k]) && $keys[$k] !== $english) $k .= '.' . substr(md5($english), 0, 4);
    $keys[$k] = $english; return $k;
}
function unesc(string $raw): ?string {              // JS string body -> text; null if an escape we do not handle
    $out = ''; $n = strlen($raw);
    for ($i = 0; $i < $n; $i++) {
        $c = $raw[$i]; if ($c !== '\\') { $out .= $c; continue; }
        $d = $raw[++$i] ?? ''; 
        if ($d === 'n') $out .= "\n"; elseif ($d === 't') $out .= "\t"; elseif ($d === "'" || $d === '"' || $d === '\\' || $d === '/') $out .= $d;
        elseif ($d === 'u' && preg_match('/^[0-9a-fA-F]{4}/', substr($raw, $i + 1, 4))) { $out .= json_decode('"\\u' . substr($raw, $i + 1, 4) . '"'); $i += 4; }
        else return null;
    }
    return $out;
}
function enc(string $s): string {                    // text -> single-quoted JS literal
    $s = str_replace(['\\', "'", "\n", "\t", "\r"], ['\\\\', "\\'", '\\n', '\\t', '\\r'], $s);
    return "'" . $s . "'";
}
/** Index just past the string literal starting at $i (quote char at $i), or -1. */
function skip_str(string $s, int $i): int {
    $q = $s[$i]; $n = strlen($s);
    for ($j = $i + 1; $j < $n; $j++) { if ($s[$j] === '\\') { $j++; continue; } if ($s[$j] === $q) return $j + 1; if ($q !== '`' && $s[$j] === "\n") return -1; }
    return -1;
}
/** Split the text of ONE argument at top-level '+'. Returns list of parts, or null if unsafe. */
function split_plus(string $a): ?array {
    $parts = []; $cur = ''; $depth = 0; $n = strlen($a); $last = '';
    for ($i = 0; $i < $n; $i++) {
        $c = $a[$i];
        if ($c === '"' || $c === "'") { $e = skip_str($a, $i); if ($e < 0) return null; $cur .= substr($a, $i, $e - $i); $i = $e - 1; $last = $c; continue; }
        if ($c === '`') return null;                                     // template literals: left alone
        if ($c === '/') { if ($a[$i + 1] === '/' || $a[$i + 1] === '*') return null; if ($last === '' || strpos('(,=:[!&|?{};+-*%<>', $last) !== false) return null; }
        if ($c === '(' || $c === '[' || $c === '{') $depth++;
        if ($c === ')' || $c === ']' || $c === '}') $depth--;
        if ($depth < 0) return null;
        if ($depth === 0) {
            if ($c === '?' || ($c === ':' ) || ($c === '|' && ($a[$i + 1] ?? '') === '|') || ($c === '&' && ($a[$i + 1] ?? '') === '&') || $c === '=' || $c === ',' || $c === ';') return null;
            if ($c === '+' && ($a[$i + 1] ?? '') !== '+' && ($a[$i - 1] ?? '') !== '+') { $parts[] = $cur; $cur = ''; $last = '+'; continue; }
        }
        $cur .= $c; if (!ctype_space($c)) $last = $c;
    }
    if ($depth !== 0) return null;
    $parts[] = $cur; return $parts;
}
function name_for(string $expr, array &$used): string {
    $b = 'n';
    if (preg_match_all('/[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/', preg_replace("/'(?:[^'\\\\]|\\\\.)*'|\"(?:[^\"\\\\]|\\\\.)*\"/", '', $expr), $m)) {
        foreach ($m[0] as $id) { $seg = strtolower(substr(strrchr('.' . $id, '.'), 1)); if (!in_array($seg, ['math', 'string', 'number', 'round', 'floor', 'ceil', 'length', 'tostring', 'trim', 'join', 'true', 'false', 'null', 'undefined'], true)) { $b = $seg; break; } }
    }
    $b = preg_replace('/[^a-z0-9]/', '', $b) ?: 'n'; if (ctype_digit($b[0])) $b = 'n';
    $nm = $b; $i = 2; while (isset($used[$nm])) $nm = $b . $i++; $used[$nm] = 1; return $nm;
}
/** Build T(...) for an argument, or null to leave it. */
function convert_plain(string $arg): ?string {
    $arg = trim($arg);
    if (preg_match('/^T\s*\(/', $arg)) return null;                        // already done
    $parts = split_plus($arg); if ($parts === null) return null;
    $eng = ''; $vars = []; $used = []; $lits = 0;
    foreach ($parts as $p) {
        $p = trim($p); if ($p === '') return null;
        if (($p[0] === "'" || $p[0] === '"') && skip_str($p, 0) === strlen($p)) { $t = unesc(substr($p, 1, -1)); if ($t === null) return null; $eng .= str_replace(['{', '}'], ['{', '}'], $t); $lits++; }
        else { $nm = name_for($p, $used); $eng .= '{' . $nm . '}'; $vars[$nm] = $p; }
    }
    if (!$lits) return null;
    $letters = preg_match_all('/[A-Za-z]/', preg_replace('/\{\w+\}/', '', $eng)); if ($letters < 3) return null;
    if (preg_match('/\{[^\w]|[^\w]\}/', preg_replace('/\{\w+\}/', '', $eng)) && strpos(preg_replace('/\{\w+\}/', '', $eng), '{') !== false) return null;   // stray braces in the English
    $k = key_for($eng);
    if (!$vars) return "T('$k', " . enc($eng) . ')';
    $o = []; foreach ($vars as $n => $e) $o[] = $n . ': ' . $e;
    return "T('$k', " . enc($eng) . ', {' . implode(', ', $o) . '})';
}
/** Top-level operator positions ('?', ':', '||') of an expression; null when unsafe to look at. */
function top_ops(string $a): ?array {
    $ops = []; $depth = 0; $n = strlen($a); $last = '';
    for ($i = 0; $i < $n; $i++) {
        $c = $a[$i];
        if ($c === '"' || $c === "'") { $e = skip_str($a, $i); if ($e < 0) return null; $i = $e - 1; $last = $c; continue; }
        if ($c === '`') return null;
        if ($c === '/') { if (($a[$i + 1] ?? '') === '/' || ($a[$i + 1] ?? '') === '*') return null; if ($last === '' || strpos('(,=:[!&|?{};+-*%<>', $last) !== false) return null; }
        if ($c === '(' || $c === '[' || $c === '{') $depth++;
        if ($c === ')' || $c === ']' || $c === '}') $depth--;
        if ($depth < 0) return null;
        if ($depth === 0) {
            if ($c === '?' && ($a[$i + 1] ?? '') !== '?' && ($a[$i + 1] ?? '') !== '.') $ops[] = [$i, '?'];
            elseif ($c === ':') $ops[] = [$i, ':'];
            elseif ($c === '|' && ($a[$i + 1] ?? '') === '|') { $ops[] = [$i, '||']; $i++; }
            elseif ($c === '=' || $c === ';' || $c === ',') return null;
        }
        if (!ctype_space($c)) $last = $c;
    }
    return $depth === 0 ? $ops : null;
}
/** Plain chain, or  cond ? A : B  /  x || 'fallback'  with the literal branches converted. */
function convert_arg(string $arg): ?string {
    $r = convert_plain($arg); if ($r !== null) return $r;
    $a = trim($arg); if (preg_match('/^T\s*\(/', $a)) return null;
    $ops = top_ops($a); if (!$ops) return null;
    $q = array_values(array_filter($ops, fn($o) => $o[1] === '?')); $c = array_values(array_filter($ops, fn($o) => $o[1] === ':'));
    if (count($q) === 1 && count($c) === 1 && $q[0][0] < $c[0][0]) {            // ternary
        $cond = substr($a, 0, $q[0][0]); $x = substr($a, $q[0][0] + 1, $c[0][0] - $q[0][0] - 1); $y = substr($a, $c[0][0] + 1);
        $nx = convert_plain($x); $ny = convert_plain($y);
        if ($nx === null && $ny === null) return null;
        return trim($cond) . ' ? ' . ($nx ?? trim($x)) . ' : ' . ($ny ?? trim($y));
    }
    if (!$q && !$c) { $or = array_values(array_filter($ops, fn($o) => $o[1] === '||'));           // x || 'literal'
        if ($or) { $p = end($or)[0]; $tail = substr($a, $p + 2); $nt = convert_plain($tail); if ($nt !== null) return rtrim(substr($a, 0, $p)) . ' || ' . $nt; } }
    return null;
}

/** Find the end of the first argument / of the call, starting just after '('. Returns [argEnd, callEnd] or null. */
function scan_call(string $s, int $i): ?array {
    $n = strlen($s); $depth = 0; $argEnd = null; $last = '';
    for (; $i < $n; $i++) {
        $c = $s[$i];
        if ($c === '"' || $c === "'") { $e = skip_str($s, $i); if ($e < 0) return null; $i = $e - 1; $last = $c; continue; }
        if ($c === '`') { $e = skip_str($s, $i); if ($e < 0) return null; $i = $e - 1; $last = $c; continue; }
        if ($c === '/') { if (($s[$i + 1] ?? '') === '/' || ($s[$i + 1] ?? '') === '*') return null; if ($last === '' || strpos('(,=:[!&|?{};+-*%<>', $last) !== false) return null; }
        if ($c === '(' || $c === '[' || $c === '{') $depth++;
        elseif ($c === ')' || $c === ']' || $c === '}') { if ($depth === 0) { if ($c !== ')') return null; return [$argEnd ?? $i, $i]; } $depth--; }
        elseif ($c === ',' && $depth === 0 && $argEnd === null) $argEnd = $i;
        if (!ctype_space($c)) $last = $c;
    }
    return null;
}

$files = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($APP . '/js', FilesystemIterator::SKIP_DOTS));
$changed = [];
foreach ($files as $fi) {
    if ($fi->getExtension() !== 'js' || in_array($fi->getFilename(), ['i18n.js', 'lang-ui.js'], true)) continue;
    $path = $fi->getPathname(); $rel = 'js/' . substr($path, strlen($APP . '/js/'));
    $src = file_get_contents($path); $out = ''; $pos = 0; $n = strlen($src);
    if (!preg_match_all('/(?<![\w.$])(' . implode('|', $FUNCS) . ')\s*\(/', $src, $mm, PREG_OFFSET_CAPTURE)) { $mm = [[], []]; }
    foreach ($mm[0] as $i => $hit) {
        $start = $hit[1] + strlen($hit[0]);                    // just after '('
        if ($start < $pos) continue;
        if (preg_match('/function\s+$/', substr($src, max(0, $hit[1] - 12), 12))) continue;   // a definition
        $sc = scan_call($src, $start);
        if (!$sc) { $stat['skip'][] = "$rel: " . trim(substr($src, $hit[1], 60)) . ' (unparsable)'; continue; }
        $arg = substr($src, $start, $sc[0] - $start);
        $new = convert_arg($arg);
        if ($new === null) { if (!preg_match('/^\s*T\s*\(/', $arg)) $stat['skip'][] = "$rel: " . preg_replace('/\s+/', ' ', substr($hit[0] . $arg, 0, 90)); continue; }
        $lead = preg_match('/^\s*/', $arg, $w) ? $w[0] : ''; $trail = preg_match('/\s*$/', $arg, $w) ? $w[0] : '';
        $out .= substr($src, $pos, $start - $pos) . $lead . $new . $trail; $pos = $sc[0];
        $stat['conv']++; $pairs[] = [trim($arg), $new, $rel];
    }
    $out .= substr($src, $pos);
    // plain assignments:  x.textContent = 'literal';   x.title = '...';   x.placeholder = '...';
    $out = preg_replace_callback('/(\.(?:textContent|title|placeholder))(\s*=\s*)(\'(?:[^\'\\\\\n]|\\\\.)*\'|"(?:[^"\\\\\n]|\\\\.)*")(?=\s*[;\n)])/', function ($m) use (&$stat) {
        $t = unesc(substr($m[3], 1, -1)); if ($t === null || !preg_match('/[A-Za-z]{3}/', $t)) return $m[0];
        $stat['assign']++; return $m[1] . $m[2] . "T('" . key_for($t) . "', " . enc($t) . ')';
    }, $out);
    if ($out !== $src) $changed[$path] = [$src, $out, $rel];
}
if (in_array('--proof', $argv, true)) file_put_contents(sys_get_temp_dir() . '/lang_js_pairs.json', json_encode($pairs));
foreach ($changed as $path => [$old, $new, $rel]) {
    if ($dry) continue;
    file_put_contents($path, $new);
    exec('node --check ' . escapeshellarg($path) . ' 2>&1', $o, $rc);
    if ($rc !== 0) { file_put_contents($path, $old); fwrite(STDERR, "  RESTORED $rel: " . implode(' ', array_slice($o, 0, 3)) . "\n"); }
    $o = [];
}
fwrite(STDERR, sprintf("lang_annotate_js: %d messages converted, %d assignments, %d files touched; %d calls left as they were%s\n",
    $stat['conv'], $stat['assign'], count($changed), count($stat['skip']), $dry ? ' (dry run)' : ''));
if (in_array('--skipped', $argv, true)) fwrite(STDERR, implode("\n", array_slice($stat['skip'], 0, 400)) . "\n");
