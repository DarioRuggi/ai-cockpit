// =============================================================================
// THEME EDITOR
// =============================================================================
// Color groups rendered in the editor and their swatch labels.
const _THEME_EDITOR_GROUPS = [
    {
        key: 'background', title: 'Background',
        fields: [
            ['base',      'Page base'],
            ['panel',     'Panel / topbar'],
            ['sidebar',   'Sidebar'],
            ['console',   'Chat console'],
            ['hover',     'Hover'],
            ['active',    'Active'],
            ['darker',    'Darker (inputs)'],
            ['codeblock', 'Code block'],
        ],
    },
    {
        key: 'agents', title: 'Agents',
        fields: [
            ['claude',     'Claude'],
            ['claudeDim',  '  Claude dim'],
            ['gemini',     'Gemini'],
            ['geminiDim',  '  Gemini dim'],
            ['ollama',     'Ollama'],
            ['ollamaDim',  '  Ollama dim'],
            ['localai',    'LocalAI'],
            ['localaiDim', '  LocalAI dim'],
            ['workers',    'Workers'],
            ['workersDim', '  Workers dim'],
            ['tools',      'Tools'],
            ['toolsDim',   '  Tools dim'],
        ],
    },
    {
        key: 'accents', title: 'Accents',
        fields: [
            ['amber', 'Amber (warn)'],
            ['blue',  'Blue (info)'],
            ['green', 'Green (ok)'],
            ['warm', 'User input'],
        ],
    },
    {
        key: 'text', title: 'Text',
        fields: [
            ['primary', 'Primary'],
            ['base',    'Body'],
            ['dim',     'Dim'],
            ['muted',   'Muted'],
        ],
    },
    {
        key: 'border', title: 'Border',
        fields: [
            ['dim',    'Dim'],
            ['mid',    'Standard'],
            ['bright', 'Bright / active'],
        ],
    },
];

async function themeEditorOpen() {
    const modal = document.getElementById('theme-editor-modal');
    if (!modal) return;
    modal.style.display = 'flex';
    await themeEditorRefreshPicker();
    const active = window._themeState.active || localStorage.getItem('cockpit_theme_active') || 'cockpit_original_dark';
    const picker = document.getElementById('theme-picker');
    if (picker) {
        picker.value = active;
        if (!picker.value) picker.selectedIndex = 0;
    }
    _themeEditorUpdateTitle(active);
    await themeEditorSelectTheme(picker?.value || active);
}

function _themeEditorUpdateTitle(id) {
    const el = document.getElementById('theme-editor-current-name');
    if (!el) return;
    const idx = window._themeState.themesIndex[id];
    el.textContent = idx ? ': Current Theme = ' + idx.name : '';
}

function themeEditorClose() {
    const modal = document.getElementById('theme-editor-modal');
    if (modal) modal.style.display = 'none';
    window._themeState.editing = null;
    window._themeState.editingDraft = null;
}

async function themeEditorRefreshPicker() {
    try {
        const r = await fetch('themes.php?action=list');
        const d = await r.json();
        if (!d.ok) return;
        window._themeState.themesIndex = {};
        const sel = document.getElementById('theme-picker');
        if (!sel) return;
        sel.innerHTML = '';
        // Group: dark first, then light, then mixed
        const darks  = d.themes.filter(t => t.mode === 'dark');
        const lights = d.themes.filter(t => t.mode === 'light');
        const mixed  = d.themes.filter(t => t.mode === 'mixed');
        const buildOptGroup = (label, list) => {
            const og = document.createElement('optgroup');
            og.label = label;
            for (const t of list) {
                window._themeState.themesIndex[t.id] = t;
                const opt = document.createElement('option');
                opt.value = t.id;
                opt.textContent = t.name + (t.builtin ? ' (built-in)' : '');
                // read by the custom drop-down list (js/core/dropdown.js): swatch colours and a tag in words
                if (Array.isArray(t.swatch) && t.swatch.length) opt.dataset.ddSwatch = t.swatch.join(',');
                opt.dataset.ddMeta = t.mode === 'mixed' ? 'Mixed' : (t.mode === 'light' ? 'Light' : 'Dark');
                og.appendChild(opt);
            }
            return og;
        };
        if (darks.length)  sel.appendChild(buildOptGroup('● Dark themes',  darks));
        if (lights.length) sel.appendChild(buildOptGroup('○ Light themes', lights));
        if (mixed.length)  sel.appendChild(buildOptGroup('◑ Mixed themes', mixed));
    } catch(e) {
        console.warn('themeEditorRefreshPicker failed:', e);
    }
}

async function themeEditorSelectTheme(id) {
    if (!id) return;
    try {
        const r = await fetch('themes.php?action=get&id=' + encodeURIComponent(id));
        const d = await r.json();
        if (!d.ok) return;
        window._themeState.editing = id;
        // Deep-clone colors so edits don't mutate the cached theme
        window._themeState.editingDraft = JSON.parse(JSON.stringify(d.theme.colors));

        // Mode tag
        const modeTag = document.getElementById('theme-picker-mode-tag');
        if (modeTag) modeTag.textContent = (d.theme.mode || 'dark').toUpperCase();
        // Builtin tag + Save/Delete button visibility
        const isBuiltin = !!d.theme.builtin;
        const tag = document.getElementById('theme-picker-builtin-tag');
        if (tag) tag.style.display = isBuiltin ? '' : 'none';
        const saveBtn = document.getElementById('theme-editor-save-btn');
        if (saveBtn) saveBtn.style.display = isBuiltin ? 'none' : '';
        const delBtn  = document.getElementById('theme-editor-delete-btn');
        if (delBtn)  delBtn.style.display  = isBuiltin ? 'none' : '';

        themeEditorRenderGroups();
        themeEditorUpdatePreview();
    } catch(e) {
        console.warn('themeEditorSelectTheme failed:', e);
    }
}

function themeEditorRenderGroups() {
    const root = document.getElementById('theme-editor-groups');
    if (!root || !window._themeState.editingDraft) return;
    const draft = window._themeState.editingDraft;

    let html = '';
    for (const g of _THEME_EDITOR_GROUPS) {
        const grp = draft[g.key] || {};
        html += `<div style="background:var(--bg-panel);border:1px solid var(--border-dim);border-radius:4px;padding:9px 11px;">
            <div style="font-size:10px;font-weight:700;letter-spacing:0.06em;color:var(--text-dim);
                 text-transform:uppercase;margin-bottom:6px;">${escapeHtml(g.title)}</div>`;
        for (const [field, label] of g.fields) {
            const val = grp[field] || '#000000';
            html += `<div style="display:flex;align-items:center;gap:8px;margin-bottom:3px;">
                <input type="color" value="${escapeHtml(val)}"
                    oninput="themeEditorOnColorChange('${g.key}', '${field}', this.value)"
                    style="width:28px;height:22px;border:1px solid var(--border-mid);
                           border-radius:3px;padding:0;cursor:pointer;background:transparent;">
                <input type="text" value="${escapeHtml(val)}"
                    oninput="themeEditorOnHexInput('${g.key}', '${field}', this.value, this)"
                    style="width:78px;font-family:var(--font-mono);font-size:10.5px;
                           background:var(--bg-darker);border:1px solid var(--border-dim);
                           color:var(--text-base);padding:2px 5px;border-radius:2px;">
                <span style="font-size:10.5px;color:var(--text-base);flex:1;">${escapeHtml(label)}</span>
            </div>`;
        }
        html += `</div>`;
    }
    root.innerHTML = html;
}

function themeEditorOnColorChange(group, field, val) {
    if (!window._themeState.editingDraft) return;
    if (!window._themeState.editingDraft[group]) window._themeState.editingDraft[group] = {};
    window._themeState.editingDraft[group][field] = val;
    themeEditorUpdatePreview();
    // Sync the text input next to the color picker
    themeEditorRenderGroups();
}

function themeEditorOnHexInput(group, field, val, el) {
    // Validate; only commit if it looks like a hex color
    const ok = /^#?[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$/.test(val.trim());
    if (!ok) {
        el.style.outline = '1px solid var(--ollama)';
        return;
    }
    el.style.outline = '';
    const norm = val.trim().startsWith('#') ? val.trim() : '#' + val.trim();
    if (!window._themeState.editingDraft[group]) window._themeState.editingDraft[group] = {};
    window._themeState.editingDraft[group][field] = norm;
    themeEditorUpdatePreview();
}

// Update only the preview strip — does NOT touch the rest of the cockpit.
// Apply button commits; this just shows the user what their edits look like.
function themeEditorUpdatePreview() {
    const d = window._themeState.editingDraft;
    if (!d) return;
    const preview = document.getElementById('theme-preview-strip');
    if (!preview) return;

    const bg = d.background || {};
    const tx = d.text || {};
    const bo = d.border || {};
    const ag = d.agents || {};
    const ac = d.accents || {};

    // Apply colors as inline styles to the preview strip elements
    preview.style.background = bg.base || '#000';
    preview.style.borderColor = bo.mid || '#333';

    const tpsTopbar = document.getElementById('tps-topbar');
    if (tpsTopbar) {
        tpsTopbar.style.background    = bg.panel || '';
        tpsTopbar.style.borderBottomColor = bo.dim || '';
    }

    const tpsBrand = document.getElementById('tps-brand');
    // a Mixed theme's top bar and status bar are DARK: their text is the theme's textChrome set (the text group is the dark one for the light content)
    const _tpsMixed = ((window._themeState.themesIndex || {})[window._themeState.editing] || {}).mode === 'mixed';
    const _tpsChrome = d.textChrome || { primary: '#e8eaf0', muted: '#8b8f9e' };
    if (tpsBrand) tpsBrand.style.color = (_tpsMixed ? _tpsChrome.primary : tx.primary) || '';

    // Color the agent cards in the faux topbar
    const cardEntries = [
        ['tps-card-claude',  ag.claude],
        ['tps-card-gemini',  ag.gemini],
        ['tps-card-ollama',  ag.ollama],
        ['tps-card-workers', ag.workers],
        ['tps-card-tools',   ag.tools],
    ];
    for (const [eid, color] of cardEntries) {
        const el = document.getElementById(eid);
        if (el) {
            el.style.color = color || '';
            el.style.borderColor = color || '';
            el.style.background  = bg.panel || '';
        }
    }

    // Chat
    const tpsChat = document.getElementById('tps-chat');
    if (tpsChat) {
        tpsChat.style.background = bg.console || '';
        tpsChat.style.color      = tx.base || '';
    }
    const tpsDario = document.getElementById('tps-dario');
    // the agent / warm colours are tuned for the dark cards: on the preview's own chat background they are darkened until they read
    const _tpsInk = function (fg, bgc) {
        const h = function (x) { x = String(x || '').replace('#', ''); if (x.length === 3) x = x.replace(/./g, '$&$&'); return [0, 2, 4].map(function (i) { return parseInt(x.substr(i, 2), 16) || 0; }); };
        const L = function (c) { return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]); };
        const lin = function (v) { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        if (!fg || !bgc) return fg || '';
        let c = h(fg); const b = h(bgc), lb = L(b);
        for (let k = 0; k < 20; k++) { const lc = L(c), r = (Math.max(lc, lb) + 0.05) / (Math.min(lc, lb) + 0.05); if (r >= 4.5) break; c = c.map(function (v) { return lb > 0.4 ? v * 0.85 : Math.min(255, v + (255 - v) * 0.15); }); }
        return '#' + c.map(function (v) { return Math.round(v).toString(16).padStart(2, '0'); }).join('');
    };
    if (tpsDario) tpsDario.style.color = _tpsInk(ac.warm, bg.console) || '';
    const tpsClaude = document.getElementById('tps-claude-msg');
    if (tpsClaude) tpsClaude.style.color = _tpsInk(ag.claude, bg.console) || '';
    const tpsSystem = document.getElementById('tps-system');
    if (tpsSystem) tpsSystem.style.color = tx.dim || '';
    const tpsTextBase = document.getElementById('tps-text-base');
    if (tpsTextBase) tpsTextBase.style.color = tx.base || '';
    const tpsTextDim = document.getElementById('tps-text-dim');
    if (tpsTextDim) tpsTextDim.style.color = tx.dim || '';
    const tpsCode = document.getElementById('tps-code');
    if (tpsCode) {
        tpsCode.style.background    = bg.codeblock || bg.darker || '';
        tpsCode.style.color         = tx.base || '';
        tpsCode.style.borderColor   = bo.dim || '';
    }

    // Statusbar
    const tpsSb = document.getElementById('tps-statusbar');
    if (tpsSb) {
        tpsSb.style.background    = bg.panel || '';
        tpsSb.style.color         = tx.dim  || '';
        tpsSb.style.borderTopColor = bo.dim || '';
    }
    const dotMap = [
        ['tps-dot-claude', ag.claude],
        ['tps-dot-gemini', ag.gemini],
        ['tps-dot-ollama', ag.ollama],
    ];
    for (const [eid, color] of dotMap) {
        const el = document.getElementById(eid);
        if (el) el.style.background = color || '';
    }
    const tpsInfo = document.getElementById('tps-info');
    if (tpsInfo) tpsInfo.style.color = _tpsInk((_tpsMixed ? _tpsChrome.muted : tx.muted), bg.panel) || '';
    if (tpsBrand) tpsBrand.style.color = _tpsInk((_tpsMixed ? _tpsChrome.primary : tx.primary), bg.panel) || '';
}

// "Apply" — commit the editing draft to document.documentElement and
// also save it server-side as the active theme.
async function themeEditorApply() {
    const d = window._themeState.editingDraft;
    const id = window._themeState.editing;
    if (!d || !id) return;
    const idx = window._themeState.themesIndex[id] || {};
    applyTheme({
        id:      id,
        name:    idx.name || id,
        mode:    idx.mode || 'dark',
        builtin: !!idx.builtin,
        colors:  d,
    });
    // Persist as active
    try {
        await fetch('themes.php?action=set_active', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({id: id})
        });
    } catch(e) {}
    _themeEditorUpdateTitle(id);
    appendSystem(T('msg.theme.applied.name', 'Theme applied: {name}', {name: (idx.name || id)}));
}

// Readability report (js/features/theme-guard.js): a saved theme is stored as the user made it, and every apply passes it through
// the guard, which lifts text/accent colours that cannot be read on the surfaces they sit on. This tells the author which ones.
function themeEditorGuardNote(colors, mode, name) {
    try {
        if (!window.themeGuard) return;
        const g = window.themeGuard.themeGuardVars({ mode: mode || 'dark', colors: colors }, false);
        if (!g.problems.length) return;
        const list = g.problems.slice(0, 4).map(p => p.pair + ' ' + p.ratio + ':1 (needs ' + p.min + ')').join('; ');
        appendSystem(T('msg.theme.readability', 'Readability: {n} colour(s) of "{name}" are too faint for the surface they sit on and are brightened or darkened when the theme is applied: {list}{more}',
            { n: g.problems.length, name: name, list: list, more: g.problems.length > 4 ? ' …' : '' }));
    } catch (e) { /* the report is advice; saving never depends on it */ }
}

// "Save As" — store editing draft as a NEW user theme (always allowed).
async function themeEditorSaveAs() {
    const d = window._themeState.editingDraft;
    if (!d) return;
    const editingId = window._themeState.editing || '';
    const idx = window._themeState.themesIndex[editingId] || {};
    const defaultName = (idx.name || 'Custom Theme') + ' (edited)';
    const name = await cprompt('New theme name:', defaultName);
    if (!name) return;
    // Generate id from name
    const id = 'user_' + name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
    if (!id) { appendSystem(T('msg.invalid.name.try.something.with.letters.or.n', 'Invalid name — try something with letters or numbers.')); return; }
    const mode = idx.mode || 'dark';
    try {
        const r = await fetch('themes.php?action=save', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({id, name, mode, colors: d})
        });
        const data = await r.json();
        if (!data.ok) { appendSystem(T('msg.save.failed.error', 'Save failed: {error}', {error: data.error})); return; }
        await themeEditorRefreshPicker();
        document.getElementById('theme-picker').value = id;
        await themeEditorSelectTheme(id);
        appendSystem(T('msg.theme.saved.name', 'Theme saved: {name}', {name: name}));
        themeEditorGuardNote(d, mode, name);
    } catch(e) { appendSystem(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message})); }
}

// "Save" — overwrite an existing user theme in place.
async function themeEditorSave() {
    const d  = window._themeState.editingDraft;
    const id = window._themeState.editing;
    if (!d || !id) return;
    const idx = window._themeState.themesIndex[id] || {};
    if (idx.builtin) { themeEditorSaveAs(); return; }
    try {
        const r = await fetch('themes.php?action=save', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({id, name: idx.name, mode: idx.mode || 'dark', colors: d})
        });
        const data = await r.json();
        if (!data.ok) { appendSystem(T('msg.save.failed.error', 'Save failed: {error}', {error: data.error})); return; }
        appendSystem(T('msg.theme.saved.name', 'Theme saved: {name}', {name: idx.name}));
        themeEditorGuardNote(d, idx.mode || 'dark', idx.name);
    } catch(e) { appendSystem(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message})); }
}

// "Delete" — remove a user theme. Builtins are protected server-side.
async function themeEditorDelete() {
    const id = window._themeState.editing;
    if (!id) return;
    const idx = window._themeState.themesIndex[id] || {};
    if (idx.builtin) { appendSystem(T('msg.cannot.delete.a.built.in.theme', 'Cannot delete a built-in theme.')); return; }
    if (!await cockpitConfirm('Delete theme?', 'Delete theme "' + idx.name + '"? This cannot be undone.', 'Delete', {danger:true, icon:'delete'})) return;
    try {
        const r = await fetch('themes.php?action=delete&id=' + encodeURIComponent(id), { method: 'POST' });
        const data = await r.json();
        if (!data.ok) { appendSystem(T('msg.delete.failed.error', 'Delete failed: {error}', {error: data.error})); return; }
        await themeEditorRefreshPicker();
        // Pick the first option
        const sel = document.getElementById('theme-picker');
        if (sel.options.length > 0) {
            const firstId = sel.querySelector('option').value;
            sel.value = firstId;
            await themeEditorSelectTheme(firstId);
            // the header names the theme that is now in use (it kept the deleted one's name)
            if (window._themeState.active === id || !window._themeState.themesIndex[window._themeState.active]) { window._themeState.active = firstId; try { localStorage.setItem('cockpit_theme_active', firstId); } catch (e) {} }
            _themeEditorUpdateTitle(window._themeState.active);
        }
        appendSystem(T('msg.theme.deleted', 'Theme deleted.'));
    } catch(e) { appendSystem(T('msg.delete.failed.message', 'Delete failed: {message}', {message: e.message})); }
}

// ── New Theme ───────────────────────────────────────────────────────────────
function themeEditorNew() {
    const dlg = document.getElementById('theme-new-dialog');
    if (!dlg) return;
    dlg.style.display = 'block';
    const inp = document.getElementById('theme-new-name');
    if (inp) { inp.value = ''; inp.focus(); }
}

async function themeEditorNewCreate() {
    const name = (document.getElementById('theme-new-name')?.value || '').trim();
    if (!name) { document.getElementById('theme-new-name')?.focus(); return; }
    const mode = document.getElementById('theme-new-mode')?.value || 'dark';
    const id = 'user_' + name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
    if (!id || id === 'user_') { appendSystem(T('msg.invalid.name', 'Invalid name.')); return; }
    const baseColors = window._themeState.editingDraft || {};
    try {
        const r = await fetch('themes.php?action=save', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({id, name, mode, colors: baseColors})
        });
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.create.failed.error', 'Create failed: {error}', {error: d.error})); return; }
        document.getElementById('theme-new-dialog').style.display = 'none';
        await themeEditorRefreshPicker();
        document.getElementById('theme-picker').value = id;
        await themeEditorSelectTheme(id);
        appendSystem(T('msg.theme.created.name', 'Theme created: {name}', {name: name}));
    } catch(e) { appendSystem(T('msg.create.failed.message', 'Create failed: {message}', {message: e.message})); }
}

async function themeEditorNewAutoGen() {
    const name = (document.getElementById('theme-new-name')?.value || '').trim() || 'Auto ' + Date.now().toString(36);
    const mode = document.getElementById('theme-new-mode')?.value || 'dark';
    const id = 'user_' + name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
    if (!id || id === 'user_') { appendSystem(T('msg.invalid.name', 'Invalid name.')); return; }

    // The palette comes from js/features/theme-generator.js: palette type (normal, high contrast, colour-vision types) and the optional picked
    // colours. Whatever it makes goes through the readability guard once more, so the theme is saved already readable.
    const palette = document.getElementById('theme-gen-palette')?.value || 'normal';
    const pickOf = k => (document.getElementById('theme-gen-' + k + '-rand')?.checked === false) ? (document.getElementById('theme-gen-' + k)?.value || null) : null;
    let colors = window.themeGenerate({ mode: mode, palette: palette, pick: { bg: pickOf('bg'), chrome: pickOf('chrome'), accent: pickOf('accent') } });
    try { if (window.themeGuard) colors = window.themeGuard.themeGuardVars({ mode: mode, colors: colors }, true).theme.colors; } catch (e) { /* the guard also runs on every apply */ }
    try {
        const r = await fetch('themes.php?action=save', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({id, name, mode, colors})
        });
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.auto.generate.failed.error', 'Auto-generate failed: {error}', {error: d.error})); return; }
        document.getElementById('theme-new-dialog').style.display = 'none';
        await themeEditorRefreshPicker();
        document.getElementById('theme-picker').value = id;
        await themeEditorSelectTheme(id);
        themeEditorApply();
        appendSystem(T('msg.auto.generated.theme.name', 'Auto-generated theme: {name}', {name: name}));
    } catch(e) { appendSystem(T('msg.auto.generate.failed.message', 'Auto-generate failed: {message}', {message: e.message})); }
}

// ── Export all themes ───────────────────────────────────────────────────────
async function themeEditorExport() {
    try {
        const r = await fetch('themes.php?action=list');
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.export.failed', 'Export failed.')); return; }
        const all = {};
        for (const t of d.themes) {
            const tr = await fetch('themes.php?action=get&id=' + encodeURIComponent(t.id));
            const td = await tr.json();
            if (td.ok) all[t.id] = td.theme;
        }
        const blob = new Blob([JSON.stringify(all, null, 2)], {type: 'application/json'});
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url; a.download = 'cockpit_themes.json'; a.click();
        URL.revokeObjectURL(url);
        appendSystem(T('msg.exported.keys.themes', 'Exported {keys} themes.', {keys: Object.keys(all).length}));
    } catch(e) { appendSystem(T('msg.export.failed.message', 'Export failed: {message}', {message: e.message})); }
}

// ── Import themes from JSON ─────────────────────────────────────────────────
function themeEditorImportClick() {
    cockpitPickIntoInput('theme-import-file',['json'],'Import theme');
}
async function themeEditorImportFile(input) {
    const file = input.files?.[0];
    if (!file) return;
    try {
        const text = await file.text();
        const data = JSON.parse(text);
        let count = 0;
        for (const [id, theme] of Object.entries(data)) {
            if (!theme.colors || !theme.name) continue;
            if (theme.builtin) continue;
            const r = await fetch('themes.php?action=save', {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({id, name: theme.name, mode: theme.mode || 'dark', colors: theme.colors})
            });
            const d = await r.json();
            if (d.ok) count++;
        }
        await themeEditorRefreshPicker();
        const active = window._themeState.active || 'cockpit_original_dark';
        document.getElementById('theme-picker').value = active;
        appendSystem(T('msg.imported.count.user.theme.s', 'Imported {count} user theme(s).', {count: count}));
    } catch(e) { appendSystem(T('msg.import.failed.message', 'Import failed: {message}', {message: e.message})); }
    input.value = '';
}

// ── Import VS Code theme ────────────────────────────────────────────────────
function themeEditorImportVSCodeClick() {
    cockpitPickIntoInput('theme-vscode-file',['json'],'Import VS Code theme');
}

async function themeEditorImportVSCode(input) {
    const file = input.files?.[0];
    if (!file) return;
    try {
        const text = await file.text();
        const vsc = JSON.parse(text);
        const mapped = _mapVSCodeTheme(vsc, file.name);
        if (!mapped) { appendSystem(T('msg.could.not.parse.vs.code.theme.missing.colors', 'Could not parse VS Code theme — missing "colors" object.')); return; }
        const r = await fetch('themes.php?action=save', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(mapped)
        });
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.import.failed.error', 'Import failed: {error}', {error: d.error})); return; }
        await themeEditorRefreshPicker();
        document.getElementById('theme-picker').value = mapped.id;
        await themeEditorSelectTheme(mapped.id);
        themeEditorApply();
        appendSystem(T('msg.vs.code.theme.imported.name', 'VS Code theme imported: {name}', {name: mapped.name}));
    } catch(e) { appendSystem(T('msg.import.failed.message', 'Import failed: {message}', {message: e.message})); }
    input.value = '';
}

function _mapVSCodeTheme(vsc, filename) {
    const c = vsc.colors;
    if (!c) return null;
    const name = vsc.name || filename.replace(/\.json$/i, '') || 'VS Code Import';
    const id = 'user_vsc_' + name.toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 40);
    const mode = (vsc.type === 'light' || vsc.type === 'hc-light') ? 'light' : 'dark';

    const g = (k, fb) => c[k] || fb || null;
    // HSL helpers for deriving missing colors
    const hexToHsl = (hex) => {
        if (!hex) return [0,0,50];
        let h = hex.replace('#','');
        if (h.length === 3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
        // strip alpha if 8-char
        if (h.length === 8) h = h.slice(0,6);
        const r=parseInt(h.substr(0,2),16)/255, gr=parseInt(h.substr(2,2),16)/255, b=parseInt(h.substr(4,2),16)/255;
        const mx=Math.max(r,gr,b), mn=Math.min(r,gr,b), d=mx-mn;
        let hue=0, s=0, l=(mx+mn)/2;
        if(d>0){s=d/(1-Math.abs(2*l-1));hue=mx===r?((gr-b)/d+6)%6*60:mx===gr?(b-r)/d*60+120:(r-gr)/d*60+240;}
        return [Math.round(hue), Math.round(s*100), Math.round(l*100)];
    };
    const hslToHex = (h,s,l) => {
        s/=100; l/=100;
        const a=s*Math.min(l,1-l);
        const f=n=>{const k=(n+h/30)%12;return l-a*Math.max(Math.min(k-3,9-k,1),-1);};
        return '#'+[f(0),f(8),f(4)].map(x=>Math.round(Math.max(0,Math.min(255,x*255))).toString(16).padStart(2,'0')).join('');
    };
    const shiftL = (hex, delta) => {
        if (!hex) return '#888888';
        const [h,s,l] = hexToHsl(hex);
        return hslToHex(h, s, Math.max(0, Math.min(100, l + delta)));
    };
    const dimOf = (hex) => shiftL(hex, mode === 'dark' ? -20 : 20);
    const norm = (hex) => hex && hex.length > 7 ? hex.slice(0,7) : hex;

    // Extract token colors for agent-like accent colors
    const tokenFg = {};
    for (const tc of (vsc.tokenColors || [])) {
        const fg = tc.settings?.foreground;
        if (!fg) continue;
        const scopes = Array.isArray(tc.scope) ? tc.scope : (tc.scope || '').split(',').map(s=>s.trim());
        for (const sc of scopes) {
            if (!tokenFg[sc]) tokenFg[sc] = fg;
        }
    }
    const tkn = (...keys) => { for (const k of keys) if (tokenFg[k]) return norm(tokenFg[k]); return null; };

    const edBg = norm(g('editor.background', '#1e1e1e'));
    const edFg = norm(g('editor.foreground', '#d4d4d4'));

    // Agent colors from token scopes or terminal ANSI
    const claudeColor  = tkn('keyword','keyword.control','storage.type') || norm(g('terminal.ansiBlue'))    || '#7ecfff';
    const geminiColor  = tkn('string','string.quoted')                   || norm(g('terminal.ansiGreen'))   || '#98c379';
    const ollamaColor  = tkn('entity.name.function','support.function')  || norm(g('terminal.ansiYellow'))  || '#e5c07b';
    const localaiColor = tkn('entity.name.tag','markup.heading')         || norm(g('terminal.ansiBrightCyan')) || _deriveLocalAI(ollamaColor);
    const workersColor = tkn('constant.numeric','constant')              || norm(g('terminal.ansiMagenta')) || '#c678dd';
    const toolsColor   = tkn('entity.name.type','support.type')          || norm(g('terminal.ansiCyan'))    || '#56b6c2';

    const colors = {
        background: {
            base:      edBg,
            panel:     norm(g('editorGroupHeader.tabsBackground', g('titleBar.activeBackground'))) || shiftL(edBg, mode==='dark'?4:-4),
            sidebar:   norm(g('sideBar.background')) || shiftL(edBg, mode==='dark'?2:-2),
            console:   norm(g('terminal.background', g('panel.background'))) || shiftL(edBg, mode==='dark'?-2:2),
            hover:     norm(g('list.hoverBackground')) || shiftL(edBg, mode==='dark'?8:-8),
            active:    norm(g('list.activeSelectionBackground')) || shiftL(edBg, mode==='dark'?12:-12),
            darker:    norm(g('input.background')) || shiftL(edBg, mode==='dark'?-4:4),
            codeblock: norm(g('textBlockQuote.background', g('editor.background'))) || shiftL(edBg, mode==='dark'?-3:3),
        },
        text: {
            primary: norm(g('foreground', edFg)),
            base:    norm(edFg),
            dim:     norm(g('descriptionForeground')) || shiftL(edFg, mode==='dark'?-25:25),
            muted:   norm(g('disabledForeground', g('tab.inactiveForeground'))) || shiftL(edFg, mode==='dark'?-40:40),
        },
        border: {
            dim:    norm(g('editorGroup.border', g('panel.border'))) || shiftL(edBg, mode==='dark'?10:-10),
            mid:    norm(g('focusBorder', g('contrastBorder'))) || shiftL(edBg, mode==='dark'?20:-20),
            bright: norm(g('contrastActiveBorder', g('focusBorder'))) || shiftL(edBg, mode==='dark'?30:-30),
        },
        agents: {
            claude: claudeColor, claudeDim: dimOf(claudeColor),
            gemini: geminiColor, geminiDim: dimOf(geminiColor),
            ollama: ollamaColor, ollamaDim: dimOf(ollamaColor),
            localai: localaiColor, localaiDim: dimOf(localaiColor),
            workers: workersColor, workersDim: dimOf(workersColor),
            tools: toolsColor, toolsDim: dimOf(toolsColor),
        },
        accents: {
            amber: norm(g('editorWarning.foreground', g('terminal.ansiYellow'))) || '#e5c07b',
            blue:  norm(g('editorInfo.foreground', g('terminal.ansiBlue'))) || '#7ecfff',
            green: norm(g('terminal.ansiGreen', g('testing.iconPassed'))) || '#98c379',
            warm: norm(g('terminal.ansiBrightCyan', g('textLink.foreground'))) || '#e8a44a',
        },
    };
    return { id, name, mode, colors };
}

// Backdrop + Escape to close
document.addEventListener('click', (e) => {
    if (e.target?.id === 'theme-editor-modal') themeEditorClose();
});
document.addEventListener('keydown', (e) => {
    const m = document.getElementById('theme-editor-modal');
    if (!m || m.style.display === 'none') return;
    if (e.key === 'Escape') { e.preventDefault(); themeEditorClose(); }
});

// Apply the saved active theme as soon as the page is ready. Don't await —
// the rest of the cockpit init can proceed in parallel.
// The fetch gate is still closed this early (no confirmed session yet), so
// that first call is answered with a local 401 and applies nothing; the gate
// fires cockpit-auth-open once it opens and the theme is loaded for real then.
themeLoadAndApply().catch(()=>{});
document.addEventListener("cockpit-auth-open", () => { themeLoadAndApply().catch(()=>{}); });


function supActivate(agent, ev) {
    // Don't fire when click came from a form control inside the card body
    if (ev && ev.target) {
        const t = ev.target;
        if (t.closest('select, input, button, .custom-select-wrapper')) return;
    }
    if (currentAgent === agent) return;
    setAgent(agent);
}

function setAgent(agent) {
    // Bail if same agent — prevents redundant work and noisy system messages.
    // (supActivate() also checks this, but direct callers may not.)
    if (currentAgent === agent) return;

    // DEBUG: log who called us. Remove after confirming the cycling cause.
    if (typeof console !== 'undefined' && console.trace) {
        console.log('[setAgent]', currentAgent, '→', agent, 'at', new Date().toISOString());
    }

    currentAgent = agent;

    // 2026-05-09: persist the user's selection across reloads. The matching
    // load logic lives in _initialActiveAgent() at the top of this script.
    try { localStorage.setItem('cockpit_current_agent', agent); } catch(e) {}

    // Update legacy hidden agent buttons (kept for any code still keying off them)
    ['claude','gemini','ollama','workers','tools'].forEach(a => {
        const btn = document.getElementById('btn-agent-' + a);
        if (btn) btn.className = 'agent-btn' + (a === agent ? ' active-' + a : '');
    });

    // Update supplier cards — only the active one expands
    ['claude','gemini','ollama','workers','tools'].forEach(a => {
        const card = document.getElementById('sup-card-' + a);
        if (card) card.classList.toggle('sup-active', a === agent);
        // Show/hide detail rows based on active state
        if (['claude','gemini','ollama'].includes(a)) {
            if (a === agent) {
                cardUsageOnExpand(a);
            } else {
                cardUsageOnCollapse(a);
            }
        }
    });

    // Refresh all card labels — active cards show agent name, inactive show selected model
    if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();

    // Update execute button color
    if (typeof btnExecute !== 'undefined' && btnExecute) {
        btnExecute.className = 'action-btn' + (agent !== 'gemini' ? ' agent-' + agent : '');
    }

    // Update console border color
    const colors = {
        claude:  'var(--claude-dim)',
        gemini:  'var(--gemini-dim)',
        ollama:  'var(--ollama-dim)',
        workers: 'var(--workers)',
        tools:   'var(--tools)',
    };
    if (typeof consoleBox !== 'undefined' && consoleBox) {
        consoleBox.style.borderLeft = '2px solid ' + (colors[agent] || colors.gemini);
    }

    // Suppress the system message during the first 2 seconds after page load —
    // any agent-switching during init is internal setup, not user-driven.
    if (Date.now() - _pageLoadAt > 2000) {
        appendSystem(T('msg.agent.touppercase', 'Agent → {touppercase}', {touppercase: agent.toUpperCase()}));
    }

    // 1.1 fix (revised 2026-05-09): restore focus to the prompt input —
    // clicking a supplier card shouldn't strand the keyboard on the card
    // itself; the user almost certainly wants to type next.
    //
    // Deferred via setTimeout(0) to run after the layout/visibility
    // transition completes — without this, the active card's newly-visible
    // <select> model picker can grab implicit focus AFTER our synchronous
    // .focus() call, undoing it. setTimeout(0) yields to the browser to
    // finish layout, then runs our focus call as the last step.
    setTimeout(() => {
        const _promptIn = document.getElementById('prompt-in');
        if (_promptIn && document.activeElement !== _promptIn) {
            _promptIn.focus();
        }
    }, 0);
}

// =============================================================================
// focusPromptDeferred — give keyboard focus back to the prompt textarea.
//
// Used after context switches (agent, chat, project) so the user can start
// typing immediately. Deferred via setTimeout(0) for the same reason as in
// setAgent: layout/visibility transitions may finish AFTER the call and
// could otherwise steal focus (e.g. a newly-visible <select>).
// =============================================================================
function focusPromptDeferred() {
    setTimeout(() => {
        const _p = document.getElementById('prompt-in');
        if (_p && document.activeElement !== _p) _p.focus();
    }, 0);
}

// =============================================================================
// currentChatFile — returns the active chat file path

