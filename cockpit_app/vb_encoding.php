<?php
// =============================================================================
// vb_encoding.php — detect the text encoding of VB6 source files and convert COPIES to UTF-8.
//
//   php vb_encoding.php scan    <srcdir> [--csv report.csv]
//   php vb_encoding.php convert <srcdir> <outdir> [--csv report.csv]
//
// Why: VB6 files are ANSI in the author's Windows code page, not UTF-8. Spanish accents (Windows-1252)
// and Hebrew (Windows-1255) read as garbage, or get silently corrupted, the moment a model or a Unicode
// tool touches them — before any translation starts. This runs FIRST in the migration pipeline.
//
// It never modifies the originals: `scan` only reads; `convert` writes new files under <outdir>.
// Each file gets: encoding, confidence (high/medium/low), the evidence behind it, and a REVIEW flag for
// anything a person should look at (low confidence, mixed encodings, unsupported script). A review
// list shows the same lines decoded under the best candidates, so the choice takes seconds.
//
// Decision order: BOM -> pure ASCII -> valid UTF-8 -> single-byte code page by script statistics
// (Hebrew 1255 / Cyrillic 1251 / Greek 1253 / Western 1252), with the project's own form font charset
// (Charset = 177 Hebrew, 204 Cyrillic, 0/1 Western) as a PRIOR that breaks ties and raises confidence.
// Not handled (flagged for review, never guessed): Arabic 1256, Central European 1250,
// Baltic 1257, Turkish 1254 and the East Asian double-byte pages.
// =============================================================================
if (PHP_SAPI !== 'cli') { http_response_code(403); exit; }      // a command-line tool: never answers a web request

const VB_TEXT_EXT = ['vbp', 'vbg', 'frm', 'bas', 'cls', 'ctl', 'pag', 'dob', 'dsr', 'vbw', 'rc', 'txt', 'ini', 'cfg', 'inc'];

function enc_runs(string $b, callable $isLetter): array {          // [bytes in runs of >=2, total run bytes of any length]
    $n = strlen($b); $inRun = 0; $inRunTotal = 0; $len = 0;
    for ($i = 0; $i <= $n; $i++) {
        $c = $i < $n ? ord($b[$i]) : 0;
        if ($i < $n && $isLetter($c)) { $len++; continue; }
        if ($len >= 2) $inRun += $len;
        $inRunTotal += $len; $len = 0;
    }
    return [$inRun, $inRunTotal];
}
/** Decide the encoding of one file's bytes. @return array{enc:string,conf:string,why:string,review:bool,cands:array} */
function enc_detect(string $b, ?string $prior): array {
    if (strncmp($b, "\xEF\xBB\xBF", 3) === 0) return ['enc' => 'utf-8-bom', 'conf' => 'high', 'why' => 'UTF-8 byte-order mark', 'review' => false, 'cands' => []];
    if (strncmp($b, "\xFF\xFE", 2) === 0)     return ['enc' => 'utf-16le', 'conf' => 'high', 'why' => 'UTF-16 LE byte-order mark', 'review' => false, 'cands' => []];
    if (strncmp($b, "\xFE\xFF", 2) === 0)     return ['enc' => 'utf-16be', 'conf' => 'high', 'why' => 'UTF-16 BE byte-order mark', 'review' => false, 'cands' => []];
    if (strpos($b, "\0") !== false)           return ['enc' => 'binary', 'conf' => 'high', 'why' => 'contains NUL bytes (not a text file)', 'review' => false, 'cands' => []];
    if (!preg_match('/[\x80-\xFF]/', $b))     return ['enc' => 'ascii', 'conf' => 'high', 'why' => 'only ASCII bytes', 'review' => false, 'cands' => []];
    $high = preg_match_all('/[\x80-\xFF]/', $b);
    $validUtf8 = mb_check_encoding($b, 'UTF-8');
    if ($validUtf8) return ['enc' => 'utf-8', 'conf' => 'high', 'why' => "valid UTF-8 with $high non-ASCII bytes", 'review' => false, 'cands' => []];
    // Some bytes form valid UTF-8 sequences but the whole file is not valid UTF-8: a MIXED file.
    $multi = preg_match_all('/[\xC2-\xDF][\x80-\xBF]|[\xE0-\xEF][\x80-\xBF]{2}/', $b);
    $mixed = $multi >= 2 && $multi * 2 >= $high * 0.5;
    // Script statistics over the high bytes. A candidate must satisfy TWO tests: its letters form WORDS
    // (runs of consecutive high bytes: Hebrew, Cyrillic and Greek words are made of them, while Spanish or
    // French accents sit alone inside ASCII words) AND its most frequent letters are the ones that language
    // actually uses most (a byte-share test; the byte ranges of the three scripts overlap heavily, so ranges
    // alone cannot tell Greek from Cyrillic or from Hebrew).
    $hist = array_fill(0, 256, 0); foreach (count_chars($b, 1) as $byte => $cnt) if ($byte >= 0x80) $hist[$byte] = $cnt;
    $run = enc_runs($b, fn($c) => $c >= 0xC0); $coherence = $high ? $run[0] / $high : 0;
    $freqSets = [   // the ten most frequent letters of each language, as bytes in its code page
        'windows-1255' => [0xE4, 0xE5, 0xE9, 0xEC, 0xE0, 0xF8, 0xFA, 0xEE, 0xF0, 0xF9],   // ה ו י ל א ר ת מ נ ש
        'windows-1251' => [0xEE, 0xE5, 0xE0, 0xE8, 0xED, 0xF2, 0xF1, 0xF0, 0xE2, 0xEB],   // о е а и н т с р в л
        'windows-1253' => [0xE1, 0xE5, 0xEF, 0xE9, 0xED, 0xF4, 0xF3, 0xF1, 0xE7, 0xF5],   // α ε ο ι ν τ σ ρ η υ
    ];
    $share = []; foreach ($freqSets as $e => $set) { $sum = 0; foreach ($set as $byte) $sum += $hist[$byte]; $share[$e] = $high ? $sum / $high : 0; }
    $cyrMarks = $hist[0xFB] + $hist[0xFC] + $hist[0xFF];                                  // ы ь я: not Hebrew, not Greek (0xFF is unassigned there)
    $lat = 0;                                                                              // accented letters sitting inside ASCII words
    if (preg_match_all('/(?<=[A-Za-z])[\xC0-\xFF]|[\xC0-\xFF](?=[A-Za-z])|[\xA1\xBF](?=[A-Za-z])/', $b, $m)) $lat = count($m[0]);
    $latScore = $high ? $lat / $high : 0;
    $cands = [];
    // Non-Latin scripts: accented Latin letters (Portuguese ç+ã, French) form short "runs" too, but they sit next to ASCII
    // letters; real Hebrew/Cyrillic/Greek words do not. Found by the accuracy run (Portuguese read as Greek).
    if ($coherence >= 0.6 && $latScore < 0.4) foreach ($share as $e => $v) if ($v >= 0.4) $cands[$e] = $v + ($e === 'windows-1251' && $cyrMarks ? 0.1 : 0);
    if ($latScore >= 0.5 && $coherence < 0.6)  $cands['windows-1252'] = $latScore;
    if (!$cands && $latScore > 0.2)            $cands['windows-1252'] = $latScore * 0.8;
    $hebScore = $share['windows-1255']; $cyrScore = $share['windows-1251'];
    // the project's font charset as a prior
    $priorMap = ['hebrew' => 'windows-1255', 'cyrillic' => 'windows-1251', 'western' => 'windows-1252'];
    $priorEnc = $prior ? ($priorMap[$prior] ?? null) : null;
    if ($priorEnc && isset($cands[$priorEnc])) $cands[$priorEnc] += 0.15;
    elseif ($priorEnc && !$cands) $cands[$priorEnc] = 0.4;
    arsort($cands);
    $top = array_key_first($cands);
    $ev = sprintf('%d high bytes: word-runs %.0f%%, letter fit hebrew %.0f%% / cyrillic %.0f%% / greek %.0f%%, latin-in-word %.0f%%%s%s', $high, $coherence * 100,
                  $share['windows-1255'] * 100, $share['windows-1251'] * 100, $share['windows-1253'] * 100, $latScore * 100,
                  $cyrMarks ? ", cyrillic-only letters x$cyrMarks" : '', $priorEnc ? ", project font suggests $priorEnc" : '');
    if ($mixed)  return ['enc' => $top ?? 'windows-1252', 'conf' => 'low', 'why' => "MIXED: $multi valid UTF-8 sequences and other bytes in one file; $ev", 'review' => true, 'cands' => array_keys($cands)];
    if (!$top)   return ['enc' => 'windows-1252', 'conf' => 'low', 'why' => "no script recognised (could be Greek, Arabic, Central European or a double-byte page); $ev", 'review' => true, 'cands' => []];
    $second = count($cands) > 1 ? array_values($cands)[1] : 0.0; $score = $cands[$top];
    // the margin over the runner-up matters as much as the score: the three scripts share many byte values
    $margin = $score - $second;
    // A handful of letters cannot tell Hebrew from Cyrillic from Greek: tiny samples are never better than low.
    $conf = ($score >= 0.65 && $margin >= 0.2 && $high >= 20) ? 'high' : (($score >= 0.4 && $margin >= 0.12 && $high >= 12) ? 'medium' : 'low');
    if (substr($top, 0, 12) === 'windows-1252' && $latScore >= 0.8 && $high >= 3 && $margin >= 0.3) $conf = $high >= 6 ? 'high' : 'medium';   // accents inside ASCII words: unmistakable
    if ($high < 3 && $conf === 'high') $conf = 'medium';
    return ['enc' => $top, 'conf' => $conf, 'why' => $ev, 'review' => $conf === 'low', 'cands' => array_keys($cands)];
}
/** The form-font charset used in a project's .frm files -> 'hebrew' | 'cyrillic' | 'western' | null. */
function enc_project_prior(string $dir): ?string {
    $votes = [];
    foreach (glob(rtrim($dir, '/') . '/*.{frm,ctl,dob,pag}', GLOB_BRACE) ?: [] as $f) {
        if (preg_match_all('/^\s*Charset\s*=\s*(\d+)/mi', (string)@file_get_contents($f), $m)) foreach ($m[1] as $c) {
            $k = $c == 177 ? 'hebrew' : ($c == 204 ? 'cyrillic' : (in_array((int)$c, [0, 1], true) ? 'western' : 'other'));
            $votes[$k] = ($votes[$k] ?? 0) + 1;
        }
    }
    unset($votes['western']); unset($votes['other']);                       // Western is the default font charset: not evidence
    if (!$votes) return null; arsort($votes); return array_key_first($votes);
}
function enc_to_utf8(string $b, string $enc): ?string {
    switch ($enc) {
        case 'utf-8': case 'ascii': return $b;
        case 'utf-8-bom': return substr($b, 3);
        case 'utf-16le': return mb_convert_encoding(substr($b, 2), 'UTF-8', 'UTF-16LE');
        case 'utf-16be': return mb_convert_encoding(substr($b, 2), 'UTF-8', 'UTF-16BE');
        case 'binary': return null;
        default:
            $r = @iconv(strtoupper($enc), 'UTF-8//IGNORE', $b);                 // unmapped bytes are dropped, and counted by the caller
            return $r === false ? null : $r;
    }
}
function enc_walk(string $dir): array {
    $out = []; $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) if ($f->isFile()) $out[] = $f->getPathname();
    sort($out); return $out;
}
function enc_main(array $argv): int {
    $cmd = $argv[1] ?? ''; $src = rtrim($argv[2] ?? '', '/');
    $convert = $cmd === 'convert'; $dst = $convert ? rtrim($argv[3] ?? '', '/') : '';
    if (!in_array($cmd, ['scan', 'convert'], true) || !is_dir($src) || ($convert && $dst === '')) { fwrite(STDERR, "usage: vb_encoding.php scan <srcdir> [--csv f] | convert <srcdir> <outdir> [--csv f]\n"); return 2; }
    $absDst = $convert ? ((realpath(dirname($dst)) ?: dirname($dst)) . '/' . basename($dst)) : '';
    if ($convert && strpos($absDst . '/', realpath($src) . '/') === 0) { fwrite(STDERR, "refusing: <outdir> is inside <srcdir>\n"); return 2; }
    $csvPath = null; foreach ($argv as $i => $a) if ($a === '--csv') $csvPath = $argv[$i + 1] ?? null;
    $rows = []; $review = []; $skipped = 0; $frx = 0; $priors = [];
    foreach (enc_walk($src) as $f) {
        $rel = substr($f, strlen($src) + 1); $ext = strtolower(pathinfo($f, PATHINFO_EXTENSION));
        if ($ext === 'frx' || $ext === 'ctx') { $frx++; continue; }
        if (!in_array($ext, VB_TEXT_EXT, true)) { $skipped++; continue; }
        $d = dirname($f); $priors[$d] ??= enc_project_prior($d);
        $b = (string)file_get_contents($f);
        $r = enc_detect($b, $priors[$d]);
        $out = ''; $lost = 0;
        if ($convert) {
            $u = enc_to_utf8($b, $r['enc']);
            if ($u === null) { $out = 'skipped'; }
            else {
                $o = $dst . '/' . $rel; @mkdir(dirname($o), 0775, true); file_put_contents($o, $u); $out = 'written';
                if (!in_array($r['enc'], ['ascii', 'utf-8', 'utf-8-bom', 'utf-16le', 'utf-16be'], true)) {
                    $lost = max(0, preg_match_all('/[\x80-\xFF]/', $b) - preg_match_all('/[^\x00-\x7F]/u', $u));        // a rough "bytes dropped" guard
                    if (strpos($u, "\xEF\xBF\xBD") !== false) $r['review'] = true;
                }
            }
        }
        $rows[] = [$rel, strlen($b), $r['enc'], $r['conf'], $r['review'] ? 'REVIEW' : '', $out, $r['why']];
        if ($r['review']) $review[] = [$rel, $b, $r];
    }
    $csv = fopen($csvPath ?: 'php://stdout', 'w');
    fputcsv($csv, ['file', 'bytes', 'encoding', 'confidence', 'review', 'output', 'evidence']);
    foreach ($rows as $row) fputcsv($csv, $row);
    if ($csvPath) fclose($csv);
    $by = []; foreach ($rows as $r) $by[$r[2]] = ($by[$r[2]] ?? 0) + 1; ksort($by);
    fwrite(STDERR, sprintf("vb_encoding: %d text files (%s); %d need review; %d .frx/.ctx binaries not touched; %d other files ignored%s\n",
        count($rows), implode(', ', array_map(fn($k, $v) => "$k $v", array_keys($by), $by)), count($review), $frx, $skipped, $convert ? "; copies in $dst" : ' (scan only: nothing written)'));
    foreach ($review as [$rel, $b, $r]) {
        fwrite(STDERR, "  REVIEW $rel  [{$r['enc']}, {$r['conf']}]  {$r['why']}\n");
        $shown = 0;
        foreach (preg_split('/\r?\n/', $b) as $ln) {
            if (!preg_match('/[\x80-\xFF]/', $ln) || $shown >= 3) continue; $shown++;
            foreach (array_unique(array_merge([$r['enc']], $r['cands'], ['windows-1255', 'windows-1252'])) as $c) { $t = @iconv(strtoupper($c), 'UTF-8//IGNORE', $ln); fwrite(STDERR, sprintf("      %-13s %s\n", $c, $t === false ? '(cannot decode)' : mb_substr(trim($t), 0, 70))); }
            fwrite(STDERR, "      --\n");
        }
    }
    return 0;
}
// run as a program, not when another script (vb_tool) loads its functions
if (realpath($_SERVER['SCRIPT_FILENAME'] ?? '') === __FILE__) exit(enc_main($argv));
