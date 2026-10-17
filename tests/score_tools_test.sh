#!/usr/bin/env bash
# score_tools_test.sh — the Music scores tools (cockpit_app/score_tool, tools_builtins/score.json, kinds/music-notation.json) with the real LilyPond, INSIDE bubblewrap:
# a good score builds, a bar error is reported with its line and column, and — the point — a malicious .ly that tries to run a command, write outside its scratch folder or read
# the home folder is contained.   bash tests/score_tools_test.sh     SKIPPED without php, lilypond or bwrap
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/cockpit_app/score_tool"
for c in php lilypond bwrap; do command -v $c >/dev/null 2>&1 || { echo "score_tools_test: $c is needed - SKIPPED"; exit 0; }; done
bwrap --ro-bind / / --unshare-all --die-with-parent true >/dev/null 2>&1 || { echo "score_tools_test: bubblewrap cannot create a sandbox here (user namespaces?) - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1; mkdir p
cat > p/good.ly <<'LY'
\version "2.24.0"
\header { title = "Test tune" }
\score { \relative c' { \time 3/4 c4 d e | f g a | g2. | }  \layout { } \midi { } }
LY
cat > p/short.ly <<'LY'
\version "2.24.0"
\score { \relative c' { \time 3/4 c4 d e | f g | g2. | }  \layout { } \midi { } }
LY
printf '\\version "2.24.0"\n\\score { \\relative c'"'"' { c4 d e \\foo f }  \\layout { } }\n' > p/syntax.ly
cat > p/evil.ly <<LY
\\version "2.24.0"
#(system "touch $T/PWNED_BY_SYSTEM")
#(call-with-output-file "$T/PWNED_BY_WRITE" (lambda (p) (display "x" p)))
#(display (call-with-input-file "$HOME/.bashrc" read-line))
{ c'4 d' e' f' }
LY
printf '\\version "2.24.0"\n\\score { \\relative c'"'"' { c4 d e f }  \\layout { } }\n' > p/nomidi.ly
sum0=$(find p -type f | sort | xargs md5sum | md5sum)
# a good score
php "$ST" check p/good.ly c.md >/dev/null; has "No problems found." c.md && has "[exit code 0]" c.md && has "PDF made" c.md && has "MIDI made" c.md && ok || bad "good score: $(cat c.md | head -12)"
has "Run in a sandbox" c.md && ok || bad "the report does not say it ran in a sandbox"
php "$ST" build p/good.ly o.pdf >/dev/null; head -c 4 o.pdf | grep -q '%PDF' && ok || bad "build did not make a PDF"
php "$ST" midi p/good.ly o.mid >/dev/null; head -c 4 o.mid | grep -q 'MThd' && ok || bad "midi is not a MIDI file"
php "$ST" png p/good.ly o.png >/dev/null; head -c 8 o.png | grep -q PNG && ok || bad "png"
[ "$(find p -type f | sort | xargs md5sum | md5sum)" = "$sum0" ] && ok || bad "the project folder got files (the build must be in a scratch copy)"
# bar check and syntax error, with line and column
php "$ST" check p/short.ly s.md >/dev/null; has "short.ly(2," s.md && has "Warning: barcheck failed" s.md && has "bar before that point" s.md || has "bar before" s.md; ok
grep -qE '^short\.ly\([0-9]+,[0-9]+\) Warning: barcheck' s.md && ok || bad "bar check line,col: $(grep -i bar s.md | head -3)"
php "$ST" check p/syntax.ly y.md >/dev/null; grep -qE '^syntax\.ly\([0-9]+,[0-9]+\) Error:' y.md && has "[exit code 1]" y.md && ok || bad "syntax error: $(sed -n 8,12p y.md)"
[ "$(grep -cE '^(.+?)\([0-9]+,[0-9]+\) (Error|Warning): ' y.md)" -ge 1 ] && ok || bad "summary-box regex"
php "$ST" midi p/nomidi.ly x.mid >/dev/null 2>&1; [ $? = 1 ] && ok || bad "midi without a \\midi block was not refused"
# THE SAFETY: a malicious score is contained
php "$ST" check p/evil.ly e.md >/dev/null 2>&1; [ ! -e "$T/PWNED_BY_SYSTEM" ] && ok || bad "a SYSTEM COMMAND in a score ran outside the sandbox"
[ ! -e "$T/PWNED_BY_WRITE" ] && ok || bad "a score wrote a file outside its scratch folder"
has "[exit code 1]" e.md && has "Guile signaled an error" e.md && ok || bad "the malicious score must fail to compile: $(sed -n 8,12p e.md)"
out=$(php "$ST" build p/evil.ly e.pdf 2>&1); echo "$out" | grep -qE "BUILT WITH [0-9]+ ERROR" && [ ! -e "$T/PWNED_BY_SYSTEM" ] && ok || bad "building the malicious score must say it was built with errors, and still not run it: $out"
# without bwrap the tool must refuse (simulate by hiding it from the PATH)
mkdir nobw; for b in php lilypond; do ln -s "$(command -v $b)" nobw/$b; done; PATH="$T/nobw" "$(command -v php)" "$ST" check p/good.ly nb.md >/dev/null 2>nb.err; [ $? = 1 ] && grep -q "bwrap" nb.err && grep -q "not run without it" nb.err && ok || bad "without bwrap the tool must REFUSE: $(cat nb.err)"
# update, imports, new
printf '\\version "2.18.2"\n\\relative c'"'"' { c4 d e f }\n' > p/old.ly; php "$ST" update p/old.ly u.ly >/dev/null; grep -q '2.24' u.ly && ok || bad "convert-ly did not update the version: $(head -2 u.ly)"
printf 'X:1\nT:Test\nM:4/4\nL:1/4\nK:C\nC D E F|G A B c|\n' > p/tune.abc; php "$ST" abc p/tune.abc a.ly >/dev/null; grep -q '\\version' a.ly && ok || bad "abc to ly"
cat > p/t.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd"><score-partwise version="3.1"><part-list><score-part id="P1"><part-name>Music</part-name></score-part></part-list><part id="P1"><measure number="1"><attributes><divisions>1</divisions><key><fifths>0</fifths></key><time><beats>4</beats><beat-type>4</beat-type></time><clef><sign>G</sign><line>2</line></clef></attributes><note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><type>whole</type></note></measure></part></score-partwise>
XML
php "$ST" musicxml p/t.xml m.ly >/dev/null; grep -q '\\version' m.ly && ok || bad "musicxml to ly"
php "$ST" new . n.txt tune1 key=d time=3/4 tempo=90 >/dev/null; [ -f tune1.ly ] && grep -q '\\key d' tune1.ly && grep -q 'time 3/4' tune1.ly && grep -q 'tempo 4 = 90' tune1.ly && ok || bad "new tune: $(ls)"
mkdir nt; php "$ST" new nt n2.txt "tune1" >/dev/null; php "$ST" new nt n3.txt "tune1" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "new over an existing file was not refused"
php "$ST" new nt n4.txt "x key=h" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad key was not refused"
php "$ST" check tune1.ly nc.md >/dev/null; has "No problems found." nc.md && ok || bad "the scaffold must be a clean score: $(sed -n 8,14p nc.md)"
# play (only when a sound font works)
if command -v timidity >/dev/null 2>&1; then php "$ST" wav p/good.ly o.wav >/dev/null 2>&1; if [ -s o.wav ]; then [ "$(stat -c %s o.wav)" -gt 20000 ] && ok || bad "the wav is too small"; else echo "  (timidity made no sound: no sound font? the play check was skipped)"; fi; fi
# refusals, scratch, guard, definitions
php "$ST" check x.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
echo hi > x.txt; php "$ST" check x.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-.ly file was not refused"
php "$ST" frob p/good.ly x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
ls -d /tmp/score_* 2>/dev/null | grep -q . && bad "a scratch folder was left in /tmp" || ok
head -20 "$ROOT/cockpit_app/score_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/score_tool (check|build|midi|wav|png|update|musicxml|abc|new) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/score.json" > pc 2>&1; [ "$(cat pc)" = 9 ] && ok || bad "score.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/music-notation.json")" = score ] && ok || bad "the kind does not name the tool"
echo "score_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
