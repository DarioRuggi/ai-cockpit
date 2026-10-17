#!/usr/bin/env bash
# imagegen_tools_test.sh — cockpit_app/image_tool with a FAKE stable-diffusion.cpp (a script that records its arguments and writes a real PNG): the exact command the program is given,
# presets and caps, seeds and the record next to every image, variants, a prompt that tries to be a shell command, failures said plainly, check.   bash tests/imagegen_tools_test.sh
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; IT="$ROOT/cockpit_app/image_tool"
command -v php >/dev/null 2>&1 || { echo "imagegen_tools_test: php is needed - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/ig_XXXX) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
PNG='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='
cat > fakesd <<SH
#!/bin/bash
# records the arguments, one per line, in args.<n>; writes a PNG to the -o path
n=\$(ls args.* 2>/dev/null | wc -l); printf '%s\n' "\$@" > "$T/args.\$((n+1))"
[ -f "$T/sd_fail" ] && { echo "ggml_vulkan: out of memory while allocating" >&2; exit 1; }
[ -f "$T/sd_nopng" ] && exit 0
o=""; while [ \$# -gt 0 ]; do [ "\$1" = "-o" ] && o="\$2"; shift; done
echo $PNG | base64 -d > "\$o"; exit 0
SH
chmod +x fakesd; echo fake > model.safetensors; export COCKPIT_SD_BIN="$T/fakesd" COCKPIT_SD_MODEL="$T/model.safetensors"
printf 'a red fox in the snow' > p.txt
arg() { sed -n "$2p" "$T/args.$1"; }       # line number in the n-th recorded call
php "$IT" gen p.txt out.png seed=123 >/dev/null; [ -s out.png ] && head -c 4 out.png | grep -q PNG && ok || bad "an image is written"
tr '\n' ' ' < args.1 | grep -q -- "-M img_gen -m $T/model.safetensors -p a red fox in the snow -o out.png --steps 20 -W 512 -H 512 --seed 123 -t 8 --diffusion-fa --vae-tiling" && ok || bad "the exact command: $(tr '\n' ' ' < args.1)"
jq -e '.seed==123 and .steps==20 and .size=="512x512" and .prompt=="a red fox in the snow" and .model=="model.safetensors"' out.png.prompt.json >/dev/null && ok || bad "the record next to the image: $(cat out.png.prompt.json)"
php "$IT" gen p.txt o2.png preset=logo steps=8 size=900x300 negative="blurry text" >/dev/null; tr '\n' ' ' < args.2 | grep -q -- "-p a red fox in the snow, flat vector logo, centered, simple, solid dark background -o o2.png --steps 8 -W 512 -H 300" && tr '\n' ' ' < args.2 | grep -q -- "-n blurry text" && ok || bad "preset suffix, size capped to 512, negative prompt: $(tr '\n' ' ' < args.2)"
php "$IT" gen p.txt o3.png preset=background >/dev/null; tr '\n' ' ' < args.3 | grep -q -- "-W 512 -H 512" && ok || bad "background preset capped at 512 (a 4 GB GPU)"
php "$IT" gen p.txt o4.png >/dev/null; php "$IT" gen p.txt o5.png >/dev/null; s4=$(jq .seed o4.png.prompt.json); s5=$(jq .seed o5.png.prompt.json); [ "$s4" != "$s5" ] && [ "$s4" -ge 1 ] && ok || bad "without seed= each image gets its own random seed, and it is recorded: $s4 $s5"
# a prompt that tries to be a shell command stays text
printf 'x"; touch %s/PWNED; echo "$(touch %s/PWNED2) `touch %s/PWNED3` and quotes %s' "$T" "$T" "$T" "'" > evil.txt; php "$IT" gen evil.txt e.png seed=1 >/dev/null; [ ! -e PWNED ] && [ ! -e PWNED2 ] && [ ! -e PWNED3 ] && grep -qF 'touch' args.6 && ok || bad "a prompt must never run as a command"
printf 'line one\n\n   line   two\n' > ml.txt; php "$IT" gen ml.txt m.png >/dev/null; grep -qx 'line one line two' "$T/args.7" || tr '\n' ' ' < "$T/args.7" | grep -q -- "-p line one line two" ; ok
php -r 'file_put_contents("long.txt", str_repeat("word ", 400));'; php "$IT" gen long.txt l.png >/dev/null; [ "$(jq -r '.prompt|length' l.png.prompt.json)" -le 1000 ] && ok || bad "a very long prompt is cut at 1000 characters"
# variants: several seeds, one sheet, a record for each
php "$IT" variants p.txt v.png count=3 seed=10 >/dev/null; [ -f v.1.png ] && [ -f v.2.png ] && [ -f v.3.png ] && [ -s v.png ] && ok || bad "variants make count images and a sheet: $(ls v*)"
jq -e '.seeds==[10,11,12]' v.png.prompt.json >/dev/null && jq -e '.seed==11' v.2.png.png.prompt.json >/dev/null 2>&1 || jq -e '.seed==11' v.2.png.prompt.json >/dev/null && ok || bad "variants record their seeds: $(cat v.png.prompt.json | head -c 200)"
php "$IT" variants p.txt v9.png count=9 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "count above 6 refused"
# failures are said plainly
touch sd_fail; php "$IT" gen p.txt f.png >/dev/null 2>e.txt; rc=$?; [ $rc = 1 ] && grep -q "did not make an image" e.txt && grep -q "out of memory" e.txt && ok || bad "a failing sd: $(cat e.txt)"; rm -f sd_fail f.png
touch sd_nopng; php "$IT" gen p.txt f2.png >/dev/null 2>e.txt; [ $? = 1 ] && grep -q "did not make an image" e.txt && ok || bad "sd exits 0 but writes no image: must fail"; rm -f sd_nopng
COCKPIT_SD_BIN="$T/nonexistent" php "$IT" gen p.txt f3.png >/dev/null 2>e.txt; [ $? = 1 ] && grep -q "not built" e.txt && ok || bad "no sd: $(cat e.txt)"
COCKPIT_SD_MODEL="$T/nomodel" php "$IT" gen p.txt f4.png >/dev/null 2>e.txt; [ $? = 1 ] && grep -q "no Stable Diffusion model" e.txt && ok || bad "no model: $(cat e.txt)"
: > empty.txt; php "$IT" gen empty.txt f5.png >/dev/null 2>&1; [ $? = 1 ] && ok || bad "empty prompt"
php "$IT" gen nope.txt f6.png >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing prompt file"
php "$IT" gen p.txt f7.jpg >/dev/null 2>&1; [ $? = 1 ] && ok || bad "output must be .png"
for bad_arg in "steps=0" "steps=99" "size=big" "seed=abc" "preset=nope"; do php "$IT" gen p.txt f8.png $bad_arg >/dev/null 2>&1; [ $? = 1 ] && ok || bad "$bad_arg was accepted"; done
php "$IT" frob p.txt x.png >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
php "$IT" check p.txt c.md >/dev/null; has "Ready." c.md && has "[exit code 0]" c.md && has "model.safetensors" c.md && ok || bad "check: $(cat c.md)"
COCKPIT_SD_BIN="$T/nonexistent" php "$IT" check p.txt c2.md >/dev/null; has "not built" c2.md && has "[exit code 1]" c2.md && ok || bad "check without sd"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/image_tool (gen|variants|check) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/imagegen.json" > pc 2>&1; [ "$(cat pc)" = 6 ] && ok || bad "imagegen.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/image-generation.json")" = imagegen ] && ok || bad "the kind does not name the tool first"
head -25 "$IT" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
echo "imagegen_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
