#!/usr/bin/env bash
# topbar_gaps_test.sh — the spacing of the top bar's cards, measured in the REAL window (cockpit_shell: WebKit, frameless, like the rig; 1920 = the rig, 2100 = a wider window, where the Clock card takes the spare width) against the real page.
# Rule (2026-10-14, "the left gaps are not the same as the right gaps"): every card is exactly 4px from the next, from the first agent card to Settings; the two ends of the bar have the same margin;
# inside the Account, Control, Clock and Settings groups the buttons are inset the same on the left and the right; and the bar does not overflow the window.
# A throwaway Cockpit (aicserver + php-cgi, own data folder, a test account) is served, the shell opens it, and a small script (tests/fixtures/topbar_measure.js) reports the rectangles.
#   bash tests/topbar_gaps_test.sh      SKIPPED without fpc, php-cgi, aicserver, php, jq, curl or a display
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"; PHPCGI="$(command -v php-cgi)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && command -v php jq curl xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1 && [ -x "$AS" ] && [ -n "$PHPCGI" ] || { echo "topbar_gaps_test: needs fpc, php, php-cgi, aicserver, jq, curl and an X display - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/tg_XXXX) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill -9 $p 2>/dev/null; done; [ "$CGI" != 0 ] && pkill -KILL -P $CGI 2>/dev/null; sleep 0.3; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/sh" >/dev/null 2>&1 && "$T/sh" --check >/dev/null 2>&1 || { echo "topbar_gaps_test: shell build or GTK/WebKit missing - SKIPPED"; exit 0; }
W="$T/web"; D="$T/data"; mkdir -p "$W" "$D" "$T/sess" "$T/proj" "$T/cfg/ai-cockpit"; cp -r "$ROOT/cockpit_app/." "$W/"
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/t.sock","queue_dir":"%s/q","response_dir":"%s/r"}' "$T" "$D" "$D" "$T" "$T" "$T" "$T" > "$W/paths.json"
printf '<?php file_put_contents("%s/rep.json", file_get_contents("php://input")); echo "ok";' "$T" > "$W/rep.php"
php -r '$p="'"$W"'/index.html"; $s=file_get_contents($p); $h=file_get_contents("'"$ROOT"'/tests/fixtures/topbar_measure.js"); $i=strrpos($s,"</body>"); file_put_contents($p, substr($s,0,$i)."<script>".$h."</script>\n".substr($s,$i));'
printf '<?php http_response_code(404);' > "$T/fake.php"; FP=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$FP "$T/fake.php" >"$T/fake.log" 2>&1 & PIDS="$PIDS $!"
export COCKPIT_OLLAMA_URL="http://127.0.0.1:$FP"
PHP_FCGI_CHILDREN=3 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$T/sess" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
PORT=$((20000 + RANDOM % 20000))
jq -n --argjson port "$PORT" --arg root "$W" --arg php "unix:$T/php.sock" '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:60},deny:[".*"],limits:{max_body_mb:8}}' > "$T/srv.json"
"$AS" run --config "$T/srv.json" >"$T/srv.log" 2>&1 & PIDS="$PIDS $!"
U="http://127.0.0.1:$PORT/cockpit"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done; for i in $(seq 40); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done
curl -s -X POST -H "Content-Type: application/json" -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=setup" | jq -e .ok >/dev/null || { echo "setup failed"; exit 1; }
export XDG_CONFIG_HOME="$T/cfg"; echo on > "$T/cfg/ai-cockpit/frameless"
rm -f /tmp/topbar_gaps_last.*; : > /tmp/topbar_gaps_last.log
for WIDTH in 1920 2100; do
  rm -f "$T/rep.json"; (setsid "$T/sh" --url "$U/" --width $WIDTH --height 1040 --frameless --title "TG $WIDTH" >"$T/shell.$WIDTH.log" 2>&1 & echo $! > "$T/shell.pid")
  SP=$(cat "$T/shell.pid"); for i in $(seq 160); do [ -s "$T/rep.json" ] && break; sleep 0.5; done
  if [ -n "${TOPBAR_SHOT:-}" ] && [ $WIDTH = 1920 ] && command -v wmctrl >/dev/null 2>&1 && command -v import >/dev/null 2>&1; then sleep 1; WID=$(wmctrl -l | grep "TG 1920" | head -1 | cut -d" " -f1); [ -n "$WID" ] && import -window $WID -crop 1920x112+0+0 +repage "$TOPBAR_SHOT" 2>/dev/null; fi   # a picture of the bar, when asked (for a person to look at)
  pkill -f -- "--title TG $WIDTH" 2>/dev/null
  if [ -s "$T/rep.json" ]; then
    out=$(php -r '
      $j = json_decode(file_get_contents("'"$T"'/rep.json"), true); $w = '"$WIDTH"'; $f = 0; $n = 0; $tol = 0.9;
      $chk = function ($ok, $m) use (&$f, &$n, $w) { $n++; if (!$ok) { $f++; echo "  FAIL [width $w] $m\n"; } };
      $c = $j["cards"]; $chk(count($c) === 9, "all nine cards are measured (" . count($c) . ")");
      $gaps = []; for ($i = 1; $i < count($c); $i++) $gaps[] = round($c[$i]["r"][0] - $c[$i - 1]["r"][1], 2);
      $chk(count($gaps) > 0 && max(array_map(fn($g) => abs($g - 4), $gaps)) <= $tol, "every card is 4px from the next: " . implode(", ", $gaps));
      $lm = $j["brand"][0]; $rm = $j["vw"] - end($c)["r"][1]; $chk(abs($lm - $rm) <= $tol, "the two ends of the bar have the same margin: left " . round($lm, 1) . ", right " . round($rm, 1));
      foreach ($j["inner"] as $k => $g) $chk(abs($g["gapL"] - $g["gapR"]) <= 1.01, "$k: buttons inset the same left and right: " . round($g["gapL"], 2) . " / " . round($g["gapR"], 2));
      $chk($j["sw"] <= $j["vw"] + 1, "the bar does not overflow the window (scroll width " . round($j["sw"]) . " in " . $j["vw"] . ")");
      $chk(abs($c[0]["r"][2] - $c[8]["r"][2]) < 0.9 && abs($c[0]["r"][3] - $c[8]["r"][3]) < 0.9, "the first and the last card are the same height and level");
      echo "RESULT $n $f\n";')
    { echo "== width $WIDTH $(date +%T)"; echo "$out"; } >> /tmp/topbar_gaps_last.log; cp "$T/rep.json" "/tmp/topbar_gaps_last.$WIDTH.json" 2>/dev/null   # kept for whoever looks at a failure inside a build (guards hide their output)
    echo "$out" | grep -v "^RESULT"; read -r _ an af <<<"$(echo "$out" | grep "^RESULT")"; n=$((n + ${an:-0})); fails=$((fails + ${af:-1}))
  else bad "[width $WIDTH] the window never reported its measurements: $(tail -3 "$T/shell.$WIDTH.log")"; fi
done
echo "topbar_gaps_test: $n passed, $fails failed"; [ $fails = 0 ]
