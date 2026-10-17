#!/bin/bash
# check_theme_readability.sh — build guard: every built-in theme must come out READABLE.
# Runs cockpit_app/js/features/theme-guard.js (the same code the app uses on every theme apply) over each built-in theme:
#   * the repaired copy has no remaining problem (the guard is idempotent), and
#   * a Mixed theme carries its own light-text set for the dark areas (textChrome) and dark text for the light content.
# The count of colours the guard has to lift is reported (informational: those themes keep their look but are brightened/darkened at apply time).
# Needs node (build machine only; the app itself ships no Node). Without node the check is skipped with a notice.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "check_theme_readability: node not found - SKIPPED"; exit 0; }
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
php -r '
$s = file_get_contents("'"$ROOT"'/cockpit_app/themes.php");
$a = strpos($s, "function builtinThemes"); $b = strpos($s, "// ────", $a);
eval(substr($s, $a, $b - $a));
echo json_encode(array_values(builtinThemes()));' > "$TMP" || { echo "check_theme_readability: cannot read built-in themes"; exit 1; }
node -e '
const g = require(process.argv[1]), T = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
let fail = 0, lifted = 0;
for (const t of T) {
  const r = g.themeGuardVars(t, true);
  if (r.problems.length) lifted++;
  const again = g.themeGuardVars(r.theme, false).problems;
  if (again.length) { fail++; console.log("  " + t.id + ": still unreadable after repair: " + again[0].pair + " " + again[0].ratio + ":1"); }
  if (t.mode === "mixed") {
    if (!t.colors.textChrome) { fail++; console.log("  " + t.id + ": mixed theme without textChrome"); }
    const tb = g.hex2rgb(t.colors.text.base), bb = g.hex2rgb(t.colors.background.base);
    if (tb && bb && g.ratio(t.colors.text.base, t.colors.background.base) < 4.5) { fail++; console.log("  " + t.id + ": mixed text.base unreadable on the light content"); }
  }
}
console.log("check_theme_readability: " + T.length + " built-in themes, " + lifted + " need colours lifted at apply time, " + fail + " failure(s)");
process.exit(fail ? 1 : 0);
' "$ROOT/cockpit_app/js/features/theme-guard.js" "$TMP"
# The Auto Generate palette maker (js/features/theme-generator.js): structure, readability after the guard, and the colour-vision
# palettes measured under a simulation. Same node requirement.
# (capture first: the status of a pipeline is the LAST command's, which would hide a failing test)
_gen=$(node "$ROOT/tests/theme_generator_test.js") || { echo "$_gen"; echo "theme generator regressed (tests/theme_generator_test.js)"; exit 1; }
echo "$_gen" | tail -1
