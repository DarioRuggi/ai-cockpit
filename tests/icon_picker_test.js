// icon_picker_test.js — the shared icon picker (cockpit_app/js/core/icon-picker.js): the search, the field markup, and — the one that matters — that every icon the picker SUGGESTS exists in the icon font Cockpit carries
// (a name that is not in the font is drawn as plain text, "mark_email_read", instead of a picture, and nothing errors).
const fs = require('fs'), path = require('path');
const root = path.join(__dirname, '..', 'cockpit_app');
const src = fs.readFileSync(path.join(root, 'js', 'core', 'icon-picker.js'), 'utf8');
const names = fs.readFileSync(path.join(root, 'assets', 'fonts', 'material-symbols.names'), 'utf8').split('\n').map(s => s.trim()).filter(Boolean);
let n = 0, fails = 0; const ok = (c, m) => { n++; if (!c) { fails++; console.error('  FAIL ' + m); } };
const T = (k, d, v) => (v ? d.replace(/\{(\w+)\}/g, (x, y) => v[y]) : d);
const g = new Function('T', src + '; return { ckIconSearch, ckIconFieldHtml, SUGG: _CK_ICON_SUGGESTED, IDEAS: _CK_ICON_IDEAS };')(T);
const set = new Set(names);
ok(names.length > 4000, 'the vendored icon list is the whole catalogue: ' + names.length);
const missing = g.SUGG.filter(x => !set.has(x)); ok(!missing.length, 'every SUGGESTED icon exists in the font: ' + missing.join(', '));
const miss2 = []; for (const [k, v] of Object.entries(g.IDEAS)) for (const x of v) if (!set.has(x)) miss2.push(k + ':' + x); ok(!miss2.length, 'every icon behind a plain idea exists in the font: ' + miss2.join(', '));
ok(new Set(g.SUGG).size === g.SUGG.length, 'no icon is suggested twice');
let r = g.ckIconSearch(names, 'write'); ok(r.length > 5 && r.includes('edit') && r.includes('draw'), 'a plain idea ("write") finds edit and draw: ' + r.slice(0, 6));
r = g.ckIconSearch(names, 'mail'); ok(r.includes('mail') && r.some(x => /mail/.test(x)) && r[0].includes('mail'), 'a word finds names that hold it: ' + r.slice(0, 4));
r = g.ckIconSearch(names, 'FIX'); ok(r.includes('build') && r.includes('auto_fix_high'), 'upper case and ideas: ' + r.slice(0, 5));
r = g.ckIconSearch(names, 'format list'); ok(r.length > 0 && r.every(x => /format/.test(x) && /list/.test(x) || Object.values(g.IDEAS).flat().includes(x)), 'two words must both be in the name (or come from an idea)');
r = g.ckIconSearch(names, 'zzzzqx'); ok(r.length === 0, 'nothing matches nonsense');
ok(g.ckIconSearch(names, '').length === 0 && g.ckIconSearch(names, '   ').length === 0, 'an empty search is empty (the picker then shows the suggested set)');
r = g.ckIconSearch(names, 'heart'); ok(r.some(x => x.startsWith('heart')), 'heart: names starting with it come out: ' + r.slice(0, 4));
r = g.ckIconSearch(names, 'print'); ok(r.length > 0 && r[0].startsWith('print'), 'print: starts-with comes first: ' + r.slice(0, 3));
r = g.ckIconSearch(names, 'translate'); ok(new Set(r).size === r.length, 'no icon twice in the results');
const h = g.ckIconFieldHtml('pw-icon', 'spellcheck'); ok(/<input type="hidden" id="pw-icon" value="spellcheck">/.test(h) && /ckIconPickerOpen\('pw-icon'\)/.test(h) && />spellcheck</.test(h), 'the field: a hidden input holding the name + a button showing it');
ok(/value="bolt"/.test(g.ckIconFieldHtml('x', '"><script>alert(1)</script>')) && !/<script>/.test(g.ckIconFieldHtml('x', '"><script>')), 'a hostile or invalid name falls back to bolt and is never put into the markup');
ok(/value="bolt"/.test(g.ckIconFieldHtml('x', '')) && /value="folder"/.test(g.ckIconFieldHtml('x', 'folder')), 'empty -> bolt, a real name is kept');
console.log('icon_picker_test: ' + (n - fails) + ' passed, ' + fails + ' failed'); process.exit(fails ? 1 : 0);
