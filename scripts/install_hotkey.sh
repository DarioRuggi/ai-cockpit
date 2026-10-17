#!/usr/bin/env bash
# install_hotkey.sh — register a desktop shortcut that summons AI Cockpit, and
# starts it when it is not running (the app's own grab can only work while it
# already runs). Per user, no sudo. Usage: install_hotkey.sh ["<Control><Alt>c"]
#   --remove   take the shortcut out again
set -e
KEY="${1:-<Control><Alt>c}"
CMD="cockpit-start --toggle"
NAME="AI Cockpit"
[ "$1" = "--remove" ] && { KEY=""; REMOVE=1; }

have() { command -v "$1" >/dev/null 2>&1; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

# ── Cinnamon ────────────────────────────────────────────────────────────────
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org.cinnamon.desktop.keybindings$'; then
    SLOT="custom0"; BASE="org.cinnamon.desktop.keybindings.custom-keybinding"
    PATHP="/org/cinnamon/desktop/keybindings/custom-keybindings"
    # Reuse our own slot if it exists, else take the next free one.
    list=$(gsettings get org.cinnamon.desktop.keybindings custom-list 2>/dev/null)
    for i in 0 1 2 3 4 5 6 7 8 9; do
        n=$(gsettings get "$BASE:$PATHP/custom$i/" name 2>/dev/null || echo "")
        case "$n" in *"$NAME"*) SLOT="custom$i"; break ;; "'']"|"''"|"") SLOT="custom$i"; break ;; esac
    done
    if [ "${REMOVE:-0}" = "1" ]; then
        gsettings set "$BASE:$PATHP/$SLOT/" binding "[]" 2>/dev/null || true
        new=$(printf '%s' "$list" | sed "s/'$SLOT'//; s/, ,/,/; s/\[, /[/; s/, \]/]/")
        gsettings set org.cinnamon.desktop.keybindings custom-list "$new" 2>/dev/null || true
        ok "Cinnamon shortcut removed"; exit 0
    fi
    gsettings set "$BASE:$PATHP/$SLOT/" name "$NAME"
    gsettings set "$BASE:$PATHP/$SLOT/" command "$CMD"
    gsettings set "$BASE:$PATHP/$SLOT/" binding "['$KEY']"
    case "$list" in *"'$SLOT'"*) : ;; "@as []"|"[]") gsettings set org.cinnamon.desktop.keybindings custom-list "['$SLOT']" ;;
        *) gsettings set org.cinnamon.desktop.keybindings custom-list "$(printf '%s' "$list" | sed "s/]$/, '$SLOT']/")" ;; esac
    ok "Cinnamon: $KEY → $CMD"; exit 0
fi

# ── GNOME ───────────────────────────────────────────────────────────────────
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org.gnome.settings-daemon.plugins.media-keys$'; then
    P="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/ai-cockpit/"
    B="org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
    list=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)
    if [ "${REMOVE:-0}" = "1" ]; then
        gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$(printf '%s' "$list" | sed "s|'$P'||; s/, ,/,/; s/\[, /[/; s/, \]/]/")"
        ok "GNOME shortcut removed"; exit 0
    fi
    gsettings set "$B:$P" name "$NAME"; gsettings set "$B:$P" command "$CMD"; gsettings set "$B:$P" binding "$KEY"
    case "$list" in *"$P"*) : ;; "@as []"|"[]") gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$P']" ;;
        *) gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$(printf '%s' "$list" | sed "s|]$|, '$P']|")" ;; esac
    ok "GNOME: $KEY → $CMD"; exit 0
fi

# ── KDE Plasma (5 + 6) ───────────────────────────────────────────────────────
# Plasma binds global shortcuts to launchers: a hidden .desktop file plus a
# [services][<file>] _launch entry in kglobalshortcutsrc, picked up when the
# kglobalaccel daemon reloads. (Manjaro KDE VM: Ctrl+Alt+C did nothing.)
if have kwriteconfig6 || have kwriteconfig5; then
    kw=kwriteconfig6; have kwriteconfig6 || kw=kwriteconfig5
    k=$(printf '%s' "$KEY" | sed 's/<Control>/Ctrl+/; s/<Primary>/Ctrl+/; s/<Alt>/Alt+/; s/<Shift>/Shift+/; s/<Super>/Meta+/')
    k="${k%?}$(printf '%s' "${k: -1}" | tr '[:lower:]' '[:upper:]')"      # ctrl+alt+c → Ctrl+Alt+C
    df="$HOME/.local/share/applications/ai-cockpit-toggle.desktop"
    if [ "${REMOVE:-0}" = "1" ]; then
        rm -f "$df"; $kw --file kglobalshortcutsrc --group services --group ai-cockpit-toggle.desktop --key _launch --delete 2>/dev/null || true
    else
        mkdir -p "$(dirname "$df")"
        printf '[Desktop Entry]\nType=Application\nName=%s (toggle)\nExec=%s\nNoDisplay=true\nX-KDE-GlobalAccel-CommandShortcut=true\n' "$NAME" "$CMD" > "$df"
        $kw --file kglobalshortcutsrc --group services --group ai-cockpit-toggle.desktop --key _launch "$k"
    fi
    systemctl --user restart plasma-kglobalaccel.service 2>/dev/null \
      || { (kquitapp6 kglobalaccel || kquitapp5 kglobalaccel) >/dev/null 2>&1; sleep 1; (kglobalaccel6 || kglobalaccel5) >/dev/null 2>&1 & }
    [ "${REMOVE:-0}" = "1" ] && { ok "KDE shortcut removed"; exit 0; }
    ok "KDE: $k → $CMD (takes effect now; if not, log out and in)"; exit 0
fi

# ── MATE (Marco) ────────────────────────────────────────────────────────────
# Marco keeps twelve run-command slots: org.mate.Marco.keybinding-commands
# command-N + org.mate.Marco.global-keybindings run-command-N. Reuse our slot
# if present, else the first empty one. (Arch/MATE VM: Ctrl+Alt+C did nothing.)
if have gsettings && gsettings list-schemas 2>/dev/null | grep -q '^org.mate.Marco.keybinding-commands$'; then
    slot=""
    for i in $(seq 1 12); do
        c=$(gsettings get org.mate.Marco.keybinding-commands "command-$i" 2>/dev/null | tr -d "'")
        if [ "$c" = "$CMD" ]; then slot=$i; break; fi
        [ -z "$slot" ] && [ -z "$c" ] && slot=$i
    done
    if [ "${REMOVE:-0}" = "1" ]; then
        [ -n "$slot" ] && gsettings set org.mate.Marco.keybinding-commands "command-$slot" "" && gsettings set org.mate.Marco.global-keybindings "run-command-$slot" "disabled"
        ok "MATE shortcut removed"; exit 0
    fi
    [ -n "$slot" ] || { warn "MATE: all twelve Marco command slots are taken — free one in Keyboard Shortcuts and re-run."; exit 1; }
    gsettings set org.mate.Marco.keybinding-commands "command-$slot" "$CMD"
    gsettings set org.mate.Marco.global-keybindings "run-command-$slot" "$KEY"
    ok "MATE: $KEY → $CMD (Marco run-command-$slot)"; exit 0
fi

# ── XFCE ────────────────────────────────────────────────────────────────────
if have xfconf-query; then
    x=$(printf '%s' "$KEY" | sed 's/<Control>/<Primary>/')
    if [ "${REMOVE:-0}" = "1" ]; then
        xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$x" -r 2>/dev/null || true
        ok "XFCE shortcut removed"; exit 0
    fi
    xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$x" -n -t string -s "$CMD" 2>/dev/null \
      || xfconf-query -c xfce4-keyboard-shortcuts -p "/commands/custom/$x" -s "$CMD"
    ok "XFCE: $KEY → $CMD"; exit 0
fi

warn "No supported desktop settings found — add a shortcut for '$CMD' by hand."
exit 1
