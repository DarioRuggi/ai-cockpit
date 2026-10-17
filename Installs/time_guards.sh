#!/usr/bin/env bash
# time_guards.sh — run every guard of rebuild_tarballs.sh once on its own and print how long each takes, slowest first.
# Used to decide which guards are worth skipping when their inputs did not change (see Installs/guard_cache.sh).
#   bash Installs/time_guards.sh            needs no build running (the guards use temp ports and sandboxes)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; R="$ROOT/Installs/rebuild_tarballs.sh"
[ -z "$(pgrep -f '[r]ebuild_tarballs.sh|[n]ext_build.sh')" ] || { echo "a build is running: wait for it"; exit 1; }
OUT=$(mktemp); n=0
# the guard lines: they start with bash|php|node|sh, run something under tests/ or Installs/check_/gen_, and end in "|| { echo ...; exit 1; }"
grep -E '^(bash|php|node|sh) "\$ROOT/(tests/|Installs/(check_|gen_|lang_extract))' "$R" | while IFS= read -r line; do
    cmd="${line%% || *}"; cmd="${cmd%% >/dev/null*}"; cmd="${cmd//\$ROOT/$ROOT}"; cmd="${cmd//\"/}"
    s=$(date +%s.%N); eval "$cmd" >/dev/null 2>&1; rc=$?; e=$(date +%s.%N)
    printf '%6.1f s  rc=%s  %s\n' "$(echo "$e - $s" | bc)" "$rc" "$(echo "$cmd" | sed "s|$ROOT/||")" | tee -a "$OUT"
done
echo; echo "total: $(awk '{t+=$1} END {printf "%.0f s over %d guards", t, NR}' "$OUT")"; echo "slowest:"; sort -rn "$OUT" | head -12; rm -f "$OUT"
