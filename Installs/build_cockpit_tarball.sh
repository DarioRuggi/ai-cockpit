#!/usr/bin/env bash
# =============================================================================
# build_cockpit_tarball.sh — Package the current cockpit into a distributable
# tarball for use with install_cockpit.sh on a fresh machine.
#
# Run this from your DEV machine (where the cockpit is currently working).
# Produces:  cockpit_<version>_<date>.tar.gz
#
# Tarball layout (when extracted):
#   cockpit/web/                 — files for /var/www/html/cockpit/
#     index.html
#     *.php
#   cockpit/scripts/             — files for ~/scripts/
#     agent_loop.sh
#     ai_bridge.sh
#     cockpit_start.sh
#     cockpit_stop.sh
#     crud_executor.sh
#   cockpit/MANIFEST.txt         — list of files + sha256 sums
#   cockpit/VERSION              — single-line version string
# =============================================================================

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
COCKPIT_VERSION="${COCKPIT_VERSION:-1.0.0}"
WEB_SRC="${WEB_SRC:-/var/www/html/cockpit}"
SCRIPTS_SRC="${SCRIPTS_SRC:-$HOME/scripts}"
BUILD_DIR="$(mktemp -d /tmp/cockpit_build_XXXXXX)"
OUT_DIR="${OUT_DIR:-$PWD}"
DATE_STAMP="$(date +%Y%m%d_%H%M)"
TARBALL_NAME="cockpit_${COCKPIT_VERSION}_${DATE_STAMP}.tar.gz"

# ── Sanity checks ──────────────────────────────────────────────────────────
echo "─── Building cockpit tarball v${COCKPIT_VERSION} ───"

if [ ! -d "$WEB_SRC" ]; then
    echo "ERROR: Web source not found: $WEB_SRC"
    echo "Set WEB_SRC env var to point at your cockpit web dir."
    exit 1
fi
if [ ! -d "$SCRIPTS_SRC" ]; then
    echo "ERROR: Scripts source not found: $SCRIPTS_SRC"
    echo "Set SCRIPTS_SRC env var to point at your scripts dir."
    exit 1
fi

# ── Stage files ────────────────────────────────────────────────────────────
mkdir -p "$BUILD_DIR/cockpit/web"
mkdir -p "$BUILD_DIR/cockpit/scripts"

echo "Staging web files from: $WEB_SRC"
# Copy index.html and all .php files (skip queue/, responses/, .git, etc.)
for f in "$WEB_SRC"/index.html "$WEB_SRC"/*.php; do
    [ -f "$f" ] && cp -v "$f" "$BUILD_DIR/cockpit/web/" 2>/dev/null
done

echo "Staging scripts from: $SCRIPTS_SRC"
# Just the cockpit-related scripts — we know their names exactly
for f in agent_loop.sh ai_bridge.sh cockpit_start.sh cockpit_stop.sh crud_executor.sh; do
    if [ -f "$SCRIPTS_SRC/$f" ]; then
        cp -v "$SCRIPTS_SRC/$f" "$BUILD_DIR/cockpit/scripts/"
    else
        echo "  (skipped, not present: $f)"
    fi
done

# ── Generate VERSION and MANIFEST ──────────────────────────────────────────
# Write VERSION at the cockpit/ root (for the tarball metadata) AND inside
# cockpit/web/ so version.php can read it at runtime after install.
echo "$COCKPIT_VERSION" > "$BUILD_DIR/cockpit/VERSION"
echo "$COCKPIT_VERSION" > "$BUILD_DIR/cockpit/web/VERSION"

(
    cd "$BUILD_DIR/cockpit"
    {
        echo "# Cockpit ${COCKPIT_VERSION} — built $(date -Iseconds)"
        echo "# format: <sha256>  <relative path>"
        echo ""
        find web scripts -type f | sort | while read -r f; do
            sha256sum "$f"
        done
    } > MANIFEST.txt
)

# ── Tar it up ──────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
TAR_OUT="$OUT_DIR/$TARBALL_NAME"

(
    cd "$BUILD_DIR"
    tar -czf "$TAR_OUT" cockpit/
)

# ── Cleanup and summary ────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"

SIZE_KB=$(du -k "$TAR_OUT" | cut -f1)
echo ""
echo "─── Build complete ───"
echo "Tarball:  $TAR_OUT"
echo "Size:     ${SIZE_KB} KB"
echo "Files:    $(tar -tzf "$TAR_OUT" | wc -l)"
echo ""
echo "Inspect with:  tar -tzvf $TAR_OUT"
echo "Install with:  ./install_cockpit.sh $TAR_OUT"
