#!/bin/bash
# internal_auth_http_test.sh — the real pages, served by php -S from a scratch copy with its own data folder and users.json:
# search/workers/tools/library answer the loop's credential, nothing else does, and a PROPOSE from crud_cli.php lands in the right person's folder.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S=$(mktemp -d); PASS=0; FAIL=0; SRV=""
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; rm -rf "$S"' EXIT
ok() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL $1: wanted $3 got $2"; fi; }
mkdir -p "$S/web" "$S/data/users/dario" "$S/proj"
cp -r "$ROOT/cockpit_app/." "$S/web/"
printf '{"cockpit_data":"%s","projects_root":"%s"}' "$S/data" "$S/proj" > "$S/web/paths.json"
printf '[{"id":1,"username":"dario","hash":"x","role":"admin"},{"id":2,"username":"viewer1","hash":"x","role":"viewer"}]' > "$S/data/users.json"
KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'); printf '%s\n' "$KEY" > "$S/data/internal_key"
PORT=$((20000 + RANDOM % 20000))
HOME="$S/home" COCKPIT_DATA_ROOT="$S/data" php -S 127.0.0.1:$PORT -t "$S/web" >"$S/srv.log" 2>&1 & SRV=$!
for i in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/auth.php" && break; sleep 0.2; done
B="http://127.0.0.1:$PORT"
code() { curl -s -o "$S/body" -w '%{http_code}' --max-time 15 "$@"; }
H=(-H "X-Cockpit-Internal: $KEY" -H "X-Cockpit-User: dario")
# which data root does paths.php use here? the shared one holds users.json — find out from a real call
R=$(code "${H[@]}" "$B/workers.php?action=models"); ok "workers models with key" "$([ "$R" != 401 ] && echo notauth || echo 401)" notauth
ok "workers models without key" "$(code "$B/workers.php?action=models")" 401
ok "wrong key" "$(code -H 'X-Cockpit-Internal: nope' -H 'X-Cockpit-User: dario' "$B/workers.php?action=models")" 401
ok "tools presets with key" "$([ "$(code "${H[@]}" "$B/tools.php?action=presets")" != 401 ] && echo notauth)" notauth
ok "search with key" "$([ "$(code "${H[@]}" "$B/search.php?action=search&q=x")" != 401 ] && echo notauth)" notauth
ok "proposal_add with key" "$([ "$(code "${H[@]}" -X POST -d '{"action":"proposal_add","propose_kind":"snippet","proposer":"t","project":"p","payload":{"title":"t"}}' "$B/library.php")" != 401 ] && echo notauth)" notauth
ok "other action on library refused" "$(code "${H[@]}" "$B/library.php?action=list")" 401
ok "other page refused (files.php)" "$(code "${H[@]}" "$B/files.php?action=list")" 401
ok "other page refused (themes.php)" "$(code "${H[@]}" "$B/themes.php?action=list")" 401
ok "unknown user refused" "$(code -H "X-Cockpit-Internal: $KEY" -H 'X-Cockpit-User: ghost' "$B/workers.php?action=models")" 401
ok "proxy header refused" "$(code "${H[@]}" -H 'X-Forwarded-For: 1.2.3.4' "$B/workers.php?action=models")" 401
printf '%%%%PROPOSE:snippet%%%%\ntitle: hello snip\nlang: bash\ncontent: echo hi\n%%%%END%%%%\n' > "$S/resp.txt"
COCKPIT_BASE_URL="$B" COCKPIT_INTERNAL_KEY="$KEY" COCKPIT_INTERNAL_USER=dario HOME="$S/home" php "$ROOT/scripts/crud_cli.php" "$S/proj" "$S/resp.txt" claude proj1 >"$S/crud.out" 2>&1
ok "PROPOSE through crud_cli lands in the person's folder" "$(grep -c 'hello snip' "$S/data/users/dario/proposals.json" 2>/dev/null)" 1
COCKPIT_BASE_URL="$B" HOME="$S/home" php "$ROOT/scripts/crud_cli.php" "$S/proj" "$S/resp.txt" claude proj1 >/dev/null 2>&1
ok "PROPOSE without the credential adds nothing more" "$(grep -c 'hello snip' "$S/data/users/dario/proposals.json" 2>/dev/null)" 1
echo "internal_auth_http_test: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
