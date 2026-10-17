#!/usr/bin/env bash
# =============================================================================
# build_splash.sh — ONE source → both splash screens.
#
# WHY THIS EXISTS
# The splash is the first thing anyone sees, and until 2026-09-26 it was a single
# image baked in at a very early stage, before most of what Cockpit can now do
# existed. Worse, the two editions had drifted into different shapes: V2 was one
# 259 KB image with nothing but a title, V1 a 138 KB image with its own text and
# badges. Both were ~99% base64 — there was no markup to maintain, only a picture
# nobody could edit.
#
# Now: Installs/splash/features.json says what each edition advertises, this
# script bakes in the version, build number and edition badges, and writes both
# files. Changing the pitch is a JSON edit, not an image export.
#
# Images are optional. A card with no image shows its icon, which is the default.
# Anything in Installs/splash/images/ named by a card is inlined as a data: URI —
# the splash must work from file:// with no network and no second request.
#
# Usage: bash Installs/build_splash.sh [--check]
# =============================================================================
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/Installs/splash"
OUT="$ROOT/scripts"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }

VERSION="$(tr -d ' \n' < "$ROOT/cockpit_app/VERSION" 2>/dev/null || echo '2.0.0')"
# COCKPIT_BUILD_NO when rebuild_tarballs is driving (it has already bumped the
# number and exported it); the file otherwise, for a standalone run.
BUILD="${COCKPIT_BUILD_NO:-$(tr -d ' \n' < "$ROOT/Installs/BUILD_NUMBER" 2>/dev/null || echo '0')}"
RC="$(tr -d ' \n' < "$ROOT/Installs/RC_NUMBER" 2>/dev/null || true)"

[ -f "$SRC/features.json" ] || { echo "build_splash: $SRC/features.json missing" >&2; exit 1; }

say "splash: version $VERSION, build $BUILD${RC:+, rc $RC}"
for ED in v2 v1; do
    case "$ED" in
        v2) FILE="$OUT/cockpit_splash.html" ;;
        v1) FILE="$OUT/cockpit_splash_v1.html" ;;
    esac
    if [ "$CHECK" = 1 ]; then
        php "$SRC/render.php" "$ED" "$VERSION" "$BUILD" "$RC" "$SRC" > /tmp/_splash_$$.html || exit 1
        if [ -f "$FILE" ] && cmp -s /tmp/_splash_$$.html "$FILE"; then echo "  · unchanged: $(basename "$FILE")"
        else printf '  \033[33m~ would update:\033[0m %s\n' "$(basename "$FILE")"; fi
        rm -f /tmp/_splash_$$.html
        continue
    fi
    php "$SRC/render.php" "$ED" "$VERSION" "$BUILD" "$RC" "$SRC" > "$FILE" || exit 1
    ok "$(basename "$FILE")  ($(( $(wc -c < "$FILE") / 1024 )) KB)"
done
[ "$CHECK" = 1 ] || echo "Edit Installs/splash/features.json and re-run this; never hand-edit the HTML."
