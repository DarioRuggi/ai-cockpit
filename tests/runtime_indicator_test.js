// runtime_indicator_test.js — js/core/status.js updateRuntime(): what the status bar says about the runtime in use.   node tests/runtime_indicator_test.js
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(__dirname + '/../cockpit_app/js/core/status.js', 'utf8');
const m = src.match(/function updateRuntime\(rt\) \{[\s\S]*?\n\}\n/);
if (!m) { console.log('FAIL could not find updateRuntime'); process.exit(1); }
let fails = 0, n = 0; const ok = (name, c) => { n++; if (!c) { fails++; console.log('FAIL ' + name); } };
function mk() { const els = {}; ['claude', 'gemini', 'ollama'].forEach(a => els['rt-' + a] = { style: { display: 'none' }, textContent: '', title: '', classList: { s: new Set(), toggle(c, on) { on ? this.s.add(c) : this.s.delete(c); } } });
    els['rt-chip'] = { style: { display: 'none' }, title: '' }; for (const id of ['rt-eng', 'rt-sch', 'rt-web']) els[id] = { style: { display: '' }, textContent: '', classList: { s: new Set(), toggle(c, on) { on ? this.s.add(c) : this.s.delete(c); } } };
    els.chipText = () => [els['rt-eng'], els['rt-sch'], els['rt-web']].filter(x => x.textContent && x.style.display !== 'none').map(x => x.textContent).join(' · '); return els; }
function run(rt) { const els = mk(); const ctx = { document: { getElementById: id => els[id] || null }, T: (k, d, p) => d.replace(/\{(\w+)\}/g, (_, x) => (p || {})[x]) };
    vm.createContext(ctx); vm.runInContext(m[0], ctx); ctx.updateRuntime(rt); return els; }
const full = { host: 'supervisor', agents: { claude: { host: 'supervisor', loop: 'shell', pid: 11 }, gemini: { host: 'supervisor', loop: 'shell', pid: 12 }, ollama: { host: 'supervisor', loop: 'native', pid: 13 } },
    engine: { on: true, installed: true }, switches: ['use_native_loop_ollama'], scheduler: 'supervisor' };
let e = run(full);
ok('ollama tag says just native (the supervisor is in the hover)', e['rt-ollama'].textContent === 'native');
ok('claude tag says just shell', e['rt-claude'].textContent === 'shell');
ok('native tag is marked', e['rt-ollama'].classList.s.has('native') && !e['rt-claude'].classList.s.has('native'));
ok('tags are visible', e['rt-ollama'].style.display === '' && e['rt-gemini'].style.display === '');
ok('tooltip names the loop, the host and the pid', /native loop/.test(e['rt-ollama'].title) && /supervisor/.test(e['rt-ollama'].title) && /pid 13/.test(e['rt-ollama'].title));
ok('chip says engine on, scheduler supervisor', e.chipText() === 'on · sup' && e['rt-chip'].style.display === '');
ok('each of the three tags has its own hover', /Native engine: on/.test(e['rt-eng'].title) && /Scheduler tick/.test(e['rt-sch'].title) && /Web server/.test(e['rt-web'].title || 'Web server'));
ok('the hover still names the supervisor', /supervisor/.test(e['rt-ollama'].title));
ok('chip tooltip lists the switch files', /use_native_loop_ollama/.test(e['rt-chip'].title) && /ON \(file use_engine\)/.test(e['rt-chip'].title));
e = run({ host: 'tmux', agents: { claude: { host: 'tmux', loop: 'shell', pid: 5 }, gemini: { host: 'none', loop: 'none', pid: 0 }, ollama: { host: 'tmux', loop: 'native', pid: 6 } }, engine: { on: false, installed: false }, switches: [], scheduler: 'cron/other' });
ok('tmux host shows tmux', e['rt-claude'].textContent === 'tmux · shell' && e['rt-ollama'].textContent === 'tmux · native');
ok('a stopped agent shows no tag', e['rt-gemini'].style.display === 'none');
ok('chip says engine off, cron', e.chipText() === 'off · cron');
ok('chip tooltip warns the program is not installed', /not installed/.test(e['rt-chip'].title) && /nothing/.test(e['rt-chip'].title));
e = run(Object.assign({}, full, { web: 'aicserver' }));
ok('chip names the web front', e.chipText() === 'on · sup · aic' && /aicserver/.test(e['rt-chip'].title));
e = run(Object.assign({}, full, { web: 'apache' }));
ok('chip names Apache', e.chipText() === 'on · sup · apache');
e = run(Object.assign({}, full, { web: 'none' }));
ok('no web word when unknown', e.chipText() === 'on · sup');
ok('the web tag is hidden when unknown, shown and marked for aicserver', e['rt-web'].style.display === 'none' && run(Object.assign({}, full, { web: 'aicserver' }))['rt-web'].classList.s.has('native'));
e = run(null);
ok('no runtime data hides the chip', e['rt-chip'].style.display === 'none');
e = run({ host: 'mixed', agents: { claude: { host: 'other', loop: 'shell', pid: 9 }, gemini: { host: 'none', loop: 'none' }, ollama: { host: 'none', loop: 'none' } }, engine: {}, switches: [], scheduler: 'cron/other' });
ok('an unknown host shows a question mark', e['rt-claude'].textContent === '? · shell');
console.log('runtime_indicator_test: ' + n + ' checks, ' + fails + ' failure(s)'); process.exit(fails ? 1 : 0);
