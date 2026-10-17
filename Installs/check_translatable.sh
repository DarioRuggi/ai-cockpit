#!/usr/bin/env bash
# check_translatable.sh — WARNS (never fails) when new interface text was added without being
# marked translatable. Runs both annotators in --dry mode: anything they WOULD convert is new.
#   fix:  php Installs/lang_annotate.php && php Installs/lang_annotate_js.php && php Installs/lang_extract.php
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
h=$(php "$ROOT/Installs/lang_annotate.php" --dry 2>&1 | tail -1)
j=$(php "$ROOT/Installs/lang_annotate_js.php" --dry 2>&1 | tail -1)
nh=$(echo "$h" | grep -oE '[0-9]+' | head -4 | paste -sd+ | bc 2>/dev/null || echo 0)
nj=$(echo "$j" | grep -oE '^lang_annotate_js: [0-9]+ messages converted, [0-9]+ assignments' | grep -oE '[0-9]+' | paste -sd+ | bc 2>/dev/null || echo 0)
if [ "${nh:-0}" -gt 0 ] || [ "${nj:-0}" -gt 0 ]; then
  echo "check_translatable: WARNING — new text is not translatable yet (page: ${nh:-0}, scripts: ${nj:-0})."
  echo "  run: php Installs/lang_annotate.php && php Installs/lang_annotate_js.php && php Installs/lang_extract.php"
else
  echo "check_translatable: all interface text is marked translatable"
fi
exit 0
