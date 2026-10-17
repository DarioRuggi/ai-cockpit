#!/usr/bin/env bash
# books_tools_test.sh — the Bookkeeping tools (cockpit_app/books_tool, tools_builtins/books.json, kinds/bookkeeping.json): the ledger check, number and date formats, the summary, the bank
# reconciliation, tax by rate and by quarter.   bash tests/books_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; BT="$ROOT/cockpit_app/books_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "books_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
cat > led.csv <<'CSV'
Date,Description,Category,Amount,Invoice,Tax,Currency
2026-01-05,Client A payment,Sales,"1,170.00",INV-001,17%,ILS
2026-01-07,Office rent,Rent,-2000.00,,,ILS
2026-01-09,Software,Tools,-117.00,B-77,17%,ILS
2026-01-09,Software,Tools,-117.00,B-77,17%,ILS
2026-02-01,Client B payment,Sales,2340.00,INV-002,17%,ILS
2026-02-03,Coffee,,-18.50,,,ILS
2026-02-10,Client C payment,Sales,"1,000.00",INV-004,0%,ILS
2026-13-45,Broken date,Misc,-5,,,ILS
2026-02-12,Bad amount,Misc,abc,,,ILS
2999-01-01,Future,Misc,-1,,,ILS
2026-02-14,Flights,Travel,-9999.00,,,ILS
2026-02-15,Taxi,Travel,-30,,,ILS
2026-02-16,Taxi,Travel,-28,,,ILS
2026-02-17,Taxi,Travel,-31,,,ILS
2026-02-18,Taxi,Travel,-29,,,ILS
2026-02-19,Taxi,Travel,-32,,,ILS
2026-02-20,Taxi,Travel,-27,,,ILS
CSV
cat > bank.csv <<'CSV'
Date;Details;Debit;Credit
06/01/2026;TRANSFER CLIENT A;;1.170,00
08/01/2026;RENT;2.000,00;
09/01/2026;SOFTWARE CO;117,00;
05/02/2026;CLIENT B;;2.340,00
20/02/2026;UNKNOWN WITHDRAWAL;55,00;
CSV
sum0=$(md5sum led.csv bank.csv | md5sum)
php "$BT" check led.csv c.md >/dev/null; has "[exit code 1]" c.md && ok || bad "check must exit 1 (two errors)"
has "led.csv(9) Error: the date \"2026-13-45\" cannot be read" c.md && has "led.csv(10) Error: the amount \"abc\" cannot be read" c.md && ok || bad "unreadable date / amount: $(grep Error c.md)"
has "led.csv(5) Warning: looks like a duplicate of line 4" c.md && ok || bad "duplicate"
has "led.csv(11) Warning: the date 2999-01-01 is in the future" c.md && ok || bad "future date"
has "led.csv(12) Warning: an unusually large amount for \"Travel\": 9,999.00 (the usual is about 30.00)" c.md && ok || bad "an outlier must not hide itself by inflating the spread: $(grep -i unusual c.md)"
has "led.csv(7) Note: no category" c.md && ok || bad "no category"
has "the invoice numbers (INV-…) skip: 3" c.md && has "invoice number B-77 is used more than once" c.md && ok || bad "invoice numbers: $(grep -i invoice c.md)"
[ "$(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md)" = 6 ] && ok || bad "summary-box regex finds $(grep -cE '^(.+?)\([0-9]+\) (Error|Warning): ' c.md) lines, want 6"
grep -q "Undefined\|Warning: Undefined" c.md && bad "a PHP warning leaked into the report" || ok
# summary
php "$BT" summary led.csv s.md >/dev/null; has "- Income: 4,510.00" s.md && has "| Rent | -2,000.00 |" s.md && has "| 2026-01 | 1,170.00 | 2,234.00 | -1,064.00 |" s.md && ok || bad "summary: $(sed -n 3,16p s.md)"
has "(2 unreadable rows left out: run Check)" s.md && ok || bad "unreadable rows are mentioned"
# number and date formats
printf 'Fecha;Concepto;Importe\n31/12/2025;Café;-3,50\n01/01/2026;Venta;"1.234,56"\n' > es.csv; php "$BT" summary es.csv es.md >/dev/null; has "- Income: 1,234.56" es.md && has "- Expenses: 3.50" es.md && has "| 2025-12 |" es.md && ok || bad "Spanish headers, 1.234,56, -3,50 and day-first dates: $(sed -n 3,9p es.md)"
printf 'תאריך,תיאור,סכום\n2026-03-01,שכר דירה,(4500.00)\n2026-03-02,לקוח,"2,000.00"\n' > he.csv; php "$BT" summary he.csv he.md >/dev/null; has "- Expenses: 4,500.00" he.md && has "- Income: 2,000.00" he.md && ok || bad "Hebrew headers and (4500.00): $(sed -n 3,8p he.md)"
printf 'Date,Description,Debit,Credit\n2026-01-01,Pay,100.00,\n2026-01-02,Sale,,250.00\n' > dc.csv; php "$BT" summary dc.csv dc.md >/dev/null; has "- Income: 250.00" dc.md && has "- Expenses: 100.00" dc.md && ok || bad "debit/credit columns"
printf 'Date,Description,Amount\n2026-01-01,Pay,100.00\n2026-01-02,Sale,-250.00\n' > pe.csv; php "$BT" summary pe.csv pe.md positive=expense >/dev/null; has "- Expenses: 100.00" pe.md && has "- Income: 250.00" pe.md && ok || bad "positive=expense"
printf 'Date,Description,Amount\n2026-05-15,A,10\n' > amb.csv; php "$BT" check amb.csv amb.md >/dev/null; has "day-first" amb.md && ok || bad "the date reading is stated"
printf 'Date,Description,Amount\n2026-05-31,A,10\n' > a2.csv; printf 'Date,Description,Amount\n05/31/2026,A,10\n' > us.csv; php "$BT" summary us.csv us.md >/dev/null; has "| 2026-05 |" us.md && ok || bad "month-first dates are recognised when a day is above 12"
# reconcile
php "$BT" reconcile led.csv r.md with=bank.csv >/dev/null; has "- Matched (same amount, dates within 3 days): 3" r.md && ok || bad "matched count: $(sed -n 3,6p r.md)"
has "bank.csv(6) Warning: not in the ledger: 2026-02-20 -55.00 UNKNOWN WITHDRAWAL" r.md && ok || bad "only in the bank file"
has "led.csv(6) Warning: not on the bank file: 2026-02-01 2340.00" r.md || has "not on the bank file: 2026-02-01 2,340.00" r.md && ok || bad "only in the ledger (a 4-day difference is not a match)"
has "[exit code 1]" r.md && ok || bad "unmatched rows -> exit 1"
php "$BT" reconcile led.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "reconcile without with= was not refused"
# tax
php "$BT" tax led.csv t.md >/dev/null; has "| 17% | 3,510.00 | 510.00 | 234.00 | 34.00 |" t.md && has "| (tax not stated) |" t.md && has "- Net to pay (collected minus paid): 476.00" t.md && ok || bad "tax by rate: $(sed -n 5,12p t.md)"
has "| 2026-Q1 |" t.md && ok || bad "tax by quarter"
printf 'Date,Description,Amount,VAT amount\n2026-01-01,Sale,118.00,18.00\n2026-01-02,Buy,-59.00,9.00\n' > va.csv; php "$BT" tax va.csv va.md >/dev/null; has "(tax amount column)" va.md && has "- Tax collected on sales: 18.00" va.md && has "- Tax paid on purchases: 9.00" va.md && ok || bad "a tax AMOUNT column: $(sed -n 5,12p va.md)"
php "$BT" tax pe.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "tax without a tax column was not refused"
# refusals
printf 'a,b\n1,2\n' > nodate.csv; php "$BT" check nodate.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "no date column was not refused"
: > e.csv; php "$BT" check e.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an empty file was not refused"
php "$BT" check nope.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a missing file was not refused"
iconv -f UTF-8 -t WINDOWS-1252 es.csv > es1252.csv 2>/dev/null; php "$BT" summary es1252.csv e2.md >/dev/null 2>&1; has "- Income: 1,234.56" e2.md && ok || bad "a Windows-1252 file"
[ "$(md5sum led.csv bank.csv | md5sum)" = "$sum0" ] && ok || bad "an original changed"
head -20 "$ROOT/cockpit_app/books_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/books_tool (check|summary|reconcile|tax) \{INPUT\} \{OUTPUT\}~",$p["command"])) { echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/books.json" > pc 2>&1; [ "$(cat pc)" = 4 ] && ok || bad "books.json presets: $(cat pc)"
[ "$(jq -r '.tools[0].tool' "$ROOT/cockpit_app/kinds/bookkeeping.json")" = books ] && ok || bad "the kind does not name the tool"
echo "books_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
