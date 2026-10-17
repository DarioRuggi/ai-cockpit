#!/usr/bin/env bash
# =============================================================================
# install_aider.sh — Aider (free open-source coding agent) in an ISOLATED venv,
# for the "Stay Free" Agent-CLI cards. Aider runs on your LOCAL Ollama models —
# no API key, offline. It's a Python tool, so it goes in its OWN venv with a
# single symlink onto ~/.local/bin — the system Python is never touched.
#
#   binary exposed as:  ~/.local/bin/aider  (on the app's detection + agent PATH)
#   venv:               ~/scripts/cockpit_data/venv-aider
#
# Usage: install_aider.sh
# Env:   AIDER_VENV, AIDER_BIN_DIR to override locations.
# =============================================================================
set -euo pipefail

VENV="${AIDER_VENV:-$HOME/scripts/cockpit_data/venv-aider}"
BIN_DIR="${AIDER_BIN_DIR:-$HOME/.local/bin}"

say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

command -v python3 >/dev/null 2>&1 || { echo "missing: python3 (needed only to build the isolated venv)"; exit 1; }

if [ -x "$VENV/bin/aider" ]; then
    say "Updating aider-chat in $VENV"
    "$VENV/bin/pip" install -q --upgrade aider-chat || warn "update failed — keeping existing version"
else
    say "Creating isolated venv → $VENV (system Python untouched)"
    python3 -m venv "$VENV"
    # setuptools + wheel too: Python 3.14 venvs (Fedora 44) ship without them and
    # pip then cannot build the sdists aider pulls ("Cannot import setuptools.build_meta")
    "$VENV/bin/pip" install -q --upgrade pip setuptools wheel >/dev/null 2>&1 || true
    say "Installing aider-chat into the venv…"
    "$VENV/bin/pip" install -q aider-chat
fi

mkdir -p "$BIN_DIR"
ln -sf "$VENV/bin/aider" "$BIN_DIR/aider"

_ver="$("$VENV/bin/aider" --version 2>/dev/null || echo '?')"
ok "aider ready: $_ver  →  $BIN_DIR/aider"
ok "Enable it in the app: Supplier Slots → set an Agent-CLI card to 'Aider [Free]'."
ok "Aider needs Ollama running with at least one model (it uses your local models, no key)."
