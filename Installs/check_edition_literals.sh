#!/usr/bin/env bash
# =============================================================================
# check_edition_literals.sh — 'v1' / 'v2' must be strings when compared or
# defaulted to, never bare identifiers.
#
# Why this exists: build 129 (2026-09-26) shipped
#     if ((window.COCKPIT_EDITION || v2) === v1) return cockpitUserManager();
# with the quotes missing. It parses, so `node --check` passes. It renders, so the
# button looked right. It is a ReferenceError the instant it RUNS — which is only
# when you click — so the button showing who you are signed in as did nothing at
# all, in both editions, for five days. Found 2026-10-01 because a person pressed it.
#
# Same family as the missing <script> tags (check_assets.sh) and the wrong element
# id (check_element_ids.sh): correct-looking code with no path that works. A
# `let v1 = ...` as a local variable is fine and is not matched; only COMPARING
# against, or DEFAULTING to, a bare v1/v2 is.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/cockpit_app"
hits=$(grep -rnE "(===|!==|==|!=)[[:space:]]*v[12]\b|\|\|[[:space:]]*v[12]\b" "$APP/js" "$APP/edition.js.php" "$APP/index.html" 2>/dev/null \
       | grep -vE "^[^:]+:[0-9]+:[[:space:]]*(//|\*)" || true)
if [ -n "$hits" ]; then
  echo "check_edition_literals: bare v1/v2 used as an identifier — these are ReferenceErrors when run:"
  echo "$hits" | sed 's/^/  /'
  exit 1
fi
echo "check_edition_literals: no bare v1/v2 identifiers"
