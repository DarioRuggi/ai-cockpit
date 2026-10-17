#!/usr/bin/env bash
# podcast_tools_test.sh — the Podcast tools (cockpit_app/podcast_tool, tools_builtins/podcast.json, kinds/podcast.json) on a synthetic episode: speech made with eSpeak, silences at
# both ends and in the middle, very quiet.   bash tests/podcast_tools_test.sh     SKIPPED without php, ffmpeg or espeak-ng
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; PT="$ROOT/cockpit_app/podcast_tool"
for c in php ffmpeg ffprobe; do command -v $c >/dev/null 2>&1 || { echo "podcast_tools_test: $c is needed - SKIPPED"; exit 0; }; done
ES=$(command -v espeak-ng || command -v espeak) || { echo "podcast_tools_test: espeak-ng is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
"$ES" -v en -w s1.wav "Welcome to the show. Today we talk about subtitles and loudness." 2>/dev/null; "$ES" -v en -w s2.wav "And now the second topic, after a long pause." 2>/dev/null
for d in 2 5 4; do ffmpeg -nostdin -y -loglevel error -f lavfi -i anullsrc=r=22050:cl=mono -t $d sil$d.wav; done
ffmpeg -nostdin -y -loglevel error -i sil2.wav -i s1.wav -i sil5.wav -i s2.wav -i sil4.wav -filter_complex "[0][1][2][3][4]concat=n=5:v=0:a=1,volume=-18dB" -ar 22050 -ac 1 -b:a 40k ep.mp3
[ -s ep.mp3 ] && ok || bad "fixture not made"
sum0=$(md5sum ep.mp3 | cut -c1-32)
# check
php "$PT" check ep.mp3 c.md >/dev/null; has "Podcast check: ep.mp3" c.md && has "MP3, mono, 22050 Hz" c.md && ok || bad "check header: $(head -5 c.md)"
has "Warning: too quiet" c.md && ok || bad "a very quiet episode must be flagged: $(grep -E 'LUFS' c.md | head -3)"
has "Warning: the bit rate is only 40 kbit/s" c.md && ok || bad "low bit rate"
has "Note: the sample rate is 22050 Hz" c.md && ok || bad "sample rate"
has "the audio starts with 2 s of silence" c.md && has "the audio ends with a long silence" c.md && ok || bad "leading/trailing silence: $(grep -E 'silence' c.md)"
has "Note: a pause of 5." c.md && ok || bad "the middle pause: $(grep -E 'pause' c.md)"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md)" = 2 ] && ok || bad "summary-box regex finds $(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md) lines, want 2"
has "[exit code 0]" c.md && ok || bad "exit line"
# chapters
php "$PT" chapters ep.mp3 ch.md >/dev/null; has "0:00:00 — start" ch.md && has "after a pause of 5." ch.md && ok || bad "chapters: $(cat ch.md)"
# normalize -> measured loudness near the target
php "$PT" normalize ep.mp3 n.mp3 >/dev/null; [ -s n.mp3 ] && ok || bad "normalize wrote nothing"
php "$PT" check n.mp3 nc.md >/dev/null; has "Warning: too quiet" nc.md && bad "after normalising it must not be 'too quiet'" || ok
li=$(grep -oE 'Loudness: -?[0-9.]+' nc.md | grep -oE -- '-?[0-9.]+$'); awk -v l="${li:-0}" 'BEGIN{exit !(l > -20 && l < -14)}' && ok || bad "loudness after normalising is ${li:-?} LUFS (want -20..-14)"
php "$PT" normalize ep.mp3 n.m4a >/dev/null; [ "$(ffprobe -v error -show_entries stream=codec_name -of csv=p=0 n.m4a)" = aac ] && ok || bad "m4a is not AAC"
# clean, trim
php "$PT" clean ep.mp3 cl.mp3 >/dev/null; [ -s cl.mp3 ] && ok || bad "clean wrote nothing"
php "$PT" trim ep.mp3 t.mp3 >/dev/null; d0=$(ffprobe -v error -show_entries format=duration -of csv=p=0 ep.mp3); d1=$(ffprobe -v error -show_entries format=duration -of csv=p=0 t.mp3); awk -v a="$d0" -v b="$d1" 'BEGIN{exit !(b < a - 4)}' && ok || bad "trim did not shorten it enough ($d0 -> $d1)"
# tags: the audio is untouched
php "$PT" tag ep.mp3 tg.mp3 'title=Episode 12;artist=Dario;album=My Show' >/dev/null; [ "$(ffprobe -v error -show_entries format_tags=title -of csv=p=0 tg.mp3)" = "Episode 12" ] && ok || bad "tags not set"
[ "$(ffmpeg -v error -i ep.mp3 -f md5 - 2>&1)" = "$(ffmpeg -v error -i tg.mp3 -f md5 - 2>&1)" ] && ok || bad "tagging changed the audio"
php "$PT" tag ep.mp3 x.mp3 'bogus=1' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown tag was not refused"
php "$PT" tag ep.mp3 x.wav 'title=a' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a different extension was not refused for tag"
php "$PT" normalize ep.mp3 x.xyz >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown output format was not refused"
php "$PT" check nope.mp3 x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
echo hi > a.txt; php "$PT" check a.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-audio file was not refused"
[ "$(md5sum ep.mp3 | cut -c1-32)" = "$sum0" ] && ok || bad "the original changed"
head -20 "$ROOT/cockpit_app/podcast_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/podcast_tool (check|chapters|normalize|clean|trim|tag) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/podcast.json" > pc 2>&1; [ "$(cat pc)" = 8 ] && ok || bad "podcast.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/podcast.json")" = podcast ] && ok || bad "the kind does not name the tool"
echo "podcast_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
