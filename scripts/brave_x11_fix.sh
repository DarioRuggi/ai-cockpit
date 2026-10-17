#!/bin/bash
# Keep the needed flags on Brave's launchers. Brave updates wipe user .desktop
# overrides, reverting to the flagless system launcher. Idempotent; safe to run
# every login (autostart). No-ops on non-Brave systems.
#
# Flags:
#   --ozone-platform=x11  : force X11 backend (harmless on X11; needed if the
#                           session is ever Wayland).
#   --disable-gpu-compositing : works around a GPU-compositing input-offset bug
#                           on some GPUs (AMD) where clicks land above the
#                           pointer. Lighter than --disable-gpu — keeps hardware
#                           video decode. Use --disable-gpu instead if the
#                           offset persists on your machine.
FLAGS="--ozone-platform=x11 --disable-gpu-compositing"
A="$HOME/.local/share/applications"
mkdir -p "$A"

_has_all() { local _fl; for _fl in $FLAGS; do grep -qF -- "$_fl" "$1" 2>/dev/null || return 1; done; return 0; }

# Main + portal launchers (use /usr/bin/brave-browser-stable)
for f in brave-browser.desktop com.brave.Browser.desktop; do
    sys="/usr/share/applications/$f"
    [ -f "$sys" ] || continue
    if ! _has_all "$A/$f"; then
        sed "s#\(Exec\(\[[^]]*\]\)\?=\)\(/usr/bin/brave-browser-stable\)#\1\3 $FLAGS#g" \
            "$sys" > "$A/$f"
    fi
done
# PWA app shortcuts (brave-<id>-Default.desktop) call the binary directly
for f in "$A"/brave-*-Default.desktop; do
    [ -f "$f" ] || continue
    _has_all "$f" && continue
    sed -i "s#\(Exec\(\[[^]]*\]\)\?=/opt/brave.com/brave/brave-browser\) #\1 $FLAGS #g" "$f"
done
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$A" 2>/dev/null || true
