#!/usr/bin/env bash
# budget_tools_test.sh — the Personal finance tool (cockpit_app/budget_tool, tools_builtins/budget.json, kinds/personal-finance.json): budget variance, recurring payments, tax-document checklist, loan and savings projections, refusals.   bash tests/budget_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TL="$ROOT/cockpit_app/budget_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "budget_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
rc() { php "$TL" "$@" >/dev/null 2>&1; echo $?; }
cd "$T" || exit 1
printf 'category,budget\nGroceries,300\nRent,1000\nFun,100\n' > bud.csv
cat > act.csv <<'CSV'
date,description,amount,category
2026-03-01,Salary,2500,Income
2026-03-02,Landlord,-1000,Rent
2026-03-05,Market,-180.50,Groceries
2026-03-12,Market,-190,Groceries
2026-03-20,Cinema,-130,Fun
2026-03-22,Gym,-40,Health
2026-02-01,Stream Co 4411,-9.99,Fun
2026-03-01,Stream Co 5512,-9.99,Fun
2026-04-01,Stream Co 7,-9.99,Fun
2026-01-01,Stream Co 7,-9.99,Fun
CSV
printf 'Rent;1000\n' > /dev/null
sum0=$(md5sum bud.csv act.csv | md5sum)
php "$TL" variance bud.csv v.md with=act.csv month=2026-03 >/dev/null; [ $? = 0 ] && ok || bad "variance exit"
has "| Groceries | 300.00 | 370.50 | -70.50 |" v.md && has "| Rent | 1,000.00 | 1,000.00 | 0.00 |" v.md && ok || bad "variance rows: $(sed -n 8,12p v.md)"
has "Groceries: over by 70.50" v.md && has "Fun: over by 39.99" v.md && ok || bad "overspend list"
has "Health: 40.00" v.md && has "Savings rate: 38" v.md && ok || bad "unbudgeted spend, savings rate (949.51 / 2500)"
php "$TL" variance bud.csv v2.md with=act.csv >/dev/null; has "(4 months)" v2.md && ok || bad "without month= the budget is multiplied by the months in the file"
printf 'date;description;debit;credit;category\n01.03.2026;Pay;;"1.000,00";Income\n05.03.2026;Shop;"250,50";;Groceries\n' > eu.csv; printf 'category,budget\nGroceries,200\n' > b3.csv
php "$TL" variance b3.csv v3.md with=eu.csv >/dev/null; has "| Groceries | 200.00 | 250.50 | -50.50 |" v3.md && ok || bad "semicolon, debit/credit and 1.234,56 amounts"
# recurring
php "$TL" recurring act.csv r.md >/dev/null; has "| stream co | paid | 9.99 | monthly | 4 |" r.md && ok || bad "recurring: $(sed -n 6,10p r.md)"
has "119.95" r.md && ok || bad "yearly cost"
printf 'date,description,amount\n2026-01-03,Water Co,-30\n2026-02-03,Water Co,-55\n2026-03-04,Water Co,-42\n2026-04-03,Water Co,-70\n' > var.csv; php "$TL" recurring var.csv r2.md >/dev/null; has "Regular timing but a changing amount (1)" r2.md && ok || bad "variable amount: $(grep -A3 'changing' r2.md)"
# tax documents
mkdir -p td/sub; touch td/W-2_2025.pdf td/sub/bank_interest_1099-INT.pdf td/random.txt td/Charity-receipts-2024.pdf
printf 'W-2 | w2, wage statement\nBank interest | 1099-int\nMortgage interest statement\n- [ ] Charity receipts\n' > list.txt
sumd=$(find td -type f | sort | md5sum)
php "$TL" taxdocs td d.md with=list.txt >/dev/null; has "- [ ] Mortgage interest statement" d.md && has "- [x] W-2: W-2_2025.pdf" d.md && has "- [x] Bank interest: sub/bank_interest_1099-INT.pdf" d.md && ok || bad "taxdocs: $(sed -n 8,20p d.md)"
has "random.txt" d.md && has "list.txt(1) Warning: missing: Mortgage interest statement" d.md && has "[exit code 1]" d.md && ok || bad "unmatched files, file(line), exit code"
php "$TL" taxdocs td d2.md with=list.txt year=2025 >/dev/null; has "- [x] W-2:" d2.md && has "- [ ] Charity receipts" d2.md && ok || bad "year= filter"
[ "$(find td -type f | sort | md5sum)" = "$sumd" ] && ok || bad "the folder changed"
# project
printf 'principal=10000\nrate=6\nyears=2\n' > loan.txt
php "$TL" project loan.txt l.md start=2026-01 extra=100 >/dev/null; has "Monthly payment: 443.21" l.md && has "Months to pay off: 20" l.md && has "saves 4 months and 119.83 of interest" l.md && has "| 2026-01 | 543.21 | 50.00 | 493.21 | 9,506.79 |" l.md && ok || bad "loan: $(sed -n 3,9p l.md)"
php "$TL" project loan.txt l0.md >/dev/null; has "Months to pay off: 24" l0.md && has "Total interest: 636.94" l0.md && ok || bad "loan without extra: $(sed -n 5,8p l0.md)"
printf 'kind=savings\nprincipal=1000\ndeposit=100\nrate=5\nyears=3\ntarget=3000\n' > sv.txt
php "$TL" project sv.txt s.md >/dev/null; has "5,036.80" s.md && has "reached in month 19" s.md && ok || bad "savings: $(sed -n 3,6p s.md)"
php "$TL" project loan.txt l5.md rate=0 years=1 >/dev/null; has "Monthly payment: 833.33" l5.md && ok || bad "zero-interest loan"
# refusals, honesty, original unchanged
[ "$(rc project loan.txt x.md payment=40)" = 1 ] && ok || bad "a payment below the interest was not refused"
[ "$(rc project loan.txt x.md rate=500)" = 1 ] && ok || bad "an absurd rate was not refused"
[ "$(rc variance bud.csv x.md)" = 1 ] && ok || bad "variance without with= was not refused"
[ "$(rc taxdocs act.csv x.md with=list.txt)" = 1 ] && ok || bad "taxdocs on a file (not a folder) was not refused"
[ "$(rc recurring nope.csv x.md)" = 1 ] && ok || bad "a missing file was not refused"
[ "$(rc frob act.csv x.md)" = 2 ] && ok || bad "an unknown subcommand was not refused"
has "not financial, investment or tax advice" v.md && has "not financial, investment or tax advice" l.md && ok || bad "the not-advice statement is missing"
[ "$(md5sum bud.csv act.csv | md5sum)" = "$sum0" ] && ok || bad "the original changed"
head -20 "$TL" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r 'foreach(array_slice($argv,1) as $f){ $j=json_decode(file_get_contents($f),true); if(!is_array($j)){ echo "bad json $f"; exit(1);} } echo "ok";' "$ROOT/cockpit_app/tools_builtins/budget.json" > pc 2>&1; [ "$(cat pc)" = ok ] && ok || bad "json: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; for($i=2;$i<count($argv);$i++){ $j=json_decode(file_get_contents($argv[$i]),true); $e=""; if(kind_validate($j,$e)===null){ echo "invalid ".$argv[$i].": $e"; exit(1);} if(count($j["examples"]??[])<3||empty($j["verify"])||empty($j["group"])||empty($j["note"])||empty($j["details"])){ echo "incomplete ".$argv[$i]; exit(1);} } echo "ok";' "$ROOT" "$ROOT/cockpit_app/kinds/personal-finance.json" > kc 2>&1; [ "$(cat kc)" = ok ] && ok || bad "kind: $(cat kc)"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/budget_tool [a-z]+ \{INPUT\} \{OUTPUT\}~",$p["command"])){ echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/budget.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "presets: $(cat pc)"
echo "budget_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
