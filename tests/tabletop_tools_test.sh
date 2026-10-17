#!/usr/bin/env bash
# tabletop_tools_test.sh — the Tabletop tools (cockpit_app/tabletop_tool, tools_builtins/tabletop.json, kinds/tabletop.json): roll with seed, odds, initiative, sheet check, notes index, refusals.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; TT="$ROOT/cockpit_app/tabletop_tool"
command -v php >/dev/null 2>&1 && php -m 2>/dev/null | grep -qi '^mbstring$' || { echo "tabletop_tools_test: php with mbstring is needed - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
has() { grep -qF -- "$1" "$2"; }
cd "$T" || exit 1
printf '2d6+3\n4d6kh3\n2d20kl1\nd100\n3d8dl1+1d4-2\n' > d.txt
printf '1d6\n2d6\n4d6kh3\n2d20kh1\n2d6+3\n' > o.txt
printf 'name,bonus,hp,ac,team,count\nAria,+3,24,15,party,1\nGoblin,1,7,13,foes,3\nOgre,-1,59,11,foes,\n' > i.csv
printf 'Name: Aria\nClass: Rogue\nLevel: 3\nSTR: 8\nDEX: 15\nCON: 13\nINT: 12\nWIS: 10\nCHA: 14\nBackground:\n' > s.md
mkdir notes; printf '# Session 1\nWe met **Brother Aldric** in Oakvale. The innkeeper Mara poured.\n## Session 2\nAldric left Oakvale; Mara stayed.\n' > notes/s1.md; printf 'Café Noir is where Mara works.\n' > notes/s2.txt
printf 'name,type,aliases\nAldric,npc,Brother Aldric\nMara,npc,\nOakvale,location,\nRedhold,location,\nCafe,location,Café Noir\n' > ent.csv
before=$(md5sum d.txt o.txt i.csv s.md notes/s1.md ent.csv)
# roll
php "$TT" roll d.txt r1.md seed=7 times=2 >/dev/null; [ $? = 0 ] && ok || bad "roll rc"
php "$TT" roll d.txt r2.md seed=7 times=2 >/dev/null; cmp -s r1.md r2.md && ok || bad "the same seed gave different rolls"
php "$TT" roll d.txt r3.md seed=8 times=2 >/dev/null; cmp -s r1.md r3.md && bad "a different seed gave identical rolls" || ok
has "Seed 7" r1.md && has "## 4d6kh3" r1.md && has "~~" r1.md && ok || bad "roll output: $(head -20 r1.md)"
php -r '$t=file_get_contents($argv[1]); preg_match_all("/\*\*(\d+)\*\*  \(2d6 \[(\d), (\d)\]=(\d+) \+3\)/",$t,$m,PREG_SET_ORDER); if(!$m){exit(1);} foreach($m as $x){ if($x[2]+$x[3]!=$x[4]||$x[4]+3!=$x[1]||$x[2]<1||$x[2]>6){exit(1);} } exit(0);' r1.md && ok || bad "2d6+3 totals are not the sum of the dice plus 3"
php -r '$t=file_get_contents($argv[1]); preg_match_all("/4d6kh3 \[([^\]]*)\]=(\d+)/",$t,$m,PREG_SET_ORDER); if(!$m)exit(1); foreach($m as $x){ $d=array_map(fn($v)=>trim($v),explode(",",$x[1])); $keep=[]; foreach($d as $v) if(strpos($v,"~~")===false) $keep[]=(int)$v; sort($keep); $all=[]; foreach($d as $v)$all[]=(int)trim($v,"~"); sort($all); if(count($keep)!=3||array_sum($keep)!=$x[2]||array_slice($all,1)!=$keep) exit(1);} exit(0);' r1.md && ok || bad "4d6kh3 did not keep the three highest"
printf '2d6+\nabc\n0d6\n1d1\n3d6kh4\n' > badd.txt; php "$TT" roll badd.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "an all-invalid file was not refused"
printf '1d6\nabc\n' > mix.txt; php "$TT" roll mix.txt mx.md >/dev/null 2>&1; [ $? = 0 ] && has 'mix.txt(2) Error' mx.md && ok || bad "one bad line among good ones"
# odds
php "$TT" odds o.txt od.md target=10 >/dev/null; has "| 7 | 16.67% | 58.33% |" od.md && ok || bad "2d6 table: $(sed -n 1,25p od.md)"
has "Minimum 3, maximum 18, mean 12.245" od.md && ok || bad "4d6kh3 mean 12.2446"
has "Chance of 10 or more: 16.67%." od.md && ok || bad "target chance for 2d6"
has "| 20 | 9.75% | 9.75% |" od.md && ok || bad "2d20kh1: P(20) = 39/400 = 9.75%"
has "| 5 | 2.78% | 100.00% |" od.md && ok || bad "2d6+3 shifted"
printf '10d100kh3\n' > big.txt; php "$TT" odds big.txt bg.md seed=3 >/dev/null; has "sampled: 200000 rolls, seed 3" bg.md && ok || bad "a huge case must be sampled and labelled"
# initiative
php "$TT" initiative i.csv in1.md seed=5 >/dev/null; php "$TT" initiative i.csv in2.md seed=5 >/dev/null; cmp -s in1.md in2.md && ok || bad "initiative not repeatable with a seed"
has "Goblin 1" in1.md && has "Goblin 3" in1.md && has "## Round tracker" in1.md && ok || bad "numbered copies / tracker: $(cat in1.md)"
php -r '$t=file($argv[1]); $p=null; $c=0; foreach($t as $l){ if(preg_match("/^\| (\d+) \| .*? \| (\d+) \| ([+-]\d+) \| (\d+) \|/",$l,$m)){ $c++; if($m[2]+(int)$m[3]!=$m[4]) exit(1); if($p!==null && $m[4]>$p) exit(1); $p=$m[4]; } } exit($c==5?0:1);' in1.md && ok || bad "order is not descending or total != roll + bonus"
printf 'name,bonus\nA,x\n' > bi.csv; php "$TT" initiative bi.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "unusable combatants not refused"
printf 'hp,ac\n5,5\n' > nn.csv; php "$TT" initiative nn.csv x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing name column not refused"
# sheet
php "$TT" sheet s.md sh.md require=name,class,level,hp abilities=str,dex,con,int,wis,cha budget=27 costs=8:0,9:1,10:2,11:3,12:4,13:5,14:7,15:9 min=3 max=18 >/dev/null; has 'required field "hp" is missing' sh.md && has "Point-buy: 27 of 27" sh.md && has 'field "background" is empty' sh.md && ok || bad "sheet: $(cat sh.md)"
php "$TT" sheet s.md sh2.md abilities=str,dex,con,int,wis,cha budget=20 costs=8:0,9:1,10:2,11:3,12:4,13:5,14:7,15:9 >/dev/null; has "over the budget 20" sh2.md && ok || bad "over budget"
php "$TT" sheet s.md sh3.md abilities=str,dex max=14 >/dev/null; has "dex 15 is above the maximum 14" sh3.md && has "No point-buy table given" sh3.md && ok || bad "ability max, no assumed system"
php "$TT" sheet s.md sh4.md abilities=str budget=10 costs=9:1 >/dev/null; has "str 8 is not in your cost table" sh4.md && ok || bad "score not in cost table"
php "$TT" sheet s.md x.md budget=10 >/dev/null 2>&1; [ $? = 2 ] && ok || bad "budget without costs must exit 2"
printf 'just prose with no fields\n' > nf.md; php "$TT" sheet nf.md x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "a sheet with no fields not refused"
# notes
php "$TT" notes notes n.md with=ent.csv >/dev/null; has "- **Aldric**: 2 mention(s)" n.md && has "- **Mara**: 3 mention(s)" n.md && has "- Redhold (location)" n.md && has "Never mentioned (1)" n.md && ok || bad "notes index: $(cat n.md)"
has "- **Cafe**: 1 mention(s) - s2.txt:1" n.md && ok || bad "an alias with an accent (Café Noir) should match"
has "(under: Session 1; Session 2)" n.md && ok || bad "headings of the mentions"
php "$TT" notes notes n2.md >/dev/null; has "Brother Aldric" n2.md && ok || bad "bold candidates without an entity file"
printf 'plain text no names\n' > pl.md; php "$TT" notes pl.md x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "no entities not refused"
php "$TT" notes notes x.md with=nope.csv >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing entity file not refused"
# refusals, original untouched
php "$TT" roll nope.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "missing file not refused"
: > e.txt; php "$TT" roll e.txt x.md >/dev/null 2>&1; [ $? = 1 ] && ok || bad "empty file not refused"
php "$TT" frob d.txt x.md >/dev/null 2>&1; [ $? = 2 ] && ok || bad "unknown subcommand"
[ "$(md5sum d.txt o.txt i.csv s.md notes/s1.md ent.csv)" = "$before" ] && ok || bad "an original changed"
head -20 "$ROOT/cockpit_app/tabletop_tool" | grep -q "PHP_SAPI !== 'cli'" && ok || bad "no CLI guard"
php -r '$j=json_decode(file_get_contents($argv[1]),true); foreach($j["presets"] as $p){ if(!preg_match("~^php \{WEBROOT\}/tabletop_tool (roll|odds|initiative|sheet|notes) \{INPUT\} \{OUTPUT\}~",$p["command"])) {echo "bad";exit(1);} } echo count($j["presets"]);' "$ROOT/cockpit_app/tools_builtins/tabletop.json" > pc.out 2>&1; [ "$(cat pc.out)" = 5 ] && ok || bad "tabletop.json: $(cat pc.out)"
php -r 'require $argv[1]."/cockpit_app/kinds_lib.php"; $k=json_decode(file_get_contents($argv[1]."/cockpit_app/kinds/tabletop.json"),true); $e=""; $r=kind_validate($k,$e); exit($r&&$r["group"]==="Home & life"&&$r["tools"][0]["tool"]==="tabletop"?0:1);' "$ROOT" >/dev/null 2>&1 && ok || bad "kind fails kind_validate"
echo "tabletop_tools_test: $n passed, $fails failed"; [ "$fails" = 0 ]
