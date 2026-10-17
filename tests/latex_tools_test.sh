#!/usr/bin/env bash
# latex_tools_test.sh — the Academic paper tools (cockpit_app/latex_tool, tools_builtins/latex.json, kinds/academic-paper.json): the scaffold builds, a paper
# with every kind of fault is reported with file(line), a missing package is named with how to install it, the project is never written to, TeX cannot read
# outside the project, the bibliography check, the word count.   bash tests/latex_tools_test.sh     SKIPPED without php or pdflatex
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; LT="$ROOT/cockpit_app/latex_tool"
command -v php >/dev/null 2>&1 || { echo "latex_tools_test: php is needed - SKIPPED"; exit 0; }
command -v pdflatex >/dev/null 2>&1 || { echo "latex_tools_test: pdflatex is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
# scaffold, build, check
php "$LT" new . n.txt paper >/dev/null; [ -f paper/main.tex ] && [ -f paper/refs.bib ] && ok || bad "scaffold not written"
php "$LT" new . n2.txt paper >/dev/null 2>&1; [ $? = 1 ] && ok || bad "new over an existing folder was not refused"
php "$LT" new . n3.txt '../x' >/dev/null 2>&1; [ ! -e ../x ] && [ -d "$T/x" ] && ok || bad "a path in the name was not reduced to a plain name"
sum0=$(cd paper && find . -type f | sort | xargs md5sum | md5sum)
php "$LT" check paper c.md >/dev/null; has "No problems found." c.md && has "[exit code 0]" c.md && has "bibtex run" c.md && ok || bad "scaffold check: $(cat c.md)"
php "$LT" build paper out.pdf >/dev/null; head -c 4 out.pdf | grep -q '%PDF' && ok || bad "scaffold did not build a PDF"
[ "$(cd paper && find . -type f | sort | xargs md5sum | md5sum)" = "$sum0" ] && ok || bad "the project was written to (aux/log/pdf left behind)"
command -v pdftotext >/dev/null 2>&1 && { pdftotext out.pdf - 2>/dev/null | grep -q "Knuth" && ok || bad "the citation did not resolve in the PDF (no bibtex pass?)"; }
# a paper with faults
mkdir bad; cat > bad/main.tex <<'TEX'
\documentclass{article}
\usepackage{amsmath}
\usepackage[numbers]{natbib}
\begin{document}
\section{One}\label{sec:one}
See Section~\ref{sec:nowhere} and \cite{ghost}.
\foo{bar}
A very long unbreakable word: Pneumonoultramicroscopicsilicovolcanoconiosispneumonoultramicroscopicsilicovolcanoconiosispneumonoultramicroscopicsilicovolcanoconiosis end.
\bibliographystyle{plainnat}
\bibliography{refs}
\end{document}
TEX
printf '@book{used,\n  author={A},\n  title={B},\n  year={2000}\n}\n@book{unused,\n  title={C}\n}\n' > bad/refs.bib
php "$LT" check bad b.md >/dev/null; has "[exit code 1]" b.md && ok || bad "faulty paper not exit 1"
has "main.tex(7) Error: Undefined control sequence" b.md && ok || bad "undefined control sequence with its line: $(grep Error b.md)"
has "undefined reference 'sec:nowhere'" b.md && has "undefined citation 'ghost'" b.md && ok || bad "undefined reference / citation: $(grep Warning b.md)"
has "Warning: a line is" b.md && ok || bad "overfull box over 10 pt: $(grep -i wide b.md)"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' b.md)" -ge 4 ] && ok || bad "summary-box regex finds too few lines"
php "$LT" build bad b.pdf >/dev/null 2>&1; true; ok
# a missing package is named, with the install hint
mkdir pk; printf '\\documentclass{article}\n\\usepackage{nonexistentpackage}\n\\begin{document}x\\end{document}\n' > pk/main.tex
php "$LT" check pk p.md >/dev/null; has "the TeX package 'nonexistentpackage.sty' is not installed." p.md && has "sudo apt install texlive-latex-recommended" p.md && ok || bad "missing package hint: $(grep Error p.md)"
grep -q "Emergency stop" p.md && bad "the follow-on 'Emergency stop' noise was not hidden" || ok
mkdir pk2; printf '\\documentclass{article}\n\\usepackage{booktabs}\n\\begin{document}x\\end{document}\n' > pk2/main.tex
php "$LT" check pk2 p2.md >/dev/null; if [ -n "$(kpsewhich booktabs.sty 2>/dev/null)" ]; then ok; else has "texlive-latex-recommended" p2.md && ok || bad "a known package maps to its Debian package: $(grep Error p2.md)"; fi
# TeX may not read outside the project
mkdir esc; printf '\\documentclass{article}\n\\begin{document}\n\\input{/etc/hostname}\n\\end{document}\n' > esc/main.tex
php "$LT" check esc e.md >/dev/null; has "[exit code 1]" e.md && ok || bad "an absolute \\input was not blocked: $(cat e.md)"
mkdir esc2; printf '\\documentclass{article}\n\\begin{document}\n\\immediate\\write18{touch %s/PWNED}\n\\end{document}\n' "$T" > esc2/main.tex
php "$LT" check esc2 e2.md >/dev/null; [ ! -e "$T/PWNED" ] && ok || bad "shell escape ran a command"
# which main file: folder with two, a .tex given directly, none
mkdir two; cp bad/main.tex two/a.tex; cp bad/main.tex two/b.tex; php "$LT" check two t.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with two main files was not refused"
php "$LT" check two/a.tex t2.md >/dev/null 2>&1; has "a.tex" t2.md && ok || bad "a .tex given directly"
mkdir none; php "$LT" check none t3.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no .tex was not refused"
echo hi > x.txt; php "$LT" check x.txt t4.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-.tex file was not refused"
# bibliography check
php "$LT" bibcheck bad bc.md >/dev/null
has "main.tex(6) Error: the citation 'ghost' is not in any .bib file" bc.md && ok || bad "missing citation key: $(grep -E 'Error|Warning|Note' bc.md)"
has "refs.bib(6) Warning: entry 'unused' (book) has no author, year" bc.md && ok || bad "an entry lacking fields: $(grep Warning bc.md)"
has "refs.bib(5) Note: entry 'unused' is never cited" bc.md || has "Note: entry 'unused' is never cited" bc.md && ok || bad "an unused entry"
printf '@book{a,\n author={X},title={Y},year={1}\n}\n@book{a,\n author={X},title={Y},year={1}\n}\n' > bad/dup.bib; sed -i 's/{refs}/{refs,dup}/' bad/main.tex; php "$LT" bibcheck bad bc2.md >/dev/null; has "the key 'a' is defined twice" bc2.md && ok || bad "a duplicated key: $(grep Error bc2.md)"
php "$LT" bibcheck paper bc3.md >/dev/null; has "No problems found." bc3.md && ok || bad "the scaffold's bibliography should be clean: $(cat bc3.md)"
# words
if command -v pandoc >/dev/null 2>&1; then php "$LT" words paper w.md >/dev/null; grep -qE 'Words in the text .*: [0-9]+' w.md && ok || bad "word count: $(cat w.md)"; w=$(grep -oE ': [0-9]+$' w.md | head -1 | tr -d ': '); [ "${w:-0}" -gt 15 ] && [ "${w:-999}" -lt 90 ] && ok || bad "the word count is implausible: ${w:-?}"; fi
# the definitions and the web guard
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^(php \{WEBROOT\}/latex_tool (new|build|check|bibcheck|words)|pandoc) ~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/latex.json" > pc 2>&1; [ "$(cat pc)" = 7 ] && ok || bad "latex.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/academic-paper.json")" = latex ] && ok || bad "the kind does not name the tool"
head -20 "$ROOT/cockpit_app/latex_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
ls -d /tmp/lt_* 2>/dev/null | grep -q . && bad "a scratch folder was left in /tmp" || ok
echo "latex_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
