#!/bin/bash
# =============================================================================
# agent_loop.sh - Agent Queue Watcher v3 (CRUD + JSON chat persistence)
# Location: ~/scripts/agent_loop.sh
# Pure bash + awk/sed/grep only — no Python, no Java, no Node.
# =============================================================================

AGENT="$1"
# ${VAR^^} is bash 4 ONLY and macOS ships bash 3.2 as /bin/bash (this script's
# shebang), so every log line below was a "bad substitution" that killed the
# agent loop on a Mac. tr is POSIX. AGENT never changes, so uppercase it once
# rather than forking tr 21 times per request. Found 2026-09-23.
uc() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
log() { echo "[${AGENT_UC}]$*"; }   # was called (engine refused) but never defined: "log: command not found" on stderr
AGENT_UC="$(uc "$AGENT")"
QUEUE_DIR="${COCKPIT_QUEUE_DIR:-/var/www/html/cockpit/queue}"
RESPONSE_DIR="${COCKPIT_RESPONSE_DIR:-/var/www/html/cockpit/responses}"
# Read the projects root from the app's runtime config (paths.json) instead of
# hardcoding it — keeps the agent in sync with what the installer/UI actually set.
_PATHS_JSON="$(dirname "$QUEUE_DIR")/paths.json"
if [ -f "$_PATHS_JSON" ] && command -v jq >/dev/null 2>&1; then
    COCKPIT_ROOT="$(jq -r '.projects_root // empty' "$_PATHS_JSON" 2>/dev/null)"
fi
[ -z "${COCKPIT_ROOT:-}" ] && COCKPIT_ROOT="$HOME/Software/Programing/LocalAIProjs"
export COCKPIT_ROOT
SCRIPTS_DIR="${COCKPIT_SCRIPTS_DIR:-$HOME/scripts}"   # the override is for a test copy that must run the scripts about to ship (Installs/sandbox)
# Per-edition data dir (v1 vs v2). Defaults to v2 when unset.
_DATA="${COCKPIT_DATA_DIR:-$_DATA}"

MAX_HISTORY=6   # exchanges (user+agent pairs) to include in context

# Free CLIs live outside npm-global: opencode in ~/.opencode/bin (+ ~/.local/bin symlink), aider/goose in ~/.local/bin
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
# Stop button (2026-10-06): bridge.php 'cleanup' sends Ctrl-C to this pane to halt the running CLI. The signal goes to the whole foreground
# process group, i.e. the CLI AND this loop. With no handler the loop died with it, the tmux session still existed (status.php only checks
# that), and every later prompt sat in the queue unanswered until someone restarted the session. With a handler, bash lets the CLI die from
# the signal, runs the handler, and carries on with the request (the partial answer is saved) and with the next one.
# tests/stop_survival_test.sh proves it with a private tmux and a fake CLI.
trap 'echo "[agent] interrupted (Stop pressed) -- still serving"' INT
export OLLAMA_MODELS="$HOME/ollama/models"

# Load Ollama operational knobs from cockpit config
_OLLAMA_CFG="$_DATA/ollama_config.json"
if [ -f "$_OLLAMA_CFG" ]; then
    _ka=$(python3 -c "import json;print(json.load(open('$_OLLAMA_CFG')).get('keep_alive','5m'))" 2>/dev/null)
    _np=$(python3 -c "import json;print(json.load(open('$_OLLAMA_CFG')).get('num_parallel',1))" 2>/dev/null)
    _ml=$(python3 -c "import json;print(json.load(open('$_OLLAMA_CFG')).get('max_loaded',1))" 2>/dev/null)
    [ -n "$_ka" ] && export OLLAMA_KEEP_ALIVE="$_ka"
    [ -n "$_np" ] && export OLLAMA_NUM_PARALLEL="$_np"
    [ -n "$_ml" ] && export OLLAMA_MAX_LOADED_MODELS="$_ml"
fi
export GEMINI_CLI_TRUST_WORKSPACE=true
export NO_COLOR=1
export TERM=dumb

# Gemini Code Assist OAuth was discontinued for individual accounts ("migrate to
# Antigravity"). Use a free AI Studio API key instead: drop it in the file below
# and the gemini CLI picks it up via GEMINI_API_KEY (generativelanguage API).
_GEMINI_KEY_F="$_DATA/gemini_api_key.txt"
if [ -f "$_GEMINI_KEY_F" ]; then
    _gk="$(tr -d '[:space:]' < "$_GEMINI_KEY_F" 2>/dev/null)"
    [ -n "$_gk" ] && export GEMINI_API_KEY="$_gk"
fi
# Groq free-REST fallback (Card 2 alternative). Key file → GROQ_API_KEY.
_GROQ_KEY_F="$_DATA/groq_api_key.txt"
if [ -f "$_GROQ_KEY_F" ]; then
    _qk="$(tr -d '[:space:]' < "$_GROQ_KEY_F" 2>/dev/null)"
    [ -n "$_qk" ] && export GROQ_API_KEY="$_qk"
fi

# =============================================================================
# Supplier slot resolution — map slot aliases to actual CLI tools
# Reads cockpit_data/supplier_slots.json to find which CLI binary to use.
# Slot aliases: claude=primary, gemini=fallback, ollama=local
# =============================================================================
# Both resolvers take the cockpit_data dir to read from. supplier_slots.json and
# cli_suppliers.json are PER-USER (users/<login>/) since paths.php's per-user
# scoping; this loop only knew the shared root, so a Card 2 set to opencode still
# ran the Gemini CLI (rig, 2026-09-21). Startup resolves from the shared root
# (may find nothing → the alias' own name); every request re-resolves from the
# cockpit_data its meta names, which is the user's.
resolve_supplier() {
    local _D="$1" _SLOTS_F="$1/supplier_slots.json" _CLI_CAT_F
    CLI_SUPPLIER=""; CLI_BINARY=""; CLI_PROMPT_FLAG="-p"; CLI_MODEL_FLAG=""; CLI_EFFORT_FLAG=""
    CLI_PARSE="text"; CLI_EXTRA_ARGS=""; CLI_MODEL_PREFIX=""; CLI_BACKEND=""; CLI_RELAY=""; CLI_HASBIN=""; CLI_SUBCMD=""; CLI_ENV=""
    CLI_IMAGE_FLAG=""; CLI_IMAGE_SEP=0; CLI_PROMPT_STYLE="plain"
    [ "$AGENT" = "claude" ] || [ "$AGENT" = "gemini" ] || return 0
    local _SLOT_KEY="primary"
    [ "$AGENT" = "gemini" ] && _SLOT_KEY="fallback"
    if [ -f "$_SLOTS_F" ] && command -v jq >/dev/null 2>&1; then
        CLI_SUPPLIER=$(jq -r ".$_SLOT_KEY // empty" "$_SLOTS_F" 2>/dev/null)
    fi
    [ -z "$CLI_SUPPLIER" ] && CLI_SUPPLIER="$AGENT"

    # Load CLI catalog for this supplier (per-user copy first, shared root second)
    # cli_catalog.json = the merged catalog suppliers.php materialises (defaults + override); per-user dir first
    _CLI_CAT_F=""; for _c in "$_D/cli_catalog.json" "$_DATA/cli_catalog.json" "$_D/cli_suppliers.json" "$_DATA/cli_suppliers.json"; do [ -f "$_c" ] && { _CLI_CAT_F="$_c"; break; }; done
    CLI_CATALOG_FILE=""; [ -f "$_CLI_CAT_F" ] && CLI_CATALOG_FILE="$_CLI_CAT_F"      # the engine reads the same merged catalog
    if [ -f "$_CLI_CAT_F" ] && command -v jq >/dev/null 2>&1; then
        CLI_BINARY=$(jq -r ".[\"$CLI_SUPPLIER\"].binary // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_PROMPT_FLAG=$(jq -r ".[\"$CLI_SUPPLIER\"].cli_flag // \"-p\"" "$_CLI_CAT_F" 2>/dev/null)
        CLI_MODEL_FLAG=$(jq -r ".[\"$CLI_SUPPLIER\"].model_flag // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_EFFORT_FLAG=$(jq -r ".[\"$CLI_SUPPLIER\"].effort_flag // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_PARSE=$(jq -r ".[\"$CLI_SUPPLIER\"].parse // \"text\"" "$_CLI_CAT_F" 2>/dev/null)
        CLI_EXTRA_ARGS=$(jq -r ".[\"$CLI_SUPPLIER\"].extra_args // empty" "$_CLI_CAT_F" 2>/dev/null)
        # Native image input (catalog image_mode=flag): the flag to pass each file
        # on, and whether a `--` must follow because that flag is variadic.
        CLI_IMAGE_FLAG=$(jq -r "if .[\"$CLI_SUPPLIER\"].image_mode == \"flag\" then (.[\"$CLI_SUPPLIER\"].image_flag // empty) else empty end" "$_CLI_CAT_F" 2>/dev/null)
        CLI_IMAGE_SEP=$(jq -r "if .[\"$CLI_SUPPLIER\"].image_needs_sep then 1 else 0 end" "$_CLI_CAT_F" 2>/dev/null)
        CLI_PROMPT_STYLE=$(jq -r ".[\"$CLI_SUPPLIER\"].prompt_style // \"plain\"" "$_CLI_CAT_F" 2>/dev/null)
        # Local-agent support (e.g. Aider→Ollama): model_prefix qualifies the model
        # string (ollama_chat/<tag>); backend=ollama exports OLLAMA_API_BASE; relay
        # marks REST/Workers-dispatched suppliers (no local binary).
        CLI_MODEL_PREFIX=$(jq -r ".[\"$CLI_SUPPLIER\"].model_prefix // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_BACKEND=$(jq -r ".[\"$CLI_SUPPLIER\"].backend // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_RELAY=$(jq -r ".[\"$CLI_SUPPLIER\"].relay // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_HASBIN=$(jq -r ".[\"$CLI_SUPPLIER\"].binary // empty" "$_CLI_CAT_F" 2>/dev/null)
        CLI_SUBCMD=$(jq -r ".[\"$CLI_SUPPLIER\"].subcmd // empty" "$_CLI_CAT_F" 2>/dev/null)   # e.g. goose/opencode "run"
        CLI_ENV=$(jq -r ".[\"$CLI_SUPPLIER\"].env // empty" "$_CLI_CAT_F" 2>/dev/null)          # e.g. "GOOSE_PROVIDER=ollama GOOSE_MODEL=%MODEL%"
    fi
    [ -z "$CLI_BINARY" ] && CLI_BINARY="$CLI_SUPPLIER"
    return 0
}
resolve_supplier "$_DATA"

# opencode does not read OLLAMA_API_BASE: its Ollama access is a provider block in
# ~/.config/opencode/opencode.json that must also list the model by name, else every
# run ends in "Unexpected server error" (rig, 2026-09-21). Merge ours in before each
# run, keeping whatever else the person configured there.
opencode_ensure_provider() {
    local _tag="$1" _cfgd="$HOME/.config/opencode" _cfg="$HOME/.config/opencode/opencode.json" _tmp
    [ -n "$_tag" ] && [ "$_tag" != "auto" ] && [ "${HAS_JQ:-0}" -eq 1 ] || return 0
    mkdir -p "$_cfgd" 2>/dev/null
    [ -s "$_cfg" ] || printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$_cfg"
    jq -e --arg t "$_tag" '.provider.ollama.models[$t] != null' "$_cfg" >/dev/null 2>&1 && return 0
    _tmp=$(mktemp)
    jq --arg t "$_tag" --arg b "${LOCAL_BASE:-http://127.0.0.1:11434}/v1" \
       '.provider.ollama.npm = "@ai-sdk/openai-compatible" | .provider.ollama.name = (.provider.ollama.name // "Ollama (local)") | .provider.ollama.options.baseURL = $b | .provider.ollama.models[$t] = {name: $t}' \
       "$_cfg" > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_cfg" || rm -f "$_tmp"
}
# ── Portable userland helpers (Linux + macOS) ────────────────────────────────
# macOS ships BSD tools, and three differences matter here:
#   sed -i        BSD takes the NEXT ARGUMENT as a backup suffix, so `sed -i -e`
#                 silently consumes the -e. GNU takes none.
#   stat -c       BSD spells it -f with different format letters.
#   readlink -f   Not in older BSD readlink at all.
# These wrappers pick the right form once, so the rest of the script reads the
# same on both systems.
if sed --version >/dev/null 2>&1; then _SED_INPLACE=(-i); else _SED_INPLACE=(-i ''); fi
sedi() { sed "${_SED_INPLACE[@]}" "$@"; }
stat_gid()  { stat -c %g "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null; }
stat_user() { stat -c %U "$1" 2>/dev/null || stat -f %Su "$1" 2>/dev/null; }

# ── Dialects ─────────────────────────────────────────────────────────────────
# Agents are not addressed identically. Claude is trained to read XML-ish tags as
# structural markers separating instructions from material, and its own guidance
# says so; most other CLIs are not, and tags there are just noise the model has to
# read past. So the catalog says which dialect an agent speaks (prompt_style:
# xml | plain, absent = plain) and these two helpers wrap a section or do nothing.
#
# Quiet by design: a wrong guess costs a few tokens, never correctness.
dialect_open()  { [ "${CLI_PROMPT_STYLE:-plain}" = "xml" ] && printf '<%s>\n' "$1" || true; }
dialect_close() { [ "${CLI_PROMPT_STYLE:-plain}" = "xml" ] && printf '</%s>\n' "$1" || true; }

# ── CLI config isolation ─────────────────────────────────────────────────────
# A CLI agent Cockpit starts would otherwise read the personal Claude Code config
# of whoever runs the machine: hooks, plugins, skills and global memory. That is
# not theoretical — a caveman-mode SessionStart hook silently rewrote every
# Cockpit answer on this rig (2026-09-22) while Cockpit's own Mode/Style said
# nothing of the sort, and the same hook class had already broken the NDJSON
# parse path this file works around above.
#
# So by default we point the CLI at a Cockpit-owned config dir holding nothing
# but the LOGIN (symlinked, so token refreshes still reach the real file) and an
# empty settings.json. Turning the "Use my global CLI config" capability on skips
# all of this and lets the agent read the user's own config, deliberately.
# Returns with CLAUDE_CONFIG_DIR exported, or unset when inheriting.
cockpit_cli_isolate() {
    local _capsF="${REQ_DATA:-}/capabilities/global_caps.json"
    local _inherit=0
    if [ -f "$_capsF" ]; then
        if [ "${HAS_JQ:-0}" -eq 1 ]; then
            [ "$(jq -r '.inherit_cli_config // false' "$_capsF" 2>/dev/null)" = "true" ] && _inherit=1
        else
            grep -q '"inherit_cli_config"[[:space:]]*:[[:space:]]*true' "$_capsF" 2>/dev/null && _inherit=1
        fi
    fi
    if [ "$_inherit" = 1 ]; then
        unset CLAUDE_CONFIG_DIR
        return 0
    fi
    local _dir="${REQ_DATA:-$HOME/.cockpit}/cli_config/claude"
    mkdir -p "$_dir" 2>/dev/null || { unset CLAUDE_CONFIG_DIR; return 0; }
    # Login only. A symlink (not a copy) so a refreshed token is written back to
    # the real credential file and the user never has to log in twice.
    #
    # The symlink DOES NOT SURVIVE (measured 2026-09-30). The CLI rewrites the
    # credential file atomically -- temp file plus rename() -- and a rename
    # REPLACES a symlink with a regular file. On this rig the isolated copy had
    # been refreshing for eight days while ~/.claude/.credentials.json sat
    # untouched: two independent inodes, not one.
    #
    # Worse than the divergence: the replacement file is created inside this
    # setgid 2775 directory, so it inherits group `dario` and mode 660 -- while
    # the real one is 600. The web tier runs as www-data, which Cockpit puts in
    # that group for the socket, so a credential that was owner-only became
    # readable by the web server. Nothing needs that: the agent runs as the
    # owning user through tmux, never as www-data.
    #
    # Re-tighten on every run. This is the half with no trade-off; whether the
    # refreshed token should be copied back over the user's real credential file
    # is the user's call, not something to do silently.
    [ -e "$HOME/.claude/.credentials.json" ] && [ ! -e "$_dir/.credentials.json" ] \
        && ln -sf "$HOME/.claude/.credentials.json" "$_dir/.credentials.json" 2>/dev/null
    [ -f "$_dir/.credentials.json" ] && [ ! -L "$_dir/.credentials.json" ] \
        && chmod 600 "$_dir/.credentials.json" 2>/dev/null
    [ -f "$_dir/settings.json" ] || printf '{}\n' > "$_dir/settings.json" 2>/dev/null
    # Trust the dirs Cockpit runs agents in. A fresh config dir has no trust
    # record, and the CLI then prints a "workspace has not been trusted" notice
    # that would be captured as part of the answer on the non-jq path.
    local _cj="$_dir/.claude.json"
    [ -f "$_cj" ] || printf '{"projects":{}}\n' > "$_cj" 2>/dev/null
    if [ "${HAS_JQ:-0}" -eq 1 ]; then
        local _d _tmp="$_cj.tmp.$$"
        for _d in "$PROJECT_DIR" "$COCKPIT_ROOT"; do
            [ -n "$_d" ] || continue
            grep -q "\"$_d\"" "$_cj" 2>/dev/null && continue
            jq --arg d "$_d" '.projects[$d].hasTrustDialogAccepted = true' "$_cj" > "$_tmp" 2>/dev/null \
                && mv -f "$_tmp" "$_cj" || rm -f "$_tmp"
        done
    fi
    export CLAUDE_CONFIG_DIR="$_dir"
}

# ── Engine hand-off (opt-in) ─────────────────────────────────────────────────
# The step that SPAWNS the agent (argument building, environment, process group, stdin,
# the answer landing in OUT_FILE) can be done by aicengine (Free Pascal) instead of the
# Bash below. Off by default; switch it on with COCKPIT_ENGINE=1 in the environment, or by
# creating the file use_engine in the user's cockpit_data (or the shared one). The Bash
# path stays complete and is used whenever the engine is missing or refuses a request
# (exit 2), so turning it on can never leave an agent without an answer.
# What the engine does and how it is proven equal: aicockpit-runtime/aicengine/README.md,
# tests/legacy_parity.sh.
engine_bin() {
    local _b
    for _b in "${COCKPIT_ENGINE_BIN:-}" "$HOME/scripts/aicengine" "$(command -v aicengine 2>/dev/null)"; do
        [ -n "$_b" ] && [ -x "$_b" ] && { printf '%s' "$_b"; return 0; }
    done
    return 1
}
engine_enabled() {
    [ "${COCKPIT_ENGINE:-}" = "1" ] && return 0
    [ -f "${REQ_DATA:-/nonexistent}/use_engine" ] || [ -f "${_DATA:-/nonexistent}/use_engine" ]
}

# The whole loop can run as the native program (`aicengine loop <agent>`: the same steps, no jq/sed/bc/curl; it needs PHP only for the chat history and
# the %%markers%%). Its own switch, because it replaces this script rather than one step of it: the file use_native_loop in the data folder (or
# COCKPIT_NATIVE_LOOP=1). It takes over the process (exec), so the supervisor, tmux and the Stop signal see the same pid and the same arguments' agent.
# An engine too old to have `loop`, or no engine at all, leaves this script running as before. Proof: tests/loop_native_test.sh.
if [ "${COCKPIT_NATIVE_LOOP:-}" = "1" ] || [ -f "${_DATA:-/nonexistent}/use_native_loop" ] || [ -f "${_DATA:-/nonexistent}/use_native_loop_$AGENT" ]; then   # one agent: use_native_loop_ollama
    _nl=$(engine_bin) && "$_nl" version 2>/dev/null | grep -q ' loop' && exec "$_nl" loop "$AGENT"
fi

# The chat-history half of this script (the gate, the index, the transcript renderers) can also be done by
# history_cli.php, the same logic without sqlite3/jq/awk/sed/python3. Same switch as the engine; the Bash
# below stays complete and is used whenever the helper cannot run (no php, file missing, it fails).
# Proof of equality: tests/history_parity.sh.
history_cli() {
    local _h="${SCRIPTS_DIR:-$HOME/scripts}/history_cli.php"
    [ -f "$_h" ] && command -v php >/dev/null 2>&1 && printf '%s' "$_h"
}

# Carrying out the %%COMMAND%% markers of a response (crud_executor.sh) can be done by crud_cli.php: the same
# interpreter without jq/awk/sed/head/realpath. Same switch. Chosen BEFORE it runs and never retried afterwards:
# unlike the history helper, a half-finished run must not be repeated (an APPEND or a DELETE twice is not harmless).
# Proof of equality: tests/crud_parity.sh.
# The first half of a turn (token, meta, model file, paths, the prompt with its effort text, the extra CLI arguments) can be done by
# `aicengine intake`; same switch. It refuses (exit 2) BEFORE removing anything for the few inputs it does not copy, and then the Bash below
# runs unchanged. Proof of equality: tests/intake_parity.sh. Sets the loop's globals, so it must not be called inside $( ).
intake_engine() {   # $1 = the prompt file
    engine_enabled || return 1
    local _eng _po _sh
    _eng=$(engine_bin) || return 1
    _po=$(mktemp "${TMPDIR:-/tmp}/ckpo.XXXXXX") || return 1
    _sh=$("$_eng" intake --agent "$AGENT" --queue-dir "$QUEUE_DIR" --response-dir "$RESPONSE_DIR" --prompt-file "$1" --root "$COCKPIT_ROOT" --prompt-out "$_po" 2>/dev/null) || { rm -f "$_po"; return 1; }
    eval "$_sh"
    USER_PROMPT=$(cat "$_po"); rm -f "$_po"
    [ "$META_FOUND" = 1 ] || echo "[${AGENT_UC}] WARNING: no metadata for ${TOKEN} — falling back to the shared root and default project/models; this turn may be saved to the wrong chat"
    if [ "$META_FOUND" = 1 ]; then
        internal_setup
        if [ -n "$REQ_DATA" ] && [ -f "$REQ_DATA/supplier_slots.json" ]; then resolve_supplier "$REQ_DATA"; resolve_local "$REQ_DATA"; fi
    fi
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR" 2>/dev/null || cd "$COCKPIT_ROOT" 2>/dev/null || true
    return 0
}

# The capabilities, Workers and Tools auto-route steps of a turn can be done by `aicengine route` (same switch). It refuses (exit 2)
# BEFORE writing anything for the few inputs it does not copy (Gemini's MCP merge, odd skill files, non-string provider names), and then the
# Bash below runs unchanged. Proof of equality: tests/route_parity.sh. Sets OLLAMA_CAPS_PROMPT / WORKERS_AUTO_PROMPT / TOOLS_AUTO_PROMPT.
route_engine() {
    engine_enabled || return 1
    local _eng _sh
    _eng=$(engine_bin) || return 1
    _sh=$("$_eng" route --agent "$AGENT" --project "$PROJECT" --project-dir "$PROJECT_DIR" --data-dir "$_DATA" --base-url "${COCKPIT_BASE_URL:-http://localhost/cockpit}" --home "$HOME" 2>/dev/null) || return 1
    eval "$_sh"
}

# The loop's credential for the pages the markers call (cockpit_app/internal_auth.php). The key file is made here, never by the web server:
# 32 random bytes, mode 0640 (the owner's group = the web server's account, as with the supervisor token). The person is the owner of this
# request's data folder (<data>/users/<login>); with no such folder no headers are sent and those pages answer 401, as before.
# Also points the calls at THIS edition's pages: the default http://localhost/cockpit would make a V1 loop call V2.
internal_setup() {
    unset COCKPIT_INTERNAL_KEY COCKPIT_INTERNAL_USER
    local _kf="${_DATA:-}/internal_key" _login=""
    COCKPIT_BASE_URL="${COCKPIT_BASE_URL_OVERRIDE:-http://localhost/$(basename "${QUEUE_DIR%/queue}")}"; export COCKPIT_BASE_URL   # the override is for a test copy on its own port (Installs/sandbox)
    [ -n "${_DATA:-}" ] && [ -d "$_DATA" ] || return 0
    if [ ! -s "$_kf" ]; then
        ( umask 077; head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$_kf.new" ) 2>/dev/null && chmod 640 "$_kf.new" 2>/dev/null && mv -f "$_kf.new" "$_kf" 2>/dev/null
    fi
    [ -s "$_kf" ] || return 0
    case "${REQ_DATA:-}" in */users/*) _login="${REQ_DATA##*/users/}"; _login="${_login%%/*}" ;; esac
    case "$_login" in ""|*[!A-Za-z0-9_-]*) return 0 ;; esac
    COCKPIT_INTERNAL_KEY=$(tr -d ' \r\n' < "$_kf"); COCKPIT_INTERNAL_USER="$_login"
    export COCKPIT_INTERNAL_KEY COCKPIT_INTERNAL_USER
}
_ck_hdr() {   # writes a private header file for one internal curl; its path is left in _CK_HF (empty = no credential) and the caller removes it
    [ -n "${COCKPIT_INTERNAL_KEY:-}" ] || { _CK_HF=""; return 0; }
    _CK_HF=$(umask 077; mktemp "${TMPDIR:-/tmp}/ckih.XXXXXX" 2>/dev/null) || { _CK_HF=""; return 0; }
    printf 'X-Cockpit-Internal: %s\nX-Cockpit-User: %s\n' "$COCKPIT_INTERNAL_KEY" "$COCKPIT_INTERNAL_USER" > "$_CK_HF"
}

run_crud() {   # same arguments as crud_executor.sh: PROJECT_DIR RESPONSE_FILE PROPOSER PROJECT_NAME
    local _c="${SCRIPTS_DIR:-$HOME/scripts}/crud_cli.php" _eng _o _rc
    # first the engine's own executor (`aicengine crud`, no PHP needed); exit 9 = it refused before touching anything, and the interpreter below takes over
    if engine_enabled && _eng=$(engine_bin) && "$_eng" version 2>/dev/null | grep -q ' crud'; then
        _o=$(COCKPIT_DATA_USER="${REQ_DATA:-}" "$_eng" crud "$@" 2>&1); _rc=$?
        if [ "$_rc" -ne 9 ]; then printf '%s\n' "$_o"; return 0; fi
    fi
    if engine_enabled && [ -f "$_c" ] && command -v php >/dev/null 2>&1; then
        COCKPIT_DATA_USER="${REQ_DATA:-}" php "$_c" "$@" 2>&1
    else
        COCKPIT_DATA_USER="${REQ_DATA:-}" "${SCRIPTS_DIR:-$HOME/scripts}/crud_executor.sh" "$@" 2>&1
    fi
}

# The Ollama / OpenAI-compatible local-model branch (moved here unchanged from the case below, so that the engine hand-off
# and the parity tests can reach it). Uses and sets globals: MODEL, USER_PROMPT, SYS_TMP, PROMPT_TMP, OUT_FILE, CHAT_FILE, LOCAL_BASE,
# LOCAL_STYLE, STDBUF, AGENT_UC; sets OLLAMA_PROMPT_CHARS for the usage log.
run_ollama_branch() {
    local _eng _erc _lc_h _lc_u _LC_DONE
    # Ollama gets a chat-friendly default; OpenAI-style servers
    # (LocalAI/…) need whatever model the user actually loaded.
    [ -z "$MODEL" ] && [ "$LOCAL_STYLE" = "ollama" ] && MODEL="llama3.2:3b"
    OLLAMA_PROMPT_CHARS=$(wc -c < "$PROMPT_TMP" 2>/dev/null | tr -d '[:space:]')
    OLLAMA_PROMPT_CHARS=${OLLAMA_PROMPT_CHARS:-0}
    # Use the /api/chat endpoint with STRUCTURED role messages
    # (system + prior turns + this user turn) instead of `ollama run`
    # on a flat transcript. Small models attribute roles far better
    # this way, and there's no PTY — which also kills the "25h/25l"
    # spinner-artifact the old script -qfc path leaked.
    if needs_history "$USER_PROMPT"; then
        OLLAMA_HIST_JSON=$(build_history "$CHAT_FILE" "$USER_PROMPT" json)
    else
        OLLAMA_HIST_JSON='[]'
    fi
    # Native path (same switch): `aicengine localchat` builds the request itself, pulls the model on first
    # use and streams the reply into OUT_FILE — no jq, no curl, no jq process per streamed line, and no
    # 128 KB limit on the prompt. Exit 2 = refused before anything was sent: the Bash below then does it.
    _LC_DONE=""
    if engine_enabled && _eng="$(engine_bin)"; then
        _lc_h=$(mktemp); _lc_u=$(mktemp)
        printf '%s' "$OLLAMA_HIST_JSON" > "$_lc_h"; printf '%s' "$USER_PROMPT" > "$_lc_u"
        "$_eng" localchat --base "$LOCAL_BASE" --style "$LOCAL_STYLE" --model "$MODEL" --system-file "$SYS_TMP" \
                --history-file "$_lc_h" --user-file "$_lc_u" --out "$OUT_FILE" --agent-uc "$AGENT_UC"
        _erc=$?
        rm -f "$_lc_h" "$_lc_u"
        [ "$_erc" -ne 2 ] && _LC_DONE=1
    fi
    if [ -z "$_LC_DONE" ]; then
    OLLAMA_PAYLOAD=$(jq -n \
        --arg model "$MODEL" \
        --rawfile sys "$SYS_TMP" \
        --argjson hist "$OLLAMA_HIST_JSON" \
        --arg user "$USER_PROMPT" \
        '{ model:$model, stream:true,
           messages: ([{role:"system",content:$sys}] + $hist + [{role:"user",content:$user}]) }' \
        2>/dev/null)
    [ -n "$OLLAMA_PAYLOAD" ] || echo "[${AGENT_UC}] payload build failed (history JSON invalid?) — falling back to ollama run"
    printf '%s' "$OLLAMA_PAYLOAD" > "${OUT_FILE}.payload" 2>/dev/null
    if [ "$LOCAL_STYLE" = "openai" ]; then
        # OpenAI-compatible server (LocalAI / LM Studio / vLLM). Same
        # messages payload; POST /v1/chat/completions and read SSE
        # "data:" deltas (.choices[0].delta.content), stop on [DONE].
        if [ -n "$OLLAMA_PAYLOAD" ]; then
            curl -s --no-buffer -m 300 -X POST "$LOCAL_BASE/v1/chat/completions" \
                -H 'Content-Type: application/json' -d "$OLLAMA_PAYLOAD" 2>>"${OUT_FILE}.err" \
              | while IFS= read -r _line; do
                    case "$_line" in
                        data:\ *) _d="${_line#data: }"
                            [ "$_d" = "[DONE]" ] && continue
                            printf '%s' "$_d" | jq -j '.choices[0].delta.content // empty' 2>/dev/null ;;
                    esac
                done > "$OUT_FILE"
        fi
    elif [ -n "$OLLAMA_PAYLOAD" ]; then
        # /api/chat does not pull: a model never pulled came back as
        # {"error":"model not found"} and read 'returned nothing' (Fedora VM).
        # Pull it first; the tags list is the truth, not the card.
        if ! curl -s -m 5 "$LOCAL_BASE/api/tags" 2>/dev/null | jq -e --arg m "$MODEL" '.models[]?.name | select(. == $m or . == ($m + ":latest"))' >/dev/null 2>&1; then
            echo "[${AGENT_UC}] pulling $MODEL (first use) …"
            ollama pull "$MODEL" >/dev/null 2>&1 || true
        fi
        curl -s --no-buffer -m 300 -X POST "$LOCAL_BASE/api/chat" \
            -H 'Content-Type: application/json' -d "$OLLAMA_PAYLOAD" 2>>"${OUT_FILE}.err" \
          | while IFS= read -r _line; do
                printf '%s' "$_line" | jq -j '.message.content // (if .error then "[ollama: " + .error + "]" else empty end)' 2>/dev/null
            done > "$OUT_FILE"
    else
        # jq missing / payload build failed → fall back to the CLI.
        $STDBUF ollama run --nowordwrap "$MODEL" "$(cat "$PROMPT_TMP")" > "$OUT_FILE" 2>>"${OUT_FILE}.err"
    fi
    fi   # [ -z "$_LC_DONE" ]
    # If the model produced nothing, or a CODER model refused a
    # chat-style prompt, replace the empty/garbage bubble with a
    # clear, actionable note instead of leaving junk.
    _resp=$(cat "$OUT_FILE" 2>/dev/null)
    _trim=$(printf '%s' "$_resp" | tr -d '[:space:]')
    if [ -z "$_trim" ]; then
        printf '[%s returned nothing — try another local model (Card 3), or a smaller prompt]' "$MODEL" > "$OUT_FILE"
    elif printf '%s' "$MODEL" | grep -qi 'coder' \
         && printf '%s' "$_resp" | grep -qiE "can'?t assist|cannot assist|can not assist|i'?m sorry, but|unable to (help|assist)|i (can'?t|cannot) (help|do that)"; then
        case " $USER_PROMPT " in
            *"[CHAT MODE]"*|*"[ANALYZE MODE]"*|*"[REPORT MODE]"*|*"[RESEARCH MODE]"*|*"[OUTLINE MODE]"*)
                printf '[Coder model "%s" — not suited for chat. Switch Card 3 to a chat model (e.g. llama3.2:3b), or use the Build/Debug style.]' "$MODEL" > "$OUT_FILE" ;;
        esac
    fi
}

# Cleaning the agent's raw output and logging the turn (moved out of the main loop below, unchanged in what it does, so that the engine hand-off and the
# parity tests can reach it): strip the terminal artifacts from an Ollama / Gemini answer, measure the duration, and write the Ollama usage line.
# Uses (globals): AGENT OUT_FILE PROMPT_TMP SYS_TMP START_TIME QUEUE_DIR MODEL PROJECT CHAT_NAME OLLAMA_PROMPT_CHARS.   Sets: DURATION (and END_TIME).
# Native path (same switch as the engine): `aicengine clean` does all three without sed, bc or date arithmetic (so also on macOS, where `date +%s%N`
# gives a literal N). Exit 2 = it refused before touching anything: the Bash below does it. Proof of equality: tests/post_parity.sh.
finish_output() {
    local _eng
    if engine_enabled && _eng=$(engine_bin); then
        DURATION=$("$_eng" clean --agent "$AGENT" --out-file "$OUT_FILE" --start-ns "${START_TIME:-}" \
            --usage-log "${QUEUE_DIR%/queue}/ollama_usage.jsonl" --model "${MODEL:-}" --project "$PROJECT" --chat "$CHAT_NAME" \
            --prompt-chars "${OLLAMA_PROMPT_CHARS:-0}" 2>/dev/null) && { rm -f "$PROMPT_TMP" "$SYS_TMP"; return 0; }
    fi
    # ── Strip PTY artifacts ───────────────────────────────────────────────
    # Ollama: script -qfc gives it a PTY for streaming, but the PTY injects
    #   \r at line endings and ollama's progress spinner re-prints the last
    #   few words on a new final line prefixed with timing (e.g. "25h <tail>").
    #   We delete the entire artifact line, but only when it is the LAST
    #   line of the file ($ address) — protects against legitimate content
    #   like "5h timer set" appearing mid-response.
    # Gemini: CLI emits colour-capability warnings and tool-fallback notices
    #   ("Ripgrep is not available. Falling back to GrepTool.") that are
    #   cosmetic CLI messages, not part of the actual response.
    if [ "$AGENT" = "ollama" ]; then
        sedi \
            -e 's/\r//g' \
            -e 's/\x1b\[[0-9;]*[mGKHFJA-Z]//g' \
            -e '$ { /^[0-9]\+[hs] / d }' \
            "$OUT_FILE"
    elif [ "$AGENT" = "gemini" ]; then
        sedi \
            -e 's/\r//g' \
            -e 's/\x1b\[[0-9;]*[mGKHFJA-Z]//g' \
            -e '/Warning:.*color\|true color\|True color/Id' \
            -e '/Ripgrep is not available/Id' \
            -e '/Falling back to GrepTool/Id' \
            -e '/Basic terminal detected/Id' \
            -e '/Using a terminal with true color/Id' \
            "$OUT_FILE"
    fi

    rm -f "$PROMPT_TMP" "$SYS_TMP"

    END_TIME=$(date +%s%N)
    DURATION=$(echo "scale=1; ($END_TIME - $START_TIME) / 1000000000" | bc 2>/dev/null || echo "0")

    # ── Ollama usage logging ─────────────────────────────────────────────
    # Append one JSONL record per Ollama call to ollama_usage.jsonl.
    # Fields match usage_parser.php parse_ollama():
    #   ts             — ISO timestamp (parse_ts() accepts ISO or unix int)
    #   model          — Ollama model name (e.g. qwen2.5-coder:1.5b)
    #   project / chat — cockpit context
    #   prompt_tokens  — estimated: prompt_chars / 4 (ollama CLI has no token API)
    #   output_tokens  — estimated: response_chars / 4
    #   total_ms       — duration_s × 1000
    # Pure bash — no Python, no jq needed for writing a flat JSONL line.
    if [ "$AGENT" = "ollama" ]; then
        OLLAMA_LOG="${QUEUE_DIR%/queue}/ollama_usage.jsonl"
        OLLAMA_RESP_CHARS=$(wc -c < "$OUT_FILE" 2>/dev/null | tr -d '[:space:]')
        OLLAMA_RESP_CHARS=${OLLAMA_RESP_CHARS:-0}
        OLLAMA_PROMPT_CHARS=${OLLAMA_PROMPT_CHARS:-0}
        OLLAMA_PROMPT_TOKENS=$(( OLLAMA_PROMPT_CHARS / 4 ))
        OLLAMA_OUTPUT_TOKENS=$(( OLLAMA_RESP_CHARS   / 4 ))
        OLLAMA_TOTAL_MS=$(echo "${DURATION:-0} * 1000" | bc 2>/dev/null | cut -d. -f1)
        OLLAMA_TOTAL_MS=${OLLAMA_TOTAL_MS:-0}
        LOG_TS=$(date -u +"%Y-%m-%dT%H:%M:%S")
        LOG_MODEL="${MODEL//\"/\\\"}"
        LOG_PROJECT="${PROJECT//\"/\\\"}"
        LOG_CHAT="${CHAT_NAME//\"/\\\"}"
        printf '{"ts":"%s","model":"%s","project":"%s","chat":"%s","prompt_tokens":%s,"output_tokens":%s,"total_ms":%s}\n' \
            "$LOG_TS" "$LOG_MODEL" "$LOG_PROJECT" "$LOG_CHAT" \
            "$OLLAMA_PROMPT_TOKENS" "$OLLAMA_OUTPUT_TOKENS" "$OLLAMA_TOTAL_MS" \
            >> "$OLLAMA_LOG"
        chmod 664 "$OLLAMA_LOG" 2>/dev/null
    fi
}

# The "installed but not signed in" hint (moved out of the main loop below for the same reasons). Uses: AGENT AGENT_UC OUT_FILE.
signin_hint() {
    local _eng
    if engine_enabled && _eng=$(engine_bin) && "$_eng" signin-hint --agent "$AGENT" --agent-uc "$AGENT_UC" --out-file "$OUT_FILE" 2>/dev/null; then return 0; fi
    # A CLI that is installed but not signed in answers with its own words
    # ("Not logged in · Please run /login") and nothing says where to do that
    # from inside Cockpit — the first VM tester asked. Append the way.
    # (short replies only — a long answer that merely mentions "not authenticated" is not this)
    if [ "$(stat -c%s "$OUT_FILE" 2>/dev/null || echo 9999)" -lt 800 ] && \
       grep -qiE 'not logged in|please run /login|run .?(claude|gemini|codex|qwen)?.?(auth|login)|not authenticated|authentication required|GEMINI_API_KEY|OPENAI_API_KEY' "$OUT_FILE" 2>/dev/null; then
        printf '\n\n[COCKPIT] %s is installed but not signed in. Sign in once: on the %s card click "Open %s CLI in a new terminal" and sign in when it asks (/login or /auth opens the browser). Ollama needs no sign-in.\n' \
            "$AGENT" "${AGENT_UC}" "$AGENT" >> "$OUT_FILE"
    fi
}

# Assembling the prompt for one turn (moved out of the main loop below, unchanged in what it does, so that the engine hand-off and the
# parity tests can reach it): the project's goal/kind/descriptions, COCKPIT.md, the person's profile, the global directives, the identity line,
# then the layout for Claude (one flat prompt) or for Gemini/Ollama (a system block + the flat prompt).
# Uses (globals): AGENT PROJECT PROJECT_DIR CHAT_NAME REQ_DATA _DATA USER_PROMPT HISTORY RAG_B64 WORKERS_AUTO_PROMPT TOOLS_AUTO_PROMPT
#   OLLAMA_CAPS_PROMPT CLAUDE_MODEL GEMINI_MODEL MODEL CLI_SUPPLIER CLI_PROMPT_STYLE CRUD_SYSTEM_PROMPT.   Sets: PROMPT_TMP SYS_TMP (and the
#   block variables below, as before).
assemble_prompt() {
    # The Claude style guide, here once for both paths (it used to sit inside the Claude branch below).
    CLAUDE_STYLE='[Style guide for this conversation]
Be terse. Do NOT narrate what you are about to do before doing it.
Do the work first (use your tools directly), then give a single short
confirmation line. No preambles like "I will now..." or "Let me...".

REUSABLE CODE: Do NOT write %%PROPOSE%% blocks. Just put code in normal fenced
Markdown blocks (```lang ... ```) — the cockpit automatically queues every code
block to the user'\''s Pending Proposals for one-click saving.

You can READ from the cockpit catalogs by including these in your response (the
executor injects the content back for the next turn):
  %%LIB:Title-or-id%%    — read a library entry (URL fetch or local cat)
  %%SNIP:Title-or-id%%   — read a saved snippet
  %%SRC:Title-or-id%%    — read a saved source
  %%SEARCH:terms%%       — web search (top 5 results)
  %%FETCH:url%%          — fetch URL text content

[End style guide]'
    PROMPT_TMP=$(mktemp /tmp/cockpit_prompt_XXXXXX.txt)
    SYS_TMP=$(mktemp /tmp/cockpit_sys_XXXXXX.txt)   # system block alone (for Ollama /api/chat)
    # Native path (same switch as the engine): `aicengine prompt` builds both files itself: the goal / kind / description blocks, COCKPIT.md, the
    # profile, the directives, the identity line, the layout; without jq, awk or a dozen subshells. Proof of equality: tests/prompt_parity.sh.
    # Exit 2 (or no engine, or one too old to know the command) = it refused before writing anything: the Bash below does it.
    local _eng _pd _prc _rag
    if engine_enabled && _eng=$(engine_bin); then
        _pd=$(mktemp -d /tmp/cockpit_pa_XXXXXX)
        printf '%s' "$USER_PROMPT" > "$_pd/user"; printf '%s' "${HISTORY:-}" > "$_pd/hist"
        _rag=$(printf '%s' "${RAG_B64:-}" | base64 -d 2>/dev/null); printf '%s' "$_rag" > "$_pd/rag"
        printf '%s' "${WORKERS_AUTO_PROMPT:-}" > "$_pd/workers"; printf '%s' "${TOOLS_AUTO_PROMPT:-}" > "$_pd/tools"; printf '%s' "${OLLAMA_CAPS_PROMPT:-}" > "$_pd/caps"
        printf '%s' "$CRUD_SYSTEM_PROMPT" > "$_pd/crud"; printf '%s' "$CLAUDE_STYLE" > "$_pd/style"
        "$_eng" prompt --agent "$AGENT" --project "$PROJECT" --project-dir "$PROJECT_DIR" --chat-name "$CHAT_NAME" --data-dir "${REQ_DATA:-$_DATA}" \
            --cli-supplier "${CLI_SUPPLIER:-}" --claude-model "${CLAUDE_MODEL:-}" --gemini-model "${GEMINI_MODEL:-}" --model "${MODEL:-}" --prompt-style "${CLI_PROMPT_STYLE:-plain}" \
            --user-file "$_pd/user" --history-file "$_pd/hist" --rag-file "$_pd/rag" --workers-file "$_pd/workers" --tools-file "$_pd/tools" --caps-file "$_pd/caps" \
            --crud-file "$_pd/crud" --style-file "$_pd/style" --out "$PROMPT_TMP" --sys-out "$SYS_TMP" 2>/dev/null
        _prc=$?
        rm -rf "$_pd"
        [ "$_prc" -eq 0 ] && return 0
    fi
    # E1: per-project context. If the project folder contains a COCKPIT.md,
    # prepend it as a system-style context block so the agent always knows
    # the project's conventions, stack, and goals. Capped at 8 KB to protect
    # the context window; larger files are truncated with a notice.
    # The project's GOAL (.cockpit_project.json, written by the Project dialog):
    # one sentence saying what this folder is for. Cheap, always in front of the
    # agent, and it keeps answers on-target across threads (2026-09-22).
    PROJECT_GOAL_BLOCK=""
    # Push-RAG: bridge.php picked the best library/snippet/source matches for this
    # prompt when the "RAG Search" capability is on; base64 so the naive meta parser
    # survives the multi-line text.
    RAG_BLOCK=""
    if [ -n "${RAG_B64:-}" ]; then
        RAG_BLOCK=$(printf '%s' "$RAG_B64" | base64 -d 2>/dev/null)
    fi
    # Scope (2026-10-06): the KIND is the project's (every chat in it inherits it) and the GOAL is the CHAT's, kept in
    # .chat_meta/<chat>.json; a project's older goal in .cockpit_project.json is the fallback for a chat with none.
    # A free (_standalone) chat has no project to hold a kind, so both come from its own chat file.
    _GOAL_F="$PROJECT_DIR/.cockpit_project.json"
    _CHAT_F="$PROJECT_DIR/.chat_meta/$(printf '%s' "$CHAT_NAME" | tr 'A-Z ' 'a-z_').json"      # same slug rule as files.php
    if command -v jq >/dev/null 2>&1; then
        _goal=""; _kind_note=""; _kind_name=""
        if [ -f "$_CHAT_F" ]; then _goal=$(jq -r '.goal // empty' "$_CHAT_F" 2>/dev/null | head -c 600); fi
        if [ "$PROJECT" = "_standalone" ]; then
            _KIND_F="$_CHAT_F"
        else
            _KIND_F="$_GOAL_F"
            [ -z "$_goal" ] && [ -f "$_GOAL_F" ] && _goal=$(jq -r '.goal // empty' "$_GOAL_F" 2>/dev/null | head -c 600)
        fi
        [ -n "$_goal" ] && PROJECT_GOAL_BLOCK="[Project goal] $_goal"
        # The KIND (Lazarus, VB6 migration, research, game…): a standing note.
        if [ -f "$_KIND_F" ]; then
            _kind_note=$(jq -r '.kind_note // empty' "$_KIND_F" 2>/dev/null | head -c 900)
            _kind_name=$(jq -r '.kind_name // .kind // empty' "$_KIND_F" 2>/dev/null | head -c 60)
        fi
        if [ -n "$_kind_note" ]; then
            PROJECT_GOAL_BLOCK="${PROJECT_GOAL_BLOCK:+$PROJECT_GOAL_BLOCK
}[Project kind: $_kind_name] $_kind_note"
        fi
        # Descriptions are the person's own notes (what a chat or project is for, what it achieved). They reach the agent
        # only where the person switched "also send to the agent" on, for that chat or that project.
        _desc=""
        if [ -f "$_CHAT_F" ]; then
            _desc=$(jq -r 'select(.desc_send == true) | .description // empty' "$_CHAT_F" 2>/dev/null | head -c 300)
            [ -n "$_desc" ] && PROJECT_GOAL_BLOCK="${PROJECT_GOAL_BLOCK:+$PROJECT_GOAL_BLOCK
}[Chat description] $_desc"
        fi
        if [ "$PROJECT" != "_standalone" ] && [ -f "$_GOAL_F" ]; then
            _desc=$(jq -r 'select(.desc_send == true) | .description // empty' "$_GOAL_F" 2>/dev/null | head -c 300)
            [ -n "$_desc" ] && PROJECT_GOAL_BLOCK="${PROJECT_GOAL_BLOCK:+$PROJECT_GOAL_BLOCK
}[Project description] $_desc"
        fi
    fi
    COCKPIT_MD_BLOCK=""
    COCKPIT_MD_FILE="$PROJECT_DIR/COCKPIT.md"
    if [ -f "$COCKPIT_MD_FILE" ]; then
        COCKPIT_MD_CONTENT=$(head -c 8192 "$COCKPIT_MD_FILE")
        if [ "$(wc -c < "$COCKPIT_MD_FILE")" -gt 8192 ]; then
            COCKPIT_MD_CONTENT="$COCKPIT_MD_CONTENT"$'\n'"[... COCKPIT.md truncated at 8 KB]"
        fi
        COCKPIT_MD_BLOCK="[Project context — from COCKPIT.md]"$'\n'"$COCKPIT_MD_CONTENT"$'\n'"[End project context]"
    fi

    # ── Unified Directive Layer ──────────────────────────────────────────
    # Global standing directives applied to EVERY supplier (Claude, Gemini,
    # Ollama, Workers). Written once in the cockpit "Directives" panel and
    # prepended to every agent's context at dispatch. A "compact" variant is
    # used for suppliers listed in directives_config.json:compact_suppliers
    # (e.g. tiny Ollama models) so a long preamble doesn't crowd out the task.
    # Profile — durable facts about the person (units, language, how they like
    # answers), kept apart from the directives above: those say how to behave,
    # this says who you are working with. Short by design and capped here too,
    # because it rides on every single prompt.
    # paths.php scopes cockpit_data to users/<login>/ for the WEB request, so
    # anything the UI writes lands there while this daemon's $_DATA is the
    # shared root. Reading the wrong one is silent: the file simply is not
    # found and the block is empty. Profile was written to the per-user dir
    # and never reached an agent; the directives below had the same bug and
    # nobody noticed because a missing directives file looks like "none set".
    _UDATA="${REQ_DATA:-$_DATA}"

    PROFILE_BLOCK=""
    PROFILE_F="$_UDATA/profile.md"
    if [ -s "$PROFILE_F" ] && [ ! -f "$_UDATA/profile_enabled" ]; then
        PROFILE_CONTENT=$(head -c 4096 "$PROFILE_F")
        [ -n "$PROFILE_CONTENT" ] && PROFILE_BLOCK="[About the person you are working with]"$'\n'"$PROFILE_CONTENT"$'\n'"[End profile]"
    fi

    GLOBAL_DIRECTIVES_BLOCK=""
    DIRECTIVES_CFG="$_UDATA/directives_config.json"
    DIRECTIVES_FULL="$_UDATA/directives_global.md"
    DIRECTIVES_COMPACT="$_UDATA/directives_global_compact.md"
    DIR_ENABLED="true"
    DIR_COMPACT_LIST=""
    if [ -f "$DIRECTIVES_CFG" ] && command -v jq >/dev/null 2>&1; then
        DIR_ENABLED=$(jq -r 'if .enabled == false then "false" else "true" end' "$DIRECTIVES_CFG" 2>/dev/null)
        DIR_COMPACT_LIST=$(jq -r '(.compact_suppliers // []) | join(" ")' "$DIRECTIVES_CFG" 2>/dev/null)
    fi
    if [ "$DIR_ENABLED" = "true" ]; then
        # Choose compact variant if this supplier is in the compact list.
        DIR_USE_COMPACT="no"
        for _s in $DIR_COMPACT_LIST; do
            [ "$_s" = "$AGENT" ] && DIR_USE_COMPACT="yes"
        done
        # Per-supplier override (directives_<agent>.md) wins over full/compact.
        DIR_OVERRIDE="$_UDATA/directives_${AGENT}.md"
        DIR_SRC="$DIRECTIVES_FULL"
        if [ -s "$DIR_OVERRIDE" ]; then
            DIR_SRC="$DIR_OVERRIDE"
        elif [ "$DIR_USE_COMPACT" = "yes" ] && [ -s "$DIRECTIVES_COMPACT" ]; then
            DIR_SRC="$DIRECTIVES_COMPACT"
        fi
        if [ -s "$DIR_SRC" ]; then
            DIR_CONTENT=$(head -c 8192 "$DIR_SRC")
            GLOBAL_DIRECTIVES_BLOCK="[Global directives — always apply]"$'\n'"$DIR_CONTENT"$'\n'"[End global directives]"
        fi
    fi

    # ── Identity line — tell every agent its real provider + model so it
    #    stops hallucinating a different name (e.g. Llama claiming "Claude").
    case "$AGENT" in
        claude) ID_PROVIDER="Anthropic Claude"; ID_MODEL="$CLAUDE_MODEL" ;;
        gemini)
            case "$CLI_SUPPLIER" in
                ""|gemini)        ID_PROVIDER="Google Gemini"; ID_MODEL="$GEMINI_MODEL" ;;
                groq_build|groq)  ID_PROVIDER="Groq";          ID_MODEL="$GEMINI_MODEL" ;;
                *huggingface*|hf) ID_PROVIDER="HuggingFace";   ID_MODEL="$GEMINI_MODEL" ;;
                *cloudflare*)     ID_PROVIDER="Cloudflare";    ID_MODEL="$GEMINI_MODEL" ;;
                *)                ID_PROVIDER="$CLI_SUPPLIER";  ID_MODEL="$GEMINI_MODEL" ;;
            esac ;;
        ollama) ID_PROVIDER="a local Ollama model"; ID_MODEL="$MODEL" ;;
        *)      ID_PROVIDER="$AGENT"; ID_MODEL="" ;;
    esac
    case "$ID_MODEL" in ""|auto) ID_MODEL="" ;; esac
    IDENTITY_LINE="[Identity] You are running inside AI Cockpit on ${ID_PROVIDER}${ID_MODEL:+ (model: ${ID_MODEL})}. If asked which model or company you are, answer truthfully with this; do not claim to be a different model or company."

    if [ "$AGENT" = "claude" ]; then
        # Claude has native file tools + --dangerously-skip-permissions.
        # Do NOT inject CRUD prompt — Claude correctly identifies it as
        # prompt injection and ignores it. Use its own tools.
        # We DO add a brief terseness directive so its replies match the
        # cockpit cosole style, plus the proposal protocol.
        {
            echo "$CLAUDE_STYLE"
            echo ""
            echo "$IDENTITY_LINE"
            if [ -n "$GLOBAL_DIRECTIVES_BLOCK" ]; then
                echo ""
                echo "$GLOBAL_DIRECTIVES_BLOCK"
            fi
            if [ -n "$PROFILE_BLOCK" ]; then
                echo ""
                echo "$PROFILE_BLOCK"
            fi
            if [ -n "$PROJECT_GOAL_BLOCK" ]; then
                echo ""
                echo "$PROJECT_GOAL_BLOCK"
            fi
            if [ -n "$COCKPIT_MD_BLOCK" ]; then
                echo ""
                echo "$COCKPIT_MD_BLOCK"
            fi
            if [ -n "$WORKERS_AUTO_PROMPT" ]; then
                echo ""
                echo "$WORKERS_AUTO_PROMPT"
            fi
            if [ -n "$TOOLS_AUTO_PROMPT" ]; then
                echo ""
                echo "$TOOLS_AUTO_PROMPT"
            fi
            echo ""
            [ -n "$HISTORY" ] && echo "$HISTORY" && echo ""
            # Retrieved knowledge sits LAST, right against the question.
            # Models weight the start and end of a long prompt more than the
            # middle ("lost in the middle"), and this block used to be buried
            # between the style guide and the history.
            if [ -n "$RAG_BLOCK" ]; then
                dialect_open "context"
                echo "$RAG_BLOCK"
                dialect_close "context"
                echo ""
            fi
            dialect_open "task"
            printf '%s\n' "$USER_PROMPT"
            dialect_close "task"
        } > "$PROMPT_TMP"
    else
        # Gemini and Ollama have no native tools — inject CRUD system prompt
        # so they know to output %%CREATE%% blocks for file operations.
        # For Ollama specifically, also prepend any capability-shim
        # additions (FETCH:, SEARCH:, FS_READ:, etc.) so it knows what
        # commands are available beyond CRUD.
        # System block alone → SYS_TMP (Ollama /api/chat uses it as the
        # "system" message; the flat PROMPT_TMP appends history + user below).
        {
            echo "$CRUD_SYSTEM_PROMPT"
            echo ""
            echo "$IDENTITY_LINE"
            if [ -n "$GLOBAL_DIRECTIVES_BLOCK" ]; then
                echo ""
                echo "$GLOBAL_DIRECTIVES_BLOCK"
            fi
            if [ -n "$PROFILE_BLOCK" ]; then
                echo ""
                echo "$PROFILE_BLOCK"
            fi
            if [ -n "$PROJECT_GOAL_BLOCK" ]; then
                echo ""
                echo "$PROJECT_GOAL_BLOCK"
            fi
            if [ -n "$COCKPIT_MD_BLOCK" ]; then
                echo ""
                echo "$COCKPIT_MD_BLOCK"
            fi
            if [ "$AGENT" = "ollama" ] && [ -n "$OLLAMA_CAPS_PROMPT" ]; then
                echo ""
                echo "$OLLAMA_CAPS_PROMPT"
            fi
            if [ -n "$WORKERS_AUTO_PROMPT" ]; then
                echo ""
                echo "$WORKERS_AUTO_PROMPT"
            fi
            if [ -n "$TOOLS_AUTO_PROMPT" ]; then
                echo ""
                echo "$TOOLS_AUTO_PROMPT"
            fi
        } > "$SYS_TMP"
        {
            cat "$SYS_TMP"
            echo ""
            [ -n "$HISTORY" ] && echo "$HISTORY" && echo ""
            # Same reasoning as the other path: retrieved knowledge last.
            if [ -n "$RAG_BLOCK" ]; then
                dialect_open "context"
                echo "$RAG_BLOCK"
                dialect_close "context"
                echo ""
            fi
            dialect_open "task"
            printf '%s\n' "User: $USER_PROMPT"
            dialect_close "task"
        } > "$PROMPT_TMP"
    fi
}

# The Gemini REST branch (moved out of the case below, unchanged in what it does, so that the engine hand-off and the parity tests can
# reach it). Uses: GEMINI_MODEL, GEMINI_API_KEY, PROMPT_TMP, OUT_FILE. Test hooks: GEMINI_API_BASE, GEMINI_CA_FILE.
# The key travels in a header (x-goog-api-key), not in the URL: a URL shows up in `ps`, in proxy logs and in curl's own error text.
# Same switch as the engine: `aicengine gemini` makes the call over verified TLS with no jq/curl and no 128 KB limit on the prompt;
# exit 2 = refused before anything was sent (the Bash below then does it), any other status = done, never a second try.
run_gemini_rest() {
    local GMODEL _base _eng _grc GEM_PAYLOAD GEM_RAW _fr
    case "$GEMINI_MODEL" in
        gemini-2.0-flash-lite) GMODEL="gemini-2.0-flash-lite" ;;
        *)                     GMODEL="gemini-2.5-flash" ;;
    esac
    if [ -z "$GEMINI_API_KEY" ]; then
        echo "[GEMINI ERROR] No API key. Put a free AI Studio key in cockpit_data/gemini_api_key.txt and restart agents." >> "$OUT_FILE"
        return 0
    fi
    _base="${GEMINI_API_BASE:-https://generativelanguage.googleapis.com}"
    if engine_enabled && _eng=$(engine_bin); then
        GEMINI_API_KEY="$GEMINI_API_KEY" "$_eng" gemini --model "$GMODEL" --prompt-file "$PROMPT_TMP" --out "$OUT_FILE" \
            --base "$_base" ${GEMINI_CA_FILE:+--ca-file "$GEMINI_CA_FILE"} --timeout 180
        _grc=$?
        [ "$_grc" -ne 2 ] && return 0
    fi
    GEM_PAYLOAD=$(jq -n --rawfile p "$PROMPT_TMP" '{contents:[{parts:[{text:$p}]}]}')
    # the body goes in on stdin: as an argument it hit the 128 KB limit of one command-line word on a long prompt
    GEM_RAW=$(printf '%s' "$GEM_PAYLOAD" | curl -s -m 180 ${GEMINI_CA_FILE:+--cacert "$GEMINI_CA_FILE"} \
        "${_base}/v1beta/models/${GMODEL}:generateContent" \
        -H 'Content-Type: application/json' -H "x-goog-api-key: ${GEMINI_API_KEY}" --data-binary @-)
    printf '%s' "$GEM_RAW" | jq -r '
        if .candidates then (.candidates[0].content.parts[]?.text // empty)
        else ("[GEMINI ERROR] " + (.error.message // "no response")) end' \
      >> "$OUT_FILE"
    # ("// empty", not '// ""': with no text in any part the old program printed one empty line, so the file was never empty and the reason
    #  below -- written for exactly a safety block or an empty candidate -- was never reached: the person saw a blank answer)
    if [ ! -s "$OUT_FILE" ]; then
        # Empty (e.g. safety block / no parts) — surface a reason.
        _fr=$(printf '%s' "$GEM_RAW" | jq -r '.candidates[0].finishReason // "empty response"' 2>/dev/null)
        echo "[GEMINI ERROR] $_fr" >> "$OUT_FILE"
    fi
}

# The native Claude call (moved here unchanged from the claude branch so the engine switch
# and the parity tests can reach it). $1 = the full model string.
run_claude_json() {
    local CF="$1" _eng _erc
    if engine_enabled && _eng="$(engine_bin)"; then
        "$_eng" legacy --claude-model "$CF" --prompt-file "$PROMPT_TMP" --out "$OUT_FILE" --extra-args "${EXTRA_CLI_ARGS:-}"
        _erc=$?
        [ "$_erc" -ne 2 ] && return 0                     # 2 = refused before anything ran: the Bash below still can
        log "  engine refused the request (exit 2) - using the Bash path"
    fi
    if [ "$HAS_JQ" -eq 1 ]; then
        # Use --output-format json and pull the schema-stable .result
        # field. (The older stream-json/text_delta path broke: this CLI
        # version no longer emits text_delta events, AND SessionStart
        # hooks like the caveman plugin embed multi-line text with raw
        # newlines that produce invalid NDJSON and kill jq. .result is
        # a single final string — robust across versions.) On auth or
        # API failure, .result holds the error text, so the user sees
        # the real reason instead of an empty bubble.
        set -o pipefail
        claude --model "$CF" $EXTRA_CLI_ARGS --dangerously-skip-permissions -p \
               "$(cat "$PROMPT_TMP")" \
               --output-format json 2>>"${OUT_FILE}.err" \
          | jq -r '.result // .error.message // .error // empty' \
          >> "$OUT_FILE"
        set +o pipefail
        # If nothing landed (jq miss / crash), surface stderr so the
        # response is never silently empty.
        if [ ! -s "$OUT_FILE" ] && [ -s "${OUT_FILE}.err" ]; then
            head -c 2000 "${OUT_FILE}.err" >> "$OUT_FILE"
        fi
        rm -f "${OUT_FILE}.err"
    else
        # Fallback if jq isn't installed — buffered, but still works
        $STDBUF claude --model "$CF" $EXTRA_CLI_ARGS --dangerously-skip-permissions \
               -p "$(cat "$PROMPT_TMP")" > "$OUT_FILE" 2>&1
    fi
}

# Generic CLI dispatch shared by Card 1 (any non-Claude paid/free CLI) and Card 2
# (any CLI-kind agent, e.g. Aider). Builds: <binary> [model_flag <prefix><model>]
# <extra_args> <EXTRA_CLI_ARGS> <prompt_flag> "<prompt>". Uses jq .result when
# parse=claude_json, else raw stdout. Exports OLLAMA_API_BASE for local backends.
# Args: $1 = chosen model string (may be empty/"auto").
run_generic_cli() {
    local _raw="$1"                       # the plain model (e.g. an ollama tag), pre-prefix
    local _eng _erc
    if engine_enabled && _eng="$(engine_bin)" && [ -n "${CLI_CATALOG_FILE:-}" ]; then
        # (opencode's provider block in its own config is merged in by the engine itself)
        "$_eng" legacy --catalog "$CLI_CATALOG_FILE" --supplier "$CLI_SUPPLIER" --model "$_raw" --prompt-file "$PROMPT_TMP" \
                --out "$OUT_FILE" --images "${REQ_IMAGES:-}" --extra-args "${EXTRA_CLI_ARGS:-}" --local-base "${LOCAL_BASE:-}"
        _erc=$?
        [ "$_erc" -ne 2 ] && return 0                     # 2 = refused before anything ran: the Bash below still can
        log "  engine refused the request (exit 2) - using the Bash path"
    fi
    local _m="$_raw"
    [ -n "$CLI_MODEL_PREFIX" ] && [ -n "$_m" ] && [ "$_m" != "auto" ] && _m="${CLI_MODEL_PREFIX}${_m}"
    local -a GEN_CMD=("$CLI_BINARY")
    [ -n "$CLI_SUBCMD" ] && GEN_CMD+=($CLI_SUBCMD)                 # subcommand (goose/opencode "run")
    [ -n "$CLI_MODEL_FLAG" ] && [ -n "$_m" ] && [ "$_m" != "auto" ] && GEN_CMD+=("$CLI_MODEL_FLAG" "$_m")
    [ -n "$CLI_EXTRA_ARGS" ] && GEN_CMD+=($CLI_EXTRA_ARGS)
    [ -n "$EXTRA_CLI_ARGS" ] && GEN_CMD+=($EXTRA_CLI_ARGS)
    # Images on this agent's own image flag (catalog image_mode=flag), e.g.
    # `codex exec --image FILE -- "prompt"`. CLI_IMAGE_SEP exists because that
    # flag is variadic: without the `--` it eats the prompt as another file and
    # then blocks on stdin, which looks exactly like a hung agent.
    local _imgAdded=0 _img
    if [ -n "${CLI_IMAGE_FLAG:-}" ] && [ -n "${REQ_IMAGES:-}" ]; then
        local _oldIFS="$IFS"; IFS='|'
        for _img in $REQ_IMAGES; do
            [ -f "$_img" ] || continue
            GEN_CMD+=("$CLI_IMAGE_FLAG" "$_img"); _imgAdded=1
        done
        IFS="$_oldIFS"
        [ "$_imgAdded" = 1 ] && log "  image passed to $CLI_SUPPLIER via $CLI_IMAGE_FLAG"
    fi
    [ "$_imgAdded" = 1 ] && [ "${CLI_IMAGE_SEP:-0}" = "1" ] && GEN_CMD+=("--")
    local _prompt; _prompt="$(cat "$PROMPT_TMP")"
    if [ -n "$CLI_PROMPT_FLAG" ]; then GEN_CMD+=("$CLI_PROMPT_FLAG" "$_prompt")   # flagged prompt (aider --message, goose -t)
    else GEN_CMD+=("$_prompt"); fi                                                # positional prompt (opencode run "…")
    [ "$CLI_BACKEND" = "ollama" ] && export OLLAMA_API_BASE="${LOCAL_BASE:-http://127.0.0.1:11434}"
    [ "$CLI_SUPPLIER" = "opencode" ] && opencode_ensure_provider "$_raw"
    # Per-supplier env (e.g. Goose GOOSE_PROVIDER/GOOSE_MODEL). %MODEL% → the raw model.
    if [ -n "$CLI_ENV" ]; then
        local _kv
        for _kv in $CLI_ENV; do export "${_kv//%MODEL%/$_raw}"; done
    fi
    if [ "$CLI_PARSE" = "claude_json" ] && [ "$HAS_JQ" -eq 1 ]; then
        set -o pipefail
        "${GEN_CMD[@]}" 2>>"${OUT_FILE}.err" | jq -r '.result // .error.message // .error // empty' >> "$OUT_FILE"
        set +o pipefail
        [ ! -s "$OUT_FILE" ] && [ -s "${OUT_FILE}.err" ] && head -c 2000 "${OUT_FILE}.err" >> "$OUT_FILE"
        rm -f "${OUT_FILE}.err"
    else
        "${GEN_CMD[@]}" > "$OUT_FILE" 2>&1 || echo "[$(uc "$CLI_SUPPLIER") ERROR] CLI failed or not installed — check ~/scripts/cockpit_data/cli_catalog.json." >> "$OUT_FILE"
        # opencode prefixes its answer with a "> build · <model>" banner line
        [ "$CLI_SUPPLIER" = "opencode" ] && sedi -e '/^[[:space:]]*> build · /d' -e '1{/^[[:space:]]*$/d}' "$OUT_FILE"
    fi
}

# ── Card-3 local LLM server (Ollama vs OpenAI-style: LocalAI / LM Studio / …) ──
# The supplier-slots UI writes slots.local = {provider, base_url}. Ollama speaks
# its own /api/chat; everything else (LocalAI, LM Studio, vLLM, …) is OpenAI-
# compatible (/v1/chat/completions, SSE deltas). Read it so the ollama branch
# can dispatch to whichever the user picked for Card 3.
resolve_local() {
    local _SLOTS_LOCAL_F="$1/supplier_slots.json"
    LOCAL_PROVIDER="ollama"; LOCAL_BASE="http://127.0.0.1:11434"; LOCAL_STYLE="ollama"
    if [ -f "$_SLOTS_LOCAL_F" ] && command -v jq >/dev/null 2>&1; then
        local _lp _lb
        _lp="$(jq -r '.local.provider // .slots.local.provider // empty' "$_SLOTS_LOCAL_F" 2>/dev/null)"
        _lb="$(jq -r '.local.base_url // .slots.local.base_url // empty' "$_SLOTS_LOCAL_F" 2>/dev/null)"
        [ -n "$_lp" ] && LOCAL_PROVIDER="$_lp"
        [ -n "$_lb" ] && LOCAL_BASE="${_lb%/}"
        # dual: this loop is the Ollama half; LocalAI goes through dual_model.php.
        case "$LOCAL_PROVIDER" in ollama|dual) LOCAL_STYLE="ollama" ;; *) LOCAL_STYLE="openai" ;; esac
    fi
    return 0
}
resolve_local "$_DATA"

cd "$COCKPIT_ROOT" 2>/dev/null || cd "$HOME" 2>/dev/null || {
    echo "[${AGENT_UC}] FATAL: cannot cd to $COCKPIT_ROOT or $HOME" >&2
    exit 1
}

echo "[${AGENT_UC}] Agent loop v3 started (supplier: ${CLI_SUPPLIER:-$AGENT}; re-read per request from the user's slots). CRUD enabled. No Python."
echo "[${AGENT_UC}] Watching: $QUEUE_DIR"

# =============================================================================
# Simple JSON field extractor (no Python, no jq)
# Handles: "key": "value"  — string values only, single-line
# =============================================================================
json_get() {
    local file="$1"
    local key="$2"
    # Extract "key": "value" — handles spaces around colon and value
    grep -o "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" \
        | head -1 \
        | sed 's/.*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' \
        | sed 's/\\\//\//g'   # un-escape JSON \/ → / (this parser is naive)
}

# =============================================================================
# Read recent history from chat JSON — pure bash/awk
# =============================================================================
# History as a JSON messages array [{role:"user"|"assistant", content}] for the
# Ollama /api/chat endpoint — structured roles keep small models from confusing
# who said what (a flat "User:/Assistant:" transcript trips them up). jq handles
# the multi-line text escaping the awk transcript path can't.
read_history_json() {
    local CHAT_FILE="$1" max="$((MAX_HISTORY * 2))"
    if [ ! -f "$CHAT_FILE" ] || ! command -v python3 >/dev/null 2>&1; then echo '[]'; return; fi
    # Chat files store text with RAW (unescaped) newlines, so they aren't valid
    # JSON — a lenient regex extractor pulls each exchange's role + FULL
    # multi-line text and emits a proper JSON messages array for /api/chat.
    python3 - "$CHAT_FILE" "$max" <<'PY' 2>/dev/null || echo '[]'
import re, json, sys
raw = open(sys.argv[1], encoding='utf-8', errors='replace').read()
maxn = int(sys.argv[2])
msgs = []
# role ... text; text runs (non-greedy, across newlines) to the closing quote
# that is followed by either the next "key" or the object's closing brace.
for m in re.finditer(r'"role"\s*:\s*"([^"]+)".*?"text"\s*:\s*"(.*?)"\s*(?:,\s*"[a-z_]+"\s*:|,?\s*\})',
                     raw, re.S):
    role, text = m.group(1), m.group(2)
    for a, b in (('\\n', '\n'), ('\\t', '\t'), ('\\r', '\r'), ('\\"', '"'), ('\\\\', '\\')):
        text = text.replace(a, b)
    if text.strip() == '':
        continue
    msgs.append({'role': 'user' if role == 'user' else 'assistant', 'content': text})
print(json.dumps(msgs[-maxn:], ensure_ascii=False))
PY
}

read_history() {
    local CHAT_FILE="$1"
    [ -f "$CHAT_FILE" ] || return

    # Extract exchanges with mawk-compatible awk (no match() capture arrays)
    # Uses sub() to extract values instead of match(pattern, str, array)
    awk -v max_pairs="$((MAX_HISTORY * 2))" '
    BEGIN { in_exch=0; depth=0; role=""; text=""; count=0; agent=""; model="" }

    /"exchanges"/ && /\[/ { in_exch=1; next }

    in_exch && /^\{/ { depth++; role=""; text=""; agent=""; model="" }
    in_exch && /^  \{/ { depth++; role=""; text=""; agent=""; model="" }
    in_exch && /^    \{/ { depth++; role=""; text=""; agent=""; model="" }

    in_exch && depth==1 {
        # Extract "role" value — strip everything before and after the value
        if ($0 ~ /"role"/) {
            s = $0
            sub(/.*"role"[^"]*"/, "", s)
            sub(/".*/, "", s)
            role = s
        }
        if ($0 ~ /"agent"/) {
            s = $0
            sub(/.*"agent"[^"]*"/, "", s)
            sub(/".*/, "", s)
            agent = s
        }
        if ($0 ~ /"model"/ && $0 !~ /null/) {
            s = $0
            sub(/.*"model"[^"]*"/, "", s)
            sub(/".*/, "", s)
            model = s
        }
        if ($0 ~ /"text"/) {
            s = $0
            sub(/.*"text"[^"]*"/, "", s)
            sub(/"[,]?[ \t]*$/, "", s)
            gsub(/\\n/, " ", s)
            gsub(/\\t/, " ", s)
            text = s
        }
    }

    in_exch && /^[[:space:]]*\}/ && depth==1 {
        depth--
        if (role != "") {
            count++
            roles[count] = role
            texts[count] = text
            agents[count] = agent
            models[count] = model
        }
    }
    in_exch && /^[[:space:]]*\]/ { in_exch=0 }

    END {
        start = count - max_pairs + 1
        if (start < 1) start = 1
        if (count == 0) exit
        # Framing matters. With a bare "[Previous conversation]" header Claude Code
        # answered "No conversation history exists" to "what was the main topic of
        # this chat?" while the transcript sat right above the question: it read
        # "this chat" as its own (empty) CLI session and ignored the block.
        # Reproduced outside the loop with `claude -p`; fixed by saying what the
        # block is and whose words "this chat" / "we" / "earlier" refer to.
        print "[Transcript of THIS chat so far -- the AI Cockpit chat the user is typing in. You are one of its agents. When the user says \"this chat\", \"earlier\", \"before\", \"we\", they mean this transcript, not your own CLI session.]"
        for (i = start; i <= count; i++) {
            if (roles[i] == "user") {
                speaker = "User"
            } else {
                ag = agents[i]
                speaker = toupper(substr(ag,1,1)) substr(ag,2)
                if (models[i] != "") speaker = speaker " (" models[i] ")"
            }
            t = texts[i]
            if (length(t) > 1500) t = substr(t,1,1500) "... [truncated]"
            print speaker ": " t
            print ""
        }
        print "[End of transcript. The new user message follows.]"
        print ""
    }
    ' "$CHAT_FILE"
}

# =============================================================================
# Append exchange to chat JSON — pure bash
# Appends two raw JSON objects to the exchanges array
# =============================================================================
# =============================================================================
# History gate -- does THIS prompt need the previous turns at all?
#
# Until now every CLI prompt got the last MAX_HISTORY exchanges prepended,
# including "say hi in one word". Most turns do not need them. The gate skips
# history ONLY when the prompt is confidently self-contained; every doubt
# includes it. The two failure modes are not symmetric: a wrong "skip"
# reproduces the bug of 2026-09-12 (Claude: "No previous messages exist --
# this conversation just started"); a wrong "include" costs a few hundred
# tokens. So the default is include.
#
#   COCKPIT_HISTORY=auto    (default) gate decides
#   COCKPIT_HISTORY=always  old behaviour, always prepend
#   COCKPIT_HISTORY=never   never prepend (debugging only)
#
# Returns 0 = include history, 1 = skip. Logs the decision so it is observable.
# =============================================================================
# The user's own words: the client wraps every prompt in a style prefix line
# ("[CHAT MODE] Answer conversationally ...", "[DEBUG MODE] ...") and a trailing
# "(Now: ...)" timestamp. Neither is the user speaking. The gate and the keyword
# query must judge the message, not the wrapper -- the CHAT MODE line alone is
# 25 words, which made every prompt "long" and filled all twelve query slots
# before the question itself was reached (live, 2026-09-12).
history_user_text() {
    printf '%s' "$1" \
      | sed -E '1{/^\[[A-Z][A-Z ]* MODE\] /d}' \
      | sed -E 's/\(Now: [0-9]{4}-[0-9]{2}-[0-9]{2}[^)]*\)//g'
}
needs_history() {
    local p="$1" _hc _hrc
    if engine_enabled && _hc="$(history_cli)"; then
        printf '%s' "$p" | php "$_hc" needs --agent "$AGENT_UC"; _hrc=$?
        [ "$_hrc" -le 1 ] && return "$_hrc"                    # 0 = include, 1 = skip; anything else = the helper failed
    fi
    p=$(history_user_text "$p")
    case "${COCKPIT_HISTORY:-auto}" in
        always) echo "[${AGENT_UC}] history: included (COCKPIT_HISTORY=always)"; return 0 ;;
        never)  echo "[${AGENT_UC}] history: skipped (COCKPIT_HISTORY=never)";  return 1 ;;
    esac
    local lower words
    lower=$(printf '%s' "$p" | tr 'A-Z' 'a-z')
    words=$(printf '%s' "$p" | wc -w | tr -d ' ')
    # Short prompts are almost always follow-ups: "and you?", "why?", "ok do it".
    if [ "${words:-0}" -lt 8 ]; then
        echo "[${AGENT_UC}] history: included (short prompt, $words words)"; return 0
    fi
    # Openers that continue a thread.
    if printf '%s' "$lower" | grep -qE '^[[:space:]]*(and|but|so|then|ok|okay|yes|no|also|now|what about|how about|instead)\b'; then
        echo "[${AGENT_UC}] history: included (continuation opener)"; return 0
    fi
    # Back-references: pronouns without an antecedent in the prompt, and words
    # that only make sense against something said before.
    # Deliberately NOT in this list: it / its / that / they / them. As relative
    # or generic pronouns they appear in most self-contained prompts ("a script
    # THAT lists files"), so they would include history nearly every time and
    # the gate would save nothing. Pronoun-only follow-ups are short and are
    # caught by the word-count rule above; anything longer that truly refers
    # back almost always carries one of the explicit markers below.
    if printf '%s' "$lower" | grep -qwE 'those|these|previous|previously|earlier|above|before|last|again|continue|same|too|refer|recap|summari[sz]e|rewrite|redo|retry|repeat|other|another|instead|the (file|code|function|script|output|answer|result|plan|list|error|bug|test|version)|you (said|wrote|mentioned|suggested|gave)|as (we|you|i) (said|discussed)|this (chat|conversation|thread|session|discussion)|the (chat|conversation|thread|session|discussion)|(did|have|were|are|do) we|we (talked|discussed|said|did|were|agreed)|so far|topic|remind|where were we|catch me up|history|summary'; then
        echo "[${AGENT_UC}] history: included (back-reference)"; return 0
    fi
    echo "[${AGENT_UC}] history: skipped (self-contained prompt, $words words)"
    return 1
}

# =============================================================================
# Chat index -- a DERIVED, rebuildable SQLite/FTS5 cache of every exchange.
#
# The chat JSON stays canonical. The index exists so that later steps can find
# the exchanges RELEVANT to a prompt (one FTS MATCH) instead of blindly taking
# the last six, and can hand a file-capable agent a tiny pointer list instead
# of the text. It is maintained here, inside the same flock as the JSON append,
# so the two cannot drift under concurrent writers -- and because PHP on this
# rig has no sqlite module, combos_core.php cannot update it when it rewrites
# a chat. That is handled by reconciliation: whenever the index's row count for
# a chat differs from the JSON's exchange count, the chat is re-indexed from
# the JSON. Delete the .db and it is rebuilt on the next turn.
#
#   <user root>/.chat_index.db     one per data root, table `ex`
# =============================================================================
# Every index call waits up to 3s on a locked db instead of failing: Apache
# (combos_core.php via chat_index.php) writes the same file. WAL is set by
# whichever side opens it first and persists.
sq() { sqlite3 -cmd '.timeout 3000' "$@"; }
chat_index_db() {   # $1 = chat file -> path of the index db for its root
    echo "$(dirname "$(dirname "$1")")/.chat_index.db"
}
chat_index_ready() {  # 0 if sqlite3 with FTS5 is usable
    command -v sqlite3 >/dev/null 2>&1 || return 1
    [ -n "${_CHAT_INDEX_OK:-}" ] && return 0
    if sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(x);' >/dev/null 2>&1; then _CHAT_INDEX_OK=1; return 0; fi
    return 1
}
chat_index_init() {   # $1 = db
    # Shared with Apache (www-data): SQLite creates 0644, which locks the other
    # writer out. Group-writable, group of the parent dir (see chat_index.php).
    local _g; _g=$(stat_gid "$(dirname "$1")")
    for _p in "$1" "$1-wal" "$1-shm"; do
        [ -e "$_p" ] || continue
        chmod 664 "$_p" 2>/dev/null; [ -n "$_g" ] && chgrp "$_g" "$_p" 2>/dev/null
    done
    sq "$1" 'PRAGMA journal_mode=WAL; CREATE VIRTUAL TABLE IF NOT EXISTS ex USING fts5(chat UNINDEXED, id UNINDEXED, role UNINDEXED, agent UNINDEXED, ts UNINDEXED, body, tokenize="porter unicode61");' >/dev/null 2>&1
    for _p in "$1" "$1-wal" "$1-shm"; do
        [ -e "$_p" ] || continue
        chmod 664 "$_p" 2>/dev/null; [ -n "$_g" ] && chgrp "$_g" "$_p" 2>/dev/null
    done
}
# Emit every exchange of a chat as TSV: id role agent ts body(with \n escaped)
# via the same lenient reader read_history_json relies on (python3, regex --
# chat files may hold raw newlines and be invalid strict JSON).
chat_index_extract() {  # $1 = chat file
    python3 - "$1" <<'PYX'
import sys,re,json
raw=open(sys.argv[1],encoding='utf-8',errors='replace').read()
try:
    d=json.loads(raw); exs=d.get('exchanges',[])
except Exception:
    exs=[]
    for m in re.finditer(r'\{[^{}]*?"role"\s*:\s*"([^"]+)"[^{}]*?\}', raw, re.S):
        blk=m.group(0)
        def g(k):
            mm=re.search(r'"'+k+r'"\s*:\s*"((?:[^"\\]|\\.)*)"', blk); return mm.group(1) if mm else ''
        mi=re.search(r'"id"\s*:\s*(\d+)', blk)
        exs.append({'id':int(mi.group(1)) if mi else 0,'role':g('role'),'agent':g('agent'),'timestamp':g('timestamp'),'text':g('text')})
# Unit separator (\x1f), NOT tab: a user row has an empty agent field, and
# bash `read` with a whitespace IFS collapses consecutive tabs, shifting every
# later field one column left. \x1f is not whitespace, so empty fields survive.
for i,e in enumerate(exs):
    body=str(e.get('text','')).replace('\x1f',' ').replace('\t',' ').replace('\n','\\n')
    print('\x1f'.join([str(e.get('id',i+1)),str(e.get('role','')),str(e.get('agent','')),str(e.get('timestamp') or e.get('ts') or ''),body]))
PYX
}
chat_index_count_json() {  # exchanges in the JSON
    chat_index_extract "$1" | wc -l | tr -d ' '
}
chat_index_count_db() {    # rows in the index for this chat
    sq "$1" "SELECT count(*) FROM ex WHERE chat='$(printf '%s' "$2" | sed "s/'/''/g")';" 2>/dev/null || echo 0
}
# Reconcile: rebuild this chat's rows from the JSON when the counts disagree.
# Cheap when they agree (two counts), full re-index only when they do not.
chat_index_sync() {   # $1 = chat file ; call INSIDE the chat's flock
    local _hc
    if engine_enabled && _hc="$(history_cli)"; then
        php "$_hc" sync --chat "$1" --agent "$AGENT_UC" && return 0
    fi
    chat_index_ready || return 0
    local db chat nj nd
    db=$(chat_index_db "$1"); chat="$1"
    chat_index_init "$db"
    nj=$(chat_index_count_json "$chat"); nd=$(chat_index_count_db "$db" "$chat")
    [ "$nj" = "$nd" ] && return 0
    {
        echo "BEGIN;"
        echo "DELETE FROM ex WHERE chat='$(printf '%s' "$chat" | sed "s/'/''/g")';"
        chat_index_extract "$chat" | while IFS=$'\x1f' read -r id role agent ts body; do
            printf "INSERT INTO ex(chat,id,role,agent,ts,body) VALUES('%s',%s,'%s','%s','%s','%s');\n" \
                "$(printf '%s' "$chat" | sed "s/'/''/g")" "${id:-0}" "$role" "$agent" "$ts" "$(printf '%s' "$body" | sed "s/'/''/g")"
        done
        echo "COMMIT;"
    } | sq "$db" 2>&1 | sed "s/^/[${AGENT_UC}] chat index: sqlite: /"
    echo "[${AGENT_UC}] chat index: rebuilt $(basename "$chat") ($nd -> $(chat_index_count_db "$db" "$chat") rows, json has $nj)"
}
# Fast path after a successful append: add just the two new rows.
chat_index_add() {    # $1=chat $2=id $3=role $4=agent $5=ts $6=text(raw)
    case "$(basename "$1")" in chat__*) return 0 ;; esac   # scratch chats (chat__summary_scratch…) stay out of history
    local _hc _tf _hrc
    if engine_enabled && _hc="$(history_cli)"; then
        _tf=$(mktemp); printf '%s' "$6" > "$_tf"
        php "$_hc" add --chat "$1" --id "$2" --role "$3" --agent "$4" --ts "$5" --text-file "$_tf"; _hrc=$?
        rm -f "$_tf"
        [ "$_hrc" -eq 0 ] && return 0
    fi
    chat_index_ready || return 0
    local db; db=$(chat_index_db "$1"); chat_index_init "$db"
    local body; body=$(printf '%s' "$6" | tr '\t' ' ' | sed ':a;N;$!ba;s/\n/\\n/g' | sed "s/'/''/g")
    sq "$db" "INSERT INTO ex(chat,id,role,agent,ts,body) VALUES('$(printf '%s' "$1" | sed "s/'/''/g")',$2,'$3','$4','$5','$body');" 2>/dev/null
}

# =============================================================================
# Selective history (steps 3 and 4 of the context design, 2026-09-12).
#
# Once the gate says a prompt needs history, the old behaviour was "the last
# MAX_HISTORY exchanges, verbatim". With the index in place the loop can do
# better in two ways:
#
#   3. INLINE, SELECTED  -- one FTS MATCH on the prompt's content words ranks
#      the chat's exchanges by relevance (bm25). The most relevant pairs plus
#      the last two pairs (immediate continuity) are inlined, in id order,
#      capped at MAX_HISTORY pairs. A 200-turn chat costs the same as a
#      6-turn one, and the turns that arrive are the ones that matter.
#   4. POINTER           -- a file-capable agent (Claude CLI, which can read
#      files itself) gets only the last pair inline plus the chat file's path
#      and the ids of the relevant exchanges, with the jq line that reads
#      them. It pulls the text only if the message really depends on it.
#
# Everything reads from the index, so the JSON is never parsed at dispatch
# time; the index is reconciled first (two counts when nothing changed).
# Without sqlite3/FTS5 the old read_history / read_history_json paths run.
#
#   COCKPIT_HISTORY_MODE = auto (default) | inline | pointer
#     auto: pointer for Claude CLI on the primary card, inline for everyone
#     else (REST relays, Ollama, and generic CLIs whose file access is not
#     guaranteed).
# =============================================================================
HISTORY_RELEVANT=4     # top-ranked pairs to pull by keyword (besides the last 2)
history_mode() {
    case "${COCKPIT_HISTORY_MODE:-auto}" in
        inline|pointer) echo "${COCKPIT_HISTORY_MODE}"; return ;;
    esac
    if [ "$AGENT" = "claude" ] && { [ "${CLI_SUPPLIER:-}" = "claude" ] || [ -z "${CLI_SUPPLIER:-}" ]; }; then
        echo pointer
    else
        echo inline
    fi
}
# FTS5 query from the prompt: content words of 4+ letters, minus a stoplist,
# minus the timestamp line, each quoted (so FTS never sees an operator), OR-ed.
history_terms() {
    history_user_text "$1" \
      | tr 'A-Z' 'a-z' | tr -c 'a-z0-9\n' ' ' | tr ' ' '\n' \
      | grep -E '^[a-z][a-z0-9]{3,}$' \
      | grep -vxE 'this|that|what|with|from|have|were|does|about|there|their|then|than|they|them|these|those|which|would|could|should|please|tell|show|give|make|want|need|like|just|also|some|more|most|very|into|over|only|your|when|where|will|been|being|here|main|topic|chat|conversation|thread|session|earlier|before|again|same|said|talk|talked|discussed|write|explain|question|answer|really|thing|things|something|anything|everything|know|think|time|last|next|first|still|each|other|another|much|many|such|does|done|doing|using|used' \
      | awk '!seen[$0]++' | head -12 \
      | sed 's/.*/"&"/' | paste -sd'|' - | sed 's/|/ OR /g'
}
# ids (one per line, numeric order) of the exchanges to send: top-ranked pairs
# by MATCH, plus the last two pairs, capped at MAX_HISTORY pairs (last pairs
# win over lower-ranked relevant ones).
history_select_ids() {   # $1 = chat file  $2 = prompt
    local db chat q top last
    db=$(chat_index_db "$1"); chat="$(printf '%s' "$1" | sed "s/'/''/g")"
    q=$(history_terms "$2")
    top=""
    if [ -n "$q" ]; then
        top=$(sq "$db" "SELECT id FROM ex WHERE chat='$chat' AND ex MATCH '$(printf '%s' "$q" | sed "s/'/''/g")' ORDER BY bm25(ex) LIMIT $((HISTORY_RELEVANT * 2));" 2>/dev/null)
    fi
    last=$(sq "$db" "SELECT id FROM ex WHERE chat='$chat' ORDER BY id DESC LIMIT 4;" 2>/dev/null)
    # expand every id to its pair: a user row (odd) owns the following agent
    # row, an agent row (even) belongs to the preceding user row.
    {
        printf '%s\n' $top | awk 'NF{ if ($1%2==1) print $1"\n"$1+1; else print $1-1"\n"$1 }' | head -n $((HISTORY_RELEVANT * 2))
        printf '%s\n' $last
    } | grep -E '^[0-9]+$' | sort -un | awk -v max="$((MAX_HISTORY * 2))" '
        { ids[NR]=$1 }
        END { start = NR - max + 1; if (start < 1) start = 1; for (i = start; i <= NR; i++) print ids[i] }'
}
# Rows for a list of ids as SQL-ready "IN (...)".
_history_in() { printf '%s\n' "$@" | grep -E '^[0-9]+$' | paste -sd, - ; }
# Inline transcript of the given ids, with the framing header that Claude Code
# needs (see read_history for why the header is worded this way).
render_history_inline() {   # $1 = chat file ; $2.. = ids
    local db chat in; db=$(chat_index_db "$1"); chat="$(printf '%s' "$1" | sed "s/'/''/g")"; shift
    in=$(_history_in "$@"); [ -n "$in" ] || return 0
    echo '[Transcript of THIS chat so far -- the AI Cockpit chat the user is typing in. You are one of its agents. When the user says "this chat", "earlier", "before", "we", they mean this transcript, not your own CLI session. Only the exchanges relevant to the new message are shown; gaps are omitted turns.]'
    sq -separator $'\x1f' "$db" "SELECT id, role, agent, body FROM ex WHERE chat='$chat' AND id IN ($in) ORDER BY id;" 2>/dev/null \
      | while IFS=$'\x1f' read -r id role agent body; do
            local who; if [ "$role" = "user" ]; then who="User"; else who="$(printf '%s' "${agent:-agent}" | sed 's/^./\U&/')"; fi
            body=$(printf '%s' "$body" | sed 's/\\n/\n/g')
            [ ${#body} -gt 1500 ] && body="${body:0:1500}... [truncated]"
            printf '#%s %s: %s\n\n' "$id" "$who" "$body"
        done
    echo '[End of transcript. The new user message follows.]'
    echo
}
# Same selection as a JSON messages array for /api/chat (Ollama / OpenAI-style).
render_history_json() {   # $1 = chat file ; $2.. = ids
    local db chat in; db=$(chat_index_db "$1"); chat="$(printf '%s' "$1" | sed "s/'/''/g")"; shift
    in=$(_history_in "$@"); [ -n "$in" ] || { echo '[]'; return 0; }
    sq -json "$db" "SELECT role, body FROM ex WHERE chat='$chat' AND id IN ($in) ORDER BY id;" 2>/dev/null \
      | jq -c '[ .[] | { role: (if .role == "user" then "user" else "assistant" end),
                        content: (.body | gsub("\\\\n"; "\n")) } | select(.content != "") ]' 2>/dev/null || echo '[]'
}
# Pointer block for a file-capable agent: last pair inline, the rest as ids +
# the exact command that reads them from the canonical JSON.
render_history_pointer() {   # $1 = chat file ; $2.. = ids
    local f="$1"; shift
    local all="$*" lastpair rest n
    n=$#; lastpair=""; rest=""
    if [ "$n" -ge 2 ]; then
        set -- $(printf '%s\n' "$@" | sort -n)
        while [ $# -gt 2 ]; do rest="$rest $1"; shift; done
        lastpair="$1 $2"
    else
        lastpair="$all"
    fi
    [ -n "$lastpair" ] && render_history_inline "$f" $lastpair
    if [ -n "$rest" ]; then
        local list; list=$(printf '%s\n' $rest | paste -sd, -)
        echo "[Earlier turns of this chat that look relevant to the new message (by keyword index): exchange ids $list. The full transcript is the JSON file $f -- .exchanges[] items carry id, role, agent, text. Read only those turns, and only if the new message depends on them:"
        echo "  jq '.exchanges[] | select(.id as \$i | [$list] | index(\$i)) | {id,role,text}' '$f'"
        echo "]"
        echo
    fi
}
# The one entry point used at dispatch. Sets HISTORY (text) or, for the JSON
# path, prints the messages array. Falls back to the whole-tail readers when
# the index is unavailable, and logs what was chosen so it is observable.
build_history() {   # $1 = chat file  $2 = prompt  $3 = text|json
    local f="$1" p="$2" fmt="${3:-text}" ids mode _hc _ht _hrc
    if engine_enabled && _hc="$(history_cli)"; then
        _ht=$(mktemp)
        printf '%s' "$p" | php "$_hc" build --chat "$f" --format "$fmt" --mode "$(history_mode)" --agent "$AGENT_UC" > "$_ht"; _hrc=$?
        if [ "$_hrc" -le 1 ]; then cat "$_ht"; rm -f "$_ht"; return "$_hrc"; fi   # 0/1 = answered (1 as the Bash returns it); its log lines went to stderr, as the Bash's do
        rm -f "$_ht"
    fi
    if ! chat_index_ready || [ ! -f "$f" ]; then
        echo "[${AGENT_UC}] history: whole tail (no index)" >&2
        if [ "$fmt" = json ]; then read_history_json "$f"; else read_history "$f"; fi
        return
    fi
    ( flock -x 200; chat_index_sync "$f" >&2 ) 200>"${f}.lock"
    ids=$(history_select_ids "$f" "$p")
    if [ -z "$ids" ]; then
        echo "[${AGENT_UC}] history: whole tail (index empty)" >&2
        if [ "$fmt" = json ]; then read_history_json "$f"; else read_history "$f"; fi
        return
    fi
    if [ "$fmt" = json ]; then
        echo "[${AGENT_UC}] history: inline-json ids=$(printf '%s\n' $ids | paste -sd, -)" >&2
        render_history_json "$f" $ids
        return
    fi
    mode=$(history_mode)
    echo "[${AGENT_UC}] history: $mode ids=$(printf '%s\n' $ids | paste -sd, -)" >&2
    if [ "$mode" = pointer ]; then render_history_pointer "$f" $ids; else render_history_inline "$f" $ids; fi
}

append_to_chat() {
    local CHAT_FILE="$1"
    local PROJECT="$2"
    local CHAT_NAME="$3"
    local USER_TEXT_FILE="$4"
    local AGENT_TEXT_FILE="$5"
    local MODEL="$6"
    local DURATION="$7"
    local MSTYLE="${8:-}"
    local MMODE="${9:-}"

    # Saving the turn can be done by history_cli.php (same switch): the same file layout and the same index rows,
    # without awk/sed/bc/mktemp. Exit 3 = it wrote NOTHING, so the Bash below can still do it; any other non-zero
    # status means it may have written, and writing again would duplicate the turn — so that case is only logged.
    local _hc _hrc
    if engine_enabled && _hc="$(history_cli)"; then
        php "$_hc" append --chat "$CHAT_FILE" --project "$PROJECT" --chat-name "$CHAT_NAME" --user-file "$USER_TEXT_FILE" \
            --agent-file "$AGENT_TEXT_FILE" --model "$MODEL" --duration "$DURATION" --style "$MSTYLE" --mode "$MMODE" \
            --agent "$AGENT" --supplier "${CLI_SUPPLIER:-${LOCAL_PROVIDER:-$AGENT}}" --agent-uc "$AGENT_UC"
        _hrc=$?
        [ "$_hrc" -eq 0 ] && return 0
        if [ "$_hrc" -ne 3 ]; then echo "[${AGENT_UC}] append_to_chat: history_cli.php exited $_hrc after it may have written; NOT retrying with the Bash"; return 1; fi
    fi

    local NOW
    # Zulu suffix, not a bare UTC stamp: without it every reader (the app's
    # JS above all) takes it for local time — chat turns showed UTC while the
    # system lines beside them showed local (2026-09-16).
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local USER_TEXT AGENT_TEXT
    USER_TEXT=$(cat "$USER_TEXT_FILE" 2>/dev/null)
    AGENT_TEXT=$(cat "$AGENT_TEXT_FILE" 2>/dev/null)

    # JSON-escape a string (escape backslash, quote, and control chars)
    json_escape() {
        local s="$1"
        s="${s//\\/\\\\}"   # backslash first
        s="${s//\"/\\\"}"   # quotes
        s="${s//$'\n'/\\n}" # newlines
        s="${s//$'\r'/\\r}" # carriage returns
        s="${s//$'\t'/\\t}" # tabs
        # Strip remaining control bytes 0x00-0x1F (LOW-9) — JSON spec disallows them.
        # tr is faster than bash regex for this single byte-range pass.
        s=$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')
        echo "$s"
    }

    local USER_ESC AGENT_ESC MODEL_ESC
    USER_ESC=$(json_escape "$USER_TEXT")
    AGENT_ESC=$(json_escape "$AGENT_TEXT")
    [ -z "$(printf %s "$AGENT_TEXT" | tr -d "[:space:]")" ] && AGENT_ESC="[stopped before any answer]"   # Stop pressed before the first words: say so instead of saving an empty reply
    MODEL_ESC=$(json_escape "$MODEL")

    # Serialize concurrent writers: multiple agent_loops (Broadcast/Pipeline, or
    # both UI versions v1+v2) can append to the SAME chat file at once → stale
    # read → lost-update race. flock makes the whole read-modify-write atomic
    # per chat file. Lock auto-releases when the subshell (fd 200) closes.
    (
    flock -x 200
    # Reconcile the derived index FIRST, while we hold the lock: if PHP
    # (combos_core.php) rewrote this chat since the last turn, the index is
    # behind and gets rebuilt from the JSON here. Cheap when nothing changed.
    [ -f "$CHAT_FILE" ] && chat_index_sync "$CHAT_FILE"
    # If chat file doesn't exist, create it. Note: "exchanges" is opened on a
    # separate line below — keeping "[" and "]" each on their own lines is
    # critical for the awk insertion logic to find the closing bracket.
    if [ ! -f "$CHAT_FILE" ]; then
        mkdir -p "$(dirname "$CHAT_FILE")"
        cat > "$CHAT_FILE" << JSONEOF
{
  "schema_version": 1,
  "project": "$PROJECT",
  "chat": "$CHAT_NAME",
  "created": "$NOW",
  "updated": "$NOW",
  "exchanges": [
  ]
}
JSONEOF
        chmod 664 "$CHAT_FILE" 2>/dev/null
    fi

    # Get next ID — count existing exchanges and add 1
    local NEXT_ID RAW_COUNT
    RAW_COUNT=$(grep -c '"role"' "$CHAT_FILE" 2>/dev/null) || RAW_COUNT=0
    # Strip any whitespace/newlines that would break arithmetic
    RAW_COUNT=$(echo "$RAW_COUNT" | tr -d '[:space:]')
    [ -z "$RAW_COUNT" ] && RAW_COUNT=0
    NEXT_ID=$(( RAW_COUNT + 1 ))

    # Build two new exchange JSON objects
    local MODEL_JSON="null"
    [ -n "$MODEL_ESC" ] && MODEL_JSON="\"$MODEL_ESC\""

    local DUR_JSON="null"
    # HIGH-2 fix: previously "0.0" or ".5" were string-equal to "0"? No — string
    # != 0 means ".5" passed but "0.0" was treated as null. Use numeric compare:
    # DURATION > 0 → emit it as a number; otherwise null.
    if [ -n "$DURATION" ]; then
        local _dur_gt_zero
        _dur_gt_zero=$(echo "$DURATION > 0" | bc 2>/dev/null)
        # bc prints ".9" for sub-second durations: valid for jq, a JSON syntax error for PHP
        # (export.php answered "Corrupt chat file" for every chat with such a turn — rig, b86)
        [ "$_dur_gt_zero" = "1" ] && DUR_JSON="$(printf '%s' "$DURATION" | sed 's/^\./0./')"
    fi

    local NEW_EXCHANGES
    NEW_EXCHANGES=$(cat << EXCHEOF
    {
      "id": $NEXT_ID,
      "timestamp": "$NOW",
      "role": "user",
      "text": "$USER_ESC"
    },
    {
      "id": $((NEXT_ID + 1)),
      "timestamp": "$NOW",
      "role": "agent",
      "agent": "$AGENT",
      "supplier": "$(json_escape "${CLI_SUPPLIER:-${LOCAL_PROVIDER:-$AGENT}}")",
      "model": $MODEL_JSON,
      "duration_s": $DUR_JSON,
      "style": "$(json_escape "$MSTYLE")",
      "mode": "$(json_escape "$MMODE")",
      "text": "$AGENT_ESC"
    }
EXCHEOF
)

    # Insert before the closing ] of exchanges array
    # Use a temp file to avoid in-place issues
    local TMP
    TMP=$(mktemp)

    # Auto-heal pre-existing files that were created with the old single-line
    # "exchanges": [] format. The awk insertion below only matches "]" on its
    # own line, so without this normalization no exchange would ever be
    # appended to such files (silent data loss).
    # ...and the SAME heal must accept a trailing comma. combos_core.php rewrites
    # the whole file with PHP's JSON_PRETTY_PRINT, where "exchanges" is not the
    # last key, so an empty array lands as `"exchanges": [],` -- which the
    # original pattern (anchored on `[]` at end of line) never matched.
    sedi 's/"exchanges":[[:space:]]*\[\]\([[:space:]]*,\{0,1\}\)[[:space:]]*$/"exchanges": [\n  ]\1/' "$CHAT_FILE"

    # Strategy: find the last ] that closes exchanges, insert before it
    # We look for the pattern:  \n  ]  followed by optional whitespace and \n}
    # CRITICAL: pass the new block via the ENVIRONMENT, not `awk -v`. awk's -v
    # assignment processes backslash escape sequences, so the JSON-escaped "\n",
    # "\t", "\\" inside the block would be turned back into REAL control chars —
    # re-corrupting the file the moment any agent text spans multiple lines.
    # ENVIRON[] values are taken literally (no escape processing).
    # The closing bracket may be `]` OR `],`: after combos_core.php has rewritten
    # a chat with PHP's pretty-printer, "exchanges" is followed by "updated", so
    # the array closes as `],`. The original pattern required a bare `]`, matched
    # nothing, and every CLI turn appended to such a chat was silently dropped --
    # the "updated" stamp below still moved, so the file LOOKED written to.
    # Measured 2026-09-12: 8 of 13 of Dario's chats were in that state. The line
    # is printed unchanged afterwards, so the comma is preserved either way.
    # 2026-10-05: the block used to travel in the ENVIRONMENT of awk (NEW_EXCHANGES="$NEW_EXCHANGES" awk ...). An
    # environment string is capped at 128 KB by the kernel, so a turn of that size made awk fail to START, $TMP stayed
    # empty, and the `mv` below replaced the WHOLE chat file with it — every earlier turn gone, and this one not saved.
    # It now goes through a file (same bytes: awk prints it followed by a newline, as it printed the variable), and the
    # chat file is never replaced when awk did not succeed.
    local NEWF; NEWF=$(mktemp)
    printf '%s' "$NEW_EXCHANGES" > "$NEWF"
    awk -v NEWF="$NEWF" '
    function emit(   nl) { while ((getline nl < NEWF) > 0) print nl; close(NEWF) }
    /^[[:space:]]*\],?[[:space:]]*$/ && !done {
        # Check if next meaningful line is closing brace (end of file structure)
        # We insert before this closing bracket
        # First check if exchanges array is empty
        if (found_open && !has_items) {
            emit()
        } else if (found_open) {
            print ","
            emit()
        }
        done = 1
    }
    { print }
    /"exchanges"/ { found_open = 1 }
    /"role"/ { has_items = 1 }
    ' "$CHAT_FILE" > "$TMP" || { rm -f "$TMP" "$NEWF"; echo "[${AGENT_UC}] append_to_chat: could not insert the turn into $(basename "$CHAT_FILE") — chat file left untouched" >&2; exit 1; }
    rm -f "$NEWF"

    # Update the "updated" timestamp
    sedi "s/\"updated\":[[:space:]]*\"[^\"]*\"/\"updated\": \"$NOW\"/" "$TMP"

    mv "$TMP" "$CHAT_FILE"
    chmod 664 "$CHAT_FILE" 2>/dev/null
    # Index the two rows just written. Same ids the JSON got. If this ever
    # fails, the next turn's reconcile repairs it -- the JSON is the truth.
    chat_index_add "$CHAT_FILE" "$NEXT_ID"       user  ""       "$NOW" "$USER_TEXT"
    chat_index_add "$CHAT_FILE" "$((NEXT_ID+1))" agent "$AGENT" "$NOW" "$AGENT_TEXT"
    ) 200>"${CHAT_FILE}.lock"
}

# =============================================================================
# CRUD SYSTEM PROMPT
# =============================================================================
CRUD_SYSTEM_PROMPT='[SYSTEM: File Operation Protocol]
You are running in a text-only pipeline. You do NOT have access to file system
tools, Write tools, Edit tools, or Bash tools. The ONLY way to perform file
operations is by embedding the command blocks below in your text response.
An external executor parses and runs them automatically.

To CREATE or OVERWRITE a file:
%%CREATE:path/to/file.ext%%
exact file contents here
%%END%%

To APPEND to a file:
%%APPEND:path/to/file.ext%%
content to append
%%END%%

To READ a file:    %%READ:path/to/file.ext%%
To READ a library entry: %%LIB:Title-or-id%%   (fetches URL or reads file)
To READ a snippet:    %%SNIP:Title-or-id%%   (loads a saved function/procedure)
To READ a source:     %%SRC:Title-or-id%%    (loads a saved whole program/file)
To SEARCH the web: %%SEARCH:your search terms%%   (returns top 5 results)
To FETCH a URL:    %%FETCH:https://example.com/page%%   (returns page text, 16KB cap)
To DELETE a file:  %%DELETE:path/to/file.ext%% then %%CONFIRM:DELETE%%
To MAKE a dir:     %%MKDIR:path/to/newdir%%
To LIST contents:  %%LIST%%   or   %%LIST:subdir%%

REUSABLE CODE:
Do NOT write any %%PROPOSE%% blocks. When you produce code, just put it in a
normal fenced Markdown block with its language, e.g.:
```pascal
program Foo; begin ... end.
```
The app automatically adds every fenced code block to the user'\''s Pending
Proposals for one-click saving — you do not queue anything yourself.

RULES:
- Paths are relative to project root. No "../" or absolute paths.
- BE TERSE. Do NOT explain what you are about to do before doing it.
- Output real answers/code directly; only use %%blocks%% for actual file ops.
- Do NOT use any tool calls. Only %%blocks%% are processed.
[END SYSTEM]'

# One loop per agent and queue (2026-10-06). Two loops reading the same queue pick up the same prompt and answer it twice. That happened for real
# when the supervisor started loops while the tmux ones from an earlier start were still running. The first loop writes its pid here; a second one
# that finds a live loop of the same agent in that file says so and leaves. (Stale files are harmless: the pid must be alive AND be this script.)
_LOOP_PIDF="$QUEUE_DIR/.loop_${AGENT}.pid"
if [ -f "$_LOOP_PIDF" ]; then
    _other=$(cat "$_LOOP_PIDF" 2>/dev/null)
    if [ -n "$_other" ] && [ "$_other" != "$$" ] && ps -p "$_other" -o args= 2>/dev/null | grep -q -e "agent_loop.sh $AGENT" -e "aicengine loop $AGENT"; then
        echo "[${AGENT_UC}] Another agent loop (pid $_other) already serves $QUEUE_DIR; this one is not needed and exits."
        exit 0
    fi
fi
echo "$$" > "$_LOOP_PIDF" 2>/dev/null || true

# =============================================================================
# Main loop
# =============================================================================
while true; do
    PROMPT_FILE=$(ls "$QUEUE_DIR/${AGENT}_prompt_"*.txt 2>/dev/null | head -1)

    if [ -n "$PROMPT_FILE" ]; then
        INTAKE_DONE=0
        intake_engine "$PROMPT_FILE" && INTAKE_DONE=1
        if [ "$INTAKE_DONE" != 1 ]; then
        TOKEN=$(basename "$PROMPT_FILE" .txt | sed "s/${AGENT}_prompt_//")
        OUT_FILE="$RESPONSE_DIR/${TOKEN}.out"
        DONE_FILE="$RESPONSE_DIR/${TOKEN}.done"
        META_FILE="$QUEUE_DIR/${TOKEN}_meta.json"
        # No metadata means project, chat, per-user root and models all fall back to
        # defaults -- the SHARED root, not the user's. bridge.php publishes the prompt
        # last so this should never happen, but a silent misroute is how a finished
        # turn ended up in the wrong chat file without a single error (2026-10-01).
        [ -f "$META_FILE" ] || echo "[${AGENT_UC}] WARNING: no metadata for ${TOKEN} — falling back to the shared root and default project/models; this turn may be saved to the wrong chat"

        # ── Read metadata (simple JSON, grep-parseable) ──────────────────────
        MODEL=""
        PROJECT="default"
        CHAT_NAME="default"
        CLAUDE_MODEL="sonnet"
        GEMINI_MODEL="auto"
        CLAUDE_EFFORT=""   # base64 prompt-prefix from *_controls.json (inject:prompt_prefix)
        GEMINI_EFFORT=""
        CLAUDE_ARGS_B64="" # base64 extra CLI args from *_controls.json (inject:cli_args)
        GEMINI_ARGS_B64=""

        REQ_ROOT=""   # reset per request; filled from meta below
        REQ_DATA=""   # per-user cockpit_data (for worker_relay key lookup)
        REQ_WEB=""    # web root (to locate worker_relay.php)
        RAG_B64=""    # push-RAG block (base64) computed by bridge.php
        if [ -f "$META_FILE" ]; then
            PROJECT=$(json_get "$META_FILE" "project")
            CHAT_NAME=$(json_get "$META_FILE" "chat")
            MA_STYLE=$(json_get "$META_FILE" "style")
            MA_MODE=$(json_get "$META_FILE" "mode")
            REQ_ROOT=$(json_get "$META_FILE" "projects_root")
            REQ_DATA=$(json_get "$META_FILE" "cockpit_data")
            REQ_WEB=$(json_get "$META_FILE" "web_root")
            CLAUDE_MODEL=$(json_get "$META_FILE" "claude_model")
            GEMINI_MODEL=$(json_get "$META_FILE" "gemini_model")
            CLAUDE_EFFORT=$(json_get "$META_FILE" "claude_effort")
            GEMINI_EFFORT=$(json_get "$META_FILE" "gemini_effort")
            CLAUDE_ARGS_B64=$(json_get "$META_FILE" "claude_args")
            GEMINI_ARGS_B64=$(json_get "$META_FILE" "gemini_args")
            RAG_B64=$(json_get "$META_FILE" "rag")
            internal_setup
            REQ_IMAGES=$(json_get "$META_FILE" "images")     # pipe-separated paths, catalog image_mode=flag
            [ -z "$PROJECT" ]      && PROJECT="default"
            [ -z "$CHAT_NAME" ]    && CHAT_NAME="default"
            [ -z "$CLAUDE_MODEL" ] && CLAUDE_MODEL="sonnet"
            [ -z "$GEMINI_MODEL" ] && GEMINI_MODEL="auto"
            rm -f "$META_FILE"
            # The request names the user's cockpit_data: that is where the Slots
            # dialog saved supplier_slots.json. Re-resolve Card 1/2/3 from it.
            if [ -n "$REQ_DATA" ] && [ -f "$REQ_DATA/supplier_slots.json" ]; then
                resolve_supplier "$REQ_DATA"; resolve_local "$REQ_DATA"
            fi
        fi

        # Ollama model file
        MODEL_FILE="$QUEUE_DIR/${TOKEN}_model.txt"
        [ -f "$MODEL_FILE" ] && MODEL=$(cat "$MODEL_FILE") && rm -f "$MODEL_FILE"

        # ── Paths ────────────────────────────────────────────────────────────
        # Use the per-request root from meta (paths.php's per-user scoping) so we
        # write where THIS user's UI reads; fall back to the daemon's shared root.
        REQ_ROOT="${REQ_ROOT:-$COCKPIT_ROOT}"
        if [ "$PROJECT" = "_standalone" ]; then
            PROJECT_DIR="$REQ_ROOT/_standalone"
        else
            PROJECT_DIR="$REQ_ROOT/$PROJECT"
        fi
        CHAT_FILE="$PROJECT_DIR/chat_${CHAT_NAME}.json"
        mkdir -p "$PROJECT_DIR"
        # Work from the project folder: a CLI that ignores the %%block%% rule and uses its
        # own file tools (Claude Code, --dangerously-skip-permissions) then still writes
        # into THIS user's project, not the daemon's shared root (haiku.txt landed there, rig b86).
        cd "$PROJECT_DIR" 2>/dev/null || cd "$COCKPIT_ROOT" 2>/dev/null || true
        fi   # INTAKE_DONE

        # ── Apply capabilities — wires MCP/Skills/Tool-shims for this project
        # The bridge.php already called capabilities.php?action=apply which
        # wrote staged configs to $PROJECT_DIR/.cockpit_caps/. Here we move
        # them into place where each agent expects to find them.
        # All steps are idempotent and safe to run on every prompt.
        ROUTE_DONE=0
        route_engine && ROUTE_DONE=1
        if [ "$ROUTE_DONE" != 1 ]; then
        CAPS_STAGE="$PROJECT_DIR/.cockpit_caps"
        OLLAMA_CAPS_PROMPT=""

        if [ -d "$CAPS_STAGE" ]; then
            case "$AGENT" in
                claude)
                    # Claude reads MCP config from PROJECT_DIR/.mcp.json
                    # (per-workspace) — copy if our staged file has servers.
                    if [ -s "$CAPS_STAGE/claude_mcp.json" ]; then
                        cp -f "$CAPS_STAGE/claude_mcp.json" "$PROJECT_DIR/.mcp.json" 2>/dev/null || true
                    fi
                    # Symlink any project-specific skills into ~/.claude/skills/
                    # so Claude reads them as expert playbooks.
                    if [ -s "$CAPS_STAGE/claude_skills.json" ] && command -v jq >/dev/null 2>&1; then
                        mkdir -p "$HOME/.claude/skills"
                        # The JSON is { "skills": { "id1": "/abs/path", ... } }
                        jq -r '.skills | to_entries[] | "\(.key)\t\(.value)"' \
                            "$CAPS_STAGE/claude_skills.json" 2>/dev/null | \
                        while IFS=$'\t' read -r sk_id sk_path; do
                            if [ -f "$sk_path" ]; then
                                ln -sfn "$sk_path" "$HOME/.claude/skills/${sk_id}.md" 2>/dev/null || true
                            fi
                        done
                    fi
                    ;;
                gemini)
                    # Gemini reads MCP config from ~/.gemini/settings.json
                    # We merge our staged servers into the existing settings,
                    # preserving any other user settings that might exist.
                    if [ -s "$CAPS_STAGE/gemini_mcp.json" ] && command -v jq >/dev/null 2>&1; then
                        mkdir -p "$HOME/.gemini"
                        SETTINGS="$HOME/.gemini/settings.json"
                        if [ ! -f "$SETTINGS" ]; then echo '{}' > "$SETTINGS"; fi
                        # Merge: take everything from existing settings, override
                        # mcpServers with our staged value
                        jq -s '.[0] * .[1]' "$SETTINGS" "$CAPS_STAGE/gemini_mcp.json" \
                            > "$SETTINGS.tmp" 2>/dev/null && mv "$SETTINGS.tmp" "$SETTINGS"
                    fi
                    ;;
                ollama)
                    # Ollama gets capability info as a system-prompt prefix.
                    # The shim text will be prepended to the user's prompt.
                    if [ -s "$CAPS_STAGE/ollama_system_prompt.txt" ]; then
                        OLLAMA_CAPS_PROMPT=$(cat "$CAPS_STAGE/ollama_system_prompt.txt")
                    fi
                    ;;
            esac
        fi

        # ── Workers auto-route check ─────────────────────────────────────────
        # If this project has workers auto-route enabled, all agents (incl
        # Claude/Gemini) get a system-prompt addition advising them about the
        # %%WORKER:provider:task:prompt%% syntax. The crud_executor.sh script
        # picks up these markers and dispatches to workers.php.
        WORKERS_AUTO_PROMPT=""
        if [ -f $_DATA/workers_state.json ] && command -v jq >/dev/null 2>&1; then
            # Check if auto-route is enabled for this project
            auto_on=$(jq -r --arg p "$PROJECT" \
                '.auto_route_projects // [] | map(select(. == $p)) | length' \
                $_DATA/workers_state.json 2>/dev/null)
            if [ "$auto_on" = "1" ]; then
                # Get list of available providers (key set + enabled)
                _ck_hdr; avail=$(curl -s ${_CK_HF:+-H "@$_CK_HF"} --max-time 4 "${COCKPIT_BASE_URL:-http://localhost/cockpit}/workers.php?action=models" 2>/dev/null \
                       | jq -r '.models // [] | map(.provider) | unique | join(", ")' 2>/dev/null); rm -f "${_CK_HF:-/nonexistent}"
                if [ -n "$avail" ] && [ "$avail" != "null" ]; then
                    WORKERS_AUTO_PROMPT="
[SYSTEM: Workers Auto-Route Available]
For tasks outside your specialty (image generation, audio, niche translations,
or when you've hit token limits), you can dispatch to online specialty workers
by emitting a marker like:
    %%WORKER:provider:task:prompt%%

Available providers: $avail
Tasks: text, translate, summary, image, image-gen, audio, code

The result will be returned to you in the next turn as %%WORKER_RESULT:...%%.
Use sparingly — only when your own capabilities don't suffice.
"
                fi
            fi
        fi

        # ── Tools auto-route check ──────────────────────────────────────────
        # If this project has tools auto-route enabled, all agents get a
        # system-prompt addition advising them about the %%TOOL:%% syntax.
        # crud_executor.sh dispatches the markers to tools.php and returns
        # output paths the agent can reason about in subsequent turns.
        TOOLS_AUTO_PROMPT=""
        if [ -f $_DATA/tools_state.json ] && command -v jq >/dev/null 2>&1; then
            t_auto_on=$(jq -r --arg p "$PROJECT" \
                '.auto_route_projects // [] | map(select(. == $p)) | length' \
                $_DATA/tools_state.json 2>/dev/null)
            if [ "$t_auto_on" = "1" ]; then
                # Build a compact list of available <tool>:<preset> pairs
                _ck_hdr; t_avail=$(curl -s ${_CK_HF:+-H "@$_CK_HF"} --max-time 4 "${COCKPIT_BASE_URL:-http://localhost/cockpit}/tools.php?action=presets" 2>/dev/null \
                         | jq -r '.presets // [] | map(.value) | join(", ")' 2>/dev/null); rm -f "${_CK_HF:-/nonexistent}"
                if [ -n "$t_avail" ] && [ "$t_avail" != "null" ] && [ "$t_avail" != "" ]; then
                    TOOLS_AUTO_PROMPT="
[SYSTEM: Local Tools Auto-Route Available]
For file conversions and transformations (media, audio, transcription, document
formats, ebooks, subtitles), you can dispatch to local CLI tools by emitting:
    %%TOOL:tool:preset:input_path%%
or with extra arguments:
    %%TOOL:tool:preset:input_path|extra_args%%

Available tool:preset pairs: $t_avail

The output path is returned in the next turn as %%TOOL_RESULT:tool:output_path%%.
Use these for offline file operations — no internet required.
"
                fi
            fi
        fi
        fi   # ROUTE_DONE

        # ── Read prompt ──────────────────────────────────────────────────────
        if [ "$INTAKE_DONE" != 1 ]; then
        USER_PROMPT=$(cat "$PROMPT_FILE")
        rm -f "$PROMPT_FILE"

        # ── Supplier control: prompt_prefix injection (effort, etc.) ─────────
        # The selected option's text arrives base64-encoded in the meta (so it
        # survives the JSON/sanitiser pipeline). Decode and prepend to the user's
        # prompt. Defined in cockpit_data/{claude,gemini}_controls.json.
        _EFFORT_B64=""
        case "$AGENT" in
            claude) _EFFORT_B64="$CLAUDE_EFFORT" ;;
            gemini) _EFFORT_B64="$GEMINI_EFFORT" ;;
        esac
        if [ -n "$_EFFORT_B64" ]; then
            _EFFORT_TXT=$(printf '%s' "$_EFFORT_B64" | base64 -d 2>/dev/null)
            [ -n "$_EFFORT_TXT" ] && USER_PROMPT="${_EFFORT_TXT}${USER_PROMPT}"
        fi

        # ── Supplier control: cli_args injection (e.g. Claude --effort high) ──
        # Decoded then whitelisted to flag-ish tokens only (no shell metachars),
        # then word-split into the CLI invocation below via $EXTRA_CLI_ARGS.
        EXTRA_CLI_ARGS=""
        _ARGS_B64=""
        case "$AGENT" in
            claude) _ARGS_B64="$CLAUDE_ARGS_B64" ;;
            gemini) _ARGS_B64="$GEMINI_ARGS_B64" ;;
        esac
        if [ -n "$_ARGS_B64" ]; then
            _ARGS_TXT=$(printf '%s' "$_ARGS_B64" | base64 -d 2>/dev/null)
            # Allow only flags/values: letters, digits, space, - _ . : = /
            if printf '%s' "$_ARGS_TXT" | grep -qE '^[-A-Za-z0-9 _.:=/]*$'; then
                EXTRA_CLI_ARGS="$_ARGS_TXT"
            fi
        fi
        fi   # INTAKE_DONE

        echo "[${AGENT_UC}] Processing: $TOKEN | Project: $PROJECT | Chat: $CHAT_NAME"

        # ── Build full prompt ────────────────────────────────────────────────
        if needs_history "$USER_PROMPT"; then
            HISTORY=$(build_history "$CHAT_FILE" "$USER_PROMPT" text)
        else
            HISTORY=""
        fi

        assemble_prompt

        # ── Run agent ────────────────────────────────────────────────────────
        # Pre-create the .out file so the streaming poll endpoint can find it
        # immediately. Each agent uses the best available streaming approach:
        #   - Claude: --output-format stream-json + jq for token-by-token deltas
        #   - Gemini: stdbuf line buffering (CLI doesn't support stream output yet)
        #   - Ollama: native streaming, just needs stdbuf to defeat the pipe buffer
        : > "$OUT_FILE"
        chmod 664 "$OUT_FILE" 2>/dev/null

        STDBUF=""
        command -v stdbuf >/dev/null 2>&1 && STDBUF="stdbuf -oL -eL"
        HAS_JQ=0
        command -v jq >/dev/null 2>&1 && HAS_JQ=1

        START_TIME=$(date +%s%N)

        case "$AGENT" in
            claude)
              # Card 1 (primary) can be any paid-subscription CLI. Claude keeps its
              # tuned path; any other CLI uses the catalog-driven generic dispatch.
              cockpit_cli_isolate    # personal hooks/plugins stay out unless asked for
              if [ "$CLI_SUPPLIER" = "claude" ] || [ -z "$CLI_SUPPLIER" ]; then
                # Model now comes from claude_controls.json as a full CLI string
                # (e.g. claude-opus-4-8). Use it directly; still map the legacy
                # aliases for backward compatibility with old stored selections.
                case "$CLAUDE_MODEL" in
                    claude-*) CF="$CLAUDE_MODEL" ;;
                    opus)     CF="claude-opus-4-8" ;;
                    haiku)    CF="claude-haiku-4-5-20251001" ;;
                    opusplan) CF="claude-opus-4-8" ;;
                    *)        CF="claude-sonnet-4-6" ;;
                esac
                run_claude_json "$CF"
              else
                # Generic CLI dispatch (Codex/Qwen/Aider/any) — catalog-driven, incl.
                # local backends (Aider→Ollama via model_prefix + OLLAMA_API_BASE).
                run_generic_cli "$CLAUDE_MODEL"
              fi
                ;;
            gemini)
              # The "fallback" slot (Card 2) can be any free-REST provider OR a
              # CLI-kind agent (e.g. Aider). CLI agents (have a binary, no relay) use
              # the same generic dispatch as Card 1; REST/relay providers route
              # through the Workers engine (worker_relay.php).
              if [ -n "$CLI_SUPPLIER" ] && [ "$CLI_SUPPLIER" != "gemini" ] && [ -z "$CLI_RELAY" ] && [ -n "$CLI_HASBIN" ]; then
                # Card 2 = a CLI-kind agent (Aider/Codex/…) — generic catalog dispatch.
                run_generic_cli "$GEMINI_MODEL"
              elif [ -n "$CLI_SUPPLIER" ] && [ "$CLI_SUPPLIER" != "gemini" ]; then
                case "$CLI_SUPPLIER" in
                    groq_build|groq) RELAY_PROVIDER="groq";        RELAY_MODEL="openai/gpt-oss-120b" ;;
                    *huggingface*|hf) RELAY_PROVIDER="huggingface"; RELAY_MODEL="meta-llama/Llama-3.1-8B-Instruct" ;;
                    *cloudflare*)    RELAY_PROVIDER="cloudflare";  RELAY_MODEL="@cf/meta/llama-3.1-8b-instruct" ;;
                    *)               RELAY_PROVIDER="" ;;
                esac
                # Use the model picked in the card dropdown (now the provider's
                # models), unless it's empty / a leftover Gemini/auto value.
                case "$GEMINI_MODEL" in
                    ""|auto|gemini-*|*Flash*|*flash*) : ;;
                    *) RELAY_MODEL="$GEMINI_MODEL" ;;
                esac
                if [ -z "$RELAY_PROVIDER" ]; then
                    echo "[FALLBACK ERROR] unsupported free-REST provider: $CLI_SUPPLIER" >> "$OUT_FILE"
                else
                    _RELAY_PHP="${REQ_WEB:-/var/www/html/cockpit}/worker_relay.php"
                    [ -f "$_RELAY_PHP" ] || _RELAY_PHP="${QUEUE_DIR%/queue}/worker_relay.php"   # web root = the queue dir's parent (Arch: /srv/http)
                    COCKPIT_DATA_OVERRIDE="$REQ_DATA" php "$_RELAY_PHP" "$RELAY_PROVIDER" "$RELAY_MODEL" "$PROMPT_TMP" >> "$OUT_FILE" 2>/dev/null
                fi
              else
                # Direct REST to the Gemini API. The gemini-cli is a full agent
                # (tool/MCP discovery, retries) that adds 50-110s of startup per
                # call; the REST endpoint returns in ~1s. The CRUD system prompt
                # is already baked into PROMPT_TMP, so plain text in/out behaves
                # exactly like before. Non-streaming: OUT_FILE fills on completion.
                # Flash-only by policy — card 2's whole pitch is a free-tier-safe
                # default, so Pro (paid-tier-only on most keys) is never selected
                # automatically even if a stale GEMINI_MODEL says "pro".
                run_gemini_rest
              fi
                ;;
            ollama)
                run_ollama_branch
                ;;
        esac

        finish_output

        # ── Execute CRUD commands ────────────────────────────────────────────
        CRUD_RESULTS=$(run_crud "$PROJECT_DIR" "$OUT_FILE" "$AGENT" "$PROJECT")   # the user's cockpit_data: catalog markers read its library_index.json
        if [ -n "$CRUD_RESULTS" ]; then
            echo "[${AGENT_UC}] CRUD operations executed"
            printf '\n\n---\n[File Operations]\n%s\n' "$CRUD_RESULTS" >> "$OUT_FILE"
        fi

        # ── Save to chat JSON ────────────────────────────────────────────────
        USER_TMP=$(mktemp /tmp/cockpit_user_XXXXXX.txt)
        printf '%s' "$USER_PROMPT" > "$USER_TMP"

        signin_hint

        DISPLAY_MODEL="$MODEL"
        [ "$AGENT" = "claude" ] && DISPLAY_MODEL="$CLAUDE_MODEL"
        [ "$AGENT" = "gemini" ] && DISPLAY_MODEL="$GEMINI_MODEL"

        append_to_chat "$CHAT_FILE" "$PROJECT" "$CHAT_NAME" \
            "$USER_TMP" "$OUT_FILE" "$DISPLAY_MODEL" "$DURATION" "$MA_STYLE" "$MA_MODE"

        rm -f "$USER_TMP"

        # ── Signal done ──────────────────────────────────────────────────────
        echo "$TOKEN" > "$DONE_FILE"
        echo "[${AGENT_UC}] Done: $TOKEN (${DURATION}s)"
    fi

    sleep 0.5
done
