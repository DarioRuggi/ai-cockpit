// DIRECTIVES — Unified Directive Layer (global standing rules across suppliers)
// =============================================================================
const DIRECTIVES_LIMIT = 8192; // bytes; must match directives.php MAX_DIRECTIVE_BYTES

function _dirByteLen(s) {
    // Count UTF-8 bytes (Hebrew/Spanish chars are multi-byte) to match PHP strlen.
    return new Blob([s || '']).size;
}
function _dirUpdateCounts() {
    const f = document.getElementById('directives-full');
    const c = document.getElementById('directives-compact');
    const fc = document.getElementById('directives-full-count');
    const cc = document.getElementById('directives-compact-count');
    // NOTE: .count-chip is display:none by default — force it visible here.
    if (f && fc) {
        const n = _dirByteLen(f.value);
        fc.textContent = n + ' / ' + DIRECTIVES_LIMIT + ' B';
        fc.style.display = 'inline-block';
        fc.style.color = n > DIRECTIVES_LIMIT ? 'var(--accent-orange)' : 'var(--text-muted)';
    }
    if (c && cc) {
        const n = _dirByteLen(c.value);
        cc.textContent = n + ' / ' + DIRECTIVES_LIMIT + ' B';
        cc.style.display = 'inline-block';
        cc.style.color = n > DIRECTIVES_LIMIT ? 'var(--accent-orange)' : 'var(--text-muted)';
    }
}

async function directivesOpen() {
    const modal = document.getElementById('directives-modal');
    if (!modal) return;
    const status = document.getElementById('directives-status');
    if (status) { status.textContent = T('msg.loading', 'Loading…'); status.style.color = 'var(--text-muted)'; }
    modal.style.display = 'flex';
    try {
        const res = await fetch('directives.php?action=get');
        const d   = await res.json();
        if (!d.ok) throw new Error(d.error || 'load failed');
        document.getElementById('directives-full').value    = d.full || '';
        document.getElementById('directives-compact').value = d.compact || '';
        const cfg = d.config || {};
        document.getElementById('directives-enabled').checked = (cfg.enabled !== false);
        const compactSet = new Set(cfg.compact_suppliers || []);
        document.querySelectorAll('.dir-compact-cb').forEach(cb => {
            cb.checked = compactSet.has(cb.dataset.supplier);
        });
        const ov = d.overrides || {};
        ['claude','gemini','ollama','workers'].forEach(s => {
            const el = document.getElementById('dir-ov-' + s); if (el) el.value = ov[s] || '';
        });
        _dirUpdateCounts();
        if (status) status.textContent = '';
    } catch (e) {
        if (status) { status.textContent = 'Load failed: ' + e.message; status.style.color = 'var(--accent-orange)'; }
    }
}

function directivesClose() {
    const modal = document.getElementById('directives-modal');
    if (modal) modal.style.display = 'none';
}

function voiceOptsToggle(e) {
    if (e) e.stopPropagation();
    const p = document.getElementById('voice-opts');
    if (!p) return;
    p.style.display = (p.style.display === 'flex') ? 'none' : 'flex';
}
document.addEventListener('click', e => {
    const p = document.getElementById('voice-opts');
    if (p && p.style.display === 'flex' && !e.target.closest('#voice-opts') && !e.target.closest('#mic-btn') && e.target.textContent !== '▾')
        p.style.display = 'none';
});

function typographyOpen() {
    const m = document.getElementById('typography-modal');
    if (m) m.style.display = 'flex';
}
function typographyClose() {
    const m = document.getElementById('typography-modal');
    if (m) m.style.display = 'none';
}
document.addEventListener('click', e => { if (e.target?.id === 'typography-modal') typographyClose(); });

async function directivesSave() {
    const status  = document.getElementById('directives-status');
    const full    = document.getElementById('directives-full').value;
    const compact = document.getElementById('directives-compact').value;
    if (_dirByteLen(full) > DIRECTIVES_LIMIT || _dirByteLen(compact) > DIRECTIVES_LIMIT) {
        if (status) { status.textContent = 'Too long — max ' + DIRECTIVES_LIMIT + ' bytes per block.';
                      status.style.color = 'var(--accent-orange)'; }
        return;
    }
    const compact_suppliers = Array.from(document.querySelectorAll('.dir-compact-cb'))
        .filter(cb => cb.checked).map(cb => cb.dataset.supplier);
    const config = {
        enabled: document.getElementById('directives-enabled').checked,
        compact_suppliers,
    };
    const overrides = {};
    for (const s of ['claude','gemini','ollama','workers']) {
        const el = document.getElementById('dir-ov-' + s);
        const v = el ? el.value : '';
        if (_dirByteLen(v) > DIRECTIVES_LIMIT) {
            if (status) { status.textContent = s + ' override too long — max ' + DIRECTIVES_LIMIT + ' bytes.'; status.style.color = 'var(--accent-orange)'; }
            return;
        }
        overrides[s] = v;   // empty string → backend removes the override file
    }
    if (status) { status.textContent = T('msg.saving', 'Saving…'); status.style.color = 'var(--text-muted)'; }
    try {
        const res = await fetch('directives.php', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({action: 'save', full, compact, config, overrides}),
        });
        const d = await res.json();
        if (!d.ok) throw new Error(d.error || 'save failed');
        _directivesCache = null; // invalidate client cache so Workers pick up the new text
        if (status) { status.textContent = T('msg.saved.applies.to.the.next.turn.for.every.sup', 'Saved — applies to the next turn for every supplier.');
                      status.style.color = 'var(--accent-cyan)'; }
        setTimeout(directivesClose, 900);
    } catch (e) {
        if (status) { status.textContent = 'Save failed: ' + e.message; status.style.color = 'var(--accent-orange)'; }
    }
}

// ── Client-side directive access (for the Workers path) ─────────────────────
// Claude/Gemini/Ollama get directives injected server-side by agent_loop.sh.
// Workers answering directly (sendToWorker) bypass agent_loop, so we prepend the
// directive block here — but ONLY for text tasks (image/audio generators must
// not receive a directive preamble). Cached ~30s to avoid refetching per call.
let _directivesCache = null;
let _directivesCacheTime = 0;
async function _getDirectives() {
    const now = Date.now();
    if (_directivesCache && (now - _directivesCacheTime) < 30000) return _directivesCache;
    try {
        const r = await fetch('directives.php?action=get');
        const d = await r.json();
        if (d && d.ok) { _directivesCache = d; _directivesCacheTime = now; }
    } catch (e) {}
    return _directivesCache;
}
async function _directivePreamble(supplier) {
    const d = await _getDirectives();
    if (!d || !d.config || d.config.enabled === false) return '';
    const useCompact = (d.config.compact_suppliers || []).includes(supplier);
    const override = (d.overrides || {})[supplier];
    const block = (override && override.trim()) ? override
                : (useCompact && d.compact && d.compact.trim()) ? d.compact : d.full;
    if (!block || !block.trim()) return '';
    return '[Global directives — always apply]\n' + block.trim() + '\n[End global directives]\n\n';
}

// Live byte counters + close-on-backdrop
document.addEventListener('input', e => {
    if (e.target && (e.target.id === 'directives-full' || e.target.id === 'directives-compact')) {
        _dirUpdateCounts();
    }
});
document.addEventListener('click', e => {
    if (e.target && e.target.id === 'directives-modal') directivesClose();
});

async function toolsOpenSettings() {
    const modal = document.getElementById('tools-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    await toolsRefreshSettings();
}
function toolsCloseSettings() {
    const modal = document.getElementById('tools-modal');
    if (modal) modal.style.display = 'none';
    toolsLoadPresets();
}
document.addEventListener('click', (e) => {
    if (e.target?.id === 'tools-modal') toolsCloseSettings();
    if (e.target?.id === 'tools-input-overlay') toolsHideInputModal();
});

async function toolsRefreshSettings() {
    const list = document.getElementById('tools-list');
    if (!list) return;
    try {
        const r = await fetch('tools.php?action=tools');
        const d = await r.json();
        if (!d.ok) {
            list.innerHTML = '<div style="color:var(--text-muted);padding:16px;text-align:center;">' +
                'Error: ' + (d.error || 'failed to load') + '</div>';
            return;
        }
        list.innerHTML = (d.tools || []).map(t => toolsRenderTool(t)).join('');
        _applyToolsSort();   // re-apply the chosen tool sort after re-render
    } catch(e) {
        list.innerHTML = '<div style="color:var(--text-muted);padding:16px;text-align:center;">' +
            'Error: ' + e.message + '</div>';
    }
}

// Tool-list sort (Tools card). Reorders the .tool-item blocks in #tools-list.
// Mode persists so a settings refresh (full re-render) keeps it.
let _toolsSortMode = 'default';
function sortToolsList(sel) { if (sel) _toolsSortMode = sel.value; _applyToolsSort(); }
function _applyToolsSort() {
    const list = document.getElementById('tools-list');
    if (!list) return;
    const items = [...list.querySelectorAll(':scope > .tool-item')];
    if (items.length < 2) return;
    items.forEach((el, i) => { if (el.dataset.oi === undefined) el.dataset.oi = i; });
    const name = el => el.dataset.name || '';
    const num  = (el, k) => +(el.dataset[k] || 0);
    const mode = _toolsSortMode;
    const cmp = mode === 'alpha'   ? (a, b) => name(a).localeCompare(name(b))
              : mode === 'enabled' ? (a, b) => num(b, 'enabled') - num(a, 'enabled') || name(a).localeCompare(name(b))
              : mode === 'avail'   ? (a, b) => num(b, 'avail') - num(a, 'avail')     || name(a).localeCompare(name(b))
              : (a, b) => num(a, 'oi') - num(b, 'oi');
    items.sort(cmp);
    items.forEach(el => list.appendChild(el));
}
function toolsRenderTool(t) {
    // Phase 2b 2026-05-09 — per-preset chips with × for user_added presets.
    const presets = (t.presets || []).map(p => {
        const removable = !!p.user_added;
        const chipColor = `cap-${p.output_kind || 'text'}`;
        return `<span class="cap-agent-badge ${chipColor}" title="${escapeHtml(p.command || '')}"
                      style="display:inline-flex;align-items:center;gap:4px;padding:2px 5px;">
            ${escapeHtml(p.label || p.id)}${p.output_ext ? ' → .' + p.output_ext : ''}
            ${removable ? `<button onclick="toolsRemovePreset('${t.id}','${escapeHtml(p.id)}')"
                                  title="Remove this user-added preset"
                                  style="background:none;border:none;color:inherit;cursor:pointer;
                                         padding:0 2px;font-size:13px;line-height:1;opacity:0.6;"
                                  onmouseover="this.style.opacity=1;this.style.color='var(--ollama)';"
                                  onmouseout="this.style.opacity=0.6;this.style.color='inherit';">×</button>` : ''}
         </span>`;
    }).join(' ');

    const binState = t.binary_available
        ? `<span style="color:var(--accent-green);"><span class="material-symbols-rounded ico">check</span> found at <code style="font-family:var(--font-mono);font-size:9.5px;">${escapeHtml(t.binary_resolved||'')}</code></span>`
        : `<span style="color:var(--claude);"><span class="material-symbols-rounded ico">close</span> not found</span>`;

    const enabledToggle = t.enabled
        ? `<button class="plan-tb-btn" onclick="toolsToggleEnabled('${t.id}', false)" style="background:rgba(125,196,163,0.2);">
              <span class="material-symbols-rounded">toggle_on</span> Enabled
           </button>`
        : `<button class="plan-tb-btn" onclick="toolsToggleEnabled('${t.id}', true)">
              <span class="material-symbols-rounded">toggle_off</span> Disabled
           </button>`;

    const customBadge = t.custom ?
        '<span class="cap-builtin-badge" style="background:rgba(125,196,163,0.15);color:var(--tools);">user</span>' : '';
    const deleteBtn = t.custom ?
        `<button class="plan-tb-btn" onclick="toolsDelete('${t.id}')" title="Delete this user tool"
                style="background:rgba(212,73,73,0.1);">
            <span class="material-symbols-rounded">delete</span> Delete
        </button>` : '';

    // Phase 2b 2026-05-09: Test button — runs `<bin> --version` and reports
    const testBtn = t.binary_available
        ? `<button class="plan-tb-btn" onclick="toolsTestBinary('${t.id}')"
                  title="Run '${escapeHtml(t.binary_resolved||'')} --version' to verify">
              <span class="material-symbols-rounded">science</span> Test
           </button>`
        : `<button class="plan-tb-btn" disabled
                  title="Binary not detected — set binary path or click Detect"
                  style="opacity:0.45;cursor:not-allowed;">
              <span class="material-symbols-rounded">science</span> Test
           </button>`;

    return `
    <div class="tool-item" data-name="${escapeHtml((t.name||'').toLowerCase())}" data-enabled="${t.enabled ? 1 : 0}" data-avail="${t.binary_available ? 1 : 0}" style="border:1px solid var(--border-dim);border-radius:4px;padding:10px;background:var(--bg-darker);">
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">
            <h3 style="margin:0;font-size:12px;color:var(--text-primary);flex:1;">
                ${escapeHtml(t.name)} ${customBadge}
            </h3>
            ${enabledToggle}
            ${testBtn}
            ${deleteBtn}
        </div>
        <div style="font-size:10px;color:var(--text-dim);margin-bottom:6px;">
            ${escapeHtml(t.description || '')}
            ${t.website ? ` <a href="${t.website}" target="_blank" style="color:var(--gemini);">website</a>` : ''}
        </div>
        <div style="font-size:9.5px;margin-bottom:6px;">${binState}</div>

        <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
            <span style="font-size:10px;color:var(--text-muted);">Override binary path:</span>
            <input type="text" id="bin-input-${t.id}" value="${escapeHtml(t.binary_override || '')}"
                   placeholder="e.g. /opt/local/bin/${escapeHtml(t.binary || t.id)}"
                   style="flex:1;min-width:240px;background:var(--bg-base);border:1px solid var(--border-dim);
                          color:var(--text-base);font-size:11px;padding:4px 8px;border-radius:3px;
                          font-family:var(--font-mono);">
            <button class="plan-tb-btn" onclick="toolsSetBinary('${t.id}')">
                <span class="material-symbols-rounded">save</span>
            </button>
        </div>

        <div style="display:flex;gap:6px;align-items:center;flex-wrap:wrap;margin-bottom:8px;">
            <span style="font-size:10px;color:var(--text-muted);">Override output dir:</span>
            <input type="text" id="outdir-input-${t.id}" value="${escapeHtml(t.output_dir || '')}"
                   placeholder="(default: project dir, or ~/scripts/cockpit_data/tools_outputs/)"
                   style="flex:1;min-width:240px;background:var(--bg-base);border:1px solid var(--border-dim);
                          color:var(--text-base);font-size:11px;padding:4px 8px;border-radius:3px;
                          font-family:var(--font-mono);">
            <button class="plan-tb-btn" onclick="toolsSetOutputDir('${t.id}')">
                <span class="material-symbols-rounded">save</span>
            </button>
        </div>

        <div style="font-size:9.5px;color:var(--text-dim);border-top:1px solid var(--border-dim);
                    padding-top:6px;margin-top:6px;">
            <b>Presets (${(t.presets || []).length}):</b><br>
            <div style="margin-top:4px;display:flex;flex-wrap:wrap;gap:4px;align-items:center;">
                ${presets}
                <button class="plan-tb-btn" onclick="toolsOpenAddPresetDialog('${t.id}')"
                        title="Add a preset to ${escapeHtml(t.name)}"
                        style="font-size:10px;padding:3px 8px;">
                    <span class="material-symbols-rounded" style="font-size:13px;">add</span> Add preset
                </button>
            </div>
        </div>
    </div>`;
}

// =============================================================================
