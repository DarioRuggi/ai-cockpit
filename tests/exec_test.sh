#!/bin/bash
# exec_test.sh — the command window (aicengine exec): runs as this account, in a zone folder, and the KERNEL (Landlock) decides what it can touch:
# write only in Public, read the areas and the system's programs, nothing else. Limits on time and output. No sandbox = nothing runs.
#   bash tests/exec_test.sh     ENGINE=<aicengine>      Exit 0 = pass; SKIPPED without an engine with `exec`, jq, or Landlock in this kernel.
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
command -v jq >/dev/null 2>&1 || { echo "exec_test: jq is needed - SKIPPED"; exit 0; }
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " exec" || { echo "exec_test: no engine with 'exec' - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
PUB="$T/Public"; AREA="$T/area"; OUT="$T/outside"; AUD="$T/audit.jsonl"
mkdir -p "$AREA/docs" "$OUT"; echo "area file" > "$AREA/docs/readme.txt"; echo "TOPSECRET" > "$OUT/secret.txt"
ZONES=$(jq -n --arg p "$PUB" --arg a "$AREA" '[{name:"public",path:$p,rw:true},{name:"area",path:$a,rw:false}]')
fails=0; n=0; ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
# run CMD [cwd] [timeout] [maxkb]  -> JSON on stdout
run() { jq -n --arg c "$1" --arg w "${2:-public:}" --argjson t "${3:-20}" --argjson k "${4:-256}" --argjson z "$ZONES" --arg au "$AUD" '{cmd:$c,cwd:$w,timeout_s:$t,max_output_kb:$k,zones:$z,user:"tester",audit:$au}' > "$T/req.json"; "$ENG" exec --request-file "$T/req.json"; }
r=$(run 'echo hi'); if [ "$(echo "$r" | jq -r .sandbox)" = false ]; then echo "exec_test: this kernel has no Landlock - SKIPPED"; exit 0; fi
[ "$(echo "$r" | jq -r .output)" = "hi" ] && [ "$(echo "$r" | jq -r .exit)" = 0 ] && ok "a command runs and its output comes back" || bad "echo: $r"
r=$(run 'pwd'); [ "$(echo "$r" | jq -r .output | tr -d '\n')" = "$(realpath "$PUB")" ] && ok "the default folder is Public" || bad "pwd: $r"
[ "$(run 'exit 3' | jq -r .exit)" = 3 ] && ok "the exit code comes back" || bad "exit code"
run 'echo made > a.txt' >/dev/null; [ "$(cat "$PUB/a.txt" 2>/dev/null)" = "made" ] && ok "a command can write in Public" || bad "write in Public"
run 'mkdir sub && echo x > sub/b.txt && mv sub/b.txt . && rm -r sub' >/dev/null; [ -f "$PUB/b.txt" ] && [ ! -e "$PUB/sub" ] && ok "folders, files, move (across folders) and delete work in Public" || bad "fs ops in Public"
r=$(run "echo evil > '$OUT/evil.txt'"); [ ! -e "$OUT/evil.txt" ] && [ "$(echo "$r" | jq -r .exit)" != 0 ] && ok "a write outside Public is refused by the kernel" || bad "write outside: $r"
run "echo evil > '$AREA/docs/evil.txt'" >/dev/null; [ ! -e "$AREA/docs/evil.txt" ] && ok "a write into a read-only area is refused" || bad "write to area"
run "rm '$AREA/docs/readme.txt'; mv '$AREA/docs/readme.txt' '$PUB/'" >/dev/null; [ -f "$AREA/docs/readme.txt" ] && ok "a delete or move out of an area is refused" || bad "delete from area"
r=$(run "cat '$AREA/docs/readme.txt'"); [ "$(echo "$r" | jq -r .output | tr -d '\n')" = "area file" ] && ok "an area can be read" || bad "read area: $r"
r=$(run "cat '$OUT/secret.txt'"); [ "$(echo "$r" | jq -r .output | grep -c TOPSECRET)" = 0 ] && [ "$(echo "$r" | jq -r .exit)" != 0 ] && ok "a file outside every zone cannot be read" || bad "read outside: $r"
r=$(run "ls '$OUT'"); [ "$(echo "$r" | jq -r .exit)" != 0 ] && ok "a folder outside every zone cannot be listed" || bad "list outside"
r=$(run "cat ~/.bashrc ~/.ssh/id_rsa /home/*/.bash_history 2>&1 | head -c 200"); [ "$(echo "$r" | jq -r .output | grep -ci 'permission denied\|no such')" -ge 1 ] && ok "the owner's home files are out of reach" || bad "home reachable: $r"
run 'touch /tmp/cockpit_exec_probe_$$' >/dev/null; ls /tmp/cockpit_exec_probe_* >/dev/null 2>&1 && { bad "wrote into /tmp"; rm -f /tmp/cockpit_exec_probe_*; } || ok "/tmp is not writable"
r=$(run 'f=$(mktemp) && echo ok > "$f" && cat "$f"'); [ "$(echo "$r" | jq -r .output | tr -d '\n')" = "ok" ] && ok "a private temp folder works (TMPDIR)" || bad "mktemp: $r"
r=$(run 'echo "#!/bin/sh
echo from-script" > s.sh; chmod +x s.sh; ./s.sh'); [ "$(echo "$r" | jq -r .output | tr -d '\n')" = "from-script" ] && ok "a script made in Public can be run" || bad "script: $r"
export COCKPIT_TEST_SECRET=hunter2; r=$(run 'env'); [ "$(echo "$r" | jq -r .output | grep -c hunter2)" = 0 ] && ok "the service's environment (secrets) is not passed on" || bad "env leaked"
r=$(run 'sudo -n true 2>&1; echo rc=$?'); [ "$(echo "$r" | jq -r .output | grep -c 'rc=0')" = 0 ] && ok "sudo / privilege gain does not work" || bad "sudo worked"
ln -s "$OUT/secret.txt" "$PUB/lk"; r=$(run 'cat lk'); [ "$(echo "$r" | jq -r .output | grep -c TOPSECRET)" = 0 ] && ok "a link in Public to a file outside cannot be read through" || bad "link read: $r"
r=$(run 'cat readme.txt' 'area:docs'); [ "$(echo "$r" | jq -r .output | tr -d '\n')" = "area file" ] && ok "a command can run inside an area (read-only)" || bad "cwd area: $r"
run 'echo x > nope.txt' 'area:docs' >/dev/null; [ ! -e "$AREA/docs/nope.txt" ] && ok "...and still cannot write there" || bad "write in area cwd"
ln -s "$OUT" "$PUB/dirlink"; r=$(run 'pwd' 'public:dirlink'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok "a folder reached through a link is refused as the working folder" || bad "cwd via link: $r"
r=$(run 'pwd' 'public:../outside'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok '".." in the working folder is refused' || bad "cwd dotdot"
t0=$(date +%s); r=$(run 'sleep 30' public: 1); t1=$(date +%s); [ "$(echo "$r" | jq -r .timed_out)" = true ] && [ $((t1-t0)) -le 4 ] && ok "a command that runs too long is stopped" || bad "timeout: $r in $((t1-t0))s"
sleep 0.5; if ps -eo args= | grep -qx "sleep 30"; then bad "the timed-out command is still running"; for p in $(pgrep -x sleep); do kill $p 2>/dev/null; done; else ok "...and nothing of it is left running"; fi
t0=$(date +%s); r=$(run 'yes' public: 20 1); t1=$(date +%s); [ "$(echo "$r" | jq -r .truncated)" = true ] && [ "$(echo "$r" | jq -r .output | wc -c)" -le 1100 ] && [ $((t1-t0)) -le 8 ] && ok "endless output is cut at the limit and stopped" || bad "flood: $(echo "$r" | jq -c '{truncated,len:(.output|length)}') in $((t1-t0))s"
if pgrep -x yes >/dev/null; then bad "yes still running"; pkill -x yes; else ok "...and the flooding command is killed"; fi
r=$(run ''); [ "$(echo "$r" | jq -r .ok)" = false ] && ok "an empty command is refused" || bad "empty"
r=$(run 'echo a; echo b >&2'); [ "$(echo "$r" | jq -r .output | tr -d '\n')" = "ab" ] && ok "errors (stderr) are part of the output" || bad "stderr: $r"
r=$(run 'cat'); [ "$(echo "$r" | jq -r .exit)" = 0 ] && ok "a command that reads input gets an empty input, not a hang" || bad "stdin"
[ "$(jq -s 'map(select(.op=="exec"))|length' "$AUD")" -ge 10 ] && [ "$(jq -s 'map(select(.cmd=="echo hi"))|length' "$AUD")" -ge 1 ] && ok "every command is audited with its text" || bad "audit"
echo "exec_test: $n passed, $fails failed"; [ "$fails" = 0 ]
