#!/usr/bin/env bash
# catalog_feed_test.sh — the signed catalog feed (cockpit_app/catalog_feed_lib.php, catalog_feed.php, the merge in workers.php) and custom suppliers that really work.
#   A  the library: signature checks (good / tampered / wrong key / garbage), validation (bad prices, non-https suggestions, bad dates), the merge (price update, new model, retire, order,
#      fields a feed may NOT touch), suggestions, the age of the catalog
#   B  through aicserver + php-cgi against a fake feed server and a fake OpenAI-style supplier: the feed is OFF by default and nothing is fetched; ON, a signed feed changes a price; a tampered
#      feed is refused and the old one kept; OFF again, the shipped price is back; add_custom with an address, then a real call to that custom supplier, a price on Add model
#   bash tests/catalog_feed_test.sh     SKIPPED without php (sodium), aicserver, php-cgi, curl, jq
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"; PHPCGI="$(command -v php-cgi)"
command -v php curl jq >/dev/null && php -r 'exit(function_exists("sodium_crypto_sign_keypair")?0:1);' || { echo "catalog_feed_test: needs php with sodium, curl, jq - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/cf_XXXX) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; [ "$CGI" != 0 ] && pkill -KILL -P $CGI 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
W="$T/web"; D="$T/data"; mkdir -p "$W" "$D" "$T/sess" "$T/proj" "$T/feed/api"; cp -r "$ROOT/cockpit_app/." "$W/"
# a key pair that exists only for this test; the app under test trusts ONLY it
php -r '$kp=sodium_crypto_sign_keypair(); file_put_contents("'"$T"'/sk", base64_encode(sodium_crypto_sign_secretkey($kp))); file_put_contents("'"$W"'/catalog_pubkeys.txt", "# test key\n".base64_encode(sodium_crypto_sign_publickey($kp))."\n"); $o=sodium_crypto_sign_keypair(); file_put_contents("'"$T"'/sk_other", base64_encode(sodium_crypto_sign_secretkey($o)));'
sign() { php -r '$sk=base64_decode(trim(file_get_contents("'"$T"'/'"${2:-sk}"'"))); echo base64_encode(sodium_crypto_sign_detached(file_get_contents($argv[1]), $sk));' "$1"; }
feed() {   # feed AS_OF 'MODELS_JSON' -> $T/feed/api/catalog.json + .sig (signed with the test key)
  jq -n --arg d "$1" --argjson m "$2" '{format_version:1, as_of:$d, providers:{anthropic:{models:$m}}, new_providers:[{id:"newco",name:"NewCo",base:"openai",base_url:"https://api.newco.example/v1",models:[{id:"newco-1",label:"NewCo 1",kinds:["text"],free:false,pricing:{input_per_mtok:1,output_per_mtok:2}}]}]}' > "$T/feed/api/catalog.json"
  sign "$T/feed/api/catalog.json" > "$T/feed/api/catalog.json.sig"; }

# ───────────────────────── A. the library ─────────────────────────
cat > "$T/lib_test.php" <<'PHP'
<?php
$W = $argv[1]; $T = $argv[2]; require "$W/catalog_feed_lib.php";
$f = 0; $n = 0; $chk = function ($ok, $m) use (&$f, &$n) { $n++; if (!$ok) { $f++; echo "  FAIL $m\n"; } };
$sk = base64_decode(trim(file_get_contents("$T/sk"))); $sk2 = base64_decode(trim(file_get_contents("$T/sk_other")));
$sign = fn($b, $k = null) => base64_encode(sodium_crypto_sign_detached($b, $k ?? $sk));
$bytes = '{"format_version":1}';
$chk(catalog_feed_verify($bytes, $sign($bytes)), 'a good signature must verify');
$chk(!catalog_feed_verify($bytes . ' ', $sign($bytes)), 'a changed byte must not verify');
$chk(!catalog_feed_verify($bytes, $sign($bytes, $sk2)), 'a signature by another key must not verify');
$chk(!catalog_feed_verify($bytes, 'not base64 !!'), 'garbage must not verify');
$chk(!catalog_feed_verify($bytes, ''), 'an empty signature must not verify');
$ship = json_decode(file_get_contents("$W/workers_providers.json"), true);
$good = ['format_version' => 1, 'as_of' => '2026-11-01', 'providers' => ['anthropic' => ['models' => [['id' => 'claude-haiku-5-5', 'pricing' => ['input_per_mtok' => 0.2, 'output_per_mtok' => 0.9]]]]]];
$chk(catalog_feed_validate($good) === null, 'a good feed must validate: ' . catalog_feed_validate($good));
$mut = function ($fn) use ($good) { $g = $good; $fn($g); return catalog_feed_validate($g); };
$chk($mut(function (&$g) { $g['providers']['anthropic']['models'][0]['pricing']['input_per_mtok'] = -1; }) !== null, 'a negative price must be refused');
$chk($mut(function (&$g) { $g['providers']['anthropic']['models'][0]['pricing']['output_per_mtok'] = '5'; }) !== null, 'a price that is a string must be refused');
$chk($mut(function (&$g) { $g['providers']['anthropic']['models'][0]['pricing']['input_per_mtok'] = 99999; }) !== null, 'an absurd price must be refused');
$chk($mut(function (&$g) { $g['as_of'] = 'yesterday'; }) !== null, 'a bad date must be refused');
$chk($mut(function (&$g) { $g['format_version'] = 2; }) !== null, 'an unknown format must be refused');
$chk($mut(function (&$g) { $g['providers']['anthropic']['models'][0]['id'] = 'bad id with spaces'; }) !== null, 'a model id with spaces must be refused');
$chk($mut(function (&$g) { $g['new_providers'] = [['id' => 'x', 'base' => 'openai', 'base_url' => 'http://evil.example/v1']]; }) !== null, 'a non-https suggestion address must be refused');
$chk($mut(function (&$g) { $g['new_providers'] = [['id' => 'x', 'base' => 'openai', 'base_url' => 'https://ok.example/v1']]; }) === null, 'an https suggestion is fine');
// the merge
$feed = $good; $feed['providers']['anthropic']['models'] = [
  ['id' => 'claude-haiku-5-5', 'pricing' => ['input_per_mtok' => 0.2, 'output_per_mtok' => 0.9], 'base_url' => 'https://evil.example', 'evil' => 'x', 'label' => 'Haiku Five'],
  ['id' => 'claude-brand-new-9', 'label' => 'Brand New 9', 'pricing' => ['input_per_mtok' => 7, 'output_per_mtok' => 8]]];
$feed['providers']['anthropic']['retire'] = ['claude-opus-4-8'];
$feed['providers']['no_such_supplier'] = ['models' => [['id' => 'ghost']]];
$feed['providers']['anthropic']['base_url'] = 'https://evil.example/v1';
$m = catalog_feed_apply($ship, $feed); $a = null; foreach ($m['providers'] as $p) if ($p['id'] === 'anthropic') $a = $p;
$by = []; foreach ($a['models'] as $mm) $by[$mm['id']] = $mm;
$chk($by['claude-haiku-5-5']['pricing']['input_per_mtok'] == 0.2 && $by['claude-haiku-5-5']['label'] === 'Haiku Five', 'a feed updates price and label of a known model');
$chk(isset($by['claude-haiku-5-5']['pricing']) && !isset($by['claude-haiku-5-5']['evil']) && !isset($by['claude-haiku-5-5']['base_url']), 'a feed must not smuggle fields (base_url, unknown keys) into a model');
$chk(isset($by['claude-brand-new-9']) && $by['claude-brand-new-9']['pricing']['output_per_mtok'] == 8 && !empty($by['claude-brand-new-9']['from_feed']), 'a new model is added, marked from_feed');
$chk(!empty($by['claude-opus-4-8']['deprecated']), 'retire marks a model deprecated');
$chk(($a['base_url'] ?? 'unchanged') === ($ship['providers'][array_search('anthropic', array_column($ship['providers'], 'id'))]['base_url'] ?? 'unchanged'), "a feed must never change a supplier's address");
$chk(count(array_filter($m['providers'], fn($p) => ($p['id'] ?? '') === 'no_such_supplier')) === 0, 'a feed must not create a supplier by listing it under providers');
$chk($a['models'][0]['id'] === 'claude-haiku-5-5' && $a['models'][1]['id'] === 'claude-brand-new-9', "the feed's own order comes first");
$chk(count($a['models']) === count($ship['providers'][array_search('anthropic', array_column($ship['providers'], 'id'))]['models']) + 1, 'models the feed does not mention are kept');
$chk(catalog_feed_apply($ship, null) === $ship, 'no feed: the shipped catalog unchanged');
// suggestions
$sg = $good; $sg['new_providers'] = [['id' => 'newco', 'name' => 'NewCo', 'base' => 'openai', 'base_url' => 'https://api.newco.example/v1'], ['id' => 'groq', 'base' => 'openai', 'base_url' => 'https://api.groq.example/v1']];
$s = catalog_feed_suggestions($ship, $sg); $chk(count($s) === 1 && $s[0]['id'] === 'newco', 'a supplier already in the catalog is not suggested again: ' . json_encode(array_column($s, 'id')));
// age
$chk(catalog_age_days(date('Y-m-d', time() - 3 * 86400)) === 3, 'age in days');
$chk(catalog_as_of(['as_of' => '2026-01-01', 'feed_as_of' => '2026-03-01']) === '2026-03-01' && catalog_as_of(['as_of' => '2026-05-01']) === '2026-05-01', 'the catalog date is the newer of shipped and feed');
$chk(preg_match('/^\d{4}-\d{2}-\d{2}$/', (string)($ship['as_of'] ?? '')) === 1, 'the shipped catalog carries an as_of date (run Installs/catalog_tool.php build)');
echo "A: " . ($n - $f) . " passed, $f failed\n"; exit($f ? 1 : 0);
PHP
php "$T/lib_test.php" "$W" "$T" > "$T/A.out" 2>&1; rc=$?; grep FAIL "$T/A.out"; ap=$(sed -n 's/^A: \([0-9]*\) passed.*/\1/p' "$T/A.out"); af=$(sed -n 's/^A: .* \([0-9]*\) failed/\1/p' "$T/A.out")
[ -n "$ap" ] && { n=$((n + ap)); fails=$((fails + af)); } || bad "part A did not finish: $(tail -3 "$T/A.out")"

# ───────────────────────── B. over HTTP ─────────────────────────
[ -x "$AS" ] && [ -n "$PHPCGI" ] || { echo "catalog_feed_test: part B needs aicserver and php-cgi - SKIPPED"; echo "catalog_feed_test: $n passed, $fails failed (A only)"; [ $fails = 0 ]; exit; }
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/t.sock","queue_dir":"%s/q","response_dir":"%s/r"}' "$T" "$D" "$D" "$T" "$T" "$T" "$T" > "$W/paths.json"
# one fake server: the feed under /api/ (and a count of requests) and an OpenAI-style supplier under /v1/
cat > "$T/fake.php" <<'PHP'
<?php
$u = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
if (strpos($u, '/api/catalog.json') === 0) { file_put_contents(__DIR__ . '/feed_calls', "x\n", FILE_APPEND); $f = __DIR__ . '/feed' . $u; if (!is_file($f)) { http_response_code(404); exit; } echo file_get_contents($f); exit; }
if (strpos($u, '/v1/chat/completions') !== false) { file_put_contents(__DIR__ . '/last_body.json', file_get_contents('php://input')); file_put_contents(__DIR__ . '/last_auth', $_SERVER['HTTP_AUTHORIZATION'] ?? '');
  header('Content-Type: application/json'); echo json_encode(['choices' => [['message' => ['content' => 'custom supplier says hi'], 'finish_reason' => 'stop']], 'usage' => ['prompt_tokens' => 10, 'completion_tokens' => 5]]); exit; }
http_response_code(404);
PHP
FP=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$FP "$T/fake.php" >"$T/fake.log" 2>&1 & PIDS="$PIDS $!"
export COCKPIT_CATALOG_FEED_URL="http://127.0.0.1:$FP/api/catalog.json"
PHP_FCGI_CHILDREN=3 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$T/sess" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
PORT=$((20000 + RANDOM % 20000))
jq -n --argjson port "$PORT" --arg root "$W" --arg php "unix:$T/php.sock" '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:60},deny:[".*"],limits:{max_body_mb:8}}' > "$T/srv.json"
"$AS" run --config "$T/srv.json" >"$T/srv.log" 2>&1 & PIDS="$PIDS $!"
U="http://127.0.0.1:$PORT/cockpit"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done; for i in $(seq 40); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done
curl -s -X POST -H "Content-Type: application/json" -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=setup" | jq -e .ok >/dev/null || { echo "setup failed"; exit 1; }
curl -s -c "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=login" | jq -e .ok >/dev/null || { echo "login failed"; exit 1; }
wk() { curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$2" "$U/workers.php?action=$1"; }
cf() { curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "${2:-{\}}" "$U/catalog_feed.php?action=$1"; }
price() { curl -s -b "$T/jar" "$U/workers.php?action=providers" | jq -r --arg m "$1" '[.providers[]|select(.id=="anthropic")|.models[]|select(.id==$m)|.pricing.input_per_mtok][0]'; }
FC() { [ -f "$T/feed_calls" ] && wc -l < "$T/feed_calls" || echo 0; }

st=$(cf status); [ "$(echo "$st" | jq -r .enabled)" = false ] && [ "$(echo "$st" | jq -r .can_verify)" = true ] && echo "$st" | jq -e '.as_of|test("^[0-9]{4}-")' >/dev/null && ok || bad "status at the start: $st"
[ "$(price claude-haiku-5-5)" = 0.1 ] && ok || bad "the shipped Haiku 5.5 input price should be 0.1: $(price claude-haiku-5-5)"
feed 2099-01-01 '[{"id":"claude-haiku-5-5","pricing":{"input_per_mtok":0.2,"output_per_mtok":0.9}}]'
r=$(cf check); [ "$(echo "$r" | jq -r .ok)" = false ] && [ "$(FC)" = 0 ] && ok || bad "with the feed OFF, check must refuse and fetch NOTHING: $r (feed requests: $(FC))"
cf set '{"enabled":true}' | jq -e '.enabled==true' >/dev/null && ok || bad "switching the feed on"
r=$(cf check); [ "$(echo "$r" | jq -r .ok)" = true ] && [ "$(echo "$r" | jq -r .feed_as_of)" = 2099-01-01 ] && ok || bad "a signed feed must be accepted: $r"
[ "$(price claude-haiku-5-5)" = 0.2 ] && ok || bad "the feed's price must reach the catalog: $(price claude-haiku-5-5)"
echo "$r" | jq -e '.suggestions|length==1 and .[0].id=="newco" and .[0].base_url=="https://api.newco.example/v1"' >/dev/null && ok || bad "a new supplier must be a suggestion: $(echo "$r" | jq -c .suggestions)"
curl -s -b "$T/jar" "$U/workers.php?action=providers" | jq -e '[.providers[].id]|index("newco")|not' >/dev/null && ok || bad "a suggested supplier must NOT be merged into the catalog"
# a feed that is not signed by our key, or was changed after signing: refused, the earlier one stays
feed 2099-02-01 '[{"id":"claude-haiku-5-5","pricing":{"input_per_mtok":0.3,"output_per_mtok":1}}]'; sign "$T/feed/api/catalog.json" sk_other > "$T/feed/api/catalog.json.sig"
r=$(cf check); [ "$(echo "$r" | jq -r .ok)" = true ] && echo "$r" | jq -r .last_result | grep -qi "signature" && [ "$(price claude-haiku-5-5)" = 0.2 ] && ok || bad "a feed signed by another key: refused, price kept: $(echo "$r" | jq -c '{last_result}') price=$(price claude-haiku-5-5)"
feed 2099-02-01 '[{"id":"claude-haiku-5-5","pricing":{"input_per_mtok":0.3,"output_per_mtok":1}}]'; sed -i 's/0\.3/0.0001/' "$T/feed/api/catalog.json"
r=$(cf check); echo "$r" | jq -r .last_result | grep -qi "signature" && [ "$(price claude-haiku-5-5)" = 0.2 ] && ok || bad "a feed changed after signing: refused, price kept: $(echo "$r" | jq -c '{last_result}') price=$(price claude-haiku-5-5)"
feed 2098-01-01 '[{"id":"claude-haiku-5-5","pricing":{"input_per_mtok":0.5,"output_per_mtok":1}}]'
r=$(cf check); echo "$r" | jq -r .last_result | grep -qi "older" && [ "$(price claude-haiku-5-5)" = 0.2 ] && ok || bad "an older signed feed must not replace a newer one: $(echo "$r" | jq -c '{last_result}')"
# tampering with the stored copy afterwards: it stops counting
CD=$(dirname "$(find "$D" -name catalog_feed.json | head -1)"); [ -f "$CD/catalog_feed.json" ] && ok || bad "the verified feed must be stored in the data folder"
cp "$CD/catalog_feed.json" "$T/keep.json"; sed -i 's/0\.2/0.0002/' "$CD/catalog_feed.json"
[ "$(price claude-haiku-5-5)" = 0.1 ] && ok || bad "a stored feed edited after verification must be ignored (fail closed): $(price claude-haiku-5-5)"
cp "$T/keep.json" "$CD/catalog_feed.json"; [ "$(price claude-haiku-5-5)" = 0.2 ] && ok || bad "the restored feed counts again"
# switching OFF: the shipped price is back, and nothing more is fetched
before=$(FC); cf set '{"enabled":false}' >/dev/null; [ "$(price claude-haiku-5-5)" = 0.1 ] && ok || bad "OFF: the shipped price must be back: $(price claude-haiku-5-5)"
cf check >/dev/null; [ "$(FC)" = "$before" ] && ok || bad "OFF: nothing may be fetched"
# the price field on Add model; a bad price refused
wk add_model '{"provider":"groq","model_id":"my-new-model","label":"Mine","kinds":["text"],"free":false,"pricing":{"input_per_mtok":1.5,"output_per_mtok":6}}' | jq -e .ok >/dev/null && ok || bad "add_model with a price"
curl -s -b "$T/jar" "$U/workers.php?action=providers" | jq -e '[.providers[]|select(.id=="groq")|.models[]|select(.id=="my-new-model")|.pricing.output_per_mtok][0]==6' >/dev/null && ok || bad "the added model must carry its price"
wk add_model '{"provider":"groq","model_id":"bad-price","pricing":{"input_per_mtok":-3,"output_per_mtok":1}}' | jq -e '.ok==false' >/dev/null && ok || bad "a negative price on add_model must be refused"
# custom suppliers: an address is required, https (or a private http), and the supplier REALLY works
wk add_custom '{"provider":"mycorp","name":"MyCorp","base":"openai","models":[{"id":"m1","label":"M1","kinds":["text"],"free":true}]}' | jq -e '.ok==false' >/dev/null && ok || bad "a custom supplier without an address must be refused"
wk add_custom '{"provider":"mycorp","name":"MyCorp","base":"openai","base_url":"http://example.com/v1","models":[{"id":"m1","free":true}]}' | jq -e '.ok==false' >/dev/null && ok || bad "plain http to a public host must be refused"
wk add_custom '{"provider":"mycorp","name":"MyCorp","base":"openai","base_url":"http://127.0.0.1:'$FP'/v1/","models":[{"id":"m1","label":"M1","kinds":["text"],"free":true}]}' | jq -e .ok >/dev/null && ok || bad "add_custom with a local http address"
curl -s -b "$T/jar" "$U/workers.php?action=providers" | jq -e '[.providers[]|select(.id=="mycorp")|.base_url]==["http://127.0.0.1:'$FP'/v1"]' >/dev/null && ok || bad "the custom supplier must keep its address (trailing slash trimmed)"
wk set_key '{"provider":"mycorp","key":"sk-custom"}' | jq -e .ok >/dev/null && ok || bad "set_key for the custom supplier"
wk enable_provider '{"provider":"mycorp","enabled":true}' | jq -e .ok >/dev/null && ok || bad "enable the custom supplier"
r=$(wk invoke '{"provider":"mycorp","model":"m1","task":"text","prompt":"hello","user_text":"hello"}')
[ "$(echo "$r" | jq -r .output)" = "custom supplier says hi" ] && ok || bad "a call to a custom supplier must reach ITS address and answer: $r"
[ "$(cat "$T/last_auth" 2>/dev/null)" = "Bearer sk-custom" ] && ok || bad "the custom supplier must get ITS key: $(cat "$T/last_auth" 2>/dev/null)"
wk add_custom '{"provider":"paidco","name":"PaidCo","base":"openai","base_url":"http://127.0.0.1:'$FP'/v1","models":[{"id":"p1","free":false,"pricing":{"input_per_mtok":1,"output_per_mtok":2}}]}' >/dev/null
curl -s -b "$T/jar" "$U/workers.php?action=providers" | jq -e '[.providers[]|select(.id=="paidco")|.incurs_cost]==[true]' >/dev/null && ok || bad "a custom supplier with a paid model must count as paid (consent gate + caps apply)"
wk set_key '{"provider":"paidco","key":"sk-p"}' >/dev/null; r=$(wk invoke '{"provider":"paidco","model":"p1","task":"text","prompt":"hello"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -qi "spend\|enabled\|consent" && ok || bad "a paid custom supplier must be gated like any paid one: $r"
echo "catalog_feed_test: $n passed, $fails failed"; [ $fails = 0 ]
