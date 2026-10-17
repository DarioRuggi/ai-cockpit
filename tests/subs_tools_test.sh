#!/usr/bin/env bash
# subs_tools_test.sh — the Subtitling tools (cockpit_app/sub_tool, tools_builtins/subs.json, kinds/subtitling.json): the lint on a file with every kind of
# fault and on a clean one, conversion through ffmpeg, shifting and stretching, refusals, the original untouched.   bash tests/subs_tools_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ST="$ROOT/cockpit_app/sub_tool"
command -v php >/dev/null 2>&1 || { echo "subs_tools_test: php is needed - SKIPPED"; exit 0; }
php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "subs_tools_test: php mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
printf '\xEF\xBB\xBF1\r\n00:00:01,000 --> 00:00:03,000\r\nשלום עולם\r\nשורה שנייה\r\n\r\n2\r\n00:00:02,500 --> 00:00:04,000\r\nOverlaps the first cue\r\n\r\n3\r\n00:00:05,000 --> 00:00:05,400\r\nToo fast and way too short for anyone to read all of this text\r\n\r\n4\r\n00:00:07,000 --> 00:00:06,000\r\nEnds before it starts\r\n\r\n5\r\n00:00:08,000 --> 00:00:09,000\r\n\r\n' > "$T/bad.srt"
printf '1\n00:00:01,000 --> 00:00:03,000\nHello <i>there</i>\n\n2\n00:00:04,000 --> 00:00:06,500\nשלום\n' > "$T/good.srt"
sum0=$(md5sum "$T/bad.srt" "$T/good.srt" | md5sum)
# check: every fault, with its line, in the form the summary box reads
php "$ST" check "$T/bad.srt" "$T/bad.md" >/dev/null; [ $? = 0 ] && ok || bad "check exited non-zero"
has "bad.srt(7) Error: cue 2 overlaps cue 1 by 500 ms" "$T/bad.md" && ok || bad "overlap: $(grep Error "$T/bad.md")"
has "bad.srt(15) Error: cue 4 ends" "$T/bad.md" && ok || bad "end before start"
has "bad.srt(19) Error: cue 5 has no text" "$T/bad.md" && ok || bad "empty cue"
has "bad.srt(11) Warning: cue 3 has a line of 62 characters" "$T/bad.md" && has "characters per second" "$T/bad.md" && has "on screen for only 400 ms" "$T/bad.md" && ok || bad "the cue-3 warnings"
has "(3 errors, 3 warnings)" "$T/bad.md" && has "[exit code 1]" "$T/bad.md" && ok || bad "counts / exit line"
has "with a BOM, UTF-8" "$T/bad.md" && ok || bad "BOM not reported"
[ "$(grep -cE '^(.+?)\([0-9]+(,[0-9]+)?\) (Error|Warning): ' "$T/bad.md")" = 6 ] && ok || bad "summary-box regex does not match all six lines"
php "$ST" check "$T/good.srt" "$T/good.md" >/dev/null; has "No problems found." "$T/good.md" && has "[exit code 0]" "$T/good.md" && ok || bad "clean file: $(tail -3 "$T/good.md")"
# not UTF-8
printf '1\n00:00:01,000 --> 00:00:02,000\n\xF9\xEC\xE5\xED\n' > "$T/ansi.srt"; php "$ST" check "$T/ansi.srt" "$T/ansi.md" >/dev/null; has "ansi.srt(1) Error: the file is not valid UTF-8" "$T/ansi.md" && ok || bad "a Windows-1255 file was not flagged"
# vtt without header
printf '00:00:01.000 --> 00:00:02.000\nhi\n' > "$T/nohdr.vtt"; php "$ST" check "$T/nohdr.vtt" "$T/nohdr.md" >/dev/null; has "must start with WEBVTT" "$T/nohdr.md" && ok || bad "missing WEBVTT header"
# convert (ffmpeg)
if command -v ffmpeg >/dev/null 2>&1; then
  php "$ST" convert "$T/good.srt" "$T/good.vtt" >/dev/null; head -1 "$T/good.vtt" | grep -q WEBVTT && has "שלום" "$T/good.vtt" && has "<i>there</i>" "$T/good.vtt" && ok || bad "srt to vtt: $(head -5 "$T/good.vtt")"
  php "$ST" convert "$T/good.vtt" "$T/back.srt" >/dev/null; has "00:00:04,000 --> 00:00:06,500" "$T/back.srt" && ok || bad "vtt back to srt"
  php "$ST" convert "$T/good.srt" "$T/good.ass" >/dev/null; has "[Events]" "$T/good.ass" && ok || bad "srt to ass"
  php "$ST" check "$T/good.ass" "$T/ass.md" >/dev/null; has "[exit code 0]" "$T/ass.md" && ok || bad "check of an .ass: $(tail -3 "$T/ass.md")"
else echo "  (ffmpeg missing: conversion checks skipped)"; fi
php "$ST" convert "$T/good.srt" "$T/x.txt" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown output format was not refused"
# shift
php "$ST" shift "$T/good.srt" "$T/s1.srt" +1500 >/dev/null; has "00:00:02,500 --> 00:00:04,500" "$T/s1.srt" && has "00:00:05,500 --> 00:00:08,000" "$T/s1.srt" && ok || bad "shift +1500: $(cat "$T/s1.srt")"
php "$ST" shift "$T/good.srt" "$T/s2.srt" -2s >/dev/null; has "00:00:00,000 --> 00:00:01,000" "$T/s2.srt" && has "00:00:02,000 --> 00:00:04,500" "$T/s2.srt" && ok || bad "shift -2s clamps the start at 0: $(cat "$T/s2.srt")"
php "$ST" shift "$T/good.srt" "$T/s3.srt" -4000 >/dev/null; [ "$(grep -c -- '-->' "$T/s3.srt")" = 1 ] && ok || bad "a cue ending before 0 was not dropped"
php "$ST" shift "$T/good.srt" "$T/s4.vtt" '*25/23.976' >/dev/null; head -1 "$T/s4.vtt" | grep -q WEBVTT && has "00:00:01.043 --> 00:00:03.128" "$T/s4.vtt" && ok || bad "stretch to vtt: $(cat "$T/s4.vtt")"
php "$ST" shift "$T/good.srt" "$T/s5.srt" '*5' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an absurd stretch was not refused"
php "$ST" shift "$T/good.srt" "$T/s6.srt" '' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing amount was not refused"
php "$ST" shift "$T/good.srt" "$T/s7.srt" 'soon' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a nonsense amount was not refused"
# refusals and the originals
php "$ST" check "$T/nope.srt" "$T/r.md" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
echo hi > "$T/a.txt"; php "$ST" check "$T/a.txt" "$T/r.md" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-subtitle file was not refused"
[ "$(md5sum "$T/bad.srt" "$T/good.srt" | md5sum)" = "$sum0" ] && ok || bad "an original changed"
( cd "$T" && REQUEST_METHOD=GET php-cgi -q "$ST" >/dev/null 2>&1; true ); ok
# the definitions
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/sub_tool (check|convert|shift) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/subs.json" > "$T/pc" 2>&1; [ "$(cat "$T/pc")" = 6 ] && ok || bad "subs.json presets: $(cat "$T/pc")"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/subtitling.json")" = subs ] && ok || bad "the kind does not name the tool"
echo "subs_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
