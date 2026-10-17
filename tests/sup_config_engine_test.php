<?php
// sup_config_engine_test.php — cockpit_sup_config.php: the engine's file/command service is part of the supervisor's configuration when the engine exists.   php tests/sup_config_engine_test.php
$GLOBALS['argv'] = [__FILE__];
require __DIR__ . '/../scripts/cockpit_sup_config.php';
$fails = 0; $n = 0; function ok($name, $c) { global $fails, $n; $n++; if (!$c) { $fails++; echo "FAIL $name\n"; } }
$base = ['edition' => 'v2', 'web_root' => '/w', 'data_dir' => '/d', 'projects_root' => '/p', 'loop' => '/l.sh', 'agents' => ['claude', 'gemini', 'ollama'], 'group' => 'grp', 'scheduler' => ''];
$names = fn($c) => array_map(fn($s) => $s['name'], $c['services']);
$c = sup_config($base + ['engine_bin' => '']);
ok('without the engine there are only the three loops', $names($c) === ['cockpit_claude', 'cockpit_gemini', 'cockpit_ollama']);
$c = sup_config($base + ['engine_bin' => '/h/scripts/aicengine']);
ok('with the engine there is a fourth service', $names($c) === ['cockpit_claude', 'cockpit_gemini', 'cockpit_ollama', 'cockpit_engine']);
$e = $c['services'][3]; $a = $e['args'];
ok('it runs the engine program in serve mode', $e['command'] === '/h/scripts/aicengine' && $a[0] === 'serve');
ok('socket and token sit in the supervisor folder of the data dir', in_array('/d/supervisor/engine.sock', $a, true) && in_array('/d/supervisor/engine_token', $a, true));
ok('the socket is group-readable for the web account', $a[array_search('--socket-mode', $a) + 1] === '660' && $a[array_search('--socket-group', $a) + 1] === 'grp');
ok('writable zones are limited to the projects root', $a[array_search('--allowed-roots', $a) + 1] === '/p');
ok('it is restarted if it dies', $e['restart'] === 'always');
$c = sup_config(['group' => ''] + $base + ['engine_bin' => '/h/scripts/aicengine']);
ok('without a group the socket stays private', $c['services'][3]['args'][array_search('--socket-mode', $c['services'][3]['args']) + 1] === '600' && !in_array('--socket-group', $c['services'][3]['args'], true));
echo "sup_config_engine_test: $n checks, $fails failure(s)\n"; exit($fails ? 1 : 0);
