#!/usr/bin/env bash
# deps_manifest.sh — the packages Cockpit installs from the internet, treated
# like models: know where each comes from, check monthly that it is still there,
# keep a copy on this rig (git-ignored Models/deps, mirrored to the F disk weekly),
# and publish a withdrawn one on ruggi.site/assets/files/tools/ so the installer's
# mirror fallback (fetch_mirror in install_cockpit.sh) can still get it.
#
#   check    : HEAD every upstream URL — report the ones that no longer answer
#   archive  : download the current artifact of each dependency into Models/deps/
#   list     : show the table
#
# name | upstream URL (or npm:package) | mirror file name on ruggi.site
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; DEST="$ROOT/Models/deps"
MIRROR_LIST="https://ruggi.site/backups.php?list=tools"
DEPS=(
  "ollama-linux-amd64|gh-latest:ollama/ollama:ollama-linux-amd64\.tar\.zst|ollama-linux-amd64.tar.zst"
  "localai-linux-amd64|gh-latest:mudler/LocalAI:local-ai-v[0-9.]+-linux-amd64|local-ai-linux-amd64"
  "piper-linux-x86_64|https://github.com/rhasspy/piper/releases/latest/download/piper_linux_x86_64.tar.gz|piper_linux_x86_64.tar.gz"
  "yt-dlp|https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp|yt-dlp"
  "bitwarden-cli|gh-latest:bitwarden/clients:bw-linux-[0-9.]+\\.zip|bw-linux.zip"
  "whisper-ggml-base|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin|ggml-base.bin"
  "whisper-ggml-small|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin|ggml-small.bin"
  "whisper-ggml-large-v3-turbo|https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin|ggml-large-v3-turbo.bin"
  "piper-voice-en_US-lessac|https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx|en_US-lessac-medium.onnx"
  "claude-code|npm:@anthropic-ai/claude-code|claude-code.tgz"
  "gemini-cli|npm:@google/gemini-cli|gemini-cli.tgz"
  "codex|npm:@openai/codex|codex.tgz"
  "qwen-code|npm:@qwen-code/qwen-code|qwen-code.tgz"
  "whisper.cpp-src|https://github.com/ggerganov/whisper.cpp/archive/refs/heads/master.tar.gz|whisper-cpp-src.tar.gz"
  "stable-diffusion.cpp-src|https://github.com/leejet/stable-diffusion.cpp/archive/refs/heads/master.tar.gz|stable-diffusion-cpp-src.tar.gz"
)
# gh-latest:owner/repo:REGEX → download URL of the newest release asset whose name matches
gh_asset(){ local spec repo re; spec="${1#gh-latest:}"; repo="${spec%%:*}"; re="${spec#*:}"; curl -fsSL -m 25 "https://api.github.com/repos/$repo/releases?per_page=30" | jq -r --arg re "^$re$" '[.[] | select(.draft==false and .prerelease==false)][] | .assets[] | select(.name|test($re)) | .browser_download_url' | head -1; }
resolve(){ case "$1" in gh-latest:*) gh_asset "$1" ;; *) echo "$1" ;; esac; }
# Three answers, not two. 0 = obtainable, 1 = GONE (the server said so: 404/410),
# 2 = COULDN'T TELL (no connection, a 5xx, or a rate limit). The second and third
# used to be the same answer, so a machine that was simply not online yet reported
# every package as withdrawn (2026-10-01: 85 false "withdrawn" at boot, 14s after
# power-on, from a Persistent timer firing before the network was up).
head_ok(){
  local u="$1" c
  case "$u" in
    gh-latest:*) local api; api=$(curl -s -o /dev/null -w '%{http_code}' -m 15 https://api.github.com/ 2>/dev/null)
                 # 403/429 = unauthenticated rate limit (60/hr), not "the asset is gone"
                 case "$api" in 200) ;; *) return 2 ;; esac
                 u=$(resolve "$u"); [ -n "$u" ] || return 1 ;;   # API fine, no matching asset: genuinely gone
  esac
  case "$u" in
    npm:*) c=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "https://registry.npmjs.org/${u#npm:}/latest") ;;
    *)     c=$(curl -sL -o /dev/null -w '%{http_code}' -m 25 -r 0-0 "$u") ;;
  esac
  case "$c" in 200|206) return 0 ;; 404|410) return 1 ;; *) return 2 ;; esac
}
case "${1:-list}" in
list) printf '%-28s %s\n' NAME UPSTREAM; for d in "${DEPS[@]}"; do IFS='|' read -r n u m <<<"$d"; printf '%-28s %s\n' "$n" "$u"; done ;;
check)
    gone=0; unk=0; for d in "${DEPS[@]}"; do IFS='|' read -r n u m <<<"$d"
        head_ok "$u"; rc=$?
        case $rc in 0) printf 'ok    %s\n' "$n" ;;
                    1) gone=$((gone+1)); printf 'GONE  %-28s %s\n' "$n" "$u" ;;
                    *) unk=$((unk+1));   printf '?     %-28s %s (could not tell)\n' "$n" "$u" ;; esac; done
    echo "# deps checked ${#DEPS[@]}, gone $gone, unreachable $unk"; [ "$gone" -eq 0 ] ;;
archive)
    mkdir -p "$DEST"; for d in "${DEPS[@]}"; do IFS='|' read -r n u m <<<"$d"; out="$DEST/$n"; mkdir -p "$out"
        case "$u" in
          npm:*) ( cd "$out" && npm pack "${u#npm:}" --silent >/dev/null 2>&1 ) && echo "  $n: $(ls -t "$out"/*.tgz | head -1 | xargs basename)" || echo "  $n: npm pack FAILED" ;;
          gh-latest:*) url=$(resolve "$u"); [ -n "$url" ] && curl -fsSL --retry 3 -o "$out/$(basename "$url")" "$url" && echo "  $n: $(basename "$url") ($(du -h "$out/$(basename "$url")" | cut -f1))" || echo "  $n: FAILED" ;;
          *) f="$out/$m"; curl -fsSL --retry 3 -o "$f.part" "$u" && mv "$f.part" "$f" && echo "  $n: $m ($(du -h "$f" | cut -f1))" || { rm -f "$f.part"; echo "  $n: FAILED $u"; } ;;
        esac
    done; echo "archive: $(du -sh "$DEST" | cut -f1) in $DEST (mirrored to F weekly)" ;;
*) echo "usage: $0 [list|check|archive]"; exit 2 ;;
esac
