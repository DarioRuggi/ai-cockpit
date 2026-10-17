#!/usr/bin/env bash
# enable_samba.sh — turn Samba (smbd, nmbd) back ON: the undo of disable_samba.sh. Your per-user shares (net usershare: D, D_Net, E, F ...) serve the TV's VLC.
# It asks YOU for the sudo password; Claude never sees it.
sudo -k      # always ask for the password afresh; never inherit a cached sudo timestamp
B=$'\e[1;30;103m'; G=$'\e[1;32m'; R=$'\e[1;31m'; N=$'\e[0m'
banner() { printf '\n%s  %s  %s\n' "$B" "$1" "$N"; }
banner "STEP 1 of 2 — ENABLE and START smbd and nmbd   |   WHY: undo of today's disable; the TV reads movies from your Samba shares   |   password asked now"
sudo systemctl enable --now smbd nmbd; echo "  systemctl exit code: $?"
banner "STEP 2 of 2 — VERIFY"
bad=0
for u in smbd nmbd; do a=$(systemctl is-active $u 2>/dev/null); e=$(systemctl is-enabled $u 2>/dev/null); printf '  %s: active=%s enabled=%s\n' $u "$a" "$e"; { [ "$a" = active ] && [ "$e" = enabled ]; } || bad=1; done
ss -tlnH | awk '$4 ~ /:(139|445)$/ {print "  listening: " $4}'
echo "  shares:"; (testparm -s 2>/dev/null | grep '^\[' | sed 's/^/    /'); ls /var/lib/samba/usershares/ 2>/dev/null | sed 's/^/    usershare: /'
[ $bad = 0 ] && printf '\n%sSamba is on again.%s\n' "$G" "$N" || printf '\n%sNot fully on: see above.%s\n' "$R" "$N"
read -n1 -r -p "Press any key to close"; exit $bad
