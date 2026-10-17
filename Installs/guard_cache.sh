# guard_cache.sh — sourced by rebuild_tarballs.sh. guard_run: run a slow guard only when its inputs changed since it last PASSED.
#
#   guard_run NAME "dep dep ..." command args...
#
# A dep is a file or a folder (relative to the repo root, or absolute). The fingerprint is a hash of the contents of every dep plus the command line;
# when it equals the one stored the last time the guard passed, the guard is skipped with a one-line note. A guard that fails stores nothing, so it
# runs again next time. A dep that is missing counts as a change. FULL=1 in the environment runs everything (do this for a release).
# Only slow guards use this: a fast one gains nothing by it and a wrong dependency list would hide a real failure.
GUARD_CACHE_DIR="${GUARD_CACHE_DIR:-${ROOT:-.}/.guard_cache}"
guard_fingerprint() {
    local d p
    { printf 'cmd:%s\n' "$*"
      for d in $GUARD_DEPS; do
          case "$d" in /*) p="$d" ;; *) p="${ROOT:-.}/$d" ;; esac
          if [ -d "$p" ]; then ( cd "$p" && find . -type f -not -path './.git/*' -print0 2>/dev/null | sort -z | xargs -0 sha256sum 2>/dev/null ) | sed "s|^|$d |"
          elif [ -f "$p" ]; then printf '%s %s\n' "$d" "$(sha256sum < "$p" | cut -c1-64)"
          else printf 'MISSING %s\n' "$d"; fi
      done; } | sha256sum | cut -c1-64
}
guard_run() {
    local name="$1" deps="$2"; shift 2
    local fp stored f="$GUARD_CACHE_DIR/$name"
    GUARD_DEPS="$deps" fp="$(GUARD_DEPS="$deps" guard_fingerprint "$@")"
    stored="$(cat "$f" 2>/dev/null)"
    if [ "${FULL:-0}" != 1 ] && [ -n "$stored" ] && [ "$stored" = "$fp" ]; then
        echo "   guard $name: skipped (its inputs are unchanged since it last passed; FULL=1 runs it anyway)" >&2
        return 0
    fi
    if "$@"; then mkdir -p "$GUARD_CACHE_DIR" 2>/dev/null && printf '%s\n' "$fp" > "$f"; return 0; fi
    rm -f "$f"; return 1
}
