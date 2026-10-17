<?php
// as_owner_test.php — paths.php cockpit_as_owner(): no sudo when PHP already runs as the owner of this Cockpit (the self-contained mode), the
// same `sudo -u <owner>` as ever when it does not (Apache), and no call site of the launch scripts builds a sudo command by hand any more.
//   php tests/as_owner_test.php
$fails = 0; $n = 0; function ok($name, $c) { global $fails, $n; $n++; if (!$c) { $fails++; echo "FAIL $name\n"; } }
$d = sys_get_temp_dir() . '/asown_' . getmypid(); mkdir($d, 0777, true);
$PATHS = ['home' => $d];
// load only the two helpers + cockpit_owner_user from paths.php (the rest of the file needs a web request)
$src = file_get_contents(__DIR__ . '/../cockpit_app/paths.php');
foreach (['cockpit_owner_user', 'cockpit_runs_as_owner', 'cockpit_as_owner'] as $fn) {
    if (!preg_match('/^function ' . $fn . '\(.*?^\}\n/ms', $src, $m)) { echo "FAIL could not find $fn\n"; exit(1); }
    eval($m[0]);
}
ok('as the owner: no prefix at all', cockpit_as_owner() === '' && cockpit_as_owner(true) === '' && cockpit_runs_as_owner() === true);
ok('a launch line built with it is the plain command', sprintf('%s %s%s >/dev/null 2>&1 &', 'DISPLAY=:0', cockpit_as_owner(), 'xterm -e foo') === 'DISPLAY=:0 xterm -e foo >/dev/null 2>&1 &');
// another owner: a folder owned by root (when we are not root)
if (function_exists('posix_geteuid') && posix_geteuid() !== 0 && is_dir('/root')) {
    $code = '$PATHS = ["home" => "/root"]; $_s = file_get_contents("' . __DIR__ . '/../cockpit_app/paths.php"); foreach (["cockpit_owner_user","cockpit_runs_as_owner","cockpit_as_owner"] as $f) { preg_match("/^function " . $f . "\\(.*?^\\}\\n/ms", $_s, $m); eval($m[0]); } echo cockpit_as_owner(), "|", cockpit_as_owner(true);';
    $out = shell_exec('php -r ' . escapeshellarg($code));
    ok('another owner: sudo -u <owner>, and -n when asked', $out === "sudo -u 'root' |sudo -n -u 'root' ");
}
// the call sites
$sites = ['auth.php', 'scheduler.php', 'session.php', 'translate.php', 'launch_cli.php'];
foreach ($sites as $f) {
    $t = file_get_contents(__DIR__ . '/../cockpit_app/' . $f);
    $t = preg_replace('~^\s*//.*$~m', '', $t);
    preg_match_all('/sudo -[a-z -]*u |\'sudo -u|"sudo -u/', $t, $mm);
    $left = count($mm[0]);
    ok("$f builds no sudo -u command by hand (left: $left)", $f === 'launch_cli.php' ? $left <= 1 : $left === 0);
    ok("$f uses cockpit_as_owner()", strpos($t, 'cockpit_as_owner(') !== false || $f === 'translate.php' && strpos($t, 'cockpit_as_owner') !== false);
}
$s = file_get_contents(__DIR__ . '/../cockpit_app/session.php');
ok('a start from the self-contained front tells the launcher (COCKPIT_SELF=1)', strpos($s, 'COCKPIT_SELF=1') !== false && strpos($s, "'aicserver'") !== false);
ok('the tmux socket fix is skipped when PHP is the owner', preg_match('/function fix_tmux_socket_perms.*?cockpit_runs_as_owner\(\)\) return;/s', $s) === 1);
@rmdir($d);
echo "as_owner_test: $n checks, $fails failure(s)\n"; exit($fails ? 1 : 0);
