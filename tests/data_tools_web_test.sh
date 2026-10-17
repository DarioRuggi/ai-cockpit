#!/usr/bin/env bash
# data_tools_web_test.sh — the Data, Web site AND VB6 presets through the real tools.php, behind aicserver + php-cgi in a throw-away data folder: the extra
# arguments are split on spaces and every part quoted by tools.php, so SQL with quotes, parentheses and * must still arrive whole.
#   bash tests/data_tools_web_test.sh      needs php, php-cgi, curl, jq, sqlite3; SKIPPED without them or without aicserver.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"; PHPCGI="$(command -v php-cgi)"
[ -x "$AS" ] && [ -n "$PHPCGI" ] && command -v php curl jq sqlite3 >/dev/null || { echo "data_tools_web_test: needs aicserver, php-cgi, php, curl, jq, sqlite3 - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/dtw_XXXX) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; pkill -KILL -P $CGI 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
W="$T/web"; D="$T/data"; mkdir -p "$W" "$D" "$T/sess" "$T/proj/p1"; cp -r "$ROOT/cockpit_app/." "$W/"
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/t.sock","queue_dir":"%s/q","response_dir":"%s/r"}' "$T" "$D" "$D" "$T" "$T" "$T" "$T" > "$W/paths.json"; echo v2 > "$W/.edition"
cat > "$T/proj/p1/sales.csv" <<'X'
city,month,"sales total",units
Tel Aviv,2026-01,1200.5,10
Haifa,2026-01,800,7
Tel Aviv,2026-02,1500,12
Haifa,2026-02,,5
Eilat,2026-02,300.25,2
X
PHP_FCGI_CHILDREN=3 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$T/sess" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
PORT=$((20000 + RANDOM % 20000))
jq -n --argjson port "$PORT" --arg root "$W" --arg php "unix:$T/php.sock" '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:60},deny:[".*"],limits:{max_body_mb:8}}' > "$T/srv.json"
"$AS" run --config "$T/srv.json" >"$T/srv.log" 2>&1 & PIDS="$PIDS $!"
U="http://127.0.0.1:$PORT/cockpit"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done
for i in $(seq 40); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done
curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=setup" | jq -e .ok >/dev/null || { echo "setup failed"; exit 1; }
curl -s -c "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=login" | jq -e .ok >/dev/null || { echo "login failed"; exit 1; }
run() {   # run PRESET FILE EXTRA  (the file is in the project folder; given as an absolute path) -> $T/res.json
    curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$1" --arg i "$T/proj/p1/$2" --arg e "$3" '{tool:"data",preset:$p,input:$i,extra_args:$e,project:"p1"}')" "$U/tools.php?action=run" > "$T/res.json"
}
out() { jq -r .output "$T/res.json"; }
tools=$(curl -s -b "$T/jar" "$U/tools.php?action=tools"); [ "$(echo "$tools" | jq -r '.tools[]|select(.id=="data")|.binary_available')" = true ] && ok || bad "the data tool is not listed or not available: $(echo "$tools" | jq -c '[.tools[].id]')"
run csv-query sales.csv "SELECT city, COUNT(*) AS n, SUM(CAST(\"sales total\" AS REAL)) AS total FROM t WHERE city <> 'Eilat' GROUP BY city ORDER BY n DESC, city"
[ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "Tel Aviv" "$(out)" && grep -qE "Tel Aviv +\| 2 +\| 2700.5" "$(out)" && ok || bad "csv-query through tools.php: $(cat "$T/res.json" | head -c 400)"
run csv-describe sales.csv ""; [ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "distinct_values" "$(out)" && ok || bad "csv-describe: $(head -c 300 "$T/res.json")"
run col-count sales.csv "city 2"; [ "$(jq -r .ok "$T/res.json")" = true ] && [ "$(grep -c '^| ' "$(out)")" = 3 ] && ok || bad "col-count with two arguments: $(head -c 300 "$T/res.json")"
run csv-query sales.csv "ATTACH DATABASE '$T/evil.db' AS e"; [ "$(jq -r .ok "$T/res.json")" = false ] || [ ! -e "$T/evil.db" ] && [ ! -e "$T/evil.db" ] && ok || bad "an ATTACH got through tools.php"
run chart-bar sales.csv "city sales_total Sales by city"; [ "$(jq -r .ok "$T/res.json")" = true ] && xmllint --noout "$(out)" 2>/dev/null && grep -q "Sales by city" "$(out)" && ok || bad "chart-bar through tools.php: $(head -c 300 "$T/res.json")"
case "$(out)" in *.svg) ok;; *) bad "the chart is not an .svg: $(out)";; esac
r=$(curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$(out)" '{path:$p}')" "$U/tools.php?action=read_output"); [ "$(echo "$r" | jq -r .ok)" = true ] && echo "$r" | jq -r .content | grep -q "<svg" && ok || bad "an agent cannot read the svg back: $r"
run csv-to-sqlite sales.csv ""; [ "$(jq -r .ok "$T/res.json")" = true ] && [ -f "$T/proj/p1/sales.db" ] && ok || bad "csv-to-sqlite beside the file: $(head -c 300 "$T/res.json")"
# --- the Web site tools through tools.php: check, a preview that survives the request, stop, pack
mkdir -p "$T/proj/p1/site/.git" "$T/proj/p1/site/about"; printf '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Home</title></head><body><a href="about/">About</a> <a href="gone.html">Gone</a></body></html>' > "$T/proj/p1/site/index.html"; printf '<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>About</title></head><body>About</body></html>' > "$T/proj/p1/site/about/index.html"; printf secret > "$T/proj/p1/site/.git/config"
wrun() { curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$1" --arg i "$T/proj/p1/site" --arg e "$2" '{tool:"website",preset:$p,input:$i,extra_args:$e,project:"p1"}')" "$U/tools.php?action=run" > "$T/res.json"; }
[ "$(echo "$tools" | jq -r '.tools[]|select(.id=="website")|.binary_available')" = true ] && ok || bad "the website tool is not listed"
wrun check ""; [ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "gone.html: no such file" "$(out)" && grep -q "1 errors, 0 warnings, 0 hints" "$(out)" && ok || bad "check through tools.php: $(head -c 300 "$T/res.json")"
wrun serve "2"; if [ "$(jq -r .ok "$T/res.json")" = true ]; then WU=$(head -1 "$(out)"); case "$WU" in http://127.0.0.1:*) ok;; *) bad "the preview address is wrong: $WU";; esac; sleep 1; [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$WU")" = 200 ] && ok || bad "the preview did not survive the end of the request"; [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "${WU}.git/config")" = 404 ] && ok || bad "the preview served .git"; else bad "serve through tools.php: $(head -c 300 "$T/res.json")"; fi
wrun stop ""; [ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "Stopped 1" "$(out)" && ok || bad "stop through tools.php: $(head -c 300 "$T/res.json")"
sleep 0.5; [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${WU:-http://127.0.0.1:1/}")" = 000 ] && ok || bad "the preview still answers after Stop"
if php -m 2>/dev/null | grep -qi '^zip$'; then wrun pack ""; [ "$(jq -r .ok "$T/res.json")" = true ] && unzip -l "$(out)" | grep -q "about/index.html" && ! unzip -l "$(out)" | grep -q "\.git" && ok || bad "pack through tools.php: $(head -c 300 "$T/res.json")"; fi
# --- the VB6 tools through tools.php
php "$ROOT/tests/vb6_fixture.php" "$T/proj/p1/vbproj"
vrun() { curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$(jq -nc --arg p "$1" --arg i "$T/proj/p1/vbproj" '{tool:"vb6",preset:$p,input:$i,extra_args:"",project:"p1"}')" "$U/tools.php?action=run" > "$T/res.json"; }
vrun inventory; [ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "kernel32" "$(out)" && grep -q "Port in this order" "$(out)" && ok || bad "vb6 inventory through tools.php: $(head -c 300 "$T/res.json")"
vrun to-utf8; [ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "שלום" "$T/proj/p1/vbproj_utf8/frmPrincipal.frm" && ok || bad "vb6 to-utf8 through tools.php: $(head -c 300 "$T/res.json")"
vrun verify; [ "$(jq -r .ok "$T/res.json")" = true ] && grep -q "4 files identical" "$(out)" && ok || bad "vb6 verify through tools.php: $(head -c 300 "$T/res.json")"
echo "data_tools_web_test: $n passed, $fails failed"; [ "$fails" = 0 ]
