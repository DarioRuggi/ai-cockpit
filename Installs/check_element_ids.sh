#!/usr/bin/env bash
# =============================================================================
# check_element_ids.sh — every getElementById('x') must refer to an id that
# exists somewhere in the app.
#
# Why: dossier.js, intercom.js and margin.js all wrote their prompt into
# document.getElementById('promptInput') — an id that has never existed. The box
# is #prompt-in. Each then called sendPrompt() on an empty textarea, so Dossier
# gathered 12 pages and sent nothing, Intercom transcribed speech and sent
# nothing, and Margin asked for no edit. Three features, one typo, and no error
# anywhere: `if (input)` turned a wrong id into silence.
#
# An id counts as defined if it appears as id="x" anywhere (index.html or a
# JS/PHP string that builds markup). Ids that are only ever READ are the bug.
#
# Known dangling ids live in Installs/known_dangling_ids.txt so this can fail on
# NEW ones without blocking on the backlog. Shrink that file, do not grow it.
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ALLOW="$ROOT/Installs/known_dangling_ids.txt"

python3 - "$ROOT" "$ALLOW" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1]) / 'cockpit_app'
allow = set()
p = pathlib.Path(sys.argv[2])
if p.exists():
    allow = {l.strip() for l in p.read_text().splitlines() if l.strip() and not l.startswith('#')}

files = [f for f in root.rglob('*') if f.suffix in ('.js', '.html', '.php', '.css') and f.is_file()]
blobs = {f: f.read_text(encoding='utf-8', errors='ignore') for f in files}

used = {}
for f, s in blobs.items():
    if f.suffix != '.js':
        continue
    for m in re.finditer(r"getElementById\('([^']+)'\)", s):
        used.setdefault(m.group(1), set()).add(f.name)

bad = []
for i, who in used.items():
    if i in allow:
        continue
    # Two failure modes to dodge at once. Too strict and it fires on ids that are
    # never written as markup at all -- saas-account builds its form through
    # _saasInput('cp-new', ...) and supplier-slots passes 'ag-id' in a list -- and
    # an alarm on correct code stops being read. Too lenient and a COMMENT
    # mentioning the id vouches for it: the first cut of this guard passed because
    # the comment explaining the bug contained the word promptInput.
    #
    # So: strip comments, drop the reads, and ask whether the id survives as a
    # quoted string anywhere. Passing it to a builder counts; talking about it
    # does not.
    defined = False
    q = re.compile(r"['\"]" + re.escape(i) + r"['\"]")
    for s2 in blobs.values():
        stripped = re.sub(r"getElementById\('[^']+'\)", '', s2)
        stripped = re.sub(r'/\*.*?\*/', '', stripped, flags=re.S)
        stripped = re.sub(r'^\s*(//|#|\*).*$', '', stripped, flags=re.M)
        if q.search(stripped) or re.search(r'id\s*=\s*[\\\'"]*' + re.escape(i), stripped):
            defined = True
            break
    if not defined:
        bad.append((i, sorted(who)))

if bad:
    print('check_element_ids: these ids are read but never defined anywhere:')
    for i, who in sorted(bad):
        print('  #%-28s read by %s' % (i, ', '.join(who)))
    print('  Either fix the id, or add it to Installs/known_dangling_ids.txt with a reason.')
    sys.exit(1)
print('check_element_ids: every referenced element id exists (%d checked)' % len(used))
PY
