#!/usr/bin/env bash
# website_tools_test.sh — the Web Site tools (cockpit_app/web_check, web_serve, web_router.php, tools_builtins/website.json) on a small site that
# has one of each defect: exact problems and counts, the other modes, and the preview server (served, hidden files and unknown URLs 404, PHP runs,
# one server per folder, stop, automatic stop, nothing but 127.0.0.1).
#   bash tests/website_tools_test.sh      SKIPPED without php and curl.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; WC="$ROOT/cockpit_app/web_check"; WS="$ROOT/cockpit_app/web_serve"
for c in php curl jq; do command -v $c >/dev/null 2>&1 || { echo "website_tools_test: $c is needed - SKIPPED"; exit 0; }; done
T=$(mktemp -d) || exit 1; SRVPIDS=""
cleanup() { bash "$WS" stop "$T/site" "$T/stop.out" >/dev/null 2>&1; rm -rf "${T:?}"; }; trap cleanup EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
mkdir -p "$T/site/css" "$T/site/img" "$T/site/about" "$T/site/.git"
cat > "$T/site/index.html" <<'X'
<!DOCTYPE html>
<html>
<head>
<title>Home</title>
<link rel="stylesheet" href="css/style.css">
<link rel="stylesheet" href="css/missing.css">
</head>
<body>
<header><nav><a href="about/">About</a> <a href="about/team.html#members">Team</a> <a href="about/team.html#nobody">Nobody</a></nav></header>
<img src="img/Logo.png">
<img src="img/photo.jpg" alt="a photo">
<a href="#contact">Contact</a> <a href="">empty</a> <a href="https://example.com" target="_blank">ext</a>
<div id="x">1</div><div id="x">2</div>
<font color="red">old</font>
<p>Unclosed <b>bold
</body>
</html>
X
cat > "$T/site/about/index.html" <<'X'
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>About us</title></head>
<body><main><h1 id="top">About</h1><a href="../index.html">Home</a> <a href="../nope.html">Gone</a> <a href="/img/photo.jpg">abs</a></main></body></html>
X
cat > "$T/site/about/team.html" <<'X'
<!DOCTYPE html><html lang="he"><head><meta charset="utf-8"><title>צוות</title></head><body><h2 id="members">חברים</h2></body></html>
X
printf 'body { color: red; }\n.a { background: url(../img/missing.png); }\n.b { margin: 0;\n' > "$T/site/css/style.css"
printf 'secret' > "$T/site/.git/config"; printf 'x' > "$T/site/img/photo.jpg"; printf 'x' > "$T/site/img/logo.png"; printf 'old' > "$T/site/index.html.bak"
printf '<?php echo "php ok ".(1+1);' > "$T/site/hello.php"

php "$WC" check "$T/site" "$T/check.txt" >/dev/null 2>&1; rc=$?
[ $rc = 0 ] && ok || bad "check exits non-zero: $rc"
has() { grep -qF -- "$1" "$T/check.txt"; }
has "9 errors, 3 warnings, 5 hints" && ok || bad "counts: $(tail -3 "$T/check.txt")"
tail -1 "$T/check.txt" | grep -qx '\[exit code 1\]' && ok || bad "no [exit code 1] line"
for want in \
  "about/index.html(3) Error: broken link ../nope.html: no such file: nope.html" \
  "css/style.css(2) Error: url(../img/missing.png): no such file: img/missing.png" \
  "css/style.css(3) Error: a { is never closed" \
  "index.html(6) Error: broken link css/missing.css: no such file: css/missing.css" \
  "index.html(9) Error: link about/team.html#nobody: the page about/team.html has no element with id 'nobody'" \
  "index.html(10) Warning: image without alt text: img/Logo.png" \
  "file name differs in case: the page says 'Logo.png', the file is 'logo.png'" \
  "index.html(12) Warning: a link with an empty href" \
  "index.html(12) Hint: target=\"_blank\" without rel=\"noopener\"" \
  "index.html(12) Error: no element with id 'contact' on this page (link #contact)" \
  "index.html(13) Error: duplicate id 'x'" \
  "index.html(14) Hint: old tag <font>" \
  "index.html(16) Error: Opening and ending tag mismatch: body and b" \
  "index.html(1) Warning: no <meta charset>" \
  "about/team.html(1) Hint: no <meta name=\"viewport\">"; do has "$want" && ok || bad "missing in the report: $want"; done
grep -q 'ID x already defined' "$T/check.txt" && bad "libxml's duplicate-id line is not filtered (it doubles ours)" || ok
grep -q 'about/index.html.*\.\./index.html' "$T/check.txt" && bad "a relative link up one folder was reported broken" || ok
grep -q 'about/index.html.*img/photo.jpg' "$T/check.txt" && bad "a root-relative link to an existing file was reported broken" || ok
grep -q 'team.html.*Error' "$T/check.txt" && bad "a valid Hebrew page was reported with errors" || ok
grep -q "^\.git\|\.git/" "$T/check.txt" && bad "the .git folder was looked at" || ok
# other modes
php "$WC" links "$T/site" "$T/links.txt" >/dev/null; grep -q "5 errors, 0 warnings, 0 hints" "$T/links.txt" && ok || bad "links: $(tail -3 "$T/links.txt")"
php "$WC" sitemap "$T/site" "$T/map.md" >/dev/null; grep -q "| about/team.html | צוות |" "$T/map.md" && grep -q "(3 pages)" "$T/map.md" && ok || bad "sitemap: $(cat "$T/map.md")"
php "$WC" check "$T/site/about/team.html" "$T/one.txt" >/dev/null; grep -q "1 pages" "$T/one.txt" && grep -q "0 errors" "$T/one.txt" && ok || bad "a single page: $(tail -2 "$T/one.txt")"
if php -m 2>/dev/null | grep -qi '^zip$'; then
    php "$WC" pack "$T/site" "$T/site.zip" >/dev/null && unzip -l "$T/site.zip" | grep -q "about/team.html" && ! unzip -l "$T/site.zip" | grep -qE '\.git|\.bak' && ok || bad "pack: $(unzip -l "$T/site.zip" 2>&1 | tail -8)"
fi
php "$WC" check "$T/nofolder" "$T/x.txt" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing folder must fail"
# the preview server
bash "$WS" start "$T/site" "$T/serve.txt" 5; [ $? = 0 ] && ok || bad "serve failed: $(cat "$T/serve.txt")"
U=$(head -1 "$T/serve.txt"); case "$U" in http://127.0.0.1:*) ok;; *) bad "the address is not on 127.0.0.1: $U";; esac
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$U$1"; }
[ "$(code '')" = 200 ] && [ "$(code about/)" = 200 ] && [ "$(code about/team.html)" = 200 ] && [ "$(code img/photo.jpg)" = 200 ] && ok || bad "served pages do not answer 200"
[ "$(code .git/config)" = 404 ] && [ "$(code index.html.bak)" = 404 ] && [ "$(code '%2egit/config')" = 404 ] && ok || bad "hidden files or backups are served"
[ "$(code nope)" = 404 ] && [ "$(code about/nope.html)" = 404 ] && [ "$(code css/)" = 404 ] && ok || bad "an unknown URL (or a folder without an index) does not answer 404"
[ "$(curl -s --max-time 3 "${U}hello.php")" = "php ok 2" ] && ok || bad "a PHP file did not run"
port=$(echo "$U" | sed 's/.*://; s#/##'); [ "$(ss -ltn 2>/dev/null | awk -v p=":$port\$" '$4 ~ p {print $4}' | sort -u)" = "127.0.0.1:$port" ] && ok || bad "the server listens on more than 127.0.0.1"
bash "$WS" start "$T/site" "$T/serve2.txt"; grep -q "Already being served: $U" "$T/serve2.txt" && ok || bad "a second start did not say it is already running: $(cat "$T/serve2.txt")"
bash "$WS" stop "$T/site" "$T/stop.txt"; grep -q "Stopped 1" "$T/stop.txt" && ok || bad "stop: $(cat "$T/stop.txt")"
sleep 0.5; [ "$(code '')" = 000 ] && ok || bad "the server still answers after stop"
bash "$WS" stop "$T/site" "$T/stop.txt"; grep -q "No preview" "$T/stop.txt" && ok || bad "a second stop should say nothing runs"
WEB_SERVE_SECONDS=2 bash "$WS" start "$T/site" "$T/serve3.txt"; U=$(head -1 "$T/serve3.txt"); [ "$(code '')" = 200 ] && ok || bad "the short-lived server did not start"
sleep 3.5; [ "$(code '')" = 000 ] && ok || bad "the server did not stop by itself"
bash "$WS" start "$T/nofolder" "$T/x.txt" >/dev/null 2>&1; [ $? = 1 ] && ok || bad "serve of a missing folder must fail"
# the tool definition
jq -e '.id=="website" and .binary=="php" and ([.presets[]|.id and .label and .command and .output_ext and .timeout_seconds]|all) and ([.presets[].id]|sort)==["check","links","pack","serve","sitemap","stop"]' "$ROOT/cockpit_app/tools_builtins/website.json" >/dev/null && ok || bad "website.json is incomplete"
echo "website_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
