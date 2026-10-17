#!/usr/bin/env bash
# =============================================================================
# install_stable_diffusion.sh — local image generation for AI Cockpit.
#
# Builds leejet/stable-diffusion.cpp (Vulkan GPU backend, CPU fallback) into
# ~/ai-tools/sd.cpp, exposes an `sd-cli` symlink (generate.php looks for it),
# and optionally downloads an SD-1.5 checkpoint.
#
# System deps (install first, needs sudo):
#   Debian/Ubuntu:  sudo apt install -y build-essential cmake git curl \
#                     libvulkan-dev glslc glslang-tools spirv-headers spirv-tools
#   (Vulkan GPU backend needs glslc + spirv-headers; glslang-tools alone is not enough.)
# Usage:
#   install_stable_diffusion.sh [--cpu] [--model-url URL] [--no-model]
# =============================================================================
set -euo pipefail

PREFIX="${SD_PREFIX:-$HOME/ai-tools/sd.cpp}"
REPO="https://github.com/leejet/stable-diffusion.cpp"
MODEL_URL="${SD_MODEL_URL:-https://huggingface.co/stable-diffusion-v1-5/stable-diffusion-v1-5/resolve/main/v1-5-pruned-emaonly.safetensors}"
WANT_GPU=1; WANT_MODEL=1
while [ $# -gt 0 ]; do
    case "$1" in
        --cpu) WANT_GPU=0; shift ;;
        --no-model) WANT_MODEL=0; shift ;;
        --model-url) MODEL_URL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

for c in git cmake make g++; do command -v "$c" >/dev/null || { echo "missing build tool: $c (install build-essential cmake git)"; exit 1; }; done

# 1. clone / update
if [ -d "$PREFIX/.git" ]; then
    say "Updating stable-diffusion.cpp"; git -C "$PREFIX" pull --ff-only || true
    git -C "$PREFIX" submodule update --init --recursive
else
    say "Cloning stable-diffusion.cpp → $PREFIX"
    mkdir -p "$(dirname "$PREFIX")"
    git clone --recursive "$REPO" "$PREFIX"
fi

# 2. configure (try Vulkan GPU, fall back to CPU)
BUILD="$PREFIX/build"
configure(){ cmake -S "$PREFIX" -B "$BUILD" "$@" >/dev/null 2>>"$PREFIX/build.log"; }
BACKEND="CPU"
if [ "$WANT_GPU" = "1" ] && [ -f /usr/include/vulkan/vulkan.h ]; then
    say "Configuring (Vulkan GPU backend)"
    if configure -DCMAKE_BUILD_TYPE=Release -DSD_VULKAN=ON; then BACKEND="Vulkan";
    else warn "Vulkan configure failed (see $PREFIX/build.log) — falling back to CPU"; rm -rf "$BUILD"; fi
fi
if [ "$BACKEND" = "CPU" ]; then
    [ "$WANT_GPU" = "1" ] && warn "Building CPU-only (no vulkan headers / configure failed) — generation will be slow."
    say "Configuring (CPU backend)"
    configure -DCMAKE_BUILD_TYPE=Release
fi

# 3. build
say "Building (this takes several minutes)…"
cmake --build "$BUILD" --config Release -j"$(nproc)" >>"$PREFIX/build.log" 2>&1
BIN=""
for b in "$BUILD/bin/sd-cli" "$BUILD/bin/sd"; do [ -x "$b" ] && [ ! -L "$b" ] && { BIN="$b"; break; }; done
[ -n "$BIN" ] || { echo "build produced no sd/sd-cli binary — check $PREFIX/build.log"; exit 1; }
# generate.php prefers sd-cli. Only add the symlink when the REAL binary is `sd`
# — never symlink sd-cli onto itself (that clobbers the actual binary).
if [ "$(basename "$BIN")" != "sd-cli" ]; then ln -sfn "$(basename "$BIN")" "$BUILD/bin/sd-cli"; fi
ok "built $BACKEND backend: $BIN"

# 4. model
mkdir -p "$PREFIX/models"
if [ "$WANT_MODEL" = "1" ]; then
    if ls "$PREFIX"/models/*.safetensors "$PREFIX"/models/*.gguf "$PREFIX"/models/*.ckpt >/dev/null 2>&1; then
        ok "model already present: $(ls "$PREFIX"/models/*.safetensors 2>/dev/null | head -1)"
    else
        say "Downloading SD-1.5 checkpoint (~4 GB)…"
        if curl -fL --retry 3 -o "$PREFIX/models/sd-v1-5.safetensors" "$MODEL_URL"; then
            ok "model: $PREFIX/models/sd-v1-5.safetensors"
        else
            warn "Model download failed. Put any SD-1.5 .safetensors in $PREFIX/models/ (override with --model-url)."
        fi
    fi
else
    warn "Skipped model download (--no-model). Drop an SD checkpoint into $PREFIX/models/."
fi

echo; ok "Done. Backend=$BACKEND. Test image gen from the Cockpit generate button."
