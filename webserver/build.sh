#!/usr/bin/env bash
# Build aicserver from source with Free Pascal (fpc 3.2+). No -dev packages: nothing is linked beyond the RTL (TLS is bound at run time).
# Usage:  bash build.sh [output-path]     (default: ./aicserver)
set -e
cd "$(dirname "$0")"
OUT="${1:-$PWD/aicserver}"
command -v fpc >/dev/null 2>&1 || { echo "fpc not found — install the fpc package (Free Pascal Compiler)"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fpc -O2 -Xs -Fu./src -FE"$TMP" -FU"$TMP" -o"$OUT" src/aicserver.lpr >"$TMP/fpc.log" 2>&1 || { grep -E "Error|Fatal" "$TMP/fpc.log" | head -20; exit 1; }
chmod +x "$OUT"
echo "built: $OUT ($(stat -c %s "$OUT") bytes)"
