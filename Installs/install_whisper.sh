#!/usr/bin/env bash
# =============================================================================
# install_whisper.sh — local speech-to-text (whisper.cpp) for the Transcriber's
# uploaded-video / local-file sources and SRT export.
#
# Builds ggerganov/whisper.cpp (Vulkan GPU, CPU fallback) into ~/ai-tools/whisper.cpp
# and downloads a ggml model. Binary exposed as build/bin/whisper-cli.
#
# System deps: build-essential cmake git curl  (+ libvulkan-dev glslc for GPU)
# Usage: install_whisper.sh [--cpu] [--model base|small|medium]
# =============================================================================
set -euo pipefail
fetch_mirror() { local url="$1" out="$2" name="$3"; curl -fL --retry 2 -o "$out" "$url" 2>/dev/null && return 0; echo "  upstream failed ($url) — trying ruggi.site mirror"; curl -fL --retry 2 -o "$out" "https://ruggi.site/backups.php?get=$name" 2>/dev/null && return 0; rm -f "$out"; return 1; }

PREFIX="${WHISPER_PREFIX:-$HOME/ai-tools/whisper.cpp}"
REPO="https://github.com/ggerganov/whisper.cpp"
MODEL="${WHISPER_MODEL:-base}"
WANT_GPU=1
while [ $# -gt 0 ]; do case "$1" in
    --cpu) WANT_GPU=0; shift ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done

say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }
for c in git cmake make g++; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 1; }; done

# 1. clone / update
if [ -d "$PREFIX/.git" ]; then say "Updating whisper.cpp"; git -C "$PREFIX" pull --ff-only || true
else say "Cloning whisper.cpp → $PREFIX"; mkdir -p "$(dirname "$PREFIX")"; git clone "$REPO" "$PREFIX"; fi

# 2. configure (Vulkan, CPU fallback)
BUILD="$PREFIX/build"
BACKEND="CPU"
if [ "$WANT_GPU" = "1" ] && [ -f /usr/include/vulkan/vulkan.h ]; then
    say "Configuring (Vulkan GPU)"
    if cmake -S "$PREFIX" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON >/dev/null 2>>"$PREFIX/build.log"; then BACKEND="Vulkan"
    else warn "Vulkan configure failed — CPU fallback"; rm -rf "$BUILD"; fi
fi
[ "$BACKEND" = "CPU" ] && { say "Configuring (CPU)"; cmake -S "$PREFIX" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null 2>>"$PREFIX/build.log"; }

# 3. build
say "Building (a few minutes)…"
cmake --build "$BUILD" --config Release -j"$(nproc)" >>"$PREFIX/build.log" 2>&1
BIN=""
for b in "$BUILD/bin/whisper-cli" "$BUILD/bin/main" "$BUILD/bin/whisper"; do [ -x "$b" ] && { BIN="$b"; break; }; done
[ -n "$BIN" ] || { echo "no whisper binary — see $PREFIX/build.log"; exit 1; }
# normalise name → whisper-cli (transcriber.php looks for it)
[ "$(basename "$BIN")" != "whisper-cli" ] && ln -sfn "$(basename "$BIN")" "$BUILD/bin/whisper-cli"
ok "built $BACKEND backend: $BIN"

# 4. model
mkdir -p "$PREFIX/models"
MODEL_FILE="$PREFIX/models/ggml-$MODEL.bin"
if [ -f "$MODEL_FILE" ]; then ok "model present: ggml-$MODEL.bin"
else
    say "Downloading whisper model: ggml-$MODEL.bin"
    fetch_mirror "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL.bin" "$MODEL_FILE" "ggml-$MODEL.bin" \
        && ok "model: $MODEL_FILE" || warn "model download failed — retry or place ggml-$MODEL.bin in $PREFIX/models/"
fi
# Record the chosen model so the app USES it. transcribe.php reads
# whisper_config.json when it names a model, and otherwise falls back to "auto",
# which means "largest installed wins". Nothing ever wrote that file, so the
# choice made here was silently discarded the moment a bigger model existed
# alongside it -- and a bigger model IS slower: measured 2026-09-25,
# large-v3-turbo runs at 1.17x realtime, so a 16s utterance costs 18.8s and
# Intercom feels laggy. Writing the file is what makes "base = fast" mean it.
# Existing keys are preserved: this only sets bin+model.
if [ -s "$MODEL_FILE" ]; then
    CD_DIR="${COCKPIT_DATA:-$HOME/scripts/cockpit_data}"
    CFG="$CD_DIR/whisper_config.json"
    WBIN="$PREFIX/build/bin/whisper-cli"
    [ -x "$WBIN" ] || WBIN="$(command -v whisper-cli 2>/dev/null || echo "$PREFIX/build/bin/whisper-cli")"
    if mkdir -p "$CD_DIR" 2>/dev/null && command -v php >/dev/null 2>&1; then
        php -r '
            $f=$argv[1]; $j=is_file($f) ? json_decode((string)file_get_contents($f),true) : [];
            if(!is_array($j)) $j=[];
            $j["bin"]=$argv[2]; $j["model"]=$argv[3];
            file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES)."\n");
        ' "$CFG" "$WBIN" "$MODEL_FILE" 2>/dev/null           && { chmod 0664 "$CFG" 2>/dev/null; ok "recorded your choice: $CFG (model=$MODEL)"; }           || warn "could not write $CFG — the app will fall back to the largest installed model"
    fi
fi

echo; if [ -s "$MODEL_FILE" ]; then ok "Done. Backend=$BACKEND, model=$MODEL. Transcriber can now transcribe local video."; else warn "Built (backend=$BACKEND) but NO model — the Transcriber will not work until ggml-$MODEL.bin is in $PREFIX/models/"; exit 1; fi
