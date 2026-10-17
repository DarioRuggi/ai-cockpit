// kind_wizard_test.js — the kind wizard's two advanced fields (js/chat/input.js: _kwStarter, _kwTools): starter rows and the tools JSON. Taken from the real file.   node tests/kind_wizard_test.js
const fs = require('fs'), path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'cockpit_app', 'js', 'chat', 'input.js'), 'utf8');
const a = src.indexOf('function _kwStarter'), b = src.indexOf('async function kindWizard'); if (a < 0 || b < 0) { console.error('wizard helpers not found'); process.exit(1); }
let n = 0, fails = 0; const ok = (c, m) => { n++; if (!c) { fails++; console.error('  FAIL ' + m); } };
const T = (k, d, v) => (v ? d.replace(/\{(\w+)\}/g, (x, y) => v[y]) : d);
eval(src.slice(a, b) + '; globalThis.__w = { _kwStarter, _kwTools };'); const W = globalThis.__w;
let r = W._kwStarter([{ path: 'outline.md', content: '# Outline' }, { path: '', content: '' }, { path: 'chapters/01.md', content: '' }]);
ok(r.list && r.list.length === 2 && r.list[0].path === 'outline.md' && r.list[1].path === 'chapters/01.md', 'good rows kept, an empty row dropped: ' + JSON.stringify(r));
ok(W._kwStarter([]).list.length === 0 && W._kwStarter(null).list.length === 0, 'no rows: an empty list');
for (const p of ['../evil.md', '/etc/passwd', 'a/../b.md', 'x//y.md', 'dir/', 'bad|name', '.hidden/../x']) ok(!!W._kwStarter([{ path: p, content: 'x' }]).error, 'path refused: ' + p);
ok(!!W._kwStarter([{ path: '', content: 'text without a name' }]).error, 'text but no file name is an error');
ok(!!W._kwStarter([{ path: 'a.md', content: 'x'.repeat(20001) }]).error, 'over 20000 characters refused');
ok(!!W._kwStarter(Array.from({ length: 13 }, (_, i) => ({ path: 'f' + i + '.md', content: 'x' }))).error, 'more than 12 files refused');
ok(W._kwStarter(Array.from({ length: 12 }, (_, i) => ({ path: 'f' + i + '.md', content: 'x' }))).list.length === 12, 'exactly 12 files is fine');
ok(W._kwTools('').list.length === 0 && W._kwTools('   ').list.length === 0, 'empty tools box: none');
ok(W._kwTools('[{"id":"copykit","binary":"cp","presets":[]}]').list.length === 1, 'a valid list is passed on');
ok(/not valid JSON/.test(W._kwTools('[{"id":').error), 'broken JSON gets a message: ' + W._kwTools('[{"id":').error);
ok(/must hold a list/.test(W._kwTools('{"id":"x"}').error), 'an object instead of a list is refused');
ok(/At most 4/.test(W._kwTools('[{},{},{},{},{}]').error), 'more than 4 tools refused');
console.log('kind_wizard_test: ' + (n - fails) + ' passed, ' + fails + ' failed'); process.exit(fails ? 1 : 0);
