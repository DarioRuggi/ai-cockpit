// USAGE PANEL — Phase 2b 2026-05-09
// =============================================================================
// Free-tier quota tracker for the Workers providers. Renders the right-sidebar
// "right-usage" panel and also feeds the inline indicator on the Workers
// supplier card. Refreshed by the existing 4-second status poll
// (see refreshStatus → setInterval near the top of the script section).
//
// =============================================================================
// DATE / TIME FORMATTING — 24h clock, DD/MM/YYYY everywhere
// =============================================================================
function fmtTime(d) {
    if (!(d instanceof Date)) d = new Date(d);
    return d.toLocaleTimeString([], {hour:'2-digit', minute:'2-digit', second:'2-digit', hour12:false});
}
function fmtTimeSh(d) {
    if (!(d instanceof Date)) d = new Date(d);
    return d.toLocaleTimeString([], {hour:'2-digit', minute:'2-digit', hour12:false});
}
function fmtDate(d) {
    if (!(d instanceof Date)) d = new Date(d);
    const dd = String(d.getDate()).padStart(2,'0');
    const mm = String(d.getMonth()+1).padStart(2,'0');
    const yy = d.getFullYear();
    return dd + '/' + mm + '/' + yy;
}
function fmtDateTime(d) {
    if (!(d instanceof Date)) d = new Date(d);
    return fmtDate(d) + ' ' + fmtTimeSh(d);
}
function fmtDateTimeSec(d) {
    if (!(d instanceof Date)) d = new Date(d);
    return fmtDate(d) + ' ' + fmtTime(d);
}
// Compact poll every 10s for all cards; full detail immediately on expand
// =============================================================================
let _cardUsageTimer = null;
const CLAUDE_MAX_TOKENS = 44000;   // ~Claude Pro 5h window
const CLAUDE_CTX_WINDOW = 5 * 60 * 60; // 5h in seconds

async function _fetchCardUsage(mode) {
    // mode: 'compact' (today summary) or 'full' (today + session detail)
    try {
        const r = await fetch('usage_parser.php?action=all&range=today');
        if (!r.ok) return null;
        return await r.json();
    } catch(e) { return null; }
}

function _updateCardCompact(d) {
    if (!d) return;
    const now = new Date().toLocaleTimeString([], {hour:'2-digit', minute:'2-digit', second:'2-digit', hour12:false});

    // ── Claude ────────────────────────────────────────────────────────────────
    // Server total = input+output. When the log dir is unreadable by www-data
    // (c.note set) the server returns 0 — fall back to client-side usageStats,
    // the same source the Usage tab uses, so the card stays in sync.
    const c = d.claude || {};
    let ctok = (c.input || 0) + (c.output || 0);
    if (ctok === 0 && typeof usageStats !== 'undefined' && usageStats.claude) {
        ctok = usageStats.claude.tokens || 0;
    }
    const cpct = Math.min(100, Math.round(ctok / CLAUDE_MAX_TOKENS * 100));
    const cEl  = document.getElementById('claude-tokens-val');
    if (cEl) cEl.textContent = _fmtK(ctok) + ' / ~44K tok';
    const cBar = document.getElementById('claude-bar');
    if (cBar) cBar.style.width = cpct + '%';
    const cMini = document.getElementById('claude-bar-mini');
    if (cMini) cMini.style.width = cpct + '%';
    const cRt = document.getElementById('claude-refresh-time');
    if (cRt) cRt.textContent = '↻ ' + now;

    // ── Gemini ────────────────────────────────────────────────────────────────
    const g = d.gemini || {};
    let gtok  = g.total || 0;
    let gmsg  = g.messages || 0;
    if (gtok === 0 && typeof usageStats !== 'undefined' && usageStats.gemini) {
        gtok = usageStats.gemini.tokens || 0;
        gmsg = usageStats.gemini.calls  || gmsg;
    }
    const gpct  = Math.min(100, Math.round(gtok / 100000 * 100)); // ~100K daily
    const gEl   = document.getElementById('gemini-tokens-val');
    if (gEl) gEl.textContent = gmsg + ' msg · ' + _fmtK(gtok) + ' tok';
    const gBar  = document.getElementById('gemini-bar');
    if (gBar) gBar.style.width = gpct + '%';
    const gMini = document.getElementById('gemini-bar-mini');
    if (gMini) gMini.style.width = gpct + '%';
    const gRt = document.getElementById('gemini-refresh-time');
    if (gRt) gRt.textContent = '↻ ' + now;

    // ── Workers ───────────────────────────────────────────────────────────────
    const w = d.workers?.providers || {};
    const provKeys = Object.keys(w);
    let wtotalCalls = 0, wmaxPct = 0, wprovName = '—';
    for (const pk of provKeys) {
        wtotalCalls += (w[pk].calls_used || 0);
        if ((w[pk].calls_pct || 0) > wmaxPct) {
            wmaxPct   = w[pk].calls_pct;
            wprovName = w[pk].name || pk;
        }
    }
    const wEl  = document.getElementById('workers-calls-val');
    if (wEl) wEl.textContent = wtotalCalls + ' calls · ' + provKeys.length + ' providers';
    const wpEl = document.getElementById('workers-providers-val');
    if (wpEl) wpEl.textContent = provKeys.length > 0 ? 'max: ' + wmaxPct + '% (' + wprovName + ')' : '— configure —';
    const wBar = document.getElementById('workers-bar');
    if (wBar) wBar.style.width = Math.min(100, wmaxPct) + '%';
    const wMini = document.getElementById('workers-bar-mini');
    if (wMini) wMini.style.width = Math.min(100, wmaxPct) + '%';
    const o = d.ollama || {};
    const ocalls = o.calls || 0;
    const optok  = o.prompt_tokens || 0;
    const octx   = o.context_window || 32768;
    const opct   = Math.min(100, Math.round(optok / octx * 100));
    const oEl    = document.getElementById('ollama-calls-val');
    if (oEl) oEl.textContent = ocalls + ' calls · ' + _fmtK(optok) + ' tok';
    const oBar   = document.getElementById('ollama-bar');
    if (oBar) oBar.style.width = opct + '%';
    const oMini  = document.getElementById('ollama-bar-mini');
    if (oMini) oMini.style.width = opct + '%';
    const oRt = document.getElementById('ollama-refresh-time');
    if (oRt) oRt.textContent = '↻ ' + now;
}

function _updateCardFull(agent, d) {
    if (!d) return;

    if (agent === 'claude') {
        const c = d.claude || {};
        // Fall back to live client-side usageStats when server returns 0
        // (www-data often can't read ~/.claude logs).
        const inTok  = (c.input  || 0) || (usageStats.claude.input  || 0);
        const outTok = (c.output || 0) || (usageStats.claude.output || 0);
        _setText('claude-d-input',  _fmtK(inTok));
        _setText('claude-d-output', _fmtK(outTok));
        _setText('claude-d-cache',  _fmtK(c.cache_read || 0));
        // R = time remaining in the current 5h window
        let rTxt = '—';
        if (usageStats.claude.windowStart) {
            const rem = CLAUDE_WINDOW_MS - (Date.now() - usageStats.claude.windowStart);
            if (rem > 0) rTxt = fmtRemaining(rem);
        } else if (c.messages > 0) {
            rTxt = '5h win';
        }
        _setText('claude-d-reset', rTxt);
    }

    if (agent === 'gemini') {
        const g = d.gemini || {};
        const inTok  = (g.input  || 0) || (usageStats.gemini.input  || 0);
        const outTok = (g.output || 0) || (usageStats.gemini.output || 0);
        _setText('gemini-d-input',    _fmtK(inTok));
        _setText('gemini-d-output',   _fmtK(outTok));
        _setText('gemini-d-cache',    _fmtK(g.cached   || 0));
        _setText('gemini-d-thoughts', _fmtK(g.thoughts || 0));
    }

    if (agent === 'ollama') {
        const o = d.ollama || {};
        _setText('ollama-d-prompt', _fmtK(o.prompt_tokens || 0));
        _setText('ollama-d-output', _fmtK(o.output_tokens || 0));
        _setText('ollama-d-calls',  String(o.calls || 0));
        _setText('ollama-d-ms',     String(o.avg_ms || 0));
    }
}

function _setText(id, val) {
    const el = document.getElementById(id);
    if (el) el.textContent = val;
}

function _fmtK(n) {
    n = parseInt(n) || 0;
    if (n >= 1000000) return (n/1000000).toFixed(2) + 'M';
    if (n >= 1000)    return (n/1000).toFixed(1) + 'K';
    return String(n);
}

// Called by supActivate when a card is selected
async function cardUsageOnExpand(agent) {
    const d = await _fetchCardUsage('full');
    _updateCardCompact(d);
    _updateCardFull(agent, d);
}

// Called by setAgent when a card is deselected — CSS hides .sup-detail-row automatically
function cardUsageOnCollapse(agent) { /* no-op — CSS handles it */ }

// Poll every 10s — compact update for all cards, plus full detail for the
// currently-expanded agent card so its I/O/C/R values refresh after prompting.
// ── Dario-10S encryption tester (FPC ⇄ PHP cross-check) ────────────────────
async function runEncryptionTest() {
    appendSystem(T('msg.running.dario.10s.cipher.cross.test.free.pas', 'Running Dario-10S cipher cross-test (Free Pascal vs PHP)…'));
    let d;
    try { const r = await fetch('encryptester.php'); d = await r.json(); }
    catch (e) { appendError(T('msg.cipher.test.failed.message', 'Cipher test failed: {message}', {message: e.message})); return; }
    document.getElementById('cipher-test-modal')?.remove();
    const ov = document.createElement('div');
    ov.id = 'cipher-test-modal';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const rows = (d.tests || []).map(t =>
        '<div style="display:flex;align-items:center;gap:8px;font-size:11.5px;padding:3px 0;">' +
        '<span class="material-symbols-rounded" style="font-size:15px;color:' + (t.pass ? 'var(--accent-cyan)' : 'var(--accent-orange)') + ';">' +
        (t.pass ? 'check_circle' : 'cancel') + '</span><span>' + escHtml(t.name) + '</span>' +
        '<b style="margin-left:auto;color:' + (t.pass ? 'var(--accent-cyan)' : 'var(--accent-orange)') + ';">' + (t.pass ? 'PASS' : 'FAIL') + '</b></div>').join('');
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(560px,92vw);padding:18px 22px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:12px;">' +
            '<span class="material-symbols-rounded" style="color:var(--gemini);font-size:18px;">enhanced_encryption</span>' +
            '<h2 style="margin:0;font-size:14px;color:var(--gemini);flex:1;">Dario-10S cipher test</h2>' +
            '<b style="font-size:12px;color:' + (d.skipped ? 'var(--text-muted)' : (d.ok ? 'var(--accent-cyan)' : 'var(--accent-orange)')) + ';">' + (d.skipped ? 'PARTIAL — cross-check skipped' : (d.ok ? 'ALL PASS' : 'FAIL')) + '</b>' +
        '</div>' +
        (d.error ? '<p style="color:var(--accent-orange);font-size:12px;">' + escHtml(d.error) + '</p>' : '') +
        (d.skipped ? '<p style="color:var(--text-muted);font-size:11px;">The Free Pascal cross-check needs <code>fpc</code> and the Pascal source, which a normal install does not carry (' + escHtml(d.reason || '') + '). The PHP implementation the app uses was tested above.</p>' : '') +
        rows +
        '<div style="font-size:10px;color:var(--text-muted);margin-top:10px;font-family:var(--font-mono);word-break:break-all;">' +
            'key=' + (d.key_len || '?') + 'B · keyNum=' + (d.keynum ?? '?') + ' · fpc=' + escHtml(d.fpc || '—') + '<br>' +
            'cipher: ' + escHtml((d.php_cipher || '').slice(0, 64)) + '…</div>' +
        '<div style="display:flex;justify-content:flex-end;margin-top:14px;">' +
            '<button class="action-btn" onclick="document.getElementById(\'cipher-test-modal\').remove()" style="padding:5px 16px;">Close</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    appendSystem(T('msg.cipher.test.skipped', 'Cipher test: {skipped}', {skipped: (d.skipped
        ? ((d.ok ? 'PHP roundtrip PASS' : 'PHP roundtrip FAILED') + ' — cross-check with Free Pascal skipped (' + (d.reason || 'not available here') + ').')
        : (d.ok ? 'ALL PASS — FPC and PHP encryption are byte-identical.' : 'FAIL — see the dialog.'))}));
}

// ── Local multimodal generation (Image / Sound / Video) ───────────────────
let _genTimers = {};   // id → poll interval
function genOpenDialog(kind) {
    document.getElementById('gen-modal')?.remove();
    const presets = {
        image: [['logo','Logo'],['icon','Icon'],['favicon','FavIcon'],['background','Background'],['image','Plain image']],
        video: [['gif','Animated GIF'],['effect','Short effect'],['logo','Animated logo']],
        sound: [],
    }[kind] || [];
    const title = { image:'Generate image (local sd.cpp)', sound:'Generate sound (local)', video:'Generate animated GIF (sd.cpp + ffmpeg)' }[kind];
    const ph    = { image:'a control yoke logo, vector, dark background', sound:'Text to speak aloud…', video:'a glowing control yoke, neon' }[kind];
    const icon  = { image:'<span class="material-symbols-rounded ico">palette</span>', sound:'<span class="material-symbols-rounded ico">music_note</span>', video:'<span class="material-symbols-rounded ico">movie</span>' }[kind];
    const _selCss = 'margin-left:6px;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:11px;padding:3px 6px;border-radius:3px;';
    const presetHtml = presets.length
        ? '<label style="font-size:11px;color:var(--text-muted);display:block;margin-bottom:8px;">Preset ' +
          '<select id="gen-preset" style="' + _selCss + '">' +
          presets.map(p => '<option value="' + p[0] + '">' + p[1] + '</option>').join('') + '</select></label>'
        : '';
    // Sound gets a Type + (for speech) Language picker.
    const soundHtml = kind === 'sound'
        ? '<div style="display:flex;gap:14px;align-items:center;margin-bottom:8px;flex-wrap:wrap;">' +
            '<label style="font-size:11px;color:var(--text-muted);">Type' +
              '<select id="gen-sound-type" onchange="_genSoundTypeChange()" style="' + _selCss + '">' +
              '<option value="speech">Speech (TTS)</option><option value="effect">Effect</option>' +
              '<option value="melody">Melody</option><option value="background">Background</option></select></label>' +
            '<label id="gen-lang-wrap" style="font-size:11px;color:var(--text-muted);">Language' +
              '<select id="gen-lang" style="' + _selCss + '"><option value="auto">Auto</option>' +
              '<option value="ar">Arabic</option><option value="bg">Bulgarian</option><option value="ca">Catalan</option><option value="zh">Chinese</option><option value="cs">Czech</option><option value="da">Danish</option><option value="nl">Dutch</option><option value="en">English</option><option value="et">Estonian</option><option value="fi">Finnish</option><option value="fr">French</option><option value="ka">Georgian</option><option value="de">German</option><option value="el">Greek</option><option value="he">Hebrew</option><option value="hi">Hindi</option><option value="hu">Hungarian</option><option value="is">Icelandic</option><option value="id">Indonesian</option><option value="it">Italian</option><option value="ja">Japanese</option><option value="kk">Kazakh</option><option value="ko">Korean</option><option value="lv">Latvian</option><option value="lb">Luxembourgish</option><option value="ne">Nepali</option><option value="no">Norwegian</option><option value="fa">Persian</option><option value="pl">Polish</option><option value="pt">Portuguese</option><option value="ro">Romanian</option><option value="ru">Russian</option><option value="sr">Serbian</option><option value="sk">Slovak</option><option value="sl">Slovenian</option><option value="es">Spanish</option><option value="sw">Swahili</option><option value="sv">Swedish</option><option value="th">Thai</option><option value="tr">Turkish</option><option value="uk">Ukrainian</option><option value="vi">Vietnamese</option><option value="cy">Welsh</option></select></label>' +
          '</div>'
        : '';
    // Video (animated GIF) gets Motion (img2img strength) + Frames (length) pickers.
    const videoHtml = kind === 'video'
        ? '<div style="display:flex;gap:14px;align-items:center;margin-bottom:8px;flex-wrap:wrap;">' +
            '<label style="font-size:11px;color:var(--text-muted);">Motion' +
              '<select id="gen-strength" style="' + _selCss + '">' +
              '<option value="0.20">Subtle (0.20)</option>' +
              '<option value="0.32" selected>Medium (0.32)</option>' +
              '<option value="0.45">Strong (0.45)</option>' +
              '<option value="0.60">Wild (0.60)</option></select></label>' +
            '<label style="font-size:11px;color:var(--text-muted);">Frames' +
              '<select id="gen-frames" style="' + _selCss + '">' +
              '<option value="6" selected>6 (short ~2 min)</option>' +
              '<option value="10">10 (medium ~3.5 min)</option>' +
              '<option value="16">16 (long ~6 min)</option>' +
              '<option value="24">24 (longest ~9 min)</option></select></label>' +
          '</div>'
        : '';
    // Engine selector — Auto prefers a cloud Worker when online + a media-capable
    // worker exists + quota remains (frees the local 4GB GPU); else falls back local.
    const engineHtml =
        '<div style="display:flex;gap:10px;align-items:center;margin-bottom:8px;flex-wrap:wrap;">' +
          '<label style="font-size:11px;color:var(--text-muted);">Engine' +
            '<select id="gen-engine" style="' + _selCss + '">' +
            '<option value="auto" selected>Auto (cloud if online)</option>' +
            '<option value="local">Local (GPU)</option>' +
            '<option value="cloud">Cloud (Worker)</option></select></label>' +
          '<span id="gen-engine-note" style="font-size:9.5px;color:var(--text-muted);"></span>' +
        '</div>';
    const promptNote = kind === 'sound'
        ? '<div id="gen-prompt-note" style="font-size:10px;color:var(--text-muted);margin:6px 0;">Speech: the text to speak. Effect/Melody/Background: prompt is ignored (procedural).</div>'
        : '<div style="font-size:10px;color:var(--text-muted);margin:6px 0;">Auto prefers a cloud Worker when online (saves the local GPU); otherwise runs offline. ~30 s image · ~2 min GIF (local).</div>';
    const ov = document.createElement('div');
    ov.id = 'gen-modal';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(540px,92vw);padding:18px 22px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<h2 style="margin:0 0 12px 0;font-size:14px;color:var(--workers);">' + icon + ' ' + title + '</h2>' +
        presetHtml + soundHtml + videoHtml + engineHtml +
        '<textarea id="gen-prompt" placeholder="' + escAttr(ph) + '" style="width:100%;box-sizing:border-box;min-height:70px;resize:vertical;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:12px;padding:8px;border-radius:3px;font-family:var(--font-mono);"></textarea>' +
        promptNote +
        '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:8px;">' +
            '<button class="action-btn" onclick="document.getElementById(\'gen-modal\').remove()" style="padding:5px 14px;">Cancel</button>' +
            '<button class="action-btn agent-claude" onclick="genStart(\'' + kind + '\')" style="padding:5px 18px;">Generate</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    setTimeout(() => document.getElementById('gen-prompt')?.focus(), 50);
}
function _genSoundTypeChange() {
    const t = document.getElementById('gen-sound-type')?.value;
    const lw = document.getElementById('gen-lang-wrap');
    if (lw) lw.style.display = (t === 'speech') ? '' : 'none';
    const note = document.getElementById('gen-prompt-note');
    if (note) note.textContent = (t === 'speech')
        ? 'Speech: the text to speak (Auto detects EN/ES/HE).'
        : 'Procedural ' + t + ' — generated offline via ffmpeg (prompt optional).';
}
// Find a Worker model that can produce this media kind (image/audio/video).
function genCloudModel(kind) {
    const want = (kind === 'image') ? 'image' : (kind === 'sound') ? 'audio' : (kind === 'video') ? 'video' : null;
    if (!want) return null;
    // Self-heal (#4): skip models the backend flagged dead/degraded.
    const m = (_workersModels || []).find(m => (m.kinds || []).includes(want) && !m.degraded);
    return m || null;
}
// Is the provider for this model within its free-tier quota? null/unknown → allow.
async function genQuotaOk(providerId) {
    try {
        const r = await fetch('workers.php?action=usage_with_quota');
        const d = await r.json();
        const row = (d.rows || []).find(x => x.provider === providerId);
        if (!row) return true;
        if (row.enabled === false) return false;
        const rem = row.remaining_rpd;
        return (rem === null || rem === undefined) ? true : rem > 0;   // null = unmetered
    } catch (e) { return true; }
}
// Resolve which engine to use. Returns {engine:'local'|'cloud', model?, why}.
async function genResolveEngine(kind, choice) {
    const cloud = genCloudModel(kind);
    if (choice === 'local') return { engine: 'local', why: 'forced local' };
    if (choice === 'cloud') {
        if (!cloud) return { engine: 'local', why: 'no cloud ' + kind + ' worker configured → local' };
        if (!navigator.onLine) return { engine: 'local', why: 'offline → local' };
        if (!(await genQuotaOk(cloud.provider))) return { engine: 'local', why: 'cloud quota exhausted → local' };
        return { engine: 'cloud', model: cloud, why: 'forced cloud' };
    }
    // auto — prefer cloud (spares the 4GB GPU) when everything lines up.
    if (cloud && navigator.onLine && await genQuotaOk(cloud.provider))
        return { engine: 'cloud', model: cloud, why: 'auto → cloud (' + cloud.provider + ')' };
    const reason = !cloud ? 'no cloud ' + kind + ' worker' : !navigator.onLine ? 'offline' : 'quota';
    return { engine: 'local', why: 'auto → local (' + reason + ')' };
}

async function genStart(kind) {
    const prompt = (document.getElementById('gen-prompt')?.value || '').trim();
    const soundType = document.getElementById('gen-sound-type')?.value || 'speech';
    if (!prompt && !(kind === 'sound' && soundType !== 'speech')) { appendError(T('msg.enter.a.prompt.first', 'Enter a prompt first.')); return; }
    const preset = document.getElementById('gen-preset')?.value || '';
    const language = document.getElementById('gen-lang')?.value || 'auto';
    const strength = document.getElementById('gen-strength')?.value || '';
    const frames   = document.getElementById('gen-frames')?.value || '';
    const engineChoice = document.getElementById('gen-engine')?.value || 'auto';
    document.getElementById('gen-modal')?.remove();

    // Decide local vs cloud. Cloud only realistically applies to image (and any
    // kind a worker advertises); otherwise this resolves to local.
    const route = await genResolveEngine(kind, engineChoice);
    appendSystem(T('msg.generation.engine.why', 'Generation engine: {why}', {why: route.why}));
    if (route.engine === 'cloud') { await genStartCloud(kind, prompt, route.model); return; }

    let res;
    try {
        const r = await fetch('generate.php?action=start', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ kind, preset, prompt, sound_type: soundType, language, strength, frames }) });
        res = await r.json();
    } catch (e) { appendError(T('msg.generation.failed.message', 'Generation failed: {message}', {message: e.message})); return; }
    if (!res.ok) { appendError(T('msg.generation.failed.errorhint', 'Generation failed: {error}{hint}', {error: (res.error || 'unknown'), hint: (res.hint ? ' — ' + res.hint : '')})); return; }
    _genProgress(res.id, kind);
    _genPoll(res.id, kind, prompt);
}

// Cloud generation via a Worker (frees the local GPU). Renders the returned
// media inline with the same chips. Falls back to a clear error (try Local).
async function genStartCloud(kind, prompt, model) {
    const [provider, ...rest] = (model.value || '').split(':');
    const mdl  = rest.join(':');
    const task = (kind === 'image') ? 'image' : (kind === 'sound') ? 'audio' : 'video';
    const pid  = 'cloud-' + Date.now();
    _genProgress(pid, kind);
    try {
        const r = await fetch('workers.php?action=invoke', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ provider, model: mdl, task, prompt, extra: {} })
        });
        const d = await r.json();
        _genProgressDone(pid);
        if (!d.ok) { appendError(T('msg.cloud.generation.failed.error.switch.engine', 'Cloud generation failed: {error} — switch Engine to Local to use the GPU.', {error: (d.error || 'unknown')})); return; }
        if (typeof costRecordTurn === 'function') costRecordTurn(d.tokens_in || 0, d.tokens_out || 0, d.cost_usd || 0);
        _checkSpendWarnings(d);
        const ext = (kind === 'image') ? 'png' : (kind === 'sound') ? 'wav' : 'mp4';
        // d.output is a data: URL or a remote URL — <img>/<audio>/<video> handle both.
        _genRender(kind, d.output, prompt, ext, null);
    } catch (e) {
        _genProgressDone(pid);
        appendError(T('msg.cloud.generation.failed.message', 'Cloud generation failed: {message}', {message: e.message}));
    }
}
// Live progress element with elapsed timer + Cancel button.
function _genProgress(id, kind) {
    const wrap = document.createElement('div');
    wrap.id = 'gen-prog-' + id;
    wrap.style.cssText = 'margin:10px 0;padding:8px 12px;border-left:2px solid var(--accent-amber);display:flex;align-items:center;gap:10px;';
    wrap.innerHTML =
        '<span class="material-symbols-rounded" style="color:var(--accent-amber);animation:pulse 1s infinite;">hourglass_top</span>' +
        '<span style="font-size:11px;">Generating ' + kind + '… <span id="gen-prog-t-' + id + '">0s</span></span>' +
        '<button class="action-btn" onclick="genCancel(\'' + id + '\')" style="margin-left:auto;padding:3px 12px;font-size:10px;">Cancel</button>';
    consoleBox.appendChild(wrap);
    consoleBox.scrollTop = consoleBox.scrollHeight;
    const t0 = Date.now();
    wrap._timer = setInterval(() => { const e = document.getElementById('gen-prog-t-' + id); if (e) e.textContent = Math.round((Date.now() - t0) / 1000) + 's'; }, 1000);
}
function _genProgressDone(id) { const w = document.getElementById('gen-prog-' + id); if (w) { clearInterval(w._timer); w.remove(); } }
async function genCancel(id) {
    try { await fetch('generate.php?action=cancel&id=' + id); } catch (e) {}
    if (_genTimers[id]) { clearInterval(_genTimers[id]); delete _genTimers[id]; }
    _genProgressDone(id);
    appendSystem(T('msg.generation.cancelled', 'Generation cancelled.'));
}
function _genPoll(id, kind, prompt) {
    let tries = 0;
    _genTimers[id] = setInterval(async () => {
        if (++tries > 240) { clearInterval(_genTimers[id]); delete _genTimers[id]; _genProgressDone(id); appendError(T('msg.generation.timed.out', 'Generation timed out.')); return; }
        try {
            const r = await fetch('generate.php?action=status&id=' + id);
            const d = await r.json();
            if (d.state === 'done')      { clearInterval(_genTimers[id]); delete _genTimers[id]; _genProgressDone(id); _genRender(kind, d.url, prompt, d.ext, id); }
            else if (d.state === 'error')     { clearInterval(_genTimers[id]); delete _genTimers[id]; _genProgressDone(id); appendError(T('msg.generation.error.log', 'Generation error: {log}', {log: ((d.log || '').slice(-200) || 'unknown')})); }
            else if (d.state === 'cancelled') { clearInterval(_genTimers[id]); delete _genTimers[id]; _genProgressDone(id); }
        } catch (e) {}
    }, 2000);
}
function _genRender(kind, url, prompt, ext, id) {
    let media = '';
    if (ext === 'png' || ext === 'gif') media = '<img src="' + url + '" style="max-width:512px;max-height:512px;border-radius:4px;display:block;">';
    else if (ext === 'wav')             media = '<audio src="' + url + '" controls style="width:320px;"></audio>';
    else if (ext === 'mp4')             media = '<video src="' + url + '" controls style="max-width:512px;border-radius:4px;"></video>';
    // Default filename: short slug from the prompt + the real extension.
    const slug = (prompt || kind).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40) || kind;
    const fname = slug + '.' + ext;
    const wrap = document.createElement('div');
    wrap.style.cssText = 'margin:10px 0;padding:8px 12px;border-left:2px solid var(--workers);';
    // Chip buttons beneath the media: Save (→Attachments), Save as…, Download, Delete.
    const chip = 'display:inline-flex;align-items:center;gap:4px;padding:3px 9px;margin:3px 4px 0 0;' +
                 'font-size:10.5px;font-weight:600;border-radius:11px;cursor:pointer;border:1px solid var(--border-dim);' +
                 'background:var(--bg-codeblock,rgba(255,255,255,0.04));color:var(--text-main);';
    wrap.innerHTML =
        '<div style="font-size:10px;color:var(--workers);font-weight:600;margin-bottom:5px;">[GENERATED · ' + kind.toUpperCase() + ']</div>' +
        media +
        '<div style="font-size:10px;color:var(--text-muted);margin-top:5px;">' + escHtml(prompt) + '</div>' +
        '<div class="gen-chips" style="margin-top:6px;">' +
        '<span class="gen-chip" data-act="save"     style="' + chip + 'color:var(--accent-cyan);"><span class="material-symbols-rounded" style="font-size:13px;">bookmark_add</span>Save</span>' +
        '<span class="gen-chip" data-act="saveas"   style="' + chip + 'color:var(--accent-cyan);"><span class="material-symbols-rounded" style="font-size:13px;">drive_file_rename_outline</span>Save as…</span>' +
        '<span class="gen-chip" data-act="download" style="' + chip + 'color:var(--accent-amber);"><span class="material-symbols-rounded" style="font-size:13px;">download</span>Download</span>' +
        '<span class="gen-chip" data-act="delete"   style="' + chip + 'color:var(--accent-orange);"><span class="material-symbols-rounded" style="font-size:13px;">delete</span>Delete</span>' +
        '</div>';
    wrap.querySelector('.gen-chips').addEventListener('click', async e => {
        const c = e.target.closest('.gen-chip'); if (!c) return;
        const act = c.dataset.act;
        if (act === 'download') {
            _genDownload(url, fname);
        } else if (act === 'save') {
            if (wrap._savedName) { appendSystem(T('msg.already.in.attachments.savedname', 'Already in Attachments: {savedname}', {savedname: wrap._savedName})); attachPanelRefresh(); return; }
            wrap._savedName = await _genSaveToAttachments(url, fname, kind);
        } else if (act === 'saveas') {
            const nm = await prompt2('Save generated ' + kind + ' as (filename):', fname);
            if (nm === null) return;
            let name = nm.trim(); if (!name) return;
            if (!/\.[a-z0-9]+$/i.test(name)) name += '.' + ext;   // keep a real extension
            await _genSaveToAttachments(url, name, kind);
        } else if (act === 'delete') {
            if (!await cockpitConfirm('Delete generated ' + kind + '?', 'Delete this generated ' + kind + '? It will be removed from the chat' + (id ? ' and disk.' : '.'), 'Delete', {danger:true, icon:'delete'})) return;
            if (id) { try { await fetch('generate.php?action=delete&id=' + encodeURIComponent(id)); } catch (e) {} }
            wrap.remove();
            appendSystem(T('msg.generated.kind.deleted', 'Generated {kind} deleted.', {kind: kind}));
        }
    });
    consoleBox.appendChild(wrap);
    consoleBox.scrollTop = consoleBox.scrollHeight;
    appendSystem(T('msg.generated.kind.ready', 'Generated {kind} ready.', {kind: kind}));
    // Auto-add to the right-panel Attachments tab so every generation is tracked.
    _genSaveToAttachments(url, fname, kind, true).then(n => { if (n) wrap._savedName = n; });
}

// Trigger a browser download of a generated file under a friendly name.
function _genDownload(url, fname) {
    const a = document.createElement('a');
    a.href = url; a.download = fname;
    document.body.appendChild(a); a.click(); a.remove();
}

// Fetch a generated file and persist it into this chat's Attachments store.
// silent=true suppresses the success toast (used for the auto-add on render).
async function _genSaveToAttachments(url, fname, kind, silent) {
    const proj = currentProject || '_standalone';
    const chat = currentChat    || 'default';
    try {
        const blob = await (await fetch(url)).blob();
        const b64  = await new Promise((res, rej) => {
            const fr = new FileReader();
            fr.onload  = () => res(String(fr.result).split(',')[1] || '');
            fr.onerror = rej;
            fr.readAsDataURL(blob);
        });
        const r = await fetch('attachments.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ action:'save', project:proj, chat:chat,
                filename:fname, data_b64:b64, mime:blob.type || '' })
        });
        const d = await r.json();
        if (!d.ok) { if (!silent) appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error || '')})); return ''; }
        if (!silent) appendSystem(T('msg.saved.to.attachments.filename', 'Saved to Attachments: {filename}', {filename: d.filename}));
        // Refresh the panel if it's the visible right-panel tab.
        if (document.getElementById('right-attachments')?.offsetParent !== null) attachPanelRefresh();
        return d.filename || '';
    } catch (e) {
        if (!silent) appendError(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message}));
        return '';
    }
}

// Small await cprompt() wrapper kept separate so the chip handler's local var doesn't
// shadow the global prompt string parameter.
function prompt2(msg, def) { return cprompt(msg, def); }

// ── FPC/PHP Unit Mapper — structural map for LLM navigational context ──────
async function mapUnits() {
    const proj = currentProject || 'default';
    appendSystem(T('msg.mapping.units.in.project.proj', 'Mapping units in project "{proj}"…', {proj: proj}));
    let d;
    try {
        const r = await fetch('mapper.php?action=map&project=' + encodeURIComponent(proj));
        d = await r.json();
    } catch (e) { appendError(T('msg.map.failed.message', 'Map failed: {message}', {message: e.message})); return; }
    if (!d.ok) { appendError(T('msg.map.failed.error', 'Map failed: {error}', {error: (d.error || 'unknown')})); return; }
    if (!d.files) { appendSystem(T('msg.no.pascal.php.source.files.found.in.this.pro', 'No Pascal/PHP source files found in this project.')); return; }
    appendSystem(T('msg.mapped.files.file.s', 'Mapped {files} file(s).', {files: d.files}));
    openFloatingEditor({
        id: 'unitmap', heading: 'Unit map — ' + proj, filename: d.files + ' files (Pascal/PHP)',
        content: d.markdown || '', language: 'md',
        onSave: async () => { return { ok:false, error:'Read-only map. Use the prompt box to feed it to an agent.' }; },
        onSaveAs: async (content) => {
            // "Save as…" inserts the map into the prompt as LLM context.
            promptInput.value = '[Project structure map]\n' + content + '\n\n' + (promptInput.value || '');
            promptInput.focus();
            appendSystem(T('msg.unit.map.inserted.into.the.prompt', 'Unit map inserted into the prompt.'));
            return { ok:true };
        }
    });
}

// ── Network latency monitor (topbar) ──────────────────────────────────────
let _netLatencyHost = '';
async function netLatencyPoll() {
    const el = document.getElementById('net-latency');
    if (!el) return;
    try {
        const r = await fetch('latency.php' + (_netLatencyHost ? ('?host=' + encodeURIComponent(_netLatencyHost)) : ''));
        const d = await r.json();
        _netLatencyHost = d.host || _netLatencyHost;
        if (d.ok && d.ms != null) {
            const ms = Math.round(d.ms);
            // Colour by band (text always present → protanopia-safe): good/ok/slow.
            const col = ms < 40 ? 'var(--accent-cyan)' : ms < 120 ? 'var(--accent-amber)' : 'var(--accent-orange)';
            el.textContent = '⇄ ' + ms + ' ms';
            el.style.color = col;
            el.title = 'Network latency to ' + d.host + ' — ' + ms + ' ms (click to change host)';
        } else {
            el.textContent = T('msg.offline', '⇄ offline');
            el.style.color = 'var(--text-dim)';
            el.title = 'No reply from ' + (d.host || '?') + ' (click to change host)';
        }
    } catch (e) {
        el.textContent = '⇄ —'; el.style.color = 'var(--text-dim)';
    }
}
async function netLatencySetHost() {
    const h = await cprompt('Latency monitor — host to ping (hostname or IP). It starts on your own router; a public address means a call out of this machine:', _netLatencyHost || '');
    if (h === null) return;
    const host = h.trim();
    if (!/^[A-Za-z0-9._\-]{1,253}$/.test(host)) { appendError(T('msg.invalid.host', 'Invalid host.')); return; }
    _netLatencyHost = host;
    fetch('latency.php?host=' + encodeURIComponent(host) + '&set=1').then(() => netLatencyPoll()).catch(() => {});
    appendSystem(T('msg.latency.host.set.to.host', 'Latency host set to {host}.', {host: host}));
}
document.addEventListener('DOMContentLoaded', () => {
    setTimeout(netLatencyPoll, 2000);
    setInterval(netLatencyPoll, 5000);
});

// Toggle the amber "syncing" dot on the supplier cards during a background sync.
function _setSyncDots(on) {
    ['claude','gemini','ollama'].forEach(a => {
        const dot = document.getElementById('sync-dot-' + a);
        if (dot) dot.classList.toggle('on', !!on);
    });
}
async function _cardUsagePoll() {
    _setSyncDots(true);
    try {
        const d = await _fetchCardUsage('full');
        _updateCardCompact(d);
        ['claude','gemini','ollama'].forEach(a => {
            const card = document.getElementById('sup-card-' + a);
            if (card && card.classList.contains('sup-active')) _updateCardFull(a, d);
        });
    } finally {
        // Brief lingering blink so the dot is perceptible even on a fast sync.
        setTimeout(() => _setSyncDots(false), 350);
    }
}

// Start polling on page load
document.addEventListener('DOMContentLoaded', () => {
    setTimeout(_cardUsagePoll, 1500); // initial load
    _cardUsageTimer = setInterval(_cardUsagePoll, 10000);
});
async function usageParserRefresh() {
    const list  = document.getElementById('rp-list-usage');
    const range = document.getElementById('usage-range')?.value || 'today';
    if (list) list.innerHTML = '<div class="sidebar-empty">Reading log files…</div>';

    try {
        const r = await fetch('usage_parser.php?action=all&range=' + range +
                              '&project=' + encodeURIComponent(currentProject || ''));
        const d = await r.json();
        if (!d.ok) throw new Error(d.error || 'parse failed');
        _renderUsagePanel(d, range, list);
        const upd = document.getElementById('usage-last-update');
        if (upd) upd.textContent = 'Updated ' + fmtTime(new Date());
    } catch(e) {
        if (list) list.innerHTML = '<div class="sidebar-empty">Error: ' + escHtml(e.message) + '</div>';
    }
}

// =============================================================================
