#!/usr/bin/env bash
# fix_sudoers_cockpit_shell.sh — let Cockpit's web server (www-data) start the web-worker windows as YOU.
#
# Why: the web page workers (Duck.ai, Perplexity, ...) run in a window of ~/scripts/cockpit_shell. When Cockpit is served by Apache, PHP runs as www-data and has to start that
# window as the desktop owner: `sudo -n -u <you> cockpit_shell --worker ...`. Without a sudoers rule that fails with "sudo: a password is required".
#
# What it does (it asks YOU for the sudo password; Claude never sees it):
#   1. shows what the sudoers folder already says about cockpit_shell,
#   2. if no rule exists, writes ONE NEW file /etc/sudoers.d/cockpit-webworker (no existing file is edited), checks it with `visudo -cf` BEFORE installing it,
#   3. shows the result. To undo: sudo rm /etc/sudoers.d/cockpit-webworker
# The rule: www-data may run exactly this one program as you, with no password and no other command:  /home/<you>/scripts/cockpit_shell
sudo -k      # always ask for the password afresh; never inherit a cached sudo timestamp

OWNER="${COCKPIT_OWNER:-$USER}"
WEB="${COCKPIT_WEB_USER:-www-data}"
SH="$HOME/scripts/cockpit_shell"
DROPIN="/etc/sudoers.d/cockpit-webworker"
B=$'\e[1;97;44m'; G=$'\e[1;32m'; R=$'\e[1;31m'; N=$'\e[0m'
banner() { printf '\n%s %s %s\n' "$B" "$1" "$N"; }
fail() { printf '%s%s%s\n' "$R" "$1" "$N"; read -rp "Press Enter to close" _; exit 1; }

banner "WHAT: allow the web server ($WEB) to start $SH as $OWNER   |   WHY: web page workers need a window   |   ONE new file: $DROPIN"
[ -x "$SH" ] || fail "$SH is missing or not executable: nothing to allow."
command -v visudo >/dev/null || fail "visudo not found."

banner "STEP 1 of 3 — what sudoers already says about cockpit_shell (password asked now)"
sudo sh -c 'grep -Hn "cockpit_shell" /etc/sudoers /etc/sudoers.d/* 2>/dev/null' || echo "(nothing found: no rule exists yet)"
if sudo test -f "$DROPIN"; then echo "$DROPIN already exists:"; sudo cat "$DROPIN"; fi

banner "STEP 2 of 3 — write and CHECK the new rule, then install it"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# Cockpit web page workers: the web server may start the Cockpit window as the desktop owner (no other command, no password).
$WEB ALL=($OWNER) NOPASSWD: $SH
Defaults!$SH env_keep += "DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS LANG WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_TYPE"
EOF
echo "The file that will be installed:"; sed 's/^/    /' "$TMP"
sudo visudo -cf "$TMP" >/dev/null || fail "visudo says the rule is not valid: nothing was installed."
sudo install -m 0440 -o root -g root "$TMP" "$DROPIN" || fail "could not install $DROPIN"
sudo visudo -c >/dev/null && echo "${G}sudoers as a whole: OK${N}" || { sudo rm -f "$DROPIN"; fail "the whole sudoers failed its check: the new file was removed again."; }

banner "STEP 3 of 3 — verify"
sudo -l -U "$WEB" 2>/dev/null | grep -n "cockpit_shell" || fail "the rule does not show up for $WEB."
printf '%sDone.%s %s may now start %s as %s. Press F5 in Cockpit and run the web worker Self-test again.\nTo undo:  sudo rm %s\n' "$G" "$N" "$WEB" "$SH" "$OWNER" "$DROPIN"
read -rp "Press Enter to close" _
