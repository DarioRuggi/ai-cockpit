#!/usr/bin/env bash
# =============================================================================
# install_tex.sh — a LaTeX system for the Academic paper tools (cockpit_app/latex_tool).
#
#   bash Installs/install_tex.sh [none|recommended|full] [--dry-run]
#
#   none         nothing
#   recommended  the packages most papers need (xcolor, booktabs, hyperref's etoolbox, microtype, the standard fonts)     ~22 MB download on Ubuntu
#   full         recommended + latex-extra (tikz-adjacent extras, cleveref, listings, ...), LuaTeX with fontspec (Hebrew and Unicode-font papers),
#                bibtex-extra, biber (biblatex), latexmk                                                                  ~217 MB download, ~640 MB installed
#
# Default: recommended. Runs sudo itself when not root; --dry-run prints what it would install (and, on apt, the size) without changing anything.
# The Debian/Ubuntu package names are tested; the Fedora, Arch and openSUSE ones are best effort (collections by their usual names) and untested.
# macOS: not installed here (MacTeX is several GB): the tools say what is missing.
# =============================================================================
set -u
LEVEL="recommended"; DRY=0
for a in "$@"; do case "$a" in none|recommended|full) LEVEL="$a" ;; --dry-run) DRY=1 ;; -h|--help) sed -n 2,16p "$0"; exit 0 ;; *) echo "install_tex: unknown argument: $a" >&2; exit 2 ;; esac; done
[ "$LEVEL" = none ] && { echo "install_tex: none chosen: nothing to do."; exit 0; }

PM=""
if [ "$(uname -s)" = Darwin ]; then echo "install_tex: macOS: install MacTeX or BasicTeX from https://www.tug.org/mactex/ (several GB, not done here)."; exit 0
elif command -v apt-get >/dev/null 2>&1; then PM=apt
elif command -v dnf >/dev/null 2>&1; then PM=dnf
elif command -v pacman >/dev/null 2>&1; then PM=pacman
elif command -v zypper >/dev/null 2>&1; then PM=zypper
else echo "install_tex: no supported package manager (apt, dnf, pacman, zypper)." >&2; exit 1; fi

case "$PM" in
    apt)    REC="texlive-latex-base texlive-latex-recommended texlive-fonts-recommended"
            FULL="$REC texlive-latex-extra texlive-luatex texlive-bibtex-extra biber latexmk" ;;
    dnf)    REC="texlive-latex texlive-collection-latexrecommended texlive-collection-fontsrecommended"
            FULL="$REC texlive-collection-latexextra texlive-collection-luatex texlive-collection-bibtexextra texlive-biber texlive-latexmk" ;;
    pacman) REC="texlive-core texlive-latexextra texlive-fontsextra"
            FULL="$REC texlive-bibtexextra biber texlive-binextra" ;;
    zypper) REC="texlive-latex texlive-collection-latexrecommended texlive-collection-fontsrecommended"
            FULL="$REC texlive-collection-latexextra texlive-collection-luatex texlive-collection-bibtexextra texlive-biber texlive-latexmk" ;;
esac
PKGS="$REC"; [ "$LEVEL" = full ] && PKGS="$FULL"
echo "install_tex: $LEVEL set for $PM: $PKGS"

if [ "$PM" = apt ]; then
    plan="$(apt-get -s install $PKGS 2>/dev/null | awk '/^Inst/{print $2}')"
    if [ -n "$plan" ]; then
        echo "$plan" | xargs apt-cache show 2>/dev/null | awk '/^Package:/{n++} /^Size:/{d+=$2} /^Installed-Size:/{i+=$2} END{printf "install_tex: %d packages to add, download about %.0f MB, installed about %.0f MB\n", n, d/1048576, i/1024}'
    else echo "install_tex: nothing new to install (already present), or the package lists are not available."; fi
fi
[ "$DRY" = 1 ] && { echo "install_tex: --dry-run: nothing changed."; exit 0; }

SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"
case "$PM" in
    apt)    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS ;;
    dnf)    $SUDO dnf install -y $PKGS ;;
    pacman) $SUDO pacman -S --needed --noconfirm $PKGS ;;
    zypper) $SUDO zypper --non-interactive install $PKGS ;;
esac
rc=$?
[ "$rc" = 0 ] || { echo "install_tex: the package manager failed (exit $rc)." >&2; exit "$rc"; }

# verify: the things the Academic paper tools need, by what is actually on disk
miss=0; chk() { if kpsewhich "$1" >/dev/null 2>&1; then echo "  ok   $1"; else echo "  MISSING $1"; miss=1; fi; }
echo "install_tex: checking:"
for f in xcolor.sty booktabs.sty etoolbox.sty hyperref.sty natbib.sty; do chk "$f"; done
if [ "$LEVEL" = full ]; then
    for f in fontspec.sty cleveref.sty; do chk "$f"; done
    for b in lualatex biber latexmk bibtex; do if command -v "$b" >/dev/null 2>&1; then echo "  ok   $b"; else echo "  MISSING $b"; miss=1; fi; done
fi
[ "$miss" = 0 ] && echo "install_tex: done." || { echo "install_tex: installed, but something above is missing." >&2; exit 1; }
