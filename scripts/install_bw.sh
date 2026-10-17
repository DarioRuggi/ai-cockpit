#!/usr/bin/env bash
# install_bw.sh — fetch the official Bitwarden CLI (bw) into ~/.local/bin.
# Used by the AI Cockpit installer (optional step) and on demand. No sudo: the
# binary is per-user, which is also where cockpit_shell looks first.
# The CLI is Bitwarden's own release asset (GitHub: bitwarden/clients, tag
# cli-v*), verified by the archive's published sha256 when the release lists one.
set -e
DEST="${1:-$HOME/.local/bin}"
arch=$(uname -m); case "$arch" in x86_64) pat='bw-linux-[0-9.]+\.zip$' ;; aarch64|arm64) pat='bw-linux-arm64-[0-9.]+\.zip$' ;; *) echo "bw: no official Linux build for $arch"; exit 1 ;; esac
command -v curl >/dev/null && command -v jq >/dev/null && command -v unzip >/dev/null || { echo "bw: needs curl, jq, unzip"; exit 1; }
rel=$(curl -fsSL https://api.github.com/repos/bitwarden/clients/releases?per_page=40 | jq -r '[.[] | select(.tag_name|startswith("cli-"))][0]')
[ -n "$rel" ] && [ "$rel" != null ] || { echo "bw: could not read the release list"; exit 1; }
url=$(printf '%s' "$rel" | jq -r --arg p "$pat" '.assets[] | select(.name|test($p)) | .browser_download_url' | head -1)
tag=$(printf '%s' "$rel" | jq -r .tag_name)
[ -n "$url" ] || { echo "bw: no asset matching $pat in $tag"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "bw: downloading $tag ($(basename "$url"))"
curl -fsSL -o "$tmp/bw.zip" "$url"
sum=$(printf '%s' "$rel" | jq -r --arg n "$(basename "$url")" '.assets[] | select(.name == ($n + ".sha256")) | .browser_download_url' | head -1)
if [ -n "$sum" ]; then
    want=$(curl -fsSL "$sum" | awk '{print $1}'); have=$(sha256sum "$tmp/bw.zip" | awk '{print $1}')
    [ "$want" = "$have" ] || { echo "bw: sha256 mismatch — not installed"; exit 1; }
    echo "bw: sha256 verified"
fi
mkdir -p "$DEST"; unzip -qo "$tmp/bw.zip" -d "$tmp/x"; install -m 0755 "$tmp/x/bw" "$DEST/bw"
echo "bw: installed $("$DEST/bw" --version) at $DEST/bw"
echo "bw: next, in your terminal:  $DEST/bw login     (once; then Cockpit's Fill buttons unlock the vault when needed)"
