#!/usr/bin/env bash
# =============================================================================
# install_user_mode.sh — install AI Cockpit WITHOUT administrator rights and WITHOUT Apache.
#
#   bash install_user_mode.sh [--bundle FILE] [--edition v2|v1|both] [--projects DIR] [--upgrade]
#
# What it does (all inside your home folder; nothing is run with sudo, nothing outside $HOME is touched):
#   * unpacks the web app to   ~/.local/share/cockpit-web/cockpit      (V1: .../cockpit-v1)
#   * unpacks the scripts and the prebuilt programs (supervisor, engine, aicserver, window) to   ~/scripts
#   * writes paths.json, creates the data and projects folders, and switches on the self-contained mode:
#       use_supervisor + use_aicserver in ~/scripts/cockpit_data   (aicserver and php-cgi under the supervisor, on 127.0.0.1:8081)
#   * adds the commands cockpit-self-start / cockpit-self-stop (V1: cockpit-v1-self-start) in ~/.local/bin and menu entries.
# Start it with  cockpit-self-start.
#
# What it needs on the machine already (it checks, and tells you the package names; it installs nothing itself):
#   php (command line), php-cgi, the php modules sqlite3, curl, mbstring, xml; tmux, jq, curl.
#
# Refuses to touch an existing installation (~/scripts/cockpit_start.sh present) unless you pass --upgrade.
# The bundle is cockpit_install.tar.gz (the same file the ordinary installer ships in); the default is the one next to this script, or
# ../server_mirror/cockpit.ruggi.site/downloads/ when run from a source checkout.
# =============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE=""; EDITION="v2"; PROJECTS="$HOME/AI-Cockpit/projects"; UPGRADE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle) BUNDLE="$2"; shift 2 ;;
        --edition) EDITION="$2"; shift 2 ;;
        --projects) PROJECTS="$2"; shift 2 ;;
        --upgrade) UPGRADE=1; shift ;;
        -h|--help) sed -n 2,26p "$0"; exit 0 ;;
        *) echo "unknown option: $1"; exit 2 ;;
    esac
done
case "$EDITION" in v1|v2|both) ;; *) echo "--edition must be v2, v1 or both"; exit 2 ;; esac
[ "$(id -u)" != 0 ] || { echo "Run this as yourself, not as root: it installs into your home folder."; exit 2; }
say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ── the bundle ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
if [ -z "$BUNDLE" ]; then
    for c in "$HERE/cockpit_install.tar.gz" "$HERE/../cockpit_install.tar.gz" "$HERE/../server_mirror/cockpit.ruggi.site/downloads/cockpit_install.tar.gz"; do
        [ -f "$c" ] && { BUNDLE="$c"; break; }
    done
fi
DIST=""
[ -z "$BUNDLE" ] && [ -f "$HERE/dist/cockpit_v2.tar.gz" ] && DIST="$HERE/dist"      # run from an unpacked bundle: dist/ is right beside this script
[ -n "$DIST" ] || [ -f "$BUNDLE" ] || die "no bundle found: pass --bundle /path/to/cockpit_install.tar.gz"

# ── prerequisites: report, install nothing ──────────────────────────────────────────────────────────────────────────────────────────
missing=""; need() { command -v "$1" >/dev/null 2>&1 || missing="$missing $2"; }
need php php-cli; need php-cgi php-cgi; need tmux tmux; need jq jq; need curl curl; need tar tar
if command -v php >/dev/null 2>&1; then
    for m in sqlite3 curl mbstring xml; do
        php -m 2>/dev/null | grep -qix "$m" || missing="$missing php-$m"
    done
fi
if [ -n "$missing" ]; then
    say "Missing on this machine:$missing"
    if command -v apt-get >/dev/null 2>&1; then say "  (as an administrator)  sudo apt install$(printf ' %s' $missing | sed 's/ php-cli/ php-cli/')"
    elif command -v dnf >/dev/null 2>&1; then say "  (as an administrator)  sudo dnf install$(printf ' %s' $missing | sed 's/php-cli/php-cli/; s/php-sqlite3/php-pdo/; s/php-xml/php-xml/')"
    elif command -v pacman >/dev/null 2>&1; then say "  (as an administrator)  sudo pacman -S php php-cgi php-sqlite tmux jq curl"
    elif command -v zypper >/dev/null 2>&1; then say "  (as an administrator)  sudo zypper install php8 php8-cgi php8-sqlite php8-curl php8-mbstring php8-xmlreader tmux jq curl"
    fi
    say "Install those (or ask whoever administers this machine), then run this again. Nothing was changed."
    exit 1
fi

# ── refuse to overwrite an existing install ─────────────────────────────────────────────────────────────────────────────────────────
if [ -e "$HOME/scripts/cockpit_start.sh" ] && [ "$UPGRADE" != 1 ]; then
    die "an installation already exists in ~/scripts (cockpit_start.sh). Pass --upgrade to replace its programs and the web app (your data and settings are kept)."
fi

T="$(mktemp -d)" || die "no temporary folder"; trap 'rm -rf "${T:?}"' EXIT
say "Unpacking the bundle ..."
if [ -n "$DIST" ]; then mkdir -p "$T/cockpit" && ln -s "$DIST" "$T/cockpit/dist"
else tar xzf "$BUNDLE" -C "$T" cockpit/dist 2>/dev/null || die "that file is not a Cockpit install bundle (no cockpit/dist)"; fi

WEBBASE="$HOME/.local/share/cockpit-web"; mkdir -p "$WEBBASE" "$HOME/scripts" "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"
install_edition() {   # install_edition v2|v1
    local ed="$1" tgz mnt data
    tgz="$T/cockpit/dist/cockpit_$ed.tar.gz"; [ -f "$tgz" ] || die "the bundle has no $ed edition"
    case "$ed" in v1) mnt="cockpit-v1"; data="$HOME/scripts/cockpit_data_v1" ;; *) mnt="cockpit"; data="$HOME/scripts/cockpit_data" ;; esac
    mkdir -p "$T/x_$ed" && tar xzf "$tgz" -C "$T/x_$ed" || die "could not unpack the $ed edition"
    local src="$T/x_$ed/cockpit"; [ -d "$src/web" ] || die "the $ed archive has no web folder"
    # the web app: replaced as a whole (it is shipped code, not data); the per-install files are kept on --upgrade
    local keep=""; if [ -d "$WEBBASE/$mnt" ]; then keep="$T/keep_$ed"; mkdir -p "$keep"; for f in paths.json project_state.json workers_quotas.json; do [ -f "$WEBBASE/$mnt/$f" ] && cp "$WEBBASE/$mnt/$f" "$keep/"; done; rm -rf "$WEBBASE/$mnt.old"; mv "$WEBBASE/$mnt" "$WEBBASE/$mnt.old"; fi
    mkdir -p "$WEBBASE/$mnt"; cp -a "$src/web/." "$WEBBASE/$mnt/"
    [ -n "$keep" ] && cp -a "$keep/." "$WEBBASE/$mnt/" 2>/dev/null
    mkdir -p "$WEBBASE/$mnt/queue" "$WEBBASE/$mnt/responses" "$data" "$PROJECTS"
    chmod 775 "$WEBBASE/$mnt/queue" "$WEBBASE/$mnt/responses" 2>/dev/null
    # paths.json: the bundle ships a template without paths; ALWAYS set home, the data folder and the projects folder explicitly (the app's
    # fall-back is computed from the account database, which is not what a user-mode install, or a test home, should rely on). Anything else in
    # an existing file is kept.
    local p="$PROJECTS"; [ "$ed" = v1 ] && p="$PROJECTS-v1"; mkdir -p "$p"
    local pj="$WEBBASE/$mnt/paths.json"; [ -f "$pj" ] || echo '{}' > "$pj"
    jq --arg pr "$p" --arg h "$HOME" --arg d "$data" '.home = $h | .cockpit_data = (.cockpit_data // $d) | .projects_root = (.projects_root // $pr)' "$pj" > "$pj.new" && mv -f "$pj.new" "$pj" || die "could not write paths.json"
    # the programs and scripts: shared by both editions, copied once (the later one wins, they are identical)
    if [ -d "$src/scripts" ]; then cp -a "$src/scripts/." "$HOME/scripts/"; fi
    # the self-contained mode
    [ -f "$data/use_supervisor" ] || : > "$data/use_supervisor"
    [ -f "$data/use_aicserver" ] || : > "$data/use_aicserver"
    say "  $ed: web app in $WEBBASE/$mnt, data in $data"
}
case "$EDITION" in v2) install_edition v2 ;; v1) install_edition v1 ;; both) install_edition v2; install_edition v1 ;; esac
chmod +x "$HOME"/scripts/*.sh "$HOME"/scripts/aic* "$HOME"/scripts/cockpit_shell 2>/dev/null

# ── the programs run on this machine? (prebuilt x86-64 binaries; build from the shipped sources when they do not) ─────────────────────
runs_here() { [ -x "$HOME/scripts/$1" ] || return 1; case "$1" in aicsupervisor) "$HOME/scripts/$1" service-file systemd-user --config /x --binary /x >/dev/null 2>&1 ;; *) "$HOME/scripts/$1" version >/dev/null 2>&1 ;; esac; }
for prog in aicsupervisor aicserver aicengine; do
    if runs_here "$prog"; then continue; fi
    if command -v fpc >/dev/null 2>&1 && [ -f "$HOME/scripts/${prog}_src/build.sh" ]; then
        say "  building $prog from source for this machine ..."; bash "$HOME/scripts/${prog}_src/build.sh" "$HOME/scripts/$prog" >/dev/null 2>&1 || say "  WARNING: could not build $prog"
    else say "  WARNING: $prog does not run here and there is no Free Pascal compiler to build it (install fpc)"; fi
done

# ── commands and menu entries ───────────────────────────────────────────────────────────────────────────────────────────────────────
printf '%s\n' '#!/bin/bash' 'exec "$HOME/scripts/cockpit_start.sh" --self "$@"' > "$HOME/.local/bin/cockpit-self-start"
printf '%s\n' '#!/bin/bash' 'exec "$HOME/scripts/cockpit_stop.sh" "$@"' > "$HOME/.local/bin/cockpit-self-stop"
printf '%s\n' '#!/bin/bash' 'exec env COCKPIT_EDITION=v1 "$HOME/scripts/cockpit_start.sh" --self "$@"' > "$HOME/.local/bin/cockpit-v1-self-start"
chmod +x "$HOME/.local/bin/cockpit-self-start" "$HOME/.local/bin/cockpit-self-stop" "$HOME/.local/bin/cockpit-v1-self-start"
LOGO="$WEBBASE/cockpit/assets/logo_512.png"; [ -f "$LOGO" ] || LOGO="$WEBBASE/cockpit-v1/assets/logo_512.png"
[ -f "$LOGO" ] && cp "$LOGO" "$HOME/.local/share/icons/ai-cockpit.png"
printf '%s\n' '[Desktop Entry]' 'Version=1.0' 'Type=Application' 'Name=AI Cockpit' 'Comment=AI Cockpit (user-mode install: no Apache, no administrator rights)' \
    'Exec=cockpit-self-start' 'Icon=ai-cockpit' 'Terminal=false' 'Categories=Development;Utility;' 'StartupNotify=true' 'StartupWMClass=ai-cockpit' > "$HOME/.local/share/applications/ai-cockpit-self.desktop"
chmod +x "$HOME/.local/share/applications/ai-cockpit-self.desktop"; command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) say "NOTE: $HOME/.local/bin is not on your PATH; the menu entry works, or run $HOME/.local/bin/cockpit-self-start" ;; esac

say ""
say "Installed (user mode). Start it with:  cockpit-self-start     Stop it with:  cockpit-self-stop"
say "The app opens on http://127.0.0.1:8081/cockpit/  (V1: port 8082). The first screen asks you to create your login."
exit 0
