<?php
// =============================================================================
// power_sched_lib.php — Power Buttons that run by themselves: a WATCHED FOLDER (drop a PDF or an audio file in, the button runs and the answer is written next to it) and a SCHEDULED button
// ("every morning at 08:00 summarise this folder"). Both ride the scheduler that already runs every minute (scheduler.php → scheduler_tick_dir → power_sched_tick), so there is no new daemon.
//
// Rules live in <data>/power_rules.json (the Power Buttons panel edits them through power.php), progress in <data>/power_rules_state.json, a short log in <data>/power_rules.log.
//   { id, kind:'watch'|'daily'|'every', button, enabled,
//     watch:  folder, existing(false: files already there when the rule starts are NOT processed)
//     daily:  time 'HH:MM' (local), source (a file or a folder to work on; '' = nothing), to
//     every:  minutes (5-1440), source, to }
// 'to': 'beside' (watch only: <file>.<button id>.md next to the file) · 'file=PATH' · 'notify' · 'clipboard' · '' = the button's own output.
// Each run is `power_run` started in the background (a run can take minutes; the minute tick must not wait). The run goes through power.php like any other, so the supplier, the spend consent,
// the caps and the secret check all apply - and a button that would send a secret, or needs a confirmation, simply stops (power_run exit 2) and the log says so. Nothing is ever deleted or moved.
// =============================================================================
const POWER_RULES_MAX = 40;

function power_rules_read(string $dir): array { $j = @json_decode((string)@file_get_contents($dir . '/power_rules.json'), true); return is_array($j['rules'] ?? null) ? $j['rules'] : []; }
function power_rules_write(string $dir, array $rules): bool {
    $t = $dir . '/power_rules.json.tmp' . getmypid(); if (@file_put_contents($t, json_encode(['rules' => array_values($rules)], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)) === false) return false;
    @chmod($t, 0664); return @rename($t, $dir . '/power_rules.json');
}
/** → a clean rule, or an error string. */
function power_rule_validate(array $r) {
    $kind = (string)($r['kind'] ?? ''); if (!in_array($kind, ['watch', 'daily', 'every'], true)) return 'The rule must be a watched folder, a daily run or a repeating run.';
    $btn = trim((string)($r['button'] ?? '')); if ($btn === '' || strlen($btn) > 60) return 'Choose the button this rule runs.';
    $id = (string)($r['id'] ?? ''); if ($id === '') $id = 'r' . substr(bin2hex(random_bytes(4)), 0, 7); if (!preg_match('/^[a-z0-9][a-z0-9_-]{0,31}$/', $id)) return 'Bad rule id.';
    $out = ['id' => $id, 'kind' => $kind, 'button' => $btn, 'enabled' => !array_key_exists('enabled', $r) || !empty($r['enabled']), 'created' => (int)($r['created'] ?? time())];
    $path = function ($v) { $v = trim((string)$v); return ($v === '' || ($v[0] === '/' && strlen($v) < 1024 && strpos($v, "\0") === false && strpos($v, '..') === false)) ? $v : null; };
    $to = trim((string)($r['to'] ?? ''));
    if ($to !== '' && !in_array($to, ['beside', 'notify', 'clipboard'], true) && !(strncmp($to, 'file=', 5) === 0 && $path(substr($to, 5)) !== null && substr($to, 5) !== '')) return 'The answer can go beside the file, to a file you name (a full path), to a notification or to the clipboard.';
    if ($kind === 'watch') {
        $f = $path($r['folder'] ?? ''); if ($f === null || $f === '') return 'Give the folder to watch as a full path, like /home/you/Inbox.';
        $out += ['folder' => rtrim($f, '/') ?: '/', 'existing' => !empty($r['existing']), 'to' => $to === '' ? 'beside' : $to];
        if ($out['to'] === 'clipboard') return 'A watched folder writes its answers into files (or notifications), not the clipboard.';
    } else {
        $src = $path($r['source'] ?? ''); if ($src === null) return 'The input must be a full path to a file or a folder (or empty).';
        $out += ['source' => rtrim($src, '/'), 'to' => ($to === 'beside' ? '' : $to)];
        if ($kind === 'daily') { $t = (string)($r['time'] ?? ''); if (!preg_match('/^([01]\d|2[0-3]):[0-5]\d$/', $t)) return 'The time must look like 08:30.'; $out['time'] = $t; }
        else { $m = (int)($r['minutes'] ?? 0); if ($m < 5 || $m > 1440) return 'Repeat every 5 to 1440 minutes.'; $out['minutes'] = $m; }
    }
    return $out;
}
function power_sched_log(string $dir, string $line): void {
    $f = $dir . '/power_rules.log'; @file_put_contents($f, date('Y-m-d H:i:s') . ' ' . $line . "\n", FILE_APPEND | LOCK_EX);
    if (@filesize($f) > 60000) { $l = @file($f) ?: []; @file_put_contents($f, implode('', array_slice($l, -250)), LOCK_EX); }
}
/** Start power_run in the background. $runner: the command that starts it (a test replaces it with COCKPIT_POWER_RUN_CMD). */
function power_sched_spawn(string $dir, array $rule, array $args): void {
    $php = PHP_BINARY ?: 'php'; $run = getenv('COCKPIT_POWER_RUN') ?: (__DIR__ . '/power_run');
    $user = (basename(dirname($dir)) === 'users') ? basename($dir) : '';
    $root = $user !== '' ? dirname(dirname($dir)) : $dir;
    $cmd = escapeshellarg($php) . ' ' . escapeshellarg($run) . ' ' . escapeshellarg($rule['button']) . ' --quiet --data-root ' . escapeshellarg($root) . ($user !== '' ? ' --user ' . escapeshellarg($user) : '');
    foreach ($args as $a) $cmd .= ' ' . escapeshellarg($a);
    $log = escapeshellarg($dir . '/power_rules.log');
    @exec('(setsid ' . $cmd . ' >>/dev/null 2>>' . $log . ' &) >/dev/null 2>&1');
    power_sched_log($dir, 'rule ' . $rule['id'] . ': started ' . $rule['button'] . ' ' . implode(' ', $args));
}
function power_sched_files(string $folder): array {
    $o = []; foreach (@scandir($folder) ?: [] as $n) {
        if ($n === '.' || $n === '..' || $n[0] === '.' || preg_match('/\.(part|crdownload|tmp|swp)$/i', $n)) continue;
        $p = $folder . '/' . $n;
        if (preg_match('/^(.+)\.[a-z0-9-]+\.md$/i', $n, $m) && is_file($folder . '/' . $m[1])) continue;   // an answer this feature wrote beside its file
 if (is_file($p) && !is_link($p)) $o[] = $p;
    } sort($o); return $o;
}
/** The minute tick for one data dir. $now is a parameter so a test can move the clock. Returns how many runs were started. */
function power_sched_tick(string $dir, ?int $now = null): int {
    $rules = power_rules_read($dir); if (!$rules) return 0; $now = $now ?? time();
    $sf = $dir . '/power_rules_state.json'; $st = @json_decode((string)@file_get_contents($sf), true); if (!is_array($st)) $st = [];
    $started = 0; $dirty = false; $live = [];
    foreach ($rules as $r) {
        if (!is_array($r) || empty($r['id'])) continue; $id = $r['id']; $live[$id] = true; $s = $st[$id] ?? [];
        if (empty($r['enabled'])) continue;
        if (($r['kind'] ?? '') === 'watch') {
            $folder = (string)($r['folder'] ?? ''); if (!is_dir($folder)) continue;
            $sig = []; foreach (power_sched_files($folder) as $p) $sig[$p] = filesize($p) . ':' . filemtime($p);
            if (!isset($s['seen'])) {   // the first look: what is already there is the baseline, unless the rule asks for it
                $s = ['seen' => !empty($r['existing']) ? [] : $sig, 'pending' => []]; $st[$id] = $s; $dirty = true;
                if (empty($r['existing'])) { power_sched_log($dir, 'rule ' . $id . ': watching ' . $folder . ' (' . count($sig) . ' files already there are left alone)'); continue; }
            }
            $pending = $s['pending'] ?? []; $seen = $s['seen'] ?? []; $newPending = []; $left = 3;   // at most three starts a minute
            foreach ($sig as $p => $v) {
                if (($seen[$p] ?? null) === $v) continue;
                if (($pending[$p] ?? null) !== $v || (time() - filemtime($p)) < 3) { $newPending[$p] = $v; continue; }   // still being written: wait for a quiet minute
                if ($left-- <= 0) { $newPending[$p] = $v; continue; }
                $to = $r['to'] === 'beside' ? 'file=' . $p . '.' . preg_replace('/[^a-z0-9]+/', '-', strtolower($r['button'])) . '.md' : $r['to'];
                power_sched_spawn($dir, $r, ['--from', 'file=' . $p, '--to', $to]); $seen[$p] = $v; $started++;
            }
            if (count($seen) > 2000) $seen = array_slice($seen, -1500, null, true);
            $st[$id] = ['seen' => $seen, 'pending' => $newPending]; $dirty = true;
            continue;
        }
        $due = false; $last = (int)($s['last'] ?? ($r['created'] ?? $now));   // a new rule counts from the moment it was made
        if (($r['kind'] ?? '') === 'daily') { $at = strtotime(date('Y-m-d', $now) . ' ' . $r['time']); $due = $now >= $at && $last < $at && $now - $at < 6 * 3600; }   // a missed time still runs within six hours
        elseif (($r['kind'] ?? '') === 'every') { $due = $now - $last >= (int)$r['minutes'] * 60; }
        if (!$due) continue;
        $src = (string)($r['source'] ?? '');
        $args = $src === '' ? ['--from', 'none'] : ['--from', (is_dir($src) ? 'folder=' : 'file=') . $src];
        if (($r['to'] ?? '') !== '') $args = array_merge($args, ['--to', $r['to']]);
        power_sched_spawn($dir, $r, $args); $st[$id] = ['last' => $now]; $dirty = true; $started++;
    }
    foreach (array_keys($st) as $k) if (!isset($live[$k])) { unset($st[$k]); $dirty = true; }
    if ($dirty) { $t = $sf . '.tmp' . getmypid(); if (@file_put_contents($t, json_encode($st, JSON_UNESCAPED_SLASHES)) !== false) @rename($t, $sf); }
    return $started;
}
