#!/usr/bin/env bash
# =============================================================================
# install_security_conf.sh — install cockpit-security.conf into the local Apache.
#
# Same shape as install_cache_conf.sh: idempotent, needs root, tests the config
# before reloading and REVERTS if the test fails (a server that will not start is
# worse than the problem this fixes).  Debian/Ubuntu use conf-available +
# a2enconf; Fedora/Arch/SUSE drop the file into conf.d.
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/cockpit-security.conf"
[ -f "$SRC" ] || { echo "security conf: source missing ($SRC)"; exit 1; }

if [ -d /etc/apache2/conf-available ]; then          # Debian / Ubuntu / Mint
    install -m 644 "$SRC" /etc/apache2/conf-available/cockpit-security.conf || exit 1
    a2enconf cockpit-security >/dev/null 2>&1
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2 >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1
        echo "security conf: installed (apache2)"
    else
        a2disconf cockpit-security >/dev/null 2>&1
        echo "security conf: apache configtest FAILED — change reverted, nothing reloaded"; exit 1
    fi
elif [ -d /etc/httpd/conf.d ]; then                   # Fedora / RHEL / Arch / SUSE
    install -m 644 "$SRC" /etc/httpd/conf.d/cockpit-security.conf || exit 1
    if httpd -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
        systemctl reload httpd >/dev/null 2>&1
        echo "security conf: installed (httpd)"
    else
        rm -f /etc/httpd/conf.d/cockpit-security.conf
        echo "security conf: httpd configtest FAILED — change reverted"; exit 1
    fi
else
    echo "security conf: no Apache config directory found — skipped"
fi
