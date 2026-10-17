#!/usr/bin/env bash
# guard_cache_test.sh — Installs/guard_cache.sh: a slow guard is skipped only when its inputs are unchanged since it last PASSED.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
ROOT="$T/repo"; GUARD_CACHE_DIR="$T/cache"; mkdir -p "$ROOT/d"      # a throw-away tree: the real repo is never touched
. "$REPO/Installs/guard_cache.sh"
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
echo one > "$ROOT/a.txt"; echo x > "$ROOT/d/f1"; runs="$T/runs"; : > "$runs"
g() { echo run >> "$runs"; return "${RC:-0}"; }
cnt() { wc -l < "$runs" | tr -d ' '; }
guard_run t "a.txt d" g 2>/dev/null;            [ "$(cnt)" = 1 ] && ok || bad "first call must run"
guard_run t "a.txt d" g 2>/dev/null;            [ "$(cnt)" = 1 ] && ok || bad "unchanged inputs must skip (ran $(cnt))"
echo two > "$ROOT/a.txt"
guard_run t "a.txt d" g 2>/dev/null;            [ "$(cnt)" = 2 ] && ok || bad "a changed file must run"
echo y > "$ROOT/d/f2"
guard_run t "a.txt d" g 2>/dev/null;            [ "$(cnt)" = 3 ] && ok || bad "a new file in a dep folder must run"
guard_run t "a.txt d" g 2>/dev/null;            [ "$(cnt)" = 3 ] && ok || bad "settled again must skip"
FULL=1 guard_run t "a.txt d" g 2>/dev/null;     [ "$(cnt)" = 4 ] && ok || bad "FULL=1 must run"
guard_run t "a.txt d nothere" g 2>/dev/null;    [ "$(cnt)" = 5 ] && ok || bad "a missing dep must count as a change"
RC=1 guard_run f "a.txt" g 2>/dev/null;         [ $? = 1 ] && ok || bad "a failing guard must fail"
[ ! -f "$GUARD_CACHE_DIR/f" ] && ok || bad "a failure stored a fingerprint"
RC=0 guard_run f "a.txt" g 2>/dev/null;         [ "$(cnt)" = 7 ] && ok || bad "after a failure the guard must run again (ran $(cnt))"
guard_run t "a.txt d nothere" g 2>/dev/null;    [ "$(cnt)" = 7 ] && ok || bad "still-missing dep, unchanged: must skip"
guard_run t2 "a.txt" g 2>/dev/null;             [ "$(cnt)" = 8 ] && ok || bad "another guard has its own fingerprint"
msg=$(guard_run t2 "a.txt" g 2>&1 >/dev/null); echo "$msg" | grep -q "skipped" && ok || bad "a skip says so"
# in the real build: the four slow guards are wired through it
for g in gemini history crud castle; do grep -q "^guard_run $g " "$REPO/Installs/rebuild_tarballs.sh" && ok || bad "$g is not gated"; done
echo "guard_cache_test: $n passed, $fails failed"; [ "$fails" = 0 ]
