#!/usr/bin/env bash
# shell_power_hotkey_test.sh — what the Cockpit window (shell/cockpit_shell.pas) does for Power Buttons, on the real X display with real key presses (xdotool):
#   * open_power_sync   the page hands over [{key,cmd}]; the window grabs those keys GLOBALLY, a press runs the command, a bad key / a multi-line command is refused, a new list releases the old keys,
#                       and the list is kept in <config>/power_hotkeys.json and grabbed again when the window starts
#   * open_install_file writes a launcher / desktop icon / file-manager script / the cockpit-run tool only under the fixed names, executable, and refuses everything else
#   * the ⚡ menu       a Browser window has a ⚡ button that lists the buttons from power_menu.json and runs the chosen command
# SKIPPED without fpc, xdotool, php or a display.
#   bash tests/shell_power_hotkey_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && command -v xdotool >/dev/null 2>&1 && command -v php >/dev/null 2>&1 && command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1 || { echo "shell_power_hotkey_test: needs fpc, xdotool, php and an X display - SKIPPED"; exit 0; }
[ -z "${WAYLAND_DISPLAY:-}" ] || { echo "shell_power_hotkey_test: a Wayland session grabs no keys - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/ph_XXXX) || exit 1; PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/sh" >/dev/null 2>&1 && "$T/sh" --check >/dev/null 2>&1 || { echo "shell_power_hotkey_test: shell build or GTK/WebKit missing - SKIPPED"; exit 0; }
mkdir -p "$T/site" "$T/home" "$T/cfg/ai-cockpit" "$T/data"
# the stand-in page: posts the commands it is told to (from /cmds.json, one list per round) and reports every reply to /rep.php
cat > "$T/site/index.html" <<'HTML'
<!doctype html><title>power stand-in</title><body style="margin:0;background:#223">stand-in
<script>
var n = 0;
window.cockpitShellReply = function (r) { fetch('rep.php', { method: 'POST', body: JSON.stringify(r) }); };
function send(o) { window.webkit.messageHandlers.cockpit.postMessage(JSON.stringify(o)); }
var seen = {};
setInterval(function () { fetch('cmds.php').then(function (r) { return r.json(); }).then(function (q) { (q || []).forEach(function (j) { if (j && j.cmd && !seen[j.id]) { seen[j.id] = 1; send(j); } }); }); }, 400);
</script></body>
HTML
cat > "$T/site/cmds.php" <<'PHP'
<?php $f = __DIR__ . '/queue.json'; header('Content-Type: application/json'); echo is_file($f) ? file_get_contents($f) : '[]';
PHP
cat > "$T/site/rep.php" <<'PHP'
<?php file_put_contents(__DIR__ . '/replies.log', file_get_contents('php://input') . "\n", FILE_APPEND); echo 'ok';
PHP
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT -t "$T/site" >"$T/php.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.2; done
export XDG_CONFIG_HOME="$T/cfg" HOME="$T/home"
queue() { echo "$1" > "$T/site/queue.json"; }
wait_for() { local i; for i in $(seq 40); do eval "$1" && return 0; sleep 0.25; done; return 1; }
replies() { cat "$T/site/replies.log" 2>/dev/null; }
rm -f "$T/site/replies.log"
"$T/sh" --url "http://127.0.0.1:$PORT/" --width 600 --height 300 --title "PH main" --hotkey none >"$T/out" 2>&1 & MP=$!; PIDS="$PIDS $MP"
wait_for "xdotool search --pid $MP >/dev/null 2>&1" || { bad "the window did not appear: $(head -c 300 "$T/out")"; echo "shell_power_hotkey_test: $n passed, $fails failed"; exit 1; }
sleep 2
K1="ctrl+alt+shift+F9"; K2="ctrl+alt+shift+F10"
# ── 1. hotkeys
queue "[{\"id\":\"s1\",\"cmd\":\"open_power_sync\",\"hotkeys\":[{\"key\":\"ctrl+alt+shift+f9\",\"cmd\":\"touch $T/hit1\"},{\"key\":\"ctrl+alt+shift+f10\",\"cmd\":\"touch $T/hit2\"},{\"key\":\"ctrl+f13\",\"cmd\":\"touch $T/bad1\"},{\"key\":\"a\",\"cmd\":\"touch $T/bad2\"},{\"key\":\"ctrl+alt+shift+f11\",\"cmd\":\"touch $T/bad3\\ntouch $T/bad4\"},{\"key\":\"ctrl+alt+shift+f9\",\"cmd\":\"touch $T/dup\"}],\"menu\":[]}]"
wait_for "replies | grep -q '\"id\":\"s1\"'" && ok || bad "no reply to open_power_sync: $(tail -3 "$T/out")"
replies | grep -q '"grabbed":2' && ok || bad "2 keys are grabbed (two good; a bad key, a bare key, a two-line command and a repeated key are refused): $(replies)"
xdotool key $K1; wait_for "[ -f $T/hit1 ]" && ok || bad "the global hotkey ran its command: $(tail -4 "$T/out")"
xdotool key $K2; wait_for "[ -f $T/hit2 ]" && ok || bad "the second hotkey ran its own command"
[ ! -f "$T/dup" ] && [ ! -f "$T/bad1" ] && [ ! -f "$T/bad3" ] && [ ! -f "$T/bad4" ] && ok || bad "a refused hotkey must not run anything"
grep -q "power hotkey: refused" "$T/out" && grep -q "already taken" "$T/out" && ok || bad "refusals are logged"
[ -f "$T/cfg/ai-cockpit/power_hotkeys.json" ] && jq -e 'length==6' "$T/cfg/ai-cockpit/power_hotkeys.json" >/dev/null 2>&1 && ok || bad "the list is kept for the next start: $(cat "$T/cfg/ai-cockpit/power_hotkeys.json" 2>/dev/null | head -c 200)"
# a new list releases the old keys
rm -f "$T/hit1" "$T/hit2"; queue "[$(jq -c '.[0]' "$T/site/queue.json" 2>/dev/null),{\"id\":\"s2\",\"cmd\":\"open_power_sync\",\"hotkeys\":[{\"key\":\"ctrl+alt+shift+f10\",\"cmd\":\"touch $T/hit2\"}],\"menu\":[]}]"
wait_for "replies | grep -q '\"id\":\"s2\"'" || bad "no reply to the second open_power_sync"
xdotool key $K1; sleep 1.2; [ ! -f "$T/hit1" ] && ok || bad "a key dropped from the list is released"
xdotool key $K2; wait_for "[ -f $T/hit2 ]" && ok || bad "a key still on the list keeps working"
# an empty list releases everything
rm -f "$T/hit2"; jq -c '. + [{"id":"s3","cmd":"open_power_sync","hotkeys":[],"menu":[]}]' "$T/site/queue.json" > "$T/site/q2.json" && mv "$T/site/q2.json" "$T/site/queue.json"
wait_for "replies | grep -q '\"id\":\"s3\"'" || bad "no reply to the empty list"
xdotool key $K2; sleep 1.2; [ ! -f "$T/hit2" ] && ok || bad "an empty list releases every key"
# the saved list is grabbed again when the window starts
echo '[]' > "$T/site/queue.json"; kill $MP 2>/dev/null; sleep 1; PIDS=""
printf '[{"key":"ctrl+alt+shift+f9","cmd":"touch %s/again"}]' "$T" > "$T/cfg/ai-cockpit/power_hotkeys.json"
"$T/sh" --url "http://127.0.0.1:$PORT/" --width 600 --height 300 --title "PH main2" --hotkey none >"$T/out2" 2>&1 & MP=$!; PIDS="$MP"
wait_for "xdotool search --pid $MP >/dev/null 2>&1"; sleep 2.5; xdotool key $K1; wait_for "[ -f $T/again ]" && ok || bad "a saved hotkey is grabbed at start: $(tail -3 "$T/out2")"
# ── 2. install_file
rm -f "$T/site/replies.log"
body='#!/bin/sh\necho hi\n'
q='[{"id":"i0","cmd":"open_install_file","kind":"cli","name":"cockpit-run","content":"x"}'
add() { q="$q,{\"id\":\"$1\",\"cmd\":\"open_install_file\",\"kind\":\"$2\",\"name\":\"$3\",\"content\":\"$4\"}"; }
add i1 launcher "cockpit-power-proof.desktop" '[Desktop Entry]\nName=Proof\nExec=true\n'
add i2 desktop_icon "cockpit-power-proof.desktop" '[Desktop Entry]\nName=Proof\n'
add i3 nautilus "Cockpit - Proof (v2)" "$body"
add i4 dolphin "cockpit-power.desktop" '[Desktop Entry]\nType=Service\n'
add i5 cli "cockpit-run" "$body"
add e1 launcher "../evil.desktop" "$body"
add e2 launcher "cockpit-power-x.sh" "$body"
add e3 launcher ".desktop" "$body"
add e4 nautilus "../../etc/x" "$body"
add e5 nautilus "Cockpit - a/b" "$body"
add e6 cli "other-name" "$body"
add e7 dolphin "other.desktop" "$body"
add e8 nope "cockpit-run" "$body"
add e9 launcher "cockpit-power-Up.desktop" "$body"
q="$q,{\"id\":\"e10\",\"cmd\":\"open_install_file\",\"kind\":\"cli\",\"name\":\"cockpit-run\",\"content\":\"\"}]"
echo "$q" > "$T/site/queue.json"
wait_for "replies | grep -q '\"id\":\"e10\"'" || bad "install_file replies missing: $(tail -3 "$T/out2")"
for i in i1 i2 i3 i4 i5; do replies | grep "\"id\":\"$i\"" | grep -q '"ok":true' && ok || bad "install_file $i should succeed: $(replies | grep "\"id\":\"$i\"")"; done
for i in e1 e2 e3 e4 e5 e6 e7 e8 e9 e10; do replies | grep "\"id\":\"$i\"" | grep -q '"ok":false' && ok || bad "install_file $i must be refused: $(replies | grep "\"id\":\"$i\"")"; done
H="$T/home"
[ -x "$H/.local/share/applications/cockpit-power-proof.desktop" ] && grep -q "^Exec=true" "$H/.local/share/applications/cockpit-power-proof.desktop" && ok || bad "the launcher is in the applications menu folder, executable"
[ -x "$H/Desktop/cockpit-power-proof.desktop" ] && ok || bad "the desktop icon is on the desktop, executable: $(ls -la "$H/Desktop" 2>&1 | tail -2)"
[ -x "$H/.local/share/nautilus/scripts/Cockpit - Proof (v2)" ] && ok || bad "the Files script is in the scripts folder, executable"
[ -f "$H/.local/share/kio/servicemenus/cockpit-power.desktop" ] && ok || bad "the Dolphin menu is in the service menus folder"
[ -x "$H/.local/bin/cockpit-run" ] && [ "$(head -1 "$H/.local/bin/cockpit-run")" = "#!/bin/sh" ] && ok || bad "cockpit-run is in ~/.local/bin, executable"
[ ! -e "$H/evil.desktop" ] && [ ! -e "$T/evil.desktop" ] && [ ! -e "$H/.local/share/applications/evil.desktop" ] && ok || bad "a path in the name must never write anywhere else"
# ── 3. the ⚡ menu of a Browser window
kill $MP 2>/dev/null; sleep 1; PIDS=""
printf '[{"name":"Proofread","icon":"spellcheck","cmd":"touch %s/menu_hit"},{"name":"Bad","cmd":"x\\ny"}]' "$T" > "$T/cfg/ai-cockpit/power_menu.json"
"$T/sh" --browser --frameless --url "http://127.0.0.1:$PORT/" --width 700 --height 300 --title "PH browser" >"$T/out3" 2>&1 & BP=$!; PIDS="$BP"
wait_for "xdotool search --pid $BP >/dev/null 2>&1"; sleep 2.5
MW=""; for c in $(xdotool search --pid $BP 2>/dev/null); do eval "$(xdotool getwindowgeometry --shell $c 2>/dev/null)"; [ "${WIDTH:-0}" -ge 300 ] && MW=$c; done
if [ -n "$MW" ]; then
  X0=$(xwininfo -id $MW | sed -n 's/.*Absolute upper-left X: *//p'); Y0=$(xwininfo -id $MW | sed -n 's/.*Absolute upper-left Y: *//p'); W0=$(xwininfo -id $MW | sed -n 's/.*Width: *//p')
  command -v wmctrl >/dev/null 2>&1 && wmctrl -i -r $MW -b add,above 2>/dev/null; xdotool windowraise $MW 2>/dev/null; sleep 0.5
  xdotool mousemove $((X0 + W0 - 60)) $((Y0 + 20)); wait_for "grep -q 'window buttons shown' '$T/out3'" && ok || bad "the Browser window shows its buttons at the top right: $(tail -3 "$T/out3")"
  sleep 0.6; l=$(grep "window button 0 at " "$T/out3" | tail -1); read -r bx by bw bh <<<"$(echo "$l" | sed 's/.*window button 0 at \([0-9]*\),\([0-9]*\) size \([0-9]*\)x\([0-9]*\).*/\1 \2 \3 \4/')"
  if [ -n "$bx" ]; then
    px=$((X0 + bx - 34 + 15)); py=$((Y0 + by + bh / 2)); xdotool mousemove $px $py; sleep 0.3; xdotool click 1
    wait_for "grep -q 'power menu opened with 1 items' '$T/out3'" && ok || bad "the ⚡ button opens a menu with the one valid item (the two-line command is left out): $(grep -i 'power menu' "$T/out3" | tail -2)"
    xdotool key Down; sleep 0.3; xdotool key Return; wait_for "[ -f $T/menu_hit ]" && ok || bad "choosing the item runs its command: $(tail -3 "$T/out3")"
  else bad "no logged position for the window buttons"; ok; ok; fi
else bad "the Browser window did not appear"; ok; ok; fi
echo "shell_power_hotkey_test: $n passed, $fails failed"; [ $fails = 0 ]
