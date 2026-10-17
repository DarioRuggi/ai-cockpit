#!/usr/bin/env bash
# ebook_tools_test.sh — the E-book tools (cockpit_app/ebook_tool, tools_builtins/ebook.json, kinds/ebook-publishing.json) with pandoc and the real epubcheck: a book is built from markdown,
# inspected and validated; a broken book is reported with file(line,col); markdown that points outside the folder or at the network is refused.   bash tests/ebook_tools_test.sh
# SKIPPED without php (zip), pandoc, Java or epubcheck.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ET="$ROOT/cockpit_app/ebook_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^zip$' || { echo "ebook_tools_test: php with zip is needed - SKIPPED"; exit 0; }
command -v pandoc >/dev/null 2>&1 || { echo "ebook_tools_test: pandoc is needed - SKIPPED"; exit 0; }
EC=$(command -v epubcheck || echo "$HOME/.local/bin/epubcheck"); [ -x "$EC" ] && command -v java >/dev/null 2>&1 || { echo "ebook_tools_test: epubcheck and Java are needed - SKIPPED"; exit 0; }
export PATH="$(dirname "$EC"):$PATH"
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
command -v convert >/dev/null 2>&1 && convert -size 600x900 gradient:blue-white cover.png || printf '\x89PNG\r\n\x1a\n' > cover.png
# new, build
php "$ET" new . n.txt MyBook >/dev/null; [ -f MyBook/metadata.yaml ] && [ -f MyBook/01-first-chapter.md ] && [ -f MyBook/style.css ] && ok || bad "skeleton: $(ls MyBook)"
php "$ET" new . n2.txt MyBook >/dev/null 2>&1; [ $? = 1 ] && ok || bad "new over an existing folder was not refused"
php "$ET" new . n3.txt 'bad name=1' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing name was not refused"
sum0=$(cd MyBook && md5sum * | md5sum)
php "$ET" build MyBook b.epub cover=cover.png >/dev/null; [ -s b.epub ] && ok || bad "build wrote no epub"
unzip -l b.epub | grep -q "mimetype" && ok || bad "an epub needs a mimetype file"
[ "$(cd MyBook && md5sum * | md5sum)" = "$sum0" ] && ok || bad "the build changed the book folder"
# inspect
php "$ET" inspect b.epub i.md >/dev/null; has "| Title | MyBook |" i.md && has "| Author | Author Name |" i.md && has "| Language | en |" i.md && has "| Navigation document | yes |" i.md && has "| Cover image | yes |" i.md && ok || bad "inspect: $(sed -n 3,16p i.md)"
has "| Chapters (xhtml) | 5 |" i.md && ok || bad "chapter count: $(grep Chapters i.md)"
has "no accessibility metadata" i.md && ok || bad "the accessibility note"
php "$ET" build MyBook nc.epub >/dev/null; php "$ET" inspect nc.epub inc.md >/dev/null; has "no cover image" inc.md && ok || bad "a book with no cover must say so"
# check: epubcheck on a good book, then on a broken one
php "$ET" check b.epub c.md >/dev/null; has "No errors or warnings." c.md && has "[exit code 0]" c.md && ok || bad "a pandoc-built epub must pass epubcheck: $(sed -n 3,12p c.md)"
mkdir x; (cd x && unzip -q ../b.epub && f=$(find . -name ch001.xhtml | head -1) && sed -i 's|<p>The first paragraph of the book.</p>|<p>The first <b>paragraph of the book.</p><img src="missing.png" />|' "$f" && rm -f ../broken.epub && zip -q -X0 ../broken.epub mimetype && zip -q -X -r ../broken.epub . -x mimetype)
php "$ET" check broken.epub bc.md >/dev/null; has "[exit code 1]" bc.md && ok || bad "a broken epub must exit 1"
grep -qE '^EPUB/text/ch001\.xhtml\([0-9]+,[0-9]+\) Error: \[RSC-016\]' bc.md && ok || bad "the parse error with file,line,col and the code: $(sed -n 5,12p bc.md)"
grep -q '^\./' bc.md && bad "the path prefix of the epub was not removed" || ok
[ "$(grep -cE '^(.+?)\([0-9]+,[0-9]+\) (Error|Warning): ' bc.md)" -ge 1 ] && ok || bad "summary-box regex"
echo "not an epub" > fake.epub; php "$ET" inspect fake.epub x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-zip .epub was not refused"
php "$ET" check fake.epub x.md >/dev/null 2>&1; has "[exit code 1]" x.md && ok || bad "epubcheck on a non-epub must be an error finding: $(cat x.md | head -8)"
# the build must refuse anything that pulls a file from elsewhere
mkdir evil; printf '# A\n\n![x](/etc/passwd)\n' > evil/01.md; php "$ET" build evil e1.epub >/dev/null 2>e1.err; [ $? = 1 ] && grep -q "outside the book folder" e1.err && [ ! -f e1.epub ] && ok || bad "an absolute image path must be refused: $(cat e1.err)"
printf '# A\n\n![x](../secret.png)\n' > evil/01.md; php "$ET" build evil e2.epub >/dev/null 2>e2.err; [ $? = 1 ] && grep -q "outside the book folder" e2.err && ok || bad "a .. image path must be refused"
printf '# A\n\n![x](https://example.org/x.png)\n' > evil/01.md; php "$ET" build evil e3.epub >/dev/null 2>e3.err; [ $? = 1 ] && grep -q "remote file" e3.err && ok || bad "a remote image must be refused: $(cat e3.err)"
printf -- '---\ncover-image: /etc/passwd\n---\n# A\n' > evil/01.md; php "$ET" build evil e4.epub >/dev/null 2>e4.err; [ $? = 1 ] && ok || bad "a path-valued YAML key outside the folder must be refused"
printf '<p><img src="/etc/hostname"></p>\n\n# A\n' > evil/01.md; php "$ET" build evil e5.epub >/dev/null 2>&1; [ $? = 1 ] && ok || bad "raw HTML with an absolute src must be refused"
printf '# A\n\ntext\n' > evil/01.md; php "$ET" build evil e6.epub cover=/etc/passwd >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a cover that is not an image was not refused"
php "$ET" build evil e7.epub css=/etc/passwd >/dev/null 2>e7.err; [ $? = 1 ] && ok || bad "a stylesheet outside the folder was not refused"
php "$ET" build MyBook e8.txt >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-.epub output was not refused"
php "$ET" build empty e9.epub >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing folder was not refused"
php "$ET" frob b.epub x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
ls -d /tmp/ebook_* 2>/dev/null | grep -q . && bad "scratch files left in /tmp" || ok
head -20 "$ROOT/cockpit_app/ebook_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/ebook_tool (check|inspect|build|new) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/ebook.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "ebook.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/ebook-publishing.json")" = ebook ] && ok || bad "the kind does not name the tool"
echo "ebook_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
