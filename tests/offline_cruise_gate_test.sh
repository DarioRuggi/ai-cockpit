#!/usr/bin/env bash
# Cruise and AutoCognition switch off while the account server is unreachable (entitle.php cockpit_account_reachable), and only those.
set -u
cd "$(dirname "$0")/../cockpit_app" || exit 1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; pass=0; fail=0
chk() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL $1: got $3 want $2"; fi; }
run() { # $1 account json  $2 cap -> prints 1/0
  printf '%s' "$1" > "$T/saas_account.json"
  php -r '$GLOBALS["PATHS"]=["cockpit_data"=>$argv[1]]; putenv("COCKPIT_EDITION=v2"); require "entitle.php"; echo cap_allowed($argv[2])?1:0;' "$T" "$2" 2>/dev/null; }
EDQ=$(php -r 'require "edition.php"; echo ed_allows("saas")?1:0;' 2>/dev/null)
if [ "$EDQ" != 1 ]; then echo "SKIP: this tree is not the Full edition (no saas)"; exit 0; fi
now=$(date -Iseconds); old=$(date -Iseconds -d '10 days ago')
A='"signed_in":true,"license_key":"k","tier":"pro","can_cruise":true,"can_cognition":true,"can_everywhere":true'
chk "online cruise" 1 "$(run "{$A,\"offline\":false,\"validated_at\":\"$now\"}" cruise)"
chk "online cognition" 1 "$(run "{$A,\"offline\":false,\"validated_at\":\"$now\"}" cognition)"
chk "offline cruise" 0 "$(run "{$A,\"offline\":true,\"validated_at\":\"$now\"}" cruise)"
chk "offline cognition" 0 "$(run "{$A,\"offline\":true,\"validated_at\":\"$now\"}" cognition)"
chk "offline beta cruise" 0 "$(run "{$A,\"beta\":true,\"offline\":true,\"validated_at\":\"$now\"}" cruise)"
chk "stale 10d cruise" 0 "$(run "{$A,\"offline\":false,\"validated_at\":\"$old\"}" cruise)"
chk "offline everywhere (untouched here)" 1 "$(run "{$A,\"offline\":true,\"validated_at\":\"$now\"}" everywhere)"
echo "offline_cruise_gate_test: $pass passed, $fail failed"; [ $fail = 0 ]
