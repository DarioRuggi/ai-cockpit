#!/bin/bash
# build.sh — cross-build locked_pc_probe.exe (Windows x64) on Linux with FPC 3.2.2, then make dist/locked_pc_probe.zip.
# No system change: the Windows RTL is compiled into a scratch folder (about 2 seconds) from the installed fpc-src package.
#   bash build.sh                      # needs: fpc, fpc-src (/usr/share/fpcsrc/3.2.2), zip
#   FPC_WIN_UNITS=/path/to/units/x86_64-win64 bash build.sh     # reuse an already-compiled Windows RTL
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${FPCSRC:-/usr/share/fpcsrc/3.2.2}"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
UNITS="${FPC_WIN_UNITS:-}"
if [ -z "$UNITS" ]; then
    [ -d "$SRC/rtl" ] || { echo "build.sh: FPC sources not found at $SRC (package fpc-src)"; exit 1; }
    mkdir -p "$W/src"; cp -r "$SRC/rtl" "$SRC/Makefile" "$SRC/Makefile.fpc" "$W/src/" 2>/dev/null || cp -r "$SRC/rtl" "$W/src/"
    ( cd "$W/src/rtl" && make all OS_TARGET=win64 CPU_TARGET=x86_64 FPC="$(command -v fpc)" >"$W/rtl.log" 2>&1 ) || { tail -20 "$W/rtl.log"; exit 1; }
    UNITS="$W/src/rtl/units/x86_64-win64"
fi
mkdir -p "$HERE/dist" "$W/o"
fpc -Twin64 -Px86_64 -Fu"$UNITS" -FE"$W/o" -FU"$W/o" "$HERE/locked_pc_probe.pas" 2>&1 | grep -iE "error|fatal" && exit 1
cp "$W/o/locked_pc_probe.exe" "$HERE/dist/"
cp "$HERE/locked_pc_probe.bat" "$HERE/README.txt" "$HERE/dist/"
( cd "$HERE/dist" && rm -f locked_pc_probe.zip && zip -q locked_pc_probe.zip locked_pc_probe.exe locked_pc_probe.bat README.txt )
ls -l "$HERE/dist"
