<?php
// =============================================================================
// music_poly.php — is this audio ONE melodic line, or something music_sheet cannot transcribe?
//
//   php music_poly.php <audio-file>      prints one line of JSON, exit 0
//   {"verdict":"single|polyphonic|noisy|silent|unreadable","windows":N,"poly":0.00,"noisy":0.00,"why":"..."}
//
// Why: aubio follows one pitch. Given a chord, a bass line under a melody or a drum kit it does not
// say "I cannot" — it returns a confident, wrong tune (found 2026-10-02: a synthetic full mix came
// back as "Engraved 37 notes at 121 BPM"). A model-free check is possible because a single note's
// spectral peaks are all HARMONICS of one fundamental, while a chord, a melody over a bass, or a
// drum hit leaves strong peaks that fit no single harmonic series.
//
// Method: 16 kHz mono -> 0.256 s Hann windows, 50% overlap, 80–3000 Hz. For each active window take
// the strong spectral peaks (>= 12% of the window's peak), and ask whether ONE fundamental explains
// them: for each candidate fundamental (the strongest few peaks AND their sub-octave), count the
// strong peaks that are not integer multiples of it (3% tolerance). Unexplained strong peaks => the
// window holds more than one voice. A window with very many strong peaks is "noisy" (drums, dense
// mix). A melody changes note, so two voices briefly share a window at each change: only RUNS of
// >= 3 consecutive such windows (~0.4 s) count, which a sustained chord/mix is, a note change is not.
// =============================================================================
if (PHP_SAPI !== 'cli') exit;
$in = $argv[1] ?? '';
function out(array $a): void { echo json_encode($a, JSON_UNESCAPED_UNICODE), "\n"; exit(0); }
if (!is_file($in)) out(['verdict' => 'unreadable', 'why' => 'no such file']);

$SR = 16000; $N = 4096; $HOP = 2048; $MAXSEC = 90;
$cmd = 'ffmpeg -v error -i ' . escapeshellarg($in) . ' -t ' . $MAXSEC . ' -ac 1 -ar ' . $SR . ' -f s16le - 2>/dev/null';
$raw = (string)shell_exec($cmd);
if (strlen($raw) < $N * 2) out(['verdict' => 'unreadable', 'why' => 'could not decode audio, or it is shorter than a quarter of a second']);
$s = array_values(unpack('s*', $raw)); $len = count($s);
foreach ($s as $i => $v) $s[$i] = $v / 32768.0;

// iterative radix-2 FFT (in place, separate re/im arrays)
function fft(array &$re, array &$im): void {
    $n = count($re);
    for ($i = 1, $j = 0; $i < $n; $i++) { $bit = $n >> 1; for (; $j & $bit; $bit >>= 1) $j ^= $bit; $j ^= $bit;
        if ($i < $j) { [$re[$i], $re[$j]] = [$re[$j], $re[$i]]; [$im[$i], $im[$j]] = [$im[$j], $im[$i]]; } }
    for ($len = 2; $len <= $n; $len <<= 1) {
        $ang = -2 * M_PI / $len; $wr = cos($ang); $wi = sin($ang);
        for ($i = 0; $i < $n; $i += $len) { $cr = 1.0; $ci = 0.0;
            for ($k = 0; $k < $len / 2; $k++) {
                $a = $i + $k; $b = $a + $len / 2;
                $tr = $re[$b] * $cr - $im[$b] * $ci; $ti = $re[$b] * $ci + $im[$b] * $cr;
                $re[$b] = $re[$a] - $tr; $im[$b] = $im[$a] - $ti; $re[$a] += $tr; $im[$a] += $ti;
                $t = $cr * $wr - $ci * $wi; $ci = $cr * $wi + $ci * $wr; $cr = $t;
            } } }
}
$hann = []; for ($i = 0; $i < $N; $i++) $hann[$i] = 0.5 - 0.5 * cos(2 * M_PI * $i / ($N - 1));
$binHz = $SR / $N; $lo = (int)ceil(80 / $binHz); $hi = (int)floor(3000 / $binHz);

// A quiet recording (soft piano, a distant whistle) is not silence: judge each window against the
// loudest one in the file, with a small absolute floor so digital near-silence still counts as silent.
$maxRms = 0.0;
for ($p = 0; $p + $N <= $len; $p += $HOP) { $e = 0.0; for ($i = 0; $i < $N; $i += 4) { $x = $s[$p + $i]; $e += $x * $x; } $e = sqrt($e / ($N / 4)); if ($e > $maxRms) $maxRms = $e; }
$floor = max(0.0015, 0.08 * $maxRms);
$active = 0; $flags = []; $noisyFlags = []; $win = 0;
for ($p = 0; $p + $N <= $len; $p += $HOP) {
    $rms = 0.0; $re = []; $im = [];
    for ($i = 0; $i < $N; $i++) { $x = $s[$p + $i]; $rms += $x * $x; $re[$i] = $x * $hann[$i]; $im[$i] = 0.0; }
    $rms = sqrt($rms / $N);
    if ($rms < $floor) { $flags[] = null; $noisyFlags[] = null; continue; }          // silent window
    fft($re, $im);
    $mag = []; $mx = 0.0;
    for ($k = $lo; $k <= $hi; $k++) { $m = sqrt($re[$k] * $re[$k] + $im[$k] * $im[$k]); $mag[$k] = $m; if ($m > $mx) $mx = $m; }
    if ($mx <= 0) { $flags[] = null; $noisyFlags[] = null; continue; }
    $active++;
    // strong local maxima
    $peaks = [];
    for ($k = $lo + 1; $k < $hi; $k++) if ($mag[$k] >= 0.12 * $mx && $mag[$k] > $mag[$k - 1] && $mag[$k] >= $mag[$k + 1]) {
        // parabolic interpolation for the frequency
        $a = $mag[$k - 1]; $b = $mag[$k]; $c = $mag[$k + 1]; $d = ($a - 2 * $b + $c); $off = $d != 0 ? 0.5 * ($a - $c) / $d : 0;
        $peaks[] = [($k + $off) * $binHz, $b / $mx];
    }
    // merge peaks closer than 25 Hz (window leakage), keep the stronger
    usort($peaks, fn($x, $y) => $y[1] <=> $x[1]); $kept = [];
    foreach ($peaks as $pk) { $near = false; foreach ($kept as $q) if (abs($q[0] - $pk[0]) < 25) { $near = true; break; } if (!$near) $kept[] = $pk; }
    $peaks = $kept; $np = count($peaks);
    if ($np <= 1) { $flags[] = false; $noisyFlags[] = false; continue; }
    // best single-fundamental explanation
    $cands = [];
    foreach (array_slice($peaks, 0, 4) as $pk) { $cands[] = $pk[0]; $cands[] = $pk[0] / 2; if ($pk[0] / 3 >= 70) $cands[] = $pk[0] / 3; }
    $best = $np;
    foreach ($cands as $f0) { if ($f0 < 60) continue; $un = 0;
        foreach ($peaks as $pk) { $r = $pk[0] / $f0; $near = round($r); if ($near < 1 || $near > 8 || abs($r - $near) / $near > 0.03) { /* harmonic numbers above 8 fit almost any frequency */ if ($pk[1] >= 0.40) $un++; } }
        if ($un < $best) $best = $un; }
    $flags[] = ($best >= 1);
    $noisyFlags[] = ($np >= 14);
}
function runs(array $f, int $minRun): int {            // frames that belong to a run of >= minRun consecutive true
    $tot = 0; $run = 0;
    foreach (array_merge($f, [false]) as $v) { if ($v === true) $run++; else { if ($run >= $minRun) $tot += $run; $run = 0; } }
    return $tot;
}
if ($active < 4) out(['verdict' => 'silent', 'windows' => $active, 'poly' => 0, 'noisy' => 0, 'why' => 'almost no signal above the noise floor']);
$poly = runs($flags, 3) / $active; $noisy = runs($noisyFlags, 3) / $active;
$verdict = 'single'; $why = 'one melodic line';
if ($noisy > 0.30)      { $verdict = 'noisy';      $why = 'broadband / percussive content (drums, dense mix, noise)'; }
elseif ($poly > 0.35)   { $verdict = 'polyphonic'; $why = 'several notes or voices sound at once (chords, accompaniment, bass under a melody)'; }
out(['verdict' => $verdict, 'windows' => $active, 'poly' => round($poly, 2), 'noisy' => round($noisy, 2), 'why' => $why]);
