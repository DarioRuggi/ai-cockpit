#!/usr/bin/env bash
# =============================================================================
# install_opencode.sh — opencode (SST) free open-source terminal agent for the
# "Stay Free" Agent-CLI cards. Go binary, NO Python. Runs on your local Ollama
# models (no key, offline). Uses SST's official installer, which drops the binary
# on ~/.opencode/bin (already on the app's detection PATH); we also symlink it
# onto ~/.local/bin so the agent dispatch finds it.
#
# NOTE: opencode wants an Ollama model saved with num_ctx >= 16k (its default 4k
# truncates). Pull/create such a variant in the app's Local Models card.
#
# Usage: install_opencode.sh
# =============================================================================
set -euo pipefail

BIN_DIR="${OPENCODE_BIN_DIR:-$HOME/.local/bin}"
say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v curl >/dev/null 2>&1 || { echo "missing: curl"; exit 1; }

if command -v opencode >/dev/null 2>&1; then
    ok "opencode already present: $(opencode --version 2>/dev/null | head -1)"
else
    say "Installing opencode (SST, Go — no Python)…"
    curl -fsSL https://opencode.ai/install | bash \
        || { warn "opencode install script failed — see https://opencode.ai/docs for manual steps."; exit 1; }
fi

# SST's installer targets ~/.opencode/bin; symlink onto ~/.local/bin for the agent PATH.
mkdir -p "$BIN_DIR"
_oc="$(command -v opencode 2>/dev/null || echo "$HOME/.opencode/bin/opencode")"
[ -x "$_oc" ] && ln -sf "$_oc" "$BIN_DIR/opencode"
ok "opencode ready: $("$BIN_DIR/opencode" --version 2>/dev/null | head -1 || echo installed)"
ok "Enable it: Supplier Slots → set an Agent-CLI card to 'opencode [Free]'. Needs Ollama running (num_ctx >= 16k)."
