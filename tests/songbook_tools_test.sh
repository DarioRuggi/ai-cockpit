#!/usr/bin/env bash
# songbook_tools_test.sh — the Music practice and songbook tools (cockpit_app/songbook_tool, tools_builtins/songbook.json, kinds/music-practice.json): practice log, set list,
# chord transposer with capo, lyric sheets, songbook index, refusals.   bash tests/songbook_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/cockpit_app/songbook_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "songbook_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { n=$((n+1)); echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
t() { if eval "$1"; then ok; else bad "$2"; fi; }
cd "$T" || exit 1
cat > log.csv <<'TXT'
date,piece,minutes
2026-10-05,Scales,20
2026-10-06,Scales,20
2026-10-06,Sonata,30
2026-10-07,Sonata,45
2026-10-09,Scales,30
2026-10-12,Sonata,60
2026-10-13,Scales,40
2026-10-14,Sonata,50
TXT
cat > sl.csv <<'TXT'
title,minutes,key,tempo
One,3:30,G,120
Two,4:00,D,121
Three,3:00,E,119
Four,5,Bb,80
Five,4:15,F#,80
TXT
printf 'title,minutes,key,tempo\nA,3:00,C,100\nB,3:00,Am,140\nC,3:00,G,90\n' > sl_ok.csv
printf 'C G Am F\nWalking down the road today\nC        G\nSecond line\n' > plain.txt
printf 'Bb F/A Gm Eb\nSome words\n' > flat.txt
printf '{title: T}\n{key: G}\n[G]Hello [D/F#]world [Em7]again [Cadd9]now\nPlain line, A day in B town\n' > cp.cho
cat > songs.md <<'TXT'
# The Road Home
Key: G

[Verse 1]
G        D
First line here
[Chorus]
C   G
Chorus words

Verse 3 text unlabeled
more

# Amazing
Key: Am

[Verse 1]
Words
[Verse 2]
Words two

# Empty One
Key: C
TXT
printf 'title,verses\nThe Road Home,3\nAmazing,2\nMissing Song,1\n' > set.csv
sum0=$(md5sum log.csv sl.csv plain.txt cp.cho songs.md set.csv | md5sum)
# practice
php "$ST" practice log.csv p.md goal=120 today=2026-10-14 >/dev/null; t "[ \$? = 0 ]" "practice exited non-zero"
t "has '| 2026-W41 | 145 | 2 |' p.md && has '| 2026-W42 | 150 | 2 |' p.md" "minutes per week: \$(grep W4 p.md)"
t "has '| Sonata | 185 | 4 | 2026-10-14 |' p.md" "minutes per piece"
t "has 'Longest streak: 3 consecutive days' p.md && has 'Current streak: 3 days' p.md" "streaks: \$(grep -i streak p.md)"
t "has 'Met in 2 of 2 weeks' p.md" "goal progress"
php "$ST" practice log.csv p2.md goal=200 today=2026-10-25 >/dev/null; t "has 'Met in 0 of 2 weeks' p2.md && has '50 to go' p2.md && has 'Current streak: 0 days' p2.md && has 'no practice for 11 days' p2.md" "a bigger goal and a later today: \$(grep -E 'Met|streak|Note' p2.md)"
printf 'date,piece,minutes\n2026-13-01,X,10\n2026-10-01,Y,abc\n2026-10-02,Z,20\n' > badlog.csv; php "$ST" practice badlog.csv p3.md today=2026-10-14 >/dev/null; t "has 'badlog.csv(2) Error: the date' p3.md && has 'badlog.csv(3) Error: the minutes' p3.md" "bad rows: \$(grep Error p3.md)"
# setlist
php "$ST" setlist sl.csv s.md slot=20 gap=30 >/dev/null
t "has '| 5 | Five | 4:15 | 21:45 | F# | 80 |' s.md" "running time with changeovers: \$(grep '^| ' s.md)"
t "has 'sl.csv(1) Error: the set runs 21:45, 1:45 over the slot of 20 minutes' s.md" "over the slot"
t "has 'sl.csv(4) Warning: the same tempo (about 119 bpm) three songs in a row' s.md" "same tempo three in a row"
t "has 'big key jump: \"Three\" (E) to \"Four\" (Bb)' s.md && has 'big key jump: \"Four\" (Bb) to \"Five\" (F#)' s.md" "big key jumps: \$(grep Warning s.md)"
t "! has 'big key jump: \"One\"' s.md" "G to D (a fifth) flagged as a big jump"
php "$ST" setlist sl_ok.csv s2.md slot=10 >/dev/null; t "has '0 errors, 0 warnings' s2.md && has 'Fits the slot of 10 minutes with 1:00 to spare' s2.md" "an acceptable set (Am after C is close): \$(grep -E 'Warning|Error|Fits' s2.md)"
php "$ST" setlist sl_ok.csv s3.md slot=30 >/dev/null; t "has 'short of the slot of 30 minutes' s3.md" "a set far short of the slot"
php "$ST" setlist sl_ok.csv s4.md >/dev/null; t "has 'no slot length given' s4.md" "no slot"
# transpose
php "$ST" transpose plain.txt tr.txt +2 >/dev/null; t "head -1 tr.txt | grep -qx 'D A Bm G'" "plain chords +2: \$(head -3 tr.txt)"
t "sed -n 3p tr.txt | grep -qx 'D        A'" "chord positions over the lyrics are kept: \$(sed -n 3p tr.txt | cat -A)"
t "sed -n 2p tr.txt | grep -qx 'Walking down the road today'" "a lyric line was changed"
php "$ST" transpose tr.txt back.txt -2 >/dev/null; t "head -1 back.txt | grep -qx 'C G Am F'" "round trip +2 then -2"
php "$ST" transpose plain.txt tr2.txt to=F >/dev/null; t "head -1 tr2.txt | grep -qx 'F C Dm Bb'" "to=F uses flats: \$(head -1 tr2.txt)"
php "$ST" transpose plain.txt tr3.txt to=G >/dev/null; t "head -1 tr3.txt | grep -qx 'G D Em C'" "to=G from the first chord: \$(head -1 tr3.txt)"
t "has 'Capo suggestion: no capo' tr3.txt" "G D Em C needs no capo: \$(grep Capo tr3.txt)"
php "$ST" transpose flat.txt tr4.txt +1 >/dev/null; t "head -1 tr4.txt | grep -qx 'B  F#/A# G#m E'" "flat chart +1 (key B uses sharps; slash bass F#/A# spelling): \$(head -1 tr4.txt)" || true
php "$ST" transpose flat.txt tr5.txt to=D from=Bb >/dev/null; t "head -1 tr5.txt | grep -qx 'D  A/C# Bm G'" "to=D from=Bb: \$(head -1 tr5.txt)"
php "$ST" transpose flat.txt tr6.txt +2 >/dev/null; t "head -1 tr6.txt | grep -qx 'C  G/B Am F'" "flats kept in a flat chart: \$(head -1 tr6.txt)"
t "has 'Capo suggestion: capo on fret 3' tr2.txt && has 'D A Bm G' tr2.txt" "a capo for F C Dm Bb: \$(grep Capo tr2.txt)"
php "$ST" transpose cp.cho tr7.cho to=Eb >/dev/null; t "has '{key: Eb}' tr7.cho && has '[Eb]Hello [Bb/D]world [Cm7]again [Abadd9]now' tr7.cho" "ChordPro to=Eb: \$(sed -n 2,3p tr7.cho)"
t "has 'Plain line, A day in B town' tr7.cho" "lyrics in ChordPro changed"
php "$ST" transpose cp.cho tr8.cho +0 >/dev/null; t "sed -n 3p tr8.cho | grep -qx '\[G\]Hello \[D/F#\]world \[Em7\]again \[Cadd9\]now'" "+0 changed the chart"
php "$ST" transpose cp.cho tr9.cho +2 sharps >/dev/null; t "has '[A]Hello [E/G#]world [F#m7]again [Dadd9]now' tr9.cho" "ChordPro +2 sharps: \$(sed -n 3p tr9.cho)"
printf 'just some words here\n' > nochord.txt; php "$ST" transpose nochord.txt x.txt +2 >/dev/null 2>&1; t "[ \$? = 1 ]" "a file without chords was not refused"
php "$ST" transpose plain.txt x.txt >/dev/null 2>&1; t "[ \$? = 2 ]" "transpose without an amount was not refused"
php "$ST" transpose plain.txt x.txt to=H >/dev/null 2>&1; t "[ \$? = 2 ]" "a bad key was not refused"
# lyrics
php "$ST" lyrics songs.md l.md set.csv >/dev/null
t "has 'songs.md(11) Warning: an unlabelled block of 2 lines in \"The Road Home\"' l.md" "an unlabelled block: \$(grep -E 'Error|Warning|Note' l.md)"
t "has 'songs.md(1) Error: \"The Road Home\" has 1 verses but the set list says 3: 2 missing' l.md" "missing verses against the set list"
t "has 'Error: the set list has \"Missing Song\" but there are no lyrics for it' l.md" "a set list song without lyrics"
t "has 'Error: the song \"Empty One\" has no lyrics under it' l.md && has 'Note: \"Empty One\" is not in the set list' l.md" "an empty song / not in the set list"
printf '# S\n[Verse 1]\na\n\n[Verse 3]\nb\n' > gap.md; php "$ST" lyrics gap.md l2.md >/dev/null; t "has '\"S\" has verse 3 but no verse 2' l2.md" "a missing verse number"
printf '# S\n{start_of_verse: Verse 1}\nline\n{end_of_verse}\n{c: Chorus}\nline two\n' > cho.md; php "$ST" lyrics cho.md l3.md >/dev/null; t "has '0 errors, 0 warnings' l3.md" "ChordPro labels not understood: \$(grep -E 'Error|Warning' l3.md)"
# index
php "$ST" index songs.md ix.md 'title="My Book"' >/dev/null; t "has 'title: \"My Book\"' ix.md && has '1. The Road Home (G)' ix.md && has '3. Empty One (C)' ix.md" "contents: \$(head -10 ix.md)"
t "awk '/^## Alphabetical/{f=1} f' ix.md | tr -d '\n' | grep -q '\*\*A\*\*- Amazing (2)\*\*E\*\*- Empty One (3)\*\*R\*\*- The Road Home (1)'" "alphabetical index ignoring 'The': \$(awk '/^## Alphabetical/{f=1} f' ix.md | head -14)"
t "has '## Index by key' ix.md && has '**Am**' ix.md && has 'pandoc FILE.md --toc' ix.md" "index by key / pandoc line"
if command -v pandoc >/dev/null 2>&1; then pandoc ix.md -t plain -o ix.txt 2>/dev/null; t "grep -q 'Amazing' ix.txt" "pandoc could not read the index"; else ok; fi
# refusals, untouched, guard, json
printf '\xF9\xEC\n' > ansi.txt; php "$ST" lyrics ansi.txt x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a non-UTF-8 file was not refused"
: > empty.csv; php "$ST" practice empty.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "an empty file was not refused"
php "$ST" practice nope.csv x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a missing file was not refused"
php "$ST" frob log.csv x.md >/dev/null 2>&1; t "[ \$? = 2 ]" "an unknown subcommand was not refused"
printf 'plain words\n' > nosongs.md; php "$ST" index nosongs.md x.md >/dev/null 2>&1; t "[ \$? = 1 ]" "a file without songs was not refused"
t "[ \"\$(md5sum log.csv sl.csv plain.txt cp.cho songs.md set.csv | md5sum)\" = \"$sum0\" ]" "an original was changed"
t "head -20 '$ST' | grep -q \"PHP_SAPI !== 'cli'\"" "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/songbook_tool (practice|setlist|transpose|lyrics|index) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/songbook.json" > pc 2>&1; t "[ \"\$(cat pc)\" = 5 ]" "songbook.json presets: \$(cat pc)"
cat > kv.php <<'PHP'
<?php require $argv[1] . '/cockpit_app/kinds_lib.php'; $k = json_decode(file_get_contents($argv[2]), true); $e = ''; $v = kind_validate($k, $e); if (!$v) { echo "invalid: $e"; exit(1); } foreach (['id','name','icon','description','note','verify','group','details','examples','tools'] as $f) if (empty($v[$f])) { echo "missing $f"; exit(1); } if ($v['note'] !== $k['note'] || $v['details'] !== $k['details']) { echo 'text too long'; exit(1); } echo 'ok';
PHP
php kv.php "$ROOT" "$ROOT/cockpit_app/kinds/music-practice.json" > kc 2>&1; t "[ \"\$(cat kc)\" = ok ]" "the music-practice kind: \$(cat kc)"
t "[ \"\$(jq -r '.tools[0].tool' '$ROOT/cockpit_app/kinds/music-practice.json')\" = songbook ] && [ \"\$(jq -r .group '$ROOT/cockpit_app/kinds/music-practice.json')\" = Media ] && jq -r '.tools[].tool' '$ROOT/cockpit_app/kinds/music-practice.json' | grep -qx score" "the kind does not name the tool / group / the score kind tool"
t "jq -r .note '$ROOT/cockpit_app/kinds/music-practice.json' | grep -q 'Music scores'" "the kind note does not point to the Music scores kind"
echo "songbook_tools_test: $((n-fails)) passed, $fails failed"; [ "$fails" = 0 ]
