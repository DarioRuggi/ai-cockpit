<?php
// =============================================================================
// pascal_standards.php — static checks of a Lazarus / Free Pascal project against house rules.
//
//   php pascal_standards.php DIR [--json] [--min-comments=0.05] [--gen-resources]
//
// Reads, never writes (--gen-resources PRINTS a resourcestring unit; it does not touch DIR).
//
// Checks
//   strings   user-visible text typed straight into code or forms instead of a resourcestring:
//             Caption/Text/Hint/Title/TextHint := '...', ShowMessage('...'), MessageDlg('...'),
//             Application.MessageBox('...'), raise E....Create('...'); and Caption/Hint/TextHint = '...'
//             in .lfm files.
//   portable  Windows-only units (Windows, ShellAPI, ActiveX, ComObj, Registry, ...) or API calls
//             outside an {$IFDEF MSWINDOWS}/{$IFDEF WINDOWS} block; drive-letter paths; '\' typed
//             where PathDelim belongs.
//   theme     does anything in the project look at dark/light (a switch)? Reported once, per project.
//   comments  comment lines as a share of code lines, per unit; units under --min-comments flagged.
//
// Every finding: file, line, rule, message. Pascal comments and string literals are tokenised
// properly ({ }, (* *), //, and 'it''s'), so a rule never fires inside a comment.
// =============================================================================
if (PHP_SAPI !== 'cli' && !defined('PASCAL_STANDARDS_LIB')) { http_response_code(403); exit; }

const PS_WINUNITS = ['windows', 'shellapi', 'activex', 'comobj', 'registry', 'messages', 'winsock', 'winsock2', 'jwawindows', 'shlobj', 'comctrls_win'];
const PS_WINCALLS = '/\b(GetWindowsDirectory|GetSystemDirectory|ShellExecute|ShellExecuteEx|RegOpenKey(Ex)?|RegQueryValue(Ex)?|CreateOleObject|HKEY_[A-Z_]+|GetModuleHandle|WinExec)\b/i';
const PS_UICALLS = '/\b(ShowMessage|MessageDlg|MessageBox|InputBox|Application\.MessageBox)\s*\(\s*\'/i';

/** One Pascal source -> list of [line, codeText, isComment] per physical line with strings kept and comments blanked. */
function ps_tokenise(string $src): array {
    $out = []; $n = strlen($src); $i = 0; $line = 1; $cur = ''; $hasComment = false; $hasCode = false;
    $flush = function () use (&$out, &$cur, &$line, &$hasComment, &$hasCode) {
        $out[] = ['line' => $line, 'code' => $cur, 'has_comment' => $hasComment, 'has_code' => $hasCode];
        $cur = ''; $hasComment = false; $hasCode = false; $line++;
    };
    $mode = '';   // '' | '{' | '(*'
    while ($i < $n) {
        $c = $src[$i]; $d = $src[$i + 1] ?? '';
        if ($mode === '{')  { if ($c === '}') $mode = ''; elseif ($c === "\n") $flush(); $hasComment = true; $i++; continue; }
        if ($mode === '(*') { if ($c === '*' && $d === ')') { $mode = ''; $i += 2; continue; } if ($c === "\n") $flush(); $hasComment = true; $i++; continue; }
        if ($c === "\n") { $flush(); $i++; continue; }
        if ($c === '{') {
            if (($d === '$')) { $e = strpos($src, '}', $i); $e = $e === false ? $n - 1 : $e; $cur .= substr($src, $i, $e - $i + 1); $i = $e + 1; continue; }   // directive: keep
            $mode = '{'; $hasComment = true; $i++; continue;
        }
        if ($c === '(' && $d === '*') { $mode = '(*'; $hasComment = true; $i += 2; continue; }
        if ($c === '/' && $d === '/') { $hasComment = true; $e = strpos($src, "\n", $i); $i = $e === false ? $n : $e; continue; }
        if ($c === "'") {                                  // string literal: keep verbatim
            $j = $i + 1; while ($j < $n) { if ($src[$j] === "'") { if (($src[$j + 1] ?? '') === "'") { $j += 2; continue; } break; } if ($src[$j] === "\n") break; $j++; }
            $cur .= substr($src, $i, $j - $i + 1); $hasCode = true; $i = $j + 1; continue;
        }
        if (!ctype_space($c)) $hasCode = true;
        $cur .= $c; $i++;
    }
    if ($cur !== '' || $hasComment) $flush();
    return $out;
}

function ps_visible(string $lit): bool {            // 'Save' yes; '' / ',' / '%d' / '0' no
    $t = trim(str_replace("''", "'", substr($lit, 1, -1)));
    return strlen($t) >= 2 && preg_match('/[A-Za-z\x{00C0}-\x{024F}\x{0590}-\x{05FF}]{2}/u', $t) && !preg_match('/^[A-Za-z0-9_.\/\\\\:-]+\.(txt|ini|json|png|ico|log|xml|csv)$/i', $t);
}

function ps_scan_pas(string $path, string $rel, array &$f, array &$strings, array &$stat): void {
    $lines = ps_tokenise((string)file_get_contents($path));
    $guard = []; $inRes = false; $cm = 0; $code = 0; $theme = false;
    foreach ($lines as $L) {
        $t = $L['code']; $ln = $L['line'];
        if ($L['has_comment']) $cm++;
        if ($L['has_code']) $code++;
        $portSegs = [];                                   // text between directives, with the guard state at that point
        foreach (preg_split('/(\{\$[^}]*\})/', $t, -1, PREG_SPLIT_DELIM_CAPTURE) as $seg) {
            if (preg_match('/^\{\$(IFDEF|IFNDEF|IF|ELSE|ENDIF|IFOPT)\b\s*([^}]*)\}$/i', $seg, $m)) {
                $k = strtoupper($m[1]);
                if ($k === 'ENDIF') array_pop($guard);
                elseif ($k === 'ELSE') { if ($guard) $guard[count($guard) - 1] = !end($guard); }
                else $guard[] = ($k === 'IFDEF' || $k === 'IF') && preg_match('/\b(MSWINDOWS|WINDOWS|WIN32|WIN64)\b/i', $m[2]);
            } else $portSegs[] = [$seg, in_array(true, $guard, true)];
        }
        if (preg_match('/^\s*resourcestring\b/i', $t)) { $inRes = true; continue; }
        if ($inRes && preg_match('/^\s*(var|const|type|procedure|function|implementation|begin|initialization|uses)\b/i', $t)) $inRes = false;
        if (preg_match('/dark|lightmode|colorscheme|isdarkmode|theme/i', $t)) $theme = true;
        foreach ($portSegs as [$seg, $winGuard]) {
            if (!$winGuard) {
                foreach (PS_WINUNITS as $u) if (preg_match('/(^|[\s,])' . $u . '\s*(,|;)/i', $seg) && preg_match('/^\s*(uses\b|[A-Za-z_][\w.]*\s*[,;]|,)/', $seg . ' ') && !preg_match('/:=|\(/', $seg))
                    $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'portable', 'message' => "unit $u is Windows-only; guard it with {\$IFDEF MSWINDOWS}"];
                if (preg_match(PS_WINCALLS, preg_replace('/\'(?:[^\']|\'\')*\'/', "''", $seg), $m)) $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'portable', 'message' => "{$m[1]} is Windows-only; guard it with {\$IFDEF MSWINDOWS}"];
            }
        }
        if (preg_match('/\'[A-Za-z]:\\\\/', $t)) $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'portable', 'message' => 'drive-letter path typed into code; build paths with ConcatPaths / PathDelim'];
        if (preg_match('/\+\s*\'\\\\\'|\'\\\\\'\s*\+/', $t)) $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'portable', 'message' => "'\\' typed where PathDelim belongs"];
        // strings
        if ($inRes) continue;
        if (preg_match_all('/\b(Caption|Text|Hint|Title|TextHint|Filter)\s*:=\s*(\'(?:[^\']|\'\')*\')/i', $t, $mm, PREG_SET_ORDER)
            || preg_match_all(PS_UICALLS, $t, $mm2) ) {
            foreach ((array)$mm as $x) if (ps_visible($x[2])) { $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'strings', 'message' => "{$x[1]} := {$x[2]} — use a resourcestring"]; $strings[] = [$rel, $ln, $x[2]]; }
            if (!empty($mm2[0])) foreach ($mm2[0] as $_) if (preg_match_all('/\'(?:[^\']|\'\')*\'/', $t, $q)) foreach ($q[0] as $lit) if (ps_visible($lit)) { $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'strings', 'message' => "dialog text $lit — use a resourcestring"]; $strings[] = [$rel, $ln, $lit]; break; }
        }
        if (preg_match('/\braise\s+E\w+\.Create\s*\(\s*(\'(?:[^\']|\'\')*\')/i', $t, $m) && ps_visible($m[1])) { $f[] = ['file' => $rel, 'line' => $ln, 'rule' => 'strings', 'message' => "exception text {$m[1]} — use a resourcestring"]; $strings[] = [$rel, $ln, $m[1]]; }
    }
    $stat['units'][$rel] = ['code_lines' => $code, 'comment_lines' => $cm, 'ratio' => $code ? round($cm / $code, 3) : 0.0];
    $stat['theme'] = ($stat['theme'] ?? false) || $theme;
}

function ps_scan_lfm(string $path, string $rel, array &$f, array &$strings): void {
    $n = 0;
    foreach (file($path, FILE_IGNORE_NEW_LINES) as $i => $line) {
        if (preg_match('/^\s*(Caption|Hint|TextHint|Title)\s*=\s*(\'(?:[^\']|\'\')*\')\s*$/', $line, $m) && ps_visible($m[2])) {
            $f[] = ['file' => $rel, 'line' => $i + 1, 'rule' => 'strings', 'message' => "form {$m[1]} = {$m[2]} — set it from a resourcestring in FormCreate"];
            $strings[] = [$rel, $i + 1, $m[2]];
        }
    }
}

function ps_scan(string $dir, float $minComments = 0.05): array {
    $f = []; $strings = []; $stat = ['units' => [], 'theme' => false]; $files = 0;
    $it = new RecursiveIteratorIterator(new RecursiveCallbackFilterIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS),
        fn($x) => !in_array($x->getFilename(), ['backup', 'lib', '.git', '.cockpit', 'node_modules'], true) && !$x->isLink()));
    foreach ($it as $x) {
        if (!$x->isFile()) continue;
        $ext = strtolower($x->getExtension()); $rel = ltrim(substr($x->getPathname(), strlen($dir)), '/');
        if (in_array($ext, ['pas', 'pp', 'lpr', 'inc'], true)) { $files++; ps_scan_pas($x->getPathname(), $rel, $f, $strings, $stat); }
        elseif ($ext === 'lfm') { $files++; ps_scan_lfm($x->getPathname(), $rel, $f, $strings); }
    }
    foreach ($stat['units'] as $u => $s) if ($s['code_lines'] >= 30 && $s['ratio'] < $minComments)
        $f[] = ['file' => $u, 'line' => 0, 'rule' => 'comments', 'message' => sprintf('%d%% comment lines (%d of %d code lines); the house minimum is %d%%', round($s['ratio'] * 100), $s['comment_lines'], $s['code_lines'], round($minComments * 100))];
    if ($files && !$stat['theme']) $f[] = ['file' => '(project)', 'line' => 0, 'rule' => 'theme', 'message' => 'no sign of a dark/light switch anywhere in the sources'];
    $by = []; foreach ($f as $x) $by[$x['rule']] = ($by[$x['rule']] ?? 0) + 1;
    return ['files' => $files, 'counts' => $by, 'findings' => $f, 'strings' => $strings];
}

/** A resourcestring unit holding every flagged literal, named from the text. The project is not changed. */
function ps_resources(array $strings): string {
    $seen = []; $o = "unit cockpit_strings;\n\n{ Generated by Cockpit's standards check. Move the strings you keep into your own resource unit,\n  then replace the literals in the code and forms with these names. }\n\n{\$mode objfpc}{\$H+}\n\ninterface\n\nresourcestring\n";
    foreach ($strings as [$rel, $ln, $lit]) {
        $txt = str_replace("''", "'", substr($lit, 1, -1)); if (isset($seen[$txt])) continue;
        $w = preg_split('/[^A-Za-z0-9]+/', $txt, -1, PREG_SPLIT_NO_EMPTY); $name = 'rs' . implode('', array_map('ucfirst', array_slice($w, 0, 4)));
        $name = $name === 'rs' ? 'rsText' . (count($seen) + 1) : $name; $base = $name; $k = 2; while (in_array($name, $seen, true)) $name = $base . $k++;
        $seen[$txt] = $name; $o .= "  $name = " . $lit . ";   // $rel:$ln\n";
    }
    return $o . "\nimplementation\n\nend.\n";
}

if (PHP_SAPI === 'cli' && realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) {
    $dir = $argv[1] ?? ''; if (!is_dir($dir)) { fwrite(STDERR, "usage: php pascal_standards.php DIR [--json] [--min-comments=0.05] [--gen-resources]\n"); exit(2); }
    $min = 0.05; foreach ($argv as $a) if (preg_match('/^--min-comments=([0-9.]+)$/', $a, $m)) $min = (float)$m[1];
    $r = ps_scan(rtrim($dir, '/'), $min);
    if (in_array('--gen-resources', $argv, true)) { echo ps_resources($r['strings']); exit(0); }
    if (in_array('--json', $argv, true)) { echo json_encode($r, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE), "\n"; exit(0); }
    echo "{$r['files']} source files; " . ($r['findings'] ? count($r['findings']) . " findings (" . json_encode($r['counts']) . ")" : 'no findings') . "\n";
    foreach ($r['findings'] as $x) echo "  [{$x['rule']}] {$x['file']}" . ($x['line'] ? ":{$x['line']}" : '') . "  {$x['message']}\n";
    exit($r['findings'] ? 1 : 0);
}
