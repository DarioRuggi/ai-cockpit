#!/usr/bin/env bash
# =============================================================================
# install_libretranslate.sh — local LibreTranslate for AI Cockpit's Translate.
#
# Installs LibreTranslate into a self-contained Python venv (no Docker needed),
# pre-downloads the requested language models, and writes a start script that
# cockpit_start.sh launches so http://localhost:5000 is up with the cockpit.
#
# Usage:
#   install_libretranslate.sh [--langs en,he] [--port 5000] [--prefix DIR]
# Env: LT_LANGS, LT_PORT, LT_PREFIX override the same.
# =============================================================================
set -euo pipefail

LT_LANGS="${LT_LANGS:-en,he}"
LT_PORT="${LT_PORT:-5000}"
LT_PREFIX="${LT_PREFIX:-$HOME/libretranslate}"   # models cache + log only
SCRIPTS_DIR="${SCRIPTS_DIR:-$HOME/scripts}"
# ONE shared virtualenv for ALL cockpit Python features (LibreTranslate, and any
# future venv-needing tool). Every such feature installs into this same venv.
COCKPIT_VENV="${COCKPIT_VENV:-$HOME/scripts/cockpit_data/venv}"

while [ $# -gt 0 ]; do
    case "$1" in
        --langs)  LT_LANGS="$2"; shift 2 ;;
        --port)   LT_PORT="$2";  shift 2 ;;
        --prefix) LT_PREFIX="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

VENV="$COCKPIT_VENV"
LT_BIN="$VENV/bin/libretranslate"

say "LibreTranslate install → venv $VENV  (langs: $LT_LANGS, port: $LT_PORT)"
mkdir -p "$LT_PREFIX" "$SCRIPTS_DIR" "$(dirname "$VENV")"

# 1. shared cockpit venv (reused by every python feature)
if [ ! -x "$VENV/bin/python" ]; then
    say "Creating shared cockpit venv: $VENV"
    python3 -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --quiet --upgrade pip setuptools wheel >/dev/null 2>&1 || true

# ── installing into the SHARED venv ──────────────────────────────────────────
# One venv means one namespace: every package exists at exactly ONE version, so
# a second feature can silently re-resolve the first one's dependencies. pip does
# not check -- it resolves for what you asked for and overwrites the rest.
#
# Measured 2026-09-24: a plain `pip install faster-whisper` into this venv wants
# numpy 1.26.4 -> 2.5.3, crossing the boundary LibreTranslate's ctranslate2 stack
# sits on. Translate would break days later, pointing at the wrong cause. With the
# current freeze held as constraints it resolves with ZERO changes and works.
#
# So: hold the freeze as constraints on every install here. An install may ADD
# packages; it may not CHANGE a version something else already depends on.
CONSTRAINTS="$VENV/constraints.txt"

venv_pip_install() {
    local rc=0 filtered="" a p upgrading=0
    # Only an EXPLICIT upgrade may lift a constraint. Without this the helper
    # would drop the pin for whatever it was asked to install, so a direct
    # `numpy>=2` would sail through and break LibreTranslate -- which is exactly
    # what this guard exists to stop. Caught by the test, 2026-09-24.
    for a in "$@"; do
        case "$a" in -U|--upgrade) upgrading=1 ;; esac
    done
    if [ -s "$CONSTRAINTS" ]; then
        filtered="$(mktemp)"; cp "$CONSTRAINTS" "$filtered"
        # When upgrading, do not constrain the named package -- yt-dlp MUST stay
        # current or YouTube breaks it within months. Everything else stays held.
        [ "$upgrading" = 1 ] && for a in "$@"; do
            case "$a" in -*) continue ;; esac
            p="${a%%[<>=!~]*}"
            awk -v p="$p" '
                function norm(x){ gsub(/[-_]/,"-",x); return tolower(x) }
                { n=$0; sub(/[=<>!~[].*/,"",n); if (norm(n) != norm(p)) print }
            ' "$filtered" > "$filtered.n" && mv "$filtered.n" "$filtered"
        done
        "$VENV/bin/pip" install --quiet -c "$filtered" "$@" || rc=$?
        rm -f "$filtered" "$filtered.n"
    else
        "$VENV/bin/pip" install --quiet "$@" || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        warn "pip refused to install: $*"
        warn "It cannot be added without changing a version another feature depends on."
        warn "NOTHING was changed. Give it its own venv or a container -- that is the supported answer."
        return "$rc"
    fi
    # Refresh the baseline so the next install is held to what is there now.
    "$VENV/bin/pip" freeze > "$CONSTRAINTS" 2>/dev/null || true
    return 0
}

# 2. install libretranslate (ctranslate2 ships prebuilt wheels — no compiler needed)
if [ ! -x "$LT_BIN" ]; then
    say "Installing libretranslate (this downloads a few hundred MB)…"
    # First real install: there is no baseline yet, so this one DEFINES it.
    venv_pip_install libretranslate
fi
ok "libretranslate: $("$LT_BIN" --version 2>/dev/null || echo installed)"

# yt-dlp is NO LONGER installed here (2026-09-24). It used to go into this venv to
# stay current, which quietly made the Transcriber depend on Python even for users
# who never wanted Translate -- and tied it to this venv's lifetime. The installer
# now places the SELF-CONTAINED build (Python bundled inside) in /usr/local/bin,
# which `yt-dlp -U` keeps current by itself. paths.php prefers that copy and falls
# back to a venv one so installs made before this keep working.

# 3. language config — which languages LibreTranslate loads. Editable; the start
#    script + the manager read it, so adding languages is just a config change.
LANGS_FILE="$SCRIPTS_DIR/cockpit_data/libretranslate_langs"
CACHED_FILE="$SCRIPTS_DIR/cockpit_data/libretranslate_cached"   # codes with a caged (on-disk, hidden) model
mkdir -p "$(dirname "$LANGS_FILE")"
[ -f "$LANGS_FILE" ] || printf '%s\n' "$LT_LANGS" > "$LANGS_FILE"
[ -f "$CACHED_FILE" ] || : > "$CACHED_FILE"
ok "languages config: $LANGS_FILE ($(cat "$LANGS_FILE"))"

# 4. start script (cockpit_start.sh calls this; also runnable by hand). Reads the
#    langs config each start, so no need to regenerate it when languages change.
START="$SCRIPTS_DIR/libretranslate_start.sh"
cat > "$START" <<EOF
#!/usr/bin/env bash
# Start LibreTranslate on 127.0.0.1:$LT_PORT if not already listening.
# Auto-generated by install_libretranslate.sh. Languages come from LANGS_FILE.
set -u
PORT=$LT_PORT
LANGS_FILE="$LANGS_FILE"
LANGS="\$(tr -d '[:space:]' < "\$LANGS_FILE" 2>/dev/null)"; [ -n "\$LANGS" ] || LANGS="$LT_LANGS"
if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":\${PORT}[[:space:]]"; then
    exit 0   # already up
fi
LOG="$LT_PREFIX/libretranslate.log"
nohup "$LT_BIN" --host 127.0.0.1 --port \$PORT --load-only "\$LANGS" \\
    >> "\$LOG" 2>&1 &
echo "LibreTranslate starting on 127.0.0.1:\$PORT langs=\$LANGS (log: \$LOG)"
EOF
chmod +x "$START"
ok "start script: $START"

# 5. language manager — set/add languages, then restart to load them.
#    Usage: libretranslate_langs.sh set en,he,es   |   libretranslate_langs.sh add es fr
MANAGER="$SCRIPTS_DIR/libretranslate_langs.sh"
cat > "$MANAGER" <<EOF
#!/usr/bin/env bash
# Manage which languages LibreTranslate loads, then restart it (downloads any
# newly-added models on next start). Auto-generated by install_libretranslate.sh.
set -u
LANGS_FILE="$LANGS_FILE"
CACHED_FILE="$CACHED_FILE"
START="$START"
VENV="$VENV"
LOG="$LT_PREFIX/libretranslate.log"
PORT=$LT_PORT
usage(){ echo "usage: \$0 list | set <a,b,c> | add <langs...> | remove <langs...>"; exit 1; }
cur(){ tr -d '[:space:]' < "\$LANGS_FILE" 2>/dev/null; }
save(){ printf '%s\n' "\$1" > "\$LANGS_FILE"; }
uniq_csv(){ printf '%s' "\$1" | tr ',' '\n' | awk 'NF && !seen[\$0]++' | paste -sd,; }
# Sync installed argos models to the configured language set, with CAGING:
#  - un-cage: a de-selected model isn't deleted, just moved to a sibling caged/
#    dir (LibreTranslate/argos only scan packages/, so it vanishes from /languages)
#  - re-adding a caged language moves it back (instant, no re-download)
#  - only a never-seen language is downloaded.
# (--load-only does NOT hide an installed language, so caging is what removes it.)
install_models(){
    "\$VENV/bin/python" - "\$(cur)" "\$CACHED_FILE" <<'PY'
import os, json, shutil, sys
import argostranslate.package as pkg
langs = set(x for x in sys.argv[1].split(',') if x)
cached_file = sys.argv[2] if len(sys.argv) > 2 else ''

def codes(path):
    try:
        with open(os.path.join(path, 'metadata.json')) as f:
            m = json.load(f); return m.get('from_code'), m.get('to_code')
    except Exception:
        return None, None

inst = pkg.get_installed_packages()
pkgs_dir = os.path.dirname(str(inst[0].package_path)) if inst else os.path.expanduser('~/.local/share/argos-translate/packages')
caged_dir = os.path.join(os.path.dirname(pkgs_dir), 'caged')
os.makedirs(caged_dir, exist_ok=True)

# 1. UN-CAGE: bring back caged models whose languages are now selected
for name in list(os.listdir(caged_dir)):
    src = os.path.join(caged_dir, name)
    if not os.path.isdir(src): continue
    fc, tc = codes(src)
    if fc in langs and tc in langs:
        dst = os.path.join(pkgs_dir, name)
        if not os.path.exists(dst):
            try: shutil.move(src, dst); print("uncaged", fc, tc)
            except Exception as e: print("uncage failed", fc, tc, e)

# 2. DOWNLOAD any still-missing selected pairs
try: pkg.update_package_index()
except Exception as e: print("index update failed:", e)
have = {(p.from_code, p.to_code) for p in pkg.get_installed_packages()}
for p in pkg.get_available_packages():
    if p.from_code in langs and p.to_code in langs and (p.from_code, p.to_code) not in have:
        try: p.install(); print("installed", p.from_code, p.to_code)
        except Exception as e: print("install failed", p.from_code, p.to_code, e)

# 3. CAGE de-selected models (keep on disk, hidden from LibreTranslate)
for p in pkg.get_installed_packages():
    if p.from_code not in langs or p.to_code not in langs:
        src = str(p.package_path)
        dst = os.path.join(caged_dir, os.path.basename(src))
        try:
            if os.path.exists(dst): shutil.rmtree(dst)
            shutil.move(src, dst); print("caged", p.from_code, p.to_code)
        except Exception as e: print("cage failed", p.from_code, p.to_code, e)

# record which languages are currently caged (on disk, hidden) for the UI badge
caged_langs = set()
for name in os.listdir(caged_dir):
    p = os.path.join(caged_dir, name)
    if os.path.isdir(p):
        fc, tc = codes(p)
        for c in (fc, tc):
            if c and c not in langs:
                caged_langs.add(c)
if cached_file:
    try:
        with open(cached_file, 'w') as f: f.write(','.join(sorted(caged_langs)))
    except Exception as e: print("cached-list write failed:", e)
print("models synced (caged/uncaged) to:", ",".join(sorted(langs)), "| caged:", ",".join(sorted(caged_langs)))
PY
}
# Synchronous apply (download models, then restart). Run in the background by the
# set/add/remove commands so callers (incl. the web UI) return immediately.
_apply(){
    install_models
    pkill -f "libretranslate .*--port \$PORT" 2>/dev/null || true
    sleep 1; "\$START"
}
apply_bg(){ nohup "\$0" _apply >> "\$LOG" 2>&1 & echo "Applying in background — models download then LibreTranslate restarts. Watch: \$LOG"; }
cmd="\${1:-list}"; shift || true
case "\$cmd" in
    list) echo "loaded: \$(cur)";;
    _apply) _apply;;
    set)  [ \$# -ge 1 ] || usage; save "\$(uniq_csv "\$1")"; echo "set: \$(cur)"; apply_bg;;
    add)  [ \$# -ge 1 ] || usage; save "\$(uniq_csv "\$(cur),\$(printf '%s,' "\$@")")"; echo "now: \$(cur)"; apply_bg;;
    remove) [ \$# -ge 1 ] || usage; keep="\$(cur)"; for l in "\$@"; do keep="\$(printf '%s' "\$keep" | tr ',' '\n' | grep -vx "\$l" | paste -sd,)"; done; save "\$keep"; echo "now: \$(cur)"; apply_bg;;
    *) usage;;
esac
EOF
chmod +x "$MANAGER"
ok "language manager: $MANAGER  (e.g. '$MANAGER add es fr')"

# 6. warm the models (first run downloads argos packages for the langs)
say "Downloading language models for: $LT_LANGS (first run only)…"
"$START" >/dev/null 2>&1 || true
# wait up to 180s for the port to answer /languages
for i in $(seq 1 180); do
    if curl -fsS "http://127.0.0.1:$LT_PORT/languages" >/dev/null 2>&1; then
        ok "LibreTranslate is up on http://localhost:$LT_PORT"
        exit 0
    fi
    sleep 1
done
warn "Port $LT_PORT not answering yet — models may still be downloading."
warn "Check $LT_PREFIX/libretranslate.log; re-run $START once done."
exit 0
