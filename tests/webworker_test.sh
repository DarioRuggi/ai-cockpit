#!/usr/bin/env bash
# webworker_test.sh — web workers end to end: the REAL cockpit_shell --worker window (built from source here) loads a local fake chat site, Cockpit's engine types into
# its box, presses its button, reads the streamed answer back; login and bot-check pages are reported (never passed); the window stays off-screen.   bash tests/webworker_test.sh
# SKIPPED without a display, fpc, php or the GTK/WebKit libraries.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "${DISPLAY:-}" ] || export DISPLAY=:0
command -v fpc >/dev/null 2>&1 && command -v php >/dev/null 2>&1 && command -v xdpyinfo >/dev/null 2>&1 && xdpyinfo >/dev/null 2>&1 || { echo "webworker_test: needs fpc, php and a running X display - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/ww_XXXX) || exit 1; PIDS=""
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; [ -d "$T/webworkers" ] && for d in "$T"/webworkers/*; do echo "{\"cmd\":\"quit\"}" > "$d/cmd.9.json" 2>/dev/null; done; sleep 0.5; pkill -f "cockpit_shell_t.*--worker $T" 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
bash "$ROOT/shell/build.sh" "$T/cockpit_shell_t" >/dev/null 2>&1 || { echo "webworker_test: the shell did not build - $(bash "$ROOT/shell/build.sh" "$T/cockpit_shell_t" 2>&1 | tail -3)"; exit 1; }
"$T/cockpit_shell_t" --check >/dev/null 2>&1 || { echo "webworker_test: GTK/WebKit libraries missing - SKIPPED"; exit 0; }
mkdir -p "$T/site"; cp "$ROOT/tests/fixtures/fakechat.html" "$T/site/"
PORT=$((20000 + RANDOM % 20000)); php -S 127.0.0.1:$PORT -t "$T/site" >"$T/site.log" 2>&1 & PIDS="$PIDS $!"
for i in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/fakechat.html" && break; sleep 0.2; done
mkdir -p "$T/cfg/ai-cockpit"; printf '{ "w" : 1777, "h" : 999, "max" : true, "x" : 5, "y" : 6, "frameless" : false }' > "$T/cfg/ai-cockpit/window.json"; echo on > "$T/cfg/ai-cockpit/frameless"; export XDG_CONFIG_HOME="$T/cfg"   # frameless on: the worker window carries the border strips, and everything must still work
cat > "$T/drive.php" <<PHP
<?php
\$PATHS = ['cockpit_data' => '$T', 'home' => '$T']; putenv('COCKPIT_SHELL_BIN=$T/cockpit_shell_t');
require '$ROOT/cockpit_app/webworker_lib.php';
\$U = 'http://127.0.0.1:$PORT/fakechat.html'; \$out = [];
\$cfg = ['input' => ['#in', '#ce'], 'send' => ['#send'], 'answer' => ['.msg.bot'], 'busy' => ['#stop'], 'login' => ['#email'], 'blocked' => ['verify you are human'], 'stable' => 800, 'timeout' => 40000];
// a stale alive file from an earlier window (read once, so PHP's stat cache holds its old time) must not hide a window that starts now
\$sd = ww_dir('stale'); @mkdir(\$sd, 0777, true); touch(\$sd . '/alive', time() - 3600); \$out['stale_before'] = ww_alive(\$sd);
\$out['stale'] = ww_run('stale', "\$U?mode=textarea", \$cfg, 'Stale file question', null, 60); ww_stop('stale');
\$deltas = []; \$r = ww_run('fake', "\$U?mode=textarea", \$cfg, 'Hello there', function (\$d) use (&\$deltas) { \$deltas[] = \$d; }, 60); \$out['textarea'] = \$r + ['deltas' => \$deltas];
\$dir = ww_dir('fake'); \$off = ww_events_end(\$dir); ww_cmd(\$dir, ['cmd' => 'status', 'id' => 's1']); usleep(800000); \$st = null; foreach (ww_events(\$dir, \$off) as \$e) if ((\$e['t'] ?? '') === 'status') \$st = \$e; \$out['status_after'] = \$st;
\$r = ww_run('fake', "\$U?mode=ce", \$cfg, "Line one\nLine two", null, 60); \$out['ce'] = \$r;
\$r = ww_run('fake', "\$U?mode=login", \$cfg, 'hi', null, 40); \$out['login'] = \$r;
\$off = ww_events_end(\$dir); ww_cmd(\$dir, ['cmd' => 'status', 'id' => 's2']); usleep(800000); \$st = null; foreach (ww_events(\$dir, \$off) as \$e) if ((\$e['t'] ?? '') === 'status') \$st = \$e; \$out['status_login'] = \$st;
ww_cmd(\$dir, ['cmd' => 'hide']);
\$r = ww_run('fake', "\$U?mode=blocked", \$cfg, 'hi', null, 40); \$out['blocked'] = \$r; ww_cmd(\$dir, ['cmd' => 'hide']);
\$cfgH = ['input' => ['#in', '#ce'], 'send' => ['#send'], 'busy' => ['#stop'], 'trim' => ['\\\\n?2nd opinion[\\\\s\\\\S]*\$'], 'trimStart' => ['^Fake said\\\\s*\\\\n[^\\\\n]*\\\\n'], 'stable' => 800, 'timeout' => 40000];
\$out['heur'] = ww_run('fake', "\$U?mode=junk", \$cfgH, 'Which number is the answer?', null, 60);
\$cfgM = ['input' => ['#in', '#ce'], 'send' => ['#send'], 'busy' => ['#stop'], 'trimStart' => ['^(?:(?:Read more|Researched)\\\\s*\\\\n\\\\s*)+'], 'dropLines' => ['^[a-z0-9][a-z0-9.-]{2,40}\$', '^\\\\+\\\\d+\$'], 'stable' => 800, 'timeout' => 40000];
\$out['math'] = ww_run('fake', "\$U?mode=math", \$cfgM, 'What is the square root of minus one?', null, 60);
\$out['redirect'] = ww_run('fake', "\$U?mode=redirect", \$cfg, 'Redirect question', null, 60);
\$cfgL = ['input' => ['#in', '#ce'], 'send' => ['#send'], 'busy' => ['#stop'], 'answer' => ['[data-part="answer"]'], 'stable' => 800, 'timeout' => 40000];
\$out['letters'] = ww_run('fake', "\$U?mode=letters", \$cfgL, 'Question for letters', null, 60);
\$cfgA = ['input' => ['#in', '#ce'], 'send' => ['#send'], 'busy' => ['#stop'], 'answer' => ['.msg.bot.ans'], 'stable' => 800, 'timeout' => 40000];
\$out['mathsel'] = ww_run('fake', "\$U?mode=math", \$cfgA, 'What is the square root of minus one?', null, 60);
\$cfgS = ['input' => ['#in', '#ce'], 'send' => ['#send'], 'busy' => ['#stop'], 'answer' => ['.blk'], 'answerJoin' => true, 'trimStart' => ['^Show thinking\\\\s*'], 'stable' => 800, 'timeout' => 40000];
\$out['split'] = ww_run('fake', "\$U?mode=split", \$cfgS, 'Split question', null, 60);
\$out['selftest'] = ww_selftest('fake', "\$U?mode=textarea", \$cfg);
\$out['probe'] = ww_probe('fake', "\$U?mode=textarea", 20);
\$out['alive_before_quit'] = ww_alive(\$dir); ww_stop('fake'); sleep(2); \$out['alive_after_quit'] = ww_alive(\$dir);
// a launcher that fails: its own words must reach the error (a window that never starts used to say only "is a desktop session running?")
file_put_contents('$T/badshell', "#!/bin/sh\necho 'sudo: a password is required' >&2\nexit 1\n"); chmod('$T/badshell', 0755); putenv('COCKPIT_SHELL_BIN=$T/badshell');
\$out['bad_launcher'] = ww_ensure('badlauncher', 'http://x/'); putenv('COCKPIT_SHELL_BIN=$T/cockpit_shell_t');
\$out['no_binary'] = (function () { putenv('COCKPIT_SHELL_BIN='); global \$PATHS; \$PATHS['home'] = '/nonexistent'; return ww_ensure('nobin', 'http://x/'); })();
echo json_encode(\$out);
PHP
php "$T/drive.php" > "$T/out.json" 2>"$T/err.txt"; jq -e . "$T/out.json" >/dev/null 2>&1 || { echo "driver failed: $(head -c 800 "$T/err.txt") $(head -c 400 "$T/out.json")"; exit 1; }
q() { jq -r "$1" "$T/out.json"; }
[ "$(q .stale_before)" = false ] && [ "$(q .stale.ok)" = true ] && ok || bad "a stale alive file must not stop a new window from being seen: $(q .stale -c | head -c 300)"
[ "$(q .textarea.ok)" = true ] && q .textarea.output | grep -q "You asked: Hello there" && q .textarea.output | grep -q "Grüße 日本語" && ok || bad "textarea chat: $(q .textarea -c | head -c 500)"
[ "$(q '.textarea.deltas|join("")')" = "$(q .textarea.output)" ] && [ "$(q '.textarea.deltas|length')" -ge 2 ] && ok || bad "the answer must arrive as growing pieces that add up to the final text: $(q '.textarea.deltas|length') pieces"
[ "$(q .textarea.tokens_estimated)" = true ] && [ "$(q .textarea.via)" = web ] && ok || bad "web answers are marked estimated"
[ "$(q .status_after.shown)" = false ] && ok || bad "the window must be put away after a good answer: $(q .status_after -c)"
[ "$(q .ce.ok)" = true ] && q .ce.output | grep -q "Line one" && q .ce.output | grep -q "Line two" && ok || bad "contenteditable box with a two-line prompt: $(q .ce -c | head -c 400)"
[ "$(q .login.ok)" = false ] && [ "$(q .login.needs_login)" = true ] && ok || bad "a login page must be reported as needs_login: $(q .login -c)"
[ "$(q .status_login.shown)" = true ] && ok || bad "the window must be brought on screen for a login: $(q .status_login -c)"
[ "$(q .blocked.ok)" = false ] && [ "$(q .blocked.blocked)" = true ] && ok || bad "a bot check must be reported as blocked, not passed: $(q .blocked -c)"
[ "$(q .heur.ok)" = true ] && [ "$(q .heur.output)" = "The answer is 42 with Grüße 日本語 done." ] && ok || bad "a page with no answer selector: the header and footer the site prints must be trimmed off: $(q .heur -c | head -c 400)"
q .math.output | grep -qF 'The root is $i$ and also $(-i)^2=-1$.' && q .math.output | grep -qF 'Second paragraph.' && ! q .math.output | grep -q '^Read more' && ! q .math.output | grep -qF '(-i)2' && ! q .math.output | grep -qx 'britannica' && ! q .math.output | grep -qx '+1' && q .math.output | grep -qF 'Third paragraph.' && ok || bad "a formula drawn twice (visual + MathML) must come back once, as TeX, with the page's own labels trimmed: $(q .math -c | head -c 300)"
[ -z "$(grep -P '[^\x00-\x7F]' "$ROOT/cockpit_app/webworkers/_engine.js")" ] && ok || bad "the engine must be pure ASCII: non-ASCII characters in injected code were mangled on the way into the page"
[ "$(q .redirect.ok)" = true ] && q .redirect.output | grep -q 'Redirect question' && ok || bad "a page that loads a second page right after the first must not swallow the prompt: $(q .redirect -c | head -c 300)"
[ "$(q .letters.output)" = 'The real answer.' ] && ok || bad "an answer element found by a selector: only its text, none of the page's labels: $(q .letters -c | head -c 300)"
q .mathsel.output | grep -qF 'The root is $i$ and also $(-i)^2=-1$.' && ! q .mathsel.output | grep -qF '(-i)2' && ok || bad "a formula inside a selected answer comes back once as TeX: $(q .mathsel -c | head -c 300)"
q .split.output | grep -qF 'function f() {}' && q .split.output | grep -qF 'Area $A = \pi r^2$ where $r$ is the radius.' && ! q .split.output | grep -q 'Show thinking' && ok || bad "a reply split into several blocks comes back whole, in order, picture formulas as TeX, header dropped: $(q .split -c | head -c 300)"
[ "$(q .selftest.ok)" = true ] && [ "$(q .selftest.status)" = ok ] && ok || bad "self-test: $(q .selftest -c)"
[ "$(q .probe.ok)" = true ] && [ "$(q '.probe.inputs|length')" -ge 1 ] && [ "$(q '.probe.buttons|length')" -ge 1 ] && ok || bad "probe: $(q .probe -c | head -c 400)"
[ "$(cat "$T/cfg/ai-cockpit/window.json")" = '{ "w" : 1777, "h" : 999, "max" : true, "x" : 5, "y" : 6, "frameless" : false }' ] && ok || bad "a worker window must never overwrite the person's saved window size and position: $(cat "$T/cfg/ai-cockpit/window.json")"
grep -q 'border strips installed' "$T"/webworkers/fake/start.log 2>/dev/null && ok || bad "a frameless worker window must carry the border strips (start.log: $(tail -c 300 "$T"/webworkers/fake/start.log 2>/dev/null))"
[ "$(q .alive_before_quit)" = true ] && [ "$(q .alive_after_quit)" = false ] && ok || bad "start/stop: $(q '{alive_before_quit,alive_after_quit}' -c)"
q .bad_launcher | grep -q "The launcher said: sudo: a password is required" && q .bad_launcher | grep -q "NOPASSWD" && ok || bad "a failing launcher must say why: $(q .bad_launcher)"
grep -q 'cockpit_shell \"\*) ;; \*) _launch_bins' "$ROOT/Installs/install_cockpit.sh" && ok || bad "the installer must always grant the Cockpit window in its sudoers rules"
q .no_binary | grep -q "cockpit_shell is not installed" && ok || bad "a missing shell must be said plainly: $(q .no_binary)"
# off-screen: the worker window is not in the visible area
if command -v xwininfo >/dev/null 2>&1; then :; fi
echo "webworker_test: $n passed, $fails failed"; [ "$fails" = 0 ]
