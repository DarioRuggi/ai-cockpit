#!/usr/bin/env bash
# =============================================================================
# test_php_conf.sh — prove cockpit-php.conf lifts the upload limits under mod_php, and only for Cockpit.
#
# Throwaway Apache AS THE CURRENT USER on a high port with the system's libphp (no root, the real server is not
# touched). Runs twice: WITHOUT the conf (a 3 MB multipart upload must be dropped — otherwise the test proves
# nothing) and WITH it (the same upload arrives, a 40 MB one too; a non-Cockpit folder keeps PHP's own limits).
#   bash Installs/apache/test_php_conf.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MODS=/usr/lib/apache2/modules
command -v apache2 >/dev/null 2>&1 || { echo "apache2 not installed — cannot run"; exit 2; }
ls "$MODS"/libphp*.so >/dev/null 2>&1 || { echo "mod_php (libphp) not installed — cannot run"; exit 2; }
PHPSO="$(ls "$MODS"/libphp*.so | head -1)"
T="$(mktemp -d)"; PORT=18098; PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/www/html/cockpit" "$T/www/html/other" "$T/run" "$T/log"
for d in cockpit other; do
cat > "$T/www/html/$d/up.php" <<'PHP'
<?php header('Content-Type: application/json');
echo json_encode(['upload_max' => ini_get('upload_max_filesize'), 'post_max' => ini_get('post_max_size'),
                  'got' => isset($_FILES['f']) ? ($_FILES['f']['error'] === 0 ? $_FILES['f']['size'] : 'err' . $_FILES['f']['error']) : 'none']);
PHP
done
cp "$HERE/../../cockpit_app/.user.ini" "$T/www/html/cockpit/.user.ini" 2>/dev/null     # mod_php must IGNORE it (the conf is what acts)
head -c $((3*1024*1024)) /dev/urandom > "$T/f3"; head -c $((40*1024*1024)) /dev/urandom > "$T/f40"

run() {
    local inc=""; [ "$1" = with ] && inc="Include $HERE/cockpit-php.conf"
    cat > "$T/apache.conf" <<CONF
ServerRoot "$T"
PidFile $T/run/apache.pid
Listen 127.0.0.1:$PORT
ErrorLog $T/log/error.log
LoadModule mpm_prefork_module $MODS/mod_mpm_prefork.so
LoadModule authz_core_module $MODS/mod_authz_core.so
LoadModule dir_module $MODS/mod_dir.so
LoadModule mime_module $MODS/mod_mime.so
LoadModule php_module $PHPSO
TypesConfig /etc/mime.types
DocumentRoot "$T/www/html"
<Directory />
    AllowOverride None
    Require all denied
</Directory>
<Directory "$T/www/">
    Require all granted
</Directory>
<FilesMatch ".+\.ph(ar|p|tml)\$">
    SetHandler application/x-httpd-php
</FilesMatch>
$inc
CONF
    apache2 -f "$T/apache.conf" -t >"$T/log/t.out" 2>&1 || { echo "config test FAILED:"; cat "$T/log/t.out"; exit 1; }
    apache2 -f "$T/apache.conf" -k start >"$T/log/start.out" 2>&1
    for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/other/up.php" && break; sleep 0.1; done
    PID="$(cat "$T/run/apache.pid" 2>/dev/null)"
}
stop() { apache2 -f "$T/apache.conf" -k stop >/dev/null 2>&1; for i in $(seq 1 30); do [ -f "$T/run/apache.pid" ] || break; sleep 0.1; done; PID=""; }
j() { php -r '$d=json_decode(stream_get_contents(STDIN),true); echo $d["'"$1"'"] ?? "?";'; }
echo "== the installer's inline copy must say the same as cockpit-php.conf"
_directives() { grep -vE '^\s*(#|$)'; }
INLINE="$(sed -n "/^_php_conf_body()/,/^}/p" "$HERE/../install_cockpit.sh" | sed -n "/<<'PHPCONF'/,/^PHPCONF/p" | sed '1d;$d' | _directives)"
FILE="$(_directives < "$HERE/cockpit-php.conf")"
PASS=0; FAIL=0
if [ -n "$INLINE" ] && [ "$INLINE" = "$FILE" ]; then echo "  PASS  install_cockpit.sh and cockpit-php.conf have identical directives"; PASS=$((PASS+1))
else echo "  FAIL  the inline copy in install_cockpit.sh drifted from cockpit-php.conf"; FAIL=$((FAIL+1)); fi
expect() { if [ "$2" = "$3" ]; then echo "  PASS  $1  ($2)"; PASS=$((PASS+1)); else echo "  FAIL  $1  (got '$2', wanted '$3')"; FAIL=$((FAIL+1)); fi; }
upload() { curl -s -F "f=@$2" "http://127.0.0.1:$PORT$1" | j got; }

echo "== WITHOUT the conf (the limits must bite, or this test proves nothing)"
run without
expect "PHP's own upload_max_filesize applies to Cockpit"  "$(curl -s http://127.0.0.1:$PORT/cockpit/up.php | j upload_max)" 2M
expect "a 3 MB multipart upload is dropped"                "$(upload /cockpit/up.php "$T/f3")" err1
stop

echo "== WITH cockpit-php.conf"
run with
expect "upload_max_filesize is 1G under /cockpit"          "$(curl -s http://127.0.0.1:$PORT/cockpit/up.php | j upload_max)" 1G
expect "post_max_size is 1G under /cockpit"                "$(curl -s http://127.0.0.1:$PORT/cockpit/up.php | j post_max)" 1G
expect "a 3 MB upload now arrives whole"                   "$(upload /cockpit/up.php "$T/f3")" $((3*1024*1024))
expect "a 40 MB upload arrives whole"                      "$(upload /cockpit/up.php "$T/f40")" $((40*1024*1024))
expect "a non-Cockpit folder keeps PHP's own 2M"           "$(curl -s http://127.0.0.1:$PORT/other/up.php | j upload_max)" 2M
expect "...and still drops a 3 MB upload"                  "$(upload /other/up.php "$T/f3")" err1
stop
echo; echo "php conf: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
