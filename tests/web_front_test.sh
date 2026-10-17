#!/usr/bin/env bash
# =============================================================================
# web_front_test.sh — the opt-in web front (aicserver + php-cgi, written by scripts/cockpit_sup_config.php) in front of a sandbox copy
# of cockpit_app: the pages and PHP work, and what Apache refuses today (Installs/apache/cockpit-security.conf: state files, logs,
# locks, queue/, responses/, dotfiles, source) is refused here as well; a 20 MB upload passes (.user.ini limits).
#   bash tests/web_front_test.sh      AICSERVER=<bin>   SKIPPED without aicserver or php-cgi.
# =============================================================================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"
PHPCGI="$(command -v php-cgi)"
[ -x "$AS" ] && [ -n "$PHPCGI" ] && command -v php curl >/dev/null || { echo "web_front_test: needs aicserver, php-cgi, php, curl - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; pkill -KILL -P ${CGI:-0} 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
W="$T/web"; D="$T/data"; mkdir -p "$W/queue" "$W/responses" "$D"
cp -r "$ROOT/cockpit_app/." "$W/" 2>/dev/null; cp "$ROOT/cockpit_app/.user.ini" "$W/" 2>/dev/null
mkdir -p "$W/queue" "$W/responses"
for f in paths.json project_state.json workers_quotas.json ollama_usage.jsonl x.lock x.sock .secret queue/q1.txt responses/r1.out queue/sub.txt; do echo SECRET > "$W/$f"; done
echo '<?php echo "UP:".strlen(file_get_contents("php://input"));' > "$W/upl.php"
echo bash > "$W/leak.sh"
PORT=$((20000 + RANDOM % 20000)); echo $PORT > "$D/use_aicserver"
php "$ROOT/scripts/cockpit_sup_config.php" --edition v2 --web-root "$W" --data-dir "$D" --projects-root "$T" --aicserver-bin "$AS" --php-cgi "$PHPCGI" --out "$D/supervisor/sup.json" || { echo "config generator failed"; exit 1; }
jq -e '[.services[].name] | index("cockpit_phpcgi") and index("cockpit_web")' "$D/supervisor/sup.json" >/dev/null && ok || bad "the supervisor file has no web services"
CMD=$(jq -r '.services[]|select(.name=="cockpit_phpcgi")|.args|join(" ")' "$D/supervisor/sup.json")
PHP_FCGI_CHILDREN=3 "$PHPCGI" $CMD >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
for i in $(seq 50); do [ -S "$D/supervisor/php.sock" ] && break; sleep 0.2; done
"$AS" run --config "$D/supervisor/web.json" >"$T/web.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/cockpit/" && break; sleep 0.2; done
U="http://127.0.0.1:$PORT/cockpit"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
[ "$(code "$U/")" = 200 ] && ok || bad "index"
[ "$(code "$U/js/core/status.js")" = 200 ] && ok || bad "a script file"
[ "$(code "$U/status.php")" = 401 ] && ok || bad "status.php should answer 401 without a login"
curl -s "$U/status.php" | jq -e '.ok==false' >/dev/null && ok || bad "status.php JSON"
curl -s "$U/auth.php?action=status" | jq -e . >/dev/null && ok || bad "auth.php?action=status is not JSON"
for f in paths.json project_state.json workers_quotas.json ollama_usage.jsonl x.lock x.sock .secret .user.ini leak.sh queue/q1.txt queue/ responses/r1.out responses/ queue/sub.txt; do
    c=$(code "$U/$f"); case "$c" in 403|404) ok;; *) bad "$f is served ($c)";; esac
done
curl -s "$U/paths.json" | grep -q SECRET && bad "paths.json content leaked" || ok
[ "$(code "$U/worker_relay.php")" = 403 ] && ok || bad "worker_relay.php (a command-line helper) is reachable over the web"
c=$(code "$U/../etc/passwd"); case "$c" in 400|403|404) ok;; *) bad "traversal ($c)";; esac
dd if=/dev/zero of="$T/big" bs=1M count=20 2>/dev/null
[ "$(curl -s -X POST --data-binary @"$T/big" "$U/upl.php")" = "UP:20971520" ] && ok || bad "a 20 MB upload did not reach PHP whole"
echo "web_front_test: $n passed, $fails failed"; [ "$fails" = 0 ]
