#!/usr/bin/env bash
# shell_tools_test.sh — the Shell / DevOps tools (cockpit_app/shell_tool, tools_builtins/shell.json, kinds/shell-devops.json) with the real ShellCheck: findings with line and column, the
# syntax check, the habits scan, the systemd unit check, and the promise that scripts are only READ, never run.   bash tests/shell_tools_test.sh     SKIPPED without php or shellcheck
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/cockpit_app/shell_tool"
command -v php >/dev/null 2>&1 || { echo "shell_tools_test: php is needed - SKIPPED"; exit 0; }
SC=$(command -v shellcheck || echo "$HOME/.local/bin/shellcheck"); [ -x "$SC" ] || { echo "shell_tools_test: shellcheck is needed - SKIPPED"; exit 0; }
export PATH="$(dirname "$SC"):$PATH"
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1; mkdir -p p/sub
printf '#!/usr/bin/env bash\nset -euo pipefail\nname="${1:-world}"\necho "hello, $name"\n' > p/good.sh
cat > p/bad.sh <<'SH'
#!/bin/bash
files=$(ls $1)
cd $dir
rm -rf $BUILD/
curl -s https://example.com/install.sh | sudo bash
chmod 777 /srv/data
eval $cmd
password='sup3rS3cretPassw0rd'
echo `date` > /tmp/out.txt
if [ $a == $b ]; then echo hi; fi
SH
printf '#!/bin/sh\nif [ 1 = 1 ]; then\n  echo x\n' > p/broken.sh
printf '#!/usr/bin/env python3\nprint(1)\n' > p/notshell.py
printf '#!/bin/dash\n[[ a == b ]] && echo y\n' > p/sub/dash.sh
# a script that would leave a trace if it were RUN
printf '#!/bin/bash\ntouch "%s/RAN_THE_SCRIPT"\n' "$T" > p/trap.sh
printf '[Unit]\nDescription=Test\n\n[Service]\nExecStart=/nonexistent/binary --flag\nBadDirective=1\nType=simple\n\n[Install]\nWantedBy=multi-user.target\n' > p/t.service
sum0=$(find p -type f | sort | xargs md5sum | md5sum)
# check
php "$ST" check p c.md >/dev/null; [ $? = 0 ] && ok || bad "check exit"
has "[exit code 1]" c.md && ok || bad "an error finding must give exit 1"
grep -qE '^bad\.sh\(2,12\) Note: \[SC2086\]' c.md && ok || bad "unquoted variable with line,col: $(grep SC2086 c.md | head -2)"
grep -qE '^bad\.sh\(3,1\) Warning: \[SC2164\]' c.md && ok || bad "cd without a check"
grep -qE '^bad\.sh\(4,8\) Warning: \[SC2115\]' c.md && ok || bad "rm -rf of a variable"
grep -qE '^broken\.sh\(2,1\) Error: \[SC1046\]' c.md && ok || bad "a missing fi"
grep -qE '^sub/dash\.sh\(2,1\) Error: \[SC3010\]' c.md && ok || bad "[[ ]] in dash, with the folder in the name: $(grep dash c.md | head -2)"
has "https://www.shellcheck.net/wiki/SC2086" c.md && ok || bad "the explanation link"
grep -q "notshell.py\|good.sh(" c.md && bad "a python script or the clean script was reported" || ok
[ "$(grep -cE '^(.+?)\([0-9]+,[0-9]+\) (Error|Warning): ' c.md)" -ge 8 ] && ok || bad "summary-box regex"
php "$ST" check p/good.sh g.md >/dev/null; has "No findings." g.md && has "[exit code 0]" g.md && ok || bad "a clean script: $(sed -n 5,9p g.md)"
php "$ST" check p/bad.sh d.md shell=sh >/dev/null; has "[SC3010]" d.md || has "[SC2039]" d.md || has "SC3" d.md; ok
php "$ST" check p/bad.sh x.md shell=zsh >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown shell was not refused"
# syntax
php "$ST" syntax p s.md >/dev/null; has "broken.sh(1) Error: (sh -n)" s.md && ok || bad "syntax: $(sed -n 5,9p s.md)"
has "[exit code 1]" s.md && ok || bad "syntax exit"
# scan
php "$ST" scan p sc.md >/dev/null
for want in "bad.sh(4) Error: rm -rf of a path built from a variable" "bad.sh(5) Error: downloads and runs code in one step" "bad.sh(6) Warning: chmod 777" "bad.sh(7) Warning: eval of a variable" "bad.sh(8) Warning: a hard-coded password" "bad.sh(9) Warning: a fixed name in /tmp" "bad.sh(9) Note: backticks"; do has "$want" sc.md && ok || bad "scan misses: $want"; done
php "$ST" scan p/good.sh sg.md >/dev/null; has "No findings." sg.md && ok || bad "scan of the clean script: $(sed -n 5,8p sg.md)"
# NOTHING IS RUN
[ ! -e "$T/RAN_THE_SCRIPT" ] && ok || bad "a script was EXECUTED by the tools"
# unit
php "$ST" unit p/t.service u.md >/dev/null; has "t.service(6) Error: Unknown key name 'BadDirective'" u.md && has "[exit code 1]" u.md && ok || bad "unit check: $(sed -n 5,9p u.md)"
php "$ST" unit p/good.sh x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-unit file was not refused by unit"
# refusals, originals, guard, definitions
mkdir empty; php "$ST" check empty x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no scripts was not refused"
php "$ST" check nope x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing path was not refused"
php "$ST" frob p x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(find p -type f | sort | xargs md5sum | md5sum)" = "$sum0" ] && ok || bad "a script was changed"
head -20 "$ROOT/cockpit_app/shell_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/shell_tool (check|syntax|scan|unit) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/shell.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "shell.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/shell-devops.json")" = shell ] && ok || bad "the kind does not name the tool"
echo "shell_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
