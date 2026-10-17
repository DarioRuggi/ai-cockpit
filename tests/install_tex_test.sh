#!/usr/bin/env bash
# install_tex_test.sh — the LaTeX choice in the installer: the helper's dry run for each level, refusals, the installer asks the question (terminal AND wizard)
# with "recommended" as the default, the phase maps the answers, and the helper ships in the bundles. Nothing is installed.   bash tests/install_tex_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; H="$ROOT/Installs/install_tex.sh"; I="$ROOT/Installs/install_cockpit.sh"
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash -n "$H" && bash -n "$I" && ok || bad "syntax"
o=$(bash "$H" none --dry-run 2>&1); echo "$o" | grep -q "nothing to do" && ok || bad "none: $o"
o=$(bash "$H" --dry-run 2>&1); echo "$o" | grep -q "recommended set" && echo "$o" | grep -q "nothing changed" && ok || bad "the default level must be recommended: $o"
o=$(bash "$H" full --dry-run 2>&1); echo "$o" | grep -q "full set" && echo "$o" | grep -q "texlive-luatex\|texlive-collection-luatex" && echo "$o" | grep -q "biber" && echo "$o" | grep -q "latexmk" && ok || bad "full must add luatex, biber, latexmk: $o"
o=$(bash "$H" recommended --dry-run 2>&1); echo "$o" | grep -q "biber\|latexmk\|luatex" && bad "recommended must NOT include biber/latexmk/luatex: $o" || ok
bash "$H" bogus >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown level must exit 2"
# the installer: the question in the terminal path, the wizard, the prefill, the summary, the phase, the unattended variable
q='LaTeX system for the Academic paper tools (none, recommended, full)'
[ "$(grep -cF "$q" "$I")" -ge 4 ] && ok || bad "the question text appears $(grep -cF "$q" "$I") times (wants: ask, pre_set, gui prefill, summary, phase)"
grep -qF 'ask _q "'"$q"'" "recommended"' "$I" && ok || bad "the terminal question's default is not recommended"
grep -qF '"key": "TEX", "type": "select"' "$I" && grep -qF '"default": "recommended"' "$I" && ok || bad "the wizard has no TEX select defaulting to recommended"
grep -qF 'COCKPIT_INSTALL_TEX:-recommended' "$I" && ok || bad "the unattended default is not recommended"
grep -q '^step "Phase 5h' "$I" && ok || bad "no Phase 5h"
# Phase 5h sits after the other optional installs and before Ollama models (Phase 6)
a=$(grep -n '^step "Phase 5h' "$I" | cut -d: -f1); b=$(grep -n '^step "Phase 6 ' "$I" | cut -d: -f1); [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] && ok || bad "Phase 5h is not before Phase 6"
# the wizard spec is valid JSON with the field in it (render the media page the way the installer does: just parse the TEX object)
php -r '$s=file_get_contents($argv[1]); preg_match("~\{ \"key\": \"TEX\".*?\"options\": (\[\[.*?\]\]) \}~s",$s,$m); $o=json_decode($m[1] ?? "",true); exit(is_array($o)&&count($o)==3&&$o[0][0]=="recommended"&&$o[1][0]=="full"&&$o[2][0]=="none"?0:1);' "$I" && ok || bad "the TEX options are not recommended / full / none in that order"
# shipped in the bundles
grep -q 'install_tex.sh' "$ROOT/Installs/rebuild_tarballs.sh" && grep -q 'install_tex.sh' "$ROOT/Installs/build_download_bundles.sh" && ok || bad "install_tex.sh is not copied into the bundles"
echo "install_tex_test: $n passed, $fails failed"; [ "$fails" = 0 ]
