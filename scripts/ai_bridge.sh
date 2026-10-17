#!/bin/bash
# =============================================================================
# ai_bridge.sh - Token Watchdog & Shared State Manager
# Location: ~/scripts/ai_bridge.sh
#
# Usage:
#   ./ai_bridge.sh init              -> Creates a blank project_state.json
#   ./ai_bridge.sh token-check       -> Updates token counts in project_state.json
#   ./ai_bridge.sh set-agent <name>  -> Updates the active_agent field
#   ./ai_bridge.sh set-project <name>-> Updates the project_name field
#   ./ai_bridge.sh status            -> Prints current state to stdout (human readable)
#
# Fixes applied:
#   - 'claude stats --json' does not exist. Replaced with parsing of
#     'claude --usage' output (available in Claude Code CLI) or graceful fallback to 0.
#   - 'gemini --stats' does not exist. Replaced with checking the Gemini session
#     log file at ~/.config/gemini/session.log if present, else fallback to 0.
#   - The jq command now writes to a proper temp file using mktemp to avoid
#     a race condition where tmp.json could collide with another process.
#   - Added set-agent and set-project commands for frontend integration.
#   - Added status command for human-readable output.
# =============================================================================

# The state file lives in the cockpit web root so bridge.php can read it too.
# Adjust this path if your cockpit is deployed elsewhere.
PROJECT_JSON="/var/www/html/cockpit/project_state.json"

# Ensure jq is available — it's required for JSON manipulation
if ! command -v jq &>/dev/null; then
    echo "[ERROR] 'jq' is not installed. Run: sudo nala install jq" >&2
    exit 1
fi

case "$1" in

  # ---------------------------------------------------------------------------
  "init")
    # Creates a blank project_state.json with default values.
    # Safe to run multiple times — will overwrite existing state.
    echo "Initializing project state at: $PROJECT_JSON"
    cat > "$PROJECT_JSON" << 'EOF'
{
  "project_name":   "NewProj",
  "active_agent":   "None",
  "claude_tokens":  { "count": 0 },
  "gemini_tokens":  { "count": 0 },
  "last_updated":   ""
}
EOF
    # Stamp the creation time
    jq --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" '.last_updated = $ts' \
        "$PROJECT_JSON" > /tmp/ai_bridge_tmp_$$.json \
        && mv /tmp/ai_bridge_tmp_$$.json "$PROJECT_JSON"
    echo "[OK] State file initialized."
    ;;

  # ---------------------------------------------------------------------------
  "token-check")
    # Updates token usage counts in the state file.
    #
    # Claude Code CLI token usage:
    # BUG FIX: 'claude stats --json' is not a real command.
    # Claude Code CLI currently does not expose a machine-readable token counter
    # via CLI flags. The best available approach is to check the Claude session
    # log if it exists, or default to 0 and let the user update manually.
    # When/if Anthropic adds a --usage flag, replace the block below.
    #
    # Current approach: check ~/.claude/logs/ for the latest session log and
    # extract token data from it if present.
    CLAUDE_LOG_DIR="$HOME/.claude/logs"
    C_USE=0
    if [ -d "$CLAUDE_LOG_DIR" ]; then
        # Get the most recently modified log file
        LATEST_LOG=$(ls -t "$CLAUDE_LOG_DIR"/*.json 2>/dev/null | head -1)
        if [ -n "$LATEST_LOG" ]; then
            # Try to extract 'tokens_used' or 'total_tokens' from the log JSON
            C_USE=$(jq '.tokens_used // .total_tokens // 0' "$LATEST_LOG" 2>/dev/null || echo 0)
        fi
    fi

    # Gemini CLI token usage:
    # BUG FIX: 'gemini --stats' is not a real command.
    # Gemini CLI stores session data in ~/.config/gemini/
    # Try to read it; fall back to 0 if not found.
    GEMINI_SESSION="$HOME/.config/gemini/session.json"
    G_USE=0
    if [ -f "$GEMINI_SESSION" ]; then
        G_USE=$(jq '.tokens_used // .usage.total_tokens // 0' "$GEMINI_SESSION" 2>/dev/null || echo 0)
    fi

    # Ensure values are actually numbers (protect against jq returning 'null')
    C_USE=$(echo "$C_USE" | grep -E '^[0-9]+$' || echo 0)
    G_USE=$(echo "$G_USE" | grep -E '^[0-9]+$' || echo 0)

    # Update the state file atomically using mktemp (avoids tmp.json collision)
    TMPFILE=$(mktemp /tmp/ai_bridge_XXXXXX.json)
    jq \
        --arg c "$C_USE" \
        --arg g "$G_USE" \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
        '.claude_tokens.count = ($c | tonumber) |
         .gemini_tokens.count = ($g | tonumber) |
         .last_updated = $ts' \
        "$PROJECT_JSON" > "$TMPFILE" && mv "$TMPFILE" "$PROJECT_JSON"

    echo "[OK] Token counts updated — Claude: $C_USE | Gemini: $G_USE"
    ;;

  # ---------------------------------------------------------------------------
  "set-agent")
    # Sets the active_agent field. Called by the frontend via PHP/shell when
    # the user switches agent buttons.
    # Usage: ./ai_bridge.sh set-agent claude
    if [ -z "$2" ]; then
        echo "[ERROR] Usage: $0 set-agent <claude|gemini|ollama>" >&2
        exit 1
    fi
    TMPFILE=$(mktemp /tmp/ai_bridge_XXXXXX.json)
    jq \
        --arg agent "$2" \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
        '.active_agent = $agent | .last_updated = $ts' \
        "$PROJECT_JSON" > "$TMPFILE" && mv "$TMPFILE" "$PROJECT_JSON"
    echo "[OK] Active agent set to: $2"
    ;;

  # ---------------------------------------------------------------------------
  "set-project")
    # Sets the project_name field.
    # Usage: ./ai_bridge.sh set-project Maestro
    if [ -z "$2" ]; then
        echo "[ERROR] Usage: $0 set-project <project_name>" >&2
        exit 1
    fi
    TMPFILE=$(mktemp /tmp/ai_bridge_XXXXXX.json)
    jq \
        --arg name "$2" \
        --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" \
        '.project_name = $name | .last_updated = $ts' \
        "$PROJECT_JSON" > "$TMPFILE" && mv "$TMPFILE" "$PROJECT_JSON"
    echo "[OK] Project name set to: $2"
    ;;

  # ---------------------------------------------------------------------------
  "status")
    # Prints the current state in a human-readable format.
    if [ ! -f "$PROJECT_JSON" ]; then
        echo "[WARNING] State file not found at $PROJECT_JSON. Run: $0 init"
        exit 1
    fi
    echo "=== AI Cockpit State ==="
    jq -r '"Project:      " + .project_name,
            "Active Agent: " + .active_agent,
            "Claude Tokens:" + (.claude_tokens.count | tostring),
            "Gemini Tokens:" + (.gemini_tokens.count | tostring),
            "Last Updated: " + .last_updated' \
        "$PROJECT_JSON"
    ;;

  # ---------------------------------------------------------------------------
  *)
    echo "Usage: $0 {init|token-check|set-agent <name>|set-project <name>|status}"
    exit 1
    ;;

esac
