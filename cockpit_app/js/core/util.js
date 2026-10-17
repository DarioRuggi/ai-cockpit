// =============================================================================
// Utilities
// =============================================================================
// Basic markdown renderer — operates on already-escaped HTML
// so we work with &amp; etc. and don't introduce XSS
function renderMarkdown(s) {
    // Collapse model reasoning (<think>…</think> / <thinking>…</thinking>, e.g.
    // DeepSeek-R1, extended thinking) into a collapsed <details> panel so the
    // chat shows the answer, not the raw chain-of-thought. (s is HTML-escaped,
    // so the tags arrive as &lt;think&gt;.)
    s = s.replace(/&lt;think(?:ing)?&gt;([\s\S]*?)&lt;\/think(?:ing)?&gt;/gi, (m, inner) =>
        '<details class="think-block" style="margin:4px 0;border-left:2px solid var(--border-dim);padding-left:8px;">' +
        '<summary style="cursor:pointer;font-size:11px;color:var(--text-muted);user-select:none;"><span class="material-symbols-rounded ico">psychology_alt</span> Reasoning</summary>' +
        '<div style="font-size:0.92em;color:var(--text-muted);white-space:pre-wrap;">' + inner.trim() + '</div></details>');
    // Also fold a dangling, still-streaming "<think>" with no close yet.
    s = s.replace(/&lt;think(?:ing)?&gt;([\s\S]*)$/i, (m, inner) =>
        '<details class="think-block" open style="margin:4px 0;border-left:2px solid var(--border-dim);padding-left:8px;">' +
        '<summary style="cursor:pointer;font-size:11px;color:var(--text-muted);"><span class="material-symbols-rounded ico">psychology_alt</span> Reasoning…</summary>' +
        '<div style="font-size:0.92em;color:var(--text-muted);white-space:pre-wrap;">' + inner.trim() + '</div></details>');
    // Per-tool status chips: render %%CREATE/APPEND/DELETE%% + %%WORKER/TOOL/
    // FETCH/SEARCH%% markers as compact badges instead of raw %%…%% text. (Input
    // is HTML-escaped, so markers arrive literal — % and : aren't escaped.)
    s = s.replace(/%%(CREATE|APPEND):([^%\n]+)%%\n?([\s\S]*?)%%END%%/g, (m, op, path, content) =>
        '<details style="margin:4px 0;border:1px solid var(--border-dim);border-radius:4px;">' +
        '<summary style="cursor:pointer;font-size:11px;padding:3px 7px;background:var(--bg-active);color:var(--ollama,#7dc4a3);"><span class="material-symbols-rounded ico">description</span> ' +
        (op === 'APPEND' ? 'Appended → ' : 'Created → ') + '<b>' + path.trim() + '</b></summary>' +
        '<div style="font-family:var(--font-mono);font-size:11px;white-space:pre-wrap;padding:6px 8px;">' + content.replace(/\n$/, '') + '</div></details>');
    s = s.replace(/%%DELETE:([^%\n]+)%%(\s*%%CONFIRM:DELETE%%)?/g, (m, path) =>
        '<span style="display:inline-block;font-size:11px;padding:2px 7px;border-radius:3px;background:var(--bg-active);color:var(--warn,#e6b43c);"><span class="material-symbols-rounded ico">delete</span> Deleted <b>' + path.trim() + '</b></span>');
    s = s.replace(/%%(WORKER|TOOL|FETCH|SEARCH|READ|LIB|SNIP|SRC):([^%\n]+)%%/g, (m, kind, arg) =>
        '<span style="display:inline-block;font-size:11px;padding:2px 7px;border-radius:3px;background:var(--bg-active);color:var(--workers,#c9a3e0);font-family:var(--font-mono);"><span class="material-symbols-rounded ico">build</span> ' + kind + ': ' + arg.trim() + '</span>');

    // F2/F3 + readability: extract fenced ``` blocks FIRST, replace with
    // placeholders so the inline rules below don't mangle code, then restore
    // them as styled blocks with Copy + Save-to-Snippets buttons.
    const codeBlocks = [];
    s = s.replace(/```([a-zA-Z0-9_+\-]*)\n?([\s\S]*?)```/g, (m, lang, code) => {
        const idx = codeBlocks.length;
        codeBlocks.push({ lang: (lang||'').toLowerCase(), code: code.replace(/\n$/,'') });
        return '\u0000CODEBLOCK' + idx + '\u0000';
    });
    // Bold: **text** or __text__
    s = s.replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>');
    s = s.replace(/__(.*?)__/g,     '<strong>$1</strong>');
    // Italic: *text* or _text_
    s = s.replace(/\*(.*?)\*/g,     '<em>$1</em>');
    // Inline code: `code`
    s = s.replace(/`([^`]+)`/g,
        '<code style="background:var(--bg-active);padding:1px 5px;border-radius:2px;font-family:var(--font-mono);font-size:0.92em">$1</code>');
    // Headers: ## Header
    s = s.replace(/^### (.+)$/gm, '<span style="color:var(--text-primary);font-weight:700;font-size:1.0em">$1</span>');
    s = s.replace(/^## (.+)$/gm,  '<span style="color:var(--text-primary);font-weight:700;font-size:1.05em">$1</span>');
    s = s.replace(/^# (.+)$/gm,   '<span style="color:var(--text-primary);font-weight:700;font-size:1.1em">$1</span>');
    // Horizontal rule
    s = s.replace(/^---+$/gm, '<hr style="border:none;border-top:1px solid var(--border-mid);margin:6px 0">');
    // Bullet points: * or - at line start
    s = s.replace(/^\s*[\*\-] (.+)$/gm,
        '<span style="display:block;padding-left:12px">· $1</span>');
    // Numbered lists
    s = s.replace(/^\s*(\d+)\. (.+)$/gm,
        '<span style="display:block;padding-left:12px">$1. $2</span>');
    // Restore fenced code blocks as styled blocks (content already escaped by
    // the caller; codeBlocks holds escaped text since s was escaped upstream).
    s = s.replace(/\u0000CODEBLOCK(\d+)\u0000/g, (m, i) => {
        const blk = codeBlocks[parseInt(i,10)];
        if (!blk) return '';
        const langLabel = blk.lang ? blk.lang : 'text';
        const lines = blk.code.split('\n').length;
        const collapsed = lines > 15;
        const meta = _codeMeta(blk.code, blk.lang);   // { name, type }
        const nameType = (meta.name ? escHtml(meta.name) + ' · ' : '') + escHtml(meta.type);
        return '<div class="cp-codeblock' + (collapsed ? ' cp-cb-collapsed' : '') + '" data-lang="' + escHtml(blk.lang) +
            '" style="position:relative;margin:6px 0;border:1px solid var(--border-dim);border-radius:4px;background:var(--bg-darker,var(--bg-codeblock));">' +
            '<div class="cp-cb-header" style="display:flex;align-items:center;gap:6px;padding:3px 8px;border-bottom:1px solid var(--border-dim);font-size:9.5px;color:var(--text-muted);cursor:pointer;" onclick="_cpCbToggle(this)">' +
            '<span class="cp-cb-fold material-symbols-rounded" style="font-size:12px;transition:transform 0.15s;">' + (collapsed ? 'expand_more' : 'expand_less') + '</span>' +
            '<span style="font-family:var(--font-mono);font-weight:700;letter-spacing:0.5px;">CODE</span>' +
            '<span class="cp-cb-name" title="detected name · type">' + nameType + '</span>' +
            '<span class="cp-cb-lines" style="opacity:0.5;">· ' + lines + ' lines</span>' +
            '<span class="cp-cb-lang" style="font-family:var(--font-mono);opacity:0.7;">· ' + escHtml(langLabel) + '</span>' +
            '<span style="flex:1;"></span>' +
            '<span class="cp-cb-copy material-symbols-rounded" style="font-size:13px;cursor:pointer;opacity:0.6;" title="Copy code" onclick="event.stopPropagation()">content_copy</span>' +
            '<span class="cp-cb-save material-symbols-rounded" style="font-size:13px;cursor:pointer;opacity:0.6;" title="Save to Snippets" onclick="event.stopPropagation()">bookmark_add</span>' +
            '</div>' +
            '<pre style="margin:0;padding:8px 10px;overflow-x:auto;font-family:var(--font-mono);font-size:11px;white-space:pre;">' +
            blk.code + '</pre></div>';
    });
    return s;
}

function _cpCbToggle(header) {
    const block = header.parentElement;
    block.classList.toggle('cp-cb-collapsed');
    const icon = header.querySelector('.cp-cb-fold');
    if (icon) icon.textContent = block.classList.contains('cp-cb-collapsed') ? 'expand_more' : 'expand_less';
}

// Best-effort: pull a name + type out of a code block (function/class/etc.) so
// the code header can read "CODE · doBubbleSort · function · 24 lines · pascal".
function _codeMeta(code, lang) {
    const pats = [
        [/^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s+([A-Za-z_$][\w$]*)/m, 'function'],
        [/^\s*(?:export\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)/m,                 'class'],
        [/^\s*def\s+([A-Za-z_]\w*)/m,                                                     'function'],   // python
        [/^\s*(?:function|procedure)\s+([A-Za-z_]\w*)/im,                                 'routine'],    // pascal
        [/^\s*program\s+([A-Za-z_]\w*)/im,                                                'program'],    // pascal
        [/^\s*unit\s+([A-Za-z_]\w*)/im,                                                   'unit'],       // pascal
        [/^\s*(?:public|private|protected|internal)?\s*(?:static\s+)?(?:interface|struct|enum)\s+([A-Za-z_]\w*)/m, 'type'],
        [/^\s*type\s+([A-Za-z_]\w*)/m,                                                    'type'],
        [/^\s*(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=/m,                               'const'],
        [/^\s*#!\s*\/.*\b(bash|sh|zsh|python\d?)\b/m,                                     'script'],
    ];
    for (const [re, type] of pats) {
        const m = (code || '').match(re);
        if (m) return { name: (m[1] || ''), type: type };
    }
    // SQL / markup / data → describe by kind rather than a name
    const l = (lang || '').toLowerCase();
    if (/^\s*(select|insert|update|create|alter|delete)\b/i.test(code || '')) return { name: '', type: 'query' };
    if (['json','yaml','yml','toml','ini','xml','html','css','md','markdown','csv'].includes(l)) return { name: '', type: l.replace('yml','yaml') };
    return { name: '', type: 'snippet' };
}

// System message folding — collapses consecutive system messages into a group
function _foldSystemMessages() {
    if (!consoleBox) return;
    const msgs = Array.from(consoleBox.children);
    let run = [];
    for (let i = 0; i < msgs.length; i++) {
        const m = msgs[i];
        if (m.classList.contains('msg-system') && !m.classList.contains('msg-system-pinned')) {
            run.push(m);
        } else {
            if (run.length >= 4) _collapseSystemRun(run);
            run = [];
        }
    }
    if (run.length >= 4) _collapseSystemRun(run);
}

function _collapseSystemRun(msgs) {
    if (msgs[0].parentElement.querySelector('.msg-system-group-toggle[data-for="' + msgs[0].id + '"]')) return;
    const wrapper = document.createElement('div');
    wrapper.className = 'msg-system-group';
    const gid = 'sysg-' + Date.now() + '-' + Math.random().toString(36).slice(2,5);
    msgs[0].id = msgs[0].id || gid;
    const toggle = document.createElement('div');
    toggle.className = 'msg-system-group-toggle';
    toggle.setAttribute('data-for', msgs[0].id);
    toggle.innerHTML = '<span class="material-symbols-rounded" style="font-size:12px;">expand_more</span>' +
        msgs.length + ' system messages (click to expand)';
    toggle.onclick = function() {
        const hidden = wrapper.style.display === 'none';
        wrapper.style.display = hidden ? '' : 'none';
        toggle.querySelector('span').textContent = hidden ? 'expand_less' : 'expand_more';
        toggle.childNodes[1].textContent = hidden ? ' ' + msgs.length + ' system messages (click to collapse)' :
            ' ' + msgs.length + ' system messages (click to expand)';
    };
    msgs[0].parentElement.insertBefore(toggle, msgs[0]);
    msgs[0].parentElement.insertBefore(wrapper, msgs[0]);
    msgs.forEach(m => wrapper.appendChild(m));
    wrapper.style.display = 'none';
}

// F2/F3: delegated handler for the Copy / Save buttons on rendered code blocks.
// (Delegated so it works for streamed messages re-rendered after load.)
document.addEventListener('click', function(e) {
    const copyBtn = e.target.closest ? e.target.closest('.cp-cb-copy') : null;
    const saveBtn = e.target.closest ? e.target.closest('.cp-cb-save') : null;
    if (!copyBtn && !saveBtn) return;
    const block = (copyBtn || saveBtn).closest('.cp-codeblock');
    if (!block) return;
    const pre = block.querySelector('pre');
    const code = pre ? (pre.innerText || pre.textContent || '') : '';
    if (copyBtn) {
        navigator.clipboard.writeText(code).then(() => {
            copyBtn.textContent = T('msg.check', 'check');
            setTimeout(() => copyBtn.textContent = 'content_copy', 1200);
        });
    } else if (saveBtn) {
        const lang = block.dataset.lang || '';
        const title = _deriveTitleFromText(code, 'Snippet');
        _showSaveLibraryDialog('snippet', code, title, lang);
    }
});

function escHtml(s) {
    return String(s)
        .replace(/&/g,'&amp;').replace(/</g,'&lt;')
        .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function formatTime(d) {
    return d.toTimeString().slice(0,8);
}
// Chat timestamps are UTC. Old files (and agent_loop before 2026-09-16) wrote
// them without a zone, which Date() reads as LOCAL — turns showed 3 hours off
// next to the system lines. A stamp with no zone is therefore taken as UTC.
function parseTs(v) {
    if (v instanceof Date) return v;
    if (typeof v === 'number') return new Date(v < 1e12 ? v * 1000 : v);
    const s = String(v || '').trim();
    if (!s) return new Date();
    const naive = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/.test(s);
    const d = new Date(naive ? s.replace(' ', 'T') + 'Z' : s);
    return isNaN(d) ? new Date() : d;
}

// A stored stamp shown to the person: parsed with parseTs (UTC, zone-aware) and
// written in the viewer's zone as "YYYY-MM-DD HH:MM". Slicing the raw ISO string
// showed server time (UTC) three hours off the clock card on the rig.
function fmtTsLocal(v) {
    if (!v) return '';
    const d = parseTs(v); const p = n => String(n).padStart(2, '0');
    return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

// Elapsed time → "3s" under a minute, "M:SS" under an hour, "H:MM:SS" beyond.
let _thinkTimer = null, _thinkStart = 0;
function fmtElapsed(ms) {
    const s = Math.floor(ms / 1000);
    if (s < 60) return s + 's';
    const m = Math.floor(s / 60), ss = s % 60;
    if (m < 60) return m + ':' + String(ss).padStart(2, '0');
    const h = Math.floor(m / 60), mm = m % 60;
    return h + ':' + String(mm).padStart(2, '0') + ':' + String(ss).padStart(2, '0');
}

function setLoading(on) {
    // While running, the Execute slot becomes one row: Cancel + thinking indicator.
    const runRow = document.getElementById('run-row');
    if (runRow) runRow.style.display = on ? 'flex' : 'none';
    btnExecute.style.display = on ? 'none' : '';
    btnExecute.disabled      = on;
    btnCancel.className       = 'action-btn' + (on ? ' visible' : '');
    // Live "Thinking" elapsed timer.
    const tEl = document.getElementById('think-timer');
    clearInterval(_thinkTimer); _thinkTimer = null;
    if (on) {
        _thinkStart = Date.now();
        if (tEl) tEl.textContent = '0s';
        _thinkTimer = setInterval(() => {
            const el = document.getElementById('think-timer');
            if (el) el.textContent = fmtElapsed(Date.now() - _thinkStart);
        }, 1000);
    } else if (tEl) {
        tEl.textContent = '';
    }
}

function clearConsole() {
    consoleBox.innerHTML = '';
    lastMsgTime = null;
    appendSystem(T('msg.console.cleared', 'Console cleared.'));
}

async function saveTranscript() {
    const text = consoleBox.innerText;
    if (!text.trim()) { appendSystem(T('msg.nothing.to.save.2c1b', 'Nothing to save.')); return; }
    try {
        const res = await fetch('saver.php', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ text })
        });
        const d = await res.json();
        appendSystem(d.message);
    } catch (e) {
        appendError(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message}));
    }
}


// ckOnce(key, ms): false when the same action ran less than ms ago. A double click on "New chat" read the chat count twice before either
// chat existed and created two chats with the same name (slice 9, 2026-10-18); the creating actions use this to ignore the second click.
function ckOnce(key, ms) { const now = Date.now(); window.__ckOnce = window.__ckOnce || {}; if (now - (window.__ckOnce[key] || 0) < (ms || 800)) return false; window.__ckOnce[key] = now; return true; }

// ── One rule for closing modals: Esc and a click on the backdrop (2026-10-15) ───
// Most modals had no Escape handling and the backdrop click was inconsistent (some closed, some ignored it, and Rules
// closed with typed text lost). Now: Esc or a click on the dimmed backdrop closes the topmost full-screen modal through its
// own Close / Cancel / Got-it button (else its backdrop handler); if you TYPED or changed something in it you are asked
// first. Left alone on purpose: the sign-in gate and the one-time recovery-token reveal.
(function () {
    let _top = null; const _dirty = new WeakSet();
    function overlayOf(node) {
        let best = null;
        for (let n = node; n && n !== document.body; n = n.parentElement) {
            if (getComputedStyle(n).position === 'fixed') best = n;
        }
        return best;
    }
    function topOverlay() {
        let best = null, bz = -1;
        // overlays are fixed-position elements: those that are direct children of <body>, plus any with an inline position:fixed (some live inside a wrapper)
        const cands = new Set([...document.body.children, ...document.querySelectorAll('[style*="position:fixed"], [style*="position: fixed"]')]);
        for (const el of cands) {
            if (el.nodeType !== 1 || el.tagName === 'SCRIPT') continue;
            const cs = getComputedStyle(el);
            if (cs.position !== 'fixed' || cs.display === 'none' || cs.visibility === 'hidden') continue;
            const r = el.getBoundingClientRect();
            if (r.width < innerWidth * 0.9 || r.height < innerHeight * 0.9) continue;      // a full-screen backdrop only
            if (cs.backgroundColor === 'rgba(0, 0, 0, 0)' || cs.backgroundColor === 'transparent') continue;   // has a dimming backdrop
            const z = parseInt(cs.zIndex, 10) || 0;
            if (z >= bz) { best = el; bz = z; }
        }
        return best;
    }
    function protectedOverlay(ov) {
        const txt = ov.textContent || '';
        return /only time it will be shown/i.test(txt) || ov.dataset.noEsc !== undefined
            || (ov.id === 'saas-acct-ov' && /A free account is required once/i.test(txt));
    }
    function closeIt(ov) {
        const btns = [...ov.querySelectorAll('button,[role="button"],.close,[data-close],[data-role="cancel"]')];
        const label = b => ((b.getAttribute('aria-label') || '') + ' ' + (b.title || '') + ' ' + (b.textContent || '')).trim().toLowerCase();
        const pick = btns.find(b => b.matches('[data-role="cancel"],[data-close]'))
            || btns.find(b => /^(close|cancel|got it|done|dismiss|back|×|✕|x)$/i.test((b.textContent || '').trim()))
            || btns.find(b => /\bclose\b/.test(label(b)));
        if (pick && !pick.disabled) pick.click(); else ov.click();
        // a modal with no obvious button that ignores its own backdrop: take it out
        setTimeout(() => { if (document.body.contains(ov) && getComputedStyle(ov).display !== 'none' && ov.id !== 'saas-acct-ov') { try { ov.remove(); } catch (e) {} } }, 80);
    }
    function requestClose(ov) {
        if (_dirty.has(ov) && typeof cockpitConfirm === 'function') {
            cockpitConfirm('Close without saving?', 'You changed something here. Closing now discards it.', 'Discard', { danger: true, icon: 'warning' })
                .then(ok => { if (ok && document.body.contains(ov)) closeIt(ov); });
        } else closeIt(ov);
    }
    // typed or changed by a person (not set by the page's own code) marks the modal as having unsaved input
    ['input', 'change'].forEach(t => window.addEventListener(t, e => {
        if (!e.isTrusted || (e.target && e.target.type === 'file')) return;
        const ov = overlayOf(e.target); if (ov) _dirty.add(ov);
    }, true));
    window.addEventListener('keydown', e => { _top = e.key === 'Escape' ? topOverlay() : null; }, true);
    document.addEventListener('keydown', e => {
        if (e.key !== 'Escape' || !_top || e.defaultPrevented || !document.body.contains(_top)) return;
        const ov = _top; _top = null;
        if (protectedOverlay(ov)) return;
        // a floating window (a file picker, say) opened FROM the modal sits above it: Esc closes that one first
        const w = document.querySelector('.ckwin.active');
        if (w && (parseInt(w.style.zIndex, 10) || 0) > (parseInt(getComputedStyle(ov).zIndex, 10) || 0)) {
            const cb = w.querySelector('.ckwin-btn.close'); if (cb) { e.preventDefault(); cb.click(); return; }
        }
        e.preventDefault(); requestClose(ov);
    });
    // a click on the dimmed backdrop itself (not on the dialog)
    window.addEventListener('click', e => {
        if (!e.isTrusted || !e.target || e.target.nodeType !== 1) return;
        const ov = e.target; if (ov !== topOverlay() || protectedOverlay(ov)) return;
        e.stopPropagation(); e.preventDefault();      // this one rule replaces each modal's own backdrop handler
        requestClose(ov);
    }, true);
})();
