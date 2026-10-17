#!/bin/bash
# fs_test.sh — the file window's operations (aicengine fs): the Public zone does everything, areas are read-only (copy out only), nothing
# follows a symbolic link, ".." is refused, deletes go to the trash, every change is audited.
#   bash tests/fs_test.sh     ENGINE=<aicengine>      Exit 0 = pass; SKIPPED without an engine with `fs`, or without jq.
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
command -v jq >/dev/null 2>&1 || { echo "fs_test: jq is needed - SKIPPED"; exit 0; }
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " fs" || { echo "fs_test: no engine with 'fs' - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
PUB="$T/Public"; AREA="$T/area"; OUT="$T/outside"; AUD="$T/audit.jsonl"
mkdir -p "$AREA/docs/sub" "$OUT/secretdir"; echo "area file" > "$AREA/docs/readme.txt"; echo "deep" > "$AREA/docs/sub/deep.txt"; echo "TOPSECRET" > "$OUT/secret.txt"; echo "TOPSECRET2" > "$OUT/secretdir/s2.txt"
ZONES=$(jq -n --arg p "$PUB" --arg a "$AREA" --arg e /etc '[{name:"public",path:$p,rw:true},{name:"area",path:$a,rw:false},{name:"etc",path:$e,rw:false}]')
# fsr op key=value ...   (string values; use fsj for raw JSON)
fsr() { local op="$1"; shift; local j; j=$(jq -n --arg op "$op" --argjson z "$ZONES" --arg au "$AUD" '{op:$op,zones:$z,user:"tester",audit:$au}'); local kv
    for kv in "$@"; do case "${kv%%=*}" in offset|length) j=$(printf "%s" "$j" | jq --arg k "${kv%%=*}" --argjson v "${kv#*=}" ".[\$k]=\$v");; *) j=$(printf "%s" "$j" | jq --arg k "${kv%%=*}" --arg v "${kv#*=}" ".[\$k]=\$v");; esac; done
    printf '%s' "$j" > "$T/req.json"; "$ENG" fs --request-file "$T/req.json"; }
good() { [ "$(fsr "$@" | jq -r .ok)" = true ]; }
refused() { local r; r=$(fsr "$@"); [ "$(printf '%s' "$r" | jq -r .ok)" = false ]; }
errof() { fsr "$@" | jq -r '.error // ""'; }
b64() { printf '%s' "$1" | base64 -w0; }

# the zones themselves
r=$(fsr list path=public:); [ "$(echo "$r" | jq -r .ok)" = true ] && [ -d "$PUB" ] && ok "Public is created on first use" || bad "Public not created"
[ "$(echo "$r" | jq -r .rw)" = true ] && ok "Public is read-write" || bad "Public rw flag"
[ "$(fsr list path=area: | jq -r .rw)" = false ] && ok "an owned area is listed, read-only" || bad "area rw flag"
refused list path=etc: && ok "an area not owned by this account is not offered (/etc)" || bad "/etc was offered"
refused list path=nozone: && ok "an unknown zone is refused" || bad "unknown zone"

# Public: everything works
good mkdir path=public:docs && ok "new folder" || bad "mkdir"
good newfile path=public:docs/a.txt && ok "new file" || bad "newfile"
refused newfile path=public:docs/a.txt && ok "new file over an existing one is refused" || bad "newfile overwrite"
[ "$(errof newfile path=public:docs/a.txt)" = "a.txt: already exists" ] && ok "...and the reason says so (the C library's error, not a stale one)" || bad "errno text: $(errof newfile path=public:docs/a.txt)"
[ "$(errof read path=public:docs/none.txt)" = "none.txt: not found" ] && ok "a missing file says not found" || bad "not found text"
[ "$(errof rename path=public:docs/a.txt name=a.txt)" = "rename: already exists" ] && ok "a rename onto itself or an existing name says already exists" || bad "rename text: $(errof rename path=public:docs/a.txt name=a.txt)"
refused mkdir path=public:docs && ok "new folder over an existing one is refused" || bad "mkdir exists"
good write path=public:docs/a.txt data_b64="$(b64 'hello world')" && ok "write" || bad "write"
r=$(fsr read path=public:docs/a.txt); [ "$(echo "$r" | jq -r .data_b64 | base64 -d)" = "hello world" ] && [ "$(echo "$r" | jq -r .eof)" = true ] && ok "read it back" || bad "read back"
r=$(fsr read path=public:docs/a.txt offset=6 length=3); [ "$(echo "$r" | jq -r .data_b64 | base64 -d)" = "wor" ] && [ "$(echo "$r" | jq -r .eof)" = false ] && ok "read with offset and length (not at the end)" || bad "read range"
j=$(jq -n --argjson z "$ZONES" '{op:"write",zones:$z,path:"public:docs/chunks.bin",offset:0,data_b64:"QUJD"}'); echo "$j" > "$T/req.json"; "$ENG" fs --request-file "$T/req.json" >/dev/null
j=$(jq -n --argjson z "$ZONES" '{op:"write",zones:$z,path:"public:docs/chunks.bin",offset:3,data_b64:"REVG"}'); echo "$j" > "$T/req.json"; "$ENG" fs --request-file "$T/req.json" >/dev/null
[ "$(cat "$PUB/docs/chunks.bin")" = "ABCDEF" ] && ok "an upload in two chunks (offset) is one file" || bad "chunked write: $(cat "$PUB/docs/chunks.bin")"
r=$(fsr stat path=public:docs/a.txt); [ "$(echo "$r" | jq -r .stat.type)" = file ] && [ "$(echo "$r" | jq -r .stat.size)" = 11 ] && ok "stat: type and size" || bad "stat"
r=$(fsr list path=public:docs); [ "$(echo "$r" | jq -r '[.entries[].name]|sort|join(",")')" = "a.txt,chunks.bin" ] && ok "list shows the entries" || bad "list: $r"
good rename path=public:docs/a.txt name="b file.txt" && [ -f "$PUB/docs/b file.txt" ] && ok "rename (a name with a space)" || bad "rename"
refused rename path=public:docs/b\ file.txt name=chunks.bin && ok "rename onto an existing name is refused" || bad "rename overwrite"
refused rename path=public:docs/chunks.bin name=../x && ok "a name with a slash is refused" || bad "rename slash"
refused rename path=public:docs/chunks.bin name=.. && ok "a name of .. is refused" || bad "rename .."
good mkdir path=public:other && good move path=public:docs/chunks.bin to_dir=public:other && [ -f "$PUB/other/chunks.bin" ] && [ ! -e "$PUB/docs/chunks.bin" ] && ok "move inside Public" || bad "move"
refused move path=public:docs to_dir=public:docs/ && ok "moving a folder into the folder it is in does nothing harmful" || true
good mkdir path=public:docs/inner && refused move path=public:docs to_dir=public:docs/inner && ok "moving a folder into itself is refused" || bad "move into itself"
good newfile path=public:other/chunks.bin 2>/dev/null; refused move path=public:docs/b\ file.txt to_dir=area:docs && ok "move out of Public into an area is refused" || bad "move to area"
refused move path=area:docs/readme.txt to_dir=public: && ok "move from an area is refused (it would delete there)" || bad "move from area"

# areas: read-only, copy out
r=$(fsr list path=area:docs); [ "$(echo "$r" | jq -r '[.entries[].name]|sort|join(",")')" = "readme.txt,sub" ] && ok "an area can be listed" || bad "area list"
[ "$(fsr read path=area:docs/readme.txt | jq -r .data_b64 | base64 -d)" = "area file" ] && ok "an area file can be read" || bad "area read"
refused mkdir path=area:docs/new && ok "no new folder in an area" || bad "area mkdir"
refused newfile path=area:docs/new.txt && ok "no new file in an area" || bad "area newfile"
refused write path=area:docs/readme.txt data_b64="$(b64 x)" && ok "no write in an area" || bad "area write"
refused rename path=area:docs/readme.txt name=z.txt && ok "no rename in an area" || bad "area rename"
refused delete path=area:docs/readme.txt && ok "no delete in an area" || bad "area delete"
[ "$(cat "$AREA/docs/readme.txt")" = "area file" ] && ok "the area file is untouched" || bad "area file changed"
refused copy path=public:docs/b\ file.txt to_dir=area:docs && ok "no copy into an area" || bad "copy into area"
good copy path=area:docs/readme.txt to_dir=public:other && [ "$(cat "$PUB/other/readme.txt")" = "area file" ] && ok "copy a file from an area into Public" || bad "copy file"
r=$(fsr copy path=area:docs/readme.txt to_dir=public:other); [ "$(echo "$r" | jq -r .name)" = "readme (2).txt" ] && [ -f "$PUB/other/readme (2).txt" ] && ok "a copy never overwrites: the name gets (2)" || bad "copy rename: $r"
good copy path=area:docs to_dir=public: && [ "$(cat "$PUB/docs (2)/sub/deep.txt" 2>/dev/null)" = "deep" ] || [ "$(cat "$PUB/docs/sub/deep.txt" 2>/dev/null)" = "deep" ] && ok "copy a whole folder tree" || bad "copy tree"
[ -f "$AREA/docs/readme.txt" ] && ok "the area original is still there after copying" || bad "area original gone"

# paths
refused list path=public:../outside && ok '".." is refused' || bad "dotdot"
refused read path=public:docs/../../outside/secret.txt && ok '".." in the middle is refused' || bad "dotdot middle"
refused read path="public:/etc/passwd" && ok "an absolute path is read as relative (and is not found), never as the real /etc" || bad "absolute"
refused read path=public:docs && ok "reading a folder is refused" || bad "read folder"
refused list path=nocolon && ok "a path without a zone is refused" || bad "nocolon"

# symbolic links: never followed
ln -s "$OUT" "$PUB/linkdir"; ln -s "$OUT/secret.txt" "$PUB/linkfile"; ln -s "$OUT/secret.txt" "$AREA/docs/arealink"
refused list path=public:linkdir && ok "a link to a folder is not entered (list)" || bad "list through link"
refused read path=public:linkdir/secret.txt && ok "a file behind a link-folder is not read" || bad "read through link"
refused write path=public:linkdir/new.txt data_b64="$(b64 x)" && [ ! -e "$OUT/new.txt" ] && ok "nothing is written through a link-folder" || bad "write through link"
refused mkdir path=public:linkdir/made && [ ! -e "$OUT/made" ] && ok "no folder is made through a link-folder" || bad "mkdir through link"
refused read path=public:linkfile && ok "a link to a file is not read" || bad "read link file"
refused write path=public:linkfile data_b64="$(b64 CHANGED)" && [ "$(cat "$OUT/secret.txt")" = "TOPSECRET" ] && ok "a link to a file is not written through" || bad "write link file"
refused read path=area:docs/arealink && ok "a link in an area is not followed either" || bad "area link"
r=$(fsr stat path=public:linkfile); [ "$(echo "$r" | jq -r .stat.type)" = link ] && [ "$(echo "$r" | jq -r .stat.link)" = "$OUT/secret.txt" ] && ok "stat reports a link as a link, with its target" || bad "stat link"
good copy path=public:linkfile to_dir=public:other && [ ! -e "$PUB/other/linkfile" ] && ok "a link is not copied" || bad "copy link"
good delete path=public:linkfile && [ -f "$OUT/secret.txt" ] && ok "deleting a link removes the link, never its target" || bad "delete link"
good delete path=public:linkdir && [ -d "$OUT/secretdir" ] && ok "deleting a link-folder leaves the folder it pointed to" || bad "delete linkdir"

# a swap race: a folder is flipped between real and link while many reads run
mkdir -p "$PUB/race"; mkdir -p "$PUB/race_real"; echo "REAL" > "$PUB/race_real/secret.txt"; ln -sfn "$PUB/race_real" "$PUB/race/d" 2>/dev/null; rm -f "$PUB/race/d"
mkdir "$PUB/race/d"; echo "REAL" > "$PUB/race/d/secret.txt"
( for i in $(seq 1 150); do mv "$PUB/race/d" "$PUB/race/d.real" 2>/dev/null; ln -s "$OUT" "$PUB/race/d" 2>/dev/null; rm -f "$PUB/race/d" 2>/dev/null; mv "$PUB/race/d.real" "$PUB/race/d" 2>/dev/null; done ) & RP=$!
leak=0; for i in $(seq 1 120); do v=$(fsr read path=public:race/d/secret.txt | jq -r '.data_b64 // ""' | base64 -d 2>/dev/null); [ "$v" = "TOPSECRET" ] && leak=1; done; wait $RP 2>/dev/null
[ $leak = 0 ] && ok "no read ever reached the outside file while a folder was flipped to a link" || bad "a read followed a swapped link"

# trash
good delete path=public:other/readme\ \(2\).txt && [ ! -e "$PUB/other/readme (2).txt" ] && ok "delete moves to the trash" || bad "delete"
r=$(fsr list path=public:.trash); [ "$(echo "$r" | jq -r '.entries|length')" -ge 1 ] && ok "the trash lists what was deleted" || bad "trash list"
tn=$(echo "$r" | jq -r '.entries[0].name'); good delete path="public:.trash/$tn" && [ ! -e "$PUB/.trash/$tn" ] && ok "delete inside the trash is permanent" || bad "purge"
refused delete path=public: && ok "the top folder cannot be deleted" || bad "delete root"
refused delete path=public:.trash && ok "the trash folder itself is not deleted (empty it instead)" || bad "delete trash folder"
good delete path=public:docs && good empty_trash zone=public && [ -z "$(ls -A "$PUB/.trash" 2>/dev/null)" ] && ok "empty the trash removes everything in it" || bad "empty trash"
good mkdir path=public:uni && good newfile path="public:uni/שלום עולם.txt" && [ -f "$PUB/uni/שלום עולם.txt" ] && ok "Hebrew file names" || bad "unicode name"
refused newfile path="public:uni/$(printf 'x%.0s' $(seq 1 300))" && ok "a name over 255 bytes is refused" || bad "long name"
j=$(jq -n --argjson z "$ZONES" --arg d "$(head -c 100 /dev/zero | base64 -w0)" '{op:"write",zones:$z,path:"public:uni/big",offset:600000000,data_b64:$d}'); echo "$j" > "$T/req.json"; [ "$("$ENG" fs --request-file "$T/req.json" | jq -r .ok)" = false ] && ok "a write beyond the size limit is refused" || bad "size limit"

# audit
[ "$(jq -s 'map(select(.op=="mkdir" and .ok==true))|length' "$AUD")" -ge 1 ] && ok "changes are audited" || bad "audit missing"
[ "$(jq -s 'map(select(.ok==false))|length' "$AUD")" -ge 5 ] && ok "refusals are audited with the reason" || bad "refusals not audited"
[ "$(jq -s 'map(select(.user=="tester"))|length' "$AUD")" = "$(jq -s 'length' "$AUD")" ] && ok "every audit line names the user" || bad "audit user"
[ "$(jq -s 'map(select(.op=="list" or .op=="read" or .op=="stat"))|length' "$AUD")" = 0 ] && ok "reading is not audited" || bad "reads audited"
# "Open with the system" starts the program for good: a stand-in xdg-open that keeps its output open for 8 s then writes a marker must
# (a) let the call return at once, (b) still be alive after the old 6 s limit (the old way killed a GUI program that held its pipes).
mkdir -p "$T/bin"; printf '#!/bin/sh\necho "$1" > "%s/opened.txt"\nsleep 8\necho survived > "%s/survived.txt"\n' "$T" "$T" > "$T/bin/xdg-open"; chmod +x "$T/bin/xdg-open"
echo hi > "$PUB/o.txt"
t0=$(date +%s); fsr_open() { local j; j=$(jq -n --argjson z "$ZONES" --arg au "$AUD" '{op:"open",zones:$z,user:"tester",audit:$au,path:"public:o.txt",display:":0"}'); printf "%s" "$j" > "$T/req2.json"; PATH="$T/bin:$PATH" "$ENG" fs --request-file "$T/req2.json"; }
r=$(fsr_open); t1=$(date +%s)
[ "$(echo "$r" | jq -r .ok)" = true ] && [ $((t1 - t0)) -le 2 ] && ok "open returns at once" || bad "open did not return at once: $r"
sleep 1; [ "$(cat "$T/opened.txt" 2>/dev/null)" = "$PUB/o.txt" ] && ok "the opener got the real path" || bad "opener not run with the path"
sleep 8; [ -f "$T/survived.txt" ] && ok "the program lives on past the old 6 s limit" || bad "the opened program was killed"
echo "fs_test: $n passed, $fails failed"; [ "$fails" = 0 ]
