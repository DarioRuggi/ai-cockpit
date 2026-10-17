#!/usr/bin/env bash
# webworker_http_test.sh — a "webworker" provider through the REAL workers.php (aicserver + php-cgi) and the REAL cockpit_shell --worker window, against a local fake chat site:
# invoke (JSON and stream), a login page (needs_login + no health mark), cascade (the web worker is asked, a login pauses it), the self-test action.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"; PHPCGI="$(command -v php-cgi)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && [ -x "$AS" ] && [ -n "$PHPCGI" ] && command -v php curl jq xdpyinfo >/dev/null && xdpyinfo >/dev/null 2>&1 || { echo "webworker_http_test: needs fpc, aicserver, php-cgi, curl, jq and an X display - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/wh_XXXX) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; for d in $(find "$T" -type d -path "*webworkers/*" -maxdepth 6 2>/dev/null); do [ -f "$d/alive" ] && echo "{\"cmd\":\"quit\"}" > "$d/cmd.9.json"; done; sleep 1; pkill -KILL -P $CGI 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/cockpit_shell_t" >/dev/null 2>&1 && "$T/cockpit_shell_t" --check >/dev/null 2>&1 || { echo "webworker_http_test: shell build or GTK/WebKit missing - SKIPPED"; exit 0; }
export COCKPIT_SHELL_BIN="$T/cockpit_shell_t"
W="$T/web"; D="$T/data"; mkdir -p "$W" "$D" "$T/sess" "$T/proj" "$T/site"; cp -r "$ROOT/cockpit_app/." "$W/"; cp "$ROOT/tests/fixtures/fakechat.html" "$T/site/"
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/t.sock","queue_dir":"%s/q","response_dir":"%s/r"}' "$T" "$D" "$D" "$T" "$T" "$T" "$T" > "$W/paths.json"
SP=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$SP -t "$T/site" >"$T/site.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$SP/fakechat.html" && break; sleep 0.2; done
AD='{"input":["#in","#ce"],"send":["#send"],"answer":[".msg.bot"],"busy":["#stop"],"login":["#email"],"blocked":["verify you are human"],"stable":800,"timeout":40000}'
mk() { jq -n --arg id "$1" --arg url "$2" --argjson ad "$AD" '{id:$id,name:$id,type:"webworker",url:$url,free:true,incurs_cost:false,no_key_required:true,kinds:["text"],models:[{id:"web",label:$id,kinds:["text"],free:true}],adapter:$ad}'; }
jq --argjson a "$(mk ww_fake "http://127.0.0.1:$SP/fakechat.html?mode=textarea")" --argjson b "$(mk ww_login "http://127.0.0.1:$SP/fakechat.html?mode=login")" '.providers += [$a,$b]' "$ROOT/cockpit_app/workers_providers.json" > "$W/workers_providers.json"
PHP_FCGI_CHILDREN=4 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$T/sess" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
PORT=$((20000 + RANDOM % 20000))
jq -n --argjson port "$PORT" --arg root "$W" --arg php "unix:$T/php.sock" '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:300},deny:[".*"],limits:{max_body_mb:8}}' > "$T/srv.json"
"$AS" run --config "$T/srv.json" >"$T/srv.log" 2>&1 & PIDS="$PIDS $!"
U="http://127.0.0.1:$PORT/cockpit"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done; for i in $(seq 40); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done
r0=$(curl -s -X POST -H "Content-Type: application/json" -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=setup"); echo "$r0" | jq -e .ok >/dev/null || { echo "setup failed: [$r0]"; exit 1; }
curl -s -c "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=login" | jq -e .ok >/dev/null || { echo "login failed"; exit 1; }
wk() { curl -s -m 150 -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$2" "$U/workers.php?action=$1"; }
# the providers action lists them as web workers
r=$(curl -s -b "$T/jar" "$U/workers.php?action=providers"); [ "$(echo "$r" | jq -r '[.providers[]|select(.id=="ww_fake")][0].type')" = webworker ] && [ "$(echo "$r" | jq -r '[.providers[]|select(.id=="ww_duckai")]|length')" = 1 ] && ok || bad "providers must list the web workers: $(echo "$r" | head -c 200)"
r=$(wk enable_provider '{"provider":"ww_fake","enabled":true}'); [ "$(echo "$r" | jq -r .ok)" = true ] && ok || bad "enable a web worker (no key, no consent): $r"
wk enable_provider '{"provider":"ww_login","enabled":true}' >/dev/null
# invoke, JSON
r=$(wk invoke '{"provider":"ww_fake","model":"web","task":"text","prompt":"Plain question","user_text":"Plain question"}')
echo "$r" | jq -r .output | tr "\n" " " | grep -q "You asked:.*Plain question" && [ "$(echo "$r" | jq -r .tokens_estimated)" = true ] && ok || bad "invoke via the page: $r"
# invoke, stream
curl -s -m 150 -N -b "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"provider":"ww_fake","model":"web","task":"text","prompt":"Stream me","user_text":"Stream me","stream":true}' "$U/workers.php?action=invoke" > "$T/sse.txt"
[ "$(grep -c '^data: {"chunk"' "$T/sse.txt")" -ge 2 ] && grep -q '^data: \[DONE\]' "$T/sse.txt" && ok || bad "web worker SSE: $(head -c 400 "$T/sse.txt")"
fin=$(grep '^data: {"final"' "$T/sse.txt" | sed 's/^data: //'); echo "$fin" | jq -r .final.output | grep -q "Grüße 日本語" && ok || bad "final text with non-ASCII: $fin"
# a login page: reported, and NOT recorded as a broken model
r=$(wk invoke '{"provider":"ww_login","model":"web","task":"text","prompt":"hi","user_text":"hi"}')
[ "$(echo "$r" | jq -r .needs_login)" = true ] && echo "$r" | jq -r .error | grep -qi "log in" && ok || bad "login page: $r"
HF=$(find "$D" -name workers_health.json | head -1); { [ -z "$HF" ] || [ "$(jq -r '.["ww_login:web"].status // "none"' "$HF")" = none ]; } && ok || bad "a login must not mark the model as broken: $(cat "$HF")"
wk ww_hide '{"provider":"ww_login"}' >/dev/null
# the self-test action
r=$(wk ww_test '{"provider":"ww_fake"}'); [ "$(echo "$r" | jq -r .status)" = ok ] && ok || bad "self-test: $r"
r=$(wk ww_test '{"provider":"groq"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -q "Not a web page worker" && ok || bad "ww_test on an API provider must be refused: $r"
# cascade: the login worker is asked first when the saved order says so, fails, is paused; the web worker behind it answers
wk set_cascade_order '{"order":["ww_login:web","ww_fake:web"]}' >/dev/null
r=$(wk cascade_invoke '{"task":"text","prompt":"Cascade question","user_text":"Cascade question"}')
[ "$(echo "$r" | jq -r .served_by)" = "ww_fake:web" ] && echo "$r" | jq -e '[.attempts[]|select(.worker=="ww_login:web" and .failed=="needs_login")]|length==1' >/dev/null && ok || bad "cascade through a worker that needs a login: $(echo "$r" | head -c 400)"
wk ww_hide '{"provider":"ww_login"}' >/dev/null
r=$(wk cascade_invoke '{"task":"text","prompt":"Again","user_text":"Again"}'); echo "$r" | jq -e '[.attempts[]|select(.worker=="ww_login:web" and .skipped=="exhausted")]|length==1' >/dev/null && ok || bad "the paused worker must not be asked again for a while: $(echo "$r" | jq -c .attempts)"
echo "webworker_http_test: $n passed, $fails failed"; [ "$fails" = 0 ]
