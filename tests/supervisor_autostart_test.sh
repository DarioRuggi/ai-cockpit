#!/bin/bash
# supervisor_autostart_test.sh — scripts/cockpit_sup_autostart.sh without touching the real systemd: HOME is a scratch folder and
# systemctl / loginctl are stand-ins that only record what they were asked. `print` is also checked with the real systemd-analyze.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d) || exit 1; trap 'rm -rf "$T"' EXIT
fails=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
mkdir -p "$T/home/scripts" "$T/bin"
cp "$ROOT/scripts/cockpit_sup_config.php" "$T/home/scripts/"
printf '#!/bin/bash\nexit 0\n' > "$T/home/scripts/aicsupervisor"; chmod +x "$T/home/scripts/aicsupervisor"
cat > "$T/bin/systemctl" <<FAKE
#!/bin/bash
echo "systemctl \$*" >> "$T/calls.log"
case "\$*" in *"is-system-running"*|*"show-environment"*) exit 0 ;; *"is-active"*) echo active ;; *"is-enabled"*) echo enabled ;; esac
exit 0
FAKE
cat > "$T/bin/loginctl" <<'FAKE'
#!/bin/bash
echo no
FAKE
chmod +x "$T/bin/systemctl" "$T/bin/loginctl"
# COCKPIT_DOCROOT keeps install away from the REAL tmux server (it ends tmux agent sessions: only ever those of this scratch tree)
mkdir -p "$T/docroot/cockpit"
A() { HOME="$T/home" USER=tester PATH="$T/bin:$PATH" COCKPIT_UNIT_DIR="$T/units" COCKPIT_DOCROOT="$T/docroot" bash "$ROOT/scripts/cockpit_sup_autostart.sh" "$@"; }

U=$(A print --edition v2)
echo "$U" | grep -q "^ExecStartPre=.*cockpit_sup_config.php --auto --edition v2 --out $T/home/scripts/cockpit_data/supervisor/cockpit.supervisor.json" && ok "print v2: the unit regenerates the configuration before every start" || bad "print v2: no ExecStartPre --auto"
echo "$U" | grep -q "^ExecStart=$T/home/scripts/aicsupervisor run --config $T/home/scripts/cockpit_data/supervisor/cockpit.supervisor.json" && ok "print v2: ExecStart runs the supervisor on that file" || bad "print v2: ExecStart"
echo "$U" | grep -q "^Restart=on-failure" && ! echo "$U" | grep -q "^Restart=always" && ok "Restart=on-failure (a clean 'stop all' is NOT restarted)" || bad "restart policy"
echo "$U" | grep -q "^KillMode=mixed" && echo "$U" | grep -q "WantedBy=default.target" && ok "KillMode=mixed, WantedBy=default.target" || bad "kill mode / target"
V=$(A print --edition v1)
echo "$V" | grep -q "cockpit_data_v1/supervisor" && echo "$V" | grep -q "aicockpit-supervisor-v1" && ok "print v1: its own data folder and unit name" || bad "print v1"
[ -d "$T/units" ] && bad "print wrote something" || ok "print changes nothing"
A print --edition v3 >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown edition is refused (exit 2)" || bad "edition v3 accepted"
A frobnicate >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown action is refused (exit 2)" || bad "unknown action accepted"
A install --edition v2 --bogus >/dev/null 2>&1; [ $? -eq 2 ] && ok "an unknown argument is refused (exit 2)" || bad "unknown argument accepted"
# the real systemd-analyze reads the unit
if command -v systemd-analyze >/dev/null 2>&1; then
    mkdir -p "$T/v"; echo "$U" > "$T/v/aicockpit-supervisor-v2.service"
    OUT=$(systemd-analyze --user verify "$T/v/aicockpit-supervisor-v2.service" 2>&1)
    echo "$OUT" | grep -qiE "unknown (key|section)|invalid|failed to parse|bad (unit|setting)" && bad "systemd-analyze: $OUT" || ok "systemd-analyze --user verify raises no syntax complaint"
fi
# --auto: the directories are worked out the way cockpit_start.sh does it
mkdir -p "$T/doc/cockpit-v1"; : > "$T/doc/cockpit-v1/index.html"; echo '<?php // tick' > "$T/doc/cockpit-v1/scheduler.php"
echo '{"projects_root":"'$T'/projects"}' > "$T/doc/cockpit-v1/paths.json"
J=$(HOME="$T/home" COCKPIT_DOCROOT="$T/doc" php "$T/home/scripts/cockpit_sup_config.php" --auto --edition v1)
echo "$J" | php -r '$d=json_decode(stream_get_contents(STDIN),true); $s=$d["services"][0]; $e=$s["env"]; exit(($d["state_dir"]==="'$T'/home/scripts/cockpit_data_v1/supervisor" && $e["COCKPIT_QUEUE_DIR"]==="'$T'/doc/cockpit-v1/queue" && $e["COCKPIT_DATA_DIR"]==="'$T'/home/scripts/cockpit_data_v1" && $s["cwd"]==="'$T'/projects" && count($d["services"])===3)?0:1);' && ok "--auto v1: web root, data dir, projects_root (from paths.json) and state dir are the ones cockpit_start.sh would use" || bad "--auto v1: $(echo "$J" | head -c 300)"
echo "$J" | php -r '$d=json_decode(stream_get_contents(STDIN),true); $j=$d["jobs"][0]??null; exit(($j && $j["name"]==="scheduler" && $j["schedule"]==="every 60s" && $j["args"][0]==="'$T'/doc/cockpit-v1/scheduler.php" && $j["overlap"]==="skip" && $j["run_at_start"]===true)?0:1);' && ok "the web root's scheduler.php becomes the job \"scheduler\" (every 60 s, never two at once)" || bad "no scheduler job"
rm "$T/doc/cockpit-v1/scheduler.php"
HOME="$T/home" COCKPIT_DOCROOT="$T/doc" php "$T/home/scripts/cockpit_sup_config.php" --auto --edition v1 | grep -q '"jobs"' && bad "a job was configured without a scheduler.php" || ok "without scheduler.php there is no job"
# install: unit file, switch file, the right systemctl calls
if command -v tmux >/dev/null 2>&1; then
    TS="$T/docroot/cockpit/tmux.sock"
    for n in cockpit_claude cockpit_gemini cockpit_ollama cockpit_tools; do tmux -S "$TS" new-session -d -s $n -x 80 -y 24 "sleep 300"; done
fi
A install --edition v2 >"$T/install.out" 2>&1
[ -f "$T/units/aicockpit-supervisor-v2.service" ] && ok "install: the unit file is written" || bad "install: no unit file ($(cat "$T/install.out" | head -3))"
[ -f "$T/home/scripts/cockpit_data/use_supervisor" ] && ok "install: the supervisor switch file is created" || bad "install: no switch file"
grep -q "systemctl --user daemon-reload" "$T/calls.log" && grep -q "systemctl --user enable --now aicockpit-supervisor-v2" "$T/calls.log" && ok "install: daemon-reload, then enable --now" || bad "install: systemctl calls were: $(cat "$T/calls.log")"
grep -q "enable-linger" "$T/install.out" && ok "install: tells how to start at boot (and does not do it itself)" || bad "install: no linger note"
if command -v tmux >/dev/null 2>&1; then
    n=$(tmux -S "$TS" list-sessions -F "#S" 2>/dev/null | tr "\n" " ")
    [ "$n" = "cockpit_tools " ] && ok "install ends the tmux agent sessions (a second loop would answer every prompt twice) and keeps Tools" || bad "tmux sessions left after install: $n"
    tmux -S "$TS" kill-server 2>/dev/null
fi
grep -q "linger" "$T/calls.log" && bad "install ran a linger command itself" || ok "install never touches linger"
A status --edition v2 | grep -q "unit: installed" && ok "status: reports the unit installed" || bad "status"
# remove
: > "$T/calls.log"
A remove --edition v2 >/dev/null 2>&1
[ ! -f "$T/units/aicockpit-supervisor-v2.service" ] && grep -q "disable --now aicockpit-supervisor-v2" "$T/calls.log" && ok "remove: disabled and the unit deleted" || bad "remove"
[ -f "$T/home/scripts/cockpit_data/use_supervisor" ] && ok "remove: the switch file is left (that is the user's decision)" || bad "remove deleted the switch file"
echo "supervisor_autostart_test: $fails failure(s)"
exit $((fails>0))
