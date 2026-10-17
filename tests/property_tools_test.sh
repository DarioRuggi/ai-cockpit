#!/usr/bin/env bash
# property_tools_test.sh — the Real estate and rentals tool (cockpit_app/property_tool, tools_builtins/property.json, kinds/real-estate.json): rent roll, yield / cash flow / mortgage, listing text check, refusals.   bash tests/property_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TL="$ROOT/cockpit_app/property_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "property_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
rc() { php "$TL" "$@" >/dev/null 2>&1; echo $?; }
cd "$T" || exit 1
cat > roll.csv <<'CSV'
unit,tenant,rent,due,paid,lease end,deposit,currency
A1,Smith,1000,2026-02-01,yes,2026-04-10,1000,EUR
A1,Smith,1000,2026-03-01,,2026-04-10,1000,EUR
B2,Jones,800,2026-02-15,500,2027-01-01,800,EUR
B2,Jones,800,2026-03-05,,2027-01-01,800,EUR
C3,Lee,900,2026-02-01,2026-02-02,2026-01-31,,EUR
CSV
sum0=$(md5sum roll.csv | cut -d' ' -f1)
php "$TL" rentroll roll.csv rr.md today=2026-03-02 >/dev/null; [ $? = 0 ] && ok || bad "rentroll exit"
has "| 4 | B2 (Jones) | 2026-02-15 | 15 | 300.00 EUR |" rr.md && has "| 3 | A1 (Smith) | 2026-03-01 | 1 | 1,000.00 EUR |" rr.md && has "Total owing: 1,300.00 EUR" rr.md && ok || bad "overdue with a part payment: $(sed -n 7,14p rr.md)"
has "B2 (Jones): 800.00 EUR due 2026-03-05 (in 3 days)" rr.md && ok || bad "upcoming rent"
[ "$(grep -c 'A1 (Smith): ends 2026-04-10' rr.md)" = 1 ] && has "C3 (Lee): ended 2026-01-31 (30 days ago)" rr.md && ok || bad "lease ends once per tenancy, and ended leases: $(grep -n 'ends\|ended' rr.md)"
has "| EUR | 1,800.00 | 2 |" rr.md && has "No deposit recorded for: C3 (Lee)" rr.md && ok || bad "deposit totals count a tenancy once"
has "roll.csv(4) Warning: rent for B2 (Jones) was due 2026-02-15" rr.md && ok || bad "file(line) lines"
php "$TL" rentroll roll.csv rr2.md today=2026-03-02 within=20 >/dev/null; has "Leases ending within 20 days (0)" rr2.md && ok || bad "within="
printf 'unit;loyer;échéance;payé\nA;"1.000,00";03/03/2026;oui\nB;500;15/02/2026;non\nC;xx;01/03/2026;\n' > fr.csv; php "$TL" rentroll fr.csv fr.md today=2026-03-10 >/dev/null
has "fr.csv(3) Warning: rent for B was due 2026-02-15" fr.md && has "fr.csv(4) Error: the rent \"xx\" cannot be read" fr.md && has "[exit code 1]" fr.md && ok || bad "French headers, 1.000,00 amounts and a bad rent: $(sed -n 5,12p fr.md)"
# calc
printf 'price=300000\nrent=1500\ndown=20%%\nrate=5\nyears=25\nclosing=6000\ntax=2400\ninsurance=600\nmaintenance=1500\nvacancy=5\nmanagement=8\n' > p.txt
php "$TL" calc p.txt c.md >/dev/null; has "Gross yield (yearly rent / price): **6.00%**" c.md && has "net yield (cap rate, NOI / price): **3.74%**" c.md && ok || bad "yields: $(sed -n 7,10p c.md)"
has "Monthly payment (principal and interest): 1,403.02" c.md && has "Monthly cash flow: -467.02" c.md && has "Cash-on-cash return" c.md && has "0.67" c.md && ok || bad "mortgage and cash flow: $(sed -n 11,24p c.md)"
printf 'price=200000\nrent=1000\n' > p2.txt; php "$TL" calc p2.txt c2.md >/dev/null; has "Not worked out: give down=" c2.md && has "yearly costs you gave (none)" c2.md && ok || bad "nothing is assumed when figures are missing"
php "$TL" calc p2.txt c3.md down=200000 rate=4 years=10 >/dev/null; has "no loan" c3.md && ok || bad "a down payment equal to the price"
# listing
cat > lst.txt <<'TXT'
Stunning, perfect apartment in a prime location!
3 bedrooms, 85 m2 plus 12 m² balcony.
Price: 1,200 per month, or €1,350 furnished. Deposit 2400.
Newly renovated. Close to everything. Guaranteed return of 8%.
Available soon.
TXT
php "$TL" listing lst.txt l.md >/dev/null; has "| area | yes | line 2: 85 m2 |" l.md && has "| rooms | yes |" l.md && has "| price | yes |" l.md && ok || bad "found facts: $(sed -n 5,10p l.md)"
has "lst.txt(1) Note: unverifiable wording (stunning, perfect, prime location)" l.md && has "lst.txt(4) Warning: a promise nobody can keep or prove (guaranteed)" l.md && has "lst.txt(5) Note: \"available\" is stated without a date" l.md && ok || bad "unverifiable claims and the promised return: $(sed -n '/Problems/,$p' l.md | head -8)"
has "several different amounts appear" l.md && has "more than one area appears" l.md && ok || bad "several prices / areas"
printf 'Nice flat.\n' > l2.txt; php "$TL" listing l2.txt l2.md >/dev/null; [ "$(grep -c 'is not stated' l2.md)" = 4 ] && has "| area | **missing** |" l2.md && ok || bad "missing facts: $(grep Warning l2.md)"
printf 'Appartement lumineux de 60 m2, 2 pièces, 900 euros par mois, disponible dès le 01/04/2026.\n' > fr.txt; php "$TL" listing fr.txt fr2.md >/dev/null; [ "$(grep -c '\*\*missing\*\*' fr2.md)" = 0 ] && ok || bad "a French listing has all four facts: $(sed -n 5,10p fr2.md)"
printf 'Wohnung, 55 qm, 2 Zimmer, Miete 700 EUR, ab sofort frei. Perfekte Lage, garantiert ruhig.\n' > de.txt; php "$TL" listing de.txt de2.md >/dev/null; [ "$(grep -c '\*\*missing\*\*' de2.md)" = 0 ] && has "unverifiable wording" de2.md && ok || bad "a German listing: $(sed -n 5,12p de2.md)"
# refusals, honesty, original unchanged
printf '\xF9\xEC\n' > ansi.txt; [ "$(rc listing ansi.txt x.md)" = 1 ] && ok || bad "a non-UTF-8 listing was not refused"
[ "$(rc calc p.txt x.md down=500000)" = 1 ] && ok || bad "a down payment above the price was not refused"
[ "$(rc calc p.txt x.md rate=500)" = 1 ] && ok || bad "an absurd rate was not refused"
[ "$(rc rentroll rr.md x.md)" = 1 ] && ok || bad "a file with no rent column was not refused"
[ "$(rc rentroll roll.csv x.md today=soon)" = 1 ] && ok || bad "a bad today= was not refused"
[ "$(rc rentroll nope.csv x.md)" = 1 ] && ok || bad "a missing file was not refused"
[ "$(rc frob roll.csv x.md)" = 2 ] && ok || bad "an unknown subcommand was not refused"
has "not legal, financial, tax or investment advice" rr.md && has "not legal, financial, tax or investment advice" c.md && has "not legal, financial, tax or investment advice" l.md && ok || bad "the not-advice statement is missing"
[ "$(md5sum roll.csv | cut -d' ' -f1)" = "$sum0" ] && ok || bad "the original changed"
head -20 "$TL" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r 'foreach(array_slice($argv,1) as $f){ $j=json_decode(file_get_contents($f),true); if(!is_array($j)){ echo "bad json $f"; exit(1);} } echo "ok";' "$ROOT/cockpit_app/tools_builtins/property.json" > pc 2>&1; [ "$(cat pc)" = ok ] && ok || bad "json: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; for($i=2;$i<count($argv);$i++){ $j=json_decode(file_get_contents($argv[$i]),true); $e=""; if(kind_validate($j,$e)===null){ echo "invalid ".$argv[$i].": $e"; exit(1);} if(count($j["examples"]??[])<3||empty($j["verify"])||empty($j["group"])||empty($j["note"])||empty($j["details"])){ echo "incomplete ".$argv[$i]; exit(1);} } echo "ok";' "$ROOT" "$ROOT/cockpit_app/kinds/real-estate.json" > kc 2>&1; [ "$(cat kc)" = ok ] && ok || bad "kind: $(cat kc)"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/property_tool [a-z]+ \{INPUT\} \{OUTPUT\}~",$p["command"])){ echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/property.json" > pc 2>&1; [ "$(cat pc)" = 3 ] && ok || bad "presets: $(cat pc)"
echo "property_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
