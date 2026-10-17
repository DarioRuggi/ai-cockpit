#!/usr/bin/env python3
"""
merge_custom_icons.py — add Cockpit's own glyphs to the vendored icon font.

    python3 Installs/merge_custom_icons.py <font.woff2> [icons_dir]

Each SVG in Installs/icons_custom/ becomes one glyph, addressed by its filename:
ck_bee.svg is written <span class="material-symbols-rounded">ck_bee</span>.

Why a ck_ prefix: 'margin' is ALREADY a Material icon, and Google adds names
over time, so an unprefixed custom name is a collision waiting to happen.

Why a ligature and no codepoint: the private-use area is ~4200/6400 full, and a
ligature target needs no codepoint at all.

Run it AFTER build_icon_font.sh, which replaces the font wholesale and would
otherwise drop these.

Needs python3-fonttools (the Debian package; no pip, no venv).
"""
import glob, os, re, sys
from fontTools.ttLib import TTFont
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import SVGPath
from fontTools.misc.transform import Transform
from fontTools.ttLib.tables import otTables as ot

font_path = sys.argv[1]
icons_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'icons_custom')

svgs = sorted(glob.glob(os.path.join(icons_dir, '*.svg')))
if not svgs:
    print('merge_custom_icons: no svgs in %s — nothing to do' % icons_dir)
    sys.exit(0)

f = TTFont(font_path)
upem = f['head'].unitsPerEm
# The stock glyphs put a 24-unit grid on the em with the baseline near y=864:
# x -> x*upem/24, y -> 864 - y*upem/24.
xform = Transform(upem / 24.0, 0, 0, -upem / 24.0, 0, 864)

glyf, hmtx = f['glyf'], f['hmtx']
g2c = {gn: chr(cp) for cp, gn in f['cmap'].getBestCmap().items()}
c2g = {c: gn for gn, c in g2c.items()}

lookup = f['GSUB'].table.LookupList.Lookup[0]
sub = lookup.SubTable[0]
sub = sub.ExtSubTable if lookup.LookupType == 7 else sub
existing = set()
for first, sets in sub.ligatures.items():
    for lg in sets:
        existing.add(''.join(g2c.get(p, '?') for p in [first] + list(lg.Component)))

added, skipped = [], []
for path in svgs:
    name = os.path.splitext(os.path.basename(path))[0]
    if not re.fullmatch(r'[a-z0-9_]+', name):
        skipped.append((name, 'name must be lowercase a-z0-9_')); continue
    if name in existing:
        skipped.append((name, 'a ligature of that name already exists')); continue
    if any(ch not in c2g for ch in name):
        skipped.append((name, 'the font cannot spell it')); continue

    gname = 'ckglyph_' + name
    pen = TTGlyphPen(None)
    # Cu2QuPen converts the SVG's cubics to the quadratics glyf needs.
    SVGPath(path).draw(TransformPen(Cu2QuPen(pen, 1.0), xform))
    # glyf.__setitem__ also extends the (shared) glyph order — appending to it
    # here as well double-counts and maxp then refuses to compile.
    glyf[gname] = pen.glyph()
    glyf[gname].recalcBounds(glyf)          # bounds are not computed until asked
    hmtx[gname] = (upem, glyf[gname].xMin if glyf[gname].numberOfContours else 0)

    chars = list(name)
    first, rest = c2g[chars[0]], [c2g[c] for c in chars[1:]]
    lig = ot.Ligature(); lig.LigGlyph = gname
    lig.Component = rest; lig.CompCount = len(rest) + 1
    sub.ligatures.setdefault(first, []).append(lig)
    # Longest first, or a shorter ligature sharing the same opening letters wins
    # and the longer name never resolves.
    sub.ligatures[first].sort(key=lambda l: -l.CompCount)
    existing.add(name); added.append(name)

# The glyph-id map is cached from before these glyphs existed; compiling GSUB
# against the stale copy raises KeyError on the new names.
f.getReverseGlyphMap(rebuild=True)
f.save(font_path)
print('merge_custom_icons: added %d (%s)' % (len(added), ', '.join(added)) if added else 'merge_custom_icons: added 0')
for n, why in skipped:
    print('  skipped %s — %s' % (n, why))
