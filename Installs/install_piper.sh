#!/usr/bin/env bash
# =============================================================================
# install_piper.sh — local text-to-speech for AI Cockpit's Sound (Speech) button.
#
# Installs the piper binary + voice models into ~/ai-tools/piper (en, es by
# default) and writes a Hebrew wrapper (~/ai-tools/israwave/heb-tts.sh) that
# uses espeak-ng (piper has no Hebrew voice; israwave ships no CLI binary).
#
# Hebrew needs the system espeak-ng:  sudo apt install -y espeak-ng
# Usage: install_piper.sh [--voices en,es]
# =============================================================================
set -euo pipefail
fetch_mirror() { local url="$1" out="$2" name="$3"; curl -fL --retry 2 -o "$out" "$url" 2>/dev/null && return 0; echo "  upstream failed ($url) — trying ruggi.site mirror"; curl -fL --retry 2 -o "$out" "https://ruggi.site/backups.php?get=$name" 2>/dev/null && return 0; rm -f "$out"; return 1; }

VOICES="${PIPER_VOICES:-en,es}"
PREFIX="${PIPER_PREFIX:-$HOME/ai-tools/piper}"
HEB_DIR="${HEB_DIR:-$HOME/ai-tools/israwave}"
while [ $# -gt 0 ]; do case "$1" in --voices) VOICES="$2"; shift 2;; *) echo "unknown arg: $1" >&2; exit 2;; esac; done

say(){ printf '\033[36m▶\033[0m %s\n' "$*"; }
ok(){  printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn(){ printf '  \033[33m!\033[0m %s\n' "$*"; }

HF="https://huggingface.co/rhasspy/piper-voices/resolve/main"
# lang → voice path on HF (onnx + onnx.json share the basename)
# Built from the upstream voices.json, not hand-picked. It used to map ONLY en and
# es -- the developer's own two languages -- so a French, German or Japanese user
# got no voice at all and the Sound button silently did nothing for them.
# Unpinned 2026-09-24. Hebrew is deliberately absent here and handled below via
# espeak-ng: Piper's he_IL voice declares phoneme_type "hebrew" and needs a
# separate Hebrew phonemizer that Piper does not ship.
voice_url(){ case "$1" in
    ar) echo "$HF/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx";;
    bg) echo "$HF/bg/bg_BG/dimitar/medium/bg_BG-dimitar-medium.onnx";;
    ca) echo "$HF/ca/ca_ES/upc_ona/medium/ca_ES-upc_ona-medium.onnx";;
    cs) echo "$HF/cs/cs_CZ/jirka/medium/cs_CZ-jirka-medium.onnx";;
    cy) echo "$HF/cy/cy_GB/bu_tts/medium/cy_GB-bu_tts-medium.onnx";;
    da) echo "$HF/da/da_DK/talesyntese/medium/da_DK-talesyntese-medium.onnx";;
    de) echo "$HF/de/de_DE/mls/medium/de_DE-mls-medium.onnx";;
    el) echo "$HF/el/el_GR/joy/medium/el_GR-joy-medium.onnx";;
    en) echo "$HF/en/en_US/lessac/medium/en_US-lessac-medium.onnx";;
    es) echo "$HF/es/es_ES/davefx/medium/es_ES-davefx-medium.onnx";;
    et) echo "$HF/et/et_EE/news/medium/et_EE-news-medium.onnx";;
    fa) echo "$HF/fa/fa_IR/amir/medium/fa_IR-amir-medium.onnx";;
    fi) echo "$HF/fi/fi_FI/harri/medium/fi_FI-harri-medium.onnx";;
    fr) echo "$HF/fr/fr_FR/mls/medium/fr_FR-mls-medium.onnx";;
    hi) echo "$HF/hi/hi_IN/pratham/medium/hi_IN-pratham-medium.onnx";;
    hu) echo "$HF/hu/hu_HU/anna/medium/hu_HU-anna-medium.onnx";;
    id) echo "$HF/id/id_ID/news_tts/medium/id_ID-news_tts-medium.onnx";;
    is) echo "$HF/is/is_IS/bui/medium/is_IS-bui-medium.onnx";;
    it) echo "$HF/it/it_IT/paola/medium/it_IT-paola-medium.onnx";;
    ja) echo "$HF/ja/ja_JP/hi_fi_captain/medium/ja_JP-hi_fi_captain-medium.onnx";;
    ka) echo "$HF/ka/ka_GE/natia/medium/ka_GE-natia-medium.onnx";;
    kk) echo "$HF/kk/kk_KZ/issai/high/kk_KZ-issai-high.onnx";;
    ko) echo "$HF/ko/ko_KR/kss/medium/ko_KR-kss-medium.onnx";;
    lb) echo "$HF/lb/lb_LU/marylux/medium/lb_LU-marylux-medium.onnx";;
    lv) echo "$HF/lv/lv_LV/aivars/medium/lv_LV-aivars-medium.onnx";;
    ne) echo "$HF/ne/ne_NP/chitwan/medium/ne_NP-chitwan-medium.onnx";;
    nl) echo "$HF/nl/nl_BE/nathalie/medium/nl_BE-nathalie-medium.onnx";;
    no) echo "$HF/no/no_NO/nvcc/medium/no_NO-nvcc-medium.onnx";;
    pl) echo "$HF/pl/pl_PL/darkman/medium/pl_PL-darkman-medium.onnx";;
    pt) echo "$HF/pt/pt_BR/cadu/medium/pt_BR-cadu-medium.onnx";;
    ro) echo "$HF/ro/ro_RO/mihai/medium/ro_RO-mihai-medium.onnx";;
    ru) echo "$HF/ru/ru_RU/denis/medium/ru_RU-denis-medium.onnx";;
    sk) echo "$HF/sk/sk_SK/lili/medium/sk_SK-lili-medium.onnx";;
    sl) echo "$HF/sl/sl_SI/artur/medium/sl_SI-artur-medium.onnx";;
    sr) echo "$HF/sr/sr_RS/serbski_institut/medium/sr_RS-serbski_institut-medium.onnx";;
    sv) echo "$HF/sv/sv_SE/alma/medium/sv_SE-alma-medium.onnx";;
    sw) echo "$HF/sw/sw_CD/lanfrica/medium/sw_CD-lanfrica-medium.onnx";;
    th) echo "$HF/th/th_TH/tsync2/medium/th_TH-tsync2-medium.onnx";;
    tr) echo "$HF/tr/tr_TR/dfki/medium/tr_TR-dfki-medium.onnx";;
    uk) echo "$HF/uk/uk_UA/ukrainian_tts/medium/uk_UA-ukrainian_tts-medium.onnx";;
    vi) echo "$HF/vi/vi_VN/vais1000/medium/vi_VN-vais1000-medium.onnx";;
    zh) echo "$HF/zh/zh_CN/chaowen/medium/zh_CN-chaowen-medium.onnx";;
    *)  echo "";;
esac; }

mkdir -p "$PREFIX" "$HEB_DIR"

# 1. piper binary (self-contained tarball: binary + libs + espeak-ng-data)
if [ ! -x "$PREFIX/piper" ]; then
    say "Downloading piper binary"
    TMP="$(mktemp -d)"
    fetch_mirror "https://github.com/rhasspy/piper/releases/latest/download/piper_linux_x86_64.tar.gz" "$TMP/piper.tgz" piper_linux_x86_64.tar.gz
    tar -xzf "$TMP/piper.tgz" -C "$TMP"
    # tarball unpacks a `piper/` dir → move its contents into $PREFIX
    cp -a "$TMP/piper/." "$PREFIX/"
    rm -rf "$TMP"
fi
[ -x "$PREFIX/piper" ] || { echo "piper binary missing after install"; exit 1; }
ok "piper: $("$PREFIX/piper" --version 2>/dev/null || echo installed)"

# 2. voices (named <lang>_*.onnx so generate.php's piper_voice() globs them)
IFS=',' read -ra VL <<< "$VOICES"
for lang in "${VL[@]}"; do
    lang="$(echo "$lang" | tr -d '[:space:]')"; [ -n "$lang" ] || continue
    [ "$lang" = "he" ] && continue    # Hebrew handled below (espeak-ng)
    url="$(voice_url "$lang")"
    if [ -z "$url" ]; then warn "no preset voice for '$lang' — skipping (drop a ${lang}_*.onnx into $PREFIX)"; continue; fi
    base="$(basename "$url")"
    if [ -f "$PREFIX/$base" ]; then ok "voice present: $base"; continue; fi
    say "Downloading $lang voice: $base"
    curl -fL --retry 3 -o "$PREFIX/$base"        "$url"        || { warn "voice download failed: $lang"; continue; }
    curl -fL --retry 3 -o "$PREFIX/$base.json"   "$url.json"   || warn "voice config download failed: $lang"
    ok "voice: $base (+ .json)"
done

# 3. Hebrew wrapper via espeak-ng (generate.php runs heb-tts.sh "<text>" "<out.wav>")
if printf '%s' "$VOICES" | grep -qw he; then
    cat > "$HEB_DIR/heb-tts.sh" <<'SH'
#!/usr/bin/env bash
# Hebrew TTS via the SYSTEM espeak-ng. Args: <text> <out.wav>
# (Resolve explicitly — piper bundles a non-CLI espeak-ng that can shadow PATH.)
set -u
TEXT="${1:-}"; OUT="${2:-out.wav}"
ESPEAK=""
for c in /usr/bin/espeak-ng /usr/local/bin/espeak-ng /bin/espeak-ng; do
    [ -x "$c" ] && { ESPEAK="$c"; break; }
done
[ -n "$ESPEAK" ] || { echo "system espeak-ng not installed (sudo apt install -y espeak-ng)" >&2; exit 1; }
"$ESPEAK" -v he -s 150 -w "$OUT" "$TEXT"
SH
    chmod +x "$HEB_DIR/heb-tts.sh"
    if [ -x /usr/bin/espeak-ng ] || [ -x /usr/local/bin/espeak-ng ]; then ok "Hebrew: heb-tts.sh (system espeak-ng ready)"
    else warn "Hebrew: heb-tts.sh written — install the system voice: sudo apt install -y espeak-ng"; fi
fi

echo; ok "Done. Speech (TTS) ready for: $VOICES. Test the Sound button → Speech."
