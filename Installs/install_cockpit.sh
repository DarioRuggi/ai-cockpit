#!/usr/bin/env bash
# =============================================================================
# install_cockpit.sh — Install AI Cockpit (by Dario Ruggi)
#
# One universal installer for every POSIX target. Package manager AND OS are
# auto-detected: nala/apt-get (Debian, Ubuntu, Linux Mint), pacman (Arch),
# dnf (Fedora), zypper (openSUSE), apk (Alpine), brew (macOS, Apple Silicon
# only — Intel isn't supported yet, same as cockpit_auth's binary coverage).
# Only nala/apt-get (Linux) and brew (macOS) are CI-verified against real
# runners — pacman/dnf/zypper/apk are new, shipped untested per beta policy:
# better to offer them and find real bugs from real installs than gate them
# behind hardware we don't have. This replaces the old separate
# install_cockpit_macos.sh, which is retired — it had real bugs on Apple
# Silicon (confirmed on an M4 Mac) and diverged further from the Linux
# script's feature set (no edition choice, no local admin account, no SaaS
# login) every time one got updated without the other; one script now.
#
# What this script does (in order, same shape on every OS — services differ:
# systemd on Linux, launchd on macOS; apt/dnf/pacman/etc. on Linux, brew on
# macOS):
#   1.  Identify the user (detected, confirmable)
#   2.  Update the package index
#   3.  Install system packages: web server, PHP + extensions, tmux, jq,
#       util-linux, curl, git, build tools
#   4.  Install Node.js LTS (needed by Claude and Gemini CLIs)
#   5.  Install Claude Code CLI (npm)
#   6.  Install Gemini CLI (npm)
#   7.  Install Ollama (official install script on Linux, brew on macOS) and
#       configure OLLAMA_MODELS to ~/ollama/models
#   8.  Install LocalAI (checksum-verified binary download) and set it up as
#       a systemd service (Linux) / launchd agent (macOS) under ~/localai/ —
#       dual-mode combos/chat need this actually running, not just Ollama
#   9.  Pull Ollama models (interactive; suggests the list from your dev rig)
#   10. Extract cockpit tarball into $WEB_ROOT (web) and ~/scripts/
#   11. Set permissions, create project tree, install sudoers rules (Linux
#       only — macOS's httpd runs as the invoking user, no cross-user rule
#       needed)
#   12. Configure the web server for the cockpit
#   13. Run a verification pass and print the next-steps card
#
# Requirements:
#   - Fresh Linux Mint 22+ (Ubuntu 24.04 base), another supported distro, or
#     macOS on Apple Silicon (arm64)
#   - Internet connection
#   - User has sudo (macOS: only needed for a few steps, not the whole run)
#   - cockpit_*.tar.gz tarball available (built with build_cockpit_tarball.sh)
#
# Usage:
#   sudo ./install_cockpit.sh /path/to/cockpit_1.0.0_20260502.tar.gz
#   sudo ./install_cockpit.sh --unattended /path/to/cockpit_1.0.0_20260502.tar.gz
#
# Run as USER (not root) — script uses sudo internally where needed.
#
# --unattended (or COCKPIT_UNATTENDED=1): skips every interactive prompt,
# using: the detected user as-is, "yes" to every confirm(), and no Ollama
# models pulled by default (override with COCKPIT_UNATTENDED_MODELS, a
# space-separated list, e.g. "tinyllama:1.1b" for a real but small smoke
# test). Built for CI (GitHub Actions install-test workflows) — a real
# person should still just run it normally and answer the prompts.
# =============================================================================

set -euo pipefail

UNATTENDED=0
for arg in "$@"; do
    if [ "$arg" = "--unattended" ]; then UNATTENDED=1; fi
done
[ "${COCKPIT_UNATTENDED:-0}" = "1" ] && UNATTENDED=1
# CI mode: distro-matrix containers have no systemd/GPU and shouldn't touch the
# network or send telemetry — verify PACKAGES + SCRIPT LOGIC only. Implies
# unattended; skips service enable/start, readiness waits, SaaS, and telemetry.
CI_MODE=0
[ "${COCKPIT_CI:-0}" = "1" ] && { CI_MODE=1; UNATTENDED=1; }
# Filter --unattended out of $@ so the tarball-path positional arg below
# (still reads $1) isn't confused by it, regardless of argument order.
ARGS=()
COCKPIT_APP_VERSION="${COCKPIT_APP_VERSION:-}"   # v1 | v2 | "" (ask/derive)
for arg in "$@"; do
    case "$arg" in
        --unattended) ;;
        --v1|--version=v1) COCKPIT_APP_VERSION=v1 ;;
        --v2|--version=v2) COCKPIT_APP_VERSION=v2 ;;
        --both|--version=both) COCKPIT_APP_VERSION=both ;;
        *) ARGS+=("$arg") ;;
    esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# ── Configurable defaults at the top so user can override before running ────
DEFAULT_USER="${SUDO_USER:-$USER}"
SCRIPTS_DIR_NAME="scripts"
OLLAMA_MODELS_DIR_NAME="ollama/models"
LOCALAI_MODELS_DIR_NAME="localai/models"
LOCALAI_DATA_DIR_NAME="localai/data"
LOCALAI_BACKENDS_DIR_NAME="localai/backends"
LOCALAI_VERSION="4.7.1"
PROJECTS_ROOT_DEFAULT_NAME="AI-Cockpit/projects"   # was the author's own folder layout
# PHP is asked for unversioned (php, php-cli, …): apt resolves the distro default — 8.3 on Ubuntu 24.04, 8.4 on Debian 13. A pinned php8.3 does not exist on trixie.
NODE_MAJOR="20"

# ── Defaults for Ollama model suggestions (your dev rig's current set) ──────
# Parallel arrays, same index — DESC is shown next to each suggestion so
# picking one means something instead of just a name.
DEFAULT_OLLAMA_MODELS=(
    "qwen2.5-coder:1.5b"
    "llama3.2:3b"
    "deepseek-r1:1.5b"
    "qwen2.5:7b"
    "phi4-mini:3.8b"
)
DEFAULT_OLLAMA_MODELS_DESC=(
    "Good for: code — CRUD/combo steps, fast, fits 4GB VRAM"
    "Good for: general chat — fast, well-rounded, fits 4GB VRAM"
    "Good for: reasoning/multi-step logic — shows its work, small enough for 4GB VRAM"
    "Good for: general chat/writing, higher quality than the 3b above — needs ~6-8GB VRAM (Qwen3 8B)"
    "Good for: instruction-following, tool-use/agentic steps — fits 4GB VRAM"
)

# LocalAI equivalents of the same 5 — same job, same size class, run through
# LocalAI's llama.cpp backend instead of Ollama's. Gallery ids below match
# LocalAI's actual slug convention (lowercased HF model name) but haven't
# been re-verified against a live /models/available on every LocalAI
# version — if a pull 404s, browse http://127.0.0.1:8080/models/available
# and swap in the exact id shown there.
DEFAULT_LOCALAI_MODELS=(
    "qwen3-1.7b"
    "llama-3.2-3b-instruct:q4_k_m"
    "deepseek-r1-distill-qwen-1.5b"
    "qwen3-8b"
    "qwen3-4b"
)
DEFAULT_LOCALAI_MODELS_DESC=(
    "Good for: code — CRUD/combo steps, fast, fits 4GB VRAM"
    "Good for: general chat — fast, well-rounded, fits 4GB VRAM"
    "Good for: reasoning/multi-step logic — shows its work, small enough for 4GB VRAM"
    "Good for: general chat/writing, higher quality than the 3b above — needs ~6-8GB VRAM (Qwen3 8B)"
    "Good for: instruction-following, tool-use/agentic steps — fits 4GB VRAM"
)

# ── Colors for output (Protanopia-safe: blue/yellow/grey, no red/green) ─────
C_BLUE="\033[1;34m"
C_YELLOW="\033[1;33m"
C_GREY="\033[0;37m"
C_DIM="\033[2m"
C_OFF="\033[0m"

step()   {
    # the phase we are leaving finished (an aborted run never reaches this line for it)
    if [ -n "${CURRENT_PHASE:-}" ]; then state_put "done_$(phase_key "$CURRENT_PHASE")" 1; fi
    state_put last "$1"
    CURRENT_PHASE="$1"; echo -e "${C_BLUE}▶${C_OFF} ${C_BLUE}$1${C_OFF}"
    # A new phase ends any sub-step context. Without this, SUBSTEP_PARENT keeps
    # the FIRST phase that ever used a sub-step, and every later sub-step reports
    # itself under the wrong parent.
    SUBSTEP_PARENT="$1"; SUBSTEP_T0=""
    if [ "$TELE_ON" = "1" ]; then tele phase
    else TELE_BUFFER="${TELE_BUFFER}${1}
"; fi
}
note()   { echo -e "  ${C_GREY}$1${C_OFF}"; }
warn()   { echo -e "${C_YELLOW}!${C_OFF} ${C_YELLOW}$1${C_OFF}"; }
ok()     { echo -e "  ${C_BLUE}✓${C_OFF} $1"; }

# Lowercase a string. ${var,,} is bash 4 ONLY, and macOS still ships bash 3.2 as
# /bin/bash (Apple froze it at the last GPLv2 release), so every $(lc "$_X_DO") here
# died with "bad substitution" and took the whole install down at Phase 5b —
# long before Phase 10 could configure httpd. Found by the Apple Silicon CI run,
# 2026-09-23. tr is POSIX and behaves the same on both userlands.
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
fatal()  { echo -e "${C_YELLOW}✗ FATAL:${C_OFF} $1" >&2; tele_fail 1 "$1"; exit 1; }

# ── Install telemetry (opt-in / V2-gated, anonymous) ─────────────────────────
# Best-effort POSTs of install PROGRESS and FAILURES to a server page so we can
# see how many installs succeed and where the failing ones stop. NEVER sends
# personal data: no username, no file paths (stripped), no IP (the server drops
# it). Gated on: V2 selected → on (opt out with COCKPIT_NO_TELEMETRY=1); v1-only
# → explicit permission; Stand-alone edition → always off.
TELE_ENDPOINT="${COCKPIT_TELE_ENDPOINT:-https://ruggi.site/install_telemetry.php}"
# What this installer shipped as. Stamped into the bundle beside this script;
# falls back to whatever the dist tarball carries, else "unknown" — a wrong
# version string would produce a wrong "update available", which is worse than
# saying nothing.
INSTALLER_VERSION="unknown"
if [ -r "$(dirname "$0")/VERSION" ]; then
    INSTALLER_VERSION="$(tr -d ' \t\r\n' < "$(dirname "$0")/VERSION")"
fi
# Container/runtime context, reported as coarse environment, never as identity.
detect_container() {
    if [ -f /.dockerenv ]; then echo docker
    elif grep -qa 'docker\|containerd' /proc/1/cgroup 2>/dev/null; then echo docker
    elif [ -n "${container:-}" ]; then echo "${container}"
    elif grep -qia microsoft /proc/version 2>/dev/null; then echo wsl
    else echo none; fi
}
CONTAINER_KIND="$(detect_container 2>/dev/null || echo none)"
# Which download route this bundle came from — a BUCKET, never an identifier.
# Stamped once at build time into a handful of shared values ("site", "docs",
# "maestro"...), so thousands of people carry the same tag and no one can be
# singled out. Blank when absent, which is the normal case for a hand-built or
# self-compiled bundle.
DL_SOURCE="unknown"
if [ -r "$(dirname "$0")/SOURCE" ]; then
    DL_SOURCE="$(tr -cd 'a-z0-9._-' < "$(dirname "$0")/SOURCE" | cut -c1-20)"
    [ -n "$DL_SOURCE" ] || DL_SOURCE="unknown"
fi
# Where the V1 "may we report success?" answer is remembered. Written once;
# "declined" means nothing asks again, ever — including the app at first run.
SUCCESS_MARKER_REL=".cockpit_install_report"
TELE_ON=0
# Phases reached BEFORE the consent decision. They are held in memory only and
# flushed after consent — so a user who aborts early, or declines, sends nothing,
# while a consenting user's early steps are no longer silently discarded.
TELE_BUFFER=""
TELE_META=""
CURRENT_PHASE="start"
TELE_ID="$( (od -An -N8 -tx1 /dev/urandom 2>/dev/null || date +%s%N) | tr -d ' \n' )"
strip_personal() {   # scrub home/user before anything leaves the machine
    sed -e "s#${USER_HOME:-__nohome__}#<home>#g" \
        -e "s#${COCKPIT_USER:-__nouser__}#<user>#g" \
        -e 's#/home/[^/ "]*#/home/<user>#g' -e 's#/Users/[^/ "]*#/Users/<user>#g'
}
tele_build_meta() {  # refresh the shared metadata fragment (values sans quotes)
    local cpu gpu
    cpu="$(printf '%s' "${HW_CPU_MODEL:-}" | tr -d '"\\')"
    gpu="$(printf '%s' "${HW_GPU_NAME:-}"  | tr -d '"\\')"
    TELE_META=$(printf '"os":"%s","distro":"%s","distro_ver":"%s","arch":"%s","pkg_mgr":"%s","version":"%s","edition":"%s","cpu_model":"%s","cpu_cores":%s,"ram_mb":%s,"gpu":"%s","vram_mb":%s' \
        "${TELE_OS:-}" "${TELE_DISTRO:-}" "${TELE_DISTRO_VER:-}" "$(uname -m 2>/dev/null)" \
        "${PKG_MGR:-}" "${COCKPIT_APP_VERSION:-}" "${EDITION:-}" \
        "$cpu" "${HW_CPU_CORES:-0}" "${HW_RAM_MB:-0}" "$gpu" "${HW_VRAM_MB:-0}")
}
tele() {   # tele <event> — best-effort, backgrounded, never blocks or fails
    [ "$TELE_ON" = "1" ] || return 0
    local body
    body=$(printf '{"id":"%s","event":"%s","phase":"%s",%s}' \
        "$TELE_ID" "$1" "$CURRENT_PHASE" "$TELE_META")
    (curl -fsS -m 4 -X POST -H 'Content-Type: application/json' \
        -d "$body" "$TELE_ENDPOINT" >/dev/null 2>&1 || true) &
}
tele_flush() {   # replay the phases reached before consent was established
    [ "$TELE_ON" = "1" ] || { TELE_BUFFER=""; return 0; }
    local _saved="$CURRENT_PHASE" _line
    while IFS= read -r _line; do
        [ -n "$_line" ] || continue
        CURRENT_PHASE="$_line"; tele phase
    done <<EOF
$TELE_BUFFER
EOF
    CURRENT_PHASE="$_saved"; TELE_BUFFER=""
}
# ── Boot beacon + version check ──────────────────────────────────────────────
# ONE installer serves every edition, so at this point we genuinely cannot know
# which one the user will pick — there is nothing yet to respect. This call is
# therefore notice-and-opt-out, announced on screen before it happens, and it
# earns its place by doing something FOR the user: asking whether a newer
# release exists. The No-Phone-Home promise begins at SELECTION: choose V1 and
# nothing further leaves the machine unless you later say yes.
#
# Honours COCKPIT_NO_TELEMETRY=1 and CI mode, both of which are known before
# any prompt, so opting out in advance still works exactly as documented.
tele_boot() {
    [ "$CI_MODE" = "1" ] && return 0
    [ -n "${COCKPIT_NO_TELEMETRY:-}" ] && { note "Version check + install ping: off (COCKPIT_NO_TELEMETRY set)"; return 0; }
    note "Checking for a newer release. This sends one anonymous line — OS, distro,"
    note "architecture, package manager, coarse hardware and this installer's version."
    note "No username, no paths, no files, no IP. Opt out with COCKPIT_NO_TELEMETRY=1."
    local body resp
    body=$(printf '{"id":"%s","event":"boot","phase":"boot","installer_ver":"%s","container":"%s","dl_source":"%s",%s}' \
        "$TELE_ID" "$INSTALLER_VERSION" "$CONTAINER_KIND" "$DL_SOURCE" "$TELE_META")
    resp=$(curl -fsS -m 6 -X POST -H 'Content-Type: application/json' -d "$body" "$TELE_ENDPOINT" 2>/dev/null || true)
    case "$resp" in
        *'"newer":true'*)
            local latest
            latest=$(printf '%s' "$resp" | sed -n 's/.*"latest":"\([^"]*\)".*/\1/p')
            echo
            warn "A newer AI Cockpit exists: ${latest:-newer} (you have ${INSTALLER_VERSION})."
            note "Get it at https://cockpit.ruggi.site/download.php — or carry on with this one."
            echo
            ;;
        *'"latest"'*) note "You have the current version (${INSTALLER_VERSION})." ;;
        *) : ;;   # no answer / offline — never block the install over a version check
    esac
}

# Fired for EVERY selection, v1 included. That is the point: if this event is
# missing we know the user abandoned before choosing, instead of having to guess
# whether they picked V1 or simply walked away. For V1 it carries the choice and
# nothing else, and no further event is sent.
tele_selection() {
    [ "$CI_MODE" = "1" ] && return 0
    [ -n "${COCKPIT_NO_TELEMETRY:-}" ] && return 0
    local body
    body=$(printf '{"id":"%s","event":"selection","phase":"selection","selection":"%s","installer_ver":"%s","container":"%s","dl_source":"%s",%s}' \
        "$TELE_ID" "${COCKPIT_APP_VERSION:-unknown}" "$INSTALLER_VERSION" "$CONTAINER_KIND" "$DL_SOURCE" "$TELE_META")
    (curl -fsS -m 4 -X POST -H 'Content-Type: application/json' -d "$body" "$TELE_ENDPOINT" >/dev/null 2>&1 || true) &
}
# ── Sub-step markers ────────────────────────────────────────────────────────
# A phase like "Phase 4 — Agent CLIs" covers three CLI installs AND model pulls
# that can each run for minutes. When one fails, "Phase 4" does not say which,
# and a model download that dies at 90% looks exactly like a CLI that never
# installed. substep() narrows CURRENT_PHASE to the actual operation, so the
# failure report and the last-seen marker both name the thing that broke.
#
# It also times the operation: a step that starts and never reports again is a
# hang, which is a different bug from a step that fails — and until now they
# were indistinguishable.
SUBSTEP_T0=""
substep() {   # substep "<what is happening>"
    SUBSTEP_PARENT="${SUBSTEP_PARENT:-$CURRENT_PHASE}"
    CURRENT_PHASE="${SUBSTEP_PARENT} :: $1"
    SUBSTEP_T0=$(date +%s)
    if [ "$TELE_ON" = "1" ]; then tele phase
    else TELE_BUFFER="${TELE_BUFFER}${CURRENT_PHASE}
"; fi
}
substep_done() {   # close the current sub-step; reports how long it took
    [ -n "$SUBSTEP_T0" ] || return 0
    _sd=$(( $(date +%s) - SUBSTEP_T0 ))
    [ "$TELE_ON" = "1" ] && [ "$_sd" -ge 20 ] && {
        CURRENT_PHASE="${CURRENT_PHASE} (${_sd}s)"; tele phase; }
    CURRENT_PHASE="${SUBSTEP_PARENT:-$CURRENT_PHASE}"
    SUBSTEP_T0=""
}
tele_fail() {   # tele_fail <code> <raw error text>
    [ "$TELE_ON" = "1" ] || return 0
    local code="$1" msg
    msg=$(printf '%s' "$2" | strip_personal | tr -d '"\\' | tr '\n' ' ' | cut -c1-480)
    local body
    body=$(printf '{"id":"%s","event":"fail","phase":"%s",%s,"err_code":%s,"err_msg":"%s"}' \
        "$TELE_ID" "$CURRENT_PHASE" "$TELE_META" "$code" "$msg")
    curl -fsS -m 4 -X POST -H 'Content-Type: application/json' -d "$body" "$TELE_ENDPOINT" >/dev/null 2>&1 || true
}
# Report the failing command + phase on any error (set -e will then exit).
trap '__rc=$?; tele_fail "$__rc" "$BASH_COMMAND"' ERR
# Any other death (set -e, a refused sudo, Ctrl-C) says where it stopped — the
# log and the progress window otherwise just end mid-phase (seen on the GUI test).
trap '__rc=$?; if [ "$__rc" -ne 0 ] && [ "${CURRENT_PHASE:-}" != "complete" ]; then echo -e "${C_YELLOW}✗ Install stopped in ${CURRENT_PHASE:-startup} (exit $__rc)${C_OFF} — details above; log: ${INSTALL_LOG:-none}"; fi' EXIT

# sha256sum is GNU coreutils — macOS ships shasum -a 256 instead, same output format.
# macOS ships no GNU sha256sum, but some non-coreutils tool named sha256sum
# can still show up on PATH there (confirmed on a real GitHub macOS runner —
# it rejected -c with a BSD-style usage string, not GNU's) — always prefer
# the OS-native shasum on macOS instead of trusting whatever sha256sum
# happens to resolve to.
sha256() { if [ "$IS_MACOS" != "1" ] && command -v sha256sum &>/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# ── Package manager + web-server-user/docroot detection ─────────────────────
# Detected here (before Phase 1's layout summary needs WEB_ROOT to print) so
# every distro-specific path — DocumentRoot, the user Apache/httpd runs as,
# the service name — is known up front instead of assumed to be Debian's.
# Only nala/apt-get (Debian/Ubuntu/Mint) is CI-tested; the rest are new,
# shipped untested per beta policy — see Phase 2 below for the matching
# package-list/install logic.
IS_MACOS=0
[ "$(uname -s)" = "Darwin" ] && IS_MACOS=1

PKG_MGR=""
if [ "$IS_MACOS" = "1" ]; then
    PKG_MGR="brew"
elif command -v nala &>/dev/null; then PKG_MGR="nala"
elif command -v apt-get &>/dev/null; then PKG_MGR="apt-get"
elif command -v pacman &>/dev/null; then PKG_MGR="pacman"
elif command -v dnf &>/dev/null; then PKG_MGR="dnf"
elif command -v zypper &>/dev/null; then PKG_MGR="zypper"
elif command -v apk &>/dev/null; then PKG_MGR="apk"
fi
[ -z "$PKG_MGR" ] && fatal "No supported package manager found (looked for nala, apt-get, pacman, dnf, zypper, apk)."

# ── Boot: version check + anonymous environment line ─────────────────────────
# Fired HERE, before the first question, because one installer serves every
# edition — there is no choice yet to respect. Everything after selection obeys
# the choice: pick V1 and nothing more is sent.
if [ "$IS_MACOS" = "1" ]; then
    TELE_OS="macos"; TELE_DISTRO="macos"
    TELE_DISTRO_VER="$(sw_vers -productVersion 2>/dev/null || echo '')"
else
    TELE_OS="linux"
    TELE_DISTRO="$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}")"
    TELE_DISTRO_VER="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
fi
tele_build_meta
tele_boot

# HTTP_PORT/URL_PREFIX: macOS's Homebrew httpd defaults to the same port
# LocalAI binds (127.0.0.1:8080) — confirmed the hard way in the old
# macOS-only script's own history that both grabbing 8080 is a silent
# collision (whichever starts first wins the port). httpd moves to 8090 on
# macOS only; Linux/BSD-family Apache/httpd has no such collision (LocalAI
# is 8080, Apache is 80), so it keeps the plain default.
HTTP_PORT="80"
URL_PREFIX=""

case "$PKG_MGR" in
    nala|apt-get)
        APACHE_SVC="apache2"; APACHE_USER="www-data"; DOCROOT="/var/www/html"
        ;;
    pacman)
        APACHE_SVC="httpd"; APACHE_USER="http"; DOCROOT="/srv/http"
        ;;
    dnf)
        APACHE_SVC="httpd"; APACHE_USER="apache"; DOCROOT="/var/www/html"
        ;;
    zypper)
        APACHE_SVC="apache2"; APACHE_USER="wwwrun"; DOCROOT="/srv/www/htdocs"
        ;;
    apk)
        APACHE_SVC="apache2"; APACHE_USER="apache"; DOCROOT="/var/www/localhost/htdocs"
        ;;
    brew)
        # No dedicated "www-data"-style service account on macOS — Homebrew's
        # httpd runs as the invoking user, so there's no cross-user
        # ownership split to manage (see Phase 8/9 below, both no-op here).
        APACHE_SVC="httpd"; APACHE_USER="$(whoami)"
        if [ "$(uname -m)" = "arm64" ]; then
            DOCROOT="/opt/homebrew/var/www"
        else
            DOCROOT="/usr/local/var/www"
        fi
        HTTP_PORT="8090"
        URL_PREFIX="/cockpit"
        ;;
esac
WEB_ROOT="${DOCROOT}/cockpit"

# How long to wait for a human at any prompt before falling back to its default.
PROMPT_TIMEOUT="${COCKPIT_PROMPT_TIMEOUT:-600}"   # 10 minutes

# ── Install state: resume, remembered answers, finished phases ───────────────
# Three interrupted runs on one VM each started from the first question. The
# state file (per invoking user, no secrets: passwords/tokens are never saved)
# records every answer and every finished phase. On the next run the user picks
# "continue" (answers reused, finished component phases offered as "use it or
# redo") or "start anew". A completed install is offered the same choice as an
# upgrade. Delete the file, or answer "anew", to forget everything.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ai-cockpit"
STATE_FILE="$STATE_DIR/install.state"
RESUME=0; STATE_COMPLETE=""; STATE_STARTED=""; STATE_LAST=""; QUIET_PREFILL=0
# (no associative arrays: macOS ships bash 3.2 — the file itself is the map, last line wins)
state_get()   { [ -f "$STATE_FILE" ] || return 1; grep -- "^$1=" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-; }
state_has()   { [ -f "$STATE_FILE" ] && grep -q -- "^$1=" "$STATE_FILE" 2>/dev/null; }
state_load()  { [ -f "$STATE_FILE" ] || return 1; STATE_COMPLETE="$(state_get complete || true)"; STATE_STARTED="$(state_get started || true)"; STATE_LAST="$(state_get last || true)"; return 0; }
state_put()   { mkdir -p "$STATE_DIR" 2>/dev/null || return 0; printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE" 2>/dev/null || true; }
state_reset() { rm -f "$STATE_FILE" 2>/dev/null; state_put started "$(date '+%Y-%m-%d %H:%M')"; }
pre_set() { local __k; __k="$(ans_key "$1")"; printf -v "PRE_$__k" '%s' "$2"; case "$1" in *[Pp]assword*|*[Tt]oken*|*[Ss]ecret*|*[Kk]ey*|Proceed*|"Pick 1 or 2"|redo:*) ;; *) state_put "ans_$__k" "$2" ;; esac; }
pre_get() { local __k __pv; __k="$(ans_key "$1")"; __pv="PRE_$__k"; printf '%s' "${!__pv:-}"; }
# ${1,,} is bash 4 and macOS ships bash 3.2 — same class as the lc() helper above,
# missed because the build guard's regex only matched NAMED variables, not
# positional ones. Found by the Apple Silicon CI, 2026-09-25.
yn() { case "$(lc "$1")" in y|yes) echo yes ;; *) echo no ;; esac; }
# "Phase 5b — LocalAI" → "5b"; "Edition" → "Edition"
phase_key()   { local p="${1#Phase }"; printf '%s' "${p%% *}"; }
ans_key()     { printf '%s' "$1" | cksum | cut -d' ' -f1; }
# phase_wanted [test-command]: run this phase's body? Skipped (returns 1) when
# the user says "use it" for a phase finished in an earlier run, or for a
# component the test finds already present. Detection-only phases (packages,
# files, permissions, sudoers, web server, verification) are never gated.
# ── desktop essentials the machine may lack (a bare Arch/MATE VM had no browser) ──
# Names by desktop family; the browser is Firefox everywhere (MozillaFirefox on zypper).
desk_family() { case "${XDG_CURRENT_DESKTOP:-}${DESKTOP_SESSION:-}" in *KDE*|*[Pp]lasma*) echo kde ;; *XFCE*|*xfce*) echo xfce ;; *MATE*|*mate*) echo mate ;; *Cinnamon*|*cinnamon*) echo cinnamon ;; *LXQt*) echo lxqt ;; *) echo gnome ;; esac; }
desk_files_pkg() { case "$(desk_family)" in kde) echo dolphin ;; xfce) echo thunar ;; mate) echo caja ;; cinnamon) echo nemo ;; lxqt) echo pcmanfm-qt ;; *) echo nautilus ;; esac; }
desk_term_pkg()  { case "$(desk_family)" in kde) echo konsole ;; xfce) echo xfce4-terminal ;; mate) echo mate-terminal ;; lxqt) echo qterminal ;; *) echo gnome-terminal ;; esac; }
desk_browser_pkg() { [ "${PKG_MGR:-}" = "zypper" ] && echo MozillaFirefox || echo firefox; }
have_any() { local b; for b in "$@"; do command -v "$b" >/dev/null 2>&1 && return 0; done; return 1; }
# WSL2 (used for the sudo prompt wording): the interop binfmt entry, or the kernel name.
IS_WSL=0; { ls /proc/sys/fs/binfmt_misc/WSLInterop* >/dev/null 2>&1 || grep -qi microsoft /proc/version 2>/dev/null; } && IS_WSL=1
MISS_BROWSER=0; MISS_FILES=0; MISS_TERM=0
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    have_any firefox brave-browser brave chromium chromium-browser google-chrome google-chrome-stable vivaldi-stable microsoft-edge epiphany || MISS_BROWSER=1
    have_any nautilus dolphin thunar caja nemo pcmanfm pcmanfm-qt || MISS_FILES=1
    have_any gnome-terminal ptyxis kgx konsole xfce4-terminal mate-terminal tilix kitty alacritty xterm qterminal || MISS_TERM=1
fi
INST_BROWSER=n; INST_FILES=n; INST_TERM=n; CKBROWSER=y   # the Cockpit Browser is the default browser everywhere (decision 2026-10-12)
# Inside a VM (KVM/QEMU/VMware/…): install the guest agent so the host can drive this
# machine (run the installer, open/close Cockpit) — the rig's Installs/ci/vmrun.sh does that.
IN_VM=0; case "$(systemd-detect-virt --vm 2>/dev/null)" in kvm|qemu|bochs) IN_VM=1 ;; esac   # qemu-guest-agent is KVM/QEMU only: VMware, Hyper-V (also WSL2 = "microsoft"/"wsl"), VirtualBox have their own tools
SSH_ALLOW=""
[ "$MISS_BROWSER" = 1 ] && CKBROWSER=y   # no browser at all: the Cockpit window becomes the system browser
# WSL2: Ubuntu's firefox package is a snap stub and snapd does not run under WSL, so no Firefox
# offer there; the Cockpit Browser (the native window in --browser mode, proven under WSLg) is the browser.
[ "$IS_WSL" = 1 ] && MISS_BROWSER=0 && CKBROWSER=y

# ── components the gated phases would find (shared by the GUI page and phase_wanted) ──
comp_title() { case "$1" in 3) echo "Node.js" ;; 4) echo "Claude Code / Gemini / Ollama CLIs" ;; 5) echo "LocalAI" ;; 5b) echo "LibreTranslate" ;; 5c) echo "stable-diffusion.cpp" ;; 5d) echo "Piper TTS" ;; 5e) echo "whisper.cpp" ;; 5f) echo "Aider" ;; 5g) echo "Goose / opencode" ;; 6) echo "Ollama models" ;; 13) echo "Companion tools (ftpush, secrets)" ;; *) echo "Phase $1" ;; esac; }
comp_present() {
    local h="${USER_HOME:-$HOME}"
    case "$1" in
        3)  command -v node >/dev/null 2>&1 ;;
        4)  [ -x "$h/.npm-global/bin/claude" ] && command -v ollama >/dev/null 2>&1 ;;
        5)  [ -x "$h/.local/bin/local-ai" ] ;;
        5b) [ -d "$h/libretranslate" ] ;;
        5c) [ -d "$h/ai-tools/sd.cpp" ] || [ -d "$h/ai-tools/stable-diffusion.cpp" ] ;;
        5d) [ -d "$h/ai-tools/piper" ] ;;
        5e) [ -x "$h/ai-tools/whisper.cpp/build/bin/whisper-cli" ] ;;
        5f) [ -x "$h/.local/bin/aider" ] ;;
        5g) [ -x "$h/.local/bin/goose" ] || [ -x "$h/.local/bin/opencode" ] ;;
        6)  ollama list 2>/dev/null | tail -n +2 | grep -q . ;;
        13) [ -x "$h/.local/bin/ftpush" ] && [ -x "$h/.local/bin/secrets" ] ;;
        *)  return 1 ;;
    esac
}
GATED_PHASES="3 4 5 5b 5c 5d 5e 5f 5g 6 13"
phase_wanted() {
    local key; key="$(phase_key "$CURRENT_PHASE")"
    local why=""
    # decided up front (the GUI's "already on this machine" page)?
    local pre; pre="$(pre_get "redo:$key")"
    if [ -n "$pre" ]; then
        if [ "$pre" = "y" ]; then return 0; fi
        ok "kept — skipping ${CURRENT_PHASE}"; return 1
    fi
    if [ "$RESUME" = "1" ] && state_has "done_$key"; then why="finished in the earlier run"
    elif [ -n "${1:-}" ] && eval "$1" >/dev/null 2>&1; then why="already present on this machine"
    fi
    [ -n "$why" ] || return 0
    if confirm "  $CURRENT_PHASE — $why. Use it as is? (n = redo this phase)" y; then
        ok "kept — skipping ${CURRENT_PHASE}"; return 1
    fi
    return 0
}

# ask VAR "question" "default" [timeout]
# Prompts with the default spelled out, shows an animated "waiting" status bar
# on its own line (so it never corrupts what you type), waits up to $timeout
# seconds, then falls back to the default. Sets VAR to the answer (or default).
ask() {
    local __var="$1" __q="$2" __def="$3" __to="${4:-$PROMPT_TIMEOUT}"
    if [ "$UNATTENDED" = "1" ]; then
        note "$__q -> ${__def:-<none>} (unattended)"
        printf -v "$__var" '%s' "$__def"
        return 0
    fi
    # One clean line, no animation (an animated bar corrupts/scrolls the input
    # line on real terminals). The wait window is stated inline; on timeout the
    # default is used. No background process → nothing for set -e to trip on.
    # Asked already this run (the questionnaire up front asks everything once;
    # the phases then find their answer here and never prompt again).
    local __k __pv; __k="$(ans_key "$__q")"; __pv="PRE_$__k"
    if [ "${!__pv+set}" = set ]; then
        printf -v "$__var" '%s' "${!__pv}"
        [ "$QUIET_PREFILL" = "1" ] || note "$__q -> ${!__var:-<none>}"
        return 0
    fi
    # Remembered from an interrupted run (never passwords/tokens/keys).
    if [ "$RESUME" = "1" ] && state_has "ans_$__k"; then
        printf -v "$__var" '%s' "$(state_get "ans_$__k")"
        note "$__q -> ${!__var:-<none>} (remembered from the earlier run)"
        return 0
    fi
    local __ans="" __pm=$(( __to / 60 )) __prompt
    # A long default (e.g. a path) would wrap the line, so show it above and keep
    # the input prompt short. The prompt goes to readline via -p so it OWNS the
    # line: -e gives backspace/arrows/ctrl-u and the hint stays put while editing.
    if [ "${#__def}" -gt 28 ]; then
        printf '  %bdefault (Enter) = %s%b\n' "$C_GREY" "${__def:-skip}" "$C_OFF"
        __prompt="$__q (${__pm}m): "
    else
        __prompt="$__q  (Enter=${__def:-skip}, ${__pm}m): "
    fi
    printf '%b?%b ' "$C_BLUE" "$C_OFF"
    IFS= read -e -r -t "$__to" -p "$__prompt" __ans || true
    if [ -z "$__ans" ]; then
        __ans="$__def"
        printf '%b(no input — using default: %s)%b\n' "$C_GREY" "${__def:-skip}" "$C_OFF"
    fi
    printf -v "$__var" '%s' "$__ans"
    printf -v "$__pv" '%s' "$__ans"
    case "$__q" in *[Pp]assword*|*[Tt]oken*|*[Ss]ecret*|*[Kk]ey*|Proceed*|"Pick 1 or 2") ;; *) state_put "ans_$__k" "$__ans" ;; esac
}

confirm() {
    # confirm "Question" [default y|n]   — returns 0 on yes, 1 on no
    local prompt="$1"
    local default="${2:-y}"
    local hint reply
    [ "$default" = "y" ] && hint="[Y/n]" || hint="[y/N]"
    if [ "$UNATTENDED" = "1" ]; then
        note "$prompt $hint -> $default (unattended)"
        [ "$default" = "y" ]
        return
    fi
    ask reply "$prompt $hint" "$default"
    reply="$(lc "$reply")"
    [ "$reply" = "y" ] || [ "$reply" = "yes" ]
}

detect_hardware() {
    HW_CPU_CORES=1; HW_CPU_MODEL=""; HW_RAM_MB=0; HW_GPU_NAME=""; HW_VRAM_MB=0
    if [ "$IS_MACOS" = "1" ]; then
        HW_CPU_CORES="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 1)"
        HW_CPU_MODEL="$(/usr/sbin/sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
        HW_RAM_MB=$(( $(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0) / 1048576 ))
        local sp; sp="$(system_profiler SPDisplaysDataType 2>/dev/null || true)"
        HW_GPU_NAME="$(printf '%s\n' "$sp" | awk -F': ' '/Chipset Model:/{print $2; exit}')"
        [ -z "$HW_GPU_NAME" ] && HW_GPU_NAME="$(uname -m)"   # Apple Silicon: unified memory
    else
        HW_CPU_CORES="$(nproc 2>/dev/null || echo 1)"
        # CPU model — key for local-LLM speed (core count alone doesn't tell you
        # the generation / AVX2-AVX512 support llama.cpp leans on).
        HW_CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/^Model name/{gsub(/^[ \t]+/,"",$2);print $2;exit}')"
        [ -z "$HW_CPU_MODEL" ] && [ -r /proc/cpuinfo ] && HW_CPU_MODEL="$(awk -F: '/model name/{gsub(/^ +/,"",$2);print $2;exit}' /proc/cpuinfo)"
        [ -r /proc/meminfo ] && HW_RAM_MB=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 ))
        if command -v nvidia-smi >/dev/null 2>&1; then
            local l; l="$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)"
            HW_GPU_NAME="$(printf '%s' "$l" | cut -d, -f1 | sed 's/^ *//;s/ *$//')"
            HW_VRAM_MB="$(printf '%s' "$l" | cut -d, -f2 | tr -dc '0-9')"
        else
            command -v lspci >/dev/null 2>&1 && HW_GPU_NAME="$(lspci 2>/dev/null | grep -iE 'VGA|3D controller|Display' | head -1 | sed 's/.*: //' || true)" || true
            local f
            for f in /sys/class/drm/card*/device/mem_info_vram_total; do
                [ -r "$f" ] && { HW_VRAM_MB=$(( $(cat "$f") / 1048576 )); break; }
            done
        fi
    fi
    [ -z "$HW_VRAM_MB" ] && HW_VRAM_MB=0
    # memory budget for sizing local models
    if [ "${HW_VRAM_MB:-0}" -ge 1024 ]; then HW_BUDGET_MB=$HW_VRAM_MB
    else HW_BUDGET_MB=$HW_RAM_MB; fi           # no discrete VRAM → CPU/unified inference
    if   [ "$HW_BUDGET_MB" -ge 12000 ]; then HW_TIER="high"
    elif [ "$HW_BUDGET_MB" -ge 6000 ];  then HW_TIER="mid"
    else                                     HW_TIER="low"; fi
    # no discrete VRAM at all (VM, iGPU-only box): CPU inference — model pulls default to none
    if [ "${HW_VRAM_MB:-0}" -lt 1024 ]; then HW_NOGPU=1; else HW_NOGPU=0; fi
}
# =============================================================================
# Pre-flight
# =============================================================================
echo
echo -e "${C_BLUE}       . | .${C_OFF}"
echo -e "${C_BLUE}        \\|/${C_OFF}"
echo -e "${C_BLUE}    .--- O ---.${C_OFF}     ${C_BLUE}═══════════════════════════════════════════${C_OFF}"
echo -e "${C_BLUE}   /    /|\\    \\      AI Cockpit — Installer${C_OFF}"
echo -e "${C_BLUE}  '    / | \\    '${C_OFF}    ${C_BLUE}  by Dario Ruggi${C_OFF}"
echo -e "${C_BLUE}       . | .${C_OFF}        ${C_BLUE}═══════════════════════════════════════════${C_OFF}"
echo

# Best-effort: widen a narrow terminal so long default paths don't wrap.
# (xterm-style escape; ignored by terminals/multiplexers that don't support it.)
_cols="$(tput cols 2>/dev/null || echo 80)"
if [ "${_cols:-80}" -lt 100 ]; then
    printf '\e[8;40;100t'
    sleep 0.2
    _cols="$(tput cols 2>/dev/null || echo "$_cols")"
    [ "${_cols:-80}" -lt 90 ] && note "Tip: widen this window (≥100 cols) for the cleanest layout."
fi

if [ "$EUID" -eq 0 ]; then
    fatal "Do not run this script as root. Run as your normal user — it will sudo as needed."
fi
if ! sudo -n true 2>/dev/null; then
    note "Will prompt for your sudo password."
fi

if [ "$IS_MACOS" = "1" ] && [ "$(uname -m)" != "arm64" ]; then
    fatal "This build only ships an Apple Silicon (arm64) cockpit_auth binary. Intel Macs aren't supported yet."
fi

# ── App version + tarball resolution ────────────────────────────────────────
# V1, V2, or BOTH are installable. An explicit tarball path (positional arg)
# always wins and installs just that. Otherwise resolve from the chosen version
# (--v1/--v2/--both, or a prompt defaulting to v2) against tarballs bundled next
# to this installer in dist/ (cockpit_v1.tar.gz / cockpit_v2.tar.gz).
#
# "both": V2 is the PRIMARY install (full flow, its own account) at $WEB_ROOT;
# V1 is a SECONDARY install at ${WEB_ROOT}-v1 (served at /cockpit-v1), sharing
# the same Ollama/LocalAI and packages.
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# Everything below also lands in a log — the first VM tester could only paste
# scrollback. Prompts still read from the terminal.
INSTALL_LOG="${COCKPIT_INSTALL_LOG:-$HOME/cockpit-install.log}"
if [ "$UNATTENDED" != "1" ] && exec > >(tee -a "$INSTALL_LOG") 2>&1; then note "Log: $INSTALL_LOG"; fi
DIST_DIR="${COCKPIT_DIST_DIR:-$SELF_DIR/dist}"
INSTALL_BOTH=0
SECONDARY_TARBALL=""
SECONDARY_VERSION=""
resolve_tarball() {   # $1 = v1|v2 → echoes path or empty
    local v="$1"
    local p="$DIST_DIR/cockpit_${v}.tar.gz"
    [ -f "$p" ] || p="$(ls -1 "$DIST_DIR"/cockpit_${v}*.tar.gz 2>/dev/null | head -1 || true)"
    printf '%s' "$p"
}

# ── GUI front end: ckdialog (shipped beside this script) ─────────────────────
# A wizard window asks everything the terminal questionnaire asks, then the
# install runs while a progress window follows the log. The terminal path stays
# for SSH, servers and CI (no display, COCKPIT_TUI=1, or the binary missing).
CKD="$SELF_DIR/ckdialog"; GUI=0
if [ "$UNATTENDED" != "1" ] && [ "${COCKPIT_TUI:-0}" != "1" ] && [ -x "$CKD" ] && "$CKD" --check 2>/dev/null; then GUI=1; fi
je() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }   # JSON string escape
gui_answer_for() {   # $1 = question text → remembered answer (resume) or ""
    local k; k="$(ans_key "$1")"
    if [ "$RESUME" = "1" ] && state_has "ans_$k"; then state_get "ans_$k"; fi
}
gui_wizard() {
    local spec="$STATE_DIR/wizard.json" pre="$STATE_DIR/wizard.pre" out="$STATE_DIR/wizard.out"
    local md o l home_guess
    mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR" 2>/dev/null || true
    detect_hardware
    md="$([ "$HW_NOGPU" = "1" ] && echo none || echo all)"
    home_guess="$(getent passwd "$DEFAULT_USER" 2>/dev/null | cut -d: -f6)"; [ -n "$home_guess" ] || home_guess="$HOME"
    o=""; for i in "${!DEFAULT_OLLAMA_MODELS[@]}"; do o="$o$([ -n "$o" ] && echo ,)[\"$(je "${DEFAULT_OLLAMA_MODELS[$i]}")\",\"$(je "${DEFAULT_OLLAMA_MODELS[$i]} — ${DEFAULT_OLLAMA_MODELS_DESC[$i]}")\"]"; done
    l=""; for i in "${!DEFAULT_LOCALAI_MODELS[@]}"; do l="$l$([ -n "$l" ] && echo ,)[\"$(je "${DEFAULT_LOCALAI_MODELS[$i]}")\",\"$(je "${DEFAULT_LOCALAI_MODELS[$i]} — ${DEFAULT_LOCALAI_MODELS_DESC[$i]}")\"]"; done
    # components the gated phases would find here (or finished in the earlier run):
    # one page, ticked = use as is, unticked = redo. Replaces the per-phase
    # terminal questions that a person watching the window never saw.
    local comp="" opt ttl why
    for k in $GATED_PHASES; do
        why=""
        if [ "$RESUME" = "1" ] && state_has "done_$k"; then why="finished in the earlier run"
        elif comp_present "$k"; then why="already on this machine"; fi
        [ -n "$why" ] || continue
        ttl="$(comp_title "$k")"
        comp="$comp$([ -n "$comp" ] && echo ,)[\"$k\",\"$(je "$ttl — $why")\"]"
    done
    COMP_KEYS=""; for k in $GATED_PHASES; do case "$comp" in *"[\"$k\","*) COMP_KEYS="$COMP_KEYS $k" ;; esac; done
    # "Desktop apps this machine lacks": only when something is missing; fields joined without a trailing comma
    _af=""
    [ "$MISS_BROWSER" = 1 ] && _af="$_af,{ \"key\": \"INST_BROWSER\", \"type\": \"check\", \"text\": \"Web browser — Firefox\", \"default\": \"y\", \"summary\": \"Install Firefox\" }"
    [ "$MISS_FILES" = 1 ]   && _af="$_af,{ \"key\": \"INST_FILES\", \"type\": \"check\", \"text\": \"File manager — $(desk_files_pkg)\", \"default\": \"y\", \"summary\": \"Install file manager\" }"
    [ "$MISS_TERM" = 1 ]    && _af="$_af,{ \"key\": \"INST_TERM\", \"type\": \"check\", \"text\": \"Terminal — $(desk_term_pkg)\", \"default\": \"y\", \"summary\": \"Install terminal\" }"
    _apps_page=""
    [ -n "$_af" ] && _apps_page="    { \"id\": \"apps\", \"title\": \"Desktop apps this machine lacks\", \"text\": \"Cockpit opens files, folders, terminals and links through the desktop's own apps. These are missing here; tick to install them.\", \"fields\": [ ${_af#,} ] },"
    cat > "$spec" <<JSON
{ "title": "AI Cockpit Setup", "heading": "AI Cockpit", "subheading": "Local-first AI workbench — setup", "width": 720, "height": 680, "finish_label": "Install",
  "icon": "$(je "$SELF_DIR/logo_128.png")", "logo": "$(je "$SELF_DIR/logo_32.png")",
  "pages": [
    { "id": "welcome", "title": "Welcome", "text": "This sets up AI Cockpit on this computer.\n\nA few pages of choices, one password prompt for the system (sudo), then it installs on its own — packages, the AI command-line tools, Ollama, and the app itself.\n\nEverything here can be changed later. Re-running this setup is safe: it remembers your answers." },
    { "id": "edition", "title": "Edition", "text": "One codebase — the choice only sets what is switched on.", "fields": [
      { "key": "EDITION", "type": "radio", "label": "Which edition runs on this machine?", "default": "1", "summary": "Edition", "options": [
        ["1", "Full — registers once with a FREE account (no card): Marketplace and the optional paid features. Everything local stays free."],
        ["2", "Stand-alone — no account, ever, zero network calls to our server. No Marketplace / Cruise / AutoCognition / Everywhere relay."],
        ["3", "Both — Full at /cockpit and Stand-alone at /cockpit-v1, side by side."] ] } ] },
    { "id": "folders", "title": "User and folders", "fields": [
      { "key": "USER", "type": "entry", "label": "Install for which Linux user", "hint": "Cockpit's files, models and background agents run as this user — normally your own login.", "default": "$(je "$DEFAULT_USER")", "summary": "User" },
      { "key": "PROJECTS", "type": "folder", "label": "Projects folder", "hint": "Where the workspaces you create in the app live (code, notes, generated files). Anything with room.", "default": "$(je "$home_guess/$PROJECTS_ROOT_DEFAULT_NAME")", "summary": "Projects" } ] },
    { "id": "agents", "title": "AI command-line tools", "text": "Claude Code and Gemini CLI are always installed. Optional extras:", "fields": [
      { "key": "CODEX", "type": "check", "text": "OpenAI Codex CLI — Card 2 uses it by default (small npm download)", "default": "y", "summary": "Codex CLI" },
      { "key": "QWEN", "type": "check", "text": "Qwen Code CLI (Alibaba) — only if you specifically want it", "default": "n", "summary": "Qwen CLI" },
      { "key": "AIDER", "type": "check", "text": "Aider — free open-source agent on your local Ollama models, no key", "default": "y", "summary": "Aider" },
      { "key": "EXTRA", "type": "check", "text": "Goose and opencode — more free local agents (Rust/Go, no Python)", "default": "n", "summary": "Goose + opencode" },
      { "key": "YTDLP", "type": "check", "text": "yt-dlp media downloader for the Tools card", "default": "n", "summary": "yt-dlp" } ] },
    { "id": "models", "title": "Local models", "text": "This machine: $(je "${HW_CPU_MODEL:-?} · ${HW_RAM_MB} MB RAM · ${HW_GPU_NAME:-no GPU}$([ "${HW_VRAM_MB:-0}" -gt 0 ] && echo " · ${HW_VRAM_MB} MB VRAM")")$([ "$HW_NOGPU" = "1" ] && echo '\n<b>No discrete GPU</b> — local models run on the CPU here; nothing is pre-selected.' || { [ "$HW_TIER" = "low" ] && echo '\n<b>Small GPU</b> — the 1.5–4B models fit; the 7B one will be slow.'; })\nEach model is a multi-GB download. The first prompt to a missing model pulls it anyway.", "fields": [
      { "key": "OLLAMA", "type": "checklist", "label": "Ollama models to pull now", "default": "$md", "summary": "Ollama models", "options": [ $o ] },
      { "key": "LOCALAI", "type": "checklist", "label": "LocalAI models to pull now", "hint": "Same jobs through LocalAI's llama.cpp — Dual Mode and dual-supplier combos need both backends.", "default": "$md", "summary": "LocalAI models", "options": [ $l ] } ] },
    { "id": "media", "title": "Media tools (optional)", "text": "Each one builds or downloads for a few minutes. All can be added later from the Setup Guide.", "fields": [
      { "key": "LT", "type": "check", "text": "LibreTranslate — offline chat translation", "default": "y", "summary": "LibreTranslate" },
      { "key": "LT_LANGS", "type": "entry", "label": "Languages to load (comma-separated)", "default": "$(je "$( _l="$(printf '%s' "${LANG:-}" | cut -d_ -f1)"; [ -n "$_l" ] && [ "$_l" != en ] && echo "en,$_l" || echo en)")", "show_if": { "LT": ["y"] }, "summary": "Languages" },
      { "key": "SD", "type": "check", "text": "stable-diffusion.cpp — local image generation (+ ~4 GB model)", "default": "n", "summary": "Image generation" },
      { "key": "TTS", "type": "check", "text": "Piper — local text-to-speech for the Sound button", "default": "y", "summary": "Piper TTS" },
      { "key": "TTS_V", "type": "entry", "label": "Voices to install (en,es,he supported)", "default": "en,es,he", "show_if": { "TTS": ["y"] }, "summary": "Voices" },
      { "key": "WH", "type": "check", "text": "whisper.cpp — local video/audio transcription (Transcriber SRT); compiles from source", "default": "y", "summary": "whisper.cpp" },
      { "key": "WH_M", "type": "select", "label": "Whisper model", "default": "base", "show_if": { "WH": ["y"] }, "summary": "Whisper model", "options": [["base","base — fast"],["small","small — better"],["medium","medium — best, slow"]] },
      { "key": "TEX", "type": "select", "label": "LaTeX system for the Academic paper tools", "default": "recommended", "summary": "LaTeX", "options": [["recommended","Recommended — what most papers need (about 22 MB download)"],["full","Full — adds LuaTeX for Hebrew papers, biblatex/biber, latexmk, extra packages (about 217 MB download, 640 MB on disk)"],["none","None — the paper tools then say what is missing"]] } ] },
$([ -n "$comp" ] && printf '%s' '    { "id": "present", "title": "Already on this machine", "text": "These were found here (or finished in the earlier run). Ticked = keep as is. Untick one to install it again.", "fields": [
      { "key": "KEEP", "type": "checklist", "label": "Keep", "default": "all", "summary": "Keep as is", "options": [ '"$comp"' ] } ] },')
$_apps_page
    { "id": "remote", "title": "Remote administration", "text": "Optional. Let one address open a shell on this machine over SSH — for managing it from another computer (your desktop, a VM host). Leave blank for none.$([ "$IN_VM" = 1 ] && printf '%s' ' This is a virtual machine: the QEMU guest agent is installed so the host can drive it.')", "fields": [
      { "key": "SSH_ALLOW", "type": "entry", "label": "Allow SSH from this IP or network (e.g. 192.168.1.10 or 192.168.1.0/24)", "default": "", "summary": "SSH from" } ] },
    { "id": "desktop", "title": "Desktop", "fields": [
      { "key": "CKBROWSER", "type": "check", "text": "Use the Cockpit window as the web browser — for links inside Cockpit and as the system default (Cockpit Browser)", "default": "$CKBROWSER", "summary": "Cockpit Browser" },
      { "key": "AUTOSTART", "type": "check", "text": "Open AI Cockpit automatically when you log in", "default": "n", "summary": "Autostart" },
      { "key": "HOTKEY", "type": "check", "text": "Ctrl+Alt+C brings AI Cockpit up from any application", "default": "y", "summary": "Ctrl+Alt+C" },
      { "key": "BW", "type": "check", "text": "Bitwarden CLI (bw) — fill Cockpit's login forms from your vault", "default": "n", "summary": "Bitwarden CLI" }$([ -d "$SELF_DIR/tools" ] && echo ',
      { "key": "TOOLS", "type": "check", "text": "Companion tools (into ~/.local, no root)", "default": "y", "summary": "Companion tools" },
      { "type": "note", "dim": true, "text": "    <b>ftpsuite</b> — ftpush / ftpull / ftps-cli / ftps-gui: deploy files to a site over FTPS from a terminal or a small GUI.\n    <b>secretsuite</b> — secrets / secrets-cli / secrets-gui: encrypted credential sheets (gpg) that ftpush and your scripts read." }') ] },
    { "id": "logins", "title": "Logins", "text": "Both are optional here — the app asks for anything left blank on its first screen.", "fields": [
      { "key": "APP_USER", "type": "entry", "label": "Local app login — username", "hint": "Unlocks the app on this machine (not a system account). Full edition: the first login takes your Cockpit account name — fill the account below and this name follows it.", "default": "", "summary": "App login" },
      { "key": "APP_PASS", "type": "password", "label": "Local app login — password (min 6)", "default": "", "summary": "App password" },
      { "key": "APP_PASS2", "type": "password", "label": "Repeat the password", "default": "", "confirm_of": "APP_PASS" },
      { "key": "SAAS_USER", "type": "entry", "label": "cockpit.ruggi.site account — username", "hint": "Already have one? Sign in here. No account yet: leave blank, the app creates one (free, no card) with the human check.", "default": "", "show_if": { "EDITION": ["1","3"] }, "summary": "Account" },
      { "key": "SAAS_PASS", "type": "password", "label": "cockpit.ruggi.site account — password", "default": "", "show_if": { "EDITION": ["1","3"] }, "summary": "Account password" } ] },
    { "id": "summary", "title": "Ready to install", "type": "summary", "text": "Press Install. The system will ask for your password once (sudo)." }
  ] }
JSON
    # remembered answers (resume) → the wizard's prefill
    : > "$pre"
    { printf 'EDITION=%s\n'  "$(gui_answer_for 'Pick 1, 2, or 3')"
      printf 'USER=%s\n'     "$(gui_answer_for 'Install for which user')"
      printf 'PROJECTS=%s\n' "$(gui_answer_for 'Projects folder')"
      printf 'CODEX=%s\n'    "$(gui_answer_for 'Also install OpenAI Codex CLI? (Card 2 uses it by default; small npm download) [Y/n]')"
      printf 'QWEN=%s\n'     "$(gui_answer_for 'Also install Qwen Code CLI? (extra download, optional) [y/N]')"
      printf 'YTDLP=%s\n'    "$(gui_answer_for 'Install yt-dlp media downloader? (optional) [y/N]')"
      printf 'AIDER=%s\n'    "$(gui_answer_for 'Install Aider (free open-source agent — runs on your local Ollama models, no key)? (y/n)')"
      printf 'EXTRA=%s\n'    "$(gui_answer_for 'Also install Goose and opencode (extra free local agents, no Python)? (y/n)')"
      printf 'OLLAMA=%s\n'   "$(gui_answer_for "Ollama models to pull (numbers, names, or 'none')")"
      printf 'LOCALAI=%s\n'  "$(gui_answer_for "LocalAI models to pull (numbers, names, or 'none')")"
      printf 'LT=%s\n'       "$(gui_answer_for 'Install LibreTranslate for offline chat translation? (y/n)')"
      printf 'LT_LANGS=%s\n' "$(gui_answer_for 'Languages to load (comma-separated)')"
      printf 'SD=%s\n'       "$(gui_answer_for 'Build local image generation (stable-diffusion.cpp + ~4GB model)? (y/n)')"
      printf 'TTS=%s\n'      "$(gui_answer_for 'Install Piper text-to-speech for the Sound button? (y/n)')"
      printf 'TTS_V=%s\n'    "$(gui_answer_for 'Voices to install (en,es,he supported)')"
      printf 'WH=%s\n'       "$(gui_answer_for 'Build whisper.cpp for local video transcription (Transcriber SRT)? (y/n)')"
      printf 'WH_M=%s\n'     "$(gui_answer_for 'Whisper model (base=fast, small/medium=better)')"
      printf 'TEX=%s\n'      "$(gui_answer_for 'LaTeX system for the Academic paper tools (none, recommended, full)')"
      printf 'AUTOSTART=%s\n' "$(gui_answer_for 'Open AI Cockpit automatically when you log in? [y/N]')"
      printf 'HOTKEY=%s\n'   "$(gui_answer_for 'Add a Ctrl+Alt+C shortcut that brings AI Cockpit up from any application? [Y/n]')"
      printf 'CKBROWSER=%s\n' "$(gui_answer_for 'Use the Cockpit window as the web browser? [y/N]')"
      printf 'INST_BROWSER=%s\n' "$(gui_answer_for 'Install a web browser (Firefox)? [Y/n]')"
      printf 'INST_FILES=%s\n' "$(gui_answer_for 'Install a file manager? [Y/n]')"
      printf 'INST_TERM=%s\n' "$(gui_answer_for 'Install a terminal? [Y/n]')"
      printf 'SSH_ALLOW=%s\n' "$(gui_answer_for 'Allow SSH from this IP or network (blank = none)')"
      printf 'BW=%s\n'       "$(gui_answer_for 'Install the Bitwarden CLI (bw) so login forms can be filled from your Bitwarden vault? [y/N]')"
      printf 'TOOLS=%s\n'    "$(gui_answer_for 'Install the companion tools? [Y/n]')"
      printf 'APP_USER=%s\n' "$(gui_answer_for 'Local Cockpit login username (blank = skip, app asks on first open)')"
      printf 'SAAS_USER=%s\n' "$(gui_answer_for 'cockpit.ruggi.site username (blank = skip / create below)')"
    } | grep -v '=$' > "$pre" || true
    if ! "$CKD" --wizard "$spec" --answers "$pre" --out "$out"; then rm -f "$out" "$pre"; fatal "Setup cancelled."; fi
    # answers → the same per-question memory the terminal questionnaire fills
    # (SAAS_PASS / LOCAL_APP_PASS stay global — Phase 7b and 12 read them; a local here
    # made Phase 12 ask for the SaaS password in the terminal on ck-ubuntu2404)
    local EDITION USER PROJECTS CODEX QWEN AIDER EXTRA YTDLP OLLAMA LOCALAI LT LT_LANGS SD TTS TTS_V WH WH_M AUTOSTART HOTKEY BW TOOLS APP_USER APP_PASS APP_PASS2 SAAS_USER KEEP
    while IFS='=' read -r k v; do case "$k" in EDITION|USER|PROJECTS|CODEX|QWEN|AIDER|EXTRA|YTDLP|OLLAMA|LOCALAI|LT|LT_LANGS|SD|TTS|TTS_V|WH|WH_M|AUTOSTART|HOTKEY|BW|TOOLS|APP_USER|APP_PASS|APP_PASS2|SAAS_USER|SAAS_PASS|KEEP|CKBROWSER|INST_BROWSER|INST_FILES|INST_TERM|SSH_ALLOW) printf -v "$k" '%s' "$v" ;; esac; done < "$out"
    rm -f "$out" "$pre"   # passwords were in there
    pre_set "Pick 1, 2, or 3" "${EDITION:-1}"
    pre_set "Install for which user" "${USER:-$DEFAULT_USER}"
    pre_set "Projects folder" "${PROJECTS:-}"
    pre_set "Also install OpenAI Codex CLI? (Card 2 uses it by default; small npm download) [Y/n]" "${CODEX:-n}"
    pre_set "Also install Qwen Code CLI? (extra download, optional) [y/N]" "${QWEN:-n}"
    pre_set "Install yt-dlp media downloader? (optional) [y/N]" "${YTDLP:-n}"
    pre_set "Install Aider (free open-source agent — runs on your local Ollama models, no key)? (y/n)" "${AIDER:-n}"
    pre_set "Also install Goose and opencode (extra free local agents, no Python)? (y/n)" "${EXTRA:-n}"
    pre_set "Ollama models to pull (numbers, names, or 'none')" "${OLLAMA:-none}"
    pre_set "LocalAI models to pull (numbers, names, or 'none')" "${LOCALAI:-none}"
    pre_set "Install LibreTranslate for offline chat translation? (y/n)" "${LT:-n}"
    pre_set "Languages to load (comma-separated)" "${LT_LANGS:-en}"
    pre_set "Build local image generation (stable-diffusion.cpp + ~4GB model)? (y/n)" "${SD:-n}"
    pre_set "Install Piper text-to-speech for the Sound button? (y/n)" "${TTS:-n}"
    pre_set "Voices to install (en,es,he supported)" "${TTS_V:-en}"
    pre_set "Build whisper.cpp for local video transcription (Transcriber SRT)? (y/n)" "${WH:-n}"
    pre_set "Whisper model (base=fast, small/medium=better)" "${WH_M:-base}"
    pre_set "LaTeX system for the Academic paper tools (none, recommended, full)" "${TEX:-recommended}"
    pre_set "Install whisper.cpp for offline voice transcription? (slow build, optional) [y/N]" "n"
    pre_set "Open AI Cockpit automatically when you log in? [y/N]" "${AUTOSTART:-n}"
    pre_set "Add a Ctrl+Alt+C shortcut that brings AI Cockpit up from any application? [Y/n]" "${HOTKEY:-n}"
    pre_set "Use the Cockpit window as the web browser? [y/N]" "${CKBROWSER:-n}"; pre_set "Use the Cockpit window as the web browser? [Y/n]" "${CKBROWSER:-n}"   # the runtime confirm's default (and so its hint) depends on whether a browser exists
    pre_set "Install a web browser (Firefox)? [Y/n]" "${INST_BROWSER:-n}"
    pre_set "Install a file manager? [Y/n]" "${INST_FILES:-n}"
    pre_set "Install a terminal? [Y/n]" "${INST_TERM:-n}"
    pre_set "Allow SSH from this IP or network (blank = none)" "${SSH_ALLOW:-}"
    pre_set "Install the Bitwarden CLI (bw) so login forms can be filled from your Bitwarden vault? [y/N]" "${BW:-n}"
    pre_set "Install the companion tools? [Y/n]" "${TOOLS:-n}"
    pre_set "Local Cockpit login username (blank = skip, app asks on first open)" "${APP_USER:-}"
    LOCAL_APP_PASS="${APP_PASS:-}"
    pre_set "cockpit.ruggi.site username (blank = skip / create below)" "${SAAS_USER:-}"
    SAAS_PASS="${SAAS_PASS:-}"
    [ -n "${SAAS_USER:-}" ] || pre_set "Create a new FREE account now? [Y/n]" "n"
    # the "already on this machine" page: kept → skip the phase, unticked → redo
    for k in ${COMP_KEYS:-}; do case " ${KEEP:-} " in *" $k "*) pre_set "redo:$k" "n" ;; *) pre_set "redo:$k" "y" ;; esac; done
    pre_set "Proceed? [Y/n]" "y"
    QUIET_PREFILL=1
    # sudo through a window, not the terminal: sudo -A + our askpass. On WSL people
    # reach for the Windows password; the Linux one is what sudo wants here.
    _ap_msg="AI Cockpit Setup needs your password to install system packages (sudo)."
    [ "$IS_WSL" = 1 ] && _ap_msg="AI Cockpit Setup needs your Linux (WSL) password for sudo — the one install_windows.ps1 showed, not your Windows password."
    printf '#!/bin/sh\nexec "%s" --askpass "%s"\n' "$CKD" "$_ap_msg" > "$STATE_DIR/askpass.sh"
    chmod 700 "$STATE_DIR/askpass.sh"; export SUDO_ASKPASS="$STATE_DIR/askpass.sh"
    sudo() { command sudo -A "$@"; }
    # progress window follows the log; tail ends with this script → the window shows Done
    tail -n 0 -f --pid=$$ "$INSTALL_LOG" 2>/dev/null | "$CKD" --progress --title "Installing AI Cockpit" --text "Sit back — this takes a while (packages, AI tools, models). The window says Done when it is finished." --total "$(grep -c '^step "Phase ' "$0")" --phase-match "▶ Phase " >/dev/null 2>&1 &
}
# ── Interrupted or earlier install? ──────────────────────────────────────────
if [ "$UNATTENDED" != "1" ] && state_load; then
    echo
    if [ "$STATE_COMPLETE" = "1" ]; then
        note "AI Cockpit was already installed from here (run started ${STATE_STARTED:-?})."
        echo "    1) Continue — keep the earlier answers; components already here are"
        echo "                  offered one by one as 'use it' or 'redo'"
        echo "    2) Start anew — forget the earlier answers and ask everything again"
    else
        note "An earlier install stopped after '${STATE_LAST:-the start}' (run started ${STATE_STARTED:-?})."
        echo "    1) Continue — keep its answers and skip what it finished (each one asked first)"
        echo "    2) Start anew — forget it and ask everything again"
    fi
    if [ "$GUI" = "1" ]; then
        if "$CKD" --question --title "AI Cockpit Setup" --text "$([ "$STATE_COMPLETE" = "1" ] && echo "AI Cockpit was already installed from here." || echo "An earlier setup stopped after '${STATE_LAST:-the start}'.")

Continue with the earlier answers? (No = start anew and ask everything again)"; then _rs=1; else _rs=2; fi
    else
        ask _rs "Pick 1 or 2" "1"
    fi
    if [ "$_rs" = "2" ]; then state_reset; ok "Starting anew"; else RESUME=1; ok "Continuing the earlier run"; fi
else
    state_reset
fi
[ "$GUI" = "1" ] && gui_wizard

TARBALL="${1:-}"
if [ -n "$TARBALL" ] && [ -f "$TARBALL" ]; then
    COCKPIT_APP_VERSION="${COCKPIT_APP_VERSION:-explicit}"
else
    if [ -z "$COCKPIT_APP_VERSION" ]; then
        if [ "$UNATTENDED" = "1" ]; then
            COCKPIT_APP_VERSION="${COCKPIT_UNATTENDED_APP_VERSION:-v2}"
        else
            echo
            # Same words as the download page, same default (Full). The old "v2 / v1
            # older 1.0.0 / Enter = both" contradicted it and installed two copies
            # when the prompt timed out (ck-ubuntu2404).
            echo "  Which edition this machine runs (one codebase; the choice sets what is switched on):"
            echo "    1) Full        — registers once with a FREE account (no card): Marketplace,"
            echo "                     and the optional paid features. Everything local stays free."
            echo "    2) Stand-alone — no account, ever, zero network calls to our server."
            echo "                     No Marketplace / Cruise / AutoCognition / Everywhere relay."
            echo "    3) Both        — Full at /cockpit AND Stand-alone at /cockpit-v1, side by side."
            ask _vc "Pick 1, 2, or 3" "1"
            case "$_vc" in 1) COCKPIT_APP_VERSION=v2 ;; 2) COCKPIT_APP_VERSION=v1 ;; *) COCKPIT_APP_VERSION=both ;; esac
        fi
    fi
    case "$COCKPIT_APP_VERSION" in
        v1)   TARBALL="$(resolve_tarball v1)" ;;
        v2)   TARBALL="$(resolve_tarball v2)" ;;
        both) TARBALL="$(resolve_tarball v2)"; INSTALL_BOTH=1
              SECONDARY_VERSION=v1; SECONDARY_TARBALL="$(resolve_tarball v1)" ;;
        *)    fatal "Unknown version '$COCKPIT_APP_VERSION' (use --v1, --v2, or --both)." ;;
    esac
fi
if [ -z "$TARBALL" ] || [ ! -f "$TARBALL" ]; then
    echo
    fatal "No tarball found. Pass a path ($0 /path/to/cockpit.tar.gz) or run Installs/build_dist.sh to stage $DIST_DIR (cockpit_v1.tar.gz / cockpit_v2.tar.gz)."
fi
if [ "$INSTALL_BOTH" = "1" ] && { [ -z "$SECONDARY_TARBALL" ] || [ ! -f "$SECONDARY_TARBALL" ]; }; then
    fatal "'both' selected but the v1 tarball is missing in $DIST_DIR — run Installs/build_dist.sh."
fi

# The selection is now known. Report it for EVERY choice, v1 included: a missing
# 'selection' event then means "walked away before choosing", which absence
# could not tell us before. For v1 this is the last thing sent unless the user
# says yes at the end.
tele_build_meta
tele_selection
# readlink -f is a GNU coreutils extension — not on macOS's BSD readlink.
# cd+pwd works identically everywhere and needs no platform branch.
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
[ -n "$SECONDARY_TARBALL" ] && SECONDARY_TARBALL="$(cd "$(dirname "$SECONDARY_TARBALL")" && pwd)/$(basename "$SECONDARY_TARBALL")"
if [ "$INSTALL_BOTH" = "1" ]; then
    ok "Version   : both (primary v2 + secondary v1)"
else
    ok "Version   : ${COCKPIT_APP_VERSION:-explicit tarball}"
fi
note "Using tarball: $TARBALL"
[ "$INSTALL_BOTH" = "1" ] && note "Secondary  : $SECONDARY_TARBALL → ${WEB_ROOT}-v1"
# V2 (primary or 'both') needs at least a free cockpit.ruggi.site account.
V2_SELECTED=0
case "$COCKPIT_APP_VERSION" in v2|both) V2_SELECTED=1 ;; esac

# Check Linux Mint / Ubuntu version
if [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    note "Detected: $DISTRIB_DESCRIPTION"
fi

# =============================================================================
# Phase 1 — Identify the user
# =============================================================================
echo
step "Phase 1 — User configuration"
echo
note "Which Linux/Mac account Cockpit installs under — its files, models, and"
note "background agents run as this user. Normally your own login. The app's own"
note "browser login is separate (set later). Detected: ${DEFAULT_USER}"
if [ "$UNATTENDED" = "1" ]; then
    INPUT_USER=""
    note "Use this user, or enter a different one: (unattended, using detected user)"
else
    ask INPUT_USER "Install for which user" "$DEFAULT_USER"
fi
COCKPIT_USER="${INPUT_USER:-$DEFAULT_USER}"

if ! id "$COCKPIT_USER" &>/dev/null; then
    fatal "User '$COCKPIT_USER' does not exist on this system."
fi

# getent is a GNU/glibc tool — no equivalent shell-out on macOS, use dscl.
if [ "$IS_MACOS" = "1" ]; then
    USER_HOME=$(dscl . -read "/Users/$COCKPIT_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
else
    USER_HOME=$(getent passwd "$COCKPIT_USER" | cut -d: -f6)
fi
SCRIPTS_DIR="${USER_HOME}/${SCRIPTS_DIR_NAME}"
# Ollama uses its OWN default models dir (see Phase 4). Shown here for the layout
# summary; Phase 4 re-confirms it (or an existing custom path).
if [ "$IS_MACOS" = "1" ]; then
    OLLAMA_MODELS_DIR="${USER_HOME}/.ollama/models"
else
    OLLAMA_MODELS_DIR="/usr/share/ollama/.ollama/models"
fi
LOCALAI_MODELS_DIR="${USER_HOME}/${LOCALAI_MODELS_DIR_NAME}"
LOCALAI_DATA_DIR="${USER_HOME}/${LOCALAI_DATA_DIR_NAME}"
LOCALAI_BACKENDS_DIR="${USER_HOME}/${LOCALAI_BACKENDS_DIR_NAME}"

# ── Projects root — let the user pick/create instead of a hardcoded path ────
DEFAULT_PROJECTS_ROOT="${USER_HOME}/${PROJECTS_ROOT_DEFAULT_NAME}"
if [ "$UNATTENDED" = "1" ]; then
    PROJECTS_ROOT="${COCKPIT_UNATTENDED_PROJECTS_ROOT:-$DEFAULT_PROJECTS_ROOT}"
    note "Projects root: $PROJECTS_ROOT (unattended)"
else
    note "Folder where Cockpit keeps the projects/workspaces you create in the app"
    note "(code, notes, generated files). Pick anything with room; the default is fine."
    ask INPUT_PROJECTS_ROOT "Projects folder" "$DEFAULT_PROJECTS_ROOT"
    PROJECTS_ROOT="${INPUT_PROJECTS_ROOT:-$DEFAULT_PROJECTS_ROOT}"
fi
# Expand ~ if the user typed it
PROJECTS_ROOT="${PROJECTS_ROOT/#\~/$USER_HOME}"

# On Linux, WEB_ROOT's parent is root-owned (/var/www/html, /srv/http, etc.)
# so writing there needs sudo, while $COCKPIT_USER's own paths (scripts,
# projects, cockpit_data) are written as that user via `sudo -u`. On macOS,
# Homebrew's whole prefix (including its DocumentRoot) is owned by the
# invoking user already — no privilege split exists, and running any of this
# under sudo would create root-owned files that the later plain-user
# permissions pass (Phase 8) can't fix, since it doesn't itself use sudo.
# as_root/as_user below make every command from here on go through the
# right path without duplicating each line per OS. Functions, not arrays —
# macOS ships bash 3.2 (Apple froze it at the last GPLv2 release), and an
# EMPTY array expanded as "${arr[@]}" under `set -u` throws "unbound
# variable" on bash < 4.4 even though the array is legitimately declared
# empty on purpose (fixed upstream in 4.4, confirmed the hard way via CI on
# a real macOS runner). Functions sidestep the whole bash-version pitfall.
# Defined here (right after COCKPIT_USER is known) rather than down in
# Phase 7 where extraction happens, since Phase 4's optional whisper.cpp
# build also needs it.
as_root() { if [ "$IS_MACOS" = "1" ]; then "$@"; else sudo "$@"; fi; }
# fetch_mirror URL OUT NAME — download URL; when upstream is gone (a release
# withdrawn, a project moved) fall back to the copy Cockpit keeps at
# ruggi.site/assets/files/tools/NAME (served by backups.php?get=NAME). The mirror
# is filled only for things that disappeared; see Installs/deps_manifest.sh.
fetch_mirror() {
    local url="$1" out="$2" name="$3"
    if curl -fL --retry 2 -o "$out" "$url" 2>/dev/null; then return 0; fi
    warn "upstream download failed ($url) — trying the Cockpit mirror"
    if curl -fL --retry 2 -o "$out" "https://ruggi.site/backups.php?get=$name" 2>/dev/null; then ok "got $name from the Cockpit mirror"; return 0; fi
    rm -f "$out"; return 1
}
as_user() { if [ "$IS_MACOS" = "1" ]; then "$@"; else sudo -u "$COCKPIT_USER" "$@"; fi; }
# Session-bound helpers (gsettings keybindings, autostart, keyring) need the
# user's D-Bus session; a plain sudo -u drops it and gsettings then writes
# nowhere while exiting 0 — the Ctrl+Alt+C shortcut 'succeeded' on ck-ubuntu2404
# and did nothing. Same user as the invoker → run directly; else pass the bus.
as_session_user() {
    if [ "$IS_MACOS" = "1" ] || [ "$COCKPIT_USER" = "$(id -un)" ]; then "$@"; return; fi
    local _uid; _uid="$(id -u "$COCKPIT_USER" 2>/dev/null || echo 1000)"
    sudo -u "$COCKPIT_USER" env "XDG_RUNTIME_DIR=/run/user/$_uid" "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$_uid/bus" \
        "DISPLAY=${DISPLAY:-:0}" "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}" "HOME=$USER_HOME" "$@"
}

# ── PATH / npm-prefix helpers ────────────────────────────────────────────────
# Add a dir to the user's PATH in whichever rc files exist (idempotent). Used
# for the npm prefix bin and ~/.local/bin (local-ai).
ensure_path_dir() {
    local dir="$1" line rc
    line="export PATH=\"${dir}:\$PATH\""
    for rc in "${USER_HOME}/.profile" "${USER_HOME}/.zshrc" "${USER_HOME}/.bashrc"; do
        [ -e "$rc" ] || { [ "$rc" = "${USER_HOME}/.profile" ] || continue; as_user touch "$rc"; }
        grep -qF "$dir" "$rc" 2>/dev/null || printf '%s\n' "$line" | as_user tee -a "$rc" >/dev/null
    done
    case ":$PATH:" in *":$dir:"*) ;; *) export PATH="$dir:$PATH" ;; esac
}

# Single global npm prefix decision: a per-user prefix (~/.npm-global) so the
# agent CLIs never need sudo and never land in two places. Reconciles whatever
# THIS machine already has — another rig may carry a system prefix or a stray
# global copy from a previous install.
NPM_PREFIX_TARGET="${USER_HOME}/.npm-global"
setup_npm_prefix() {
    local cur cli_path
    cur="$(as_user npm config get prefix 2>/dev/null || echo '')"
    cli_path="$(as_user sh -lc 'command -v claude 2>/dev/null || command -v gemini 2>/dev/null' 2>/dev/null || echo '')"
    if [ -n "$cli_path" ]; then
        case "$cli_path" in
            "${NPM_PREFIX_TARGET}/bin/"*) ok "npm prefix: agent CLIs already under ${NPM_PREFIX_TARGET}" ;;
            *)
                warn "Existing agent CLI found outside the standard prefix:"
                warn "    $cli_path"
                warn "    standard prefix here: ${NPM_PREFIX_TARGET}/bin"
                if [ "$UNATTENDED" = "1" ] || confirm "Remove the old global copies and switch to ${NPM_PREFIX_TARGET}?" "y"; then
                    for p in @anthropic-ai/claude-code @google/gemini-cli @openai/codex @qwen-code/qwen-code; do
                        as_user npm rm -g "$p" >/dev/null 2>&1 || sudo npm rm -g "$p" >/dev/null 2>&1 || true
                    done
                    ok "Old global CLIs removed — will reinstall under ${NPM_PREFIX_TARGET}"
                else
                    fatal "Existing global CLIs in '$cur' would collide. Uninstall them (npm rm -g @anthropic-ai/claude-code @google/gemini-cli ...) then re-run."
                fi ;;
        esac
    fi
    as_user mkdir -p "${NPM_PREFIX_TARGET}/bin"
    as_user npm config set prefix "$NPM_PREFIX_TARGET" >/dev/null 2>&1 || true
    ensure_path_dir "${NPM_PREFIX_TARGET}/bin"
    ok "npm global prefix set to ${NPM_PREFIX_TARGET} (no sudo needed for global installs)"
}
# User-prefix global install — no sudo, one location on every OS.
npm_i() {
    if [ "${ONLINE:-1}" != "1" ]; then warn "Offline — skipping npm install: $*"; return 0; fi
    as_user env "npm_config_prefix=$NPM_PREFIX_TARGET" npm install -g "$@"
}

# ── Hardware probe (CPU / RAM / GPU / VRAM) ──────────────────────────────────
# Best-effort, mirrors scripts/hardware_scan.sh. Sets HW_CPU_CORES, HW_RAM_MB,
# HW_GPU_NAME, HW_VRAM_MB, and HW_BUDGET_MB (discrete VRAM if any, else system
# RAM) which drives the default local-model tier so we don't push a 7B model
# onto a 4GB card. Needs lspci/nvidia-smi, installed in Phase 1.

ok "User      : $COCKPIT_USER"
ok "Home      : $USER_HOME"
ok "Web root  : $WEB_ROOT"
ok "Scripts   : $SCRIPTS_DIR"
ok "Models    : $OLLAMA_MODELS_DIR"
ok "Projects  : $PROJECTS_ROOT"
echo


# ── Everything asked up front ─────────────────────────────────────────────────
# One screen of choices, then the install runs through on them without
# stopping (three interrupted VM runs were all "walked away at a prompt").
# Every phase still asks its own question — and finds the answer already given
# here (ask() keeps answers per question for the whole run). Passwords stay in
# memory only.
if [ "$UNATTENDED" != "1" ] && [ "$GUI" != "1" ]; then
    echo
    step "Your choices"
    note "Answer these once; the install then runs without further questions."
    note "Enter takes the default shown. Everything can be changed later."
    echo
    detect_hardware
    ok "This machine: ${HW_CPU_MODEL:-?} · ${HW_RAM_MB} MB RAM · ${HW_GPU_NAME:-no GPU}$([ "${HW_VRAM_MB:-0}" -gt 0 ] && echo " · ${HW_VRAM_MB} MB VRAM")"
    [ "$HW_NOGPU" = "1" ] && warn "No discrete GPU — local models run on the CPU here; model pulls default to none."
    _MODELS_DEFAULT="$([ "$HW_NOGPU" = "1" ] && echo none || echo all)"
    echo
    note "── Agent CLIs (Claude Code + Gemini are always installed) ──"
    command -v codex >/dev/null 2>&1 || confirm "Also install OpenAI Codex CLI? (Card 2 uses it by default; small npm download)" "y" || true
    command -v qwen  >/dev/null 2>&1 || confirm "Also install Qwen Code CLI? (extra download, optional)" "n" || true
    command -v yt-dlp >/dev/null 2>&1 || confirm "Install yt-dlp media downloader? (optional)" "n" || true
    echo
    note "── Free local agents (run on your own Ollama models, no key) ──"
    ask _q "Install Aider (free open-source agent — runs on your local Ollama models, no key)? (y/n)" "y"
    ask _q "Also install Goose and opencode (extra free local agents, no Python)? (y/n)" "n"
    echo
    note "── Local models (multi-GB downloads; Enter = ${_MODELS_DEFAULT}) ──"
    note "Ollama:"
    for i in "${!DEFAULT_OLLAMA_MODELS[@]}"; do echo "    $((i+1)). ${DEFAULT_OLLAMA_MODELS[$i]} — ${DEFAULT_OLLAMA_MODELS_DESC[$i]}"; done
    ask _q "Ollama models to pull (numbers, names, or 'none')" "$_MODELS_DEFAULT"
    note "LocalAI (same jobs through LocalAI's llama.cpp — Dual Mode / dual-supplier combos need both):"
    for i in "${!DEFAULT_LOCALAI_MODELS[@]}"; do echo "    $((i+1)). ${DEFAULT_LOCALAI_MODELS[$i]} — ${DEFAULT_LOCALAI_MODELS_DESC[$i]}"; done
    ask _q "LocalAI models to pull (numbers, names, or 'none')" "$_MODELS_DEFAULT"
    echo
    note "── Media tools (optional; each builds or downloads, minutes each) ──"
    _LT_DEFAULT_LANGS="en"; _sys_lang="$(printf '%s' "${LANG:-}" | cut -d_ -f1)"
    [ -n "$_sys_lang" ] && [ "$_sys_lang" != "en" ] && _LT_DEFAULT_LANGS="en,$_sys_lang"
    ask _q "Install LibreTranslate for offline chat translation? (y/n)" "y"
    [ "$(yn "$_q")" = yes ] && ask _q "Languages to load (comma-separated)" "$_LT_DEFAULT_LANGS"
    ask _q "Build local image generation (stable-diffusion.cpp + ~4GB model)? (y/n)" "n"
    ask _q "Install Piper text-to-speech for the Sound button? (y/n)" "y"
    [ "$(yn "$_q")" = yes ] && ask _q "Voices to install (en,es,he supported)" "en,es,he"
    ask _q "Build whisper.cpp for local video transcription (Transcriber SRT)? (y/n)" "y"
    [ "$(yn "$_q")" = yes ] && ask _q "Whisper model (base=fast, small/medium=better)" "base"
    note "LaTeX (for the Academic paper tools): recommended = what most papers need (~22 MB); full = + LuaTeX for Hebrew, biber, latexmk, extras (~217 MB download, ~640 MB on disk); none = skip"
    ask _q "LaTeX system for the Academic paper tools (none, recommended, full)" "recommended"
    pre_set "Install whisper.cpp for offline voice transcription? (slow build, optional) [y/N]" "n"   # Phase 5e does that build
    echo
    note "── Desktop ──"
    confirm "Open AI Cockpit automatically when you log in?" n || true
    confirm "Add a Ctrl+Alt+C shortcut that brings AI Cockpit up from any application?" y || true
    if [ "$MISS_BROWSER$MISS_FILES$MISS_TERM" != "000" ]; then
        note "── Desktop apps this machine lacks (Cockpit opens files, folders, terminals and links through them) ──"
        [ "$MISS_BROWSER" = 1 ] && { confirm "Install a web browser (Firefox)?" y || true; }
        [ "$MISS_FILES" = 1 ]   && { note "file manager: $(desk_files_pkg)"; confirm "Install a file manager?" y || true; }
        [ "$MISS_TERM" = 1 ]    && { note "terminal: $(desk_term_pkg)"; confirm "Install a terminal?" y || true; }
    fi
    note "Cockpit Browser: the native window as a plain browser — links inside Cockpit, and the system default (pre-ticked: it is Cockpit's default browser; your own browser stays installed and can be chosen in the Apps panel)"
    confirm "Use the Cockpit window as the web browser?" "$CKBROWSER" || true
    note "── Remote administration (optional) ──"
    [ "$IN_VM" = 1 ] && note "This is a virtual machine: the QEMU guest agent will be installed so the host can drive it."
    ask _ssh "Allow SSH from this IP or network (blank = none)" ""; pre_set "Allow SSH from this IP or network (blank = none)" "$_ssh"
    confirm "Install the Bitwarden CLI (bw) so login forms can be filled from your Bitwarden vault?" n || true
    [ -d "$SELF_DIR/tools" ] && { note "Companion tools: ftpush/ftpull + secrets (into ~/.local, no root)"; confirm "Install the companion tools?" y || true; }
    echo
    note "── Logins (the app asks for anything left blank on its first screen) ──"
    ask LOCAL_APP_USER "Local Cockpit login username (blank = skip, app asks on first open)" ""
    LOCAL_APP_PASS=""
    if [ -n "$LOCAL_APP_USER" ]; then
        read -r -s -p "$(echo -e "${C_BLUE}?${C_OFF} Local app admin password (min 6): ")" LOCAL_APP_PASS; echo
    fi
    SAAS_PASS=""
    if [ "$V2_SELECTED" = "1" ]; then
        ask SAAS_USER "cockpit.ruggi.site username (blank = skip / create below)" ""
        if [ -n "$SAAS_USER" ]; then
            read -r -s -p "$(echo -e "${C_BLUE}?${C_OFF} SaaS password: ")" SAAS_PASS; echo
        else
            note "No account yet — the app's first screen creates one (free, no card), with the human check."
            pre_set "Create a new FREE account now? [Y/n]" "n"
        fi
    fi
    echo
    echo -e "${C_BLUE}  Summary${C_OFF}"
    ok "Edition   : $COCKPIT_APP_VERSION   User: $COCKPIT_USER   Projects: $PROJECTS_ROOT"
    ok "Agents    : Claude, Gemini$([ "$(yn "$(pre_get 'Also install OpenAI Codex CLI? (Card 2 uses it by default; small npm download) [Y/n]')")" = yes ] && echo ', Codex')$([ "$(yn "$(pre_get 'Also install Qwen Code CLI? (extra download, optional) [y/N]')")" = yes ] && echo ', Qwen')$([ "$(yn "$(pre_get 'Install Aider (free open-source agent — runs on your local Ollama models, no key)? (y/n)')")" = yes ] && echo ', Aider')$([ "$(yn "$(pre_get 'Also install Goose and opencode (extra free local agents, no Python)? (y/n)')")" = yes ] && echo ', Goose, opencode')"
    ok "Models    : Ollama=$(pre_get "Ollama models to pull (numbers, names, or 'none')")  LocalAI=$(pre_get "LocalAI models to pull (numbers, names, or 'none')")"
    ok "Media     : LibreTranslate=$(yn "$(pre_get 'Install LibreTranslate for offline chat translation? (y/n)')")  SD=$(yn "$(pre_get 'Build local image generation (stable-diffusion.cpp + ~4GB model)? (y/n)')")  Piper=$(yn "$(pre_get 'Install Piper text-to-speech for the Sound button? (y/n)')")  whisper=$(yn "$(pre_get 'Build whisper.cpp for local video transcription (Transcriber SRT)? (y/n)')")  yt-dlp=$(yn "$(pre_get 'Install yt-dlp media downloader? (optional) [y/N]')")  LaTeX=$(pre_get 'LaTeX system for the Academic paper tools (none, recommended, full)')"
    ok "Desktop   : autostart=$(yn "$(pre_get 'Open AI Cockpit automatically when you log in? [y/N]')")  Ctrl+Alt+C=$(yn "$(pre_get 'Add a Ctrl+Alt+C shortcut that brings AI Cockpit up from any application? [Y/n]')")  Bitwarden=$(yn "$(pre_get 'Install the Bitwarden CLI (bw) so login forms can be filled from your Bitwarden vault? [y/N]')")"
    ok "Logins    : app=${LOCAL_APP_USER:-<first screen>}  account=${SAAS_USER:-<first screen>}"
    echo
    QUIET_PREFILL=1
fi
note "Folders and choices above. Yes = install now with them;"
note "No = stop now so you can re-run and change them. Nothing is written yet."
confirm "Proceed?" || fatal "Aborted by user."

# ── Edition — Full account vs Stand-alone ────────────────────────────────────
# One codebase, one tarball, one runtime flag file. Stand-alone edition means
# no account is ever created and NOTHING calls out to our server, ever — the
# flag file created below (cockpit_data/.edition_standalone) is checked by
# auth.php before its one network call (funnel-ping on first local account
# created) and gates Phase 12's SaaS login prompt further down. Full edition
# (default) leaves the flag absent — matches all pre-unification installs,
# which never wrote it, so upgraders keep their existing behavior.
echo
step "Edition"
echo
# Edition is DERIVED from the version — no separate question:
#   • v2 or both  → Full (V2 needs at least a free cockpit.ruggi.site account).
#   • v1 only     → Stand-alone (v1 is local, needs no account).
if [ "$V2_SELECTED" = "1" ]; then
    EDITION="full"
    note "Edition: Full account — V2 needs at least a FREE account (no card) for the"
    note "Marketplace, remote relay, and sync. You'll sign in / register near the end."
else
    EDITION="standalone"
    note "Edition: Stand-alone — v1 runs fully local with no account and no network"
    note "calls to our server. Nothing to sign into."
fi
ok "Edition   : $EDITION"

# ── Install telemetry consent + first beacon ─────────────────────────────────
TELE_OS=$([ "$IS_MACOS" = "1" ] && echo macos || echo linux)
if [ "$IS_MACOS" = "1" ]; then
    TELE_DISTRO="macos"; TELE_DISTRO_VER="$(sw_vers -productVersion 2>/dev/null || echo '')"
else
    TELE_DISTRO="$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}")"
    TELE_DISTRO_VER="$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")"
fi
# Telemetry is INSTALLER-side and version-gated (not tied to the app edition):
# V2/both → on (opt out); V1-only → explicit opt-in ask.
if [ "$CI_MODE" = "1" ]; then
    TELE_ON=0; note "Install telemetry: off (CI mode)"
elif [ -n "${COCKPIT_NO_TELEMETRY:-}" ]; then
    TELE_ON=0; note "Install telemetry: off (COCKPIT_NO_TELEMETRY set)"
elif [ "$V2_SELECTED" = "1" ]; then
    TELE_ON=1
    note "Install telemetry: ON — anonymous install progress + failures only, so we"
    note "can fix broken installs. No personal data (no username, no paths, no IP)."
    note "Opt out any time by re-running with COCKPIT_NO_TELEMETRY=1."
else
    # V1 chosen — the No-Phone-Home half of the deal starts here. The boot and
    # selection lines are already sent and are the last of it: no phases, no
    # errors, nothing further, unless the user is asked at the very end and says
    # yes to a single "it worked" line. Asking mid-install would interrupt the
    # thing they came to do; asking at the end lets them answer knowing the
    # outcome they would be reporting.
    TELE_ON=0
    note "V1 selected — No Phone Home from here on."
    note "Nothing further is sent during this install: no progress, no errors."
    note "At the very end you will be asked, once, whether to send a single"
    note "anonymous \"it worked\" line. Saying no is final for this install."
fi
tele_build_meta
tele start
# Replay what happened before consent existed: "Phase 1 — User configuration"
# and "Edition" were previously dropped on the floor, so the very step where a
# hesitant user is most likely to stop was the one step never recorded.
tele_flush

# Home dir must be traversable by service accounts (ollama, www-data via
# other-users-execute bit) or their daemons crash-loop trying to mkdir
# under it ("permission denied: ensure path elements are traversable").
# Only adds the execute (traverse) bit, never read — doesn't expose file
# listing or contents, just lets other users descend through if they
# already know the path.
# The GROUP bit matters too: the web server joins the person's group later
# (shared cockpit_data), and for a group member the group bits apply, not
# 'other'. Fedora homes are 0700 — o+x alone left apache unable to reach
# ~/scripts at all (integrity: 23 missing, hardware unknown).
# GNU stat spells the mode -c '%a', BSD (macOS) spells it -f '%OLp'. And the
# 2>/dev/null hid more than it looked: under `set -e` an assignment whose command
# substitution FAILS aborts the script, so on macOS this single line ended the
# install with exit 1 and no message at all, right after the Edition phase.
# Found by the Apple Silicon CI run, 2026-09-23. `|| true` keeps it advisory:
# an unreadable mode should skip the check, never stop the install.
_hm="$(stat -c '%a' "$USER_HOME" 2>/dev/null || stat -f '%OLp' "$USER_HOME" 2>/dev/null || true)"
# Same class of trap one line down: if the mode is not exactly three digits,
# ${_hm:2:1} is empty, `$(( % 2 ))` is an arithmetic error, and set -e kills the
# install again. Require three digits before indexing into it.
if [ ${#_hm} -eq 3 ] && { [ "$(( ${_hm:2:1} % 2 ))" -eq 0 ] || [ "$(( ${_hm:1:1} % 2 ))" -eq 0 ]; }; then
    note "Home dir not traversable by service accounts — fixing (chmod g+x,o+x)..."
    sudo chmod g+x,o+x "$USER_HOME"
fi

# =============================================================================
# Phase 2 — package-manager detection + system packages
# =============================================================================
echo
step "Phase 2 — System packages"
note "Detected package manager: $PKG_MGR (web server: $APACHE_SVC, docroot: $DOCROOT)"

# ── Connectivity — Cockpit can install OFFLINE (esp. V1-only) ─────────────────
# Online steps (package installs, CLI/Ollama/LocalAI downloads, model pulls,
# accounts, telemetry) are skipped gracefully when there's no internet, so the
# local app + web files still deploy. V2 needs internet for its account + models
# to be fully useful; V1 is happy fully offline.
have_internet() {
    curl -fsS -m 5 -o /dev/null https://ollama.com/ 2>/dev/null && return 0
    curl -fsS -m 5 -o /dev/null https://ruggi.site/ 2>/dev/null && return 0
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    return 1
}
if [ "${COCKPIT_ASSUME_OFFLINE:-0}" = "1" ]; then ONLINE=0
elif have_internet; then ONLINE=1
else ONLINE=0; fi
if [ "$ONLINE" = "1" ]; then
    ok "Internet: online"
else
    warn "Internet: OFFLINE — will skip all downloads (packages, CLIs, Ollama/"
    warn "LocalAI, models). Already-installed tools are used as-is. Best for a"
    warn "V1 offline install; V2's account + model pulls need a connection later."
    TELE_ON=0   # nothing to send, and no network to send it on
fi

install_pkgs() {
    if [ "$ONLINE" != "1" ]; then
        warn "Offline — skipping package install: $*"
        return 0
    fi
    # Every package install is a named sub-step. This is where installs most
    # often die -- a missing repo, a held package, a mirror that 404s -- and
    # "Phase 2" alone never said WHICH package. Only the first two names are
    # reported: enough to identify the call, short enough to stay non-personal.
    substep "pkg: $(printf '%s' "$*" | cut -d' ' -f1-2)"
    case "$PKG_MGR" in
        nala|apt-get) sudo "$PKG_MGR" install -y "$@" ;;
        pacman)       sudo pacman -S --noconfirm --needed "$@" ;;
        dnf)          sudo dnf install -y "$@" ;;
        zypper)       sudo zypper --non-interactive install "$@" ;;
        apk)          sudo apk add --no-cache "$@" ;;
        brew)
            # brew install errors on an already-installed formula (unlike
            # apt/dnf/etc., which are idempotent) — check each one first
            # so a re-run doesn't fail here.
            for pkg in "$@"; do
                if brew list --formula "$pkg" &>/dev/null; then
                    ok "$pkg already installed"
                else
                    brew install "$pkg"
                fi
            done
            ;;
    esac
    substep_done
}

if [ "$PKG_MGR" = "brew" ] && ! command -v brew &>/dev/null; then
    note "Homebrew not found — installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv)"
fi

# A Debian installed from live media keeps its "deb cdrom:" line; apt-get update
# then fails outright (exit 100, "Please use apt-cdrom"). Comment it out — the
# standard first step on such a machine — and say so.
if [ "$PKG_MGR" = "apt-get" ] || [ "$PKG_MGR" = "nala" ]; then
    if grep -qs '^deb cdrom:' /etc/apt/sources.list; then
        note "apt still lists the install CD/DVD as a source — commenting it out (/etc/apt/sources.list) so package updates come from the network"
        sudo sed -i 's/^deb cdrom:/# deb cdrom:/' /etc/apt/sources.list
    fi
    # A Debian installed offline (Calamares) has NO network source at all once the
    # cdrom line is gone — apt "updates" fine and then finds no package. Add the
    # distro's own archive for the running release, and say so.
    if ! grep -rhs '^deb ' /etc/apt/sources.list /etc/apt/sources.list.d/*.list 2>/dev/null | grep -qv 'cdrom:' \
       && ! grep -rhs '^URIs:' /etc/apt/sources.list.d/*.sources 2>/dev/null | grep -q .; then
        _code="$(. /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}")"
        _id="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
        if [ "$_id" = "debian" ] && [ -n "$_code" ]; then
            note "apt has no network source (offline install) — adding the Debian archive for '$_code' (/etc/apt/sources.list.d/debian.list)"
            printf 'deb http://deb.debian.org/debian %s main contrib non-free non-free-firmware\ndeb http://deb.debian.org/debian %s-updates main contrib non-free non-free-firmware\ndeb http://security.debian.org/debian-security %s-security main contrib non-free non-free-firmware\n' "$_code" "$_code" "$_code" | sudo tee /etc/apt/sources.list.d/debian.list >/dev/null
        else
            warn "apt has no network source configured — package installs will fail; add your distro's repository and re-run"
        fi
    fi
fi
# Remote administration: the guest agent inside a VM; an SSH server when an address was given.
SSH_ALLOW="$(pre_get 'Allow SSH from this IP or network (blank = none)')"
if [ "$IN_VM" = 1 ]; then SYS_PACKAGES+=(qemu-guest-agent); note "virtual machine: adding qemu-guest-agent (the host can drive this VM)"; fi
if [ -n "$SSH_ALLOW" ]; then
    case "$PKG_MGR" in pacman) SYS_PACKAGES+=(openssh) ;; *) SYS_PACKAGES+=(openssh-server) ;; esac
    note "remote shell: adding the SSH server (allowed from $SSH_ALLOW only)"
fi
# Desktop essentials the person asked for (only offered when missing — see MISS_*):
# the desktop's own file manager / terminal, and Firefox. Same names on every
# package manager except the browser on zypper.
if [ "$(yn "$(pre_get 'Install a web browser (Firefox)? [Y/n]')")" = yes ] && [ "$MISS_BROWSER" = 1 ]; then SYS_PACKAGES+=("$(desk_browser_pkg)"); note "adding a web browser: $(desk_browser_pkg)"; fi
if [ "$(yn "$(pre_get 'Install a file manager? [Y/n]')")" = yes ] && [ "$MISS_FILES" = 1 ]; then SYS_PACKAGES+=("$(desk_files_pkg)"); note "adding a file manager: $(desk_files_pkg)"; fi
if [ "$(yn "$(pre_get 'Install a terminal? [Y/n]')")" = yes ] && [ "$MISS_TERM" = 1 ]; then SYS_PACKAGES+=("$(desk_term_pkg)"); note "adding a terminal: $(desk_term_pkg)"; fi
note "Updating package index..."
case "$PKG_MGR" in
    nala|apt-get) sudo "$PKG_MGR" update ;;
    # Arch/Manjaro: -Sy alone then -S is a partial upgrade — unsupported, and on a
    # system installed from an older ISO it ends in dependency conflicts (gpgme on
    # the Manjaro VM). Full upgrade first; that is the only supported way.
    pacman)       note "pacman: full system upgrade first (partial upgrades are unsupported on Arch/Manjaro — this can take a while on a fresh install)"; 
                  # Manjaro: an ISO-era mirror list leaves multilib behind core (lib32-libcap vs libcap on the VM) — pick fresh mirrors, then force-sync
                  # keyrings first: a system installed from an older ISO rejects every new package as "unknown trust" (Manjaro VM: 200 signature errors)
                  sudo pacman -Sy --noconfirm archlinux-keyring >/dev/null 2>&1 || true; pacman -Si manjaro-keyring >/dev/null 2>&1 && sudo pacman -Sy --noconfirm manjaro-keyring >/dev/null 2>&1 || true
                  if command -v pacman-mirrors >/dev/null 2>&1; then sudo pacman-mirrors --fasttrack 5 >/dev/null 2>&1 || true; sudo pacman -Syyu --noconfirm; else sudo pacman -Syu --noconfirm; fi ;;
    dnf)          sudo dnf check-update || true ;;   # exits 100 when updates exist — not a real failure
    zypper)       sudo zypper --non-interactive refresh ;;
    apk)          sudo apk update ;;
    brew)         brew update ;;
esac

note "Installing system dependencies..."
# Same functional set on every distro (web server, PHP + the 4 extensions
# the app needs, tmux/jq for the agent sessions, build tools for anything
# that compiles from source) — package *names* differ per distro's repo
# conventions, so each manager gets its own list rather than one shared array.
case "$PKG_MGR" in
    nala|apt-get)
        SYS_PACKAGES=(
            zstd   # Ollama's installer unpacks a zstd tarball; minimal images (WSL) lack it
            apache2 php php-cli php-xml
            php-curl php-mbstring php-zip
            libapache2-mod-php php-sqlite3 sqlite3 inotify-tools tmux jq util-linux curl wget git openssl
            build-essential ca-certificates gnupg zsh ffmpeg pandoc
            imagemagick poppler-utils
            # Explicit even though Debian/Mint ship them in base — a minimal
            # image (or another distro) may not: unzip (files.php zip import),
            # iputils-ping (host reachability check), pciutils (lspci GPU scan).
            unzip iputils-ping pciutils wmctrl
            # WebKitGTK runtime for the native window (scripts/cockpit_shell); fpc
            # only if you want to rebuild it from scripts/cockpit_shell_src.
            libwebkit2gtk-4.1-0 libnotify4 libayatana-appindicator3-1
            # python venv + pip for the LibreTranslate install (Phase 5b).
            python3 python3-venv python3-pip
            # build deps for stable-diffusion.cpp image gen (Phase 5c, Vulkan GPU).
            # ggml-vulkan needs: libvulkan-dev (headers), glslc (shader compiler —
            # glslang-tools alone is NOT enough), and spirv-headers + spirv-tools.
            cmake build-essential libvulkan-dev glslc glslang-tools spirv-headers spirv-tools
            # espeak-ng: Hebrew TTS backend for the Sound button (piper has no he voice).
            espeak-ng
        )
        ;;
    pacman)
        # Arch ships one rolling php package (no per-minor-version split like
        # Debian) — extensions are compiled in or enabled via php.ini, not
        # separate packages, so there's no per-extension package list here.
        SYS_PACKAGES=(
            zstd   # Ollama's installer unpacks a zstd tarball; minimal images (WSL) lack it
            apache php php-apache php-sqlite sqlite inotify-tools tmux jq util-linux curl wget git openssl
            base-devel ca-certificates gnupg zsh ffmpeg pandoc
            imagemagick poppler
            # Arch base is minimal — spell out tools Debian/Mint preinstall:
            # unzip, iputils (ping), pciutils (lspci), which, coreutils
            # (stdbuf/timeout/GNU date used by the agent scripts).
            unzip iputils pciutils which coreutils wmctrl webkit2gtk-4.1 libnotify libayatana-appindicator
            # the setup window (ckdialog) needs GTK 3 — KDE spins may lack it
            gtk3
            # python venv/pip (LibreTranslate, Aider); build deps for whisper.cpp /
            # stable-diffusion.cpp (Vulkan: loader, headers, glslc via shaderc); Piper's Hebrew fallback
            python python-pip cmake vulkan-icd-loader vulkan-headers shaderc espeak-ng
        )
        ;;
    dnf)
        SYS_PACKAGES=(
            zstd   # Ollama's installer unpacks a zstd tarball; minimal images (WSL) lack it
            httpd php php-cli php-xml php-curl php-mbstring php-zip php-pdo php-process sqlite inotify-tools
            tmux jq util-linux curl wget git gcc gcc-c++ make openssl
            ca-certificates gnupg2 zsh ffmpeg pandoc
            ImageMagick poppler-utils
            # Don't assume a Fedora/RHEL minimal has these: unzip, iputils
            # (ping), pciutils (lspci), which, coreutils.
            unzip iputils pciutils which coreutils wmctrl webkit2gtk4.1 libnotify libayatana-appindicator-gtk3
            # python venv/pip (LibreTranslate, Aider); Fedora 44 ships Python 3.14
            python3 python3-pip
            # build deps for whisper.cpp / stable-diffusion.cpp (Vulkan) — the
            # Ubuntu set had these, this one did not: "missing: cmake" (Fedora VM)
            cmake vulkan-loader-devel vulkan-headers glslc glslang spirv-headers-devel spirv-tools
            # semanage for Phase 8b (SELinux) — Workstation has it, minimal installs may not
            policycoreutils-python-utils
            espeak-ng
        )
        ;;
    zypper)
        SYS_PACKAGES=(
            zstd   # Ollama's installer unpacks a zstd tarball; minimal images (WSL) lack it
            apache2 apache2-mod_php8 php8 php8-cli php8-xmlreader php8-curl
            php8-mbstring php8-zip php8-sqlite sqlite3 inotify-tools tmux jq util-linux curl wget git openssl
            gcc gcc-c++ make ca-certificates gpg2 zsh ffmpeg pandoc
            ImageMagick poppler-tools
            # openSUSE minimal safety: unzip, iputils (ping), pciutils (lspci),
            # which, coreutils.
            unzip iputils pciutils which coreutils wmctrl libwebkit2gtk-4_1-0 libnotify4 libayatana-appindicator3-1
            # setup window (GTK 3); python venv/pip; build deps for whisper.cpp / sd.cpp (Vulkan); Piper's Hebrew fallback;
            # SELinux tools (Tumbleweed enforces SELinux now — Phase 8b needs semanage)
            libgtk-3-0 python3 python3-pip cmake vulkan-devel shaderc espeak-ng policycoreutils-python-utils
        )
        ;;
    apk)
        SYS_PACKAGES=(
            zstd   # Ollama's installer unpacks a zstd tarball; minimal images (WSL) lack it
            apache2 php83 php83-apache2 php83-cli php83-xml php83-curl
            php83-mbstring php83-zip php83-sqlite3 sqlite inotify-tools tmux jq util-linux curl wget git openssl
            build-base ca-certificates gnupg zsh ffmpeg pandoc
            imagemagick poppler-utils
            # Alpine ships busybox, not the GNU tools the agent scripts assume —
            # install real coreutils/grep/sed/gawk/findutils so flags behave the
            # same as on Debian, plus unzip, iputils (ping), pciutils, which.
            unzip iputils pciutils which coreutils grep sed gawk findutils wmctrl
        )
        ;;
    brew)
        # coreutils — macOS's BSD date/stat/etc. don't support the GNU flags
        # (`date -Iseconds`, etc.) used elsewhere in this script; installing
        # coreutils alone doesn't shadow the BSD tools (they'd need the
        # g-prefixed names or a PATH change), so anywhere this script uses a
        # GNU-only flag on a distro-independent path is handled with an
        # explicit macOS branch instead of relying on coreutils silently
        # fixing it — same conservative approach the old macOS-only script
        # used. httpd/php/tmux/jq/git/ffmpeg/pandoc match the Linux set;
        # util-linux/build-essential/gnupg/ca-certificates have no meaningful
        # Homebrew equivalent (Xcode Command Line Tools cover build tools,
        # macOS ships its own trust store) so they're simply not needed here.
        # The Linux-only extras (unzip, iputils-ping, which) are all macOS
        # built-ins; lspci has no macOS equivalent (GPU scan degrades to
        # "unknown", which hardware_scan.sh already handles).
        SYS_PACKAGES=(httpd php tmux jq coreutils curl wget git ffmpeg pandoc imagemagick poppler openssl@3 zstd)
        ;;
esac

install_pkgs "${SYS_PACKAGES[@]}"
ok "System packages installed"

# xed (Linux Mint's default text editor) — Debian/Ubuntu family only,
# best-effort, nothing in this script depends on it being present.
if [ "$PKG_MGR" = "nala" ] || [ "$PKG_MGR" = "apt-get" ]; then
    install_pkgs xed 2>/dev/null || true
fi

# Enable + start the web server
note "Enabling ${APACHE_SVC}..."
if [ "$CI_MODE" = "1" ]; then
    note "CI mode — skipping web-server enable/start (no systemd in container)"
elif [ "$PKG_MGR" = "brew" ]; then
    brew services start httpd
else
    sudo systemctl enable "$APACHE_SVC"
    sudo systemctl start "$APACHE_SVC" || true   # may already be running
fi
[ "$CI_MODE" = "1" ] || ok "${APACHE_SVC} enabled and running"
# The GROUP the web server runs with is not always the user's own: openSUSE
# runs wwwrun:www, and the worker's supplementary groups do not include
# "wwwrun" — every directory chowned to group wwwrun was unwritable to it
# (queue empty, prompts never dispatched, Tumbleweed VM). Read it from the
# running process; default to the user name (Debian/Fedora/Arch all match).
APACHE_GROUP="$(ps -eo user=,group= 2>/dev/null | awk -v u="$APACHE_USER" '$1==u{print $2; exit}')"
APACHE_GROUP="${APACHE_GROUP:-$APACHE_USER}"
[ "$APACHE_GROUP" = "$APACHE_USER" ] || note "web server runs as ${APACHE_USER}:${APACHE_GROUP} — shared files use group ${APACHE_GROUP}"

# =============================================================================
# Phase 3 — Node.js LTS (for Claude Code and Gemini CLIs)
# =============================================================================
echo
step "Phase 3 — Node.js ${NODE_MAJOR}.x"
if phase_wanted 'command -v node'; then

if command -v node &>/dev/null && node -v | grep -qE "^v(${NODE_MAJOR}|2[1-9])\."; then
    ok "Node.js $(node -v) already installed (>= ${NODE_MAJOR})"
elif [ "$ONLINE" != "1" ]; then
    warn "Offline — can't install Node.js. Agent CLIs (Claude/Gemini) need it;"
    warn "install Node >= ${NODE_MAJOR} later, then: npm i -g @anthropic-ai/claude-code @google/gemini-cli"
else
    case "$PKG_MGR" in
        nala|apt-get)
            # NodeSource setup script — Debian/Ubuntu's own repo Node is
            # usually too old, this is the only reliable way to get a
            # specific current major version on that family.
            note "Installing Node.js ${NODE_MAJOR}.x via NodeSource..."
            curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
            install_pkgs nodejs
            ;;
        *)
            # Arch/Fedora/openSUSE/Alpine repos generally track a current
            # enough Node already — no NodeSource-equivalent needed there.
            note "Installing Node.js via ${PKG_MGR}..."
            install_pkgs nodejs npm
            ;;
    esac
    ok "Node.js $(node -v) installed"
fi

fi   # phase_wanted
# =============================================================================
# Phase 4 — Agent CLIs
# =============================================================================
echo
step "Phase 4 — Agent CLIs (Claude Code, Gemini, Ollama)"
if phase_wanted '[ -x "$USER_HOME/.npm-global/bin/claude" ] && command -v ollama'; then

# Standardize the global npm prefix first (per-user ~/.npm-global, no sudo) and
# reconcile any pre-existing install in a different prefix on this machine.
setup_npm_prefix

# ── Claude Code ───────────────────────────────────────────────────────────
note "Installing Claude Code CLI..."
if [ -x "${NPM_PREFIX_TARGET}/bin/claude" ]; then
    ok "claude already installed: $(as_user "${NPM_PREFIX_TARGET}/bin/claude" --version 2>/dev/null || echo present)"
else
    npm_i @anthropic-ai/claude-code
    ok "Claude Code CLI installed → ${NPM_PREFIX_TARGET}/bin/claude"
fi
# The npm package is a launcher; the platform binary arrives through its
# postinstall. When that did not run (Manjaro VM: "claude native binary not
# installed"), run the package's own installer once.
if [ -x "${NPM_PREFIX_TARGET}/bin/claude" ] && ! as_user "${NPM_PREFIX_TARGET}/bin/claude" --version >/dev/null 2>&1; then
    note "claude's platform binary is missing (postinstall did not run) — fetching it..."
    as_user node "${NPM_PREFIX_TARGET}/lib/node_modules/@anthropic-ai/claude-code/install.cjs" >/dev/null 2>&1 \
      && ok "claude: $(as_user "${NPM_PREFIX_TARGET}/bin/claude" --version 2>/dev/null)" \
      || warn "claude still cannot start — run: node ${NPM_PREFIX_TARGET}/lib/node_modules/@anthropic-ai/claude-code/install.cjs"
fi

# ── Gemini ────────────────────────────────────────────────────────────────
note "Installing Gemini CLI..."
if [ -x "${NPM_PREFIX_TARGET}/bin/gemini" ]; then
    ok "gemini already installed: $(as_user "${NPM_PREFIX_TARGET}/bin/gemini" --version 2>/dev/null || echo present)"
else
    npm_i @google/gemini-cli
    ok "Gemini CLI installed → ${NPM_PREFIX_TARGET}/bin/gemini"
fi

# ── Codex CLI (optional — Card 1 supports it, but it's not a default) ──────
if [ -x "${NPM_PREFIX_TARGET}/bin/codex" ]; then
    ok "codex already installed"
else
    note "Optional extra AI CLI. Cockpit already installed Claude + Gemini (enough to"
    note "start). Codex is an alternative for the coding card — only if you use OpenAI."
    # Card 2 defaults to Codex in the app; a "no" here left a dead card on the first VM install
    if confirm "Also install OpenAI Codex CLI? (Card 2 uses it by default; small npm download)" "y"; then
        npm_i @openai/codex
        ok "Codex CLI installed"
    else
        note "Skipped — install later with: npm install -g @openai/codex"
    fi
fi

# ── Qwen Code CLI (optional — Card 1 supports it, but it's not a default) ──
if [ -x "${NPM_PREFIX_TARGET}/bin/qwen" ]; then
    ok "qwen already installed"
else
    note "Another optional coding CLI (Alibaba's Qwen). Same idea as Codex — skip"
    note "unless you specifically want it. Claude + Gemini already cover the basics."
    if confirm "Also install Qwen Code CLI? (extra download, optional)" "n"; then
        npm_i @qwen-code/qwen-code
        ok "Qwen Code CLI installed"
    else
        note "Skipped — install later with: npm install -g @qwen-code/qwen-code"
    fi
fi

# ── whisper.cpp (optional — Tools card, offline voice transcription) ───────
# Real cost to say yes here: a source compile + a multi-GB model download on
# Linux (no simple package — see SETUP_GUIDE.html's own manual steps, which
# this mirrors exactly), so it stays opt-in on every OS, not just Linux.
if command -v whisper-cli &>/dev/null || command -v whisper &>/dev/null; then
    ok "whisper already installed"
else
    note "Optional: local speech-to-text (turn audio/voice into text, offline) for the"
    note "Tools card. Heavy — it COMPILES from source + downloads a multi-GB model, so"
    note "it's slow to set up. Skip unless you need transcription; you can add it later."
fi
if command -v whisper-cli &>/dev/null || command -v whisper &>/dev/null; then
    : # already handled above
elif confirm "Install whisper.cpp for offline voice transcription? (slow build, optional)" "n"; then
    if [ "$IS_MACOS" = "1" ]; then
        note "Installing whisper.cpp (Homebrew, Metal build)..."
        install_pkgs whisper-cpp
        ok "whisper.cpp installed"
    else
        note "Building whisper.cpp from source (same steps as the Setup Guide)..."
        install_pkgs cmake
        # ai-tools/, not $HOME directly: this phase's own completion check (comp 5e)
        # and transcriber.php both read ~/ai-tools/whisper.cpp, so building into
        # ~/whisper.cpp left the installer reporting its own work as missing and
        # voice input finding nothing. One location, agreed by everyone.
        WHISPER_DIR="${USER_HOME}/ai-tools/whisper.cpp"
        as_user mkdir -p "${USER_HOME}/ai-tools"
        if [ -d "${USER_HOME}/whisper.cpp" ] && [ ! -d "$WHISPER_DIR" ]; then
            note "moving an earlier ~/whisper.cpp build into ai-tools/"
            as_user mv "${USER_HOME}/whisper.cpp" "$WHISPER_DIR"
        fi
        if [ -d "$WHISPER_DIR" ]; then
            note "~/ai-tools/whisper.cpp already exists — skipping clone, rebuilding in place"
        else
            substep "git clone whisper.cpp"
            as_user git clone https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
            substep_done
        fi
        substep "build whisper.cpp"
        (cd "$WHISPER_DIR" && cmake -B build && cmake --build build -j --config Release)
        substep_done
        # Download the model the USER picked, not a fixed large one. This block
        # used to pull large-v3-turbo unconditionally while Phase 5e asked "base=
        # fast, small/medium=better" and defaulted to base -- so someone who chose
        # "base - fast" still ended up running large, because transcribe.php
        # resolves "auto" as largest-installed-wins. Measured 2026-09-25:
        # large-v3-turbo transcribes at 1.17x realtime here, i.e. a 16s utterance
        # costs 18.8s, which lands straight on Intercom's critical path.
        _wh_model="$(pre_get 'Whisper model (base=fast, small/medium=better)')"
        [ -n "$_wh_model" ] || _wh_model="base"
        note "Downloading whisper model: ggml-${_wh_model}.bin (your choice; larger = better but slower)"
        (cd "$WHISPER_DIR" && ./models/download-ggml-model.sh "$_wh_model")
        # Web tier (Apache/httpd user) must be able to read the binary + model.
        chmod -R a+rX "$WHISPER_DIR"
        ok "whisper.cpp built and model downloaded"
    fi
else
    note "Skipped — see the Setup Guide's 'whisper.cpp + a model' section to add it later"
fi

# ── yt-dlp (optional — Tools card, media download) ──────────────────────────
if command -v yt-dlp &>/dev/null; then
    ok "yt-dlp already installed"
else
    note "Optional: a media downloader (YouTube etc.) used by the Tools card. Small,"
    note "quick. Only useful if you'll download media in the app — otherwise skip."
fi
if command -v yt-dlp &>/dev/null; then
    : # handled above
elif confirm "Install yt-dlp media downloader? (optional)" "n"; then
    # The plain "yt-dlp" asset is a ZIPAPP -- it still needs a Python interpreter on
    # the host. The platform assets (yt-dlp_linux, _aarch64, _musllinux, _macos) are
    # SELF-CONTAINED: Python is bundled inside, nothing is required on the machine.
    # Switched 2026-09-24 so the Transcriber stops depending on system Python.
    # `yt-dlp -U` still works on these builds, which is what keeps it current --
    # and staying current is the whole reason yt-dlp is used rather than a distro
    # package that YouTube breaks within months.
    if [ "$IS_MACOS" = "1" ]; then _yta="yt-dlp_macos"
    else
        case "$(uname -m)" in
            aarch64|arm64) _yta="yt-dlp_linux_aarch64" ;;
            armv7l)        _yta="yt-dlp_linux_armv7l.zip" ;;
            *)             if ldd /bin/sh 2>/dev/null | grep -q musl; then _yta="yt-dlp_musllinux"; else _yta="yt-dlp_linux"; fi ;;
        esac
    fi
    _ytd="$(mktemp)"; fetch_mirror "https://github.com/yt-dlp/yt-dlp/releases/latest/download/${_yta}" "$_ytd" "$_yta" && sudo install -m 0755 "$_ytd" /usr/local/bin/yt-dlp; rm -f "$_ytd"
    sudo chmod a+rx /usr/local/bin/yt-dlp
    ok "yt-dlp installed"
else
    note "Skipped — install later (self-contained build, no Python needed):"
    note "  sudo curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux -o /usr/local/bin/yt-dlp && sudo chmod a+rx /usr/local/bin/yt-dlp"
fi

# ── Ollama ────────────────────────────────────────────────────────────────
note "Installing Ollama..."
OLLAMA_PRESENT=1
if command -v ollama &>/dev/null; then
    ok "ollama already installed: $(ollama --version 2>/dev/null | head -1)"
elif [ "$CI_MODE" = "1" ]; then
    OLLAMA_PRESENT=0
    note "CI mode — skipping Ollama install (needs systemd; not tested in container)"
elif [ "$ONLINE" != "1" ]; then
    OLLAMA_PRESENT=0
    warn "Offline — skipping Ollama install. Local models (Cards) won't work until"
    warn "you install Ollama (https://ollama.com) and pull a model."
elif [ "$IS_MACOS" = "1" ]; then
    install_pkgs ollama
    ok "Ollama installed"
else
    # Official install script — pure bash, no Python
    substep "install ollama runtime"
    curl -fsSL https://ollama.com/install.sh | sh
    substep_done
    ok "Ollama installed"
fi

# Model location: use Ollama's OWN DEFAULT dir — don't impose a custom path.
# If this machine already has a custom OLLAMA_MODELS pointing elsewhere, tell the
# user (Cockpit doesn't need a custom path) and let them reset or continue.
if ! command -v ollama &>/dev/null; then
    note "Ollama not installed (offline) — skipping model-location config."
else
if [ "$IS_MACOS" = "1" ]; then
    OLLAMA_DEFAULT_DIR="${USER_HOME}/.ollama/models"     # ollama app runs as the user
else
    OLLAMA_DEFAULT_DIR="/usr/share/ollama/.ollama/models" # systemd 'ollama' service user
fi
# Detect any pre-existing custom override (env / systemd / launchd / rc).
OLLAMA_CUSTOM=""
_e="$(printenv OLLAMA_MODELS 2>/dev/null || true)"; [ -n "$_e" ] && OLLAMA_CUSTOM="$_e" || true
if [ "$IS_MACOS" = "1" ]; then
    _l="$(launchctl getenv OLLAMA_MODELS 2>/dev/null || true)"; [ -n "$_l" ] && OLLAMA_CUSTOM="$_l" || true
else
    # grep returns 2 when the override dir is absent (the normal fresh-install
    # case) and 1 on no-match — with set -o pipefail + set -e that would kill the
    # script, so each detection pipeline ends in `|| true`.
    _ov="$(grep -rhoE 'OLLAMA_MODELS=[^"]+' /etc/systemd/system/ollama.service.d/ 2>/dev/null | head -1 | cut -d= -f2- || true)"
    [ -n "$_ov" ] && OLLAMA_CUSTOM="$_ov" || true
    _sv="$(systemctl show ollama -p Environment 2>/dev/null | tr ' ' '\n' | grep -oE 'OLLAMA_MODELS=[^ ]+' | head -1 | cut -d= -f2- || true)"
    [ -n "$_sv" ] && OLLAMA_CUSTOM="$_sv" || true
fi

if [ -n "$OLLAMA_CUSTOM" ] && [ "$OLLAMA_CUSTOM" != "$OLLAMA_DEFAULT_DIR" ]; then
    warn "Ollama already uses a CUSTOM models location on this machine:"
    warn "    $OLLAMA_CUSTOM"
    warn "Cockpit uses each supplier's DEFAULT location instead:"
    warn "    $OLLAMA_DEFAULT_DIR"
    note "To move to the default: stop & uninstall Ollama and remove the override —"
    if [ "$IS_MACOS" = "1" ]; then
        note "  launchctl unsetenv OLLAMA_MODELS ; remove any OLLAMA_MODELS line in ~/.zshrc"
    else
        note "  sudo rm /etc/systemd/system/ollama.service.d/*.conf ; remove OLLAMA_MODELS"
        note "  lines in ~/.profile / ~/.zshrc ; then: sudo systemctl daemon-reload"
    fi
    note "…then re-run this installer. Or keep using the custom location for now."
    if ! confirm "Keep the existing custom location and continue?" "y"; then
        fatal "Exiting so you can reset Ollama to its default location, then re-run."
    fi
    OLLAMA_MODELS_DIR="$OLLAMA_CUSTOM"
else
    OLLAMA_MODELS_DIR="$OLLAMA_DEFAULT_DIR"
    note "Ollama models: default location ($OLLAMA_MODELS_DIR) — no override set"
fi

# Make sure the daemon is up (Linux: enable the service; the ollama user already
# owns its default dir, so no chown/group dance is needed for the default path).
if [ "$CI_MODE" = "1" ]; then
    note "CI mode — skipping Ollama service start + readiness wait"
else
    if [ "$IS_MACOS" != "1" ]; then
        sudo systemctl enable --now ollama 2>/dev/null || sudo systemctl restart ollama 2>/dev/null || true
    fi
    for i in $(seq 1 30); do
        curl -sf http://127.0.0.1:11434/ >/dev/null 2>&1 && break
        sleep 1
    done
    ok "Ollama ready — models at $OLLAMA_MODELS_DIR"
fi
fi   # end: ollama present

fi   # phase_wanted
# =============================================================================
# Phase 5 — LocalAI (dual-mode combos/chat need this actually running)
# =============================================================================
echo
# Hardware first: the model offers below (LocalAI here, Ollama in Phase 6) size
# themselves by it. It used to be detected only in Phase 6, so a 6 GB VM with no
# GPU was offered five "fits 4GB VRAM" LocalAI models with Enter = all of them.
detect_hardware
tele_build_meta
ok "CPU       : ${HW_CPU_MODEL:-unknown} (${HW_CPU_CORES} cores)"
ok "Memory    : ${HW_RAM_MB} MB RAM"
ok "GPU       : ${HW_GPU_NAME:-unknown}$([ "${HW_VRAM_MB:-0}" -gt 0 ] && echo " · ${HW_VRAM_MB} MB VRAM")"
[ "$HW_TIER" = "low" ] && warn "Only ~${HW_BUDGET_MB} MB memory budget (no/low discrete VRAM) — local models will be slow here; the model offers below default to none."
echo
step "Phase 5 — LocalAI"
if phase_wanted '[ -x "$USER_HOME/.local/bin/local-ai" ]'; then

if command -v local-ai &>/dev/null; then
    ok "local-ai already installed: $(local-ai --version 2>/dev/null | head -1)"
elif [ "$CI_MODE" = "1" ]; then
    note "CI mode — skipping LocalAI install (needs systemd; not tested in container)"
elif [ "$ONLINE" != "1" ]; then
    warn "Offline — skipping LocalAI download. Dual-mode combos/chat need it;"
    warn "install later from https://localai.io, then re-run."
else
    note "Installing LocalAI v${LOCALAI_VERSION}..."
    if [ "$IS_MACOS" = "1" ]; then
        # Same arm64-only constraint as cockpit_auth — checked earlier in
        # Pre-flight, so by this point we know we're on Apple Silicon.
        ARCH="arm64"
    else
        ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    fi
    case "$ARCH" in
        amd64|x86_64)
            LOCALAI_ASSET="local-ai-v${LOCALAI_VERSION}-linux-amd64"
            LOCALAI_SHA256="2a4ccf4cd7ecc76fb6dde8d847a6d1448b67d7cf84fdcb4285cd002f42a9c801"
            ;;
        arm64|aarch64)
            if [ "$IS_MACOS" = "1" ]; then
                LOCALAI_ASSET="local-ai-v${LOCALAI_VERSION}-darwin-arm64"
                LOCALAI_SHA256="83f8823714e1269284b7db7f71d786d45df09afa31d281f1d6035d20d5ba42f0"
            else
                LOCALAI_ASSET="local-ai-v${LOCALAI_VERSION}-linux-arm64"
                LOCALAI_SHA256="6cb39eb765ca005aad6ad3e4c34197406d46f5b7700c5c9a8c543b35847db553"
            fi
            ;;
        *)
            warn "Unrecognized architecture '$ARCH' — skipping LocalAI install. Dual-mode combos/chat need LocalAI, install it manually: https://localai.io"
            LOCALAI_ASSET=""
            ;;
    esac
    if [ -n "$LOCALAI_ASSET" ]; then
        LOCALAI_TMP="$(mktemp -d "${TMPDIR:-/tmp}/localai_dl_XXXXXX")"
        LOCALAI_URL="https://github.com/mudler/LocalAI/releases/download/v${LOCALAI_VERSION}/${LOCALAI_ASSET}"
        if fetch_mirror "$LOCALAI_URL" "$LOCALAI_TMP/local-ai" "$LOCALAI_ASSET"; then
            LOCALAI_GOT_SHA="$(sha256 "$LOCALAI_TMP/local-ai" | cut -d' ' -f1)"
            if [ "$LOCALAI_GOT_SHA" = "$LOCALAI_SHA256" ]; then
                if [ "$IS_MACOS" = "1" ]; then
                    mkdir -p "${USER_HOME}/.local/bin"
                    cp "$LOCALAI_TMP/local-ai" "${USER_HOME}/.local/bin/local-ai"
                    chmod +x "${USER_HOME}/.local/bin/local-ai"
                else
                    sudo -u "$COCKPIT_USER" mkdir -p "${USER_HOME}/.local/bin"
                    sudo -u "$COCKPIT_USER" cp "$LOCALAI_TMP/local-ai" "${USER_HOME}/.local/bin/local-ai"
                    sudo -u "$COCKPIT_USER" chmod +x "${USER_HOME}/.local/bin/local-ai"
                fi
                ok "LocalAI installed to ${USER_HOME}/.local/bin/local-ai"
            else
                warn "LocalAI download checksum mismatch (got $LOCALAI_GOT_SHA, expected $LOCALAI_SHA256) — skipping install. Dual-mode combos/chat won't work until this is installed manually."
            fi
        else
            warn "LocalAI download failed — skipping. Dual-mode combos/chat won't work until this is installed manually."
        fi
        rm -rf "$LOCALAI_TMP"
    fi
fi

if [ -x "${USER_HOME}/.local/bin/local-ai" ]; then
    note "Configuring LocalAI models/data/backends under ${USER_HOME}/localai/"
    if [ "$IS_MACOS" = "1" ]; then
        mkdir -p "$LOCALAI_MODELS_DIR" "$LOCALAI_DATA_DIR" "$LOCALAI_BACKENDS_DIR"
    else
        sudo -u "$COCKPIT_USER" mkdir -p "$LOCALAI_MODELS_DIR" "$LOCALAI_DATA_DIR" "$LOCALAI_BACKENDS_DIR"
    fi

    # LocalAI's --data-path/--backends-path/--models-path default to CWD-
    # relative paths (confirmed the hard way: under systemd, with no
    # WorkingDirectory set, CWD is "/" and it tries `mkdir //data` and fails
    # with a permission error). Every path is set explicitly here so it never
    # depends on the caller's CWD.
    if [ "$IS_MACOS" = "1" ]; then
        # No systemd on macOS — and local-ai isn't a Homebrew formula with
        # its own `brew services` entry, so this launchd plist has to launch
        # the binary itself directly (unlike Ollama's tiny env-only plist).
        LOCALAI_PLIST="${USER_HOME}/Library/LaunchAgents/com.cockpit.localai.plist"
        mkdir -p "${USER_HOME}/Library/LaunchAgents"
        cat > "$LOCALAI_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.cockpit.localai</string>
    <key>ProgramArguments</key>
    <array>
        <string>${USER_HOME}/.local/bin/local-ai</string>
        <string>run</string>
        <string>--address</string>
        <string>127.0.0.1:8080</string>
    </array>
    <key>WorkingDirectory</key><string>${USER_HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LOCALAI_MODELS_PATH</key><string>${LOCALAI_MODELS_DIR}</string>
        <key>LOCALAI_DATA_PATH</key><string>${LOCALAI_DATA_DIR}</string>
        <key>LOCALAI_BACKENDS_PATH</key><string>${LOCALAI_BACKENDS_DIR}</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>${USER_HOME}/localai/launchd.log</string>
    <key>StandardErrorPath</key><string>${USER_HOME}/localai/launchd.log</string>
</dict>
</plist>
EOF
        launchctl unload "$LOCALAI_PLIST" 2>/dev/null || true
        launchctl load "$LOCALAI_PLIST"
    else
        sudo tee /etc/systemd/system/localai.service >/dev/null <<EOF
[Unit]
Description=LocalAI Service
After=network-online.target

[Service]
WorkingDirectory=${USER_HOME}
ExecStart=${USER_HOME}/.local/bin/local-ai run --address 127.0.0.1:8080
Environment="LOCALAI_MODELS_PATH=${LOCALAI_MODELS_DIR}"
Environment="LOCALAI_DATA_PATH=${LOCALAI_DATA_DIR}"
Environment="LOCALAI_BACKENDS_PATH=${LOCALAI_BACKENDS_DIR}"
User=${COCKPIT_USER}
Group=${COCKPIT_USER}
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
        if [ "$CI_MODE" = "1" ]; then
            note "CI mode — skipping LocalAI service start"
        else
            sudo systemctl daemon-reload
            sudo systemctl enable --now localai
        fi
    fi
    if [ "$CI_MODE" != "1" ]; then
        for i in $(seq 1 30); do
            curl -sf http://127.0.0.1:8080/ >/dev/null 2>&1 && break
            sleep 1
        done
    fi
    ok "LocalAI configured to use ${USER_HOME}/localai/"

    echo
    note "Suggested LocalAI models (recommended — LocalAI equivalents of the Ollama set above,"
    note "same job, same size class, run through LocalAI's llama.cpp backend instead):"
    for i in "${!DEFAULT_LOCALAI_MODELS[@]}"; do
        echo "    $((i+1)). ${DEFAULT_LOCALAI_MODELS[$i]}"
        echo "       ${DEFAULT_LOCALAI_MODELS_DESC[$i]}"
    done
    echo
    echo "  Press Enter to pull all of the above (recommended — this is what Dual Mode"
    echo "  and dual-supplier Combos on Card 3 need to actually have both backends loaded),"
    echo "  or enter numbers separated by spaces for just those, or 'none' to skip,"
    echo "  or type gallery model ids yourself."
    echo
    if [ "$UNATTENDED" = "1" ]; then
        # Same conservative default as the Ollama model pull above — CI
        # shouldn't download multi-GB models on every run.
        LOCALAI_MODEL_INPUT="${COCKPIT_UNATTENDED_LOCALAI_MODEL:-none}"
        note "LocalAI models to pull: $LOCALAI_MODEL_INPUT (unattended)"
    else
        # no usable GPU → Enter = none (a CPU-only box should not download 10 GB by default)
        ask LOCALAI_MODEL_INPUT "LocalAI models to pull (numbers, names, or 'none')" "$([ "$HW_NOGPU" = "1" ] && echo none || echo all)"
    fi
    LOCALAI_MODELS_TO_PULL=()
    if [ "$LOCALAI_MODEL_INPUT" = "all" ] || { [ -z "$LOCALAI_MODEL_INPUT" ] && [ "$UNATTENDED" != "1" ]; }; then
        LOCALAI_MODELS_TO_PULL=("${DEFAULT_LOCALAI_MODELS[@]}")
    elif [ -z "$LOCALAI_MODEL_INPUT" ] || [ "$LOCALAI_MODEL_INPUT" = "none" ]; then
        LOCALAI_MODELS_TO_PULL=()
    else
        for token in $LOCALAI_MODEL_INPUT; do
            if [[ "$token" =~ ^[0-9]+$ ]]; then
                idx=$((token - 1))
                if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DEFAULT_LOCALAI_MODELS[@]}" ]; then
                    LOCALAI_MODELS_TO_PULL+=("${DEFAULT_LOCALAI_MODELS[$idx]}")
                else
                    warn "Index $token out of range — skipping"
                fi
            else
                LOCALAI_MODELS_TO_PULL+=("$token")
            fi
        done
    fi

    if [ "$ONLINE" != "1" ]; then
        note "Offline — skipping LocalAI model pulls (fetch later from the Card 3 model manager)."
    elif [ "${#LOCALAI_MODELS_TO_PULL[@]}" -eq 0 ]; then
        note "Skipping LocalAI model pull (browse http://127.0.0.1:8080/models/available or use the Marketplace/Card 3 model manager later)"
    else
        for model in "${LOCALAI_MODELS_TO_PULL[@]}"; do
            # gallery ids drift between LocalAI releases (three of five had vanished
            # by 4.7): check the id exists before asking, so the person reads why
            if ! curl -sf http://127.0.0.1:8080/models/available 2>/dev/null | grep -q "\"name\":\"${model%%:*}\""; then
                warn "$model is not in this LocalAI's gallery any more — browse http://127.0.0.1:8080/models/available and pull a current equivalent from Card 3"; continue
            fi
            note "Requesting $model ..."
            LOCALAI_JOB=$(curl -sf -X POST http://127.0.0.1:8080/models/apply \
                -H "Content-Type: application/json" \
                -d "{\"id\":\"${model}\"}" | grep -o '"uuid":"[^"]*"' | cut -d'"' -f4 || true)   # pipefail: a refused apply must not kill the run
            if [ -n "$LOCALAI_JOB" ]; then
                LOCALAI_DONE=""
                for i in $(seq 1 120); do
                    LOCALAI_DONE=$(curl -sf "http://127.0.0.1:8080/models/jobs/${LOCALAI_JOB}" | grep -o '"processed":[a-z]*' | cut -d: -f2 || true)
                    [ "$LOCALAI_DONE" = "true" ] && break
                    sleep 5
                done
                # processed:true also covers "finished with an error" — read the job's
                # error field (4 of 5 gallery pulls failed silently on the Ubuntu VM)
                LOCALAI_ERR=$(curl -sf "http://127.0.0.1:8080/models/jobs/${LOCALAI_JOB}" | grep -o '"error":"[^"]*"' | cut -d'"' -f4 || true)
                if [ "$LOCALAI_DONE" = "true" ] && [ -n "$LOCALAI_ERR" ] && [ "$LOCALAI_ERR" != "null" ]; then
                    warn "$model: ${LOCALAI_ERR:0:160}"
                elif [ "$LOCALAI_DONE" = "true" ]; then
                    ok "$model"
                else
                    warn "Timed out waiting for $model — check http://127.0.0.1:8080/models/available and pull it later if needed"
                fi
            else
                warn "Failed to start the pull for $model — gallery id may not match this LocalAI version. Browse http://127.0.0.1:8080/models/available for the exact id and pull it later if needed"
            fi
        done
    fi
else
    warn "LocalAI binary not found — dual-mode combos/chat (Card 3 'Dual — Ollama + LocalAI') won't work until it's installed manually."
fi

fi   # phase_wanted
# =============================================================================
# Phase 5b — LibreTranslate (offline backend for the Translate-chat button, :5000)
# =============================================================================
echo
step "Phase 5b — LibreTranslate (Translate chat)"
if phase_wanted '[ -d "$USER_HOME/libretranslate" ]'; then
if [ "${CI_MODE:-0}" = "1" ]; then
    note "CI mode — skipping LibreTranslate."
else
    _LT_DEFAULT_LANGS="en"
    _sys_lang="$(printf '%s' "${LANG:-}" | cut -d_ -f1)"
    [ -n "$_sys_lang" ] && [ "$_sys_lang" != "en" ] && _LT_DEFAULT_LANGS="en,$_sys_lang"
    if [ "$UNATTENDED" = "1" ]; then
        _LT_DO="${COCKPIT_INSTALL_LIBRETRANSLATE:-y}"
    else
        ask _LT_DO "Install LibreTranslate for offline chat translation? (y/n)" "y"
    fi
    if [ "$(lc "$_LT_DO")" = "y" ] || [ "$(lc "$_LT_DO")" = "yes" ]; then
        if [ "$UNATTENDED" = "1" ]; then _LT_LANGS="${COCKPIT_LIBRETRANSLATE_LANGS:-$_LT_DEFAULT_LANGS}"; else
            ask _LT_LANGS "Languages to load (comma-separated)" "$_LT_DEFAULT_LANGS"
        fi
        _LT_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_libretranslate.sh"
        if [ -f "$_LT_SH" ]; then
            note "Installing LibreTranslate (Python venv + models: ${_LT_LANGS}) — a few hundred MB…"
            as_user env LT_LANGS="$_LT_LANGS" SCRIPTS_DIR="$USER_HOME/scripts" bash "$_LT_SH" --langs "$_LT_LANGS" \
                || warn "LibreTranslate install had issues — Translate stays unavailable until :5000 is up."
        else
            warn "install_libretranslate.sh not found next to the installer — skipping."
        fi
    else
        note "Skipped. Translate chat needs a LibreTranslate on :5000 (set paths.json 'libretranslate')."
    fi
fi

fi   # phase_wanted
# =============================================================================
# Phase 5c — stable-diffusion.cpp (local image generation)
# =============================================================================
echo
step "Phase 5c — Local image generation (stable-diffusion.cpp)"
if phase_wanted '[ -d "$USER_HOME/ai-tools/stable-diffusion.cpp" ]'; then
if [ "${CI_MODE:-0}" = "1" ] || [ "$IS_MACOS" = "1" ]; then
    note "Skipped (CI or macOS)."
else
    if [ "$UNATTENDED" = "1" ]; then _SD_DO="${COCKPIT_INSTALL_SD:-n}"; else
        ask _SD_DO "Build local image generation (stable-diffusion.cpp + ~4GB model)? (y/n)" "n"
    fi
    if [ "$(lc "$_SD_DO")" = "y" ] || [ "$(lc "$_SD_DO")" = "yes" ]; then
        _SD_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_stable_diffusion.sh"
        if [ -f "$_SD_SH" ]; then
            note "Building stable-diffusion.cpp (Vulkan GPU, CPU fallback) + downloading a model…"
            as_user bash "$_SD_SH" || warn "Image-gen build had issues — see ~/ai-tools/sd.cpp/build.log."
        else
            warn "install_stable_diffusion.sh not found next to the installer — skipping."
        fi
    else
        note "Skipped. Build later: Installs/install_stable_diffusion.sh (needs libvulkan-dev glslang-tools)."
    fi
fi

fi   # phase_wanted
# =============================================================================
# Phase 5d — Piper TTS (Sound button → Speech)
# =============================================================================
echo
step "Phase 5d — Local text-to-speech (Piper)"
if phase_wanted '[ -d "$USER_HOME/ai-tools/piper" ]'; then
if [ "${CI_MODE:-0}" = "1" ] || [ "$IS_MACOS" = "1" ]; then
    note "Skipped (CI or macOS)."
else
    if [ "$UNATTENDED" = "1" ]; then _TTS_DO="${COCKPIT_INSTALL_PIPER:-y}"; else
        ask _TTS_DO "Install Piper text-to-speech for the Sound button? (y/n)" "y"
    fi
    if [ "$(lc "$_TTS_DO")" = "y" ] || [ "$(lc "$_TTS_DO")" = "yes" ]; then
        if [ "$UNATTENDED" = "1" ]; then _TTS_V="${COCKPIT_PIPER_VOICES:-en,es,he}"; else
            ask _TTS_V "Voices to install (en,es,he supported)" "en,es,he"
        fi
        _TTS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_piper.sh"
        if [ -f "$_TTS_SH" ]; then
            note "Installing Piper + voices (${_TTS_V})…"
            as_user bash "$_TTS_SH" --voices "$_TTS_V" || warn "Piper install had issues."
        else
            warn "install_piper.sh not found next to the installer — skipping."
        fi
    else
        note "Skipped. Speech needs piper in ~/ai-tools/piper (Installs/install_piper.sh)."
    fi
fi

fi   # phase_wanted
# =============================================================================
# Phase 5e — whisper.cpp (Transcriber: local video/audio → SRT)
# =============================================================================
echo
step "Phase 5e — Local speech-to-text (whisper.cpp)"
if phase_wanted '[ -x "$USER_HOME/ai-tools/whisper.cpp/build/bin/whisper-cli" ]'; then
if [ "${CI_MODE:-0}" = "1" ] || [ "$IS_MACOS" = "1" ]; then
    note "Skipped (CI or macOS)."
else
    if [ "$UNATTENDED" = "1" ]; then _WH_DO="${COCKPIT_INSTALL_WHISPER:-y}"; else
        ask _WH_DO "Build whisper.cpp for local video transcription (Transcriber SRT)? (y/n)" "y"
    fi
    if [ "$(lc "$_WH_DO")" = "y" ] || [ "$(lc "$_WH_DO")" = "yes" ]; then
        if [ "$UNATTENDED" = "1" ]; then _WH_M="${COCKPIT_WHISPER_MODEL:-base}"; else
            ask _WH_M "Whisper model (base=fast, small/medium=better)" "base"
        fi
        _WH_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_whisper.sh"
        if [ -f "$_WH_SH" ]; then
            note "Building whisper.cpp (Vulkan, CPU fallback) + ggml-${_WH_M} model…"
            as_user bash "$_WH_SH" --model "$_WH_M" || warn "whisper build had issues — see ~/ai-tools/whisper.cpp/build.log."
        else
            warn "install_whisper.sh not found next to the installer — skipping."
        fi
    else
        note "Skipped. Local-file transcription needs Installs/install_whisper.sh."
    fi
fi

fi   # phase_wanted
# =============================================================================
# Phase 5f — Aider (free local Agent-CLI, isolated venv)
# =============================================================================
step "Phase 5f — Aider (free local coding agent)"
if phase_wanted '[ -x "$USER_HOME/.local/bin/aider" ]'; then
if [ "${CI_MODE:-0}" = "1" ]; then
    note "Skipped (CI)."
else
    if [ "$UNATTENDED" = "1" ]; then _AID_DO="${COCKPIT_INSTALL_AIDER:-y}"; else
        ask _AID_DO "Install Aider (free open-source agent — runs on your local Ollama models, no key)? (y/n)" "y"
    fi
    if [ "$(lc "$_AID_DO")" = "y" ] || [ "$(lc "$_AID_DO")" = "yes" ]; then
        _AID_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_aider.sh"
        if [ -f "$_AID_SH" ]; then
            note "Installing Aider in an isolated venv (no system Python changes)…"
            as_user env HOME="$USER_HOME" bash "$_AID_SH" || warn "Aider install had issues — you can re-run Installs/install_aider.sh later."
        else
            warn "install_aider.sh not found next to the installer — skipping."
        fi
    else
        note "Skipped. Enable later with Installs/install_aider.sh (needed for the 'Stay Free' Aider card)."
    fi
fi

fi   # phase_wanted
# =============================================================================
# Phase 5g/5h — Goose + opencode (free local Agent-CLIs; Rust/Go, no Python)
# =============================================================================
step "Phase 5g — Goose + opencode (free local agents, optional)"
if phase_wanted '[ -x "$USER_HOME/.local/bin/goose" ] || [ -x "$USER_HOME/.local/bin/opencode" ]'; then
if [ "${CI_MODE:-0}" = "1" ]; then
    note "Skipped (CI)."
else
    if [ "$UNATTENDED" = "1" ]; then _EXTRA_DO="${COCKPIT_INSTALL_EXTRA_AGENTS:-n}"; else
        ask _EXTRA_DO "Also install Goose and opencode (extra free local agents, no Python)? (y/n)" "n"
    fi
    if [ "$(lc "$_EXTRA_DO")" = "y" ] || [ "$(lc "$_EXTRA_DO")" = "yes" ]; then
        _HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        for _agent in goose opencode; do
            _SH="$_HERE/install_${_agent}.sh"
            if [ -f "$_SH" ]; then
                note "Installing ${_agent} (isolated binary on ~/.local/bin)…"
                as_user env HOME="$USER_HOME" bash "$_SH" || warn "${_agent} install had issues — re-run Installs/install_${_agent}.sh later."
            else
                warn "install_${_agent}.sh not found next to the installer — skipping ${_agent}."
            fi
        done
    else
        note "Skipped. Enable later with Installs/install_goose.sh / install_opencode.sh."
    fi
fi

fi   # phase_wanted
# =============================================================================
# Phase 5h — LaTeX system for the Academic paper tools (optional; recommended by default)
# =============================================================================
step "Phase 5h — LaTeX (Academic paper tools)"
if [ "${CI_MODE:-0}" = "1" ]; then
    note "Skipped (CI)."
else
    if [ "$UNATTENDED" = "1" ]; then _TEX_DO="${COCKPIT_INSTALL_TEX:-recommended}"; else
        ask _TEX_DO "LaTeX system for the Academic paper tools (none, recommended, full)" "recommended"
    fi
    _TEX_DO="$(lc "$_TEX_DO")"
    case "$_TEX_DO" in none|recommended|full) ;; y|yes) _TEX_DO=recommended ;; n|no) _TEX_DO=none ;; *) _TEX_DO=recommended ;; esac
    if [ "$_TEX_DO" = "none" ]; then
        note "Skipped. Add it later with: bash Installs/install_tex.sh recommended   (or full)."
    elif [ "$ONLINE" != "1" ]; then
        warn "Offline — skipping the LaTeX install. Later: bash Installs/install_tex.sh $_TEX_DO"
    else
        _TEX_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_tex.sh"
        if [ -f "$_TEX_SH" ]; then
            note "Installing the $_TEX_DO LaTeX set…"
            bash "$_TEX_SH" "$_TEX_DO" || warn "The LaTeX install had issues — re-run: bash Installs/install_tex.sh $_TEX_DO"
        else
            warn "install_tex.sh not found next to the installer — skipping LaTeX."
        fi
    fi
fi
# =============================================================================
# Phase 6 — Pull Ollama models (interactive)
# =============================================================================
echo
step "Phase 6 — Ollama models"
if phase_wanted 'ollama list 2>/dev/null | tail -n +2 | grep -q .'; then
echo
detect_hardware
tele_build_meta   # refresh telemetry metadata now that CPU/RAM/GPU/VRAM are known
ok "CPU       : ${HW_CPU_MODEL:-unknown} (${HW_CPU_CORES} cores)"
ok "Memory    : ${HW_RAM_MB} MB RAM"
ok "GPU       : ${HW_GPU_NAME:-unknown}$([ "${HW_VRAM_MB:-0}" -gt 0 ] && echo " · ${HW_VRAM_MB} MB VRAM")"
case "$HW_TIER" in
    high) note "Detected a ${HW_BUDGET_MB} MB memory budget — this machine can also run larger 7-14B models (add e.g. 'qwen2.5:14b' below)." ;;
    mid)  note "Detected a ${HW_BUDGET_MB} MB memory budget — the 7-8B suggestions will run comfortably here." ;;
    low)  warn "Only ~${HW_BUDGET_MB} MB memory budget (no/low discrete VRAM) — stick to the small 3-4B suggestions; larger models will be slow or fail." ;;
esac
echo
note "Suggested models (recommended — good spread of code/chat/reasoning, all fit in 4-8GB VRAM):"
for i in "${!DEFAULT_OLLAMA_MODELS[@]}"; do
    echo "    $((i+1)). ${DEFAULT_OLLAMA_MODELS[$i]}"
    echo "       ${DEFAULT_OLLAMA_MODELS_DESC[$i]}"
done
echo
echo "  These are the local AI 'brains' Cockpit runs on your own machine (private,"
echo "  offline once downloaded). Each is a multi-GB download. Enter = get the whole"
echo "  recommended set (works out of the box); numbers (e.g. '1 3 5') = just those;"
echo "  'none' = skip for now (you can pull models anytime later)."
echo

if [ "$UNATTENDED" = "1" ]; then
    # Default: pull nothing, CI shouldn't be downloading multi-GB models on
    # every run. Override with a real (small) list for an actual functional
    # smoke test, e.g.: COCKPIT_UNATTENDED_MODELS="tinyllama:1.1b"
    MODEL_INPUT="${COCKPIT_UNATTENDED_MODELS:-none}"
    note "Models to pull: $MODEL_INPUT (unattended)"
else
    ask MODEL_INPUT "Ollama models to pull (numbers, names, or 'none')" "$([ "$HW_NOGPU" = "1" ] && echo none || echo all)"
fi
MODELS_TO_PULL=()

if [ "$MODEL_INPUT" = "all" ] || { [ -z "$MODEL_INPUT" ] && [ "$UNATTENDED" != "1" ]; }; then
    MODELS_TO_PULL=("${DEFAULT_OLLAMA_MODELS[@]}")
elif [ -z "$MODEL_INPUT" ] || [ "$MODEL_INPUT" = "none" ]; then
    MODELS_TO_PULL=()
else
    # Parse — numbers map to suggestion list; words are taken as-is
    for token in $MODEL_INPUT; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            idx=$((token - 1))
            if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#DEFAULT_OLLAMA_MODELS[@]}" ]; then
                MODELS_TO_PULL+=("${DEFAULT_OLLAMA_MODELS[$idx]}")
            else
                warn "Index $token out of range — skipping"
            fi
        else
            MODELS_TO_PULL+=("$token")
        fi
    done
fi

if [ "$ONLINE" != "1" ] || ! command -v ollama &>/dev/null; then
    note "Offline / no Ollama — skipping model pulls (later: ollama pull <model>)."
elif [ "${#MODELS_TO_PULL[@]}" -eq 0 ]; then
    note "Skipping model pull (you can run 'ollama pull <model>' later)"
else
    for model in "${MODELS_TO_PULL[@]}"; do
        note "Pulling $model ..."
        substep "ollama pull ${model}"
        if sudo -u "$COCKPIT_USER" -H ollama pull "$model"; then
            substep_done
            ok "$model"
        else
            warn "Failed to pull $model — continuing"
        fi
    done
fi

fi   # phase_wanted
# =============================================================================
# Phase 7 — Extract cockpit tarball
# =============================================================================
echo
step "Phase 7 — Cockpit files"

EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cockpit_extract_XXXXXX")
# A re-install over a locked-down install: the guard would put the old files
# back while we copy, and ~/scripts is root-owned (cp as the user failed on
# ck-ubuntu2404). Pause the guard now; the lockdown at the end re-applies it.
if [ "$IS_MACOS" != "1" ] && systemctl is-active --quiet cockpit-guard 2>/dev/null; then
    as_root systemctl stop cockpit-guard && note "cockpit-guard paused for the copy (restarted at the end)"
fi
note "Extracting tarball to staging dir..."
substep "extract app tarball"
tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
substep_done

if [ ! -d "$EXTRACT_DIR/cockpit/web" ] || [ ! -d "$EXTRACT_DIR/cockpit/scripts" ]; then
    rm -rf "$EXTRACT_DIR"
    fatal "Tarball doesn't contain expected layout (cockpit/web/, cockpit/scripts/)"
fi

# Verify checksums if MANIFEST.txt is present
if [ -f "$EXTRACT_DIR/cockpit/MANIFEST.txt" ]; then
    note "Verifying file integrity..."
    (
        cd "$EXTRACT_DIR/cockpit"
        # MANIFEST.txt has comments starting with #, skip them
        grep -v '^#' MANIFEST.txt | grep -v '^$' | sha256 -c --quiet
    ) && ok "All files verified" || warn "Checksum mismatch in tarball"
fi

# ── Web files → $WEB_ROOT ─────────────────────────────────────────────────
note "Installing web files to ${WEB_ROOT}..."
as_root mkdir -p "$WEB_ROOT"
as_root cp -r "$EXTRACT_DIR/cockpit/web/." "$WEB_ROOT/"
as_root mkdir -p "$WEB_ROOT/queue" "$WEB_ROOT/responses"
ok "Web files installed"

# ── Scripts → ~/scripts/ ──────────────────────────────────────────────────
note "Installing scripts to ${SCRIPTS_DIR}..."
as_user mkdir -p "$SCRIPTS_DIR"
# root copies (shipped files may be root-owned from an earlier lockdown), then
# the tree is the user's again; the lockdown phase re-roots the shipped ones
as_root cp -r "$EXTRACT_DIR/cockpit/scripts/." "$SCRIPTS_DIR/"
as_root chown -R "$COCKPIT_USER" "$SCRIPTS_DIR"

# Native window (cockpit_shell): the bundle carries a prebuilt x86-64 binary and
# its Apache-2.0 sources (scripts/cockpit_shell_src). Keep the prebuilt one when
# it runs here; otherwise rebuild from source with fpc if present; else the
# start script falls back to a browser --app window (close button then bypasses
# the exit procedure).
if [ -f "$SCRIPTS_DIR/cockpit_shell_src/cockpit_shell.pas" ]; then
    as_user chmod +x "$SCRIPTS_DIR/cockpit_shell" 2>/dev/null || true
    if as_user "$SCRIPTS_DIR/cockpit_shell" --check >/dev/null 2>&1; then
        ok "Native window: cockpit_shell ready (close button runs the exit procedure)"
    else
        # The native window is the intended way to run Cockpit — the browser is
        # a last resort, not an equal option: the close button runs the exit
        # procedure, panels detach into real windows, and the hotkey summons it.
        # Falling back because ONE runtime library is absent gave a worse app to
        # anyone whose distro does not pull WebKitGTK in by default, so try to
        # install it before giving up (2026-09-26).
        _wk_pkg=""
        case "$PKG_MGR" in
            nala|apt-get) _wk_pkg="libwebkit2gtk-4.1-0" ;;
            dnf)          _wk_pkg="webkit2gtk4.1" ;;
            pacman)       _wk_pkg="webkit2gtk-4.1" ;;
            zypper)       _wk_pkg="libwebkit2gtk-4_1-0" ;;
            apk)          _wk_pkg="webkit2gtk-4.1" ;;
            # brew: the GTK stack on macOS is not worth dragging in for this;
            # that platform keeps the browser window.
        esac
        if [ -n "$_wk_pkg" ]; then
            note "Native window: WebKitGTK 4.1 runtime missing — installing ${_wk_pkg}"
            install_pkgs "$_wk_pkg" >/dev/null 2>&1 || true
        fi
        if as_user "$SCRIPTS_DIR/cockpit_shell" --check >/dev/null 2>&1; then
            ok "Native window: WebKitGTK runtime installed, cockpit_shell ready"
        elif command -v fpc >/dev/null 2>&1 && as_user bash "$SCRIPTS_DIR/cockpit_shell_src/build.sh" "$SCRIPTS_DIR/cockpit_shell" >/dev/null 2>&1 \
             && as_user "$SCRIPTS_DIR/cockpit_shell" --check >/dev/null 2>&1; then
            ok "Native window: cockpit_shell rebuilt from source for this machine"
        else
            warn "Native window unavailable (WebKitGTK 4.1 could not be installed, and no fpc to rebuild for this CPU) — the app opens in a browser window instead"
        fi
    fi
fi

# GNOME Shell shows tray icons only with the AppIndicator extension. Only on a
# real GNOME Shell session: the package depends on gnome-shell and would drag
# gdm3 onto a Cinnamon/XFCE/KDE machine (seen 2026-09-16). Those have trays.
if command -v gnome-extensions >/dev/null 2>&1 && pgrep -x gnome-shell >/dev/null 2>&1 && [ "$PKG_MGR" != "brew" ]; then
    case "$PKG_MGR" in nala|apt-get) as_root "$PKG_MGR" install -y -q gnome-shell-extension-appindicator >/dev/null 2>&1 || true ;; esac
fi
if command -v gnome-extensions >/dev/null 2>&1 && pgrep -x gnome-shell >/dev/null 2>&1; then
    for _ext in ubuntu-appindicators@ubuntu.com appindicatorsupport@rgcjonas.gmail.com; do
        as_user gnome-extensions info "$_ext" >/dev/null 2>&1 && { as_user gnome-extensions enable "$_ext" >/dev/null 2>&1 && ok "Tray: GNOME AppIndicator extension enabled ($_ext)"; break; }
    done
fi

# "Open at login" (optional): the window itself brings Cockpit up — it shows a
# boot screen and runs cockpit-start when the server is not answering yet, so
# nothing needs Apache to be up first.
if [ -x "$SCRIPTS_DIR/cockpit_shell" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    if confirm "Open AI Cockpit automatically when you log in?" n; then
        _au="${USER_HOME}/.config/autostart"; as_user mkdir -p "$_au"
        printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=AI Cockpit' \
            'Exec=cockpit-start' 'Icon=ai-cockpit' 'Terminal=false' \
            'X-GNOME-Autostart-enabled=true' 'StartupWMClass=ai-cockpit' \
            | as_user tee "$_au/ai-cockpit.desktop" >/dev/null
        as_user chmod +x "$_au/ai-cockpit.desktop" 2>/dev/null || true
        ok "Autostart: AI Cockpit opens at login (remove $_au/ai-cockpit.desktop to stop)"
    fi
fi

# ── Remote administration ────────────────────────────────────────────────────
if [ "$IN_VM" = 1 ] && command -v systemctl >/dev/null 2>&1; then
    sudo systemctl enable --now qemu-guest-agent >/dev/null 2>&1 || sudo systemctl start qemu-guest-agent >/dev/null 2>&1 || true   # Arch: udev-activated, "enable" has nothing to do
    ok "QEMU guest agent running — the host can run commands here (Installs/ci/vmrun.sh)"
fi
if [ -n "$SSH_ALLOW" ] && command -v systemctl >/dev/null 2>&1; then
    _sshsvc=sshd; systemctl list-unit-files ssh.service >/dev/null 2>&1 && _sshsvc=ssh
    sudo mkdir -p /etc/ssh/sshd_config.d
    printf '# AI Cockpit installer: remote administration from one address only\nAllowUsers %s@%s\n' "$COCKPIT_USER" "$SSH_ALLOW" | sudo tee /etc/ssh/sshd_config.d/90-cockpit.conf >/dev/null
    grep -q "^Include /etc/ssh/sshd_config.d" /etc/ssh/sshd_config 2>/dev/null || echo "Include /etc/ssh/sshd_config.d/*.conf" | sudo tee -a /etc/ssh/sshd_config >/dev/null
    sudo systemctl enable --now "$_sshsvc" >/dev/null 2>&1 || true
    if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then sudo ufw allow from "$SSH_ALLOW" to any port 22 proto tcp >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$SSH_ALLOW service name=ssh accept" >/dev/null 2>&1; sudo firewall-cmd --reload >/dev/null 2>&1 || true; fi
    ok "SSH: ${COCKPIT_USER}@$(hostname -I 2>/dev/null | awk '{print $1}') reachable from $SSH_ALLOW (password login; add your key to ~/.ssh/authorized_keys and set PasswordAuthentication no to harden)"
fi

# Cockpit Browser: the native window as a plain web browser (cockpit_shell
# --browser). Always registered as an app (Apps panel, xdg handler); made the
# SYSTEM default when asked — pre-ticked everywhere (the Cockpit Browser is the default browser; a system browser is the fallback when the shell is missing).
if [ "$IS_MACOS" != "1" ] && [ -x "$SCRIPTS_DIR/cockpit_shell" ]; then
    _ad="$USER_HOME/.local/share/applications"; as_user mkdir -p "$_ad"
    printf '[Desktop Entry]\nType=Application\nName=Cockpit Browser\nComment=The AI Cockpit window as a plain web browser (WebKitGTK)\nExec=%s --browser --url %%u\nIcon=%s\nTerminal=false\nCategories=Network;WebBrowser;\nMimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;\nStartupNotify=true\n' "$SCRIPTS_DIR/cockpit_shell" "$USER_HOME/.local/share/icons/ai-cockpit.png" | as_user tee "$_ad/cockpit-browser.desktop" >/dev/null
    as_user update-desktop-database "$_ad" >/dev/null 2>&1 || true
    ok "Cockpit Browser registered (Applications → Internet)"
    if confirm "Use the Cockpit window as the web browser?" "$CKBROWSER"; then
        as_session_user xdg-settings set default-web-browser cockpit-browser.desktop >/dev/null 2>&1 || true
        as_session_user xdg-mime default cockpit-browser.desktop x-scheme-handler/http x-scheme-handler/https text/html >/dev/null 2>&1 || true
        ok "Cockpit Browser is the default web browser (change it back in your desktop's Default Applications)"
    fi
fi

# Desktop shortcut: Ctrl+Alt+C summons Cockpit and starts it when it is not
# running (the app's own grab only exists while it runs). Per user, no sudo.
if [ -x "$SCRIPTS_DIR/install_hotkey.sh" ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    if confirm "Add a Ctrl+Alt+C shortcut that brings AI Cockpit up from any application?" y; then
        as_session_user bash "$SCRIPTS_DIR/install_hotkey.sh" >/dev/null 2>&1 && ok "Shortcut: Ctrl+Alt+C brings Cockpit up (remove it later with ~/scripts/install_hotkey.sh --remove)" || warn "Could not add the shortcut — add one for 'cockpit-start --toggle' in your desktop settings"
    fi
fi

# The scheduler's minute tick. Jobs (and autonomous goals, which run through the
# scheduler) do nothing without it, and a pasted crontab line is not an install
# step — so the installer puts it in the owner's crontab (2026-09-22). Idempotent;
# the Jobs panel can add/remove it later with one click.
if [ -x "$SCRIPTS_DIR/cockpit_cron.sh" ]; then
    if command -v crontab >/dev/null 2>&1; then
        if as_user env COCKPIT_WEB_ROOT="$WEB_ROOT" bash "$SCRIPTS_DIR/cockpit_cron.sh" install >/dev/null 2>&1; then
            ok "Scheduler tick installed in ${COCKPIT_USER}'s crontab (every minute) — Jobs and autonomous goals now fire"
        else
            note "Could not write the crontab — add the tick later from the Jobs panel (one click)"
        fi
    else
        note "cron is not installed on this machine — Jobs will only run while the app is open; install cron/cronie, then use the Jobs panel's Install button"
    fi
fi

# Cache headers. Apache serves index.html with no Cache-Control of its own, so a
# browser keeps the previous copy and a freshly installed or updated Cockpit can
# look unchanged until someone presses Ctrl+Shift+R — with a stale index.html
# against fresh js/, which is worse than either. no-cache means "revalidate",
# not "never cache": an unchanged file costs a 304.
_cache_conf_body() {
    cat <<'CACHECONF'
# Installed by AI Cockpit. no-cache means "revalidate", not "never cache":
# an unchanged file costs one 304 and no download.
<IfModule mod_headers.c>
    <Directory "/var/www/html">
        <FilesMatch "\.(html|js|css|json)$">
            Header set Cache-Control "no-cache, must-revalidate"
        </FilesMatch>
    </Directory>
</IfModule>
CACHECONF
}
_install_cache_conf() {
    if [ -d /etc/apache2/conf-available ]; then
        _cache_conf_body > /etc/apache2/conf-available/cockpit-cache.conf || return 1
        chmod 644 /etc/apache2/conf-available/cockpit-cache.conf
        a2enmod headers >/dev/null 2>&1; a2enconf cockpit-cache >/dev/null 2>&1
        if apache2ctl configtest >/dev/null 2>&1; then
            systemctl reload apache2 >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1
            return 0
        fi
        a2disconf cockpit-cache >/dev/null 2>&1   # never leave a server that will not start
        return 1
    elif [ -d /etc/httpd/conf.d ]; then
        _cache_conf_body > /etc/httpd/conf.d/cockpit-cache.conf || return 1
        chmod 644 /etc/httpd/conf.d/cockpit-cache.conf
        if httpd -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
            systemctl reload httpd >/dev/null 2>&1; return 0
        fi
        rm -f /etc/httpd/conf.d/cockpit-cache.conf; return 1
    fi
    return 2
}
if _install_cache_conf; then
    ok "Web server set to revalidate the app's files — a new build shows up on a normal reload"
else
    [ $? = 2 ] && note "No Apache config directory found — skipped the cache-header step" \
               || note "Could not set cache headers — after an update you may need Ctrl+Shift+R once"
fi

# Keep Cockpit's working folders and data files off the web. Apache listens on
# every network interface, and without this it LISTS queue/ and responses/ and
# serves the agent replies in them to anyone on the network with no login, plus a
# few data files only PHP reads (found by the 2026-10-05 audit). Nothing in the app
# fetches them over HTTP. Same safe-install shape as the cache step above: config
# test first, reverted if it fails. The directives must match
# Installs/apache/cockpit-security.conf (test_security_conf.sh checks that).
_security_conf_body() {
    cat <<'SECCONF'
# Installed by AI Cockpit: no folder listings under Cockpit, and queue/ responses/
# and internal data files are never served.
<DirectoryMatch "/cockpit(-v1)?(/|$)">
    Options -Indexes
    <FilesMatch "^(paths|project_state|workers_quotas)\.json$|^\.user\.ini$|\.jsonl$|\.(lock|sock)$">
        Require all denied
    </FilesMatch>
</DirectoryMatch>
<DirectoryMatch "/cockpit(-v1)?/(queue|responses)(/|$)">
    Require all denied
</DirectoryMatch>
SECCONF
}
_install_security_conf() {
    if [ -d /etc/apache2/conf-available ]; then
        _security_conf_body > /etc/apache2/conf-available/cockpit-security.conf || return 1
        chmod 644 /etc/apache2/conf-available/cockpit-security.conf
        a2enconf cockpit-security >/dev/null 2>&1
        if apache2ctl configtest >/dev/null 2>&1; then
            systemctl reload apache2 >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1
            return 0
        fi
        a2disconf cockpit-security >/dev/null 2>&1   # never leave a server that will not start
        return 1
    elif [ -d /etc/httpd/conf.d ]; then
        _security_conf_body > /etc/httpd/conf.d/cockpit-security.conf || return 1
        chmod 644 /etc/httpd/conf.d/cockpit-security.conf
        if httpd -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
            systemctl reload httpd >/dev/null 2>&1; return 0
        fi
        rm -f /etc/httpd/conf.d/cockpit-security.conf; return 1
    fi
    return 2
}
if _install_security_conf; then
    ok "Web server told not to list or serve Cockpit's working folders and data files"
else
    [ $? = 2 ] && note "No Apache config directory found — skipped the folder-protection step" \
               || warn "Could not add the folder-protection config — see Installs/apache/cockpit-security.conf"
fi

# Upload size limits for Apache's mod_php. PHP ships with 2M per file / 8M per request,
# so a voice note longer than ~a minute, a video for the transcriber or a larger chat
# import was dropped without a word. These can only be set per directory, so Apache
# gets them here; PHP-FPM/php-cgi reads cockpit_app/.user.ini instead. Same safe-install
# shape as the steps above. Directives must match Installs/apache/cockpit-php.conf
# (test_php_conf.sh checks that).
_php_conf_body() {
    cat <<'PHPCONF'
# Installed by AI Cockpit: lift PHP's 2M / 8M upload limits for Cockpit's folders (mod_php).
<DirectoryMatch "/cockpit(-v1)?(/|$)">
    <IfModule mod_php.c>
        php_value upload_max_filesize 1G
        php_value post_max_size 1G
    </IfModule>
    <IfModule mod_php8.c>
        php_value upload_max_filesize 1G
        php_value post_max_size 1G
    </IfModule>
</DirectoryMatch>
PHPCONF
}
_install_php_conf() {
    if [ -d /etc/apache2/conf-available ]; then
        _php_conf_body > /etc/apache2/conf-available/cockpit-php.conf || return 1
        chmod 644 /etc/apache2/conf-available/cockpit-php.conf
        a2enconf cockpit-php >/dev/null 2>&1
        if apache2ctl configtest >/dev/null 2>&1; then
            systemctl reload apache2 >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1
            return 0
        fi
        a2disconf cockpit-php >/dev/null 2>&1   # never leave a server that will not start
        return 1
    elif [ -d /etc/httpd/conf.d ]; then
        _php_conf_body > /etc/httpd/conf.d/cockpit-php.conf || return 1
        chmod 644 /etc/httpd/conf.d/cockpit-php.conf
        if httpd -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
            systemctl reload httpd >/dev/null 2>&1; return 0
        fi
        rm -f /etc/httpd/conf.d/cockpit-php.conf; return 1
    fi
    return 2
}
if _install_php_conf; then
    ok "PHP told to accept uploads up to 1 GB for Cockpit (voice notes, videos, imports)"
else
    [ $? = 2 ] && note "No Apache config directory found — skipped the upload-limit step" \
               || warn "Could not add the upload-limit config — see Installs/apache/cockpit-php.conf"
fi

# The agent engine (aicengine): a prebuilt binary and its sources ship beside the scripts. Nothing uses it until the
# user opts in (COCKPIT_ENGINE=1, or a file called use_engine in cockpit_data), and agent_loop.sh falls back to its
# Bash whenever the engine is missing or refuses a request — so this step can only ever add an option.
if [ -f "$SCRIPTS_DIR/aicengine_src/src/aicengine.lpr" ]; then
    as_user chmod +x "$SCRIPTS_DIR/aicengine" 2>/dev/null || true
    if [ -x "$SCRIPTS_DIR/aicengine" ] && as_user "$SCRIPTS_DIR/aicengine" version >/dev/null 2>&1; then
        ok "Agent engine: aicengine ready (off until you switch it on)"
    elif command -v fpc >/dev/null 2>&1 && as_user bash "$SCRIPTS_DIR/aicengine_src/build.sh" "$SCRIPTS_DIR/aicengine" >/dev/null 2>&1; then
        ok "Agent engine: rebuilt from source for this machine"
    else
        note "Agent engine: no usable binary for this machine (install fpc to build it) — the Bash path is used"
    fi
fi
# The process supervisor (aicsupervisor): a prebuilt binary and its sources ship beside the scripts. Nothing uses it until the user
# opts in (a file called use_supervisor in cockpit_data); cockpit_start.sh and the web pages fall back to tmux whenever it is missing.
if [ -f "$SCRIPTS_DIR/aicsupervisor_src/src/aicsupervisor.lpr" ]; then
    as_user chmod +x "$SCRIPTS_DIR/aicsupervisor" 2>/dev/null || true
    if [ -x "$SCRIPTS_DIR/aicsupervisor" ] && as_user "$SCRIPTS_DIR/aicsupervisor" service-file systemd-user --config /x/sup.json --binary /x/aicsupervisor >/dev/null 2>&1; then
        ok "Process supervisor: aicsupervisor ready (off until you switch it on)"
    elif command -v fpc >/dev/null 2>&1 && as_user bash "$SCRIPTS_DIR/aicsupervisor_src/build.sh" "$SCRIPTS_DIR/aicsupervisor" >/dev/null 2>&1; then
        ok "Process supervisor: rebuilt from source for this machine"
    else
        note "Process supervisor: no usable binary for this machine (install fpc to build it) — tmux is used"
    fi
fi
# The web server (aicserver): a prebuilt binary and its sources ship beside the scripts. Nothing uses it until the user opts in (a file called
# use_aicserver in cockpit_data, and php-cgi installed); Apache stays the web server whenever it is missing or off.
if [ -f "$SCRIPTS_DIR/aicserver_src/src/aicserver.lpr" ]; then
    as_user chmod +x "$SCRIPTS_DIR/aicserver" 2>/dev/null || true
    if [ -x "$SCRIPTS_DIR/aicserver" ] && as_user "$SCRIPTS_DIR/aicserver" version >/dev/null 2>&1; then
        ok "Web server: aicserver ready (off until you switch it on)"
    elif command -v fpc >/dev/null 2>&1 && as_user bash "$SCRIPTS_DIR/aicserver_src/build.sh" "$SCRIPTS_DIR/aicserver" >/dev/null 2>&1; then
        ok "Web server: rebuilt from source for this machine"
    else
        note "Web server: no usable binary for this machine (install fpc to build it) — Apache is used"
    fi
fi
# Bitwarden CLI (optional): the native window's "Fill from Bitwarden" buttons on
# Cockpit's own login forms need bw. Official release binary into ~/.local/bin,
# no sudo; the user runs `bw login` once. Skipped when bw is already present.
if [ -x "$SCRIPTS_DIR/cockpit_shell" ] && ! as_user bash -c 'command -v bw >/dev/null 2>&1 || [ -x "$HOME/.local/bin/bw" ]'; then
    if confirm "Install the Bitwarden CLI (bw) so login forms can be filled from your Bitwarden vault?" n; then
        as_user bash "$SCRIPTS_DIR/install_bw.sh" && ok "Bitwarden CLI installed — run 'bw login' once in your terminal" || warn "Bitwarden CLI install failed (optional; retry later with ~/scripts/install_bw.sh)"
    fi
fi
as_user chmod +x "$SCRIPTS_DIR"/*.sh
ok "Scripts installed and made executable"

# System-wide `cockpit-start` / `cockpit-stop` commands (run from anywhere).
if [ "$IS_MACOS" = "1" ]; then
    ln -sf "$SCRIPTS_DIR/cockpit_start.sh" /usr/local/bin/cockpit-start 2>/dev/null || true
    ln -sf "$SCRIPTS_DIR/cockpit_stop.sh"  /usr/local/bin/cockpit-stop  2>/dev/null || true
else
    sudo ln -sf "$SCRIPTS_DIR/cockpit_start.sh" /usr/local/bin/cockpit-start 2>/dev/null || true
    sudo ln -sf "$SCRIPTS_DIR/cockpit_stop.sh"  /usr/local/bin/cockpit-stop  2>/dev/null || true
fi
command -v cockpit-start >/dev/null 2>&1 && ok "Commands available: cockpit-start / cockpit-stop"

# GUI launcher (no terminal): icon + .desktop so the app starts from the menu/
# dock — only the splash + app window appear. Also registers a custom top-level
# "AI" menu category (freedesktop .directory + menu-merge fragment) and files
# the launcher under it. Menu-spec DEs (KDE/XFCE/MATE/Cinnamon/LXQt) show the
# "AI" submenu; GNOME lists it flat in the app grid — either way it appears.
if [ "$IS_MACOS" != "1" ]; then
    _apps_dir="${USER_HOME}/.local/share/applications"
    _icon_dir="${USER_HOME}/.local/share/icons"
    _dir_dir="${USER_HOME}/.local/share/desktop-directories"
    _menu_dir="${USER_HOME}/.config/menus/applications-merged"
    as_user mkdir -p "$_apps_dir" "$_icon_dir" "$_dir_dir" "$_menu_dir"
    _logo="$WEB_ROOT/assets/logo_512.png"; [ -f "$_logo" ] || _logo="$WEB_ROOT/assets/logo.png"
    [ -f "$_logo" ] && as_user cp "$_logo" "$_icon_dir/ai-cockpit.png"
    printf '%s\n' \
        '[Desktop Entry]' 'Version=1.0' 'Type=Application' 'Name=AI Cockpit' \
        'GenericName=AI Orchestration Cockpit' \
        'Comment=Start the AI Cockpit agent sessions and open the app' \
        'Exec=cockpit-start' 'Icon=ai-cockpit' 'Terminal=false' \
        'Categories=Development;Utility;X-AI;' 'StartupNotify=true' \
        'StartupWMClass=ai-cockpit' \
        'Keywords=cockpit;ai;claude;gemini;ollama;' \
        | as_user tee "$_apps_dir/ai-cockpit.desktop" >/dev/null
    as_user chmod +x "$_apps_dir/ai-cockpit.desktop" 2>/dev/null || true
    printf '%s\n' '[Desktop Entry]' 'Type=Directory' 'Name=AI' 'Icon=ai-cockpit' \
        | as_user tee "$_dir_dir/AI.directory" >/dev/null
    printf '%s\n' \
        '<!DOCTYPE Menu PUBLIC "-//freedesktop//DTD Menu 1.0//EN" "http://www.freedesktop.org/standards/menu-spec/menu-1.0.dtd">' \
        '<Menu>' '  <Name>Applications</Name>' '  <Menu>' '    <Name>AI</Name>' \
        '    <Directory>AI.directory</Directory>' \
        '    <Include><Category>X-AI</Category></Include>' '  </Menu>' '</Menu>' \
        | as_user tee "$_menu_dir/ai.menu" >/dev/null
    as_user update-desktop-database "$_apps_dir" 2>/dev/null || true
    ok "GUI launcher + 'AI' menu category installed"
    # The self-contained start (no Apache: aicserver + php-cgi under the supervisor, the same window on a side port). Two more commands and
    # two more menu entries; the ordinary launcher is untouched. Each is a one-line wrapper around the same script.
    as_user mkdir -p "${USER_HOME}/.local/bin"
    printf '%s\n' '#!/bin/bash' 'exec "$HOME/scripts/cockpit_start.sh" --self "$@"' | as_user tee "${USER_HOME}/.local/bin/cockpit-self-start" >/dev/null
    printf '%s\n' '#!/bin/bash' 'exec env COCKPIT_EDITION=v1 "$HOME/scripts/cockpit_start.sh" --self "$@"' | as_user tee "${USER_HOME}/.local/bin/cockpit-v1-self-start" >/dev/null
    as_user chmod +x "${USER_HOME}/.local/bin/cockpit-self-start" "${USER_HOME}/.local/bin/cockpit-v1-self-start" 2>/dev/null || true
    printf '%s\n' '[Desktop Entry]' 'Version=1.0' 'Type=Application' 'Name=AI Cockpit (self-contained)' \
        'Comment=Start AI Cockpit without Apache: its own small web server, same window' \
        'Exec=cockpit-self-start' 'Icon=ai-cockpit' 'Terminal=false' 'Categories=Development;Utility;X-AI;' \
        'StartupNotify=true' 'StartupWMClass=ai-cockpit' | as_user tee "$_apps_dir/ai-cockpit-self.desktop" >/dev/null
    printf '%s\n' '[Desktop Entry]' 'Version=1.0' 'Type=Application' 'Name=AI Cockpit V1 (self-contained)' \
        'Comment=Start AI Cockpit V1 without Apache: its own small web server, same window' \
        'Exec=cockpit-v1-self-start' 'Icon=ai-cockpit' 'Terminal=false' 'Categories=Development;Utility;X-AI;' \
        'StartupNotify=true' | as_user tee "$_apps_dir/ai-cockpit-v1-self.desktop" >/dev/null
    as_user chmod +x "$_apps_dir/ai-cockpit-self.desktop" "$_apps_dir/ai-cockpit-v1-self.desktop" 2>/dev/null || true
    ok "GUI launcher + 'AI' menu category installed"

    # Brave x11 guard: a login autostart that re-applies --ozone-platform=x11 to
    # Brave's launchers (Brave updates wipe user .desktop overrides → wrong
    # rendering). No-ops on non-Brave systems. Ships in scripts/.
    if [ -x "$SCRIPTS_DIR/brave_x11_fix.sh" ]; then
        as_user mkdir -p "${USER_HOME}/.config/autostart"
        printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Brave x11 fix (AI Cockpit)' \
            'Comment=Re-apply --ozone-platform=x11 to Brave launchers after updates' \
            "Exec=${SCRIPTS_DIR}/brave_x11_fix.sh" 'X-GNOME-Autostart-enabled=true' \
            'NoDisplay=true' 'Terminal=false' \
            | as_user tee "${USER_HOME}/.config/autostart/brave-x11-fix.desktop" >/dev/null
        as_user "$SCRIPTS_DIR/brave_x11_fix.sh" 2>/dev/null || true
    fi
fi

# ── Project root ──────────────────────────────────────────────────────────
note "Creating project root: ${PROJECTS_ROOT}"
as_user mkdir -p "$PROJECTS_ROOT"
as_user mkdir -p "$PROJECTS_ROOT/_standalone"
as_user mkdir -p "$PROJECTS_ROOT/default"
ok "Project structure created"

# Web (Apache) runs as ${APACHE_USER}; the agent daemon runs as ${COCKPIT_USER}.
# BOTH must read+write the chat/project files. Add the web user to the cockpit
# user's group and make the tree group-owned + group-writable + setgid, so every
# file/dir either process creates carries the shared group and stays writable by
# both. Without this, files.php (Apache) cannot create chats in the ${COCKPIT_USER}-
# owned tree (New Chat / New Project silently fail).
if [ "$IS_MACOS" != "1" ] && [ "$APACHE_USER" != "$COCKPIT_USER" ]; then
    sudo usermod -aG "$COCKPIT_USER" "$APACHE_USER" 2>/dev/null || true
    sudo chgrp -R "$COCKPIT_USER" "$PROJECTS_ROOT" 2>/dev/null || true
    sudo chmod -R g+w "$PROJECTS_ROOT" 2>/dev/null || true
    sudo find "$PROJECTS_ROOT" -type d -exec chmod g+s {} + 2>/dev/null || true
    ok "Shared group configured (${APACHE_USER} ∈ ${COCKPIT_USER}); Apache restart in Phase 10 applies it"
fi

# paths.php's own fallback default (${HOME}/Projects) does NOT match the
# folder we just created above -- without this, the app would silently look
# in the wrong place on every fresh install. Same for "home": unset, the web
# server resolved it to ITS home (/var/www), asked sudo for /var/www/scripts/
# cockpit_start.sh as root, and no agent session ever started on a fresh
# install (ck-ubuntu2404, 2026-09-19). Write (or update) paths.json so
# the two agree, without touching any other value a user may have already
# customized there.
PATHS_JSON="${WEB_ROOT}/paths.json"
if [ -f "$PATHS_JSON" ]; then
    as_root php -r '
        $f = $argv[1]; $root = $argv[2];
        $j = json_decode(file_get_contents($f), true) ?: [];
        $j["projects_root"] = $root;
        $j["home"] = $argv[3];
        file_put_contents($f, json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE));
    ' "$PATHS_JSON" "$PROJECTS_ROOT" "$USER_HOME"
else
    as_root tee "$PATHS_JSON" > /dev/null <<EOF
{
    "_comment": "AI Cockpit -- runtime path configuration. Edit via the cockpit's Library/Config tab or directly with a text editor. Changes take effect on the next request (no restart needed).",
    "projects_root": "${PROJECTS_ROOT}",
    "home": "${USER_HOME}"
}
EOF
fi
ok "paths.json set: projects_root -> ${PROJECTS_ROOT}, home -> ${USER_HOME}"

# ── Cockpit data dir (Library / Snippets / Sources / Code / Approvals) ────
COCKPIT_DATA="${SCRIPTS_DIR}/cockpit_data"
# Full path for the V1 report answer, now that the data dir is known. Kept in
# cockpit_data so it survives app upgrades and is per-install, not per-user-shell.
SUCCESS_MARKER="${COCKPIT_DATA}/${SUCCESS_MARKER_REL}"
note "Creating cockpit_data dirs at ${COCKPIT_DATA}..."
for kind in library snippets sources code approvals; do
    as_user mkdir -p "${COCKPIT_DATA}/${kind}"
done
ok "cockpit_data hierarchy created"

# ── Edition flag — read by auth.php (funnel-ping gate) and this script's own
# Phase 12 below. Standalone: touch it. Full: remove any stale one from a
# prior standalone install being re-run as full.
if [ "$EDITION" = "standalone" ]; then
    as_user touch "${COCKPIT_DATA}/.edition_standalone"
else
    as_user rm -f "${COCKPIT_DATA}/.edition_standalone"
fi

# Seed the free Power Combo packs (50 Ollama + 50 LocalAI + 50 Dual) so a
# fresh install isn't left with zero combos — combos_core.php's plaintext
# fallback reads combos_ollama.json/combos_localai.json/combos_dual.json from
# here, and nothing else ships them. Only copy if missing, so re-running the
# installer on an existing setup never clobbers the user's own edits/saved
# combos in these files.
note "Seeding free Power Combo packs..."
for f in combos_ollama.json combos_localai.json combos_dual.json; do
    src="${EXTRACT_DIR}/cockpit/seed_combos/${f}"
    dst="${COCKPIT_DATA}/${f}"
    if [ -f "$src" ] && [ ! -f "$dst" ]; then
        as_user cp "$src" "$dst"
    fi
done
ok "Combo packs seeded"

# ── Secondary version (only when 'both' was chosen) ──────────────────────────
# Deploy the older V1 alongside V2: its own web root (${WEB_ROOT}-v1, served at
# /cockpit-v1) and its own data dir, sharing the same Ollama/LocalAI/packages.
if [ "$INSTALL_BOTH" = "1" ]; then
    echo
    step "Phase 7c — Secondary version (${SECONDARY_VERSION}) side-by-side"
    SECONDARY_WEB_ROOT="${WEB_ROOT}-v1"
    SECONDARY_DATA="${SCRIPTS_DIR}/cockpit_data_v1"
    SEC_EXTRACT=$(mktemp -d "${TMPDIR:-/tmp}/cockpit_v1_XXXXXX")
    substep "extract secondary (v1) tarball"
    tar -xzf "$SECONDARY_TARBALL" -C "$SEC_EXTRACT"
    substep_done
    if [ ! -d "$SEC_EXTRACT/cockpit/web" ]; then
        rm -rf "$SEC_EXTRACT"
        warn "Secondary tarball layout unexpected — skipping V1 side-by-side"
    else
        note "Installing V1 web files to ${SECONDARY_WEB_ROOT}..."
        as_root mkdir -p "$SECONDARY_WEB_ROOT"
        as_root cp -r "$SEC_EXTRACT/cockpit/web/." "$SECONDARY_WEB_ROOT/"
        as_root mkdir -p "$SECONDARY_WEB_ROOT/queue" "$SECONDARY_WEB_ROOT/responses"
        as_user mkdir -p "$SECONDARY_DATA"
        for f in combos_ollama.json combos_localai.json combos_dual.json; do
            [ -f "$SEC_EXTRACT/cockpit/seed_combos/$f" ] && [ ! -f "$SECONDARY_DATA/$f" ] && \
                as_user cp "$SEC_EXTRACT/cockpit/seed_combos/$f" "$SECONDARY_DATA/"
        done
        if [ "$IS_MACOS" = "1" ]; then
            chmod -R u+rwX "$SECONDARY_WEB_ROOT" "$SECONDARY_DATA"
            chmod -R g+rwX "$SECONDARY_WEB_ROOT/queue" "$SECONDARY_WEB_ROOT/responses"
        else
            sudo chown -R "$COCKPIT_USER":"$APACHE_GROUP" "$SECONDARY_WEB_ROOT"
            sudo chmod -R u+rwX,g+rX,o+rX "$SECONDARY_WEB_ROOT"
            sudo chmod -R g+rwX "$SECONDARY_WEB_ROOT/queue" "$SECONDARY_WEB_ROOT/responses"
        fi
        # V1 needs its OWN paths.json or it does not use the data dir created for
        # it three lines up: paths.php falls back to the default cockpit_data, so
        # both editions landed on the same Library, Snippets, Sources, chats and
        # projects. Changing a setting or opening a chat in one showed it in the
        # other — reported 2026-09-26, and the reason `cockpit_data_v1` existed
        # while nothing ever read it.
        #
        # Separate is the default because two editions are two workspaces; a user
        # who wants one shared set can say so (COCKPIT_V1_SHARE_DATA=1, or by
        # editing this file later — it is the documented way to move either root).
        SECONDARY_PROJECTS="${PROJECTS_ROOT}"
        if [ "${COCKPIT_V1_SHARE_DATA:-0}" = "1" ]; then
            SECONDARY_DATA_EFF="${SCRIPTS_DIR}/cockpit_data"
            note "V1 will SHARE V2's data and projects (COCKPIT_V1_SHARE_DATA=1)."
        else
            SECONDARY_DATA_EFF="$SECONDARY_DATA"
            SECONDARY_PROJECTS="${PROJECTS_ROOT%/}_v1"
            as_user mkdir -p "$SECONDARY_PROJECTS" 2>/dev/null || true
            note "V1 gets its own data + projects (separate by default)."
        fi
        SEC_PATHS_JSON="${SECONDARY_WEB_ROOT}/paths.json"
        as_root tee "$SEC_PATHS_JSON" > /dev/null <<EOF
{
    "_comment": "AI Cockpit V1 (Stand-alone) -- its own data and projects, separate from V2 by default. Point these at V2's paths to share one workspace.",
    "projects_root": "${SECONDARY_PROJECTS}",
    "cockpit_data": "${SECONDARY_DATA_EFF}",
    "home": "${USER_HOME}"
}
EOF
        as_root chown "$COCKPIT_USER":"$APACHE_GROUP" "$SEC_PATHS_JSON" 2>/dev/null || true
        ok "V1 paths.json: data -> ${SECONDARY_DATA_EFF}, projects -> ${SECONDARY_PROJECTS}"

        ok "V1 installed at ${SECONDARY_WEB_ROOT}  →  http://localhost:${HTTP_PORT}/cockpit-v1/"
        note "V1 is the Stand-alone edition — it shows as 1.x, and its login/data are separate from V2's."

        # Distinct window title so V1's --app window / the launcher's guards don't
        # clash with V2's "AI Cockpit".
        as_root sed -i 's#<title>AI Cockpit</title>#<title>AI Cockpit V1</title>#' \
            "$SECONDARY_WEB_ROOT/index.html" 2>/dev/null || true

        if [ "$IS_MACOS" != "1" ]; then
            # V1 launcher commands (edition-aware shared script via COCKPIT_EDITION).
            for _w in cockpit-v1-start:cockpit_start.sh cockpit-v1-stop:cockpit_stop.sh; do
                _cmd="${_w%%:*}"; _tgt="${_w##*:}"
                printf '#!/bin/bash\nexec env COCKPIT_EDITION=v1 "%s/%s" "$@"\n' "$SCRIPTS_DIR" "$_tgt" \
                    | sudo tee "/usr/local/bin/$_cmd" >/dev/null
                sudo chmod +x "/usr/local/bin/$_cmd"
            done
            # V1 GUI launcher under the AI menu.
            _apps_dir="${USER_HOME}/.local/share/applications"
            as_user mkdir -p "$_apps_dir"
            printf '%s\n' '[Desktop Entry]' 'Version=1.0' 'Type=Application' 'Name=AI Cockpit V1' \
                'GenericName=AI Cockpit (No-Account Edition)' \
                'Comment=Start AI Cockpit V1 — fully local, no account' \
                'Exec=cockpit-v1-start' 'Icon=ai-cockpit' 'Terminal=false' \
                'Categories=Development;Utility;X-AI;' 'StartupNotify=true' \
        'StartupWMClass=ai-cockpit' \
                'Keywords=cockpit;ai;v1;local;' \
                | as_user tee "$_apps_dir/ai-cockpit-v1.desktop" >/dev/null
            as_user update-desktop-database "$_apps_dir" 2>/dev/null || true
            ok "V1 commands (cockpit-v1-start/stop) + AI-menu launcher installed"
        fi
    fi
    rm -rf "$SEC_EXTRACT"
fi

# Cleanup staging
rm -rf "$EXTRACT_DIR"

# =============================================================================
# Phase 8 — Permissions
# =============================================================================
echo
step "Phase 8 — Permissions"

# Web files — owned by user, group $APACHE_USER, group-writable for queue/responses.
# macOS: no www-data-style service account — Homebrew's httpd runs as the
# invoking user, so there's no cross-user ownership split to manage; this
# whole phase is just making sure the current user can read/write its own
# files, no chown needed at all.
note "Setting web file ownership and permissions..."
# Local image generation (stable-diffusion.cpp) runs the GPU under Apache
# (${APACHE_USER}); the Vulkan render node /dev/dri/renderD* is render/video-group
# only. Add the web user to those groups so it can use the GPU (else it silently
# falls back to slow CPU). No-op if the groups don't exist.
if [ "$IS_MACOS" != "1" ]; then
    for _grp in render video; do
        getent group "$_grp" >/dev/null 2>&1 && sudo usermod -aG "$_grp" "$APACHE_USER" 2>/dev/null || true
    done
    ok "GPU access: ${APACHE_USER} added to render/video (Apache restart applies it)"
fi
if [ "$IS_MACOS" = "1" ]; then
    chmod -R u+rwX "$WEB_ROOT" "$COCKPIT_DATA"
    chmod -R g+rwX "$WEB_ROOT/queue" "$WEB_ROOT/responses"
else
    sudo chown -R "$COCKPIT_USER":"$APACHE_GROUP" "$WEB_ROOT"
    sudo chmod -R u+rwX,g+rX,o+rX "$WEB_ROOT"
    sudo chmod -R g+rwX "$WEB_ROOT/queue" "$WEB_ROOT/responses"

    # project_state.json must be writable by the web server (it writes to it)
    if [ -f "$WEB_ROOT/project_state.json" ]; then
        sudo chown "$COCKPIT_USER":"$APACHE_GROUP" "$WEB_ROOT/project_state.json"
        sudo chmod 664 "$WEB_ROOT/project_state.json"
    fi

    sudo chown -R "$COCKPIT_USER":"$APACHE_GROUP" "$COCKPIT_DATA"
    sudo chmod -R 775 "$COCKPIT_DATA"
fi

ok "Permissions set"

# =============================================================================
# Phase 8b — SELinux (Fedora / RHEL family, only when enforcing)
# =============================================================================
# Seen on the first Fedora 44 install: the web server could not execute the
# auth binary under /var/www ("Auth component not installed"), and the LocalAI
# service could not start a binary in ~/.local/bin (init_t → gconf_home_t).
# Cockpit's web backend must run the person's agents (sudo -u, tmux) and talk
# to the account server — that does not fit httpd_t. The web-server DOMAIN is
# made permissive (denials logged, not enforced); every other domain stays
# enforcing. Binaries under ~/.local/bin get bin_t so services can start them.
# Detected through the kernel, not $PATH: openSUSE keeps getenforce/semanage in /usr/sbin, off a user's PATH — the phase silently skipped there (Tumbleweed VM).
_se_on=0; [ -r /sys/fs/selinux/enforce ] && [ "$(cat /sys/fs/selinux/enforce 2>/dev/null)" = "1" ] && _se_on=1
if [ "$IS_MACOS" != "1" ] && [ "$_se_on" = "1" ]; then
    echo
    step "Phase 8b — SELinux"
    _sem="$(command -v semanage 2>/dev/null || { [ -x /usr/sbin/semanage ] && echo /usr/sbin/semanage; })"
    _seb="$(command -v setsebool 2>/dev/null || echo /usr/sbin/setsebool)"; _rcn="$(command -v restorecon 2>/dev/null || echo /sbin/restorecon)"
    if [ -n "$_sem" ]; then
        as_root "$_sem" permissive -a httpd_t 2>/dev/null && ok "SELinux: web-server domain (httpd_t) set permissive — it runs your agents via sudo/tmux; everything else stays enforcing" || warn "SELinux: could not set httpd_t permissive — the account step and agent sessions may be denied (see: sudo ausearch -m avc -ts recent)"
        as_root "$_sem" fcontext -a -t bin_t "${USER_HOME}/.local/bin(/.*)?" 2>/dev/null || as_root "$_sem" fcontext -m -t bin_t "${USER_HOME}/.local/bin(/.*)?" 2>/dev/null || true
        as_root "$_rcn" -R "${USER_HOME}/.local/bin" 2>/dev/null && ok "SELinux: ~/.local/bin labelled bin_t (LocalAI, Aider, Goose services can start)"
        as_root "$_seb" -P httpd_can_network_connect=1 httpd_enable_homedirs=1 2>/dev/null || true
    else
        warn "SELinux is enforcing and 'semanage' is missing (package policycoreutils-python-utils) — install it and re-run, or the account step and agent sessions will be denied"
    fi
fi

# =============================================================================
# Phase 9 — Sudoers (for tmux signal access from Apache)
# =============================================================================
echo
step "Phase 9 — Sudoers rules"

if [ "$IS_MACOS" = "1" ]; then
    note "Skipped — Homebrew's httpd runs as your own user on macOS, not a"
    note "separate service account, so there's no cross-user tmux-signal"
    note "permission to grant."
else
    SUDOERS_FILE="/etc/sudoers.d/cockpit"
    note "Writing sudoers rule to allow the web server to signal tmux..."

    # Apache/httpd runs as $APACHE_USER; it needs to send signals to the user's
    # tmux sessions (only on the cockpit_* sockets) without a password.
    sudo tee "$SUDOERS_FILE" >/dev/null <<EOF
# Allow ${APACHE_USER} to manage cockpit tmux sessions running under ${COCKPIT_USER}
# Used by bridge.php to verify session is alive and (rarely) restart it.
${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: /usr/bin/tmux -S ${WEB_ROOT}/tmux.sock has-session -t cockpit_*
${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: /usr/bin/tmux -S ${WEB_ROOT}/tmux.sock list-sessions
# The Stand-alone (V1) edition runs its own tmux socket under its own web root.
# Without these, V1 can start and stop sessions but can never SEE them (no count).
# Listed unconditionally so installing V1 later needs no sudoers rewrite.
${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: /usr/bin/tmux -S ${WEB_ROOT}-v1/tmux.sock has-session -t cockpit_*
${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: /usr/bin/tmux -S ${WEB_ROOT}-v1/tmux.sock list-sessions
# Web Start/Stop/Restart buttons (session.php) — run the lifecycle scripts as
# ${COCKPIT_USER}, and fix the tmux socket perms so ${APACHE_USER} can read it.
# The trailing " *" forms allow the optional per-agent target argument.
${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: /usr/bin/env COCKPIT_INVOKED_FROM_WEB=1 ${USER_HOME}/scripts/cockpit_start.sh, /usr/bin/env COCKPIT_INVOKED_FROM_WEB=1 ${USER_HOME}/scripts/cockpit_start.sh *
${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: ${USER_HOME}/scripts/cockpit_stop.sh, ${USER_HOME}/scripts/cockpit_stop.sh *
${APACHE_USER} ALL=(root) NOPASSWD: /bin/chown ${COCKPIT_USER}\:${APACHE_GROUP} ${WEB_ROOT}/tmux.sock
${APACHE_USER} ALL=(root) NOPASSWD: /bin/chmod 660 ${WEB_ROOT}/tmux.sock
${APACHE_USER} ALL=(root) NOPASSWD: /bin/chown ${COCKPIT_USER}\:${APACHE_GROUP} ${WEB_ROOT}-v1/tmux.sock
${APACHE_USER} ALL=(root) NOPASSWD: /bin/chmod 660 ${WEB_ROOT}-v1/tmux.sock
EOF
    sudo chmod 0440 "$SUDOERS_FILE"

    # Validate sudoers syntax
    if sudo visudo -c -f "$SUDOERS_FILE" >/dev/null 2>&1; then
        ok "Sudoers rule installed and validated"
    else
        sudo rm -f "$SUDOERS_FILE"
        fatal "Sudoers syntax error — rule was rolled back"
    fi

    # Toolbar Terminal / Files / Browser buttons (launch_cli.php) — Apache
    # launches GUI apps as ${COCKPIT_USER}, preserving the X11/display env. Only
    # emit entries for binaries that exist so we never grant a missing path.
    # (Linux desktop only; skipped on macOS which has no /usr/bin/gnome-terminal.)
    if [ "$IS_MACOS" != "1" ]; then
        LAUNCH_SUDOERS="/etc/sudoers.d/cockpit-launch-cli"
        # Grant EVERY installed candidate (+ the default dispatchers xdg-open /
        # x-terminal-emulator) so the user can switch apps in the Apps panel
        # without editing sudoers. launch_cli.php only ever runs one of these.
        _launch_bins=""
        for _b in /usr/bin/xdg-open /usr/bin/x-terminal-emulator \
                  /usr/bin/gnome-terminal /usr/bin/ptyxis /usr/bin/kgx /usr/bin/konsole /usr/bin/xfce4-terminal \
                  /usr/bin/mate-terminal /usr/bin/tilix /usr/bin/kitty /usr/bin/alacritty /usr/bin/xterm \
                  /usr/bin/nemo /usr/bin/nautilus /usr/bin/dolphin /usr/bin/thunar /usr/bin/pcmanfm /usr/bin/caja \
                  /usr/bin/brave-browser /usr/bin/firefox /usr/bin/chromium /usr/bin/chromium-browser \
                  /usr/bin/google-chrome /usr/bin/google-chrome-stable "${USER_HOME}/scripts/cockpit_shell" \
                  /usr/bin/startlazarus /usr/bin/lazarus-ide; do
            [ -x "$_b" ] && _launch_bins="$_launch_bins $_b"
        done
        # The Cockpit window (web page workers start it as the owner) is ALWAYS granted, even when it is built later than this step: a sudoers rule is only a path, and a rule
        # that was missing here left every web worker failing with "sudo: a password is required" on installs made before the shell existed.
        case " $_launch_bins " in *" ${USER_HOME}/scripts/cockpit_shell "*) ;; *) _launch_bins="$_launch_bins ${USER_HOME}/scripts/cockpit_shell" ;; esac
        {
            echo "# Cockpit toolbar Terminal/Files/Browser (launch_cli.php) — GUI apps as ${COCKPIT_USER}"
            for _b in $_launch_bins; do echo "${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: ${_b}"; done
            for _b in $_launch_bins; do echo "Defaults!${_b} env_keep += \"DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS LANG WAYLAND_DISPLAY XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION GDMSESSION BROWSER\""; done
            echo "# Jobs panel: install/remove the scheduler's minute tick in the owner's crontab"
            echo "${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: ${USER_HOME}/scripts/cockpit_cron.sh, ${USER_HOME}/scripts/cockpit_cron.sh *"
            echo "# In-app Translate language manager (translate.php set_langs)"
            echo "${APACHE_USER} ALL=(${COCKPIT_USER}) NOPASSWD: ${USER_HOME}/scripts/libretranslate_langs.sh, ${USER_HOME}/scripts/libretranslate_langs.sh *"
            echo "# cockpit_start.sh may (re)start the web server if it isn't up — passwordless"
            echo "${COCKPIT_USER} ALL=(root) NOPASSWD: /usr/bin/systemctl start ${APACHE_SVC}, /bin/systemctl start ${APACHE_SVC}"
        } | sudo tee "$LAUNCH_SUDOERS" >/dev/null
        sudo chmod 0440 "$LAUNCH_SUDOERS"
        if sudo visudo -c -f "$LAUNCH_SUDOERS" >/dev/null 2>&1; then
            ok "Launch-CLI sudoers installed ($(echo $_launch_bins | wc -w) apps)"
        else
            sudo rm -f "$LAUNCH_SUDOERS"
            note "Launch-CLI sudoers failed validation — toolbar launch buttons disabled (non-fatal)"
        fi
    fi
fi

# =============================================================================
# Phase 10 — Apache/httpd configuration
# =============================================================================
echo
step "Phase 10 — ${APACHE_SVC} configuration"

if [ "$IS_MACOS" = "1" ]; then
    # Homebrew's httpd.conf ships with none of this by default — no Cockpit
    # alias, rewrite commented out, and (unlike Linux, where `apt install
    # libapache2-mod-phpX` wires the PHP module automatically) no PHP module
    # line at all, since PHP isn't bundled with Homebrew's httpd formula.
    # Both of the original guesses missed, so this whole block was skipped on a
    # real Mac and httpd came up healthy but serving nothing at /cockpit/:
    #   ${DOCROOT%/www} on /opt/homebrew/var/www is /opt/homebrew/VAR, giving
    #     /opt/homebrew/var/etc/httpd/httpd.conf — one path element too deep.
    #   `brew --prefix httpd` is the KEG (/opt/homebrew/opt/httpd); Homebrew
    #     installs configs to HOMEBREW_PREFIX/etc, never into the keg.
    # Found by the Apple Silicon CI run, 2026-09-23. Try the real locations in
    # order (Apple Silicon, Intel, and whatever brew actually reports).
    HTTPD_CONF=""
    for _hc_try in \
        "${DOCROOT%/var/www}/etc/httpd/httpd.conf" \
        "$(brew --prefix 2>/dev/null)/etc/httpd/httpd.conf" \
        /opt/homebrew/etc/httpd/httpd.conf \
        /usr/local/etc/httpd/httpd.conf
    do
        [ -f "$_hc_try" ] && { HTTPD_CONF="$_hc_try"; break; }
    done
    # Never fail silently again: if no config is found, the install cannot serve
    # Cockpit at all, so say so loudly rather than finishing with a broken site.
    [ -n "$HTTPD_CONF" ] || warn "httpd.conf not found (looked under $(brew --prefix 2>/dev/null || echo /opt/homebrew)/etc/httpd) — Cockpit will not be served; see the macOS notes."
    if [ -f "$HTTPD_CONF" ]; then
        # Move httpd off 8080 — LocalAI (Phase 5) binds 127.0.0.1:8080 too,
        # and whichever starts first silently wins the port otherwise.
        sed -i '' -E "s/^Listen (127\\.0\\.0\\.1:)?8080\$/Listen \\1${HTTP_PORT}/" "$HTTPD_CONF" 2>/dev/null || true
        if ! grep -q "cockpit" "$HTTPD_CONF"; then
            note "Adding Cockpit alias to httpd.conf..."
            cat >> "$HTTPD_CONF" <<EOF

# AI Cockpit
Alias ${URL_PREFIX} "${WEB_ROOT}"
<Directory "${WEB_ROOT}">
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF
        fi
        sed -i '' 's/^#LoadModule rewrite_module/LoadModule rewrite_module/' "$HTTPD_CONF" 2>/dev/null || true

        LIBPHP=$(find "$(brew --prefix php 2>/dev/null)/lib/httpd/modules" -name "libphp.so" 2>/dev/null | head -1)
        if [ -n "$LIBPHP" ] && ! grep -q "LoadModule php_module" "$HTTPD_CONF"; then
            note "Wiring PHP module into httpd.conf..."
            cat >> "$HTTPD_CONF" <<EOF

# PHP (added by AI Cockpit installer)
LoadModule php_module ${LIBPHP}
<FilesMatch \.php\$>
    SetHandler application/x-httpd-php
</FilesMatch>
DirectoryIndex index.php index.html
EOF
        elif [ -z "$LIBPHP" ]; then
            warn "libphp.so not found under Homebrew's php prefix — PHP module not wired into httpd"
        fi
    else
        warn "httpd.conf not found at expected path — verify Cockpit alias manually"
    fi

    HTTPD_BIN="$(brew --prefix httpd 2>/dev/null)/bin/httpd"
    if [ -x "$HTTPD_BIN" ] && ! "$HTTPD_BIN" -t 2>&1 | grep -q "Syntax OK"; then
        warn "httpd.conf failed syntax check — showing details:"
        "$HTTPD_BIN" -t || true
    fi

    brew services restart httpd
else
    # Enable mod_rewrite — a2enmod only exists on Debian/Ubuntu's Apache
    # layout; Fedora/Arch/openSUSE/Alpine httpd builds either load it by
    # default already or need a LoadModule line uncommented in httpd.conf
    # directly (not attempted here — cockpit doesn't strictly need rewrite,
    # this is best-effort only).
    if [ "$PKG_MGR" = "nala" ] || [ "$PKG_MGR" = "apt-get" ]; then
        sudo a2enmod rewrite >/dev/null 2>&1 || true
    fi
    # Arch's "http" system account is created EXPIRED in /etc/shadow; sudo runs
    # PAM's account check on the caller before looking at any NOPASSWD rule, so
    # every launch from the app ("Open … CLI", Terminal, Files) died with
    # "Account expired" and no visible error (Arch/MATE VM). Lift the expiry.
    if [ "$IS_MACOS" != "1" ] && command -v chage >/dev/null 2>&1; then
        if sudo chage -l "$APACHE_USER" 2>/dev/null | grep -qiE '^Account expires\s*:\s*(Jan 0?2, 1970|[0-9])'; then
            sudo chage -E -1 "$APACHE_USER" 2>/dev/null && ok "web-server account ${APACHE_USER}: expiry removed (sudo refused it as 'Account expired')"
        fi
    fi
    # Arch/Manjaro: php-apache is installed but NOT wired — httpd runs mpm_event
    # (libphp is not thread-safe, it needs prefork), php_module is not loaded,
    # and /etc/php/php.ini ships curl/sqlite3/pdo_sqlite/zip commented out. The
    # Manjaro VM served session.php as plain text. This is the Arch wiki recipe.
    if [ "$PKG_MGR" = "pacman" ] && [ -f /etc/httpd/conf/httpd.conf ]; then
        _hc=/etc/httpd/conf/httpd.conf
        if [ -f /usr/lib/httpd/modules/libphp.so ]; then
            note "Wiring PHP into httpd (mpm_prefork + php_module — Arch ships them unconnected)..."
            sudo sed -i 's|^LoadModule mpm_event_module modules/mod_mpm_event.so|#LoadModule mpm_event_module modules/mod_mpm_event.so|; s|^#LoadModule mpm_prefork_module modules/mod_mpm_prefork.so|LoadModule mpm_prefork_module modules/mod_mpm_prefork.so|; s|^#LoadModule rewrite_module modules/mod_rewrite.so|LoadModule rewrite_module modules/mod_rewrite.so|' "$_hc"
            grep -q '^LoadModule mpm_prefork_module' "$_hc" || echo 'LoadModule mpm_prefork_module modules/mod_mpm_prefork.so' | sudo tee -a "$_hc" >/dev/null
            grep -q '^LoadModule php_module' "$_hc" || printf '\n# PHP (added by AI Cockpit installer)\nLoadModule php_module modules/libphp.so\nAddHandler php-script .php\nInclude conf/extra/php_module.conf\n' | sudo tee -a "$_hc" >/dev/null
        else
            warn "php-apache's libphp.so not found — PHP is not wired into httpd"
        fi
        if [ -f /etc/php/php.ini ]; then
            sudo sed -i -E 's/^;(extension=(curl|sqlite3|pdo_sqlite|zip|iconv|mbstring|xml|sockets|posix))$/\1/' /etc/php/php.ini
            note "php.ini: curl, sqlite3, pdo_sqlite, zip, iconv enabled (Arch ships them off)"
        fi
        sudo systemctl restart "$APACHE_SVC" 2>/dev/null || true
    fi
    # Arch's httpd.service runs with ProtectHome=true: the web server sees an
    # EMPTY /home, so ~/scripts (agent loop, integrity manifest entries, hardware
    # scan) does not exist for it — every scripts/* file read as "missing" and
    # ruggi.site answered 'unofficial_build' (Manjaro VM). A drop-in lifts it;
    # the service keeps every other sandbox setting.
    if [ "$IS_MACOS" != "1" ] && command -v systemctl >/dev/null 2>&1; then
        _ph="$(systemctl show "$APACHE_SVC" -p ProtectHome --value 2>/dev/null)"
        _nnp="$(systemctl show "$APACHE_SVC" -p NoNewPrivileges --value 2>/dev/null)"
        # NoNewPrivileges=yes (Arch's httpd.service) blocks setuid: every `sudo -u <user>`
        # the app runs (Open CLI, Terminal, Files, session control) died silently.
        if [ "$_ph" = "yes" ] || [ "$_nnp" = "yes" ]; then
            note "${APACHE_SVC}.service sandbox (ProtectHome=${_ph:-?}, NoNewPrivileges=${_nnp:-?}) — adding a drop-in so it can reach ~/scripts and run sudo"
            sudo mkdir -p "/etc/systemd/system/${APACHE_SVC}.service.d"
            printf '# AI Cockpit: the web server runs the agent scripts under the login user'"'"'s home, via sudo\n[Service]\nProtectHome=false\nNoNewPrivileges=false\n' | sudo tee "/etc/systemd/system/${APACHE_SVC}.service.d/cockpit.conf" >/dev/null
            sudo systemctl daemon-reload; sudo systemctl restart "$APACHE_SVC" 2>/dev/null || true
        fi
    fi
    # Make sure the web server can read the cockpit dir — it's already
    # inside $DOCROOT, the default DocumentRoot for this distro, so no
    # extra vhost needed.
fi

# Verify PHP works
note "Verifying PHP-${APACHE_SVC} integration..."
if [ "$IS_MACOS" = "1" ]; then
    PHP_TEST="${WEB_ROOT}/_cockpit_phpcheck_$$.php"
    echo '<?php echo "phpok-".phpversion(); ?>' > "$PHP_TEST"
else
    PHP_TEST="${DOCROOT}/_cockpit_phpcheck_$$.php"
    echo '<?php echo "phpok-".phpversion(); ?>' | sudo tee "$PHP_TEST" >/dev/null
fi
sleep 1
PHP_TEST_URL="http://localhost:${HTTP_PORT}${URL_PREFIX}/$(basename "$PHP_TEST")"
if curl -s "$PHP_TEST_URL" | grep -q "^phpok-"; then
    ok "PHP $(curl -s "$PHP_TEST_URL" | sed 's/^phpok-//') working"
else
    if [ "$CI_MODE" = "1" ]; then warn "PHP test page didn't respond as expected — check web server config"; else fatal "PHP is not being executed by ${APACHE_SVC} (the test page came back wrong) — nothing in Cockpit works without it. Check: ${APACHE_SVC} error log, php_module loaded, php.ini extensions"; fi
fi
if [ "$IS_MACOS" = "1" ]; then rm -f "$PHP_TEST"; else sudo rm -f "$PHP_TEST"; fi

if [ "$CI_MODE" = "1" ]; then
    note "CI mode — skipping web-server reload"
elif [ "$IS_MACOS" = "1" ]; then
    for i in $(seq 1 15); do
        curl -sf "http://127.0.0.1:${HTTP_PORT}/" >/dev/null 2>&1 && break
        sleep 1
    done
else
    sudo systemctl reload "$APACHE_SVC"
fi

# =============================================================================
# Phase 11 — Verification
# =============================================================================
echo
step "Phase 11 — Verification"

# 1. Cockpit URL reachable? Always at /cockpit/ regardless of OS — Linux
# reaches it as a plain DocumentRoot subfolder, macOS via the explicit
# httpd.conf Alias set up in Phase 10, but the browsable path is the same.
COCKPIT_URL="http://localhost:${HTTP_PORT}/cockpit/"
if curl -s -o /dev/null -w "%{http_code}" "$COCKPIT_URL" | grep -q "^200$"; then
    ok "${COCKPIT_URL} — reachable"
else
    warn "${COCKPIT_URL} — not reachable yet"
fi

# 2. Each agent CLI responds?
note "Testing agent CLIs..."
for cli in claude gemini ollama; do
    if command -v "$cli" &>/dev/null; then
        ok "$cli installed: $(command -v "$cli")"
    else
        warn "$cli NOT FOUND"
    fi
done

# 3. Scripts present?
for s in agent_loop.sh ai_bridge.sh cockpit_start.sh cockpit_stop.sh crud_executor.sh; do
    if [ -x "$SCRIPTS_DIR/$s" ]; then
        ok "$s installed and executable"
    else
        warn "$s missing or not executable"
    fi
done

# 4. PHP extensions
for ext in xml curl mbstring; do
    if php -m | grep -qi "^$ext\$\|^$ext "; then
        ok "PHP extension: $ext"
    else
        warn "PHP extension: $ext NOT loaded"
    fi
done

# 5. Integrity (2026-09-13): the install against its shipped manifest, and the
#    bundle kept under cockpit_data/install_src/ so a changed file can be
#    restored later (the app's Integrity modal points here).
if [ -f "$WEB_ROOT/integrity.json" ]; then
    as_user mkdir -p "$COCKPIT_DATA/install_src" 2>/dev/null || true
    # the outer bundle sits beside the extracted cockpit/ folder; else keep the inner app tarball
    _outer="$(dirname "$SELF_DIR")/cockpit_install.tar.gz"
    if [ -f "$_outer" ]; then as_user cp "$_outer" "$COCKPIT_DATA/install_src/cockpit_install.tar.gz" 2>/dev/null && ok "Install bundle kept: $COCKPIT_DATA/install_src/cockpit_install.tar.gz"
    elif [ -f "$TARBALL" ]; then as_user cp "$TARBALL" "$COCKPIT_DATA/install_src/cockpit_app.tar.gz" 2>/dev/null && ok "App tarball kept: $COCKPIT_DATA/install_src/cockpit_app.tar.gz"; fi
    _ic=$(cd "$WEB_ROOT" && php -r 'require "integrity_lib.php"; $m=integrity_manifest(); $c=[]; $x=[]; $id=integrity_compute($m,$c,$x); echo ($id===$m["build_id"] && !$c && !$x) ? "intact ".$id : "CHANGED ".count($c)." changed, ".count($x)." missing";' 2>/dev/null || echo 'check failed')
    case "$_ic" in intact*) ok "Integrity: every shipped file matches the manifest (build ${_ic#intact })" ;; *) warn "Integrity: $_ic — the app's Integrity panel lists them" ;; esac
fi
# 6. Lockdown + guard (2026-09-13). Shipped files become root-owned read-only
#    (cockpit_lockdown.sh) and cockpit-guard.service watches them: a change is
#    logged, flagged in the app, and put back from the kept bundle. Both are on
#    by default; COCKPIT_LOCKDOWN=0 / COCKPIT_GUARD=0 in the environment skip them.
if [ "${COCKPIT_LOCKDOWN:-1}" = 1 ] && [ -f "$WEB_ROOT/integrity.json" ] && [ "$IS_MACOS" != "1" ]; then
    _lk="$SELF_DIR/cockpit_lockdown.sh"; [ -f "$_lk" ] || _lk="$EXTRACT_DIR/cockpit/cockpit_lockdown.sh"
    if [ -f "$_lk" ]; then
        _webs=(--web "$WEB_ROOT"); [ -n "${SECONDARY_WEB_ROOT:-}" ] && [ -f "$SECONDARY_WEB_ROOT/integrity.json" ] && _webs+=(--web "$SECONDARY_WEB_ROOT")
        sudo bash "$_lk" "${_webs[@]}" --user "$COCKPIT_USER" >/dev/null 2>&1 && ok "Lockdown: shipped files are root-owned, read-only for others (sudo to edit; Integrity shows changes)" || warn "Lockdown skipped (cockpit_lockdown.sh failed)"
    fi
fi
if [ "${COCKPIT_GUARD:-1}" = 1 ] && [ "$IS_MACOS" != "1" ] && command -v systemctl >/dev/null 2>&1 && command -v inotifywait >/dev/null 2>&1; then
    _unit="$SELF_DIR/cockpit-guard.service"; [ -f "$_unit" ] || _unit="$EXTRACT_DIR/cockpit/cockpit-guard.service"
    if [ -f "$_unit" ] && [ -f "$SCRIPTS_DIR/cockpit_guard.sh" ]; then
        sed "s|__USER__|$COCKPIT_USER|g; s|__HOME__|$USER_HOME|g" "$_unit" | sudo tee /etc/systemd/system/cockpit-guard.service >/dev/null
        sudo systemctl daemon-reload && sudo systemctl enable --now cockpit-guard >/dev/null 2>&1 && ok "cockpit-guard running (logs to cockpit_data/guard.log; restores from the kept bundle)" || warn "cockpit-guard could not be started"
    fi
fi
# 7. Terms
note "AI Cockpit is provided under the licence in $WEB_ROOT/LICENSE.md (also shown in the app on first use). Using it means accepting those terms."

# =============================================================================
# Phase 12 — SaaS account login (optional, full edition only)
# =============================================================================
# Only logs in to an EXISTING SaaS account (username+password, no captcha
# needed). Full registration needs a Turnstile captcha token from a real
# browser, so that can't be scripted here — left blank or on failure, the
# app's own Account modal handles login/register on first open.
# Stand-alone edition skips this entirely — no account, ever, is the point.
echo
step "Phase 12 — Cockpit account (cockpit.ruggi.site)"
SAAS_LOGIN_OK=0
echo
if [ "$V2_SELECTED" = "1" ] && [ "$EDITION" != "standalone" ]; then
    warn "V2 needs at least a FREE account (cockpit.ruggi.site) to work."
    note "It powers the Marketplace, remote relay (Everywhere), and account sync."
    note "Log in below with an existing account, or create a free one (no card)."
fi
if [ "$ONLINE" != "1" ]; then
    if [ "$V2_SELECTED" = "1" ]; then
        warn "Offline — can't sign in now. V2 needs a free cockpit.ruggi.site account:"
        warn "once online, open the app's Account tab to log in or register (free, no card)."
    else
        note "Offline — skipping account step."
    fi
    SAAS_USER=""; SAAS_PASS=""
elif [ "$EDITION" = "standalone" ]; then
    note "Skipped — Stand-alone edition never creates a SaaS account"
elif [ "$UNATTENDED" = "1" ]; then
    SAAS_USER="${COCKPIT_UNATTENDED_SAAS_USER:-}"
    SAAS_PASS="${COCKPIT_UNATTENDED_SAAS_PASS:-}"
    note "SaaS account: ${SAAS_USER:-<none, unattended>}"
else
    ask SAAS_USER "cockpit.ruggi.site username (blank = skip / create below)" ""
    SAAS_PASS="${SAAS_PASS:-}"
    if [ -n "$SAAS_USER" ] && [ -z "$SAAS_PASS" ]; then   # typed up front already?
        read -r -s -p "$(echo -e "${C_BLUE}?${C_OFF} SaaS password: ")" SAAS_PASS
        echo
    fi
fi

if [ "$EDITION" != "standalone" ] && [ "$ONLINE" = "1" ]; then
    if [ -n "$SAAS_USER" ] && [ -n "$SAAS_PASS" ]; then
        # saas.php sits behind the local app login and keeps the account in the
        # signed-in local user's own cockpit_data. Without that session the POST was
        # refused (or landed in the shared root) and the app opened UNREGISTERED
        # after a Phase 12 "login" (ck-ubuntu2404). Sign in to the app first, same jar.
        _jar="/tmp/cockpit_saas_login_cookies.$$"; : > "$_jar"; chmod 600 "$_jar"
        if [ -s "$COCKPIT_DATA/users.json" ] && [ -n "${LOCAL_APP_USER:-}" ] && [ -n "${LOCAL_APP_PASS:-}" ]; then   # re-install: a local login exists
            _lr=$(curl -s -X POST -H "Content-Type: application/json" -c "$_jar" -b "$_jar" \
                -d "{\"username\":\"${LOCAL_APP_USER}\",\"password\":\"${LOCAL_APP_PASS}\"}" \
                "http://localhost:${HTTP_PORT}/cockpit/auth.php?action=login")
            echo "$_lr" | grep -q '"ok":true' || warn "Local app sign-in for the account step failed ($_lr)"
        else
            note "First-run: the account is stored at the shared root and attached to the local login created next"
        fi
        SAAS_LOGIN_RESP=$(curl -s -X POST \
            -H "Content-Type: application/json" -c "$_jar" -b "$_jar" \
            -d "{\"username\":\"${SAAS_USER}\",\"password\":\"${SAAS_PASS}\"}" \
            "http://localhost:${HTTP_PORT}/cockpit/saas.php?action=login")
        rm -f "$_jar"
        if echo "$SAAS_LOGIN_RESP" | grep -q '"ok":true'; then
            ok "SaaS login succeeded: $SAAS_USER"; SAAS_LOGIN_OK=1
        else
            warn "SaaS login failed — log in from the app's Account tab instead ($SAAS_LOGIN_RESP)"
        fi
    else
        # No credentials entered. Offer to guide free registration. Registration
        # is captcha-protected, so it can't be scripted here — it happens in the
        # browser; we just point the user at it.
        if [ "$UNATTENDED" != "1" ] && confirm "Create a new FREE account now?" "y"; then
            note "Free sign-up needs a quick human captcha, so it's done in your browser:"
            note "    open  https://cockpit.ruggi.site/  →  Account  →  Register (free, no card)"
            note "Then log in from the app's Account tab (or re-run this installer with the"
            note "credentials). The app works fully once a free account is signed in."
        else
            note "Skipped — log in or register any time from the app's Account tab"
        fi
    fi
    # Paid tiers — informational only, nothing to buy here.
    if [ "$V2_SELECTED" = "1" ]; then
        echo
        note "Beyond the free tier (optional, upgrade in-app later):"
        note "  • Plus — more remote-relay minutes + higher Marketplace limits"
        note "  • Pro  — the premium 185-combo packs + priority relay"
        note "  Free stays fully functional; paid tiers just lift limits."
    fi
fi

# =============================================================================
# Phase 7b — Local app account (optional)
# =============================================================================
# auth.php already has a first-run "setup" screen that appears when
# users.json is empty/missing — so if left blank here, nothing to do, the
# app will ask on first open. This just lets a re-install skip that screen
# by seeding the admin account up front.
echo
step "Phase 7b — Local app account (Cockpit login)"
echo
note "Cockpit is protected by a local username + password — you use it to log in"
note "to the app in your browser. Create it now, or skip and the app will ask on"
note "its first-run setup screen."
echo
if [ "$UNATTENDED" = "1" ]; then
    LOCAL_APP_USER="${COCKPIT_UNATTENDED_APP_USER:-}"
    LOCAL_APP_PASS="${COCKPIT_UNATTENDED_APP_PASS:-}"
    note "Local app account: ${LOCAL_APP_USER:-<none, unattended>}"
else
    ask LOCAL_APP_USER "Local Cockpit login username (blank = skip, app asks on first open)" ""
    LOCAL_APP_PASS="${LOCAL_APP_PASS:-}"
    if [ -n "$LOCAL_APP_USER" ] && [ -z "$LOCAL_APP_PASS" ]; then   # typed up front already?
        read -r -s -p "$(echo -e "${C_BLUE}?${C_OFF} Local app admin password: ")" LOCAL_APP_PASS
        echo
    fi
fi

USERS_JSON="${COCKPIT_DATA}/users.json"
# Full edition: the first local login IS the Cockpit account name (one identity
# per machine — Dario, 2026-09-19). The account step (Phase 12) ran first and
# left saas_account.json at the shared root; auth.php enforces the same rule
# for the app's own first-run screen.
if [ "$V2_SELECTED" = "1" ] && [ "${SAAS_LOGIN_OK:-0}" = "1" ] && [ -n "${SAAS_USER:-}" ]; then
    if [ -n "$LOCAL_APP_USER" ] && [ "$LOCAL_APP_USER" != "$SAAS_USER" ]; then
        note "Local login name set to your account name ($SAAS_USER) — the first login on a machine is the account's; more logins with other names can be added in the app."
    fi
    LOCAL_APP_USER="$SAAS_USER"
fi
if [ -s "$USERS_JSON" ] && grep -q '"username"' "$USERS_JSON" 2>/dev/null; then
    note "Local logins already exist on this machine — kept as they are (manage them in the app: Users)."
elif [ -n "$LOCAL_APP_USER" ] && [ -n "$LOCAL_APP_PASS" ]; then
    if [ ${#LOCAL_APP_USER} -lt 2 ] || [ ${#LOCAL_APP_USER} -gt 32 ]; then
        warn "Username must be 2-32 chars — skipping, app will ask on first open"
    elif [ ${#LOCAL_APP_PASS} -lt 6 ]; then
        warn "Password must be >= 6 chars — skipping, app will ask on first open"
    else
        as_user php -r '
            $f = $argv[1]; $user = $argv[2]; $pass = $argv[3];
            $users = [[
                "id"         => 1,
                "username"   => $user,
                "hash"       => password_hash($pass, PASSWORD_BCRYPT),
                "role"       => "admin",
                "created_at" => date("c"),
            ]];
            file_put_contents($f, json_encode($users, JSON_PRETTY_PRINT));
        ' "$USERS_JSON" "$LOCAL_APP_USER" "$LOCAL_APP_PASS"
        chmod 660 "$USERS_JSON" 2>/dev/null || true   # the web server (in the login user's group) must update it later; auth.php writes 0660 too — Manjaro VM: "Permission denied" in auth.php
        ok "Local login created: $LOCAL_APP_USER"
        # the app's own first-run screen sends this funnel signal (auth.php setup →
        # setup_ping.php); a login created here must count the same way, else the
        # dashboard shows installs with no accounts (the VM installs, 2026-09-19)
        if [ "$V2_SELECTED" = "1" ] && [ "$TELE_ON" = "1" ]; then
            curl -s -m 6 -X POST -H 'Content-Type: application/json' -d '{"event":"first_account_created","edition":"v2"}' https://cockpit.ruggi.site/api/setup_ping.php >/dev/null 2>&1 || true
        fi
        # the account signed in during first-run lives at the shared root — it belongs to this login
        if [ -f "$COCKPIT_DATA/saas_account.json" ]; then
            as_user mkdir -p "$COCKPIT_DATA/users/$LOCAL_APP_USER"
            for _f in saas_account.json accounts_roster.json; do
                [ -f "$COCKPIT_DATA/$_f" ] && as_user mv -f "$COCKPIT_DATA/$_f" "$COCKPIT_DATA/users/$LOCAL_APP_USER/$_f"
            done
            ok "Cockpit account attached to the local login $LOCAL_APP_USER"
        fi
    fi
else
    note "Skipped — app will show its first-run setup screen"
fi

# =============================================================================
# Done
# =============================================================================
echo
echo
# ── V1: the one question we owe the user, asked at the end ───────────────────
# V1 sent a boot line and a selection line, then nothing. Now that the install
# has actually finished, ask once whether to send a single "it worked" line.
# Declining is final for this install. If they neither accept nor decline (a
# piped/unattended run), leave a marker so the app may ask ONCE at first run and
# then stop asking forever — an unanswered question is not consent.
if [ "$V2_SELECTED" != "1" ] && [ "$CI_MODE" != "1" ] && [ -z "${COCKPIT_NO_TELEMETRY:-}" ]; then
    echo
    note "AI Cockpit V1 is installed. Nothing has been sent since you chose V1."
    note "One last thing, and it is entirely your call: may we record that this"
    note "install SUCCEEDED? One line: the fact it worked, your OS/distro, and"
    note "coarse hardware. No name, no paths, no files, no IP. It is the only"
    note "way we learn that V1 installs work at all — V1 tells us nothing else."
    if [ "$UNATTENDED" = "1" ]; then
        # Nobody is there to answer. Do not assume yes; leave it for first run.
        as_user mkdir -p "$(dirname "$SUCCESS_MARKER")" 2>/dev/null || true
        printf 'ask\n%s\n' "$TELE_ID" | as_user tee "$SUCCESS_MARKER" >/dev/null 2>&1 || true
        note "Unattended run — not asked. The app may ask once on first run."
    elif confirm "Send a single anonymous \"install succeeded\" line?" "y"; then
        body=$(printf '{"id":"%s","event":"complete","phase":"v1-complete","installer_ver":"%s","container":"%s",%s}' \
            "$TELE_ID" "$INSTALLER_VERSION" "$CONTAINER_KIND" "$TELE_META")
        curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d "$body" "$TELE_ENDPOINT" >/dev/null 2>&1 || true
        printf 'sent\n' | as_user tee "$SUCCESS_MARKER" >/dev/null 2>&1 || true
        ok "Sent. Thank you — that single line is the whole V1 picture."
    else
        # Declined means declined: record it so nothing ever asks again.
        as_user mkdir -p "$(dirname "$SUCCESS_MARKER")" 2>/dev/null || true
        printf 'declined\n' | as_user tee "$SUCCESS_MARKER" >/dev/null 2>&1 || true
        note "Not sent, and you will not be asked again."
    fi
fi

state_put "done_$(phase_key "$CURRENT_PHASE")" 1; state_put complete 1
CURRENT_PHASE="complete"; tele complete   # anonymous success beacon (if enabled)

# Anonymous one-line ping so we know downloads are turning into real
# installs — timestamp + daily-hashed IP + "install_complete", nothing else
# (no machine info, no account data). Best-effort, never blocks anything.
# Set COCKPIT_NO_TELEMETRY=1 before running this script to skip it.
# Stand-alone edition ALWAYS skips this — its whole promise is zero network
# calls to our server, ever, so this can't be opt-out-only for that edition.
if [ "$CI_MODE" = "1" ]; then
    note "Telemetry ping skipped (CI mode)"
elif [ "$EDITION" = "standalone" ]; then
    note "Telemetry ping skipped — Stand-alone edition never calls our server"
elif [ -z "${COCKPIT_NO_TELEMETRY:-}" ]; then
    if [ "$IS_MACOS" = "1" ]; then TELEMETRY_META="full-macos"; else TELEMETRY_META="full-linux"; fi
    curl -fsS -o /dev/null --max-time 3 \
        "https://ruggi.site/tracker.php?action=install_complete&doc=cockpit&beacon=1&meta=${TELEMETRY_META}" \
        2>/dev/null || true
else
    note "Telemetry ping skipped (COCKPIT_NO_TELEMETRY set)"
fi
echo
# ── Phase 13 — companion tools (optional) ───────────────────────────────────
# ftpsuite and secretsuite ship beside Cockpit and are useful with it: ftpush
# deploys a site, secrets keeps the credentials that deployment needs. Both are
# self-contained and install to ~/.local — no root, nothing system-wide, and
# declining leaves Cockpit exactly as it was.
#
# They are OPT-IN and OPTIONAL on purpose. A failure here must never fail the
# Cockpit install, so each runs inside `|| true` and only warns.
step "Phase 13 — Companion tools (optional)"
if phase_wanted '[ -x "$USER_HOME/.local/bin/ftpush" ] && [ -x "$USER_HOME/.local/bin/secrets" ]'; then
echo
TOOLS_SRC=""
for cand in "${SELF_DIR}/tools" "${SELF_DIR}/../tools" "${SCRIPT_DIR:-}/tools"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { TOOLS_SRC="$cand"; break; }
done

if [ -z "$TOOLS_SRC" ]; then
    note "No companion tools bundled with this installer — skipping."
else
    note "Bundled alongside Cockpit, installed into ~/.local (no root needed):"
    note "  ftpsuite    ftpush/ftpull/ftps-cli/ftps-gui — deploy files to a site"
    note "  secretsuite secrets/secrets-cli/secrets-gui — encrypted credential sheets"
    echo
    if confirm "Install the companion tools?" y; then
        # their own installers would sudo apt for these and stall on the password
        # prompt (Phase 13 runs them with stdin closed) — install as root here first
        install_pkgs lftp dialog tk 2>/dev/null || warn "lftp/dialog/tk not installed — ftps-cli/ftps-gui/secrets-gui may be unavailable"
        # Shared pieces first (the dialog colour themes both TUIs use).
        if [ -d "$TOOLS_SRC/../share" ]; then
            as_user mkdir -p "$USER_HOME/.local/share/dariotools" 2>/dev/null || true
            for f in "$TOOLS_SRC/../share"/*; do
                [ -f "$f" ] && as_user cp "$f" "$USER_HOME/.local/share/dariotools/" 2>/dev/null || true
            done
            ok "shared TUI themes -> $USER_HOME/.local/share/dariotools"
        fi
        for d in "$TOOLS_SRC"/*/; do
            [ -d "$d" ] || continue
            n=$(basename "$d")
            inst=""
            for i in "$d$n-install.sh" "$d"*-install.sh; do
                [ -f "$i" ] && { inst="$i"; break; }
            done
            [ -n "$inst" ] || { note "$n — no installer found, skipped"; continue; }
            note "Installing $n ..."
            # as_user is `sudo -u` WITHOUT -H, so $HOME would still be root's and
            # the tools would land in /root/.local. Pass the real home explicitly.
            # stdin closed: the tool installers ask "Install tk now? [y/N]" with a plain
            # read, and with output hidden that prompt hung the whole install (ck-ubuntu2404).
            # Output goes to a log; its tail is shown when the installer fails.
            _tlog="/tmp/cockpit-tools-$n.log"
            if as_user env HOME="$USER_HOME" sh "$inst" </dev/null >"$_tlog" 2>&1; then
                ok "$n installed"
            else
                warn "$n installer returned non-zero — Cockpit is unaffected."
                tail -5 "$_tlog" | sed "s/^/       /"
                note "  Run it yourself later:  sh $inst   (log: $_tlog)"
            fi
        done
        note "Tools live in ~/.local/bin — open a new terminal to pick them up."
    else
        note "Skipped. Install later with:  sh $TOOLS_SRC/../dariotools-install.sh"
    fi
fi
echo

fi   # phase_wanted
echo -e "${C_BLUE}═══════════════════════════════════════════════════════════${C_OFF}"
echo -e "${C_BLUE}  Installation complete${C_OFF}"
echo -e "${C_BLUE}═══════════════════════════════════════════════════════════${C_OFF}"
echo
echo -e "${C_YELLOW}Next steps:${C_OFF}"
echo
if [ "$IS_WSL" = 1 ]; then
    # No Linux app menu or hotkey daemon under WSL: the Windows shortcuts made by install_windows.ps1 are the way in.
    echo "  1. Open AI Cockpit from the Windows Start menu or Desktop shortcut \"AI Cockpit\","
    echo -e "     or in this terminal:  ${C_BLUE}cockpit-start${C_OFF}   (Windows browser instead: http://localhost:${HTTP_PORT}/cockpit/ — http, not https)"
else
    echo "  1. Open AI Cockpit: app menu → AI → AI Cockpit, or press Ctrl+Alt+C,"
    echo -e "     or in a terminal:  ${C_BLUE}cockpit-start${C_OFF}   (browser instead: http://localhost:${HTTP_PORT}/cockpit/)"
fi
echo
echo "  2. First open: create the app's local login, then the free account (Full edition)."
echo
echo "  3. Sign the AI CLIs in once — on a card click \"Open ... CLI in a new terminal\","
echo "     or in any terminal:"
echo -e "       ${C_BLUE}claude${C_OFF}   then /login   (pick \"Claude account with subscription\" if you have one)"
echo -e "       ${C_BLUE}gemini${C_OFF}   then /auth"
echo "     (Ollama runs locally — no sign-in; the first prompt pulls the model)"
echo
echo -e "  4. Stop everything: the Exit button in the window, or  ${C_BLUE}cockpit-stop${C_OFF}"
echo
echo "  Re-running this installer later is safe: it remembers your answers and"
echo "  offers every component already here as 'use it' or 'redo'."
echo
note "Project root: ${PROJECTS_ROOT}"
case "$PKG_MGR" in
    pacman|dnf) APACHE_LOG="/var/log/httpd/error_log" ;;
    zypper)     APACHE_LOG="/var/log/apache2/error_log" ;;
    brew)       APACHE_LOG="$(brew --prefix httpd 2>/dev/null)/var/log/httpd/error_log" ;;
    *)          APACHE_LOG="/var/log/${APACHE_SVC}/error.log" ;;
esac
note "Logs:         ${APACHE_LOG}  (${APACHE_SVC})"
note "              ${SCRIPTS_DIR}/*.log          (cockpit scripts, if any)"
echo
