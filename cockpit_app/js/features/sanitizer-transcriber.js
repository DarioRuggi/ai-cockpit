// =============================================================================
// SANITIZER UI
// =============================================================================

let _sanPanelOpen  = false;
let _sanActiveTab  = 'run';
let _sanPollTimer  = null;
let _sanRunJobId   = null;

function accumulatorOpenPanel() {
    _sanPanelOpen = true;
    document.getElementById('accumulator-panel-overlay').style.display = 'block';
    document.getElementById('accumulator-panel').style.display = 'block';
    accumulatorShowTab(_sanActiveTab);
}

function accumulatorClosePanel() {
    _sanPanelOpen = false;
    document.getElementById('accumulator-panel-overlay').style.display = 'none';
    document.getElementById('accumulator-panel').style.display = 'none';
    _sanStopPoll();
}

// C5: pipeline health check — verifies extractors + Ollama reachability
async function accumulatorPingPipeline() {
    const banner = document.getElementById('san-health-banner');
    if (!banner) return;
    banner.style.display = 'block';
    banner.textContent = T('msg.checking.pipeline', 'Checking pipeline…');
    try {
        const r = await fetch('sanitizer.php?action=ping');
        const d = await r.json();
        if (!d.ok) { banner.textContent = T('msg.health.check.failed', 'Health check failed.'); return; }
        const bins = d.binaries || {};
        const missing = Object.keys(bins).filter(b => !bins[b]);
        const parts = [];
        parts.push('Extractors: ' + Object.keys(bins).map(b =>
            (bins[b] ? '[[icon:check]]' : '[[icon:close]]') + b).join('  '));
        parts.push('Ollama: ' + (d.ollama ? ('[[icon:check]] reachable (' + (d.models||[]).length + ' models)') : '[[icon:close]] unreachable'));
        const dirIssues = Object.entries(d.dirs||{})
            .filter(([k,v]) => !v.exists || !v.writable)
            .map(([k]) => k);
        if (dirIssues.length) parts.push('Dir issues: ' + dirIssues.join(', '));
        const allGood = missing.length === 0 && d.ollama && dirIssues.length === 0;
        banner.style.color = allGood ? 'var(--accent-cyan)' : 'var(--accent-orange)';
        banner.innerHTML = (allGood ? '<span class="material-symbols-rounded ico">check</span> Pipeline ready. ' : '<span class="material-symbols-rounded ico">warning</span> Pipeline partial. ') +
            parts.map(escHtml).map(iconTokens).join(' · ');
    } catch(e) {
        banner.style.color = 'var(--accent-orange)';
        banner.textContent = 'Health check error: ' + e.message;
    }
}

function accumulatorShowTab(tab) {
    _sanActiveTab = tab;
    ['run','jobs','results'].forEach(t => {
        document.getElementById('san-pane-' + t).style.display = t === tab ? 'block' : 'none';
        const btn = document.getElementById('san-tab-' + t);
        if (btn) {
            btn.classList.toggle('acc-tab-active', t === tab);
            btn.style.background = t === tab ? '' : 'var(--bg-darker)';
            btn.style.color      = t === tab ? '' : 'var(--text-base)';
            btn.style.fontWeight = t === tab ? '' : 'normal';
        }
    });
    if (tab === 'jobs')    accumulatorLoadJobs();
    if (tab === 'results') accumulatorLoadResults();
}

// ---------------------------------------------------------------------------
// Run Now — schedules immediately via scheduler.php then polls for progress
// ---------------------------------------------------------------------------
async function accumulatorRunNow() {
    const path    = document.getElementById('san-input-path').value.trim();
    const slug    = document.getElementById('san-input-slug').value.trim();
    const lang    = document.getElementById('san-input-lang').value.trim();
    const provVal = document.getElementById('san-input-provider').value;

    // Empty state, not an error: say what the field wants and how to fill it.
    if (!path) {
        _sanMsg('run', 'Pick a document first — a PDF, DOCX, ODT, EPUB, HTML or TXT on this machine. Use Browse, or paste a full path.');
        document.getElementById('san-input-path').focus();
        return;
    }

    let provider = '', model = '';
    if (provVal) { [provider, model] = provVal.split('|'); }

    _sanMsg('run', 'Scheduling…');

    try {
        // Schedule for right now via scheduler.php
        const params = { input_file: path, book_slug: slug || 'auto',
                         language: lang, provider, model };
        const sr = await fetch('scheduler.php?action=schedule', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                command: 'sanitize',
                params,
                scheduled_at: new Date().toISOString(),
            }),
        });
        const sd = await sr.json();
        if (!sd.ok) { _sanMsg('run', 'Error: ' + (sd.error || 'failed')); return; }

        _sanRunJobId = sd.job_id;
        _sanMsg('run', 'Running… job ' + sd.job_id);
        document.getElementById('san-progress-box').style.display = 'block';
        _sanProgressUpdate(0, 0, 0, 0, 0, 'waiting for cron…');

        // Show running dot on topbar button
        const dot = document.getElementById('accumulator-running-dot');
        if (dot) dot.style.display = 'inline-block';

        // Poll job state every 4 seconds
        _sanStopPoll();
        _sanPollTimer = setInterval(() => _sanPollJob(sd.job_id), 4000);

    } catch(e) {
        _sanMsg('run', 'Network error: ' + e.message);
    }
}

// Poll a specific accumulator job state file via list_jobs
async function _sanPollJob(jobId) {
    try {
        const r = await fetch('sanitizer.php?action=list_jobs');
        const d = await r.json();
        if (!d.ok) return;

        const job = (d.jobs || []).find(j => j.job_id === jobId);
        if (!job) return;

        const prog = job.progress || {};
        _sanProgressUpdate(
            prog.total_chunks || 0,
            prog.processed_chunks || 0,
            prog.snippets_extracted || 0,
            prog.knowledge_extracted || 0,
            prog.skipped_chunks || 0,
            job.provider_used || 'waiting…'
        );

        // Check terminal states
        if (job.status === 'done') {
            _sanStopPoll();
            cockpitNotify('Accumulator Done', 'Snippets: ' + (prog.snippets_extracted||0) + ', Knowledge: ' + (prog.knowledge_extracted||0));
            const dot = document.getElementById('accumulator-running-dot');
            if (dot) dot.style.display = 'none';
            const errs = (prog.errors || []).length;
            _sanMsg('run',
                'Done! Snippets: ' + (prog.snippets_extracted || 0) +
                ', Knowledge: '    + (prog.knowledge_extracted || 0) +
                ', Skipped: '      + (prog.skipped_chunks || 0) +
                (errs ? ', Errors: ' + errs : '') +
                (job.note ? '\n<span class="material-symbols-rounded ico">warning</span> ' + job.note : '')
            );
            // Refresh result count badge
            setTimeout(() => _sanRefreshBadge(), 1000);
        } else if (job.status === 'failed') {
            _sanStopPoll();
            cockpitNotify('Accumulator Failed', job.error || 'unknown error');
            const dot = document.getElementById('accumulator-running-dot');
            if (dot) dot.style.display = 'none';
            _sanMsg('run', 'Failed: ' + (job.error || 'unknown error'));
        }
        // 'running' / 'pending' → keep polling
    } catch(e) { /* silent */ }
}

async function _sanRefreshBadge() {
    try {
        const r = await fetch('sanitizer.php?action=list_results&filter=all');
        const d = await r.json();
        const badge = document.getElementById('accumulator-count-badge');
        if (d.ok && badge) {
            const count = d.count || 0;
            badge.textContent   = count > 99 ? '99+' : count;
            badge.style.display = count > 0 ? 'block' : 'none';
        }
    } catch(e) { /* silent */ }
}

// ---------------------------------------------------------------------------
// Schedule (via scheduler.php)
// ---------------------------------------------------------------------------
async function accumulatorSchedulePrompt() {
    const path = document.getElementById('san-input-path').value.trim();
    if (!path) { _sanMsg('run', 'Please enter a PDF path first.'); return; }

    const when = await cprompt('Schedule for when?\n(e.g. "tonight 02:00", "2026-05-17 03:00", or leave blank for now)');
    if (when === null) return;   // cancelled

    const slug  = document.getElementById('san-input-slug').value.trim();
    const lang  = document.getElementById('san-input-lang').value.trim();
    const provVal = document.getElementById('san-input-provider').value;
    let provider = '', model = '';
    if (provVal) { [provider, model] = provVal.split('|'); }

    const params = { input_file: path, book_slug: slug || 'auto',
                     language: lang, provider, model };

    try {
        const r = await fetch('scheduler.php?action=schedule', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                command: 'sanitize',
                params,
                scheduled_at: when || new Date().toISOString(),
            }),
        });
        const d = await r.json();
        if (d.ok) {
            _sanMsg('run', 'Scheduled: ' + d.job_id +
                    ' — ' + (when ? 'for ' + when : 'immediately'));
            accumulatorShowTab('jobs');
        } else {
            _sanMsg('run', 'Schedule error: ' + (d.error || 'unknown'));
        }
    } catch(e) {
        _sanMsg('run', 'Network error: ' + e.message);
    }
}

// ---------------------------------------------------------------------------
// Jobs tab
// ---------------------------------------------------------------------------
async function accumulatorLoadJobs() {
    document.getElementById('san-jobs-msg').textContent = T('msg.loading', 'Loading…');
    try {
        const r = await fetch('sanitizer.php?action=list_jobs');
        const d = await r.json();
        if (!d.ok) { document.getElementById('san-jobs-msg').textContent = 'Error: ' + (d.error||'failed'); return; }
        _sanRenderJobs(d.jobs || []);
        document.getElementById('san-jobs-msg').textContent = '';
    } catch(e) {
        document.getElementById('san-jobs-msg').textContent = 'Error: ' + e.message;
    }
}

function _sanRenderJobs(jobs) {
    const el = document.getElementById('san-jobs-list');
    if (!jobs.length) { el.innerHTML = '<div style="color:var(--text-dim);font-size:10px;">No accumulator jobs yet.</div>'; return; }

    // Sort: running first, then pending, then done/failed by date desc
    jobs.sort((a,b) => {
        const order = {running:0, pending:1, done:2, failed:3, missed:4, cancelled:5};
        const ao = order[a.status]??9, bo = order[b.status]??9;
        if (ao !== bo) return ao - bo;
        return (b.updated_at||'').localeCompare(a.updated_at||'');
    });

    el.innerHTML = jobs.map(j => {
        const status   = j.status || '';
        const slug     = j.book_slug || j.params?.book_slug || '—';
        const prog     = j.progress || {};
        const total    = prog.total_chunks || 0;
        const done_c   = prog.processed_chunks || 0;
        const snips    = prog.snippets_extracted || 0;
        const know     = prog.knowledge_extracted || 0;
        const pct      = total > 0 ? Math.round(done_c / total * 100) : (status === 'done' ? 100 : 0);
        const provider = j.provider_used || '—';
        const updated  = j.updated_at ? _sanFmtTime(j.updated_at) : '—';

        const badgeColor = status === 'done' ? 'var(--accent-cyan)'
                         : status === 'running' ? 'var(--gemini)'
                         : status === 'failed'  ? 'var(--claude)'
                         : 'var(--text-dim)';

        const barHTML = (status === 'running' || status === 'done') ? `
            <div style="background:var(--bg-base);border-radius:2px;height:4px;margin:4px 0;">
                <div style="height:4px;border-radius:2px;background:var(--accent-cyan);width:${pct}%;"></div>
            </div>` : '';

        return `<div style="border:1px solid var(--border-dim);border-radius:3px;
                             padding:6px 8px;margin-bottom:5px;background:var(--bg-darker);">
            <div style="display:flex;align-items:center;gap:6px;margin-bottom:3px;">
                <span style="font-size:10.5px;color:var(--text-primary);flex:1;">${escapeHtml(slug)}</span>
                <span style="font-size:9.5px;color:${badgeColor};">${status}</span>
            </div>
            ${barHTML}
            <div style="font-size:9.5px;color:var(--text-dim);">
                ${done_c}/${total} chunks &nbsp;·&nbsp;
                <span style="color:var(--accent-cyan);">${snips} snippets</span> &nbsp;·&nbsp;
                <span style="color:var(--gemini);">${know} knowledge</span> &nbsp;·&nbsp;
                ${updated}
            </div>
            <div style="font-size:9px;color:var(--text-dim);margin-top:2px;">${escapeHtml(provider)}</div>
        </div>`;
    }).join('');
}

// ---------------------------------------------------------------------------
// Results tab
// ---------------------------------------------------------------------------
async function accumulatorLoadResults() {
    const filter = document.getElementById('san-results-filter').value;
    const el     = document.getElementById('san-results-list');
    const countEl= document.getElementById('san-results-count');
    el.innerHTML = '<div style="color:var(--text-dim);font-size:10px;">Loading…</div>';

    try {
        const r = await fetch('sanitizer.php?action=list_results&filter=' + encodeURIComponent(filter));
        const d = await r.json();
        if (!d.ok) { el.innerHTML = '<div style="color:var(--claude);font-size:10px;">Error: ' + escapeHtml(d.error||'failed') + '</div>'; return; }
        const items = d.items || [];
        countEl.textContent = items.length + ' item' + (items.length !== 1 ? 's' : '');
        _sanRenderResults(items, el);
    } catch(e) {
        el.innerHTML = '<div style="color:var(--claude);font-size:10px;">Error: ' + escapeHtml(e.message) + '</div>';
    }
}

// Keep items in module-level var so sanitizerUseItem can access by index
let _sanResultItems = [];

function _sanRenderResults(items, el) {
    _sanResultItems = items;
    if (!items.length) {
        el.innerHTML = '<div style="color:var(--text-dim);font-size:10px;">No results yet — run the Accumulator on a PDF first.</div>';
        return;
    }
    el.innerHTML = items.map((item, idx) => {
        const isSnip = item.kind === 'snippet';
        const accent = isSnip ? 'var(--accent-cyan)' : 'var(--gemini)';
        const icon   = isSnip ? 'code' : 'lightbulb';
        const lang   = item.language ? ' · ' + escapeHtml(item.language) : '';
        const book   = item.from_book ? escapeHtml(item.from_book) : '—';

        return `<div style="border:1px solid var(--border-dim);border-radius:3px;
                             padding:6px 8px;margin-bottom:5px;background:var(--bg-darker);">
            <div style="display:flex;align-items:center;gap:6px;margin-bottom:3px;">
                <span class="material-symbols-rounded"
                      style="font-size:13px;color:${accent};cursor:pointer;"
                      onclick="accumulatorToggleItem(this.parentElement.parentElement)">${icon}</span>
                <span style="font-size:10.5px;color:var(--text-primary);flex:1;cursor:pointer;"
                      onclick="accumulatorToggleItem(this.parentElement.parentElement)">
                    ${escapeHtml(item.name || '—')}
                </span>
                <span style="font-size:9px;color:${accent};">
                    ${isSnip ? 'snippet' : 'knowledge'}${lang}
                </span>
                <button onclick="sanitizerUseItem(${idx})"
                        title="Insert into prompt"
                        style="background:none;border:1px solid var(--border-dim);
                               border-radius:3px;color:var(--accent-cyan);cursor:pointer;
                               font-size:9px;padding:1px 5px;flex-shrink:0;
                               display:flex;align-items:center;gap:2px;">
                    <span class="material-symbols-rounded" style="font-size:11px;">south</span>
                    Use
                </button>
            </div>
            <div style="font-size:9.5px;color:var(--text-dim);margin-bottom:3px;">
                ${escapeHtml(item.purpose || '')}
            </div>
            <div class="san-item-preview"
                 style="font-size:9px;color:var(--text-dim);font-family:var(--font-mono);
                        white-space:pre-wrap;display:none;margin-top:4px;
                        background:var(--bg-base);padding:4px;border-radius:2px;
                        max-height:200px;overflow-y:auto;">
${isSnip ? escapeHtml(item.source_code || '') : escapeHtml(item.content || '')}</div>
            <div style="font-size:9px;color:var(--text-dim);margin-top:3px;">
                From: ${book}
            </div>
        </div>`;
    }).join('');
}

// Inject snippet/knowledge content into the cockpit prompt input
function sanitizerUseItem(idx) {
    const item = _sanResultItems[idx];
    if (!item) return;

    // Find the prompt textarea
    const prompt = document.getElementById('prompt-in');
    if (!prompt) { _sanMsg('results', 'Could not find prompt input'); return; }

    const isSnip  = item.kind === 'snippet';
    const content = isSnip ? item.source_code : item.content;
    const label   = isSnip
        ? '```' + (item.language || '') + '\n' + content + '\n```'
        : content;
    const header  = '**' + item.name + '** (' + item.kind + ' from ' + item.from_book + '):\n\n';

    // Append to existing prompt or set if empty
    const current = prompt.value.trim();
    prompt.value  = current ? current + '\n\n' + header + label : header + label;

    // Trigger input event so cockpit's char counter etc. update
    prompt.dispatchEvent(new Event('input', {bubbles: true}));
    prompt.focus();

    // Close the panel so user can see the prompt
    accumulatorClosePanel();
}

// Toggle expanded code/content view on click
function accumulatorToggleItem(el) {
    const preview = el.querySelector('.san-item-preview');
    if (!preview) return;
    preview.style.display = preview.style.display === 'none' ? 'block' : 'none';
}

// ---------------------------------------------------------------------------
// Progress helpers
// ---------------------------------------------------------------------------
function _sanProgressUpdate(total, done, snips, know, skip, provider) {
    const pct = total > 0 ? Math.round(done / total * 100) : (done > 0 ? 100 : 0);
    document.getElementById('san-prog-bar').style.width    = pct + '%';
    document.getElementById('san-prog-chunks').textContent = done + '/' + total;
    document.getElementById('san-prog-snips').textContent  = snips;
    document.getElementById('san-prog-know').textContent   = know;
    document.getElementById('san-prog-skip').textContent   = skip;
    document.getElementById('san-prog-provider').textContent = provider || '—';
}

function _sanMsg(pane, msg) {
    const el = document.getElementById('san-' + pane + '-msg');
    if (el) el.textContent = msg;
}

function _sanFmtTime(iso) {
    if (!iso) return '—';
    try {
        const d = new Date(iso);
        const diff = Math.round((Date.now() - d) / 60000);
        if (diff < 2)    return 'just now';
        if (diff < 60)   return diff + 'm ago';
        if (diff < 1440) return Math.round(diff/60) + 'h ago';
        return fmtDate(d);
    } catch(e) { return iso; }
}

function _sanStopPoll() {
    if (_sanPollTimer) { clearInterval(_sanPollTimer); _sanPollTimer = null; }
}

// ── Cockpit modal confirm / prompt (replaces native confirm/prompt) ─────────
function cockpitConfirm(title, message, confirmLabel = 'Confirm', opts = {}) {
    return new Promise(resolve => {
        const id = 'cockpit-confirm-modal';
        document.getElementById(id)?.remove();
        const ov = document.createElement('div');
        ov.id = id;
        // Always-on-top: confirm must sit above every other modal (account /
        // marketplace / picker use z-index up to ~100002).
        ov.style.cssText = 'position:fixed;inset:0;z-index:2147483000;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        const accent = opts.danger ? 'var(--accent-amber)' : 'var(--accent-blue)';
        ov.innerHTML =
            '<div style="background:var(--bg-base);border:1px solid ' + accent + ';border-radius:6px;width:min(460px,90vw);padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
            '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
                '<span class="material-symbols-rounded" style="color:' + accent + ';font-size:18px;">' + (opts.icon || 'help') + '</span>' +
                '<h2 style="margin:0;font-size:13px;color:' + accent + ';">' + title + '</h2>' +
            '</div>' +
            '<div style="font-size:12px;color:var(--text-base);line-height:1.5;margin-bottom:14px;white-space:pre-line;">' + message + '</div>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
                '<button class="action-btn" data-role="cancel" style="padding:5px 14px;">' + escapeHtml(opts.cancelLabel || 'Cancel') + '</button>' +
                '<button class="action-btn" data-role="ok" style="padding:5px 16px;background:' + accent + ';color:var(--bg-base);border-color:' + accent + ';font-weight:600;">' + confirmLabel + '</button>' +
            '</div></div>';
        document.body.appendChild(ov);
        const close = v => { document.removeEventListener('keydown', esc, true); ov.remove(); resolve(v); };   // the Esc listener must go with the dialog, or it swallows the NEXT Esc anywhere
        ov.querySelector('[data-role="cancel"]').onclick = () => close(false);
        ov.querySelector('[data-role="ok"]').onclick = () => close(true);
        ov.addEventListener('click', e => { if (e.target === ov) close(false); });
        const esc = e => { if (e.key === 'Escape') { e.stopPropagation(); close(false); document.removeEventListener('keydown', esc, true); } };
        document.addEventListener('keydown', esc, true);
        // a destructive confirm starts on Cancel, so a stray Enter cannot delete anything
        ov.querySelector(opts.danger ? '[data-role="cancel"]' : '[data-role="ok"]').focus();
    });
}

function cockpitPrompt(title, message, placeholder = '', defaultVal = '') {
    return new Promise(resolve => {
        const id = 'cockpit-prompt-modal';
        document.getElementById(id)?.remove();
        const ov = document.createElement('div');
        ov.id = id;
        ov.style.cssText = 'position:fixed;inset:0;z-index:10100;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        ov.innerHTML =
            '<div style="background:var(--bg-base);border:1px solid var(--accent-blue);border-radius:6px;width:min(460px,90vw);padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
            '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
                '<span class="material-symbols-rounded" style="color:var(--accent-blue);font-size:18px;">edit</span>' +
                '<h2 style="margin:0;font-size:13px;color:var(--accent-blue);">' + title + '</h2>' +
            '</div>' +
            '<div style="font-size:12px;color:var(--text-base);line-height:1.5;margin-bottom:10px;">' + message + '</div>' +
            '<input type="text" data-role="input" value="' + escapeHtml(defaultVal) + '" placeholder="' + escapeHtml(placeholder) + '" ' +
                'style="width:100%;box-sizing:border-box;padding:6px 10px;font-size:12px;font-family:var(--font-mono);background:var(--bg-panel);color:var(--text-base);border:1px solid var(--border-mid);border-radius:4px;margin-bottom:14px;">' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
                '<button class="action-btn" data-role="cancel" style="padding:5px 14px;">Cancel</button>' +
                '<button class="action-btn" data-role="ok" style="padding:5px 16px;background:var(--accent-blue);color:var(--bg-base);border-color:var(--accent-blue);font-weight:600;">OK</button>' +
            '</div></div>';
        document.body.appendChild(ov);
        const inp = ov.querySelector('[data-role="input"]');
        const close = v => { document.removeEventListener('keydown', esc, true); ov.remove(); resolve(v); };   // the Esc listener must go with the dialog, or it swallows the NEXT Esc anywhere
        ov.querySelector('[data-role="cancel"]').onclick = () => close(null);
        ov.querySelector('[data-role="ok"]').onclick = () => close(inp.value);
        inp.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); close(inp.value); } });
        ov.addEventListener('click', e => { if (e.target === ov) close(null); });
        const esc = e => { if (e.key === 'Escape') { e.stopPropagation(); close(null); document.removeEventListener('keydown', esc, true); } };
        document.addEventListener('keydown', esc, true);
        inp.focus(); inp.select();
    });
}

// Drop-in replacement for the native confirm(): the styled dialog (native confirm is blocked or invisible in some embedded
// browsers and looks foreign everywhere). Same arg as window.confirm, so call sites only need `await`.
function cconfirm(message, confirmLabel = 'OK') {
    return cockpitConfirm('Cockpit', escapeHtml(String(message)), confirmLabel);
}

// Drop-in replacement for the native prompt dialog using the Cockpit modal.
// Same arg order as window.prompt so call sites only need `await`.
function cprompt(message, defaultVal = '', title = 'Cockpit') {
    return cockpitPrompt(title, message, '', defaultVal);
}

function cockpitChoice(title, message, options) {
    return new Promise(resolve => {
        const id = 'cockpit-choice-modal';
        document.getElementById(id)?.remove();
        const ov = document.createElement('div');
        ov.id = id;
        ov.style.cssText = 'position:fixed;inset:0;z-index:10100;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        const btns = options.map((o, i) =>
            '<button class="action-btn" data-idx="' + i + '" style="padding:5px 14px;' +
            (o.accent ? 'background:' + o.accent + ';color:var(--bg-base);border-color:' + o.accent + ';font-weight:600;' : '') +
            '">' + o.label + '</button>').join('');
        ov.innerHTML =
            '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(460px,90vw);padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
            '<div style="border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
                '<h2 style="margin:0;font-size:13px;color:var(--text-base);">' + title + '</h2>' +
            '</div>' +
            '<div style="font-size:12px;color:var(--text-base);line-height:1.5;margin-bottom:14px;white-space:pre-line;">' + message + '</div>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap;">' +
                '<button class="action-btn" data-role="cancel" style="padding:5px 14px;">Cancel</button>' +
                btns +
            '</div></div>';
        document.body.appendChild(ov);
        const close = v => { document.removeEventListener('keydown', esc, true); ov.remove(); resolve(v); };   // the Esc listener must go with the dialog, or it swallows the NEXT Esc anywhere
        ov.querySelector('[data-role="cancel"]').onclick = () => close(null);
        ov.querySelectorAll('[data-idx]').forEach(b => {
            b.onclick = () => close(options[parseInt(b.dataset.idx)].value);
        });
        ov.addEventListener('click', e => { if (e.target === ov) close(null); });
        const esc = e => { if (e.key === 'Escape') { e.stopPropagation(); close(null); document.removeEventListener('keydown', esc, true); } };
        document.addEventListener('keydown', esc, true);
    });
}

// ── Custom context menu helper ──────────────────────────────────────────────
function cockpitContextMenu(e, items) {
    e.preventDefault();
    document.querySelectorAll('.cockpit-ctx-menu').forEach(m => m.remove());
    const menu = document.createElement('div');
    menu.className = 'cockpit-ctx-menu';
    menu.style.cssText = 'position:fixed;z-index:10200;background:var(--bg-base);border:1px solid var(--border-mid);border-radius:4px;padding:4px 0;box-shadow:0 4px 16px rgba(0,0,0,0.5);font-family:var(--font-ui);font-size:11px;min-width:140px;';
    menu.style.left = Math.min(e.clientX, window.innerWidth - 180) + 'px';
    menu.style.top  = Math.min(e.clientY, window.innerHeight - items.length * 30 - 10) + 'px';
    items.forEach(it => {
        if (it === '---') { const hr = document.createElement('div'); hr.style.cssText='border-top:1px solid var(--border-dim);margin:3px 0;'; menu.appendChild(hr); return; }
        const row = document.createElement('div');
        row.style.cssText = 'padding:5px 14px;cursor:pointer;white-space:nowrap;display:flex;align-items:center;gap:6px;';
        if (it.icon) row.innerHTML = '<span class="material-symbols-rounded" style="font-size:14px;">' + it.icon + '</span>';
        const lbl = document.createElement('span'); lbl.textContent = it.label; row.appendChild(lbl);
        row.onmouseover = () => row.style.background = 'var(--bg-active)';
        row.onmouseout  = () => row.style.background = '';
        row.onclick = () => { menu.remove(); it.action(); };
        menu.appendChild(row);
    });
    document.body.appendChild(menu);
    const off = e2 => { if (!menu.contains(e2.target)) { menu.remove(); document.removeEventListener('mousedown', off, true); } };
    setTimeout(() => document.addEventListener('mousedown', off, true), 0);
}

// ── Global context menu suppression ─────────────────────────────────────────
document.addEventListener('contextmenu', e => {
    // A field's own contextmenu listener (prompt box, note body) already ran and
    // called cockpitContextMenu (which preventDefaults) — don't double-handle.
    if (e.defaultPrevented) return;
    const tag = e.target.tagName;

    // SELECT / dropdowns: nothing to edit — just suppress the native menu.
    if (tag === 'SELECT') { e.preventDefault(); return; }

    // Any other input/textarea: generic Cockpit edit menu (Cut/Copy/Paste/All).
    if (tag === 'INPUT' || tag === 'TEXTAREA') {
        const el = e.target;
        const a = el.selectionStart ?? 0, b = el.selectionEnd ?? 0;
        const fsel = (el.value || '').substring(a, b);
        const hasSel = fsel && fsel.trim() !== '';
        const items = [];
        if (hasSel) {
            items.push({ label: 'Cut', icon: 'content_cut', action: () => { navigator.clipboard.writeText(fsel); el.setRangeText('', el.selectionStart, el.selectionEnd, 'end'); } });
            items.push({ label: 'Copy', icon: 'content_copy', action: () => navigator.clipboard.writeText(fsel) });
        }
        items.push({ label: 'Paste', icon: 'content_paste', action: () => navigator.clipboard.readText().then(t => el.setRangeText(t, el.selectionStart, el.selectionEnd, 'end')) });
        items.push({ label: 'Select All', icon: 'select_all', action: () => el.select() });
        cockpitContextMenu(e, items);
        return;
    }

    // Chat panel: allow copy on selected text
    const inChat = e.target.closest('#console-box');
    const sel = window.getSelection();
    if (inChat && sel && sel.toString().trim()) {
        const txt = sel.toString();
        cockpitContextMenu(e, [
            { label: 'Copy', icon: 'content_copy', action: () => navigator.clipboard.writeText(txt) },
            { label: 'Select All', icon: 'select_all', action: () => { const r = document.createRange(); r.selectNodeContents(consoleBox); sel.removeAllRanges(); sel.addRange(r); } },
            '---',
            { label: 'Save to Snippets', icon: 'bookmark', action: () => _showSaveLibraryDialog('snippet', txt, txt.split('\n')[0].slice(0,60) || 'Snippet', '') },
            { label: 'Save to Library', icon: 'library_books', action: () => _showSaveLibraryDialog('library', txt, txt.split('\n')[0].slice(0,60) || 'Library entry', 'md') }
        ]);
        return;
    }

    // Elements with custom oncontextmenu attr — let them handle it
    if (e.target.closest('[oncontextmenu]')) return;

    e.preventDefault();
});

// =============================================================================
// TRANSCRIBER UI
// =============================================================================
let _transCurrentId = null;

function transcriberOpen() {
    document.getElementById('transcriber-overlay').style.display = 'block';
    document.getElementById('transcriber-panel').style.display = 'block';
    transcriberLoadList();
}

function transcriberClose() {
    document.getElementById('transcriber-overlay').style.display = 'none';
    document.getElementById('transcriber-panel').style.display = 'none';
}

function _transMsg(msg, isErr) {
    const el = document.getElementById('trans-msg');
    el.textContent = msg;
    el.style.color = isErr ? 'var(--accent-orange)' : 'var(--text-muted)';
}

async function transcriberExtract() {
    const url = document.getElementById('trans-url').value.trim();
    if (!url) { _transMsg('Enter a YouTube URL', true); return; }
    _transMsg('Extracting transcript…');
    document.getElementById('trans-results').style.display = 'none';

    try {
        const r = await fetch('transcriber.php?action=extract', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ url }),
        });
        const d = await r.json();
        if (!d.ok) { _transMsg('Error: ' + (d.error || 'failed'), true); return; }

        _transCurrentId = d.id;
        _transMsg('Transcript extracted — ' + d.word_count + ' words');
        document.getElementById('trans-results').style.display = 'block';
        document.getElementById('trans-meta').innerHTML =
            '<div style="font-weight:600;color:var(--accent-cyan);">' + _esc(d.title) + '</div>' +
            '<div style="color:var(--text-muted);font-size:10px;">' + _esc(d.channel) +
            ' | ' + Math.round(d.duration/60) + ' min | ' + d.word_count + ' words</div>';
        document.getElementById('trans-analysis').innerHTML = '';
        document.getElementById('trans-btn-analyze').style.display = '';
        document.getElementById('trans-btn-compile').style.display = 'none';
        document.getElementById('trans-btn-download').style.display = 'none';
        document.getElementById('trans-btn-html').style.display = 'none';
        _transPopulateSrtLangs();
        transcriberLoadList();
    } catch(e) { _transMsg('Network error: ' + e.message, true); }
}

// Toggle the three input sources; show the spoken-language row for file sources.
function transSrcSwitch() {
    const v = (document.querySelector('input[name="trans-src"]:checked') || {}).value || 'youtube';
    document.getElementById('trans-src-youtube').style.display = v === 'youtube' ? 'flex' : 'none';
    document.getElementById('trans-src-upload').style.display  = v === 'upload'  ? 'flex' : 'none';
    document.getElementById('trans-src-path').style.display    = v === 'path'    ? 'flex' : 'none';
    document.getElementById('trans-lang-row').style.display    = (v === 'upload' || v === 'path') ? 'flex' : 'none';
}

// Render an extracted/transcribed result into the panel (shared by all sources).
function _transShowResult(d) {
    _transCurrentId = d.id;
    _transMsg('Transcript ready — ' + d.word_count + ' words');
    document.getElementById('trans-results').style.display = 'block';
    document.getElementById('trans-meta').innerHTML =
        '<div style="font-weight:600;color:var(--accent-cyan);">' + _esc(d.title || '') + '</div>' +
        '<div style="color:var(--text-muted);font-size:10px;">' + _esc(d.channel || '') +
        (d.duration ? ' | ' + Math.round(d.duration/60) + ' min' : '') + ' | ' + d.word_count + ' words</div>';
    document.getElementById('trans-analysis').innerHTML = '';
    document.getElementById('trans-btn-analyze').style.display = '';
    document.getElementById('trans-btn-compile').style.display = 'none';
    document.getElementById('trans-btn-download').style.display = 'none';
    document.getElementById('trans-btn-html').style.display = 'none';
    _transPopulateSrtLangs();
    transcriberLoadList();
}

// Fill the SRT target-language dropdown from LibreTranslate's loaded languages.
async function _transPopulateSrtLangs() {
    const sel = document.getElementById('trans-srt-lang');
    if (!sel || sel.dataset.filled) return;
    try {
        const langs = (typeof _xlateFetchLangsRaw === 'function') ? await _xlateFetchLangsRaw() : [];
        if (langs.length) {
            sel.innerHTML = '<option value="">original</option>' +
                langs.map(l => '<option value="' + l.code + '">→ ' + _esc(l.name) + '</option>').join('');
            sel.dataset.filled = '1';
        }
    } catch(e) {}
}

// Transcribe a local file (uploaded or on-disk path) via whisper → SRT.
async function transcriberExtractFile(mode) {
    const lang = document.getElementById('trans-lang-in').value || 'auto';
    _transMsg('Transcribing locally (whisper)… this can take a while for long clips.');
    document.getElementById('trans-results').style.display = 'none';
    try {
        let r;
        if (mode === 'upload') {
            const f = document.getElementById('trans-file').files[0];
            if (!f) { _transMsg('Choose a video/audio file', true); return; }
            const fd = new FormData(); fd.append('video', f); fd.append('lang', lang);
            r = await fetch('transcriber.php?action=extract_file', { method:'POST', body: fd });
        } else {
            const path = document.getElementById('trans-path').value.trim();
            if (!path) { _transMsg('Enter a file path', true); return; }
            r = await fetch('transcriber.php?action=extract_file', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({ path, lang }) });
        }
        const d = await r.json();
        if (!d.ok) { _transMsg('Error: ' + (d.error || 'failed') + (d.hint ? ' — ' + d.hint : ''), true); return; }
        _transShowResult(d);
    } catch(e) { _transMsg('Network error: ' + e.message, true); }
}

// Download subtitles as .srt (optionally translated to the selected language).
async function transcriberDownloadSrt() {
    if (!_transCurrentId) { _transMsg('Extract or transcribe something first', true); return; }
    const lang = document.getElementById('trans-srt-lang').value || '';
    _transMsg(lang ? ('Building + translating SRT to ' + lang + '…') : 'Building SRT…');
    try {
        const r = await fetch('transcriber.php?action=srt&id=' + encodeURIComponent(_transCurrentId) +
                              (lang ? '&lang=' + encodeURIComponent(lang) : ''));
        if (!r.ok) { const d = await r.json().catch(() => ({})); _transMsg('SRT failed: ' + (d.error || r.status), true); return; }
        const blob = await r.blob();
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = _transCurrentId + (lang ? '.' + lang : '') + '.srt';
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 4000);
        _transMsg('SRT downloaded.');
    } catch(e) { _transMsg('SRT error: ' + e.message, true); }
}

async function transcriberAnalyze() {
    if (!_transCurrentId) return;
    const model = sentOllamaModelGet() || 'qwen2.5-coder:1.5b';
    _transMsg('Analyzing with ' + model + '…');

    try {
        const r = await fetch('transcriber.php?action=analyze', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ id: _transCurrentId, model }),
        });
        const d = await r.json();
        if (!d.ok) { _transMsg('Analysis error: ' + (d.error || ''), true); return; }

        _transMsg('LLM running… polling output…');
        let output = '';
        try { output = await orchestratorPollToken(d.token, 'transcriber'); }
        catch(e) { _transMsg('Poll timeout: ' + e.message, true); return; }

        const fr = await fetch('transcriber.php?action=analyze_finalize', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ id: _transCurrentId, output }),
        });
        const fd = await fr.json();
        if (!fd.ok) { _transMsg('Finalize error: ' + (fd.error || ''), true); return; }

        _transMsg('Analysis complete');
        _transRenderAnalysis(fd.analysis);
        document.getElementById('trans-btn-compile').style.display = '';
    } catch(e) { _transMsg('Error: ' + e.message, true); }
}

function _transRenderAnalysis(a) {
    const el = document.getElementById('trans-analysis');
    let h = '<div style="background:var(--bg-darker);border-left:3px solid var(--accent-cyan);padding:8px 10px;margin-bottom:6px;border-radius:3px;">'
          + '<strong>Summary:</strong> ' + _esc(a.summary || '') + '</div>';
    (a.sections || []).forEach((s, i) => {
        h += '<div style="background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;padding:8px 10px;margin-bottom:4px;">'
           + '<div style="color:var(--accent-orange);font-weight:600;">' + (i+1) + '. ' + _esc(s.title || '') + '</div>'
           + '<div style="font-size:10px;"><span style="color:var(--accent-cyan);">How:</span> ' + _esc(s.how_it_works || '') + '</div>'
           + '<div style="font-size:10px;"><span style="color:var(--accent-cyan);">Best for:</span> ' + _esc(s.best_for || '') + '</div>'
           + '</div>';
    });
    if (a.takeaways && a.takeaways.length) {
        h += '<div style="border:1px dashed var(--accent-orange);border-radius:4px;padding:8px 10px;margin-top:6px;">'
           + '<strong>Takeaways:</strong><ul style="margin:4px 0;padding-left:16px;">';
        a.takeaways.forEach(t => { h += '<li>' + _esc(t) + '</li>'; });
        h += '</ul></div>';
    }
    el.innerHTML = h;
}

async function transcriberCompile() {
    if (!_transCurrentId) return;
    _transMsg('Compiling document…');
    try {
        const r = await fetch('transcriber.php?action=compile', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ id: _transCurrentId }),
        });
        const d = await r.json();
        if (!d.ok) { _transMsg('Compile error: ' + (d.error || ''), true); return; }
        _transMsg('Document ready' + (d.has_pdf ? ' (PDF + HTML)' : ' (HTML only)'));
        if (d.has_pdf) document.getElementById('trans-btn-download').style.display = '';
        document.getElementById('trans-btn-html').style.display = '';
        cockpitNotify('Transcriber Done', 'Document compiled and ready for download.');
        transcriberLoadList();
    } catch(e) { _transMsg('Error: ' + e.message, true); }
}

function transcriberDownload(fmt) {
    if (!_transCurrentId) return;
    window.open('transcriber.php?action=download&id=' + encodeURIComponent(_transCurrentId) + '&format=' + fmt, '_blank');
}

async function transcriberLoadList() {
    const el = document.getElementById('trans-list');
    try {
        const r = await fetch('transcriber.php?action=list');
        const d = await r.json();
        if (!d.ok || !d.items || d.items.length === 0) {
            el.innerHTML = '<div style="color:var(--text-dim);font-size:10px;padding:4px;">No transcriptions yet.</div>';
            return;
        }
        el.innerHTML = d.items.map(it => {
            const statusIcon = it.status === 'compiled' ? 'check_circle' : it.status === 'error' ? 'error' : 'pending';
            return '<div style="display:flex;align-items:center;gap:6px;padding:4px 0;border-bottom:1px solid var(--border-dim);cursor:pointer;" '
                 + 'onclick="_transLoadPast(\'' + _esc(it.id) + '\')">'
                 + '<span class="material-symbols-rounded" style="font-size:13px;color:var(--text-muted);">' + statusIcon + '</span>'
                 + '<span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + _esc(it.title) + '</span>'
                 + '<span style="font-size:9px;color:var(--text-dim);">' + _esc(it.status) + '</span>'
                 + (it.has_pdf ? '<span class="material-symbols-rounded" style="font-size:12px;color:var(--accent-cyan);cursor:pointer;" '
                   + 'onclick="event.stopPropagation();_transCurrentId=\'' + _esc(it.id) + '\';transcriberDownload(\'pdf\')">download</span>' : '')
                 + '</div>';
        }).join('');
    } catch(e) { el.innerHTML = '<div style="color:var(--accent-orange);">Load error</div>'; }
}

async function _transLoadPast(id) {
    _transCurrentId = id;
    _transMsg('Loading…');
    try {
        const r = await fetch('transcriber.php?action=status&id=' + encodeURIComponent(id));
        const d = await r.json();
        if (!d.ok) { _transMsg('Error: ' + (d.error || ''), true); return; }
        document.getElementById('trans-results').style.display = 'block';
        document.getElementById('trans-meta').innerHTML =
            '<div style="font-weight:600;color:var(--accent-cyan);">' + _esc(d.title || id) + '</div>' +
            '<div style="color:var(--text-muted);font-size:10px;">' + _esc(d.channel || '') +
            ' | ' + Math.round((d.duration||0)/60) + ' min</div>';
        document.getElementById('trans-btn-analyze').style.display = (d.status === 'extracted') ? '' : 'none';
        document.getElementById('trans-btn-compile').style.display = (d.status === 'analyzed') ? '' : 'none';
        document.getElementById('trans-btn-download').style.display = d.has_pdf ? '' : 'none';
        document.getElementById('trans-btn-html').style.display = (d.status === 'compiled') ? '' : 'none';
        _transMsg('Status: ' + d.status);
    } catch(e) { _transMsg('Error: ' + e.message, true); }
}


// Viewport size display in status bar
(function() {
    function updateSize() {
        const el = document.getElementById('statusbar-viewport');
        if (el) el.textContent = window.innerWidth + '×' + window.innerHeight;
    }
    window.addEventListener('resize', updateSize);
    updateSize();
})();

