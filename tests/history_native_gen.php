<?php
// history_native_gen.php OUTDIR — fixtures for tests/history_native_parity.sh: chat files in the loop's own layout (and a few odd shapes), and a prompt corpus.
$o = $argv[1]; @mkdir("$o/fx", 0775, true); @mkdir("$o/prompts", 0775, true);
function esc(string $s): string { return substr(json_encode($s, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 1, -1); }
function chat(string $name, array $exs, string $style = 'pretty', string $project = 'proj'): void {
    global $o;
    @mkdir("$o/fx/$name/proj", 0775, true);
    $items = [];
    foreach ($exs as $i => $e) {
        [$role, $agent, $text] = $e; $model = $e[3] ?? null; $id = $e[4] ?? ($i + 1); $tsKey = $e[5] ?? 'timestamp';
        $t = $style === 'raw' ? str_replace(['\\', '"'], ['\\\\', '\\"'], $text) : esc($text);
        $b = "    {\n      \"id\": $id,\n      \"$tsKey\": \"2026-10-01T10:0" . ($i % 10) . ":00Z\",\n      \"role\": \"$role\",\n";
        if ($role === 'agent') $b .= "      \"agent\": \"$agent\",\n      \"supplier\": \"$agent\",\n      \"model\": " . ($model === null ? 'null' : '"' . $model . '"') . ",\n      \"duration_s\": 1.5,\n      \"style\": \"chat\",\n      \"mode\": \"single\",\n";
        $b .= "      \"text\": \"$t\"\n    }";
        $items[] = $b;
    }
    $body = $items ? implode(",\n", $items) . "\n" : '';
    file_put_contents("$o/fx/$name/proj/chat_x.json", "{\n  \"schema_version\": 1,\n  \"project\": \"$project\",\n  \"chat\": \"x\",\n  \"created\": \"2026-10-01T10:00:00Z\",\n  \"updated\": \"2026-10-01T10:00:00Z\",\n  \"exchanges\": [\n$body  ]\n}\n");
}
$topics = [['How do I sort a list in python?', 'Use sorted(list) or list.sort(); both are stable.'], ['Explain docker networking bridges', "A bridge network connects containers on one host.\nUse docker network create mynet."],
  ['What is a mutex?', 'A mutual exclusion lock that protects shared state.'], ['Write a haiku about autumn rain', 'Grey rain on the leaves / the garden holds its breath / autumn folds the light'],
  ['How to compress a folder with tar?', "tar -czf out.tgz folder/\nAdd -v for verbose output."], ['Recipe for pancakes', 'Mix flour, milk, eggs; fry on a hot pan.'],
  ['Difference between TCP and UDP', 'TCP is reliable and ordered, UDP is not; UDP is lighter.'], ['Regex to match an email', 'Something like ^[^@\s]+@[^@\s]+\.[a-z]+$ for the simple case.'],
  ['Postgres index types', 'btree, hash, gin, gist, brin.'], ['Kubernetes pod restart policy', 'Always, OnFailure or Never.']];
$ex = function (int $n, string $agent = 'claude', ?string $model = 'claude-sonnet-4-6') use ($topics) { $r = []; for ($i = 0; $i < $n; $i++) { $t = $topics[$i % count($topics)]; $r[] = ['user', '', $t[0] . ($i >= 10 ? " (round $i)" : '')]; $r[] = ['agent', $agent, $t[1], $model]; } return $r; };
chat('empty', []);
chat('one', $ex(1));
chat('five', $ex(5));
chat('thirty', $ex(30, 'ollama', 'qwen2.5:7b'));
chat('agents', array_merge([['user', '', 'hi there'], ['agent', 'claude', 'hello', 'claude-opus-4-8'], ['user', '', 'second'], ['agent', 'gemini', 'ok', null], ['user', '', 'third question here'], ['agent', 'opencode', 'sure thing', 'qwen2.5:7b'],
  ['user', '', 'fourth'], ['agent', 'ollama', 'fine', 'llama3.2:3b'], ['user', '', 'fifth'], ['agent', 'Codex', 'caps', 'o4-mini'], ['user', '', 'sixth'], ['agent', '', 'no agent name', null]]));
$long = str_repeat('word ', 300); $multi = str_repeat('שלום עולם ', 200); $just = str_repeat('a', 1500); $over = str_repeat('b', 1501); $mb = str_repeat('é', 1500) . 'X';
chat('unicode', [['user', '', 'שלום, איך אתה? tell me about naïve café ☕'], ['agent', 'claude', "Hebrew: " . $multi . "\ntabs\there\n\\backslash \"quotes\"", 'claude-sonnet-4-6'], ['user', '', 'emoji 😀 and a long one'],
  ['agent', 'gemini', $long, null], ['user', '', 'exactly 1500'], ['agent', 'ollama', $just, 'm'], ['user', '', 'over 1500'], ['agent', 'ollama', $over, 'm'], ['user', '', 'multibyte boundary'], ['agent', 'claude', $mb, 'm'],
  ['user', '', "ctrl\x01char and unit\x1fsep and\ttab"], ['agent', 'claude', "line1\n\nline3\n", 'm']]);
chat('gaps', [['user', '', 'first', null, 1], ['agent', 'claude', 'a', 'm', 2], ['user', '', 'third', null, 5], ['agent', 'claude', 'b', 'm', 6], ['user', '', 'with ts key', null, 7, 'ts'], ['agent', 'claude', 'c', 'm', 8, 'ts']]);
chat('rawnl', $ex(3), 'raw');
file_put_contents("$o/fx/rawnl/proj/chat_x.json", str_replace('\n', "\n", file_get_contents("$o/fx/rawnl/proj/chat_x.json")) . '');   // old loops: real newlines inside strings
// shapes
@mkdir("$o/fx/oneline/proj", 0775, true); file_put_contents("$o/fx/oneline/proj/chat_x.json", "{\n  \"schema_version\": 1,\n  \"project\": \"p\",\n  \"chat\": \"x\",\n  \"created\": \"2026-10-01T10:00:00Z\",\n  \"updated\": \"2026-10-01T10:00:00Z\",\n  \"exchanges\": [],\n  \"x\": 1\n}\n");
@mkdir("$o/fx/oneline2/proj", 0775, true); file_put_contents("$o/fx/oneline2/proj/chat_x.json", "{\n  \"schema_version\": 1,\n  \"project\": \"p\",\n  \"chat\": \"x\",\n  \"updated\": \"2026-10-01T10:00:00Z\",\n  \"exchanges\": [] \n}\n");
@mkdir("$o/fx/phppretty/proj", 0775, true); file_put_contents("$o/fx/phppretty/proj/chat_x.json", json_encode(['schema_version' => 1, 'project' => 'p', 'chat' => 'x', 'created' => '2026-10-01T10:00:00Z', 'updated' => '2026-10-01T10:00:00Z',
  'exchanges' => [['id' => 1, 'timestamp' => 't', 'role' => 'user', 'text' => 'python sorting question'], ['id' => 2, 'timestamp' => 't', 'role' => 'agent', 'agent' => 'claude', 'model' => 'm', 'text' => 'use sorted']]], JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE) . "\n");
@mkdir("$o/fx/phppretty_empty/proj", 0775, true); file_put_contents("$o/fx/phppretty_empty/proj/chat_x.json", json_encode(['schema_version' => 1, 'project' => 'p', 'chat' => 'x', 'updated' => 'u', 'exchanges' => []], JSON_PRETTY_PRINT) . "\n");
@mkdir("$o/fx/nobracket/proj", 0775, true); file_put_contents("$o/fx/nobracket/proj/chat_x.json", "{\n  \"exchanges\": [\n    {\n      \"id\": 1,\n      \"role\": \"user\",\n      \"text\": \"hello world\"\n    }\n");
@mkdir("$o/fx/emptyfile/proj", 0775, true); file_put_contents("$o/fx/emptyfile/proj/chat_x.json", '');
@mkdir("$o/fx/missing/proj", 0775, true);
@mkdir("$o/fx/nonl/proj", 0775, true); file_put_contents("$o/fx/nonl/proj/chat_x.json", rtrim(file_get_contents("$o/fx/five/proj/chat_x.json"), "\n"));
// the prompt corpus: file => plain|odd
$P = [
 'short' => 'hi', 'short2' => 'and you?', 'seven' => 'one two three four five six seven', 'eight' => 'one two three four five six seven eight',
 'selfcontained' => 'Write a detailed explanation of how the quick sort algorithm works including pivot choice and complexity analysis please',
 'cont_and' => "and also tell me about the quick sort algorithm with its pivot choice and the average complexity analysis", 'cont_ok' => 'ok then please write a long explanation of the whole quick sort algorithm with every step described',
 'cont_okay' => 'okay so here is a long self contained request about sorting algorithms and their complexity analysis in detail', 'cont_what' => 'what about the quick sort algorithm and its pivot choice and also the average complexity analysis',
 'cont_how' => 'how about writing a longer explanation of the quick sort algorithm with its pivot choice and complexity analysis', 'cont_instead' => 'instead of that please write a full explanation of quick sort with pivot choice and complexity analysis',
 'cont_not' => 'android development guide covering activities fragments and the complete lifecycle with examples for every part',
 'cont_line2' => "Write a long explanation of the quick sort algorithm\nand then compare it with merge sort in terms of memory and complexity analysis",
 'cont_indent' => "Write a long explanation of the quick sort algorithm with pivot choice\n   \tyes please add the complexity analysis as well",
 'back_those' => 'please summarize those results into a short paragraph with the main points and the final recommendation for the team',
 'back_file' => 'can you change the file so that it also handles empty input and prints a helpful error message when something fails',
 'back_you' => 'you said earlier that the approach was fine but now I want a completely different long explanation of the topic',
 'back_chat' => 'in this chat we talked about many things so please list the main topics with one short line for each of them',
 'back_didwe' => 'did we already cover how docker networking works in detail or should I ask about bridges and overlay networks now',
 'back_sofar' => 'give me a recap of everything so far in this long conversation including the decisions and the open questions',
 'back_word' => 'the history of the roman empire from the republic until the fall in a detailed and well structured long essay',
 'back_substr' => 'a prehistory lesson about the ancient world and its summaries written for pupils with plenty of illustrated examples',
 'back_summarise' => 'please summarise the whole thing in a single paragraph that a non technical reader could understand easily today',
 'back_underscore' => 'what does the variable same_as_before mean in this long configuration example with many other settings listed',
 'mode' => "[CHAT MODE] Answer conversationally as if speaking.\n\nreply with just the word waterland", 'mode_long' => "[BUILD MODE] Answer carefully.\nWrite a detailed explanation of how the quick sort algorithm works including pivot choice and complexity analysis please",
 'mode_odd' => "[Mixed Mode] not a mode line\nand then a long request about quick sort algorithm pivot choice and complexity analysis please", 'mode_empty' => "[X MODE] hello",
 'now' => "tell me a long story about a dragon\n\n(Now: 2026-10-07 19:56 Wed, Asia/Jerusalem)", 'now_only' => '(Now: 2026-10-07 19:56 Wed, Asia/Jerusalem)', 'now_two' => 'a (Now: 2026-01-01 x) b (Now: 2026-01-02 y) c d e f g h i j k',
 'now_bad' => 'a (Now: 26-10-07 19:56) long text here that continues for many words so that it passes the short test easily',
 'trailing_nl' => "one two three four five six seven eight\n\n\n", 'nbsp' => "one\u{00A0}two\u{00A0}three four five six seven eight nine ten", 'tabs' => "one\ttwo\tthree\tfour five six seven eight nine ten",
 'hebrew' => 'שלום איך אתה מרגיש היום אני רוצה הסבר מפורט על מיון מהיר ועל הסיבוכיות שלו בבקשה', 'hebrew_short' => 'שלום עולם',
 'terms_many' => 'python sorting docker networking mutex haiku autumn tar compress pancakes recipe tcp udp regex email postgres index kubernetes pod restart policy lists',
 'terms_stop' => 'this that what with from have were does about there their then than they them please',
 'terms_digits' => '1234 abc12 9abc ab12cd 12ab a1b2c3 word2',
 'terms_dup' => 'python python Python PYTHON sorting sorting',
 'terms_punct' => 'docker, networking! (bridges) "overlay" and bridges-again/overlay',
 'keyword_python' => 'how did we sort the python list again', 'keyword_docker' => 'tell me again about docker networking bridges and overlay', 'keyword_postgres' => 'postgres index types again please with examples',
 'keyword_none' => 'zzzzzz qqqqqq xxxxxxxx', 'keyword_unicode' => 'café naïve שלום python', 'keyword_or' => 'regex OR email AND postgres NOT index', 'keyword_quote' => 'say "python" and "docker" with quotes inside',
 'empty' => '', 'spaces' => '   ', 'newlines' => "\n\n", 'ctrl' => "one\x01two three four five six seven eight nine ten",
 'oddsurr' => "one two three four five six seven eight \xE2\x80\xA8 nine ten", 'vtab' => "hello\x0bworld one two three four five six seven eight",
];
$odd = ['emoji' => "one two three four five six seven eight 😀 nine", 'emoji_new' => "one two three four five six seven 🥹", 'invalid' => "one two three four five six seven \xFF\xFE eight nine", 'nel' => "one\xC2\x85two three four five six seven eight nine ten"];
$man = '';
foreach ($P as $k => $v) { file_put_contents("$o/prompts/$k.txt", $v); $man .= "$k plain\n"; }
foreach ($odd as $k => $v) { file_put_contents("$o/prompts/$k.txt", $v); $man .= "$k odd\n"; }
file_put_contents("$o/prompts/MANIFEST", $man);
$fx = array_diff(scandir("$o/fx"), ['.', '..']); sort($fx);
file_put_contents("$o/fx/MANIFEST", implode("\n", $fx) . "\n");
echo count($P) + count($odd) . " prompts, " . count($fx) . " fixtures\n";
