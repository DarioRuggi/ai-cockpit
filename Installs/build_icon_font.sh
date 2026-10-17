#!/usr/bin/env bash
# =============================================================================
# build_icon_font.sh — rebuild the vendored Material Symbols subset.
#
# The app serves its icon font from assets/fonts/ instead of fonts.googleapis.com:
# a machine with no internet used to render every icon as its ligature text
# ("settings", "attach_file"), which makes the UI unusable rather than merely
# plain.
#
# It ships the COMPLETE catalogue (2026-09-27), not a subset of the names the
# source happens to use. Measured: 4254 icons for 424 KB against 479 for 54 KB.
# The 370 KB buys the end of a whole bug class — an icon used without rebuilding
# the font renders as its own name, which is silent, and shipped eight times in
# build 99. Cockpit serves this file from the user's own machine, so the size is
# disk in the bundle (~3% of 11 MB), never a download anyone waits for.
#
# It also retires the subsetting tax: no name harvesting to get it wrong, no
# false positives from prose (the word "checklist" in a COMMENT pulled a glyph
# in), and picking an icon is now just using it.
#
# Run this only to refresh the catalogue (Google adds icons over time).
#
# Usage:  bash Installs/build_icon_font.sh [--list]
#           --list   print the icon names the SOURCE uses, and stop.
#                    That is what check_icons.sh compares against the font, so
#                    it must stay "what the source uses", not "what we ship" --
#                    otherwise the guard compares a set with itself.
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
APP=cockpit_app
OUT="$APP/assets/fonts/material-symbols-rounded.woff2"
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36'

# Nothing to exclude: the intersection with the official list already drops
# anything that is not an icon name. An exclusion list here is actively
# dangerous — a first cut of it removed 'search', 'key', 'hive' and 'home',
# every one of which IS an icon in this UI.
NOT_ICONS='^$'

# Harvesting by pattern does not work: icon names reach the DOM as multi-line
# span attributes, object maps ({dark:'light_mode'}), function arguments
# (_mkMini('keyboard_arrow_up',…)) and ternaries. A regex per shape misses one
# every time — eight icons shipped as literal text in build 99 that way.
#
# So: intersect EVERY identifier-ish token in the source with Google's official
# icon-name list. Any icon the UI can name must appear as a token somewhere, so
# this cannot miss one. It over-includes words that happen to be icon names
# ("block", "cable", "camera") at roughly 130 bytes each — cheap insurance.
METADATA='https://fonts.google.com/metadata/icons?incomplete=1&key=material_symbols'

harvest() {
    local all; all=$(mktemp)
    # The metadata response is prefixed with )]}' to defeat JSON hijacking.
    curl -fsS "$METADATA" | tail -c +6 | grep -oE '"name": *"[a-z0-9_]+"' | sed 's/.*"\([a-z0-9_]*\)"$/\1/' | LC_ALL=C sort -u > "$all"
    [ -s "$all" ] || { echo "could not fetch the official icon list" >&2; rm -f "$all"; return 1; }
    local tokens; tokens=$(mktemp)
    grep -rhoE '[a-z][a-z0-9_]{2,}' "$APP/index.html" "$APP/js" "$APP"/*.php 2>/dev/null | LC_ALL=C sort -u > "$tokens"
    LC_ALL=C comm -12 "$tokens" "$all" | grep -vxE "$NOT_ICONS"
    rm -f "$all" "$tokens"
}

NAMES_FILE=$(mktemp); trap 'rm -f "$NAMES_FILE"' EXIT
harvest > "$NAMES_FILE"
COUNT=$(wc -l < "$NAMES_FILE")
echo "harvested $COUNT icon names"

if [ "${1:-}" = "--list" ]; then cat "$NAMES_FILE"; exit 0; fi

# The complete face: no icon_names parameter, so Google returns every icon.
# (Requesting all 4254 by name would exceed any sane URL length anyway.)
CSS=$(curl -fsS -A "$UA" "https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@20,300,0,0") \
  || { echo "Google Fonts refused the request." >&2; exit 1; }

URL=$(printf '%s' "$CSS" | grep -oE 'https://fonts.gstatic.com/[^)]+' | head -1)
[ -n "$URL" ] || { echo "no font url in the returned CSS" >&2; exit 1; }

TMP=$(mktemp); curl -fsS -o "$TMP" "$URL"
# The full face is ~420 KB. Anything much smaller means we fetched an error page,
# an empty font, or a subset — and shipping that silently breaks icons.
SZ=$(stat -c %s "$TMP")
[ "$SZ" -gt 200000 ] || { rm -f "$TMP"; echo "downloaded font is only $SZ bytes — refusing to install it" >&2; exit 1; }
OLD=$( [ -f "$OUT" ] && stat -c %s "$OUT" || echo 0 )
mv "$TMP" "$OUT"; chmod 644 "$OUT"

# Cockpit's own glyphs (Installs/icons_custom/*.svg). This MUST run before the
# name list is derived below, so the ck_* names land in it and check_icons.sh
# and the glyph sheet both see them. The download above replaces the font
# wholesale, so without this step every refresh silently drops them.
if python3 -c 'import fontTools' 2>/dev/null; then
    python3 "$(dirname "$0")/merge_custom_icons.py" "$OUT" || {
        echo "merging the custom glyphs failed" >&2; exit 1; }
else
    echo "fontTools not installed — custom glyphs NOT merged" >&2
fi

# Record what the font can actually render, read from its own ligature table
# rather than from the catalogue: the font carries alias names too (access_time
# is the schedule glyph), and check_icons.sh must not flag one of those as
# missing. Falls back to the catalogue when fontTools is absent.
NAMES_OUT="$APP/assets/fonts/material-symbols.names"
if python3 -c 'import fontTools' 2>/dev/null; then
    python3 - "$OUT" > "$NAMES_OUT" <<'PYEOF'
import sys
from fontTools.ttLib import TTFont
f = TTFont(sys.argv[1])
g2c = {gn: chr(cp) for cp, gn in f['cmap'].getBestCmap().items()}
names = set()
for lk in f['GSUB'].table.LookupList.Lookup:
    for st in lk.SubTable:
        st = st.ExtSubTable if lk.LookupType == 7 else st
        for first, sets in getattr(st, 'ligatures', {}).items():
            for lg in sets:
                names.add(''.join(g2c.get(p, '?') for p in [first] + list(lg.Component)))
print('\n'.join(sorted(n for n in names if '?' not in n)))
PYEOF
else
    echo "fontTools not installed — recording the catalogue list instead" >&2
    curl -fsS "$METADATA" | tail -c +6 | grep -oE '"name": *"[a-z0-9_]+"' \
        | sed 's/.*"\([a-z0-9_]*\)"$/\1/' | LC_ALL=C sort -u > "$NAMES_OUT"
fi
chmod 644 "$NAMES_OUT"
# Re-stat: the size captured before the merge under-reports the shipped file.
SZ=$(stat -c %s "$OUT")
SHIPPED=$(wc -l < "$NAMES_OUT")
echo "wrote $OUT  ($OLD -> $SZ bytes, $SHIPPED renderable names)"
echo "remember: bash Installs/stamp_assets.sh, so browsers pick up the new file"
