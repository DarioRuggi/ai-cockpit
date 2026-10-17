#!/usr/bin/env bash
# stamp_assets.sh — cache-busting for the split front end. Apache here sends no
# Cache-Control, so a browser may keep a js/css file after a deploy and run
# old code against new markup. index.html carries ?v=<stamp> on every css/js
# reference; the stamp is the first 10 hex of the sha256 over all those files,
# so it changes exactly when any of them does. Run before build_integrity /
# the bundles (rebuild_tarballs does), and commit the result: the repo tree,
# the deployed roots and the bundle must be the same bytes.
set -e
WEB="${1:-$(cd "$(dirname "$0")/.." && pwd)/cockpit_app}"
cd "$WEB"
stamp=$( (find css js -type f \( -name '*.css' -o -name '*.js' \) | LC_ALL=C sort | xargs cat) | sha256sum | cut -c1-10)
before=$(sha256sum index.html | cut -c1-16)
# add ?v= where missing, refresh where present — only on our own css/ and js/ paths
sed -i -E "s#(href=\"css/[^\"?]+\.css)(\?v=[0-9a-f]+)?\"#\1?v=$stamp\"#g; s#(src=\"js/[^\"?]+\.js)(\?v=[0-9a-f]+)?\"#\1?v=$stamp\"#g" index.html
after=$(sha256sum index.html | cut -c1-16)
n=$(grep -o "?v=$stamp" index.html | wc -l)
[ "$before" = "$after" ] && echo "assets stamp $stamp unchanged ($n refs)" || echo "assets stamp $stamp written ($n refs)"
