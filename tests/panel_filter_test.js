// panel_filter_test.js — the filter box of the Tools / Workers / Models dropdowns (panelFilter in js/features/ollama-models.js): typing matches an option's own text, AND a group whose
// NAME matches keeps all its options (Dario, 2026-10-11: typing "legal" showed nothing because the presets are called "Check the document", not "Legal ...").
// The function is taken from the real file and run against a hand-made DOM.   node tests/panel_filter_test.js
const fs = require('fs'), path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'cockpit_app', 'js', 'features', 'ollama-models.js'), 'utf8');
const m = src.match(/function panelFilter\(panelId, q\) \{[\s\S]*?\n\}\n/); if (!m) { console.error('panelFilter not found'); process.exit(1); }
let n = 0, fails = 0; const ok = (c, msg) => { n++; if (!c) { fails++; console.error('  FAIL ' + msg); } };
// a tiny DOM
function el(cls, opts = {}) { const e = { classList: { contains: c => cls.split(' ').includes(c) }, style: { display: '' }, dataset: opts.search ? { search: opts.search } : {}, children: [], childNodes: [], nextElementSibling: null, textContent: opts.text || '', _input: !!opts.input, parentNode: null };
    // a real header: the collapse chevron span FIRST, then the name text, then the sort chip (wireCollapsibleGroupHeaders puts the chevron in front)
    if (opts.title) { e.childNodes = [{ nodeType: 1, cls: 'cgh-chevron', text: '▾' }, { nodeType: 3, nodeValue: opts.title + ' ' }, { nodeType: 1, cls: 'sort', text: 'A→Z' }];
        e.cloneNode = () => { const parts = e.childNodes.slice(); return { querySelectorAll: () => ({ forEach: f => parts.filter(x => x.nodeType === 1).forEach(x => { f({ remove: () => parts.splice(parts.indexOf(x), 1) }); }) }), get textContent() { return parts.map(x => x.nodeType === 3 ? x.nodeValue : '').join(''); } }; }; }
    e.querySelector = sel => (sel === 'input' && e._input) ? {} : null; return e; }
function panel(spec) { const p = el('panel'); let prev = null; for (const x of spec) { const c = x.hdr ? el('cs-group-header', { title: x.hdr, input: x.input }) : el('cs-option', { search: x.opt }); if (prev) prev.nextElementSibling = c; p.children.push(c); prev = c; }
    p.querySelectorAll = sel => p.children.filter(c => sel === '.cs-option' ? c.classList.contains('cs-option') : c.classList.contains('cs-group-header')); return p; }
const build = spec => { const p = panel(spec); global.document = { getElementById: () => p }; eval(m[0].replace('function panelFilter', 'global.panelFilter = function')); return p; };
const vis = p => p.children.filter(c => c.style.display !== 'none').map(c => c.classList.contains('cs-group-header') ? '[' + c.childNodes.find(x => x.nodeType === 3).nodeValue.trim() + ']' : c.dataset.search);
const P = () => build([{ hdr: 'x', input: true }, { hdr: 'Legal review' }, { opt: 'legal review check the document' }, { opt: 'legal review compare two versions' }, { hdr: 'Bookkeeping' }, { opt: 'bookkeeping check the ledger' }, { hdr: 'Data' }, { opt: 'data describe every column' }, { opt: 'data first rows' }]);
// the group NAME matches, the option labels do not
let p = P(); panelFilter('p', 'legal'); ok(vis(p).includes('[Legal review]') && vis(p).includes('legal review check the document') && vis(p).includes('legal review compare two versions'), 'a matching group name must keep all its options: ' + vis(p));
ok(!vis(p).includes('[Bookkeeping]') && !vis(p).includes('data first rows'), 'the other groups must be hidden: ' + vis(p));
// a name that matches one group only
p = build([{ hdr: 'x', input: true }, { hdr: 'Data' }, { opt: 'describe every column' }, { opt: 'first rows' }, { hdr: 'Git' }, { opt: 'commit' }]); panelFilter('p', 'data'); ok(vis(p).filter(x => x === 'describe every column' || x === 'first rows').length === 2 && !vis(p).includes('commit'), 'group Data: ' + vis(p));
// the old behaviour stays: an option's own text still matches, and only that option shows
p = P(); panelFilter('p', 'ledger'); ok(vis(p).includes('bookkeeping check the ledger') && vis(p).includes('[Bookkeeping]') && !vis(p).includes('legal review check the document') && !vis(p).includes('[Legal review]'), 'option text: ' + vis(p));
p = P(); panelFilter('p', 'column'); ok(vis(p).includes('data describe every column') && !vis(p).includes('data first rows') && vis(p).includes('[Data]'), 'one option of a group: ' + vis(p));
// an option that matches inside a group whose name does not
p = P(); panelFilter('p', 'check'); ok(vis(p).includes('legal review check the document') && vis(p).includes('bookkeeping check the ledger') && !vis(p).includes('legal review compare two versions'), 'check: ' + vis(p));
// an empty query shows everything again; no match hides everything but the filter box
p = P(); panelFilter('p', 'legal'); panelFilter('p', ''); ok(p.children.every(c => c.style.display !== 'none'), 'an empty query must show everything again');
p = P(); panelFilter('p', 'zzzz'); ok(vis(p).length === 1 && vis(p)[0] === '[x]', 'no match: only the filter header stays: ' + vis(p));
// the sort dropdown text in the header is not part of the group name (the text node stops at the first element)
p = P(); panelFilter('p', 'a→z'); ok(!vis(p).includes('[Legal review]'), 'the sort dropdown label must not count as a group name: ' + vis(p));
console.log('panel_filter_test: ' + (n - fails) + ' passed, ' + fails + ' failed'); process.exit(fails ? 1 : 0);
