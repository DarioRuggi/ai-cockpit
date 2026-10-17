#!/bin/bash
# gemini_parity.sh — the Gemini REST branch of agent_loop.sh, Bash path vs `aicengine gemini`, against a local TLS stand-in for the API.
#
# Real: scripts/agent_loop.sh (run_gemini_rest extracted from it), the aicengine binary, curl, jq, real TLS with certificate verification.
# Fake: the server (tests/gemini_mock.php, PHP, self-signed certificate for localhost). Nothing leaves the machine.
#   bash tests/gemini_parity.sh              ENGINE=<path to aicengine> to choose the binary (default: the runtime repo's build)
# Exit 0 = pass; SKIPPED (exit 0) when the engine has no `gemini` command, or php/openssl/curl/jq are missing.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
for t in php openssl curl jq; do command -v $t >/dev/null 2>&1 || { echo "gemini_parity: $t not found - SKIPPED"; exit 0; }; done
[ -x "$ENG" ] && "$ENG" gemini 2>&1 | grep -q "needs --model" || { echo "gemini_parity: $ENG has no 'gemini' command - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1
PORT=$((19000 + RANDOM % 500))
cleanup() { [ -f "$T/server.pid" ] && kill "$(cat "$T/server.pid")" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
fails=0; n=0; ok() { echo "  ok   $1"; n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }

# ---- certificates: one for localhost (trusted via --cacert / --ca-file), one for another name (to prove the host name is checked) ----
mkcert() { openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/$1.key" -out "$T/$1.pem" -days 2 -subj "/CN=$2" -addext "subjectAltName=DNS:$2" >/dev/null 2>&1; }
mkcert good localhost; mkcert other example.invalid
[ -s "$T/good.pem" ] && [ -s "$T/other.pem" ] || { bad "could not make test certificates"; exit 1; }
serve() { # $1 = cert name
    [ -f "$T/server.pid" ] && kill "$(cat "$T/server.pid")" 2>/dev/null; sleep 0.3
    ( setsid php "$ROOT/tests/gemini_mock.php" $PORT "$T/$1.pem" "$T/$1.key" "$T/req.log" >"$T/server.out" 2>&1 < /dev/null & echo $! > "$T/server.pid" )
    for i in $(seq 1 40); do (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null && break; sleep 0.15; done
}
serve good

# ---- the Bash function, extracted from the real file ------------------------------------------------------------------------------
awk '/^engine_bin\(\) \{/{p=1} p{print} p&&/^}/{c++; if(c==2){p=0}} ' "$ROOT/scripts/agent_loop.sh" > "$T/fn.sh"        # engine_bin + engine_enabled
awk '/^run_gemini_rest\(\) \{/{p=1} p{print} p&&/^}/{p=0}' "$ROOT/scripts/agent_loop.sh" >> "$T/fn.sh"
grep -q "^run_gemini_rest()" "$T/fn.sh" && grep -q "^engine_enabled()" "$T/fn.sh" || { bad "could not extract the functions from agent_loop.sh"; exit 1; }
cat > "$T/run.sh" <<RUN
#!/bin/bash
. "$T/fn.sh"
GEMINI_MODEL="gemini-2.5-flash"; GEMINI_API_KEY="\${KEY-testkey-SECRET123}"; PROMPT_TMP="\$1"; OUT_FILE="\$2"
GEMINI_API_BASE="https://localhost:$PORT"; GEMINI_CA_FILE="\${CA:-$T/good.pem}"
run_gemini_rest
RUN
bashpath() { env -u COCKPIT_ENGINE bash "$T/run.sh" "$1" "$2"; }                       # engine off
enginepath() { COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$ENG" bash "$T/run.sh" "$1" "$2"; }   # engine on

scenario() { # $1 name, $2 extra prompt text
    printf 'SCENARIO:%s\n%s' "$1" "${2:-the rest of the prompt}" > "$T/p_$1.txt"
    : > "$T/b_$1.out"; : > "$T/e_$1.out"
    bashpath "$T/p_$1.txt" "$T/b_$1.out" 2>/dev/null; enginepath "$T/p_$1.txt" "$T/e_$1.out" 2>/dev/null
    if cmp -s "$T/b_$1.out" "$T/e_$1.out"; then ok "$1: engine output = Bash output  ($(head -c 60 "$T/e_$1.out" | tr '\n' '|'))"
    else bad "$1: outputs differ"; echo "      bash:   $(head -c 120 "$T/b_$1.out" | od -c | head -3 | tr '\n' ' ')"; echo "      engine: $(head -c 120 "$T/e_$1.out" | od -c | head -3 | tr '\n' ' ')"; fi
}
for s in ok1 ok2 unicode echo safety nocontent emptycands emptytext err errnomsg errnum nojson emptybody nullbody notobj numtext chunked close; do scenario "$s"; done

# ---- the answers themselves (not only equal: right) ------------------------------------------------------------------------------------
[ "$(cat "$T/e_ok2.out")" = "$(printf 'Hello\n world')" ] && ok "two parts: one per line, as jq -r prints them" || bad "ok2 content: $(cat "$T/e_ok2.out")"
grep -q "שלום" "$T/e_unicode.out" && grep -q 'quoted' "$T/e_unicode.out" && grep -q $'\xf0\x9f\x98\x80' "$T/e_unicode.out" && ok "unicode, quotes, backslash, tab and an emoji survive" || bad "unicode content"
[ "$(cat "$T/e_safety.out")" = "[GEMINI ERROR] SAFETY" ] && ok "a safety block says SAFETY" || bad "safety: $(cat "$T/e_safety.out")"
[ "$(cat "$T/e_err.out")" = "[GEMINI ERROR] API key not valid. Please pass a valid API key." ] && ok "an API error shows its message" || bad "err: $(cat "$T/e_err.out")"
[ "$(cat "$T/e_chunked.out" | head -c 14)" = "chunked answer" ] && ok "a chunked response is decoded" || bad "chunked: $(head -c 40 "$T/e_chunked.out")"

# ---- a long prompt: the old argument-list limit (128 KB in one word) ---------------------------------------------------------------------------
head -c 400000 /dev/zero | tr '\0' 'a' > "$T/filler.txt"
printf 'SCENARIO:echo\n' > "$T/p_big.txt"; cat "$T/filler.txt" >> "$T/p_big.txt"
BYTES=$(wc -c < "$T/p_big.txt")
: > "$T/b_big.out"; : > "$T/e_big.out"
bashpath "$T/p_big.txt" "$T/b_big.out" 2>/dev/null; enginepath "$T/p_big.txt" "$T/e_big.out" 2>/dev/null
[ "$(cat "$T/e_big.out")" = "got $BYTES bytes" ] && ok "engine: a 400 KB prompt arrives whole ($BYTES bytes)" || bad "engine big: $(head -c 80 "$T/e_big.out")"
[ "$(cat "$T/b_big.out")" = "got $BYTES bytes" ] && ok "Bash path: the same (the body now goes in on stdin, not as one argument)" || bad "bash big: $(head -c 80 "$T/b_big.out")"

# ---- the key: a header, never the URL; not on the engine's command line --------------------------------------------------------------------
: > "$T/req.log"; scenario ok1 >/dev/null
BOTH=$(cat "$T/req.log")
echo "$BOTH" | jq -e -s 'length==2 and all(.[]; .key_header=="testkey-SECRET123" and .key_query=="")' >/dev/null && ok "both paths send the key as x-goog-api-key and never as ?key=" || bad "key transport: $BOTH"
printf 'SCENARIO:slow\nx' > "$T/p_slow.txt"
: > "$T/slow.out"
( GEMINI_API_KEY=testkey-SECRET123 "$ENG" gemini --model m --prompt-file "$T/p_slow.txt" --out "$T/slow.out" --base "https://localhost:$PORT" --ca-file "$T/good.pem" --timeout 20 & echo $! > "$T/slow.pid" ) ; sleep 1.5
if ps -eo args | grep -v grep | grep -q "testkey-SECRET123"; then bad "the API key is visible in the process list while the engine runs"; else ok "the engine keeps the key off its command line (not in ps)"; fi
grep -q "$(cat "$T/slow.pid")" /dev/null 2>&1; wait 2>/dev/null; sleep 5

# ---- TLS must verify: certificate and host name ------------------------------------------------------------------------------------------
BEFORE=$(wc -l < "$T/req.log")
: > "$T/tls1.out"; GEMINI_API_KEY=k "$ENG" gemini --model m --prompt-file "$T/p_ok1.txt" --out "$T/tls1.out" --base "https://localhost:$PORT" --timeout 10
grep -q "certificate verify failed" "$T/tls1.out" && ok "a certificate that is not trusted is refused ($(head -c 90 "$T/tls1.out"))" || bad "untrusted certificate: $(cat "$T/tls1.out")"
[ "$(wc -l < "$T/req.log")" = "$BEFORE" ] && ok "... and nothing was sent to that server (no request reached it)" || bad "a request reached the untrusted server"
serve other
BEFORE=$(wc -l < "$T/req.log")
: > "$T/tls2.out"; GEMINI_API_KEY=k "$ENG" gemini --model m --prompt-file "$T/p_ok1.txt" --out "$T/tls2.out" --base "https://localhost:$PORT" --ca-file "$T/other.pem" --timeout 10
grep -qi "certificate verify failed" "$T/tls2.out" && ok "a trusted certificate for ANOTHER host name is refused ($(head -c 100 "$T/tls2.out"))" || bad "host name not checked: $(cat "$T/tls2.out")"
[ "$(wc -l < "$T/req.log")" = "$BEFORE" ] && ok "... and nothing was sent" || bad "a request reached the wrong-name server"
serve good

# ---- failures that are not the server's answer ------------------------------------------------------------------------------------------------
: > "$T/t.out"; GEMINI_API_KEY=k "$ENG" gemini --model m --prompt-file "$T/p_slow.txt" --out "$T/t.out" --base "https://localhost:$PORT" --ca-file "$T/good.pem" --timeout 2
grep -q "timed out" "$T/t.out" && ok "a server that does not answer in time: the call ends with a timeout line (${SECONDS}s into the test)" || bad "timeout: $(cat "$T/t.out")"
sleep 5; serve good
kill "$(cat "$T/server.pid")" 2>/dev/null; sleep 0.5
: > "$T/n1.out"; : > "$T/n2.out"
bashpath "$T/p_ok1.txt" "$T/n1.out" 2>/dev/null; enginepath "$T/p_ok1.txt" "$T/n2.out" 2>/dev/null
[ "$(cat "$T/n1.out")" = "[GEMINI ERROR] " ] && ok "no server, Bash path: '[GEMINI ERROR] ' with no reason (as before)" || bad "bash no server: $(cat "$T/n1.out")"
grep -q "^\[GEMINI ERROR\] connection failed" "$T/n2.out" && ok "no server, engine: the reason is said ($(cat "$T/n2.out"))" || bad "engine no server: $(cat "$T/n2.out")"
# missing key: both paths leave it to the loop's own message; the engine itself refuses (exit 2) rather than sending nothing useful
KEY= bashpath "$T/p_ok1.txt" "$T/k1.out" 2>/dev/null; grep -q "No API key" "$T/k1.out" && ok "no key: the loop's own message (the engine is not even asked)" || bad "no key: $(cat "$T/k1.out" 2>/dev/null)"
env -u GEMINI_API_KEY "$ENG" gemini --model m --prompt-file "$T/p_ok1.txt" --out "$T/k2.out" >/dev/null 2>&1; [ $? -eq 2 ] && [ ! -s "$T/k2.out" ] && ok "the engine without a key: exit 2, nothing written" || bad "engine without key"
# an engine that does not know the command (an older build) -> the Bash path answers
printf '#!/bin/bash\necho "unknown command: $1" >&2\nexit 2\n' > "$T/oldengine"; chmod +x "$T/oldengine"
serve good
: > "$T/f.out"; COCKPIT_ENGINE=1 COCKPIT_ENGINE_BIN="$T/oldengine" bash "$T/run.sh" "$T/p_ok1.txt" "$T/f.out" 2>/dev/null
[ "$(cat "$T/f.out")" = "Hello there" ] && ok "an engine that refuses (exit 2): the Bash path answers" || bad "fallback: $(cat "$T/f.out")"
echo "gemini_parity: $n passed, $fails failure(s)"
exit $((fails>0))
