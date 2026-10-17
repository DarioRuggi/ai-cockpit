// power_strip_layout_test.js — the Power Buttons strip must not push the prompt area or the status bar off the screen (found on 2026-10-14: a free-standing extra row in the fixed-height footer did exactly that).
// The footer has a FIXED height (so the chat|prompt border lines up with the sidebars); the strip is one fixed row that lives in it, and while buttons exist the footer grows by exactly that row.
// These checks keep the three numbers in step and the strip where it belongs: below the prompt, above the status bar.
const fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..', 'cockpit_app');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8'), css = fs.readFileSync(path.join(root, 'css', 'console.css'), 'utf8');
let n = 0, fails = 0; const ok = (c, m) => { n++; if (!c) { fails++; console.error('  FAIL ' + m); } };
const strip = html.match(/<div id="power-strip"[^>]*style="([^"]*)"/);
ok(!!strip, 'the strip exists in index.html'); const st = strip ? strip[1] : '';
const rowH = (st.match(/(?:^|;)height:(\d+)px/) || [])[1]; ok(!!rowH, 'the strip has a fixed height: ' + st.slice(0, 120));
ok(new RegExp('flex:0 0 ' + rowH + 'px').test(st), 'the strip does not shrink or grow (flex:0 0 ' + rowH + 'px)');
ok(/overflow-x:auto/.test(st) && /overflow-y:hidden/.test(st) && /white-space:nowrap/.test(st), 'many buttons scroll sideways; they never make the row taller');
const footerH = (css.match(/\.footer\s*\{[^}]*?height:\s*(\d+)px/s) || [])[1];
const grown = css.match(/body\.has-power-strip\s+\.footer\s*\{\s*height:\s*calc\(\s*(\d+)px\s*\+\s*(\d+)px\s*\)/);
ok(!!footerH && !!grown, 'the footer rule and the grown-footer rule both exist');
ok(grown && grown[1] === footerH, 'the grown footer starts from the footer height (' + footerH + ') and adds: ' + (grown && grown[1]));
ok(grown && grown[2] === rowH, 'the footer grows by exactly the strip row (' + rowH + 'px), not another number: ' + (grown && grown[2]));
const i = { prompt: html.indexOf('id="prompt-in"'), strip: html.indexOf('id="power-strip"'), dock: html.indexOf('id="dock-bar"'), status: html.indexOf('id="status-bar"'), style: html.indexOf('id="style-strip"') };
ok(i.prompt > 0 && i.strip > i.prompt && i.strip < i.dock && i.dock < i.status, 'the strip sits after the prompt and before the status bar');
ok(i.style > 0 && i.style < i.prompt, 'the Mode and Style rows stay above the prompt');
const js = fs.readFileSync(path.join(root, 'js', 'features', 'power-buttons.js'), 'utf8'), mobile = fs.readFileSync(path.join(root, 'css', 'mobile.css'), 'utf8');
ok(/classList\.toggle\('has-power-strip',\s*show\)/.test(js) && /const show = !!_pw\.data && \(list\.length > 0 \|\| !hintOff\)/.test(js), 'the class that grows the footer is set only while the strip (buttons, or the hint) is shown');
ok(/ck_power_hint_off/.test(js) && /function powerHintHide/.test(js) && /powerOpen\(\)/.test(js.slice(js.indexOf('ui.power.hint.add') - 120, js.indexOf('ui.power.hint.add'))), 'with no buttons a hint stands in the row: an Add one button, and an × that hides it for good');
// the Mode and Style rows: ONE fixed line each (Pipeline/Broadcast/Plan used to wrap them to 34 and 57px and push the status bar off the screen)
ok(/#ma-strip\s*\{\s*height:\s*29px;\s*flex:\s*0 0 29px;\s*\}/.test(css) && /#style-strip\s*\{\s*height:\s*27px;\s*flex:\s*0 0 27px;\s*\}/.test(css), 'the Mode row (29px) and the Style row (27px) have fixed heights');
ok(/#ma-strip,\s*#style-strip\s*\{[^}]*overflow-x:\s*auto;[^}]*overflow-y:\s*hidden;[^}]*white-space:\s*nowrap/.test(css), 'those rows never wrap: too narrow = they scroll sideways');
ok(/#ma-strip,\s*(?:html\.ck-compact\s+)?#style-strip\s*\{[^}]*height:\s*auto !important/.test(mobile), 'on a phone the two rows may wrap again (mobile.css overrides the fixed height)');
ok(/\.footer \{ height: auto !important/.test(mobile), 'on a phone the footer is auto height, so the strip needs nothing extra there');
console.log('power_strip_layout_test: ' + (n - fails) + ' passed, ' + fails + ' failed'); process.exit(fails ? 1 : 0);
