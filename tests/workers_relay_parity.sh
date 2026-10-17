#!/usr/bin/env bash
# =============================================================================
# workers_relay_parity.sh — does `aicengine relay` print what cockpit_app/worker_relay.php prints?
#
# Both are run on the same encrypted key store (made with workers.php's own encrypt_blob) against a mock provider that answers per
# model name; compared: stdout, and the request the provider received (method, path, Authorization, content type, body).
# Refusals (exit 9) are tested separately; a refusal must print nothing.
#
#   bash tests/workers_relay_parity.sh        (needs php; the engine binary at $ENGINE)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PHPR="$HERE/../cockpit_app/worker_relay.php"; PHPW="$HERE/../cockpit_app/workers.php"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
command -v php >/dev/null || { echo "needs php"; exit 2; }
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " relay" || { echo "SKIP: engine without relay"; exit 0; }
T="$(mktemp -d)"; PORT=18957; MOCKPID=""
trap '[ -n "$MOCKPID" ] && kill "$MOCKPID" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1${2:+  — $2}"; FAIL=$((FAIL+1)); }

mkdir -p "$T/mock" "$T/data"
cat > "$T/router.php" <<'PHP'
<?php
$dir = getenv('MOCK_DIR');
$body = file_get_contents('php://input');
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$j = json_decode($body, true);
$model = is_array($j) && isset($j['model']) ? $j['model'] : basename($path);
$entry = ['method' => $_SERVER['REQUEST_METHOD'], 'path' => $path, 'auth' => $_SERVER['HTTP_AUTHORIZATION'] ?? null, 'ctype' => $_SERVER['CONTENT_TYPE'] ?? null, 'body' => $body];
file_put_contents("$dir/requests.log", json_encode($entry, JSON_UNESCAPED_UNICODE) . "\n", FILE_APPEND | LOCK_EX);
$f = "$dir/resp_" . preg_replace('/[^A-Za-z0-9_.-]/', '_', $model);
if (!is_file($f)) { http_response_code(404); echo ''; exit; }
$c = file_get_contents($f);
while (true) {
  if (strpos($c, "STATUS:") === 0) { [$l, $c] = explode("\n", $c, 2); http_response_code((int)substr($l, 7)); }
  elseif (strpos($c, "CT:") === 0) { [$l, $c] = explode("\n", $c, 2); header('Content-Type: ' . substr($l, 3)); }
  elseif (strpos($c, "REDIRECT:") === 0) { [$l, $c] = explode("\n", $c, 2); header('Location: ' . substr($l, 9), true, 302); exit; }
  else break;
}
echo $c;
PHP
MOCK_DIR="$T/mock" php -S "127.0.0.1:$PORT" "$T/router.php" >/dev/null 2>&1 & MOCKPID=$!
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/x" && break; sleep 0.1; done
BASE="http://127.0.0.1:$PORT"

# the key store, exactly as workers.php writes it
mkkeys() {   # mkkeys DIR JSON
  php -r 'require $argv[1]; file_put_contents($argv[2]."/workers_keys.enc", encrypt_blob($argv[3]));' "$PHPW" "$1" "$2" 2>/dev/null
}
mkdir -p "$T/d1" "$T/d_nokey" "$T/d_none" "$T/d_bad"
mkkeys "$T/d1" '{"groq":"gsk_TESTKEY","huggingface":"hf_TESTKEY","cloudflare":"acct123:cftoken"}'
mkkeys "$T/d_nokey" '{"other":"x"}'
echo "not-a-valid-blob!" > "$T/d_bad/workers_keys.enc"
[ -s "$T/d1/workers_keys.enc" ] || { echo "could not make the key store (php/openssl?)"; exit 2; }

mock() { printf '%s' "$2" > "$T/mock/resp_$(printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g')"; }
run_php() { : > "$T/mock/requests.log"; COCKPIT_DATA_OVERRIDE="$1" COCKPIT_WORKER_BASE="$BASE" php "$PHPR" "$2" "$3" "$4" 2>/dev/null; echo "[rc=$?]"; }
run_eng() { COCKPIT_DATA_OVERRIDE="$1" COCKPIT_WORKER_BASE="$BASE" "$ENG" relay "$2" "$3" "$4" 2>/dev/null; echo "[rc=$?]"; }

# case NAME DATA PROVIDER MODEL PROMPT   (the mock answer is set before: mock MODEL CONTENT)
case_() {
  local name="$1" dd="$2" prov="$3" model="$4" prompt="$5" pf="$T/prompt.txt"
  printf '%s' "$prompt" > "$pf"
  local a b ra rb
  a="$(run_php "$dd" "$prov" "$model" "$pf")"; ra="$(cat "$T/mock/requests.log" 2>/dev/null)"
  : > "$T/mock/requests.log"
  b="$(run_eng "$dd" "$prov" "$model" "$pf")"; rb="$(cat "$T/mock/requests.log" 2>/dev/null)"
  if [ "$a" != "$b" ]; then bad "$name" "output: php=[$a] engine=[$b]"; return; fi
  if [ "$ra" != "$rb" ]; then bad "$name" "request: php=[$ra] engine=[$rb]"; return; fi
  ok "$name  → ${a:0:60}"
}
refused() {   # refused NAME DATA PROVIDER MODEL PROMPTFILE
  local out rc
  out="$(COCKPIT_DATA_OVERRIDE="$2" COCKPIT_WORKER_BASE="$BASE" "$ENG" relay "$3" "$4" "$5" 2>/dev/null)"; rc=$?
  if [ "$rc" = 9 ] && [ -z "$out" ]; then ok "refuses: $1"; else bad "refuses: $1" "rc=$rc out=[$out]"; fi
}

echo "== groq =="
mock m_ok '{"choices":[{"message":{"content":"hello there"}}],"usage":{"prompt_tokens":3}}'
case_ "groq ok" "$T/d1" groq m_ok 'say hi'
case_ "groq unicode, slash, quote, newline in the prompt" "$T/d1" groq m_ok $'שלום "x" a/b\ttab\nline2 \xe2\x80\xa8 end'
mock m_empty_choice '{"choices":[]}'
case_ "groq no choices → empty answer" "$T/d1" groq m_empty_choice 'q'
mock m_nullc '{"choices":[{"message":{"content":null}}]}'
case_ "groq null content" "$T/d1" groq m_nullc 'q'
mock m_errobj '{"error":{"message":"rate limited, slow down"}}'
case_ "groq error object" "$T/d1" groq m_errobj 'q'
mock m_errnomsg '{"error":{"code":5}}'
case_ "groq error object without message" "$T/d1" groq m_errnomsg 'q'
mock m_errstr '{"error":"just text"}'
case_ "groq error string (200)" "$T/d1" groq m_errstr 'q'
mock m_badjson 'not json at all'
case_ "groq bad JSON" "$T/d1" groq m_badjson 'q'
mock m_scalar '42'
case_ "groq JSON scalar" "$T/d1" groq m_scalar 'q'
mock m_401 $'STATUS:401\n{"error":{"message":"Invalid API Key"}}'
case_ "groq 401 with message" "$T/d1" groq m_401 'q'
mock m_401s $'STATUS:401\n{"error":"bad key text"}'
case_ "groq 401 error string" "$T/d1" groq m_401s 'q'
mock m_500e $'STATUS:500\n'
case_ "groq 500 empty body" "$T/d1" groq m_500e 'q'
mock m_500h "$(printf 'STATUS:503\n<html>%s</html>' "$(head -c 400 /dev/zero | tr '\0' 'x')")"
case_ "groq 503 html body (cut at 300 bytes)" "$T/d1" groq m_500h 'q'
mock m_zero $'STATUS:400\n{"error":{"message":"0"}}'
case_ "groq 400 message '0' (falsy → body)" "$T/d1" groq m_zero 'q'
mock m_404msg $'STATUS:404\n{"message":"no such model"}'
case_ "groq 404 json without error key" "$T/d1" groq m_404msg 'q'
mock m_ok2 '{"choices":[{"message":{"content":"x"}}]}'
case_ "groq: no key store" "$T/d_none" groq m_ok2 'q'
case_ "groq: store without this provider" "$T/d_nokey" groq m_ok2 'q'
case_ "groq: store that cannot be decrypted" "$T/d_bad" groq m_ok2 'q'

echo "== huggingface =="
mock hf_gen '[{"generated_text":"hf says hi"}]'
case_ "hf generated_text" "$T/d1" huggingface hf_gen 'q'
mock hf_tr '[{"translation_text":"hola"}]'
case_ "hf translation_text" "$T/d1" huggingface hf_tr 'q'
mock hf_err '{"error":"Model is loading"}'
case_ "hf error text" "$T/d1" huggingface hf_err 'q'
mock hf_bad 'nope'
case_ "hf bad response" "$T/d1" huggingface hf_bad 'q'
mock hf_img $'CT:image/png\nPNGBYTES\x01\x02'
case_ "hf image answer → data URI" "$T/d1" huggingface hf_img 'q'
mock hf_aud $'CT:audio/wav; codec=x\nWAVDATA'
case_ "hf audio answer → data URI" "$T/d1" huggingface hf_aud 'q'
mock hf_404 $'STATUS:404\n{"error":"Model not found"}'
case_ "hf 404" "$T/d1" huggingface hf_404 'q'
case_ "hf model with a slash in its name" "$T/d1" huggingface 'meta/llama' 'q'

echo "== cloudflare =="
mock cf_ok '{"success":true,"result":{"response":"cf says hi"}}'
case_ "cf ok" "$T/d1" cloudflare cf_ok 'hello "q"'
mock cf_fail '{"success":false,"errors":[{"message":"bad token"}]}'
case_ "cf success false" "$T/d1" cloudflare cf_fail 'q'
mock cf_fail2 '{"success":false}'
case_ "cf success false without errors" "$T/d1" cloudflare cf_fail2 'q'
mock cf_zero '{"success":"0","errors":[{"message":"zero"}]}'
case_ "cf success '0' (falsy)" "$T/d1" cloudflare cf_zero 'q'
mock cf_nores '{"success":true,"result":{}}'
case_ "cf no response field" "$T/d1" cloudflare cf_nores 'q'
mock cf_bad 'plain'
case_ "cf bad JSON" "$T/d1" cloudflare cf_bad 'q'
mock cf_403 $'STATUS:403\n{"errors":[{"message":"forbidden"}]}'
case_ "cf 403 (no error key → body)" "$T/d1" cloudflare cf_403 'q'
mkdir -p "$T/d_cfbad" "$T/d_cfsp"
mkkeys "$T/d_cfbad" '{"cloudflare":"onlytoken"}'
case_ "cf key without ACCOUNT_ID:" "$T/d_cfbad" cloudflare cf_ok 'q'
mkkeys "$T/d_cfsp" '{"cloudflare":"my acct/1:tok:en"}'
case_ "cf account with space and slash (rawurlencode), token with a colon" "$T/d_cfsp" cloudflare cf_ok 'q'

echo "== refusals (exit 9, nothing printed) =="
printf 'q' > "$T/p.txt"; : > "$T/empty.txt"; printf '\xff\xfe bad utf8' > "$T/bad8.txt"
refused "no per-user data folder" "" groq m_ok "$T/p.txt"
refused "another provider" "$T/d1" openrouter m "$T/p.txt"
refused "empty prompt" "$T/d1" groq m "$T/empty.txt"
refused "missing prompt file" "$T/d1" groq m "$T/nope.txt"
refused "prompt that is not UTF-8" "$T/d1" groq m_ok "$T/bad8.txt"
mock m_num '{"choices":[{"message":{"content":12.5}}]}'
refused "a number where text is expected" "$T/d1" groq m_num "$T/p.txt"
mock m_errarr '{"error":{"message":["a","b"]}}'
refused "an error message that is not text" "$T/d1" groq m_errarr "$T/p.txt"
mock m_500arr $'STATUS:500\n{"error":["x"]}'
refused "an HTTP error that is a list" "$T/d1" groq m_500arr "$T/p.txt"
mock m_redir $'REDIRECT:/elsewhere\n'
refused "a redirect" "$T/d1" groq m_redir "$T/p.txt"
mock hf_other '{"foo":"bar"}'
refused "hf answer of an unknown shape (PHP pretty-prints it)" "$T/d1" huggingface hf_other "$T/p.txt"

echo "== transport failure =="
out="$(COCKPIT_DATA_OVERRIDE="$T/d1" COCKPIT_WORKER_BASE="http://127.0.0.1:1" "$ENG" relay groq m "$T/p.txt" 2>/dev/null)"
case "$out" in "[GROQ ERROR] curl: "*) ok "connection refused reads '[GROQ ERROR] curl: …'";; *) bad "connection refused" "[$out]";; esac

echo
echo "workers relay parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
