<?php
// internal_auth_test.php — cockpit_app/internal_auth.php: who may call the loop's five pages without a login, and who may not.
// A pure function over (server vars, query, body, data folder): every refusal is a case here.   php tests/internal_auth_test.php
require __DIR__ . '/../cockpit_app/internal_auth.php';
$fails = 0; $n = 0;
function ok(string $name, bool $cond): void { global $fails, $n; $n++; if (!$cond) { $fails++; echo "FAIL $name\n"; } }
$d = sys_get_temp_dir() . '/ia_' . getmypid(); mkdir($d, 0777, true);
$KEY = bin2hex(random_bytes(32));
file_put_contents("$d/internal_key", $KEY . "\n");
file_put_contents("$d/users.json", json_encode([['id' => 1, 'username' => 'dario', 'role' => 'admin'], ['id' => 2, 'username' => 'view_only', 'role' => 'viewer'], ['id' => 3, 'username' => 'no_role']]));
$base = ['HTTP_X_COCKPIT_INTERNAL' => $KEY, 'HTTP_X_COCKPIT_USER' => 'dario', 'REMOTE_ADDR' => '127.0.0.1', 'SCRIPT_FILENAME' => '/var/www/html/cockpit/search.php'];
$call = fn(array $over = [], array $get = ['action' => 'search'], string $body = '') => ck_internal_login($over + $base, $get, $body, $d);
$s = fn(array $remove = [], array $add = []) => array_diff_key($add + $base, array_flip($remove));

$r = $call();
ok('a correct call is accepted as the named person with their role', $r === ['user' => 'dario', 'role' => 'admin']);
ok('IPv6 loopback is loopback', $call(['REMOTE_ADDR' => '::1']) !== null && $call(['REMOTE_ADDR' => '::ffff:127.0.0.1']) !== null);
foreach (['192.168.1.5', '10.0.0.1', '8.8.8.8', '', '127.0.0.2', '::2', 'localhost'] as $ip) ok("refused from $ip", ck_internal_login(['REMOTE_ADDR' => $ip] + $base, ['action' => 'search'], '', $d) === null);
ok('refused with no REMOTE_ADDR at all', ck_internal_login($s(['REMOTE_ADDR']), ['action' => 'search'], '', $d) === null);
foreach (['HTTP_X_FORWARDED_FOR' => '203.0.113.9', 'HTTP_FORWARDED' => 'for=203.0.113.9', 'HTTP_X_REAL_IP' => '203.0.113.9', 'HTTP_X_FORWARDED_HOST' => 'x.example'] as $h => $v)
    ok("refused when a proxy header ($h) is present", $call([$h => $v]) === null);
ok('refused without the key header', ck_internal_login($s(['HTTP_X_COCKPIT_INTERNAL']), ['action' => 'search'], '', $d) === null);
ok('refused with an empty key header', $call(['HTTP_X_COCKPIT_INTERNAL' => '']) === null);
ok('refused with a wrong key', $call(['HTTP_X_COCKPIT_INTERNAL' => str_repeat('0', 64)]) === null);
ok('refused with the key plus a trailing character', $call(['HTTP_X_COCKPIT_INTERNAL' => $KEY . 'x']) === null);
ok('refused with a truncated key', $call(['HTTP_X_COCKPIT_INTERNAL' => substr($KEY, 0, 63)]) === null);
ok('refused with the key in another case', $call(['HTTP_X_COCKPIT_INTERNAL' => strtoupper($KEY)]) === null);
file_put_contents("$d/internal_key", "short\n");
ok('refused when the key file holds a short secret (nothing to compare against)', ck_internal_login(['HTTP_X_COCKPIT_INTERNAL' => 'short'] + $base, ['action' => 'search'], '', $d) === null);
file_put_contents("$d/internal_key", '');
ok('refused when the key file is empty', ck_internal_login(['HTTP_X_COCKPIT_INTERNAL' => ''] + $base, ['action' => 'search'], '', $d) === null);
unlink("$d/internal_key");
ok('refused when there is no key file', $call() === null);
file_put_contents("$d/internal_key", $KEY . "\n");
// pages and actions
$pairs = ['search.php' => ['search', 'fetch'], 'workers.php' => ['models', 'invoke'], 'tools.php' => ['presets', 'run'], 'library.php' => ['proposal_add']];
foreach ($pairs as $page => $acts) foreach ($acts as $a) ok("allowed: $page?action=$a", $call(['SCRIPT_FILENAME' => "/x/$page"], ['action' => $a]) !== null);
foreach (['files.php', 'auth.php', 'themes.php', 'settings.php', 'launch_cli.php', 'saas.php', 'backup.php', 'bridge.php', 'index.html', ''] as $page) ok("page not on the list: $page", $call(['SCRIPT_FILENAME' => "/x/$page"], ['action' => 'search']) === null);
foreach (['save_config', 'delete', 'set_key', 'list_keys', 'export', '', 'SEARCH', 'search ', '../search'] as $a) ok("action not on the list: '$a'", $call([], ['action' => $a]) === null);
ok('right action on the wrong page: workers.php?action=search', $call(['SCRIPT_FILENAME' => '/x/workers.php'], ['action' => 'search']) === null);
ok('library.php may only add a proposal (list is refused)', $call(['SCRIPT_FILENAME' => '/x/library.php'], ['action' => 'list']) === null);
ok('a path trick in SCRIPT_FILENAME does not smuggle another page in', $call(['SCRIPT_FILENAME' => '/x/search.php/../files.php'], ['action' => 'search']) === null);
ok('the action may come from a JSON body (library.php posts it there)', $call(['SCRIPT_FILENAME' => '/x/library.php'], [], '{"action":"proposal_add","payload":{}}') !== null);
ok('a JSON body with another action is refused', $call(['SCRIPT_FILENAME' => '/x/library.php'], [], '{"action":"delete"}') === null);
ok('a body that is not JSON gives no action', $call(['SCRIPT_FILENAME' => '/x/library.php'], [], 'not json') === null);
ok('query and body naming different actions: refused', $call(['SCRIPT_FILENAME' => '/x/library.php'], ['action' => 'proposal_add'], '{"action":"delete"}') === null);
ok('the query action wins over the body', $call(['SCRIPT_FILENAME' => '/x/library.php'], ['action' => 'list'], '{"action":"proposal_add"}') === null);
// the person
ok('refused without a user header', ck_internal_login($s(['HTTP_X_COCKPIT_USER']), ['action' => 'search'], '', $d) === null);
foreach (['', 'nobody', 'DARIO', 'dario ', 'da rio', '../dario', 'dario/x', str_repeat('a', 65), "dario\n", 'dar;io'] as $u) ok("user not accepted: '" . addcslashes($u, "\n") . "'", $call(['HTTP_X_COCKPIT_USER' => $u]) === null);
ok('a viewer stays a viewer', ($call(['HTTP_X_COCKPIT_USER' => 'view_only']) ?? [])['role'] === 'viewer');
ok('a user without a role in users.json is a viewer', ($call(['HTTP_X_COCKPIT_USER' => 'no_role']) ?? [])['role'] === 'viewer');
file_put_contents("$d/users.json", '{ broken');
ok('refused when users.json is not valid JSON', $call() === null);
unlink("$d/users.json");
ok('refused when there is no users.json', $call() === null);
file_put_contents("$d/users.json", json_encode([['username' => 'dario', 'role' => 'admin']]));
ok('accepted again once users.json is back', $call() !== null);
exec('rm -rf ' . escapeshellarg($d));
echo "internal_auth_test: $n checks, $fails failure(s)\n"; exit($fails ? 1 : 0);
