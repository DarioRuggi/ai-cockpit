#!/bin/bash
# history_native_parity.sh — `aicengine history` against scripts/history_cli.php (the byte-exact reference of the Bash), on identical copies of the same chats:
# standard output, log lines (stderr), exit code, every chat file, and the rows of the FTS5 index must be identical. An exit 9 (REFUSED, for the inputs the native
# code does not copy: invalid UTF-8, characters FPC's tables do not know, non-strict JSON, ...) must leave the files untouched, and is allowed only on the "odd" cases.
#   bash tests/history_native_parity.sh     ENGINE=<aicengine>     Exit 0 = pass; SKIPPED without an engine with `history`, php+SQLite3(FTS5), or the sqlite3 tool.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PHPCLI="$ROOT/scripts/history_cli.php"
ENG="${ENGINE:-$HOME/aicockpit-runtime/aicengine/bin/aicengine}"
for c in php sqlite3 diff; do command -v $c >/dev/null 2>&1 || { echo "history_native_parity: $c is needed - SKIPPED"; exit 0; }; done
[ -x "$ENG" ] && "$ENG" version 2>/dev/null | grep -q " history" || { echo "history_native_parity: no engine with 'history' - SKIPPED"; exit 0; }
php -r 'exit(class_exists("SQLite3") ? 0 : 1);' || { echo "history_native_parity: php without SQLite3 - SKIPPED"; exit 0; }
T=$(mktemp -d) || exit 1; trap 'rm -rf "${T:?}"' EXIT
php "$ROOT/tests/history_native_gen.php" "$T" >/dev/null
fails=0; n=0; refused=0
ok() { n=$((n+1)); [ -n "$VERBOSE" ] && echo "  ok   $1"; return 0; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
ENVV=(); STDIN=/dev/null; FX=five; ALLOW=plain
A="$T/runA"; B="$T/runB"
dump() { [ -f "$1/.chat_index.db" ] && sqlite3 "$1/.chat_index.db" "SELECT chat,id,role,agent,ts,body FROM ex ORDER BY rowid" 2>&1 | sed "s|$1|@D@|g" || echo "(no index)"; }
runside() {   # dir kind  -> runs every command of CMDS in order; leaves out/err/rc files in the dir's parent as <dir>.out etc.
    local d="$1" kind="$2" rc=0; : > "$d.out"; : > "$d.err"; : > "$d.rc"
    local -a args; local line
    for line in "${CMDS[@]}"; do
        args=(); local IFS=$'\x1f'; read -r -a args <<< "$line"; unset IFS
        local k; for k in "${!args[@]}"; do args[$k]="${args[$k]//@D@/$d}"; done
        if [ "$kind" = php ]; then ( cd "$d" && env "${ENVV[@]}" CHAT_CLI_NOW=2026-10-07T12:00:00Z php "$PHPCLI" "${args[@]}" < "$STDIN" >> "$d.out" 2>> "$d.err" ); rc=$?
        else ( cd "$d" && env "${ENVV[@]}" CHAT_CLI_NOW=2026-10-07T12:00:00Z "$ENG" history "${args[@]}" < "$STDIN" >> "$d.out" 2>> "$d.err" ); rc=$?; fi
        echo "$rc" >> "$d.rc"
    done
}
pair() {   # label   (uses FX ENVV STDIN ALLOW CMDS)
    local label="$1"
    rm -rf "$A" "$B" "$A".* "$B".*; cp -a "$T/fx/$FX" "$A"; cp -a "$T/fx/$FX" "$B"
    runside "$A" php; runside "$B" eng
    if grep -qx 9 "$B.rc"; then
        refused=$((refused+1))
        if [ "$ALLOW" = plain ]; then bad "$label: refused on a plain case ($(head -c 120 "$B.err" | tr '\n' ' '))"; return; fi
        diff -r -x '.chat_index.db*' -x '*.lock' "$T/fx/$FX" "$B" >/dev/null 2>&1 && ok "$label (refused, nothing changed)" || bad "$label: refused but files changed"; return
    fi
    local good=1 why=""
    cmp -s <(sed "s|$A|@D@|g" "$A.out") <(sed "s|$B|@D@|g" "$B.out") || { good=0; why="$why stdout;"; }
    cmp -s <(sed "s|$A|@D@|g" "$A.err") <(sed "s|$B|@D@|g" "$B.err") || { good=0; why="$why stderr;"; }
    cmp -s "$A.rc" "$B.rc" || { good=0; why="$why exit code ($(tr '\n' ' ' < "$A.rc")vs $(tr '\n' ' ' < "$B.rc"));"; }
    diff -r -x '.chat_index.db*' -x '*.lock' "$A" "$B" >/dev/null 2>&1 || { good=0; why="$why files;"; }
    cmp -s <(dump "$A") <(dump "$B") || { good=0; why="$why index rows;"; }
    if [ $good = 1 ]; then ok "$label"; else
        bad "$label:$why"
        diff <(sed "s|$A|@D@|g" "$A.out") <(sed "s|$B|@D@|g" "$B.out") | head -4; diff <(sed "s|$A|@D@|g" "$A.err") <(sed "s|$B|@D@|g" "$B.err") | head -4
        diff -r -x '.chat_index.db*' -x '*.lock' "$A" "$B" | head -6; diff <(dump "$A") <(dump "$B") | head -4
    fi
}
sep=$'\x1f'
cmd() { local IFS="$sep"; CMDS+=("$*"); }

# ---- the gate ---------------------------------------------------------------------------------------------------------------------------
while read -r p kind; do
    [ -n "$p" ] || continue
    FX=five; ALLOW=$kind; STDIN="$T/prompts/$p.txt"; ENVV=(); CMDS=(); cmd needs --agent CLAUDE; pair "needs: $p"
done < "$T/prompts/MANIFEST"
for p in short selfcontained back_file keyword_python; do for h in always never; do
    FX=five; ALLOW=plain; STDIN="$T/prompts/$p.txt"; ENVV=(COCKPIT_HISTORY=$h); CMDS=(); cmd needs --agent OLLAMA; pair "needs $h: $p"
done; done

# ---- build -------------------------------------------------------------------------------------------------------------------------------
BP="keyword_python keyword_docker keyword_postgres keyword_none keyword_unicode keyword_or keyword_quote terms_many terms_stop terms_digits terms_dup terms_punct empty short mode now back_word"
for fx in $(cat "$T/fx/MANIFEST"); do
    for p in $BP; do
        for spec in "text inline" "text pointer" "json inline"; do
            set -- $spec; FX=$fx; ALLOW=plain; { [ "$fx" = rawnl ] || [ "$fx" = nobracket ]; } && ALLOW=odd; STDIN="$T/prompts/$p.txt"; ENVV=(); CMDS=()
            cmd build --chat "@D@/proj/chat_x.json" --format $1 --mode $2 --agent CLAUDE; pair "build $fx $p $1/$2"
        done
    done
    for p in keyword_python keyword_docker empty; do
        for env in MAX_HISTORY=2 HISTORY_CLI_NO_INDEX=1 MAX_HISTORY=1; do
            for fmt in text json; do
                FX=$fx; ALLOW=plain; { [ "$fx" = rawnl ] || [ "$fx" = nobracket ]; } && ALLOW=odd; STDIN="$T/prompts/$p.txt"; ENVV=($env); CMDS=()
                cmd build --chat "@D@/proj/chat_x.json" --format $fmt --mode inline --agent GEMINI; pair "build $fx $p $fmt $env"
            done
        done
    done
    FX=$fx; ALLOW=plain; { [ "$fx" = rawnl ] || [ "$fx" = nobracket ]; } && ALLOW=odd; STDIN=/dev/null; ENVV=(); CMDS=(); cmd sync --chat "@D@/proj/chat_x.json" --agent CLAUDE; cmd sync --chat "@D@/proj/chat_x.json" --agent CLAUDE; pair "sync twice $fx"
done
# the index follows a chat that changed behind its back
FX=five; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=(); cmd sync --chat "@D@/proj/chat_x.json" --agent CLAUDE; cmd build --chat "@D@/proj/chat_x.json" --format text --mode inline --agent CLAUDE; pair "build twice reuses the index"

# ---- add ------------------------------------------------------------------------------------------------------------------------------------
mkdir -p "$T/txt"; printf 'plain text\n' > "$T/txt/a1"; printf 'with\ttab and\nnewlines\n\n' > "$T/txt/a2"; printf 'unit\x1fsep' > "$T/txt/a3"; printf 'שלום\n' > "$T/txt/a4"
n_=0; for f in a1 a2 a3 a4; do FX=five; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=(); cmd sync --chat "@D@/proj/chat_x.json" --agent CLAUDE; cmd add --chat "@D@/proj/chat_x.json" --id 99 --role agent --agent claude --ts 2026-10-07T12:00:00Z --text-file "$T/txt/$f"; cmd build --chat "@D@/proj/chat_x.json" --format text --mode inline --agent CLAUDE; pair "add $f"; done
FX=five; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=(); cmd add --chat "@D@/proj/chat__scratch.json" --id 1 --role user --agent '' --ts t --text-file "$T/txt/a1"; pair "add to a scratch chat is skipped"

# ---- append ----------------------------------------------------------------------------------------------------------------------------------
printf 'hello world\n' > "$T/txt/u1"; printf 'a\\b "q" \x01 \t end\nline2\n\n' > "$T/txt/u2"; printf -- '-n' > "$T/txt/u3"; printf -- '-ne' > "$T/txt/u4"; printf -- '-x' > "$T/txt/u5"; printf '' > "$T/txt/u6"
printf 'שלום עולם 😀 é\n' > "$T/txt/u7"; printf 'tab\there\x0b\x0c\r\n' > "$T/txt/u8"; head -c 3000 /dev/zero | tr '\0' 'x' > "$T/txt/u9"; printf 'nul\0inside\n' > "$T/txt/u10"; printf '\n\n\ntrailing\n\n\n' > "$T/txt/u11"
UF="u1 u2 u3 u4 u5 u6 u7 u8 u9 u10 u11"
for fx in $(cat "$T/fx/MANIFEST"); do
    for uf in $UF; do
        FX=$fx; ALLOW=plain; { [ "$fx" = rawnl ] || [ "$fx" = nobracket ]; } && ALLOW=odd; STDIN=/dev/null; ENVV=(); CMDS=()
        cmd append --chat "@D@/proj/chat_x.json" --project proj --chat-name x --user-file "$T/txt/$uf" --agent-file "$T/txt/u2" --model claude-opus-4-8 --duration 3.5 --style chat --mode single --agent claude --supplier claude --agent-uc CLAUDE
        pair "append $fx user=$uf"
        FX=$fx; CMDS=(); cmd append --chat "@D@/proj/chat_x.json" --project proj --chat-name x --user-file "$T/txt/u1" --agent-file "$T/txt/$uf" --model "" --duration .9 --style 'we"ird' --mode 'a\b' --agent ollama --supplier dual --agent-uc OLLAMA
        pair "append $fx agent=$uf"
    done
    for dur in "" 0 0.0 .5 12 1.234 abc 1.2.3 -1 ".0" "00.00"; do
        FX=$fx; ALLOW=plain; { [ "$fx" = rawnl ] || [ "$fx" = nobracket ]; } && ALLOW=odd; STDIN=/dev/null; ENVV=(); CMDS=()
        cmd append --chat "@D@/proj/chat_x.json" --project proj --chat-name x --user-file "$T/txt/u1" --agent-file "$T/txt/u7" --model m --duration "$dur" --style s --mode m --agent claude --supplier claude --agent-uc CLAUDE
        pair "append $fx duration='$dur'"
    done
    FX=$fx; ALLOW=plain; { [ "$fx" = rawnl ] || [ "$fx" = nobracket ]; } && ALLOW=odd; STDIN=/dev/null; ENVV=(); CMDS=()
    for k in 1 2 3; do cmd append --chat "@D@/proj/chat_x.json" --project proj --chat-name x --user-file "$T/txt/u1" --agent-file "$T/txt/u7" --model m --duration 1 --style s --mode m --agent claude --supplier claude --agent-uc CLAUDE; done
    cmd build --chat "@D@/proj/chat_x.json" --format text --mode inline --agent CLAUDE
    pair "append three times then build $fx"
done
# new chats, odd names
for cn in 'chat__scratch' 'chat_new'; do
    FX=missing; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=()
    cmd append --chat "@D@/proj/$cn.json" --project 'my proj' --chat-name 'my chat' --user-file "$T/txt/u1" --agent-file "$T/txt/u2" --model m --duration 2 --style s --mode m --agent claude --supplier claude --agent-uc CLAUDE
    pair "append creates $cn"
done
FX=missing; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=(); cmd append --chat "@D@/new/dir/chat_deep.json" --project 'role' --chat-name 'role' --user-file "$T/txt/u1" --agent-file "$T/txt/u2" --model m --duration 2 --style s --mode m --agent claude --supplier claude --agent-uc CLAUDE; cmd append --chat "@D@/new/dir/chat_deep.json" --project 'role' --chat-name 'role' --user-file "$T/txt/u1" --agent-file "$T/txt/u2" --model m --duration 2 --style s --mode m --agent claude --supplier claude --agent-uc CLAUDE; pair "a project named role (the Bash's quirk)"
FX=five; ALLOW=plain; STDIN=/dev/null; ENVV=(HISTORY_CLI_NO_INDEX=1); CMDS=(); cmd append --chat "@D@/proj/chat_x.json" --project proj --chat-name x --user-file "$T/txt/u1" --agent-file "$T/txt/u2" --model m --duration 2 --style s --mode m --agent claude --supplier claude --agent-uc CLAUDE; pair "append without an index"
FX=five; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=(); cmd append --chat "@D@/proj/chat_x.json" --user-file "$T/txt/u1"; pair "append with missing arguments (usage, exit 2)"
FX=five; ALLOW=plain; STDIN=/dev/null; ENVV=(); CMDS=(); cmd build; cmd sync; cmd add --chat x; cmd bogus; pair "usage errors"

echo "history_native_parity: $n passed, $fails failed ($refused refused-and-untouched)"; [ "$fails" = 0 ]
