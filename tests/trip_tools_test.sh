#!/usr/bin/env bash
# trip_tools_test.sh — the Travel planning tool (cockpit_app/trip_tool, tools_builtins/trip.json, kinds/travel.json): overlaps, connections across time zones, lodging gaps, budget with the user's own rates, packing list, refusals.   bash tests/trip_tools_test.sh     SKIPPED without php (mbstring)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TL="$ROOT/cockpit_app/trip_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "trip_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
rc() { php "$TL" "$@" >/dev/null 2>&1; echo $?; }
cd "$T" || exit 1
cat > it.csv <<'CSV'
type,description,from,to,start,start offset,end,end offset,amount,currency,category
flight,Outbound,Paris,New York,2026-05-01 10:00,+02:00,2026-05-01 12:30,-04:00,400,EUR,flights
flight,Connect,New York,Boston,2026-05-01 13:00,-04:00,2026-05-01 14:10,-04:00,120,USD,flights
flight,Too early,Boston,Chicago,2026-05-01 14:00,-04:00,2026-05-01 16:00,-05:00,90,USD,flights
hotel,Boston inn,,,2026-05-01,,2026-05-04,,300,USD,
hotel,Chicago,,,2026-05-06,,2026-05-08,,200,CAD,
vol,Bad,A,B,2026-05-09 10:00,,2026-05-09 08:00,,,,
CSV
sum0=$(md5sum it.csv | cut -d' ' -f1)
[ "$(rc check it.csv o.md)" = 0 ] && ok || bad "check exit"
has "8h30" o.md && ok || bad "the Paris-New York flight lasts 8h30 in real time (UTC offsets): $(grep Outbound o.md)"
has "it.csv(3) Warning: tight connection: only 0h30" o.md && ok || bad "tight connection of 30 minutes"
has "it.csv(4) Error: impossible connection" o.md && ok || bad "arrival after the next departure"
has "it.csv(6) Warning: no lodging for 2 night(s): 2026-05-04 to 2026-05-05" o.md && ok || bad "lodging gap"
has "it.csv(7) Error: it ends before it starts" o.md && ok || bad "end before start (also with a French type word)"
has "[exit code 1]" o.md && ok || bad "exit code line"
php "$TL" check it.csv o2.md min=20 >/dev/null; has "tight connection" o2.md && bad "min=20 should silence the 30-minute warning" || ok
printf 'type,start,end\nhotel,2026-06-01,2026-06-05\nhotel,2026-06-04,2026-06-08\n' > ov.csv; php "$TL" check ov.csv ov.md >/dev/null; has "lodging overlaps line 2" ov.md && ok || bad "lodging overlap"
printf 'type,start,end\nflight,05/03/2026 10:00,05/03/2026 12:00\nflight,13/03/2026 10:00,13/03/2026 11:00\n' > dm.csv; php "$TL" check dm.csv dm.md >/dev/null; has "dates read day-first" dm.md && has "2026-03-13 10:00" dm.md && ok || bad "day-first dates"
# budget
php "$TL" budget it.csv b.md base=USD rates=EUR=1.1 >/dev/null; has "**Total: 950.00 USD**" b.md && ok || bad "budget total (400 EUR x 1.1 + 120 + 90 + 300): $(grep Total b.md)"
has "| 2026-05-01 | 750.00 |" b.md && has "| 2026-05-02 | 100.00 |" b.md && ok || bad "by day with lodging spread over its nights"
has "no rate for CAD" b.md && ok || bad "a currency without a rate is listed, not guessed"
php "$TL" budget it.csv b2.md >/dev/null; has "| EUR | 400.00 |" b2.md && has "never added together" b2.md && ok || bad "no base: each currency on its own"
# packing
printf '5 days of hiking in the rain, then the beach\n- [ ] passport\n' > t.md
php "$TL" packing t.md p.md >/dev/null; has "Trip length: 5 day(s)" p.md && has "Waterproof jacket" p.md && has "Hiking boots" p.md && has "Swimwear" p.md && ok || bad "packing content: $(head -12 p.md)"
[ "$(grep -ci 'passport' p.md)" = 0 ] && ok || bad "an item already ticked in the file is repeated"
[ "$(grep -c 'Sunscreen' p.md)" = 1 ] && [ "$(grep -c 'Refillable water bottle' p.md)" = 1 ] && ok || bad "an item appears twice"
php "$TL" packing it.csv p2.md climate=cold >/dev/null; has "Warm jacket" p2.md && has "Trip length: 9 day(s) (from the itinerary dates)" p2.md && ok || bad "length from the itinerary: $(sed -n 3p p2.md)"
# refusals, original unchanged
[ "$(rc check nope.csv x.md)" = 1 ] && ok || bad "a missing file was not refused"
[ "$(rc frob it.csv x.md)" = 2 ] && ok || bad "an unknown subcommand was not refused"
printf 'a,b\n1,2\n' > nos.csv; [ "$(rc check nos.csv x.md)" = 1 ] && ok || bad "a sheet without a start column was not refused"
[ "$(rc packing nos.csv x.md)" = 1 ] && ok || bad "packing without a trip length was not refused"
[ "$(rc budget it.csv x.md rates=EUR=1.1)" = 1 ] && ok || bad "rates without base was not refused"
[ "$(md5sum it.csv | cut -d' ' -f1)" = "$sum0" ] && ok || bad "the original changed"
head -20 "$TL" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no command-line-only guard"
php -r 'foreach(array_slice($argv,1) as $f){ $j=json_decode(file_get_contents($f),true); if(!is_array($j)){ echo "bad json $f"; exit(1);} } echo "ok";' "$ROOT/cockpit_app/tools_builtins/trip.json" > pc 2>&1; [ "$(cat pc)" = ok ] && ok || bad "json: $(cat pc)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; for($i=2;$i<count($argv);$i++){ $j=json_decode(file_get_contents($argv[$i]),true); $e=""; if(kind_validate($j,$e)===null){ echo "invalid ".$argv[$i].": $e"; exit(1);} if(count($j["examples"]??[])<3||empty($j["verify"])||empty($j["group"])||empty($j["note"])||empty($j["details"])){ echo "incomplete ".$argv[$i]; exit(1);} } echo "ok";' "$ROOT" "$ROOT/cockpit_app/kinds/travel.json" > kc 2>&1; [ "$(cat kc)" = ok ] && ok || bad "kind: $(cat kc)"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/trip_tool [a-z]+ \{INPUT\} \{OUTPUT\}~",$p["command"])){ echo "bad ".$p["id"]; exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/trip.json" > pc 2>&1; [ "$(cat pc)" = 3 ] && ok || bad "presets: $(cat pc)"
# the word "hotel" is not hot weather
printf '4 days in the rain, 2 nights hotel Lisboa, hotel breakfast\n- [ ] passport\n' > hotel.md
php "$TL" packing hotel.md hotel_p.md >/dev/null; { grep -q 'Climate words found: rain' hotel_p.md || grep -q 'rain' hotel_p.md; } && ! grep -q 'Sunscreen' hotel_p.md && ok || bad "hotel read as hot weather: $(head -8 hotel_p.md)"
echo "trip_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
