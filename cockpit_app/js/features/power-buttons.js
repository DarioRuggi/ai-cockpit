// =============================================================================
// Power Buttons — one click runs a saved prompt on what you copied, with the supplier you chose, and puts the answer where you want it.
// The panel lists your buttons and the starters, edits a button (prompt, supplier, input, output, safety), and has a Try-it box that runs a button on text you paste.
// All the work is power.php (design: plans/PLAN_3_power_buttons.md); from outside Cockpit a launcher runs `power_run "<button>"`.
// =============================================================================
let _pw = { data: null, models: [], editing: null };

/** Put text on the clipboard: the browser's way, and if it refuses (some embedded browsers do) the old select-and-copy way. */
async function _pwCopyText(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch (e) { /* fall back */ }
    try { const ta = document.createElement('textarea'); ta.value = text; ta.style.cssText = 'position:fixed;left:-9999px;top:0;'; document.body.appendChild(ta); ta.select(); const ok = document.execCommand('copy'); ta.remove(); return !!ok; } catch (e) { return false; }
}
async function powerApi(action, body) {
    const r = body === undefined ? await fetch('power.php?action=' + action) : await fetch('power.php?action=' + action, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return r.json();
}
function _pwEsc(s) { return (typeof escapeHtml === 'function' ? escapeHtml(String(s == null ? '' : s)) : String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))); }

function powerOpen() {
    let ov = document.getElementById('power-overlay');
    if (ov) { ov.style.display = 'flex'; powerRefresh(); return; }
    ov = document.createElement('div'); ov.id = 'power-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(920px,95vw);max-height:90vh;overflow:hidden;display:flex;flex-direction:column;padding:16px;">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">touch_app</span> ' + T('ui.power.title', 'Power Buttons') + '</h2>' +
        '<button class="rp-action-btn" id="power-new" title="' + _pwEsc(T('ui.power.new.tip', 'Make a new button: a saved prompt, the supplier that answers, where the input comes from and where the answer goes.')) + '">+ ' + T('ui.power.new', 'New button') + '</button>' +
        '<span class="rp-action-btn" id="power-close" style="cursor:pointer;margin-left:6px;">×</span></div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-bottom:8px;line-height:1.5;">' + T('ui.power.intro', 'A Power Button runs a saved prompt on text you copied, with the supplier you choose (a model on this computer by default), and puts the answer back on your clipboard, in a notification or in a file. Run it here, or from outside Cockpit with the command shown under each button.') + '</div>' +
        '<div style="display:flex;gap:12px;overflow:hidden;flex:1;min-height:320px;">' +
        '<div id="power-list" style="width:260px;overflow:auto;border-right:1px solid var(--border-dim);padding-right:8px;display:flex;flex-direction:column;gap:4px;"></div>' +
        '<div id="power-editor" style="flex:1;overflow:auto;"></div></div></div>';
    document.body.appendChild(ov);
    const close = () => ov.style.display = 'none';
    document.getElementById('power-close').onclick = close; ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('power-new').onclick = () => powerEditorRender({ name: '', prompt: '', supplier: { type: 'ollama', model: '' }, input: 'clipboard', output: 'clipboard', confirm: 'first' }, true);
    powerRefresh();
}

async function powerRefresh() {
    let d, m;
    try { d = await powerApi('list'); } catch (e) { d = null; }
    try { m = await (await fetch('workers.php?action=models')).json(); } catch (e) { m = null; }
    _pw.data = d && d.ok ? d : null; _pw.models = (m && m.models) || [];
    powerStripDraw();
    const list = document.getElementById('power-list'); if (!list) return;
    if (!_pw.data) { list.innerHTML = '<div style="color:var(--text-muted);font-size:11px;">' + T('ui.power.loaderr', 'Could not load the buttons.') + '</div>'; return; }
    const row = (b, mine) => '<div style="display:flex;align-items:center;gap:6px;padding:4px 6px;border:1px solid var(--border-dim);border-radius:4px;">' +
        '<span class="material-symbols-rounded" style="font-size:16px;' + (b.colour ? 'color:' + _pwEsc(b.colour) + ';' : 'color:var(--accent-cyan);') + '">' + _pwEsc(b.icon || 'bolt') + '</span>' +
        '<span style="flex:1;font-size:11.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' + _pwEsc(b.description || b.prompt || '') + '">' + _pwEsc(b.name) + '</span>' +
        (mine ? '<button class="action-btn" style="padding:1px 7px;" title="' + _pwEsc(T('ui.power.open.tip', 'Open this button: edit it or try it on some text')) + '" onclick="powerEdit(\'' + _pwEsc(b.id) + '\')">' + T('ui.power.open', 'Open') + '</button>'
              : '<button class="action-btn" style="padding:1px 7px;" title="' + _pwEsc(T('ui.power.add.tip', 'Copy this starter into your buttons so you can use and change it')) + '" onclick="powerAddStarter(\'' + _pwEsc(b.id) + '\')">' + T('ui.power.add', 'Add') + '</button>') + '</div>';
    list.innerHTML = '<div style="font-size:11px;font-weight:600;margin:2px 0;">' + T('ui.power.mine', 'My buttons') + '</div>' +
        (_pw.data.buttons.length ? _pw.data.buttons.map(b => row(b, true)).join('') : '<div style="font-size:10.5px;color:var(--text-muted);">' + T('ui.power.none', 'None yet. Add a starter below, or make a new button.') + '</div>') +
        '<div style="font-size:11px;font-weight:600;margin:10px 0 2px;">' + T('ui.power.starters', 'Starters') + '</div>' + _pw.data.starters.map(b => row(b, false)).join('') +
        '<div style="margin-top:10px;"><button class="action-btn" style="padding:2px 10px;" onclick="powerHistoryShow()" title="' + _pwEsc(T('ui.power.history.tip', 'The last runs: which button, which supplier, how long, and whether it worked. The text itself is never kept.')) + '">' + T('ui.power.history', 'History') + '</button></div>' +
        (_pw.data.ollama.up ? '' : '<div style="font-size:10.5px;color:var(--accent-amber);margin-top:8px;">' + T('ui.power.nolocal', 'No local model server is running (Ollama). Buttons set to a local model will not work until it is; or pick a cloud supplier in the button.') + '</div>');
}

async function powerAddStarter(id) { const r = await powerApi('add_starter', { id }); if (!r.ok) { appendError(T('msg.power.add.failed', 'Could not add the starter: {error}', { error: r.error || '' })); return; } await powerRefresh(); powerEdit(r.button.id); }
function powerEdit(id) { const b = (_pw.data.buttons || []).find(x => x.id === id); if (b) powerEditorRender(b, false); }

function _pwSupplierOptions(cur) {
    const o = [];
    const sel = (t, p, m) => (cur.type === t && (t === 'ollama' ? (cur.model || '') === (m || '') : cur.provider === p && cur.model === m)) ? ' selected' : '';
    o.push('<option value="ollama:"' + sel('ollama', '', '') + '>' + T('ui.power.sup.local.auto', 'A model on this computer (automatic)') + (_pw.data.ollama.default ? ' — ' + _pwEsc(_pw.data.ollama.default) : '') + '</option>');
    for (const m of _pw.data.ollama.models) if (!/embed|nomic|bge|minilm|rerank/i.test(m.name)) o.push('<option value="ollama:' + _pwEsc(m.name) + '"' + sel('ollama', '', m.name) + '>' + T('ui.power.sup.local', 'On this computer') + ': ' + _pwEsc(m.name) + '</option>');
    for (const m of _pw.models) o.push('<option value="worker:' + _pwEsc(m.provider) + ':' + _pwEsc(m.model) + '"' + sel('worker', m.provider, m.model) + '>' + T('ui.power.sup.cloud', 'Sent to') + ': ' + _pwEsc(m.label) + '</option>');
    if (cur.type === 'worker' && !_pw.models.some(m => m.provider === cur.provider && m.model === cur.model)) o.push('<option value="worker:' + _pwEsc(cur.provider) + ':' + _pwEsc(cur.model) + '" selected>' + _pwEsc(cur.provider + ' · ' + cur.model) + ' (' + T('ui.power.sup.off', 'not enabled now') + ')</option>');
    return o.join('');
}

function powerEditorRender(b, isNew) {
    _pw.editing = b; const ed = document.getElementById('power-editor'); if (!ed) return;
    const inp = 'background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;width:100%;box-sizing:border-box;';
    const opt = (v, cur, label) => '<option value="' + v + '"' + (v === cur ? ' selected' : '') + '>' + label + '</option>';
    ed.innerHTML =
        '<div style="display:grid;grid-template-columns:90px 1fr;gap:6px;align-items:start;font-size:11px;">' +
        '<span>' + T('ui.power.f.name', 'Name') + '</span><input id="pw-name" style="' + inp + '" value="' + _pwEsc(b.name) + '" maxlength="60">' +
        '<span>' + T('ui.power.f.icon', 'Icon') + '</span><span>' + ckIconFieldHtml('pw-icon', b.icon || 'bolt') + '</span>' +
        '<span>' + T('ui.power.f.colour', 'Colour') + '</span><span>' + _pwColourHtml(b.colour || '') + '</span>' +
        '<span>' + T('ui.power.f.prompt', 'Prompt') + '</span><textarea id="pw-prompt" rows="6" style="' + inp + 'resize:vertical;" placeholder="' + _pwEsc(T('ui.power.f.prompt.ph', 'What should the AI do with the text? For example: Proofread the text, keep its language, return only the corrected text.')) + '">' + _pwEsc(b.prompt || '') + '</textarea>' +
        '<span></span><span style="font-size:10px;color:var(--text-muted);">' + T('ui.power.f.prompt.help', 'The copied text is added below your prompt automatically, with a sentence saying it is data, not instructions. {clipboard} in your prompt reads as "the text below the line". {date} is today\'s date.') + '</span>' +
        '<span>' + T('ui.power.f.supplier', 'Answered by') + '</span><select id="pw-supplier" style="' + inp + '">' + _pwSupplierOptions(b.supplier || { type: 'ollama', model: '' }) + '</select>' +
        '<span>' + T('ui.power.f.input', 'Input') + '</span><select id="pw-input" style="' + inp + '">' + opt('clipboard', b.input, T('ui.power.in.clipboard', 'What I copied (clipboard)')) + opt('selection', b.input, T('ui.power.in.selection', 'What I selected (X11 / Wayland selection)')) + opt('file', b.input, T('ui.power.in.file', 'A file I name when I run it')) + opt('image', b.input, T('ui.power.in.image', 'A picture I copied (needs a picture-capable model)')) + opt('none', b.input, T('ui.power.in.none', 'Nothing (the prompt alone)')) + '</select>' +
        '<span></span><span id="pw-imghint" style="font-size:10px;color:var(--text-muted);"></span>' +
        '<span>' + T('ui.power.f.output', 'Answer goes to') + '</span><select id="pw-output" style="' + inp + '">' + opt('clipboard', b.output, T('ui.power.out.clipboard', 'The clipboard')) + opt('notify', b.output, T('ui.power.out.notify', 'A notification')) + opt('file', b.output, T('ui.power.out.file', 'A file')) + opt('show', b.output, T('ui.power.out.show', 'This panel')) + '</select>' +
        '<span>' + T('ui.power.f.confirm', 'Ask before sending') + '</span><select id="pw-confirm" style="' + inp + '" title="' + _pwEsc(T('ui.power.f.confirm.tip', 'Only matters for a supplier outside this computer: it receives what you copied.')) + '">' + opt('first', b.confirm || 'first', T('ui.power.c.first', 'The first time, for each supplier')) + opt('always', b.confirm || 'first', T('ui.power.c.always', 'Every time')) + opt('never', b.confirm || 'first', T('ui.power.c.never', 'Never')) + '</select>' +
        '<span></span><label style="font-size:10.5px;"><input type="checkbox" id="pw-secrets"' + (b.allow_secrets ? ' checked' : '') + '> ' + T('ui.power.f.secrets', 'Allow text that looks like a password or key to be sent outside this computer') + '</label>' +
        '</div>' +
        '<div style="display:flex;gap:8px;margin-top:10px;"><button class="action-btn" id="pw-save" style="padding:4px 14px;">' + T('ui.power.save', 'Save') + '</button>' +
        (isNew ? '' : '<button class="action-btn" id="pw-delete" style="padding:4px 14px;">' + T('ui.power.delete', 'Delete') + '</button>') + '<span id="pw-msg" style="font-size:10.5px;color:var(--text-muted);align-self:center;"></span></div>' +
        (isNew ? '' : '<div style="margin-top:14px;border-top:1px solid var(--border-dim);padding-top:10px;"><div style="font-size:11px;font-weight:600;margin-bottom:4px;">' + T('ui.power.try', 'Try it') + '</div>' +
            '<textarea id="pw-try" rows="4" style="' + inp + 'resize:vertical;" placeholder="' + _pwEsc(T('ui.power.try.ph', 'Paste some text to run this button on (or leave it empty to use your clipboard)')) + '"></textarea>' +
            '<div style="display:flex;gap:8px;margin-top:6px;align-items:center;"><button class="action-btn" id="pw-run" style="padding:4px 14px;">' + T('ui.power.run', 'Run') + '</button><span id="pw-runmsg" style="font-size:10.5px;color:var(--text-muted);"></span></div>' +
            '<pre id="pw-result" style="display:none;white-space:pre-wrap;margin:8px 0 0;padding:8px;background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;font-size:11.5px;max-height:220px;overflow:auto;"></pre>' +
            '<button class="action-btn" id="pw-copy" style="display:none;margin-top:6px;padding:2px 10px;">' + T('ui.power.copy', 'Copy the answer') + '</button>' +
            '<div style="font-size:10px;color:var(--text-muted);margin-top:10px;">' + T('ui.power.cli', 'From outside Cockpit, a launcher or a script runs it with') + ' <code style="user-select:all;">php power_run "' + _pwEsc(b.name) + '"</code></div></div>');
    document.getElementById('pw-save').onclick = powerSave; _pwColourSet(b.colour || '');
    const hint = () => { const h = document.getElementById('pw-imghint'); if (!h) return; const on = document.getElementById('pw-input').value === 'image'; const v = _pw.data && _pw.data.ollama.vision;
        h.textContent = on ? (v ? T('ui.power.imghint.ok', 'A picture is read by {model} on this computer, or by Anthropic if you choose it as the supplier.', { model: v }) : T('ui.power.imghint.none', 'No picture-capable model is installed on this computer (for example llava or gemma3): pick Anthropic as the supplier, or install one with Ollama.')) : ''; };
    document.getElementById('pw-input').onchange = hint; hint();
    const del = document.getElementById('pw-delete'); if (del) del.onclick = powerDelete;
    const run = document.getElementById('pw-run'); if (run) run.onclick = powerRunUi;
}

const _PW_COLOURS = ['', '#4da3ff', '#3fb950', '#d29922', '#f0883e', '#f85149', '#bc8cff', '#ff7eb6', '#39c5bb', '#8b949e'];
function _pwColourHtml(cur) {
    const sw = _PW_COLOURS.map(c => '<button type="button" data-c="' + c + '" onclick="_pwColourSet(\'' + c + '\')" title="' + _pwEsc(c || T('ui.power.colour.none', 'Default')) + '" style="width:22px;height:22px;border-radius:50%;cursor:pointer;padding:0;border:2px solid ' + (c === cur ? 'var(--text-primary)' : 'var(--border-dim)') + ';background:' + (c || 'var(--bg-darker)') + ';">' + (c ? '' : '<span class="material-symbols-rounded" style="font-size:14px;color:var(--text-muted);">block</span>') + '</button>').join('');
    return '<input type="hidden" id="pw-colour" value="' + _pwEsc(cur) + '"><span id="pw-swatches" style="display:inline-flex;gap:5px;align-items:center;flex-wrap:wrap;">' + sw +
        '<input type="color" id="pw-colour-custom" value="' + (cur || '#4da3ff') + '" title="' + _pwEsc(T('ui.power.colour.custom', 'Any colour')) + '" style="width:26px;height:24px;padding:0;border:none;background:none;cursor:pointer;" onchange="_pwColourSet(this.value)"></span>';
}
function _pwColourSet(c) {
    const h = document.getElementById('pw-colour'); if (!h) return; h.value = c;
    document.querySelectorAll('#pw-swatches button').forEach(b => { b.style.borderColor = b.dataset.c === c ? 'var(--text-primary)' : 'var(--border-dim)'; });
    const g = document.querySelector('#pw-icon-btn span.material-symbols-rounded'); if (g) g.style.color = c || '';
}
function _pwCollect() {
    const s = document.getElementById('pw-supplier').value, p = s.split(':');
    const supplier = p[0] === 'ollama' ? { type: 'ollama', model: p.slice(1).join(':') } : { type: 'worker', provider: p[1], model: p.slice(2).join(':') };
    return { id: _pw.editing && _pw.editing.id ? _pw.editing.id : undefined, name: document.getElementById('pw-name').value.trim(), icon: (document.getElementById('pw-icon').value || '').trim() || 'bolt', colour: (document.getElementById('pw-colour') || {}).value || '',
        prompt: document.getElementById('pw-prompt').value, supplier, input: document.getElementById('pw-input').value, output: document.getElementById('pw-output').value, confirm: document.getElementById('pw-confirm').value,
        allow_secrets: document.getElementById('pw-secrets').checked, description: _pw.editing ? (_pw.editing.description || '') : '' };
}
async function powerSave() {
    const msg = document.getElementById('pw-msg'); msg.textContent = '…';
    const r = await powerApi('save', { button: _pwCollect() });
    if (!r.ok) { msg.style.color = 'var(--accent-red,#e55)'; msg.textContent = r.error || T('ui.power.save.failed', 'Could not save'); return; }
    msg.style.color = 'var(--text-muted)'; msg.textContent = T('ui.power.saved', 'Saved.'); await powerRefresh(); powerEditorRender(r.button, false);
}
async function powerDelete() {
    if (!_pw.editing || !await cockpitConfirm(T('ui.power.del.title', 'Delete this button?'), T('ui.power.del.body', 'The button "{name}" will be removed. Its prompt is lost unless you saved it elsewhere.', { name: _pw.editing.name }), T('ui.power.delete', 'Delete'), { danger: true, icon: 'delete' })) return;
    await powerApi('delete', { id: _pw.editing.id }); _pw.editing = null; document.getElementById('power-editor').innerHTML = ''; await powerRefresh();
}
async function powerRunUi() {
    const b = _pw.editing; if (!b || !b.id) return; const msg = document.getElementById('pw-runmsg'), res = document.getElementById('pw-result'), cp = document.getElementById('pw-copy');
    let text = document.getElementById('pw-try').value, payload;
    msg.style.color = 'var(--text-muted)'; res.style.display = 'none'; cp.style.display = 'none';
    if (b.input === 'image') { payload = await _pwReadInput(b); if (!payload) { msg.textContent = ''; return; } }
    else if (b.input === 'none') payload = { input: '' };
    else if (text.trim()) payload = { input: text };
    else { payload = await _pwReadInput(b); if (!payload) { msg.textContent = ''; return; } }
    msg.textContent = T('ui.power.working', 'Working…');
    const r = await _pwRunWithGates(b, payload);
    if (!r) { msg.textContent = ''; return; }
    msg.textContent = _pwMeta(r);
    res.textContent = r.output; res.style.display = 'block'; cp.style.display = 'inline-block';
    cp.onclick = async () => { cp.textContent = (await _pwCopyText(r.output)) ? T('ui.power.copied', 'Copied') : T('ui.power.copyfail', 'Could not copy'); };
    powerRefresh();
}

// ── one run, shared by the panel's Run and the strip: read the input, run, and handle every stop with a clear question ──────────────────────────────────────────────────────────────────
function _pwMeta(r) { return (r.supplier || '') + (r.model ? ' · ' + r.model : '') + ' · ' + (r.ms / 1000).toFixed(1) + ' s' + (r.truncated_input ? ' · ' + T('ui.power.cut', 'the text was cut to fit') : '') + (r.cost_usd ? ' · $' + Number(r.cost_usd).toFixed(4) : ''); }
function _pwBlobB64(blob) { return new Promise((res, rej) => { const fr = new FileReader(); fr.onload = () => res(String(fr.result).split(',')[1] || ''); fr.onerror = rej; fr.readAsDataURL(blob); }); }

/** A small modal that answers with the value of the button pressed (null on Esc / outside click). */
function _pwDialog(title, html, buttons, mount) {
    return new Promise(resolve => {
        document.getElementById('pw-dialog')?.remove();
        const ov = document.createElement('div'); ov.id = 'pw-dialog'; ov.style.cssText = 'position:fixed;inset:0;z-index:10060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(520px,94vw);max-height:86vh;overflow:auto;padding:14px;color:var(--text-primary);"><div style="font-weight:600;font-size:13px;margin-bottom:8px;">' + _pwEsc(title) + '</div><div id="pw-dlg-body" style="font-size:11.5px;line-height:1.5;">' + html + '</div>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px;flex-wrap:wrap;">' + buttons.map((b, i) => '<button class="action-btn" data-i="' + i + '" style="padding:4px 12px;' + (b.danger ? 'border-color:var(--accent-amber);' : '') + '">' + _pwEsc(b.label) + '</button>').join('') + '</div></div>';
        document.body.appendChild(ov);
        const done = v => { ov.remove(); document.removeEventListener('keydown', onKey, true); resolve(v); };
        const onKey = e => { if (e.key === 'Escape') { e.stopPropagation(); done(null); } }; document.addEventListener('keydown', onKey, true);
        ov.onclick = e => { if (e.target === ov) done(null); };
        ov.querySelectorAll('button[data-i]').forEach(bt => bt.onclick = () => { const b = buttons[+bt.dataset.i]; done(typeof b.value === 'function' ? b.value() : b.value); });
        if (mount) mount(ov, done);
    });
}

/** The text or picture this button works on. Tries the browser's clipboard; if the browser will not give it, asks the person to paste it here. */
async function _pwReadInput(b) {
    const kind = b.input || 'clipboard';
    try {
        if (kind === 'none') return { input: '' };
        if (kind === 'selection') { const sel = String(window.getSelection ? window.getSelection() : '').trim(); if (sel) return { input: sel }; return { input: await navigator.clipboard.readText() }; }
        if (kind === 'clipboard') { const t = await navigator.clipboard.readText(); if (t.trim()) return { input: t }; throw new Error('empty'); }
        if (kind === 'image') { const items = await navigator.clipboard.read(); for (const it of items) { const ty = it.types.find(x => x.startsWith('image/')); if (ty) return { image: { b64: await _pwBlobB64(await it.getType(ty)) } }; } throw new Error('no picture'); }
        if (kind === 'file') return await _pwPickFile();
    } catch (e) { /* the browser did not give it: ask */ }
    return _pwAskPaste(b);
}
function _pwPickFile() {
    return new Promise(resolve => {
        const f = document.createElement('input'); f.type = 'file'; f.style.display = 'none'; document.body.appendChild(f);
        f.onchange = async () => { const file = f.files && f.files[0]; f.remove(); if (!file) { resolve(null); return; } if (file.size > 400000) { _pwToast(null, T('ui.power.file.big', 'That file is too large (400 KB at most).')); resolve(null); return; } resolve({ input: await file.text() }); };
        f.addEventListener('cancel', () => { f.remove(); resolve(null); }); f.click();
    });
}
function _pwAskPaste(b) {
    const pic = (b.input || '') === 'image';
    let got = null;
    const html = '<div style="color:var(--text-muted);margin-bottom:6px;">' + (pic ? T('ui.power.paste.pic', 'Cockpit could not read your clipboard. Click the box and paste the picture (Ctrl+V).') : T('ui.power.paste.text', 'Cockpit could not read your clipboard. Paste the text here (Ctrl+V).')) + '</div>' +
        '<div id="pw-paste" contenteditable="true" style="min-height:110px;max-height:240px;overflow:auto;background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;padding:6px;white-space:pre-wrap;"></div>';
    return _pwDialog(b.name, html, [{ label: T('ui.power.cancel', 'Cancel'), value: null }, { label: T('ui.power.run', 'Run'), value: () => got }], (ov) => {
        const box = ov.querySelector('#pw-paste'); box.focus();
        box.addEventListener('paste', async e => {
            const items = e.clipboardData ? [...e.clipboardData.items] : [];
            const im = items.find(i => i.type.startsWith('image/'));
            if (im) { e.preventDefault(); const blob = im.getAsFile(); got = { image: { b64: await _pwBlobB64(blob) } }; box.innerHTML = '<img style="max-width:100%;max-height:200px;" src="data:' + im.type + ';base64,' + got.image.b64 + '">'; return; }
        });
        box.addEventListener('input', () => { if (!pic && !box.querySelector('img')) got = { input: box.innerText }; });
    }).then(v => (v && (v.input || v.image)) ? v : null);
}

async function _pwRunWithGates(b, payload, extra) {
    extra = extra || {};
    for (let tries = 0; tries < 4; tries++) {
        const r = await powerApi('run', Object.assign({ id: b.id }, payload, extra));
        if (r.ok) return r;
        if (r.gate === 'confirm') {
            const html = '<div>' + T('ui.power.sendq.body2', 'This button sends {what} to {supplier} ({model}), which is outside this computer.', { what: r.image ? T('ui.power.what.pic', 'the picture you copied') : T('ui.power.what.text', 'the text you copied') + ' (' + r.chars + ' ' + T('ui.power.chars', 'characters') + ')', supplier: _pwEsc(r.supplier), model: _pwEsc(r.model) }) + '</div>' +
                (r.preview ? '<div style="margin-top:8px;padding:6px;background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;white-space:pre-wrap;max-height:130px;overflow:auto;">' + _pwEsc(r.preview) + (r.chars > r.preview.length ? '…' : '') + '</div>' : '');
            const v = await _pwDialog(T('ui.power.sendq.title', 'Send this outside this computer?'), html, [{ label: T('ui.power.cancel', 'Cancel'), value: null }, { label: T('ui.power.sendq.yes', 'Send it'), value: 'yes' }]);
            if (v !== 'yes') return null;
            if (r.mode !== 'always') await powerApi('consent', { supplier: r.supplier });
            extra = Object.assign({}, extra, { confirmed: true }); continue;
        }
        if (r.gate === 'secret') {
            const v = await _pwDialog(T('ui.power.secret.title', 'This looks like a secret'), '<div>' + T('ui.power.secret.body', 'The text looks like {kind}, so it was NOT sent to {supplier}.', { kind: _pwEsc(r.kind || 'a secret'), supplier: _pwEsc(r.supplier || 'the supplier') }) + '</div><div style="margin-top:6px;color:var(--text-muted);">' + T('ui.power.secret.hint', 'A model on this computer never sends anything away.') + '</div>',
                [{ label: T('ui.power.cancel', 'Cancel'), value: null }, { label: T('ui.power.secret.local', 'Use a model on this computer'), value: 'local' }, { label: T('ui.power.secret.once', 'Send it anyway, this once'), value: 'once', danger: true }]);
            if (v === 'local') { extra = Object.assign({}, extra, { supplier: { type: 'ollama', model: '' } }); continue; }
            if (v === 'once') { extra = Object.assign({}, extra, { allow_secrets_once: true }); continue; }
            return null;
        }
        const em = r.error || T('ui.power.failed', 'It did not work.');
        if (document.getElementById('power-overlay') && document.getElementById('power-overlay').style.display !== 'none' && document.getElementById('pw-runmsg')) { const m = document.getElementById('pw-runmsg'); m.style.color = 'var(--accent-amber)'; m.textContent = em; } else _pwToast(b, em, true);
        return null;
    }
    return null;
}

// ── the result card (bottom right) ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
function _pwToast(b, text, isError, r) {
    let box = document.getElementById('power-toast'); if (!box) { box = document.createElement('div'); box.id = 'power-toast'; box.style.cssText = 'position:fixed;right:14px;bottom:14px;z-index:10040;display:flex;flex-direction:column;gap:8px;max-width:min(460px,92vw);'; document.body.appendChild(box); }
    const card = document.createElement('div');
    card.style.cssText = 'background:var(--bg-base);border:1px solid ' + (isError ? 'var(--accent-amber)' : 'var(--border-mid)') + ';border-radius:6px;padding:10px 12px;box-shadow:0 6px 22px rgba(0,0,0,.45);color:var(--text-primary);font-size:11.5px;';
    const head = b ? '<span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;' + (b.colour ? 'color:' + _pwEsc(b.colour) + ';' : 'color:var(--accent-cyan);') + '">' + _pwEsc(b.icon || 'bolt') + '</span> <b>' + _pwEsc(b.name) + '</b>' : '';
    card.innerHTML = '<div style="display:flex;align-items:center;gap:8px;">' + head + '<span style="flex:1;font-size:10px;color:var(--text-muted);">' + (r ? _pwEsc(_pwMeta(r)) : '') + '</span><span class="rp-action-btn" data-x style="cursor:pointer;">×</span></div>' +
        '<div style="margin-top:6px;white-space:pre-wrap;max-height:240px;overflow:auto;' + (isError ? 'color:var(--accent-amber);' : '') + '">' + _pwEsc(text) + '</div>' +
        (r ? '<div style="display:flex;gap:6px;margin-top:8px;align-items:center;"><button class="action-btn" data-copy style="padding:2px 10px;">' + T('ui.power.copy', 'Copy the answer') + '</button>' + (r.output_to === 'file' ? '<button class="action-btn" data-save style="padding:2px 10px;">' + T('ui.power.savefile', 'Save as a file') + '</button>' : '') + '<span data-note style="font-size:10px;color:var(--text-muted);"></span></div>' : '');
    box.appendChild(card);
    const close = () => card.remove(); card.querySelector('[data-x]').onclick = close;
    if (r) {
        const note = card.querySelector('[data-note]'); const cp = card.querySelector('[data-copy]');
        const copy = async () => { const ok = await _pwCopyText(r.output); note.textContent = ok ? T('ui.power.copied.note', 'On your clipboard.') : T('ui.power.copyfail', 'Could not copy'); return ok; };
        cp.onclick = copy;
        const sv = card.querySelector('[data-save]'); if (sv) sv.onclick = () => { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([r.output + '\n'], { type: 'text/markdown' })); a.download = (b.name || 'answer').toLowerCase().replace(/[^a-z0-9]+/g, '-') + '.md'; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 4000); };
        if (r.output_to === 'clipboard') copy().then(() => setTimeout(close, 14000));
    } else if (isError) setTimeout(close, 12000);
    return card;
}

// ── the strip above the prompt ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
function powerStripDraw() {
    const el = document.getElementById('power-strip'); if (!el) return;
    const list = (_pw.data && _pw.data.buttons) || [];
    // with no buttons yet, a one-line hint stands in the same row (until the first button exists, or the person hides it with the ×)
    let hintOff = false; try { hintOff = localStorage.getItem('ck_power_hint_off') === '1'; } catch (e) {}
    const show = !!_pw.data && (list.length > 0 || !hintOff);
    document.body.classList.toggle('has-power-strip', show);   // css/console.css: the footer grows by this one row
    if (!show) { el.style.display = 'none'; el.innerHTML = ''; return; }
    el.style.display = 'flex';
    if (!list.length) {
        el.innerHTML = '<span class="material-symbols-rounded" style="font-size:15px;color:var(--accent-cyan);">touch_app</span>' +
            '<span style="color:var(--text-muted);"><b style="font-weight:600;">' + T('ui.power.hint.title', 'Power Buttons') + '</b> — ' + T('ui.power.hint.text', 'one click runs a saved prompt on what you copied: proofread, summarise, make it polite…') + '</span>' +
            '<button class="ma-mode-btn" onclick="powerOpen()" style="display:inline-flex;align-items:center;gap:4px;">' + T('ui.power.hint.add', 'Add one…') + '</button>' +
            '<button class="ma-mode-btn" onclick="powerHintHide()" title="' + _pwEsc(T('ui.power.hint.hide', 'Do not show this hint again')) + '" style="margin-left:auto;">×</button>';
        return;
    }
    el.innerHTML = '<span style="color:var(--text-muted);font-weight:600;" title="' + _pwEsc(T('ui.power.strip.tip', 'Power Buttons: one click runs a saved prompt on what you copied')) + '">' + T('ui.power.strip', 'Power Buttons:') + '</span>' +
        list.slice(0, 14).map(b => '<button class="ma-mode-btn" onclick="powerRunButton(\'' + _pwEsc(b.id) + '\')" title="' + _pwEsc(b.name + (b.description ? ' — ' + b.description : '') + ' · ' + (b.supplier && b.supplier.type === 'worker' ? b.supplier.provider : T('ui.power.on.computer', 'on this computer')) + ' · ' + ({ clipboard: T('ui.power.in.clipboard.s', 'works on what you copied'), selection: T('ui.power.in.selection.s', 'works on what you selected'), image: T('ui.power.in.image.s', 'works on a picture you copied'), file: T('ui.power.in.file.s', 'works on a file'), none: '' }[b.input] || '')) + '" style="display:inline-flex;align-items:center;gap:4px;">' +
            '<span class="material-symbols-rounded" style="font-size:14px;' + (b.colour ? 'color:' + _pwEsc(b.colour) + ';' : '') + '">' + _pwEsc(b.icon || 'bolt') + '</span>' + _pwEsc(b.name) + '</button>').join('') +
        '<button class="ma-mode-btn" onclick="powerOpen()" title="' + _pwEsc(T('ui.power.strip.manage', 'Open Power Buttons: edit or add buttons')) + '" style="margin-left:auto;"><span class="material-symbols-rounded" style="font-size:14px;">tune</span></button>';
}
function powerHintHide() { try { localStorage.setItem('ck_power_hint_off', '1'); } catch (e) {} powerStripDraw(); }
async function powerStripRefresh() { try { const d = await powerApi('list'); if (d && d.ok) { _pw.data = d; powerStripDraw(); } } catch (e) {} }
async function powerRunButton(id) {
    if (!_pw.data) await powerStripRefresh();
    const b = ((_pw.data && _pw.data.buttons) || []).find(x => x.id === id); if (!b) return;
    if (_pwBusy.has(id)) return; _pwBusy.add(id);
    const chip = [...document.querySelectorAll('#power-strip button')].find(x => (x.getAttribute('onclick') || '').includes("'" + id + "'")); if (chip) chip.style.opacity = '0.55';
    try {
        const payload = await _pwReadInput(b); if (!payload) return;
        const w = _pwToast(b, T('ui.power.working', 'Working…'), false);
        const r = await _pwRunWithGates(b, payload); w.remove();
        if (r) { _pwToast(b, r.output, false, r); powerStripRefresh(); }
    } finally { _pwBusy.delete(id); if (chip) chip.style.opacity = ''; }
}
const _pwBusy = new Set();
if (typeof window !== 'undefined') { (window.authGateReady ? window.authGateReady() : Promise.resolve()).then(() => setTimeout(powerStripRefresh, 800)); }

// ── history ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
async function powerHistoryShow() {
    const ed = document.getElementById('power-editor'); if (!ed) return; _pw.editing = null;
    const d = await powerApi('list'); const h = (d && d.history) || [];
    const fmt = t => { try { return new Date(t).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' }); } catch (e) { return t; } };
    ed.innerHTML = '<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;"><b style="font-size:12px;flex:1;">' + T('ui.power.history.title', 'Recent runs') + '</b><button class="action-btn" id="pw-hclear" style="padding:2px 10px;">' + T('ui.power.history.clear', 'Clear history') + '</button></div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-bottom:6px;">' + T('ui.power.history.note', 'One line per run: when, which button, which supplier, how long and how big. The text you worked on and the answer are never kept here.') + '</div>' +
        (h.length ? '<table style="width:100%;border-collapse:collapse;font-size:11px;">' + h.map(x => '<tr style="border-top:1px solid var(--border-dim);' + (x.ok ? '' : 'color:var(--accent-amber);') + '"><td style="padding:3px 6px;white-space:nowrap;">' + _pwEsc(fmt(x.t)) + '</td><td style="padding:3px 6px;">' + _pwEsc(x.name) + (x.image ? ' <span class="material-symbols-rounded" style="font-size:13px;vertical-align:-2px;" title="' + _pwEsc(T('ui.power.history.pic', 'a picture')) + '">image</span>' : '') + '</td><td style="padding:3px 6px;">' + _pwEsc((x.supplier || '') + (x.model ? ' · ' + x.model : '')) + '</td><td style="padding:3px 6px;white-space:nowrap;">' + (x.ms ? (x.ms / 1000).toFixed(1) + ' s' : '') + '</td><td style="padding:3px 6px;">' + (x.ok ? (x.chars_in || 0) + ' → ' + (x.chars_out || 0) : _pwEsc(x.error || '')) + '</td></tr>').join('') + '</table>' : '<div style="font-size:11px;color:var(--text-muted);">' + T('ui.power.history.none', 'Nothing yet.') + '</div>');
    document.getElementById('pw-hclear').onclick = async () => { await powerApi('history_clear', {}); powerHistoryShow(); };
}