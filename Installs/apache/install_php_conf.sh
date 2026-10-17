#!/usr/bin/env bash
# =============================================================================
# install_php_conf.sh — install cockpit-php.conf (upload size limits for mod_php).
#
# Same shape as install_security_conf.sh: idempotent, needs root, tests the Apache
# config before reloading and REVERTS if the test fails.  Debian/Ubuntu use
# conf-available + a2enconf; Fedora/Arch/SUSE drop the file into conf.d.
# The conf only does anything when mod_php is loaded (it is wrapped in <IfModule>),
# so it is harmless on a PHP-FPM setup, which reads .user.ini instead.
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/cockpit-php.conf"
[ -f "$SRC" ] || { echo "php conf: source missing ($SRC)"; exit 1; }

if [ -d /etc/apache2/conf-available ]; then          # Debian / Ubuntu / Mint
    install -m 644 "$SRC" /etc/apache2/conf-available/cockpit-php.conf || exit 1
    a2enconf cockpit-php >/dev/null 2>&1
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2 >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1
        echo "php conf: installed (apache2)"
    else
        a2disconf cockpit-php >/dev/null 2>&1
        echo "php conf: apache configtest FAILED — change reverted, nothing reloaded"; exit 1
    fi
elif [ -d /etc/httpd/conf.d ]; then                   # Fedora / RHEL / Arch / SUSE
    install -m 644 "$SRC" /etc/httpd/conf.d/cockpit-php.conf || exit 1
    if httpd -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
        systemctl reload httpd >/dev/null 2>&1
        echo "php conf: installed (httpd)"
    else
        rm -f /etc/httpd/conf.d/cockpit-php.conf
        echo "php conf: httpd configtest FAILED — change reverted"; exit 1
    fi
else
    echo "php conf: no Apache config directory found — skipped"
fi
