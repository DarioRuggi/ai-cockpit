#!/usr/bin/env bash
# sysadmin_tools_test.sh — the System administration tools (cockpit_app/sys_tool, tools_builtins/sysadmin.json, kinds/system-administration.json). They read the REAL machine, so the checks
# are about structure and behaviour, not values: the report's sections, a listener this test starts, a log file made here, disk use of a folder made here, the unit-name check, and — the
# promise of the kind — that the tool can only LOOK: no command in it changes the system.   bash tests/sysadmin_tools_test.sh     SKIPPED without php or ss
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/cockpit_app/sys_tool"
command -v php >/dev/null 2>&1 && command -v ss >/dev/null 2>&1 || { echo "sysadmin_tools_test: php and ss are needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; LP=""; trap '[ -n "$LP" ] && kill $LP 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
# the promise: read only. No mutating command anywhere in the tool's source (apart from comments).
grep -v '^\s*//' "$ST" | grep -nE "systemctl\s+(start|stop|restart|reload|enable|disable|mask|daemon-reload|kill)|\bsudo\b|\brm\s|\bmv\s|\bchmod\b|\bchown\b|\bapt(-get)?\s+(install|remove|purge|upgrade)|\bkill\s|\bpkill\b|\bufw\b|\biptables\b|\bshutdown\b|\breboot\s*['\"]|\bmkfs\b|\bdd\s+if|>\s*/etc|\bsed\s+-i|\bpasswd\b|useradd|userdel|crontab\s+-" > mut.txt; [ ! -s mut.txt ] && ok || bad "the tool contains a command that could change the system: $(head -3 mut.txt)"
grep -q "READ ONLY" "$ST" && ok || bad "the tool does not say it is read only"
# report
php "$ST" report r.md >/dev/null 2>r.err; [ $? = 0 ] && ok || bad "report failed: $(cat r.err)"
for s in "# System report" "## Memory" "## Disks" "## Busiest processes" "## Listening ports" "## Findings"; do has "$s" r.md && ok || bad "report lacks: $s"; done
has "- Run as: $(id -un)" r.md && ok || bad "the report must say which account it ran as"
grep -q "Warning: Undefined\|Notice:\|Deprecated:" r.md r.err && bad "a PHP warning leaked: $(grep -h 'Undefined\|Notice\|Deprecated' r.md r.err | head -2)" || ok
[ "$(grep -c '^system(1) Warning: failed service: casper' r.md)" -le 1 ] && ok || bad "a warning was repeated"
[ "$(sort r.md | uniq -d | grep -c '^system(1)')" = 0 ] && ok || bad "duplicate findings: $(sort r.md | uniq -d | grep '^system(1)' | head -2)"
# disk of a folder made here
mkdir -p d/big d/small; head -c 3000000 /dev/zero > d/big/f.bin; echo x > d/small/f.txt; php "$ST" disk d dk.md >/dev/null; has "## Biggest folders" dk.md && grep -q "| .* | .*d/big |" dk.md && ok || bad "disk: $(sed -n 8,16p dk.md)"
php "$ST" disk nope dk2.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing folder was not refused"
php "$ST" disk /etc/hostname dk3.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a file given as the folder was not refused"
# ports: a listener started here, on every interface, then on a risky port
PORT=$((20000 + RANDOM % 20000)); php -S 0.0.0.0:$PORT -t "$T" >/dev/null 2>&1 & LP=$!; sleep 1
php "$ST" ports p.md >/dev/null; grep -qE "^\| (0\.0\.0\.0|\*) \| $PORT \|" p.md && ok || bad "the listener on port $PORT is not listed: $(grep -c . p.md) lines"
grep -E "\| $PORT \|" p.md | grep -q "| yes |" && ok || bad "a 0.0.0.0 listener must be marked open to the network"
kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=""
if ! ss -H -ltn | grep -q ":11211 "; then php -S 0.0.0.0:11211 -t "$T" >/dev/null 2>&1 & LP=$!; sleep 1; php "$ST" ports p2.md >/dev/null; has "port 11211 (memcached) listens on" p2.md && ok || bad "a memcached port open to the network must warn: $(grep Warning p2.md | head -2)"; kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=""; fi
PORT2=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT2 -t "$T" >/dev/null 2>&1 & LP=$!; sleep 1; php "$ST" ports p3.md >/dev/null; grep -E "\| 127.0.0.1 \| $PORT2 \|" p3.md | grep -q "no (this machine only)" && ok || bad "a 127.0.0.1 listener must be marked this machine only"; kill $LP 2>/dev/null; wait $LP 2>/dev/null; LP=""
# services
if command -v systemctl >/dev/null 2>&1; then
  php "$ST" services sv.md >/dev/null 2>&1; has "## Failed units" sv.md && ok || bad "services: $(head -5 sv.md)"
  php "$ST" services units=ssh,nonexistent-unit-xyz sv2.md >/dev/null 2>&1; has "| nonexistent-unit-xyz |" sv2.md && has "| ssh |" sv2.md && ok || bad "named units: $(sed -n 3,14p sv2.md)"
  php "$ST" services 'units=a;rm -rf /' sv3.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a unit name with shell characters was not refused"
fi
# logs: a file made here
printf 'Oct 10 17:01:01 host kernel: Out of memory: Killed process 1234 (ollama)\nOct 10 17:01:02 host sshd[99]: Failed password for invalid user admin from 10.0.0.5 port 2222\nOct 10 17:01:03 host sshd[99]: Failed password for invalid user admin from 10.0.0.6 port 2223\nOct 10 17:02:00 host app[1]: ERROR connection refused to 10.1.1.1:5432\nOct 10 17:02:05 host app[1]: ERROR connection refused to 10.1.1.2:5432\nOct 10 17:03:00 host kernel: EXT4-fs error (device sda1)\nOct 10 17:04:00 host app[1]: all fine\n' > log.txt
php "$ST" logs log.txt lg.md >/dev/null; has "- out of memory / OOM killer: 1 line(s)" lg.md && has "- disk or I/O error: 1 line(s)" lg.md && has "- authentication failures: 2 line(s)" lg.md && ok || bad "known trouble: $(sed -n 8,16p lg.md)"
has "- 2 x  app[N]: ERROR connection refused to IP:N" lg.md && has "- 2 x  sshd[N]: Failed password for invalid user admin from IP port N" lg.md && ok || bad "repeated messages with numbers masked: $(sed -n 16,24p lg.md)"
has "system(1) Warning: out of memory / OOM killer: 1 line(s) in log.txt" lg.md && ok || bad "an OOM line must be a warning"
has "From Oct 10 17:01:01 to Oct 10 17:04:00" lg.md && ok || bad "the time span"
php "$ST" logs nope.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing log was not refused"
php "$ST" logs "$T" x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder as a log was not refused"
# journal: only when this account may read it
php "$ST" journal j.md >/dev/null 2>j.err; if [ $? = 0 ]; then has "# Errors since boot" j.md && ok || bad "journal output"; else grep -q "cannot read the journal" j.err && ok || bad "journal refusal must say why: $(cat j.err)"; fi
# usage, guard, definitions
php "$ST" frob x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
head -20 "$ST" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/sys_tool (report|disk|services|ports|logs|journal) ~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/sysadmin.json" > pc 2>&1; [ "$(cat pc)" = 6 ] && ok || bad "sysadmin.json presets: $(cat pc)"
jq -e '[.presets[]|select(.optional_input=="/")|.id]|sort == ["disk","journal","ports","report","services"]' "$ROOT/cockpit_app/tools_builtins/sysadmin.json" >/dev/null && ok || bad "the presets that need no input must default it to /"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/system-administration.json")" = sysadmin ] && ok || bad "the kind does not name the tool"
echo "sysadmin_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
