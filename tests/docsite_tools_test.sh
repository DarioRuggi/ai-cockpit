#!/usr/bin/env bash
# docsite_tools_test.sh — the Documentation site tools (cockpit_app/docs_tool, tools_builtins/docsite.json, kinds/documentation-site.json): the page check (links, anchors, images, case,
# empty pages, titles), the contents, the built site and its search, the single page.   bash tests/docsite_tools_test.sh     SKIPPED without php (zip) or pandoc
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; DT="$ROOT/cockpit_app/docs_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^zip$' || { echo "docsite_tools_test: php with zip is needed - SKIPPED"; exit 0; }
command -v pandoc >/dev/null 2>&1 || { echo "docsite_tools_test: pandoc is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1; mkdir -p site/guide site/img site/node_modules
command -v convert >/dev/null 2>&1 && convert -size 20x20 xc:blue site/img/logo.png || printf '\x89PNG\r\n\x1a\n' > site/img/logo.png
cat > site/README.md <<'MD'
# My Product

Welcome. See the [install guide](guide/01-install.md) and the [usage page](guide/02-usage.md#advanced-tips).
![logo](img/logo.png)
Broken: [missing](guide/nothing.md), [wrong case](Guide/01-install.md), [bad anchor](guide/01-install.md#nope), ![gone](img/gone.png).
MD
printf -- '---\ntitle: Installing\n---\n# Install\n\nStep one. Back to [home](../README.md).\n\n### Skipped level\n\n## Usage\n\n## Usage\n' > site/guide/01-install.md
printf '# Usage\n\nSome text.\n\n## Advanced tips\n\nTips with `code` and a table:\n\n| a | b |\n|---|---|\n| 1 | 2 |\n' > site/guide/02-usage.md
printf 'no heading and orphan\n' > site/orphan.md; : > site/empty.md; echo "ignored" > site/node_modules/x.md
sum0=$(find site -type f | sort | xargs md5sum | md5sum)
php "$DT" check site c.md >/dev/null; has "[exit code 1]" c.md && has "Pages: 5; home page: README.md" c.md && ok || bad "header: $(sed -n 3p c.md)"
has "README.md(5) Error: the link guide/nothing.md points to a file that does not exist" c.md && ok || bad "broken link"
has "(the file is 'guide/01-install.md': the case differs, which breaks on Linux)" c.md && ok || bad "case"
has "README.md(5) Error: the link guide/01-install.md#nope: there is no heading #nope" c.md && ok || bad "bad anchor"
has "README.md(5) Error: the image img/gone.png points to a file that does not exist" c.md && ok || bad "missing image"
has "empty.md(1) Error: the page is empty" c.md && ok || bad "empty page"
has "orphan.md(1) Warning: the page has no title" c.md && ok || bad "no title"
has "guide/01-install.md(8) Note: the heading level jumps from 1 to 3" c.md && ok || bad "heading jump (line counted past the front matter)"
has "guide/01-install.md(12) Note: a second heading \"Usage\"" c.md && ok || bad "repeated heading"
has "orphan.md(1) Note: no other page links to this one" c.md && ok || bad "orphan"
grep -q "node_modules" c.md && bad "node_modules was not skipped" || ok
grep -q "usage page\|02-usage.md(" c.md && bad "a good anchor link (guide/02-usage.md#advanced-tips) was flagged" || ok
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md)" = 6 ] && ok || bad "summary-box regex finds $(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md), want 6"
# a clean site
mkdir clean; printf '# Home\n\nSee [a](a.md).\n' > clean/README.md; printf '# A\n\nBack to [home](README.md).\n' > clean/a.md; php "$DT" check clean cc.md >/dev/null; has "No problems found." cc.md && has "[exit code 0]" cc.md && ok || bad "clean site: $(sed -n 5,12p cc.md)"
# toc
php "$DT" toc site t.md >/dev/null; has "- [My Product](README.md)" t.md && has "- **Guide**" t.md && has "  - [Installing](guide/01-install.md)" t.md && has "  - [Usage](guide/02-usage.md)" t.md && ok || bad "toc: $(cat t.md)"
[ "$(grep -n 'README.md' t.md | head -1 | cut -d: -f1)" -lt "$(grep -n 'Installing' t.md | cut -d: -f1)" ] && ok || bad "the home page is not first"
# build
php "$DT" build site s.zip >/dev/null; unzip -l s.zip | grep -q " index.html" && unzip -l s.zip | grep -q "guide/01-install.html" && unzip -l s.zip | grep -q "search.json" && unzip -l s.zip | grep -q "img/logo.png" && ok || bad "site files: $(unzip -l s.zip | awk '{print $4}' | tr '\n' ' ')"
unzip -l s.zip | grep -qE "\.md$|node_modules" && bad "markdown sources or node_modules went into the site" || ok
unzip -p s.zip index.html | grep -q 'href="guide/01-install.html"' && ok || bad "links must be rewritten .md -> .html in index.html: $(unzip -p s.zip index.html | grep -o 'href="[^"]*"' | head -5 | tr '\n' ' ')"
unzip -p s.zip guide/01-install.html | grep -q 'href="../index.html"' && ok || bad "a link up a folder (../README.md) must become ../index.html"
unzip -p s.zip guide/02-usage.html | grep -q '<table>' && unzip -p s.zip guide/02-usage.html | grep -q "← Installing" && ok || bad "table / previous link"
unzip -p s.zip guide/02-usage.html | grep -q 'var UP="../"' && ok || bad "the search path from a sub-folder"
php -r 'foreach (json_decode(stream_get_contents(fopen("zip://".$argv[1]."#search.json","r")), true) as $d) if ($d["t"] === "Installing") exit(0); exit(1);' "$T/s.zip" && ok || bad "search.json lacks the page titles"
unzip -p s.zip index.html | grep -qiE "https?://[a-z0-9.-]+/[^\"']*\.(js|css)" && bad "the built site loads something from the network" || ok
php "$DT" build site s.txt >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-zip output was not refused"
# single
php "$DT" single site one.html >/dev/null; [ "$(grep -c '<section' one.html)" = 5 ] && has "<h2>Contents</h2>" one.html && ok || bad "single page"
# raw HTML with a script in a page must not make pandoc read files (sandbox on)
mkdir sb; printf '# S\n\n```{=html}\n<p>raw</p>\n```\n\n![x](/etc/passwd)\n' > sb/README.md; php "$DT" build sb sb.zip >/dev/null 2>&1; unzip -p sb.zip index.html 2>/dev/null | grep -q "root:" && bad "an image path read /etc/passwd into the site" || ok
# refusals, originals, guard, definitions
php "$DT" check nope c.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing folder was not refused"
mkdir nomd; php "$DT" check nomd c.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no pages was not refused"
php "$DT" frob site x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(find site -type f | sort | xargs md5sum | md5sum)" = "$sum0" ] && ok || bad "the source changed"
ls -d /tmp/docs_* 2>/dev/null | grep -q . && bad "scratch files left in /tmp" || ok
head -20 "$ROOT/cockpit_app/docs_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/docs_tool (check|toc|build|single) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/docsite.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "docsite.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/documentation-site.json")" = docsite ] && ok || bad "the kind does not name the tool"
echo "docsite_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
