// lift_layers_test.js — js/core/dropdown.js ckLiftLayers(): an open card list lifts the layers it sits in and puts them back exactly.   node tests/lift_layers_test.js
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(__dirname + '/../cockpit_app/js/core/dropdown.js', 'utf8');
const m = src.match(/\(function \(\) \{\n    const LIFT_Z[\s\S]*?\n\}\)\(\);\n/);
if (!m) { console.log('FAIL could not find the lift code'); process.exit(1); }
let fails = 0, n = 0; const ok = (name, c) => { n++; if (!c) { fails++; console.log('FAIL ' + name); } };
function node(name, css, parent) { const o = { name, style: { zIndex: css.inlineZ || '', position: css.inlinePos || '' }, parentElement: parent || null, cs: css }; return o; }
const body = { name: 'body' }, html = { name: 'html' };
const topbar = node('topbar', { position: 'relative', zIndex: '10', opacity: '1', transform: 'none', filter: 'none', isolation: 'auto', contain: 'none' }, body);
const card = node('card', { position: 'static', zIndex: 'auto', opacity: '1', transform: 'none', filter: 'none', isolation: 'isolate', contain: 'none' }, topbar);
const plain = node('plain', { position: 'static', zIndex: 'auto', opacity: '1', transform: 'none', filter: 'none', isolation: 'auto', contain: 'none' }, card);
const faded = node('faded', { position: 'static', zIndex: 'auto', opacity: '0.9', transform: 'none', filter: 'none', isolation: 'auto', contain: 'none', inlineZ: '7' }, plain);
const panel = node('panel', {}, faded);
const ctx = { document: { body, documentElement: html, addEventListener() {} }, getComputedStyle: el => el.cs, MutationObserver: function () { this.observe = () => {}; }, HTMLElement: function () {}, window: {} };
ctx.window = ctx; vm.createContext(ctx); vm.runInContext(m[0], ctx);
ctx.ckLiftLayers(panel, true);
ok('a layer made by opacity is lifted and made positioned', faded.style.zIndex === '100000' && faded.style.position === 'relative');
ok('a layer made by isolation is lifted', card.style.zIndex === '100000' && card.style.position === 'relative');
ok('a positioned layer is lifted', topbar.style.zIndex === '100000');
ok('an ordinary element is left alone', plain.style.zIndex === '' && plain.style.position === '');
ctx.ckLiftLayers(panel, true);
ok('lifting twice keeps the first saved values', faded.style.zIndex === '100000');
ctx.ckLiftLayers(panel, false);
ok('closing restores an inline z-index that was there', faded.style.zIndex === '7' && faded.style.position === '');
ok('closing restores the others to empty', card.style.zIndex === '' && card.style.position === '' && topbar.style.zIndex === '');
console.log('lift_layers_test: ' + n + ' checks, ' + fails + ' failure(s)'); process.exit(fails ? 1 : 0);
