#!/usr/bin/env bash
# =============================================================================
# cockpit_restore.sh — put the shipped files back from the bundle the installer
# kept (cockpit_data/install_src/), for an install whose integrity check lists
# changed or missing files. Never touches config.php, paths.json, .edition,
# cockpit_data/ or any user data. Asks for sudo only when the web root needs it.
#
#   ~/scripts/cockpit_restore.sh [--web /var/www/html/cockpit] [--dry-run] [file ...]
#   no files → every shipped file that differs from the manifest is restored.
# =============================================================================
set -euo pipefail
WEB=""; DRY=0; ONLY=()
while [ $# -gt 0 ]; do case "$1" in --web) WEB="$2"; shift 2 ;; --dry-run) DRY=1; shift ;; *) ONLY+=("$1"); shift ;; esac; done
[ -n "$WEB" ] || for c in /var/www/html/cockpit /var/www/html/cockpit-v1 /srv/http/cockpit; do [ -f "$c/integrity.json" ] && { WEB="$c"; break; }; done
[ -n "$WEB" ] && [ -f "$WEB/integrity.json" ] || { echo "no Cockpit web root with integrity.json found (use --web)"; exit 1; }
CD=$(php -r 'require "'"$WEB"'/paths.php"; echo $PATHS["cockpit_data"];' 2>/dev/null || echo "$HOME/scripts/cockpit_data")
SRC=""; for b in "$CD/install_src/cockpit_install.tar.gz" "$CD/install_src/cockpit_app.tar.gz"; do [ -f "$b" ] && { SRC="$b"; break; }; done
[ -n "$SRC" ] || { echo "no kept bundle under $CD/install_src/ — re-download from https://cockpit.ruggi.site/download.php and re-run the installer"; exit 2; }
ED=$(cat "$WEB/.edition" 2>/dev/null || echo v2)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "bundle: $SRC   web root: $WEB   edition: $ED"
tar xzf "$SRC" -C "$T"
INNER=$(find "$T" -name "cockpit_${ED}.tar.gz" | head -1); [ -n "$INNER" ] || INNER=$(find "$T" -name "cockpit_v2.tar.gz" | head -1)
if [ -n "$INNER" ]; then mkdir -p "$T/in"; tar xzf "$INNER" -C "$T/in"; SRCWEB=$(find "$T/in" -type d -name web | head -1); else SRCWEB=$(find "$T" -type d -name web | head -1); fi
[ -n "$SRCWEB" ] && [ -f "$SRCWEB/integrity.json" ] || { echo "the kept bundle has no web/integrity.json"; exit 3; }
S=""; [ -w "$WEB/index.html" ] || S="sudo"   # shipped files are root-owned under lockdown
# which files: the named ones, or everything the current manifest says differs
if [ ${#ONLY[@]} -eq 0 ]; then
    # mapfile is bash 4 ONLY and macOS ships bash 3.2 — read the list the
    # portable way instead. IFS= and -r keep spaces and backslashes intact.
    ONLY=()
    while IFS= read -r _f; do [ -n "$_f" ] && ONLY+=("$_f"); done < <(cd "$WEB" && php -r 'require "integrity_lib.php"; $m=integrity_manifest(); $c=[]; $x=[]; integrity_compute($m,$c,$x); foreach (array_merge($c,$x) as $f) echo $f,"\n";')
fi
[ ${#ONLY[@]} -gt 0 ] || { echo "nothing to restore — the install matches its manifest"; exit 0; }
n=0
for f in "${ONLY[@]}"; do
    case "$f" in scripts/*) src="$SRCWEB/../scripts/${f#scripts/}"; dst="$HOME/scripts/${f#scripts/}" ;; *) src="$SRCWEB/$f"; dst="$WEB/$f" ;; esac
    case "$(basename "$f")" in config.php|paths.json|.edition) echo "skip (install-owned): $f"; continue ;; esac
    [ -f "$src" ] || { echo "not in bundle: $f"; continue; }
    if [ "$DRY" = 1 ]; then echo "would restore: $f"; else
        $S mkdir -p "$(dirname "$dst")"; $S cp "$src" "$dst"
        if [ "$(stat -c %U "$WEB/index.html" 2>/dev/null)" = root ]; then $S chown root:root "$dst"; if [ -x "$dst" ]; then $S chmod 0755 "$dst"; else $S chmod 0644 "$dst"; fi   # lockdown layout
        else $S chmod 0664 "$dst" 2>/dev/null || true; fi
        echo "restored: $f"; fi
    n=$((n+1))
done
echo "$n file(s) $([ "$DRY" = 1 ] && echo 'would be ' )restored. Reload the app; the Integrity panel should now read intact."
