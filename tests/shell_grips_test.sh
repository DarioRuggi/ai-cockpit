#!/usr/bin/env bash
# shell_grips_test.sh — the native border strips of a FRAMELESS Cockpit Browser / worker window (shell/cockpit_shell.pas: GripsInstall): real windows of a freshly built shell on the real X
# display, driven with real mouse input (xdotool): the right edge and the south-east corner resize, the middle of a side moves the window without resizing it, the page centre does neither,
# a framed window gets no strips, Ctrl+W closes the browser window.   bash tests/shell_grips_test.sh     SKIPPED without fpc, xdotool, php or a display.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v php >/dev/null 2>&1 && command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1 || { echo "shell_grips_test: needs fpc, xdotool, php and an X display - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/sg_XXXX) || exit 1; PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/sh" >/dev/null 2>&1 && "$T/sh" --check >/dev/null 2>&1 || { echo "shell_grips_test: shell build or GTK/WebKit missing - SKIPPED"; exit 0; }
mkdir -p "$T/site" "$T/cfg/ai-cockpit"; echo '<!doctype html><title>grips test</title><body style="margin:0;background:#ddd">page</body>' > "$T/site/index.html"
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT -t "$T/site" >"$T/php.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
export XDG_CONFIG_HOME="$T/cfg"
geo() { eval "$(xdotool getwindowgeometry --shell "$1" 2>/dev/null)"; echo "$X $Y $WIDTH $HEIGHT"; }
launch() { "$T/sh" --browser --url "http://127.0.0.1:$PORT/" --width 800 --height 600 >"$T/out.$1" 2>&1 & SP=$!; PIDS="$PIDS $SP"; W=""; for i in $(seq 60); do for c in $(xdotool search --pid $SP 2>/dev/null); do read -r x y w h <<<"$(geo $c)"; [ "${w:-0}" -ge 300 ] && [ "${h:-0}" -ge 300 ] && { W=$c; break 2; }; done; sleep 0.25; done; xdotool windowmove $W 300 200 2>/dev/null; sleep 2.5; xdotool windowfocus $W 2>/dev/null; sleep 0.5; }
drag() { xdotool mousemove "$1" "$2" sleep 0.3 mousedown 1 sleep 0.2 mousemove_relative --sync $(( $3 / 2 )) $(( $4 / 2 )) sleep 0.1 mousemove_relative --sync $(( $3 - $3 / 2 )) $(( $4 - $4 / 2 )) sleep 0.2 mouseup 1; sleep 0.8; }
wmstate() { xprop -id "$1" WM_STATE 2>/dev/null | grep -o 'Iconic\|Normal' | head -1; }
maxed() { xprop -id "$1" _NET_WM_STATE 2>/dev/null | grep -q MAXIMIZED_HORZ; }
# the window buttons: hover the top-right corner, then click button 0 (minimise), 1 (maximise / restore) or 2 (close); positions are fixed by the layout (30 px wide, 2 px apart, 8 px from the right edge, 6 px from the top)
# the shell logs where each button really is once they appear (the theme decides their size): hover the corner, read that line, click its centre
ctl() { read -r cx cy cw ch <<<"$(geo $W)"; xdotool mousemove $((cx + cw - 12)) $((cy + 8)); sleep 0.9; local line; line=$(grep "window button $1 at " "$T/out.f" | tail -1); [ -n "$line" ] || { echo "(no position logged for button $1)" >&2; return 1; }; local bx by bw bh; bx=$(sed -E 's/.* at ([0-9]+),([0-9]+) size ([0-9]+)x([0-9]+).*/\1/' <<<"$line"); by=$(sed -E 's/.* at ([0-9]+),([0-9]+) size ([0-9]+)x([0-9]+).*/\2/' <<<"$line"); bw=$(sed -E 's/.* at ([0-9]+),([0-9]+) size ([0-9]+)x([0-9]+).*/\3/' <<<"$line"); bh=$(sed -E 's/.* at ([0-9]+),([0-9]+) size ([0-9]+)x([0-9]+).*/\4/' <<<"$line"); xdotool mousemove $((cx + bx + bw / 2)) $((cy + by + bh / 2)); sleep 0.4; xdotool click 1; sleep 1.0; }
near() { local d=$(( $1 - $2 )); [ ${d#-} -le $3 ]; }
presses() { grep -c 'grip press' "$T/out.f"; }

# frameless: strips present
echo on > "$T/cfg/ai-cockpit/frameless"; launch f
[ -n "$W" ] && ok || { bad "the frameless browser window did not appear"; echo "shell_grips_test: $n passed, $fails failed"; exit 1; }
grep -q "border strips installed" "$T/out.f" && ok || bad "a frameless browser window must install the strips: $(head -c 300 "$T/out.f")"
read -r X0 Y0 W0 H0 <<<"$(geo $W)"
# right edge, a quarter of the way down (the resize part of the side, not the move strip in its middle)
drag $((X0 + W0 - 2)) $((Y0 + H0 / 5)) 120 0; read -r X1 Y1 W1 H1 <<<"$(geo $W)"
near $W1 $((W0 + 120)) 8 && near $H1 $H0 4 && near $X1 $X0 4 && ok || bad "right edge drag +120: ${W0}x${H0} -> ${W1}x${H1} at $X1,$Y1 (was $X0,$Y0); presses seen by the shell: $(presses); $(tail -3 "$T/out.f" | tr '\\n' ' ')"
# south-east corner
read -r X0 Y0 W0 H0 <<<"$(geo $W)"
drag $((X0 + W0 - 3)) $((Y0 + H0 - 3)) 60 40; read -r X1 Y1 W1 H1 <<<"$(geo $W)"
near $W1 $((W0 + 60)) 8 && near $H1 $((H0 + 40)) 8 && ok || bad "corner drag +60,+40: ${W0}x${H0} -> ${W1}x${H1}"
# the middle of the top side moves the window and does not resize it
read -r X0 Y0 W0 H0 <<<"$(geo $W)"
drag $((X0 + W0 / 2)) $((Y0 + 3)) 100 60; read -r X1 Y1 W1 H1 <<<"$(geo $W)"
near $W1 $W0 4 && near $H1 $H0 4 && near $X1 $((X0 + 100)) 8 && near $Y1 $((Y0 + 60)) 8 && ok || bad "move strip drag +100,+60: $X0,$Y0 ${W0}x${H0} -> $X1,$Y1 ${W1}x${H1}"
# the page itself: a drag in the middle changes nothing
read -r X0 Y0 W0 H0 <<<"$(geo $W)"
drag $((X0 + W0 / 2)) $((Y0 + H0 / 2)) 80 50; read -r X1 Y1 W1 H1 <<<"$(geo $W)"
near $W1 $W0 2 && near $H1 $H0 2 && near $X1 $X0 2 && near $Y1 $Y0 2 && ok || bad "a drag on the page must move and resize nothing: $X0,$Y0 ${W0}x${H0} -> $X1,$Y1 ${W1}x${H1}"
# window buttons: maximise, restore, minimise, restore from the taskbar's own request, close
read -r X0 Y0 W0 H0 <<<"$(geo $W)"
ctl 1; read -r X1 Y1 W1 H1 <<<"$(geo $W)"
maxed $W && [ "$W1" -gt "$W0" ] && ok || bad "the Max button must maximise: ${W0}x${H0} -> ${W1}x${H1}; shell log: $(tail -6 "$T/out.f" | tr "\n" "|")"
# a maximised window is not moved or resized by its border, but the same button restores it
ctl 1; read -r X2 Y2 W2 H2 <<<"$(geo $W)"
! maxed $W && near $W2 $W0 12 && ok || bad "the same button must restore the window: ${W1}x${H1} -> ${W2}x${H2}, maximised: $(maxed $W && echo yes || echo no)"
xprop -id $W _NET_WM_STATE 2>/dev/null | grep -q SKIP_TASKBAR && bad "a Browser window must stay in the taskbar (so a minimised one can be restored from it)" || ok
ctl 0; [ "$(wmstate $W)" = Iconic ] && ok || bad "the Min button must minimise: state $(wmstate $W)"
xdotool windowactivate $W 2>/dev/null; sleep 1.2; [ "$(wmstate $W)" = Normal ] && ok || bad "a minimised window must be restorable by the window manager (taskbar / Alt+Tab use this request): $(wmstate $W)"
# Ctrl+W closes a browser window
xdotool windowfocus $W 2>/dev/null; sleep 0.3; xdotool key --clearmodifiers ctrl+w; for i in $(seq 20); do kill -0 $SP 2>/dev/null || break; sleep 0.25; done
kill -0 $SP 2>/dev/null && bad "Ctrl+W did not close the browser window" || ok
# framed (the default): no strips
rm -f "$T/cfg/ai-cockpit/frameless"; launch g
grep -q "border strips installed" "$T/out.g" && bad "a framed window must not get the strips" || ok
kill $SP 2>/dev/null
echo "shell_grips_test: $n passed, $fails failed"; [ "$fails" = 0 ]
