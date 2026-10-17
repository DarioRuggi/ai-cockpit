#!/usr/bin/env bash
# =============================================================================
# export_icon_font.sh — turn the vendored woff2 into the other font formats and
# a browsable glyph sheet.
#
# The app ships only woff2 (smallest, and every target browser takes it). This
# produces .ttf and .woff for anywhere else you need the font — a desktop app,
# a design tool, a document — plus a self-contained HTML sheet of every glyph
# with its name, for picking icons without guessing.
#
# Output: docs/iconfont/  (docs/ does not ship to users)
#
# Re-run it after Installs/build_icon_font.sh, or the sheet describes a font
# that no longer matches the one in the app.
#
# Uses python3-fonttools, the Debian package — no pip, no venv.
# =============================================================================
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/cockpit_app/assets/fonts/material-symbols-rounded.woff2"
NAMES="$ROOT/cockpit_app/assets/fonts/material-symbols.names"
OUT="$ROOT/docs/iconfont"

[ -f "$SRC" ] || { echo "export_icon_font: no font at $SRC" >&2; exit 1; }
[ -f "$NAMES" ] || { echo "export_icon_font: no name list at $NAMES" >&2; exit 1; }
python3 -c 'import fontTools, brotli' 2>/dev/null || {
    echo "export_icon_font: needs python3-fonttools and python3-brotli" >&2
    echo "  sudo apt install python3-fonttools python3-brotli" >&2; exit 1; }

mkdir -p "$OUT"
cp -f "$SRC" "$NAMES" "$OUT/"
SHEET_TPL="$ROOT/Installs/iconfont_sheet.tpl.html" python3 - "$OUT" "$NAMES" <<'PY'
import base64, html, sys, os
from fontTools.ttLib import TTFont
out, names_file = sys.argv[1], sys.argv[2]
woff2 = os.path.join(out, 'material-symbols-rounded.woff2')

f = TTFont(woff2)                       # fontTools reads woff2 directly
f.flavor = None; f.save(os.path.join(out, 'material-symbols-rounded.ttf'))
f = TTFont(woff2); f.flavor = 'woff'
f.save(os.path.join(out, 'material-symbols-rounded.woff'))

# Every name the font can actually render, taken from the ligature table, so a
# name that would come out as plain letters cannot appear on the sheet as if it
# worked. Extension lookups (type 7) wrap the real subtable.
f = TTFont(woff2)
g2c = {gn: chr(cp) for cp, gn in f['cmap'].getBestCmap().items()}
ligs = set()
for lk in f['GSUB'].table.LookupList.Lookup:
    for st in lk.SubTable:
        st = st.ExtSubTable if lk.LookupType == 7 else st
        for first, sets in getattr(st, 'ligatures', {}).items():
            for lg in sets:
                ligs.add(''.join(g2c.get(p, '?') for p in [first] + list(lg.Component)))

used = [l.strip() for l in open(names_file) if l.strip()]
missing = [n for n in used if n not in ligs]
if missing:
    print('WARNING: %d harvested name(s) have no glyph: %s' % (len(missing), ', '.join(missing[:8])))
extra = sorted(n for n in ligs if n not in set(used))
rows = [(n, True) for n in sorted(used)] + [(n, False) for n in extra]

cells = "\n".join(
    '<button class="g%s" data-n="%s" title="%s"><span class="ms">%s</span><span class="nm">%s</span></button>'
    % ('' if u else ' x', html.escape(n), html.escape(n), html.escape(n), html.escape(n))
    for n, u in rows)

tpl = os.path.join(os.path.dirname(os.path.abspath(names_file)), '..', '..', 'Installs', 'iconfont_sheet.tpl.html')
doc = open(os.environ.get('SHEET_TPL', tpl)).read()
doc = (doc.replace('@@B64@@', base64.b64encode(open(woff2, 'rb').read()).decode())
          .replace('@@CELLS@@', cells)
          .replace('@@USED@@', str(len(used)))
          .replace('@@EXTRA@@', str(len(extra))))
open(os.path.join(out, 'cockpit_icon_font.html'), 'w').write(doc)
print('glyph sheet: %d names in use + %d extra = %d' % (len(used), len(extra), len(rows)))
PY
echo "export_icon_font: wrote $OUT"
ls -la "$OUT"
