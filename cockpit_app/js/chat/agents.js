// =============================================================================
// Cockpit Frontend JS v4
// =============================================================================

// 2026-05-09 fix (revised): on load, prefer the agent saved in localStorage
// over the DOM's static .sup-active marking. This way a user's selected
// supplier survives reloads. If localStorage is empty (first visit) we
// fall back to whichever card the markup highlights.
function _initialActiveAgent() {
    try {
        const saved = localStorage.getItem('cockpit_current_agent');
        if (saved && ['claude','gemini','ollama','workers','tools'].includes(saved)) {
            return saved;
        }
    } catch(e) {}
    const active = document.querySelector('.sup-card.sup-active');
    if (active && active.dataset && active.dataset.agent) {
        return active.dataset.agent;
    }
    return 'gemini';  // fallback if no card has sup-active for some reason
}

let currentAgent    = _initialActiveAgent();
let currentModel    = 'qwen2.5-coder:7b';
let promptStartTime = null;
let abortController = null;  // For cancelling fetch
let _activeAgent = null;     // agent currently generating (for Stop → tmux SIGINT)
let activeStreamTokens = new Set();  // tokens currently streaming, used for cleanup on cancel/unload
let lastMsgTime     = null;  // For duration calculation

// Project and chat tracking — history lives in JSON files on disk
let currentProject = localStorage.getItem('cockpit_last_project') || 'default';
let currentChat    = localStorage.getItem('cockpit_last_chat')    || 'default';
// True once a REAL (user-created / loaded) chat is active. The 'default'/'default'
// pair is only a placeholder — prompting against it orphans the save (nothing
// reloads on refresh). ensureActiveChat() creates a real chat when this is false.
let _realChatActive = (currentProject !== 'default' && currentChat !== 'default');
let _lastKnownExchangeCount = null; // detects new messages landing from elsewhere (e.g. the relay)

// Chat history is now managed by agent_loop.sh writing to a JSON file
// in the project folder. No in-memory history needed here.

// =============================================================================
// PromptHistory — shell-style up/down recall for the prompt textarea, and the list behind the History picker
// (js/chat/history-picker.js: filter, then choose).
//
// Every chat keeps its own stack in localStorage ("cockpit_prompthist_<project>__<chat>", up to MAX entries, each
// {text, t, p, c} = the text, when, the project and the chat). The SCOPE decides which stacks the arrow keys and the
// picker read (2026-10-17):  chat = only this chat (the old behaviour, still the default) · project = every chat of this
// project · all = every prompt ever typed here, so a prompt already entered anywhere can be reused anywhere.
// Wider scopes show each distinct text once, newest first in time order.
//
// Navigation model (shell-like):
//   - cursor === -1 means "not navigating; whatever's in the textarea is the user's live draft"
//   - Up arrow from index N moves to N-1 (toward older); from -1 it jumps to the most recent
//   - Down arrow from index N moves to N+1; passing the newest restores the saved draft and sets cursor back to -1
// Arrow keys only trigger history nav when the caret is on the first line (for Up) or the last line (for Down).
// =============================================================================
const PromptHistory = {
    MAX: 200,
    PREFIX: 'cockpit_prompthist_',
    SCOPE_KEY: 'cockpit_prompthistscope',      // not under PREFIX: it must never be read as a stack
    entries: [],         // [{ text, t, p, c }] oldest → newest, for the current scope
    cursor: -1,          // -1 = not navigating
    savedDraft: '',      // user's in-progress text when nav started
    loadedFor: null,     // "<chat>|<scope>" the entries belong to

    scope() { try { const s = localStorage.getItem(this.SCOPE_KEY); return (s === 'project' || s === 'all') ? s : 'chat'; } catch (e) { return 'chat'; } },
    setScope(s) { try { localStorage.setItem(this.SCOPE_KEY, (s === 'project' || s === 'all') ? s : 'chat'); } catch (e) {} this.loadedFor = null; this.load(); },

    _chat() { return (typeof currentChat !== 'undefined' && currentChat) ? currentChat : 'default'; },
    _proj() { return (typeof currentProject !== 'undefined' && currentProject) ? currentProject : '_'; },
    _key(chat, project) { return this.PREFIX + (project || this._proj()) + '__' + (chat || this._chat()); },
    _read(key) { try { const a = JSON.parse(localStorage.getItem(key) || '[]'); return Array.isArray(a) ? a.filter(e => e && typeof e.text === 'string') : []; } catch (e) { return []; } },

    // every entry of a scope, oldest → newest (a text that was typed several times keeps its newest place in the wider scopes)
    all(scope, chat) {
        scope = scope || this.scope(); chat = chat || this._chat();
        const mine = this._key(chat), proj = this.PREFIX + this._proj() + '__', keys = [];
        if (scope === 'chat') keys.push(mine);
        else { try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k && k.indexOf(this.PREFIX) === 0 && (scope === 'all' || k.indexOf(proj) === 0)) keys.push(k); } } catch (e) {} }
        let out = [], order = 0;
        keys.forEach(k => {
            const rest = k.slice(this.PREFIX.length), i = rest.indexOf('__');
            this._read(k).forEach(e => out.push({ text: e.text, t: +e.t || 0, p: e.p || (i >= 0 ? rest.slice(0, i) : ''), c: e.c || (i >= 0 ? rest.slice(i + 2) : rest), o: order++ }));
        });
        if (scope !== 'chat') {
            out.sort((a, b) => (a.t - b.t) || (a.o - b.o));
            const seen = new Set(), keep = [];
            for (let i = out.length - 1; i >= 0; i--) { if (!seen.has(out[i].text)) { seen.add(out[i].text); keep.push(out[i]); } }
            out = keep.reverse();
        }
        return out;
    },

    load(chat) {
        chat = chat || this._chat();
        const tag = chat + '|' + this.scope() + '|' + this._proj();
        if (this.loadedFor === tag) return;
        this.loadedFor = tag; this.cursor = -1; this.savedDraft = '';
        this.entries = this.all(this.scope(), chat);
    },

    save(stack) {
        const key = this._key();
        try { localStorage.setItem(key, JSON.stringify(stack)); }
        catch (e) { try { localStorage.setItem(key, JSON.stringify(stack.slice(-Math.floor(this.MAX / 2)))); } catch (e2) { /* quota — silently ignore */ } }
    },

    push(text) {
        if (!text || !text.trim()) return;
        const stack = this._read(this._key());
        const last = stack[stack.length - 1];
        if (!(last && last.text === text)) {                      // consecutive duplicates collapse
            stack.push({ text, t: Date.now(), p: this._proj(), c: this._chat() });
            if (stack.length > this.MAX) stack.splice(0, stack.length - this.MAX);
            this.save(stack);
        }
        this.loadedFor = null; this.load(); this.resetCursor();
    },

    // matches of a filter (every word must be in the text), newest first — what the picker lists
    search(q, scope) {
        const toks = String(q || '').toLowerCase().split(/\s+/).filter(Boolean);
        return this.all(scope).filter(e => !toks.length || toks.every(w => e.text.toLowerCase().indexOf(w) >= 0)).reverse();
    },

    clear(scope) {
        scope = scope || this.scope(); const proj = this.PREFIX + this._proj() + '__', del = [];
        try { for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (k && k.indexOf(this.PREFIX) === 0 && (scope === 'all' || (scope === 'project' ? k.indexOf(proj) === 0 : k === this._key()))) del.push(k); } del.forEach(k => localStorage.removeItem(k)); } catch (e) {}
        this.loadedFor = null; this.load();
    },

    resetCursor() { this.cursor = -1; this.savedDraft = ''; },

    // Called when chat changes — reload entries for the new chat
    onChatChanged() { this.loadedFor = null; this.load(); },

    // Step back (older). Returns the text to show, or null if no movement.
    prev(currentText) {
        this.load();
        if (this.entries.length === 0) return null;
        if (this.cursor === -1) {
            this.savedDraft = currentText || '';                 // starting navigation — save the live draft
            this.cursor = this.entries.length - 1;
            return this.entries[this.cursor].text;
        }
        if (this.cursor > 0) { this.cursor--; return this.entries[this.cursor].text; }
        return null;                                             // already at oldest — no movement
    },

    // Step forward (newer). Past the newest, returns the saved draft.
    next() {
        this.load();
        if (this.cursor === -1) return null;                     // not navigating
        if (this.cursor < this.entries.length - 1) { this.cursor++; return this.entries[this.cursor].text; }
        const draft = this.savedDraft;                           // stepping past the newest — restore the draft
        this.resetCursor();
        return draft;
    },
};

// Helper — true when caret sits on the first visual line of the textarea
function _promptCaretOnFirstLine(ta) {
    const pos = ta.selectionStart;
    if (pos === 0) return true;
    return ta.value.substring(0, pos).indexOf('\n') === -1;
}

// Helper — true when caret sits on the last visual line of the textarea
function _promptCaretOnLastLine(ta) {
    const pos = ta.selectionEnd;
    if (pos >= ta.value.length) return true;
    return ta.value.substring(pos).indexOf('\n') === -1;
}

const consoleBox  = document.getElementById('console-box');
const promptInput = document.getElementById('prompt-in');

// Pre-send token estimate (rough char÷4). Shows ~tokens, and on Ollama (small
// context) the share of the model's window so you can spot overflow before send.
// Live model metadata cache from models.dev (context windows, pricing, caps).
let _modelsDev = null;
fetch('models_dev.php?action=get').then(r => r.json()).then(d => {
    if (d && d.ok && d.cache && d.cache.providers) _modelsDev = d.cache.providers;
}).catch(() => {});

// Real context window for the active agent's selected model (or null → unknown).
function activeModelCtx() {
    if (!_modelsDev || typeof currentAgent === 'undefined') return null;
    let prov = null, mid = null;
    if (currentAgent === 'claude') { prov = 'anthropic'; mid = document.getElementById('claude-model')?.value; }
    else if (currentAgent === 'gemini') {
        const fb = (typeof _supplierSlots !== 'undefined' && _supplierSlots && _supplierSlots.slots && _supplierSlots.slots.fallback) || 'gemini';
        prov = fb.indexOf('groq') >= 0 ? 'groq' : fb.indexOf('hugg') >= 0 ? 'huggingface' : fb.indexOf('cloud') >= 0 ? 'cloudflare-workers-ai' : 'google';
        mid = document.getElementById('gemini-model')?.value;
    } else return null;   // ollama = local, not on models.dev
    if (!prov || !mid || !_modelsDev[prov]) return null;
    if (_modelsDev[prov][mid]) return _modelsDev[prov][mid].ctx;
    for (const k in _modelsDev[prov]) { if (k.indexOf(mid) >= 0 || mid.indexOf(k) >= 0) return _modelsDev[prov][k].ctx; }
    return null;
}

function updateTokEstimate() {
    const el = document.getElementById('tok-estimate');
    if (!el || !promptInput) return;
    const n = promptInput.value.length;
    if (!n) { el.textContent = ''; return; }
    const tok = Math.ceil(n / 4);
    let txt = '~' + tok.toLocaleString() + ' tok';
    let warn = false;
    // Real context window from models.dev; fall back to ~8K for local Ollama.
    let ctx = activeModelCtx();
    if (!ctx && typeof currentAgent !== 'undefined' && currentAgent === 'ollama') ctx = 8192;
    if (ctx) {
        const pct = Math.round((tok / ctx) * 100);
        const kctx = ctx >= 1000 ? Math.round(ctx / 1024) + 'K' : ctx;
        txt += ' · ' + pct + '% of ' + kctx + ' ctx';
        warn = tok > ctx * 0.85;
    }
    el.textContent = txt;
    el.style.color = warn ? 'var(--warn,#e6b43c)' : 'var(--text-muted)';
    el.style.fontWeight = warn ? '700' : '400';
}
if (promptInput) promptInput.addEventListener('input', updateTokEstimate);

// The composer's paste/drop wiring lived here; it tests `typeof attachFile`, which
// was true through hoisting in the single-file build and is false now that
// attachFile is defined in a later file. It moved to the end of js/chat/attach.js
// (2026-09-17 split) — same code, registered right after attachFile exists.
const spinner     = document.getElementById('spinner');
const btnExecute  = document.getElementById('btn-execute');
const btnCancel   = document.getElementById('btn-cancel');

// Agent color map
const AGENT_COLORS = { claude: 'agent-claude', gemini: '', ollama: 'agent-ollama' };

// =============================================================================
// setAgent — switch active agent, update UI
// =============================================================================
// =============================================================================
// supActivate — clicking an inactive supplier card activates that agent.
// Replaces the old AGENT button. Click is wired on the whole card; we use
// event.stopPropagation() inside form controls so dropdowns/buttons don't
// fire this. If the user clicks an already-active card, do nothing.
// =============================================================================
// Track page-load time so setAgent can suppress noisy system messages during
// the first 2 seconds (internal init activity, not user-driven switches).
const _pageLoadAt = Date.now();

