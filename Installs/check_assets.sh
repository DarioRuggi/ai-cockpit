#!/usr/bin/env bash
# =============================================================================
# check_assets.sh — every js/ and css/ file in the app must be referenced by
# index.html.
#
# Why this exists: bookshelf.js, dossier.js, profile.js and intercom.js shipped
# for months with no <script> tag. The files were built, copied, hashed into the
# integrity manifest and served with HTTP 200 — they were simply never loaded,
# so every button calling into them threw a ReferenceError and did nothing.
# Nothing caught it: the files existed, the endpoints worked, and the features
# had been proven backend-first. They were the four entries the QA checklist
# listed as "never hand-driven through the UI" — because the UI could not drive
# them at all. Found 2026-09-26 only because a user clicked Profile.
#
# A file that is present, correct and unreferenced is invisible to every other
# check we have. This one looks for exactly that.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/cockpit_app"
IDX="$APP/index.html"

[ -f "$IDX" ] || { echo "check_assets: no index.html at $IDX"; exit 1; }

missing=0
while IFS= read -r f; do
    rel="${f#$APP/}"
    if ! grep -q "$rel" "$IDX"; then
        echo "  UNREFERENCED  $rel"
        missing=$((missing + 1))
    fi
done < <(find "$APP/js" "$APP/css" -type f \( -name '*.js' -o -name '*.css' \) | sort)

if [ "$missing" -gt 0 ]; then
    echo "check_assets: $missing file(s) are shipped but never loaded by index.html."
    echo "  Either add a <script>/<link> tag, or delete the file if it is dead."
    exit 1
fi
echo "check_assets: every js/css file is referenced by index.html"
exit 0
