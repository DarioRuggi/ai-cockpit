<?php
// chat_meta_test.php — scope rules for goal and kind (files.php): the KIND is the project's, the GOAL is the chat's,
// a free chat keeps both. Extracts the real functions from files.php and runs them on a scratch folder.
$src = file_get_contents(__DIR__ . '/../cockpit_app/files.php') . file_get_contents(__DIR__ . '/../cockpit_app/kinds_lib.php');   // the kind validator lives in kinds_lib.php
require_once __DIR__ . '/../cockpit_app/tools_lib.php';
if (!defined('COCKPIT_OS')) define('COCKPIT_OS', 'linux');
$PATHS = ['cockpit_data' => sys_get_temp_dir() . '/no_such_kinds_data_' . getmypid()];   // no user kinds here: only the shipped ones
foreach (['safeName', 'project_meta_load', 'project_meta_save', 'chat_meta_path', 'chat_meta_load', 'chat_meta_save', 'chat_effective', 'kinds_user_dir', 'kind_validate', 'kinds_load', 'kind_tools_report', 'kind_tools_hint', 'kind_meta_patch'] as $fn) {
    if (!preg_match('/^function ' . $fn . '\(.*?^}/ms', $src, $m)) { echo "FAIL cannot find $fn\n"; exit(1); }
    $code = str_replace('__DIR__', "'" . realpath(__DIR__ . '/../cockpit_app') . "'", $m[0]);
    eval($code);
}
$fails = 0; $n = 0;
function ok($c, $msg) { global $fails, $n; $n++; if (!$c) { $fails++; echo "FAIL $msg\n"; } }
$root = sys_get_temp_dir() . '/chatmeta_' . getmypid(); mkdir("$root/p1", 0775, true); mkdir("$root/_standalone", 0775, true);

// a project with an older project-level goal and a kind
project_meta_save("$root/p1", ['goal' => 'old project goal'] + kind_meta_patch('research'));
$e = chat_effective("$root/p1", 'p1', 'a');
ok($e['goal'] === 'old project goal' && $e['goal_inherited'] === true, 'chat with no goal inherits the project one');
ok($e['kind'] === 'research' && $e['kind_note'] !== '', 'kind comes from the project');

// the goal is per chat
chat_meta_save("$root/p1", 'a', ['goal' => 'goal of a']);
ok(chat_effective("$root/p1", 'p1', 'a')['goal'] === 'goal of a', 'chat a has its own goal');
ok(chat_effective("$root/p1", 'p1', 'a')['goal_inherited'] === false, 'own goal is not inherited');
ok(chat_effective("$root/p1", 'p1', 'b')['goal'] === 'old project goal', 'chat b still shows the project default');
ok(chat_effective("$root/p1", 'p1', 'A b')['goal'] === 'old project goal', 'names are slugged like chat files');
chat_meta_save("$root/p1", 'Chat One', ['goal' => 'slugged']);
ok(chat_effective("$root/p1", 'p1', 'chat_one')['goal'] === 'slugged', '"Chat One" and chat_one are the same chat');

// the kind is per project: changing it changes every chat
project_meta_save("$root/p1", kind_meta_patch('learning'));
ok(chat_effective("$root/p1", 'p1', 'a')['kind'] === 'learning' && chat_effective("$root/p1", 'p1', 'b')['kind'] === 'learning', 'a new project kind reaches every chat');
ok(chat_effective("$root/p1", 'p1', 'a')['goal'] === 'goal of a', '... and leaves the chat goal alone');

// free chats keep both, and do not share
chat_meta_save("$root/_standalone", 'f1', ['goal' => 'free goal'] + kind_meta_patch('translation'));
chat_meta_save("$root/_standalone", 'f2', kind_meta_patch('writing'));
$f1 = chat_effective("$root/_standalone", '_standalone', 'f1'); $f2 = chat_effective("$root/_standalone", '_standalone', 'f2'); $f3 = chat_effective("$root/_standalone", '_standalone', 'f3');
ok($f1['goal'] === 'free goal' && $f1['kind'] === 'translation', 'free chat f1 has its own goal and kind');
ok($f2['kind'] === 'writing' && $f2['goal'] === '', 'free chat f2 has its own kind and no goal');
ok($f3['kind'] === 'general' && $f3['goal'] === '', 'a new free chat starts general with no goal');

// descriptions: per chat and per project, each with its own "send to the agent" switch (off unless set)
chat_meta_save("$root/p1", 'a', ['description' => 'what a is for', 'desc_send' => true]);
project_meta_save("$root/p1", ['description' => 'the whole project', 'desc_send' => false]);
$e = chat_effective("$root/p1", 'p1', 'a');
ok($e['description'] === 'what a is for' && $e['desc_send'] === true, 'chat description and its send switch');
ok($e['project_description'] === 'the whole project' && $e['project_desc_send'] === false, 'project description and its own switch, off by default');
$e = chat_effective("$root/p1", 'p1', 'b');
ok($e['description'] === '' && $e['desc_send'] === false, 'a chat without a description sends nothing');
ok($e['project_description'] === 'the whole project', 'every chat sees the project description');
$fe = chat_effective("$root/_standalone", '_standalone', 'f1');
ok($fe['project_description'] === '' && $fe['project_desc_send'] === false, 'a free chat has no project description');

// path safety
ok(strpos(chat_meta_path("$root/p1", '../../etc/passwd'), '..') === false, 'no traversal in the chat name');

shell_exec('rm -rf ' . escapeshellarg($root));
echo "chat_meta_test: $n checks, $fails failure(s)\n"; exit($fails ? 1 : 0);
