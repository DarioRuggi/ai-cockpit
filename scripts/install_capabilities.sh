#!/usr/bin/env bash
# =============================================================================
# install_capabilities.sh — Deploy built-in capability folders to ~/scripts/cockpit_data/capabilities/_builtin/
#
# Run after deploying capabilities.php. Idempotent — safe to re-run for upgrades.
#
# Usage: ./install_capabilities.sh [TARGET_DIR]
#   TARGET_DIR defaults to ~/scripts/cockpit_data/capabilities/_builtin
# =============================================================================

set -euo pipefail

TARGET_DIR="${1:-$HOME/scripts/cockpit_data/capabilities/_builtin}"
SOURCE_DIR="${BUILTINS_SOURCE:-$(dirname "$0")/cockpit_builtins}"

if [ ! -d "$SOURCE_DIR" ]; then
    echo "ERROR: Built-in source dir not found: $SOURCE_DIR"
    echo "Set BUILTINS_SOURCE env var to point at your cockpit_builtins/ folder."
    exit 1
fi

mkdir -p "$TARGET_DIR"

echo "Installing built-in capabilities..."
echo "  Source: $SOURCE_DIR"
echo "  Target: $TARGET_DIR"
echo ""

count=0
for cap in "$SOURCE_DIR"/*/; do
    cap_name=$(basename "$cap")
    [ "$cap_name" = "_builtin" ] && continue

    echo "  ▶ $cap_name"
    rm -rf "$TARGET_DIR/$cap_name"
    cp -r "$cap" "$TARGET_DIR/"
    count=$((count + 1))
done

# Permissions: writeable by user, readable by www-data (PHP)
if id -u www-data >/dev/null 2>&1; then
    chgrp -R www-data "$TARGET_DIR" 2>/dev/null || sudo chgrp -R www-data "$TARGET_DIR"
fi
chmod -R u+rwX,g+rX,o+rX "$TARGET_DIR"

echo ""
echo "✓ Installed $count built-in capabilities"
echo ""
echo "View them in the cockpit: Right sidebar → Capabilities tab"
