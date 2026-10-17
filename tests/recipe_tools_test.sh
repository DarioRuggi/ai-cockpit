#!/usr/bin/env bash
# recipe_tools_test.sh — the Cooking tools (cockpit_app/recipe_tool, tools_builtins/recipe.json, kinds/cooking.json): scaling with fractions, unit and temperature conversion, the merged
# shopping list, the recipe check with allergen words, refusals.   bash tests/recipe_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; RT="$ROOT/cockpit_app/recipe_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "recipe_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
mkdir rec
cat > rec/pancakes.md <<'MD'
# Pancakes

Serves 4
Allergens: gluten, milk

## Ingredients
- 1 1/2 cups all-purpose flour
- 2 tsp baking powder
- ½ tsp salt
- 1 1/4 cups milk
- 2 eggs
- 3 tbsp butter, melted
- 2-3 cloves garlic
- sugar to taste

## Method
1. Mix flour, baking powder and salt.
2. Whisk milk, eggs and butter; combine. Heat the pan to 350°F.
3. Fry until golden, add the garlic and sugar.
MD
cat > rec/omelette.md <<'MD'
# Omelette

Portions: 2

## Ingredients
- 3 eggs
- 1 onion
- 20 g butter
- 100 g flour
- 1 cup milk

## Method
1. Beat the eggs with the milk. Cook the onion in the butter with the flour.
MD
cat > rec/soup.md <<'MD'
# Soup

Serves 4

## Ingrédients
- 2 onions
- 200 g butter
- 1 cup flour
- 4 carottes
- 2 oeufs

## Méthode
1. Cook everything.
MD
cp rec/pancakes.md rec/pancakes.orig; sum0=$(md5sum rec/pancakes.md rec/omelette.md rec/soup.md)
R() { php "$RT" "$@"; }
# scale
R scale rec/pancakes.md s.md servings=6 >/dev/null; [ $? = 0 ] && ok || bad "scale exited non-zero"
has "Serves 6" s.md && has "- 2 1/4 cups all-purpose flour" s.md && ok || bad "scale x1.5: flour and servings line: $(sed -n 3,8p s.md)"
has "- 3 eggs" s.md && has "- 3/4 tsp salt" s.md && has "- 1 tbsp baking powder" s.md && ok || bad "scale: eggs, fraction, tsp becoming tbsp: $(sed -n 8,12p s.md)"
has "- 4 1/2 tbsp butter, melted" s.md && has "- 3 to 4 1/2 cloves garlic" s.md && ok || bad "scale: tbsp kept when no clean cup fraction, range scaled: $(sed -n 11,14p s.md)"
has "- sugar to taste" s.md && has "Left unchanged" s.md && ok || bad "scale: unquantified line left alone and reported"
R scale rec/pancakes.md s2.md servings=2 >/dev/null
has "- 3/4 cup all-purpose flour" s2.md && ok || bad "scale down: $(sed -n 6,8p s2.md)"
R scale rec/pancakes.md s3.md servings=8 >/dev/null; has "- 3 cups all-purpose flour" s3.md && has "- 1 1/3 tbsp baking powder" s3.md && ok || bad "scale x2: $(sed -n 6,8p s3.md)"
for alias in targetServings=8 serves=8 8; do R scale rec/pancakes.md s3a.md $alias >/dev/null 2>&1; cmp -s s3.md s3a.md && ok || bad "scale: the number of servings given as $alias is understood like servings=8"; done
printf '# No servings\n\n## Ingredients\n- 1 cup rice\n\n## Method\n1. Boil.\n' > rec/noserv.md
R scale rec/noserv.md x.md servings=4 >/dev/null 2>&1; [ $? = 1 ] && ok || bad "scale of a recipe with no servings line was not refused"
R scale rec/noserv.md x2.md servings=4 from=2 >/dev/null 2>&1; has "- 2 cups rice" x2.md && ok || bad "from= should supply the missing servings"
R scale rec/pancakes.md x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "scale without servings= was not refused with 2"
# convert
R convert rec/pancakes.md c.md to=metric >/dev/null; has "355 ml (about 190 g) all-purpose flour (was 1 1/2 cups)" c.md && ok || bad "metric with density: $(sed -n 6,7p c.md)"
has "350°F (175°C)" c.md && has "- 2 eggs" c.md && ok || bad "temperature in both scales, counts unchanged"
has "ESTIMATES" c.md && ok || bad "the estimate warning is missing"
R convert rec/pancakes.md c2.md to=grams >/dev/null; has "190 g all-purpose flour (was 1 1/2 cups)" c2.md && has "43 g butter, melted (was 3 tbsp)" c2.md && ok || bad "grams mode: $(sed -n 6,12p c2.md)"
printf '# Metric\n\nServes 4\n\n## Ingredients\n- 500 g flour\n- 250 ml milk\n- 8 oz cheese\n\n## Method\n1. Bake at 180°C.\n' > rec/metric.md
R convert rec/metric.md c3.md to=us >/dev/null; has "1 1/8 lb flour" c3.md && has "1.06 cups milk" c3.md && has "(was 500 g)" c3.md && has "350°F" c3.md && ok || bad "to=us: $(sed -n 5,12p c3.md)"
R convert rec/metric.md c4.md to=cups >/dev/null; has "4 cups flour (was 500 g)" c4.md && ok || bad "to=cups from grams with density: $(sed -n 5,8p c4.md)"
R convert rec/pancakes.md x.md to=furlongs >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown to= was not refused"
# shopping
R shopping rec c5.md >/dev/null; [ $? = 0 ] && ok || bad "shopping of a folder exited non-zero"
has "## Dairy & eggs" c5.md && has "## Fruit & vegetables" c5.md && has "## Pantry" c5.md && ok || bad "aisles: $(grep '^##' c5.md | tr '\n' ' ')"
has "5 eggs" c5.md && ok || bad "eggs from three recipes (2+3+... pancakes 2, omelette 3, soup 2 oeufs separately) : $(grep -i egg c5.md)"
grep -E "^- \[ \] .*(onion|oignon)" c5.md | grep -q "3 onion" && ok || bad "onions 1 + 2 merged to 3: $(grep -i onion c5.md)"
grep -E "butter" c5.md | grep -q "ml\|g " && ok || bad "butter merged across g and tbsp: $(grep -i butter c5.md)"
has "(no quantity given)" c5.md && has "omelette.md" c5.md && ok || bad "unquantified item and source names"
R shopping rec c6.md skip=salt,sugar >/dev/null; grep -qi "salt" c6.md && bad "skip=salt did not leave salt out" || ok
R shopping rec/metric.md c7.md >/dev/null; has "500 g flour" c7.md && has "250 ml milk" c7.md && ok || bad "single recipe shopping list"
mkdir empty; R shopping empty x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an empty folder was not refused"
# check
R check rec/pancakes.md k.md >/dev/null; [ $? = 0 ] && ok || bad "check exited non-zero"
has "allergen keyword \"flour\" (gluten)" k.md && has "pancakes.md(" k.md && ok || bad "allergen notes: $(sed -n 3,12p k.md)"
R check rec/soup.md k2.md >/dev/null; has "allergen keyword \"oeufs\" (eggs)" k2.md && has "allergen keyword \"butter\" (milk)" k2.md && has "no allergen line" k2.md && has "[exit code 0]" k2.md && ok || bad "soup check: $(sed -n 3,14p k2.md)"
cat > rec/bad.md <<'MD'
# Bad

## Ingredients
- 1/0 cup flour
- flour
- 2 flour
- 1 egg
- 1 egg
- 1 cup peanut butter
- 1 cup almond flour

Bake at 350 until done.
MD
R check rec/bad.md k3.md >/dev/null; has "Error: the quantity cannot be read" k3.md && has "Error: no method steps" k3.md && has "[exit code 1]" k3.md && ok || bad "bad recipe errors: $(sed -n 3,16p k3.md)"
has "Warning: no servings line" k3.md && has "Warning: no quantity: \"flour\"" k3.md && has "a quantity but no unit" k3.md && has "is listed twice" k3.md && ok || bad "bad recipe warnings: $(sed -n 3,16p k3.md)"
has "oven temperature without C or F" k3.md && ok || bad "temperature without a unit: $(grep -n temperature k3.md)"
printf '# Allergens\n\nServes 2\nAllergens: milk\n\n## Ingredients\n- 100 g flour\n- 2 eggs\n- 1 cup milk\n\n## Method\n1. Mix flour eggs milk.\n' > rec/al.md
R check rec/al.md k4.md >/dev/null; has "Warning: contains \"flour\" (gluten), which the recipe's allergen line does not list" k4.md && has "Warning: contains \"eggs\" (eggs)" k4.md && ok || bad "unlisted allergens: $(sed -n 3,10p k4.md)"
printf 'Serves 2\n## Zutaten\n- 200 g Mehl\n- 1 Ei\n- 100 ml Milch\n## Zubereitung\n1. Mehl Ei Milch mischen.\n' > rec/de.md
R check rec/de.md k5.md >/dev/null; has "(gluten)" k5.md && has "(eggs)" k5.md && has "(milk)" k5.md && ok || bad "German allergen words: $(sed -n 3,9p k5.md)"
# refusals, originals, shape
printf '\xF9\xEC\xE5\xED\n' > ansi.md; R check ansi.md x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a non-UTF-8 file was not refused"
: > empty.md; R check empty.md x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an empty file was not refused"
R check nope.md x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
R frob rec/pancakes.md x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "an unknown subcommand was not refused"
[ "$(md5sum rec/pancakes.md rec/omelette.md rec/soup.md)" = "$sum0" ] && cmp -s rec/pancakes.md rec/pancakes.orig && ok || bad "an original recipe was changed"
head -30 "$RT" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
# a plain list (no "Ingredients" heading, no bullets) is still scaled; a recipe with no recognisable ingredients says so instead of reporting success
printf 'Pancakes (serves 4)\n2 cups flour\n2 eggs\n1 cup milk\n1 tbsp sugar\n\nMix everything.\n' > plain.md
R scale plain.md plain_out.md servings=6 >/dev/null 2>&1; has "3 cups flour" plain_out.md && has "1 1/2 tbsp sugar" plain_out.md && ok || bad "a plain ingredient list was not scaled"
printf 'Soup (serves 2)\nBoil water.\n' > noing.md
R scale noing.md noing_out.md servings=4 >/dev/null 2>&1; has "WARNING: no ingredient lines were recognised" noing_out.md && ok || bad "a recipe with no recognisable ingredients scaled silently"
# oven temperatures written "350 F" / "180 C" (no degree sign) are converted too
printf '# Cake\nServes 4\n\n## Ingredients\n- 1 cup flour\n\n## Method\nPreheat the oven to 350 F. Bake at 20 C for a minute.\n' > temp.md
R convert temp.md temp_out.md to=metric >/dev/null 2>&1; has '350 F (175°C)' temp_out.md && has 'Bake at 20 C' temp_out.md && ok || bad "bare oven temperature: $(grep -i preheat temp_out.md)"
# definitions
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/recipe_tool (scale|convert|shopping|check) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/recipe.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "recipe.json presets: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $j=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/cooking.json"),true); $e=""; $v=kind_validate($j,$e); if(!$v){echo $e; exit(1);} if(($v["group"]??"")!=="Home & life"||empty($v["examples"])||empty($v["verify"])||mb_strlen($v["note"])<mb_strlen($j["note"])) {echo "fields"; exit(1);} echo "ok";' "$ROOT" > kv 2>&1; [ "$(cat kv)" = ok ] && ok || bad "cooking.json / recipe.json do not pass kinds_lib validation: $(cat kv)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/cooking.json")" = recipe ] && ok || bad "the kind does not name the tool"
echo "recipe_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
