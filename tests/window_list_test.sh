#!/usr/bin/env bash
# window_list_test.sh — minimised Cockpit Browser windows in the status bar (shell/cockpit_shell.pas: the window list; cockpit_app/js/core/shell-channel.js: the chips).
# Real windows on the real X display: a Browser window is minimised with the window manager, a MAIN-style shell window loads the real shell-channel.js, lists it as a chip, a click
# restores it, the right-click menu closes it. SKIPPED without fpc, xdotool, php or a display.     bash tests/window_list_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v php >/dev/null 2>&1 && command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1 || { echo "window_list_test: needs fpc, xdotool, php and an X display - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/wl_XXXX) || exit 1; PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/sh" >/dev/null 2>&1 && "$T/sh" --check >/dev/null 2>&1 || { echo "window_list_test: shell build or GTK/WebKit missing - SKIPPED"; exit 0; }
mkdir -p "$T/site" "$T/cfg/ai-cockpit" "$T/run"; cp "$ROOT/cockpit_app/js/core/shell-channel.js" "$T/site/shell-channel.js"
cat > "$T/site/index.html" <<'HTML'
<!doctype html><title>main stand-in</title><body style="margin:0;background:#222;color:#eee">
<div id="status-bar" style="position:fixed;left:0;right:0;bottom:0;height:22px;display:flex;gap:8px"><span id="status-bar-msg" style="flex:1">Ready.</span><span id="status-bar-wins" style="display:none"></span></div>
<script>
function T(k, e, v) { return e.replace(/\{(\w+)\}/g, (m, n) => (v || {})[n]); }
function appendSystem() {} function escHtml(s) { return s; }
</script>
<script src="shell-channel.js"></script>
<script>
function out(k, v) { new Image().src = '/rep?k=' + k + '&d=' + encodeURIComponent(JSON.stringify(v)) + '&n=' + Math.random(); }
setInterval(() => {
  const c = [...document.querySelectorAll('.min-win-chip')].map(b => { const r = b.getBoundingClientRect(); return { text: b.textContent, tip: b.title, x: r.x + r.width / 2, y: r.y + r.height / 2 }; });
  out('chips', c); const m = document.getElementById('min-wins-menu'); out('menu', m ? [...m.children].map(e => { const r = e.getBoundingClientRect(); return { text: e.textContent, x: r.x + r.width / 2, y: r.y + r.height / 2 }; }) : []);
}, 500);
</script>
HTML
cat > "$T/router.php" <<'PHP'
<?php
if (strpos($_SERVER['REQUEST_URI'] ?? '', '/rep?') === 0) { file_put_contents(__DIR__ . '/rep.' . preg_replace('/\W/', '', $_GET['k'] ?? 'x'), $_GET['d'] ?? ''); http_response_code(204); return true; }
return false;
PHP
echo '<!doctype html><title>second window page</title><body>b</body>' > "$T/site/b.html"
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT -t "$T/site" "$T/router.php" >"$T/php.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
export XDG_CONFIG_HOME="$T/cfg" XDG_RUNTIME_DIR="$T/run"
wmstate() { xprop -id "$1" WM_STATE 2>/dev/null | grep -o 'Iconic\|Normal' | head -1; }
findwin() { local c; for i in $(seq 60); do for c in $(xdotool search --pid $1 2>/dev/null); do eval "$(xdotool getwindowgeometry --shell $c 2>/dev/null)"; [ "${WIDTH:-0}" -ge 300 ] && { echo $c; return; }; done; sleep 0.25; done; }
# every click is checked first: the pointer must be over THIS test's main window and no other (the rig has a real, fullscreen Cockpit window that must never get a test click)
raise() { command -v wmctrl >/dev/null 2>&1 && wmctrl -i -r $MW -b add,above 2>/dev/null; xdotool windowraise $MW 2>/dev/null; xdotool windowactivate $MW 2>/dev/null; sleep 0.5; }
clickable() { local w; w=$(xdotool getmouselocation | sed 's/.*window:\([0-9]*\).*/\1/'); [ $((w >> 21)) -eq $((MW >> 21)) ]; }   # X resource ids carry the owning client in their high bits: same client = a window of this test's main shell, children included
wait_for() { local i; for i in $(seq 40); do eval "$1" && return 0; sleep 0.25; done; return 1; }
"$T/sh" --browser --url "http://127.0.0.1:$PORT/b.html" --width 700 --height 500 >"$T/out.b" 2>&1 & BP=$!; PIDS="$PIDS $BP"
"$T/sh" --url "http://127.0.0.1:$PORT/" --width 900 --height 400 --title "WL test main" >"$T/out.m" 2>&1 & MP=$!; PIDS="$PIDS $MP"
BW=$(findwin $BP); MW=$(findwin $MP)
[ -n "$BW" ] && [ -n "$MW" ] && ok || { bad "windows did not appear (browser '$BW', main '$MW'): $(head -c 300 "$T/out.m")"; echo "window_list_test: $n passed, $fails failed"; exit 1; }
sleep 2; xdotool windowmove $MW 100 100 2>/dev/null; xdotool windowactivate $MW 2>/dev/null; sleep 0.7
F="$T/run/cockpit-windows-$(id -u)/$BP.json"
wait_for "[ -f '$F' ]" && ok || bad "the Browser window must list itself: $(ls -R "$T/run" | head -5)"
wait_for "grep -q 'second window page' '$F' 2>/dev/null" && ok || bad "the entry must carry the page title: $(cat "$F" 2>/dev/null)"
grep -qE '"min" *: *false' "$F" 2>/dev/null && ok || bad "an open window must say min:false: $(cat "$F" 2>/dev/null)"
[ "$(cat "$T/rep.chips" 2>/dev/null)" = "[]" ] && ok || bad "no chip while nothing is minimised: $(cat "$T/rep.chips" 2>/dev/null)"
# minimise: the entry flips and a chip with the title and a hover text appears
T0=$(date +%s%N); xdotool windowminimize $BW
wait_for "grep -q '\"min\" *: *true' '$F' 2>/dev/null" && ok || bad "a minimised window must say min:true: $(cat "$F" 2>/dev/null)"
wait_for "grep -q 'second window page' '$T/rep.chips' 2>/dev/null" && ok || bad "the minimised window must show as a chip: $(cat "$T/rep.chips" 2>/dev/null)"
MS=$(( ($(date +%s%N) - T0) / 1000000 )); [ $MS -le 1500 ] && ok || bad "the chip took ${MS} ms to appear after the minimise (limit 1500)"
grep -q 'Minimised Cockpit Browser window: second window page' "$T/rep.chips" && grep -q 'right-click' "$T/rep.chips" && ok || bad "the chip needs the hover text: $(cat "$T/rep.chips" 2>/dev/null)"
chip() { php -r '$c=json_decode(file_get_contents("'"$T"'/rep.chips"),true);echo (int)$c[0]["x"]," ",(int)$c[0]["y"];'; }
MX=$(xwininfo -id $MW | sed -n 's/.*Absolute upper-left X: *//p'); MY=$(xwininfo -id $MW | sed -n 's/.*Absolute upper-left Y: *//p')   # xdotool's own geometry includes the frame, xwininfo's does not
read -r cx cy <<<"$(chip)"; ax=$((MX + cx)); ay=$((MY + cy))
# right-click: a menu with Restore and Close window; Escape closes it
raise; xdotool mousemove $ax $ay; sleep 0.3; clickable || { ") ws=$(xprop -id $MW _NET_WM_DESKTOP)" >&2; bad "the test window is not on top of the screen: refusing to click"; echo "window_list_test: $n passed, $fails failed"; exit 1; }; xdotool click 3
wait_for "grep -q 'Restore' '$T/rep.menu' 2>/dev/null && grep -q 'Close window' '$T/rep.menu'" && ok || bad "right-click must open Restore / Close window: menu=$(cat "$T/rep.menu" 2>/dev/null) chips=$(cat "$T/rep.chips")"
xdotool key Escape
wait_for "[ \"\$(cat '$T/rep.menu' 2>/dev/null)\" = '[]' ]" && ok || bad "Escape must close the menu"
xdotool windowactivate $MW 2>/dev/null; sleep 0.3
# a left click restores
raise; xdotool mousemove $ax $ay; sleep 0.3; clickable || { ") ws=$(xprop -id $MW _NET_WM_DESKTOP)" >&2; bad "the test window is not on top of the screen: refusing to click"; echo "window_list_test: $n passed, $fails failed"; exit 1; }; xdotool click 1
wait_for "[ \"\$(wmstate $BW)\" = Normal ]" && ok || bad "a click on the chip must restore the window: $(wmstate $BW); main log: $(grep -v libsoup "$T/out.m" | tail -4 | tr "\n" "|") run: $(ls "$T/run"/cockpit-windows-*/ | tr "\n" " ") browser log: $(tail -12 "$T/out.b" | tr "\n" "|")"
wait_for "[ \"\$(cat '$T/rep.chips' 2>/dev/null)\" = '[]' ]" && ok || bad "the chip must go once restored: $(cat "$T/rep.chips")"
# minimise again, then Close window from the menu: the process ends and its file is gone
xdotool windowminimize $BW; wait_for "grep -q 'second window page' '$T/rep.chips' 2>/dev/null"; xdotool windowactivate $MW 2>/dev/null; sleep 0.5
read -r cx cy <<<"$(chip)"; ax=$((MX + cx)); ay=$((MY + cy))
raise; xdotool mousemove $ax $ay; sleep 0.3; clickable || { bad "the test window is not on top: refusing to click"; exit 1; }; xdotool click 3; wait_for "grep -q 'Close window' '$T/rep.menu' 2>/dev/null"
read -r kx ky <<<"$(php -r '$m=json_decode(file_get_contents("'"$T"'/rep.menu"),true);foreach($m as $i)if(strpos($i["text"],"Close")!==false)echo (int)$i["x"]," ",(int)$i["y"];')"
raise; xdotool mousemove $((MX + kx)) $((MY + ky)); sleep 0.3; clickable || { bad "the test window is not on top: refusing to click"; exit 1; }; xdotool click 1
wait_for "! kill -0 $BP 2>/dev/null" && ok || bad "Close window from the menu must end the Browser window: menu=$(cat "$T/rep.menu" 2>/dev/null); $(tail -3 "$T/out.b")"
[ ! -f "$F" ] && ok || bad "a closed window must leave the list"
echo "window_list_test: $n passed, $fails failed"; [ $fails = 0 ]
