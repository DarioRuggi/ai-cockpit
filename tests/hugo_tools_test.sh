#!/usr/bin/env bash
# hugo_tools_test.sh — cockpit_app/hugo_tool: Hugo runs INSIDE bubblewrap (no network, no home). new / check / list / build, a broken template, a draft, the refusal without bwrap.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; H="$ROOT/cockpit_app/hugo_tool"
command -v php >/dev/null 2>&1 || { echo "hugo_tools_test: php is needed - SKIPPED"; exit 0; }
HB=$(command -v hugo || ls ~/.local/bin/hugo 2>/dev/null)
{ [ -n "$HB" ] && command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / --unshare-all --die-with-parent true >/dev/null 2>&1; } || { echo "hugo_tools_test: hugo or a working bwrap missing - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
php "$H" new . n.md s1 >/dev/null; [ -f s1/hugo.toml ] && [ -f s1/layouts/_default/baseof.html ] && ok || bad "new"
grep -q languageCode s1/hugo.toml && bad "scaffold uses deprecated languageCode" || ok
php "$H" new . n2.md s1 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "new over existing not refused"
php "$H" check s1 c.md >/dev/null; has "No problems found." c.md && has "pages 4" c.md && has "[exit code 0]" c.md && ok || bad "check good: $(sed -n 1,12p c.md)"
ls s1/public >/dev/null 2>&1 && bad "check left a public/ folder in the site" || ok
php "$H" list s1 l.md >/dev/null; has "content/posts/first-post.md" l.md && has "3 page(s)" l.md && ok || bad "list"
printf -- '---\ntitle: "Hidden"\ndate: 2026-03-01\ndraft: true\n---\nx\n' > s1/content/posts/hidden.md
php "$H" list s1 l2.md >/dev/null; grep -q "hidden.md.*draft" l2.md && ok || bad "draft not shown in list: $(grep hidden l2.md)"
php "$H" build s1 o.zip >/dev/null; unzip -l o.zip | grep -q "index.html" && unzip -l o.zip | grep -q "style.css" && ok || bad "build zip"
unzip -l o.zip | grep -q hidden && bad "a draft was published" || ok
# a broken template names the file and line
cp -r s1 s2; printf '{{ define "main" }}\n<h1>{{ .Title }}</h1>\n{{ .Nope.Deeper }}\n{{ end }}\n' > s2/layouts/_default/single.html
php "$H" check s2 e.md >/dev/null; grep -qE "^layouts/_default/single\.html\([0-9]+(,[0-9]+)?\) Error" e.md && has "[exit code 1]" e.md && ok || bad "template error: $(sed -n 3,12p e.md)"
# no network from inside the sandbox
printf '{{ define "main" }}{{ with resources.GetRemote "http://127.0.0.1:9/x" }}{{ .Content }}{{ end }}{{ end }}\n' > s2/layouts/_default/single.html
php "$H" check s2 net.md >/dev/null 2>&1; has "[exit code 1]" net.md && ok || bad "remote fetch must fail in the sandbox: $(sed -n 3,10p net.md)"
php "$H" check nope x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing folder"
mkdir empty; php "$H" check empty x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no hugo config must be refused"
php "$H" frob s1 x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
mkdir nobw; for b in php hugo; do p=$(command -v $b || echo "$HB"); ln -s "$p" nobw/$b; done; PATH="$T/nobw" "$(command -v php)" "$H" check s1 nb.md >/dev/null 2>nb.err; [ $? = 1 ] && grep -q "bwrap" nb.err && ok || bad "without bwrap must refuse: $(cat nb.err)"
ls -d /tmp/hugo_* 2>/dev/null | grep -q . && bad "scratch left in /tmp" || ok
head -20 "$H" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
[ "$(jq '.presets|length' "$ROOT/cockpit_app/tools_builtins/hugo.json")" = 4 ] && ok || bad "hugo.json presets"
echo "hugo_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
