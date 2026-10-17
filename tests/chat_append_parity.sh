#!/usr/bin/env bash
# =============================================================================
# chat_append_parity.sh — does `history_cli.php append` write the same chat file as append_to_chat in agent_loop.sh?
#
# append_to_chat is extracted verbatim from agent_loop.sh and run twice on identical copies of a chat (one scenario
# per fixture / text / argument combination): with the switch off (awk, sed, bc, mktemp, python3, sqlite3 — what every
# install runs today) and with it on (the same function, which hands the work to history_cli.php). Compared: the chat
# file byte for byte, its mode, the SQLite index each side built, and what was printed.
#
#   bash tests/chat_append_parity.sh      (needs the Bash's own tools: sqlite3 with FTS5, python3, bc, awk, sed, flock, php, jq)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"; AL="$SCRIPTS/agent_loop.sh"
for t in sqlite3 python3 bc awk sed flock php; do command -v "$t" >/dev/null 2>&1 || { echo "needs $t"; exit 2; }; done
sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(x);' >/dev/null 2>&1 || { echo "sqlite3 without FTS5"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1${2:+  — $2}"; FAIL=$((FAIL+1)); }

fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" { if ($0 ~ /\}[[:space:]]*$/ && $0 !~ /\{[[:space:]]*(#.*)?$/) { print; exit } p=1 } p {print} p && /^}/ {exit}' "$AL"; }
{
  echo 'log() { :; }'
  grep -m1 '^if sed --version' "$AL"
  for f in sedi stat_gid sq chat_index_db chat_index_ready chat_index_init chat_index_extract chat_index_count_json chat_index_count_db \
           chat_index_sync chat_index_add engine_bin engine_enabled history_cli; do fn "$f"; done
  # append_to_chat holds here-documents whose JSON closes with a lone } at column 0: end it at the } after its flock subshell
  awk '/^append_to_chat\(\) *\{/ {p=1} p {print} p && /200>"\$\{CHAT_FILE\}\.lock"/ {seen=1} p && seen && /^}/ {exit}' "$AL"
} > "$T/fns.sh"
for f in append_to_chat chat_index_sync chat_index_add history_cli; do grep -q "^$f()" "$T/fns.sh" || { echo "could not extract $f"; exit 2; }; done
bash -n "$T/fns.sh" || { echo "extracted functions do not parse"; exit 2; }
# a fixed clock for the Bash side (the PHP side reads CHAT_CLI_NOW)
mkdir -p "$T/shim"; printf '#!/bin/sh\nif [ "$1" = "-u" ]; then echo "2026-10-05T12:00:00Z"; else exec /bin/date "$@"; fi\n' > "$T/shim/date"; chmod +x "$T/shim/date"
export CHAT_CLI_NOW="2026-10-05T12:00:00Z"

# ---- fixtures: chat files in the formats the loop meets ----
cat > "$T/gen.php" <<'PHP'
<?php
$o = $argv[1]; @mkdir("$o/proj", 0775, true);
function ex(int $i, string $role, string $text): string {
    $esc = substr(json_encode($text, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 1, -1);
    $b = "    {\n      \"id\": $i,\n      \"timestamp\": \"2026-10-01T10:00:00Z\",\n      \"role\": \"$role\",\n";
    if ($role === 'agent') $b .= "      \"agent\": \"claude\",\n      \"supplier\": \"claude\",\n      \"model\": \"m1\",\n      \"duration_s\": 1.5,\n      \"style\": \"\",\n      \"mode\": \"\",\n";
    return $b . "      \"text\": \"$esc\"\n    }";
}
function loopfile(array $items, string $close = '  ]'): string {
    return "{\n  \"schema_version\": 1,\n  \"project\": \"proj\",\n  \"chat\": \"x\",\n  \"created\": \"2026-10-01T10:00:00Z\",\n  \"updated\": \"2026-10-01T10:00:00Z\",\n  \"exchanges\": [\n" . implode(",\n", $items) . ($items ? "\n" : '') . "$close\n}\n";
}
$two = [ex(1, 'user', 'hello there'), ex(2, 'agent', "hi!\nsecond line with \"quotes\"")];
$six = []; for ($i = 1; $i <= 6; $i++) $six[] = ex($i, $i % 2 ? 'user' : 'agent', "turn $i about postgres replication");
file_put_contents("$o/proj/chat_two.json", loopfile($two));
file_put_contents("$o/proj/chat_six.json", loopfile($six));
file_put_contents("$o/proj/chat_empty_pretty.json", loopfile([]));
file_put_contents("$o/proj/chat_empty_oneline.json", "{\n  \"schema_version\": 1,\n  \"project\": \"proj\",\n  \"exchanges\": [],\n  \"updated\": \"2026-10-01T10:00:00Z\"\n}\n");
file_put_contents("$o/proj/chat_empty_oneline_nocomma.json", "{\n  \"schema_version\": 1,\n  \"updated\": \"2026-10-01T10:00:00Z\",\n  \"exchanges\": []\n}\n");
file_put_contents("$o/proj/chat_empty_oneline_spaces.json", "{\n  \"updated\":   \"2026-10-01T10:00:00Z\",\n  \"exchanges\":   []   \n}\n");
// what combos_core.php writes with PHP's pretty printer: exchanges followed by another key, so the array closes as `],`
$php = ['schema_version' => 1, 'project' => 'proj', 'chat' => 'x', 'created' => '2026-10-01T10:00:00Z', 'exchanges' => [['id' => 1, 'timestamp' => 't', 'role' => 'user', 'text' => 'from php'], ['id' => 2, 'timestamp' => 't', 'role' => 'agent', 'agent' => 'claude', 'text' => 'reply']], 'updated' => '2026-10-01T10:00:00Z'];
file_put_contents("$o/proj/chat_phpstyle.json", json_encode($php, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
$php['exchanges'] = [];
file_put_contents("$o/proj/chat_phpstyle_empty.json", json_encode($php, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
file_put_contents("$o/proj/chat_zero.json", '');
file_put_contents("$o/proj/chat_nobracket.json", "{\n  \"schema_version\": 1,\n  \"exchanges\": [\n    {\"id\": 1, \"role\": \"user\", \"text\": \"x\"}\n}\n");
file_put_contents("$o/proj/chat_nonl.json", rtrim(loopfile($two), "\n"));
file_put_contents("$o/proj/chat_crlf.json", str_replace("\n", "\r\n", loopfile($two)));
// an old file with raw newlines inside strings (not valid JSON)
file_put_contents("$o/proj/chat_raw.json", "{\n  \"schema_version\": 1,\n  \"exchanges\": [\n    {\n      \"id\": 1,\n      \"role\": \"user\",\n      \"text\": \"raw\nnewline\ninside\"\n    },\n    {\n      \"id\": 2,\n      \"role\": \"agent\",\n      \"agent\": \"claude\",\n      \"text\": \"also\nraw\"\n    }\n  ],\n  \"updated\": \"2026-10-01T10:00:00Z\"\n}\n");
file_put_contents("$o/proj/chat__scratch.json", loopfile([]));
PHP
mkdir -p "$T/seed"; php "$T/gen.php" "$T/seed" || { echo "fixtures failed"; exit 2; }

newroot() { rm -rf "$1"; mkdir -p "$1"; cp -a "$T/seed/proj" "$1/proj"; }
dump() { [ -f "$1/.chat_index.db" ] || { echo "(no index)"; return; }; sqlite3 -separator '|' "$1/.chat_index.db" "SELECT chat,id,role,agent,ts,body FROM ex ORDER BY chat,id,rowid;" 2>&1 | sed "s|$1|ROOT|g"; }
side() {   # side bash|php ROOT 'commands'
  local s="$1" root="$2" cmd="$3"
  ( export HOME="$T/home"; mkdir -p "$HOME"
    AGENT=claude; AGENT_UC=CLAUDE; CLI_SUPPLIER=claude; LOCAL_PROVIDER=""; SCRIPTS_DIR="$SCRIPTS"
    unset COCKPIT_ENGINE
    if [ "$s" = php ]; then export COCKPIT_ENGINE=1; else export PATH="$T/shim:$PATH"; fi
    . "$T/fns.sh"; ROOTDIR="$root"; eval "$cmd" ) > "$root/stdout" 2> "$root/stderr"
  echo $? > "$root/rc"
}
txt() { printf '%s' "$2" > "$T/txt_$1"; }          # txt NAME CONTENT
both() {   # both NAME 'commands using $ROOTDIR' — run on both sides, compare the chat dir, the index and the output
  local name="$1" cmd="$2"
  newroot "$T/A"; newroot "$T/B"
  side bash "$T/A" "$cmd"; side php "$T/B" "$cmd"
  sed -i "s|$T/A|ROOT|g" "$T/A/stdout" "$T/A/stderr"; sed -i "s|$T/B|ROOT|g" "$T/B/stdout" "$T/B/stderr"
  dump "$T/A" > "$T/A/dump"; dump "$T/B" > "$T/B/dump"
  local why="" f
  for f in $( (cd "$T/A/proj" && ls -A; cd "$T/B/proj" && ls -A) | sort -u ); do
    case "$f" in *.lock) continue ;; esac
    cmp -s "$T/A/proj/$f" "$T/B/proj/$f" || why="${why:+$why; }$f differs"
    [ "$(stat -c %a "$T/A/proj/$f" 2>/dev/null)" = "$(stat -c %a "$T/B/proj/$f" 2>/dev/null)" ] || why="${why:+$why; }$f mode differs ($(stat -c %a "$T/A/proj/$f" 2>/dev/null) vs $(stat -c %a "$T/B/proj/$f" 2>/dev/null))"
  done
  cmp -s "$T/A/dump" "$T/B/dump" || why="${why:+$why; }index differs"
  cmp -s "$T/A/stdout" "$T/B/stdout" || why="${why:+$why; }stdout differs"
  [ "$(cat "$T/A/rc")" = "$(cat "$T/B/rc")" ] || why="${why:+$why; }rc $(cat "$T/A/rc") vs $(cat "$T/B/rc")"
  if [ -z "$why" ]; then ok "$name"; else bad "$name" "$why"; if [ "${VERBOSE:-0}" = 1 ]; then for f in $(cd "$T/A/proj" && ls -A | grep -v lock); do diff "$T/A/proj/$f" "$T/B/proj/$f" 2>&1 | head -8; done; diff "$T/A/dump" "$T/B/dump" | head -6; fi; fi
}
# the standard call: append TEXTNAME_USER TEXTNAME_AGENT [model] [duration] [style] [mode] on chat C (default chat_two)
ap() { local c="${1:-chat_two}" u="${2:-u1}" a="${3:-a1}" m="${4-claude-sonnet-4-6}" d="${5-3.2}" st="${6-}" md="${7-}"; echo "append_to_chat \"\$ROOTDIR/proj/$c.json\" proj mychat \"$T/txt_$u\" \"$T/txt_$a\" $(printf '%q' "$m") $(printf '%q' "$d") $(printf '%q' "$st") $(printf '%q' "$md"); echo rc=\$?"; }
txt u1 "What is postgres replication lag?"; txt a1 $'It is the delay between the primary and a replica.\nTypical causes:\n- slow disks\n- long transactions'

echo; echo "== which chat files: every shape the loop meets"
for c in two six empty_pretty empty_oneline empty_oneline_nocomma empty_oneline_spaces phpstyle phpstyle_empty zero nobracket nonl crlf raw; do
  both "append to chat_$c" "$(ap chat_$c)"
done
both "a chat file that does not exist: created (directory too), then the turn appended" "append_to_chat \"\$ROOTDIR/newproj/sub/chat_new.json\" 'My Project' 'my chat' \"$T/txt_u1\" \"$T/txt_a1\" m 1.5 '' ''; echo rc=\$?"
both "a new chat whose project name contains the word role (id and comma quirks)" "append_to_chat \"\$ROOTDIR/proj/chat_role.json\" role chat \"$T/txt_u1\" \"$T/txt_a1\" m 1.5 '' ''; echo rc=\$?"
both "a scratch chat (chat__*) is written but never indexed" "$(ap chat__scratch)"
both "three appends in a row: ids 1..6, index follows" "$(ap chat_empty_pretty); $(ap chat_empty_pretty); $(ap chat_empty_pretty)"
both "appends onto an existing chat whose index is behind (reconciled first, with its log line)" "chat_index_sync \"\$ROOTDIR/proj/chat_six.json\" >/dev/null; printf '%s' x >> /dev/null; sed -i 's/turn 3 about/turn 3 EDITED about/' \"\$ROOTDIR/proj/chat_six.json\"; php -r '\$f=\$argv[1]; \$d=json_decode(file_get_contents(\$f),true); array_pop(\$d[\"exchanges\"]); file_put_contents(\$f, json_encode(\$d, JSON_PRETTY_PRINT));' \"\$ROOTDIR/proj/chat_six.json\"; $(ap chat_six)"

echo; echo "== what gets written for different texts"
python3 - "$T" <<'PY'
import sys
T=sys.argv[1]
cases={
 'simple':'a plain answer','multi':'line one\nline two\n\nline four','quotes':'she said "hi" and it\'s fine',
 'backslash':'path C:\\temp\\new and a \\n that is two characters','tab':'tab\tseparated\tvalues','cr':'carriage\rreturn here',
 'ctrl':'bell\x07  ctrl\x01\x02\x1f  del\x7f  end','unicode':'שלום עולם ★ café 🙂 日本語','trailing':'ends with newlines\n\n\n',
 'leading':'\n\nstarts with newlines','dollar':'$(rm -rf /) `id` ${HOME} %%END%% 50%','dash_n':'-n','dash_e':'-e','dash_ne':'-ne',
 'dash_text':'-n and more','empty':'','spaces':'   ','json':'{"role": "user", "text": "x"}',
 'updated':'"updated": "evil" and "exchanges": [] and "role"','long':'lorem ipsum dolor sit amet '*8000,'nul':'before\x00after'}
for k,v in cases.items(): open(f'{T}/txt_t_{k}','wb').write(v.encode('utf-8'))
PY
for k in simple multi quotes backslash tab cr ctrl unicode trailing leading dollar dash_n dash_e dash_ne dash_text empty spaces json updated nul; do
  both "user text: $k" "$(ap chat_two t_$k a1)"
  both "agent text: $k" "$(ap chat_two u1 t_$k)"
done
# a 216 KB turn: the chat file must be identical. (The Bash then fails to add the row to the index — one SQL statement as a
# single 128 KB+ argument — which the next reconcile repairs; the PHP adds it. Only the file is compared, the PHP index is checked.)
for w in user agent; do
  newroot "$T/A"; newroot "$T/B"
  if [ $w = user ]; then c="$(ap chat_two t_long a1)"; else c="$(ap chat_two u1 t_long)"; fi
  side bash "$T/A" "$c"; side php "$T/B" "$c"
  if cmp -s "$T/A/proj/chat_two.json" "$T/B/proj/chat_two.json" && php -r '$d=json_decode(file_get_contents($argv[1]),true); exit(is_array($d) && count($d["exchanges"])===4 ? 0 : 1);' "$T/B/proj/chat_two.json" && [ "$(sqlite3 "$T/B/.chat_index.db" "SELECT count(*) FROM ex;")" = 4 ]; then ok "a 216 KB $w turn: identical chat file (4 exchanges, none lost); PHP index complete"; else bad "216 KB $w turn"; fi
done

echo; echo "== model, duration, style, mode, supplier"
for d in 3.2 .9 0 0.0 12 '' abc 1e3 -1 100.50 .0 5. '1.2.3'; do both "duration '$d'" "$(ap chat_two u1 a1 claude-x "$d")"; done
both "empty model -> null" "$(ap chat_two u1 a1 '' 2)"
both "model with quotes and backslash" "$(ap chat_two u1 a1 'my "model" \ v2' 2)"
both "model -n" "$(ap chat_two u1 a1 '-n' 2)"
both "style and mode with quotes" "$(ap chat_two u1 a1 m 2 'short "quoted" style' 'debug\mode')"
both "supplier from LOCAL_PROVIDER when CLI_SUPPLIER is empty" "CLI_SUPPLIER=''; LOCAL_PROVIDER=ollama; $(ap)"
both "supplier falls back to the agent name" "CLI_SUPPLIER=''; LOCAL_PROVIDER=''; AGENT=gemini; $(ap)"
both "another agent name goes in unescaped" "AGENT='weird\"agent'; $(ap)"

echo; echo "== concurrency: several writers on one chat (flock)"
for s in bash php; do
  r="$T/C_$s"; newroot "$r"; for i in 1 2 3 4 5 6; do mkdir -p "$r/w$i"; done
  for i in 1 2 3 4 5 6; do side "$s" "$r/w$i" "append_to_chat \"$r/proj/chat_empty_pretty.json\" proj c \"$T/txt_u1\" \"$T/txt_a1\" m 1 '' ''" & done
  wait
  php -r '$d=json_decode(file_get_contents($argv[1]),true); $ids=array_column($d["exchanges"],"id"); sort($ids); echo (is_array($d) && $ids===range(1,12)) ? "valid-12-unique" : "BAD:".json_encode($ids);' "$r/proj/chat_empty_pretty.json" > "$T/conc_$s"
  echo "|$(sqlite3 "$r/.chat_index.db" "SELECT count(*) FROM ex WHERE chat LIKE '%empty_pretty%';" 2>/dev/null)" >> "$T/conc_$s"
done
[ "$(cat "$T/conc_bash")" = "valid-12-unique|12" ] && [ "$(cat "$T/conc_php")" = "valid-12-unique|12" ] && ok "6 parallel appends: valid JSON, ids 1..12 unique, 12 index rows — both implementations" || bad "concurrent appends" "bash: $(cat "$T/conc_bash") php: $(cat "$T/conc_php")"

echo; echo "== the glue in append_to_chat"
newroot "$T/G"
# 1. helper missing -> Bash writes
side php "$T/G" "SCRIPTS_DIR=/nonexistent; $(ap chat_two)"
php -r '$d=json_decode(file_get_contents($argv[1]),true); echo count($d["exchanges"]);' "$T/G/proj/chat_two.json" > "$T/g1"
[ "$(cat "$T/g1")" = 4 ] && ok "switch on but history_cli.php missing: the Bash writes the turn (4 exchanges)" || bad "fallback, helper missing" "$(cat "$T/g1")"
# 2. helper exits 3 (nothing written) -> Bash writes
mkdir -p "$T/fake3"; printf '<?php exit(3);\n' > "$T/fake3/history_cli.php"; newroot "$T/G"
side php "$T/G" "SCRIPTS_DIR=$T/fake3; $(ap chat_two)"
php -r '$d=json_decode(file_get_contents($argv[1]),true); echo count($d["exchanges"]);' "$T/G/proj/chat_two.json" > "$T/g2"
[ "$(cat "$T/g2")" = 4 ] && ok "helper exits 3 (nothing written): the Bash writes the turn, once" || bad "fallback on exit 3" "$(cat "$T/g2")"
# 3. helper exits 7 (may have written) -> NOT retried
mkdir -p "$T/fake7"; printf '<?php exit(7);\n' > "$T/fake7/history_cli.php"; newroot "$T/G"
side php "$T/G" "SCRIPTS_DIR=$T/fake7; $(ap chat_two)"
php -r '$d=json_decode(file_get_contents($argv[1]),true); echo count($d["exchanges"]);' "$T/G/proj/chat_two.json" > "$T/g3"
[ "$(cat "$T/g3")" = 2 ] && grep -q "NOT retrying" "$T/G/stdout" && ok "helper exits 7 (may have written): the Bash does NOT write again; it says so" || bad "no retry on exit 7" "$(cat "$T/g3") $(cat "$T/G/stdout")"
# 4. the real thing writes exactly one turn
newroot "$T/G"; side php "$T/G" "$(ap chat_two)"
php -r '$d=json_decode(file_get_contents($argv[1]),true); echo count($d["exchanges"]);' "$T/G/proj/chat_two.json" > "$T/g4"
[ "$(cat "$T/g4")" = 4 ] && ok "switch on: one turn written (4 exchanges), no duplicate" || bad "double write" "$(cat "$T/g4")"

echo; echo "chat append parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
