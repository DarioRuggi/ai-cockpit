#!/usr/bin/env bash
# =============================================================================
# check_icons.sh — does the vendored icon font cover every icon the source uses?
#
# The font is a subset (Installs/build_icon_font.sh). Add an icon to the UI
# without rebuilding it and the glyph renders as its own ligature text — the
# button reads "attach_file" instead of showing a paperclip, and nothing errors.
# This compares the names in the source against the ones baked into the subset.
# Note what it CANNOT do: it only knows names the harvester can see. Build 99
# shipped eight icons as literal text because the harvester matched patterns and
# the UI writes icon names in four different shapes. The harvester now intersects
# every source token with Google's official icon list, which cannot miss one; the
# last word still belongs to the running app — see the DOM sweep in the comment
# at the end of this file.
#
# Exit 0 = covered. Exit 1 = missing names (rebuild the font).
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
NAMES="cockpit_app/assets/fonts/material-symbols.names"
[ -f "$NAMES" ] || { echo "check_icons: $NAMES missing — run Installs/build_icon_font.sh"; exit 1; }
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT
bash Installs/build_icon_font.sh --list 2>/dev/null | tail -n +1 > "$TMP"
MISSING=$(comm -23 <(sort -u "$TMP") <(sort -u "$NAMES") | grep -v '^harvested' || true)
if [ -n "$MISSING" ]; then
    echo "check_icons: the source uses icons the vendored font does not carry:"
    printf '  %s\n' $MISSING
    echo "  → bash Installs/build_icon_font.sh && bash Installs/stamp_assets.sh"
    exit 1
fi
echo "check_icons: ok ($(wc -l < "$NAMES") icons vendored, none missing)"

# Definitive check, needs a running window (kept as a comment because it needs a
# display and a live app, so it is not part of an unattended build):
#
#   walk every .material-symbols-rounded element and report any whose rendered
#   width exceeds ~1.6x its font-size — that is a ligature that did not resolve:
#
#   [...document.querySelectorAll('.material-symbols-rounded')]
#     .filter(e => e.getBoundingClientRect().width >
#                  (parseFloat(getComputedStyle(e).fontSize)||24) * 1.6)
#     .map(e => e.textContent.trim())
#
# That is how the eight missing icons in build 99 were found.
