#!/usr/bin/env bash
# arduino_tools_test.sh — cockpit_app/arduino_tool: new / lint / info / cores need no board core; compile without the core must explain and NEVER download. (A real compile is skipped unless arduino:avr is installed.)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; A="$ROOT/cockpit_app/arduino_tool"
command -v php >/dev/null 2>&1 || { echo "arduino_tools_test: php is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
php "$A" new . n.md blink >/dev/null; [ -f blink/blink.ino ] && ok || bad "new"
php "$A" new . n2.md blink >/dev/null 2>&1; [ $? = 1 ] && ok || bad "new over existing not refused"
php "$A" lint blink l.md >/dev/null; has "No findings." l.md && has "[exit code 0]" l.md && ok || bad "the scaffold must lint clean: $(sed -n 5,12p l.md)"
mkdir bad; printf 'int led=13;\nvoid loop(){ Serial.println("x"); delay(100); digitalWrite(led,HIGH);}\n' > bad/bad.ino
php "$A" lint bad lb.md >/dev/null; has "bad.ino(1) Error: no setup() function" lb.md && has "Serial.begin() is never called" lb.md && has "pinMode(led, OUTPUT) is never set" lb.md && has "wrap it in F(" lb.md && has "[exit code 1]" lb.md && ok || bad "lint of a bad sketch: $(grep -E 'Error|Warning|Note' lb.md)"
mkdir isr; printf 'void setup(){ attachInterrupt(0, h, RISING); }\nvoid loop(){}\nvoid h(){ Serial.println("hi"); delay(5); }\n' > isr/isr.ino
php "$A" lint isr li.md >/dev/null; grep -qi "interrupt\|ISR" li.md && ok || bad "isr lint: $(sed -n 5,12p li.md)"
php "$A" info blink i.md >/dev/null; has "setup(): yes; loop(): yes" i.md && has "Serial baud rate: 9600" i.md && has "LED_PIN (OUTPUT)" i.md && ok || bad "info: $(sed -n 3,10p i.md)"
php "$A" lint blink/blink.ino lf.md >/dev/null; has "No findings." lf.md && ok || bad "lint of the .ino file itself"
php "$A" lint nope x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing sketch"
mkdir empty; php "$A" lint empty x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no .ino must be refused"
php "$A" frob blink x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
if command -v arduino-cli >/dev/null 2>&1 || [ -x ~/.local/bin/arduino-cli ]; then
  php "$A" cores . c.md >/dev/null; has "Cores installed" c.md && has "arduino-cli core install arduino:avr" c.md && ok || bad "cores"
  php "$A" compile blink cm.md fqbn=bogus:board:none >/dev/null 2>&1; has "[exit code 1]" cm.md && ok || bad "compile with an unknown board"
  if arduino-cli --config-dir "$HOME/.local/share/cockpit/arduino" core list 2>/dev/null | grep -q "arduino:avr"; then
    php "$A" compile blink cu.md fqbn=arduino:avr:uno >/dev/null; has "[exit code 0]" cu.md && ok || bad "real compile: $(tail -8 cu.md)"
  else
    php "$A" compile blink cu.md fqbn=arduino:avr:uno >/dev/null; has "NOT COMPILED" cu.md && has "this tool never downloads" cu.md && has "[exit code 1]" cu.md && ok || bad "compile without the core: $(sed -n 1,8p cu.md)"
    [ -d "$HOME/.local/share/cockpit/arduino/data/packages" ] && [ -n "$(ls "$HOME/.local/share/cockpit/arduino/data/packages" 2>/dev/null | grep -v "^builtin$")" ] && bad "a core got downloaded" || ok
  fi
else echo "  (arduino-cli missing: cores/compile skipped)"; fi
head -20 "$A" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
[ "$(jq '.presets|length' "$ROOT/cockpit_app/tools_builtins/arduino.json")" = 5 ] && ok || bad "arduino.json presets"
echo "arduino_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
