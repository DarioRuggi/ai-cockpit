// WORKERS — online LLM providers as a 4th provider class
//
// Workers don't have a tmux session — they're pure HTTP. The cockpit treats
// "workers" as a special agent that, on submit, dispatches via workers.php
// to whichever provider+model is selected in the topbar dropdown.
//
// Two invocation paths:
//   1. Manual — user picks the workers agent, types a prompt, presses Execute
//   2. Auto-route — main agents emit %%WORKER:provider:task:prompt%% markers,
//      crud_executor.sh dispatches them, results feed back via %%WORKER_RESULT%%
// =============================================================================

let _workersModels = [];   // populated from workers.php?action=models

// Load model list and populate the topbar selector
async function workersLoadModels() {
    try {
        const r = await fetch('workers.php?action=models');
        const d = await r.json();
        const panel = document.getElementById('workers-panel');
        const hidden = document.getElementById('workers-model');
        if (!panel) return;
        _workersModels = d.models || [];
        if (!_workersModels.length) {
            panel.innerHTML = '<div class="cs-option disabled"><span class="cs-option-name">— no workers configured —</span></div>';
            if (hidden) hidden.value = '';
            document.getElementById('workers-selected-label').textContent = T('msg.no.workers.configured', '— no workers configured —');
            const btn = document.getElementById('btn-agent-workers');
            if (btn) btn.style.opacity = '0.5';
            return;
        }
        const btn = document.getElementById('btn-agent-workers');
        if (btn) btn.style.opacity = '1';
        const byProvider = {};
        for (const m of _workersModels) (byProvider[m.provider] = byProvider[m.provider] || []).push(m);
        let html = '';
        // Auto (cascade): rotate through enabled FREE workers by priority,
        // advancing to the next when one hits its quota (or 429). Shown only
        // when at least one free worker exists.
        if (_workersModels.some(m => m.free)) {
            html += '<div class="cs-option" data-value="__cascade__" onclick="selectWorkersModel(this)" title="Use free workers in priority order; auto-advance when each hits its limit"><span class="cs-option-name"><span class="material-symbols-rounded ico">bolt</span> Auto (cascade) — free workers, rotate on limit</span></div>';
        }
        for (const [pid, ms] of Object.entries(byProvider)) {
            ms.sort((a, b) => ((a.label.split(' · ')[1]||a.value)).localeCompare(b.label.split(' · ')[1]||b.value));
            const groupName = ms[0].label.split(' · ')[0];
            html += `<div class="cs-group-header" data-tier="${pid}">${groupName} <button type="button" class="cs-sort-combo" value="alpha" title="Sort this section: A to Z, or the order they were added" onclick="event.stopPropagation();csCycleSort(this,sortWorkersTier)">A→Z</button></div>`;
            for (const m of ms) {
                const kindMark = (m.kinds || []).map(k => ({
                    text:'<span class="material-symbols-rounded ico">edit</span>', code:'⌨', image:'<span class="material-symbols-rounded ico">image</span>', 'image-gen':'<span class="material-symbols-rounded ico">image</span>',
                    audio:'<span class="material-symbols-rounded ico">volume_up</span>', translate:'<span class="material-symbols-rounded ico">language</span>', summary:'<span class="material-symbols-rounded ico">menu</span>',
                }[k] || '·')).join('');
                const label = (m.label.split(' · ')[1] || m.value) + ' ' + kindMark + (m.free ? ' (free)' : '');
                html += `<div class="cs-option" data-value="${m.value}" onclick="selectWorkersModel(this)"><span class="cs-option-name">${label}</span></div>`;
            }
        }
        panel.innerHTML = html;
        wireCollapsibleGroupHeaders('workers-panel');
        // Auto-select first
        const saved = localStorage.getItem('cockpit_last_workers_model') || hidden.value;
        const savedOpt = saved ? panel.querySelector(`.cs-option[data-value="${CSS.escape(saved)}"]`) : null;
        const pick = savedOpt || panel.querySelector('.cs-option:not(.disabled)');
        if (pick) {
            panel.querySelectorAll('.cs-option').forEach(o => o.classList.remove('selected'));
            pick.classList.add('selected');
            hidden.value = pick.dataset.value;
            document.getElementById('workers-selected-label').textContent = pick.querySelector('.cs-option-name').textContent.trim();
        }
        if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
    } catch(e) {
        console.warn('workersLoadModels failed:', e);
    }
}

// Open the Workers settings modal — load providers and render
async function workersOpenSettings() {
    const modal = document.getElementById('workers-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    await workersRefreshSettings();
}

// Provider/model drift sweep (#3). DNS-checks each enabled provider and lists
// models flagged dead/degraded by the self-heal marks. Colour + shape + text
// (protanopia-safe): ● ok / ▲ degraded /  dead / ◌ unknown.
async function workersHealthCheck() {
    const box = document.getElementById('workers-discover-results');
    if (!box) return;
    box.style.display = 'block';
    box.innerHTML = 'Checking provider health…';
    try {
        const r = await fetch('workers.php?action=health');
        const d = await r.json();
        if (!d.ok) { box.innerHTML = 'Health check failed: ' + escHtml(d.error || ''); return; }
        const dot = (st) => {
            const map = {
                ok:       ['●', 'var(--accent-cyan,var(--gemini))', 'OK'],
                degraded: ['▲', 'var(--accent-amber)',  'DEGRADED'],
                dead:     ['<span class="material-symbols-rounded ico">close</span>', 'var(--accent-orange,var(--ollama))', 'DEAD'],
                auth:     ['▲', 'var(--accent-violet,var(--accent-amber))', 'AUTH'],
            };
            const [g, c, t] = map[st] || ['◌', 'var(--text-muted)', (st || 'UNKNOWN').toUpperCase()];
            return '<span style="color:' + c + ';font-weight:700;">' + g + ' ' + t + '</span>';
        };
        let html = '<div style="font-weight:600;margin-bottom:6px;">Provider health — ' + escHtml(d.checked_at || '') + '</div>';
        (d.rows || []).forEach(row => {
            if (!row.enabled) return;
            const dns = (row.dns_ok === false) ? ' · <span style="color:var(--accent-orange,var(--ollama));">DNS FAIL (' + escHtml(row.host || '') + ')</span>'
                       : (row.dns_ok === true) ? ' · DNS ok' : '';
            html += '<div style="border-bottom:1px solid var(--border-dim);padding:4px 0;">' +
                '<div style="display:flex;align-items:center;gap:8px;">' +
                  '<b style="min-width:120px;">' + escHtml(row.name || row.provider) + '</b>' +
                  dot(row.status) + dns +
                  (row.reason ? '<span style="color:var(--text-muted);font-size:9.5px;">· ' + escHtml(row.reason) + '</span>' : '') +
                '</div>';
            const mids = Object.keys(row.models || {});
            mids.forEach(mid => {
                const mh = row.models[mid];
                html += '<div style="font-size:9.5px;font-family:var(--font-mono);padding-left:14px;color:var(--text-muted);">' +
                    dot(mh.status) + ' ' + escHtml(mid) + (mh.reason ? ' — ' + escHtml(mh.reason) : '') + '</div>';
            });
            html += '</div>';
        });
        html += '<div style="margin-top:6px;font-size:9.5px;color:var(--text-muted);">Dead/degraded models are auto-skipped by Auto-engine routing until a later call succeeds.</div>';
        box.innerHTML = html;
        // Refresh the model list so any cleared/added degraded flags propagate.
        if (typeof workersLoadModels === 'function') workersLoadModels();
    } catch (e) {
        box.innerHTML = 'Health check failed: ' + escHtml(e.message);
    }
}

// F9: probe providers with stored keys and report reachability + sample models
async function workersDiscover() {
    const box = document.getElementById('workers-discover-results');
    if (!box) return;
    box.style.display = 'block';
    box.innerHTML = 'Probing providers… (querying each /models endpoint)';
    try {
        const r = await fetch('workers.php?action=discover', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'});
        const d = await r.json();
        if (!d.ok) { box.innerHTML = 'Discover failed: ' + escHtml(d.error||''); return; }
        let html = '<div style="font-weight:600;margin-bottom:6px;">Provider discovery — click <b>+</b> to make a model selectable</div>';
        (d.providers || []).forEach(p => {
            let statusTxt, statusColor;
            if (!p.has_key)        { statusTxt = 'no key';        statusColor = 'var(--text-muted)'; }
            else if (p.reachable)  { statusTxt = p.model_count + ' models'; statusColor = 'var(--accent-cyan,var(--gemini))'; }
            else                   { statusTxt = p.note || 'unreachable'; statusColor = 'var(--accent-orange,var(--ollama))'; }

            html += '<div style="border-bottom:1px solid var(--border-dim);padding:4px 0;">' +
                '<div style="display:flex;align-items:center;gap:6px;">' +
                  '<b style="min-width:120px;">' + escHtml(p.name) + '</b>' +
                  '<span style="color:' + statusColor + ';">' + escHtml(statusTxt) + '</span>' +
                '</div>';

            const models = p.models || [];
            if (models.length) {
                html += '<input type="text" class="wd-filter" data-pid="' + escHtml(p.id) + '" placeholder="filter ' +
                        models.length + ' models…" style="width:100%;box-sizing:border-box;margin:4px 0;background:var(--bg-darker);' +
                        'border:1px solid var(--border-dim);color:var(--text-base);font-size:10px;padding:3px 6px;border-radius:3px;font-family:var(--font-mono);">';
                html += '<div class="wd-list" data-pid="' + escHtml(p.id) + '" style="max-height:140px;overflow:auto;display:flex;flex-direction:column;gap:1px;">';
                models.forEach(mid => {
                    html += '<div class="wd-row" data-mid="' + escHtml(mid) + '" style="display:flex;align-items:center;gap:6px;font-size:9.5px;font-family:var(--font-mono);padding:1px 2px;">' +
                        '<button class="wd-add" title="Make selectable" style="cursor:pointer;background:none;border:1px solid var(--border-mid);color:var(--text-base);border-radius:3px;font-size:11px;line-height:1;padding:0 5px;">+</button>' +
                        '<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;">' + escHtml(mid) + '</span>' +
                        '</div>';
                });
                html += '</div>';
            }
            html += '</div>';
        });
        box.innerHTML = html;

        // Wire filters (per provider) and add buttons.
        box.querySelectorAll('.wd-filter').forEach(inp => {
            inp.addEventListener('input', () => {
                const q = inp.value.toLowerCase();
                const list = box.querySelector('.wd-list[data-pid="' + inp.dataset.pid + '"]');
                if (!list) return;
                list.querySelectorAll('.wd-row').forEach(row => {
                    row.style.display = row.dataset.mid.toLowerCase().includes(q) ? 'flex' : 'none';
                });
            });
        });
        box.querySelectorAll('.wd-list').forEach(list => {
            const pid = list.dataset.pid;
            list.querySelectorAll('.wd-add').forEach(btn => {
                btn.addEventListener('click', async () => {
                    const row = btn.closest('.wd-row');
                    const mid = row.dataset.mid;
                    btn.disabled = true; btn.textContent = '…';
                    const ok = await workersAddDiscoveredModel(pid, mid);
                    btn.innerHTML = ok ? '<span class="material-symbols-rounded ico">check</span>' : '+';
                    if (ok) { btn.style.borderColor = 'var(--accent-cyan)'; btn.style.color = 'var(--accent-cyan)'; }
                    else    { btn.disabled = false; }
                });
            });
        });
    } catch(e) { box.innerHTML = 'Discover failed: ' + escHtml(e.message); }
}

// Add a discovered model to a provider's selectable set (text kind, not free by
// default). Reuses the same add_model action as the manual dialog.
async function workersAddDiscoveredModel(pid, mid) {
    try {
        const r = await fetch('workers.php?action=add_model', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid, model_id: mid, label: mid, kinds: ['text'], free: false}),
        });
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.add.model.failed.error', 'Add model failed: {error}', {error: (d.error || '')})); return false; }
        appendSystem(T('msg.worker.model.mid.added.to.pid.selectable', 'Worker model "{mid}" added to {pid} (selectable).', {mid: mid, pid: pid}));
        if (typeof workersLoadModels === 'function') workersLoadModels();
        return true;
    } catch(e) { appendError(T('msg.add.model.error.message', 'Add model error: {message}', {message: e.message})); return false; }
}

// F4: test every stored key at once, show a compact status table
async function workersTestAllKeys() {
    const box = document.getElementById('workers-discover-results');
    if (!box) return;
    box.style.display = 'block';
    box.innerHTML = 'Testing all stored keys…';
    try {
        const r = await fetch('workers.php?action=test_all_keys', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'});
        const d = await r.json();
        if (!d.ok) { box.innerHTML = 'Test failed: ' + escHtml(d.error||''); return; }
        const statusColor = s => s==='active' ? 'var(--accent-cyan,var(--gemini))'
                               : s==='invalid' ? 'var(--accent-orange,var(--ollama))'
                               : 'var(--text-muted)';
        let html = '<div style="font-weight:600;margin-bottom:6px;">API key status</div>';
        const entries = Object.entries(d.statuses || {});
        if (!entries.length) html += '<div style="opacity:0.6;">No providers.</div>';
        // readable names: "ww_deepseek" -> "Deepseek", "cli_claude" -> "Claude (command line)"; "no_key" -> "no key stored"
        const niceId = id => { const cli = /^cli_/.test(id); const n = id.replace(/^(ww|cli)_/, '').replace(/_/g, ' '); return n.charAt(0).toUpperCase() + n.slice(1) + (cli ? ' (command line)' : ''); };
        const niceSt = st => ({no_key:'no key stored', active:'active', invalid:'invalid', unknown:'unknown'}[st] || String(st).replace(/_/g, ' '));
        entries.forEach(([pid, st]) => {
            html += '<div style="display:flex;align-items:center;gap:8px;padding:2px 0;">' +
                '<b style="min-width:120px;" title="' + escHtml(pid) + '">' + escHtml(niceId(pid)) + '</b>' +
                '<span style="color:' + statusColor(st) + ';">' + escHtml(niceSt(st)) + '</span></div>';
        });
        html += '<div style="font-size:9.5px;color:var(--text-muted);margin-top:6px;">Tested ' +
                escHtml((d.tested_at||'').slice(0,19).replace('T',' ')) + '. "active" = key accepted, "invalid" = rejected, "unknown" = network/other.</div>';
        box.innerHTML = html;
    } catch(e) { box.innerHTML = 'Test failed: ' + escHtml(e.message); }
}
function workersCloseSettings() {
    const modal = document.getElementById('workers-modal');
    if (modal) modal.style.display = 'none';
    // Refresh model dropdown in case enable/key state changed
    workersLoadModels();
    workersUpdateMeter();
}
// Click outside to close
document.addEventListener('click', (e) => {
    if (e.target?.id === 'workers-modal') workersCloseSettings();
});

// ── Paid-API spend: settings state + consent/cap controls ──────────────────
let _workersSettings   = { allow_paid_api_spend:false, caps:{ global_monthly_usd:0, per_model_monthly_usd:{} } };
let _workersSpend      = { global_usd:0, by_model:{} };
let _workersPaidModels = [];   // [{ key:'provider:model', label }]

async function _loadWorkerSettings() {
    try { const r = await fetch('settings.php?action=get'); const d = await r.json();
        if (d.ok) { _workersSettings = d.settings; _workersSpend = d.spend; } } catch(e) {}
}
function _workersPaidPanelHtml() {
    const allow = !!_workersSettings.allow_paid_api_spend;
    const cap   = +(_workersSettings.caps?.global_monthly_usd || 0);
    const spent = +(_workersSpend?.global_usd || 0);
    const pct   = cap > 0 ? Math.min(100, Math.round(spent / cap * 100)) : 0;
    const warn  = cap > 0 && spent >= cap * 0.8;
    const spentTxt = cap > 0
        ? ('Spent $' + spent.toFixed(4) + ' of $' + cap + ' (' + pct + '%)' + (warn ? ' — near cap!' : ''))
        : ('Spent $' + spent.toFixed(4) + ' this month · no global cap set');
    return '<div style="border:1px solid var(--border-mid);border-radius:5px;padding:10px 12px;margin-bottom:12px;background:var(--bg-darker);">' +
        '<div style="display:flex;align-items:center;gap:8px;">' +
            '<span class="material-symbols-rounded" style="color:var(--accent-amber);font-size:16px;">paid</span>' +
            '<b style="font-size:12px;">Paid API spend</b>' +
            '<span style="margin-left:auto;font-size:11px;font-weight:700;color:' + (allow ? 'var(--accent-cyan)' : 'var(--text-muted)') + ';">' +
                (allow ? 'ENABLED' : 'OFF') + '</span>' +
            '<button class="action-btn" onclick="workersTogglePaid(' + (!allow) + ')" style="padding:3px 10px;">' +
                (allow ? 'Turn OFF' : 'Turn ON…') + '</button>' +
        '</div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin:6px 0;">Paid providers (OpenAI, Claude API, Gemini API) can only be enabled or used while this is ON. Caps are <b>best-effort</b> and may overshoot by about one call.</div>' +
        '<div style="display:flex;align-items:center;gap:8px;font-size:11px;margin-top:6px;flex-wrap:wrap;">' +
            '<span>Global monthly cap&nbsp;$</span>' +
            '<input id="workers-global-cap" type="number" min="0" step="0.5" value="' + cap + '" ' +
                'style="width:80px;background:var(--bg-base);border:1px solid var(--border-dim);color:var(--text-base);padding:3px 6px;border-radius:3px;">' +
            '<span style="margin-left:auto;' + (warn ? 'color:var(--accent-orange);font-weight:700;' : 'color:var(--text-muted);') + '">' + spentTxt + '</span>' +
        '</div>' +
        _workersPerModelCapHtml() +
        '<div style="display:flex;justify-content:flex-end;margin-top:8px;">' +
            '<button class="action-btn" onclick="workersSaveCap()" style="padding:3px 12px;">Save caps</button>' +
        '</div></div>';
}
function _workersPerModelCapHtml() {
    if (!_workersPaidModels.length) return '';
    const caps = _workersSettings.caps?.per_model_monthly_usd || {};
    const spent = _workersSpend?.by_model || {};
    const rows = _workersPaidModels.map(m => {
        const cap = +(caps[m.key] || 0);
        const sp  = +(spent[m.key] || 0);
        const warn = cap > 0 && sp >= cap * 0.8;
        return '<div style="display:flex;align-items:center;gap:8px;font-size:10.5px;padding:2px 0;">' +
            '<span style="flex:1;font-family:var(--font-mono);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' + escAttr(m.key) + '">' + escHtml(m.label) + '</span>' +
            '<span>$</span><input class="wpm-cap" data-key="' + escAttr(m.key) + '" type="number" min="0" step="0.5" value="' + cap + '" ' +
                'style="width:64px;background:var(--bg-base);border:1px solid var(--border-dim);color:var(--text-base);padding:2px 5px;border-radius:3px;">' +
            '<span style="min-width:90px;text-align:right;' + (warn ? 'color:var(--accent-orange);font-weight:700;' : 'color:var(--text-muted);') + '">$' + sp.toFixed(4) + (cap > 0 ? ' / $' + cap : '') + '</span>' +
        '</div>';
    }).join('');
    return '<details style="margin-top:8px;"><summary style="cursor:pointer;font-size:11px;color:var(--text-base);">Per-model monthly caps (' + _workersPaidModels.length + ')</summary>' +
        '<div style="margin-top:4px;border-top:1px solid var(--border-dim);padding-top:4px;">' + rows + '</div></details>';
}
async function workersTogglePaid(on) {
    if (on) {
        _showPaidConsentModal(async () => {
            const r = await fetch('settings.php?action=set_allow', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ allow:true, consent:true }) });
            const d = await r.json(); if (!d.ok) { appendError(d.error || T('msg.failed', 'failed')); return; }
            appendSystem(T('msg.paid.api.spend.enabled.set.caps.then.enable', 'Paid API spend ENABLED. Set caps, then enable specific paid providers.'));
            workersOpenSettings();
        });
    } else {
        await fetch('settings.php?action=set_allow', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ allow:false, consent:true }) });
        appendSystem(T('msg.paid.api.spend.turned.off.paid.providers.can', 'Paid API spend turned OFF. Paid providers can no longer be used.'));
        workersOpenSettings();
    }
}
async function workersSaveCap() {
    const v = Math.max(0, parseFloat(document.getElementById('workers-global-cap')?.value) || 0);
    const perModel = {};
    document.querySelectorAll('.wpm-cap').forEach(inp => {
        const amt = Math.max(0, parseFloat(inp.value) || 0);
        if (amt > 0) perModel[inp.dataset.key] = amt;
    });
    await fetch('settings.php?action=set_caps', { method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({ global_monthly_usd:v, per_model_monthly_usd:perModel }) });
    appendSystem(T('msg.paid.api.caps.saved.global.vv2.keys.per.mode', 'Paid-API caps saved (global ${v}{v2}, {keys} per-model).', {v: v, v2: (v === 0 ? ' = no cap' : ''), keys: Object.keys(perModel).length}));
    workersOpenSettings();
}
// Styled, protanopia-safe consent modal (replaces the native confirm()).
function _showPaidConsentModal(onConfirm) {
    const id = 'paid-consent-modal';
    document.getElementById(id)?.remove();
    const ov = document.createElement('div');
    ov.id = id;
    ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--accent-amber);border-radius:6px;width:min(520px,92vw);padding:18px 22px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:10px;margin-bottom:12px;">' +
            '<span class="material-symbols-rounded" style="color:var(--accent-amber);font-size:20px;">paid</span>' +
            '<h2 style="margin:0;font-size:14px;color:var(--accent-amber);">Enable paid API spend?</h2>' +
        '</div>' +
        '<div style="font-size:12px;color:var(--text-base);line-height:1.6;">' +
            '<p style="margin:0 0 8px 0;">This lets paid providers (OpenAI, Claude API, Gemini API) make calls that cost <b>real money</b>, charged to <b>your</b> API keys (BYOK).</p>' +
            '<ul style="margin:0 0 8px 18px;padding:0;">' +
                '<li>The cockpit does <b>not</b> cap your spend unless you set a monthly cap.</li>' +
                '<li>Caps are <b>best-effort</b> — actual cost isn\'t known until a call returns, so spend can overshoot by about <b>one call</b>.</li>' +
                '<li>Each paid provider must still be <b>enabled individually</b>.</li>' +
                '<li>Revocable any time (turn this OFF).</li>' +
            '</ul>' +
        '</div>' +
        '<label style="display:flex;align-items:center;gap:8px;font-size:11.5px;color:var(--text-base);margin:6px 0 14px 0;cursor:pointer;">' +
            '<input type="checkbox" id="paid-consent-cb" style="width:14px;height:14px;"> I understand this spends real money on my keys.</label>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
            '<button class="action-btn" id="paid-consent-cancel" style="padding:5px 14px;">Cancel</button>' +
            '<button class="action-btn" id="paid-consent-ok" disabled style="padding:5px 16px;opacity:0.5;">Enable paid spend</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    const cb = ov.querySelector('#paid-consent-cb');
    const ok = ov.querySelector('#paid-consent-ok');
    cb.addEventListener('change', () => { ok.disabled = !cb.checked; ok.style.opacity = cb.checked ? '1' : '0.5'; });
    ov.querySelector('#paid-consent-cancel').onclick = () => ov.remove();
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    ok.onclick = () => { if (!cb.checked) return; ov.remove(); onConfirm(); };
}

async function workersRefreshSettings() {
    const list = document.getElementById('workers-list');
    if (!list) return;
    await _loadWorkerSettings();
    await _catalogFeedLoad();
    try {
        const r = await fetch('workers.php?action=providers');
        const d = await r.json();
        if (!d.ok) {
            list.innerHTML = '<div style="color:var(--text-muted);padding:16px;text-align:center;">' +
                'Error: ' + (d.error || 'failed to load') + '</div>';
            return;
        }
        // Collect paid models (for the per-model cap editor).
        _workersPaidModels = [];
        (d.providers || []).forEach(p => {
            if (p.incurs_cost) (p.models || []).forEach(m =>
                _workersPaidModels.push({ key: p.id + ':' + m.id, label: (m.label || m.id) }));
        });
        list.innerHTML = '<div id="workers-cascade-panel" style="border:1px solid var(--border-dim);border-radius:6px;padding:10px 12px;margin-bottom:6px;">Loading cascade priority…</div>'
            + _workersCatalogPanelHtml() + _workersPaidPanelHtml() + (d.providers || []).map(p => workersRenderProvider(p)).join('');
        workersRenderCascadeOrder();
        _applyWorkersSort();   // re-apply the chosen provider sort after re-render
    } catch(e) {
        list.innerHTML = '<div style="color:var(--text-muted);padding:16px;text-align:center;">' +
            'Error: ' + e.message + '</div>';
    }
}

// Cascade priority editor — orders the free workers Auto (cascade) mode walks
// through. ↑/↓ reorder; Save persists to workers.php set_cascade_order.
let _cascadeOrder = [];
async function workersRenderCascadeOrder() {
    const box = document.getElementById('workers-cascade-panel');
    if (!box) return;
    let order = [];
    try {
        const r = await fetch('workers.php?action=get_cascade_order');
        const d = await r.json();
        if (d && d.ok) order = d.order || [];
    } catch(e) {}
    _cascadeOrder = order;
    const labelFor = v => {
        const m = (_workersModels || []).find(x => x.value === v);
        return m ? (m.label || v) : v;
    };
    if (!order.length) {
        box.innerHTML = '<div style="font-size:12px;color:var(--text-muted);"><span class="material-symbols-rounded ico">bolt</span> <b>Auto (cascade) priority</b> — no free workers configured yet. Add one below, then reorder here.</div>';
        return;
    }
    const rows = order.map((v, i) =>
        '<div style="display:flex;align-items:center;gap:6px;padding:3px 0;">' +
        '<span style="flex:0 0 18px;color:var(--text-muted);font-size:11px;">' + (i+1) + '.</span>' +
        '<span style="flex:1;font-size:12px;">' + escHtml(labelFor(v)) + '</span>' +
        '<button class="action-btn" style="padding:1px 7px;" onclick="moveCascade(' + i + ',-1)" ' + (i===0?'disabled':'') + '>↑</button>' +
        '<button class="action-btn" style="padding:1px 7px;" onclick="moveCascade(' + i + ',1)" ' + (i===order.length-1?'disabled':'') + '>↓</button>' +
        '</div>').join('');
    box.innerHTML =
        '<div style="font-size:12px;font-weight:700;margin-bottom:6px;"><span class="material-symbols-rounded ico">bolt</span> Auto (cascade) priority</div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-bottom:8px;">Order free workers are used in. Each runs until its quota is spent, then the next takes over.</div>' +
        rows +
        '<div style="text-align:right;margin-top:8px;"><button class="action-btn" style="background:var(--accent-blue);color:#fff;padding:4px 12px;" onclick="saveCascadeOrder()">Save order</button></div>';
}
function moveCascade(i, dir) {
    const j = i + dir;
    if (j < 0 || j >= _cascadeOrder.length) return;
    const t = _cascadeOrder[i]; _cascadeOrder[i] = _cascadeOrder[j]; _cascadeOrder[j] = t;
    // Re-render in place (reuse renderer but with the mutated local order).
    const box = document.getElementById('workers-cascade-panel');
    if (!box) return;
    const labelFor = v => { const m = (_workersModels||[]).find(x=>x.value===v); return m?(m.label||v):v; };
    const order = _cascadeOrder;
    box.innerHTML =
        '<div style="font-size:12px;font-weight:700;margin-bottom:6px;"><span class="material-symbols-rounded ico">bolt</span> Auto (cascade) priority</div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-bottom:8px;">Order free workers are used in. Each runs until its quota is spent, then the next takes over.</div>' +
        order.map((v,idx)=>'<div style="display:flex;align-items:center;gap:6px;padding:3px 0;">' +
            '<span style="flex:0 0 18px;color:var(--text-muted);font-size:11px;">' + (idx+1) + '.</span>' +
            '<span style="flex:1;font-size:12px;">' + escHtml(labelFor(v)) + '</span>' +
            '<button class="action-btn" style="padding:1px 7px;" onclick="moveCascade(' + idx + ',-1)" ' + (idx===0?'disabled':'') + '>↑</button>' +
            '<button class="action-btn" style="padding:1px 7px;" onclick="moveCascade(' + idx + ',1)" ' + (idx===order.length-1?'disabled':'') + '>↓</button>' +
            '</div>').join('') +
        '<div style="text-align:right;margin-top:8px;"><button class="action-btn" style="background:var(--accent-blue);color:#fff;padding:4px 12px;" onclick="saveCascadeOrder()">Save order</button></div>';
}
async function saveCascadeOrder() {
    try {
        const r = await fetch('workers.php?action=set_cascade_order', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ order: _cascadeOrder }),
        });
        const d = await r.json();
        if (d && d.ok) appendSystem(T('msg.cascade.priority.saved', 'Cascade priority saved.'));
        else appendSystem(T('msg.save.failed.d', 'Save failed: {d}', {d: ((d && d.error) || 'unknown')}));
    } catch(e) { appendSystem(T('msg.save.error.message', 'Save error: {message}', {message: e.message})); }
}

// Provider-list sort (Workers card). Reorders the .worker-provider blocks in
// #workers-list; the cascade/paid panels aren't .worker-provider so they stay
// pinned on top. Mode persists so a settings refresh (full re-render) keeps it.
let _workersSortMode = 'default';
function sortWorkersList(sel) { if (sel) _workersSortMode = sel.value; _applyWorkersSort(); }
function _applyWorkersSort() {
    const list = document.getElementById('workers-list');
    if (!list) return;
    const items = [...list.querySelectorAll(':scope > .worker-provider')];
    if (items.length < 2) return;
    items.forEach((el, i) => { if (el.dataset.oi === undefined) el.dataset.oi = i; });
    const name = el => el.dataset.name || '';
    const num  = (el, k) => +(el.dataset[k] || 0);
    const mode = _workersSortMode;
    const cmp = mode === 'alpha'   ? (a, b) => name(a).localeCompare(name(b))
              : mode === 'free'    ? (a, b) => num(b, 'free') - num(a, 'free')       || name(a).localeCompare(name(b))
              : mode === 'enabled' ? (a, b) => num(b, 'enabled') - num(a, 'enabled') || name(a).localeCompare(name(b))
              : mode === 'used'    ? (a, b) => num(b, 'calls') - num(a, 'calls')     || name(a).localeCompare(name(b))
              : (a, b) => num(a, 'oi') - num(b, 'oi');
    items.sort(cmp);
    items.forEach(el => list.appendChild(el));
}
function workersRenderProvider(p) {
    const usage = p.usage || {};
    const calls = usage.calls || 0;
    const errs  = usage.errors || 0;
    const tokIn = usage.tokens_in || 0;
    const tokOut= usage.tokens_out || 0;
    const lastCall = usage.last_call_at ? shortDate(usage.last_call_at) : 'never';

    const keyState = p.type === 'webworker' ? '<span style="color:var(--accent-cyan);">web page — no key, experimental</span>'
        : p.no_key_required
        ? '<span style="color:var(--accent-cyan);">CLI — no key needed</span>'
        : p.key_set
        ? '<span style="color:var(--accent-green);">key set</span>'
        : '<span style="color:var(--claude);">no key</span>';

    // Paid providers are gated: while the global master is OFF, the enable toggle
    // is disabled with an explanatory note (protanopia-safe: text + amber, no red).
    const _paidLocked = p.incurs_cost && !_workersSettings.allow_paid_api_spend;
    const enabledToggle = _paidLocked
        ? `<button class="plan-tb-btn" disabled title="Enable paid API spend in Settings first" style="opacity:0.5;cursor:not-allowed;">
              <span class="material-symbols-rounded">lock</span> Enable paid spend first
           </button>`
        : p.enabled
        ? `<button class="plan-tb-btn" onclick="workersToggleProvider('${p.id}', false)" style="background:rgba(91,143,212,0.2);">
              <span class="material-symbols-rounded">toggle_on</span> Enabled
           </button>`
        : `<button class="plan-tb-btn" onclick="workersToggleProvider('${p.id}', true)">
              <span class="material-symbols-rounded">toggle_off</span> Disabled
           </button>`;

    // Phase 2b 2026-05-10 — per-model chips, click-to-SELECT for testing.
    // The selected model is what the Test button (next to Save) operates on.
    // Default selection is the first free+text model (matching backend
    // default behavior); user can override by clicking a different chip.
    // Selection is persisted in localStorage per-provider so it survives
    // reloads.
    const _selectedModel = workersGetTestSelection(p.id, p.models || []);
    const modelsList = (p.models || []).map(m => {
        const removable  = !!m.user_added;
        const isSelected = m.id === _selectedModel;
        const chipColor  = m.kinds && m.kinds[0] ? `cap-${m.kinds[0]}` : 'cap-text';
        // Visual: selected chip gets a ring (border) in workers accent;
        // unselected chips get default (transparent border, hover effect)
        const chipStyle = isSelected
            ? 'display:inline-flex;align-items:center;gap:4px;padding:2px 5px;cursor:pointer;'+
              'border:1.5px solid var(--workers);box-shadow:0 0 0 1px var(--workers-dim) inset;'+
              'transition:all 0.12s;'
            : 'display:inline-flex;align-items:center;gap:4px;padding:2px 5px;cursor:pointer;'+
              'border:1.5px solid transparent;transition:all 0.12s;';
        const hoverIn  = isSelected ? '' : 'this.style.borderColor=\'var(--border-bright)\';';
        const hoverOut = isSelected ? '' : 'this.style.borderColor=\'transparent\';';
        const tooltip  = isSelected ? 'Selected as test target' : 'Click to select for testing';

        return `<span class="cap-agent-badge ${chipColor}"
                      title="${tooltip} — ${escapeHtml(m.id)}"
                      data-model-id="${escapeHtml(m.id)}"
                      onclick="workersSelectTestModel('${p.id}', this.dataset.modelId, event)"
                      onmouseover="${hoverIn}"
                      onmouseout="${hoverOut}"
                      style="${chipStyle}">
            ${escapeHtml(m.label || m.id)}${m.free ? ' (free)' : ''}
            ${removable ? `<button onclick="event.stopPropagation();workersRemoveModel('${p.id}','${escapeHtml(m.id)}')"
                                  title="Remove this user-added model"
                                  style="background:none;border:none;color:inherit;cursor:pointer;
                                         padding:0 2px;font-size:13px;line-height:1;opacity:0.6;"
                                  onmouseover="event.stopPropagation();this.style.opacity=1;this.style.color='var(--ollama)';"
                                  onmouseout="event.stopPropagation();this.style.opacity=0.6;this.style.color='inherit';">×</button>` : ''}
         </span>`;
    }).join(' ');

    // Phase 2b — × on the provider header for custom (user-added) providers
    const providerCustomBadge = p.custom
        ? '<span class="cap-builtin-badge" style="background:rgba(91,143,212,0.15);color:var(--gemini);font-size:9px;">custom</span>'
        : '';
    const deleteProviderBtn = p.custom
        ? `<button class="plan-tb-btn" onclick="workersDeleteProvider('${p.id}')"
                  title="Delete this custom provider entirely"
                  style="background:rgba(212,73,73,0.1);">
              <span class="material-symbols-rounded">delete</span> Delete
           </button>`
        : '';

    // Phase 2b — Test button next to Save (only when key is set)
    // Phase 2b 2026-05-10 — Test button now tests the *selected* model
    // (chosen via clicking a chip). Tooltip shows which model will be tested.
    const _testTargetLabel = (() => {
        const m = (p.models || []).find(m => m.id === _selectedModel);
        return m ? (m.label || m.id) : '(no model selected)';
    })();
    const testBtn = p.key_set
        ? `<button class="plan-tb-btn" onclick="workersTestKey('${p.id}')"
                  title="Test the selected model: ${escapeHtml(_testTargetLabel)}">
              <span class="material-symbols-rounded">science</span> Test
           </button>`
        : `<button class="plan-tb-btn" disabled
                  title="Save an API key first to enable testing"
                  style="opacity:0.45;cursor:not-allowed;">
              <span class="material-symbols-rounded">science</span> Test
           </button>`;

    return `
    <div class="worker-provider" data-name="${escapeHtml((p.name||'').toLowerCase())}" data-free="${p.free ? 1 : 0}" data-enabled="${p.enabled ? 1 : 0}" data-calls="${calls}" style="border:1px solid var(--border-dim);border-radius:4px;padding:10px;background:var(--bg-darker);">
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
            <h3 style="margin:0;font-size:12px;color:var(--text-primary);flex:1;">
                ${escapeHtml(p.name)} ${p.free ? '<span style="font-size:9.5px;color:var(--accent-green);font-weight:400;">FREE TIER</span>' : ''} ${p.incurs_cost ? '<span title="Costs real money per call (BYOK)" style="font-size:9px;color:var(--accent-amber);font-weight:700;border:1px solid var(--accent-amber);border-radius:3px;padding:0 4px;"><span class="material-symbols-rounded ico">attach_money</span> PAID API</span>' : ''} ${providerCustomBadge}
            </h3>
            <span style="font-size:9.5px;">${keyState}</span>
            ${enabledToggle}
            ${deleteProviderBtn}
        </div>
        <div style="font-size:10px;color:var(--text-dim);margin-bottom:6px;">
            ${p.kinds ? '<b>Supports:</b> ' + p.kinds.join(', ') + ' &middot; ' : ''}
            ${p.website ? `<a href="${p.website}" target="_blank" style="color:var(--gemini);">${escapeHtml(p.website.replace(/^https?:\/\//,''))}</a>` : ''}
        </div>
        ${p.limits ? `<div style="font-size:9.5px;color:var(--text-muted);margin-bottom:6px;">
            ${p.limits.free_tier ? '<b>Free tier:</b> ' + escapeHtml(p.limits.free_tier) + '<br>' : ''}
            ${p.limits.rate_window ? '<b>Rate:</b> ' + escapeHtml(p.limits.rate_window) : ''}
        </div>` : ''}
        <div style="font-size:9.5px;margin-bottom:8px;display:flex;flex-wrap:wrap;gap:4px;align-items:center;">
            ${modelsList}
            <button class="plan-tb-btn" onclick="workersOpenAddModelDialog('${p.id}')"
                    title="Add a model to ${escapeHtml(p.name)}"
                    style="font-size:10px;padding:3px 8px;">
                <span class="material-symbols-rounded" style="font-size:13px;">add</span> Add model
            </button>
        </div>

        <div style="display:${p.no_key_required ? 'none' : 'flex'};gap:6px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
            <input type="password" id="key-input-${p.id}" placeholder="Paste API key here…"
                   style="flex:1;min-width:240px;background:var(--bg-base);border:1px solid var(--border-dim);
                          color:var(--text-base);font-size:11px;padding:4px 8px;border-radius:3px;
                          font-family:var(--font-mono);">
            <button class="plan-tb-btn" onclick="workersSetKey('${p.id}')">
                <span class="material-symbols-rounded">save</span> Save
            </button>
            ${testBtn}
            ${p.key_set ? `<button class="plan-tb-btn" onclick="workersClearKey('${p.id}')" title="Remove stored key">
                <span class="material-symbols-rounded">delete</span>
            </button>` : ''}
            ${p.key_url ? `<a href="${p.key_url}" target="_blank" class="plan-tb-btn" style="text-decoration:none;color:var(--text-base);">
                <span class="material-symbols-rounded">open_in_new</span> Get key
            </a>` : ''}
        </div>
        ${p.type === 'webworker' ? `<div style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px;">
            <button class="plan-tb-btn" onclick="workersWwAction('${p.id}','ww_show')" title="Bring the site's window on screen (to log in, or to see what it does)"><span class="material-symbols-rounded">visibility</span> Open window</button>
            <button class="plan-tb-btn" onclick="workersWwAction('${p.id}','ww_hide')" title="Put the window away again"><span class="material-symbols-rounded">visibility_off</span> Hide</button>
            <button class="plan-tb-btn" onclick="workersWwAction('${p.id}','ww_test')" title="Sends a fixed question through the page and checks the answer: tells you when the site changed and the adapter broke"><span class="material-symbols-rounded">check_circle</span> Self-test</button>
            <button class="plan-tb-btn" onclick="workersWwAction('${p.id}','ww_probe')" title="Describes the page (boxes, buttons) into the prompt box, so the adapter can be fixed"><span class="material-symbols-rounded">search</span> Probe</button>
        </div>` : ''}
        ${p.key_help ? `<div style="font-size:9.5px;color:var(--text-muted);font-style:italic;margin-bottom:6px;">${escapeHtml(p.key_help)}</div>` : ''}

        <div style="font-size:9.5px;color:var(--text-dim);border-top:1px solid var(--border-dim);padding-top:6px;
                    display:flex;gap:12px;flex-wrap:wrap;">
            <span><b>Usage:</b> ${calls} calls (${errs} errors)</span>
            <span><b>Tokens:</b> ${tokIn.toLocaleString()} in / ${tokOut.toLocaleString()} out</span>
            <span><b>Last:</b> ${lastCall}</span>
            <span style="margin-left:auto;">
                <button class="plan-tb-btn" onclick="workersResetUsage('${p.id}')" title="Reset usage counters">
                    <span class="material-symbols-rounded">restart_alt</span> Reset
                </button>
            </span>
        </div>
    </div>`;
}

// Web page workers: show / hide the site's window, self-test, probe.
async function workersWwAction(pid, act) {
    const post = async () => (await (await fetch('workers.php?action=' + act, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ provider: pid }) })).json());
    try {
        if (act === 'ww_test') appendSystem(T('msg.ww.testing', 'Testing {id}: a question goes through the page, this can take up to a minute…', { id: pid }));
        if (act === 'ww_probe') appendSystem(T('msg.ww.probing', 'Looking at the page of {id}…', { id: pid }));
        const d = await post();
        if (act === 'ww_test') appendSystem(d.status === 'ok' ? T('msg.ww.test.ok', '{id}: the page answers. Works.', { id: pid })
            : T('msg.ww.test.bad', '{id}: {status} — {detail}', { id: pid, status: d.status || 'error', detail: d.detail || d.error || '' }));
        else if (act === 'ww_probe') {
            if (!d.ok) { appendSystem(T('msg.ww.probe.bad', 'Probe failed: {error}', { error: d.error || '' })); return; }
            const ta = document.getElementById('prompt-in');
            if (ta) { ta.value = 'The adapter for ' + pid + ' needs tuning. This is what its page looks like (from the Probe button):\n\n' + JSON.stringify(d, null, 1).slice(0, 6000) + '\n\nPick the selectors for the prompt box, the send button, the answer blocks and the "still writing" indicator, and update the adapter in workers_providers.json.'; if (typeof ta.oninput === 'function') ta.oninput(); }
            appendSystem(T('msg.ww.probe.ok', 'The page description is in the prompt box.'));
        } else if (!d.ok) appendSystem(T('msg.ww.err', 'Web worker: {error}', { error: d.error || '' }));
    } catch (e) { appendSystem(T('msg.ww.err', 'Web worker: {error}', { error: e.message })); }
}
async function workersSetKey(pid) {
    const inp = document.getElementById('key-input-' + pid);
    if (!inp) return;
    const key = inp.value.trim();
    if (!key) { appendError(T('msg.paste.a.key.first', 'Paste a key first.')); return; }
    try {
        const r = await fetch('workers.php?action=set_key', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid, key}),
        });
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error||'')})); return; }
        inp.value = '';
        appendSystem(T('msg.api.key.saved.for.pid.encrypted.at.rest', 'API key saved for {pid} (encrypted at rest)', {pid: pid}));
        workersRefreshSettings();
    } catch(e) {
        appendError(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message}));
    }
}

async function workersClearKey(pid) {
    if (!await cockpitConfirm('Remove API key?', 'Remove stored API key for ' + pid + '?', 'Remove', {danger:true, icon:'key_off'})) return;
    try {
        await fetch('workers.php?action=clear_key', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid}),
        });
        appendSystem(T('msg.api.key.cleared.for.pid', 'API key cleared for {pid}', {pid: pid}));
        workersRefreshSettings();
    } catch(e) {
        appendError(T('msg.clear.failed.message', 'Clear failed: {message}', {message: e.message}));
    }
}

async function workersToggleProvider(pid, enabled) {
    try {
        await fetch('workers.php?action=enable_provider', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid, enabled}),
        });
        appendSystem(pid + ' ' + (enabled ? 'enabled' : 'disabled'));
        workersRefreshSettings();
        workersLoadModels();
    } catch(e) {
        appendError(T('msg.toggle.failed.message', 'Toggle failed: {message}', {message: e.message}));
    }
}

async function workersResetUsage(pid) {
    if (!await cockpitConfirm('Reset usage?', 'Reset usage counters for ' + pid + '?', 'Reset', {danger:true, icon:'restart_alt'})) return;
    try {
        await fetch('workers.php?action=reset_usage', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid}),
        });
        workersRefreshSettings();
        workersUpdateMeter();
    } catch(e) {
        appendError(T('msg.reset.failed.message', 'Reset failed: {message}', {message: e.message}));
    }
}

async function workersResetAllUsage() {
    if (!await cockpitConfirm('Reset all usage?', 'Reset usage counters for ALL workers?', 'Reset', {danger:true, icon:'restart_alt'})) return;
    try {
        const r = await fetch('workers.php?action=providers');
        const d = await r.json();
        for (const p of (d.providers || [])) {
            if (p.usage && p.usage.calls > 0) {
                await fetch('workers.php?action=reset_usage', {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({provider: p.id}),
                });
            }
        }
        workersUpdateMeter();
        appendSystem(T('msg.all.workers.usage.counters.reset', 'All workers usage counters reset'));
    } catch(e) {
        appendError(T('msg.reset.failed.message', 'Reset failed: {message}', {message: e.message}));
    }
}

// Update the topbar Workers meter with aggregate usage
async function workersUpdateMeter() {
    try {
        const r = await fetch('workers.php?action=usage');
        const d = await r.json();
        if (!d.ok) return;
        let calls = 0, tokIn = 0, tokOut = 0, providers = 0;
        for (const [pid, u] of Object.entries(d.usage || {})) {
            calls  += u.calls       || 0;
            tokIn  += u.tokens_in   || 0;
            tokOut += u.tokens_out  || 0;
            if ((u.calls||0) > 0) providers++;
        }
        const cv = document.getElementById('workers-calls-val');
        const pv = document.getElementById('workers-providers-val');
        const bar = document.getElementById('workers-bar');
        if (cv) cv.textContent = calls + ' calls · ' + (tokIn+tokOut).toLocaleString() + ' tok';
        if (pv) pv.textContent = providers + ' active provider' + (providers === 1 ? '' : 's');
        // Bar shows token usage relative to a soft max of 100K (informational only)
        if (bar) bar.style.width = Math.min(100, ((tokIn+tokOut) / 1000)) + '%';
    } catch(e) {}
}

// =============================================================================

// ── Models and prices: the signed catalog feed (catalog_feed.php, catalog_feed_lib.php). OFF by default: nothing is fetched until the person switches it on.
let _catalogFeed = null;
async function _catalogFeedLoad() {
    try {
        const d = await (await fetch('catalog_feed.php?action=status')).json(); _catalogFeed = d && d.ok ? d : null;
        // once-a-day automatic check, only if switched on AND automatic
        if (_catalogFeed && _catalogFeed.enabled && _catalogFeed.auto) {
            const last = _catalogFeed.last_check ? Date.parse(_catalogFeed.last_check) : 0;
            if (!last || Date.now() - last > 86400000) { const c = await (await fetch('catalog_feed.php?action=check', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).json(); if (c && c.ok) _catalogFeed = c; }
        }
    } catch (e) { _catalogFeed = null; }
}
function _workersCatalogPanelHtml() {
    const c = _catalogFeed; if (!c) return '';
    const age = c.age_days, stale = !!c.stale;
    const when = c.as_of ? (c.as_of + (age !== null ? ' (' + age + ' day' + (age === 1 ? '' : 's') + ' old)' : '')) : T('ui.catalog.nodate', 'no date');
    const sugg = (c.suggestions || []).map((s, i) => '<div style="display:flex;gap:8px;align-items:center;font-size:11px;margin-top:4px;"><span class="material-symbols-rounded" style="font-size:14px;color:var(--accent-cyan);">add_circle</span>' +
        '<span><b>' + escapeHtml(s.name || s.id) + '</b> <span style="color:var(--text-muted);font-family:var(--font-mono);">' + escapeHtml(s.base_url) + '</span></span>' +
        '<button class="action-btn" style="margin-left:auto;padding:2px 10px;" title="' + escapeHtml(T('ui.catalog.suggest.tip', 'Adds this supplier as a custom one. Your API key for it is sent to the address shown, so check it first.')) + '" onclick="workersAddSuggested(' + i + ')">' + T('ui.catalog.add', 'Add') + '</button></div>').join('');
    return '<div id="workers-catalog-panel" style="border:1px solid ' + (stale ? 'var(--accent-amber)' : 'var(--border-mid)') + ';border-radius:5px;padding:10px 12px;margin-bottom:12px;background:var(--bg-darker);">' +
        '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">' +
            '<span class="material-symbols-rounded" style="color:' + (stale ? 'var(--accent-amber)' : 'var(--accent-cyan)') + ';font-size:16px;">update</span>' +
            '<b style="font-size:12px;">' + T('ui.catalog.title', 'Models and prices') + '</b>' +
            '<span style="font-size:11px;' + (stale ? 'color:var(--accent-amber);font-weight:700;' : 'color:var(--text-muted);') + '" title="' + escapeHtml(T('ui.catalog.asof.tip', 'The date the model lists and prices in this install were last brought up to date.')) + '">' + T('ui.catalog.asof', 'as of') + ' ' + escapeHtml(when) + '</span>' +
            '<span style="margin-left:auto;font-size:11px;font-weight:700;color:' + (c.enabled ? 'var(--accent-cyan)' : 'var(--text-muted)') + ';">' + (c.enabled ? T('ui.catalog.feed.on', 'FEED ON') : T('ui.catalog.feed.off', 'FEED OFF')) + '</span>' +
            '<button class="action-btn" style="padding:3px 10px;" onclick="workersCatalogToggle(' + (!c.enabled) + ')">' + (c.enabled ? T('ui.catalog.turnoff', 'Turn OFF') : T('ui.catalog.turnon', 'Turn ON…')) + '</button>' +
            (c.enabled ? '<button class="action-btn" style="padding:3px 10px;" onclick="workersCatalogCheck()">' + T('ui.catalog.check', 'Check now') + '</button>' : '') +
        '</div>' +
        (stale ? '<div style="font-size:11px;color:var(--accent-amber);margin-top:6px;">' + T('ui.catalog.stale', 'These lists are older than {n} days: new models may be missing and prices may have changed. Check the supplier\'s own pricing page before relying on a cap.', { n: c.stale_after_days }) + '</div>' : '') +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-top:6px;">' + T('ui.catalog.explain', 'With the feed ON, Cockpit fetches one small file the maker signs (cockpit.ruggi.site; no account data, nothing that identifies you) and adds new models and prices to the lists below. The signature is checked on your machine; a file that does not verify is ignored. It can never change a supplier\'s address or touch your keys, and your own additions always win. OFF: nothing is ever fetched.') + '</div>' +
        (c.enabled ? '<label style="font-size:11px;display:inline-flex;gap:6px;align-items:center;margin-top:6px;"><input type="checkbox" ' + (c.auto ? 'checked' : '') + ' onchange="workersCatalogAuto(this.checked)"> ' + T('ui.catalog.auto', 'Check once a day automatically') + '</label>' : '') +
        (c.last_result ? '<div style="font-size:10.5px;color:var(--text-muted);margin-top:4px;">' + T('ui.catalog.last', 'Last check') + ': ' + escapeHtml(String(c.last_check || '').replace('T', ' ').slice(0, 16)) + ' — ' + escapeHtml(c.last_result) + '</div>' : '') +
        (c.enabled && !c.can_verify ? '<div style="font-size:11px;color:var(--accent-orange);margin-top:6px;">' + T('ui.catalog.noverify', 'This install cannot check signatures (the PHP sodium module or the public key is missing), so the feed cannot be used.') + '</div>' : '') +
        (sugg ? '<div style="margin-top:8px;border-top:1px solid var(--border-dim);padding-top:6px;"><div style="font-size:11px;font-weight:600;">' + T('ui.catalog.suggest', 'New suppliers you can add') + '</div>' + sugg + '</div>' : '') +
    '</div>';
}
async function workersCatalogToggle(on) {
    if (on && !await cockpitConfirm(T('ui.catalog.confirm.title', 'Turn on the catalog feed?'), T('ui.catalog.confirm.body', 'Cockpit will fetch one small signed file from cockpit.ruggi.site to learn about new models and prices. No account data and nothing that identifies you is sent. You can turn it off again at any time.'), T('ui.catalog.turnon.short', 'Turn on'), { icon: 'update' })) return;
    await fetch('catalog_feed.php?action=set', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ enabled: !!on }) });
    if (on) await fetch('catalog_feed.php?action=check', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    await workersRefreshSettings();
}
async function workersCatalogAuto(on) { await fetch('catalog_feed.php?action=set', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ auto: !!on }) }); await workersRefreshSettings(); }
async function workersCatalogCheck() {
    const d = await (await fetch('catalog_feed.php?action=check', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' })).json();
    if (d && d.ok === false && d.error) appendError(T('msg.catalog.check.failed', 'Catalog check failed: {error}', { error: d.error }));
    await workersRefreshSettings();
}
async function workersAddSuggested(i) {
    const s = (_catalogFeed && _catalogFeed.suggestions || [])[i]; if (!s) return;
    if (!await cockpitConfirm(T('ui.catalog.add.title', 'Add this supplier?'), T('ui.catalog.add.body', '{name} at {url}. Your API key for it (added afterwards) is sent to that address, so check it is the supplier\'s real one.', { name: s.name || s.id, url: s.base_url }), T('ui.catalog.add', 'Add'), { icon: 'add_circle' })) return;
    const models = (s.models || []).map(m => ({ id: m.id, label: m.label || m.id, kinds: m.kinds || ['text'], free: !!m.free, pricing: m.pricing })).filter(m => m.id);
    const r = await (await fetch('workers.php?action=add_custom', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ provider: s.id, name: s.name || s.id, base: s.base, base_url: s.base_url, website: s.website || null, models }) })).json();
    if (!r.ok) { appendError(T('msg.catalog.add.failed', 'Could not add the supplier: {error}', { error: r.error || '' })); return; }
    appendSystem(T('msg.catalog.added', 'Supplier "{name}" added. Add your key for it in the list below.', { name: s.name || s.id }));
    await workersRefreshSettings();
}