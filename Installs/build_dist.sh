#!/usr/bin/env bash
# =============================================================================
# build_dist.sh — assemble the installable V1 + V2 artifacts the pc installer
# (install_cockpit.sh) and the docker build expect.
#
# Produces:
#   Installs/dist/cockpit_v2.tar.gz      (pc installer, --v2)
#   Installs/dist/cockpit_v1.tar.gz      (pc installer, --v1)
#   Installs/docker/v2/web/  Installs/docker/v1/web/   (docker COCKPIT_EDITION)
#
# Tarball layout (what install_cockpit.sh requires):
#   cockpit/web/          — app php + index.html (+ builtins/assets for v1)
#   cockpit/scripts/      — agent runtime scripts (deployed to ~/scripts)
#   cockpit/seed_combos/  — combos_ollama.json / _localai.json / _dual.json (50 each)
#   cockpit/VERSION, cockpit/MANIFEST.txt
#
# Re-run any time; it rebuilds from repo sources + the v1 backup tarball.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO/Installs/dist"
DOCKER="$REPO/Installs/docker"
COMBO_SRC="$REPO/notes/combo_packs"
V1_BACKUP="${V1_BACKUP:-$REPO/notes/backups/tri_agent_tarballs/cockpit_live_backup_v1.0.0_20260618.tar.gz}"

RUNTIME_SCRIPTS=(agent_loop.sh ai_bridge.sh cockpit_start.sh cockpit_stop.sh
                 crud_executor.sh hardware_scan.sh files.php relay_poller.php
                 relay_start.sh relay_stop.sh themes.php web_server.sh
                 install_capabilities.sh cockpit_restore.sh cockpit_guard.sh install_bw.sh install_hotkey.sh cockpit_cron.sh history_cli.php crud_cli.php cockpit_sup_config.php cockpit_sup_autostart.sh)

# Native window: prebuilt binary + Apache-2.0 sources (see shell/README.md).
stage_shell() {
    [ -f "$REPO/shell/cockpit_shell.pas" ] || return 0
    command -v fpc >/dev/null 2>&1 && bash "$REPO/shell/build.sh" "$REPO/shell/cockpit_shell" >/dev/null
    [ -x "$REPO/shell/cockpit_shell" ] && cp "$REPO/shell/cockpit_shell" "$1/cockpit_shell"
    mkdir -p "$1/cockpit_shell_src"
    cp "$REPO/shell/cockpit_shell.pas" "$REPO/shell/build.sh" "$REPO/shell/README.md" "$1/cockpit_shell_src/"
}

# The agent engine (aicengine, Free Pascal): prebuilt x86-64 binary + its sources, like the native window. Opt-in at run
# time (agent_loop.sh uses it only when COCKPIT_ENGINE=1 or cockpit_data/use_engine exists); the Bash path is the fallback.
stage_engine() {
    [ -f "$REPO/engine/src/aicengine.lpr" ] || return 0
    command -v fpc >/dev/null 2>&1 && bash "$REPO/engine/build.sh" "$REPO/engine/aicengine" >/dev/null
    [ -x "$REPO/engine/aicengine" ] && cp "$REPO/engine/aicengine" "$1/aicengine"
    rm -rf "$1/aicengine_src"; mkdir -p "$1/aicengine_src"
    cp -r "$REPO/engine/src" "$REPO/engine/adapters" "$REPO/engine/build.sh" "$REPO/engine/README.md" "$1/aicengine_src/"
}

# The web server (aicserver, Free Pascal): prebuilt x86-64 binary + its sources, like the engine. Opt-in at run time (a file called
# use_aicserver in cockpit_data makes the supervisor run it, with php-cgi, on a side port next to Apache); Apache stays the default.
stage_webserver() {
    [ -f "$REPO/webserver/src/aicserver.lpr" ] || return 0
    command -v fpc >/dev/null 2>&1 && bash "$REPO/webserver/build.sh" "$REPO/webserver/aicserver" >/dev/null
    [ -x "$REPO/webserver/aicserver" ] && cp "$REPO/webserver/aicserver" "$1/aicserver"
    rm -rf "$1/aicserver_src"; mkdir -p "$1/aicserver_src"
    cp -r "$REPO/webserver/src" "$REPO/webserver/build.sh" "$REPO/webserver/README.md" "$1/aicserver_src/"
}

# The process supervisor (aicsupervisor, Free Pascal): prebuilt x86-64 binary + its sources, like the engine. Opt-in at run time
# (cockpit_start.sh uses it only when cockpit_data/use_supervisor exists); tmux is the default and the fallback.
stage_supervisor() {
    [ -f "$REPO/supervisor/src/aicsupervisor.lpr" ] || return 0
    command -v fpc >/dev/null 2>&1 && bash "$REPO/supervisor/build.sh" "$REPO/supervisor/aicsupervisor" >/dev/null
    [ -x "$REPO/supervisor/aicsupervisor" ] && cp "$REPO/supervisor/aicsupervisor" "$1/aicsupervisor"
    rm -rf "$1/aicsupervisor_src"; mkdir -p "$1/aicsupervisor_src"
    cp -r "$REPO/supervisor/src" "$REPO/supervisor/build.sh" "$REPO/supervisor/README.md" "$1/aicsupervisor_src/"
}

say(){ printf '3[36m▶3[0m %s\n' "$1"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$1"; }

# Regenerate the 50-combo base packs so seed_combos always has all three runners
# (ollama_base was previously missing — gen_combos.py now emits it).
gen_combos() {
    # Regenerate from source only when the dev-only combo_packs tree is present.
    # On a checkout without notes/combo_packs (source lives on the original dev
    # box), skip — stage_seed_combos() falls back to the packs already inside the
    # existing dist tarball, so builds still produce complete seed_combos.
    if [ -f "$COMBO_SRC/gen_combos.py" ]; then
        say "Generating 50-combo base packs (ollama/localai/dual)"
        ( cd "$COMBO_SRC" && python3 gen_combos.py >/dev/null )
        ok "base packs generated in $COMBO_SRC"
    else
        say "combo_packs source absent ($COMBO_SRC) — will reuse packs from existing dist"
    fi
}
stage_seed_combos() {  # $1 = dest seed_combos dir
    local d="$1"; mkdir -p "$d"
    if [ -f "$COMBO_SRC/ollama_base.json" ]; then
        cp "$COMBO_SRC/ollama_base.json"  "$d/combos_ollama.json"
        cp "$COMBO_SRC/localai_base.json" "$d/combos_localai.json"
        cp "$COMBO_SRC/dual_base.json"    "$d/combos_dual.json"
    else
        # Fallback: lift the already-generated packs out of the existing dist.
        # (extract-then-check; no `tar | grep -q` — that trips pipefail via SIGPIPE.)
        if [ -f "$DIST/cockpit_v2.tar.gz" ]; then
            tar xzOf "$DIST/cockpit_v2.tar.gz" cockpit/seed_combos/combos_ollama.json  > "$d/combos_ollama.json"  2>/dev/null || true
            tar xzOf "$DIST/cockpit_v2.tar.gz" cockpit/seed_combos/combos_localai.json > "$d/combos_localai.json" 2>/dev/null || true
            tar xzOf "$DIST/cockpit_v2.tar.gz" cockpit/seed_combos/combos_dual.json    > "$d/combos_dual.json"    2>/dev/null || true
        fi
        if [ ! -s "$d/combos_ollama.json" ]; then
            echo "  ✗ no combo packs: neither $COMBO_SRC nor an existing dist tarball has them" >&2
            return 1
        fi
    fi
}
write_manifest() {  # $1 = cockpit/ dir
    ( cd "$1" && {
        echo "# Cockpit — built $(date -Iseconds)"
        echo "# format: <sha256>  <relative path>"
        echo ""
        find web scripts seed_combos -type f 2>/dev/null | sort | while read -r f; do sha256sum "$f"; done
    } > MANIFEST.txt )
}

build_v2() {
    say "Building V2 (current repo)"
    local S; S="$(mktemp -d)"; local C="$S/cockpit"
    mkdir -p "$C/web" "$C/scripts"
    # web = the whole app webroot (php, html, logos, favicons, assets/, bin/,
    # cockpit_builtins/, …) minus dev-only cruft. Just copying *.php would drop
    # every image and the builtin capabilities.
    # cockpit_data/ is developer runtime state (transcripts, controls) — must
    # never ship; the installer creates a fresh one. Also drop editor dup files
    # ("index (copy).html") and dev cruft.
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude='*.bak' --exclude='*.bak.*' --exclude='*.confirm' \
              --exclude='*.pas' --exclude='.git*' --exclude='cockpit_data' \
              --exclude='ollama_usage.jsonl' \
              --exclude='* (copy)*' --exclude='* (another copy)*' \
              "$REPO/cockpit_app/" "$C/web/"
    else
        cp -r "$REPO/cockpit_app/." "$C/web/"
        rm -rf "$C/web/cockpit_data"
        find "$C/web" \( -name '*.bak' -o -name '*.bak.*' -o -name '*.confirm' \
             -o -name '*.pas' -o -name 'ollama_usage.jsonl' \
             -o -name '* (copy)*' -o -name '* (another copy)*' \) -delete
    fi
    # Runtime blackboard must ship NEUTRAL — never the developer's last-open
    # project/chat (a stale project_state.json makes fresh installs auto-open a
    # phantom chat that isn't in their list).
    printf '{\n    "project_name": "default",\n    "chat_name": "default",\n    "last_updated": ""\n}\n' > "$C/web/project_state.json"
    # Same reasoning for paths.json: the dev tree's copy holds THIS machine's
    # absolute paths (home, cockpit_data, projects_root, tmux socket). The
    # installer only rewrites projects_root and preserves the rest, so shipping
    # ours would both leak the build machine's layout and leave a fresh install
    # pointing at directories that do not exist on it. Every key dropped here
    # has a sane fallback in paths.php (HOME/OS defaults, web-root-relative
    # socket + queue), which is what a new install should use.
    printf '{\n    "_comment": "AI Cockpit — runtime path configuration. Set projects_root here (the installer does it for you); every other path falls back to a sane default computed by paths.php. Edit via the Library/Config tab or a text editor; changes apply on the next request."\n}\n' > "$C/web/paths.json"
    # COCKPIT.md ships too, and its TRANSCRIPT_DIR line is LIVE CONFIG read by
    # saver.php -- not a comment. This tree pins it to this machine's
    # cockpit_data, so every install was told to write transcripts to a path
    # that does not exist for it (saver.php then warns it cannot create it).
    # Drop the pin; saver.php's default is <web_root>/cockpit_data/transcripts/,
    # which is correct on any machine.
    if [ -f "$C/web/COCKPIT.md" ]; then
        sed -i '/^[[:space:]]*TRANSCRIPT_DIR[[:space:]]/d' "$C/web/COCKPIT.md"
    fi
    # scripts = runtime set (skip any not present)
    local f; for f in "${RUNTIME_SCRIPTS[@]}"; do
        [ -f "$REPO/scripts/$f" ] && cp "$REPO/scripts/$f" "$C/scripts/"
    done
    stage_shell "$C/scripts"
    stage_engine "$C/scripts"
    stage_supervisor "$C/scripts"
    stage_webserver "$C/scripts"
    stage_seed_combos "$C/seed_combos"
    local ver; ver="$(cat "$REPO/cockpit_app/VERSION" 2>/dev/null || echo '2.0.0')"
    echo "$ver" > "$C/VERSION"; echo "$ver" > "$C/web/VERSION"
    echo v2 > "$C/web/.edition"   # edition marker (V2 = Full; default)
    for _l in LICENSE.md NOTICE TERMS.md; do cp "$REPO/$_l" "$C/web/$_l" 2>/dev/null || true; done
    bash "$REPO/Installs/build_integrity.sh" "$C/web" "$C/scripts" >/dev/null   # integrity.json (2026-09-13)
    write_manifest "$C"
    mkdir -p "$DIST"
    ( cd "$S" && tar -czf "$DIST/cockpit_v2.tar.gz" cockpit )
    # docker staging
    rm -rf "$DOCKER/v2"; mkdir -p "$DOCKER/v2"; cp -r "$C/web" "$DOCKER/v2/web"
    rm -rf "$S"
    ok "cockpit_v2.tar.gz  ($(du -h "$DIST/cockpit_v2.tar.gz" | cut -f1))  + docker/v2/web"
}

build_v1() {
    # Post edition-unification: V1 is the SAME cockpit_app tree as V2, only the
    # .edition marker differs (v1 → SaaS muted by edition.php, everything else
    # real). The legacy $V1_BACKUP 1.0.0 fork is no longer used.
    say "Building V1 (unified cockpit_app tree + .edition=v1)"
    local S; S="$(mktemp -d)"; local C="$S/cockpit"
    mkdir -p "$C/web" "$C/scripts"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude='*.bak' --exclude='*.bak.*' --exclude='*.confirm' \
              --exclude='*.pas' --exclude='.git*' --exclude='cockpit_data' \
              --exclude='ollama_usage.jsonl' \
              --exclude='* (copy)*' --exclude='* (another copy)*' \
              "$REPO/cockpit_app/" "$C/web/"
    else
        cp -r "$REPO/cockpit_app/." "$C/web/"
        rm -rf "$C/web/cockpit_data"
        find "$C/web" \( -name '*.bak' -o -name '*.bak.*' -o -name '*.confirm' \
             -o -name '*.pas' -o -name 'ollama_usage.jsonl' \
             -o -name '* (copy)*' -o -name '* (another copy)*' \) -delete
    fi
    printf '{\n    "project_name": "default",\n    "chat_name": "default",\n    "last_updated": ""\n}\n' > "$C/web/project_state.json"
    # Same reasoning for paths.json: the dev tree's copy holds THIS machine's
    # absolute paths (home, cockpit_data, projects_root, tmux socket). The
    # installer only rewrites projects_root and preserves the rest, so shipping
    # ours would both leak the build machine's layout and leave a fresh install
    # pointing at directories that do not exist on it. Every key dropped here
    # has a sane fallback in paths.php (HOME/OS defaults, web-root-relative
    # socket + queue), which is what a new install should use.
    printf '{\n    "_comment": "AI Cockpit — runtime path configuration. Set projects_root here (the installer does it for you); every other path falls back to a sane default computed by paths.php. Edit via the Library/Config tab or a text editor; changes apply on the next request."\n}\n' > "$C/web/paths.json"
    # COCKPIT.md ships too, and its TRANSCRIPT_DIR line is LIVE CONFIG read by
    # saver.php -- not a comment. This tree pins it to this machine's
    # cockpit_data, so every install was told to write transcripts to a path
    # that does not exist for it (saver.php then warns it cannot create it).
    # Drop the pin; saver.php's default is <web_root>/cockpit_data/transcripts/,
    # which is correct on any machine.
    if [ -f "$C/web/COCKPIT.md" ]; then
        sed -i '/^[[:space:]]*TRANSCRIPT_DIR[[:space:]]/d' "$C/web/COCKPIT.md"
    fi
    local f; for f in "${RUNTIME_SCRIPTS[@]}"; do
        [ -f "$REPO/scripts/$f" ] && cp "$REPO/scripts/$f" "$C/scripts/"
    done
    stage_shell "$C/scripts"
    stage_engine "$C/scripts"
    stage_supervisor "$C/scripts"
    stage_webserver "$C/scripts"
    stage_seed_combos "$C/seed_combos"
    local ver; ver="$(cat "$REPO/cockpit_app/VERSION" 2>/dev/null || echo '2.0.0')"
    echo "$ver" > "$C/VERSION"; echo "$ver" > "$C/web/VERSION"
    echo v1 > "$C/web/.edition"   # edition marker → No-Account edition
    for _l in LICENSE.md NOTICE TERMS.md; do cp "$REPO/$_l" "$C/web/$_l" 2>/dev/null || true; done
    bash "$REPO/Installs/build_integrity.sh" "$C/web" "$C/scripts" >/dev/null
    write_manifest "$C"
    mkdir -p "$DIST"
    ( cd "$S" && tar -czf "$DIST/cockpit_v1.tar.gz" cockpit )
    rm -rf "$DOCKER/v1"; mkdir -p "$DOCKER/v1"; cp -r "$C/web" "$DOCKER/v1/web"
    rm -rf "$S"
    ok "cockpit_v1.tar.gz  ($(du -h "$DIST/cockpit_v1.tar.gz" | cut -f1))  + docker/v1/web"
}

gen_combos
build_v2
build_v1
say "Done — artifacts in $DIST and $DOCKER/{v1,v2}/web"
