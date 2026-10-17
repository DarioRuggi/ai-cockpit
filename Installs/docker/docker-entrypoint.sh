#!/bin/bash
# =============================================================================
# AI Cockpit — Docker entrypoint
# Starts Ollama, opens empty Claude/Gemini tmux sessions ready for the
# containerized user to authenticate into, then runs Apache in the
# foreground (PID 1) so `docker stop` shuts things down cleanly.
# =============================================================================
set -e

COCKPIT_USER="${COCKPIT_USER:-cockpit}"
TMUX_SOCK="/var/www/html/cockpit/tmux.sock"

echo "[entrypoint] starting Ollama..."
su - "$COCKPIT_USER" -c "OLLAMA_MODELS='$OLLAMA_MODELS' nohup ollama serve > /tmp/ollama.log 2>&1 &"

# Wait for Ollama to actually come up before the app tries to use it
for i in $(seq 1 15); do
    curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break
    sleep 1
done

echo "[entrypoint] starting LocalAI..."
# --address 127.0.0.1:8080 is not optional: LocalAI refuses to start bound
# to a public-looking address with no auth configured (a real safety check
# hit and confirmed while testing this on bare metal) -- loopback-only is
# exactly what combos_localai_base() expects by default anyway.
su - "$COCKPIT_USER" -c "LOCALAI_MODELS_PATH='$LOCALAI_MODELS' nohup local-ai run --address 127.0.0.1:8080 > /tmp/localai.log 2>&1 &"

# Wait for LocalAI too, same pattern as Ollama above
for i in $(seq 1 15); do
    curl -s http://127.0.0.1:8080/readyz >/dev/null 2>&1 && break
    sleep 1
done

echo "[entrypoint] starting agent tmux sessions (cockpit_claude, cockpit_gemini, cockpit_ollama)..."
su - "$COCKPIT_USER" -c "tmux -S '$TMUX_SOCK' new-session -d -s cockpit_claude  'bash' 2>/dev/null || true"
su - "$COCKPIT_USER" -c "tmux -S '$TMUX_SOCK' new-session -d -s cockpit_gemini  'bash' 2>/dev/null || true"
su - "$COCKPIT_USER" -c "tmux -S '$TMUX_SOCK' new-session -d -s cockpit_ollama  'bash' 2>/dev/null || true"
chmod 775 "$TMUX_SOCK" 2>/dev/null || true

# Same fix as install_cockpit.sh/install_cockpit_macos.sh: paths.php's own
# fallback default (${HOME}/Projects) only matches if paths.json says so
# explicitly -- without this the app silently looks in the wrong place.
COCKPIT_HOME="/home/$COCKPIT_USER"
PROJECTS_ROOT="${COCKPIT_HOME}/Projects"
PATHS_JSON="/var/www/html/cockpit/paths.json"
if [ ! -d "$PROJECTS_ROOT" ]; then
    su - "$COCKPIT_USER" -c "mkdir -p '$PROJECTS_ROOT/_standalone' '$PROJECTS_ROOT/default'"
fi
if [ ! -f "$PATHS_JSON" ]; then
    su - "$COCKPIT_USER" -c "cat > '$PATHS_JSON'" <<EOF
{
    "_comment": "AI Cockpit -- runtime path configuration. Edit via the cockpit's Library/Config tab or directly. Changes take effect on the next request (no restart needed).",
    "projects_root": "${PROJECTS_ROOT}"
}
EOF
fi

cat <<'EOF'
=============================================================================
AI Cockpit is starting.

FIRST RUN ONLY — authenticate the agent CLIs (one-time, tokens persist in
the mounted cockpit-data volume):

    docker compose exec cockpit su - cockpit -c claude
    docker compose exec cockpit su - cockpit -c gemini

Then open:  http://localhost:8080
=============================================================================
EOF

echo "[entrypoint] starting Apache..."
exec apache2ctl -D FOREGROUND
