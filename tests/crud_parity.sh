#!/usr/bin/env bash
# =============================================================================
# crud_parity.sh — is scripts/crud_cli.php the same as scripts/crud_executor.sh?
#
# Each scenario is an agent response (text with %%COMMANDS%%) run through BOTH implementations on identical copies of a
# project directory, against a mock web server that records every request. Compared: what is printed, the resulting
# file tree (names, types, modes, sizes, contents), and the requests sent to the endpoints (method, URL, decoded body).
# The deliberate differences are tested separately at the end.
#
#   bash tests/crud_parity.sh        (needs the Bash's own tools: jq, curl, awk, sed, php)
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SH="$HERE/../scripts/crud_executor.sh"; PHPCLI="${CRUD_PHP:-$HERE/../scripts/crud_cli.php}"
for t in jq curl awk sed php ls; do command -v "$t" >/dev/null 2>&1 || { echo "needs $t"; exit 2; }; done
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"; ENGOK=""; [ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " crud" && ENGOK=1
REFUSED=0; ODD=0; NOSH=""
T="$(mktemp -d)"; PORT=18955; MOCKPID=""
trap '[ -n "$MOCKPID" ] && kill "$MOCKPID" 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL  $1${2:+  — $2}"; FAIL=$((FAIL+1)); }

# ---- the mock web server: records requests, answers from files in $T/mock/ ----
mkdir -p "$T/mock"
cat > "$T/router.php" <<'PHP'
<?php
$dir = getenv('MOCK_DIR');
$body = file_get_contents('php://input');
$entry = ['ikey' => $_SERVER['HTTP_X_COCKPIT_INTERNAL'] ?? null, 'iuser' => $_SERVER['HTTP_X_COCKPIT_USER'] ?? null, 'method' => $_SERVER['REQUEST_METHOD'], 'uri' => $_SERVER['REQUEST_URI'], 'body' => $body === '' ? null : (json_decode($body, true) ?? ['_raw' => $body]), 'ctype' => $_SERVER['CONTENT_TYPE'] ?? null];
file_put_contents("$dir/requests.log", json_encode($entry, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . "\n", FILE_APPEND | LOCK_EX);
$path = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
$name = basename($path);                       // search.php, workers.php, tools.php, library.php, page.html
parse_str((string)parse_url($_SERVER['REQUEST_URI'], PHP_URL_QUERY), $q);
$key = $name . (isset($q['action']) ? '.' . $q['action'] : '');
$f = "$dir/resp_$key";
if (is_file($f)) { $c = file_get_contents($f); if (strpos($c, "STATUS:") === 0) { [$st, $c] = explode("\n", $c, 2); http_response_code((int)substr($st, 7)); } echo $c; exit; }
if (($name === 'page.html' || $name === 'page2.html') && is_file("$dir/resp_" . basename($name, '.html'))) {
    $c = file_get_contents("$dir/resp_" . basename($name, '.html'));
    if (strpos($c, "REDIRECT:") === 0) { [$l, $c] = explode("\n", $c, 2); header('Location: ' . substr($l, 9), true, 302); exit; }
    echo $c; exit;
}
http_response_code(404); echo '';
PHP
MOCK_DIR="$T/mock" php -S "127.0.0.1:$PORT" "$T/router.php" >/dev/null 2>&1 & MOCKPID=$!
for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$PORT/x" && break; sleep 0.1; done
export COCKPIT_BASE_URL="http://127.0.0.1:$PORT"
export COCKPIT_INTERNAL_KEY="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" COCKPIT_INTERNAL_USER="tester"      # the loop's credential: every side must send it to Cockpit's own pages
mock() { printf '%s' "$2" > "$T/mock/resp_$1"; }         # mock NAME CONTENT   (NAME like search.php.fetch)
mock_clear() { find "$T/mock" -name 'resp_*' -delete; : > "$T/mock/requests.log"; }

# ---- a fixture project, built identically for each side ----
mkproj() {   # mkproj DIR
  local d="$1"; rm -rf "$d"; mkdir -p "$d/src/sub" "$d/docs" "$d/empty" "$d/with space"
  printf 'hello world\n' > "$d/readme.txt"
  printf 'line1\nline2\n\nline4 no newline' > "$d/src/a.txt"
  printf 'x' > "$d/src/sub/deep.txt"
  head -c 20000 /dev/zero | tr '\0' 'a' > "$d/big.txt"
  printf 'שלום עולם ★ café\n' > "$d/unicode.txt"
  : > "$d/zero.txt"
  printf 'binary\x00bytes\n' > "$d/bin.dat"
  printf 'secret outside\n' > "$T/outside.txt"; mkdir -p "$T/outside_dir"; printf 'o\n' > "$T/outside_dir/f"
  ln -sfn "$T/outside_dir" "$d/linkdir"; ln -sfn "$T/outside.txt" "$d/linkfile"; ln -sfn "$d/readme.txt" "$d/inlink"; ln -sfn "$d/src" "$d/srclink"
  ln -sfn ../../../../etc "$d/escape"
  chmod 640 "$d/readme.txt"
  find "$d" -not -type l -exec touch -d '2026-01-15 10:30:00' {} + 2>/dev/null
  touch -h -d '2026-01-15 10:30:00' "$d"/linkdir "$d"/linkfile "$d"/inlink "$d"/srclink "$d"/escape 2>/dev/null
}
mkhome() {   # mkhome DIR: a cockpit_data with skills and a catalog
  local h="$1"; rm -rf "$h"; mkdir -p "$h/scripts/cockpit_data/skills/demo" "$h/scripts/cockpit_data/skills/nofm" "$h/scripts/cockpit_data/skills/unclosed" "$h/scripts/cockpit_data/library_text" "$h/user_data/library_text"
  printf -- '---\nname: demo\ndescription: d\n---\n# Demo skill\nbody line 1\nbody line 2\n---\nnot front matter\n' > "$h/scripts/cockpit_data/skills/demo/SKILL.md"
  printf 'no front matter here\nsecond\n' > "$h/scripts/cockpit_data/skills/nofm/SKILL.md"
  printf -- '---\nname: x\nnever closed\nbody\n' > "$h/scripts/cockpit_data/skills/unclosed/SKILL.md"
  head -c 20000 /dev/zero | tr '\0' 's' > "$h/scripts/cockpit_data/skills/big.md"; mkdir -p "$h/scripts/cockpit_data/skills/big"; mv "$h/scripts/cockpit_data/skills/big.md" "$h/scripts/cockpit_data/skills/big/SKILL.md"
  printf 'library text of lib1\nmore\n' > "$h/user_data/library_text/lib1.txt"
  cat > "$h/user_data/library_index.json" <<'JSON'
{"library":[{"id":"lib1","title":"Network Notes"},{"id":"lib2","title":"With File","file_path":"@HOME@/user_data/library_text/lib1.txt"},{"id":"lib3","title":"By URL","url":"@BASE@/page.html"},{"id":"lib4","title":"Empty Entry"}],
 "snippets":[{"id":"sn1","title":"Sort Helper","path":"@HOME@/user_data/library_text/lib1.txt"},{"id":"sn2","title":"Zebra Snippet"}],
 "sources":[{"id":"src1","title":"Docs Site","url":"@BASE@/page.html"}]}
JSON
  sed -i "s|@HOME@|$h|g; s|@BASE@|$COCKPIT_BASE_URL|g" "$h/user_data/library_index.json"
  printf '{"library":[{"id":"glob1","title":"Global Entry","file_path":"@HOME@/scripts/cockpit_data/library_text/g.txt"}]}\n' | sed "s|@HOME@|$h|g" > "$h/scripts/cockpit_data/library_index.json"
  printf 'global text\n' > "$h/scripts/cockpit_data/library_text/g.txt"
}

treedump() {   # treedump DIR -> names, types, modes, sizes, content hashes (symlink targets shown)
  ( cd "$1" && find . -printf '%p %y %m %l\n' | sort | sed "s|$T/outside|OUT|g"
    find . -type f -printf '%p %s\n' | sort
    find . -type f -exec md5sum {} + 2>/dev/null | sort -k2 )
}
# one scenario: both implementations on identical copies; $1 = name, response text on stdin
scn() {
  local name="$1" proposer="${2:-claude}" pname="${3:-myproj}"
  local resp="$T/resp.txt"; cat > "$resp"
  local out=() side
  local sides="sh php"; [ -n "$ENGOK" ] && sides="sh php eng"
  if [ -n "${NOSH:-}" ]; then if [ -n "$ENGOK" ]; then sides="php eng"; else return 0; fi; fi      # NOSH: cases only the native side has to match the PHP reference on
  for side in $sides; do
    local P="$T/proj_${side:0:1}" H="$T/home_${side:0:1}"
    mkproj "$P"; mkhome "$H"
    : > "$T/mock/requests.log"
    ( export HOME="$H" COCKPIT_DATA_USER="$H/user_data"; unset COCKPIT_ROOT
      if [ "$side" = sh ]; then bash "$SH" "$P" "$resp" "$proposer" "$pname"; elif [ "$side" = eng ]; then "$ENG" crud "$P" "$resp" "$proposer" "$pname"; else php "$PHPCLI" "$P" "$resp" "$proposer" "$pname"; fi; echo $? > "$T/rc_$side" ) > "$T/out_$side" 2> "$T/err_$side"
    sed -i "s|$T/proj_${side:0:1}|PROJ|g; s|$T/home_${side:0:1}|HOME|g" "$T/out_$side" "$T/err_$side"
    treedump "$P" | sed "s|$T/proj_${side:0:1}|PROJ|g" > "$T/tree_$side"
    # requests: decoded bodies, canonical
    php -r 'foreach (file($argv[1], FILE_IGNORE_NEW_LINES) as $l) { $e = json_decode($l, true); if (is_array($e["body"] ?? null)) { ksort($e["body"]); } echo json_encode($e, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES), "\n"; }' "$T/mock/requests.log" > "$T/req_$side"
  done
  local why=""
  if [ -z "${NOSH:-}" ]; then
  cmp -s "$T/out_sh" "$T/out_php" || why="output differs ($(wc -c < "$T/out_sh") vs $(wc -c < "$T/out_php") bytes)"
  cmp -s "$T/tree_sh" "$T/tree_php" || why="${why:+$why; }files differ"
  cmp -s "$T/req_sh" "$T/req_php" || why="${why:+$why; }requests differ"
  if [ -z "$why" ]; then ok "$name"; else bad "$name" "$why"; if [ "${VERBOSE:-0}" = 1 ]; then for f in out tree req; do diff "$T/${f}_sh" "$T/${f}_php" | head -8; done; fi; fi
  fi
  # the native side against the PHP reference (stdout, stderr, files, requests)
  if [ -n "$ENGOK" ]; then
    if [ "$(cat "$T/rc_eng")" = 9 ]; then
      REFUSED=$((REFUSED+1))
      mkproj "$T/proj_fresh"; treedump "$T/proj_fresh" | sed "s|$T/proj_fresh|PROJ|g" > "$T/tree_fresh"
      if [ "$ODD" = 1 ] && cmp -s "$T/tree_fresh" "$T/tree_eng"; then ok "$name [native: refused, nothing changed]"; else bad "$name [native]" "refused ($(head -c 100 "$T/err_eng" | tr '\\n' ' '))"; fi
    else
      local w2=""
      cmp -s "$T/out_php" "$T/out_eng" || w2="output differs ($(wc -c < "$T/out_php") vs $(wc -c < "$T/out_eng") bytes)"
      cmp -s "$T/err_php" "$T/err_eng" || w2="${w2:+$w2; }stderr differs"
      cmp -s "$T/tree_php" "$T/tree_eng" || w2="${w2:+$w2; }files differ"
      cmp -s "$T/req_php" "$T/req_eng" || w2="${w2:+$w2; }requests differ"
      if [ -z "$w2" ]; then ok "$name [native]"; else bad "$name [native]" "$w2"; if [ "${VERBOSE:-0}" = 1 ]; then for f in out err tree req; do diff "$T/${f}_php" "$T/${f}_eng" | head -8; done; fi; fi
    fi
  fi
}

echo; echo "== CREATE / UPDATE / APPEND"
scn "create a file" <<'EOF'
Here you go:
%%CREATE:notes/new.txt%%
first line
second line
%%END%%
done
EOF
scn "create overwrites, update is reported as CREATE, append appends" <<'EOF'
%%CREATE:readme.txt%%
replaced
%%END%%
%%UPDATE:src/a.txt%%
updated
%%END%%
%%APPEND:src/sub/deep.txt%%
more
%%END%%
%%APPEND:src/sub/deep.txt%%
again
%%END%%
EOF
scn "lower and mixed case markers" <<'EOF'
%%create:lower.txt%%
a
%%end%%
%%Create:mixed.txt%%
b
%%END%%
%%CrEaTe:weird.txt%%
c
%%END%%
EOF
scn "leading blank lines are dropped, inner and trailing blanks kept" <<'EOF'
%%CREATE:blank.txt%%


first

third


%%END%%
EOF
scn "a block of only blank lines" <<'EOF'
%%CREATE:onlyblank.txt%%



%%END%%
EOF
scn "an empty block" <<'EOF'
%%CREATE:empty.txt%%
%%END%%
EOF
scn "content containing percent signs, markers and shell characters" <<'EOF'
%%CREATE:odd.txt%%
50% off && $(rm -rf /) `id` 'q' "dq" \ back\slash
a %%not a marker
tab	here
%%END%%
EOF
scn "%%END%% in the middle of a line closes the block and discards that line" <<'EOF'
%%CREATE:cut.txt%%
keep this
text before %%END%% text after
this line is outside the block
EOF
scn "an unterminated block is never executed" <<'EOF'
%%CREATE:never.txt%%
content with no end
EOF
scn "CRLF line endings are kept in the content" <<EOF
%%CREATE:crlf.txt%%
line one
line two
%%END%%
EOF
scn "a path with spaces, and a nested directory that does not exist" <<'EOF'
%%CREATE:with space/new file.txt%%
x
%%END%%
%%CREATE:a/b/c/d/e.txt%%
deep
%%END%%
EOF
scn "Hebrew, emoji, accents" <<'EOF'
%%CREATE:he.txt%%
שלום עולם 🙂 café ★
%%END%%
EOF
scn "two blocks, text between them, an opener inside a block is just content" <<'EOF'
%%CREATE:one.txt%%
%%CREATE:inner.txt%%
inside
%%END%%
between
%%APPEND:one.txt%%
tail
%%END%%
EOF
scn "the response ends without a final newline" <<'EOF'
%%CREATE:nofinal.txt%%
last
%%END%%
EOF
printf '%s' $'%%CREATE:nonl.txt%%\nbody\n%%END%%' > "$T/nonl.resp"
scn "response file with no trailing newline at all" < "$T/nonl.resp"
scn "no markers at all: nothing happens, nothing printed" <<'EOF'
Just a normal answer with 100% certainty. No commands here.
EOF
scn "a lone %% is not a command" <<'EOF'
Save 50%% on this %%WHAT%% and %%%% more
EOF

echo; echo "== the sandbox: everything that tries to leave the project"
scn "traversal with ../ is stripped (one pass) and contained" <<'EOF'
%%CREATE:../escape.txt%%
x
%%END%%
%%CREATE:../../etc/passwd_copy%%
x
%%END%%
%%CREATE:a/../../b.txt%%
x
%%END%%
%%READ:../../etc/hostname%%
EOF
scn "the sed pass is not recursive: ....// leaves ../" <<'EOF'
%%CREATE:....//escaped.txt%%
x
%%END%%
%%READ:....//....//etc/hostname%%
%%READ:..../etc/hostname%%
EOF
scn "absolute paths are anchored inside the project" <<'EOF'
%%CREATE:/abs/path.txt%%
x
%%END%%
%%CREATE://double//slash.txt%%
x
%%END%%
%%READ:/etc/hostname%%
EOF
scn "a symlink that points outside is refused for write, read and delete" <<'EOF'
%%CREATE:linkfile%%
overwritten
%%END%%
%%CREATE:linkdir/new.txt%%
x
%%END%%
%%READ:linkfile%%
%%READ:linkdir/f%%
%%CONFIRM:DELETE%%
%%DELETE:linkfile%%
%%DELETE:linkdir/f%%
EOF
scn "a symlink that points inside is followed" <<'EOF'
%%READ:inlink%%
%%READ:srclink/a.txt%%
%%CREATE:srclink/via.txt%%
via link
%%END%%
EOF
scn "a relative symlink climbing out of the project" <<'EOF'
%%READ:escape/hostname%%
%%CREATE:escape/x.txt%%
x
%%END%%
EOF
scn "'.' and trailing-slash paths" <<'EOF'
%%READ:.%%
%%READ:src/%%
%%READ:./readme.txt%%
%%READ:src/./a.txt%%
%%MKDIR:./newdir/%%
EOF
scn "-n / -e as a path (echo options in the Bash's sed pipeline)" <<'EOF'
%%READ:-n%%
%%MKDIR:-e%%
EOF
scn "a path that is the project dir's prefix twin (proj_evil)" <<'EOF'
%%READ:../proj_evil/x%%
%%CREATE:../proj_sh_evil/x.txt%%
x
%%END%%
EOF

echo; echo "== READ"
scn "read: small, empty, unicode, binary, missing, a directory" <<'EOF'
%%READ:readme.txt%%
%%READ:zero.txt%%
%%READ:unicode.txt%%
%%READ:bin.dat%%
%%READ:nope.txt%%
%%READ:src%%
EOF
scn "read: larger than 16 KB is cut with a notice" <<'EOF'
%%READ:big.txt%%
EOF
scn "read: case-insensitive marker, text around it, only the first marker on a line" <<'EOF'
please %%read:readme.txt%% and then %%READ:src/a.txt%% here
EOF

echo; echo "== DELETE / MKDIR / LIST"
scn "delete needs the confirm marker anywhere in the response" <<'EOF'
%%DELETE:readme.txt%%
EOF
scn "delete with the confirm marker: file, directory, missing, outside" <<'EOF'
%%DELETE:readme.txt%%
%%DELETE:src%%
%%DELETE:nope.txt%%
%%DELETE:../outside.txt%%
and now %%CONFIRM:DELETE%%
EOF
scn "delete a symlink inside (removes the link's target, as the Bash resolved it)" <<'EOF'
%%CONFIRM:DELETE%%
%%DELETE:inlink%%
EOF
scn "mkdir: new, nested, existing, outside" <<'EOF'
%%MKDIR:newdir%%
%%MKDIR:a/b/c%%
%%MKDIR:src%%
%%MKDIR:../outsidedir%%
EOF
scn "list: root, subfolder, missing, a file, plain, trailing text" <<'EOF'
%%LIST%%
%%LIST:%%
%%LIST:src%%
%%LIST:nope%%
%%LIST:readme.txt%%
%%LIST:../..%%
EOF

echo; echo "== pass 2 reads EVERY line, also inside blocks (a quirk both share)"
scn "a READ inside a CREATE block runs too" <<'EOF'
%%CREATE:mixed.txt%%
before
%%READ:readme.txt%%
after
%%END%%
EOF

echo; echo "== PROPOSE (posted to library.php)"
mock library.php.proposal_add '{"ok":true}'
scn "propose a snippet" claude myproj <<'EOF'
%%PROPOSE:snippet%%
title: Sort helper
lang: python
notes: handy "one" liner
content: def s(x):
    return sorted(x)

# trailing comment
%%END%%
EOF
scn "propose a source, other proposer and project" gemini other <<'EOF'
%%PROPOSE:SOURCE%%
title: Docs\Site
lang: md
content:
line one
line two
%%END%%
EOF
scn "propose a library entry (kind defaults to path)" <<'EOF'
%%PROPOSE:library%%
title: My Notes
location: /home/me/notes
notes: n
%%END%%
%%PROPOSE:library%%
title: With kind
location: https://x.test
kind: url
%%END%%
EOF
scn "propose with CRLF key lines and a missing title" <<EOF
%%PROPOSE:snippet%%
lang: sh
content: echo hi
%%END%%
EOF
mock library.php.proposal_add 'STATUS:500
{"error":"boom"}'
scn "the server answering 500 still counts as 'pending approval' (curl -s)" <<'EOF'
%%PROPOSE:snippet%%
title: T
content: c
%%END%%
EOF

echo; echo "== web markers: FETCH / SEARCH / WORKER / TOOL"
mock_clear
mock search.php.fetch '{"ok":true,"text":"Line one\nLine two\twith tab and \"quotes\" and back\\slash","title":"x"}'
scn "fetch: the text field is extracted and unescaped" <<'EOF'
%%FETCH:https://example.com/a?b=1&c=two words%%
EOF
mock search.php.fetch ''
scn "fetch: empty answer" <<'EOF'
%%FETCH:https://example.com%%
EOF
mock search.php.fetch '{"ok":false,"error":"blocked"}'
scn "fetch: no text field" <<'EOF'
%%FETCH:https://example.com%%
EOF
mock search.php.fetch '{
  "ok": true,
  "text": "multi line json",
  "more": 1
}'
scn "fetch: pretty-printed JSON, one field per line" <<'EOF'
%%FETCH:https://e.com%%
EOF
mock search.php.search '{"ok":true,"results":[{"title":"First hit","url":"https://a.test/1","snippet":"about the first"},{"title":"Second hit","url":"https://b.test/2","snippet":""},{"title":"Third","url":"https://c.test/3","snippet":"third text"}]}'
scn "search: titles, urls and snippets via the comma-record parser" <<'EOF'
%%SEARCH:free pascal tutorials & tips?%%
EOF
mock search.php.search ''
scn "search: no answer" <<'EOF'
%%SEARCH:nothing%%
EOF
mock workers.php.models '{"models":[{"provider":"openai","model":"gpt-x"},{"provider":"groq","model":"llama-big"},{"provider":"groq","model":"llama-small"}]}'
mock workers.php.invoke '{"ok":true,"kind":"text","output":"translated: hola"}'
scn "worker: the first model of the provider, JSON payload, output shown" <<'EOF'
%%WORKER:groq:text:Translate "hello" to Spanish%%
EOF
scn "worker: provider without an enabled model" <<'EOF'
%%WORKER:nobody:text:hi%%
EOF
mock workers.php.invoke '{"ok":false,"error":"quota exceeded"}'
scn "worker: the endpoint reports an error" <<'EOF'
%%WORKER:groq:text:hi%%
EOF
mock workers.php.invoke 'not json at all'
scn "worker: an answer that is not JSON" <<'EOF'
%%WORKER:groq:text:hi%%
EOF
mock workers.php.invoke '{"ok":"true","kind":"image","output":"'"$(head -c 6000 /dev/zero | tr '\0' 'z')"'"}'
scn "worker: ok as a string, kind image, output over 4096 chars is truncated" <<'EOF'
%%WORKER:groq:image:draw a cat%%
EOF
mock workers.php.invoke '{"ok":true}'
scn "worker: ok with no output or kind" <<'EOF'
%%WORKER:groq:text:hi%%
EOF
mock tools.php.run '{"ok":true,"output":"/tmp/out.mp3","output_size":12345,"elapsed_ms":987}'
scn "tool: payload split on |, output path inlined" <<'EOF'
%%TOOL:ffmpeg:burn-subtitles:/path/video.mp4|/path/subs.srt%%
%%TOOL:ffmpeg:to-mp3:/path/a.flac%%
EOF
mock tools.php.run '{"ok":false,"error":"tool failed","rc":2,"log":"first line of the log\nsecond line"}'
scn "tool: error with rc and a log excerpt" <<'EOF'
%%TOOL:ffmpeg:to-mp3:/x.flac%%
EOF
mock tools.php.run '{"ok":false}'
scn "tool: error without details" <<'EOF'
%%TOOL:ffmpeg:to-mp3:/x.flac%%
EOF
mock tools.php.run '<html><body>Please sign in</body></html>'
scn "tool: the page answers with something that is not JSON (wrong address, not signed in)" <<'EOF'
%%TOOL:ffmpeg:to-mp3:/x.flac%%
EOF
mock tools.php.run ''
scn "tool: no answer" <<'EOF'
%%TOOL:ffmpeg:to-mp3:/x.flac%%
EOF

echo; echo "== LOAD_SKILL and the catalog (LIB / SNIP / SRC)"
scn "skill: with front matter, without, unclosed, big, missing, id with odd characters" <<'EOF'
%%LOAD_SKILL:demo%%
%%LOAD_SKILL:nofm%%
%%LOAD_SKILL:unclosed%%
%%LOAD_SKILL:big%%
%%LOAD_SKILL:nope%%
%%LOAD_SKILL:../demo%%
%%LOAD_SKILL:d e!mo%%
EOF
mock page '<html><body><h1>Title</h1><p>Some   text with <b>bold</b> and   spaces</p>

<p>second</p></body></html>'
scn "catalog: by id, by title (partial, case-insensitive), with a file, with a url, empty entry, missing" <<'EOF'
%%LIB:lib1%%
%%LIB:network%%
%%LIB:  WITH FILE  %%
%%LIB:By URL%%
%%LIB:Empty Entry%%
%%LIB:does not exist%%
EOF
scn "catalog: snippets (path), sources (url), global index, kind isolation" <<'EOF'
%%SNIP:sort%%
%%SNIP:Zebra%%
%%SRC:docs site%%
%%LIB:global entry%%
%%SNIP:lib1%%
EOF

echo; echo "== deliberate difference: the project directory itself is never deleted"
rm -rf "$T/dd"; mkdir -p "$T/dd/proj/sub"; echo keep > "$T/dd/proj/keep.txt"
printf '%%%%CONFIRM:DELETE%%%%\n%%%%DELETE:.%%%%\n%%%%DELETE:./%%%%\n%%%%DELETE:sub/..%%%%\n%%%%DELETE:sub%%%%\n' > "$T/dd/resp"
HOME="$T/dd/h" php "$PHPCLI" "$T/dd/proj" "$T/dd/resp" > "$T/dd/out" 2>&1
if [ -f "$T/dd/proj/keep.txt" ] && [ ! -d "$T/dd/proj/sub" ] && [ "$(grep -c 'that is the project directory itself' "$T/dd/out")" = 3 ]; then ok "PHP: DELETE of '.', './' and 'sub/..' is refused (3 refusals), a real subfolder is still deleted"; else bad "project-root delete" "$(cat "$T/dd/out")"; fi
echo keep > "$T/dd/proj/keep.txt"; mkdir -p "$T/dd/proj/sub"
if [ -d "$T/dd/proj" ]; then
  mkdir -p "$T/dd/sandbox/proj"; echo keep > "$T/dd/sandbox/proj/keep.txt"
  printf '%%%%CONFIRM:DELETE%%%%\n%%%%DELETE:.%%%%\n' > "$T/dd/resp2"
  HOME="$T/dd/h" bash "$SH" "$T/dd/sandbox/proj" "$T/dd/resp2" >/dev/null 2>&1
  [ ! -d "$T/dd/sandbox/proj" ] && ok "(for the record) the Bash DID delete the whole project directory on %%DELETE:.%%" || bad "reference behaviour changed" "the Bash no longer deletes the project root"
fi

echo; echo "== native-only cases (the PHP reference is the judge; a refusal is allowed where marked)"
NOSH=1
mock workers.php.models '{"models":[{"provider":"groq","model":"llama-big"}]}'
mock workers.php.invoke '{"ok":false,"error":"Authentication required"}'
scn "worker: an error answer with an error body is shown" <<'EOF'
%%WORKER:groq:text:hi%%
EOF
mock workers.php.invoke 'STATUS:401
{"ok":false,"error":"Authentication required"}'
scn "worker: the page answers 401 with a JSON error body" <<'EOF'
%%WORKER:groq:text:hi%%
EOF
mock workers.php.invoke '{"ok":true,"output":"plain output no kind"}'
scn "worker: ok without a kind (defaults to text)" <<'EOF'
%%WORKER:groq:text:one%%
EOF
mock workers.php.invoke '{"ok":true,"kind":"text","output":"multi\nline\n\n"}'
scn "worker: output with newlines (trailing ones stripped)" <<'EOF'
%%WORKER:groq:text:two%%
EOF
mock workers.php.invoke '{"ok":true,"kind":"text","output":12}'
scn "worker: an integer output" <<'EOF'
%%WORKER:groq:text:three%%
EOF
mock workers.php.invoke '{"ok":true,"kind":"text","output":"séance ☕ שלום"}'
scn "worker: unicode output and prompt" <<'EOF'
%%WORKER:groq:text:Σωκράτης said "שלום" \ back\slash é%%
EOF
mock workers.php.invoke '{"ok":true,"kind":"text","output":"x"}'
scn "worker: a prompt with a tab" <<'EOF'
%%WORKER:groq:text:tab	here%%
EOF
ODD=1
mock workers.php.invoke '{"ok":true,"kind":"text","output":1.5}'
scn "worker: a non-integer number is refused by the native side (the PHP helper formats it)" <<'EOF'
%%WORKER:groq:text:float%%
EOF
mock workers.php.invoke '{"ok":true,"kind":"text","output":{"a":[1,2]}}'
scn "worker: an object output is refused by the native side" <<'EOF'
%%WORKER:groq:text:obj%%
EOF
scn "worker: a provider name that is a regular expression is refused by the native side" <<'EOF'
%%WORKER:gr.q:text:regex%%
EOF
ODD=0
mock tools.php.run '{"ok":true,"output":"/tmp/out.mp3","output_size":1234,"elapsed_ms":87}'
scn "tool: integer size and time" <<'EOF'
%%TOOL:ffmpeg:mp3:/tmp/in.wav%%
EOF
mock tools.php.run '{"ok":false,"error":"boom","rc":3,"log":"line one\nline two"}'
scn "tool: error with an integer rc and a log" <<'EOF'
%%TOOL:ffmpeg:mp3:/tmp/in.wav|-vn%%
EOF
mock tools.php.run '{"ok":false,"error":"boom","rc":-1}'
scn "tool: a negative rc" <<'EOF'
%%TOOL:pandoc:docx:/tmp/in.md%%
EOF
ODD=1
mock tools.php.run '{"ok":true,"output":"o","output_size":10.5,"elapsed_ms":3}'
scn "tool: a float size is refused by the native side" <<'EOF'
%%TOOL:ffmpeg:mp3:/tmp/in.wav%%
EOF
mock tools.php.run '{"ok":false,"error":"x","rc":2,"log":["a","b"]}'
scn "tool: a log that is a list is refused by the native side" <<'EOF'
%%TOOL:ffmpeg:mp3:/tmp/in.wav%%
EOF
ODD=0
mock search.php.search '{"results":[{"title":"A","url":"http://a","snippet":"first"},{"title":"B","url":"http://b","snippet":""}]}'
scn "search: the second result has an empty snippet" <<'EOF'
%%SEARCH:needle%%
EOF
scn "search: spaces, ampersand and question mark in the query" <<'EOF'
%%SEARCH:a b&c?d%%
EOF
scn "search: -n as the query (the echo options quirk)" <<'EOF'
%%SEARCH:-n%%
EOF
mock search.php.fetch '{"ok":true,"text":"line one\nline \"two\"\twith tab\\back","title":"t"}'
scn "fetch: escapes in the text field" <<'EOF'
%%FETCH:http://example.com/a b?x=1&y=2%%
EOF
scn "two markers on one line: only the first kind runs" <<'EOF'
%%LIST%% %%READ:readme.txt%% %%MKDIR:z%%
EOF
scn "list with an empty path and a missing subfolder" <<'EOF'
%%LIST:%%
%%LIST:nope%%
EOF
scn "block markers with odd spacing and the end marker in uppercase and lowercase" <<'EOF'
%%CREATE:a b/c d.txt%%
x
%%end%%
%%APPEND:a b/c d.txt%%
y
%%END%%
%%READ:a b/c d.txt%%
EOF
mock page 'REDIRECT:'"$COCKPIT_BASE_URL"'/page2.html'
mock page2 '<html><body><h1>Redirected</h1>   <p>text   here</p>


<script>x</script></body></html>'
scn "catalog: a url entry that redirects (the redirect is followed)" <<'EOF'
%%LIB:By URL%%
EOF
mock page '<p>plain page</p>'
NOSH=""

echo; echo "== the glue in agent_loop.sh (run_crud)"
AL="$HERE/../scripts/agent_loop.sh"
fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) *\\{" {p=1} p {print} p && /^}/ {exit}' "$AL"; }
{ fn engine_bin; fn engine_enabled; fn run_crud; } > "$T/glue.sh"
bash -n "$T/glue.sh" || { echo "glue does not parse"; exit 2; }
glue() {   # glue ON|OFF -> runs run_crud on a project with the %%DELETE:.%% response (the one place the two differ on purpose)
  rm -rf "$T/g"; mkdir -p "$T/g/proj" "$T/g/h"; echo keep > "$T/g/proj/keep.txt"
  printf '%%%%CONFIRM:DELETE%%%%\n%%%%DELETE:.%%%%\n' > "$T/g/resp"
  ( export HOME="$T/g/h" SCRIPTS_DIR="$HERE/../scripts" REQ_DATA=""; unset COCKPIT_ENGINE
    [ "$1" = ON ] && export COCKPIT_ENGINE=1
    . "$T/glue.sh"; run_crud "$T/g/proj" "$T/g/resp" claude proj ) > "$T/g/out" 2>&1
}
glue OFF; [ ! -d "$T/g/proj" ] && ok "switch OFF: the Bash executor runs (it deletes the project dir on %%DELETE:.%% — the reference behaviour)" || bad "glue OFF" "$(cat "$T/g/out")"
glue ON;  [ -f "$T/g/proj/keep.txt" ] && grep -q "project directory itself" "$T/g/out" && ok "switch ON: the PHP interpreter runs (it refuses)" || bad "glue ON" "$(cat "$T/g/out")"
( export HOME="$T/g/h" SCRIPTS_DIR="$T/nonexistent_scripts" REQ_DATA="" COCKPIT_ENGINE=1; . "$T/glue.sh"; mkdir -p "$T/g/proj2"; printf '%%%%LIST%%%%\n' > "$T/g/r2"; run_crud "$T/g/proj2" "$T/g/r2" claude p ) > "$T/g/out2" 2>&1
grep -q "crud_executor.sh" "$T/g/out2" && ok "switch ON but crud_cli.php missing: falls back to the Bash executor (which is missing too here, so its error shows)" || bad "fallback when the PHP file is missing" "$(cat "$T/g/out2")"
echo; echo "== inputs the Bash handles quietly"
printf '%%%%READ:x%%%%\n' > "$T/r"; for impl in sh php; do ( HOME="$T/h" ; if [ $impl = sh ]; then bash "$SH" /nonexistent "$T/r"; else php "$PHPCLI" /nonexistent "$T/r"; fi ) > "$T/o_$impl" 2>&1; echo $? >> "$T/o_$impl"; done
cmp -s "$T/o_sh" "$T/o_php" && ok "a project directory that does not exist: silent, exit 0, both" || bad "missing project dir" "$(cat "$T/o_sh") | $(cat "$T/o_php")"
for impl in sh php; do ( HOME="$T/h" ; if [ $impl = sh ]; then bash "$SH" "$T" /nonexistent/file; else php "$PHPCLI" "$T" /nonexistent/file; fi ) > "$T/o_$impl" 2>&1; echo $? >> "$T/o_$impl"; done
cmp -s "$T/o_sh" "$T/o_php" && ok "a response file that does not exist: silent, exit 0, both" || bad "missing response file"

echo; echo "crud parity: $PASS passed, $FAIL failed ($REFUSED native refusals, files untouched)"
[ "$FAIL" -eq 0 ]
