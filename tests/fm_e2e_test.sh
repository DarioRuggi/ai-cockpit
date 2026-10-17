#!/bin/bash
# fm_e2e_test.sh — the file window and command window end to end: the engine's socket service (aicengine serve) and the real fm.php / cmd.php on a
# scratch php -S server. Per-user Public, read-only Projects, upload in chunks, ranged download that is never served as a page, commands under the
# sandbox, and the message when the service is down.
#   bash tests/fm_e2e_test.sh     ENGINE=<aicengine>     Exit 0 = pass; SKIPPED without the engine (with fs/exec), jq, php or curl.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
for c in jq php curl; do command -v $c >/dev/null 2>&1 || { echo "fm_e2e_test: $c is needed - SKIPPED"; exit 0; }; done
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " exec" || { echo "fm_e2e_test: no engine with fs/exec - SKIPPED"; exit 0; }
S=$(mktemp -d); SRV=""; ES=""
trap '[ -n "$SRV" ] && kill $SRV 2>/dev/null; [ -n "$ES" ] && kill $ES 2>/dev/null; rm -rf "${S:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
mkdir -p "$S/web" "$S/data/supervisor" "$S/proj"
cp -r "$ROOT/cockpit_app/." "$S/web/"
printf '{"cockpit_data":"%s","projects_root":"%s"}' "$S/data" "$S/proj" > "$S/web/paths.json"
echo '[]' > "$S/data/users.json"
mkdir -p "$S/proj/alpha"; echo "project file" > "$S/proj/alpha/notes.txt"
start_engine() { "$ENG" serve --socket "$S/data/supervisor/engine.sock" --state "$S/data/supervisor/engine_state" --token-file "$S/data/supervisor/engine_token" --socket-mode 600 --allowed-roots "$S/proj" >"$S/engine.log" 2>&1 & ES=$!
    for i in $(seq 40); do [ -S "$S/data/supervisor/engine.sock" ] && break; sleep 0.2; done; }
start_engine
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT -t "$S/web" >"$S/php.log" 2>&1 & SRV=$!
for i in $(seq 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/auth.php" && break; sleep 0.2; done
B="http://127.0.0.1:$PORT"
post() { curl -s -X POST -H 'Content-Type: application/json' -d "$2" "$B/$1"; }
fm() { post fm.php "$1"; }
b64() { printf '%s' "$1" | base64 -w0; }

r=$(curl -s "$B/fm.php?action=zones"); [ "$(echo "$r" | jq -r .engine)" = true ] && ok "the page reaches the engine service" || bad "zones: $r"
[ "$(echo "$r" | jq -r '[.zones[].name]|join(",")')" = "public,projects" ] && [ "$(echo "$r" | jq -r '.zones[0].rw')" = true ] && [ "$(echo "$r" | jq -r '.zones[1].rw')" = false ] && ok "zones: Public read-write, Projects read-only" || bad "zones shape"
[ "$(echo "$r" | jq -r .sandbox)" = true ] || echo "  (this kernel has no Landlock: the command checks below are skipped)"
[ "$(fm '{"action":"mkdir","path":"public:docs"}' | jq -r .ok)" = true ] && [ -d "$S/proj/Public/docs" ] && ok "a new folder lands in <projects root>/Public" || bad "mkdir"
[ "$(fm '{"action":"newfile","path":"public:docs/a.txt"}' | jq -r .ok)" = true ] && ok "a new file" || bad "newfile"
fm "{\"action\":\"write\",\"path\":\"public:docs/up.txt\",\"offset\":0,\"data_b64\":\"$(b64 'first-')\"}" >/dev/null; fm "{\"action\":\"write\",\"path\":\"public:docs/up.txt\",\"offset\":6,\"data_b64\":\"$(b64 'second')\"}" >/dev/null
[ "$(cat "$S/proj/Public/docs/up.txt")" = "first-second" ] && ok "an upload in two chunks" || bad "upload chunks: $(cat "$S/proj/Public/docs/up.txt")"
r=$(curl -s "$B/fm.php?action=list&path=public:docs"); [ "$(echo "$r" | jq -r '[.entries[].name]|sort|join(",")')" = "a.txt,up.txt" ] && ok "list" || bad "list: $r"
r=$(curl -s "$B/fm.php?action=list&path=projects:alpha"); [ "$(echo "$r" | jq -r '.entries[0].name')" = "notes.txt" ] && ok "the Projects area can be listed" || bad "projects list: $r"
[ "$(fm '{"action":"newfile","path":"projects:alpha/new.txt"}' | jq -r .ok)" = false ] && [ ! -e "$S/proj/alpha/new.txt" ] && ok "nothing can be created in Projects" || bad "write to projects"
[ "$(fm '{"action":"delete","path":"projects:alpha/notes.txt"}' | jq -r .ok)" = false ] && [ -f "$S/proj/alpha/notes.txt" ] && ok "nothing can be deleted in Projects" || bad "delete in projects"
[ "$(fm '{"action":"copy","path":"projects:alpha/notes.txt","to_dir":"public:docs"}' | jq -r .ok)" = true ] && [ "$(cat "$S/proj/Public/docs/notes.txt")" = "project file" ] && ok "copy from Projects into Public" || bad "copy in"
[ "$(fm '{"action":"rename","path":"public:docs/a.txt","name":"b.txt"}' | jq -r .ok)" = true ] && [ "$(fm '{"action":"mkdir","path":"public:more"}' | jq -r .ok)" = true ] && [ "$(fm '{"action":"move","path":"public:docs/b.txt","to_dir":"public:more"}' | jq -r .ok)" = true ] && [ -f "$S/proj/Public/more/b.txt" ] && ok "rename and move" || bad "rename/move"
[ "$(fm '{"action":"list","path":"public:../alpha"}' | jq -r .ok)" = false ] && ok '".." is refused through the page too' || bad "dotdot"
# download
printf 'abcdefghij' > "$S/proj/Public/docs/ten.txt"
[ "$(curl -s "$B/fm.php?action=download&path=public:docs/ten.txt")" = "abcdefghij" ] && ok "download a whole file" || bad "download"
[ "$(curl -s -H 'Range: bytes=2-5' "$B/fm.php?action=download&path=public:docs/ten.txt")" = "cdef" ] && ok "a ranged download (media seeking)" || bad "range"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=2-5' "$B/fm.php?action=download&path=public:docs/ten.txt")" = 206 ] && ok "...answered 206" || bad "206"
[ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=50-60' "$B/fm.php?action=download&path=public:docs/ten.txt")" = 416 ] && ok "a range past the end answers 416" || bad "416"
h=$(curl -s -D - -o /dev/null "$B/fm.php?action=download&path=public:docs/ten.txt")
echo "$h" | grep -qi "content-disposition: attachment" && echo "$h" | grep -qi "content-security-policy: sandbox" && echo "$h" | grep -qi "x-content-type-options: nosniff" && ok "a download is an attachment, sandboxed and never sniffed" || bad "download headers: $h"
echo '<script>alert(1)</script>' > "$S/proj/Public/docs/evil.html"
h=$(curl -s -D - -o /dev/null "$B/fm.php?action=download&path=public:docs/evil.html&inline=1"); echo "$h" | grep -qi "content-type: text/plain" && echo "$h" | grep -qi "sandbox" && ok "an HTML file is shown as plain text, sandboxed (no stored XSS)" || bad "html served as page: $h"
head -c 3000000 /dev/urandom > "$S/proj/Public/docs/big.bin"; [ "$(curl -s "$B/fm.php?action=download&path=public:docs/big.bin" | md5sum | cut -c1-32)" = "$(md5sum < "$S/proj/Public/docs/big.bin" | cut -c1-32)" ] && ok "a 3 MB file downloads intact (several engine reads)" || bad "big download"
# trash and areas admin
fm '{"action":"delete","path":"public:docs/evil.html"}' >/dev/null; [ ! -e "$S/proj/Public/docs/evil.html" ] && [ -n "$(ls "$S/proj/Public/.trash")" ] && ok "delete goes to the trash" || bad "trash"
mkdir -p "$S/extra"; echo "e" > "$S/extra/e.txt"
[ "$(fm "{\"action\":\"areas_set\",\"areas\":[{\"name\":\"extra\",\"path\":\"$S/extra\"}]}" | jq -r .ok)" = true ] && [ "$(curl -s "$B/fm.php?action=list&path=extra:" | jq -r '.entries[0].name')" = "e.txt" ] && ok "an admin can add a read-only area (owned by this account)" || bad "areas_set"
[ "$(fm '{"action":"areas_set","areas":[{"name":"public","path":"/x"}]}' | jq -r .ok)" = false ] && [ "$(fm '{"action":"areas_set","areas":[{"name":"bad","path":"/x/../etc"}]}' | jq -r .ok)" = false ] && ok "reserved names and .. paths are refused as areas" || bad "areas validation"
# commands
ci=$(curl -s "$B/cmd.php?action=info"); if [ "$(echo "$ci" | jq -r .sandbox)" = true ]; then
  r=$(post cmd.php '{"action":"run","cmd":"echo hello; pwd"}'); [ "$(echo "$r" | jq -r ".output|split(\"\\n\")[0]")" = hello ] && [ "$(echo "$r" | jq -r ".output|split(\"\\n\")[1]")" = "$(realpath "$S/proj/Public")" ] && ok "a command runs in the person's Public folder" || bad "run: $r"
  post cmd.php "{\"action\":\"run\",\"cmd\":\"echo x > $S/proj/alpha/evil.txt\"}" >/dev/null; [ ! -e "$S/proj/alpha/evil.txt" ] && ok "the command cannot write into the project folders" || bad "cmd wrote to projects"
  post cmd.php '{"action":"run","cmd":"echo made > fromcmd.txt"}' >/dev/null; [ "$(cat "$S/proj/Public/fromcmd.txt")" = made ] && ok "...but can write in Public (and the file window sees it)" || bad "cmd write public"
fi
# the service is down
kill $ES 2>/dev/null; wait $ES 2>/dev/null; ES=""; rm -f "$S/data/supervisor/engine.sock"
r=$(curl -s "$B/fm.php?action=list&path=public:"); [ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -qi "not running" && ok "with the service down the page says so in words" || bad "down message: $r"
r=$(post cmd.php '{"action":"run","cmd":"echo hi"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -qi "not running" && ok "the command window says so too" || bad "cmd down: $r"
[ "$(curl -s "$B/fm.php?action=zones" | jq -r .engine)" = false ] && ok "zones reports the engine as down" || bad "zones down"
echo "fm_e2e_test: $n passed, $fails failed"; [ "$fails" = 0 ]
