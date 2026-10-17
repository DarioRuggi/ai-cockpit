// =============================================================================
// sendPrompt
// =============================================================================
// =============================================================================
// Multi-agent dispatch — Single / Pipeline / Broadcast
// =============================================================================
//
// Single    — sendToOne(currentAgent)   — the original behaviour
// Pipeline  — sendPipeline(agents[])    — A → B → C, output feeds next prompt
// Broadcast — sendBroadcast(agents[])   — same prompt to all in parallel
//
// Mode is set via setMaMode() and persisted in localStorage so it survives
// reloads. The agent picker (ma-agents) is shown only in the multi modes.
// =============================================================================

// Slot id → the name of the supplier in it (Card 2 may hold opencode, Card 3 Dual);
// used by every system line that names an agent.
function agentDisplayName(a) {
    if (a === 'claude') return window._primaryName  || 'CLAUDE';
    if (a === 'gemini') return window._fallbackName || 'GEMINI';
    if (a === 'ollama') return window._localName    || 'OLLAMA';
    return String(a || '').toUpperCase();
}
let maMode = localStorage.getItem('cockpit_ma_mode') || 'single';

// The Mode, Style and Power Buttons rows are one fixed line each (css/console.css) and scroll sideways when they are too narrow: let the mouse wheel do it.
document.addEventListener('DOMContentLoaded', () => {
    ['ma-strip', 'style-strip', 'power-strip'].forEach(id => { const el = document.getElementById(id); if (!el) return;
        el.addEventListener('wheel', e => { if (!e.shiftKey && e.deltaY && el.scrollWidth > el.clientWidth) { el.scrollLeft += e.deltaY; e.preventDefault(); } }, { passive: false }); });
});
function setMaMode(mode) {
    maMode = mode;
    localStorage.setItem('cockpit_ma_mode', mode);
    document.querySelectorAll('.ma-mode-btn').forEach(b => {
        b.classList.toggle('ma-active', b.dataset.mode === mode);
    });
    const agents     = document.getElementById('ma-agents');
    const pipelineHt = document.getElementById('ma-pipeline-hint');
    if (agents) agents.style.display = (mode === 'single') ? 'none' : 'flex';
    if (pipelineHt) pipelineHt.style.display = (mode === 'pipeline') ? 'inline' : 'none';
    // ma-agents is shown for every non-single mode, Plan included — but a durable
    // chain is built from a Pipeline/Broadcast selection, and Plan has its own
    // orchestrator. Hide the button there rather than let it be clicked into an error.
    const durBtn = document.getElementById('ma-durable');
    if (durBtn) durBtn.style.display = (mode === 'pipeline' || mode === 'broadcast') ? '' : 'none';
    // A2: show the pipeline order editor only in pipeline mode
    const orderBox = document.getElementById('ma-order');
    if (orderBox) orderBox.style.display = (mode === 'pipeline') ? 'flex' : 'none';
    if (mode === 'pipeline') maRenderOrder();
    // Workflow pattern selector — only in plan mode
    const wfBox = document.getElementById('ma-workflow');
    if (wfBox) wfBox.style.display = (mode === 'plan') ? 'flex' : 'none';
}

// A2: pipeline order is persisted; default Claude → Gemini → Ollama.
function maGetPipelineOrder() {
    let order = ['claude','gemini','ollama'];
    try {
        const saved = JSON.parse(localStorage.getItem('cockpit_pipeline_order') || 'null');
        if (Array.isArray(saved) && saved.length) {
            // keep only known agents, append any missing at the end
            const known = ['claude','gemini','ollama'];
            order = saved.filter(a => known.includes(a));
            known.forEach(a => { if (!order.includes(a)) order.push(a); });
        }
    } catch(e) {}
    return order;
}
function maSetPipelineOrder(order) {
    localStorage.setItem('cockpit_pipeline_order', JSON.stringify(order));
    maRenderOrder();
}
function maMoveAgent(agent, dir) {
    const order = maGetPipelineOrder();
    const i = order.indexOf(agent);
    if (i < 0) return;
    const j = i + dir;
    if (j < 0 || j >= order.length) return;
    [order[i], order[j]] = [order[j], order[i]];
    maSetPipelineOrder(order);
}
function maRenderOrder() {
    const box = document.getElementById('ma-order');
    if (!box) return;
    const order = maGetPipelineOrder();
    const colorVar = { claude:'var(--claude)', gemini:'var(--gemini)', ollama:'var(--ollama)' };
    const label = { claude:'Claude', gemini:'Gemini', ollama:'Ollama' };
    box.innerHTML = '<span style="font-weight:600;">Order:</span>' +
        order.map((a, idx) =>
            '<span style="display:inline-flex;align-items:center;gap:2px;color:' + colorVar[a] + ';">' +
            (idx+1) + '.' + label[a] +
            '<span class="material-symbols-rounded mini-ctrl" ' +
            'onclick="maMoveAgent(\'' + a + '\',-1)" title="Move earlier">arrow_upward</span>' +
            '<span class="material-symbols-rounded mini-ctrl" ' +
            'onclick="maMoveAgent(\'' + a + '\',1)" title="Move later">arrow_downward</span>' +
            '</span>' +
            (idx < order.length-1 ? '<span style="opacity:0.5;">→</span>' : '')
        ).join('');
}

// The Agents row (Pipeline, Broadcast, Plan) used to start with all three agents ticked, even ones that are not running. Now each box follows
// whether that agent's session is up, until the person ticks or unticks it themselves (then it is left alone for good).
function maSyncAgentChecks(status) {
    if (!status) return;
    document.querySelectorAll('.ma-agent-cb').forEach(cb => {
        if (!cb.dataset.touchBound) { cb.dataset.touchBound = '1'; cb.addEventListener('change', e => { if (e.isTrusted) cb.dataset.touched = '1'; }); }
        if (cb.dataset.touched) return;
        const st = status[cb.dataset.agent];
        if (st && typeof st === 'object' && 'ok' in st) cb.checked = !!st.ok;
    });
}

function maGetSelectedAgents() {
    // Which agents are checked
    const checked = new Set(Array.from(document.querySelectorAll('.ma-agent-cb'))
        .filter(cb => cb.checked).map(cb => cb.dataset.agent));
    if (maMode === 'pipeline') {
        // A2: honor the configured pipeline order, filtered to checked agents
        return maGetPipelineOrder().filter(a => checked.has(a));
    }
    // Broadcast (and others): DOM order is fine
    return Array.from(document.querySelectorAll('.ma-agent-cb'))
        .filter(cb => cb.checked)
        .map(cb => cb.dataset.agent);
}

// Initialize mode UI when DOM is ready
setTimeout(() => setMaMode(maMode), 0);

// =============================================================================
// Style selector — Phase 2b (2026-05-09)
// =============================================================================
// Working-style prefix injection for prompts. Five styles plus Build (default).
//
// Persistence model: per-chat in localStorage under key cockpit_style_<chat>.
// Each chat can have its own working style. When you switch chats, the saved
// style for that chat is loaded; when you change style within a chat, it's
// saved to that chat's slot. Default for new/unset chats is 'build'.
//
// Prefix model: prepended to user text in sendPrompt() before any dispatch.
// 'build' injects no prefix (it's the default-style behavior of the agents
// themselves). The other four prepend a short instruction in [BRACKETS] so
// the agent sees a clear marker rather than blending into the prompt text.
//
// Applies to: Claude, Gemini, Ollama, AND Workers — all share sendPrompt's
// `text` variable, so prefixing once at the top covers all four destinations.
// =============================================================================

const STYLE_PREFIXES = {
    'chat':     '[CHAT MODE] Answer conversationally as if speaking. Avoid code blocks unless explicitly asked for them. Plain prose, questions get answers, not implementation.\n\n',
    'plan':     '[OUTLINE MODE] Think through the approach before writing code. Identify decisions that need input. Propose structure; do not write final code yet. This is conceptual outlining — for orchestrated multi-agent planning use Mode > Plan instead.\n\n',
    'research': '[RESEARCH MODE] Investigate thoroughly. Compare alternatives. Lean on facts over opinions. Cite sources where applicable.\n\n',
    'build':    '',  // default — no prefix injected
    'debug':    '[DEBUG MODE] Diagnose first, fix second. Do not change code without identifying root cause. Read existing code carefully before editing.\n\n',
    'analyze':  '[ANALYZE MODE] Examine, summarize, explain. Do not propose changes unless asked. Surface insights and patterns.\n\n',
    'report':   '[REPORT MODE] Produce a structured written report: clear headings, concise prose, key findings up front, supporting detail below. No code unless it is the subject of the report. Aim for something the reader could paste into a document.\n\n',
};

let currentStyle = 'build';

// ── Per-style default models ────────────────────────────────────────────────
// When "auto model per style" is ON, switching Style also switches each card's
// model to a task-appropriate default. Only providers/models listed here (and
// present as options) are touched; anything unmapped keeps its current pick.
// Edit freely — model ids must match the card dropdowns. Gemini stays Flash by
// policy, so it isn't switched here.
const STYLE_MODELS = {
    'chat':     { ollama: 'llama3.2:3b',      claude: 'claude-sonnet-4-6' },
    'plan':     { ollama: 'llama3.2:3b',      claude: 'claude-opus-4-8'  },
    'research': { ollama: 'qwen2.5:7b',       claude: 'claude-opus-4-8'  },
    'build':    { ollama: 'qwen2.5-coder:1.5b', claude: 'claude-sonnet-4-6' },
    'debug':    { ollama: 'qwen2.5-coder:1.5b', claude: 'claude-sonnet-4-6' },
    'analyze':  { ollama: 'llama3.2:3b',      claude: 'claude-sonnet-4-6' },
    'report':   { ollama: 'llama3.2:3b',      claude: 'claude-sonnet-4-6' },
};
const AUTO_MODEL_KEY = 'cockpit_auto_model_per_style';
function autoModelPerStyle()      { return localStorage.getItem(AUTO_MODEL_KEY) === '1'; }
function setAutoModelPerStyle(on) {
    try { localStorage.setItem(AUTO_MODEL_KEY, on ? '1' : '0'); } catch(e) {}
    if (on) applyStyleModels(currentStyle);   // apply immediately when enabled
}

// Point one card at a model, reusing that card's own selector so it persists
// exactly like a manual pick. No-ops if the model isn't an available option.
function setProviderModel(provider, model) {
    if (!model) return false;
    if (provider === 'ollama') {
        // Match by exact data-value. Ollama ids contain ':' and '.', which are
        // literal inside a quoted attribute selector — do NOT CSS.escape them.
        let opt = null;
        document.querySelectorAll('.cs-option').forEach(o => { if (!opt && o.dataset.value === model) opt = o; });
        if (opt && !opt.classList.contains('disabled')) { selectOllamaModel(opt); return true; }
        return false;
    }
    const sel = document.getElementById(provider === 'claude' ? 'claude-model'
                                      : provider === 'gemini' ? 'gemini-model' : '');
    if (sel && [...sel.options].some(o => o.value === model)) {
        sel.value = model;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
    }
    return false;
}

// Apply the per-style model defaults for the given style (if the toggle is on).
function applyStyleModels(style) {
    if (!autoModelPerStyle()) return;
    const map = STYLE_MODELS[style]; if (!map) return;
    const changed = [];
    for (const prov of ['claude', 'gemini', 'ollama']) {
        if (map[prov] && setProviderModel(prov, map[prov])) changed.push(prov + '→' + map[prov]);
    }
    if (changed.length && typeof appendSystem === 'function') {
        appendSystem(T('msg.style.style.auto.models.n', 'Style · {style} — auto models: {n}', {style: style, n: changed.join(', ')}));
    }
}

// Per-chat localStorage key
function _styleStorageKey() {
    // Scope by project too — two chats with the same slug in different containers
    // (a project vs Free) must not share a style slot.
    return 'cockpit_style_' + (currentProject || '_') + '__' + (currentChat || 'default');
}

// Set the active style. Called from button onclick handlers and from
// loadStyleForCurrentChat() when switching chats.
function setStyle(style) {
    if (!STYLE_PREFIXES.hasOwnProperty(style)) return;
    currentStyle = style;
    try { localStorage.setItem(_styleStorageKey(), style); } catch(e) {}

    // Toggle the .ma-active class on the matching button
    document.querySelectorAll('#style-strip .ma-mode-btn').forEach(b => {
        b.classList.toggle('ma-active', b.dataset.style === style);
    });

    // Hint text — for non-default styles, show what's being injected as a
    // reminder. Build (default) shows nothing — clean state, no clutter.
    const hint = document.getElementById('style-current-hint');
    if (hint) {
        if (style === 'build') {
            hint.textContent = '';
        } else if (style === 'chat') {
            hint.textContent = T('msg.conversational.answers.not.code', '(conversational — answers, not code)');
        } else if (style === 'plan') {
            hint.textContent = T('msg.outline.first.think.before.coding.no.final.c', '(outline first — think before coding, no final code yet)');
        } else {
            hint.textContent = T('msg.prepended.to.every.prompt.in.this.chat', '(prepended to every prompt in this chat)');
        }
    }

    // Auto-switch each card's model to this style's default (if enabled).
    applyStyleModels(style);
}

// Load the saved style for the currently active chat. Falls back to 'build'.
// Called whenever currentChat changes (chat switch, project switch, etc.)
function loadStyleForCurrentChat() {
    let saved = 'build';
    try {
        const v = localStorage.getItem(_styleStorageKey());
        if (v && STYLE_PREFIXES.hasOwnProperty(v)) saved = v;
    } catch(e) {}
    // Reflect the auto-model toggle before setStyle (so it can apply on load).
    const amcb = document.getElementById('auto-model-style');
    if (amcb) amcb.checked = autoModelPerStyle();
    setStyle(saved);
    // Also reload prompt history for the (possibly new) currentChat
    if (typeof PromptHistory !== 'undefined') PromptHistory.onChatChanged();
    if (typeof promptDraftRestore === 'function') promptDraftRestore();     // an empty box gets this chat's draft
}

// Apply the active style prefix to a user prompt. Returns the original text
// unchanged when style is 'build' (no prefix). Called at the top of
// sendPrompt() so all four send paths (Single/Pipeline/Broadcast/Plan) and
// all four targets (Claude/Gemini/Ollama/Workers) receive the prefixed text.
function applyStylePrefix(text) {
    const prefix = STYLE_PREFIXES[currentStyle] || '';
    return prefix + text;
}

// =============================================================================
// Caveman mode — token compression for ONLINE suppliers (Claude/Gemini/Workers).
// State: 0 = Off, 1 = Strip (local deterministic), 2 = Strip + AI (local Ollama).
// Local Ollama is the engine for the AI pass, so compression costs no paid tokens.
// =============================================================================
const CAVEMAN_ONLINE = ['claude', 'gemini', 'workers'];
let cavemanState = parseInt(localStorage.getItem('cockpit_caveman') || '0', 10) || 0;
const CAVEMAN_LABELS = ['Caveman: Off', 'Caveman: Strip', 'Caveman: Strip+AI'];

function cavemanRefreshBtn() {
    const btn = document.getElementById('caveman-btn');
    const lbl = document.getElementById('caveman-btn-label');
    if (lbl) lbl.textContent = CAVEMAN_LABELS[cavemanState];
    if (btn) {
        // Protanopia-safe: text label always present; tint by state (cyan/amber).
        btn.style.color = cavemanState === 0 ? '' :
                          cavemanState === 1 ? 'var(--accent-cyan)' : 'var(--accent-amber)';
        btn.classList.toggle('ma-active', cavemanState !== 0);
    }
}
function cavemanCycle() {
    cavemanState = (cavemanState + 1) % 3;
    try { localStorage.setItem('cockpit_caveman', String(cavemanState)); } catch (e) {}
    cavemanRefreshBtn();
    appendSystem(T('msg.caveman.cavemanstate', 'Caveman {cavemanstate}', {cavemanstate: (cavemanState === 0 ? 'off — full prompts sent.' :
        cavemanState === 1 ? 'on (local strip) — online suppliers get compressed prompts.' :
        'on (strip + local-Ollama rewrite) — heavier compression on online suppliers.')}));
}
setTimeout(cavemanRefreshBtn, 0);

// The terse-reply directive appended to compressed prompts (output-side savings).
const CAVEMAN_REPLY_NOTE =
    '\n\n[CAVEMAN: reply terse/telegraphic — drop filler & articles, keep all facts, ' +
    'numbers, code, paths exact.]';

// Estimate a model's parameter count (billions) from its name; -1 if unknown.
// Mirrors ollama_guard.php so the UI only ever offers ≤4B models for auto tasks.
function ollamaParamB(name) {
    const tag = name.includes(':') ? name.split(':').pop() : name;
    const m = tag.match(/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i) || name.match(/([0-9]+(?:\.[0-9]+)?)\s*([bm])/i);
    if (!m) return -1;
    const n = parseFloat(m[1]);
    return m[2].toLowerCase() === 'm' ? n / 1000 : n;
}
// Build the Caveman model dropdown from the Ollama model list, ≤4B only.
function cavemanPopulateModels() {
    const sel = document.getElementById('caveman-model');
    if (!sel) return;
    const opts = [...document.querySelectorAll('#ollama-options .cs-option, .cs-option')]
        .map(o => o.getAttribute('data-value'))
        .filter(v => v && ollamaParamB(v) >= 0 && ollamaParamB(v) <= 4);
    const uniq = [...new Set(opts)];
    if (uniq.length === 0) return;
    const saved = localStorage.getItem('cockpit_caveman_model') || '';
    const pref = uniq.includes('qwen2.5:3b') ? 'qwen2.5:3b' :
                 uniq.includes('llama3.2:1b') ? 'llama3.2:1b' : uniq[0];
    const chosen = uniq.includes(saved) ? saved : pref;
    sel.innerHTML = uniq.map(v => '<option value="' + v + '"' + (v === chosen ? ' selected' : '') + '>' + v + '</option>').join('');
}
function cavemanModelSave() {
    const v = document.getElementById('caveman-model')?.value || '';
    try { localStorage.setItem('cockpit_caveman_model', v); } catch (e) {}
}
setTimeout(cavemanPopulateModels, 500);

// Compress one outgoing prompt. Returns {text, note}. On any failure, returns the
// original text unchanged (never blocks a send).
async function cavemanCompress(text) {
    if (!cavemanState) return { text, note: '' };
    try {
        const model = document.getElementById('caveman-model')?.value ||
                      localStorage.getItem('cockpit_caveman_model') || 'qwen2.5:3b';
        const r = await fetch('caveman.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text, llm: cavemanState === 2 ? 1 : 0, model })
        });
        const d = await r.json();
        if (!d.ok || typeof d.text !== 'string') return { text, note: '' };
        const note = '<span class="material-symbols-rounded ico">face</span> Caveman −' + (d.saved || 0) + ' tok (' + (d.pct || 0) + '%)' +
                     (d.llm ? ' +AI(' + (d.model_used || '?') + ')'
                            : (cavemanState === 2 ? ' (AI pass failed → strip only)' : '')) +
                     (d.model_clamped ? ' [model >4B → downgraded]' : '');
        return { text: d.text + CAVEMAN_REPLY_NOTE, note };
    } catch (e) {
        return { text, note: '' };
    }
}

// Initialize style UI on DOM ready
setTimeout(() => loadStyleForCurrentChat(), 0);

// 2026-05-09: sync supplier-card visuals to the loaded currentAgent.
// At this point currentAgent has been read from localStorage (via
// _initialActiveAgent) but the DOM still has whatever static .sup-active
// the markup put there. Apply the JS state to the DOM so they match.
// We can't just call setAgent() because it short-circuits on
// currentAgent === agent. So we toggle classes directly.
setTimeout(() => {
    ['claude','gemini','ollama','workers','tools'].forEach(a => {
        const card = document.getElementById('sup-card-' + a);
        if (card) card.classList.toggle('sup-active', a === currentAgent);
    });
    // Refresh labels and any agent-keyed UI that depends on activation
    if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
}, 0);

// If no real chat is active (fresh app, only the default/default placeholder),
// create one before the prompt lands so the exchange + any code blocks are
// persisted and reload on refresh. If a real PROJECT is selected but it has no
// chat yet, the new chat is created inside that project; otherwise a standalone
// "free" chat is made. No rename-autofocus here (would steal the prompt focus).
// Guarantee a real default home exists so the app is never empty: a "default"
// project holding a "default" chat (matches the default/default blackboard
// state). Idempotent — creates the chat only if it isn't there yet (new_chat
// would otherwise spawn default_2, default_3… on each load).
// Intro text seeded into the two first-run chats (as system messages).
const _FREE_CHAT_INTRO =
    "Welcome to Free Chats.\n\n" +
    "These are standalone conversations, not tied to any project — good for quick " +
    "questions and scratch work. They live here under the Chats tab.\n\n" +
    "Want to keep one and group it with related work? Use the ⇄ \"Move to project\" " +
    "button on a chat to move it into a project. New free chats: the \"+ New Free\" button.";
const _PROJECT_CHAT_INTRO =
    "This is a project chat.\n\n" +
    "Projects group related chats together (plus their files and config). Everything " +
    "you send in a project chat is saved under that project.\n\n" +
    "Add more chats to a project with the + next to \"Chats\" in the Projects tab, or " +
    "detach a chat back to Free Chats. Create a new project with the \"New\" button.";

// First-run home: when the app has no real content yet, seed ONE free chat and
// ONE project chat, each carrying a short intro — so the user never faces empty
// free chats / empty projects / empty project chats. Also removes the legacy
// empty "default" chat (an earlier build auto-created it blank).
async function ensureDefaultHome() {
    let sections = [];
    try {
        const r = await fetch('files.php?action=chats');
        const d = await r.json();
        if (d && d.ok) sections = d.sections || [];
    } catch(e) { return; }   // can't tell state → do nothing (avoid dupes)

    let total = 0, nonEmpty = 0, emptyDefault = false;
    sections.forEach(s => (s.chats || []).forEach(c => {
        total++;
        if (!c.empty) nonEmpty++;
        if (s.project === 'default' && c.slug === 'default' && c.empty) emptyDefault = true;
    }));

    // Fresh app = nothing real yet (nothing, or only the legacy empty default).
    const fresh = (nonEmpty === 0) && (total === 0 || (total === 1 && emptyDefault));
    if (fresh) {
        try {
            await fetch('files.php', { method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'new_chat', project:'_standalone', name:'Welcome', intro:_FREE_CHAT_INTRO}) });
            const pr = await fetch('files.php', { method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'new_chat', project:'default', name:'Welcome', intro:_PROJECT_CHAT_INTRO}) });
            const pd = await pr.json().catch(() => null);
            // Land on the seeded project chat (default/default doesn't exist).
            if (pd && pd.ok && pd.slug) { currentProject = 'default'; currentChat = pd.slug; }
        } catch(e) {}
    }
    // Remove the legacy empty default chat (safe — the seed gave default another
    // chat). Server last-chat guard refuses if it's somehow the last one.
    if (emptyDefault) {
        try {
            await fetch('files.php', { method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'delete', project:'default', path:'chat_default.json'}) });
        } catch(e) {}
    }

    // Backfill: any project with zero chats gets a "Welcome" chat (no empty
    // projects — covers legacy ones made before new-project auto-seeded one).
    try {
        const pr = await fetch('files.php?action=projects');
        const pj = await pr.json();
        if (pj && pj.ok) {
            for (const p of (pj.projects || [])) {
                if (!p.chats || p.chats.length === 0) {
                    await fetch('files.php', { method:'POST', headers:{'Content-Type':'application/json'},
                        body: JSON.stringify({action:'new_chat', project:p.name, name:'Welcome', intro:_PROJECT_CHAT_INTRO}) });
                }
            }
        }
    } catch(e) {}

    // Indicator fix: if the restored (project,chat) isn't a REAL chat (e.g. the
    // phantom default/default), land on an existing one instead — prefer the
    // state-active chat, else the most recently updated.
    try {
        const r2 = await fetch('files.php?action=chats');
        const d2 = await r2.json();
        const secs = (d2 && d2.ok) ? (d2.sections || []) : [];
        const flat = [];
        secs.forEach(s => (s.chats || []).forEach(c => flat.push({ project: s.project, slug: c.slug, active: c.active, updated: c.updated || '' })));
        const exists = flat.some(c => c.project === currentProject && c.slug === currentChat);
        if (!exists && flat.length) {
            const pick = flat.find(c => c.active) ||
                         flat.slice().sort((a, b) => (b.updated).localeCompare(a.updated))[0];
            currentProject = pick.project;
            currentChat    = pick.slug;
        }
    } catch(e) {}
}

async function ensureActiveChat() {
    if (_realChatActive) return true;
    const inProject = (currentProject && currentProject !== 'default' && currentProject !== '_standalone');
    const scope = inProject ? currentProject : '_standalone';
    let n = 1;
    try {
        const lr = await fetch('files.php?action=list_chats&project=' + encodeURIComponent(scope));
        const ld = await lr.json();
        if (ld.ok && Array.isArray(ld.chats)) n = ld.chats.length + 1;
    } catch(e) {}
    try {
        const res = await fetch('files.php', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({action:'new_chat', project:scope, name:'Chat ' + n})
        });
        const data = await res.json();
        if (data && data.ok) {
            await switchToChat(data.slug, scope);   // sets _realChatActive = true
            if (typeof loadChats === 'function') await loadChats();
            return true;
        }
    } catch(e) {}
    appendSystem(T('msg.could.not.create.a.chat.automatically.create', 'Could not create a chat automatically — create one from the sidebar, then resend.'));
    return false;
}

async function sendPrompt() {
    if (window._cockpitRole === 'viewer') {
        appendSystem(T('msg.read.only.access.viewers.cannot.send.prompts', 'Read-only access — viewers cannot send prompts.'));
        return;
    }
    const userText = promptInput.value.trim();
    // Tools take a file, not prose: any prompt (or none) opens the Run dialog —
    // a typed path/URL is used as the input and runs straight away, other text
    // becomes the preset's extra arguments (2026-09-22).
    if (currentAgent === 'tools') { toolsShowInputModal(userText); promptInput.value = ''; return; }
    if (!userText) return;
    // A double click (or Enter pressed twice) must send ONCE: the input is only cleared after the awaits below, so the second call used to read the same text and add a second copy.
    const _now = Date.now();
    if (window._lastSend && window._lastSend.t === userText && _now - window._lastSend.at < 900) return;
    window._lastSend = { t: userText, at: _now };
    // Ensure a real chat exists so this exchange is saved (not orphaned onto the
    // default/default placeholder, which never reloads on refresh).
    if (!(await ensureActiveChat())) return;
    // Cap check
    const _capResult = await capsCheck(currentAgent);
    if (_capResult.warnings && _capResult.warnings.length) {
        _capResult.warnings.forEach(w => appendSystem(T('msg.icon.warning.cap.warning.w', '[[icon:warning]] Cap warning: {w}', {w: w})));
    }
    if (!_capResult.allowed) {
        appendSystem(T('msg.blocked.by.usage.cap.adjust.in.usage.caps.ed', 'Blocked by usage cap. Adjust in Usage Caps editor (cost tiers area).'));
        return;
    }
    PromptHistory.push(userText);
    // F1: expand a /skill invocation into its body before applying style prefix.
    // The chat log still shows what the user typed; the agent receives the
    // expanded skill body.
    let effectiveText = userText;
    if (userText.startsWith('/')) {
        const expanded = await skillsExpandInvocation(userText);
        if (expanded !== null) effectiveText = expanded;
    } else {
        // No explicit /trigger → auto-match folder skills and inject their bodies.
        effectiveText = await skillsAutoInject(effectiveText);
    }
    const now = new Date();
    const duration = lastMsgTime ? ((now - lastMsgTime) / 1000).toFixed(1) + 's ago' : '';
    lastMsgTime = now;

    appendMsg('dario', _userLabel(), 'dario', userText, now, duration);
    promptInput.value = '';

    // Rules — auto-delegate matching tasks before the normal dispatch below.
    // Runs on effectiveText (BEFORE the style prefix) so every downstream path
    // — the Tier-0 combo branch uses effectiveText directly, everything else
    // uses text=applyStylePrefix(effectiveText) — sees the same delegated
    // context consistently, computed once. No-op (same text back immediately)
    // when no rule fires. Single hook point covers every mode (Single/
    // Pipeline/Broadcast/Plan/Combos), since they all funnel through here.
    // Neither the Delegate classifier nor the style prefix belongs on a prompt
    // that is not going to a language model: the Tools card (the prompt only
    // opens the preset's input modal) and a Workers preset whose task is an
    // image / audio / translation job (the prompt IS the payload; a prefix or a
    // spliced delegate result corrupts it). Text models keep both. (2026-09-13)
    const _modelBound = !(currentAgent === 'tools' || (currentAgent === 'workers' && workersSelectedTask() !== 'text'));
    if (_modelBound) effectiveText = await rulesInterceptPrompt(effectiveText);
    const text = _modelBound ? applyStylePrefix(effectiveText) : effectiveText;

    // TIER 0 — a Power Combo is selected AND the Ollama card is active: run the
    // multi-model recipe instead of any single-agent / mode dispatch.
    if (_selectedCombo && currentAgent === 'ollama') {
        await runCombo(_selectedCombo, effectiveText);
        return;
    }

    // Dual-model (Ollama + LocalAI together) — only intervenes when the
    // LocalAI slot is actually in play; a lone classic Ollama selection
    // falls through untouched to the existing tmux dispatch below.
    if (currentAgent === 'ollama' && await dualMaybeIntercept(effectiveText)) {
        return;
    }

    // Dispatch to the right multi-agent handler based on mode
    if (maMode === 'pipeline') {
        const agents = maGetSelectedAgents();
        if (agents.length < 2) {
            appendError(T('msg.pipeline.mode.needs.at.least.2.agents.select', 'Pipeline mode needs at least 2 agents selected.'));
            return;
        }
        await sendPipeline(text, agents);
    } else if (maMode === 'broadcast') {
        const agents = maGetSelectedAgents();
        if (agents.length === 0) {
            appendError(T('msg.broadcast.mode.needs.at.least.1.agent.select', 'Broadcast mode needs at least 1 agent selected.'));
            return;
        }
        await sendBroadcast(text, agents);
    } else if (maMode === 'plan') {
        // Pass raw goal (no style prefix) — the orchestrator adds its own planner prompt
        await orchestratorBegin(effectiveText);
    } else {
        await sendToOne(currentAgent, timestampIntercept(text));
    }
}

// =============================================================================
// E4 — Public programmatic hook for artifacts / bookmarklets / external tools.
//
//   window.cockpitSendPrompt(text, { send: true, agent: 'claude' })
//
// Sets the prompt box to `text`. If opts.send is true, dispatches immediately
// via the normal sendPrompt() path (respecting current mode + style). If
// opts.agent is given and valid, switches the active agent first. Returns true
// if accepted. Exposed on window so code running in a sandboxed artifact iframe
// or a browser bookmarklet on the cockpit page can drive it.
// =============================================================================
window.cockpitSendPrompt = function(text, opts) {
    opts = opts || {};
    if (typeof text !== 'string' || text.trim() === '') return false;
    if (opts.agent && typeof setAgent === 'function' &&
        ['claude','gemini','ollama','workers'].includes(opts.agent)) {
        try { setAgent(opts.agent); } catch(e) {}
    }
    if (!promptInput) return false;
    promptInput.value = text;
    promptInput.focus();
    if (opts.send) {
        // Defer one tick so any agent switch settles first
        setTimeout(() => { try { sendPrompt(); } catch(e) {} }, 30);
    }
    return true;
};

// ── PIPELINE: A → B → C, each agent receives the previous one's output ──────
async function sendPipeline(initialPrompt, agents) {
    appendSystem(T('msg.pipeline.started.map', '▶ Pipeline started: {map}', {map: agents.map(agentDisplayName).join(' → ')}));
    let currentPrompt = initialPrompt;
    for (let i = 0; i < agents.length; i++) {
        const a = agents[i];
        appendSystem(T('msg.step.i.n.agentdisplayname', 'Step {i}/{n} — {agentdisplayname}', {i: (i+1), n: agents.length, agentdisplayname: agentDisplayName(a)}));
        // sendToOne returns the agent's final response text (or null on error).
        // Caveman compresses only step 0 (the user's typed prompt); later steps
        // carry prior agent output (injected context) which scope excludes.
        const resp = await sendToOne(a, currentPrompt, i === 0);
        if (resp === null) {
            appendError(T('msg.pipeline.halted.at.step.i.a', 'Pipeline halted at step {i} ({a}).', {i: (i+1), a: a}));
            return;
        }
        // Feed this agent's full response into the next agent as the new prompt.
        // We prefix it so the next agent knows it's continuing prior work.
        if (i < agents.length - 1) {
            currentPrompt =
                'Previous step (' + a.toUpperCase() + ') produced this output. '
                + 'Continue, refine, or build on it as appropriate.\n\n'
                + '--- Previous output ---\n' + resp + '\n--- End previous ---\n\n'
                + 'Original request: ' + initialPrompt;
        }
    }
    appendSystem(T('msg.icon.check.pipeline.complete', '[[icon:check]] Pipeline complete.'));
}


// Good context in front of the wrong model looks exactly like the Library
// failing. When push-RAG fires and Card 3 holds a model that cannot read prose
// (a coder, an embedding model, or one below the measured 3B floor), say so and
// offer the best alternative already installed — switching is one click, and
// nothing is re-sent behind the person's back.
function ragModelNotice(warn) {
    const sel = document.getElementById('ollama-select');
    appendSystem(T('msg.icon.warning.that.answer.used.your.library.b', '[[icon:warning]] That answer used your library, but {sel} is {why}.', {sel: (sel && sel.value ? sel.value : 'the chosen model'), why: warn.why}));
    if (!sel || !sel.options) return;
    // The SMALLEST general model at or above the 3B floor — not the largest.
    // Largest looks generous and is wrong: 14B measurably fails on a 4 GB card
    // (2.33 tok/s, past every timeout on a long answer), and VRAM detection is
    // not dependable enough to lean on here. 3B is the size that answered from
    // the text and cited it, so it is the safe recommendation everywhere; anyone
    // with a bigger card can still pick bigger themselves.
    let best = null, bestB = Infinity;
    for (const o of sel.options) {
        const v = (o.value || '').toLowerCase();
        if (!v || /coder|starcoder|codellama|code-|embed|bge-|gte-|nomic/.test(v)) continue;
        const m = v.match(/:(\d+(?:\.\d+)?)\s*b\b/);
        const b = m ? parseFloat(m[1]) : 0;
        if (b < 3) continue;
        if (b < bestB) { bestB = b; best = o.value; }
    }
    if (!best) {
        appendSystem(T('msg.icon.info.no.installed.model.looks.better.fo', '[[icon:info]] No installed model looks better for this. A 3B general model (llama3.2:3b, qwen2.5:3b) is the smallest that answered from the text in testing.'));
        return;
    }
    const box = document.getElementById('console-box');
    if (!box) return;
    const row = document.createElement('div');
    row.className = 'msg msg-system';
    row.style.cssText = 'display:flex;align-items:center;gap:8px;padding:4px 10px;';
    const lbl = document.createElement('span');
    lbl.style.cssText = 'font-size:11px;color:var(--text-muted);';
    lbl.textContent = 'Better for this: ' + best;
    const btn = document.createElement('button');
    btn.className = 'action-btn';
    btn.style.cssText = 'font-size:10px;padding:2px 8px;';
    btn.textContent = T('msg.switch.and.ask.again', 'Switch and ask again');
    btn.onclick = () => {
        sel.value = best;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
        btn.disabled = true;
        appendSystem(T('msg.icon.swap.horiz.switched.to.best.ask.again.t', '[[icon:swap_horiz]] Switched to {best}. Ask again to use it.', {best: best}));
    };
    row.append(lbl, btn);
    box.appendChild(row);
    box.scrollTop = box.scrollHeight;
}

// ── BROADCAST: same prompt to all selected agents in parallel ───────────────
// Does this agent load a LOCAL GPU model (Ollama/LocalAI)? Returns {runner,model}
// or null. Card 3 ('ollama') is local today; when Cards 1/2 gain free local-backend
// agents (M3/M4), _slotBackends[agent] carries their {runner,model} and this picks
// them up too — so the VRAM guard covers them automatically.
function _localModelFor(agent) {
    if (agent === 'ollama') {
        const m = document.getElementById('ollama-select');
        return { runner: 'ollama', model: (m && m.value) ? m.value : '' };
    }
    const bk = (window._slotBackends || {})[agent];
    if (bk && (bk.runner === 'ollama' || bk.runner === 'localai')) {
        return { runner: bk.runner, model: bk.model || '' };
    }
    return null;
}

async function sendBroadcast(text, agents) {
    appendSystem(T('msg.broadcast.to.map', '▶ Broadcast to: {map}', {map: agents.map(agentDisplayName).join(', ')}));

    // Cloud agents (Claude/Codex/Workers/…) cost 0 VRAM → always parallel. Local
    // agents share one GPU: if more than one is selected and they won't co-fit,
    // run the local subset SEQUENTIALLY (keep-alive swap) instead of thrashing/OOM.
    const localSel = agents.map(a => ({ a, loc: _localModelFor(a) })).filter(x => x.loc);
    const cloud    = agents.filter(a => !_localModelFor(a));
    let localSequential = false;

    if (localSel.length > 1) {
        try {
            const r = await fetch('suppliers.php?action=vram_budget', {
                method: 'POST', body: JSON.stringify({ locals: localSel.map(x => x.loc) })
            }).then(r => r.json());
            if (r && r.ok && !r.fits) {
                localSequential = true;
                appendSystem(T('msg.icon.warning.n.local.models.won.t.co.fit.in', '[[icon:warning]] {n} local models won\'t co-fit in VRAM (~{totalneededmb} GB needed, ~{detectedmb} GB detected) — running them one at a time; cloud agents stay parallel.', {n: localSel.length, totalneededmb: Math.round(r.total_needed_mb / 1024), detectedmb: Math.round(r.detected_mb / 1024)}));
            }
        } catch (e) { /* estimate unavailable → fall through to parallel */ }
    }

    const cloudP = Promise.all(cloud.map(a => sendToOne(a, text)));   // cloud: parallel
    if (localSequential) {
        for (const x of localSel) { await sendToOne(x.a, text); }     // local: one at a time
    } else {
        await Promise.all(localSel.map(x => sendToOne(x.a, text)));   // local: parallel (fits or ≤1)
    }
    await cloudP;
    appendSystem(T('msg.icon.check.broadcast.complete', '[[icon:check]] Broadcast complete.'));
}

// ── sendToOne — submit + stream-poll one agent. Returns the response text ───
//    Used by Single, Pipeline, and Broadcast modes.
async function sendToOne(sentAgent, text, cavemanEligible = true) {
    // Workers route — pure HTTP, doesn't go through bridge.php's tmux/streaming
    // pipeline. Dispatch to the dedicated handler that calls workers.php.
    if (sentAgent === 'workers') {
        const _pf = (typeof policyPreflight === 'function') ? await policyPreflight('workers', text) : { text };
        if (_pf.cancel) return null;
        if (_pf.local) return await sendToOne('ollama', text, cavemanEligible);
        return await sendToWorker(_pf.text, cavemanEligible);
    }
    // Tools route — local CLI execution. Tools take a file path and extra args
    // rather than free-form prompt text, so we open the input modal instead of
    // dispatching directly. The modal calls toolsRun() which talks to tools.php.
    if (sentAgent === 'tools') {
        toolsShowInputModal(text);
        return null;
    }

    setLoading(true);
    promptStartTime  = Date.now();
    // CRITICAL: always create a fresh AbortController. Reusing an old one
    // means a stale aborted state can immediately fire on the new request.
    abortController  = new AbortController();
    const localSignal = abortController.signal;
    _activeAgent = sentAgent;   // for Stop → real SIGINT to this agent's tmux pane
    const sentOllamaModel = document.getElementById('ollama-select').value;
    const sentClaudeModel = document.getElementById('claude-model').value;
    const sentGeminiModel = document.getElementById('gemini-model').value;
    const _ci = (typeof _supplierInject === 'function') ? _supplierInject('claude') : {effort:'',args:''};
    const _gi = (typeof _supplierInject === 'function') ? _supplierInject('gemini') : {effort:'',args:''};

    // Build the label/tag for the agent's response message. Always show the
    // Mode + Style that produced it — helps learn which model suits which task.
    const _cap = s => s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
    const _modeTag  = maMode       ? ' · ' + _cap(maMode) : '';
    const _styleTag = currentStyle ? ' · ' + (currentStyle === 'plan' ? 'Outline' : _cap(currentStyle)) : '';
    let tag, label, model = '';
    if (sentAgent === 'claude') {
        tag = 'claude'; model = sentClaudeModel;
        const sel = document.getElementById('claude-model');
        const _pName = window._primaryName || 'CLAUDE';
        label = '[' + _pName + ' · ' + sel.options[sel.selectedIndex].text + _modeTag + _styleTag + ']';
    } else if (sentAgent === 'gemini') {
        tag = 'gemini'; model = sentGeminiModel;
        const sel = document.getElementById('gemini-model');
        const opt = Array.from(sel.options).find(o => o.value === sentGeminiModel);
        // Fallback slot shows the chosen provider's name (GROQ, etc.), not always Gemini.
        const _fbName = window._fallbackName || 'GEMINI';
        label = '[' + _fbName + ' · ' + (opt ? opt.text : sentGeminiModel) + _modeTag + _styleTag + ']';
    } else {
        tag = 'ollama'; model = sentOllamaModel;
        const shortModel = model.includes('/') ? model.split('/').pop() : model;
        label = '[' + (window._localName || 'OLLAMA') + ' · ' + shortModel + _modeTag + _styleTag + ']';
    }

    let token = null;   // hoisted so the finally block can reach it for cleanup

    // Caveman compression — online suppliers only (Claude/Gemini here; Ollama untouched).
    let sendText = text;
    if (cavemanState && cavemanEligible && CAVEMAN_ONLINE.includes(sentAgent)) {
        const cv = await cavemanCompress(text);
        sendText = cv.text;
        if (cv.note) appendSystem(cv.note);
    }

    try {
        // ── 1. SUBMIT ─────────────────────────────────────────────────────────
        // bridge.php runs the dispatch policy first (sensitivity gate, free-only switch, monthly
        // budget). A refusal comes back as {ok:false, policy:{...}}: ask the person, then submit
        // again carrying their answer. Never decided silently.
        let _polOv = {}, submitRes = null, submit = null, _polImages;
        for (let _try = 0; _try < 4; _try++) {
            submitRes = await fetch('bridge.php', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            signal: localSignal,
            body: JSON.stringify({
                policy:       _polOv,
                mode:         'submit',
                // The turn's Mode · Style, saved with the exchange (labels, history). Not the
                // transport field above: bridge.php was storing 'submit' as the mode.
                ma_mode:      maMode,
                style:        currentStyle,
                agent:        sentAgent,
                prompt:       sendText,
                model:        sentOllamaModel,
                claude_model: sentClaudeModel,
                gemini_model: sentGeminiModel,
                claude_effort: _ci.effort, claude_args: _ci.args,
                gemini_effort: _gi.effort, gemini_args: _gi.args,
                project:      currentProject,
                chat:         currentChat,
                // Images this agent takes on its own command line (catalog
                // image_mode 'flag'). Empty for every other mode.
                images:       (_polImages !== undefined) ? _polImages : (_polImages = (typeof takePendingImages === 'function') ? takePendingImages() : [])
            })
            });
            if (!submitRes.ok) throw new Error('HTTP ' + submitRes.status + ' on submit');
            submit = await submitRes.json();
            if (!(submit && submit.policy)) break;
            const _choice = (typeof policyDecide === 'function') ? await policyDecide(submit.policy, sentAgent) : 'cancel';
            if (_choice === 'cancel') {
                appendSystem(T('policy.notsent', '🛡 Not sent — nothing left this computer.'));
                throw new DOMException('cancelled', 'AbortError');
            }
            if (_choice === 'local') {
                appendSystem(T('policy.sent.local', '🛡 Sent to the local model instead, so nothing left this computer.'));
                return await sendToOne('ollama', text, cavemanEligible);
            }
            if (_choice === 'redact') _polOv.gate = 'redact'; else if (_choice === 'anyway') _polOv.gate = 'anyway'; else if (_choice === 'spend_ok') _polOv.spend_ok = true;
        }
        if (!submit.ok || !submit.short) throw new Error((typeof submit.error === 'string' && submit.error) ? submit.error : String(submit.response || submit.message || 'submit failed').replace(/^\[ERROR\]\s*/, ''));   // the bridge answers {error:true, response:"[ERROR] …"}: show the text, not "true"
        (submit.policy_notes || []).forEach(n => appendSystem('🛡 ' + n));
        token = submit.short;
        // Push-RAG (capability "RAG Search"): say what was pulled in, so context is
        // never silently added to a prompt.
        if (Array.isArray(submit.rag) && submit.rag.length) {
            appendSystem(T('msg.icon.menu.book.rag.added.n.itemn2.from.your', '[[icon:menu_book]] RAG added {n} item{n2} from your library: {n3}', {n: submit.rag.length, n2: (submit.rag.length > 1 ? 's' : ''), n3: submit.rag.join(' · ')}));
            if (submit.rag_warn) ragModelNotice(submit.rag_warn);
        } else if (submit.rag_declined > 0) {
            // The relevance floor turned away near misses. Without this line the
            // chat is silent and looks the same as an empty library; with it, the
            // person knows the library WAS consulted and was deliberately not used.
            appendSystem(T('msg.icon.search.off.your.library.has.ragdeclined', '[[icon:search_off]] Your library has {ragdeclined} loosely related item{ragdeclined2}, but none covers what you asked, so nothing was added — answering without it.', {ragdeclined: submit.rag_declined, ragdeclined2: (submit.rag_declined > 1 ? 's' : '')}));
        }
        activeStreamTokens.add(token);

        // ── 2. Placeholder message ───────────────────────────────────────────
        const now2 = new Date();
        const placeholderId = 'msg-stream-' + token;
        appendMsg(tag, label, tag, '', now2, '', '', placeholderId);
        const bodyEl = document.getElementById(placeholderId)
            ?.querySelector('.msg-body');

        // Show "awaiting first token" indicator until real content arrives.
        // It tells the user the system is alive during model warm-up.
        if (bodyEl) {
            bodyEl.innerHTML =
                '<span style="color:var(--text-muted);font-style:italic;">' +
                '⏳ Awaiting first token...</span>';
        }
        let firstChunkArrived = false;

        // ── 3. POLL until done ───────────────────────────────────────────────
        let offset      = 0;
        let collected   = '';
        const startWait = Date.now();
        // Gemini "auto/pro" replies can legitimately take ~3 min; the old 180s cap
        // dropped them as "no response". Give online CLIs more headroom.
        const maxWaitMs = (sentAgent === 'gemini') ? 420 * 1000 : 300 * 1000;

        while (true) {
            // Use the LOCAL signal captured at call time. Don't reach into the
            // global abortController — pipeline/broadcast callers may have
            // swapped it for something else by now.
            if (localSignal.aborted) throw new DOMException('cancelled', 'AbortError');
            if (Date.now() - startWait > maxWaitMs) {
                const partial = collected.trim();
                const partialNote = partial ? ' Partial output (' + partial.length + ' chars) preserved above.' : '';
                throw new Error('Streaming timeout (' + Math.round(maxWaitMs/1000) + 's).' + partialNote);
            }

            await new Promise(r => setTimeout(r, 200));

            const pollRes = await fetch('bridge.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                signal: localSignal,
                body: JSON.stringify({ mode: 'poll', token, offset, agent: sentAgent })
            });
            if (!pollRes.ok) continue;
            const poll = await pollRes.json();
            if (!poll.ok) throw new Error(poll.message || 'poll failed');

            if (poll.chunk && poll.chunk.length > 0) {
                collected += poll.chunk;
                offset = poll.offset;
                if (bodyEl) {
                    if (!firstChunkArrived) {
                        bodyEl.innerHTML = '';
                        firstChunkArrived = true;
                    }
                    bodyEl.textContent = collected;
                    consoleBox.scrollTop = consoleBox.scrollHeight;
                }
            } else if (poll.offset !== undefined) {
                offset = poll.offset;
            }
            if (poll.done) break;
            if (poll.session_dead) {
                const partial = collected.trim();
                const partialNote = partial ? ' Partial output (' + partial.length + ' chars) preserved above.' : '';
                throw new Error('Agent session died mid-response.' + partialNote);
            }
        }

        // ── 4. Finalize ──────────────────────────────────────────────────────
        const elapsed   = ((Date.now() - promptStartTime) / 1000).toFixed(1) + 's';
        const finalText = collected.trim() || '[Empty response]';
        if (bodyEl) bodyEl.innerHTML = renderMarkdown(escHtml(finalText));
        const tagEl = document.getElementById(placeholderId)?.querySelector('.msg-meta');
        if (tagEl) tagEl.textContent = formatTime(now2) + ' · ' + elapsed;

        if (typeof rpExtractCodeBlocks === 'function') {
            rpExtractCodeBlocks(finalText, sentAgent);
        }
        if (typeof rpParseProposals === 'function') {
            rpParseProposals(finalText, sentAgent);
        }
        // A Margin request answered: offer the change against the file as it is
        // on disk, rather than writing anything on the model's say-so.
        if (typeof marginMaybeOffer === 'function') marginMaybeOffer(finalText);
        // A Dossier report: save it into the project so it joins Artifacts.
        if (typeof dossierMaybeSave === 'function') dossierMaybeSave(finalText);
        // Intercom: speak the answer and go back to listening.
        if (typeof intercomMaybeSpeak === 'function') intercomMaybeSpeak(finalText);
        const elapsedSec = parseFloat(elapsed) || 0;
        trackUsage(sentAgent, text, finalText, elapsedSec, model);
        cockpitNotifyIfAway(agentDisplayName(sentAgent) + ' replied', finalText.slice(0, 160).replace(/\s+/g, ' ') + (finalText.length > 160 ? '…' : ''));
        lastMsgTime = new Date();
        return finalText;

    } catch (err) {
        if (err.name === 'AbortError') {
            appendSystem(T('msg.agentdisplayname.prompt.cancelled', '{agentdisplayname}: prompt cancelled.', {agentdisplayname: agentDisplayName(sentAgent)}));
        } else {
            appendError(T('msg.agentdisplayname.error.message', '[{agentdisplayname} ERROR] {message}', {agentdisplayname: agentDisplayName(sentAgent), message: err.message}));
            _offerRetry(sentAgent, text, model);
        }
        // On any failure path (cancel, network error, server error), tell the
        // server to clean up any leftover .out/.done files for this token.
        // Best-effort — fire and forget; we don't await it.
        if (token) {
            fetch('bridge.php', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ mode: 'cleanup', token })
            }).catch(() => {});
        }
        return null;
    } finally {
        if (token) activeStreamTokens.delete(token);
        setLoading(false);
        // Don't null abortController here in pipeline/broadcast — they manage it themselves
        if (maMode === 'single') abortController = null;
    }
}

function _offerRetry(agent, prompt, model) {
    const id = 'retry-' + Date.now();
    const div = document.createElement('div');
    div.id = id;
    div.style.cssText = 'margin:4px 0;padding:4px 8px;display:inline-flex;align-items:center;gap:6px;';
    div.innerHTML = '<button style="padding:3px 10px;font-size:11px;cursor:pointer;' +
        'background:var(--accent-blue);color:#fff;border:none;border-radius:3px;" ' +
        'onclick="_retryPrompt(this)" data-agent="' + escHtml(agent) + '" ' +
        'data-prompt="' + escHtml(btoa(unescape(encodeURIComponent(prompt)))) + '" ' +
        'data-model="' + escHtml(model || '') + '">Retry</button>' +
        '<span style="font-size:10px;color:var(--text-dim);">Resend same prompt to ' +
        agentDisplayName(agent) + '</span>';
    consoleBox.appendChild(div);
    consoleBox.scrollTop = consoleBox.scrollHeight;
}

async function _retryPrompt(btn) {
    const agent = btn.dataset.agent;
    const prompt = decodeURIComponent(escape(atob(btn.dataset.prompt)));
    const model = btn.dataset.model || null;
    btn.closest('div').remove();
    appendSystem(T('msg.retrying.prompt.to.agentdisplayname', 'Retrying prompt to {agentdisplayname}...', {agentdisplayname: agentDisplayName(agent)}));
    document.getElementById('prompt-in').value = prompt;
    sendPrompt();
}

