#!/usr/bin/env bash
# disable_samba.sh — stop and disable Samba (smbd, nmbd) on this rig.
#
# Why: smb.conf shares only the default printers, yet smbd listens on 139/445 on EVERY interface (LAN, the VM bridge, Tailscale). Nothing is lost by turning it off.
# Undo:  sudo systemctl enable --now smbd nmbd
# It asks YOU for the sudo password; Claude never sees it. Nothing else is changed.
sudo -k      # always ask for the password afresh; never inherit a cached sudo timestamp
B=$'\e[1;30;103m'; G=$'\e[1;32m'; R=$'\e[1;31m'; N=$'\e[0m'
banner() { printf '\n%s  %s  %s\n' "$B" "$1" "$N"; }

banner "STEP 1 of 3 — BEFORE: who listens on the Samba ports (read-only)"
ss -tlnH 2>/dev/null | awk '$4 ~ /:(139|445)$/ {print "  listening: " $4}'
systemctl is-active smbd nmbd 2>/dev/null | paste -sd' ' | sed 's/^/  smbd nmbd active: /'

banner "STEP 2 of 3 — STOP and DISABLE smbd and nmbd   |   WHY: they share nothing but printers and listen on every network   |   password asked now"
sudo systemctl disable --now smbd nmbd; rc=$?
echo "  systemctl exit code: $rc"

banner "STEP 3 of 3 — VERIFY (never trust the exit code alone)"
bad=0
for u in smbd nmbd; do
    a=$(systemctl is-active $u 2>/dev/null); e=$(systemctl is-enabled $u 2>/dev/null)
    printf '  %s: active=%s enabled=%s\n' "$u" "$a" "$e"
    { [ "$a" != active ] && [ "$e" != enabled ]; } || bad=1
done
left=$(ss -tlnH 2>/dev/null | awk '$4 ~ /:(139|445)$/ {print $4}')
if [ -n "$left" ]; then echo "  ${R}still listening: $left${N}"; bad=1; else echo "  ports 139 and 445: closed"; fi
if [ $bad = 0 ]; then printf '\n%sDone: Samba is off and stays off after a reboot.%s  Undo: sudo systemctl enable --now smbd nmbd\n' "$G" "$N"
else printf '\n%sNot fully off: see the lines above.%s\n' "$R" "$N"; fi
read -n1 -r -p "Press any key to close"
exit $bad
