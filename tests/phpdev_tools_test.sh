#!/usr/bin/env bash
# phpdev_tools_test.sh — the PHP project tools (cockpit_app/php_tool, tools_builtins/phpdev.json, kinds/php-backend.json) on a small project with a syntax error, risky code, an
# unguarded endpoint and modern syntax.   bash tests/phpdev_tools_test.sh     SKIPPED without php
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; PT="$ROOT/cockpit_app/php_tool"
command -v php >/dev/null 2>&1 || { echo "phpdev_tools_test: php is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
mkdir -p proj/lib proj/vendor/x; cd proj
printf '<?php\nsession_start();\nif (empty($_SESSION["user"])) { http_response_code(401); exit; }\n' > auth.php
printf '<?php\nrequire __DIR__ . "/auth.php";\n$id = (int)$_GET["id"];\necho json_encode(["id" => $id]);\n' > api.php
cat > open.php <<'PHP'
<?php
// no auth here
$name = $_GET['name'];
echo "Hello " . $_GET['name'];
$r = mysqli_query($db, "SELECT * FROM users WHERE name = '" . $_GET['name'] . "'");
system("ls " . $_GET['dir']);
include $_GET['page'] . '.php';
header('Location: ' . $_GET['next']);
$x = unserialize($_COOKIE['data']);
eval($code);
$h = md5($password);
curl_setopt($c, CURLOPT_SSL_VERIFYPEER, false);
$token = rand(1, 9999) . "token";
$ok = @file_get_contents($u);
$cfg = ['password' => 'sup3rS3cretPassw0rd'];
$safe = htmlspecialchars($_GET['q']); echo $safe;
// system("ls " . $_GET['commented']);
PHP
printf '<?php\nfunction oops( {\n  echo "x";\n}\n' > broken.php
cat > lib/Thing.php <<'PHP'
<?php
declare(strict_types=1);
namespace App;
enum Suit: string { case H = 'h'; }
final class Thing {
    public function __construct(private readonly int $n) {}
    public function run(): string { return match($this->n) { 1 => 'one', default => 'many' }; }
    public static function make(?array $a): static { return new static($a?->count ?? 0); }
}
function helper(int|string $v): mixed { return $v; }
PHP
echo '<?php eval($_GET["x"]);' > vendor/x/skip.php
printf '<?php\nif (PHP_SAPI !== "cli") { http_response_code(403); exit; }\n$a = $_GET["a"] ?? "";\n' > cli_only.php
cd ..
sum0=$(find proj -type f | sort | xargs md5sum | md5sum)
# lint
php "$PT" lint proj l.md >/dev/null; has "broken.php(2) Error: syntax error" l.md && has "[exit code 1]" l.md && has "Files: 6" l.md && ok || bad "lint: $(sed -n 3,9p l.md)"
php "$PT" lint proj/api.php l2.md >/dev/null; has "[exit code 0]" l2.md && ok || bad "lint of one good file"
grep -q "skip.php" l.md && bad "vendor/ was not skipped" || ok
[ "$(grep -cE '^(.+?)\([0-9]+\) Error: ' l.md)" = 1 ] && ok || bad "summary-box regex"
# scan
php "$PT" scan proj s.md >/dev/null; has "[exit code 1]" s.md && ok || bad "scan exit"
for want in "open.php(4) Warning: output of request data" "open.php(5) Error: SQL built from request data" "open.php(6) Error: command execution with request data" "open.php(7) Error: include of request data" "open.php(8) Warning: redirect to a request value" "open.php(9) Error: unserialize of request data" "open.php(10) Error: code execution" "open.php(11) Warning: weak hash" "open.php(12) Warning: TLS certificate" "open.php(13) Warning: an unseeded or weak random" "open.php(14) Note: error suppression" "open.php(15) Note: a hard-coded password"; do has "$want" s.md && ok || bad "scan misses: $want"; done
grep -q "open.php(16)" s.md && bad "an escaped echo (htmlspecialchars) was flagged" || ok
grep -q "open.php(17)" s.md && bad "a commented line was flagged" || ok
grep -q "skip.php" s.md && bad "scan went into vendor/" || ok
# guard
php "$PT" guard proj g.md >/dev/null; has "open.php(1) Warning: reads the request and does not include auth.php" g.md && ok || bad "unguarded endpoint: $(grep -E 'Warning' g.md)"
grep -q "api.php" g.md && bad "api.php includes auth.php" || ok
grep -q "cli_only.php" g.md && bad "a command-line-only script was listed" || ok
has "NOT guarded: 1" g.md && ok || bad "guard counts: $(sed -n 4p g.md)"
printf '<?php\nrequire "login_check.php";\n$a = $_POST["a"];\n' > proj/other.php; php "$PT" guard proj g2.md auth=login_check.php >/dev/null; grep -q "other.php" g2.md && bad "auth=login_check.php was ignored" || ok; rm proj/other.php
php "$PT" guard proj g3.md "auth=../etc/passwd;rm" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad auth file name was not refused"
# outline
php "$PT" outline proj o.md >/dev/null; has "line 4: enum Suit" o.md && has "line 5: class Thing" o.md && has "method Thing::run()" o.md && has "function helper()" o.md && ok || bad "outline: $(sed -n 3,14p o.md)"
# version
php "$PT" version proj v.md >/dev/null; has "Needs PHP **8.1** or newer" v.md && has "- enum: 1 use(s)" v.md && has "- match expression: 1 use(s)" v.md && has "- the ?-> operator" v.md && has "union types" v.md && ok || bad "version: $(sed -n 3,12p v.md)"
printf '<?php\n$a = [1,2];\necho count($a);\n' > old.php; mkdir old; cp old.php old/a.php; php "$PT" version old v2.md >/dev/null; has "Needs PHP **5.4** or newer" v2.md && ok || bad "an old-style file needs only 5.4"
# refusals, original, guard, definitions
php "$PT" lint nope l.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing folder was not refused"
mkdir empty; php "$PT" lint empty l.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no PHP was not refused"
php "$PT" frob proj l.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(find proj -type f | sort | xargs md5sum | md5sum)" = "$sum0" ] && ok || bad "the project changed (the tools only read)"
head -20 "$ROOT/cockpit_app/php_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/php_tool (lint|scan|guard|outline|version) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/phpdev.json" > pc 2>&1; [ "$(cat pc)" = 5 ] && ok || bad "phpdev.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/php-backend.json")" = phpdev ] && ok || bad "the kind does not name the tool"
echo "phpdev_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
