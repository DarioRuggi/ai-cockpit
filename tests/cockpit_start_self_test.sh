#!/usr/bin/env bash
# cockpit_start_self_test.sh — scripts/cockpit_start.sh --self: which address the window opens, which files the mode leaves behind, and the
# fall-back to Apache when something it needs is missing. Only the self_prepare block is run (extracted from the script, with stubs); the
# rest of the launcher starts windows and sessions and is exercised by hand.   bash tests/cockpit_start_self_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SC="$ROOT/scripts/cockpit_start.sh"
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash -n "$SC" && ok || bad "the launcher has a syntax error"
# the block between its two marker comments
awk '/^# ── Self-contained mode/{p=1} p{print} /^self_prepare$/{exit}' "$SC" > "$T/block.sh"
[ -s "$T/block.sh" ] && grep -q '^self_prepare$' "$T/block.sh" && ok || bad "could not extract the self-contained block"
mkdir -p "$T/bin" "$T/data" "$T/home"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/aicserver"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/aicsupervisor"; printf '#!/bin/sh\nexit 0\n' > "$T/bin/php-cgi"; chmod +x "$T"/bin/*
# run EDITION SELF [fileContent] ...  -> prints "APP_URL|SELF_WEB|SELF_PORT"
run() {   # run EDITION SELF [aicserver-bin] [use_aicserver content]
    rm -rf "$T/data"; mkdir -p "$T/data"; [ -n "${4:-}" ] && printf '%s' "$4" > "$T/data/use_aicserver"
    ( EDITION="$1"; SELF_WEB="$2"; APP_URL="http://localhost/x/"; COCKPIT_DATA_DIR="$T/data"; SUP_BIN="$T/bin/aicsupervisor"
      COCKPIT_AICSERVER_BIN="${3:-$T/bin/aicserver}"; PATH="$T/bin:/usr/bin:/bin"; . "$T/block.sh" >/dev/null 2>&1
      echo "$APP_URL|$SELF_WEB|$SELF_PORT" )
}
[ "$(run v2 1)" = "http://127.0.0.1:8081/cockpit/|1|8081" ] && ok || bad "V2 self: $(run v2 1)"
[ "$(run v1 1)" = "http://127.0.0.1:8082/cockpit-v1/|1|8082" ] && ok || bad "V1 self: $(run v1 1)"
[ "$(run v2 1 '' 9090)" = "http://127.0.0.1:9090/cockpit/|1|9090" ] && ok || bad "a port in the file: $(run v2 1 '' 9090)"
[ "$(run v2 1 '' 80)" = "http://127.0.0.1:8081/cockpit/|1|8081" ] && ok || bad "a privileged port is ignored: $(run v2 1 '' 80)"
[ "$(run v2 0)" = "http://localhost/x/|0|" ] && ok || bad "without --self nothing changes: $(run v2 0)"
run v2 1 >/dev/null; [ -f "$T/data/use_supervisor" ] && [ -f "$T/data/use_aicserver" ] && ok || bad "the mode's two files are not left behind"
[ "$(run v2 1 "$T/bin/missing")" = "http://localhost/x/|0|" ] && ok || bad "no aicserver: must fall back to Apache: $(run v2 1 "$T/bin/missing")"
# no php-cgi on the PATH
( EDITION=v2; SELF_WEB=1; APP_URL="http://localhost/x/"; COCKPIT_DATA_DIR="$T/data"; SUP_BIN="$T/bin/aicsupervisor"; COCKPIT_AICSERVER_BIN="$T/bin/aicserver"; PATH="/nonexistent"; . "$T/block.sh" >/dev/null 2>&1; [ "$SELF_WEB" = 0 ] && [ "$APP_URL" = "http://localhost/x/" ] ) && ok || bad "no php-cgi: must fall back to Apache"
# the Apache check is skipped in self mode, and the argument is parsed
grep -q 'if \[ "\$SELF_WEB" != "1" \] && ! systemctl is-active' "$SC" && ok || bad "Apache is still started in self mode"
grep -q -- '--self) SELF_WEB=1; shift ;;' "$SC" && ok || bad "--self is not parsed"
echo "cockpit_start_self_test: $n passed, $fails failed"; [ "$fails" = 0 ]
