#!/usr/bin/env bash
# shell_mainctl_test.sh — the Min / Max / Close buttons of the MAIN window when it runs frameless (shell/cockpit_shell.pas: GripsInstall(False), OnCtlPoll, OnCtlClick).
# The Browser and worker windows get them in their top-right corner; the main window's page already fills that corner with its Settings buttons, so there they come up only when the
# pointer reaches the empty strip along the right edge. Real windows on the real X display, driven with real mouse input (xdotool); SKIPPED without fpc, xdotool, php or a display.
#   bash tests/shell_mainctl_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v php >/dev/null 2>&1 && command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1 || { echo "shell_mainctl_test: needs fpc, xdotool, php and an X display - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/mc_XXXX) || exit 1; PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/sh" >/dev/null 2>&1 && "$T/sh" --check >/dev/null 2>&1 || { echo "shell_mainctl_test: shell build or GTK/WebKit missing - SKIPPED"; exit 0; }
mkdir -p "$T/site" "$T/cfg/ai-cockpit"; echo '<!doctype html><title>main stand-in</title><body style="margin:0;background:#223">page</body>' > "$T/site/index.html"
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT -t "$T/site" >"$T/php.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
export XDG_CONFIG_HOME="$T/cfg"
wmstate() { xprop -id "$1" WM_STATE 2>/dev/null | grep -o 'Iconic\|Normal' | head -1; }
maxed() { xprop -id "$1" _NET_WM_STATE 2>/dev/null | grep -q MAXIMIZED_HORZ; }
findwin() { local c; for i in $(seq 60); do for c in $(xdotool search --pid $1 2>/dev/null); do eval "$(xdotool getwindowgeometry --shell $c 2>/dev/null)"; [ "${WIDTH:-0}" -ge 300 ] && { echo $c; return; }; done; sleep 0.25; done; }
shown() { grep -c "window buttons shown" "$1"; }
wait_for() { local i; for i in $(seq 40); do eval "$1" && return 0; sleep 0.25; done; return 1; }
# the pointer must be over THIS test's own window (a real, maximised Cockpit may sit on the screen): the X client id sits in the high bits of a window id
clickable() { local w; w=$(xdotool getmouselocation | sed 's/.*window:\([0-9]*\).*/\1/'); [ $((w >> 21)) -eq $((MW >> 21)) ]; }
raise() { command -v wmctrl >/dev/null 2>&1 && wmctrl -i -r $MW -b add,above 2>/dev/null; xdotool windowraise $MW 2>/dev/null; xdotool windowactivate $MW 2>/dev/null; sleep 0.5; }
# client-area origin and size (xwininfo: xdotool's own geometry includes the frame)
org() { X0=$(xwininfo -id $MW | sed -n 's/.*Absolute upper-left X: *//p'); Y0=$(xwininfo -id $MW | sed -n 's/.*Absolute upper-left Y: *//p'); W0=$(xwininfo -id $MW | sed -n 's/.*Width: *//p'); }

# ── a FRAMELESS main window
"$T/sh" --url "http://127.0.0.1:$PORT/" --width 900 --height 500 --title "MC main" --frameless >"$T/out.f" 2>&1 & MP=$!; PIDS="$PIDS $MP"
MW=$(findwin $MP); [ -n "$MW" ] && ok || { bad "the frameless main window did not appear: $(head -c 300 "$T/out.f")"; echo "shell_mainctl_test: $n passed, $fails failed"; exit 1; }
sleep 2; xdotool windowmove $MW 200 150 2>/dev/null; raise; org
grep -q "window buttons installed (main window)" "$T/out.f" && ok || bad "a frameless main window must install the window buttons: $(head -c 300 "$T/out.f")"
! grep -q "border strips installed" "$T/out.f" && ok || bad "the main window draws its own edge handles in the page: no native strips"
# hovering where the page's own buttons are (a little in from the right edge) must NOT bring the buttons up
xdotool mousemove $((X0 + W0 - 60)) $((Y0 + 20)); sleep 1.2; [ "$(shown "$T/out.f")" = 0 ] && ok || bad "hovering over the page's own buttons area must not pop the window buttons up"
# the empty strip along the right edge does
raise; xdotool mousemove $((X0 + W0 - 5)) $((Y0 + 20)); sleep 1.2
[ "$(shown "$T/out.f")" -ge 1 ] && ok || bad "the pointer on the right edge, top: the buttons must appear: $(tail -3 "$T/out.f")"
btn() { local l; l=$(grep "window button $1 at " "$T/out.f" | tail -1); [ -n "$l" ] || return 1; local xy; xy=$(echo "$l" | sed 's/.*window button [0-9] at \([0-9]*\),\([0-9]*\) size \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/'); read -r bx by bw bh <<<"$xy"; echo "$((X0 + bx + bw / 2)) $((Y0 + by + bh / 2))"; }
click_btn() { local c cnt; raise; xdotool mousemove $((X0 + W0 / 2)) $((Y0 + 250)); sleep 1.0   # away: the buttons hide, and their places are logged afresh the next time they show
  sleep 0.8; org   # the window manager may still be settling the size
  cnt=$(grep -c "window button 0 at" "$T/out.f"); xdotool mousemove $((X0 + W0 - 5)) $((Y0 + 20)); wait_for "[ \$(grep -c \"window button 0 at\" \"$T/out.f\") -gt $cnt ]" || { bad "the buttons did not come up again for button $1"; return 1; }
  c=$(btn $1) || { bad "no position logged for window button $1"; return 1; }; read -r cx cy <<<"$c"; xdotool mousemove $cx $cy; sleep 0.4; clickable || { bad "the test window is not on top: refusing to click"; return 1; }; xdotool click 1; sleep 0.9; }
wait_for "grep -q 'window button 0 at' '$T/out.f'" && ok || bad "the buttons' places must be logged once shown"
click_btn 1; maxed $MW && ok || bad "Max must maximise the main window"
org; click_btn 1; ! maxed $MW && ok || bad "the same button must restore it"
sleep 0.8; org; click_btn 0; wait_for "[ \"\$(wmstate $MW)\" = Iconic ]" && ok || bad "Min must minimise: $(wmstate $MW); $(grep -E "window button|window buttons" "$T/out.f" | tail -4 | tr "\n" "|")"
xdotool windowactivate $MW 2>/dev/null; wait_for "[ \"\$(wmstate $MW)\" = Normal ]" && ok || bad "the window comes back from the taskbar"
org; raise; click_btn 2; wait_for "! kill -0 $MP 2>/dev/null" && ok || bad "Close must take the exit path (a page that is not up: the window quits): $(tail -3 "$T/out.f")"
grep -q "window button 2 clicked" "$T/out.f" && ok || bad "the close click must reach the shell"

# ── a FRAMED main window: no buttons, wherever the pointer goes
"$T/sh" --url "http://127.0.0.1:$PORT/" --width 900 --height 500 --title "MC framed" >"$T/out.g" 2>&1 & GP=$!; PIDS="$PIDS $GP"
MW=$(findwin $GP); [ -n "$MW" ] && ok || bad "the framed main window did not appear"
sleep 2; xdotool windowmove $MW 200 150 2>/dev/null; raise; org
xdotool mousemove $((X0 + W0 - 5)) $((Y0 + 20)); sleep 1.3; [ "$(shown "$T/out.g")" = 0 ] && ok || bad "a framed window has a title bar: it must never get the window buttons"
echo "shell_mainctl_test: $n passed, $fails failed"; [ $fails = 0 ]
