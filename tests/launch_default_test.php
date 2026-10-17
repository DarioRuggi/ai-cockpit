<?php
// launch_default_test.php — the toolbar Browser button's default (cockpit_app/launch_cli.php: _launch_default): the Cockpit Browser (cockpit_shell) wins on every system, even when the desktop's
// default web browser is something else; with no cockpit_shell the system's browser is the fallback; the terminal and the file manager are NOT changed by this.   php tests/launch_default_test.php
$src = file_get_contents(__DIR__ . '/../cockpit_app/launch_cli.php'); $fails = 0; $n = 0;
function ok($c, $m) { global $fails, $n; $n++; if (!$c) { $fails++; echo "  FAIL $m\n"; } }
foreach (['_launch_which', '_launch_candidates', '_launch_default'] as $fn) {
    if (!preg_match('/^function ' . $fn . '\(.*?^}/ms', $src, $m)) { echo "FAIL cannot find $fn\n"; exit(1); }
    eval($m[0]);
}
$home = sys_get_temp_dir() . '/ld_' . getmypid(); mkdir("$home/scripts", 0775, true); mkdir("$home/bin", 0775, true);
$GLOBALS['PATHS'] = ['home' => $home];
// the desktop says its default browser is brave
file_put_contents("$home/bin/xdg-settings", "#!/bin/sh\necho brave-browser.desktop\n"); chmod("$home/bin/xdg-settings", 0755);
putenv("PATH=$home/bin:" . getenv('PATH'));
$haveBrave = is_file('/usr/bin/brave-browser'); $haveFirefox = is_file('/usr/bin/firefox'); $haveAny = $haveBrave || $haveFirefox || is_file('/usr/bin/chromium');
// 1. cockpit_shell present: it wins over the desktop default
file_put_contents("$home/scripts/cockpit_shell", "#!/bin/sh\n"); chmod("$home/scripts/cockpit_shell", 0755);
ok(_launch_default('browser', false) === "$home/scripts/cockpit_shell", 'the Cockpit Browser must be the default even when xdg says brave: ' . _launch_default('browser', false));
// 2. not executable (locked / missing): the system's browser is the fallback
chmod("$home/scripts/cockpit_shell", 0644);
$d = _launch_default('browser', false);
ok($d !== "$home/scripts/cockpit_shell", 'a shell that cannot run is not chosen');
if ($haveAny) ok($d !== '' && basename($d) !== 'cockpit_shell', 'with no usable shell the system browser is the fallback: ' . $d);
unlink("$home/scripts/cockpit_shell");
ok(_launch_default('browser', false) !== "$home/scripts/cockpit_shell", 'with no shell at all the system browser (or nothing) is returned');
// 3. the terminal and file manager defaults do not involve the shell
foreach (['terminal', 'files'] as $cat) ok(basename(_launch_default($cat, false)) !== 'cockpit_shell', "$cat default must stay the system's own");
// 4. the installer ticks the Cockpit Browser by default
$inst = file_get_contents(__DIR__ . '/../Installs/install_cockpit.sh');
ok(preg_match('/INST_BROWSER=n; INST_FILES=n; INST_TERM=n; CKBROWSER=y/', $inst) === 1, 'the installer must pre-tick the Cockpit Browser');
@exec('rm -rf ' . escapeshellarg($home));
echo "launch_default_test: " . ($n - $fails) . " passed, $fails failed\n"; exit($fails ? 1 : 0);
