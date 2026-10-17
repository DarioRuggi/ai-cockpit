// resize_grips_test.js — the frameless window's border handles (js/core/shell-channel.js: _winGrips / _RESIZE_GRIPS): four corner strips and, on each side, two resize strips with a MOVE strip
// (15% of the side's length) between them. A press on a resize strip hands win_resize {edge} to the shell, on a move strip win_drag; idempotent; removed when the frame comes back.
// The code is taken from the real file and run against a hand-made DOM.   node tests/resize_grips_test.js
const fs = require('fs'), path = require('path');
const src = fs.readFileSync(path.join(__dirname, '..', 'cockpit_app', 'js', 'core', 'shell-channel.js'), 'utf8');
const a = src.indexOf('const _GRIP_MOVE'), b = src.indexOf('function winMinimize()'); if (a < 0 || b < 0) { console.error('grip code not found'); process.exit(1); }
let n = 0, fails = 0; const ok = (c, m) => { n++; if (!c) { fails++; console.error('  FAIL ' + m); } };
const els = [], calls = []; let body;
const mk = tag => { const e = { tag, style: { cssText: '' }, dataset: {}, children: [], listeners: {}, className: '', id: '', appendChild(c) { this.children.push(c); c.parent = this; if (this === body) els.push(c); return c; }, remove() { const i = els.indexOf(this); if (i >= 0) els.splice(i, 1); }, addEventListener(t, f) { this.listeners[t] = f; } }; return e; };
body = mk('body'); const document = { body, createElement: mk, getElementById: id => els.find(e => e.id === id) || null };
const shellCall = (cmd, arg) => { calls.push([cmd, arg]); return Promise.resolve({}); };
eval(src.slice(a, b) + '; globalThis.__g = { _RESIZE_GRIPS, _winGrips };');
const G = globalThis.__g, GRIPS = G._RESIZE_GRIPS;
const moves = GRIPS.filter(g => g[0] === 'move'), resizes = GRIPS.filter(g => g[0] !== 'move');
ok(GRIPS.length === 16 && moves.length === 4 && resizes.length === 12, '4 corners + 4 sides x (2 resize + 1 move) = 16 strips: ' + GRIPS.length);
ok(new Set(resizes.map(g => g[0])).size === 8 && resizes.every(g => Number.isInteger(g[0]) && g[0] >= 0 && g[0] <= 7), 'the resize strips cover all eight GdkWindowEdge values');
ok(resizes.every(g => /resize$/.test(g[1])) && moves.every(g => g[1] === 'move'), 'resize cursors on the resize strips, a move cursor on the move strips');
ok(moves.every(g => /(left|top):42\.5%;(width|height):15%/.test(g[2])), 'each move strip is the middle 15% of its side (from 42.5% to 57.5%): ' + moves.map(g => g[2]).join(' | '));
// the two resize strips of a side stop where the move strip starts: no overlap
const top = GRIPS.filter(g => /^top:0;left:/.test(g[2]) && g[0] !== 0 && g[0] !== 2);
ok(top.length === 3, 'three strips on the top side');
G._winGrips(true); const box = document.getElementById('ck-resize-grips'); ok(box && box.children.length === 16, 'on: a box with sixteen strips');
G._winGrips(true); ok(els.filter(e => e.id === 'ck-resize-grips').length === 1, 'on twice: still one box');
const press = (el, button = 0) => { let p = false, s = false; el.listeners.mousedown({ button, preventDefault() { p = true; }, stopPropagation() { s = true; } }); return p && s; };
const se = box.children.find(c => String(c.dataset.edge) === '7'); calls.length = 0; const swallowed = press(se);
ok(calls.length === 1 && calls[0][0] === 'win_resize' && calls[0][1].edge === 7, 'a press on the south-east corner asks for win_resize edge 7: ' + JSON.stringify(calls));
ok(swallowed, 'the press must not reach the page underneath');
const mv = box.children.find(c => c.dataset.edge === 'move'); calls.length = 0; press(mv);
ok(calls.length === 1 && calls[0][0] === 'win_drag' && calls[0][1] === undefined, 'a press on a move strip asks for win_drag (and never win_resize): ' + JSON.stringify(calls));
calls.length = 0; press(mv, 2); press(se, 1); ok(calls.length === 0, 'only the main button works');
ok(box.children.every(c => /position:fixed/.test(c.style.cssText) && /z-index:2147483000/.test(c.style.cssText) && /background:transparent/.test(c.style.cssText)), 'strips are fixed, on top and invisible');
G._winGrips(false); ok(!document.getElementById('ck-resize-grips'), 'off: the box is gone'); G._winGrips(false); ok(true, 'off twice: no error');
console.log('resize_grips_test: ' + (n - fails) + ' passed, ' + fails + ' failed'); process.exit(fails ? 1 : 0);
