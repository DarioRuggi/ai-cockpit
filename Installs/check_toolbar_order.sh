#!/usr/bin/env bash
# =============================================================================
# check_toolbar_order.sh — the Toolbar's buttons are in ALPHABETICAL order, and stay so.
#
# Dario's rule (2026-10-03): every Toolbar button sits in alphabetical order by its English
# label, including every button added later. Archive and Backup were first put after Notepad
# and had to be moved; this makes the next one fail the build instead.
#
# Reads the buttons of the Toolbar panel (#right-toolbar) in index.html, takes each one's label
# (the text of its data-i18n span), and fails if two neighbours are out of order (case-insensitive).
# =============================================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
php -r '
$L = file($argv[1]); $start = null;
foreach ($L as $i => $l) if (strpos($l, "id=\"right-toolb") !== false) { $start = $i; break; }
if ($start === null) { echo "check_toolbar_order: Toolbar panel not found in index.html\n"; exit(1); }
$labels = [];
for ($i = $start + 1; $i < $start + 90; $i++) {
    $l = $L[$i];
    if (strpos($l, "class=\"sidebar-vtab\"") !== false || strpos($l, "id=\"right-") !== false && $i > $start + 2 && strpos($l, "right-toolb") === false) break;
    if (!preg_match("/<button class=\"action-btn\"/", $l)) continue;
    if (!preg_match("/data-i18n=\"ui\.[a-z0-9.]+\">([^<]+)</", $l, $m)) { echo "  line " . ($i + 1) . ": a Toolbar button without a data-i18n label\n"; exit(1); }
    $labels[] = [trim($m[1]), $i + 1];
}
$bad = 0;
for ($i = 1; $i < count($labels); $i++)
    if (strcasecmp($labels[$i - 1][0], $labels[$i][0]) > 0) { echo "  line {$labels[$i][1]}: \"{$labels[$i][0]}\" belongs before \"{$labels[$i - 1][0]}\"\n"; $bad++; }
if ($bad) { echo "check_toolbar_order: $bad button(s) out of alphabetical order (Toolbar buttons are kept A-Z)\n"; exit(1); }
echo "check_toolbar_order: " . count($labels) . " Toolbar buttons, all in alphabetical order\n";
' "$ROOT/cockpit_app/index.html"
