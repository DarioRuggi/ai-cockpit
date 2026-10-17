#!/usr/bin/env bash
# kinds_user_test.sh — the user's own project kinds: the user folder next to the shipped ones, validation, override, import/export,
# the tools report, and the tools line in the standing note. Real files.php behind aicserver + php-cgi in a throw-away data folder.
#   bash tests/kinds_user_test.sh      needs php, php-cgi, curl, jq; SKIPPED without them or without aicserver.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AS="${AICSERVER:-$HOME/aicockpit-runtime/aicserver/bin/aicserver}"; PHPCGI="$(command -v php-cgi)"
[ -x "$AS" ] && [ -n "$PHPCGI" ] && command -v php curl jq >/dev/null || { echo "kinds_user_test: needs aicserver, php-cgi, php, curl, jq - SKIPPED"; exit 0; }
T=$(mktemp -d /tmp/ku_XXXX) || exit 1; PIDS=""; CGI=0
trap 'for p in $PIDS; do kill $p 2>/dev/null; done; sleep 0.3; pkill -KILL -P $CGI 2>/dev/null; rm -rf "${T:?}"' EXIT
fails=0; n=0; ok() { n=$((n+1)); }; bad() { echo "  FAIL $1"; fails=$((fails+1)); }
W="$T/web"; D="$T/data"; mkdir -p "$W" "$D" "$T/sess" "$T/proj"; cp -r "$ROOT/cockpit_app/." "$W/"
printf '{"home":"%s","cockpit_data":"%s","cockpit_data_root":"%s","projects_root":"%s/proj","tmux_socket":"%s/t.sock","queue_dir":"%s/q","response_dir":"%s/r"}' "$T" "$D" "$D" "$T" "$T" "$T" "$T" > "$W/paths.json"; echo v2 > "$W/.edition"
PHP_FCGI_CHILDREN=3 "$PHPCGI" -b "$T/php.sock" -d "session.save_path=$T/sess" >"$T/cgi.log" 2>&1 & CGI=$!; PIDS="$PIDS $CGI"
PORT=$((20000 + RANDOM % 20000))
jq -n --argjson port "$PORT" --arg root "$W" --arg php "unix:$T/php.sock" '{listen:{host:"127.0.0.1",port:$port},allowed_hosts:["localhost","127.0.0.1"],mounts:[{prefix:"/cockpit",root:$root,index:["index.php","index.html"]}],php:{extensions:[".php"],fastcgi:$php,idle_timeout_s:60},deny:[".*"],limits:{max_body_mb:8}}' > "$T/srv.json"
"$AS" run --config "$T/srv.json" >"$T/srv.log" 2>&1 & PIDS="$PIDS $!"
U="http://127.0.0.1:$PORT/cockpit"
for i in $(seq 50); do [ -S "$T/php.sock" ] && break; sleep 0.2; done
for i in $(seq 40); do curl -s -o /dev/null "$U/" && break; sleep 0.2; done
r0=$(curl -s -X POST -H "Content-Type: application/json" -d "{\"username\":\"tester\",\"password\":\"test-pw-123\"}" "$U/auth.php?action=setup"); echo "$r0" | jq -e .ok >/dev/null || { echo "setup failed: [$r0] $(tail -2 "$T/srv.log") $(tail -2 "$T/cgi.log")"; exit 1; }
curl -s -c "$T/jar" -X POST -H 'Content-Type: application/json' -d '{"username":"tester","password":"test-pw-123"}' "$U/auth.php?action=login" | jq -e .ok >/dev/null || { echo "login failed"; exit 1; }
get() { curl -s -b "$T/jar" "$U/files.php?$1"; }
post() { curl -s -b "$T/jar" -X POST -H 'Content-Type: application/json' -d "$1" "$U/files.php"; }

r=$(get action=kinds)
[ "$(echo "$r" | jq '[.kinds[]|select(.source=="shipped")]|length')" -ge 14 ] && [ "$(echo "$r" | jq '[.kinds[]|select(.source=="user")]|length')" = 0 ] && ok || bad "the shipped kinds are not all listed first: $(echo "$r" | jq -c '[.kinds[].id]')"
[ "$(echo "$r" | jq -r '.kinds[0].id')" = general ] && ok || bad "general is not first"
# save
r=$(post '{"action":"kind_save","kind":{"id":"subtitling","name":"Subtitling","icon":"subtitles","description":"Subtitles for video","note":"This is a subtitling project. Keep timing exact.","detect":["*.srt","*.vtt"],"verify":"ffmpeg burn-in","tools":[{"tool":"ffmpeg","why":"mux and burn in"},{"tool":"whisper"},{"tool":"nosuchtool","why":"x"}],"junk":"dropped"}}')
[ "$(echo "$r" | jq -r .ok)" = true ] && ok || bad "save a valid kind: $r"
KD=$(dirname "$(find "$D" -name subtitling.json 2>/dev/null | head -1)")
[ -f "$KD/subtitling.json" ] && ok || bad "the kind file is not in the user folder ($KD)"
[ "$(jq 'has("junk")' "$KD/subtitling.json" 2>/dev/null)" = false ] && ok || bad "an unknown field was kept"
r=$(get action=kinds); row=$(echo "$r" | jq -c '.kinds[]|select(.id=="subtitling")')
[ "$(echo "$row" | jq -r .source)" = user ] && [ "$(echo "$row" | jq -r .note | head -c 19)" = "This is a subtitlin" ] && ok || bad "the user kind is not listed with its note: $row"
[ "$(echo "$row" | jq '.tools|length')" = 3 ] && ok || bad "tools report length: $(echo "$row" | jq -c .tools)"
[ "$(echo "$row" | jq -r '.tools[]|select(.tool=="ffmpeg")|.installed')" = "$(command -v ffmpeg >/dev/null && echo true || echo false)" ] && ok || bad "ffmpeg installed flag is wrong"
[ "$(echo "$row" | jq -r '.tools[]|select(.tool=="nosuchtool")|.known')" = false ] && ok || bad "an unknown tool is reported as known"
[ "$(echo "$row" | jq -r .tools_missing)" -ge 1 ] && ok || bad "tools_missing is not counted"
# the new fields (group, details, examples) survive save, list, export and import; every shipped kind has them
r=$(post '{"action":"kind_save","kind":{"id":"gdemo","name":"G demo","group":"Media","details":"Long text here.","examples":["one","two","","three"]}}'); [ "$(echo "$r" | jq -c '.kind|[.group,.details,.examples]')" = '["Media","Long text here.",["one","two","three"]]' ] && ok || bad "group/details/examples not kept: $r"
row=$(get action=kinds | jq -c '.kinds[]|select(.id=="gdemo")'); [ "$(echo "$row" | jq -r .group)" = Media ] && [ "$(echo "$row" | jq '.examples|length')" = 3 ] && ok || bad "the new fields are not listed: $row"
r=$(post '{"action":"kind_save","kind":{"id":"gbad","name":"x","group":"<script>"}}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "a group name with markup was accepted"
[ "$(get action=kinds | jq '[.kinds[]|select(.source=="shipped")|select((.group|length)>0 and (.details|length)>50 and (.examples|length)>=2)]|length')" -ge 14 ] && ok || bad "not every shipped kind has a group, details and examples"
rm -f "$KD/gdemo.json"
# validation
for bad_json in '{"id":"Bad Id","name":"x"}' '{"id":"ok1","name":""}' '{"id":"ok2","name":"x","detect":["../etc/passwd"]}' '{"id":"ok3","name":"x","detect":["/abs/path"]}' '{"id":"ok4","name":"x","tools":[{"tool":"fpc","command":"rm -rf /"}]}' '{"id":"ok5","name":"x","tools":[{"tool":"Bad Tool"}]}' '{"id":"ok6","name":"x","tools":[{"tool":"fpc","definition":{"binary":"sh"}}]}'; do
    r=$(post "{\"action\":\"kind_save\",\"kind\":$bad_json}"); [ "$(echo "$r" | jq -r .ok)" = false ] && [ -n "$(echo "$r" | jq -r .error)" ] && ok || bad "accepted: $bad_json -> $r"
done
ls "$KD" | grep -E '^ok[0-9]|bad' >/dev/null && bad "a refused kind left a file" || ok
# override a shipped kind, then delete the override
r=$(post '{"action":"kind_save","kind":{"id":"lazarus","name":"Lazarus (mine)","note":"my note"}}'); [ "$(echo "$r" | jq -r .overrides_shipped)" = true ] && ok || bad "override flag: $r"
row=$(get action=kinds | jq -c '.kinds[]|select(.id=="lazarus")'); [ "$(echo "$row" | jq -r '.source+" "+.name+" "+(.overrides|tostring)')" = "user Lazarus (mine) true" ] && ok || bad "the override is not listed: $row"
r=$(post '{"action":"kind_delete","id":"lazarus"}'); [ "$(echo "$r" | jq -r .ok)" = true ] && ok || bad "delete an override: $r"
row=$(get action=kinds | jq -c '.kinds[]|select(.id=="lazarus")'); [ "$(echo "$row" | jq -r .source)" = shipped ] && ok || bad "the shipped kind did not come back: $row"
r=$(post '{"action":"kind_delete","id":"research"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "a shipped kind was deletable: $r"
r=$(post '{"action":"kind_delete","id":"../x"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "a bad id was accepted by delete"
[ -f "$W/kinds/research.json" ] && ok || bad "the shipped kind file is gone"
# export / import round trip
ex=$(get "action=kind_export&id=subtitling"); [ "$(echo "$ex" | jq -r .ok)" = true ] && ok || bad "export: $ex"
echo "$ex" | jq -e '.kind|has("_source")|not' >/dev/null && ok || bad "export leaks internal fields"
kj=$(echo "$ex" | jq -c .kind); cp "$KD/subtitling.json" "$T/before.json"
r=$(post "$(jq -nc --arg j "$kj" '{action:"kind_import",json:$j}')"); [ "$(echo "$r" | jq -r .exists)" = true ] && [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "an import over an existing kind must ask: $r"
r=$(post "$(jq -nc --arg j "$kj" '{action:"kind_import",json:$j,overwrite:true}')"); [ "$(echo "$r" | jq -r .ok)" = true ] && ok || bad "import with overwrite: $r"
cmp -s "$T/before.json" "$KD/subtitling.json" && ok || bad "export -> import is not byte-identical"
r=$(post '{"action":"kind_import","json":"not json"}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "garbage import accepted"
# a broken file in the folder is reported, not served
echo '{ not json' > "$KD/broken.json"; printf '{"id":"other","name":"X"}' > "$KD/wrongname.json"
r=$(get action=kinds); [ "$(echo "$r" | jq '[.problems[].file]|sort|join(",")' -r)" = "broken.json,wrongname.json" ] && ok || bad "problems list: $(echo "$r" | jq -c .problems)"
[ "$(echo "$r" | jq '[.kinds[]|select(.id=="other")]|length')" = 0 ] && ok || bad "a file whose name is not its id was loaded"
rm -f "$KD/broken.json" "$KD/wrongname.json"
# the tools line in the standing note
post '{"action":"new_project","name":"kindproj"}' >/dev/null
post '{"action":"kind_save","kind":{"id":"fpcdemo","name":"Fpc demo","note":"Judge by the compiler.","tools":[{"tool":"fpc"}]}}' >/dev/null
r=$(post '{"action":"set_project_meta","project":"kindproj","kind":"fpcdemo"}')
if command -v fpc >/dev/null 2>&1; then
    echo "$r" | jq -r '.meta.kind_note' | grep -q 'Tools you can run here (as %%TOOL:id:preset:path%%, or %%TOOL:id:preset:path|name=value%% when a preset needs arguments): fpc:check, fpc:compile' && ok || bad "no tools line in the note: $(echo "$r" | jq -r .meta.kind_note)"
fi
echo "$r" | jq -r '.meta.kind_note' | grep -q '^Judge by the compiler\.' && ok || bad "the note itself is missing: $r"
# starter files: preview writes nothing, confirm writes only what is new, an existing file is never touched, nothing escapes the project
PD=$(find "$T" -type d -name kindproj -not -path "*/web/*" | head -1)
r=$(post '{"action":"kind_starter","id":"research","project":"kindproj","confirm":false}')
[ "$(echo "$r" | jq -r '[.files[]|select(.status=="new")]|length')" = 3 ] && [ ! -e "$PD/question.md" ] && ok || bad "preview must list 3 new files and write none: $r"
printf 'MY OWN QUESTION\n' > "$PD/question.md"
r=$(post '{"action":"kind_starter","id":"research","project":"kindproj","confirm":true}')
[ "$(echo "$r" | jq -r '[.files[]|select(.status=="created")]|length')" = 2 ] && [ "$(echo "$r" | jq -r '[.files[]|select(.status=="exists")]|length')" = 1 ] && ok || bad "confirm: 2 created, 1 left alone: $r"
[ "$(cat "$PD/question.md")" = "MY OWN QUESTION" ] && ok || bad "an existing file was overwritten"
[ -f "$PD/sources.md" ] && [ -f "$PD/log.md" ] && ok || bad "the new files are missing"
r=$(post '{"action":"kind_starter","id":"writing","project":"kindproj","confirm":true}'); [ -f "$PD/chapters/01.md" ] && ok || bad "a file in a sub-folder: $r"
r=$(post '{"action":"kind_starter","id":"general","project":"kindproj","confirm":true}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "a kind with no starter must be refused"
r=$(post '{"action":"kind_starter","id":"research","project":"_standalone","confirm":true}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "free chats have no project folder"
r=$(post '{"action":"kind_starter","id":"research","project":"nosuchproject","confirm":true}'); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "an unknown project must be refused"
# the validator: bad paths are refused when a kind is saved
for p in '../evil.md' '/etc/passwd' 'a/../b.md' 'x//y.md' 'dir/'; do r=$(post "$(jq -n --arg p "$p" '{action:"kind_save",kind:{id:"badstart",name:"Bad",note:"x",starter:[{path:$p,content:"x"}]}}')"); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "starter path accepted: $p"; done
r=$(post "$(jq -n --arg c "$(head -c 20001 /dev/zero | tr '\0' a)" '{action:"kind_save",kind:{id:"bigstart",name:"Big",note:"x",starter:[{path:"a.md",content:$c}]}}')"); [ "$(echo "$r" | jq -r .ok)" = false ] && ok || bad "a 20001-character starter file was accepted"
# a symlink inside the project that points outside must not let a starter file out
mkdir -p "$T/outside"; ln -sfn "$T/outside" "$PD/chapters2"
post '{"action":"kind_save","kind":{"id":"linkstart","name":"Link","note":"x","starter":[{"path":"chapters2/x.md","content":"leak"}]}}' >/dev/null
r=$(post '{"action":"kind_starter","id":"linkstart","project":"kindproj","confirm":true}'); [ ! -e "$T/outside/x.md" ] && [ "$(echo "$r" | jq -r '.files[0].status')" = refused ] && ok || bad "a symlink let a starter file out of the project: $r"
# the starter survives export -> import
post '{"action":"kind_save","kind":{"id":"startkind","name":"Start kind","note":"x","starter":[{"path":"a.md","content":"hello\nworld"}]}}' >/dev/null
e=$(get 'action=kind_export&id=startkind'); [ "$(echo "$e" | jq -r '.kind.starter[0].content')" = "$(printf 'hello\nworld')" ] && ok || bad "export lost the starter: $e"
r=$(get action=kinds); [ "$(echo "$r" | jq -r '[.kinds[]|select(.id=="writing")][0].starter|length')" = 4 ] && ok || bad "the list must carry the starter paths"
# a kind that carries its own tool: shown and confirmed first, strict commands only, never replaces a built-in, survives the wizard's re-save
TD='{"id":"copykit","name":"Copy kit","binary":"cp","presets":[{"id":"dup","label":"Make a copy","command":"cp {INPUT} {OUTPUT}","output_ext":"txt","input_kinds":["file"]}]}'
KJ=$(jq -n --argjson t "$TD" '{id:"toolkind",name:"Tool kind",note:"A kind with its own tool.",tool_defs:[$t]}')
r=$(post "$(jq -n --arg j "$KJ" '{action:"kind_import",json:$j}')")
[ "$(echo "$r" | jq -r .needs_confirm_tools)" = true ] && [ "$(echo "$r" | jq -r '.tools[0].commands[0]')" = "cp {INPUT} {OUTPUT}" ] && ok || bad "an import with a tool must ask first and show the command: $r"
[ -z "$(find "$D" -name copykit.json 2>/dev/null)" ] && [ "$(get action=kinds | jq '[.kinds[]|select(.id=="toolkind")]|length')" = 0 ] && ok || bad "nothing may be written before the person agrees"
r=$(post "$(jq -n --arg j "$KJ" '{action:"kind_import",json:$j,confirm_tools:true}')")
[ "$(echo "$r" | jq -r .ok)" = true ] && ok || bad "confirmed import: $r"
TF=$(find "$D" -name copykit.json | head -1); [ -n "$TF" ] && [ "$(jq -r .custom "$TF")" = true ] && [ "$(jq -r ._from_kind "$TF")" = toolkind ] && ok || bad "the tool file is missing or not marked as the kind's"
[ "$(get action=kinds | jq -r '[.kinds[]|select(.id=="toolkind")][0].tools[0].tool')" = copykit ] && ok || bad "the kind must name its tool"
curl -s -b "$T/jar" "$U/tools.php?action=presets" | grep -q '"copykit' && ok || bad "the tool must show up in the Tools presets: $(curl -s -b "$T/jar" "$U/tools.php?action=presets" | head -c 200)"
r=$(post '{"action":"kind_save","kind":{"id":"toolkind","name":"Tool kind renamed","note":"changed in the wizard"}}'); e=$(get 'action=kind_export&id=toolkind')
[ "$(echo "$e" | jq -r '.kind.tool_defs[0].id')" = copykit ] && [ "$(echo "$e" | jq -r .kind.name)" = "Tool kind renamed" ] && ok || bad "the wizard re-save lost the tool: $e"
# strict validation
tryk() { local t="$1" want="$2" msg="$3"; r=$(post "$(jq -n --argjson t "$t" '{action:"kind_import",json:({id:"badtool",name:"Bad",note:"x",tool_defs:[$t]}|tojson),confirm_tools:true}')"); [ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -qi "$want" && ok || bad "$msg was accepted or gave the wrong reason: $r"; }
tryk '{"id":"t1","binary":"bash","presets":[{"id":"a","command":"bash {INPUT} {OUTPUT}"}]}' "shell, interpreter" "a shell as the binary"
tryk '{"id":"t2","binary":"cp","presets":[{"id":"a","command":"cp {INPUT} {OUTPUT}; rm -rf x"}]}' "plain words" "a command with ;"
tryk '{"id":"t3","binary":"cp","presets":[{"id":"a","command":"cp {INPUT} $(id) {OUTPUT}"}]}' "plain words" "a command with a substitution"
tryk '{"id":"t4","binary":"cp","presets":[{"id":"a","command":"cp {INPUT} {OUTPUT} > /etc/x"}]}' "plain words" "a redirect"
tryk '{"id":"t5","binary":"cp","presets":[{"id":"a","command":"cp {WEBROOT}/x {OUTPUT}"}]}' "unknown placeholder" "a helper script placeholder"
tryk '{"id":"t6","binary":"cp","presets":[{"id":"a","command":"cp {INPUT}"}]}' "needs both" "a command with no output"
tryk '{"id":"t7","binary":"cp","presets":[{"id":"a","command":"mv {INPUT} {OUTPUT}"}]}' "must start with" "a command that does not start with the binary"
tryk '{"id":"ffmpeg","binary":"cp","presets":[{"id":"a","command":"cp {INPUT} {OUTPUT}"}]}' "ships with Cockpit" "a built-in tool id"
tryk '{"id":"t8","binary":"find","presets":[{"id":"a","command":"find {INPUT} -exec {OUTPUT}"}]}' "runs another command" "find -exec"
tryk '{"id":"t9","binary":"/bin/cp","presets":[{"id":"a","command":"/bin/cp {INPUT} {OUTPUT}"}]}' "plain program name" "a binary with a path"
tryk '{"id":"t10","binary":"cp","presets":[{"id":"a","command":"cp ../{INPUT} {OUTPUT}"}]}' "plain words" "a .. in a command"
tryk '{"id":"t11","binary":"cp","presets":[]}' "at least one preset" "no presets"
# another kind may not take over a tool id that belongs to a kind already
KJ2=$(jq -n --argjson t "$TD" '{id:"thief",name:"Thief",note:"x",tool_defs:[$t]}'); r=$(post "$(jq -n --arg j "$KJ2" '{action:"kind_import",json:$j,confirm_tools:true}')")
[ "$(echo "$r" | jq -r .ok)" = false ] && echo "$r" | jq -r .error | grep -q "already in your tools" && ok || bad "a second kind took over the tool: $r"
# the same validator without the endpoint (what the marketplace install uses)
php -r 'require $argv[1]; $e=""; $k=kind_validate(["id"=>"mk","name"=>"Mk","note"=>"n","tool_defs"=>[["id"=>"mktool","binary"=>"cp","presets"=>[["id"=>"a","command"=>"cp {INPUT} {OUTPUT}"]]]]],$e); echo ($k && $k["tools"][0]["tool"]==="mktool") ? "ok" : "no:$e";' "$ROOT/cockpit_app/kinds_lib.php" | grep -q '^ok$' && ok || bad "kinds_lib.php alone must validate a kind with a tool"
grep -q "case 'kind'" "$ROOT/cockpit_app/mkt_install.php" && ok || bad "the marketplace install has no kind case"
# the wizard can remove a kind's tools explicitly (drop_tools); a plain re-save keeps them
r=$(post '{"action":"kind_save","kind":{"id":"toolkind","name":"Tool kind again","note":"x"}}'); e=$(get 'action=kind_export&id=toolkind')
[ "$(echo "$e" | jq -r '.kind.tool_defs[0].id')" = copykit ] && ok || bad "a plain re-save must keep the tools: $e"
r=$(post '{"action":"kind_save","kind":{"id":"toolkind","name":"Tool kind no tools","note":"x"},"drop_tools":true}'); e=$(get 'action=kind_export&id=toolkind')
[ "$(echo "$e" | jq -r '.kind.tool_defs // "none"')" = none ] && [ "$(echo "$e" | jq -r '[.kind.tools[]?|select(.tool=="copykit")]|length')" = 0 ] && ok || bad "drop_tools must remove the kind's tool definitions and its tool entry: $e"
# the wizard sends starter + tool_defs in one save; starter [] clears
r=$(post '{"action":"kind_save","kind":{"id":"wizkind","name":"Wiz kind","note":"x","starter":[{"path":"a.md","content":"one"},{"path":"d/b.md","content":"two"}]}}'); [ "$(echo "$r" | jq -r .ok)" = true ] && [ "$(get 'action=kind_export&id=wizkind' | jq -r '.kind.starter|length')" = 2 ] && ok || bad "wizard save with starter files: $r"
post '{"action":"kind_save","kind":{"id":"wizkind","name":"Wiz kind","note":"x","starter":[]}}' >/dev/null; [ "$(get 'action=kind_export&id=wizkind' | jq -r '.kind.starter // "none"')" = none ] && ok || bad "an empty starter list must clear the starter files"
echo "kinds_user_test: $n passed, $fails failed"; [ "$fails" = 0 ]
