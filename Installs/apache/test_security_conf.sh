#!/usr/bin/env bash
# =============================================================================
# test_security_conf.sh — prove cockpit-security.conf closes what it claims to, and nothing more.
#
# Starts a throwaway Apache AS THE CURRENT USER on a high port (no root, the real
# server is not touched) over a scratch copy of the app tree with the same
# Directory defaults as Debian's apache2.conf (Options Indexes, AllowOverride None).
# Runs twice: WITHOUT the conf (the leak must show — otherwise the test proves
# nothing) and WITH it (every leak closed, every legitimate URL still 200).
#   bash Installs/apache/test_security_conf.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/../../cockpit_app"
MODS=/usr/lib/apache2/modules
command -v apache2 >/dev/null 2>&1 || { echo "apache2 not installed — cannot run"; exit 2; }
[ -d "$MODS" ] || { echo "$MODS not found (Debian layout needed for this test)"; exit 2; }
T="$(mktemp -d)"; PORT=18099; PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/www/html" "$T/run" "$T/log"
for V in cockpit cockpit-v1; do
    mkdir -p "$T/www/html/$V"
    cp -r "$APP"/css "$APP"/js "$APP"/index.html "$APP"/prism.js "$T/www/html/$V/" 2>/dev/null
    mkdir -p "$T/www/html/$V/queue" "$T/www/html/$V/responses" "$T/www/html/$V/assets"
    echo 'secret agent reply' > "$T/www/html/$V/responses/claude_abc123.out"
    echo 'secret prompt'      > "$T/www/html/$V/queue/job_1.json"
    echo '{"home":"/home/x"}' > "$T/www/html/$V/paths.json"
    echo '{"ts":1}'           > "$T/www/html/$V/ollama_usage.jsonl"
    echo '{}'                 > "$T/www/html/$V/project_state.json"
    echo '{}'                 > "$T/www/html/$V/workers_quotas.json"
    echo '{"build":1}'        > "$T/www/html/$V/integrity.json"
    echo 'x'                  > "$T/www/html/$V/scheduled_jobs.lock"
done
echo 'unrelated' > "$T/www/html/other.txt"; mkdir -p "$T/www/html/pub"; echo hi > "$T/www/html/pub/a.txt"   # not Cockpit: must stay listable

PASS=0; FAIL=0
run() {   # run <with|without>
    local conf="$T/apache.conf" inc=""
    [ "$1" = with ] && inc="Include $HERE/cockpit-security.conf"
    cat > "$conf" <<CONF
ServerRoot "$T"
PidFile $T/run/apache.pid
Listen 127.0.0.1:$PORT
ErrorLog $T/log/error.log
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule authz_host_module $MODS/mod_authz_host.so
LoadModule dir_module $MODS/mod_dir.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule autoindex_module $MODS/mod_autoindex.so
LoadModule alias_module $MODS/mod_alias.so
LoadModule headers_module $MODS/mod_headers.so
TypesConfig /etc/mime.types
DocumentRoot "$T/www/html"
<Directory />
    AllowOverride None
    Require all denied
</Directory>
<Directory "$T/www/">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
$inc
CONF
    apache2 -f "$conf" -t >"$T/log/t.out" 2>&1 || { echo "config test FAILED:"; cat "$T/log/t.out"; exit 1; }
    apache2 -f "$conf" -k start >"$T/log/start.out" 2>&1
    for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
    PID="$(cat "$T/run/apache.pid" 2>/dev/null)"
}
stop() { apache2 -f "$T/apache.conf" -k stop >/dev/null 2>&1; for i in $(seq 1 30); do [ -f "$T/run/apache.pid" ] || break; sleep 0.1; done; PID=""; }
code() { curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$1"; }
expect() {   # expect <label> <path> <code...>
    local label="$1" path="$2"; shift 2; local got; got="$(code "$path")"
    for want in "$@"; do [ "$got" = "$want" ] && { echo "  PASS  $label  ($path -> $got)"; PASS=$((PASS+1)); return; }; done
    echo "  FAIL  $label  ($path -> $got, wanted $*)"; FAIL=$((FAIL+1))
}

echo "== the installer's inline copy must say the same as cockpit-security.conf"
_directives() { grep -vE '^\s*(#|$)'; }
INLINE="$(sed -n "/^_security_conf_body()/,/^}/p" "$HERE/../install_cockpit.sh" | sed -n "/<<'SECCONF'/,/^SECCONF/p" | sed '1d;$d' | _directives)"
FILE="$(_directives < "$HERE/cockpit-security.conf")"
if [ -n "$INLINE" ] && [ "$INLINE" = "$FILE" ]; then echo "  PASS  install_cockpit.sh and cockpit-security.conf have identical directives"; PASS=$((PASS+1))
else echo "  FAIL  the inline copy in install_cockpit.sh drifted from cockpit-security.conf"; FAIL=$((FAIL+1)); fi

echo "== WITHOUT the conf (the leak must be visible, or this test proves nothing)"
run without
LEAK=0
for p in /cockpit/responses/ /cockpit/responses/claude_abc123.out /cockpit/queue/ /cockpit/paths.json /cockpit/ollama_usage.jsonl /cockpit/js/; do
    [ "$(code $p)" = 200 ] && LEAK=$((LEAK+1))
done
[ $LEAK -ge 5 ] && { echo "  PASS  baseline reproduces the leak ($LEAK of 6 probes answered 200)"; PASS=$((PASS+1)); } || { echo "  FAIL  baseline did not leak ($LEAK of 6) — the test setup is wrong"; FAIL=$((FAIL+1)); }
stop

echo "== WITH cockpit-security.conf"
run with
for V in cockpit cockpit-v1; do
    expect "$V: responses/ listing closed"          /$V/responses/ 403
    expect "$V: a response file is not served"      /$V/responses/claude_abc123.out 403
    expect "$V: queue/ listing closed"              /$V/queue/ 403
    expect "$V: a queued job is not served"         /$V/queue/job_1.json 403
    expect "$V: paths.json is not served"           /$V/paths.json 403
    expect "$V: usage log (.jsonl) is not served"   /$V/ollama_usage.jsonl 403
    expect "$V: project_state.json is not served"   /$V/project_state.json 403
    expect "$V: workers_quotas.json is not served"  /$V/workers_quotas.json 403
    expect "$V: lock files are not served"          /$V/scheduled_jobs.lock 403
    expect "$V: folder listing of js/ is off"       /$V/js/ 403
    expect "$V: folder listing of assets/ is off"   /$V/assets/ 403
    expect "$V: the app page still loads"           /$V/index.html 200
    expect "$V: a script still loads"               /$V/prism.js 200
    expect "$V: integrity.json still loads (public build manifest)" /$V/integrity.json 200
done
expect "something that is not Cockpit keeps its listing"   /pub/ 200
expect "...and its files"                                  /pub/a.txt 200
JS="$(cd "$APP/js" && ls | head -1)"
[ -n "$JS" ] && expect "a real js subfolder file still loads" "/cockpit/js/$(cd "$APP/js" && find . -name '*.js' | head -1 | sed 's|^\./||')" 200
stop
echo; echo "security conf: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
