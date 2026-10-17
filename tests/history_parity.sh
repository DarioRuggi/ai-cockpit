#!/usr/bin/env bash
# =============================================================================
# history_parity.sh — is scripts/history_cli.php the same as the Bash it replaces?
#
# agent_loop.sh's OWN history functions (needs_history, build_history, chat_index_sync, chat_index_add and everything
# they call) are extracted verbatim and run twice on identical inputs, in two separate copies of the same chat files:
#     engine OFF -> the Bash path (sqlite3 CLI, jq, awk, sed, python3 — what every install runs today)
#     engine ON  -> the same functions, which now hand the work to history_cli.php
# Compared: standard output, the log lines on standard error, the return code, and the full contents of the SQLite
# index each side built. Needs everything the Bash needs: sqlite3 (with FTS5), jq, python3, awk, flock, php.
#
#   bash tests/history_parity.sh
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"
AL="$SCRIPTS/agent_loop.sh"
for t in sqlite3 jq python3 awk flock php; do command -v "$t" >/dev/null 2>&1 || { echo "needs $t (the Bash reference uses it)"; exit 2; }; done
sqlite3 :memory: 'CREATE VIRTUAL TABLE t USING fts5(x);' >/dev/null 2>&1 || { echo "sqlite3 without FTS5"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1${2:+  — $2}"; FAIL=$((FAIL+1)); }

# ---- the Bash functions, verbatim ----
fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" { if ($0 ~ /\}[[:space:]]*$/ && $0 !~ /\{[[:space:]]*(#.*)?$/) { print; exit } p=1 } p {print} p && /^}/ {exit}' "$AL"; }
{
  echo 'log() { :; }'
  echo 'HISTORY_RELEVANT=4'
  for f in stat_gid history_user_text needs_history sq chat_index_db chat_index_ready chat_index_init chat_index_extract chat_index_count_json \
           chat_index_count_db chat_index_sync chat_index_add history_mode history_terms history_select_ids _history_in \
           render_history_inline render_history_json render_history_pointer build_history read_history read_history_json \
           engine_bin engine_enabled history_cli; do fn "$f"; done
} > "$T/fns.sh"
for f in needs_history build_history chat_index_sync chat_index_add history_cli read_history read_history_json; do grep -q "^$f()" "$T/fns.sh" || { echo "could not extract $f"; exit 2; }; done
bash -n "$T/fns.sh" || { echo "extracted functions do not parse"; exit 2; }

# ---- fixtures: chats in the loop's own file format ----
cat > "$T/gen.php" <<'PHP'
<?php
// gen.php OUTDIR : writes the fixture chats under OUTDIR/proj/
$o = $argv[1]; @mkdir("$o/proj", 0775, true);
function chat(string $path, array $exs, string $style = 'pretty'): void {
    $out = "{\n  \"schema_version\": 1,\n  \"project\": \"proj\",\n  \"chat\": \"x\",\n  \"created\": \"2026-10-01T10:00:00Z\",\n  \"updated\": \"2026-10-01T10:00:00Z\",\n  \"exchanges\": [\n";
    $items = [];
    foreach ($exs as $i => [$role, $agent, $text]) {
        $id = $i + 1;
        $esc = function (string $s) use ($style) {
            if ($style === 'raw') return str_replace(['\\', '"'], ['\\\\', '\\"'], $s);          // old loops: real newlines inside the string
            return substr(json_encode($s, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES), 1, -1);   // the loop's json_escape: \n \t \" \\
        };
        $b = "    {\n      \"id\": $id,\n      \"timestamp\": \"2026-10-01T10:" . sprintf('%02d', $i) . ":00Z\",\n      \"role\": \"$role\",\n";
        if ($role === 'agent') $b .= "      \"agent\": \"$agent\",\n      \"supplier\": \"$agent\",\n      \"model\": \"m1\",\n      \"duration_s\": 1.5,\n      \"style\": \"\",\n      \"mode\": \"\",\n";
        $b .= "      \"text\": \"" . $esc($text) . "\"\n    }";
        $items[] = $b;
    }
    $out .= implode(",\n", $items) . "\n  ]\n}\n";
    file_put_contents($path, $out);
}
$topics = ['postgres replication lag', 'kubernetes ingress annotations', 'sourdough hydration ratio', 'rust borrow checker lifetimes', 'tax deductions home office', 'guitar chord voicings', 'photosynthesis light reactions', 'bitcoin lightning channels'];
$exs = [];
for ($i = 0; $i < 30; $i++) {
    $t = $topics[$i % 8];
    $exs[] = ['user', '', "Question $i about $t, please explain the details of $t and how it works in practice"];
    $exs[] = ['agent', ['claude', 'gemini', 'ollama'][$i % 3], "Answer $i: here is a long explanation of $t.\nIt has several lines.\n\tand a tab\nand \"quotes\" and a backslash \\ and unicode שלום ★\n- item one\n- item two"];
}
chat("$o/proj/chat_long.json", $exs);
chat("$o/proj/chat_short.json", array_slice($exs, 0, 2));
chat("$o/proj/chat_one.json", [['user', '', 'only a user turn about postgres replication']]);
chat("$o/proj/chat_empty.json", []);
chat("$o/proj/chat_raw.json", array_slice($exs, 0, 8), 'raw');
$big = $exs; $big[5] = ['agent', 'claude', str_repeat('lorem ipsum dolor sit amet ', 120) . ' END'];
chat("$o/proj/chat_big.json", array_slice($big, 0, 12));
$odd = [['user', '', "text with trailing newline\n"], ['agent', 'claude', "ends with blank lines\n\n"], ['user', '', "tab\there and \x1f unit sep"], ['agent', 'qwen', 'plain']];
chat("$o/proj/chat_odd.json", $odd);
file_put_contents("$o/proj/chat__scratch.json", "{}\n");
PHP
mkdir -p "$T/seed"; php "$T/gen.php" "$T/seed" || { echo "fixture generation failed"; exit 2; }
# optional: real chat files (REAL_CHATS="/path/a.json /path/b.json"), copied — never modified — and compared the same way.
# Only match/mismatch is printed; the content stays on this machine.
RC=0; for f in ${REAL_CHATS:-}; do RC=$((RC+1)); cp "$f" "$T/seed/proj/chat_real$RC.json"; done

# ---- running one scenario on both sides ----
newroot() { rm -rf "$1"; mkdir -p "$1"; cp -a "$T/seed/proj" "$1/proj"; }
dump() {   # dump ROOT -> normalised index contents
  [ -f "$1/.chat_index.db" ] || { echo "(no index)"; return; }
  sqlite3 -separator '|' "$1/.chat_index.db" "SELECT chat,id,role,agent,ts,body FROM ex ORDER BY chat,id,rowid;" 2>&1 | sed "s|$1|ROOT|g"
}
# side SIDE(bash|php) ROOT 'command using the functions'
side() {
  local s="$1" root="$2" cmd="$3"
  ( export HOME="$T/home"; mkdir -p "$HOME"
    AGENT=claude; AGENT_UC=CLAUDE; CLI_SUPPLIER=claude; MAX_HISTORY=6; SCRIPTS_DIR="$SCRIPTS"
    unset COCKPIT_ENGINE COCKPIT_HISTORY COCKPIT_HISTORY_MODE HISTORY_CLI_NO_INDEX
    [ "$s" = php ] && export COCKPIT_ENGINE=1
    for kv in ${EXTRA_ENV:-}; do export "$kv"; done
    . "$T/fns.sh"
    [ -n "${FORCE_NO_INDEX:-}" ] && { chat_index_ready() { return 1; }; export HISTORY_CLI_NO_INDEX=1; }
    ROOTDIR="$root"; eval "$cmd" ) > "$root/stdout" 2> "$root/stderr"
  echo $? > "$root/rc"
}
both() {   # both NAME 'command with $ROOTDIR' [setup-command run on each root before]
  local name="$1" cmd="$2" setup="${3:-}"
  newroot "$T/A"; newroot "$T/B"
  if [ -n "$setup" ]; then ( ROOTDIR="$T/A"; eval "$setup" ) >/dev/null 2>&1; ( ROOTDIR="$T/B"; eval "$setup" ) >/dev/null 2>&1; fi
  side bash "$T/A" "$cmd"; side php "$T/B" "$cmd"
  sed -i "s|$T/A|ROOT|g" "$T/A/stdout" "$T/A/stderr"; sed -i "s|$T/B|ROOT|g" "$T/B/stdout" "$T/B/stderr"
  dump "$T/A" > "$T/A/dump"; dump "$T/B" > "$T/B/dump"
  local why=""
  cmp -s "$T/A/stdout" "$T/B/stdout" || why="stdout differs ($(wc -c < "$T/A/stdout") vs $(wc -c < "$T/B/stdout") bytes)"
  cmp -s "$T/A/stderr" "$T/B/stderr" || why="${why:+$why; }log lines differ"
  [ "$(cat "$T/A/rc")" = "$(cat "$T/B/rc")" ] || why="${why:+$why; }rc $(cat "$T/A/rc") vs $(cat "$T/B/rc")"
  cmp -s "$T/A/dump" "$T/B/dump" || why="${why:+$why; }index contents differ"
  if [ -z "$why" ]; then ok "$name"; else bad "$name" "$why"; if [ "${VERBOSE:-0}" = 1 ]; then for f in stdout stderr dump; do diff "$T/A/$f" "$T/B/$f" | head -6; done; fi; fi
}
LONG='$ROOTDIR/proj/chat_long.json'

echo; echo "== the gate (needs_history): decision, log line and return code"
gate() { local p="$1"; both "gate: $(printf '%s' "$p" | head -c 60 | tr '\n' '~')" "needs_history $(printf '%q' "$p"); echo \"rc=\$?\""; }
gate "hi"
gate "why?"
gate "and you?"
gate "Write a script that lists all the files in a directory sorted by size and prints a total at the end"
gate "[CHAT MODE] Answer conversationally.
Write a script that lists all the files in a directory sorted by size and prints a total at the end"
gate "Write a script that lists all the files in a directory sorted by size (Now: 2026-10-05 19:30 IDT) and prints the sizes"
gate "Please write a function that parses a configuration file and returns a dictionary of the settings it finds"
gate "Please write a function that parses a configuration file and so on, and then the rewrite of it as well please"
gate "ok please write a function that parses a configuration file and returns a dictionary of settings"
gate "Please write a function that parses a configuration file and returns a dictionary of the settings it finds
and then also explain how it works in detail"
gate "I looked at the code you wrote and the function does not handle the empty input case at all really"
gate "Can you explain what we discussed about kubernetes earlier in this conversation please"
gate "Summarize this chat for me, covering the main points raised by everyone here in the thread"
gate "Please write a long poem about the sea and the sky and the many moods of the weather in autumn"
gate "Please write a long poem about the sea and the sky and the many moods of the weather in autumn,
and keep the same style as before"
gate "What was the topic again of the thing we were looking at, remind me of the details please ok"
gate "Describe the architecture of a distributed system with many nodes that replicate data between them"
gate "As we said, the replication of data between nodes needs a quorum for writes to be considered safe"
gate "TOO MANY CAPS: THIS IS A VERY LONG QUESTION ABOUT NOTHING IN PARTICULAR BUT IT HAS EIGHT WORDS"
gate "שלום מה שלומך היום אני רוצה לשאול שאלה ארוכה מאוד על נושא חדש לגמרי שלא דיברנו עליו"
gate "Implement a binary tree in Rust with insertion deletion and traversal functions and unit tests for each"
gate "the file system layout of a typical linux machine has directories like etc usr var and home each one"
gate "Tell me everything about photosynthesis, I mean the light reactions and the Calvin cycle in detail now"
gate "[DEBUG MODE] x"
gate $'one two three four five six seven eight \x01\x02 \x7f nine ten'
gate $'a\x01b c d e f g h i'
gate $'bad \xff\xfe bytes \xc3 end of the long prompt here ok yes'
gate $'one\xc2\xa0two\xc2\xa0three four five six seven eight'
gate $'one\xe3\x80\x80two three four five six seven eight nine'
gate $'word \xe2\x80\x8b zero-width space here and some more words to reach eight'
gate "[chat mode] Write a script that lists all the files in a directory sorted by size and prints it all"
for m in always never; do
  both "gate with COCKPIT_HISTORY=$m" "COCKPIT_HISTORY=$m needs_history 'a long self contained question that would normally be skipped by the gate entirely ok'; echo rc=\$?"
done

echo; echo "== selective history: index, query, ids, inline transcript (chat of 30 exchanges)"
bh() { both "build text: $1" "build_history \"$LONG\" $(printf '%q' "$2") text; echo rc=\$?" "${3:-}"; }
bh "keyword match (postgres replication)" "What was the postgres replication lag thing we saw earlier?"
bh "two topics" "compare the kubernetes ingress and the sourdough hydration we covered before"
bh "no content words (only stop words)" "what about that one again?"
bh "words that match nothing" "zyxwvut qwertyu asdfghj"
bh "FTS punctuation in the prompt cannot become syntax" "what about \"postgres\" AND (replication OR NOT lag) NEAR/3 * ?"
bh "prompt with style prefix and timestamp" "[CHAT MODE] Be brief.
Tell me about the bitcoin lightning channels (Now: 2026-10-05 20:00 IDT) we looked at"
bh "uppercase and punctuation in terms" "KUBERNETES, Ingress; annotations!!!"
bh "stemming (porter): replicating -> replication" "replicating postgres"
bh "last pairs win under the cap" "kubernetes sourdough guitar photosynthesis bitcoin postgres rust taxes"
echo; echo "== modes and formats"
both "pointer mode: last pair inline + ids + the jq line" "COCKPIT_HISTORY_MODE=pointer build_history \"$LONG\" 'recap the postgres replication lag issue we had' text; echo rc=\$?"
both "pointer mode on a one-turn chat (n=1)" "COCKPIT_HISTORY_MODE=pointer build_history \"\$ROOTDIR/proj/chat_one.json\" 'postgres replication' text; echo rc=\$?"
both "pointer mode on a two-exchange chat (no 'rest')" "COCKPIT_HISTORY_MODE=pointer build_history \"\$ROOTDIR/proj/chat_short.json\" 'postgres replication lag' text; echo rc=\$?"
both "auto mode picks pointer for the Claude CLI on the primary card" "build_history \"$LONG\" 'recap the postgres replication lag issue' text; echo rc=\$?"
both "auto mode picks inline for another agent" "AGENT=gemini; CLI_SUPPLIER=gemini; build_history \"$LONG\" 'recap the postgres replication lag issue' text; echo rc=\$?"
both "json messages array (Ollama /api/chat)" "build_history \"$LONG\" 'what about the kubernetes ingress annotations' json; echo rc=\$?"
both "json: embedded quotes, backslash, tab, unicode, newlines in turns" "build_history \"\$ROOTDIR/proj/chat_short.json\" 'explain postgres replication lag details' json; echo rc=\$?"
both "text longer than 1500 characters is truncated" "build_history \"\$ROOTDIR/proj/chat_big.json\" 'lorem ipsum dolor' text; echo rc=\$?"
both "json: truncation is NOT applied (jq path)" "build_history \"\$ROOTDIR/proj/chat_big.json\" 'lorem ipsum dolor' json; echo rc=\$?"
both "trailing newlines / tabs / unit separator in turns" "build_history \"\$ROOTDIR/proj/chat_odd.json\" 'text with trailing newline' text; echo rc=\$?"
both "json for the odd chat" "build_history \"\$ROOTDIR/proj/chat_odd.json\" 'plain' json; echo rc=\$?"

echo; echo "== chats the index has to cope with"
both "an old chat with RAW newlines inside strings (not valid JSON): lenient extractor" "build_history \"\$ROOTDIR/proj/chat_raw.json\" 'what about the kubernetes ingress annotations' text; echo rc=\$?"
both "...and as JSON messages" "build_history \"\$ROOTDIR/proj/chat_raw.json\" 'explain postgres replication lag' json; echo rc=\$?"
both "a chat with no exchanges: whole tail, nothing to say" "build_history \"\$ROOTDIR/proj/chat_empty.json\" 'anything at all here' text; echo rc=\$?"
both "a chat file that does not exist" "build_history \"\$ROOTDIR/proj/nope.json\" 'anything' text; echo rc=\$?"
both "a one-turn chat (user only)" "build_history \"\$ROOTDIR/proj/chat_one.json\" 'postgres replication again' text; echo rc=\$?"
both "scratch chats (chat__*) are never indexed by add" "chat_index_add \"\$ROOTDIR/proj/chat__scratch.json\" 1 user '' 2026-10-05T10:00:00Z 'hello'; echo rc=\$?"

echo; echo "== reconcile: the index follows the JSON"
both "second call: counts agree, no rebuild, same answer" "build_history \"$LONG\" 'postgres replication' text >/dev/null 2>&1; build_history \"$LONG\" 'postgres replication' text; echo rc=\$?"
EDIT='sed -i "s/Question 3 about/Question 3 EDITED about/" "$ROOTDIR/proj/chat_long.json"; php -r '"'"'$f=$argv[1]; $d=json_decode(file_get_contents($f),true); array_pop($d["exchanges"]); array_pop($d["exchanges"]); file_put_contents($f, json_encode($d, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));'"'"' "$ROOTDIR/proj/chat_long.json"'
both "the chat shrank by two turns behind the index's back: rebuilt, with the log line" "build_history \"$LONG\" 'postgres replication' text >/dev/null 2>&1; $EDIT; build_history \"$LONG\" 'postgres replication' text; echo rc=\$?"
both "sync alone, from scratch (JSON path)" "chat_index_sync \"$LONG\"; echo rc=\$?"
both "sync alone, from scratch (raw-newline regex path: values stay as written)" "chat_index_sync \"\$ROOTDIR/proj/chat_raw.json\"; echo rc=\$?"
both "sync of every fixture, one index" "for c in long short one empty raw big odd; do chat_index_sync \"\$ROOTDIR/proj/chat_\$c.json\"; done; echo rc=\$?"

echo; echo "== chat_index_add (the fast path after an append)"
both "add: plain, multi-line, trailing newline, tabs, quotes" "for i in 1 2 3 4 5; do :; done
chat_index_sync \"\$ROOTDIR/proj/chat_empty.json\"
chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 1 user '' 2026-10-05T10:00:00Z 'plain text about postgres'
chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 2 agent claude 2026-10-05T10:00:01Z \$'line one\nline two\n\ttabbed and \"quoted\" and it\\'s'
chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 3 user '' 2026-10-05T10:00:02Z \$'ends with newline\n'
chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 4 agent gemini 2026-10-05T10:00:03Z \$'two\n\nblank lines\n\n'
chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 5 user '' 2026-10-05T10:00:04Z 'unit sep'\$'\x1f'here
chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 6 agent claude 2026-10-05T10:00:05Z 'שלום עולם ★ émoji 🙂'
echo rc=\$?"
both "add then build: the new turns are found" "chat_index_sync \"\$ROOTDIR/proj/chat_empty.json\"; chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 1 user '' 2026-10-05T10:00:00Z 'discuss the zebra migration routes'; chat_index_add \"\$ROOTDIR/proj/chat_empty.json\" 2 agent claude 2026-10-05T10:00:01Z 'zebras migrate across the plains'; build_history \"\$ROOTDIR/proj/chat_empty.json\" 'what about the zebra migration' text; echo rc=\$?"

echo; echo "== whole-tail fallbacks (no index): read_history (awk) and read_history_json (python3)"
export FORCE_NO_INDEX=1
both "no index, text: the awk reader" "build_history \"$LONG\" 'anything' text; echo rc=\$?"
both "no index, json: the python reader" "build_history \"$LONG\" 'anything' json; echo rc=\$?"
both "no index, text, odd turns (tabs, quotes, unicode)" "build_history \"\$ROOTDIR/proj/chat_short.json\" 'anything' text; echo rc=\$?"
both "no index, json, odd turns" "build_history \"\$ROOTDIR/proj/chat_short.json\" 'anything' json; echo rc=\$?"
both "no index, json, the raw-newline chat" "build_history \"\$ROOTDIR/proj/chat_raw.json\" 'anything' json; echo rc=\$?"
both "no index, text, the truncated 1500+ char turn" "build_history \"\$ROOTDIR/proj/chat_big.json\" 'anything' text; echo rc=\$?"
both "no index, empty chat" "build_history \"\$ROOTDIR/proj/chat_empty.json\" 'anything' text; echo rc=\$?"
unset FORCE_NO_INDEX

if [ "$RC" -gt 0 ]; then
  echo; echo "== real chat files ($RC), every format and mode"
  for i in $(seq 1 $RC); do
    for p in "what did we decide about the main topic earlier" "tell me about the installer and the apache config we looked at" "zebra"; do
      both "real chat $i, text, prompt: ${p:0:24}…" "build_history \"\$ROOTDIR/proj/chat_real$i.json\" $(printf '%q' "$p") text; echo rc=\$?"
      both "real chat $i, json, prompt: ${p:0:24}…" "build_history \"\$ROOTDIR/proj/chat_real$i.json\" $(printf '%q' "$p") json; echo rc=\$?"
      both "real chat $i, pointer, prompt: ${p:0:24}…" "COCKPIT_HISTORY_MODE=pointer build_history \"\$ROOTDIR/proj/chat_real$i.json\" $(printf '%q' "$p") text; echo rc=\$?"
    done
    FORCE_NO_INDEX=1 both "real chat $i, whole tail text (awk reader)" "build_history \"\$ROOTDIR/proj/chat_real$i.json\" 'x' text; echo rc=\$?"
    FORCE_NO_INDEX=1 both "real chat $i, whole tail json (python reader)" "build_history \"\$ROOTDIR/proj/chat_real$i.json\" 'x' json; echo rc=\$?"
  done
fi
echo; echo "== the glue"
# the helper cannot run -> the Bash path answers, with the same result
newroot "$T/A"; newroot "$T/B"
side bash "$T/A" "build_history \"$LONG\" 'postgres replication lag' text; echo rc=\$?"
side php "$T/B" "SCRIPTS_DIR=/nonexistent; build_history \"$LONG\" 'postgres replication lag' text; echo rc=\$?"
sed -i "s|$T/A|ROOT|g" "$T/A/stdout"; sed -i "s|$T/B|ROOT|g" "$T/B/stdout"
cmp -s "$T/A/stdout" "$T/B/stdout" && ok "engine ON but history_cli.php missing: the Bash path answers, identically" || bad "fallback when the helper is missing"
# the helper crashes -> Bash path answers
mkdir -p "$T/badscripts"; printf '<?php exit(7);\n' > "$T/badscripts/history_cli.php"
newroot "$T/B"; side php "$T/B" "SCRIPTS_DIR=$T/badscripts; build_history \"$LONG\" 'postgres replication lag' text; echo rc=\$?"
sed -i "s|$T/B|ROOT|g" "$T/B/stdout"
cmp -s "$T/A/stdout" "$T/B/stdout" && ok "the helper fails (exit 7): the Bash path answers, identically" || bad "fallback when the helper fails"
# needs: failure -> Bash decides
newroot "$T/B"; side php "$T/B" "SCRIPTS_DIR=$T/badscripts; needs_history 'hi'; echo rc=\$?"
grep -q "included (short prompt, 1 words)" "$T/B/stdout" && grep -q "rc=0" "$T/B/stdout" && ok "needs_history with a failing helper: the Bash gate decides" || bad "needs fallback" "$(cat "$T/B/stdout")"
# no php binary on PATH
newroot "$T/B"; side php "$T/B" "PATH=\$(dirname \$(command -v sqlite3)):\$(dirname \$(command -v jq)):/usr/bin/../bin; hash -r; history_cli >/dev/null; build_history \"$LONG\" 'postgres replication lag' text; echo rc=\$?"
[ -s "$T/B/stdout" ] && ok "with the switch on, the loop still answers (helper or fallback)" || bad "no output at all"

echo; echo "history parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
