#!/usr/bin/env bash
# =============================================================================
# install_cache_conf.sh — install cockpit-cache.conf into the local Apache.
#
# Idempotent; safe to re-run. Needs root (it writes to /etc and reloads apache).
# Debian/Ubuntu use conf-available + a2enmod/a2enconf; Fedora/Arch/SUSE drop the
# file into conf.d and already load mod_headers by default.
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/cockpit-cache.conf"
[ -f "$SRC" ] || { echo "cache conf: source missing ($SRC)"; exit 1; }

if [ -d /etc/apache2/conf-available ]; then          # Debian / Ubuntu / Mint
    install -m 644 "$SRC" /etc/apache2/conf-available/cockpit-cache.conf || exit 1
    a2enmod headers  >/dev/null 2>&1
    a2enconf cockpit-cache >/dev/null 2>&1
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2 >/dev/null 2>&1 || service apache2 reload >/dev/null 2>&1
        echo "cache conf: installed (apache2, headers enabled)"
    else
        a2disconf cockpit-cache >/dev/null 2>&1
        echo "cache conf: apache configtest FAILED — change reverted, nothing reloaded"; exit 1
    fi
elif [ -d /etc/httpd/conf.d ]; then                   # Fedora / RHEL / Arch / SUSE
    install -m 644 "$SRC" /etc/httpd/conf.d/cockpit-cache.conf || exit 1
    if httpd -t >/dev/null 2>&1 || apachectl -t >/dev/null 2>&1; then
        systemctl reload httpd >/dev/null 2>&1
        echo "cache conf: installed (httpd)"
    else
        rm -f /etc/httpd/conf.d/cockpit-cache.conf
        echo "cache conf: httpd configtest FAILED — change reverted"; exit 1
    fi
else
    echo "cache conf: no Apache config directory found — skipped"
fi
