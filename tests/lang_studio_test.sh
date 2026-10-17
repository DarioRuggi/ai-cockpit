#!/usr/bin/env bash
# lang_studio_test.sh — the Translation Studio's server side (lang.php: strings / check / save / template).
# A throw-away copy of lang.php with a stub paths.php (data root in a temp dir) and a stub auth.php, served by php -S.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; T="$(mktemp -d)"; PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
cleanup() { [ -n "${PID:-}" ] && kill "$PID" 2>/dev/null; rm -rf "$T"; }; trap cleanup EXIT
mkdir -p "$T/app/lang" "$T/data"
cp "$ROOT/cockpit_app/lang.php" "$T/app/"; cp "$ROOT/cockpit_app/lang/en.json" "$ROOT/cockpit_app/lang/_template.json" "$T/app/lang/"
printf '{"_meta":{"code":"he","name":"Hebrew","native":"Hebrew","dir":"rtl"},"strings":{"archive.add":"shipped-add"}}' > "$T/app/lang/he.json"
printf '<?php $PATHS = ["cockpit_data_root" => "%s"];\n' "$T/data" > "$T/app/paths.php"
printf '<?php function auth_require_writer(): void {}\n' > "$T/app/auth.php"
PORT=$((20000 + RANDOM % 20000)); (cd "$T/app" && exec php -S 127.0.0.1:$PORT >"$T/srv.log" 2>&1) & PID=$!
for i in $(seq 1 30); do curl -s "http://127.0.0.1:$PORT/lang.php?action=list" >/dev/null 2>&1 && break; sleep 0.2; done
B="http://127.0.0.1:$PORT/lang.php"
jq_() { php -r '$j=json_decode(stream_get_contents(STDIN),true); $p=explode(".",$argv[1]); foreach($p as $k){ if(!is_array($j)||!array_key_exists($k,$j)){echo "NULL";exit;} $j=$j[$k]; } echo is_bool($j)?($j?"true":"false"):(is_array($j)?json_encode($j):$j);' "$1"; }
post() { curl -s -X POST -H 'Content-Type: application/json' -d "$2" "$B?action=$1"; }

R=$(curl -s "$B?action=strings&code=he")
[ "$(echo "$R" | jq_ ok)" = true ] && ok "strings answers" || bad "strings answers"
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo count($j["en"])>2000?"y":"n";')" = y ] && ok "strings carries the English (over 2000)" || bad "strings English"
[ "$(echo "$R" | jq_ mine.archive\\.add)" = NULL ] && true
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo $j["mine"]["archive.add"]??"none";')" = "shipped-add" ] && ok "strings carries the shipped translation" || bad "shipped translation"
[ "$(echo "$R" | jq_ writable)" = true ] && ok "data folder reported writable" || bad "writable"

R=$(post check '{"code":"fr","meta":{"name":"French"},"strings":{"archive.add":"Ajouter","archive.choose":"Choisir"}}')
[ "$(echo "$R" | jq_ count)" = 2 ] && ok "check counts the good strings (no placeholders in these)" || bad "check count: $R"
KEY=$(php -r '$e=json_decode(file_get_contents($argv[1]),true)["strings"]; foreach($e as $k=>$v) if(preg_match("/\{[A-Za-z0-9_]+\}/",$v)){echo $k; exit;}' "$ROOT/cockpit_app/lang/en.json")
R=$(post check "{\"code\":\"fr\",\"meta\":{\"name\":\"French\"},\"strings\":{\"$KEY\":\"sans variable\"}}")
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo isset($j["bad"][$argv[1]])?"y":"n";' "$KEY")" = y ] && ok "a lost {placeholder} is reported" || bad "placeholder not caught: $R"
R=$(post check '{"code":"fr","meta":{"name":"French"},"strings":{"no.such.key":"x"}}')
[ "$(echo "$R" | jq_ unknown_keys)" = 1 ] && ok "an unknown key is ignored and counted" || bad "unknown key: $R"
R=$(post check '{"code":"../etc","meta":{"name":"x"},"strings":{}}'); [ "$(echo "$R" | jq_ ok)" = false ] && ok "a bad code is refused" || bad "bad code accepted"
R=$(post save '{"code":"en","meta":{"name":"English"},"strings":{}}'); [ "$(echo "$R" | jq_ ok)" = false ] && ok "English cannot be replaced" || bad "English replaced"
R=$(post save '{"code":"fr","meta":{"name":""},"strings":{"archive.add":"A"}}'); [ "$(echo "$R" | jq_ ok)" = false ] && ok "a language without a name is refused" || bad "no-name accepted"
[ ! -e "$T/data/lang/fr.json" ] && ok "nothing was written by the refused saves" || bad "file written by a refused save"

R=$(post save "{\"code\":\"fr\",\"meta\":{\"name\":\"French\",\"native\":\"Français\",\"dir\":\"ltr\",\"translator\":\"t\"},\"strings\":{\"archive.add\":\"Ajouter\",\"$KEY\":\"sans variable\",\"archive.close\":\"Fermer\"}}")
[ "$(echo "$R" | jq_ ok)" = true ] && ok "save succeeds" || bad "save: $R"
[ -f "$T/data/lang/fr.json" ] && ok "fr.json written to the data folder" || bad "fr.json missing"
php -r '$j=json_decode(file_get_contents($argv[1]),true); $s=$j["strings"]; exit((isset($s["archive.add"])&&isset($s["archive.close"])&&!isset($s[$argv[2]])&&$j["_meta"]["code"]==="fr")?0:1);' "$T/data/lang/fr.json" "$KEY" && ok "the bad-placeholder line was left out, the good ones kept" || bad "file content"
R=$(curl -s "$B?action=list"); echo "$R" | grep -q '"code":"fr"' && ok "the new language is listed" || bad "not listed"
R=$(curl -s "$B?action=template&code=fr"); [ "$(echo "$R" | jq_ strings.archive\\.add)" = NULL ] && true
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo $j["strings"]["archive.add"]??"?";')" = "Ajouter" ] && ok "template&code= comes back filled with the translation" || bad "filled template"
[ "$(curl -s "$B?action=template" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo $j["strings"]["archive.add"]===""?"empty":"filled";')" = empty ] && ok "template without a code stays empty" || bad "plain template"
R=$(post save '{"code":"he","meta":{"name":"Hebrew","dir":"rtl"},"strings":{"archive.add":"mine-add"}}'); R2=$(curl -s "$B?action=get&code=he")
[ "$(echo "$R2" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo $j["strings"]["archive.add"]??"?";')" = "mine-add" ] && ok "your file overrides a shipped pack's key" || bad "override"
# ── AutoTranslate: a stub Ollama (tags + generate) so the endpoint's parsing and its placeholder guard are tested without a model ──
mkdir -p "$T/stub"; cat > "$T/stub/router.php" <<'STUB'
<?php
$p = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH); header('Content-Type: application/json');
if ($p === '/api/tags') { echo json_encode(['models' => [['name' => 'qwen2.5-coder:3b', 'size' => 1.9e9], ['name' => 'gemma3:4b', 'size' => 3.3e9], ['name' => 'nomic-embed-text', 'size' => 2.7e8]]]); exit; }
if ($p === '/api/generate') {
    $b = json_decode(file_get_contents('php://input'), true); $pr = (string)$b['prompt'];
    // echo back, line by line: 1 → "FR(text)"; the line that has a {placeholder} loses it; one line repeats the English after a bar
    preg_match_all('/^(\d+) \| (.*)$/m', $pr, $m, PREG_SET_ORDER); $o = [];
    foreach ($m as $r) { $t = $r[2]; if (strpos($t, '{') !== false) $o[] = $r[1] . ' | sans variable'; elseif ($r[1] === '2') $o[] = $r[1] . ' | FR2 | ' . $t; else $o[] = $r[1] . ' | FR' . $r[1] . ' ' . $t; }
    echo json_encode(['response' => implode("\n", $o), 'total_duration' => 2e9]); exit;
}
http_response_code(404);
STUB
SP=$((PORT + 1)); (cd "$T/stub" && exec php -S 127.0.0.1:$SP router.php >"$T/stub.log" 2>&1) & SPID=$!
kill "$PID" 2>/dev/null; sleep 0.3; (cd "$T/app" && COCKPIT_OLLAMA_URL="http://127.0.0.1:$SP" exec php -S 127.0.0.1:$PORT >"$T/srv.log" 2>&1) & PID=$!
for i in $(seq 1 30); do curl -s "$B?action=list" >/dev/null 2>&1 && break; sleep 0.2; done
R=$(curl -s "$B?action=models"); [ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo $j["models"][0]["name"]??"?";')" = "gemma3:4b" ] && ok "models: the best translator first, coder and embedding models left out" || bad "models: $R"
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); echo count($j["models"]);')" = 1 ] && ok "models: only chat models are listed" || bad "model count: $R"
KEYS2=$(php -r '$e=json_decode(file_get_contents($argv[1]),true)["strings"]; $o=[]; $ph=null; foreach($e as $k=>$v){ if(preg_match("/\{[A-Za-z0-9_]+\}/",$v)){ if(!$ph){$ph=$k;} continue;} if(count($o)<3) $o[]=$k; } $o[]=$ph; echo json_encode($o);' "$ROOT/cockpit_app/lang/en.json")
R=$(post auto "{\"keys\":$KEYS2,\"lang_name\":\"French\",\"code\":\"fr\",\"model\":\"gemma3:4b\"}")
[ "$(echo "$R" | jq_ ok)" = true ] && ok "auto answers" || bad "auto: $R"
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); $k=json_decode($argv[1],true); echo (isset($j["results"][$k[0]])&&strpos($j["results"][$k[0]],"FR1")===0)?"y":"n";' "$KEYS2")" = y ] && ok "auto: the draft of line 1 is parsed" || bad "auto line 1: $R"
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); $k=json_decode($argv[1],true); echo ($j["results"][$k[1]]??"?");' "$KEYS2")" = "FR2" ] && ok "auto: a model that repeats the English after a bar is cut to the translation" || bad "auto bar: $R"
[ "$(echo "$R" | php -r '$j=json_decode(stream_get_contents(STDIN),true); $k=json_decode($argv[1],true); echo in_array($k[3],$j["rejected"])?"y":"n";' "$KEYS2")" = y ] && ok "auto: a draft that lost its {placeholder} is rejected, never offered" || bad "auto placeholder: $R"
R=$(post auto '{"keys":["archive.add"],"lang_name":"French","code":"fr","model":"bad model name; rm"}'); [ "$(echo "$R" | jq_ ok)" = false ] && ok "auto: a model name with shell characters is refused" || bad "bad model accepted"
R=$(post auto '{"keys":["archive.add"],"lang_name":"","code":"","model":"gemma3:4b"}'); [ "$(echo "$R" | jq_ ok)" = false ] && ok "auto: a language with no name is refused" || bad "nameless accepted"
kill "$SPID" 2>/dev/null
echo "lang_studio_test: $PASS passed, $FAIL failed"; exit $FAIL
