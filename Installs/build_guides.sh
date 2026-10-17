#!/usr/bin/env bash
# build_guides.sh — ONE Markdown source per guide -> every HTML copy.
#
# Kills the guide-drift class of bug: before this, the standalone guide and the
# site's body fragment were two hand-maintained files that silently diverged
# (guide.php served stale text for weeks).
#
# Source of truth : docs/guides/USER_GUIDE.md , docs/guides/SETUP_GUIDE.md
# Templates       : Installs/guides/*_template.html  (extracted from the originals,
#                   so the standalone keeps its exact look + theme script)
# Outputs         : standalone HTML (app, site, docs) + body fragment (guide.php)
#
# Requires pandoc (native .deb — no Python, per the rig's Python policy).
# Usage: bash Installs/build_guides.sh [--check]
#   --check  build to a temp dir and report what WOULD change; writes nothing.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1

command -v pandoc >/dev/null || { echo "ERROR: pandoc not installed (apt install pandoc)"; exit 1; }

ok(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
inf(){ printf '  · %s\n' "$*"; }

OUT=$(mktemp -d /tmp/cockpit_guides_XXXXXX)
trap 'rm -rf "$OUT"' EXIT

build_one() {
    local name="$1" slug="$2"; shift 2
    local md="$ROOT/docs/guides/${name}.md"
    local tpl="$ROOT/Installs/guides/${slug}_template.html"
    [ -f "$md" ]  || { echo "ERROR: missing source $md"; exit 1; }
    [ -f "$tpl" ] || { echo "ERROR: missing template $tpl"; exit 1; }

    # 1. standalone page (own <head>, styles, theme script) — works offline
    pandoc "$md" --toc --standalone --template="$tpl" -o "$OUT/${name}.html" || exit 1
    # 2. body fragment for the site (guide.php readfile's this INSIDE its own chrome,
    #    so: no <html>/<head>, but it still carries its own TOC nav)
    pandoc "$md" --toc --standalone \
        --template="$ROOT/Installs/guides/fragment_template.html" \
        -o "$OUT/${slug}_body.html" || exit 1

    local h_std h_frag
    h_std=$(grep -c '<h2' "$OUT/${name}.html"); h_frag=$(grep -c '<h2' "$OUT/${slug}_body.html")
    inf "$name: standalone $(wc -c <"$OUT/${name}.html")B (h2=$h_std), fragment $(wc -c <"$OUT/${slug}_body.html")B (h2=$h_frag)"
    [ "$h_std" = "$h_frag" ] || { echo "ERROR: $name section count mismatch"; exit 1; }
}

# The standalone guides are read INSIDE Cockpit, on machines that may have no
# internet — so the copies that land in the app must take their icon font from
# the app itself, not from fonts.googleapis.com (offline, every icon in the guide
# renders as its own name). The site copies keep the CDN link: they are served
# over the web by definition, and the site has no css/ directory.
localise_icons() {
    local f="$1"
    sed -i 's#<link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded[^"]*" rel="stylesheet">#<link rel="stylesheet" href="css/icons.css">#' "$f"
    sed -i '/<link rel="preconnect" href="https:\/\/fonts.googleapis.com">/d' "$f"
}

deploy_one() {
    local src="$1"; shift
    for dst in "$@"; do
        [ -e "$(dirname "$dst")" ] || continue
        if [ "$CHECK" = 1 ]; then
            if cmp -s "$src" "$dst"; then inf "unchanged: ${dst#$ROOT/}"
            else printf '  \033[33m~ would update:\033[0m %s\n' "${dst#$ROOT/}"; fi
        else
            cp "$src" "$dst" && ok "${dst#$ROOT/}"
        fi
    done
}

echo "== building guides from Markdown =="
build_one USER_GUIDE  user_guide
build_one SETUP_GUIDE setup_guide

echo "== distributing =="
S="$ROOT/server_mirror/cockpit.ruggi.site"
# Site + docs copies keep the CDN font; the app copies get the local one.
deploy_one "$OUT/USER_GUIDE.html"  "$S/USER_GUIDE.html"  "$ROOT/docs/USER_GUIDE.html"
deploy_one "$OUT/SETUP_GUIDE.html" "$S/SETUP_GUIDE.html" "$ROOT/docs/SETUP_GUIDE.html"
cp "$OUT/USER_GUIDE.html"  "$OUT/USER_GUIDE.app.html"
cp "$OUT/SETUP_GUIDE.html" "$OUT/SETUP_GUIDE.app.html"
localise_icons "$OUT/USER_GUIDE.app.html"
localise_icons "$OUT/SETUP_GUIDE.app.html"
deploy_one "$OUT/USER_GUIDE.app.html"  "$ROOT/cockpit_app/USER_GUIDE.html"
deploy_one "$OUT/SETUP_GUIDE.app.html" "$ROOT/cockpit_app/SETUP_GUIDE.html"
deploy_one "$OUT/user_guide_body.html"  "$S/assets/guides/user_guide_body.html"
deploy_one "$OUT/setup_guide_body.html" "$S/assets/guides/setup_guide_body.html"

# The public demo ships its OWN copies of both guides. They were maintained by
# hand and went stale exactly the way every other copy did before this script
# existed -- caught 2026-09-11, missing a day of new sections. Since the edition
# unification the demo is the same tree plus a `.edition` marker, so its guides
# are byte-identical to the app's and belong to this generator like the rest.
deploy_one "$OUT/USER_GUIDE.html"  "$S/demo/USER_GUIDE.html"
deploy_one "$OUT/SETUP_GUIDE.html" "$S/demo/SETUP_GUIDE.html"

# ── the in-app help topics ──────────────────────────────────────────────────
# help_default.json embeds FULL copies of both guides as help topics
# (user_guide_full / setup_guide_full). They were hand-maintained and had
# drifted badly -- 82KB against a 101KB fragment, i.e. missing everything
# appended to the guides since whenever they were last pasted in. That is the
# exact divergence this script exists to prevent, so the topics are generated
# here too. PHP does the JSON edit (no Python on this rig).
embed_help() {
    local frag="$1" topic="$2" json="$ROOT/cockpit_app/help_default.json"
    [ -f "$json" ] || { inf "help_default.json absent — skipped $topic"; return 0; }
    if [ "$CHECK" = 1 ]; then
        php -r '
            $j = json_decode(file_get_contents($argv[1]), true);
            $new = file_get_contents($argv[2]);
            $old = $j["topics"][$argv[3]]["body"] ?? null;
            if ($old === $new) { printf("  · unchanged: help topic %s\n", $argv[3]); }
            else printf("  \033[33m~ would update:\033[0m help topic %s (%dB -> %dB)\n",
                        $argv[3], strlen((string)$old), strlen($new));
        ' "$json" "$frag" "$topic"
        return 0
    fi
    php -r '
        $f = $argv[1];
        $j = json_decode(file_get_contents($f), true);
        if (!is_array($j) || !isset($j["topics"][$argv[3]])) {
            fwrite(STDERR, "help topic {$argv[3]} not found\n"); exit(1);
        }
        $j["topics"][$argv[3]]["body"] = file_get_contents($argv[2]);
        $out = json_encode($j, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if ($out === false) { fwrite(STDERR, "re-encode failed\n"); exit(1); }
        file_put_contents($f, $out . "\n");
    ' "$json" "$frag" "$topic" || exit 1
    ok "cockpit_app/help_default.json :: $topic"
}
embed_help "$OUT/user_guide_body.html"  user_guide_full
embed_help "$OUT/setup_guide_body.html" setup_guide_full

# The demo carries its own help_default.json with the same two topics. It is
# structurally identical to the app's (verified key-by-key 2026-09-11), so the
# generated file is copied straight over rather than re-embedded -- one source,
# one edit, two destinations.
if [ "$CHECK" = 1 ]; then
    if cmp -s "$ROOT/cockpit_app/help_default.json" "$S/demo/help_default.json"; then
        inf "unchanged: demo/help_default.json"
    else
        printf '  \033[33m~ would update:\033[0m demo/help_default.json\n'
    fi
else
    deploy_one "$ROOT/cockpit_app/help_default.json" "$S/demo/help_default.json"
fi

echo
if [ "$CHECK" = 1 ]; then
    echo "check only — nothing written."
else
    # LICENSE.md → site fragment (license.php includes it) — same single-source rule.
{ pandoc "$ROOT/LICENSE.md" -f markdown -t html; echo '<hr id="terms">'; pandoc "$ROOT/TERMS.md" -f markdown -t html; } > "$ROOT/server_mirror/cockpit.ruggi.site/assets/license_body.html" && ok "license_body.html (LICENSE + TERMS)"
echo "Done. Edit docs/guides/*.md and re-run this; never hand-edit the HTML."
    echo "Site copies still need deploying:  ftpush <the changed files under server_mirror/cockpit.ruggi.site/>"
fi
