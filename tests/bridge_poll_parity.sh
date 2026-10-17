#!/usr/bin/env bash
# =============================================================================
# bridge_poll_parity.sh — aicserver answering bridge.php's mode=poll ITSELF (srv_native) against PHP answering the same request.
#
# One sandbox copy of cockpit_app, one php-cgi, a test user made through the real setup/login flow, a mock supervisor on a Unix socket.
# Two aicserver instances in front of the same php-cgi: A with "native.bridge_poll" on, B off (everything goes to PHP). For each case the
# same response files are laid out for both, the same request is sent to both, and the bodies must be identical and the files left
# behind the same. A native answer carries "X-Aic-Native: bridge-poll"; a case that must be left to PHP must not.
#   bash tests/bridge_poll_parity.sh     AICSERVER=<bin>     SKIPPED without aicserver or php-cgi.
# =============================================================================
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"
PHPCGI="$(command -v php-cgi)"
[ -x "$AS" ] && [ -n "$PHPCGI" ] && command -v php curl jq >/dev/null || { echo "bridge_poll_parity: needs aicserver, php-cgi, php, curl, jq - SKIPPED"; exit 0; }
"$AS" version 2>/dev/null | grep -q aicserver || { echo "bridge_poll_parity: aicserver without version - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; pkill -KILL -P $CGI 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
W="$T/web"; D="$T/data"; S="$T/sess"; RD="$T/resp"; mkdir -p "$W" "$D/supervisor" "$S" "$RD" "$T/queue"
cp -r "$ROOT/cockpit_app/." "$W/"
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/tmux.sock","queue_dir":"%s/queue","response_dir":"%s"}' "$T" "$D" "$D" "$T" "$T" "$T" "$RD" > "$W/paths.json"
echo "v1" > "$W/.edition"
# the mock supervisor: answers {"op":"status"} with cockpit_claude running and cockpit_gemini stopped
echo secrettoken > "$D/supervisor/token"; touch "$D/use_supervisor"
cat > "$T/sup.php" <<'PHP'
<?php
$sock = $argv[1]; @unlink($sock);
$srv = stream_socket_server("unix://$sock", $en, $es);
while ($c = stream_socket_accept($srv, -1)) {
    $line = fgets($c); $j = json_decode((string)$line, true);
    $ok = is_array($j) && ($j['token'] ?? '') === 'secrettoken';
    fwrite($c, json_encode($ok ? ['ok' => true, 'services' => [['name' => 'cockpit_claude', 'state' => 'running', 'pid' => 4242], ['name' => 'cockpit_gemini', 'state' => 'stopped', 'pid' => 0]]] : ['ok' => false]) . "\n");
    fclose($c);
}
PHP
php "$T/sup.php" "$D/supervisor/sup.sock" >/dev/null 2>&1 & PIDS="$PIDS $!"
PHP_FCGI_CHILDREN=4 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$S" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done
PA=$((20000 + RANDOM % 10000)); PB=$((PA + 1))
mkcfg() {  # mkcfg PORT NATIVE(true|false) FILE
    jq -n --argjson port "$1" --arg root "$W" --arg php "unix:$T/php.sock" --argjson nat "$2" --arg sess "$S" --arg sup "$D/supervisor" \
      '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:60},deny:[".*"],limits:{max_body_mb:64},native:{bridge_poll:$nat,session_dir:$sess,supervisor_dir:$sup,session_days:90}}' > "$3"; }
mkcfg $PA true "$T/a.json"; mkcfg $PB false "$T/b.json"
"$AS" run --config "$T/a.json" >"$T/a.log" 2>&1 & PIDS="$PIDS $!"
"$AS" run --config "$T/b.json" >"$T/b.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PA/cockpit/" && curl -s -o /dev/null "http://127.0.0.1:$PB/cockpit/" && break; sleep 0.2; done
# the test user, through the real setup and login flow (test values, sandbox only)
curl -s -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "http://127.0.0.1:$PB/cockpit/auth.php?action=setup" | jq -e .ok >/dev/null || { echo "setup failed"; exit 1; }
curl -s -c "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "http://127.0.0.1:$PB/cockpit/auth.php?action=login" | jq -e .ok >/dev/null || { echo "login failed"; exit 1; }
SID=$(awk '$6=="cockpit_sid"{print $7}' "$T/jar"); [ -n "$SID" ] || { echo "no session cookie"; exit 1; }

# lay out the files of a case (tok, out-content-file|-, done 0/1) in the response folder
lay() { rm -f "$RD/$1.out" "$RD/$1.done"; [ -n "$2" ] && cp "$2" "$RD/$1.out"; [ "$3" = 1 ] && : > "$RD/$1.done"; return 0; }
snap() { (cd "$RD" && ls -1 | sort | while read f; do echo "$f $(md5sum < "$f")"; done); }
post() {  # post PORT BODY [COOKIE-SID]  -> body in $T/body, headers in $T/hdr
    local c=(); [ -n "$3" ] && c=(-H "Cookie: cockpit_sid=$3")
    curl -s -D "$T/hdr" -o "$T/body" -X POST -H 'Content-Type: application/json' "${c[@]}" -d "$2" "http://127.0.0.1:$1/cockpit/bridge.php"
}
# case NAME  EXPECT(native|php)  BODY  SID  TOKEN  OUTFILE  DONE
case_() {
    local name="$1" want="$2" body="$3" sid="$4" tok="$5" outf="$6" done="$7" ra rb sa sb na
    lay "$tok" "$outf" "$done"; post $PA "$body" "$sid"; ra=$(cat "$T/body"); sa=$(snap); grep -qi '^x-aic-native: bridge-poll' "$T/hdr" && na=native || na=php
    lay "$tok" "$outf" "$done"; post $PB "$body" "$sid"; rb=$(cat "$T/body"); sb=$(snap)
    if [ "$ra" != "$rb" ]; then bad "$name: native=[$ra] php=[$rb]"; return; fi
    if [ "$sa" != "$sb" ]; then bad "$name: files left behind differ"; return; fi
    if [ "$na" != "$want" ]; then bad "$name: expected $want to answer, $na did"; return; fi
    ok
}
J() { jq -nc "$@"; }
printf 'hello world' > "$T/f_plain"; printf 'abc\033[31mred\033[0m def\033[?25h x\r\nline2\033=\033>' > "$T/f_ansi"
printf '\xe2\xa0\x8b \xe2\xa0\x99  Hello\n' > "$T/f_brl"; printf 'שלום עולם ✓ 日本' > "$T/f_heb"; printf 'ctl\x01\x02\x07\x08\x0b\x0c\x0e\x1f\x7fend a/b "q" \\ tab\there' > "$T/f_ctl"
printf 'bad \xff\xfe utf8' > "$T/f_bad"; printf '@@ -1,2 +1,2 @@\n-old\n+new\n' > "$T/f_diff"; printf '[A[2K[1;5C text [?25l ?1049h' > "$T/f_brk"; head -c 70000 /dev/zero | tr '\0' 'x' > "$T/f_big"
printf 'half \xe2\x82' > "$T/f_cut"; printf 'x\xe2\x80\xa8y' > "$T/f_ls"

case_ "plain, from 0, not done"            native "$(J '{mode:"poll",token:"t1",offset:0}')" "$SID" t1 "$T/f_plain" 0
case_ "plain, from 6"                      native "$(J '{mode:"poll",token:"t2",offset:6}')" "$SID" t2 "$T/f_plain" 0
case_ "offset beyond the end"              native "$(J '{mode:"poll",token:"t3",offset:99}')" "$SID" t3 "$T/f_plain" 0
case_ "no file yet"                        native "$(J '{mode:"poll",token:"t4",offset:0}')" "$SID" t4 "" 0
case_ "done: last chunk, files removed"    native "$(J '{mode:"poll",token:"t5",offset:0}')" "$SID" t5 "$T/f_plain" 1
case_ "done without an out file"           native "$(J '{mode:"poll",token:"t6",offset:0}')" "$SID" t6 "" 1
case_ "terminal sequences are stripped"    native "$(J '{mode:"poll",token:"t7",offset:0}')" "$SID" t7 "$T/f_ansi" 0
case_ "braille spinner and spaces"         native "$(J '{mode:"poll",token:"t8",offset:0}')" "$SID" t8 "$T/f_brl" 0
case_ "Hebrew, check mark, Japanese"       native "$(J '{mode:"poll",token:"t9",offset:0}')" "$SID" t9 "$T/f_heb" 0
case_ "control characters, slash, quotes"  native "$(J '{mode:"poll",token:"t10",offset:0}')" "$SID" t10 "$T/f_ctl" 0
case_ "bracket sequences without ESC"      native "$(J '{mode:"poll",token:"t11",offset:0}')" "$SID" t11 "$T/f_brk" 0
case_ "U+2028 in the text"                 native "$(J '{mode:"poll",token:"t12",offset:0}')" "$SID" t12 "$T/f_ls" 0
case_ "a 70 KB answer"                     native "$(J '{mode:"poll",token:"t13",offset:10}')" "$SID" t13 "$T/f_big" 0
case_ "token with odd characters"          native "$(J '{mode:"poll",token:"t!1 @4/..",offset:0}')" "$SID" t14 "$T/f_plain" 0
case_ "token '0' = missing"                native "$(J '{mode:"poll",token:"0",offset:0}')" "$SID" 0 "" 0
case_ "missing token"                      native "$(J '{mode:"poll",offset:0}')" "$SID" x "" 0
case_ "offset as a numeric string"         native "$(J '{mode:"poll",token:"t15",offset:"3"}')" "$SID" t15 "$T/f_plain" 0
case_ "negative offset"                    native "$(J '{mode:"poll",token:"t16",offset:-5}')" "$SID" t16 "$T/f_plain" 0
case_ "agent running (supervisor says so)" native "$(J '{mode:"poll",token:"t17",offset:0,agent:"claude"}')" "$SID" t17 "$T/f_plain" 0
case_ "agent given but the answer is done" native "$(J '{mode:"poll",token:"t18",offset:0,agent:"gemini"}')" "$SID" t18 "$T/f_plain" 1
echo "-- left to PHP (no X-Aic-Native header, same answer)"
case_ "no session cookie"                  php    "$(J '{mode:"poll",token:"p1",offset:0}')" "" p1 "$T/f_plain" 0
case_ "a made-up session id"               php    "$(J '{mode:"poll",token:"p2",offset:0}')" "abcdefghijklmnopqrstuvwxyz123456" p2 "$T/f_plain" 0
case_ "agent stopped (PHP says session_dead)" php "$(J '{mode:"poll",token:"p3",offset:0,agent:"gemini"}')" "$SID" p3 "$T/f_plain" 0
case_ "agent unknown to the supervisor"    php    "$(J '{mode:"poll",token:"p4",offset:0,agent:"ollama"}')" "$SID" p4 "$T/f_plain" 0
case_ "invalid UTF-8 in the new bytes"     php    "$(J '{mode:"poll",token:"p5",offset:0}')" "$SID" p5 "$T/f_bad" 0
case_ "a half character at the end"        php    "$(J '{mode:"poll",token:"p6",offset:0}')" "$SID" p6 "$T/f_cut" 0
case_ "a diff in the final chunk"          php    "$(J '{mode:"poll",token:"p7",offset:0}')" "$SID" p7 "$T/f_diff" 1
case_ "mode cleanup"                       php    "$(J '{mode:"cleanup",token:"p8"}')" "$SID" p8 "$T/f_plain" 0
case_ "mode sync without a prompt"         php    "$(J '{mode:"sync"}')" "$SID" p9 "" 0
case_ "token that is not text"             php    "$(J '{mode:"poll",token:12,offset:0}')" "$SID" 12 "" 0
case_ "offset that is not a number"        php    "$(J '{mode:"poll",token:"p10",offset:"abc"}')" "$SID" p10 "$T/f_plain" 0
# a session that PHP did not write for a signed-in person
printf 'cockpit_login_at|i:1;' > "$S/sess_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
case_ "session without a user"             php    "$(J '{mode:"poll",token:"p11",offset:0}')" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" p11 "$T/f_plain" 0
# invalid bodies
for b in 'not json' '[]' '{"mode":' ''; do post $PA "$b" "$SID"; ra=$(cat "$T/body"); post $PB "$b" "$SID"; rb=$(cat "$T/body"); [ "$ra" = "$rb" ] && ok || bad "body [$b]: native=[$ra] php=[$rb]"; done
echo "bridge_poll_parity: $n passed, $fails failed"; [ "$fails" = 0 ]
