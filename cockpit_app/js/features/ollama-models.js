// =============================================================================
// Load Ollama models
// =============================================================================
async function loadModels() {
    // The custom Ollama dropdown is statically defined with all known models.
    // loadModels now just verifies which models are actually installed and
    // marks any panel options that aren't installed as dimmed.
    try {
        const res  = await fetch('models.php');
        const data = await res.json();
        if (data.models && data.models.length > 0) {
            const installed = new Set(data.models.map(m => m.name));
            // Mark options not currently installed
            document.querySelectorAll('#ollama-panel .cs-option').forEach(opt => {
                const val = opt.dataset.value;
                if (val && !installed.has(val) && !opt.classList.contains('disabled')) {
                    opt.style.opacity = '0.45';
                    opt.title = 'Model not installed — run: ollama pull ' + val;
                }
            });
        }
    } catch (e) { /* keep static dropdown as-is */ }
}

// =============================================================================
// F8 — Ollama Model Manager modal: pull, remove, details
// =============================================================================
let _modelsPullPoller = null;
function showModelsModal() {
    let ov = document.getElementById('models-modal-overlay');
    if (ov) { ov.style.display = 'flex'; _modelsRefresh(); return; }
    ov = document.createElement('div');
    ov.id = 'models-modal-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(720px,92vw);max-height:88vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;color:var(--ollama);flex:1;">' +
        '<span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">database</span> ' +
        'Ollama Model Manager</h2>' +
        '<span class="rp-action-btn" onclick="hideModelsModal()" style="cursor:pointer;">×</span>' +
        '</div>' +
        '<div style="display:flex;flex-direction:column;gap:6px;margin-bottom:10px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">Pull a model (e.g. <code>qwen2.5-coder:14b</code>, <code>smollm2:135m</code>)</label>' +
        '<div style="display:flex;gap:4px;">' +
        '<input id="models-pull-input" type="text" placeholder="model:tag" ' +
        'style="flex:1;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:11px;padding:5px 7px;">' +
        '<button class="rp-action-btn" onclick="modelsStartPull()">Pull</button>' +
        '</div>' +
        '<div id="models-pull-log" style="display:none;max-height:160px;overflow:auto;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);padding:6px 8px;font-family:var(--font-mono);font-size:10px;border:1px solid var(--border-dim);border-radius:3px;white-space:pre-wrap;"></div>' +
        '</div>' +
        // F8: browse/search popular models
        '<div style="display:flex;flex-direction:column;gap:6px;margin-bottom:10px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">Browse popular models</label>' +
        '<div style="display:flex;gap:4px;">' +
        '<input id="models-search-input" type="text" placeholder="filter (e.g. coder, vision, small)…" ' +
        'style="flex:1;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:11px;padding:5px 7px;">' +
        '<button class="rp-action-btn" onclick="modelsSearch()">Browse</button>' +
        '</div>' +
        '<div id="models-search-results" style="display:none;max-height:200px;overflow:auto;display:flex;flex-direction:column;gap:3px;"></div>' +
        '</div>' +
        // One-click GLM-4 tuned model (split GPU/CPU for low-VRAM cards)
        '<div style="display:flex;flex-direction:column;gap:5px;margin-bottom:10px;border:1px solid var(--border-dim);border-radius:4px;padding:8px;">' +
        '<label style="font-size:11px;color:var(--text-muted);" data-help="glm4"><span class="material-symbols-rounded ico ico-fill">star</span> One-click: <b>GLM-4 tuned for your GPU</b> → creates <code>glm4-cockpit</code></label>' +
        '<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;font-size:11px;color:var(--text-dim);">' +
        'num_gpu <input id="glm4-numgpu" type="number" value="12" min="0" max="60" title="GPU layers to offload. 12 = safe for 4 GB VRAM + Cinnamon. Lower if it crashes (OOM); raise for more speed." style="width:54px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 5px;font-size:11px;"> ' +
        'num_ctx <input id="glm4-numctx" type="number" value="8192" min="2048" max="32768" step="1024" style="width:70px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 5px;font-size:11px;"> ' +
        '<button class="rp-action-btn" onclick="modelsCreateGlm4()">Create glm4-cockpit</button>' +
        '</div>' +
        '<div style="font-size:10px;color:var(--text-dim);">Pull <code>glm4</code> first. 9B model → split GPU/CPU for 4 GB VRAM (temp 0.2). Manual/scheduled use (&gt;4B auto policy). Then pick <b>glm4-cockpit</b> in the Ollama Tier 1 dropdown.</div>' +
        '<div id="glm4-tune-log" style="display:none;max-height:140px;overflow:auto;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);padding:6px 8px;font-family:var(--font-mono);font-size:10px;border:1px solid var(--border-dim);border-radius:3px;white-space:pre-wrap;"></div>' +
        '</div>' +
        '<div style="display:flex;align-items:center;gap:8px;margin:6px 0;">' +
        '<h3 style="margin:0;font-size:12px;color:var(--text-muted);flex:1;">Installed models</h3>' +
        '<button class="rp-action-btn" onclick="_modelsRefresh()" title="Re-scan installed Ollama models">' +
        '<span class="material-symbols-rounded" style="font-size:13px;vertical-align:-2px;">refresh</span> Refresh</button>' +
        '</div>' +
        '<div id="models-list" style="display:flex;flex-direction:column;gap:4px;"></div>' +
        '<div id="models-details" style="margin-top:10px;display:none;background:var(--bg-darker,var(--bg-codeblock));padding:6px 8px;font-family:var(--font-mono);font-size:10px;white-space:pre-wrap;border-radius:3px;max-height:240px;overflow:auto;"></div>' +
        '<div style="margin-top:12px;border-top:1px solid var(--border-dim);padding-top:8px;">' +
        '<h3 style="margin:0 0 6px 0;font-size:12px;color:var(--text-muted);">Ollama runtime knobs</h3>' +
        '<div id="ollama-knobs" style="display:grid;grid-template-columns:1fr 1fr;gap:6px 12px;font-size:11px;">' +
        '<label style="color:var(--text-dim);">keep_alive <span title="How long models stay loaded after last use">ⓘ</span>' +
        '<input id="knob-keep-alive" type="text" value="5m" style="width:60px;margin-left:4px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 5px;font-size:11px;"></label>' +
        '<label style="color:var(--text-dim);">num_ctx <span title="Context window size (tokens). Higher = more memory">ⓘ</span>' +
        '<input id="knob-num-ctx" type="number" value="4096" min="512" max="131072" step="512" style="width:70px;margin-left:4px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 5px;font-size:11px;"></label>' +
        '<label style="color:var(--text-dim);">num_parallel <span title="Concurrent requests per model">ⓘ</span>' +
        '<input id="knob-num-parallel" type="number" value="1" min="1" max="8" style="width:50px;margin-left:4px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 5px;font-size:11px;"></label>' +
        '<label style="color:var(--text-dim);">max_loaded <span title="Max models loaded simultaneously">ⓘ</span>' +
        '<input id="knob-max-loaded" type="number" value="1" min="1" max="4" style="width:50px;margin-left:4px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:2px 5px;font-size:11px;"></label>' +
        '</div>' +
        '<div style="margin-top:6px;text-align:right;"><button class="rp-action-btn" onclick="_ollamaKnobsSave()">Save knobs</button></div>' +
        '<div style="font-size:9px;color:var(--text-dim);margin-top:4px;">Takes effect on next agent session restart.</div>' +
        '</div>' +
        '</div>';
    document.body.appendChild(ov);
    ov.onclick = e => { if (e.target === ov) hideModelsModal(); };
    _modelsRefresh();
    _ollamaKnobsLoad();
}
function hideModelsModal() {
    const ov = document.getElementById('models-modal-overlay');
    if (ov) ov.style.display = 'none';
    if (_modelsPullPoller) { clearInterval(_modelsPullPoller); _modelsPullPoller = null; }
}

// One-click: build a GPU-tuned GLM-4 variant (glm4-cockpit) via create_variant.
async function modelsCreateGlm4() {
    const log = document.getElementById('glm4-tune-log');
    const numGpu = parseInt(document.getElementById('glm4-numgpu')?.value || '12', 10);
    const numCtx = parseInt(document.getElementById('glm4-numctx')?.value || '8192', 10);
    if (log) { log.style.display = 'block'; log.textContent = 'Creating glm4-cockpit (base glm4, num_gpu=' + numGpu + ', num_ctx=' + numCtx + ', temp 0.2)…\n'; }
    try {
        const r = await fetch('models.php?action=create_variant', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({ base: 'glm4', name: 'glm4-cockpit',
                num_ctx: numCtx, temperature: 0.2, num_gpu: numGpu }),
        });
        const d = await r.json();
        if (log) log.textContent += (d.output || '') + '\n' + (d.ok ? 'OK: Created glm4-cockpit — now selectable in the Ollama Tier 1 dropdown.' : 'FAILED: Failed: ' + (d.error || 'unknown') + (/(not found|no such)/i.test(d.output||'') ? '  (Pull glm4 first.)' : ''));
        if (d.ok) { appendSystem(T('msg.created.tuned.model.glm4.cockpit', 'Created tuned model glm4-cockpit.')); _modelsRefresh(); }
    } catch(e) { if (log) log.textContent += 'Error: ' + e.message; }
}

async function _ollamaKnobsLoad() {
    try {
        const r = await fetch('models.php?action=config_get');
        const d = await r.json();
        if (!d.ok) return;
        const c = d.config;
        const el = id => document.getElementById(id);
        if (el('knob-keep-alive'))   el('knob-keep-alive').value   = c.keep_alive || '5m';
        if (el('knob-num-ctx'))      el('knob-num-ctx').value      = c.num_ctx || 4096;
        if (el('knob-num-parallel')) el('knob-num-parallel').value = c.num_parallel || 1;
        if (el('knob-max-loaded'))   el('knob-max-loaded').value   = c.max_loaded || 1;
    } catch(e) {}
}
async function _ollamaKnobsSave() {
    const cfg = {
        keep_alive:   document.getElementById('knob-keep-alive')?.value || '5m',
        num_ctx:      parseInt(document.getElementById('knob-num-ctx')?.value) || 4096,
        num_parallel: parseInt(document.getElementById('knob-num-parallel')?.value) || 1,
        max_loaded:   parseInt(document.getElementById('knob-max-loaded')?.value) || 1,
    };
    try {
        const r = await fetch('models.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({action:'config_set', ...cfg})
        });
        const d = await r.json();
        if (d.ok) appendSystem(T('msg.ollama.knobs.saved.restart.agent.sessions.to', 'Ollama knobs saved. Restart agent sessions to apply.'));
        else appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error||'')}));
    } catch(e) { appendError(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message})); }
}

// F8: browse/search the curated model catalog; click a result to pre-fill pull
async function modelsSearch() {
    const q = (document.getElementById('models-search-input')?.value || '').trim();
    const box = document.getElementById('models-search-results');
    if (!box) return;
    box.style.display = 'flex';
    box.innerHTML = '<div style="font-size:10px;opacity:0.6;">Loading…</div>';
    try {
        const r = await fetch('models.php?action=search&q=' + encodeURIComponent(q));
        const d = await r.json();
        if (!d.ok) { box.innerHTML = '<div style="font-size:10px;">Error.</div>'; return; }
        if (!d.models.length) { box.innerHTML = '<div style="font-size:10px;opacity:0.6;">No matches. You can still type any model id above and Pull.</div>'; return; }
        box.innerHTML = '';
        d.models.forEach(m => {
            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;gap:6px;padding:4px 6px;background:var(--bg-darker,var(--bg-codeblock));border-radius:3px;';
            row.innerHTML =
                '<span style="flex:1;font-family:var(--font-mono);font-size:10.5px;">' + escHtml(m.id) + '</span>' +
                '<span style="font-size:9px;opacity:0.7;">' + escHtml(m.size) + '</span>' +
                '<span style="font-size:9px;opacity:0.6;flex:1;">' + escHtml(m.note) + '</span>' +
                '<button class="rp-action-btn" data-model="' + escHtml(m.id) + '">Pull</button>';
            row.querySelector('button').onclick = () => {
                document.getElementById('models-pull-input').value = m.id;
                modelsStartPull();
            };
            box.appendChild(row);
        });
    } catch(e) { box.innerHTML = '<div style="font-size:10px;">Failed: ' + escHtml(e.message) + '</div>'; }
}
async function _modelsRefresh() {
    const list = document.getElementById('models-list');
    if (!list) return;
    list.innerHTML = '<div style="font-size:11px;opacity:0.6;">Loading…</div>';
    try {
        const r = await fetch('models.php?action=list');
        const d = await r.json();
        if (!d.ok) { list.innerHTML = '<div style="color:var(--accent-orange);font-size:11px;">' + escHtml(d.error||'Failed to list models') + '</div>'; return; }
        if (!d.models || d.models.length === 0) { list.innerHTML = '<div style="font-size:11px;opacity:0.6;">No models installed.</div>'; return; }
        list.innerHTML = '';
        d.models.forEach(m => {
            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;gap:6px;padding:5px 8px;background:var(--bg-darker,var(--bg-codeblock));border-radius:3px;';
            const isVar = m.is_variant;
            row.innerHTML =
                '<span style="flex:1;font-family:var(--font-mono);font-size:11px;">' + escHtml(m.name) +
                    (isVar ? ' <span style="font-size:9px;padding:1px 5px;border-radius:3px;background:var(--accent-cyan);color:var(--bg-base);font-weight:600;vertical-align:1px;">AGENTIC</span>' : '') +
                '</span>' +
                '<span style="font-size:10px;opacity:0.7;">' + escHtml(m.size||'') + '</span>' +
                '<span style="font-size:10px;opacity:0.5;">' + escHtml(m.modified||'') + '</span>' +
                '<button class="rp-action-btn" data-act="probe" data-model="' + escHtml(m.name) + '" title="Test tool-call capability">Probe</button>' +
                (isVar ? '' : '<button class="rp-action-btn" data-act="variant" data-model="' + escHtml(m.name) + '" title="Create agentic-tuned variant">Variant</button>') +
                '<button class="rp-action-btn" data-act="details" data-model="' + escHtml(m.name) + '">Details</button>' +
                '<button class="rp-action-btn" data-act="remove" data-model="' + escHtml(m.name) + '">Remove</button>';
            row.addEventListener('click', async e => {
                const act = e.target.dataset?.act;
                if (!act) return;
                const model = e.target.dataset.model;
                if (act === 'details') {
                    const d2 = document.getElementById('models-details');
                    d2.style.display = 'block';
                    d2.textContent = T('msg.loading', 'Loading…');
                    const r2 = await fetch('models.php?action=details&model=' + encodeURIComponent(model));
                    const dd = await r2.json();
                    d2.textContent = dd.ok ? dd.details : ('Error: ' + (dd.error||''));
                    d2.scrollIntoView({block:'nearest', behavior:'smooth'});   // the panel sits below the list: bring it into view
                } else if (act === 'probe') {
                    const d2 = document.getElementById('models-details');
                    d2.style.display = 'block';
                    d2.scrollIntoView({block:'nearest', behavior:'smooth'});
                    d2.textContent = 'Probing ' + model + ' for tool-call capability… (may take 1-2 min)';
                    try {
                        const r2 = await fetch('models.php', {
                            method:'POST', headers:{'Content-Type':'application/json'},
                            body: JSON.stringify({action:'probe', model:model})
                        });
                        const dd = await r2.json();
                        let lines = [];
                        (dd.checks||[]).forEach(c => {
                            lines.push((c.pass ? 'PASS' : 'FAIL') + '  ' + c.name + ': ' + c.detail);
                        });
                        lines.push('');
                        lines.push(dd.agentic_capable
                            ? 'AGENTIC CAPABLE — this model can drive tool calls'
                            : 'NOT AGENTIC — tool-call round-trip failed. Use for chat/summary only.');
                        d2.textContent = lines.join('\n');
                    } catch(e2) { d2.textContent = 'Probe error: ' + e2.message; }
                } else if (act === 'variant') {
                    const vname = await cockpitPrompt('Create agentic variant', 'Variant name (based on ' + model + '):', 'e.g. mymodel-agentic', model.replace(/:.*/, '') + '-agentic');
                    if (!vname) return;
                    const d2 = document.getElementById('models-details');
                    d2.style.display = 'block';
                    d2.textContent = 'Creating variant "' + vname + '" from ' + model + '…';
                    try {
                        const r2 = await fetch('models.php', {
                            method:'POST', headers:{'Content-Type':'application/json'},
                            body: JSON.stringify({action:'create_variant', base:model, name:vname, num_ctx:32768, temperature:0.2, repeat_penalty:1.15})
                        });
                        const dd = await r2.json();
                        if (dd.ok) {
                            d2.textContent = 'Variant created: ' + vname + '\n\nModelfile:\n' + dd.modelfile + '\n' + dd.output;
                            _modelsRefresh();
                            loadModels();
                        } else {
                            d2.textContent = 'Failed: ' + (dd.output || dd.error || '');
                        }
                    } catch(e2) { d2.textContent = 'Error: ' + e2.message; }
                } else if (act === 'remove') {
                    if (!await cockpitConfirm('Remove model?', 'Remove model "' + model + '"? This frees the disk space but the model must be re-pulled to use again.', 'Remove', {danger:true, icon:'delete'})) return;
                    const r2 = await fetch('models.php', {
                        method:'POST', headers:{'Content-Type':'application/json'},
                        body: JSON.stringify({action:'remove', model:model})
                    });
                    const dd = await r2.json();
                    if (!dd.ok) appendError(T('msg.remove.failed.error', 'Remove failed: {error}', {error: (dd.error||'')}));
                    else appendSystem(T('msg.removed.model', 'Removed {model}', {model: model}));
                    _modelsRefresh();
                    loadModels();   // refresh availability dimming on the dropdown
                }
            });
            list.appendChild(row);
        });
    } catch(e) { list.innerHTML = '<div style="color:var(--accent-orange);font-size:11px;">Error: ' + escHtml(e.message) + '</div>'; }
}
async function modelsStartPull() {
    const input = document.getElementById('models-pull-input');
    const model = input.value.trim();
    if (!model) return;
    const logEl = document.getElementById('models-pull-log');
    logEl.style.display = 'block';
    logEl.textContent = 'Starting pull of ' + model + '…';
    try {
        const r = await fetch('models.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({action:'pull', model:model})
        });
        const d = await r.json();
        if (!d.ok) { logEl.textContent = 'Error: ' + (d.error||''); return; }
        // Poll every 2 seconds until .done sentinel appears
        if (_modelsPullPoller) clearInterval(_modelsPullPoller);
        _modelsPullPoller = setInterval(async () => {
            const r2 = await fetch('models.php?action=pull_status&model=' + encodeURIComponent(model));
            const d2 = await r2.json();
            if (!d2.ok) return;
            logEl.textContent = d2.log || '';
            logEl.scrollTop = logEl.scrollHeight;
            if (d2.finished) {
                clearInterval(_modelsPullPoller); _modelsPullPoller = null;
                appendSystem(T('msg.pull.complete.modelrc', 'Pull complete: {model}{rc}', {model: model, rc: (d2.rc===0 ? ' (success)' : ' (rc=' + d2.rc + ')')}));
                if (d2.rc !== 0 && d2.mirror && d2.mirror.url) {
                    // withdrawn from the registry but kept on the Cockpit mirror
                    appendSystem(T('msg.span.class.material.symbols.rounded.ico.clou', '<span class="material-symbols-rounded ico">cloud_download</span> {eschtml} is no longer on the Ollama registry{note}, but the Cockpit mirror keeps it. Run in a terminal: <code>{eschtml2}</code> — it downloads the archive from {eschtml3}, checks its sha256 and installs it.', {eschtml: escHtml(model), note: (d2.mirror.note ? ' (' + escHtml(d2.mirror.note) + ')' : ''), eschtml2: escHtml(d2.mirror.restore), eschtml3: escHtml(d2.mirror.url)}));
                }
                _modelsRefresh();
                loadModels();
            }
        }, 2000);
    } catch(e) { logEl.textContent = 'Error: ' + e.message; }
}

// Cap a fixed-position dropdown panel's max-height at the top of the footer
// (prompt/chat-input area) so it never overlaps the chat below it.
// When a list opens, the chosen entry is brought into view (centred) instead of leaving the list at the top (2026-10-06).
// If it sits in a collapsed group, that group is opened first. The group headers float on the top row while their items scroll
// (css/topbar.css), underneath the filter box when the list has one: --cs-stick tells the headers how tall that box is.
function _panelRevealSelected(panel) {
    try {
        const fb = panel.querySelector('[id$="-filterbox"]');
        panel.style.setProperty('--cs-stick', (fb ? fb.offsetHeight : 0) + 'px');
        const row = panel.querySelector('.cs-option.selected');
        if (!row) return;
        if (!row.offsetParent) {                                     // hidden: its group is collapsed -> open the group
            let h = row.previousElementSibling;
            while (h && !(h.classList.contains('cs-group-header') && h.hasAttribute('data-cgh-wired'))) h = h.previousElementSibling;
            if (h) h.click();                                        // the header's own handler expands the group and remembers it
            if (!row.offsetParent) return;
        }
        const pr = panel.getBoundingClientRect(), rr = row.getBoundingClientRect();
        panel.scrollTop += (rr.top - pr.top) - (panel.clientHeight - row.offsetHeight) / 2;
    } catch (e) {}
}
function _panelCapToFooter(panel, top) {
    const footer = document.getElementById('footer');
    const limit = footer ? (footer.getBoundingClientRect().top - top - 8) : (window.innerHeight - top - 8);
    panel.style.maxHeight = Math.max(150, limit) + 'px';
}

// ── Combo Editor — create/edit user-authored Power Combos ───────────────────
// Plain JSON, never encrypted (combos_user.json) — separate from the hub
// registry. See COCKPIT_COMBO_PROTECTION_DESIGN.md §7.
// Real installed models only, per backend — populated once when the editor
// opens (comboEditorLoadModels(), via the same merged endpoint the Dual Mode
// picker already uses). Steps/judge pick FROM this list instead of typing a
// free-text name, so a newly-authored combo can't reference a model that
// isn't actually pulled.
let _comboEditorModels = { ollama: [], localai: [] };
async function comboEditorLoadModels() {
    try {
        const r = await (await fetch('dual_model.php?action=list_models')).json();
        _comboEditorModels = { ollama: [], localai: [] };
        if (r && r.ok && Array.isArray(r.models)) {
            r.models.forEach(m => { if (!_comboEditorModels[m.runner]) _comboEditorModels[m.runner] = []; _comboEditorModels[m.runner].push(m.name); });
        }
    } catch (e) { _comboEditorModels = { ollama: [], localai: [] }; }
}
// Option list for a step/judge model <select> — `runner` picks which
// backend's installed list to show ('' = Default = both, merged). `current`
// is always kept selectable even if it's not actually installed (editing an
// existing combo that references a model you no longer have shouldn't
// silently swap it out from under you — see comboOptionRow's "edit even
// when missing" note) — flagged with  so it's visibly not a real pick.
function comboEditorModelOptions(runner, current) {
    const list = runner === 'ollama' ? _comboEditorModels.ollama
               : runner === 'localai' ? _comboEditorModels.localai
               : [...(_comboEditorModels.ollama || []), ...(_comboEditorModels.localai || [])];
    const uniq = [...new Set(list)].sort((a, b) => a.localeCompare(b));
    let opts = uniq.map(m => '<option value="' + escAttr(m) + '"' + (m === current ? ' selected' : '') + '>' + escHtml(m) + '</option>').join('');
    if (current && !uniq.includes(current)) {
        opts = '<option value="' + escAttr(current) + '" selected>' + escHtml(current) + ' (not installed)</option>' + opts;
    }
    if (!uniq.length && !current) opts = '<option value="">— no models installed —</option>';
    return opts;
}
function comboEditorStepRunnerChanged(sel) {
    const modelSel = sel.closest('.ce-step-row').querySelector('.ce-step-model');
    // Switching backend resets the model pick unless the current value is
    // ALSO real on the new backend (rare — same name on both) — carrying
    // over an Ollama model name while now on LocalAI would silently save a
    // combo referencing a model that backend doesn't have, exactly what this
    // whole select-instead-of-type change was meant to prevent.
    const stillValid = comboEditorModelExists(sel.value, modelSel.value);
    modelSel.innerHTML = comboEditorModelOptions(sel.value, stillValid ? modelSel.value : '');
}
function comboEditorModelExists(runner, name) {
    if (!name) return false;
    const list = runner === 'ollama' ? _comboEditorModels.ollama
               : runner === 'localai' ? _comboEditorModels.localai
               : [...(_comboEditorModels.ollama || []), ...(_comboEditorModels.localai || [])];
    return list.includes(name);
}
function comboEditorStepRow(s) {
    s = s || {};
    const row = document.createElement('div');
    row.className = 'ce-step-row';
    row.style.cssText = 'display:grid;grid-template-columns:1fr auto 1fr 2fr auto;gap:6px;margin-bottom:6px;align-items:start;';
    row.innerHTML =
        '<select class="ce-step-model">' + comboEditorModelOptions(s.runner || '', s.model || '') + '</select>' +
        '<select class="ce-step-runner" onchange="comboEditorStepRunnerChanged(this)" title="Which backend this step runs on — leave Default to follow whatever Card 3 is set to; pick Ollama/LocalAI explicitly to build a dual combo that mixes both.">' +
            '<option value=""' + (!s.runner ? ' selected' : '') + '>Default</option>' +
            '<option value="ollama"' + (s.runner === 'ollama' ? ' selected' : '') + '>Ollama</option>' +
            '<option value="localai"' + (s.runner === 'localai' ? ' selected' : '') + '>LocalAI</option>' +
        '</select>' +
        '<input class="ce-step-role" placeholder="role, e.g. Reviewer" value="' + escAttr(s.role || '') + '">' +
        '<input class="ce-step-system" placeholder="system prompt" value="' + escAttr(s.system || '') + '">' +
        '<button class="action-btn" onclick="this.closest(\'.ce-step-row\').remove()" style="padding:4px 8px;" title="Remove step"><span class="material-symbols-rounded ico">close</span></button>';
    return row;
}
function comboEditorAddStep(s) { document.getElementById('ce-steps').appendChild(comboEditorStepRow(s)); }
function comboEditorPatternChange() {
    document.getElementById('ce-judge-box').style.display = document.getElementById('ce-pattern').value === 'judge' ? 'block' : 'none';
}
function comboEditorPopulateCats() {
    const dl = document.getElementById('ce-category-list');
    dl.innerHTML = Object.values(COMBO_CATS).map(label => '<option value="' + escAttr(label) + '">').join('');
}
// Turn a picked/typed category label into the slug key combos are stored
// under (matches how combosRenderTier0 auto-labels an unknown category, so
// a new category round-trips cleanly instead of creating near-duplicates).
function comboEditorCatSlug(label) {
    const typed = label.trim();
    for (const k in COMBO_CATS) if (COMBO_CATS[k].toLowerCase() === typed.toLowerCase()) return k;
    return typed.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'misc';
}
function comboEditorJudgeRunnerChanged() {
    const runner = document.getElementById('ce-judge-runner').value;
    const modelSel = document.getElementById('ce-judge-model');
    const stillValid = comboEditorModelExists(runner, modelSel.value);
    modelSel.innerHTML = comboEditorModelOptions(runner, stillValid ? modelSel.value : '');
}
async function comboEditorOpen(id) {
    comboEditorPopulateCats();
    // Real installed models, per backend — load BEFORE building any step/judge
    // selects so they're populated with real data on first render, not empty.
    await comboEditorLoadModels();
    document.getElementById('ce-err').style.display = 'none';
    document.getElementById('ce-steps').innerHTML = '';
    document.getElementById('ce-judge-box').style.display = 'none';
    document.getElementById('ce-orig-id').value = '';
    if (id) {
        document.getElementById('combo-editor-title').textContent = T('msg.edit.combo', 'Edit Combo');
        let combo = null;
        try {
            const d = await (await fetch('combos.php?action=user_list')).json();
            combo = (d.combos || []).find(c => c.id === id);
        } catch (e) {}
        if (!combo) { alert(T('msg.could.not.load.that.combo', 'Could not load that combo.')); return; }
        document.getElementById('ce-orig-id').value = combo.id;
        document.getElementById('ce-id').value = combo.id;
        document.getElementById('ce-id').disabled = true;
        document.getElementById('ce-name').value = combo.name || '';
        document.getElementById('ce-pattern').value = combo.pattern || 'parallel';
        document.getElementById('ce-category').value = COMBO_CATS[combo.category] || combo.category || '';
        document.getElementById('ce-rag').value = combo.use_rag || 'never';
        document.getElementById('ce-desc').value = combo.desc || '';
        (combo.steps || []).forEach(s => comboEditorAddStep(s));
        const judgeRunner = (combo.judge && combo.judge.runner) || '';
        document.getElementById('ce-judge-runner').value = judgeRunner;
        document.getElementById('ce-judge-model').innerHTML = comboEditorModelOptions(judgeRunner, combo.judge ? (combo.judge.model || '') : '');
        if (combo.judge) document.getElementById('ce-judge-system').value = combo.judge.system || '';
        comboEditorPatternChange();
    } else {
        document.getElementById('combo-editor-title').textContent = T('msg.new.combo', 'New Combo');
        document.getElementById('ce-id').value = '';
        document.getElementById('ce-id').disabled = false;
        document.getElementById('ce-name').value = '';
        document.getElementById('ce-pattern').value = 'parallel';
        document.getElementById('ce-category').value = '';
        document.getElementById('ce-rag').value = 'never';
        document.getElementById('ce-desc').value = '';
        document.getElementById('ce-judge-runner').value = '';
        document.getElementById('ce-judge-model').innerHTML = comboEditorModelOptions('', '');
        document.getElementById('ce-judge-system').value = '';
        comboEditorAddStep();
    }
    document.getElementById('combo-editor-modal').style.display = 'flex';
}
function comboEditorClose() { document.getElementById('combo-editor-modal').style.display = 'none'; }
async function comboEditorSave() {
    const err = document.getElementById('ce-err');
    err.style.display = 'none';
    const steps = Array.from(document.querySelectorAll('#ce-steps .ce-step-row')).map(r => {
        const step = {
            model: r.querySelector('.ce-step-model').value.trim(),
            role: r.querySelector('.ce-step-role').value.trim(),
            system: r.querySelector('.ce-step-system').value.trim(),
        };
        const runner = r.querySelector('.ce-step-runner').value;
        if (runner) step.runner = runner;
        return step;
    }).filter(s => s.model);
    const pattern = document.getElementById('ce-pattern').value;
    const combo = {
        id: document.getElementById('ce-id').value.trim(),
        name: document.getElementById('ce-name').value.trim(),
        pattern, category: comboEditorCatSlug(document.getElementById('ce-category').value),
        use_rag: document.getElementById('ce-rag').value,
        desc: document.getElementById('ce-desc').value.trim(),
        steps,
        est_vram_mb: steps.length * 1500,
    };
    if (pattern === 'judge') {
        const jm = document.getElementById('ce-judge-model').value.trim();
        if (jm) {
            combo.judge = { model: jm, system: document.getElementById('ce-judge-system').value.trim() };
            const jr = document.getElementById('ce-judge-runner').value;
            if (jr) combo.judge.runner = jr;
        }
    }
    if (!combo.id || !combo.name || !steps.length) { err.textContent = T('msg.id.name.and.at.least.one.step.with.a.model.a', 'ID, name, and at least one step (with a model) are required.'); err.style.display = 'block'; return; }
    try {
        const r = await fetch('combos.php?action=user_save', {
            method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({combo}),
        });
        const d = await r.json();
        if (!d.ok) { err.textContent = d.error || 'Save failed.'; err.style.display = 'block'; return; }
        comboEditorClose();
        await combosRefresh();
    } catch (e) { err.textContent = T('msg.save.failed', 'Save failed.'); err.style.display = 'block'; }
}
async function comboEditorDelete(id) {
    if (!await cconfirm(T('msg.delete.combo.id.this.cannot.be.undone', 'Delete combo "{id}"? This cannot be undone.', {id: id}))) return;
    try {
        await fetch('combos.php?action=user_delete', {
            method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({id}),
        });
        await combosRefresh();
    } catch (e) {}
}
async function comboUnpublish(id, contentId) {
    if (!await cconfirm(T('msg.unpublish.id.from.the.marketplace.your.local', 'Unpublish "{id}" from the Marketplace? Your local copy stays — this only removes it from the public catalog.', {id: id}))) return;
    try {
        const r = await saasApi('content_delete', { content_id: contentId });
        if (!r || !r.ok) { alert(T('msg.unpublish.failed.r', 'Unpublish failed: {r}', {r: (r && (r.error || r.status) || 'unknown')})); return; }
        const d = await (await fetch('combos.php?action=user_list')).json();
        const combo = (d.combos || []).find(c => c.id === id);
        if (combo) {
            delete combo._content_id;
            await fetch('combos.php?action=user_save', {
                method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({combo}),
            });
        }
        await combosRefresh();
    } catch (e) { alert(T('msg.unpublish.failed.message', 'Unpublish failed: {message}', {message: e.message})); }
}

// ── Custom Ollama dropdown functions ──────────────────────────────────────────
function toggleOllamaDropdown() {
    const trigger = document.getElementById('ollama-trigger');
    const panel   = document.getElementById('ollama-panel');
    const isOpen  = panel.classList.contains('open');
    if (!isOpen) loadModels();
    if (isOpen) {
        panel.classList.remove('open');
        trigger.classList.remove('open');
        // Restore default positioning so re-open recalculates fresh
        panel.style.position = '';
        panel.style.top      = '';
        panel.style.left     = '';
        panel.style.width    = '';
        panel.style.minWidth = '';
    } else {
        // Close the LocalAI panel first — the two are exclusive, only one
        // open at a time (same as picking a new tab replaces the old one).
        document.getElementById('localai-panel')?.classList.remove('open');
        document.getElementById('localai-trigger')?.classList.remove('open');
        // Anchor on the CARD, not this trigger — so both Ollama's and
        // LocalAI's panels share the exact same width and left edge
        // (the card's), regardless of which trigger was actually clicked.
        // this lets the dropdown extend below the topbar (the card itself
        // has overflow:hidden for the collapse animation, which would clip
        // a default absolute-positioned panel).
        const rect = _dualPanelAnchorRect(trigger);
        panel.style.position = 'fixed';
        panel.style.top      = (rect.bottom + 4) + 'px';
        panel.style.left     = rect.left + 'px';
        panel.style.width    = rect.width + 'px';
        panel.style.minWidth = '';
        _panelCapToFooter(panel, rect.bottom + 4);
        panel.classList.add('open');
        trigger.classList.add('open');
        _panelRevealSelected(panel);
    }
}
// Shared width/left anchor for the Ollama and LocalAI dropdown panels — the
// card they both live in (#sup-card-ollama), not each trigger's own rect,
// so the two panels always match exactly regardless of which trigger opened
// them. Falls back to the trigger's own rect if the card isn't found (should
// never happen — defensive only).
function _dualPanelAnchorRect(trigger) {
    const card = document.getElementById('sup-card-ollama');
    return card ? card.getBoundingClientRect() : trigger.getBoundingClientRect();
}

// Close Ollama dropdown when clicking outside of it
document.addEventListener('click', (e) => {
    const wrapper = document.getElementById('ollama-wrapper');
    const panel   = document.getElementById('ollama-panel');
    if (!wrapper || !panel) return;
    if (!panel.classList.contains('open')) return;
    if (wrapper.contains(e.target)) return;   // click inside, leave alone
    panel.classList.remove('open');
    document.getElementById('ollama-trigger')?.classList.remove('open');
    panel.style.position = '';
    panel.style.top = '';
    panel.style.left = '';
    panel.style.width = '';
});

// Power Combos (TIER 0): selected combo id, or null when a normal model is picked.
let _selectedCombo = null;
// Combo picked from the LocalAI column, not the classic Ollama Tier-0 —
// null means "use the global active-backend default", same as before this
// existed. Read by runCombo()/runComboNonStream() to route to the right
// server/catalog. Declared alongside _selectedCombo (its first use is in
// selectOllamaModel, far above where this used to sit).
let _selectedComboBackend = null;

function selectOllamaModel(el) {
    if (el.classList.contains('disabled')) return;
    const value = el.dataset.value;
    // Anything picked from the classic panel (model or combo) is always
    // Ollama/global-default backed, never the LocalAI-column's explicit
    // override — clear it so a stale 'localai' tag from an earlier LocalAI
    // combo pick doesn't leak into this selection.
    _selectedComboBackend = null;
    // Strip a leading favorite star (/) injected into the name span.
    const name  = el.querySelector('.cs-option-name') && _optName(el.querySelector('.cs-option-name'));
    // TIER 0 — a combo recipe rather than a single model. Track it separately;
    // the hidden <select> only knows real models, so don't write combo ids to it.
    if (value.indexOf('combo:') === 0) {
        _selectedCombo = value.slice(6);
        document.getElementById('ollama-selected-label').innerHTML = '<span class="material-symbols-rounded ico">bolt</span> ' + escHtml(name);
    } else {
        _selectedCombo = null;
        document.getElementById('ollama-select').value = value;
        document.getElementById('ollama-selected-label').textContent = name;
        localStorage.setItem('cockpit_last_ollama_model', value);
        // Also register with the dual-model system (LocalAI-side selection
        // already goes through dualSelectModel — this is the other half, so
        // a classic Ollama Tier pick shows up as the  chip too and can
        // pair with a LocalAI pick for dual-mode chat).
        if (dualModeActive() && typeof dualSelectModel === 'function') dualSelectModel('ollama', value);
    }
    document.querySelectorAll('#ollama-panel .cs-option').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    document.getElementById('ollama-panel').classList.remove('open');
    document.getElementById('ollama-trigger').classList.remove('open');
    if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
}

// Populate the TIER 0 — Power Combos group at the top of the Ollama dropdown
// from combos.php. Registry-driven; greys out combos with missing models.
let _combosData = null;
let _combosLocked = [];   // scopes (base/store) whose .enc pack exists but failed to decrypt
// 2026-07-10: expanded from 8 → 30 categories (235 combos total, 185 new —
// see cockpit_data/Cockpit_AllCombos_{Reference,Explained}.md). A category
// missing from this map means its combos silently vanish from Tier-0 (only
// combosRenderTier0() below iterates Object.keys(COMBO_CATS)) — every
// category in combos.json MUST have an entry here.
const COMBO_CATS = {
    coding:'Code', office:'Office', language:'Language', image:'Image',
    learning:'Learning', data:'Data', creative:'Creative', accessibility:'Accessibility',
    system:'System', communication:'Communication', lifestyle:'Lifestyle',
    media:'Media', research:'Research', security:'Security',
    'web design':'Web Design', 'home design':'Home Design', storage:'Storage',
    'hobby collections':'Hobby Collections', cooking:'Cooking', fashion:'Fashion',
    holidays:'Holidays', 'social media':'Social Media', science:'Science',
    spreadsheets:'Spreadsheets', electricity:'Electricity', electronics:'Electronics',
    'game development':'Game Dev', 'programmed controllers':'Controllers',
    automation:'Automation', 'smart home':'Smart Home'
};
// Icon per category (Material Symbol name) — labels above must stay plain text: they
// double as datalist options and input values.
const COMBO_CAT_ICONS = {     coding:'computer',  office:'description',  language:'public',  image:'palette',     learning:'psychology',  data:'bar_chart',  creative:'auto_awesome',  accessibility:'accessible',     system:'desktop_windows',  communication:'chat',  lifestyle:'eco',     media:'movie',  research:'science',  security:'lock', 'web design':'language', 'home design':'home',  storage:'storage', 'hobby collections':'extension',  cooking:'restaurant',  fashion:'checkroom',     holidays:'celebration', 'social media':'smartphone',  science:'science',     spreadsheets:'trending_up',  electricity:'bolt',  electronics:'power', 'game development':'sports_esports', 'programmed controllers':'tune',     automation:'smart_toy', 'smart home':'home' };
function combosFavs() { try { return new Set(JSON.parse(localStorage.getItem('cockpit_combo_favs') || '[]')); } catch (e) { return new Set(); } }
function combosToggleFav(id, ev) {
    if (ev) ev.stopPropagation();
    const f = combosFavs();
    f.has(id) ? f.delete(id) : f.add(id);
    localStorage.setItem('cockpit_combo_favs', JSON.stringify([...f]));
    combosRenderTier0();
}

// Power Combos work against Ollama (native REST) or LocalAI (OpenAI-compatible
// Chat Completions) — combos_lib.php implements both. LM Studio/llama.cpp
// aren't wired up yet, same model-naming/API-shape problem, just not solved
// for those two. Rather than silently fail against an unsupported backend,
// hide the whole feature unless Card 3 is one of the two that work.
function combosActiveBackend() {
    const provider = (_supplierSlots && _supplierSlots.slots && _supplierSlots.slots.local && _supplierSlots.slots.local.provider) || 'ollama';
    // 'dual' defaults single-backend call sites (the Tier-0 combo catalog
    // fetch, until the two-column dual layout exists) to Ollama — combos ARE
    // available in dual mode, just single-catalog for now. dualModeActive()
    // is the real "is dual mode on" check used for gating dual-only UI.
    if (provider === 'dual') return 'ollama';
    return (provider === 'ollama' || provider === 'localai') ? provider : null;
}

// The real three-way check — true only when Card 3's provider is explicitly
// set to "Dual — Ollama + LocalAI" in Supplier Slots. Picking plain Ollama or
// plain LocalAI hides all dual UI (chips, LocalAI models, dual chat) and
// restores single-backend behavior exactly as it was before dual mode existed.
function dualModeActive() {
    return !!(_supplierSlots && _supplierSlots.slots && _supplierSlots.slots.local && _supplierSlots.slots.local.provider === 'dual');
}

// "Needs both backends" is deliberately a MERGE across both catalogs, not
// just whichever one is the current single-catalog fetch — a dual combo
// saved while Card 3 was set to Ollama lives in combos.json, one saved while
// set to LocalAI lives in combos_localai.json, and either panel should show
// BOTH regardless of which catalog they actually landed in. Deduped by id in
// the (unlikely but possible) case the same id exists in both catalogs.
let _mergedDualCombos = [];
async function refreshMergedDualCombos() {
    const results = await Promise.allSettled([
        fetch('combos.php?action=list&backend=ollama').then(r => r.json()),
        fetch('combos.php?action=list&backend=localai').then(r => r.json()),
    ]);
    const seen = new Set(); const out = [];
    results.forEach(r => {
        if (r.status !== 'fulfilled' || !r.value || !r.value.ok || !Array.isArray(r.value.combos)) return;
        r.value.combos.forEach(c => {
            if ((c.needed_runners || []).length > 1 && !seen.has(c.id)) { seen.add(c.id); out.push(c); }
        });
    });
    _mergedDualCombos = out;
}

async function combosInitTier0() {
    const panel = document.getElementById('ollama-panel');
    if (!panel) return;
    if (!combosActiveBackend()) {
        _combosData = null;
        combosRenderUnavailableTier0();
        return;
    }
    let data;
    try { data = await (await fetch('combos.php?action=list')).json(); } catch (e) { return; }
    await refreshMergedDualCombos();
    if (!data || !data.ok || !Array.isArray(data.combos) || !data.combos.length) {
        _combosData = null;
        combosRenderEmptyTier0();
        return;
    }
    _combosData = data.combos;
    _combosLocked = data.locked || [];
    combosRenderTier0();
}

// Card 3 is set to something Power Combos don't support (LM Studio,
// llama.cpp, or anything else) — nothing useful to offer here.
function combosRenderUnavailableTier0() {
    const panel = document.getElementById('ollama-panel');
    if (!panel) return;
    panel.querySelectorAll('[data-t0]').forEach(n => n.remove());
    const localName = (_supplierSlots && _supplierSlots.slots && _supplierSlots.slots.local && _supplierSlots.slots.local.name) || 'this local server';
    const hdr = document.createElement('div');
    hdr.className = 'cs-group-header'; hdr.setAttribute('data-t0', '1'); hdr.setAttribute('data-tier', '0'); hdr.setAttribute('data-help', 'combos');
    hdr.innerHTML = '<span class="material-symbols-rounded ico">bolt</span> Power Combos — <span style="color:var(--text-dim);font-weight:400;">not available on ' + localName + ' (Ollama or LocalAI only). Switch Card 3 in Supplier Slots to use them.</span>';
    panel.prepend(hdr);
}
// Re-fetch after a Combo Store download so newly installed combos show up
// without a full page reload.
// Re-fetch and re-render BOTH panels — not just Ollama's. Before this fix,
// saving/deleting/unpublishing/installing a combo only refreshed the Ollama
// side (combosInitTier0()), so an edited combo's row stayed stale until a
// hard reload if you were looking at the LocalAI panel, or if the edit
// changed whether it's now a "needs both backends" entry (that section is
// built from _mergedDualCombos, which also needs a fresh fetch).
async function combosRefresh() {
    _combosData = null;
    await combosInitTier0();
    if (document.getElementById('localai-panel')) {
        await dualRenderLocalAIPanel(_lastLocalAIModels || []);
    }
}

// ── Dual-model chat: Ollama + LocalAI loaded side by side (regular, non-
// combo chat). Additive to the existing Ollama Tier picker above — that
// static curated list and its single-model tmux dispatch stay exactly as
// they were; this only adds a second, independent LocalAI slot and a new
// HTTP dispatch path used whenever the LocalAI slot (or both slots) is in
// play, since the tmux path has no LocalAI support at all.
let _dualState = { ollama: null, localai: null };

// Ollama-only session controls don't make sense once LocalAI is sharing the
// card — hide power toggle/tmux/CLI, show a LocalAI models button instead.
// Runs on every call (not gated by dualModeActive() internally) so switching
// back to plain Ollama/LocalAI correctly restores the normal button set too.
function dualUpdateOllamaCardButtons() {
    const dual = dualModeActive();
    const power = document.getElementById('sup-power-ollama');
    const tmux  = document.getElementById('ollama-tmux-btn');
    const cli   = document.getElementById('ollama-cli-btn');
    const laMng = document.getElementById('localai-manage-btn');
    if (power) power.style.display = dual ? 'none' : '';
    // tmux + CLI operate the Ollama side and still make sense in dual mode
    // (launchCLI('ollama')/openSession resolve the provider server-side —
    // dual → the Ollama REPL, plain LocalAI → its chat REPL), so keep them
    // visible; only the Ollama-specific power toggle is dropped in dual.
    if (tmux)  tmux.style.display  = '';
    if (cli)   cli.style.display   = '';
    if (laMng) laMng.style.display = dual ? '' : 'none';
}
// LocalAI has no comparable "manage models" modal of its own in Cockpit yet —
// its own built-in web UI (same address as the API) already covers pull/
// remove/inspect, so this opens that directly rather than building a second
// model-manager UI for one backend.
function dualOpenLocalAIWebUI() {
    const base = (_supplierSlots && _supplierSlots.local_servers && _supplierSlots.local_servers.localai && _supplierSlots.local_servers.localai.base_url) || 'http://127.0.0.1:8080';
    window.open(base, '_blank');
}

async function dualInit() {
    dualUpdateOllamaCardButtons();
    if (!dualModeActive()) return;
    try {
        const [modelsRes, statusRes] = await Promise.all([
            fetch('dual_model.php?action=list_models').then(r => r.json()),
            fetch('dual_model.php?action=status').then(r => r.json()),
        ]);
        if (statusRes && statusRes.ok) _dualState = statusRes.state;
        if (modelsRes && modelsRes.ok) await dualRenderLocalAIPanel(modelsRes.models.filter(m => m.runner === 'localai'));
        dualRenderChips();
    } catch (e) { /* LocalAI/Ollama unreachable — leave existing panel untouched */ }
    _setLocalCardName();   // final word on the card name — dual can't read "Ollama"
}

// Two-column dual layout: a full second custom-select component
// (#localai-wrapper/#localai-trigger/#localai-panel) built via JS and
// inserted as a sibling of #ollama-wrapper — only ever created/shown when
// dualModeActive(), so plain-Ollama/plain-LocalAI users never see it at all
// (matches today's single-column panel exactly, per Phase C's gating).
function dualEnsureLocalAIWrapper() {
    if (document.getElementById('localai-wrapper')) return;
    const ollamaWrapper = document.getElementById('ollama-wrapper');
    if (!ollamaWrapper) return;
    const wrapper = document.createElement('div');
    wrapper.className = 'custom-select-wrapper';
    wrapper.id = 'localai-wrapper';
    wrapper.style.cssText = 'flex:1;';
    wrapper.onclick = e => e.stopPropagation();
    wrapper.innerHTML =
        '<div class="custom-select-trigger" id="localai-trigger" onclick="toggleLocalAIDropdown()" title="Select LocalAI model or combo">' +
        '<span id="localai-selected-label">— pick a LocalAI model —</span><span class="arrow">▼</span></div>' +
        '<div class="custom-select-panel" id="localai-panel"></div>';
    ollamaWrapper.insertAdjacentElement('afterend', wrapper);
}
// Selecting a model or combo closes the panel — without this it stays
// visibly stuck open (fixed-positioned, floating) after the pick, looking
// broken rather than collapsing back to a normal trigger showing the
// selection, same as the classic Ollama panel already does via
// selectOllamaModel()'s own close call.
function dualCloseLocalAIDropdown() {
    const trigger = document.getElementById('localai-trigger');
    const panel   = document.getElementById('localai-panel');
    if (!panel || !trigger) return;
    panel.classList.remove('open');
    trigger.classList.remove('open');
    panel.style.position = '';
    panel.style.top      = '';
    panel.style.left     = '';
    panel.style.width    = '';
    panel.style.minWidth = '';
}
function toggleLocalAIDropdown() {
    const trigger = document.getElementById('localai-trigger');
    const panel   = document.getElementById('localai-panel');
    if (!panel || !trigger) return;
    const isOpen = panel.classList.contains('open');
    if (isOpen) {
        dualCloseLocalAIDropdown();
    } else {
        // Same fixed-positioning escape as toggleOllamaDropdown() — the
        // card's own overflow:hidden (used for its collapse animation) would
        // otherwise clip a default absolute-positioned panel to a sliver.
        // Exclusive with the Ollama panel — only one open at a time.
        document.getElementById('ollama-panel')?.classList.remove('open');
        document.getElementById('ollama-trigger')?.classList.remove('open');
        // Anchor on the CARD (same as toggleOllamaDropdown()) so both
        // panels always share the exact same width and left edge.
        const rect = _dualPanelAnchorRect(trigger);
        panel.style.position = 'fixed';
        panel.style.top      = (rect.bottom + 4) + 'px';
        panel.style.left     = rect.left + 'px';
        panel.style.width    = rect.width + 'px';
        panel.style.minWidth = '';
        _panelCapToFooter(panel, rect.bottom + 4);
        panel.classList.add('open');
        trigger.classList.add('open');
        _panelRevealSelected(panel);
    }
}
document.addEventListener('click', (e) => {
    const wrapper = document.getElementById('localai-wrapper');
    const panel   = document.getElementById('localai-panel');
    if (!wrapper || !panel) return;
    if (!panel.classList.contains('open')) return;
    if (wrapper.contains(e.target)) return;
    panel.classList.remove('open');
    document.getElementById('localai-trigger')?.classList.remove('open');
    panel.style.position = '';
    panel.style.top = '';
    panel.style.left = '';
    panel.style.width = '';
});

// Rebuilds #localai-panel below the sticky title — same shape as the Ollama
// panel: a master row (grand total across combos+models, filter, new,
// collapse/expand-all), "LocalAI Combos" (categorized, own-catalog only),
// "Needs both backends" (flat), then "LocalAI Models" (one real group — no
// fabricated Tier 1-4 subdivision, since LocalAI's /v1/models only returns
// bare names, no per-model curation data the way Ollama's static Tier 1-4
// catalog has; each row still gets a size badge when the name itself parses
// one, via the same heuristic Ollama's own sort already uses).
let _dualLocalAIPanelGen = 0;
async function dualRenderLocalAIPanel(localaiModels) {
    dualEnsureLocalAIWrapper();
    const panel = document.getElementById('localai-panel');
    if (!panel) return;
    // dualInit() can fire twice in quick succession (its own fixed-delay
    // call, plus a re-evaluation once loadSupplierSlots() actually
    // resolves) — since this function awaits a fetch, two overlapping calls
    // would otherwise both append content, doubling every section. Only the
    // most recent call is allowed to write.
    const myGen = ++_dualLocalAIPanelGen;

    // LocalAI's own combo catalog (combos_localai.json), fetched with an
    // explicit backend override so it's independent of whatever the global
    // active-backend default happens to be.
    let localaiCombos = [];
    try {
        const r = await (await fetch('combos.php?action=list&backend=localai')).json();
        if (r && r.ok) localaiCombos = r.combos || [];
    } catch (e) {}
    await refreshMergedDualCombos();
    if (myGen !== _dualLocalAIPanelGen) return;   // a newer call started meanwhile — don't overwrite with stale content

    // "Needs both backends" is the same MERGED list the Ollama panel shows —
    // dual combos from either catalog, not just this one's own.
    const dualNeeded  = _mergedDualCombos;
    const localaiOnly = localaiCombos.filter(c => (c.needed_runners || []).length <= 1);
    const grandTotal  = localaiOnly.length + dualNeeded.length + localaiModels.length;

    panel.innerHTML = '';
    const titleEl = document.createElement('div');
    titleEl.className = 'cs-panel-title';
    titleEl.style.color = 'var(--localai,#c084fc)';
    titleEl.textContent = T('msg.localai.models', 'LocalAI Models');
    panel.appendChild(titleEl);

    const collapsed = _comboCollapsedSet();
    const frag = document.createDocumentFragment();

    // Selecting one of LocalAI's OWN (single-backend) combos.
    const selectLocalAICombo = (el, c) => {
        _selectedCombo = c.id;
        _selectedComboBackend = 'localai';
        panel.querySelectorAll('.cs-option').forEach(o => o.classList.remove('selected'));
        el.classList.add('selected');
        const label = document.getElementById('localai-selected-label');
        if (label) label.innerHTML = '<span class="material-symbols-rounded ico">bolt</span> ' + escHtml(c.name);
        dualCloseLocalAIDropdown();
    };

    // Master row — grand total (combos + models), filter (panel-wide),
    // new-combo shortcut, collapse/expand-all. Mirrors the Ollama panel's
    // own master row exactly, only the accent color and label differ.
    const master = document.createElement('div');
    master.className = 'cs-group-header'; master.id = 'cs-localai-header';
    master.style.cssText = 'font-weight:600;';
    const masterCollapsed = collapsed.has('localai:__master__');
    const prevFilter = dualRenderLocalAIPanel._filter || '';
    master.innerHTML = '<span class="cgh-chevron" style="display:inline-block;transition:transform .12s;transform:rotate(' + (masterCollapsed ? '-90deg' : '0deg') + ');">▾</span>' +
        '<span class="material-symbols-rounded ico">dns</span> LocalAI (' + grandTotal + ') ' +
        '<input id="localai-filter" placeholder="filter all…" value="' + escAttr(prevFilter) + '" oninput="dualFilterLocalAIPanel()" onclick="event.stopPropagation()" ' +
        'style="margin-left:6px;font-size:10px;padding:1px 5px;border:1px solid var(--border-dim);border-radius:3px;background:var(--bg-active);color:var(--text-primary);width:90px;">' +
        '<span onclick="event.stopPropagation();dualLocalAICollapseAll()" title="Collapse all groups" style="margin-left:6px;cursor:pointer;font-size:9px;opacity:.75;">⊟ all</span>' +
        '<span onclick="event.stopPropagation();dualLocalAIExpandAll()" title="Expand all groups" style="margin-left:4px;cursor:pointer;font-size:9px;opacity:.75;">⊞ all</span>' +
        '<span onclick="event.stopPropagation();comboEditorOpen()" title="Create your own combo" style="margin-left:8px;cursor:pointer;font-size:9px;opacity:.85;color:var(--localai,#c084fc);">＋ new</span>';
    master.onclick = () => {
        const nowCollapsed = !collapsed.has('localai:__master__');
        if (nowCollapsed) collapsed.add('localai:__master__'); else collapsed.delete('localai:__master__');
        _comboCollapsedSave(collapsed);
        master.querySelector('.cgh-chevron').style.transform = 'rotate(' + (nowCollapsed ? '-90deg' : '0deg') + ')';
        let sib = master.nextElementSibling;
        while (sib && sib.hasAttribute('data-lt0')) {
            sib.style.display = nowCollapsed ? 'none' : '';
            sib = sib.nextElementSibling;
        }
    };
    frag.appendChild(master);

    // "LocalAI Combos" — own-catalog combos, categorized, same shape as
    // Ollama's Tier 0 (favorites + per-category groups, full badges,
    // unselectable + hover-missing when a step's model isn't installed).
    const comboHdr = makeCollapsibleGroupHeader('<span class="material-symbols-rounded ico">bolt</span> LocalAI Combos (' + localaiOnly.length + ')' + _comboSortSelect(), 'localai:__combos__', collapsed, 'cockpit_combo_collapsed', { 'data-lt0': '1' });
    frag.appendChild(comboHdr);
    renderCategorizedCombos(frag, localaiOnly, collapsed, 'localai:', { 'data-lt0': '1' }, selectLocalAICombo);

    // "Needs both backends" — dual combos that happen to live in THIS
    // catalog (saved while Card 3 was set to LocalAI).
    renderNeedsBothSection(frag, dualNeeded, collapsed, 'localai:', { 'data-lt0': '1' }, selectDualCombo);

    // "LocalAI Models" — one real group, all installed models.
    const modelSortSelect = '<button type="button" class="cs-sort-combo" value="alpha" data-modes="alpha:A→Z|small:Small→Large|large:Large→Small|added:Added order" title="Sorted A to Z; click to change the order" onclick="event.stopPropagation();csCycleSort(this,sortOllamaTier)">A→Z</button>';
    const modelHdr = makeCollapsibleGroupHeader('LocalAI Models (' + localaiModels.length + ') ' + modelSortSelect, 'localai:__models__', collapsed, 'cockpit_combo_collapsed', { 'data-lt0': '1' });
    frag.appendChild(modelHdr);
    if (!localaiModels.length) {
        const empty = document.createElement('div');
        empty.setAttribute('data-lt0', '1');
        empty.style.cssText = 'padding:6px 10px;font-size:11px;color:var(--text-muted);';
        empty.textContent = T('msg.no.localai.models.installed.yet', 'No LocalAI models installed yet.');
        if (collapsed.has('localai:__models__')) empty.style.display = 'none';
        frag.appendChild(empty);
    } else {
        localaiModels.forEach(m => {
            const opt = document.createElement('div');
            opt.className = 'cs-option'; opt.setAttribute('data-value', m.name); opt.setAttribute('data-lt0', '1');
            opt.dataset.search = m.name.toLowerCase();
            if (_dualState.localai === m.name) opt.classList.add('selected');
            // Best-effort size badge, same name-parsing heuristic Ollama's own
            // sort already uses — honestly blank when the name doesn't parse
            // one, never a fabricated guess.
            const paramB = ollamaParamB(m.name);
            const badge = paramB >= 0 ? '~' + paramB + 'B' : '';
            opt.innerHTML = '<span class="cs-option-name">' + escHtml(m.name) + '</span>' +
                (badge ? '<span class="cs-option-badge">' + escHtml(badge) + '</span>' : '');
            opt.onclick = () => {
                dualSelectModel('localai', m.name);
                const label = document.getElementById('localai-selected-label');
                if (label) label.textContent = m.name;
                panel.querySelectorAll('.cs-option').forEach(o => o.classList.remove('selected'));
                opt.classList.add('selected');
                dualCloseLocalAIDropdown();
            };
            if (collapsed.has('localai:__models__')) opt.style.display = 'none';
            frag.appendChild(opt);
        });
    }

    if (masterCollapsed) {
        frag.querySelectorAll('[data-lt0]').forEach(n => { if (n !== master) n.style.display = 'none'; });
    }
    panel.appendChild(frag);
    document.querySelectorAll('#localai-panel .cs-sort-combo').forEach(c => sortOllamaTier(c));
    if (prevFilter) dualFilterLocalAIPanel();
    // Cached so dualLocalAICollapseAll()/dualLocalAIExpandAll() can re-render
    // without an extra round-trip to dual_model.php?action=list_models.
    _lastLocalAIModels = localaiModels;
}
let _lastLocalAIModels = [];
// LocalAI panel's own filter box — same panelFilter() reuse as Ollama's Tier 0.
function dualFilterLocalAIPanel() {
    const f = document.getElementById('localai-filter');
    const q = (f ? f.value : '').trim().toLowerCase();
    dualRenderLocalAIPanel._filter = q;
    panelFilter('localai-panel', q);
    if (!q) {
        const collapsed = _comboCollapsedSet();
        document.querySelectorAll('#localai-panel .cs-group-header[data-group-key]').forEach(h => {
            const isCollapsed = collapsed.has(h.dataset.groupKey);
            let sib = h.nextElementSibling;
            while (sib && !sib.classList.contains('cs-group-header') && sib.id !== 'cs-localai-header') {
                sib.style.display = isCollapsed ? 'none' : '';
                sib = sib.nextElementSibling;
            }
        });
    }
}
function dualLocalAICollapseAll() {
    const collapsed = _comboCollapsedSet();
    document.querySelectorAll('#localai-panel .cs-group-header[data-group-key]').forEach(h => collapsed.add(h.dataset.groupKey));
    _comboCollapsedSave(collapsed);
    dualRenderLocalAIPanel(_lastLocalAIModels || []);
}
function dualLocalAIExpandAll() {
    const collapsed = _comboCollapsedSet();
    document.querySelectorAll('#localai-panel .cs-group-header[data-group-key]').forEach(h => collapsed.delete(h.dataset.groupKey));
    _comboCollapsedSave(collapsed);
    dualRenderLocalAIPanel(_lastLocalAIModels || []);
}

async function dualSelectModel(runner, model) {
    const res = await fetch('dual_model.php?action=select', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ runner, model })
    });
    let data; try { data = await res.json(); } catch (e) { return; }
    if (!data || !data.ok) { appendSystem(T('msg.model.select.failed.data', 'Model select failed: {data}', {data: ((data && data.error) || 'unknown error')})); return; }
    _dualState = data.state;
    if (data.note) appendSystem(data.note);
    dualRenderChips();
    const panel = document.getElementById('ollama-panel');
    if (panel) panel.querySelectorAll('[data-dual].cs-option').forEach(el => {
        el.classList.toggle('selected', el.getAttribute('data-value') === _dualState.localai);
    });
}

function dualClearSlot(runner) { dualSelectModel(runner, ''); }

// Card 3's head name + collapsed label — kept in sync from ONE place so the
// expanded ("Ollama") and collapsed ("Dual") states can't disagree. Dual mode
// reads a short "Dual"; plain backends read their own name (falling back to a
// provider title). Re-asserted at the end of dualInit() too, so nothing that
// runs after loadSupplierSlots can leave the two labels out of step.
function _setLocalCardName() {
    const local = (_supplierSlots && _supplierSlots.slots && _supplierSlots.slots.local) || null;
    if (!local) return;
    const prov = local.provider || 'ollama';
    const nm = prov === 'dual' ? 'Dual'
             : (local.name || ({ ollama: 'Ollama', localai: 'LocalAI' }[prov] || 'Local'));
    const nameEl  = document.getElementById('sup-name-ollama');
    const labelEl = document.querySelector('#sup-card-ollama .sup-label-top');
    window._localName = nm.toUpperCase();   // response labels (live + reload) name the local backend, not "OLLAMA"
    if (nameEl)  nameEl.textContent  = nm.toUpperCase();
    if (labelEl) labelEl.textContent = nm.toUpperCase();
}
// The chip's fill is the agent's "dim" colour, light in some themes and dark in others: its text is picked from the fill, so it reads in every theme.
function dualChipInk() {
    document.querySelectorAll('#dual-model-chips > span').forEach(function (ch) {
        const m = (getComputedStyle(ch).backgroundColor.match(/[\d.]+/g) || []).map(Number);
        if (m.length < 3) return;
        const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        const L = 0.2126 * f(m[0]) + 0.7152 * f(m[1]) + 0.0722 * f(m[2]);
        ch.style.color = L > 0.4 ? '#14141a' : '#f4f4f8';
    });
}
function dualRenderChips() {
    if (!_dualState) _dualState = { ollama: null, localai: null };
    let row = document.getElementById('dual-model-chips');
    // Anchor on .sup-controls, NOT #ollama-wrapper — the LocalAI wrapper is
    // itself inserted directly after #ollama-wrapper, so anchoring there put
    // the chip row *between* the two dropdowns as a third flex item in a
    // nowrap row, squeezing both. Chips belong on their own line under the
    // whole controls row.
    const controls = document.querySelector('#sup-card-ollama .sup-controls');
    if (!controls) return;
    if (!row) {
        row = document.createElement('div');
        row.id = 'dual-model-chips';
        row.style.cssText = 'display:flex;gap:6px;flex-wrap:wrap;margin-top:3px;font-size:10.5px;';
        controls.insertAdjacentElement('afterend', row);
    }
    // Letter badge (O/L) inside each chip, not just color — colorblind users
    // shouldn't need to distinguish these by hue alone.
    const chip = (letter, label, runner, model, color, dim, tip) => model
        ? '<span title="' + escHtml(tip || '') + '" style="background:var(--' + dim + ');border:1px solid var(--' + color + ');border-radius:4px;padding:2px 6px 2px 4px;display:inline-flex;align-items:center;gap:4px;color:var(--text-bright);max-width:100%;overflow:hidden;">' +
          '<b style="background:var(--' + color + ');color:var(--bg-base);border-radius:3px;padding:0 3px;font-size:9.5px;flex:0 0 auto;">' + letter + '</b> ' +
          '<span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + escHtml(label) + ': ' + escHtml(model) + '</span>' +
          '<span style="cursor:pointer;color:inherit;flex:0 0 auto;" onclick="dualClearSlot(\'' + runner + '\')"><span class="material-symbols-rounded ico">close</span></span></span>' : '';
    // The LocalAI caveat used to be inline text here — in a narrow card it ate
    // the whole row. Same honesty, as a tooltip on the chip it describes.
    row.innerHTML =
        chip('O', 'Ollama', 'ollama', _dualState.ollama, 'ollama', 'ollama-dim',
             'Ollama model held for this chat. Click <span class="material-symbols-rounded ico">close</span> to release the slot.') +
        chip('L', 'LocalAI', 'localai', _dualState.localai, 'localai', 'localai-dim',
             'LocalAI model held for this chat. Click <span class="material-symbols-rounded ico">close</span> to release the slot. Note: LocalAI has no confirmed reliable "unload model" API, so releasing updates Cockpit\'s own tracking but can\'t guarantee the model actually leaves LocalAI\'s memory.');
    dualChipInk();
}

// Called from sendPrompt() when Card 3 is active — returns true if it
// handled the send (dual path), false to let the existing single-model
// tmux dispatch continue untouched.
async function dualMaybeIntercept(effectiveText) {
    if (!dualModeActive()) return false;             // plain Ollama/LocalAI — classic path only
    const { ollama, localai } = (_dualState || {});
    if (!ollama && !localai) return false;          // nothing dual-selected — classic path
    if (ollama && !localai) return false;            // classic single-Ollama path already handles this

    setLoading(true);
    const now = new Date();
    const placeholderId = 'msg-dual-' + Date.now();
    const label = (localai && !ollama) ? ('[<span class="material-symbols-rounded ico">dns</span> LOCALAI · ' + localai.toUpperCase() + ']') : '[<span class="material-symbols-rounded ico">smart_toy</span><span class="material-symbols-rounded ico">dns</span> DUAL]';
    appendMsg('agent', label, 'ollama', '', now, '', '', placeholderId);
    const bodyEl = document.getElementById(placeholderId)?.querySelector('.msg-body');

    if (localai && !ollama) {
        // LocalAI-only — classic tmux path can't do this at all, must use HTTP.
        if (bodyEl) bodyEl.innerHTML = '<span style="color:var(--text-dim);font-size:11px;">Generating (LocalAI)…</span>';
        const r = await dualSend(effectiveText, 'winner', 'localai');
        dualRenderFinal(bodyEl, r);
        setLoading(false);
        return true;
    }

    // Both selected — score, then let the user decide.
    if (bodyEl) bodyEl.innerHTML = '<span style="color:var(--text-dim);font-size:11px;">Asking both models to rate their confidence…</span>';
    let scoreRes;
    try {
        scoreRes = await (await fetch('dual_model.php?action=score', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ prompt: effectiveText })
        })).json();
    } catch (e) { scoreRes = { ok: false, error: e.message }; }

    if (!scoreRes || !scoreRes.ok) {
        if (bodyEl) bodyEl.innerHTML = '<span style="color:var(--warn);">Scoring failed: ' + escHtml((scoreRes && scoreRes.error) || 'unknown') + '</span>';
        setLoading(false);
        return true;
    }

    if (bodyEl) bodyEl.innerHTML =
        '<div style="font-size:11px;color:var(--text-dim);">Ollama (' + escHtml(scoreRes.ollama.model) + '): ' + scoreRes.ollama.score + '/10 &nbsp;·&nbsp; ' +
        'LocalAI (' + escHtml(scoreRes.localai.model) + '): ' + scoreRes.localai.score + '/10</div>';

    // Generation happens AFTER the user picks, i.e. after this function has
    // already returned — so each choice has to re-arm the loading state and
    // show its own progress itself, otherwise the real work runs while the
    // UI still says "Ready" with the scores frozen on screen.
    const scoreLine =
        '<div style="font-size:11px;color:var(--text-dim);margin-bottom:6px;">' +
        'Self-rated · <b>O</b> ' + escHtml(scoreRes.ollama.model) + ': ' + scoreRes.ollama.score + '/10' +
        ' &nbsp;·&nbsp; <b>L</b> ' + escHtml(scoreRes.localai.model) + ': ' + scoreRes.localai.score + '/10</div>';
    const pick = (what, fn) => async () => {
        setLoading(true);
        if (bodyEl) bodyEl.innerHTML = scoreLine +
            '<span style="color:var(--text-dim);font-size:11px;">' + escHtml(what) + '…</span>';
        try {
            const r = await dualSend(effectiveText, fn.mode, fn.runner);
            if (fn.combo) dualRenderComboFinal(bodyEl, r); else dualRenderFinal(bodyEl, r);
            if (bodyEl) bodyEl.insertAdjacentHTML('afterbegin', scoreLine);
        } finally {
            setLoading(false);
        }
    };

    _showLifecycleLoadModal(
        'Both models rated their confidence',
        '<b>O</b> Ollama (' + escHtml(scoreRes.ollama.model) + '): <b>' + scoreRes.ollama.score + '/10</b><br>' +
        '<b>L</b> LocalAI (' + escHtml(scoreRes.localai.model) + '): <b>' + scoreRes.localai.score + '/10</b><br><br>' +
        'A model rating itself is a rough hint, not a benchmark — pick whichever you actually want.',
        [
            { label: 'Use Ollama',  accent: 'var(--ollama)',  run: pick('Generating with Ollama',  { mode: 'winner', runner: 'ollama' }) },
            { label: 'Use LocalAI', accent: 'var(--localai)', run: pick('Generating with LocalAI', { mode: 'winner', runner: 'localai' }) },
            { label: 'Compare both', accent: 'var(--text-muted)', run: pick('Running both in parallel', { mode: 'parallel', combo: true }) },
            { label: 'Chain',        accent: 'var(--text-muted)', run: pick('Chaining both in sequence', { mode: 'sequential', combo: true }) },
            { label: 'Judge',        accent: 'var(--gemini)',     run: pick('Running both, then judging', { mode: 'judge', combo: true }) },
        ],
        // Dismissing would otherwise strand a chat message showing only the
        // scores, with no indication the prompt was never actually answered.
        () => { if (bodyEl) bodyEl.innerHTML = scoreLine +
            '<span style="color:var(--text-muted);font-size:11px;">Cancelled — no model answered this prompt.</span>'; }
    );
    setLoading(false);
    return true;
}

async function dualSend(prompt, mode, runner) {
    const body = { prompt, mode };
    if (runner) body.runner = runner;
    try {
        return await (await fetch('dual_model.php?action=send', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        })).json();
    } catch (e) { return { ok: false, error: e.message }; }
}
function dualRenderFinal(bodyEl, r) {
    if (!bodyEl) return;
    const hdr = (r.model || r.runner)
        ? '<div style="font-size:10px;color:var(--text-muted);margin-bottom:4px;">' +
          (r.runner === 'localai' ? '<span class="material-symbols-rounded ico">dns</span> LocalAI' : '<span class="material-symbols-rounded ico">smart_toy</span> Ollama') + ' · ' + escHtml(r.model || '') + '</div>'
        : '';
    bodyEl.innerHTML = hdr + (r.ok ? escHtml(r.text) : '<span style="color:var(--warn);">Error: ' + escHtml(r.error || 'unknown') + '</span>');
}
function dualRenderComboFinal(bodyEl, r) {
    if (!bodyEl) return;
    bodyEl.innerHTML = renderComboResult(r);
}

// Fresh install / no combos downloaded yet: Tier-0 register-unlock empty-state
// (Combo Store concept — no combos ship with the app, download-only + gated).
function combosRenderEmptyTier0() {
    const panel = document.getElementById('ollama-panel');
    if (!panel) return;
    panel.querySelectorAll('[data-t0]').forEach(n => n.remove());
    const signedIn = !!(_saasAcct && _saasAcct.signed_in);
    const hdr = document.createElement('div');
    hdr.className = 'cs-group-header'; hdr.setAttribute('data-t0', '1'); hdr.setAttribute('data-tier', '0'); hdr.setAttribute('data-help', 'combos');
    hdr.style.cssText = 'display:flex;align-items:center;gap:6px;flex-wrap:wrap;';
    hdr.innerHTML = signedIn
        ? '<span class="material-symbols-rounded ico">bolt</span> Power Combos — 0 installed. <button class="action-btn" style="padding:2px 8px;font-size:10px;" onclick="combosDownloadBasePack()"><span class="material-symbols-rounded ico">download</span> Download free 50-combo pack</button>'
        : '<span class="material-symbols-rounded ico">bolt</span> Power Combos — register free to unlock 50 combos. <button class="action-btn" style="padding:2px 8px;font-size:10px;" onclick="saasRequireAccount(\'Power Combos\')">Register</button>';
    panel.insertBefore(hdr, panel.firstChild);
}

// Bulk-pull the free base pack: list kind=combo (base tier), download each,
// install as one merge (bulk replace of the base scope — it's the full set).
async function combosDownloadBasePack() {
    if (!saasRequireAccount('Power Combos')) return;
    appendSystem(T('msg.downloading.the.free.power.combos.pack', 'Downloading the free Power Combos pack…'));
    const l = await saasApi('content_list', { kind: 'combo' });
    if (!l || !l.ok) { appendSystem(T('msg.combo.pack.list.failed.l', 'Combo pack list failed: {l}', {l: (l&&l.error?l.error:'?')})); return; }
    const baseItems = (l.items || []).filter(it => ((it.requirements||{}).combo_tier || 'base') !== 'premium');
    if (!baseItems.length) { appendSystem(T('msg.no.base.combos.available.on.the.server.yet', 'No base combos available on the server yet.')); return; }
    const combos = [];
    for (const it of baseItems) {
        const g = await saasApi('content_get', { content_id: it.id });
        if (!g || !g.ok) continue;
        try { combos.push(JSON.parse(atob(g.payload_b64 || ''))); } catch(e) {}
    }
    if (!combos.length) { appendSystem(T('msg.combo.pack.download.failed.no.items.retrieve', 'Combo pack download failed — no items retrieved.')); return; }
    try {
        const ins = await (await fetch('combos.php?action=install', {method:'POST',headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ scope:'base', merge:0, combos })})).json();
        if (ins && ins.ok) { appendSystem(T('msg.installed.count.power.combos', 'Installed {count} Power Combos.', {count: ins.count})); await combosRefresh(); }
        else appendSystem(T('msg.combo.pack.install.failed.ins', 'Combo pack install failed: {ins}', {ins: (ins && ins.error ? ins.error : 'unknown')}));
    } catch(e) { appendSystem(T('msg.combo.pack.install.failed.message', 'Combo pack install failed: {message}', {message: e.message})); }
}

// Collapse/expand state for Tier-0 category groups — persisted so it
// survives reload. 2026-07-10: added when the combo count went 50→235
// (30 categories) and the flat list got unwieldy. Reusable pattern: see
// Generic retrofit: wire collapse/expand onto ANY .cs-group-header inside a
// panel (Ollama tiers 1-4 static HTML, Workers/Tools dynamically-built
// provider groups). Idempotent — safe to call after every re-render.
function _panelCollapsedSet() {
    try { return new Set(JSON.parse(localStorage.getItem('cockpit_panel_collapsed') || '[]')); }
    catch (e) { return new Set(); }
}
function wireCollapsibleGroupHeaders(panelId) {
    const panel = document.getElementById(panelId);
    if (!panel) return;
    const collapsed = _panelCollapsedSet();
    panel.querySelectorAll('.cs-group-header:not([data-t0]):not([data-cgh-wired])').forEach(h => {
        h.setAttribute('data-cgh-wired', '1');
        const groupKey = panelId + ':' + (h.dataset.tier || h.textContent.trim());
        h.style.cursor = 'pointer';
        h.style.userSelect = 'none';
        const chevron = document.createElement('span');
        chevron.className = 'cgh-chevron';
        chevron.style.cssText = 'display:inline-block;transition:transform .12s;margin-right:4px;';
        const isCollapsed = collapsed.has(groupKey);
        chevron.style.transform = 'rotate(' + (isCollapsed ? '-90deg' : '0deg') + ')';
        chevron.textContent = '▾';
        h.insertBefore(chevron, h.firstChild);
        const applyState = (nowCollapsed) => {
            let sib = h.nextElementSibling;
            while (sib && !sib.classList.contains('cs-group-header')) {
                sib.style.display = nowCollapsed ? 'none' : '';
                sib = sib.nextElementSibling;
            }
        };
        if (isCollapsed) applyState(true);
        h.addEventListener('click', (e) => {
            if (e.target.closest('select')) return;
            const nowCollapsed = !collapsed.has(groupKey);
            if (nowCollapsed) collapsed.add(groupKey); else collapsed.delete(groupKey);
            localStorage.setItem('cockpit_panel_collapsed', JSON.stringify([...collapsed]));
            chevron.style.transform = 'rotate(' + (nowCollapsed ? '-90deg' : '0deg') + ')';
            applyState(nowCollapsed);
        });
    });
}
document.addEventListener('DOMContentLoaded', () => wireCollapsibleGroupHeaders('ollama-panel'));
// makeCollapsibleGroupHeader() below, intended for other grouped lists too
// (not yet applied elsewhere — that's a separate follow-up, flagged, not
// silently done everywhere to avoid a shallow half-implementation).
function _comboCollapsedSet() {
    try { return new Set(JSON.parse(localStorage.getItem('cockpit_combo_collapsed') || '[]')); }
    catch (e) { return new Set(); }
}
function _comboCollapsedSave(set) {
    localStorage.setItem('cockpit_combo_collapsed', JSON.stringify([...set]));
}
// Generic collapsible group header — chevron + label, click toggles all
// sibling rows sharing data-group="groupKey" (no full re-render: just
// flips display + persists state + swaps the chevron glyph). Reusable for
// any grouped list: pass the header element's own group key, the storage
// Set, and the localStorage key to persist under.
function makeCollapsibleGroupHeader(txt, groupKey, collapsedSet, storageKey, extraAttrs) {
    const h = document.createElement('div');
    if (extraAttrs) for (const k in extraAttrs) h.setAttribute(k, extraAttrs[k]);
    h.className = 'cs-group-header';
    h.style.cssText = 'font-size:9px;opacity:0.75;cursor:pointer;user-select:none;display:flex;align-items:center;gap:4px;';
    h.dataset.groupKey = groupKey;
    const collapsed = collapsedSet.has(groupKey);
    h.innerHTML = '<span class="cgh-chevron" style="display:inline-block;transition:transform .12s;transform:rotate(' + (collapsed ? '-90deg' : '0deg') + ');">▾</span><span>' + txt + '</span>';
    h.onclick = () => {
        const nowCollapsed = !collapsedSet.has(groupKey);
        if (nowCollapsed) collapsedSet.add(groupKey); else collapsedSet.delete(groupKey);
        localStorage.setItem(storageKey, JSON.stringify([...collapsedSet]));
        h.querySelector('.cgh-chevron').style.transform = 'rotate(' + (nowCollapsed ? '-90deg' : '0deg') + ')';
        // Sibling rows sharing this header's data-group, up to the next header.
        let sib = h.nextElementSibling;
        while (sib && !sib.classList.contains('cs-group-header') && sib.id !== 'cs-tier0-header') {
            sib.style.display = nowCollapsed ? 'none' : '';
            sib = sib.nextElementSibling;
        }
    };
    return h;
}

// Shared, backend-agnostic combo row — same info for an Ollama-catalog combo,
// a LocalAI-catalog combo, or a "needs both backends" dual combo: favorite
// star, name, owner icons (edit/delete/unpublish — user-authored only), a
// desc line, and a badge with pattern/step-count/size/origin. Unavailable
// (missing a model) combos are unselectable (no onclick) and show what's
// missing on hover, same as everywhere else in the app. `onSelect(el, c)` is
// the caller's own selection wiring — Ollama's classic panel and LocalAI's
// panel each set different state on pick, this row doesn't care which.
// c.missing is [{model, runner}] (combos_core.php's combos_list()) — each
// entry tagged with which backend it's actually missing from, since a dual
// combo can be missing a model on Ollama, on LocalAI, or both, and "missing:
// foo" alone doesn't say where to go install it.
function comboMissingText(missing) {
    return (missing || []).map(m => m.model + ' (' + (m.runner === 'localai' ? 'LocalAI' : 'Ollama') + ')').join(', ');
}
// Sort dropdown for a combo group header — same generic sortOllamaTier() the
// model tiers use, but labelled for combos (size = estimated VRAM, not params).
// Appended into the header label; onclick stops the collapse toggle from firing.
function _comboSortSelect() {
    return ' <button type="button" class="cs-sort-combo" value="alpha" data-modes="alpha:A→Z|small:VRAM ↑|large:VRAM ↓|added:Added order" title="Sorted A to Z; click to change the order" onclick="event.stopPropagation();csCycleSort(this,sortOllamaTier)">A→Z</button>';
}
function comboOptionRow(c, onSelect, extraAttrs) {
    const favs = combosFavs();
    const fav = favs.has(c.id);
    const missingText = comboMissingText(c.missing);
    const row = document.createElement('div');
    row.className = 'cs-option' + (c.available ? '' : ' disabled');
    // Tag the row with the panel's marker (data-t0 / data-lt0) so the tier-0
    // re-render cleanup removes it. WITHOUT this the combo rows survived every
    // re-render and piled up (each combo shown several times), and the grand-
    // total's staticModelCount (.cs-option:not([data-t0])) counted them, wildly
    // inflating the header count (e.g. "Ollama (832)").
    if (extraAttrs) for (const k in extraAttrs) row.setAttribute(k, extraAttrs[k]);
    // VRAM estimate → lets the group's sort combo order combos by size
    // (Small→Large / Large→Small); model rows have no data-vram and fall back
    // to param-count parsing instead. See sortOllamaTier()'s getSize().
    row.dataset.vram = c.est_vram_mb || 0;
    row.dataset.value = 'combo:' + c.id;
    row.dataset.search = (c.name + ' ' + (c.desc || '') + ' ' + (c.category || '')).toLowerCase();
    if (c.available) row.onclick = () => onSelect(row, c);
    else row.title = 'Missing: ' + missingText;
    // Attribution: c.author is only ever set by the DOWNLOAD path (mkt_install.php)
    // — a combo I authored+published myself never has it, letting us tell
    // "mine, published" apart from "downloaded from someone else" with no extra flag.
    const originTag = c.origin === 'user'
        ? (c.author ? ' · by ' + c.author : ' · mine')
        : { store:' · <span class="material-symbols-rounded ico ico-fill">star</span>store', base:'', builtin:' · builtin' }[c.origin || 'builtin'] || '';
    const backendTag = (c.needed_runners || []).length > 1 ? ' · <span class="material-symbols-rounded ico">smart_toy</span><span class="material-symbols-rounded ico">dns</span> dual' : '';
    // badge is HTML (icon spans in backendTag/originTag) — escape only the data parts.
    const badge = escHtml(String(c.pattern)) + ' · ' + escHtml(String(c.steps)) + '× · ~' + escHtml(String(c.est_vram_mb || 0)) + 'MB' + backendTag + originTag;
    let ownerIcons = '';
    if (c.origin === 'user') {
        // Explicit pointer-events:auto — the row itself gets pointer-events:none
        // when disabled (missing a model), which would otherwise also block
        // these icons. A combo you authored yourself should always stay
        // editable/deletable even if it currently references a model you
        // haven't pulled yet — that's exactly the case you'd open Edit to fix.
        ownerIcons =
            '<span onclick="event.stopPropagation();comboEditorOpen(\'' + c.id + '\')" title="Edit (local copy)" style="cursor:pointer;margin-left:4px;color:var(--text-muted);pointer-events:auto;"><span class="material-symbols-rounded ico">edit</span></span>' +
            '<span onclick="event.stopPropagation();comboEditorDelete(\'' + c.id + '\')" title="Delete (local copy)" style="cursor:pointer;margin-left:2px;color:var(--text-muted);pointer-events:auto;"><span class="material-symbols-rounded ico">delete</span></span>';
        if (c.content_id && !c.author) {
            ownerIcons += '<span onclick="event.stopPropagation();comboUnpublish(\'' + c.id + '\',' + c.content_id + ')" title="Unpublish from Marketplace" style="cursor:pointer;margin-left:2px;color:var(--text-muted);pointer-events:auto;"><span class="material-symbols-rounded ico">language</span><span class="material-symbols-rounded ico">close</span></span>';
        }
    }
    row.innerHTML =
        '<span class="cs-option-name t0">' +
          '<span onclick="combosToggleFav(\'' + c.id + '\',event)" title="Favorite" style="cursor:pointer;margin-right:4px;color:' + (fav ? 'var(--gemini,#e6b43c)' : 'var(--text-muted)') + ';pointer-events:auto;">' + (fav ? '<span class="material-symbols-rounded ico ico-fill">star</span>' : '<span class="material-symbols-rounded ico">star</span>') + '</span>' +
          escHtml(c.name) + ownerIcons +
          '<span onclick="event.stopPropagation();hiveComboToChain(\'' + escAttr(c.id) + '\')" title="Make a durable, resumable chain from this combo (Autopilot Cruise)" style="cursor:pointer;margin-left:4px;color:var(--text-muted);pointer-events:auto;font-size:11px;"><span class="material-symbols-rounded ico">link</span></span>' + '</span>' +
        '<span class="cs-option-desc">' + escHtml(c.desc || '') +
            (c.available ? '' : ' — missing: ' + escHtml(missingText)) + '</span>' +
        '<span class="cs-option-badge">' + badge + '</span>';
    return row;
}
// Shared categorized-combos block — Favorites group + one group per
// category (known categories from COMBO_CATS first, then any category a
// user combo introduced that isn't in that map yet, auto-labeled instead of
// silently dropping those combos). Appends into `frag`; groupKeyPrefix keeps
// Ollama's and LocalAI's collapse-state keys independent (e.g. "code" vs
// "localai:code") so collapsing one panel's Code group doesn't affect the
// other's.
function renderCategorizedCombos(frag, combosList, collapsed, groupKeyPrefix, extraAttrs, onSelect) {
    const favs = combosFavs();
    const groupHeader = (txt, key) => makeCollapsibleGroupHeader(txt, groupKeyPrefix + key, collapsed, 'cockpit_combo_collapsed', extraAttrs);
    const favList = combosList.filter(c => favs.has(c.id));
    if (favList.length) {
        const h = groupHeader('<span class="material-symbols-rounded ico ico-fill">star</span> Favorites (' + favList.length + ')' + _comboSortSelect(), '__favorites__');
        frag.appendChild(h);
        favList.forEach(c => { const r = comboOptionRow(c, onSelect, extraAttrs); if (collapsed.has(groupKeyPrefix + '__favorites__')) r.style.display = 'none'; frag.appendChild(r); });
    }
    const seenCats = new Set(combosList.map(c => c.category || '').filter(Boolean));
    const allCats = { ...COMBO_CATS };
    seenCats.forEach(cat => { if (!allCats[cat]) allCats[cat] = cat.replace(/[_-]/g, ' ').replace(/\b\w/g, ch => ch.toUpperCase()); });
    Object.keys(allCats).forEach(cat => {
        const list = combosList.filter(c => (c.category || '') === cat);
        if (!list.length) return;
        const h = groupHeader((COMBO_CAT_ICONS[cat] ? '<span class="material-symbols-rounded ico">' + COMBO_CAT_ICONS[cat] + '</span> ' : '') + allCats[cat] + ' (' + list.length + ')' + _comboSortSelect(), cat);
        frag.appendChild(h);
        list.forEach(c => { const r = comboOptionRow(c, onSelect, extraAttrs); if (collapsed.has(groupKeyPrefix + cat)) r.style.display = 'none'; frag.appendChild(r); });
    });
}
// Shared flat "needs both backends" block — no categories (a handful of
// dual combos at most), same rows as everywhere else. `label` distinguishes
// Ollama's vs LocalAI's copy of this section in the collapse-state key,
// since a dual combo saved while Card 3 was set to Ollama lives in the
// Ollama catalog and one saved while set to LocalAI lives in that catalog —
// each panel only ever shows the dual combos actually in ITS OWN catalog.
function renderNeedsBothSection(frag, dualCombos, collapsed, groupKeyPrefix, extraAttrs, onSelect) {
    const h = makeCollapsibleGroupHeader('<span class="material-symbols-rounded ico">smart_toy</span><span class="material-symbols-rounded ico">dns</span> Needs both backends (' + dualCombos.length + ')' + _comboSortSelect(), groupKeyPrefix + '__needs_both__', collapsed, 'cockpit_combo_collapsed', extraAttrs);
    frag.appendChild(h);
    if (!dualCombos.length) {
        const empty = document.createElement('div');
        if (extraAttrs) for (const k in extraAttrs) empty.setAttribute(k, extraAttrs[k]);
        empty.style.cssText = 'padding:6px 10px;font-size:11px;color:var(--text-muted);';
        empty.textContent = T('msg.none.yet.build.one.with.mixed.runner.steps.v', 'None yet — build one with mixed-runner steps via "+ new combo" and it\'ll show up here.');
        if (collapsed.has(groupKeyPrefix + '__needs_both__')) empty.style.display = 'none';
        frag.appendChild(empty);
    } else {
        dualCombos.forEach(c => { const r = comboOptionRow(c, onSelect, extraAttrs); if (collapsed.has(groupKeyPrefix + '__needs_both__')) r.style.display = 'none'; frag.appendChild(r); });
    }
}

// A dual (mixed-runner) combo's steps already carry their own explicit
// runner per step — forcing a single top-level backend on top of that would
// override real per-step tags, so picking one from either panel always
// clears _selectedComboBackend rather than pinning it, same as the classic
// Ollama picker already does for every combo.
function selectDualCombo(el, c) {
    _selectedCombo = c.id;
    _selectedComboBackend = null;
    document.querySelectorAll('#ollama-panel .cs-option, #localai-panel .cs-option').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    const label = document.getElementById('ollama-selected-label');
    if (label) label.innerHTML = '<span class="material-symbols-rounded ico">bolt</span> ' + escHtml(c.name);
    document.getElementById('ollama-panel')?.classList.remove('open');
    document.getElementById('ollama-trigger')?.classList.remove('open');
    dualCloseLocalAIDropdown();
    if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
}

// (Re)build the whole Ollama panel below the sticky title: a master row
// (grand total across combos+models, filter, new, collapse/expand-all),
// then "Ollama Combos" (categorized, own-catalog only), "Needs both
// backends" (flat), then the existing static Tier 1-4 model rows (untouched,
// already baked into this page's HTML below where this fragment lands).
// Called on load and whenever a favorite is toggled.
function combosRenderTier0() {
    const panel = document.getElementById('ollama-panel');
    if (!panel || !_combosData) return;
    // Remove any existing tier-0 nodes (master row + Combos/Needs-both groups
    // and their rows) — the static Tier 1-4 rows below are untouched, they
    // don't carry data-t0.
    panel.querySelectorAll('[data-t0]').forEach(n => n.remove());

    const collapsed = _comboCollapsedSet();
    const ownCombos  = _combosData.filter(c => (c.needed_runners || []).length <= 1);
    // Merged across BOTH catalogs (see refreshMergedDualCombos()), not just
    // this one — a dual combo saved while Card 3 was set to LocalAI still
    // shows up here.
    const dualNeeded = _mergedDualCombos;
    const staticModelCount = panel.querySelectorAll('.cs-option:not([data-t0])').length;
    // ownCombos + dualNeeded (merged, may include dual combos from the OTHER
    // catalog too) + models — NOT _combosData.length, which would double-count
    // this catalog's own dual combos (they're in both _combosData and the
    // merged dualNeeded list).
    const grandTotal = ownCombos.length + dualNeeded.length + staticModelCount;

    const frag = document.createDocumentFragment();

    // Master row — grand total, filter (panel-wide: combos + models), new
    // combo shortcut, collapse/expand-all. Toggling it hides/shows every
    // data-t0 node (both sub-sections) in one go.
    const master = document.createElement('div');
    master.className = 'cs-group-header'; master.id = 'cs-tier0-header'; master.setAttribute('data-t0', '1'); master.setAttribute('data-help', 'combos');
    master.style.cssText = 'font-weight:600;';
    const masterCollapsed = collapsed.has('__master__');
    master.innerHTML = '<span class="cgh-chevron" style="display:inline-block;transition:transform .12s;transform:rotate(' + (masterCollapsed ? '-90deg' : '0deg') + ');">▾</span>' +
        '<span class="material-symbols-rounded ico">smart_toy</span> Ollama (' + grandTotal + ') ' +
        '<input id="combo-filter" placeholder="filter all…" oninput="combosFilterTier0()" onclick="event.stopPropagation()" ' +
        'style="margin-left:6px;font-size:10px;padding:1px 5px;border:1px solid var(--border-dim);border-radius:3px;background:var(--bg-active);color:var(--text-primary);width:90px;">' +
        '<span onclick="event.stopPropagation();combosCollapseAll()" title="Collapse all groups" style="margin-left:6px;cursor:pointer;font-size:9px;opacity:.75;">⊟ all</span>' +
        '<span onclick="event.stopPropagation();combosExpandAll()" title="Expand all groups" style="margin-left:4px;cursor:pointer;font-size:9px;opacity:.75;">⊞ all</span>' +
        '<span onclick="event.stopPropagation();comboEditorOpen()" title="Create your own combo" style="margin-left:8px;cursor:pointer;font-size:9px;opacity:.85;color:var(--gemini,#e6b43c);">＋ new</span>';
    master.onclick = () => {
        const nowCollapsed = !collapsed.has('__master__');
        if (nowCollapsed) collapsed.add('__master__'); else collapsed.delete('__master__');
        _comboCollapsedSave(collapsed);
        master.querySelector('.cgh-chevron').style.transform = 'rotate(' + (nowCollapsed ? '-90deg' : '0deg') + ')';
        let sib = master.nextElementSibling;
        while (sib && sib.hasAttribute('data-t0')) {
            sib.style.display = nowCollapsed ? 'none' : '';
            sib = sib.nextElementSibling;
        }
    };
    frag.appendChild(master);

    if (_combosLocked.length) {
        const warn = document.createElement('div');
        warn.setAttribute('data-t0', '1');
        warn.style.cssText = 'padding:6px 14px;font-size:10px;color:var(--accent-amber,#e6b43c);background:rgba(230,180,60,.08);border-bottom:1px solid var(--border-dim);';
        const label = { store: 'premium (extended set)', base: 'base' }[_combosLocked[0]] || _combosLocked.join(', ');
        warn.innerHTML = '<span class="material-symbols-rounded ico">warning</span> Some ' + escHtml(label) + ' combos exist on disk but can\'t be unlocked on this account/machine — sign in with the account that downloaded them, or re-download from the Marketplace.';
        frag.appendChild(warn);
    }

    // "Ollama Combos" — own-catalog combos, categorized, TIER 0.
    const comboHdr = makeCollapsibleGroupHeader('<span class="material-symbols-rounded ico">bolt</span> Ollama Combos (' + ownCombos.length + ')' + _comboSortSelect(), '__ollama_combos__', collapsed, 'cockpit_combo_collapsed', { 'data-t0': '1' });
    frag.appendChild(comboHdr);
    renderCategorizedCombos(frag, ownCombos, collapsed, '', { 'data-t0': '1' }, (el, c) => selectOllamaModel(el));

    // "Needs both backends" — dual combos that happen to live in this
    // catalog (saved while Card 3 was set to Ollama).
    renderNeedsBothSection(frag, dualNeeded, collapsed, '', { 'data-t0': '1' }, selectDualCombo);

    if (masterCollapsed) {
        frag.querySelectorAll('[data-t0]').forEach(n => { if (n !== master) n.style.display = 'none'; });
    }
    // Insert after the sticky title bar (Ollama Models), not as the very
    // first child — the title stays pinned on top via position:sticky and
    // must never get pushed down by a Tier 0 re-render. Everything here
    // lands BEFORE the static Tier 1-4 model rows, which is already where
    // they physically sit in this page's raw HTML.
    const titleEl = panel.querySelector('.cs-panel-title');
    panel.insertBefore(frag, titleEl ? titleEl.nextSibling : panel.firstChild);

    const prev = combosRenderTier0._filter || '';
    if (prev) { const f = document.getElementById('combo-filter'); if (f) { f.value = prev; combosFilterTier0(); } }
}

// Ollama tier-0 filter box → filter the WHOLE Ollama list (combos + models).
function combosFilterTier0() {
    const f = document.getElementById('combo-filter');
    const q = (f ? f.value : '').trim().toLowerCase();
    combosRenderTier0._filter = q;
    panelFilter('ollama-panel', q);
    // panelFilter force-shows every matching row (including inside collapsed
    // groups — correct while actively searching, you want hits visible
    // regardless). Clearing the search should restore collapse state rather
    // than leaving everything forced open.
    if (!q) {
        const collapsed = _comboCollapsedSet();
        document.querySelectorAll('#ollama-panel .cs-group-header[data-group-key]').forEach(h => {
            const isCollapsed = collapsed.has(h.dataset.groupKey);
            let sib = h.nextElementSibling;
            while (sib && !sib.classList.contains('cs-group-header') && sib.id !== 'cs-tier0-header') {
                sib.style.display = isCollapsed ? 'none' : '';
                sib = sib.nextElementSibling;
            }
        });
    }
}
function combosCollapseAll() {
    const collapsed = _comboCollapsedSet();
    document.querySelectorAll('#ollama-panel .cs-group-header[data-group-key]').forEach(h => collapsed.add(h.dataset.groupKey));
    _comboCollapsedSave(collapsed);
    combosRenderTier0();
}
function combosExpandAll() {
    _comboCollapsedSave(new Set());
    combosRenderTier0();
}
// Generic dropdown filter: matches every cs-option by text (or data-search),
// hides group headers with no visible rows. Keeps any header holding an input.
function panelFilter(panelId, q) {
    q = (q || '').trim().toLowerCase();
    const panel = document.getElementById(panelId); if (!panel) return;
    // A group whose OWN NAME matches keeps all its options (typing "legal" must show "Legal review" and its presets, whose labels do not contain the word).
    // The name is the header's leading text, before its sort dropdown.
    const hitGroups = new Set();
    if (q) panel.querySelectorAll('.cs-group-header').forEach(h => {
        if (h.querySelector('input')) return;
        const hc = h.cloneNode(true); hc.querySelectorAll('select,button,input,.cgh-chevron').forEach(x => x.remove()); const title = hc.textContent;   // the chevron span comes first, so reading only the leading text node found no name
        if (title.toLowerCase().indexOf(q) >= 0) hitGroups.add(h);
    });
    let curHdr = null;
    Array.from(panel.children).forEach(r => {
        if (r.classList.contains('cs-group-header')) { curHdr = r; return; }
        if (!r.classList.contains('cs-option')) return;
        const txt = (r.dataset.search || r.textContent || '').toLowerCase();
        r.style.display = (!q || txt.indexOf(q) >= 0 || (curHdr && hitGroups.has(curHdr))) ? '' : 'none';
    });
    panel.querySelectorAll('.cs-group-header').forEach(h => {
        if (h.querySelector('input')) return;   // never hide a filter/search header
        let n = h.nextElementSibling, any = false;
        while (n && !n.classList.contains('cs-group-header')) {
            if (n.classList.contains('cs-option') && n.style.display !== 'none') { any = true; break; }
            n = n.nextElementSibling;
        }
        h.style.display = any ? '' : 'none';
    });
}
// Inject a sticky filter box at the top of a panel (Workers/Tools, which have
// no tier-0 header of their own). Idempotent.
function panelEnsureFilter(panelId) {
    const panel = document.getElementById(panelId); if (!panel) return;
    if (document.getElementById(panelId + '-filterbox')) return;
    const box = document.createElement('div');
    box.id = panelId + '-filterbox'; box.className = 'cs-group-header';
    box.style.cssText = 'position:sticky;top:0;z-index:5;';
    box.innerHTML = '<input placeholder="filter…" oninput="panelFilter(\'' + panelId + '\',this.value)" onclick="event.stopPropagation()" style="width:100%;box-sizing:border-box;font-size:11px;padding:3px 6px;border:1px solid var(--border-dim);border-radius:3px;background:var(--bg-active);color:var(--text-primary);">';
    panel.insertBefore(box, panel.firstChild);
}
document.addEventListener('DOMContentLoaded', combosInitTier0);
document.addEventListener('DOMContentLoaded', () => setTimeout(dualInit, 600));

// ── Generic favorite stars for any custom-select panel (Ollama models,
// Workers, Tools). / toggle that floats favorites to the top of their group,
// persisted per-panel in localStorage. Combo rows handle their own star.
function panelFavs(key) { try { return new Set(JSON.parse(localStorage.getItem(key) || '[]')); } catch (e) { return new Set(); } }
function panelToggleFav(panelId, key, value, ev) {
    if (ev) ev.stopPropagation();
    const f = panelFavs(key);
    f.has(value) ? f.delete(value) : f.add(value);
    localStorage.setItem(key, JSON.stringify([...f]));
    panelApplyStars(panelId, key);
}
function panelInjectStars(panelId, key) {
    const panel = document.getElementById(panelId);
    if (!panel) return;
    panel.querySelectorAll('.cs-option').forEach(row => {
        const v = row.dataset.value || '';
        if (v.indexOf('combo:') === 0) return;            // combos handle their own star
        const nameEl = row.querySelector('.cs-option-name');
        if (!nameEl || nameEl.querySelector('.fav-star')) return;
        const star = document.createElement('span');
        star.className = 'fav-star';
        star.style.cssText = 'cursor:pointer;margin-right:4px;';
        star.innerHTML = '<span class="material-symbols-rounded ico">star</span>';
        star.setAttribute('onclick', "panelToggleFav('" + panelId + "','" + key + "','" + v.replace(/'/g, '') + "',event)");
        nameEl.insertBefore(star, nameEl.firstChild);
    });
    panelApplyStars(panelId, key);
}
// Option label without its favourite star (the star is an icon span inside the name).
function _optName(nameEl) { const c = nameEl.cloneNode(true); c.querySelectorAll('.fav-star').forEach(x => x.remove()); return c.textContent.trim(); }
function panelApplyStars(panelId, key) {
    const panel = document.getElementById(panelId);
    if (!panel) return;
    const favs = panelFavs(key);
    panel.querySelectorAll('.cs-option').forEach(row => {
        const v = row.dataset.value || '';
        if (v.indexOf('combo:') === 0) return;
        const star = row.querySelector('.fav-star');
        if (!star) return;
        const f = favs.has(v);
        star.innerHTML = '<span class="material-symbols-rounded ico' + (f ? ' ico-fill' : '') + '">star</span>';
        star.style.color = f ? 'var(--gemini,#e6b43c)' : 'var(--text-muted)';
    });
    // Float favorites to the top of each group (skip the combo tier-0 groups).
    panel.querySelectorAll('.cs-group-header').forEach(h => {
        if (h.id === 'cs-tier0-header' || h.getAttribute('data-t0')) return;
        const rows = [];
        let n = h.nextElementSibling;
        while (n && !n.classList.contains('cs-group-header')) {
            if (n.classList.contains('cs-option')) rows.push(n);
            n = n.nextElementSibling;
        }
        rows.filter(r => favs.has(r.dataset.value || '')).reverse()
            .forEach(r => h.parentNode.insertBefore(r, h.nextSibling));
    });
    // Panels with no group headers (Workers/Tools): float favorites to panel top.
    if (!panel.querySelector('.cs-group-header:not([data-t0]):not(#cs-tier0-header)')) {
        [...panel.querySelectorAll('.cs-option')].filter(r => favs.has(r.dataset.value || '')).reverse()
            .forEach(r => panel.insertBefore(r, panel.firstChild));
    }
}
// Inject stars whenever a panel is shown (covers dynamically-rendered Workers/Tools).
function panelStarsRefreshAll() {
    panelInjectStars('ollama-panel', 'cockpit_model_favs');
    panelInjectStars('workers-panel', 'cockpit_workers_favs');
    panelEnsureFilter('workers-panel');
    panelInjectStars('tools-panel', 'cockpit_tools_favs');
    panelEnsureFilter('tools-panel');
}
document.addEventListener('DOMContentLoaded', panelStarsRefreshAll);

// This machine, for the top bar: "i5-10600K · 32GB · RX 6500 XT 4GB" from the
// server-side hardware scan (hardware.php). It was a literal once — every install
// showed the author's rig. Also the VRAM total the live meter divides by.
let _hwVramMb = 0;
function hwShort(s) {
    // vendor strings are noisy: "Intel(R) Core(TM) i5-10600K CPU @ 4.10GHz" → "i5-10600K",
    // "Advanced Micro Devices, Inc. [AMD/ATI] Navi 24 [Radeon RX 6400/6500 XT/6500M] (rev c1)" → "Radeon RX 6400/6500 XT/6500M"
    s = String(s || '');
    const br = s.match(/\[([^\]]*(?:Radeon|GeForce|RTX|GTX|Arc|Iris|UHD)[^\]]*)\]/i); if (br) s = br[1];
    return s.replace(/\((R|TM|tm|rev [^)]*)\)/g, '').replace(/\b(CPU|Processor)\b/g, '').replace(/ ?@.*$/, '')
            .replace(/\d+-Core.*$/, '').replace(/^ *(Intel|AMD|Apple|Advanced Micro Devices, Inc\.|NVIDIA( Corporation)?) */i, '')
            .replace(/^Core */, '').replace(/ +/g, ' ').trim();
}
async function rigLineLoad() {
    const el = document.getElementById('rig-line'); if (!el) return;
    try {
        const d = await (await fetch('hardware.php')).json();
        const hw = (d && d.hw) || {};
        _hwVramMb = +hw.gpu_vram_mb || 0;
        const parts = [];
        // the machine's software first: OS + version, desktop, terminal, file manager
        const os = (d && d.os) || {};
        if (os.name) parts.push(os.name + (os.version ? ' ' + os.version : ''));
        if (os.desktop) parts.push(os.desktop);
        if (os.terminal) parts.push(os.terminal);
        if (os.files) parts.push(os.files);
        if (hw.cpu_model) parts.push(hwShort(hw.cpu_model) + (hw.cpu_cores ? ' ×' + hw.cpu_cores : ''));
        else if (hw.cpu_cores) parts.push(hw.cpu_cores + ' cores');
        if (hw.ram_mb) parts.push(Math.round(hw.ram_mb / 1024) + 'GB');
        if (hw.gpu_name) parts.push(hwShort(hw.gpu_name) + (_hwVramMb ? ' ' + (_hwVramMb / 1024).toFixed(_hwVramMb % 1024 ? 1 : 0) + 'GB' : ''));
        else if (_hwVramMb) parts.push('GPU ' + (_hwVramMb / 1024).toFixed(1) + 'GB');
        el.textContent = parts.length ? parts.join(' · ') : 'hardware: unknown';
    } catch (e) { el.textContent = ''; }
}
// after the login gate: before the session is confirmed hardware.php answers 401 → 'hardware: unknown' (b73)
document.addEventListener('DOMContentLoaded', () => { if (typeof authGateReady === 'function') authGateReady().then(rigLineLoad); else rigLineLoad(); });

// Live VRAM monitor — polls ollama_ps.php; colorblind-safe ( + "HIGH" text).
async function vramPoll() {
    const el = document.getElementById('vram-live'); if (!el) return;
    // The native window reads /sys and /proc itself: the true GPU figure (every
    // process, not only Ollama's models) without a request per tick.
    if (_inShell) {
        try {
            const d = await shellCall('sysinfo');
            if (d && d.vram_total_mb) {
                const used = d.vram_used_mb || 0, tot = d.vram_total_mb;
                const high = used > tot * 0.92;
                el.innerHTML = ' · ' + (high ? '<span class="material-symbols-rounded ico">warning</span> ' : '') +
                    'GPU ' + (used / 1024).toFixed(1) + '/' + (tot / 1024).toFixed(1) + ' GB' +
                    (d.gpu_pct !== undefined ? ' (' + d.gpu_pct + '%' + (high ? ', HIGH' : '') + ')' : '');
                el.style.fontWeight = high ? '700' : '400';
                el.title = 'GPU busy ' + (d.gpu_pct ?? '?') + '% · VRAM ' + used + '/' + tot + ' MB · CPU ' + (d.cpu_pct ?? '?') + '% · RAM ' + Math.round((d.mem_used_mb || 0) / 1024) + '/' + Math.round((d.mem_total_mb || 0) / 1024) + ' GB';
                return;
            }
        } catch (e) {}
    }
    try {
        const d = await (await fetch('ollama_ps.php')).json();
        if (!d || !d.ok) { el.textContent = ''; return; }
        const used = d.total_mb || 0, gb = (used / 1024).toFixed(1);
        const n = d.models ? d.models.length : 0, high = used > (_hwVramMb ? _hwVramMb * 0.92 : 3800);
        // no detected VRAM → show what Ollama holds, not a made-up ceiling
        el.innerHTML = ' · ' + (high ? '<span class="material-symbols-rounded ico">warning</span> ' : '') + (_hwVramMb ? 'GPU ' + gb + '/' + (_hwVramMb / 1024).toFixed(1) : 'models ' + gb) + ' GB' +
            (n ? (' (' + n + (n > 1 ? ' models' : ' model') + (high ? ', HIGH' : '') + ')') : ' (idle)');
        el.style.fontWeight = high ? '700' : '400';
    } catch (e) { el.textContent = ''; }
}
setInterval(vramPoll, 5000);
document.addEventListener('DOMContentLoaded', vramPoll);

// Ollama card live metrics — the scarcity for local inference is hardware, not
// quota, so we surface tok/s + VRAM + GPU-split + keep-alive (one row per loaded
// model). tok/s is computed from the last call's output tokens ÷ ms (already
// tracked on the card); VRAM/keep-alive come from ollama_ps.php (/api/ps).
function _fmtKeepAlive(s) {
    if (s == null) return '';
    if (s <= 0) return 'idle';
    const m = Math.floor(s / 60), ss = s % 60;
    return m + ':' + String(ss).padStart(2, '0');
}
async function ollamaCardMeter() {
    const el = document.getElementById('ollama-live-metrics'); if (!el) return;
    const o = document.getElementById('ollama-d-output'), t = document.getElementById('ollama-d-ms');
    const toks = o ? (parseInt(o.textContent) || 0) : 0;
    const ms   = t ? (parseInt(t.textContent) || 0) : 0;
    const tps  = (ms > 0 && toks > 0) ? (toks / (ms / 1000)) : null;
    try {
        const d = await (await fetch('ollama_ps.php')).json();
        const models = (d && d.ok && d.models) ? d.models : [];
        let head = tps ? ('<span class="material-symbols-rounded ico">bolt</span> ' + tps.toFixed(1) + ' tok/s') : '';
        if (d && d.total_vram_mb) head += (head ? ' · ' : '') + '<span class="material-symbols-rounded ico">sports_esports</span> ' + (d.total_vram_mb / 1024).toFixed(1) + ' GB VRAM';
        if (!models.length) head += (head ? ' · ' : '') + 'idle (no model loaded)';
        const rows = models.map(m => {
            const ka = _fmtKeepAlive(m.keep_alive_s);
            return '<div>' + escHtml(m.name) + ' · ' + escHtml(m.processor || '') +
                   ' · ' + ((m.vram_mb || 0) / 1024).toFixed(1) + 'GB' + (ka ? (' · ⏱ ' + ka) : '') + '</div>';
        }).join('');
        el.innerHTML = (head ? '<div style="color:var(--ollama);font-weight:700;">' + head + '</div>' : '') + rows;
    } catch (e) { el.innerHTML = tps ? ('<span class="material-symbols-rounded ico">bolt</span> ' + tps.toFixed(1) + ' tok/s') : ''; }
}
setInterval(ollamaCardMeter, 5000);
document.addEventListener('DOMContentLoaded', () => setTimeout(ollamaCardMeter, 800));

// Run a Power Combo via combos.php and render the multi-model result.
// Run a combo with LIVE token streaming (SSE). Falls back to the non-streaming
// POST endpoint if EventSource fails or the prompt is too long for a GET URL.
// Pool B usage credit — a combo I DOWNLOADED (not one I authored/published
// myself) reports a usage event to the Marketplace on each successful run.
// Self-runs never fire this (author unset on my own combos — see comboRow's
// origin logic) and the server also self-excludes as a backstop.
function comboReportUsage(comboId) {
    const c = (_combosData || []).find(x => x.id === comboId);
    if (c && c.origin === 'user' && c.content_id && c.author) {
        saasApi('content_usage', { content_id: c.content_id }).catch(() => {});
    }
}
function runCombo(comboId, prompt) {
    setLoading(true);
    const now = new Date();
    const placeholderId = 'msg-combo-' + Date.now();
    appendMsg('agent', '[[[icon:bolt]] COMBO · ' + comboId + ']', 'ollama', '', now, '', '', placeholderId);
    const bodyEl = document.getElementById(placeholderId)?.querySelector('.msg-body');
    if (bodyEl) bodyEl.innerHTML = '<span style="color:var(--text-dim);font-size:11px;">Starting combo…</span>';

    // combos_stream.php's live-token path only ever queries Ollama (never
    // built out for LocalAI's different chunk format) — a combo picked from
    // the LocalAI column always goes non-streaming instead of silently
    // querying the wrong server. Same real answer, just not token-by-token.
    if (_selectedComboBackend === 'localai') { runComboNonStream(comboId, prompt, bodyEl); return; }

    if (prompt.length > 2500 || typeof EventSource === 'undefined') { runComboNonStream(comboId, prompt, bodyEl); return; }

    const qs = 'combo_id=' + encodeURIComponent(comboId) + '&prompt=' + encodeURIComponent(prompt) +
               '&project=' + encodeURIComponent(currentProject) + '&chat=' + encodeURIComponent(currentChat);
    let es;
    try { es = new EventSource('combos_stream.php?' + qs); } catch (e) { runComboNonStream(comboId, prompt, bodyEl); return; }
    let gotInit = false, finished = false;
    const sid = s => 'cb-' + (s || '').replace(/[^a-zA-Z0-9]/g, '_');
    const mkBox = (st, isJudge) => {
        const id = sid(st.id);
        return '<div style="border:1px solid var(--border-dim);border-radius:5px;padding:8px;background:var(--bg-active);' + (isJudge ? 'border-color:var(--gemini,#e6b43c);' : '') + '">' +
            '<div style="font-size:10px;color:var(--text-muted);margin-bottom:4px;border-bottom:1px solid var(--border-dim);padding-bottom:3px;"><b>' + escHtml(st.role || st.id) + '</b> · ' + escHtml(st.model || '') + ' <span id="' + id + '-st">· …</span></div>' +
            '<div id="' + id + '-body" style="white-space:pre-wrap;font-size:12px;max-height:340px;overflow:auto;"></div></div>';
    };
    es.addEventListener('init', ev => {
        gotInit = true;
        const d = JSON.parse(ev.data);
        let html = '<div style="font-size:10px;color:var(--text-dim);margin-bottom:4px;"><span class="material-symbols-rounded ico">bolt</span> ' + escHtml(d.combo) + ' · ' + d.pattern.toUpperCase() + ' · streaming</div>';
        if (d.judge) html += mkBox(d.judge, true);
        if (d.pattern === 'sequential') html += '<div style="display:flex;flex-direction:column;gap:6px;">' + d.steps.map((s, i) => mkBox(s) + (i < d.steps.length - 1 ? '<div style="text-align:center;color:var(--text-muted);font-size:11px;">↓</div>' : '')).join('') + '</div>';
        else html += '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:6px;">' + d.steps.map(s => mkBox(s)).join('') + '</div>';
        if (bodyEl) bodyEl.innerHTML = html;
    });
    es.addEventListener('token', ev => {
        const d = JSON.parse(ev.data);
        const b = document.getElementById(sid(d.step) + '-body');
        if (b) { b.textContent += d.t; b.scrollTop = b.scrollHeight; }
    });
    es.addEventListener('step_done', ev => {
        const d = JSON.parse(ev.data);
        const st = document.getElementById(sid(d.step) + '-st');
        if (st) st.innerHTML = '· ' + d.ms + 'ms <span class="material-symbols-rounded ico">check</span>';
    });
    es.addEventListener('done', () => {
        finished = true; es.close(); setLoading(false);
        document.querySelectorAll('[id^="cb-"][id$="-body"]').forEach(b => { if (!b.textContent) b.innerHTML = '<span style="color:var(--text-muted);">(empty output)</span>'; });
        comboReportUsage(comboId);
    });
    es.onerror = () => {
        if (finished) return;
        es.close(); setLoading(false);
        if (!gotInit) runComboNonStream(comboId, prompt, bodyEl);   // never started → fall back
        else if (bodyEl) bodyEl.insertAdjacentHTML('beforeend', '<div style="color:var(--warn);font-size:11px;">[stream interrupted]</div>');
    };
}

// Non-streaming combo run (fallback / long prompts).
async function runComboNonStream(comboId, prompt, bodyEl) {
    if (bodyEl) bodyEl.innerHTML = '<span style="color:var(--text-dim);font-size:11px;">Running combo…</span>';
    let data;
    try {
        const body = { combo_id: comboId, prompt: prompt, project: currentProject, chat: currentChat,
                       style: (typeof currentStyle !== 'undefined' ? currentStyle : ''),
                       mode:  (typeof maMode       !== 'undefined' ? maMode       : '') };
        if (_selectedComboBackend) body.backend = _selectedComboBackend;
        const res = await fetch('combos.php?action=run', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        data = await res.json();
    } catch (e) {
        if (bodyEl) bodyEl.innerHTML = '<span style="color:var(--warn);">Combo failed: ' + escHtml(e.message) + '</span>';
        setLoading(false); return;
    }
    if (bodyEl) bodyEl.innerHTML = renderComboResult(data);
    setLoading(false);
    if (data && data.ok) comboReportUsage(comboId);
}

// Render combo JSON → grid (parallel) / pipeline (sequential) / verdict (judge).
// Protanopia-safe: each box labelled by ROLE + model, not colour.
function renderComboResult(d) {
    if (!d || !d.ok) return '<span style="color:var(--warn);">Combo error: ' + escHtml((d && d.error) || 'unknown') + '</span>';
    const box = s => '<div style="border:1px solid var(--border-dim);border-radius:5px;padding:8px;background:var(--bg-active);">' +
        '<div style="font-size:10px;color:var(--text-muted);margin-bottom:4px;border-bottom:1px solid var(--border-dim);padding-bottom:3px;">' +
        '<b>' + escHtml(s.role || s.id) + '</b> · ' + escHtml(s.model || '') + ' · ' + (s.ms || 0) + 'ms' +
        (s.ok ? '' : ' · <span style="color:var(--warn);">ERROR</span>') + '</div>' +
        '<div style="white-space:pre-wrap;font-size:12px;">' + (s.ok ? (s.text ? escHtml(s.text) : '<span style="color:var(--text-muted);">(empty output)</span>') : escHtml(s.error || 'error')) + '</div></div>';
    const head = lbl => '<div style="font-size:10px;color:var(--text-dim);margin-bottom:4px;"><span class="material-symbols-rounded ico">bolt</span> ' + escHtml(d.combo) + ' · ' + lbl + '</div>';

    if (d.pattern === 'judge' && d.judge) {
        return head('JUDGE VERDICT') +
            box({ role: 'Judge', model: d.judge.model, ms: d.judge.ms, ok: d.judge.ok, text: d.final, error: d.judge.error }) +
            '<details style="margin-top:6px;"><summary style="font-size:10px;color:var(--text-muted);cursor:pointer;">candidates (' + d.steps.length + ')</summary>' +
            '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:6px;margin-top:6px;">' + d.steps.map(box).join('') + '</div></details>';
    }
    if (d.pattern === 'sequential') {
        return head('PIPELINE') +
            '<div style="display:flex;flex-direction:column;gap:6px;">' +
            d.steps.map((s, i) => box(s) + (i < d.steps.length - 1 ? '<div style="text-align:center;color:var(--text-muted);font-size:11px;">↓</div>' : '')).join('') +
            '</div>';
    }
    return head('PARALLEL (' + d.steps.length + ')') +
        '<div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:6px;">' + d.steps.map(box).join('') + '</div>';
}

// Close dropdown when clicking outside
document.addEventListener('click', e => {
    const wrapper = document.getElementById('ollama-wrapper');
    if (wrapper && !wrapper.contains(e.target)) {
        document.getElementById('ollama-panel').classList.remove('open');
        document.getElementById('ollama-trigger').classList.remove('open');
    }
});

// ── Ollama panel: per-tier sort ──────────────────────────────────────────────
function sortOllamaTier(combo) {
    const header = combo.closest('.cs-group-header');
    if (!header) return;
    const mode = combo.value;
    const options = [];
    let sib = header.nextElementSibling;
    while (sib && !sib.classList.contains('cs-group-header')) {
        if (sib.classList.contains('cs-option')) options.push(sib);
        sib = sib.nextElementSibling;
    }
    if (options.length < 2) return;
    // snapshot original order via data-attr (set once)
    options.forEach((o, i) => { if (!o.dataset.origIdx) o.dataset.origIdx = i; });
    const getName = o => (o.querySelector('.cs-option-name')?.textContent || '').trim().toLowerCase();
    const getSize = o => {
        // Combo rows carry an explicit VRAM estimate (data-vram); model rows
        // don't, so fall back to parsing a param count out of the model name.
        if (o.dataset.vram !== undefined && o.dataset.vram !== '') {
            const mb = parseFloat(o.dataset.vram);
            if (mb > 0) return mb;
        }
        const v = o.dataset.value || getName(o);
        return ollamaParamB(v);
    };
    options.sort((a, b) => {
        if (mode === 'alpha') return getName(a).localeCompare(getName(b));
        if (mode === 'small') {
            const sa = getSize(a), sb = getSize(b);
            if (sa < 0 && sb < 0) return getName(a).localeCompare(getName(b));
            if (sa < 0) return 1; if (sb < 0) return -1;
            return sa - sb || getName(a).localeCompare(getName(b));
        }
        if (mode === 'large') {
            const sa = getSize(a), sb = getSize(b);
            if (sa < 0 && sb < 0) return getName(a).localeCompare(getName(b));
            if (sa < 0) return 1; if (sb < 0) return -1;
            return sb - sa || getName(a).localeCompare(getName(b));
        }
        // added order
        return (parseInt(a.dataset.origIdx)||0) - (parseInt(b.dataset.origIdx)||0);
    });
    const parent = header.parentNode;
    const insertBefore = sib; // next header or null
    options.forEach(o => parent.insertBefore(o, insertBefore));
}

// Initial alphabetical sort on load
document.addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('#ollama-panel .cs-sort-combo').forEach(c => sortOllamaTier(c));
});

// ── Ollama panel: resizable + persist size ──────────────────────────────────
(function() {
    const SK = 'cockpit_ollama_panel_size';
    const panel = document.getElementById('ollama-panel');
    if (!panel) return;
    const saved = JSON.parse(localStorage.getItem(SK) || 'null');
    if (saved) {
        if (saved.w) panel.style.width = saved.w + 'px';
        // Floor at 320px — a stale tiny drag from before resize was fixed
        // would otherwise permanently cap the panel on every future load.
        if (saved.h) panel.style.maxHeight = Math.max(320, saved.h) + 'px';
    }
    const ro = new ResizeObserver(entries => {
        for (const e of entries) {
            const r = e.contentRect;
            if (r.width > 0 && r.height > 0) {
                localStorage.setItem(SK, JSON.stringify({w: Math.round(r.width), h: Math.round(r.height)}));
            }
        }
    });
    ro.observe(panel);
})();

// ── Workers & Tools modals: resizable + persist size ────────────────────────
['workers-modal-inner','tools-modal-inner'].forEach(id => {
    const SK = 'cockpit_' + id + '_size';
    const el = document.getElementById(id);
    if (!el) return;
    const saved = JSON.parse(localStorage.getItem(SK) || 'null');
    if (saved) {
        if (saved.w) el.style.width = saved.w + 'px';
        if (saved.h) el.style.maxHeight = saved.h + 'px';
    }
    new ResizeObserver(entries => {
        for (const e of entries) {
            const r = e.contentRect;
            if (r.width > 0 && r.height > 0)
                localStorage.setItem(SK, JSON.stringify({w: Math.round(r.width), h: Math.round(r.height)}));
        }
    }).observe(el);
});

// ── Workers custom dropdown ─────────────────────────────────────────────────
function toggleWorkersDropdown() {
    const trigger = document.getElementById('workers-trigger');
    const panel   = document.getElementById('workers-panel');
    panelInjectStars('workers-panel', 'cockpit_workers_favs');
    panelEnsureFilter('workers-panel');
    const isOpen  = panel.classList.contains('open');
    if (isOpen) {
        panel.classList.remove('open'); trigger.classList.remove('open');
        panel.style.position = ''; panel.style.top = ''; panel.style.left = ''; panel.style.minWidth = '';
    } else {
        const rect = trigger.getBoundingClientRect();
        panel.style.position = 'fixed';
        panel.style.top = (rect.bottom + 4) + 'px';
        panel.style.left = rect.left + 'px';
        panel.style.minWidth = Math.max(320, rect.width) + 'px';
        _panelCapToFooter(panel, rect.bottom + 4);
        panel.classList.add('open'); trigger.classList.add('open'); _panelRevealSelected(panel);
    }
}
function selectWorkersModel(el) {
    if (el.classList.contains('disabled')) return;
    document.getElementById('workers-model').value = el.dataset.value;
    document.getElementById('workers-selected-label').textContent = el.querySelector('.cs-option-name') && _optName(el.querySelector('.cs-option-name'));
    document.querySelectorAll('#workers-panel .cs-option').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    localStorage.setItem('cockpit_last_workers_model', el.dataset.value);
    document.getElementById('workers-panel').classList.remove('open');
    document.getElementById('workers-trigger').classList.remove('open');
    if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
}
function sortWorkersTier(combo) {
    const header = combo.closest('.cs-group-header');
    if (!header) return;
    const mode = combo.value;
    const options = [];
    let sib = header.nextElementSibling;
    while (sib && !sib.classList.contains('cs-group-header')) {
        if (sib.classList.contains('cs-option')) options.push(sib);
        sib = sib.nextElementSibling;
    }
    if (options.length < 2) return;
    options.forEach((o, i) => { if (!o.dataset.origIdx) o.dataset.origIdx = i; });
    const getName = o => (o.querySelector('.cs-option-name')?.textContent || '').trim().toLowerCase();
    options.sort((a, b) => mode === 'alpha' ? getName(a).localeCompare(getName(b)) :
        (parseInt(a.dataset.origIdx)||0) - (parseInt(b.dataset.origIdx)||0));
    const parent = header.parentNode;
    const insertBefore = sib;
    options.forEach(o => parent.insertBefore(o, insertBefore));
}
document.addEventListener('click', e => {
    const w = document.getElementById('workers-wrapper');
    const p = document.getElementById('workers-panel');
    if (w && p && p.classList.contains('open') && !w.contains(e.target)) {
        p.classList.remove('open');
        document.getElementById('workers-trigger')?.classList.remove('open');
    }
});

// ── Tools custom dropdown ───────────────────────────────────────────────────
function toggleToolsDropdown() {
    const trigger = document.getElementById('tools-trigger');
    const panel   = document.getElementById('tools-panel');
    panelInjectStars('tools-panel', 'cockpit_tools_favs');
    panelEnsureFilter('tools-panel');
    const isOpen  = panel.classList.contains('open');
    if (isOpen) {
        panel.classList.remove('open'); trigger.classList.remove('open');
        panel.style.position = ''; panel.style.top = ''; panel.style.left = ''; panel.style.minWidth = '';
    } else {
        const rect = trigger.getBoundingClientRect();
        panel.style.position = 'fixed';
        panel.style.top = (rect.bottom + 4) + 'px';
        panel.style.left = rect.left + 'px';
        panel.style.minWidth = Math.max(320, rect.width) + 'px';
        _panelCapToFooter(panel, rect.bottom + 4);
        panel.classList.add('open'); trigger.classList.add('open'); _panelRevealSelected(panel);
    }
}
function selectToolsPreset(el) {
    if (el.classList.contains('disabled')) return;
    document.getElementById('tools-preset').value = el.dataset.value;
    document.getElementById('tools-selected-label').textContent = el.querySelector('.cs-option-name') && _optName(el.querySelector('.cs-option-name'));
    document.querySelectorAll('#tools-panel .cs-option').forEach(o => o.classList.remove('selected'));
    el.classList.add('selected');
    localStorage.setItem('cockpit_last_tools_preset', el.dataset.value);
    document.getElementById('tools-panel').classList.remove('open');
    document.getElementById('tools-trigger').classList.remove('open');
    if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
}
// A two-state sort chip (A→Z / Added order) for a section header: a button, because a native <select>'s popup opened behind the panel in the app's own window.
function csCycleSort(btn, fn) {
    // modes come from data-modes ("value:Label|value:Label"); the default is the two-state A→Z / Added chip
    const modes = (btn.dataset.modes || 'alpha:A→Z|added:Added').split('|').map(x => x.split(':'));
    const i = Math.max(0, modes.findIndex(m => m[0] === btn.value)), nx = modes[(i + 1) % modes.length];
    btn.value = nx[0]; btn.textContent = nx[1]; btn.title = 'Sorted ' + nx[1] + '; click to change the order'; fn(btn);
}
function sortToolsTier(combo) {
    const header = combo.closest('.cs-group-header');
    if (!header) return;
    const mode = combo.value;
    const options = [];
    let sib = header.nextElementSibling;
    while (sib && !sib.classList.contains('cs-group-header')) {
        if (sib.classList.contains('cs-option')) options.push(sib);
        sib = sib.nextElementSibling;
    }
    if (options.length < 2) return;
    options.forEach((o, i) => { if (!o.dataset.origIdx) o.dataset.origIdx = i; });
    const getName = o => (o.querySelector('.cs-option-name')?.textContent || '').trim().toLowerCase();
    options.sort((a, b) => mode === 'alpha' ? getName(a).localeCompare(getName(b)) :
        (parseInt(a.dataset.origIdx)||0) - (parseInt(b.dataset.origIdx)||0));
    const parent = header.parentNode;
    const insertBefore = sib;
    options.forEach(o => parent.insertBefore(o, insertBefore));
}
document.addEventListener('click', e => {
    const w = document.getElementById('tools-wrapper');
    const p = document.getElementById('tools-panel');
    if (w && p && p.classList.contains('open') && !w.contains(e.target)) {
        p.classList.remove('open');
        document.getElementById('tools-trigger')?.classList.remove('open');
    }
});

// ── Workers & Tools panels: resizable + persist size ────────────────────────
['workers-panel','tools-panel'].forEach(id => {
    const SK = 'cockpit_' + id + '_size';
    const el = document.getElementById(id);
    if (!el) return;
    const saved = JSON.parse(localStorage.getItem(SK) || 'null');
    if (saved) {
        if (saved.w) el.style.width = saved.w + 'px';
        if (saved.h) el.style.maxHeight = saved.h + 'px';
    }
    new ResizeObserver(entries => {
        for (const e of entries) {
            const r = e.contentRect;
            if (r.width > 0 && r.height > 0)
                localStorage.setItem(SK, JSON.stringify({w: Math.round(r.width), h: Math.round(r.height)}));
        }
    }).observe(el);
});

// =============================================================================

// F8 opens the Ollama Model Manager (the User Guide's shortcut table and the Model Manager help topic always said so, but nothing listened for the key).
document.addEventListener('keydown', e => {
    if (e.key !== 'F8' || e.ctrlKey || e.altKey || e.metaKey || e.shiftKey || e.defaultPrevented) return;
    if (typeof showModelsModal !== 'function') return;
    e.preventDefault();
    showModelsModal();
});
