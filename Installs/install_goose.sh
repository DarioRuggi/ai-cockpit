#!/usr/bin/env bash
# =============================================================================
# install_goose.sh — Goose (Block → Linux Foundation) free open-source agent for
# the "Stay Free" Agent-CLI cards. Rust CLI, NO Python. Runs on your local Ollama
# models (no key, offline). Uses Block's official installer, which drops the
# binary on ~/.local/bin (already on the app's detection + agent PATH).
#
# Usage: install_goose.sh
# =============================================================================
set -euo pipefail

BIN_DIR="${GOOSE_BIN_DIR:-$HOME/.local/bin}"
say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v curl >/dev/null 2>&1 || { echo "missing: curl"; exit 1; }

if command -v goose >/dev/null 2>&1; then
    ok "goose already present: $(goose --version 2>/dev/null | head -1)"
else
    say "Installing Goose (Block/Linux Foundation, Rust — no Python)…"
    # CONFIGURE=false skips the interactive provider wizard — Cockpit passes
    # GOOSE_PROVIDER/GOOSE_MODEL per call instead.
    curl -fsSL https://github.com/block/goose/releases/download/stable/download_cli.sh | CONFIGURE=false bash \
        || { warn "Goose install script failed — see https://block.github.io/goose/ for manual steps."; exit 1; }
fi

# Goose's installer targets ~/.local/bin already; make sure that's where the app looks.
mkdir -p "$BIN_DIR"
if [ ! -x "$BIN_DIR/goose" ] && command -v goose >/dev/null 2>&1; then
    ln -sf "$(command -v goose)" "$BIN_DIR/goose"
fi
ok "goose ready: $("$BIN_DIR/goose" --version 2>/dev/null | head -1 || goose --version 2>/dev/null | head -1)"
ok "Enable it: Supplier Slots → set an Agent-CLI card to 'Goose [Free]'. Needs Ollama running."
