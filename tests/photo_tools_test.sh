#!/usr/bin/env bash
# photo_tools_test.sh — the Photo tools (cockpit_app/photo_tool, tools_builtins/photo.json, kinds/photo-editing.json) on photos with real EXIF written by tests/photo_fixture.php: EXIF read,
# the check, strip, web-ready, batch zip, contact sheet, duplicates, rename plan, content-based type checks.   bash tests/photo_tools_test.sh     SKIPPED without php (exif), ImageMagick
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; PT="$ROOT/cockpit_app/photo_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^exif$' || { echo "photo_tools_test: php with exif is needed - SKIPPED"; exit 0; }
for c in convert identify; do command -v $c >/dev/null 2>&1 || { echo "photo_tools_test: ImageMagick ($c) is needed - SKIPPED"; exit 0; }; done
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
php "$ROOT/tests/photo_fixture.php" pics >/dev/null || { echo "photo_tools_test: fixture failed - SKIPPED"; exit 0; }
sum0=$(cd pics && md5sum * | md5sum)
# info
php "$PT" info pics/a.jpg i.md >/dev/null; has "800 x 600 pixels" i.md && has "Canon EOS 5D" i.md && has "2026:01:05 14:30:02" i.md && has "Orientation tag: 6" i.md && has "32.08528, 34.78167" i.md && ok || bad "info of a.jpg: $(sed -n 3,9p i.md)"
php "$PT" info pics i2.md >/dev/null; has "| a.jpg | 800x600 |" i2.md && has "| Canon EOS 5D | yes |" i2.md && has "with a GPS location: 2" i2.md && ok || bad "folder info: $(sed -n 5,16p i2.md)"
# check
php "$PT" check pics c.md >/dev/null; has "[exit code 1]" c.md && ok || bad "check must exit 1 (fake.jpg)"
has "a.jpg(1) Warning: contains the GPS location 32.0853" c.md && ok || bad "GPS warning"
has "a.jpg(1) Warning: the orientation tag is 6" c.md && ok || bad "orientation warning"
has "cmyk.jpg(1) Warning: a CMYK JPEG" c.md && ok || bad "CMYK"
has "fake.jpg(1) Error: not a photo type I can read" c.md && ok || bad "an SVG named .jpg must be an error"
has "tiny.jpg(1) Note: only 100x80 pixels" c.md && ok || bad "tiny"
has "several formats in one folder (jpeg, png)" c.md && ok || bad "mixed formats"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md)" -ge 5 ] && ok || bad "summary-box regex"
# strip: no metadata, rotation applied (800x600 with orientation 6 becomes 600x800)
php "$PT" strip pics/a.jpg s.jpg >/dev/null; [ "$(identify -format '%wx%h' s.jpg)" = "600x800" ] && ok || bad "strip must apply the rotation: $(identify -format '%wx%h' s.jpg)"
php -r '$e=@exif_read_data($argv[1],"ANY_TAG"); exit(empty($e["Make"]) && empty($e["GPSLatitude"]) && empty($e["DateTimeOriginal"]) ? 0 : 1);' s.jpg && ok || bad "strip left metadata behind"
php "$PT" strip pics/a.jpg s.png >/dev/null; head -c 8 s.png | grep -q PNG && ok || bad "strip to png"
# web: shrinks, never enlarges
php "$PT" web pics/a.jpg w.jpg max=500 quality=70 >/dev/null; [ "$(identify -format '%wx%h' w.jpg)" = "375x500" ] && ok || bad "web max=500: $(identify -format '%wx%h' w.jpg)"
php "$PT" web pics/tiny.jpg wt.jpg max=1600 >/dev/null; [ "$(identify -format '%wx%h' wt.jpg)" = "100x80" ] && ok || bad "web must never enlarge"
php -r '$e=@exif_read_data($argv[1],"ANY_TAG"); exit(empty($e["GPSLatitude"]) ? 0 : 1);' w.jpg && ok || bad "web copy kept the GPS"
[ "$(identify -format '%[colorspace]' w.jpg)" = "sRGB" ] && ok || bad "web copy is not sRGB: $(identify -format '%[colorspace]' w.jpg)"
php "$PT" enhance pics/a.jpg e.jpg >/dev/null; [ -s e.jpg ] && ok || bad "enhance"
php "$PT" web pics/fake.jpg x.jpg >/dev/null 2>x.err; [ $? = 1 ] && grep -q "judged by its content" x.err && ok || bad "an SVG named .jpg must be refused by web: $(cat x.err)"
php "$PT" web pics/a.jpg x.svg >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an .svg output was not refused"
php "$PT" web pics x.jpg >/dev/null 2>&1; [ $? = 1 ] && ok || bad "web on a folder was not refused"
# batch
php "$PT" batch pics b.zip max=300 >/dev/null; [ "$(unzip -l b.zip | grep -c '\.jpg')" = 7 ] && ok || bad "batch zip entries: $(unzip -l b.zip | awk '{print $4}' | tr '\n' ' ')"
unzip -o -q b.zip -d bz; [ "$(identify -format '%w' bz/a.jpg)" -le 300 ] 2>/dev/null || [ "$(identify -format '%h' bz/a.jpg)" -le 300 ]; ok
php -r '$e=@exif_read_data($argv[1],"ANY_TAG"); exit(empty($e["GPSLatitude"]) ? 0 : 1);' bz/a.jpg && ok || bad "batch copies kept the GPS"
unzip -l b.zip | grep -q fake && bad "the fake photo went into the batch" || ok
# sheet
php "$PT" sheet pics sh.png >/dev/null; [ "$(identify -format '%w' sh.png)" -gt 600 ] && ok || bad "contact sheet"
# duplicates
php "$PT" dupes pics d.md >/dev/null; has "a.jpg = a_copy.jpg" d.md && ok || bad "exact copies: $(sed -n 5,9p d.md)"
has "a.jpg (0.5 MP) ~ b.jpg" d.md && ok || bad "near-duplicate (the same picture resized): $(sed -n 9,13p d.md)"
grep -q "noexif.jpg\|cmyk.jpg\|c.png" <(sed -n '/Near-duplicates/,$p' d.md) && bad "different pictures were grouped as near-duplicates: $(sed -n '/Near-duplicates/,$p' d.md)" || ok
has "Nothing was deleted or moved." d.md && ok || bad "dupes must say nothing was moved"
# plan
php "$PT" plan pics pl.md >/dev/null; has "a.jpg -> 2026-01-05_14-30-02.jpg" pl.md && has "a_copy.jpg -> 2026-01-05_14-30-02_2.jpg" pl.md && has "b.jpg -> (no date taken: unchanged)" pl.md && ok || bad "rename plan: $(sed -n 5,9p pl.md)"
[ "$(cd pics && md5sum * | md5sum)" = "$sum0" ] && [ "$(ls pics | wc -l)" = 8 ] && ok || bad "the originals changed or files were added"
# refusals
php "$PT" info nope i.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing path was not refused"
# exiftool: tags / set / shift (into COPIES, original untouched)
if command -v exiftool >/dev/null 2>&1; then
  php "$PT" tags pics/a.jpg tg.md >/dev/null; has "Privacy-sensitive" tg.md && grep -qi "GPS" tg.md && has "Canon" tg.md && ok || bad "tags: $(sed -n 1,14p tg.md)"
  php "$PT" set pics/a.jpg set.jpg 'artist=Test Person' 'copyright=(c) 2026 Test' 'keywords=one,two' >/dev/null; exiftool -s3 -Artist set.jpg | grep -q "Test Person" && exiftool -s3 -Copyright set.jpg | grep -q "2026 Test" && exiftool -s3 -Keywords set.jpg | grep -q one && ok || bad "set: $(exiftool -Artist -Copyright -Keywords set.jpg)"
  php "$PT" set pics/a.jpg set2.png 'artist=x' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "set with another extension must be refused"
  php "$PT" set pics/a.jpg set3.jpg 'bogus=1' >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an unknown field must be refused"
  php "$PT" shift pics/a.jpg sh.jpg +1d2h30m >/dev/null; exiftool -s3 -DateTimeOriginal sh.jpg | grep -q "2026:01:06 17:00:02" && ok || bad "shift: $(exiftool -s3 -DateTimeOriginal sh.jpg)"
  php "$PT" shift pics/a.jpg sh2.jpg -2h >/dev/null; exiftool -s3 -DateTimeOriginal sh2.jpg | grep -q "2026:01:05 12:30:02" && ok || bad "shift back"
  php "$PT" shift pics/a.jpg sh3.jpg tomorrow >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a bad shift must be refused"
else echo "  (exiftool missing: tags/set/shift skipped)"; fi
mkdir empty; php "$PT" info empty i.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a folder with no photos was not refused"
php "$PT" frob pics x >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
ls -d /tmp/photo_* 2>/dev/null | grep -q . && bad "scratch folders left in /tmp" || ok
head -30 "$ROOT/cockpit_app/photo_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/photo_tool (info|check|strip|web|enhance|batch|sheet|dupes|plan|tags|set|shift) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/photo.json" > pc 2>&1; [ "$(cat pc)" = 12 ] && ok || bad "photo.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/photo-editing.json")" = photo ] && ok || bad "the kind does not name the tool"
echo "photo_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
