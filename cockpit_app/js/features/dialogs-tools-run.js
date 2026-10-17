// Phase 2b 2026-05-09 — Add/Remove/Test dialogs for Workers and Tools
// =============================================================================
// Generic modal infrastructure (kept tiny; each dialog builds its own form)
// plus the specific handlers for: Add Provider, Add Model, Remove Provider,
// Remove Model, Test Key (Workers); Add Tool, Add Preset, Remove Tool,
// Remove Preset, Test Binary (Tools).
//
// Design notes:
// - All dialogs render into the same #cockpit-form-modal element
// - Submission goes through fetch() to the right backend; on success we
//   refresh the parent modal (workersOpenSettings or toolsOpenSettings)
// - "Kinds" selector is multi-select with "+ add new kind" option that
//   stores user-defined kinds in localStorage.cockpit_custom_kinds
// =============================================================================

// Default + user-customized kinds, with + add new kind support
const STD_WORKER_KINDS = ['text','code','translate','summary','image','image-gen','audio','vision'];
const STD_TOOL_KINDS   = ['text','document','image','audio','video','data','file'];

function _customKindsLoad() {
    try { return JSON.parse(localStorage.getItem('cockpit_custom_kinds') || '[]'); }
    catch(e) { return []; }
}
function _customKindsSave(arr) {
    try { localStorage.setItem('cockpit_custom_kinds', JSON.stringify(arr)); } catch(e) {}
}
function _allKinds(stdSet) {
    const custom = _customKindsLoad();
    return [...stdSet, ...custom.filter(k => !stdSet.includes(k))];
}

// Generic modal show/hide helpers — uses #cockpit-form-modal which we
// inject into the document on first call (so it doesn't sit in DOM
// otherwise).
function _formModalShow(titleHtml, bodyHtml, onSubmit) {
    let modal = document.getElementById('cockpit-form-modal');
    if (!modal) {
        modal = document.createElement('div');
        modal.id = 'cockpit-form-modal';
        modal.style.cssText = 'display:none;position:fixed;inset:0;z-index:10000;'+
            'background:rgba(0,0,0,0.65);align-items:center;justify-content:center;'+
            'font-family:var(--font-ui);';
        document.body.appendChild(modal);
        modal.addEventListener('click', e => {
            if (e.target === modal) _formModalHide();
        });
    }
    modal.innerHTML = `
    <div style="background:var(--bg-base);border:1px solid var(--border-mid);
         border-radius:6px;width:min(560px, 92vw);max-height:88vh;overflow:auto;
         padding:14px 18px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">
        <div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);
             padding-bottom:6px;margin-bottom:10px;">
            <h3 style="margin:0;font-size:13px;color:var(--text-primary);flex:1;">${titleHtml}</h3>
            <button class="action-btn" onclick="_formModalHide()" style="padding:3px 9px;font-size:11px;">×</button>
        </div>
        <div id="cockpit-form-body">${bodyHtml}</div>
        <div id="cockpit-form-status" style="font-size:10px;color:var(--text-muted);margin-top:8px;min-height:14px;"></div>
        <div style="display:flex;justify-content:flex-end;gap:6px;margin-top:10px;
             border-top:1px solid var(--border-dim);padding-top:10px;">
            <button class="plan-tb-btn" onclick="_formModalHide()">Cancel</button>
            <button class="plan-tb-btn" onclick="_formModalSubmit()" id="form-submit-btn"
                    style="background:rgba(91,143,212,0.2);color:var(--text-primary);">
                Save
            </button>
        </div>
    </div>`;
    modal.style.display = 'flex';
    window._formModalSubmit = onSubmit;
}
function _formModalHide() {
    const modal = document.getElementById('cockpit-form-modal');
    if (modal) modal.style.display = 'none';
    window._formModalSubmit = null;
}
function _formModalStatus(msg, isError) {
    const el = document.getElementById('cockpit-form-status');
    if (el) {
        el.textContent = msg || '';
        el.style.color = isError ? 'var(--ollama)' : 'var(--accent-green)';
    }
}

// Multi-select kinds widget — renders as a list of checkboxes plus a
// small "+ add new kind" inline input. Returns selected kinds via
// _formCollectKinds(elementId).
function _formKindsWidget(elementId, stdSet, preselected) {
    const all = _allKinds(stdSet);
    const sel = new Set(preselected || []);
    let html = `<div id="${elementId}" style="display:flex;flex-wrap:wrap;gap:4px;
                background:var(--bg-darker);border:1px solid var(--border-dim);
                border-radius:3px;padding:5px 6px;">`;
    for (const k of all) {
        const checked = sel.has(k) ? 'checked' : '';
        html += `<label style="display:inline-flex;align-items:center;gap:3px;font-size:10.5px;
                 padding:2px 5px;background:var(--bg-base);border-radius:3px;cursor:pointer;
                 white-space:nowrap;">
            <input type="checkbox" data-kind="${escapeHtml(k)}" ${checked}
                   style="margin:0;cursor:pointer;">
            ${escapeHtml(k)}
        </label>`;
    }
    html += `<button onclick="_formAddNewKind('${elementId}', ${JSON.stringify(stdSet).replace(/"/g,'&quot;')})"
                     class="plan-tb-btn" style="font-size:10px;padding:2px 6px;">
        <span class="material-symbols-rounded" style="font-size:12px;">add</span> new kind
    </button>`;
    html += `</div>`;
    return html;
}
function _formCollectKinds(elementId) {
    const el = document.getElementById(elementId);
    if (!el) return [];
    return Array.from(el.querySelectorAll('input[type=checkbox]:checked'))
                .map(cb => cb.dataset.kind);
}
async function _formAddNewKind(widgetId, stdSetJson) {
    const stdSet = (typeof stdSetJson === 'string') ? JSON.parse(stdSetJson) : stdSetJson;
    const newKind = await cprompt('Add a new kind name (alphanumeric, dashes, underscores; ≤32 chars):');
    if (!newKind) return;
    const cleaned = String(newKind).toLowerCase().trim();
    if (!/^[a-z0-9_-]{1,32}$/.test(cleaned)) {
        appendSystem(T('msg.invalid.kind.name.use.a.z.0.9.dash.underscor', 'Invalid kind name. Use a-z, 0-9, dash, underscore, max 32 chars.'));
        return;
    }
    const customs = _customKindsLoad();
    if (!customs.includes(cleaned) && !stdSet.includes(cleaned)) {
        customs.push(cleaned);
        _customKindsSave(customs);
    }
    // Re-render the widget by reaching into its parent and replacing innerHTML
    const widget = document.getElementById(widgetId);
    if (widget) {
        const currentlySelected = _formCollectKinds(widgetId);
        currentlySelected.push(cleaned);
        widget.outerHTML = _formKindsWidget(widgetId, stdSet, currentlySelected);
    }
}

// ─── WORKERS — Add Provider dialog ──────────────────────────────────────────
async function workersOpenAddProviderDialog() {
    // Need the list of base providers to choose from — fetch fresh
    let baseOptions = '';
    try {
        const r = await fetch('workers.php?action=providers');
        const d = await r.json();
        if (d.ok) {
            // Only allow basing on shipped providers (custom-on-custom gets weird)
            baseOptions = (d.providers || [])
                .filter(p => !p.custom)
                .map(p => `<option value="${escapeHtml(p.id)}">${escapeHtml(p.name)} (API shape)</option>`)
                .join('');
        }
    } catch(e) {}

    const body = `
    <div style="font-size:10.5px;color:var(--text-dim);margin-bottom:8px;">
        A custom supplier speaks the API of an existing one (its "shape", usually OpenAI's) at its own address.
        E.g. "Llama Cloud" might use the OpenAI protocol at https://api.llama.example/v1. Your key for it is added afterwards, like any other.
    </div>
    <div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:center;font-size:11px;">
        <span>ID:</span>
        <input id="ap-id" placeholder="my-provider" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
        <span>Name:</span>
        <input id="ap-name" placeholder="My Provider" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Base shape:</span>
        <select id="ap-base"
                style="background:var(--bg-darker);border:1px solid var(--border-dim);
                       color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
            ${baseOptions}
        </select>
        <span>Address:</span>
        <input id="ap-baseurl" placeholder="https://api.example.com/v1" autocomplete="off" title="The base address of its API (https; plain http only for this machine or a private network). Your API key is sent to this address."
               style="background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;font-family:var(--font-mono);">
        <span>Website:</span>
        <input id="ap-website" placeholder="https://… (optional)" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
    </div>
    <div style="margin-top:10px;font-size:11px;">
        <div style="margin-bottom:4px;color:var(--text-muted);">First model:</div>
        <div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:center;">
            <span>Model ID:</span>
            <input id="ap-mid" placeholder="model/id-as-the-API-expects" autocomplete="off"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                          font-family:var(--font-mono);">
            <span>Label:</span>
            <input id="ap-mlabel" placeholder="My Model 7B" autocomplete="off"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
            <span>Free?</span>
            <label style="font-size:11px;">
                <input id="ap-mfree" type="checkbox"> &nbsp;Yes — has a free-tier individual quota
            </label>
        <span>Price (USD):</span>
        <span style="display:flex;gap:6px;align-items:center;">
            <input id="ap-m-pin" type="number" min="0" step="any" placeholder="input / 1M tokens" title="Optional. Price per million INPUT tokens, in US dollars. With a price, a monthly cap can protect you on this model." style="width:50%;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
            <input id="ap-m-pout" type="number" min="0" step="any" placeholder="output / 1M tokens" title="Optional. Price per million OUTPUT tokens, in US dollars." style="width:50%;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        </span>
        </div>
        <div style="margin-top:6px;font-size:10.5px;color:var(--text-muted);">Kinds (which task types this model handles):</div>
        ${_formKindsWidget('ap-mkinds', STD_WORKER_KINDS, ['text'])}
    </div>`;

    _formModalShow('Add Custom Provider', body, async () => {
        const id      = document.getElementById('ap-id').value.trim();
        const name    = document.getElementById('ap-name').value.trim();
        const base    = document.getElementById('ap-base').value;
        const website = document.getElementById('ap-website').value.trim();
        const mid     = document.getElementById('ap-mid').value.trim();
        const mlabel  = document.getElementById('ap-mlabel').value.trim() || mid;
        const mfree   = document.getElementById('ap-mfree').checked;
        const baseUrl = document.getElementById('ap-baseurl').value.trim();
        const pin = document.getElementById('ap-m-pin').value, pout = document.getElementById('ap-m-pout').value;
        const pricing = (pin !== '' && pout !== '') ? { input_per_mtok: +pin, output_per_mtok: +pout } : null;
        const kinds   = _formCollectKinds('ap-mkinds');

        if (!id || !name || !base || !baseUrl || !mid || !kinds.length) {
            _formModalStatus('All fields required (id, name, base shape, address, model id, at least one kind).', true);
            return;
        }
        _formModalStatus('Saving…');
        try {
            const r = await fetch('workers.php?action=add_custom', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    provider: id, name, base, base_url: baseUrl, website: website || null,
                    models: [Object.assign({id: mid, label: mlabel, kinds, free: mfree}, pricing ? {pricing} : {})],
                }),
            });
            const d = await r.json();
            if (!d.ok) { _formModalStatus('Error: ' + (d.error || 'failed'), true); return; }
            _formModalStatus('Saved.', false);
            await workersOpenSettings();
            setTimeout(_formModalHide, 400);
        } catch(e) {
            _formModalStatus('Network error: ' + e.message, true);
        }
    });
}

// ─── WORKERS — Add Model dialog ─────────────────────────────────────────────
function workersOpenAddModelDialog(providerId) {
    const body = `
    <div style="font-size:10.5px;color:var(--text-dim);margin-bottom:8px;">
        Adding a model to provider <b>${escapeHtml(providerId)}</b>.
        The Model ID must match exactly what the provider's API expects.
    </div>
    <div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:center;font-size:11px;">
        <span>Model ID:</span>
        <input id="am-id" placeholder="e.g. openai/gpt-oss-120b" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
        <span>Label:</span>
        <input id="am-label" placeholder="GPT-OSS 120B" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Free?</span>
        <label style="font-size:11px;">
            <input id="am-free" type="checkbox"> &nbsp;Yes — usable on this provider's free tier
        </label>
        <span>Price (USD):</span>
        <span style="display:flex;gap:6px;align-items:center;">
            <input id="am-pin" type="number" min="0" step="any" placeholder="input / 1M tokens" title="Optional. Price per million INPUT tokens, in US dollars. With a price, a monthly cap can protect you on this model." style="width:50%;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
            <input id="am-pout" type="number" min="0" step="any" placeholder="output / 1M tokens" title="Optional. Price per million OUTPUT tokens, in US dollars." style="width:50%;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        </span>
    </div>
    <div style="margin-top:8px;font-size:10.5px;color:var(--text-muted);">Kinds (which task types this model handles):</div>
    ${_formKindsWidget('am-kinds', STD_WORKER_KINDS, ['text'])}`;

    _formModalShow('Add Model to ' + escapeHtml(providerId), body, async () => {
        const mid    = document.getElementById('am-id').value.trim();
        const label  = document.getElementById('am-label').value.trim() || mid;
        const free   = document.getElementById('am-free').checked;
        const pin = document.getElementById('am-pin').value, pout = document.getElementById('am-pout').value;
        const pricing = (pin !== '' && pout !== '') ? { input_per_mtok: +pin, output_per_mtok: +pout } : null;
        const kinds  = _formCollectKinds('am-kinds');
        if (!mid || !kinds.length) {
            _formModalStatus('Model ID and at least one kind are required.', true);
            return;
        }
        _formModalStatus('Saving…');
        try {
            const r = await fetch('workers.php?action=add_model', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify(Object.assign({provider: providerId, model_id: mid, label, kinds, free}, pricing ? {pricing} : {})),
            });
            const d = await r.json();
            if (!d.ok) { _formModalStatus('Error: ' + (d.error || 'failed'), true); return; }
            _formModalStatus('Saved.', false);
            await workersOpenSettings();
            setTimeout(_formModalHide, 400);
        } catch(e) {
            _formModalStatus('Network error: ' + e.message, true);
        }
    });
}

async function workersRemoveModel(pid, mid) {
    if (!await cockpitConfirm('Remove model?', 'Remove model "' + mid + '" from ' + pid + '?', 'Remove', {danger:true, icon:'delete'})) return;
    try {
        const r = await fetch('workers.php?action=remove_model', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({provider: pid, model_id: mid}),
        });
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.remove.failed.error', 'Remove failed: {error}', {error: (d.error || 'unknown')})); return; }
        appendSystem(T('msg.model.removed.mid', 'Model removed: {mid}', {mid: mid}));
        await workersOpenSettings();
    } catch(e) { appendError(T('msg.network.error.message', 'Network error: {message}', {message: e.message})); }
}

async function workersDeleteProvider(pid) {
    if (!await cockpitConfirm('Delete provider?', 'Delete custom provider "' + pid + '" entirely? This will also remove its API key, usage history, and quota config.', 'Delete', {danger:true, icon:'delete'})) return;
    try {
        const r = await fetch('workers.php?action=delete_provider', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({provider: pid}),
        });
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (d.error || 'unknown')})); return; }
        appendSystem(T('msg.provider.deleted.pid', 'Provider deleted: {pid}', {pid: pid}));
        await workersOpenSettings();
    } catch(e) { appendError(T('msg.network.error.message', 'Network error: {message}', {message: e.message})); }
}

// Phase 2b 2026-05-10 — click-to-select-then-test machinery.
// Each provider can have one "test target" model selected at a time.
// Stored in localStorage keyed by provider id. Default (when nothing
// is stored): first free+text model, mirroring backend's old auto-pick.
function workersGetTestSelection(providerId, models) {
    let stored = null;
    try { stored = localStorage.getItem('cockpit_test_target_' + providerId); } catch(e) {}
    if (stored && models.some(m => m.id === stored)) return stored;
    // Fallback: first free+text model
    for (const m of models) {
        if (m.free && (m.kinds || []).includes('text')) return m.id;
    }
    // Last resort: first model in list
    return models.length ? models[0].id : null;
}
function workersSelectTestModel(providerId, modelId, ev) {
    if (ev) { ev.stopPropagation(); }
    try { localStorage.setItem('cockpit_test_target_' + providerId, modelId); } catch(e) {}
    // Re-render the providers panel so the chip styling updates
    workersOpenSettings();
}

async function workersTestKey(pid) {
    // Phase 2b 2026-05-10 — Test button now sends the user-selected
    // model (chip-click) rather than the backend's auto-picked default.
    // Also gives transient visual feedback on the chip itself (q3=c):
    // the chip flashes a spinner during the test, then  or  for ~3s.

    // Find which model is selected for this provider
    let selectedModel = null;
    try { selectedModel = localStorage.getItem('cockpit_test_target_' + pid); } catch(e) {}

    // Find the chip in the DOM and stash its original HTML so we can restore it
    const chip = selectedModel
        ? document.querySelector(`[data-model-id="${CSS.escape(selectedModel)}"]`)
        : null;
    let originalContent = null;
    if (chip) {
        originalContent = chip.innerHTML;
        // Replace innerHTML with a small spinner-style indicator
        chip.innerHTML = '<span style="display:inline-block;animation:spinSlow 1.2s linear infinite;"><span class="material-symbols-rounded ico">refresh</span></span> testing…';
        chip.style.opacity = '0.75';
    }

    appendSystem(T('msg.testing.pidselectedmodel', 'Testing {pid}{selectedmodel}…', {pid: pid, selectedmodel: (selectedModel ? ' · ' + selectedModel : '')}));
    try {
        const r = await fetch('workers.php?action=test_key', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({provider: pid, model: selectedModel || undefined}),
        });
        const d = await r.json();

        // Update chip with success/failure flash
        if (chip) {
            chip.style.opacity = '1';
            if (d.ok) {
                chip.innerHTML = '<span class="material-symbols-rounded ico">check</span> ' + (originalContent || '');
                chip.style.background = 'rgba(125,196,163,0.25)';
            } else {
                chip.innerHTML = '<span class="material-symbols-rounded ico">close</span> ' + (originalContent || '');
                chip.style.background = 'rgba(212,73,73,0.25)';
            }
            // Restore original after 3s
            setTimeout(() => {
                if (chip.isConnected && originalContent !== null) {
                    chip.innerHTML = originalContent;
                    chip.style.background = '';
                }
            }, 3000);
        }

        if (d.ok) {
            appendSystem(T('msg.icon.check.pid.ok.latencymsms.model.model', '[[icon:check]] {pid} OK ({latencyms}ms, model: {model})', {pid: pid, latencyms: d.latency_ms, model: d.model}));
        } else {
            appendError(T('msg.icon.close.pid.test.failed.error', '[[icon:close]] {pid} test failed: {error}', {pid: pid, error: (d.error || 'unknown')}));
        }
    } catch(e) {
        if (chip && originalContent !== null) {
            chip.innerHTML = originalContent;
            chip.style.opacity = '1';
            chip.style.background = '';
        }
        appendError(T('msg.network.error.message', 'Network error: {message}', {message: e.message}));
    }
}

// ─── TOOLS — Add Tool dialog ────────────────────────────────────────────────
function toolsOpenAddToolDialog() {
    const body = `
    <div style="font-size:10.5px;color:var(--text-dim);margin-bottom:8px;">
        Register a local CLI tool and one initial preset.
        The binary is auto-located on PATH (override later from the tool row).
    </div>
    <div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:center;font-size:11px;">
        <span>Tool ID:</span>
        <input id="at-id" placeholder="imagemagick" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
        <span>Name:</span>
        <input id="at-name" placeholder="ImageMagick" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Binary:</span>
        <input id="at-binary" placeholder="convert (or full path)" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
        <span>Description:</span>
        <input id="at-desc" placeholder="(optional, shown in tool row)" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Website:</span>
        <input id="at-website" placeholder="https://… (optional)" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
    </div>
    <div style="margin-top:10px;font-size:11px;">
        <div style="margin-bottom:4px;color:var(--text-muted);">First preset:</div>
        <div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:center;">
            <span>Preset ID:</span>
            <input id="at-pid" placeholder="to-jpg" autocomplete="off"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                          font-family:var(--font-mono);">
            <span>Label:</span>
            <input id="at-plabel" placeholder="Image → JPG" autocomplete="off"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
            <span>Output ext:</span>
            <input id="at-pext" placeholder="jpg" autocomplete="off"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                          font-family:var(--font-mono);">
            <span>Output kind:</span>
            <input id="at-pokind" placeholder="image" autocomplete="off" value="file"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
            <span>Command:</span>
            <input id="at-pcmd" placeholder="convert {INPUT} {OUTPUT}" autocomplete="off"
                   style="background:var(--bg-darker);border:1px solid var(--border-dim);
                          color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                          font-family:var(--font-mono);">
        </div>
        <div style="margin-top:6px;font-size:10.5px;color:var(--text-muted);">Input kinds (what file types the preset accepts):</div>
        ${_formKindsWidget('at-pikinds', STD_TOOL_KINDS, ['file'])}
    </div>`;

    _formModalShow('Add Custom Tool', body, async () => {
        const id     = document.getElementById('at-id').value.trim();
        const name   = document.getElementById('at-name').value.trim();
        const binary = document.getElementById('at-binary').value.trim();
        const desc   = document.getElementById('at-desc').value.trim();
        const website= document.getElementById('at-website').value.trim();
        const pid    = document.getElementById('at-pid').value.trim();
        const plabel = document.getElementById('at-plabel').value.trim() || pid;
        const pext   = document.getElementById('at-pext').value.trim() || 'out';
        const pokind = document.getElementById('at-pokind').value.trim() || 'file';
        const pcmd   = document.getElementById('at-pcmd').value.trim();
        const pikinds= _formCollectKinds('at-pikinds');
        if (!id || !name || !binary || !pid || !pcmd || !pikinds.length) {
            _formModalStatus('Tool ID, name, binary, preset ID, command, and at least one input kind are required.', true);
            return;
        }
        _formModalStatus('Saving…');
        try {
            const r = await fetch('tools.php?action=add_custom', {
                method: 'POST', headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    id, name, binary,
                    description: desc, website: website || null,
                    presets: [{
                        id: pid, label: plabel, command: pcmd,
                        input_kinds: pikinds, output_kind: pokind, output_ext: pext,
                    }],
                }),
            });
            const d = await r.json();
            if (!d.ok) { _formModalStatus('Error: ' + (d.error || 'failed'), true); return; }
            _formModalStatus('Saved.', false);
            await toolsOpenSettings();
            setTimeout(_formModalHide, 400);
        } catch(e) { _formModalStatus('Network error: ' + e.message, true); }
    });
}

// ─── TOOLS — Add Preset dialog ──────────────────────────────────────────────
function toolsOpenAddPresetDialog(toolId) {
    const body = `
    <div style="font-size:10.5px;color:var(--text-dim);margin-bottom:8px;">
        Adding a preset to tool <b>${escapeHtml(toolId)}</b>.
        Use <code style="font-family:var(--font-mono);background:var(--bg-darker);padding:1px 4px;">{INPUT}</code> and
        <code style="font-family:var(--font-mono);background:var(--bg-darker);padding:1px 4px;">{OUTPUT}</code>
        in the command for file paths.
    </div>
    <div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:center;font-size:11px;">
        <span>Preset ID:</span>
        <input id="ap2-id" placeholder="to-jpg" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
        <span>Label:</span>
        <input id="ap2-label" placeholder="Image → JPG" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Description:</span>
        <input id="ap2-desc" placeholder="(optional)" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Output ext:</span>
        <input id="ap2-ext" placeholder="jpg" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
        <span>Output kind:</span>
        <input id="ap2-okind" placeholder="image" value="file" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;">
        <span>Command:</span>
        <input id="ap2-cmd" placeholder="convert {INPUT} {OUTPUT}" autocomplete="off"
               style="background:var(--bg-darker);border:1px solid var(--border-dim);
                      color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;
                      font-family:var(--font-mono);">
    </div>
    <div style="margin-top:6px;font-size:10.5px;color:var(--text-muted);">Input kinds:</div>
    ${_formKindsWidget('ap2-ikinds', STD_TOOL_KINDS, ['file'])}`;

    _formModalShow('Add Preset to ' + escapeHtml(toolId), body, async () => {
        const pid    = document.getElementById('ap2-id').value.trim();
        const label  = document.getElementById('ap2-label').value.trim() || pid;
        const desc   = document.getElementById('ap2-desc').value.trim();
        const ext    = document.getElementById('ap2-ext').value.trim() || 'out';
        const okind  = document.getElementById('ap2-okind').value.trim() || 'file';
        const cmd    = document.getElementById('ap2-cmd').value.trim();
        const ikinds = _formCollectKinds('ap2-ikinds');
        if (!pid || !cmd || !ikinds.length) {
            _formModalStatus('Preset ID, command, and at least one input kind are required.', true);
            return;
        }
        _formModalStatus('Saving…');
        try {
            const r = await fetch('tools.php?action=add_preset', {
                method: 'POST', headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({
                    tool: toolId, preset_id: pid, label, description: desc,
                    command: cmd, output_ext: ext, output_kind: okind, input_kinds: ikinds,
                }),
            });
            const d = await r.json();
            if (!d.ok) { _formModalStatus('Error: ' + (d.error || 'failed'), true); return; }
            _formModalStatus('Saved.', false);
            await toolsOpenSettings();
            setTimeout(_formModalHide, 400);
        } catch(e) { _formModalStatus('Network error: ' + e.message, true); }
    });
}

async function toolsRemovePreset(tid, pid) {
    if (!await cockpitConfirm('Remove preset?', 'Remove preset "' + pid + '" from ' + tid + '?', 'Remove', {danger:true, icon:'delete'})) return;
    try {
        const r = await fetch('tools.php?action=remove_preset', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({tool: tid, preset_id: pid}),
        });
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.remove.failed.error', 'Remove failed: {error}', {error: (d.error || 'unknown')})); return; }
        appendSystem(T('msg.preset.removed.pid', 'Preset removed: {pid}', {pid: pid}));
        await toolsOpenSettings();
    } catch(e) { appendError(T('msg.network.error.message', 'Network error: {message}', {message: e.message})); }
}

async function toolsTestBinary(tid) {
    appendSystem(T('msg.testing.binary.for.tid', 'Testing binary for {tid}…', {tid: tid}));
    try {
        const r = await fetch('tools.php?action=test_binary', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({tool: tid}),
        });
        const d = await r.json();
        if (d.ok) {
            appendSystem(T('msg.icon.check.tid.ok.firstline.latencymsms', '[[icon:check]] {tid} OK: {firstline} ({latencyms}ms)', {tid: tid, firstline: (d.first_line || '(no version output)'), latencyms: d.latency_ms}));
        } else {
            appendError(T('msg.icon.close.tid.test.failed.rc.rc.firstline', '[[icon:close]] {tid} test failed (rc={rc}): {firstline}', {tid: tid, rc: (d.rc || '?'), firstline: (d.first_line || d.error || 'unknown')}));
        }
    } catch(e) { appendError(T('msg.network.error.message', 'Network error: {message}', {message: e.message})); }
}

async function toolsToggleEnabled(tid, enabled) {
    await fetch('tools.php?action=set_state', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({tool: tid, enabled}),
    });
    appendSystem(tid + ' ' + (enabled ? 'enabled' : 'disabled'));
    toolsRefreshSettings();
    toolsLoadPresets();
}

async function toolsSetBinary(tid) {
    const inp = document.getElementById('bin-input-' + tid);
    if (!inp) return;
    const path = inp.value.trim();
    await fetch('tools.php?action=set_state', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({tool: tid, binary_override: path}),
    });
    appendSystem(T('msg.tid.binary.path.path', '{tid} binary path {path}', {tid: tid, path: (path ? 'set to ' + path : 'cleared')}));
    toolsRefreshSettings();
    toolsLoadPresets();
}

async function toolsSetOutputDir(tid) {
    const inp = document.getElementById('outdir-input-' + tid);
    if (!inp) return;
    const path = inp.value.trim();
    await fetch('tools.php?action=set_state', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({tool: tid, output_dir: path}),
    });
    appendSystem(T('msg.tid.output.dir.path', '{tid} output dir {path}', {tid: tid, path: (path ? 'set to ' + path : 'cleared (defaults restored)')}));
    toolsRefreshSettings();
}

async function toolsDelete(tid) {
    if (!await cockpitConfirm('Delete tool?', 'Delete user tool "' + tid + '"?', 'Delete', {danger:true, icon:'delete'})) return;
    await fetch('tools.php?action=delete', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({tool: tid}),
    });
    toolsRefreshSettings();
    toolsLoadPresets();
}

async function toolsDetect() {
    appendSystem(T('msg.re.scanning.path.for.tool.binaries', 'Re-scanning PATH for tool binaries…'));
    try {
        const r = await fetch('tools.php?action=detect', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({}),
        });
        const d = await r.json();
        if (d.ok) {
            const found = Object.entries(d.report || {}).filter(([_, v]) => v.available).map(([k]) => k);
            const missing = Object.entries(d.report || {}).filter(([_, v]) => !v.available).map(([k]) => k);
            appendSystem(T('msg.detected.nn2', 'Detected: {n}{n2}', {n: (found.length ? found.join(', ') : '(none)'), n2: (missing.length ? '   ·   missing: ' + missing.join(', ') : '')}));
            toolsRefreshSettings();
            toolsLoadPresets();
        } else {
            appendError(T('msg.detect.failed.error', 'Detect failed: {error}', {error: (d.error || '')}));
        }
    } catch(e) {
        appendError(T('msg.detect.failed.message', 'Detect failed: {message}', {message: e.message}));
    }
}

// ─── Run modal — opens when TOOLS agent active and user presses Execute ───
// prefill: what the person typed in the prompt box. A Tools run needs an input
// file, not prose — so a typed path/URL goes straight into the input field (and
// runs immediately when it is clearly a file or URL); anything else becomes the
// preset's extra arguments. Before 2026-09-22 Execute only worked with an EMPTY
// prompt, which made the card feel broken.
function toolsShowInputModal(prefill) {
    const sel = document.getElementById('tools-preset');
    const value = sel ? sel.value : '';
    if (!value) {
        appendError(T('msg.no.tool.preset.selected', 'No tool preset selected.'));
        return;
    }
    const meta = _toolsPresets.find(p => p.value === value);
    if (!meta) { appendError(T('msg.preset.not.found.value', 'Preset not found: {value}', {value: value})); return; }
    _toolsActivePreset = meta;

    const info = document.getElementById('tools-input-preset-info');
    if (info) {
        info.innerHTML = `<b>${escapeHtml(meta.label)}</b>` +
            (meta.description ? '<br><span style="color:var(--text-muted);">' + escapeHtml(meta.description) + '</span>' : '') +
            (meta.input_kinds && meta.input_kinds.length ? '<br><span style="font-size:10px;color:var(--text-muted);">accepts: ' + meta.input_kinds.join(', ') + '</span>' : '');
    }
    // Reset fields, then apply what was typed in the prompt box
    const pathEl  = document.getElementById('tools-input-path');
    const extraEl = document.getElementById('tools-input-extra');
    pathEl.value = ''; extraEl.value = '';
    let typed = String(prefill || '').trim();
    if (/^\[Attached|\n/.test(typed) || typed.length > 300) typed = '';   // leftover prompt text (an attached file block, a paragraph) is not a path or an argument
    const looksLikeTarget = typed !== '' && !/\s/.test(typed) &&
        (/^(https?|file):\/\//i.test(typed) || typed.startsWith('/') || typed.startsWith('~') ||
         typed.startsWith('./') || /^[\w .\-]+\.[A-Za-z0-9]{1,8}$/.test(typed));
    if (looksLikeTarget)      pathEl.value  = typed.startsWith('~') ? typed : typed;
    else if (typed !== '')    extraEl.value = typed;
    // a preset that works without a file says so in the label
    try { const lb = document.querySelector('#tools-input-overlay label[data-i18n="ui.input.file"]'); const act = (typeof _toolsActivePreset !== 'undefined' && _toolsActivePreset) || {}; if (lb) lb.textContent = (act.optional_input ? T('ui.input.file.optional', 'Input file (optional):') : T('ui.input.file', 'Input file:')); } catch (e) {}
    document.getElementById('tools-input-overlay').style.display = 'flex';
    setTimeout(() => (looksLikeTarget ? extraEl : pathEl).focus(), 50);
    toolsCheckInstalled(meta.tool);
    // A bare path or URL is all a tool needs: run it without a second click.
    if (looksLikeTarget) setTimeout(() => { const b = document.getElementById('tools-run-btn'); if (b && !b.disabled) toolsRun(); }, 400);
}

// Is the tool's binary on this machine? Asked when the modal opens, so a
// missing pandoc is a banner with the install line BEFORE Run, not a failed
// run after. Cockpit shows the line; it never runs the install itself.
async function toolsCheckInstalled(tool) {
    const b = document.getElementById('tools-install-banner');
    const run = document.getElementById('tools-run-btn');
    if (!b) return;
    b.style.display = 'none'; if (run) run.disabled = false;
    try {
        const r = await (await fetch('tools.php?action=check&tool=' + encodeURIComponent(tool))).json();
        if (!r.ok || r.installed) return;
        const hint = r.install_hint || '';
        const isCmd = /^(sudo |brew )/.test(hint);
        b.innerHTML = '<b>' + escapeHtml(tool) + ' is not installed on this machine.</b> ' +
            (isCmd ? 'Install it, then try again:<div style="display:flex;gap:6px;align-items:center;margin-top:6px;">' +
                     '<code style="flex:1;font-family:var(--font-mono);background:var(--bg-darker);padding:4px 8px;border-radius:3px;">' + escapeHtml(hint) + '</code>' +
                     '<button class="plan-tb-btn" onclick="navigator.clipboard.writeText(' + JSON.stringify(hint).replace(/"/g, '&quot;') + ').then(()=>appendSystem(\'Install line copied.\'))">Copy</button></div>'
                   : '<div style="margin-top:4px;">' + escapeHtml(hint) + '</div>') +
            '<div style="margin-top:4px;color:var(--text-muted);">Or set the binary override in Tools settings if it lives elsewhere.</div>';
        b.style.display = 'block';
        if (run) run.disabled = true;
    } catch (e) { /* check is advisory; a failed check must not block Run */ }
}
function toolsHideInputModal() {
    document.getElementById('tools-input-overlay').style.display = 'none';
    _toolsActivePreset = null;
}

// Browse-button file picker — most browsers won't give us the full local
// path for security reasons, only the filename. We populate the path field
// with what we get; user can paste an absolute path manually if needed.
async function toolsServerPick() {
    const cur = document.getElementById('tools-input-path')?.value || '';
    const p = await cockpitPathPicker({ mode:'open', title:'Pick input file (on server)', start: cur ? cur.replace(/\/[^\/]*$/,'') : '' });
    if (p) { const inp = document.getElementById('tools-input-path'); if (inp) inp.value = p; }
}
// Local file chooser. A browser never reveals the file's path, so "paste the
// full path manually" was the only thing this button could say (2026-09-12: a
// picked unit1.pas sat in the field and nothing could run). The file itself IS
// available, so upload it into this chat's attachment store — the same path
// the paperclip uses — and put the server-side absolute path in the field.
// For a file already on the rig, the Browse (server) button next to it is the
// direct route.
// Native window: the real path, no upload. Browser: the hidden file input.
async function toolsPickFile() {
    if (_inShell) {
        const inp = document.getElementById('tools-input-path');
        const paths = await shellPickFiles({ title: 'Choose the input file', dir: (inp && inp.value ? inp.value.replace(/\/[^\/]*$/, '') : '') });
        if (paths) { if (paths[0] && inp) { inp.value = paths[0]; inp.placeholder = T('msg.absolute.path.on.the.server', 'Absolute path on the server'); } return; }
    }
    document.getElementById('tools-file-picker').click();
}
async function toolsFilePicked(event) {
    const f = event.target.files && event.target.files[0];
    if (!f) return;
    const inp = document.getElementById('tools-input-path');
    if (!inp) return;
    inp.value = ''; inp.placeholder = 'Uploading ' + f.name + '…';
    try {
        const b64 = await _fileToBase64(f);
        const r = await fetch('attachments.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'save', project: currentProject || '_standalone', chat: currentChat || 'default',
                                   filename: f.name, mime: f.type || '', data_b64: b64 }),
        });
        const d = await r.json();
        if (!d.ok || !d.path) throw new Error(d.error || 'upload failed');
        inp.value = d.path;
        inp.placeholder = T('msg.absolute.path.on.the.server', 'Absolute path on the server');
        appendSystem(T('msg.uploaded.name.path', 'Uploaded {name} → {path}', {name: f.name, path: d.path}));
    } catch (e) {
        inp.placeholder = T('msg.upload.failed.paste.an.absolute.path.or.use', 'Upload failed — paste an absolute path, or use Browse (server)');
        appendError(T('msg.upload.failed.message', 'Upload failed: {message}', {message: e.message}));
    } finally {
        event.target.value = '';   // allow picking the same file again
    }
}

// Two small buttons after a file path in the chat: open its folder (file
// selected) and open the file with the desktop's default app. Both go through
// launch_cli.php as the login user. (Dario, 2026-09-13: the output path was
// right, but finding it meant a hunt through the file explorer.)
function pathOpenButtons(path) {
    if (!path || path[0] !== '/') return '';
    const p = JSON.stringify(path).replace(/"/g, '&quot;');
    return '<span class="path-open" style="white-space:nowrap;">' +
        '<button class="plan-tb-btn" style="padding:0 5px;font-size:10px;vertical-align:middle;" title="Open the folder (file selected)" onclick="event.stopPropagation();openPathLocation(' + p + ')"><span class="material-symbols-rounded" style="font-size:13px;vertical-align:-3px;">folder_open</span></button> ' +
        (_inShell ? '<button class="plan-tb-btn" style="padding:0 5px;font-size:10px;vertical-align:middle;" title="Open a terminal in that folder" onclick="event.stopPropagation();shellCall(\'open_terminal\',{path:' + p + '})"><span class="material-symbols-rounded ico">terminal</span></button>' : '') +
        '<button class="plan-tb-btn" style="padding:0 5px;font-size:10px;vertical-align:middle;" title="Open the file with its default app" onclick="event.stopPropagation();openPathFile(' + p + ')"><span class="material-symbols-rounded" style="font-size:13px;vertical-align:-3px;">open_in_new</span></button></span>';
}
async function openPathLocation(path) {
    // In the native window the desktop call is ours to make; through PHP it runs
    // as the web server user and needs launch_cli's hand-off.
    if (_inShell) { try { await shellCall('reveal_path', { path }); return; } catch (e) {} }
    try {
        const d = await (await fetch('launch_cli.php', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'files', dir: path})})).json();
        if (!d.ok) appendSystem(T('msg.open.folder.failed.error', 'Open folder failed: {error}', {error: (d.error || 'unknown')}));
    } catch (e) { appendSystem(T('msg.open.folder.failed.message', 'Open folder failed: {message}', {message: e.message})); }
}
async function openPathFile(path) {
    if (_inShell) { try { await shellCall('open_path', { path }); return; } catch (e) {} }
    try {
        const d = await (await fetch('launch_cli.php', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'open', path})})).json();
        if (!d.ok) appendSystem(T('msg.open.file.failed.error', 'Open file failed: {error}', {error: (d.error || 'unknown')}));
    } catch (e) { appendSystem(T('msg.open.file.failed.message', 'Open file failed: {message}', {message: e.message})); }
}
// Stored tool turns (reloaded from the chat file) carry "Output: /path" as text;
// give them the same buttons.
function pathOpenDecorate(msgDiv) {
    const body = msgDiv && msgDiv.querySelector('.msg-body'); if (!body) return;
    body.innerHTML = body.innerHTML.replace(/(Output:\s*)(\/[^\s<()]+)/, (m, a, p) => a + p + ' ' + pathOpenButtons(p));
}

// Run the active preset. Async on the server: the run is started as a job,
// polled here every 1.5s (elapsed + log tail shown live), and can be stopped —
// by the Stop button, by the long-run watchdog, or by closing the page. Before
// 2026-09-13 the request was synchronous and a run showed "running" with no
// way to see, stop, or know whether anything was running at all.
// ---- Pascal / Lazarus build results: count the compiler's messages, list the errors, offer "Fix with agent" --------------------------------
// fpc and lazbuild print  file(line,col) Error: text  (also Fatal / Warning / Hint / Note); lazbuild adds lines without a file.
function _pascalParseMessages(text) {
    const out = { errors: [], warnings: 0, hints: 0, exit: null };
    String(text || '').split('\n').forEach(line => {
        const m = line.match(/^(.+?)\((\d+)(?:,(\d+))?\) (Error|Fatal|Warning|Hint|Note): (?:\(\d+\) )?(.*)$/);
        if (m) {
            if (m[4] === 'Fatal' && /^There were \d+ errors? compiling module/.test(m[5])) return;     // fpc's own summary of the errors above it
            if (m[4] === 'Error' || m[4] === 'Fatal') out.errors.push({ file: m[1], line: +m[2], col: m[3] ? +m[3] : 0, kind: m[4], msg: m[5] });
            else if (m[4] === 'Warning') out.warnings++; else out.hints++;
            return;
        }
        const x = line.match(/^\[exit code (\d+)\]$/); if (x) out.exit = +x[1];
    });
    return out;
}
async function _pascalBuildSummary(d, preset, path, bodyEl) {
    let text = '';
    try {
        const r = await fetch('tools.php?action=read_output', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path: d.output }) });
        const j = await r.json(); if (j.ok && typeof j.content === 'string') text = j.content;
    } catch (e) { return; }
    if (!text) return;
    const p = _pascalParseMessages(text), failed = (p.exit !== null && p.exit !== 0) || p.errors.length > 0, isWeb = preset.tool === 'website', isGodot = preset.tool === 'godot', isSubs = preset.tool === 'subs', isSlides = preset.tool === 'slides', isTex = preset.tool === 'latex', isPod = preset.tool === 'podcast', isLang = preset.tool === 'lang', isLegal = preset.tool === 'legal', isBooks = preset.tool === 'books', isPhp = preset.tool === 'phpdev', isScore = preset.tool === 'score', isPhoto = preset.tool === 'photo', isDocs = preset.tool === 'docsite', isSys = preset.tool === 'sysadmin', isMake = /^(shell|ebook|scad|kicad|hugo|arduino|writing)$/.test(preset.tool);
    const box = document.createElement('div'); box.style.cssText = 'margin-top:8px;font-size:11px;';
    if (!failed) {
        box.innerHTML = '<span class="material-symbols-rounded ico" style="color:var(--accent-green);">check_circle</span> ' + escapeHtml(isWeb ? T('ui.web.ok', 'No broken links or errors found') : isGodot ? T('ui.godot.ok', 'No script errors found') : isSubs ? T('ui.subs.ok', 'No problems found in the subtitles') : isSlides ? T('ui.slides.ok', 'No problems found in the deck') : isTex ? T('ui.latex.ok', 'No problems found in the paper') : isPod ? T('ui.podcast.ok', 'No problems found in the episode') : isLang ? T('ui.lang.ok', 'No problems found in the vocabulary list') : isLegal ? T('ui.legal.ok', 'No problems found in the document') : isBooks ? T('ui.books.ok', 'No problems found in the ledger') : isPhp ? T('ui.php.ok', 'No candidates found') : isScore ? T('ui.score.ok', 'The score compiled without problems') : isPhoto ? T('ui.photo.ok', 'No problems found in the photos') : isDocs ? T('ui.docs.ok', 'No problems found in the pages') : isSys ? T('ui.sys.ok', 'Nothing needs attention') : isMake ? T('ui.make.ok', 'No problems found') : T('ui.pas.ok', 'Built without errors')) + ' · ' + p.warnings + ' ' + escapeHtml(T('ui.pas.warnings', 'warnings')) + ', ' + p.hints + ' ' + escapeHtml(T('ui.pas.hints', 'hints/notes'));
    } else {
        const list = p.errors.slice(0, 8).map(e => '<div style="font-family:var(--font-mono);font-size:10.5px;"><span style="color:var(--claude);">' + escapeHtml(e.file.split('/').pop() + ':' + e.line) + '</span> ' + escapeHtml(e.msg) + '</div>').join('');
        box.innerHTML = '<span class="material-symbols-rounded ico" style="color:var(--claude);">error</span> <b>' + p.errors.length + ' ' + escapeHtml(T('ui.pas.errors', 'errors')) + '</b> · ' + p.warnings + ' ' + escapeHtml(T('ui.pas.warnings', 'warnings')) + (p.errors.length > 8 ? ' · ' + escapeHtml(T('ui.pas.first8', 'first 8 shown')) : '') + '<div style="margin-top:4px;">' + list + '</div>' +
            '<button class="action-btn" type="button" style="margin-top:6px;padding:3px 10px;font-size:11px;" title="' + escapeHtml(T('ui.pas.fixtip', 'Puts the errors in the prompt box, ready to send to the agent')) + '"><span class="material-symbols-rounded ico">auto_fix_high</span> ' + escapeHtml(T('ui.pas.fix', 'Fix with agent')) + '</button>';
        const btn = box.querySelector('button');
        btn.onclick = () => {
            const lines = p.errors.slice(0, 40).map(e => e.file + '(' + e.line + (e.col ? ',' + e.col : '') + ') ' + e.kind + ': ' + e.msg).join('\n');
            const ta = document.getElementById('prompt-in'); if (!ta) return;
            ta.value = isMake ? ('The ' + preset.tool + ' check found ' + p.errors.length + ' error(s) in ' + path + ':\n\n' + lines + '\n\nRead the files named above, explain each error in plain words, and fix the cause with the smallest change. Do not touch anything the errors do not point at, and tell me what you changed.') : isWeb ? ('The site checker found ' + p.errors.length + ' error(s) in ' + path + ':\n\n' + lines + '\n\nRead the files named above, fix the problems (broken links and markup errors first), and tell me what you changed.') : isLegal ? ('The document check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the line in the document):\n\n' + lines + '\n\nFor each, say what the document says, what is wrong and the smallest fix, as a tracked change (old struck, new in bold). Do not change any other wording, do not give legal advice, and keep the original file untouched.') : isBooks ? ('The ledger check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the line in the file):\n\n' + lines + '\n\nFor each, say what the row holds and what is wrong. Do not invent an amount, date or category: ask me when the row does not tell you. Write corrections to a new file and keep the original untouched.') : isPhp ? ('The PHP tool found ' + p.errors.length + ' error(s) in ' + path + ':\n\n' + lines + '\n\nRead each place, decide whether it is a real problem or a false alarm, and fix the real ones (validate and escape request data, prepared statements, no eval or shell with request data). Tell me which you changed and which you left, and why.') : isScore ? ('LilyPond found ' + p.errors.length + ' error(s) in ' + path + ' (line,column in brackets):\n\n' + lines + '\n\nFix them in the .ly source. A "barcheck failed" warning means the bar BEFORE that position has the wrong number of beats. Do not invent notes: ask me where the music is unclear. Do not add Scheme code that writes files or runs programs.') : isPhoto ? ('The photo check found ' + p.errors.length + ' error(s) in ' + path + ':\n\n' + lines + '\n\nSuggest which Photo tool preset fixes each (strip metadata, web-ready copy). Never overwrite or delete an original: write copies under new names.') : isDocs ? ('The docs check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the line in that page):\n\n' + lines + '\n\nFix each in the markdown (links relative, .md files, #anchors from headings). Do not change what a page means or invent commands or versions, then run the check again and tell me what you changed.') : isSys ? ('The system report found ' + p.warnings + ' warning(s):\n\n' + lines + '\n\nExplain each in plain words, how serious it is and what could go wrong if left. Do NOT run anything that changes this machine: write the exact commands for me to run myself, with what each does and how to undo it.') : isPod ? ('The podcast check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the second):\n\n' + lines + '\n\nSuggest the audio processing that fixes them (normalise, clean, trim) and which tool presets to run; do not overwrite the original recording.') : isLang ? ('The vocabulary check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the line):\n\n' + lines + '\n\nFix them in the list (do not invent a translation you are unsure of: ask me), keep the format, then tell me what you changed.') : isTex ? ('The LaTeX tool found ' + p.errors.length + ' error(s) in ' + path + ':\n\n' + lines + '\n\nFix them in the .tex / .bib sources (never invent a reference: a citation must come from an entry the user gave you), then run the check again and tell me what you changed.') : isSlides ? ('The presentation check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the slide):\n\n' + lines + '\n\nFix them in the deck\'s markdown source and rebuild it (do not edit the binary deck), then run the check again and tell me what you changed.') : isSubs ? ('The subtitle check found ' + p.errors.length + ' error(s) in ' + path + ' (the number in brackets is the line in the file):\n\n' + lines + '\n\nFix the errors in the subtitle file without changing any text that is not involved and without moving times that are not wrong, then tell me what you changed.') : isGodot ? ('Godot reported ' + p.errors.length + ' script error(s) in ' + path + ':\n\n' + lines + '\n\nRead the scripts named above, fix the errors (GDScript for the Godot version in project.godot), and tell me what you changed.') : ('The Free Pascal compiler reported ' + p.errors.length + ' error(s) building ' + path + ':\n\n' + lines + '\n\nRead the files named above, fix the errors, and tell me what you changed.');
            ta.focus(); if (typeof ta.oninput === 'function') ta.oninput();
        };
    }
    bodyEl.appendChild(box);
}

// Web Site tools: the preview's address as a link to click.
async function _webServeBox(d, preset, bodyEl) {
    let text = '';
    try { const r = await fetch('tools.php?action=read_output', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path: d.output }) }); const j = await r.json(); if (j.ok && typeof j.content === 'string') text = j.content; } catch (e) { return; }
    const m = text.match(/https?:\/\/127\.0\.0\.1:\d+\/?/); if (!m) return;
    const box = document.createElement('div'); box.style.cssText = 'margin-top:8px;font-size:11px;';
    box.innerHTML = '<span class="material-symbols-rounded ico" style="color:var(--accent-green);">public</span> ' + escapeHtml(T('ui.web.preview', 'Preview running')) + ': <a href="' + escapeHtml(m[0]) + '" target="_blank" rel="noopener" style="color:var(--accent-cyan);">' + escapeHtml(m[0]) + '</a> <span style="color:var(--text-muted);">· ' + escapeHtml(T('ui.web.preview.note', 'only this computer can open it; stop it with "Stop the preview"')) + '</span>';
    bodyEl.appendChild(box);
}
async function toolsRun() {
    if (!_toolsActivePreset) { appendError(T('msg.no.active.preset', 'No active preset')); return; }
    let path  = document.getElementById('tools-input-path').value.trim();
    const preset0 = _toolsActivePreset;
    const extra = document.getElementById('tools-input-extra').value.trim();
    if (!path && preset0.optional_input) path = (typeof preset0.optional_input === 'string') ? preset0.optional_input : ".";
    if (!path) {
        // say it inside the dialog (the chat is behind it) and keep the dialog open
        const pe = document.getElementById('tools-input-path'); let er = document.getElementById('tools-input-err');
        if (pe && !er) { er = document.createElement('div'); er.id = 'tools-input-err'; er.style.cssText = 'font-size:11px;color:var(--warn);margin-top:3px;'; pe.insertAdjacentElement('afterend', er); }
        if (er) er.textContent = T('msg.input.path.required', 'Input path required');
        if (pe) pe.focus();
        return;
    }
    const preset = _toolsActivePreset;

    toolsHideInputModal();
    setLoading(true);
    appendMsg('user', _userLabel().replace(/[\[\]]/g, ''), 'user', preset.label + ' ⟶ ' + path, new Date(), '', '', null);
    const placeholderId = 'msg-tool-' + Date.now();
    appendMsg('worker', 'TOOLS · ' + preset.label, 'worker',
              '⏳ Starting ' + preset.tool + '...', new Date(), '', '', placeholderId);
    const bodyEl = document.getElementById(placeholderId)?.querySelector('.msg-body');
    let jobId = null, flightId = null, stopped = false;

    const showFinal = (d) => {
        if (!d.ok) {
            if (bodyEl) {
                bodyEl.innerHTML = '<div style="color:var(--claude);">[' + (d.killed ? 'STOPPED' : 'ERROR') + '] ' + escapeHtml(d.error || 'unknown') + '</div>' +
                    (d.not_installed && d.install_hint ? '<div style="margin-top:4px;">Install: <code style="font-family:var(--font-mono);">' + escapeHtml(d.install_hint) + '</code></div>' : '') +
                    (d.log ? '<pre style="font-size:9.5px;background:var(--bg-darker);padding:6px;margin-top:6px;border-radius:3px;overflow:auto;max-height:240px;">' + escapeHtml(d.log) + '</pre>' : '');
            }
            if (d.killed) appendSystem(T('msg.tool.stopped.label', 'Tool stopped: {label}', {label: preset.label})); else appendError(T('msg.tool.failed.error', 'Tool failed: {error}', {error: (d.error || 'unknown')}));
            return;
        }
        const sizeKB = d.output_size ? (d.output_size / 1024).toFixed(1) + ' KB' : '?';
        if (bodyEl) {
            const isImg = d.output && /\.(png|jpe?g|webp|gif|bmp|svg)$/i.test(d.output);
            const isAudio = d.output && /\.(mp3|wav|flac|ogg|m4a)$/i.test(d.output);
            const isVideo = d.output && /\.(mp4|webm|mkv|mov)$/i.test(d.output);
            let preview = '';
            if (isImg)        preview = `<img src="file://${encodeURI(d.output)}" style="max-width:100%;max-height:400px;border-radius:4px;margin-top:6px;" alt="output">`;
            else if (isAudio) preview = `<audio controls src="file://${encodeURI(d.output)}" style="max-width:100%;margin-top:6px;"></audio>`;
            else if (isVideo) preview = `<video controls src="file://${encodeURI(d.output)}" style="max-width:100%;max-height:400px;margin-top:6px;"></video>`;
            bodyEl.innerHTML = `
                <div style="color:var(--accent-green);"><span class="material-symbols-rounded ico">check</span> Done in ${d.elapsed_ms}ms (rc=${d.rc})</div>
                <div style="margin-top:4px;font-size:11px;">
                    <b>Output:</b> <code style="font-family:var(--font-mono);background:var(--bg-darker);padding:1px 4px;border-radius:2px;">${escapeHtml(d.output)}</code>
                    <span style="color:var(--text-muted);">(${sizeKB})</span> ${pathOpenButtons(d.output)}
                </div>
                ${preview}
                ${d.log ? `<details style="margin-top:6px;font-size:10px;">
                    <summary style="cursor:pointer;color:var(--text-muted);">Log (${d.log.length} chars)</summary>
                    <pre style="font-size:9.5px;background:var(--bg-darker);padding:6px;margin-top:4px;border-radius:3px;overflow:auto;max-height:200px;">${escapeHtml(d.log)}</pre>
                </details>` : ''}
            `;
        }
        if (bodyEl && /^(fpc|lazarus)$/.test(preset.tool) && !/^new-/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'website' && /^(check|links)$/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'godot' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'score' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'photo' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'docsite' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'sysadmin' && /^(report|ports|services|disk|logs|journal)$/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && /^(shell|ebook|scad|kicad|hugo|arduino|writing)$/.test(preset.tool) && /^(check|syntax|scan|unit|lint|compile|names)$/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'legal' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'books' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'phpdev' && /^(lint|scan)$/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'podcast' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'lang' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'latex' && /^(check|bibcheck)$/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'slides' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'subs' && preset.preset === 'check') _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'castle' && /^(check|compile|package)$/.test(preset.preset)) _pascalBuildSummary(d, preset, path, bodyEl);
        if (bodyEl && preset.tool === 'website' && preset.preset === 'serve') _webServeBox(d, preset, bodyEl);
        appendSystem(T('msg.tool.done.output', 'Tool done: {output}', {output: d.output}));
    };

    try {
        const r = await fetch('tools.php?action=run', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                tool: preset.tool, preset: preset.preset, input: path, extra_args: extra,
                project: currentProject || null, chat: currentChat || null, async: true,
            }),
        });
        const d = await r.json();
        if (!d.ok) { showFinal(d); return; }
        jobId = d.job;
        flightId = inflightAdd('tool', preset.label + ' ⟶ ' + path.split('/').pop(), async () => {
            stopped = true;
            try { await fetch('tools.php?action=job_kill', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({job: jobId})}); } catch (e) {}
        }, { warnAfterMs: Math.min(120000, (d.timeout_seconds || 300) * 1000) });
        // Poll until the job finishes (or is killed).
        for (;;) {
            await new Promise(res => setTimeout(res, 1500));
            let st;
            try { st = await (await fetch('tools.php?action=job_status&job=' + jobId)).json(); }
            catch (e) { if (stopped) { showFinal({ok:false, killed:true, error:'Stopped.'}); return; } continue; }
            if (!st.ok) { showFinal({ok:false, error: st.error || 'job lost'}); return; }
            if (st.status === 'running') {
                inflightTouch(flightId, st.elapsed_ms);
                if (bodyEl) bodyEl.innerHTML = '⏳ Running ' + escapeHtml(preset.tool) + ' — ' + Math.round(st.elapsed_ms / 1000) + 's' +
                    (st.log_tail ? '<pre style="font-size:9.5px;background:var(--bg-darker);padding:6px;margin-top:6px;border-radius:3px;overflow:auto;max-height:120px;color:var(--text-muted);">' + escapeHtml(st.log_tail.split('\n').slice(-6).join('\n')) + '</pre>' : '');
                continue;
            }
            showFinal(st.result || {ok:false, error:'no result'});
            cockpitNotifyIfAway('Tool run ' + ((st.result && st.result.ok) ? 'finished' : 'failed') + ': ' + preset.label, (st.result && st.result.output) ? st.result.output : (st.result && st.result.error ? st.result.error : ''));
            return;
        }
    } catch(e) {
        if (bodyEl) bodyEl.textContent = '[ERROR] ' + e.message;
        appendError(T('msg.tool.run.failed.message', 'Tool run failed: {message}', {message: e.message}));
    } finally {
        if (flightId) inflightDone(flightId);
        setLoading(false);
    }
}
// E1: edit the current project's COCKPIT.md (agent context, auto-loaded each turn)
async function editCockpitMd() {
    const proj = currentProject;
    if (!proj || proj === '_standalone') {
        appendError(T('msg.cockpit.md.is.per.project.switch.to.a.projec', 'COCKPIT.md is per-project. Switch to a project first (Free chats have no project context file).'));
        return;
    }
    // Load existing content (if any)
    let content = '';
    try {
        const r = await fetch('files.php?action=read&project=' + encodeURIComponent(proj) +
                              '&path=' + encodeURIComponent('COCKPIT.md'));
        const d = await r.json();
        if (d.ok) content = d.content || '';
    } catch(e) {}
    if (content === '') {
        // Seed a helpful template on first creation
        content = '# ' + proj + ' — Project Context\n\n' +
            '<!-- This file is auto-loaded into every agent prompt for this project.\n' +
            '     Keep it concise (under 8 KB). Describe stack, conventions, goals. -->\n\n' +
            '## Stack\n- \n\n## Conventions\n- \n\n## Current focus\n- \n';
    }
    let ov = document.getElementById('cockpitmd-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'cockpitmd-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(760px,94vw);max-height:90vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;">' +
        '<span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">description</span> ' +
        'COCKPIT.md — ' + escHtml(proj) + '</h2>' +
        '<span class="rp-action-btn" id="cockpitmd-close" style="cursor:pointer;">×</span></div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-bottom:6px;">' +
        'Auto-loaded into every prompt for this project (capped at 8 KB). Describe the stack, conventions, and current goals so the agent always has context.</div>' +
        '<textarea id="cockpitmd-text" spellcheck="false" ' +
        'style="width:100%;height:50vh;box-sizing:border-box;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:12px;padding:8px;resize:vertical;">' +
        escHtml(content) + '</textarea>' +
        '<div id="cockpitmd-size" style="font-size:10px;color:var(--text-muted);margin-top:4px;"></div>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:10px;">' +
        '<button class="rp-action-btn" id="cockpitmd-cancel">Cancel</button>' +
        '<button class="rp-action-btn" id="cockpitmd-save" style="background:var(--bg-active);">Save COCKPIT.md</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    const ta = document.getElementById('cockpitmd-text');
    const sizeEl = document.getElementById('cockpitmd-size');
    const updateSize = () => {
        const bytes = new Blob([ta.value]).size;
        sizeEl.textContent = bytes + ' bytes' + (bytes > 8192 ? ' — over 8 KB, will be truncated in prompts' : '');
        sizeEl.style.color = bytes > 8192 ? 'var(--accent-orange)' : 'var(--text-muted)';
    };
    ta.addEventListener('input', updateSize);
    updateSize();
    const close = () => ov.remove();
    document.getElementById('cockpitmd-close').onclick = close;
    document.getElementById('cockpitmd-cancel').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('cockpitmd-save').onclick = async () => {
        try {
            const r = await fetch('files.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'write_file', project:proj, path:'COCKPIT.md', content: ta.value})
            });
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error||'')})); return; }
            appendSystem(T('msg.saved.cockpit.md.for.project.proj.size.bytes', 'Saved COCKPIT.md for project "{proj}" ({size} bytes). It will be included in every prompt.', {proj: proj, size: d.size}));
            close();
        } catch(e) { appendError(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message})); }
    };
}

// Open any cockpit-managed location in the system file manager (nemo) as the
// owner user, via launch_cli.php?mode=files. Path whitelist enforced server-side.
async function openInFiles(path) {
    if (!path) return;
    try {
        const r = await fetch('launch_cli.php?mode=files&dir=' + encodeURIComponent(path));
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.open.folder.failed.error', 'Open folder failed: {error}', {error: (d.error || 'unknown')})); return; }
        appendSystem(T('msg.opened.dir.in.fm', 'Opened {dir} in {fm}.', {dir: (d.dir || path), fm: (d.fm || 'file manager')}));
    } catch(e) { appendError(T('msg.open.folder.failed.message', 'Open folder failed: {message}', {message: e.message})); }
}
// Small reusable "open in file manager" icon button markup.
function _openFolderBtn(path, title) {
    return '<button class="rp-action-btn" data-openfiles="' + escHtml(path) + '" ' +
        'title="' + escHtml(title || ('Open ' + path + ' in file manager')) + '" ' +
        'style="padding:2px 6px;display:inline-flex;align-items:center;gap:3px;">' +
        '<span class="material-symbols-rounded" style="font-size:13px;">folder_open</span></button>';
}
// Global delegate: any element with data-openfiles opens that path.
document.addEventListener('click', e => {
    const b = e.target.closest && e.target.closest('[data-openfiles]');
    if (b) { e.preventDefault(); openInFiles(b.getAttribute('data-openfiles')); }
});

async function rpLoadConfig() {
    const listEl = document.getElementById('rp-list-config');
    listEl.innerHTML = '<div class="sidebar-empty">Loading config snapshot…</div>';
    try {
        const url = 'config.php?action=snapshot'
                  + '&project=' + encodeURIComponent(currentProject || '')
                  + '&chat=' + encodeURIComponent(currentChat || '');
        const res  = await fetch(url);
        const data = await res.json();
        if (!data.ok) { listEl.innerHTML = '<div class="sidebar-empty">Error.</div>'; return; }

        // Also fetch path settings via library.php (paths_get is kind-agnostic)
        let paths = {};
        try {
            const pr = await fetch('library.php?action=paths_get&kind=approvals');
            const pd = await pr.json();
            if (pd.ok) paths = pd.config || {};
        } catch(e) {}

        listEl.innerHTML = '';

        // ── Storage paths settings (editable) ──────────────────────────────
        const settingsGrp = document.createElement('div');
        settingsGrp.className = 'rp-cfg-group';
        settingsGrp.innerHTML = '<div class="rp-cfg-group-hdr">Settings · Storage Paths</div>';
        const pathsBox = document.createElement('div');
        pathsBox.className = 'rp-cfg-file exists';
        let pathsHtml = '<div class="rp-cfg-file-name">Configurable directories ' +
                        '<span style="float:right;font-size:9px;opacity:0.6;cursor:pointer;" data-act="reset">↻ reset to defaults</span>' +
                        '</div><div class="rp-cfg-file-meta">Edit paths and click Save Paths</div>' +
                        '<div style="margin-top:6px;display:flex;flex-direction:column;gap:4px;">';
        ['library','snippets','sources','code'].forEach(k => {
            pathsHtml += '<div style="display:flex;align-items:center;gap:6px;">' +
                '<span style="min-width:64px;font-size:10px;color:var(--text-muted);">' + k + ':</span>' +
                '<input type="text" data-pathkey="' + k + '" value="' + escHtml(paths[k] || '') +
                '" style="flex:1;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);' +
                'border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:10px;padding:3px 5px;">' +
                (paths[k] ? _openFolderBtn(paths[k], 'Open ' + k + ' folder') : '') +
                '</div>';
        });
        pathsHtml += '<div style="display:flex;gap:4px;margin-top:4px;">' +
                     '<button class="rp-action-btn" data-act="save-paths">Save Paths</button>' +
                     '</div></div>';
        pathsBox.innerHTML = pathsHtml;

        pathsBox.addEventListener('click', async e => {
            const act = e.target.dataset?.act;
            if (act === 'save-paths') {
                const newPaths = {};
                pathsBox.querySelectorAll('input[data-pathkey]').forEach(inp => {
                    const v = inp.value.trim();
                    if (v) newPaths[inp.dataset.pathkey] = v;
                });
                const r = await fetch('library.php?kind=approvals', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({action:'paths_set', config:newPaths})
                });
                const d = await r.json();
                if (!d.ok) { appendError(T('msg.save.paths.failed.error', 'Save paths failed: {error}', {error: (d.error||'')})); return; }
                appendSystem(T('msg.storage.paths.updated', 'Storage paths updated.'));
                rpLoadConfig();
            }
            if (act === 'reset') {
                if (!await cockpitConfirm('Reset paths?', 'Reset all storage paths to defaults?', 'Reset', {danger:true, icon:'restart_alt'})) return;
                // Reset = save empty config
                const r = await fetch('library.php?kind=approvals', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({action:'paths_set', config:{}})
                });
                const d = await r.json();
                if (!d.ok) { appendError(T('msg.reset.failed.error', 'Reset failed: {error}', {error: (d.error||'')})); return; }
                appendSystem(T('msg.storage.paths.reset.to.defaults', 'Storage paths reset to defaults.'));
                rpLoadConfig();
            }
        });
        settingsGrp.appendChild(pathsBox);
        listEl.appendChild(settingsGrp);

        // ── Open Locations (resolved cockpit dirs → system file manager) ────
        try {
            const lr = await fetch('launch_cli.php?mode=paths');
            const ld = await lr.json();
            if (ld.ok && ld.locations) {
                const locGrp = document.createElement('div');
                locGrp.className = 'rp-cfg-group';
                locGrp.innerHTML = '<div class="rp-cfg-group-hdr">Settings · Open Locations</div>';
                const locBox = document.createElement('div');
                locBox.className = 'rp-cfg-file exists';
                let lh = '<div class="rp-cfg-file-meta">Open a cockpit folder in the system file manager.</div>' +
                         '<div style="margin-top:6px;display:flex;flex-direction:column;gap:4px;">';
                const order = ['web_root','cockpit_data','projects_root','home','library',
                               'snippets','sources','code','approvals','queue_dir','response_dir'];
                order.forEach(k => {
                    const loc = ld.locations[k]; if (!loc) return;
                    lh += '<div style="display:flex;align-items:center;gap:6px;">' +
                        '<span style="min-width:96px;font-size:10px;color:var(--text-muted);">' + k +
                        (loc.exists ? '' : ' <span style="color:var(--warn,#c80);">(missing)</span>') + ':</span>' +
                        '<span style="flex:1;font-family:var(--font-mono);font-size:10px;color:var(--text-dim);' +
                        'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' + escHtml(loc.path) + '">' +
                        escHtml(loc.path) + '</span>' +
                        (loc.exists ? _openFolderBtn(loc.path, 'Open ' + k) : '') +
                        '</div>';
                });
                lh += '</div>';
                locBox.innerHTML = lh;
                locGrp.appendChild(locBox);
                listEl.appendChild(locGrp);
            }
        } catch(e) { /* non-fatal */ }

        // ── A7: Workers/Tools auto-route toggles (per-project) ──────────────
        try {
            const proj = currentProject || '';
            const wAR  = await (await fetch('workers.php?action=auto_route_status&project=' + encodeURIComponent(proj))).json();
            const tAR  = await (await fetch('tools.php?action=auto_route_status&project='   + encodeURIComponent(proj))).json();
            const arGrp = document.createElement('div');
            arGrp.className = 'rp-cfg-group';
            arGrp.innerHTML = '<div class="rp-cfg-group-hdr">Settings · Auto-route (project: ' + escHtml(proj || 'default') + ')</div>';
            const arBox = document.createElement('div');
            arBox.className = 'rp-cfg-file exists';
            arBox.innerHTML =
                '<div class="rp-cfg-file-meta">When ON, %%WORKER:%% and %%TOOL:%% markers in agent output execute automatically; when OFF, they are written but not executed.</div>' +
                '<div style="display:flex;flex-direction:column;gap:6px;margin-top:6px;">' +
                '<label style="display:flex;align-items:center;gap:6px;cursor:pointer;">' +
                '<input type="checkbox" data-act="ar-workers"' + ((wAR.ok && wAR.enabled) ? ' checked' : '') + '>' +
                '<span>Workers auto-route</span></label>' +
                '<label style="display:flex;align-items:center;gap:6px;cursor:pointer;">' +
                '<input type="checkbox" data-act="ar-tools"' + ((tAR.ok && tAR.enabled) ? ' checked' : '') + '>' +
                '<span>Tools auto-route</span></label>' +
                '</div>';
            arBox.addEventListener('change', async e => {
                const act = e.target.dataset?.act;
                if (!act) return;
                const endpoint = (act === 'ar-workers') ? 'workers.php' : 'tools.php';
                const r = await fetch(endpoint + '?action=set_auto_route', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({project: proj, enabled: e.target.checked})
                });
                const d = await r.json();
                if (!d.ok) { appendError(T('msg.auto.route.toggle.failed.error', 'Auto-route toggle failed: {error}', {error: (d.error||'')})); return; }
                appendSystem(act === 'ar-workers' ? 'Workers' : 'Tools' +
                             ' auto-route: ' + (e.target.checked ? 'ON' : 'OFF'));
            });
            arGrp.appendChild(arBox);
            listEl.appendChild(arGrp);
        } catch(e) { /* non-fatal — backend may not expose status yet */ }

        // (Settings · Window moved into the sessions card's window row — shell-channel.js, 2026-09-21)
        // ── B4 + B6: Attachment Settings (routes overrides + inline threshold) ─
        const attGrp = document.createElement('div');
        attGrp.className = 'rp-cfg-group';
        attGrp.innerHTML = '<div class="rp-cfg-group-hdr">Settings · Attachments</div>';
        const attBox = document.createElement('div');
        attBox.className = 'rp-cfg-file exists';
        let routes = {};
        try { routes = JSON.parse(localStorage.getItem('cockpit_attach_routes') || '{}'); } catch(e) {}
        const thr = _inlineTextThreshold();
        let attHtml = '<div class="rp-cfg-file-name">Inline-text threshold</div>' +
            '<div style="display:flex;align-items:center;gap:6px;margin-top:4px;">' +
            '<input type="number" id="att-threshold" min="1024" max="16777216" step="1024" value="' + thr +
            '" style="width:100px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:10px;padding:3px 5px;">' +
            '<span style="font-size:10px;color:var(--text-muted);">bytes (' + Math.round(thr/1024) + ' KB) — files bigger than this are saved, not inlined</span>' +
            '<button class="rp-action-btn" data-act="save-thr">Save</button>' +
            '</div>' +
            '<div class="rp-cfg-file-name" style="margin-top:10px;">Per-extension route overrides</div>' +
            '<div class="rp-cfg-file-meta">Override the default route for a file extension. Plans: inline-text, tools-preset (with preset id), image-vision, save-only.</div>' +
            '<div id="att-routes-rows" style="margin-top:6px;display:flex;flex-direction:column;gap:4px;">';
        const extKeys = Object.keys(routes);
        if (extKeys.length === 0) {
            attHtml += '<div style="font-size:10px;opacity:0.6;">No overrides set. Add one below.</div>';
        } else {
            extKeys.forEach(ext => {
                const r = routes[ext] || {};
                attHtml += '<div style="display:flex;gap:4px;align-items:center;" data-extrow="' + escHtml(ext) + '">' +
                    '<span style="min-width:60px;font-size:10px;font-family:var(--font-mono);">' + escHtml(ext) + '</span>' +
                    '<select data-fld="plan" style="font-size:10px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 4px;">' +
                    ['inline-text','tools-preset','image-vision','save-only'].map(p =>
                        '<option' + (r.plan===p?' selected':'') + '>'+p+'</option>').join('') +
                    '</select>' +
                    '<input type="text" data-fld="preset" placeholder="preset (e.g. pandoc:to-markdown)" value="' + escHtml(r.preset||'') + '"' +
                    ' style="flex:1;font-size:10px;font-family:var(--font-mono);background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 4px;">' +
                    '<button class="rp-action-btn" data-act="del-route" data-ext="' + escHtml(ext) + '">×</button>' +
                    '</div>';
            });
        }
        attHtml += '</div>' +
            '<div style="display:flex;gap:4px;margin-top:6px;align-items:center;">' +
            '<input type="text" id="att-new-ext" placeholder="ext (e.g. pdf)" style="width:80px;font-size:10px;font-family:var(--font-mono);background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 4px;">' +
            '<button class="rp-action-btn" data-act="add-route">Add override</button>' +
            '<button class="rp-action-btn" data-act="save-routes">Save Routes</button>' +
            '<button class="rp-action-btn" data-act="reset-routes" style="margin-left:auto;">↻ Reset</button>' +
            '</div>';
        attBox.innerHTML = attHtml;
        attBox.addEventListener('click', async e => {
            const act = e.target.dataset?.act;
            if (act === 'save-thr') {
                const v = parseInt(document.getElementById('att-threshold').value, 10);
                if (v > 0) { localStorage.setItem('cockpit_inline_threshold', String(v)); appendSystem(T('msg.inline.threshold.v.kb', 'Inline threshold: {v} KB', {v: Math.round(v/1024)})); rpLoadConfig(); }
            } else if (act === 'add-route') {
                const ext = document.getElementById('att-new-ext').value.trim().replace(/^\./,'').toLowerCase();
                if (!ext) return;
                let cur = {};
                try { cur = JSON.parse(localStorage.getItem('cockpit_attach_routes') || '{}'); } catch(_) {}
                if (!cur[ext]) cur[ext] = { plan: 'save-only', preset: '' };
                localStorage.setItem('cockpit_attach_routes', JSON.stringify(cur));
                rpLoadConfig();
            } else if (act === 'del-route') {
                const ext = e.target.dataset.ext;
                let cur = {};
                try { cur = JSON.parse(localStorage.getItem('cockpit_attach_routes') || '{}'); } catch(_) {}
                delete cur[ext];
                localStorage.setItem('cockpit_attach_routes', JSON.stringify(cur));
                rpLoadConfig();
            } else if (act === 'save-routes') {
                const next = {};
                attBox.querySelectorAll('[data-extrow]').forEach(row => {
                    const ext = row.dataset.extrow;
                    const plan = row.querySelector('[data-fld="plan"]').value;
                    const preset = row.querySelector('[data-fld="preset"]').value.trim();
                    const entry = { plan };
                    if (preset) entry.preset = preset;
                    next[ext] = entry;
                });
                localStorage.setItem('cockpit_attach_routes', JSON.stringify(next));
                appendSystem(T('msg.attachment.routes.saved.keys.overrides', 'Attachment routes saved ({keys} overrides).', {keys: Object.keys(next).length}));
            } else if (act === 'reset-routes') {
                if (!await cockpitConfirm('Reset routes?', 'Reset all attachment route overrides?', 'Reset', {danger:true, icon:'restart_alt'})) return;
                localStorage.removeItem('cockpit_attach_routes');
                appendSystem(T('msg.attachment.route.overrides.cleared', 'Attachment route overrides cleared.'));
                rpLoadConfig();
            }
        });
        attGrp.appendChild(attBox);
        listEl.appendChild(attGrp);

        if (data.globals) {
            for (const agent in data.globals) {
                const grp = document.createElement('div');
                grp.className = 'rp-cfg-group';
                grp.innerHTML = '<div class="rp-cfg-group-hdr">Global · ' + escHtml(agent) + '</div>';
                for (const fname in data.globals[agent]) {
                    grp.appendChild(rpBuildCfgFile(fname, data.globals[agent][fname]));
                }
                listEl.appendChild(grp);
            }
        }
        if (data.project) {
            const grp = document.createElement('div');
            grp.className = 'rp-cfg-group';
            grp.innerHTML = '<div class="rp-cfg-group-hdr">Project · ' + escHtml(currentProject) + '</div>';
            for (const fname in data.project) {
                grp.appendChild(rpBuildCfgFile(fname, data.project[fname]));
            }
            listEl.appendChild(grp);
        }
        if (data.chat_meta) {
            const grp = document.createElement('div');
            grp.className = 'rp-cfg-group';
            grp.innerHTML = '<div class="rp-cfg-group-hdr">Chat · ' + escHtml(currentChat) + '</div>';
            const meta = data.chat_meta;
            const div = document.createElement('div');
            div.className = 'rp-cfg-file exists';
            div.innerHTML =
                '<div class="rp-cfg-file-name">chat_' + escHtml(meta.chat || '') + '.json</div>' +
                '<div class="rp-cfg-file-meta">' +
                    'exchanges: ' + meta.exchanges_count +
                    '  ·  size: ' + (meta.file_size || 0) + 'B' +
                    '  ·  agents: [' + (meta.agents_used || []).join(', ') + ']' +
                    (meta.first_message_at ? '<br>first: ' + meta.first_message_at : '') +
                    (meta.last_message_at  ? '  ·  last: '  + meta.last_message_at  : '') +
                '</div>';
            grp.appendChild(div);
            listEl.appendChild(grp);
        }
    } catch(e) {
        listEl.innerHTML = '<div class="sidebar-empty">Failed.</div>';
    }
}

function rpBuildCfgFile(name, info) {
    const div = document.createElement('div');
    if (!info || !info.exists) {
        div.className = 'rp-cfg-file missing';
        div.innerHTML = '<div class="rp-cfg-file-name">' + escHtml(name) + '</div>' +
                        '<div class="rp-cfg-file-meta">not present at: ' + escHtml(info?.path || '') + '</div>' +
                        (info?.path ? '<div class="rp-cfg-file-actions" style="display:flex;margin-top:4px;">' +
                          '<button class="rp-action-btn" data-act="create">Create empty</button></div>' : '');
        if (info?.path) {
            div.addEventListener('click', async e => {
                if (e.target.dataset?.act !== 'create') return;
                e.stopPropagation();
                const r = await fetch('config.php', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({action:'save_file', path:info.path, content:''})
                });
                const d = await r.json();
                if (!d.ok) { appendError(T('msg.create.failed.error', 'Create failed: {error}', {error: (d.error||'')})); return; }
                appendSystem(T('msg.created.path', 'Created {path}', {path: info.path}));
                rpLoadConfig();
            });
        }
        return div;
    }
    div.className = 'rp-cfg-file exists';
    const sizeStr  = info.size != null ? info.size + 'B' : '';
    const mtimeStr = info.mtime ? fmtDateTime(new Date(info.mtime * 1000)) : '';
    const path     = info.path || '';
    const safeId   = 'cfg_' + Math.random().toString(36).slice(2, 10);

    div.innerHTML =
        '<div class="rp-cfg-file-name">' + escHtml(name) +
            '<span style="float:right;font-size:9px;opacity:0.6;cursor:pointer;" data-act="edit"><span class="material-symbols-rounded ico">edit</span> edit</span></div>' +
        '<div class="rp-cfg-file-meta">' + sizeStr + (mtimeStr ? '  ·  ' + mtimeStr : '') +
            (path ? '  ·  <span style="opacity:0.55;">' + escHtml(path) + '</span>' : '') + '</div>' +
        '<div class="rp-cfg-file-content">' + escHtml(info.content || '') + '</div>' +
        '<textarea class="rp-cfg-file-edit" style="display:none;width:100%;min-height:180px;' +
            'background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);' +
            'border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:10px;' +
            'padding:6px;box-sizing:border-box;">' + escHtml(info.content || '') + '</textarea>' +
        '<div class="rp-cfg-file-actions" style="display:none;margin-top:4px;gap:4px;">' +
            '<button class="rp-action-btn" data-act="save" data-path="' + escHtml(path) + '">Save</button>' +
            '<button class="rp-action-btn" data-act="cancel">Cancel</button>' +
        '</div>';

    div.addEventListener('click', async e => {
        const act = e.target.dataset?.act;
        if (act === 'save') {
            e.stopPropagation();
            const ta = div.querySelector('.rp-cfg-file-edit');
            const r = await fetch('config.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'save_file', path: e.target.dataset.path, content: ta.value})
            });
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error||'')})); return; }
            appendSystem(T('msg.saved.path.bytes.bytes', 'Saved {path} ({bytes} bytes)', {path: e.target.dataset.path, bytes: d.bytes}));
            rpLoadConfig();
            return;
        }
        if (act === 'cancel') { e.stopPropagation(); rpLoadConfig(); return; }
        if (act === 'edit') {
            e.stopPropagation();
            if (!div.classList.contains('active')) div.classList.add('active');
            div.querySelector('.rp-cfg-file-content').style.display = 'none';
            div.querySelector('.rp-cfg-file-edit').style.display    = 'block';
            div.querySelector('.rp-cfg-file-actions').style.display = 'flex';
            div.querySelector('.rp-cfg-file-edit').focus();
            return;
        }

        // Plain click — toggle active
        const list = document.getElementById('rp-list-config');
        list.querySelectorAll('.rp-cfg-file.active').forEach(el => {
            if (el !== div) el.classList.remove('active');
        });
        div.classList.toggle('active');
    });
    return div;
}

// ── Auto-load on tab switch ──────────────────────────────────────────────────
const _origSwitchTab = switchTab;
switchTab = function(side, panelId, tabEl) {
    _origSwitchTab(side, panelId, tabEl);
    if (side !== 'right') return;
    if (['library','snippets','sources','code'].includes(panelId)) rpRefreshList(panelId);
    else if (panelId === 'config') rpLoadConfig();
    else if (panelId === 'search') {
        // Auto-focus the search input so user can just start typing
        const sq = document.getElementById('search-q');
        if (sq) setTimeout(() => sq.focus(), 50);
    }
};

// Poll proposals every 10s — agents may add async via crud_executor
setInterval(() => { rpRefreshProposals(); }, 10000);

// =============================================================================
