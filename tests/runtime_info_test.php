<?php
// runtime_info_test.php — session_backend.php ck_runtime_info() on a scratch data folder with nothing running: the switch files are read,
// the answer has the shape the status bar expects, and an agent that is not running reports no loop.   php tests/runtime_info_test.php
$d = sys_get_temp_dir() . '/rti_' . getmypid(); mkdir("$d/users/u", 0777, true);
$PATHS = ['cockpit_data_root' => $d, 'cockpit_data' => "$d/users/u", 'home' => "$d/home", 'tmux_socket' => "$d/none.sock"];
require __DIR__ . '/../cockpit_app/session_backend.php';
$fails = 0; $n = 0; function ok($name, $c) { global $fails, $n; $n++; if (!$c) { $fails++; echo "FAIL $name\n"; } }
$r = ck_runtime_info();
ok('all three agents are reported', array_keys($r['agents']) === ['claude', 'gemini', 'ollama']);
ok('each agent reports a known loop kind and host', !array_filter($r['agents'], fn($a) => !in_array($a['loop'], ['none', 'shell', 'native'], true) || !in_array($a['host'], ['none', 'supervisor', 'tmux', 'other'], true)));
ok('host is one of the known words', in_array($r['host'], ['none', 'supervisor', 'tmux', 'mixed'], true));
ok('engine off with no switch file', $r['engine']['on'] === false && $r['engine']['installed'] === false);
ok('no switches listed', $r['switches'] === []);
ok('scheduler defaults to cron/other', $r['scheduler'] === 'cron/other');
ok('web server: none without SERVER_SOFTWARE', $r['web'] === 'none');
foreach (['aicserver/1.0.0' => 'aicserver', 'Apache/2.4.58 (Ubuntu)' => 'apache', 'PHP 8.3.6 Development Server' => 'php', 'nginx' => 'other'] as $ss => $want) { $_SERVER['SERVER_SOFTWARE'] = $ss; ok("web server word for [$ss]", ck_runtime_info()['web'] === $want); }
unset($_SERVER['SERVER_SOFTWARE']);
touch("$d/use_engine"); touch("$d/use_native_loop_ollama"); touch("$d/use_native_loop"); mkdir("$d/home/scripts", 0777, true); touch("$d/home/scripts/aicengine");
$r = ck_runtime_info();
ok('engine on from the shared folder', $r['engine']['on'] === true && $r['engine']['installed'] === true);
ok('switch files are listed', $r['switches'] === ['use_native_loop', 'use_native_loop_ollama']);
unlink("$d/use_engine"); touch("$d/users/u/use_engine");
ok('engine on from the per-user folder', ck_runtime_info()['engine']['on'] === true);
ok('the answer is JSON-encodable', json_encode($r) !== false);
exec('rm -rf ' . escapeshellarg($d));
echo "runtime_info_test: $n checks, $fails failure(s)\n"; exit($fails ? 1 : 0);
