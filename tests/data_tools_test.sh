#!/usr/bin/env bash
# data_tools_test.sh — the Data tools (cockpit_app/data_run, data_chart, tools_builtins/data.json) on real files: a CSV with quoted commas, a
# Hebrew header, an empty cell, a date column that must NOT be treated as a number, other separators and a BOM; SQL that must be refused;
# every chart type as well-formed SVG with the right numbers; a spreadsheet through LibreOffice when it is installed.
#   bash tests/data_tools_test.sh      SKIPPED without sqlite3, php and jq.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; DR="$ROOT/cockpit_app/data_run"; DC="$ROOT/cockpit_app/data_chart"
for c in sqlite3 php jq; do command -v $c >/dev/null 2>&1 || { echo "data_tools_test: $c is needed - SKIPPED"; exit 0; }; done
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
cat > "$T/sales.csv" <<'X'
city,month,"sales total",units,שם
Tel Aviv,2026-01,1200.5,10,"א, ב"
Haifa,2026-01,800,7,ג
Tel Aviv,2026-02,1500,12,ד
Haifa,2026-02,,5,ה
Eilat,2026-02,300.25,2,ו
Haifa,2026-03,950,8,ז
X
run() { rm -f "$T/out"; bash "$DR" "$@" > "$T/stdout" 2> "$T/stderr"; RC=$?; }
has() { grep -qF -- "$1" "$T/out"; }

run csv-head "$T/sales.csv" "$T/out" 2; [ $RC = 0 ] && has "| Tel Aviv" && has "א, ב" && has "(6 rows, 5 columns; the first 2 shown)" && ok || bad "csv-head: rc=$RC $(cat "$T/out" "$T/stderr" 2>/dev/null | head -5)"
run csv-describe "$T/sales.csv" "$T/out"; [ $RC = 0 ] && grep -qE '\| sales total +\| 6 +\| 1 +\| 5 +\| 300\.25 +\| 1500\.0 +\| 4750\.75 +\| 950\.15 +\|' "$T/out" && ok || bad "csv-describe numbers: $(cat "$T/out")"
grep -E '^\| month ' "$T/out" | grep -qE '\|[[:space:]]+\|[[:space:]]+\|$' && ok || bad "a date column was summed as a number: $(grep '^| month' "$T/out")"
grep -E '^\| units ' "$T/out" | grep -q '| 2.0 ' && grep -E '^\| units ' "$T/out" | grep -q '| 12.0 ' && ok || bad "units min/max are not numeric: $(grep '^| units' "$T/out")"
run csv-query "$T/sales.csv" "$T/out" SELECT city, SUM\(CAST\(\"sales total\" AS REAL\)\) AS total FROM t GROUP BY city ORDER BY total DESC; [ $RC = 0 ] && head -3 "$T/out" | tail -1 | grep -q "Tel Aviv | 2700.5" && ok || bad "csv-query: $(cat "$T/out" "$T/stderr" | head -5)"
run col-stats "$T/sales.csv" "$T/out" sales_total; [ $RC = 0 ] && has "| sales total | 6    | 1     | 5              |" && ok || bad "col-stats by name_with_underscore: $(cat "$T/out")"
run col-stats "$T/sales.csv" "$T/out" 4; [ $RC = 0 ] && has "| units " && ok || bad "col-stats by number"
run col-count "$T/sales.csv" "$T/out" city 2; [ $RC = 0 ] && has "| Haifa " && has "| 50.0" && [ "$(grep -c '^| ' "$T/out")" = 3 ] && ok || bad "col-count: $(cat "$T/out")"
run col-stats "$T/sales.csv" "$T/out" nosuch; [ $RC = 1 ] && grep -q "no column 'nosuch'. Columns: city, month" "$T/out" && ok || bad "an unknown column must say which exist: rc=$RC $(cat "$T/out")"
# SQL that must be refused: nothing may be written, read or run
for q in "ATTACH DATABASE '$T/evil.db' AS e; CREATE TABLE e.x(a)" "SELECT load_extension('/x')" "SELECT readfile('/etc/hostname')" "CREATE TABLE w(a)" "DROP TABLE t" ".shell touch $T/pwned" "  .read /etc/passwd" "PRAGMA writable_schema=1; UPDATE t SET city='x'"; do
    run csv-query "$T/sales.csv" "$T/out" $q; [ $RC = 1 ] && ok || bad "this SQL was not refused: $q (rc=$RC)"
done
[ ! -e "$T/evil.db" ] && [ ! -e "$T/pwned" ] && ok || bad "a refused query still wrote a file"
cmp -s <(sed -n 1,7p "$T/sales.csv") <(sed -n 1,7p "$T/sales.csv") && [ "$(wc -l < "$T/sales.csv")" = 7 ] && ok || bad "the source file changed"
run csv-query "$T/sales.csv" "$T/out" SELECT \* FROM t WHERE city = \'Nowhere\'; [ $RC = 0 ] && has "no rows" && ok || bad "an empty result is not said: $(cat "$T/out")"
run csv-query "$T/sales.csv" "$T/out"; [ $RC = 1 ] && ok || bad "csv-query without SQL must fail"
# other separators, BOM, CRLF
printf '\xEF\xBB\xBFname;age\r\nAnna;30\r\nBen;25\r\n' > "$T/semi.csv"; run csv-describe "$T/semi.csv" "$T/out"; [ $RC = 0 ] && has "| name " && has "| age " && has "| 25.0 " && ok || bad "semicolon + BOM + CRLF: $(cat "$T/out" "$T/stderr")"
printf 'a\tb\n1\t2\n3\t4\n' > "$T/tab.csv"; run col-stats "$T/tab.csv" "$T/out" b; [ $RC = 0 ] && has "| 6.0 " && ok || bad "tab separated: $(cat "$T/out")"
: > "$T/empty.csv"; run csv-head "$T/empty.csv" "$T/out"; [ $RC = 1 ] && ok || bad "an empty file must fail clearly"
run csv-head "$T/nofile.csv" "$T/out"; [ $RC = 1 ] && ok || bad "a missing file must fail"
# csv-to-sqlite: writes beside, never replaces
cp "$T/sales.csv" "$T/work.csv"; run csv-to-sqlite "$T/work.csv" "$T/out"; [ $RC = 0 ] && [ -f "$T/work.db" ] && [ "$(sqlite3 "$T/work.db" 'select count(*) from t')" = 6 ] && ok || bad "csv-to-sqlite: $(cat "$T/out")"
run csv-to-sqlite "$T/work.csv" "$T/out"; [ $RC = 1 ] && has "already exists" && ok || bad "csv-to-sqlite replaced an existing file"
# charts
chart() { rm -f "$T/c.svg"; php "$DC" "$@" > "$T/stdout" 2> "$T/stderr"; RC=$?; }
chart bar "$T/sales.csv" "$T/c.svg" city sales_total "Sales by city"; [ $RC = 0 ] && xmllint --noout "$T/c.svg" 2>/dev/null && [ "$(grep -c '<rect x=' "$T/c.svg")" = 3 ] && grep -q 'Sales by city' "$T/c.svg" && grep -q '2,700.5' "$T/c.svg" && grep -q '1 skipped' "$T/c.svg" && ok || bad "bar chart: rc=$RC $(cat "$T/stderr")"
chart bar "$T/sales.csv" "$T/c.svg" city; [ $RC = 0 ] && grep -q '>3<' "$T/c.svg" && ok || bad "bar chart of counts (Haifa = 3)"
chart line "$T/sales.csv" "$T/c.svg" units sales_total; [ $RC = 0 ] && xmllint --noout "$T/c.svg" 2>/dev/null && [ "$(grep -c '<circle' "$T/c.svg")" = 5 ] && grep -q '<polyline' "$T/c.svg" && ok || bad "line chart"
chart scatter "$T/sales.csv" "$T/c.svg" units sales_total; [ $RC = 0 ] && xmllint --noout "$T/c.svg" 2>/dev/null && [ "$(grep -c '<circle' "$T/c.svg")" = 5 ] && ok || bad "scatter chart"
chart hist "$T/sales.csv" "$T/c.svg" units 5; [ $RC = 0 ] && xmllint --noout "$T/c.svg" 2>/dev/null && [ "$(grep -c '<rect x=' "$T/c.svg")" = 5 ] && grep -q '5 bins' "$T/c.svg" && ok || bad "histogram"
chart bar "$T/sales.csv" "$T/c.svg" nosuch; [ $RC = 1 ] && grep -q "no column 'nosuch'" "$T/stderr" && ok || bad "chart: unknown column"
chart line "$T/sales.csv" "$T/c.svg" units; [ $RC = 1 ] && ok || bad "line without a y column must fail"
chart bar "$T/sales.csv" "$T/c.svg" "שם" units "כותרת <b>&"; [ $RC = 0 ] && xmllint --noout "$T/c.svg" 2>/dev/null && grep -q 'כותרת &lt;b&gt;&amp;' "$T/c.svg" && ok || bad "Hebrew text or markup in the title broke the SVG"
# the tool definition
jq -e '.id=="data" and .binary and ([.presets[]|.id and .label and .command and .output_ext and .timeout_seconds]|all) and ([.presets[].id]|length)==11' "$ROOT/cockpit_app/tools_builtins/data.json" >/dev/null && ok || bad "data.json is incomplete"
jq -r '.presets[].command' "$ROOT/cockpit_app/tools_builtins/data.json" | grep -qE 'sh -c|;|&&' && bad "a preset runs a shell line" || ok
# LibreOffice: csv -> xlsx -> csv
if command -v soffice >/dev/null 2>&1; then
    mkdir -p "$T/lo" && cp "$T/sales.csv" "$T/lo/book.csv" && ( cd "$T/lo" && HOME="$T/lohome" timeout 120 soffice --headless --convert-to xlsx book.csv >/dev/null 2>&1 )
    if [ -f "$T/lo/book.xlsx" ]; then run xlsx-to-csv "$T/lo/book.xlsx" "$T/out"; [ $RC = 0 ] && has "Tel Aviv" && has "א, ב" && ok || bad "xlsx-to-csv: rc=$RC $(head -3 "$T/out")"; else echo "  (could not make an xlsx here: LibreOffice step skipped)"; fi
fi
echo "data_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
