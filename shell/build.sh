#!/usr/bin/env bash
# Build cockpit_shell from source with Free Pascal (fpc 3.2+).
# Needs no -dev packages: every GTK / WebKitGTK symbol is loaded at run time.
# Usage:  bash build.sh [output-path]     (default: ./cockpit_shell)
set -e
cd "$(dirname "$0")"
OUT="${1:-$PWD/cockpit_shell}"
command -v fpc >/dev/null 2>&1 || { echo "fpc not found — install the fpc package (Free Pascal Compiler)"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fpc -O2 -Xs -XX -FE"$TMP" -FU"$TMP" -o"$OUT" cockpit_shell.pas >"$TMP/fpc.log" 2>&1 || { cat "$TMP/fpc.log"; exit 1; }
chmod +x "$OUT"
echo "built: $OUT ($(stat -c %s "$OUT") bytes)"
