// =============================================================================
// USAGE TRACKING
// =============================================================================
// Persisted in localStorage for cross-reload survival (no server needed for UI)
const CLAUDE_TOKEN_MAX  = 44000;   // Claude Pro ~44K tokens per 5-hour window
const CLAUDE_WINDOW_MS  = 5 * 60 * 60 * 1000;  // 5 hours in ms
const OLLAMA_SESSION_MAX = 50;     // Arbitrary visual max for progress bar (calls)

// Load persisted stats or initialise fresh
function loadUsageStats() {
    try {
        const raw = localStorage.getItem('cockpit_usage');
        if (raw) return JSON.parse(raw);
    } catch(e) {}
    return {
        claude: { tokens: 0, windowStart: null },
        gemini: { calls: 0, dayStart: null },
        ollama: { calls: 0, totalTime: 0, tokens: 0, sessionStart: Date.now() }
    };
}

function saveUsageStats(stats) {
    try { localStorage.setItem('cockpit_usage', JSON.stringify(stats)); } catch(e) {}
}

let usageStats = loadUsageStats();

// Estimate tokens from text (1 token ≈ 4 chars of English)
function estimateTokens(text) {
    return Math.ceil((text || '').length / 4);
}

// =============================================================================
// COST TIERS — Session (volatile) / Chat / Project accumulated usage.
// Session lives in memory only (resets on reload). Chat + Project come from the
// authoritative ledger (stats.php → cost_stats.json), refreshed on switch and
// periodically (item 3: reconciliation — see _costReconcile).
// =============================================================================
let _costSession = { tin:0, tout:0, usd:0, turns:0 };
let _costChat    = { tin:0, tout:0, usd:0, turns:0 };
let _costProject = { tin:0, tout:0, usd:0, turns:0 };

function _costFmt(o) {
    const t = (o.tin || 0) + (o.tout || 0);
    let s = (typeof _fmtK === 'function' ? _fmtK(t) : t) + ' tok';
    if ((o.usd || 0) > 0) s += ' · $' + (+o.usd).toFixed(o.usd < 1 ? 4 : 2);
    return s;
}
function costRenderTiers() {
    const set = (id, o, lbl) => { const e = document.getElementById(id); if (e) e.textContent = lbl + ' ' + _costFmt(o); };
    set('cost-session', _costSession, 'S');
    set('cost-chat',    _costChat,    'C');
    set('cost-project', _costProject, 'P');
}
async function costLoadForChat() {
    if (typeof _setSyncDots === 'function') _setSyncDots(true);
    try {
        const r = await fetch('stats.php?action=get&project=' + encodeURIComponent(currentProject || 'default') +
                              '&chat=' + encodeURIComponent(currentChat || 'default'));
        const d = await r.json();
        if (d.ok) { _costChat = d.chat; _costProject = d.project; costRenderTiers(); }
    } catch (e) {}
    finally { if (typeof _setSyncDots === 'function') setTimeout(() => _setSyncDots(false), 350); }
}
async function costRecordTurn(tin, tout, usd) {
    tin = tin || 0; tout = tout || 0; usd = usd || 0;
    _costSession.tin += tin; _costSession.tout += tout; _costSession.usd += usd; _costSession.turns++;
    try {
        const r = await fetch('stats.php?action=add', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ project: currentProject || 'default', chat: currentChat || 'default', tin, tout, usd }) });
        const d = await r.json();
        if (d.ok) { _costChat = d.chat; _costProject = d.project; }
    } catch (e) {}
    costRenderTiers();
}
// item 3: reconciliation — periodically re-pull the chat/project tiers from the
// authoritative ledger (keeps them correct across turns/tabs). The supplier-card
// token meters separately reconcile from usage_parser.php (the official logs).
// Note: official logs are per-day per-agent, NOT chat-scoped, so per-chat
// attribution stays sourced from the cockpit's own per-turn recording.
setInterval(() => { if (typeof costLoadForChat === 'function') costLoadForChat(); }, 45000);
document.addEventListener('DOMContentLoaded', () => setTimeout(costLoadForChat, 1400));

// Called after each successful exchange — update counters
function trackUsage(agent, promptText, responseText, durationSec, model) {
    const now = Date.now();
    const inTok  = estimateTokens(promptText);
    const outTok = estimateTokens(responseText);
    const tokens = inTok + outTok;

    if (agent === 'claude') {
        // Reset window if 5 hours have passed
        if (!usageStats.claude.windowStart ||
            now - usageStats.claude.windowStart > CLAUDE_WINDOW_MS) {
            usageStats.claude.windowStart = now;
            usageStats.claude.tokens = 0;
            usageStats.claude.input  = 0;
            usageStats.claude.output = 0;
        }
        usageStats.claude.tokens += tokens;
        usageStats.claude.input  = (usageStats.claude.input  || 0) + inTok;
        usageStats.claude.output = (usageStats.claude.output || 0) + outTok;

    } else if (agent === 'gemini') {
        // Reset daily counter at midnight (check if day has changed)
        const today = new Date().toDateString();
        if (usageStats.gemini.dayStart !== today) {
            usageStats.gemini.dayStart = today;
            usageStats.gemini.calls    = 0;
            usageStats.gemini.tokens   = 0;
            usageStats.gemini.input    = 0;
            usageStats.gemini.output   = 0;
        }
        usageStats.gemini.calls++;
        usageStats.gemini.tokens = (usageStats.gemini.tokens || 0) + tokens;
        usageStats.gemini.input  = (usageStats.gemini.input  || 0) + inTok;
        usageStats.gemini.output = (usageStats.gemini.output || 0) + outTok;

    } else { // ollama
        usageStats.ollama.calls++;
        usageStats.ollama.totalTime = (usageStats.ollama.totalTime || 0) + (durationSec || 0);
        usageStats.ollama.tokens    = (usageStats.ollama.tokens || 0) + tokens;
        usageStats.ollama.input     = (usageStats.ollama.input  || 0) + inTok;
        usageStats.ollama.output    = (usageStats.ollama.output || 0) + outTok;
    }

    saveUsageStats(usageStats);
    // Cost tiers: record this turn (CLI agents have no $ cost → usd 0).
    if (typeof costRecordTurn === 'function') costRecordTurn(inTok, outTok, 0);
    // Supplier-card meters are driven by a single authoritative source:
    // _cardUsagePoll() → usage_parser.php (with a usageStats fallback when the
    // server log dir is unreadable). The older renderUsageMeters() and
    // fetchAndRenderUsageFromServer() writers were removed (#8) — three writers
    // on three timers fought over the same DOM and flickered.
    if (typeof _cardUsagePoll === 'function') _cardUsagePoll();
}

// Format seconds as "1h 23m" or "45s"
function fmtTime(sec) {
    if (!sec || sec < 1) return '0s';
    if (sec < 60)  return Math.round(sec) + 's';
    if (sec < 3600) return Math.floor(sec/60) + 'm ' + (Math.round(sec)%60) + 's';
    return Math.floor(sec/3600) + 'h ' + Math.floor((sec%3600)/60) + 'm';
}

// Format remaining time
function fmtRemaining(msRemaining) {
    if (msRemaining <= 0) return 'now';
    const s = Math.ceil(msRemaining / 1000);
    if (s < 60)   return 'in ' + s + 's';
    if (s < 3600) return 'in ' + Math.floor(s/60) + 'm';
    return 'in ' + Math.floor(s/3600) + 'h ' + Math.floor((s%3600)/60) + 'm';
}

// renderUsageMeters() removed (#8). Supplier-card meters are now written by a
// single authoritative updater, _cardUsagePoll() → _updateCardCompact(), which
// reads usage_parser.php and falls back to the client-side usageStats counter
// when the server log dir is unreadable. usageStats is still maintained upstream
// (incremented per turn) purely as that fallback source.
function renderUsageMeters() {
    // Back-compat shim: a few call sites (reset buttons, init) still call this.
    // Delegate to the single authoritative poll instead of writing the DOM here.
    if (typeof _cardUsagePoll === 'function') _cardUsagePoll();
}

// fetchAndRenderUsageFromServer() removed (#8) — it was a duplicate card-meter
// writer (usage_parser.php → claude-bar/gemini-bar/ollama-bar) that competed with
// _cardUsagePoll() on a separate 60s timer, causing the meters to flicker between
// two text formats. _cardUsagePoll() is now the single authoritative updater.

// Reset Claude window counter button (right-click on meter, or call manually)
function resetClaudeWindow() {
    usageStats.claude.tokens = 0;
    usageStats.claude.windowStart = Date.now();
    saveUsageStats(usageStats);
    renderUsageMeters();
    appendSystem(T('msg.claude.5.hour.window.reset.manually', 'Claude 5-hour window reset manually.'));
}

function resetGeminiDay() {
    usageStats.gemini.calls    = 0;
    usageStats.gemini.tokens   = 0;
    usageStats.gemini.dayStart = new Date().toDateString();
    saveUsageStats(usageStats);
    renderUsageMeters();
    appendSystem(T('msg.gemini.daily.counter.reset.manually', 'Gemini daily counter reset manually.'));
}

function resetOllamaSession() {
    usageStats.ollama.calls     = 0;
    usageStats.ollama.totalTime = 0;
    usageStats.ollama.tokens    = 0;
    saveUsageStats(usageStats);
    renderUsageMeters();
    appendSystem(T('msg.ollama.session.counters.reset', 'Ollama session counters reset.'));
}

// Add double-click reset handlers to usage blocks
document.addEventListener('DOMContentLoaded', () => {
    // Refresh the supplier-card meters every 30s (delegates to _cardUsagePoll →
    // usage_parser.php). The dedicated _cardUsagePoll interval (10s) is the
    // primary; this is a low-frequency safety tick.
    setInterval(renderUsageMeters, 30000);

    // Inject title bars for initially active panels
    setTimeout(() => {
        const rightActive = document.querySelector('#sidebar-right .sidebar-panel.active');
        if (rightActive) _injectPanelTitle(rightActive, rightActive.id.replace('right-', ''));
        const leftActive = document.querySelector('#sidebar-left .sidebar-panel.active');
        if (leftActive) _injectPanelTitle(leftActive, leftActive.id.replace('left-', ''));
    }, 100);

    // Context menus for usage blocks and time button (replaces inline oncontextmenu)
    const ollamaUsage = document.getElementById('ollama-usage-block');
    if (ollamaUsage) ollamaUsage.addEventListener('contextmenu', e => {
        e.preventDefault();
        cockpitContextMenu(e, [
            { label: 'Reset Ollama session', icon: 'restart_alt', action: () => resetOllamaSession() }
        ]);
    });
    const workersUsage = document.getElementById('workers-usage-block');
    if (workersUsage) workersUsage.addEventListener('contextmenu', e => {
        e.preventDefault();
        cockpitContextMenu(e, [
            { label: 'Reset Workers usage', icon: 'restart_alt', action: () => workersResetAllUsage() }
        ]);
    });
    const timeBtn = document.getElementById('time-btn');
    if (timeBtn) timeBtn.addEventListener('contextmenu', e => {
        e.preventDefault();
        cockpitContextMenu(e, [
            { label: 'Time report', icon: 'assessment', action: () => timeReportOpen() }
        ]);
    });
});

// syncUsageBlockWidths removed — table handles alignment

// =============================================================================
// FONT CONTROLS
// Base size = console font size. All other sizes scale by the same ratio.
// =============================================================================
const FONT_DEFAULTS = {
    uiSize:      13.5,   // px — matches CSS --font-size-ui
    consoleSize: 14.5,   // px — matches CSS --font-size-console
    family:      'tahoma'
};

const FONT_FAMILIES = {
    tahoma:   { ui: "'Tahoma', 'Segoe UI', Geneva, sans-serif",
                mono: "'MesloLGS NF', 'MesloLGS Nerd Font Mono', 'Cascadia Code', 'Courier New', monospace" },
    segoe:    { ui: "'Segoe UI', Tahoma, Geneva, sans-serif",
                mono: "'Cascadia Code', 'Consolas', 'Courier New', monospace" },
    arial:    { ui: "Arial, Helvetica, sans-serif",
                mono: "'Courier New', monospace" },
    meslo:    { ui: "'MesloLGS NF', 'MesloLGS Nerd Font Mono', monospace",
                mono: "'MesloLGS NF', 'MesloLGS Nerd Font Mono', monospace" },
    cascadia: { ui: "'Cascadia Code', monospace",
                mono: "'Cascadia Code', 'Consolas', monospace" },
    consolas: { ui: "'Consolas', 'Courier New', monospace",
                mono: "'Consolas', 'Courier New', monospace" }
};

// Load persisted font settings
let fontState = { ...FONT_DEFAULTS };
try {
    const saved = JSON.parse(localStorage.getItem('cockpit_font') || '{}');
    if (saved.consoleSize) fontState = { ...FONT_DEFAULTS, ...saved };
} catch(e) {}

function applyFontFamily(key) {
    fontState.family = key;
    const fam = FONT_FAMILIES[key] || FONT_FAMILIES.tahoma;
    document.documentElement.style.setProperty('--font-ui',   fam.ui);
    document.documentElement.style.setProperty('--font-mono', fam.mono);
    saveFontState();
}

function changeFontSize(delta) {
    fontState.consoleSize = Math.max(10, Math.min(28, fontState.consoleSize + delta));
    applyFontSizes();
    syncFontSizeSelect();
    saveFontState();
}

function setFontSize(size) {
    fontState.consoleSize = Math.max(10, Math.min(28, size));
    applyFontSizes();
    saveFontState();
}

function syncFontSizeSelect() {
    const sel = document.getElementById('font-size-select');
    if (!sel) return;
    // Try to select exact match; if not found, select closest
    const target = String(fontState.consoleSize);
    let found = false;
    for (const opt of sel.options) {
        if (opt.value === target) { sel.value = target; found = true; break; }
    }
    if (!found) {
        // Add a custom option for non-standard sizes
        const opt = document.createElement('option');
        opt.value = target;
        opt.textContent = target + 'px';
        sel.appendChild(opt);
        sel.value = target;
    }
}

// Text style toggles — apply CSS classes to the console
const textStyles = { bold: false, italic: false, underline: false };

function toggleTextStyle(style) {
    textStyles[style] = !textStyles[style];
    const btn = document.getElementById('btn-' + style);

    if (style === 'bold') {
        consoleBox.style.fontWeight = textStyles.bold ? '700' : '';
        if (btn) btn.style.background = textStyles.bold ? 'var(--gemini-dim)' : '';
    } else if (style === 'italic') {
        consoleBox.style.fontStyle = textStyles.italic ? 'italic' : '';
        if (btn) btn.style.background = textStyles.italic ? 'var(--gemini-dim)' : '';
    } else if (style === 'underline') {
        // Underline applies to message tags only
        const styleEl = document.getElementById('underline-style') ||
            (() => { const s = document.createElement('style');
                     s.id = 'underline-style';
                     document.head.appendChild(s); return s; })();
        styleEl.textContent = textStyles.underline
            ? '.msg-tag { text-decoration: underline; }'
            : '';
        if (btn) btn.style.background = textStyles.underline ? 'var(--gemini-dim)' : '';
    }
    saveFontState();
}

function applyFontSizes() {
    const root  = document.documentElement;
    const ratio = FONT_DEFAULTS.uiSize / FONT_DEFAULTS.consoleSize; // ~0.931

    // Scale ALL size-bearing CSS variables by the same ratio from the base console size
    const cs = fontState.consoleSize;  // base
    root.style.setProperty('--font-size-ui',      (cs * ratio).toFixed(1) + 'px');
    root.style.setProperty('--font-size-console', cs + 'px');

    // Scale fixed px values used throughout the UI
    // Topbar rows
    document.querySelectorAll('.topbar-row1 td').forEach(el =>
        el.style.height = Math.round(cs * 2.9) + 'px');
    document.querySelectorAll('.topbar-row2 td').forEach(el =>
        el.style.height = Math.round(cs * 1.93) + 'px');

    // Status bar
    const sb = document.querySelector('.statusbar');
    if (sb) sb.style.height = Math.round(cs * 1.66) + 'px';

    // Console toolbar
    const ct = document.querySelector('.console-toolbar');
    if (ct) ct.style.height = Math.round(cs * 2.07) + 'px';

    // Sidebar tabs (legacy text tabs only — vtabs use fixed-size icons)
    document.querySelectorAll('.sidebar-tab').forEach(el =>
        el.style.fontSize = Math.round(cs * 0.72) + 'px');

    // Status bar labels
    document.querySelectorAll('.status-label,.usage-label,.usage-value,.usage-reset').forEach(el =>
        el.style.fontSize = (cs * 0.66).toFixed(1) + 'px');

    // Topbar agent buttons
    document.querySelectorAll('.agent-btn').forEach(el =>
        el.style.fontSize = (cs * 0.76).toFixed(1) + 'px');

    // Model selects
    document.querySelectorAll('.model-select,.font-family-select').forEach(el =>
        el.style.fontSize = (cs * 0.76).toFixed(1) + 'px');

    // Action buttons
    document.querySelectorAll('.action-btn').forEach(el =>
        el.style.fontSize = (cs * 0.76).toFixed(1) + 'px');

    // Footer textarea
    const ta = document.getElementById('prompt-in');
    if (ta) ta.style.fontSize = (cs * 0.86).toFixed(1) + 'px';

    // Body base
    document.body.style.fontSize = (cs * ratio).toFixed(1) + 'px';

    // Update display
    const disp = document.getElementById('font-size-display');
    if (disp) disp.textContent = cs + 'px';
}

function resetFont() {
    fontState = { ...FONT_DEFAULTS };
    applyFontFamily(fontState.family);
    applyFontSizes();
    const sel = document.getElementById('font-family-select');
    if (sel) sel.value = 'tahoma';
    saveFontState();
}

function saveFontState() {
    // Include text style states in persisted settings
    fontState.bold      = textStyles.bold;
    fontState.italic    = textStyles.italic;
    fontState.underline = textStyles.underline;
    try { localStorage.setItem('cockpit_font', JSON.stringify(fontState)); } catch(e) {}
}

function initFontControls() {
    applyFontFamily(fontState.family);
    applyFontSizes();
    const sel = document.getElementById('font-family-select');
    if (sel) sel.value = fontState.family;
    syncFontSizeSelect();
    // Restore text styles
    if (fontState.bold)      toggleTextStyle('bold');
    if (fontState.italic)    toggleTextStyle('italic');
    if (fontState.underline) toggleTextStyle('underline');
}

