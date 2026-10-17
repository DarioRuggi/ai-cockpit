// status_label_test.js — js/core/status.js _statusShort(): the status bar names the agent and its model, nothing else.   node tests/status_label_test.js
const fs = require('fs'), vm = require('vm');
const src = fs.readFileSync(__dirname + '/../cockpit_app/js/core/status.js', 'utf8');
const m = src.match(/function _statusShort\([\s\S]*?\n\}\n/);
if (!m) { console.log('FAIL could not find _statusShort'); process.exit(1); }
const ctx = {}; vm.createContext(ctx); vm.runInContext(m[0], ctx);
let fails = 0, n = 0; const eq = (name, got, want) => { n++; if (got !== want) { fails++; console.log('FAIL ' + name + ': [' + got + '] want [' + want + ']'); } };
eq('claude', ctx._statusShort('claude', 'Claude Code: session running', ' · Claude Sonnet 4.6 · 1,000K ctx'), 'Claude · Sonnet 4.6');
eq('claude, no model', ctx._statusShort('claude', 'Claude Code: session running', ''), 'Claude');
eq('card 1 renamed by the user', ctx._statusShort('claude', 'Codex: session running', ' · gpt-5'), 'Codex · gpt-5');
eq('opencode (card 2)', ctx._statusShort('gemini', 'OPENCODE: session running', ' · qwen2.5:7b'), 'OpenCode · qwen2.5:7b');
eq('gemini default name', ctx._statusShort('gemini', 'Gemini CLI: session running', ' · Gemini 2.5 Flash'), 'Gemini · Gemini 2.5 Flash');
eq('dual (card 3)', ctx._statusShort('ollama', 'DUAL: session running', ''), 'Local · Dual');
eq('ollama (card 3)', ctx._statusShort('ollama', 'Ollama: session running', ''), 'Local · Ollama');
eq('localai (card 3)', ctx._statusShort('ollama', 'LOCALAI: session running', ''), 'Local · LocalAI');
console.log('status_label_test: ' + n + ' checks, ' + fails + ' failure(s)'); process.exit(fails ? 1 : 0);
