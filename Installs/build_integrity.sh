#!/usr/bin/env bash
# =============================================================================
# build_integrity.sh — write <web>/integrity.json: sha256 of every shipped file
# in a Cockpit web root (+ the sibling scripts/ dir when present; the platform
# binary scripts/cockpit_shell is skipped — its sources are listed instead) and one
# build_id over the whole list. integrity.php compares the tree against it on
# demand; ruggi.site keeps the list of official build_ids (official_builds.json)
# and its account services answer only to those.
#
# Usage:  Installs/build_integrity.sh <web_dir> [scripts_dir]
#         prints the build_id on stdout.
#
# Excluded: files the install owns or the user may edit (config, paths, the
# edition marker), runtime state, the manifest itself, dev cruft. The list is
# mirrored in integrity.php (INTEGRITY_SKIP) — keep the two in step.
# =============================================================================
set -euo pipefail
WEB="${1:?web dir}"; SCR="${2:-}"
[ -d "$WEB" ] || { echo "no such dir: $WEB" >&2; exit 1; }
# Files the INSTALLER localises are excluded: hashing them means every machine
# reports "this install differs from the build" forever, on a difference that is
# correct. COCKPIT.md gains a TRANSCRIPT_DIR line pointing at the user's own data
# dir, so it tripped the Install-integrity modal on every install (2026-09-29).
# Keep this in step with ENV_FILES in scripts/demo_sync_check.sh:
#   COCKPIT.md  paths.json  project_state.json  integrity.json
# An alarm that fires on correct state stops being read — the same lesson as the
# CI portability check that flagged its own comments.
list() {
    ( cd "$WEB" && find . -type f \
        ! -name integrity.json ! -name MANIFEST.txt ! -name config.php ! -name paths.json ! -name .edition \
        ! -name 'COCKPIT.md' \
        ! -name '*.bak' ! -name '*.bak.*' ! -name '*.confirm' ! -name '*.pas' ! -name 'ollama_usage.jsonl' \
        ! -path './cockpit_data/*' ! -path './data/*' ! -path './logs/*' ! -path './projects/*' ! -path './tmp/*' \
        ! -path './queue/*' ! -path './responses/*' ! -path './.saas_home/*' ! -path './.sslcompat/*' ! -path './tools_jobs/*' \
        ! -name 'tmux.sock' ! -name '*.sock' ! -name '.lock' ! -name '*.lock' ! -name 'project_state.json' \
        ! -path './.git/*' ! -name '.DS_Store' \
        | sed 's|^\./||' )
    if [ -n "$SCR" ] && [ -d "$SCR" ]; then
        ( cd "$SCR" && find . -type f ! -name '*.bak' ! -name '*.bak.*' ! -name cockpit_shell ! -name aicengine ! -name aicsupervisor ! -name aicserver | sed 's|^\./|scripts/|' )
    fi
}
# ONE global byte-order sort over web and scripts paths — integrity_lib.php sorts
# the same way (strcmp) when it recomputes the id, so the two must agree.
list_sorted() { list | LC_ALL=C sort; }
tmp=$(mktemp)
list_sorted | while IFS= read -r f; do
    case "$f" in scripts/*) p="$SCR/${f#scripts/}" ;; *) p="$WEB/$f" ;; esac
    h=$(sha256sum "$p" | cut -d' ' -f1)
    printf '%s  %s\n' "$h" "$f"
done > "$tmp"
build_id=$(sha256sum "$tmp" | cut -d' ' -f1)
# Release-candidate number (Installs/RC_NUMBER). EMPTY means "not a candidate",
# which is the normal state — the file exists so declaring a candidate is one
# edit rather than a code change. It is stamped here so it travels with the
# build: the app reads it from integrity.json, like the build number.
RC_NO=$(tr -cd '0-9' < "$(dirname "$0")/RC_NUMBER" 2>/dev/null || true)
RC_JSON=""; [ -n "$RC_NO" ] && [ "$RC_NO" != "0" ] && RC_JSON=$(printf '\n  "rc": %s,' "$RC_NO")
# Release stage (Installs/STAGE): beta | pre-release, or empty for a final
# release. Stamped here for the same reason as the rc — the badge in the app
# is a property of the BUILD, not of the user's cloud account. It used to come
# from the site's pubconfig, which meant the Stand-alone edition could never
# show one at all: it has no account to ask. 2026-09-26.
STAGE=$(tr 'A-Z' 'a-z' < "$(dirname "$0")/STAGE" 2>/dev/null | tr -cd 'a-z-' || true)
case "$STAGE" in beta|pre-release) ;; *) STAGE="" ;; esac
STAGE_JSON=""; [ -n "$STAGE" ] && STAGE_JSON=$(printf '\n  "stage": "%s",' "$STAGE")

ver="v$(cat "$WEB/VERSION" 2>/dev/null || true)"; [ "$ver" = "v" ] && ver=$(grep -o 'v[0-9]\+\.[0-9]\+\.[0-9]\+' "$WEB/index.html" 2>/dev/null | head -1 || true)
{
    printf '{\n  "schema": 1,\n  "version": "%s",\n  "build": %s,%s%s\n  "built": "%s",\n  "build_id": "%s",\n  "files": {\n' "${ver:-}" "${COCKPIT_BUILD_NO:-0}" "${RC_JSON:-}" "${STAGE_JSON:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$build_id"
    awk 'BEGIN{first=1} { h=$1; sub(/^[^ ]+  /,""); gsub(/\\/,"\\\\",$0); gsub(/"/,"\\\"",$0); printf "%s    \"%s\": \"%s\"", (first?"":",\n"), $0, h; first=0 } END{ print "" }' "$tmp"
    printf '  }\n}\n'
} > "$WEB/integrity.json"
rm -f "$tmp"
echo "$build_id"
