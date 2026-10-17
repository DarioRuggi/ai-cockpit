#!/usr/bin/env bash
# anthropic_invoke_http_test.sh — the REAL workers.php?action=invoke for the Anthropic provider, through aicserver + php-cgi, against a fake Anthropic server:
# the paid-spend gate (consent, cap with no known price), the identity/history going to a system prompt, the SSE stream (chunks, final, [DONE]), the plain JSON path,
# and the spend ledger afterwards.   bash tests/anthropic_invoke_http_test.sh     SKIPPED without aicserver / php-cgi / curl / jq
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"; PHPCGI="$(command -v php-cgi)"
[ -x "$AS" ] && [ -n "$PHPCGI" ] && command -v php curl jq >/dev/null || { echo "anthropic_invoke_http_test: needs aicserver, php-cgi, php, curl, jq - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/ai_XXXX) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; pkill -KILL -P $CGI 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
W="$T/web"; D="$T/data"; mkdir -p "$W" "$D" "$T/sess" "$T/proj"; cp -r "$ROOT/cockpit_app/." "$W/"
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/t.sock","queue_dir":"%s/q","response_dir":"%s/r"}' "$T" "$D" "$D" "$T" "$T" "$T" "$T" > "$W/paths.json"
# the fake Anthropic
cat > "$T/fake.php" <<'PHP'
<?php
$h = array_change_key_case(getallheaders(), CASE_LOWER); $body = file_get_contents('php://input'); file_put_contents(__DIR__ . '/last_body.json', $body); file_put_contents(__DIR__ . '/calls', "x\n", FILE_APPEND);
if (strpos($_SERVER['REQUEST_URI'], '/chat/completions') === false && ($h['x-api-key'] ?? '') !== 'sk-test') { http_response_code(401); header('Content-Type: application/json'); echo json_encode(['error' => ['message' => 'invalid x-api-key']]); exit; }
$j = json_decode($body, true);
if (strpos($_SERVER['REQUEST_URI'], '/chat/completions') !== false) {
  if (($h['authorization'] ?? '') !== 'Bearer sk-oa') { http_response_code(401); echo json_encode(['error' => ['message' => 'bad key']]); exit; }
  header('Content-Type: text/event-stream'); foreach (['Open', 'AI ', 'style'] as $t) { echo 'data: ' . json_encode(['choices' => [['delta' => ['content' => $t]]]]) . "\n\n"; flush(); }
  echo 'data: ' . json_encode(['choices' => [['delta' => [], 'finish_reason' => 'stop']]]) . "\n\n"; echo 'data: ' . json_encode(['choices' => [], 'usage' => ['prompt_tokens' => 1000, 'completion_tokens' => 2000]]) . "\n\ndata: [DONE]\n\n"; exit; }
if (!empty($j['stream'])) { header('Content-Type: text/event-stream'); $ev = function ($e, $d) { echo "event: $e\ndata: " . json_encode($d) . "\n\n"; flush(); };
  $ev('message_start', ['message' => ['usage' => ['input_tokens' => 1000, 'output_tokens' => 1]]]);
  foreach (['One ', 'two ', 'three'] as $t) $ev('content_block_delta', ['delta' => ['type' => 'text_delta', 'text' => $t]]);
  $ev('message_delta', ['delta' => ['stop_reason' => 'end_turn'], 'usage' => ['output_tokens' => 2000]]); $ev('message_stop', []); exit; }
header('Content-Type: application/json'); echo json_encode(['content' => [['type' => 'text', 'text' => 'Plain JSON answer']], 'usage' => ['input_tokens' => 1000, 'output_tokens' => 2000]]);
PHP
FP=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$FP "$T/fake.php" >"$T/fake.log" 2>&1 & PIDS="$PIDS $!"
# point the shipped catalog's Anthropic entry at the fake and give model fake-priced a price, fake-free none
jq --arg b "http://127.0.0.1:$FP/v1" '(.providers[]|select(.id=="openai")) |= (.base_url=$b | .models=[{"id":"oa-priced","label":"O","kinds":["text"],"free":false,"pricing":{"input_per_mtok":1,"output_per_mtok":2}}]) | (.providers[]|select(.id=="anthropic")) |= (.base_url=$b | .models=[{"id":"fake-priced","label":"P","kinds":["text"],"free":false,"pricing":{"input_per_mtok":3,"output_per_mtok":15}},{"id":"fake-noprice","label":"N","kinds":["text"],"free":false}])' "$ROOT/cockpit_app/workers_providers.json" > "$W/workers_providers.json"
PHP_FCGI_CHILDREN=3 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$T/sess" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
PORT=$((20000 + RANDOM % 20000))
jq -n --argjson port "$PORT" --arg root "$W" --arg php "unix:$T/php.sock" '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:60},deny:[".*"],limits:{max_body_mb:8}}' > "$T/srv.json"
"$AS" run --config "$T/srv.json" >"$T/srv.log" 2>&1 & PIDS="$PIDS $!"
U="http://127.0.0.1:$PORT/cockpit"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done; for i in $(seq 40); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done
r0=$(curl -s -X POST -H "Content-Type: application/json" -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=setup"); echo "$r0" | jq -e .ok >/dev/null || { echo "setup failed: [$r0] $(tail -2 "$T/srv.log")"; exit 1; }
curl -s -c "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=login" | jq -e .ok >/dev/null || { echo "login failed"; exit 1; }
wk() { curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$2" "$U/workers.php?action=$1"; }
CALLS() { [ -f "$T/calls" ] && wc -l < "$T/calls" || echo 0; }
# 1. no consent: refused before any call
wk set_key '{"provider":"anthropic","key":"sk-test"}' | jq -e .ok >/dev/null && ok || bad "set_key"
r=$(wk invoke '{"provider":"anthropic","model":"fake-priced","task":"text","prompt":"hi"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -qi "not enabled\|spend is off\|consent" && [ "$(CALLS)" = 0 ] && ok || bad "a call before consent: $r"
CD=$(dirname "$(find "$D" -name workers_keys.enc | head -1)"); [ -d "$CD" ] && ok || bad "cannot find the per-user data folder"
printf '{"allow_paid_api_spend":true,"caps":{"global_monthly_usd":5,"per_model_monthly_usd":{}}}' > "$CD/settings.json"
wk enable_provider '{"provider":"anthropic","enabled":true}' | jq -e .ok >/dev/null && ok || bad "enable_provider after consent"
# 2. a model with no known price while a cap is set: refused, no call
r=$(wk invoke '{"provider":"anthropic","model":"fake-noprice","task":"text","prompt":"hi"}'); [ "$(echo "$r" | jq -r .gate)" = no_price ] && [ "$(CALLS)" = 0 ] && ok || bad "no price + cap: $r"
# 3. plain JSON path
r=$(wk invoke '{"provider":"anthropic","model":"fake-priced","task":"text","prompt":"Plain question","user_text":"Plain question"}')
[ "$(echo "$r" | jq -r .output)" = "Plain JSON answer" ] && [ "$(echo "$r" | jq -r .tokens_in)" = 1000 ] && ok || bad "plain invoke: $r"
[ "$(echo "$r" | jq -r .cost_usd)" = 0.033 ] && ok || bad "cost = 1000/1e6*3 + 2000/1e6*15 = 0.033: $(echo "$r" | jq -c '{cost_usd}')"
jq -e '(.system|test("\\[Identity\\]")) and (.messages[0].content=="Plain question") and (has("stream")|not)' "$T/last_body.json" >/dev/null && ok || bad "identity must be the system prompt and the user turn only the question: $(cat "$T/last_body.json" | head -c 400)"
# 4. streaming
curl -s -N -b "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"provider":"anthropic","model":"fake-priced","task":"text","prompt":"Stream","user_text":"Stream","stream":true}' "$U/workers.php?action=invoke" > "$T/sse.txt"
[ "$(grep -c '^data: {"chunk"' "$T/sse.txt")" = 3 ] && grep -q '^data: \[DONE\]' "$T/sse.txt" && ok || bad "SSE chunks/DONE: $(head -c 500 "$T/sse.txt")"
fin=$(grep '^data: {"final"' "$T/sse.txt" | sed 's/^data: //'); [ "$(echo "$fin" | jq -r .final.output)" = "One two three" ] && [ "$(echo "$fin" | jq -r .final.tokens_out)" = 2000 ] && [ "$(echo "$fin" | jq -r .final.cost_usd)" = 0.033 ] && ok || bad "final event: $fin"
jq -e '.stream==true' "$T/last_body.json" >/dev/null && ok || bad "stream:true was not sent upstream"
# 5. the ledger saw both calls; a gate refusal during a stream request is plain JSON (no half-stream)
spent=$(jq -r '.global_usd' "$CD/workers_spend.json" 2>/dev/null); awk -v s="$spent" 'BEGIN{exit !(s>0.0659 && s<0.0661)}' && ok || bad "spend ledger should hold 0.066, has: $spent"
printf '{"allow_paid_api_spend":true,"caps":{"global_monthly_usd":0.01,"per_model_monthly_usd":{}}}' > "$CD/settings.json"
r=$(curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"provider":"anthropic","model":"fake-priced","task":"text","prompt":"Stream","stream":true}' "$U/workers.php?action=invoke"); [ "$(echo "$r" | jq -r .gate)" = global_cap ] && ok || bad "a cap refusal must be plain JSON: $r"
# pictures from the Workers screen: only real image blocks reach the Anthropic API; junk and oversize are dropped on the server
printf '{"allow_paid_api_spend":true,"caps":{"global_monthly_usd":500,"per_model_monthly_usd":{}}}' > "$CD/settings.json"; wk enable_provider '{"provider":"anthropic","enabled":true}' >/dev/null
r=$(wk invoke '{"provider":"anthropic","model":"fake-priced","task":"text","prompt":"Look","user_text":"Look","extra":{"images":[{"media_type":"image/png","data":"iVBORw0KGgo="},{"media_type":"text/html","data":"PGI+"},{"media_type":"image/png","data":""},"junk"]}}')
jq -e '(.messages[0].content|type)=="array" and (.messages[0].content|length)==2 and .messages[0].content[0].type=="image" and .messages[0].content[0].source.media_type=="image/png" and .messages[0].content[1].type=="text"' "$T/last_body.json" >/dev/null && ok || bad "images reaching Anthropic: $(head -c 300 "$T/last_body.json")"
php -r 'echo json_encode(["provider"=>"anthropic","model"=>"fake-priced","task"=>"text","prompt"=>"Big","user_text"=>"Big","extra"=>["images"=>[["media_type"=>"image/png","data"=>str_repeat("A",7000001)]]]]);' > "$T/big.json"; r=$(curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d @"$T/big.json" "$U/workers.php?action=invoke")
jq -e '(.messages[0].content|type)=="string"' "$T/last_body.json" >/dev/null && ok || bad "an image over the size cap must be dropped, not forwarded: $(head -c 200 "$T/last_body.json")"
jq -n --arg d "iVBORw0KGgo=" '{provider:"openai",model:"oa-priced",task:"text",prompt:"Look",user_text:"Look",extra:{images:[{media_type:"image/png",data:$d}]}}' | curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d @- "$U/workers.php?action=invoke" >/dev/null
! grep -q "iVBORw0KGgo" "$T/last_body.json" && ok || bad "another provider must never receive the picture data"
# 5b. an OpenAI-compatible worker streams through the same action
printf '{"allow_paid_api_spend":true,"caps":{"global_monthly_usd":50,"per_model_monthly_usd":{}}}' > "$CD/settings.json"
wk set_key '{"provider":"openai","key":"sk-oa"}' >/dev/null; wk enable_provider '{"provider":"openai","enabled":true}' >/dev/null
curl -s -N -b "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"provider":"openai","model":"oa-priced","task":"text","prompt":"Hi","user_text":"Hi","stream":true}' "$U/workers.php?action=invoke" > "$T/sse2.txt"
[ "$(grep -c '^data: {"chunk"' "$T/sse2.txt")" = 3 ] && grep -q '^data: \[DONE\]' "$T/sse2.txt" && ok || bad "openai SSE: $(head -c 400 "$T/sse2.txt")"
fin=$(grep '^data: {"final"' "$T/sse2.txt" | sed 's/^data: //'); [ "$(echo "$fin" | jq -r .final.output)" = "OpenAI style" ] && [ "$(echo "$fin" | jq -r .final.cost_usd)" = 0.005 ] && ok || bad "openai final (1000*1/1e6 + 2000*2/1e6 = 0.005): $fin"
printf '{"allow_paid_api_spend":true,"caps":{"global_monthly_usd":0.01,"per_model_monthly_usd":{}}}' > "$CD/settings.json"
# 6. the probes
r=$(wk test_key '{"provider":"anthropic"}'); [ "$(echo "$r" | jq -r .status)" = active ] && ok || bad "test_key with x-api-key: $r"
r=$(wk test_all_keys '{}'); [ "$(echo "$r" | jq -r .statuses.anthropic)" = active ] && ok || bad "test_all_keys: $r"
r=$(wk discover '{}'); [ "$(echo "$r" | jq -r '[.providers[]|select(.id=="anthropic")][0].model_count')" = 0 ] || [ "$(echo "$r" | jq -r '[.providers[]|select(.id=="anthropic")][0].reachable')" = true ] && ok || bad "discover: $r"
echo "anthropic_invoke_http_test: $n passed, $fails failed"; [ "$fails" = 0 ]
