// =============================================================================
// SUPPLIER SLOTS — configurable CLI tools for primary/fallback cards
// =============================================================================
let _supplierSlots = null;

// Per-card help — a quick reference of the card's slash-commands (from commands.php)
// and its controls (the effort picker's options + what each does). Works for the two
// Agent-CLI cards ('claude'/'gemini' DOM slots → their real supplier) and shows a short
// purpose line for the local/workers/tools cards.
const _cardPurpose = {
    ollama:  'Local LLM server (Ollama / LocalAI / Dual). Runs models on your machine — no key, offline. Pick the model in the card; VRAM + tok/s show live.',
    workers: 'Cloud API providers (Groq, OpenRouter, Gemini API). Fast REST calls with your own keys — manage keys and models in the Workers panel.',
    tools:   'Local CLI tools (ffmpeg, whisper, pandoc, …). Invoked on files with %%TOOL%% markers; add/edit tools in the Tools panel.',
};
async function showCardHelp(domSlot) {
    const supplierId = (window._slotSupplier || {})[domSlot] || domSlot;
    const cat = (_supplierSlots && _supplierSlots.cli_suppliers) || {};
    const sup = cat[supplierId];
    const title = (sup && sup.name) || domSlot.toUpperCase();

    const effSel = document.getElementById(domSlot + '-effort');
    const effOpts = (effSel && effSel.style.display !== 'none') ? [...effSel.options].map(o => o.text) : [];
    const modelSel = document.getElementById(domSlot + '-model');

    let ov = document.getElementById('card-help'); if (ov) ov.remove();
    ov = document.createElement('div'); ov.id = 'card-help';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10001;background:rgba(0,0,0,.5);display:flex;align-items:flex-start;justify-content:center;padding-top:10vh;font-family:var(--font-ui);';
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(560px,94vw);max-height:78vh;overflow:auto;box-shadow:0 8px 32px rgba(0,0,0,.6);padding:14px 18px;">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h3 style="margin:0;font-size:14px;flex:1;color:var(--text-primary);">' + escHtml(title) + ' — help</h3>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="document.getElementById(\'card-help\').remove()">×</span></div>' +
        '<div id="card-help-body" style="font-size:12px;color:var(--text-primary);">Loading…</div></div>';
    document.body.appendChild(ov);
    const body = ov.querySelector('#card-help-body');

    let html = '';
    if (_cardPurpose[domSlot]) html += '<p style="color:var(--text-dim);margin:0 0 12px;">' + escHtml(_cardPurpose[domSlot]) + '</p>';

    // Controls (effort) section
    if (effOpts.length) {
        html += '<div style="font-weight:700;color:var(--claude);margin:4px 0;">Controls</div>' +
            '<div style="color:var(--text-dim);margin:0 0 4px;">Effort (' + (effSel.dataset.inject === 'cli_args' ? 'CLI flag' : 'prompt nudge') + '):</div>' +
            '<ul style="margin:0 0 12px;padding-left:18px;">' + effOpts.map(o => '<li>' + escHtml(o) + '</li>').join('') + '</ul>';
    }
    if (modelSel) html += '<div style="color:var(--text-dim);margin:0 0 12px;">Model: <b>' + escHtml(modelSel.value || '—') + '</b> · ↻ refreshes the live list · <span class="material-symbols-rounded ico">settings</span> edits <code>' + escHtml(supplierId) + '_controls.json</code></div>';

    // Commands section (agent cards)
    html += '<div style="font-weight:700;color:var(--claude);margin:4px 0;">Slash-commands</div><div id="card-help-cmds" style="color:var(--text-dim);">Loading…</div>';
    body.innerHTML = html;

    try {
        const d = await fetch('commands.php?action=list&supplier=' + encodeURIComponent(supplierId)).then(r => r.json());
        const cmds = (d && d.commands) || [];
        document.getElementById('card-help-cmds').innerHTML = cmds.length
            ? '<ul style="margin:2px 0 0;padding-left:18px;">' + cmds.map(c =>
                '<li><b style="color:var(--claude);">/' + escHtml(c.name) + '</b>' + (c.desc ? ' — ' + escHtml(c.desc) : '') + '</li>').join('') + '</ul>' +
              '<p style="margin-top:8px;color:var(--text-muted);">Insert one from the <b>Commands</b> button on the toolbar.</p>'
            : '<span>No slash-commands detected for this card.</span>';
    } catch (e) { document.getElementById('card-help-cmds').textContent = T('msg.could.not.load.commands', 'Could not load commands.'); }
}

// Command palette — lists the ACTIVE agent's slash-commands (discovered by
// commands.php from its plugins/built-ins) and inserts "/cmd " into the prompt.
// Active agent → its slot's supplier: claude/gemini slots map to their CLI supplier;
// ollama/workers have no slash commands → fall back to the primary (Card 1) supplier.
// Open the palette scoped to a specific card slot's supplier (per-card Commands button).
function openCommandPaletteForSlot(domSlot) {
    return openCommandPalette((window._slotSupplier || {})[domSlot] || domSlot);
}
async function openCommandPalette(supplierOverride) {
    let supplierId = supplierOverride;
    if (!supplierId) {
        const agent = window._activeAgent || 'claude';
        const slot  = (agent === 'gemini') ? 'gemini' : 'claude';
        supplierId = (window._slotSupplier || {})[slot] || slot;
    }
    let ov = document.getElementById('cmd-palette'); if (ov) ov.remove();
    ov = document.createElement('div'); ov.id = 'cmd-palette';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10001;background:rgba(0,0,0,.5);display:flex;align-items:flex-start;justify-content:center;padding-top:12vh;font-family:var(--font-ui);';
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(520px,92vw);max-height:70vh;overflow:auto;box-shadow:0 8px 32px rgba(0,0,0,.6);">' +
        '<div style="padding:10px 14px;border-bottom:1px solid var(--border-dim);display:flex;align-items:center;gap:8px;">' +
        '<input id="cmd-filter" placeholder="Filter commands…" style="flex:1;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;font-size:12px;border-radius:4px;">' +
        '<span style="font-size:10px;color:var(--text-dim);">' + escHtml(supplierId) + '</span></div>' +
        '<div id="cmd-list" style="padding:6px;font-size:12px;">Loading…</div></div>';
    document.body.appendChild(ov);
    const listEl = ov.querySelector('#cmd-list'), filt = ov.querySelector('#cmd-filter');
    let cmds = [];
    try {
        const d = await fetch('commands.php?action=list&supplier=' + encodeURIComponent(supplierId)).then(r => r.json());
        cmds = (d && d.commands) || [];
    } catch (e) {}
    const render = (q) => {
        const f = cmds.filter(c => !q || c.name.toLowerCase().includes(q) || (c.desc || '').toLowerCase().includes(q));
        listEl.innerHTML = f.length ? f.map(c =>
            '<div class="cmd-row" data-cmd="' + escAttr(c.name) + '" style="padding:6px 8px;border-radius:4px;cursor:pointer;display:flex;gap:8px;" onmouseover="this.style.background=\'var(--bg-active)\'" onmouseout="this.style.background=\'\'">' +
            '<b style="color:var(--claude);white-space:nowrap;">/' + escHtml(c.name) + '</b>' +
            '<span style="color:var(--text-dim);overflow:hidden;text-overflow:ellipsis;">' + escHtml(c.desc || '') + '</span></div>').join('')
            : '<div style="padding:10px;color:var(--text-dim);">No commands found for ' + escHtml(supplierId) + '.</div>';
        [...listEl.querySelectorAll('.cmd-row')].forEach(r => r.onclick = () => { insertCommand(r.dataset.cmd); ov.remove(); });
    };
    render('');
    filt.oninput = () => render(filt.value.toLowerCase());
    filt.focus();
}
function insertCommand(name) {
    const ta = document.getElementById('prompt-in'); if (!ta) return;
    ta.value = '/' + name + ' ' + (ta.value || '');
    ta.focus();
    try { ta.setSelectionRange(ta.value.length, ta.value.length); } catch (e) {}
}

// Per-SUPPLIER settings (model + effort) persisted in localStorage, so a supplier's
// choices follow it between cards (set Claude's model on Card 1 → still there when
// Claude moves to Card 2). Keyed by supplier id, not by slot.
function _supPrefGet(id) {
    try { return JSON.parse(localStorage.getItem('cockpit_sup_pref_' + id) || '{}') || {}; }
    catch (e) { return {}; }
}
function _supPrefSet(id, patch) {
    if (!id) return;
    try {
        const cur = _supPrefGet(id);
        localStorage.setItem('cockpit_sup_pref_' + id, JSON.stringify({ ...cur, ...patch }));
    } catch (e) { /* storage unavailable → in-memory only for this load */ }
}
// Save the slot's current model+effort under the supplier that fills it.
function _saveSlotPref(domSlot) {
    const id = (window._slotSupplier || {})[domSlot];
    if (!id) return;
    const m = document.getElementById(domSlot + '-model');
    const e = document.getElementById(domSlot + '-effort');
    _supPrefSet(id, { model: m ? m.value : undefined, effort: e ? e.value : undefined });
}
// Attach save-on-change to both cards' model + effort selects (once).
function _wirePrefListeners() {
    if (window._prefListenersWired) return;
    window._prefListenersWired = true;
    [['claude-model','claude'], ['claude-effort','claude'], ['gemini-model','gemini'], ['gemini-effort','gemini']]
        .forEach(([elId, slot]) => {
            const el = document.getElementById(elId);
            if (el) el.addEventListener('change', () => _saveSlotPref(slot));
        });
}

// Fill a CLI card's model <select> from the LIVE list (curated aliases + current
// models.dev entries), then restore this SUPPLIER's saved model (falls back to the
// prior selection). On failure it leaves the existing options (offline-safe).
async function populateModelSelect(selectId, supplierId) {
    const sel = document.getElementById(selectId);
    if (!sel || !supplierId) return;
    try {
        const r = await fetch('suppliers.php?action=models&id=' + encodeURIComponent(supplierId));
        const d = await r.json();
        if (!d.ok || !Array.isArray(d.models) || !d.models.length) return;   // keep existing
        const prev = sel.value;
        sel.innerHTML = d.models.map((m, i) =>
            '<option value="' + escAttr(m.id) + '" data-oi="' + i + '">' + escHtml(m.label || m.id) + '</option>').join('');
        const want = _supPrefGet(supplierId).model || prev;   // this supplier's saved choice first
        if (want && [...sel.options].some(o => o.value === want)) sel.value = want;
        // Re-apply the card's chosen model-list sort — innerHTML rebuild above
        // resets to server order, so a user's A→Z / Size sort would otherwise be
        // lost on every live refresh.
        _applyModelSort(selectId);
    } catch (e) { /* keep existing options */ }
}

// ── Native <select> model-list sort (Card 1 & 2) — mirrors sortOllamaTier's
// modes for the custom-list panels, but operates on a plain <select>'s
// <option>s. Size = param count parsed from the model name (cloud models with
// no parsable size fall back to alpha). Mode persists per select so a live
// ↻ refresh (which rebuilds the options) keeps the chosen order.
const _modelSortMode = {};
// Compact sort affordance for Card 1 & 2 — a single icon (fits the cramped
// card's control row, unlike a full dropdown which wrapped off the card edge)
// that cycles original → A→Z → size↑ → size↓. Active (non-default) modes tint
// the icon so the current state is visible at a glance.
const _MODEL_SORT_CYCLE = ['default', 'alpha', 'small', 'large'];
const _MODEL_SORT_LABEL = { default: 'original order', alpha: 'A→Z', small: 'size ↑', large: 'size ↓' };
function cycleModelSort(targetId, el) {
    const cur = _modelSortMode[targetId] || 'default';
    const next = _MODEL_SORT_CYCLE[(_MODEL_SORT_CYCLE.indexOf(cur) + 1) % _MODEL_SORT_CYCLE.length];
    _modelSortMode[targetId] = next;
    _applyModelSort(targetId);
    if (el) {
        el.title = 'Sort models: ' + _MODEL_SORT_LABEL[next] + ' (click to cycle)';
        el.style.color = next === 'default' ? '' : 'var(--gemini)';
    }
}
function _applyModelSort(targetId) {
    const mode = _modelSortMode[targetId];
    if (!mode || mode === 'default') { _applyModelSortOrder(targetId, (a, b) => (+a.dataset.oi || 0) - (+b.dataset.oi || 0)); return; }
    const nameOf = o => (o.textContent || '').trim().toLowerCase();
    const sizeOf = o => ollamaParamB(o.value || nameOf(o));
    const bySize = dir => (a, b) => {
        const sa = sizeOf(a), sb = sizeOf(b);
        if (sa < 0 && sb < 0) return nameOf(a).localeCompare(nameOf(b));
        if (sa < 0) return 1; if (sb < 0) return -1;
        return dir * (sa - sb) || nameOf(a).localeCompare(nameOf(b));
    };
    const cmp = mode === 'alpha' ? (a, b) => nameOf(a).localeCompare(nameOf(b))
              : mode === 'small' ? bySize(1)
              : mode === 'large' ? bySize(-1)
              : (a, b) => (+a.dataset.oi || 0) - (+b.dataset.oi || 0);
    _applyModelSortOrder(targetId, cmp);
}
function _applyModelSortOrder(targetId, cmp) {
    const sel = document.getElementById(targetId);
    if (!sel || sel.options.length < 2) return;
    const cur = sel.value;
    const opts = [...sel.options];
    opts.sort(cmp);
    opts.forEach(o => sel.appendChild(o));   // appendChild moves in place → reorders
    if (cur && [...sel.options].some(o => o.value === cur)) sel.value = cur;
}

// Manual ↻ — pull a fresh models.dev catalog, then repopulate both CLI cards.
async function refreshCliModels() {
    try { await fetch('models_dev.php?action=refresh'); } catch (e) {}
    if (typeof loadSupplierSlots === 'function') await loadSupplierSlots();
}

// suppliers.php is behind the login. This runs from boot.js, which used to fire
// it before the session was confirmed: the request came back 401, the old code
// returned silently, and _supplierSlots stayed null for the whole session — so
// the Slots button did nothing at all until something else happened to reload
// the config. Same trap version.php had. Wait for the gate, and say so when the
// load genuinely fails instead of leaving a dead button.
async function loadSupplierSlots() {
    try {
        if (typeof authGateReady === 'function') await authGateReady();
        const r = await fetch('suppliers.php?action=config');
        const d = await r.json();
        if (!d.ok) { console.warn('supplier config not loaded:', d.error || r.status); return; }
        _supplierSlots = d;

        const slots = d.slots || {};
        const catalog = d.cli_suppliers || {};
        const primary = catalog[slots.primary];
        const fallback = catalog[slots.fallback];

        // Fill both CLI cards' model dropdowns from the LIVE list (curated + models.dev),
        // regardless of whether the slot is the default or an alias. Async; refines the
        // static/hardcoded options already present.
        populateModelSelect('claude-model', slots.primary);
        populateModelSelect('gemini-model', slots.fallback);

        // Tell the VRAM guard (M2) which slot agents are local-backed. Card 1 dispatches
        // as agent 'claude', Card 2 as 'gemini' (names kept by the de-hardwire), so map
        // by those. Empty until a local-backed agent (e.g. Aider→Ollama) is selected.
        window._slotBackends = {};
        if (primary && primary.local) window._slotBackends['claude'] =
            { runner: primary.backend || 'ollama', model: (document.getElementById('claude-model') || {}).value || '' };
        if (fallback && fallback.local) window._slotBackends['gemini'] =
            { runner: fallback.backend || 'ollama', model: (document.getElementById('gemini-model') || {}).value || '' };

        // Track which supplier fills each slot (for per-supplier pref save/restore).
        window._slotSupplier = { claude: slots.primary, gemini: slots.fallback };

        // How each card's agent can be handed an IMAGE, straight from the catalog
        // (see image_mode in cli_catalog_default.php). Absent = 'describe', the
        // safe default: an agent that cannot see a picture invents one rather
        // than failing, so native handling is opt-in and per agent.
        window._slotImageMode = {
            claude: (catalog[slots.primary]  || {}).image_mode || 'describe',
            gemini: (catalog[slots.fallback] || {}).image_mode || 'describe',
        };
        _wirePrefListeners();

        // Per-supplier controls (effort picker) + retarget each card's tune button to
        // the supplier actually in that slot (Card 1 = 'claude' DOM, Card 2 = 'gemini' DOM).
        loadSupplierControls(slots.primary, 'claude');
        loadSupplierControls(slots.fallback, 'gemini');
        _wireSupplierTune('claude', slots.primary, primary);
        _wireSupplierTune('gemini', slots.fallback, fallback);
        _wireCardButtons('claude', primary);
        _wireCardButtons('gemini', fallback);

        if (primary) {
            const nameEl = document.getElementById('sup-name-claude');
            const labelEl = document.querySelector('#sup-card-claude .sup-label-top');
            if (nameEl) nameEl.innerHTML = escHtml(primary.name.toUpperCase()) + '<span class="sup-name-sub">' + escHtml(_supClassLabel(primary)) + '</span>';
            if (labelEl) labelEl.textContent = primary.name.toUpperCase();
            // De-hardwire Card 1: drive model list + tag from the chosen paid CLI.
            window._primaryName = primary.name.toUpperCase();
            window._primaryAlt  = (slots.primary !== 'claude');
            const pSel = document.getElementById('claude-model');
            if (window._primaryAlt && pSel && Array.isArray(primary.models)) {
                const prev = pSel.value;
                pSel.innerHTML = primary.models.map(m =>
                    '<option value="' + escAttr(m.id) + '">' + escHtml(m.label || m.id) + '</option>').join('');
                if ([...pSel.options].some(o => o.value === prev)) pSel.value = prev;
            }
            // "Open ... CLI in a new terminal" button — was always titled/opening
            // literal Claude regardless of alias (2026-07-02 fix, matches the
            // launch_cli.php server-side fix). Card 1's alias is always some
            // paid_cli (no REST option for the primary slot), so it's never hidden.
            const primCliBtn = document.querySelector('#sup-card-claude .open-btn[onclick*="launchCLI(\'claude\')"]');
            if (primCliBtn) primCliBtn.title = 'Open ' + primary.name + ' CLI in a new terminal';
        }
        if (fallback) {
            const nameEl = document.getElementById('sup-name-gemini');
            const labelEl = document.querySelector('#sup-card-gemini .sup-label-top');
            if (nameEl) nameEl.innerHTML = escHtml(fallback.name.toUpperCase()) + '<span class="sup-name-sub">' + escHtml(_supClassLabel(fallback)) + '</span>';
            if (labelEl) labelEl.textContent = fallback.name.toUpperCase();
            // ── De-hardwire: drive the fallback card from the chosen provider ──
            window._fallbackName = fallback.name.toUpperCase();
            window._fallbackAlt  = (slots.fallback !== 'gemini');   // non-Gemini alias (CLI or REST)
            const modelSel = document.getElementById('gemini-model');
            if (window._fallbackAlt && modelSel && Array.isArray(fallback.models)) {
                const prev = modelSel.value;
                modelSel.innerHTML = fallback.models.map(m =>
                    '<option value="' + escAttr(m.id) + '">' + escHtml(m.label || m.id) + '</option>').join('');
                if ([...modelSel.options].some(o => o.value === prev)) modelSel.value = prev;
            }
            // (CLI-launch button visibility + title now handled by _wireCardButtons,
            // which correctly shows it for free_cli agents too — not just paid_cli.)
        }

        _setLocalCardName();
        // combosInitTier0() may already have fired (and shown combos) before
        // this resolved and the real local provider was known — re-evaluate
        // now that it is, same pattern as the account-status re-render above.
        if (typeof combosInitTier0 === 'function') combosInitTier0();
        // Same race applies to dualInit() — its own fixed-delay auto-fire
        // might land before _supplierSlots resolves, silently missing dual
        // mode on a slow load. Re-evaluate now that the real provider is known.
        if (typeof dualInit === 'function') dualInit();
    } catch(e) {}
}

async function supplierSlotsOpen() {
    // Load on demand rather than assuming boot succeeded: whatever went wrong
    // earlier (a 401 before the session opened, a slow first request), clicking
    // the button is the moment the user is entitled to an answer.
    if (!_supplierSlots) await loadSupplierSlots();
    if (!_supplierSlots) {
        appendError(T('msg.supplier.slots.could.not.read.the.configurat', 'Supplier slots: could not read the configuration (suppliers.php). If you have just signed in, try once more; otherwise check the browser console.'));
        return;
    }
    const slots = _supplierSlots.slots || {};
    const catalog = _supplierSlots.cli_suppliers || {};
    const localServers = _supplierSlots.local_servers || {};

    let ov = document.getElementById('slots-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'slots-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';

    // Cards 1 & 2 are both Agent-CLI slots: each offers the FULL agent pool (paid
    // subscription CLIs + free-tier agents), so you can run e.g. Claude + Codex in
    // parallel, or pick a free agent on either. Free entries get a [Free] badge;
    // c.notes (e.g. key-migration caveats) becomes the option's tooltip. A relay
    // agent (c.relay, e.g. Groq) has no binary — "installed" means a key is saved.
    const agentOptions = Object.entries(catalog)
        .filter(([id, c]) => id && id[0] !== '_' && (c.kind === 'paid_cli' || c.kind === 'free_rest' || c.kind === 'free_cli'))
        .map(([id, c]) => {
            let inst = '';
            if (c.relay) inst = c.installed ? '' : ' (no key set — see Workers panel)';
            else if (c.detect_cmd && !c.installed) inst = ' (not installed)';
            const freeTag = c.free ? ' [Free]' : '';
            const title = c.notes ? ' title="' + escAttr(c.notes) + '"' : '';
            return '<option value="' + id + '"' + title + '>' + escHtml(c.name + ' — ' + c.vendor + freeTag + inst) + '</option>';
        }).join('');
    const paidOptions = agentOptions;   // both cards draw from the same pool now
    const freeOptions = agentOptions;

    // "Custom..." used to be listed here but had no handler anywhere —
    // picking it just saved the literal string "custom" as the provider,
    // which combosActiveBackend() would then treat as unsupported (silently
    // hides Power Combos, same as picking a real-but-unwired backend would).
    // Removed rather than left as a dead option that looked like it did something.
    const localOptions = Object.entries(localServers).map(([id, s]) =>
        '<option value="' + id + '">' + escHtml(s.name) + '</option>'
    ).join('');

    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(440px,90vw);padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;">Supplier Slots</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#slots-overlay\').remove()">×</span></div>' +
        '<div id="slot-policy-note" style="display:none;font-size:10.5px;line-height:1.5;color:var(--text-base);background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;padding:6px 8px;margin-bottom:10px;"></div>' +
        '<div style="display:flex;flex-direction:column;gap:12px;">' +
        '<div><label style="font-size:11px;font-weight:600;color:var(--text-muted);display:block;margin-bottom:4px;">Card 1 — Primary agent (CLI)</label>' +
        '<select id="slot-primary" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;font-size:12px;border-radius:4px;">' + paidOptions + '</select></div>' +
        '<div><label style="font-size:11px;font-weight:600;color:var(--text-muted);display:block;margin-bottom:4px;">Card 2 — Second agent (CLI)</label>' +
        '<select id="slot-fallback" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;font-size:12px;border-radius:4px;">' + freeOptions + '</select></div>' +
        '<div style="font-size:10px;color:var(--text-dim);margin-top:-4px;">Tip: <button class="action-btn" style="padding:1px 8px;font-size:10px;" onclick="supplierStayFree()">Stay Free</button> picks free-tier / local agents for every slot (no subscription). [Free] = no paid plan needed.</div>' +
        '<div><label style="font-size:11px;font-weight:600;color:var(--text-muted);display:block;margin-bottom:4px;">Card 3 — Local LLM server</label>' +
        '<select id="slot-local" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;font-size:12px;border-radius:4px;">' + localOptions + '</select>' +
        '<input id="slot-local-url" placeholder="Base URL (e.g. http://127.0.0.1:11434)" style="margin-top:4px;width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;font-size:11px;border-radius:4px;box-sizing:border-box;" value="' + escHtml((slots.local || {}).base_url || '') + '"></div>' +
        // Agents are data, not code: adding one is a JSON entry, so the app should
        // let you write it. The probe is here because "can this CLI see an image"
        // cannot be answered by reading docs — a blind agent invents an answer.
        '<div style="border-top:1px solid var(--border-dim);padding-top:10px;">' +
        '<div style="font-size:11px;font-weight:600;color:var(--text-muted);margin-bottom:4px;">Agents on this machine</div>' +
        '<div style="display:flex;gap:6px;">' +
        '<select id="slot-edit-pick" style="flex:1;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 6px;border-radius:4px;font-size:11px;">' +
        '<option value="">— pick an agent to edit —</option>' + agentOptions + '</select>' +
        '<button class="action-btn" style="font-size:10px;padding:2px 8px;" onclick="supplierAgentEdit()">Edit</button>' +
        '<button class="action-btn" style="font-size:10px;padding:2px 8px;" onclick="supplierAgentEdit(true)">Add new</button>' +
        '</div></div>' +
        '<div id="slot-err" style="font-size:11px;color:var(--accent-orange);min-height:16px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="this.closest(\'#slots-overlay\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="supplierSlotsSave()">Save & Restart</button>' +
        '</div></div></div>';

    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });

    document.getElementById('slot-primary').value = slots.primary || 'claude';
    document.getElementById('slot-fallback').value = slots.fallback || 'codex';   // Card 2 default = Codex
    document.getElementById('slot-local').value = (slots.local || {}).provider || 'ollama';

    _slotsApplyPolicy();      // 'Free agents only' is on and linked: say so, and grey out the paid agents

    // Pop the VRAM note the moment a slot is set to a local model (Dario's decision).
    ['slot-primary', 'slot-fallback'].forEach(selId => {
        const sel = document.getElementById(selId);
        if (sel) sel.addEventListener('change', () => {
            if (_supplierIsLocal(sel.value)) {
                const c = (_supplierSlots.cli_suppliers || {})[sel.value];
                _showVramNote(c ? c.name : 'This model');
            }
        });
    });
}

// True if a catalog supplier loads a LOCAL GPU model (backend Ollama/LocalAI) —
// these are the ones the VRAM note applies to (cloud/free-API agents don't touch VRAM).
function _supplierIsLocal(id) {
    const c = ((_supplierSlots && _supplierSlots.cli_suppliers) || {})[id];
    return !!(c && c.local);
}

// Short VRAM heads-up when a slot is set to a LOCAL model (Dario's decision). Local
// agents share one GPU — only one large model fits at a time; two local agents at
// once fall back to sequential. Paid cloud agents don't use your VRAM.
function _showVramNote(supplierName) {
    let m = document.getElementById('vram-note-modal');
    if (!m) {
        m = document.createElement('div');
        m.id = 'vram-note-modal';
        m.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        m.addEventListener('click', e => { if (e.target === m) m.style.display = 'none'; });
        document.body.appendChild(m);
    }
    m.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(440px,92vw);padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<h3 style="margin:0 0 8px;font-size:14px;color:var(--text-primary);">' + escHtml(supplierName) + ' runs on your GPU</h3>' +
        '<p style="margin:0 0 12px;font-size:12px;color:var(--text-primary);">This is a <strong>local model</strong> — it loads into your GPU\'s VRAM. Only one large model fits at a time, so if two card slots both run local models, a Broadcast runs them <strong>one after another</strong> instead of together. Paid cloud agents (Claude/Codex) don\'t use your VRAM, so mixing one local + cloud agents runs fully in parallel.</p>' +
        '<div style="display:flex;justify-content:flex-end;"><button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="document.getElementById(\'vram-note-modal\').style.display=\'none\'">Got it</button></div>' +
        '</div>';
    m.style.display = 'flex';
}

// ---- Stay Free <-> "Free agents only" (Privacy & spending) -----------------------------------------
// Two things with one purpose: Stay Free CHOOSES free agents (a one-time action on the selectors);
// "Free agents only" REFUSES paid agents at send time (a standing rule). Linked by default: pressing
// Stay Free also turns the rule on, and while the rule is on this dialog greys out the paid agents.
// The link is a setting (Privacy & spending -> "Link with Stay Free"), so it can be untied.
// "Paid" is ONE definition, shared with policy_lib.php: kind paid_cli and not flagged free.
function _slotAgentIsPaid(c) { return !!c && c.kind === 'paid_cli' && !c.free; }
async function _stayFreeLink(err) {
    let r; try { r = await (await fetch('policy.php?action=get')).json(); } catch (e) { return; }
    if (!r || !r.ok || !err) return;
    if (r.policy.link_stay_free) {
        if (!r.policy.free_only) {
            try { await fetch('policy.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'set', free_only: true }) }); } catch (e) { return; }
        }
        err.textContent += ' ' + T('msg.free.linked.on', 'Free agents only is now ON (Privacy & spending): paid agents are refused while it is on. You can untie the two there.');
        _slotsApplyPolicy();
    } else {
        err.textContent += ' ' + (r.policy.free_only
            ? T('msg.free.unlinked.on', 'Free agents only is a separate setting and is ON.')
            : T('msg.free.unlinked.off', 'Free agents only (Privacy & spending) is a separate setting and is OFF: paid agents can still be sent to.'));
    }
}
async function _slotsApplyPolicy() {
    const box = document.getElementById('slot-policy-note');
    if (!box) return;
    let r; try { r = await (await fetch('policy.php?action=get')).json(); } catch (e) { return; }
    const cat = (_supplierSlots && _supplierSlots.cli_suppliers) || {};
    const on = !!(r && r.ok && r.policy.free_only && r.policy.link_stay_free);
    ['slot-primary', 'slot-fallback'].forEach(id => {
        const sel = document.getElementById(id); if (!sel) return;
        Array.from(sel.options).forEach(o => {
            const paid = _slotAgentIsPaid(cat[o.value]);
            if (!o.dataset.base) o.dataset.base = o.textContent;
            o.disabled = on && paid;
            o.textContent = o.dataset.base + (on && paid ? ' — ' + T('slot.paid.blocked', 'paid, blocked') : '');
        });
    });
    if (!on) { box.style.display = 'none'; return; }
    const holds = ['slot-primary', 'slot-fallback'].map(id => { const sel = document.getElementById(id); return sel && _slotAgentIsPaid(cat[sel.value]) ? (cat[sel.value].name) : null; }).filter(Boolean);
    box.innerHTML = '🛡 ' + escHtml(T('slot.policy.on', 'Free agents only is on (Privacy & spending): paid agents are disabled below, and Stay Free keeps it on.')) +
        (holds.length ? '<br><b>' + escHtml(T('slot.policy.holds', 'A card still holds a paid agent ({names}): prompts to it are refused until you change it or turn the switch off.', { names: holds.join(', ') })) + '</b>' : '') +
        ' <button class="action-btn" style="padding:1px 7px;font-size:10px;margin-left:4px;" onclick="document.getElementById(\'slots-overlay\')?.remove();policyOpen()">' + escHtml(T('slot.policy.open', 'Open Privacy & spending')) + '</button>';
    box.style.display = 'block';
}

// "Stay Free" — set every slot to a free-tier / local agent (no subscription).
function supplierStayFree() {
    const cat = (_supplierSlots && _supplierSlots.cli_suppliers) || {};
    const free = Object.entries(cat)
        .filter(([id, c]) => c && c.free && (c.kind === 'paid_cli' || c.kind === 'free_rest'))
        .map(([id]) => id);
    const p = document.getElementById('slot-primary');
    const f = document.getElementById('slot-fallback');
    const l = document.getElementById('slot-local');
    if (p && free[0]) p.value = free[0];
    if (f) { const alt = free.find(id => id !== (p ? p.value : '')); if (alt) f.value = alt; }
    if (l) l.value = 'ollama';   // Card 3 → local models (always free)
    const err = document.getElementById('slot-err');
    if (err) err.textContent = T('msg.free.set.applied.card.3.local.ollama.always', 'Free set applied (Card 3 = local Ollama, always free). Cloud free tiers are rate-limited; local models use your GPU.');
    _stayFreeLink(err);
    if (p && _supplierIsLocal(p.value)) _showVramNote(cat[p.value].name);
    else if (f && _supplierIsLocal(f.value)) _showVramNote(cat[f.value].name);
}

async function supplierSlotsSave() {
    const primary = document.getElementById('slot-primary').value;
    const fallback = document.getElementById('slot-fallback').value;
    const localProv = document.getElementById('slot-local').value;
    const localUrl = document.getElementById('slot-local-url').value.trim();
    const errEl = document.getElementById('slot-err');

    if (primary === fallback) {
        errEl.textContent = T('msg.primary.and.fallback.must.be.different.suppl', 'Primary and fallback must be different suppliers.');
        return;
    }

    try {
        const r1 = await fetch('suppliers.php?action=set_slots', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({primary, fallback}),
        });
        const d1 = await r1.json();
        if (!d1.ok) { errEl.textContent = d1.error || 'Failed'; return; }

        if (localProv !== 'ollama' || localUrl) {
            const r2 = await fetch('suppliers.php?action=set_local', {
                method: 'POST', headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({provider: localProv, base_url: localUrl || ''}),
            });
            const d2 = await r2.json();
            if (!d2.ok) { errEl.textContent = d2.error || 'Failed to save local config'; return; }
        }

        document.getElementById('slots-overlay').remove();
        appendSystem(T('msg.supplier.slots.updated.restarting.agents', 'Supplier slots updated. Restarting agents...'));
        await loadSupplierSlots();

        try {
            await fetch('session.php?action=restart', {method: 'POST'});
        } catch(e) {}
        setTimeout(() => location.reload(), 2000);
    } catch(e) {
        errEl.textContent = 'Error: ' + e.message;
    }
}

document.addEventListener('DOMContentLoaded', () => { setTimeout(loadSupplierSlots, 500); });

// =============================================================================
// SUPPLIER CONTROLS — JSON-driven model + effort dropdowns (claude/gemini).
// Defined in cockpit_data/{claude,gemini}_controls.json so new controls are
// added by editing JSON (no recompile). inject modes:
//   model         → the option value is the CLI model string (sent as *_model)
//   prompt_prefix → the option value is text prepended to the prompt (effort);
//                   sent base64 as *_effort and decoded by agent_loop.sh
// =============================================================================
let _supplierControls = { claude: null, gemini: null };

// Controls are per-SUPPLIER now (codex_controls.json, aider_controls.json, …),
// rendered into a fixed DOM slot ('claude' = Card 1, 'gemini' = Card 2). So a slot
// running Codex shows/edits Codex's controls, not Claude's. Model lists are owned
// by M1's populateModelSelect (live) — controls JSON only drives the effort picker.
// Friendly class subtitle under a card's supplier name (replaces "Primary/Fallback").
function _supClassLabel(sup) {
    if (!sup) return '';
    if (sup.local) return 'Local Agent · GPU';
    if (sup.kind === 'free_rest') return 'Free Tier · API';
    if (sup.free) return 'Free Agent · CLI';
    if (sup.auth === 'subscription' || sup.kind === 'paid_cli') return 'Paid Agent · CLI';
    return 'Agent';
}

// De-hardwire a card's action buttons: power/tmux/CLI tooltips reflect the actual
// supplier, and the "open CLI in a new terminal" button is shown only for CLI-kind
// agents (a free-REST provider like Gemini/Groq has no local binary to open).
function _wireCardButtons(domSlot, sup) {
    const name  = (sup && sup.name) || domSlot;
    const isCli = !!(sup && (sup.kind === 'paid_cli' || sup.kind === 'free_cli'));
    const pow = document.getElementById('sup-power-' + domSlot);
    if (pow) pow.title = 'Start / stop ' + name + ' session';
    const card = document.getElementById('sup-card-' + domSlot);
    if (!card) return;
    const sessBtn = card.querySelector('.open-btn[onclick*="openSession"]');
    if (sessBtn) sessBtn.title = 'Open ' + name + ' tmux session';
    const cliBtn = card.querySelector('.open-btn[onclick*="launchCLI"]');
    if (cliBtn) {
        cliBtn.title = 'Open ' + name + ' CLI in a new terminal';
        cliBtn.style.display = isCli ? '' : 'none';
    }
}

// Point a card's tune button at the supplier actually in that slot, so it edits
// e.g. codex_controls.json when Codex runs there (not the slot's old claude/gemini file).
function _wireSupplierTune(domSlot, supplierId, sup) {
    const btn = document.querySelector('#sup-card-' + domSlot + ' .mini-ctrl');
    if (!btn || !supplierId) return;
    const name = (sup && sup.name) || supplierId;
    btn.setAttribute('onclick', "event.stopPropagation();editSupplierControls('" + supplierId + "')");
    btn.title = 'Edit ' + name + ' controls (' + supplierId + '_controls.json)';
}

async function loadSupplierControls(configSupplier, domSlot) {
    domSlot = domSlot || configSupplier;
    try {
        const r = await fetch('controls.php?action=get&supplier=' + encodeURIComponent(configSupplier));
        const d = await r.json();
        _supplierControls[domSlot] = (d && d.config) || null;
        _renderSupplierControls((d && d.config) || null, domSlot, configSupplier);
    } catch (e) { _renderSupplierControls(null, domSlot, configSupplier); }
    // Restore this supplier's saved effort (persists across cards).
    const effSel = document.getElementById(domSlot + '-effort');
    const wantEff = _supPrefGet(configSupplier).effort;
    if (effSel && effSel.style.display !== 'none' && wantEff != null &&
        [...effSel.options].some(o => o.value === wantEff)) effSel.value = wantEff;
}

// Built-in effort control for suppliers that support one, used when no
// <supplier>_controls.json exists. Claude Code: thinking levels via prompt keywords
// (prepended to the prompt). Editing the controls JSON overrides this.
function _defaultEffortFor(supplierId) {
    // Claude Code: thinking levels via prompt keywords (prepended to the prompt).
    if (supplierId === 'claude') return {
        inject: 'prompt_prefix',
        options: [
            { name: 'Normal',     value: '' },
            { name: 'Think',      value: 'think' },
            { name: 'Think hard', value: 'think hard' },
            { name: 'Ultrathink', value: 'ultrathink' },
        ],
    };
    // Codex: reasoning effort via a config override flag on the CLI.
    if (supplierId === 'codex') return {
        inject: 'cli_args',
        options: [
            { name: 'Effort: default', value: '' },
            { name: 'Effort: low',     value: '-c model_reasoning_effort=low' },
            { name: 'Effort: medium',  value: '-c model_reasoning_effort=medium' },
            { name: 'Effort: high',    value: '-c model_reasoning_effort=high' },
        ],
    };
    // Everything else (Gemini, Groq, Aider, Goose, opencode, Qwen, local models):
    // no native effort flag, but the prompt-keyword nudge is model-agnostic —
    // prepending a "think it through" instruction reliably raises reasoning depth.
    // Override per agent by creating <supplier>_controls.json (the tune button).
    return {
        inject: 'prompt_prefix',
        options: [
            { name: 'Normal',    value: '' },
            { name: 'Careful',   value: 'Think step by step before answering.' },
            { name: 'Thorough',  value: 'Think carefully step by step, consider edge cases, and double-check your answer before responding.' },
        ],
    };
}

function _renderSupplierControls(config, domSlot, supplierId) {
    const controls = (config && config.controls) || [];
    // Effort = first non-model control from the JSON, else the supplier's built-in default.
    let effCtrl = controls.find(c => c.inject !== 'model');
    if (!effCtrl || !(effCtrl.options || []).length) effCtrl = _defaultEffortFor(supplierId);
    const effSel  = document.getElementById(domSlot + '-effort');
    if (!effSel) return;
    if (effCtrl && (effCtrl.options || []).length) {
        const prev = effSel.value;
        effSel.innerHTML = (effCtrl.options || []).map(o =>
            '<option value="' + escAttr(o.value) + '">' + escHtml(o.name) + '</option>').join('');
        effSel.title = effCtrl.label || 'Effort';
        effSel.dataset.inject = effCtrl.inject || 'prompt_prefix';
        effSel.style.display = '';
        if ([...effSel.options].some(o => o.value === prev)) effSel.value = prev;
    } else {
        effSel.style.display = 'none';   // no effort control for this supplier → hide
    }
}

// Resolve the selected control value → { effort, args } base64 (routed by inject).
function _supplierInject(supplier) {
    const out = { effort: '', args: '' };
    const sel = document.getElementById(supplier + '-effort');
    if (!sel || sel.style.display === 'none' || !sel.value) return out;
    let b64 = '';
    try { b64 = btoa(unescape(encodeURIComponent(sel.value))); } catch (e) { return out; }
    if (sel.dataset.inject === 'cli_args') out.args = b64;
    else                                   out.effort = b64;   // prompt_prefix
    return out;
}

// Open the JSON control file in the floating editor.
async function editSupplierControls(supplier) {
    let content = '';
    try {
        const r = await fetch('controls.php?action=get&supplier=' + supplier);
        const d = await r.json();
        content = d.content || '';
    } catch (e) { appendError(T('msg.load.failed.message', 'Load failed: {message}', {message: e.message})); return; }
    openFloatingEditor({
        id: 'controls-' + supplier,
        heading: 'Editing ' + supplier + ' controls',
        filename: supplier + '_controls.json',
        content, language: 'json',
        onSave: async (newContent) => {
            try { JSON.parse(newContent); } catch (e) { return { ok:false, error:'Invalid JSON: ' + e.message }; }
            try {
                const r = await fetch('controls.php?action=save&supplier=' + supplier, {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({ content: newContent })
                });
                const d = await r.json();
                if (!d.ok) return { ok:false, error: d.error || 'unknown' };
                appendSystem(T('msg.supplier.controls.saved', '{supplier} controls saved.', {supplier: supplier}));
                loadSupplierControls(supplier);
                return { ok:true };
            } catch (e) { return { ok:false, error: e.message }; }
        }
    });
}
document.addEventListener('DOMContentLoaded', () => {
    // loadSupplierSlots now loads per-supplier controls + retargets the tune buttons
    // itself (no hardwired claude/gemini controls load). Re-run so the chosen
    // primary/fallback provider always wins any init race.
    setTimeout(loadSupplierSlots, 1600);
});


// =============================================================================
// AGENT EDITOR + "can it see?" probe (2026-09-23)
//
// The catalog was already extensible — cli_suppliers.json merges over the PHP
// defaults and the file agent_loop reads is regenerated from it — but nothing in
// the app could write that file, so "a new CLI came out" meant editing JSON by
// hand. This is that editor, plus the one question you cannot answer by reading
// documentation: whether the agent can actually SEE an attached image.
// =============================================================================
function supplierAgentEdit(isNew) {
    const pick = document.getElementById('slot-edit-pick');
    const id   = isNew ? '' : (pick ? pick.value : '');
    if (!isNew && !id) { const e = document.getElementById('slot-err'); if (e) e.textContent = T('msg.pick.an.agent.first', 'Pick an agent first.'); return; }
    const cat = (_supplierSlots && _supplierSlots.cli_suppliers) || {};
    const c   = cat[id] || {};

    document.getElementById('agent-edit-ov')?.remove();
    const ov = document.createElement('div');
    ov.id = 'agent-edit-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10001;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
    const fld = (lbl, id2, val, ph, hint) =>
        '<label style="font-size:10.5px;color:var(--text-muted);display:block;margin-top:7px;">' + lbl +
        (hint ? ' <span style="opacity:.65;">' + hint + '</span>' : '') + '</label>' +
        '<input id="' + id2 + '" value="' + escAttr(val || '') + '" placeholder="' + escAttr(ph || '') + '" ' +
        'style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);' +
        'border:1px solid var(--border-dim);padding:4px 6px;border-radius:4px;font-size:11px;">';

    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(480px,94vw);' +
        'max-height:90vh;overflow:auto;padding:18px;">' +
        '<div style="display:flex;align-items:center;margin-bottom:6px;">' +
        '<h2 style="margin:0;font-size:13px;flex:1;">' + (isNew ? 'Add an agent' : 'Edit ' + escHtml(c.name || id)) + '</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#agent-edit-ov\').remove()">×</span></div>' +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-bottom:6px;">Saved to cockpit_data/cli_suppliers.json — it takes effect on the next prompt, no rebuild.</div>' +
        fld('Id', 'ag-id', id, 'newcli', '(lowercase, no spaces)') +
        fld('Name', 'ag-name', c.name, 'New CLI') +
        fld('Vendor', 'ag-vendor', c.vendor, 'Someone') +
        fld('Binary', 'ag-binary', c.binary, 'newcli', '(a name on PATH, not a path)') +
        fld('Prompt flag', 'ag-cliflag', c.cli_flag, '-p') +
        fld('Model flag', 'ag-modelflag', c.model_flag, '--model') +
        fld('Subcommand', 'ag-subcmd', c.subcmd, 'run / exec', '(optional)') +
        fld('Extra args', 'ag-extra', c.extra_args, '--yolo', '(optional, flags only)') +
        '<label style="font-size:10.5px;color:var(--text-muted);display:block;margin-top:9px;">Images — how this agent is given a picture</label>' +
        '<select id="ag-imgmode" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:4px 6px;border-radius:4px;font-size:11px;">' +
        ['describe|Describe locally (safe default — the agent reads text, not the image)',
         'path|The agent opens the file itself (it has a file-read tool)',
         'flag|Pass the file on a command-line flag',
         'at|Reference it as @path in the prompt'].map(o => {
            const [v, t] = o.split('|');
            return '<option value="' + v + '"' + ((c.image_mode || 'describe') === v ? ' selected' : '') + '>' + t + '</option>';
         }).join('') + '</select>' +
        fld('Image flag', 'ag-imgflag', c.image_flag, '--image', '(when passing on a flag)') +
        '<label style="font-size:10.5px;color:var(--text-muted);display:block;margin-top:6px;">' +
        '<input type="checkbox" id="ag-imgsep"' + (c.image_needs_sep ? ' checked' : '') + '> ' +
        'that flag is variadic — put <code>--</code> before the prompt</label>' +
        '<div style="margin-top:10px;display:flex;gap:6px;align-items:center;">' +
        '<button class="action-btn" style="font-size:10px;" onclick="supplierAgentProbe()">Can it see? (test)</button>' +
        '<span id="ag-probe-state" style="font-size:10.5px;color:var(--text-dim);"></span></div>' +
        '<div id="ag-probe-out" style="display:none;margin-top:6px;font-size:11px;background:var(--bg-darker);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:7px;white-space:pre-wrap;max-height:160px;overflow:auto;"></div>' +
        '<div id="ag-err" style="font-size:11px;color:var(--accent-orange);min-height:16px;margin-top:6px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:space-between;margin-top:4px;">' +
        '<button class="action-btn" style="font-size:10px;color:var(--claude);" onclick="supplierAgentDelete()">Remove override</button>' +
        '<span><button class="action-btn" onclick="this.closest(\'#agent-edit-ov\').remove()">Cancel</button> ' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="supplierAgentSave()">Save</button></span>' +
        '</div></div>';
    document.body.appendChild(ov);
    if (!isNew) document.getElementById('ag-id').readOnly = true;
}

function _agentEntryFromForm() {
    const v = id => (document.getElementById(id) || {}).value || '';
    return {
        id: v('ag-id').trim().toLowerCase(),
        entry: {
            name: v('ag-name').trim(), vendor: v('ag-vendor').trim(), binary: v('ag-binary').trim(),
            cli_flag: v('ag-cliflag').trim(), model_flag: v('ag-modelflag').trim(),
            subcmd: v('ag-subcmd').trim(), extra_args: v('ag-extra').trim(),
            image_mode: v('ag-imgmode'), image_flag: v('ag-imgflag').trim(),
            image_needs_sep: !!(document.getElementById('ag-imgsep') || {}).checked,
        },
    };
}

// Run the agent against a shipped image of a red triangle and a blue circle.
// The answer is scored AND shown: the failure mode is a plausible wrong answer,
// so the person decides, not the substring match.
async function supplierAgentProbe() {
    const state = document.getElementById('ag-probe-state');
    const out   = document.getElementById('ag-probe-out');
    const body  = _agentEntryFromForm();
    if (body.entry.image_mode === 'describe') {
        state.textContent = T('msg.set.a.mode.other.than.describe.to.test', 'Set a mode other than "describe" to test.'); return;
    }
    state.textContent = T('msg.asking.the.agent', 'asking the agent…'); out.style.display = 'none';
    try {
        const r = await (await fetch('suppliers.php?action=vision_probe', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
        })).json();
        if (!r.ok) { state.textContent = ''; document.getElementById('ag-err').textContent = r.error || 'probe failed'; return; }
        state.textContent = r.verdict + ' · ' + r.seconds + 's';
        out.style.display = 'block';
        out.textContent = 'Expected: ' + r.expected + '\n\nAnswer:\n' + (r.answer || '(nothing)') +
                          (r.inconclusive
                              ? '\n\nThis test runs the agent bare, without the saved login or key Cockpit gives it in a chat, so it proves nothing either way. Try it from a chat on a card: attach an image and ask what is in it.'
                              : '\n\nIf that is right, Save keeps this mode. If it invented an answer, set "Describe locally" instead.');
    } catch (e) { state.textContent = ''; document.getElementById('ag-err').textContent = e.message; }
}

async function supplierAgentSave() {
    const err = document.getElementById('ag-err');
    const body = _agentEntryFromForm();
    if (!body.id) { err.textContent = T('msg.an.id.is.required', 'An id is required.'); return; }
    try {
        const r = await (await fetch('suppliers.php?action=catalog_set', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
        })).json();
        if (!r.ok) { err.textContent = r.error || 'save failed'; return; }
        document.getElementById('agent-edit-ov').remove();
        await loadSupplierSlots();
        appendSystem(T('msg.agent.id.saved.it.is.in.the.slot.lists.now.n', 'Agent "{id}" saved — it is in the slot lists now, no rebuild needed.', {id: r.id}));
        document.getElementById('slots-overlay')?.remove();
        supplierSlotsOpen();
    } catch (e) { err.textContent = e.message; }
}

async function supplierAgentDelete() {
    const body = _agentEntryFromForm();
    if (!await cockpitConfirm('Remove override',
        'Remove your changes to "' + body.id + '"? A shipped agent goes back to its default; one you added is deleted.',
        'Remove', { danger: true })) return;
    try {
        const r = await (await fetch('suppliers.php?action=catalog_delete', {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id: body.id }),
        })).json();
        if (!r.ok) { document.getElementById('ag-err').textContent = r.error || 'remove failed'; return; }
        document.getElementById('agent-edit-ov').remove();
        await loadSupplierSlots();
        appendSystem(r.restored_default ? T('msg.agent.id.restored.to.its.shipped.default', 'Agent "{id}" restored to its shipped default.', {id: r.id}) : T('msg.agent.id.removed', 'Agent "{id}" removed.', {id: r.id}));
        if (r.slots_reset && r.slots_reset.length) appendSystem(T('msg.that.agent.was.on.a.card.the.card.went.back.to.its.default', 'That agent was on a card; the card went back to its default agent.'));
        document.getElementById('slots-overlay')?.remove();
        supplierSlotsOpen();
    } catch (e) { document.getElementById('ag-err').textContent = e.message; }
}
