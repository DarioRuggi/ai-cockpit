// =============================================================================
// Power Buttons, part 2 (plans/PLAN_3_power_buttons.md steps 3-6 and the extras): a small result window, a hotkey per button, launchers (Linux, macOS, Windows/WSL), the command-line
// tool `cockpit-run`, right-click actions in the file managers, packs (export / import), and Automations (a watched folder, a daily or repeating button). Loaded after power-buttons.js,
// which it extends by wrapping a few of its functions. What needs the native Cockpit window (global hotkeys, writing a launcher into the applications menu, the ⚡ menu of a Browser window)
// goes through shellCall; in a plain browser the same files are offered as downloads and the hotkeys are explained as unavailable - never silently missing.
// =============================================================================
const _pwX = { lastSync: '' };
const _pwHasShell = () => typeof _inShell !== 'undefined' && _inShell;
const _pwInp = 'background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:4px 6px;border-radius:3px;font-size:11px;box-sizing:border-box;';

function _pwDownload(name, text, type) { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text], { type: type || 'text/plain' })); a.download = name; document.body.appendChild(a); a.click(); a.remove(); }
function _pwSay(msg, bad) { const m = document.getElementById('pw-msg'); if (m) { m.style.color = bad ? 'var(--accent-amber)' : 'var(--text-muted)'; m.textContent = msg; } else if (typeof _pwToast === 'function') _pwToast(null, msg, !!bad); }

// ── 1. the editor: a hotkey, two more outputs, the launcher / sharing row ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
const _pwEditorOrig = powerEditorRender;
powerEditorRender = function (b, isNew) {
    _pwEditorOrig(b, isNew);
    const out = document.getElementById('pw-output'); if (!out) return;
    if (!out.querySelector('option[value="window"]')) {
        const add = (v, l) => { const o = document.createElement('option'); o.value = v; o.textContent = l; if (b.output === v) o.selected = true; out.appendChild(o); };
        add('window', T('ui.power.out.window', 'A small window')); add('paste', T('ui.power.out.paste', 'Pasted where the cursor is (launcher or hotkey, not in this panel)'));
    }
    const sel = document.getElementById('pw-confirm'); if (!sel) return;
    const lab = document.createElement('span'); lab.textContent = T('ui.power.f.hotkey', 'Hotkey');
    const fld = document.createElement('span');
    fld.innerHTML = '<input id="pw-hotkey" style="' + _pwInp + 'width:160px;" maxlength="40" placeholder="ctrl+alt+1" value="' + _pwEsc(b.hotkey || '') + '" title="' + _pwEsc(T('ui.power.hotkey.tip', 'One to three of ctrl, alt, shift, super and one letter, digit or F1-F12. Works anywhere on the desktop while Cockpit is running (X11).')) + '"> ' +
        '<span style="font-size:10px;color:var(--text-muted);">' + (_pwHasShell() ? T('ui.power.hotkey.hint', 'Works anywhere on the desktop while Cockpit runs (X11 only).') : T('ui.power.hotkey.noshell', 'Needs the Cockpit window (not a browser tab), on X11.')) + '</span>';
    sel.parentNode.appendChild(lab); sel.parentNode.appendChild(fld);   // the grid is label/field pairs: the hotkey is the last pair
    const extra = document.createElement('div'); extra.style.cssText = 'margin-top:12px;border-top:1px solid var(--border-dim);padding-top:10px;';
    extra.innerHTML = isNew ? '' : '<div style="font-size:11px;font-weight:600;margin-bottom:6px;">' + T('ui.power.outside', 'Outside Cockpit') + '</div><div style="display:flex;gap:8px;flex-wrap:wrap;">' +
        '<button class="action-btn" id="pw-launcher" style="padding:3px 12px;" title="' + _pwEsc(T('ui.power.launcher.tip', 'A launcher for this one button: in your applications menu, on the desktop, or a file for another system.')) + '">' + T('ui.power.launcher', 'Create launcher…') + '</button></div>';
    const ed = document.getElementById('power-editor'); if (ed) ed.appendChild(extra);
    const lb = document.getElementById('pw-launcher'); if (lb) lb.onclick = () => powerLauncherDialog(b);
};
const _pwCollectOrig = _pwCollect;
_pwCollect = function () { const o = _pwCollectOrig(); const h = document.getElementById('pw-hotkey'); o.hotkey = h ? h.value.trim().toLowerCase() : ''; return o; };

// ── 2. keep the Cockpit window in step: the hotkeys it grabs and the ⚡ menu of Browser windows ─────────────────────────────────────────────────────────────────────────────────────────────────────
async function powerShellSync() {
    if (!_pwHasShell()) return;
    try {
        const d = await powerApi('shell_sync'); if (!d || !d.ok) return;
        const sig = JSON.stringify([d.hotkeys, d.menu]); if (sig === _pwX.lastSync) return; _pwX.lastSync = sig;
        const r = await shellCall('open_power_sync', { hotkeys: d.hotkeys, menu: d.menu });
        if (d.hotkeys.length && r.wayland) _pwSay(T('ui.power.hotkey.wayland', 'This desktop session is Wayland: it does not let a program grab keys. Add the shortcut in your desktop settings with the command from "Create launcher".'), true);
        else if (d.hotkeys.length && r.grabbed < d.hotkeys.length) _pwSay(T('ui.power.hotkey.some', '{n} of {m} hotkeys are active. A key another program holds, or a repeated one, is skipped.', { n: Math.max(0, r.grabbed), m: d.hotkeys.length }), true);
    } catch (e) { /* the window is older than this feature: nothing to sync */ }
}
const _pwRefreshOrig = powerRefresh;
powerRefresh = async function () { await _pwRefreshOrig(); powerShellSync(); };
const _pwStripRefreshOrig = powerStripRefresh;
powerStripRefresh = async function () { await _pwStripRefreshOrig(); powerShellSync(); };

// ── 3. the answer in a small window, or "pasted": what the panel can do for those two outputs ────────────────────────────────────────────────────────────────────────────────────────────
const _pwToastOrig = _pwToast;
_pwToast = function (b, text, isError, r) {
    if (r && r.output_to === 'window') { powerResultWindow(b, r); return _pwToastOrig(b, T('ui.power.window.opened', 'The answer is in its own window.'), false); }
    if (r && r.output_to === 'paste') { _pwCopyText(r.output); return _pwToastOrig(b, r.output + '\n\n' + T('ui.power.paste.note', 'Copied. Pasting into another program happens from a launcher or a hotkey; here, press Ctrl+V where you want it.'), false, Object.assign({}, r, { output_to: 'show' })); }
    return _pwToastOrig(b, text, isError, r);
};
function powerResultWindow(b, r) {
    document.getElementById('pw-result-win')?.remove();
    const w = document.createElement('div'); w.id = 'pw-result-win'; w.style.cssText = 'position:fixed;right:40px;bottom:60px;z-index:10045;width:min(520px,92vw);height:min(380px,70vh);background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;box-shadow:0 8px 28px rgba(0,0,0,.5);display:flex;flex-direction:column;color:var(--text-primary);resize:both;overflow:hidden;';
    w.innerHTML = '<div style="display:flex;align-items:center;gap:8px;padding:6px 10px;border-bottom:1px solid var(--border-dim);cursor:move;" data-drag><span class="material-symbols-rounded" style="font-size:16px;color:var(--accent-cyan);">' + _pwEsc(b.icon || 'bolt') + '</span><b style="flex:1;font-size:12px;">' + _pwEsc(b.name) + '</b>' +
        '<button class="action-btn" data-c style="padding:1px 10px;">' + T('ui.power.copy', 'Copy the answer') + '</button><button class="action-btn" data-s style="padding:1px 10px;">' + T('ui.power.save.file', 'Save…') + '</button><span class="rp-action-btn" data-x style="cursor:pointer;">×</span></div>' +
        '<pre style="flex:1;margin:0;padding:10px;white-space:pre-wrap;overflow:auto;font:inherit;font-size:12.5px;user-select:text;">' + _pwEsc(r.output) + '</pre>';
    document.body.appendChild(w);
    w.querySelector('[data-x]').onclick = () => w.remove();
    w.querySelector('[data-c]').onclick = async function () { this.textContent = (await _pwCopyText(r.output)) ? T('ui.power.copied', 'Copied') : T('ui.power.copyfail', 'Could not copy'); };
    w.querySelector('[data-s]').onclick = () => _pwDownload((b.name || 'answer').toLowerCase().replace(/[^a-z0-9]+/g, '-') + '.md', r.output + '\n', 'text/markdown');
    const bar = w.querySelector('[data-drag]'); let dx = 0, dy = 0, on = false;
    bar.onmousedown = e => { if (e.target.closest('button,[data-x]')) return; on = true; const rc = w.getBoundingClientRect(); dx = e.clientX - rc.left; dy = e.clientY - rc.top; w.style.right = 'auto'; w.style.bottom = 'auto'; w.style.left = rc.left + 'px'; w.style.top = rc.top + 'px'; e.preventDefault(); };
    document.addEventListener('mousemove', e => { if (on) { w.style.left = (e.clientX - dx) + 'px'; w.style.top = (e.clientY - dy) + 'px'; } });
    document.addEventListener('mouseup', () => { on = false; });
}

// ── 4. launchers ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
async function _pwInstall(kind, name, content) { const r = await shellCall('open_install_file', { kind, name, content }); return r.path; }
async function powerLauncherDialog(b) {
    const native = _pwHasShell();
    const html = '<div style="font-size:11.5px;line-height:1.5;">' + T('ui.power.launcher.body', 'A launcher runs "{name}" from outside Cockpit: it reads what you copied (or selected) and puts the answer where the button says. The file holds no key or password: only the button\'s name.', { name: _pwEsc(b.name) }) + '</div>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin-top:6px;">' + (native ? T('ui.power.launcher.native', 'The first two are written for you; the others download a file for that system. macOS and Windows launchers need PHP and Cockpit on that same computer.') : T('ui.power.launcher.web', 'This is a browser tab, so the launcher downloads as a file. macOS and Windows launchers need PHP and Cockpit on that same computer.')) + '</div>';
    const choices = (native ? [{ label: T('ui.power.launcher.menu', 'Add to my applications menu'), value: 'menu' }, { label: T('ui.power.launcher.desktop', 'Put an icon on the desktop'), value: 'desktop' }] : [])
        .concat([{ label: 'Linux (.desktop)', value: 'linux' }, { label: 'macOS (.command)', value: 'macos' }, { label: 'Windows (.cmd)', value: 'windows' }, { label: T('ui.power.cancel', 'Cancel'), value: null }]);
    const v = await _pwDialog(T('ui.power.launcher', 'Create launcher…'), html, choices); if (!v) return;
    try {
        const d = await powerApi('launch_spec&id=' + encodeURIComponent(b.id) + (v === 'menu' || v === 'desktop' ? '' : '&platform=' + v)); if (!d.ok) throw new Error(d.error || 'failed');
        if (v === 'menu' || v === 'desktop') {
            const f = d.files[0]; if (!/\.desktop$/.test(f.name)) throw new Error(T('ui.power.launcher.notlinux', 'This computer is not a Linux desktop: use the download buttons.'));
            const p = await _pwInstall(v === 'menu' ? 'launcher' : 'desktop_icon', f.name, f.content); _pwSay(T('ui.power.launcher.done', 'Launcher written: {path}', { path: p }));
        } else { for (const f of d.files) _pwDownload(f.name, f.content, 'text/plain'); _pwSay(T('ui.power.launcher.dl', 'Downloaded. Put it where you want it and make it executable (macOS and Linux: chmod +x).')); }
    } catch (e) { _pwSay(e.message, true); }
}

// ── 5. command line + file managers ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
async function powerInstallCli() {
    try {
        const d = await powerApi('cli_script'); if (!d.ok) throw new Error(d.error || 'failed');
        if (_pwHasShell()) { const p = await _pwInstall('cli', 'cockpit-run', d.content); await _pwDialog(T('ui.power.cli.title', 'Command line'), '<div style="font-size:11.5px;line-height:1.6;">' + T('ui.power.cli.done', 'Installed: {path}', { path: '<code>' + _pwEsc(p) + '</code>' }) + '<br><code>cockpit-run proofread &lt; draft.txt &gt; clean.txt</code><br><code>cockpit-run --list</code><br><span style="color:var(--text-muted);font-size:10.5px;">' + T('ui.power.cli.path', 'If the command is not found, add ~/.local/bin to your PATH.') + '</span></div>', [{ label: 'OK', value: 1 }]); }
        else { _pwDownload('cockpit-run', d.content); _pwSay(T('ui.power.cli.dl', 'Downloaded cockpit-run: put it in a folder on your PATH and make it executable.')); }
    } catch (e) { _pwSay(e.message, true); }
}
async function powerInstallFm() {
    try {
        const d = await powerApi('fm_integration'); if (!d.ok) throw new Error(d.error || 'failed');
        if (!d.count) { await _pwDialog(T('ui.power.fm.title', 'File manager'), T('ui.power.fm.none', 'Make a button first: each one becomes a right-click action.'), [{ label: 'OK', value: 1 }]); return; }
        if (!_pwHasShell()) { _pwDownload('cockpit-power-filemanager.txt', 'Nautilus / Nemo: put each file below in ~/.local/share/nautilus/scripts (or ~/.local/share/nemo/scripts) and make it executable.\n\n' + d.nautilus.map(f => '--- ' + f.name + '\n' + f.content).join('\n') + '\nDolphin: save as ~/.local/share/kio/servicemenus/cockpit-power.desktop\n\n' + d.dolphin); _pwSay(T('ui.power.fm.dl', 'Downloaded the instructions and the files.')); return; }
        let n = 0; for (const f of d.nautilus) { await _pwInstall('nautilus', f.name, f.content); n++; }
        if (d.dolphin) await _pwInstall('dolphin', 'cockpit-power.desktop', d.dolphin);
        await _pwDialog(T('ui.power.fm.title', 'File manager'), '<div style="font-size:11.5px;line-height:1.6;">' + T('ui.power.fm.done', '{n} right-click actions written. In Files (Nautilus) they are under Right-click → Scripts; in Dolphin under Cockpit. The answer is saved next to the file as NAME.button.md. Restart the file manager if they do not show yet.', { n }) + '</div>', [{ label: 'OK', value: 1 }]);
    } catch (e) { _pwSay(e.message, true); }
}
/** The in-app file manager: right-click a file → run a button on it. Text files and pictures; the answer follows the button's own output. */
async function powerRunOnFile(path, e, fetchUrl) {
    try {
        if (!_pw.data) await powerStripRefresh();
        const list = (_pw.data && _pw.data.buttons) || []; if (!list.length) { _pwToast(null, T('ui.power.fm.nobuttons', 'You have no Power Buttons yet: make one first.'), true); return; }
        const id = await _pwDialog(T('ui.power.fm.pick', 'Run a Power Button on this file'), '<div style="font-size:11px;color:var(--text-muted);margin-bottom:6px;">' + _pwEsc(e.name) + '</div><div style="display:flex;flex-wrap:wrap;gap:6px;">' + list.map(b => '<button class="action-btn" data-b="' + _pwEsc(b.id) + '" style="padding:4px 10px;display:inline-flex;align-items:center;gap:5px;"><span class="material-symbols-rounded" style="font-size:15px;">' + _pwEsc(b.icon || 'bolt') + '</span>' + _pwEsc(b.name) + '</button>').join('') + '</div>',
            [{ label: T('ui.power.cancel', 'Cancel'), value: null }], (ov, done) => ov.querySelectorAll('button[data-b]').forEach(bt => bt.onclick = () => done(bt.dataset.b)));
        if (!id) return; const b = list.find(x => x.id === id); if (!b) return;
        const resp = await fetch(fetchUrl); if (!resp.ok) throw new Error('HTTP ' + resp.status);
        const blob = await resp.blob(); let payload;
        if (blob.type.startsWith('image/')) payload = { image: { b64: await _pwBlobB64(blob) } };
        else { if (blob.size > 400000) throw new Error(T('ui.power.fm.big', 'This file is too big for a button (400 KB of text at most).')); const t = await blob.text(); if (t.indexOf('\u0000') >= 0) throw new Error(T('ui.power.fm.binary', 'This is not a text file or a picture. (A PDF or an audio file works from a watched folder or the file manager of your desktop.)')); payload = { input: t }; }
        const w = _pwToast(b, T('ui.power.working', 'Working…'), false); const r = await _pwRunWithGates(b, payload); w.remove(); if (r) { _pwToast(b, r.output, false, r); powerStripRefresh(); }
    } catch (err) { _pwToast(null, err.message, true); }
}

// ── 6. packs ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
async function powerPackExport() {
    try { const d = await powerApi('pack_export', {}); if (!d.ok) throw new Error(d.error || 'failed'); _pwDownload('cockpit-power-buttons.json', JSON.stringify(d.pack, null, 2), 'application/json'); _pwSay(T('ui.power.pack.exported', '{n} buttons exported. The pack holds no keys; each one will run on a model on the computer that imports it.', { n: d.count })); }
    catch (e) { _pwSay(e.message, true); }
}
function powerPackImport() {
    const inp = document.createElement('input'); inp.type = 'file'; inp.accept = '.json,application/json';
    inp.onchange = async () => {
        const f = inp.files[0]; if (!f) return; if (f.size > 204800) { _pwSay(T('ui.power.pack.big', 'That file is too big for a pack.'), true); return; }
        const text = await f.text(); let d;
        try { d = await powerApi('pack_import', { pack: text }); } catch (e) { d = { ok: false, error: e.message }; }
        if (!d.ok) { _pwSay(d.error || 'failed', true); return; }
        const rows = d.preview.map(p => '<label style="display:flex;gap:8px;align-items:flex-start;padding:5px 0;border-top:1px solid var(--border-dim);font-size:11.5px;"><input type="checkbox" data-id="' + _pwEsc(p.id) + '" checked><span><b>' + _pwEsc(p.name) + '</b>' + (p.exists ? ' <span style="color:var(--accent-amber);font-size:10px;">' + T('ui.power.pack.exists', 'you have one with this name: it is added as a copy') + '</span>' : '') + '<br><span style="color:var(--text-muted);font-size:10.5px;">' + _pwEsc(p.prompt) + '</span></span></label>').join('');
        const skipped = Object.keys(d.skipped || {});
        const html = '<div style="font-size:11px;color:var(--text-muted);margin-bottom:6px;">' + T('ui.power.pack.note', 'Read the prompts before you add them. Every button from a pack is set to run on a model on this computer, never to send secrets, and its hotkey and paste output are removed: you can change those after.') + '</div>' + rows + (skipped.length ? '<div style="font-size:10.5px;color:var(--accent-amber);margin-top:6px;">' + T('ui.power.pack.skipped', 'Not read: {names}', { names: _pwEsc(skipped.join(', ')) }) + '</div>' : '');
        const v = await _pwDialog(T('ui.power.pack.title', 'Add buttons from a pack'), html, [{ label: T('ui.power.cancel', 'Cancel'), value: null }, { label: T('ui.power.pack.add', 'Add the checked ones'), value: () => [...document.querySelectorAll('#pw-dialog input[data-id]')].filter(x => x.checked).map(x => x.dataset.id) }]);
        if (!v || !v.length) return;
        const a = await powerApi('pack_import', { pack: text, apply: true, ids: v }); if (!a.ok) { _pwSay(a.error || 'failed', true); return; }
        _pwSay(T('ui.power.pack.added', '{n} buttons added.', { n: a.saved.length })); powerRefresh();
    };
    inp.click();
}

// ── 7. automations: a watched folder, a daily or repeating button ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
async function powerAutomations() {
    const ed = document.getElementById('power-editor'); if (!ed) return; _pw.editing = null;
    const d = await powerApi('rules_list'); const l = await powerApi('list'); const btns = (l && l.buttons) || [];
    const kindName = { watch: T('ui.power.rule.watch', 'Watch a folder'), daily: T('ui.power.rule.daily', 'Every day at'), every: T('ui.power.rule.every', 'Every … minutes') };
    const rules = (d.rules || []).map(r => '<tr style="border-top:1px solid var(--border-dim);' + (r.enabled ? '' : 'opacity:.55;') + '"><td style="padding:3px 6px;">' + _pwEsc(kindName[r.kind] || r.kind) + '</td><td style="padding:3px 6px;"><b>' + _pwEsc(r.button) + '</b></td><td style="padding:3px 6px;font-size:10.5px;word-break:break-all;">' + _pwEsc(r.kind === 'watch' ? r.folder : (r.source || '—')) + ' <span style="color:var(--text-muted);">' + _pwEsc(r.kind === 'daily' ? r.time : r.kind === 'every' ? r.minutes + ' min' : '') + '</span></td>' +
        '<td style="padding:3px 6px;white-space:nowrap;"><button class="action-btn" data-t="' + _pwEsc(r.id) + '" style="padding:1px 8px;">' + (r.enabled ? T('ui.power.rule.pause', 'Pause') : T('ui.power.rule.resume', 'Resume')) + '</button> <button class="action-btn" data-d="' + _pwEsc(r.id) + '" style="padding:1px 8px;">' + T('ui.power.delete', 'Delete') + '</button></td></tr>').join('');
    ed.innerHTML = '<b style="font-size:12px;">' + T('ui.power.auto.title', 'Automations') + '</b>' +
        '<div style="font-size:10.5px;color:var(--text-muted);margin:4px 0 8px;line-height:1.5;">' + T('ui.power.auto.intro', 'A button can run by itself. Watch a folder: drop a text file, a PDF or an audio file in and the answer is written next to it as FILE.button.md (files already there are left alone). Or run a button every day or every few minutes on a file or a folder. This uses the scheduler (the minute cron job); it needs Cockpit\'s scheduler to be installed.') + '</div>' +
        (rules ? '<table style="width:100%;border-collapse:collapse;font-size:11.5px;margin-bottom:10px;">' + rules + '</table>' : '<div style="font-size:11px;color:var(--text-muted);margin-bottom:10px;">' + T('ui.power.auto.none', 'No automations yet.') + '</div>') +
        '<div style="display:grid;grid-template-columns:110px 1fr;gap:6px;align-items:center;font-size:11px;border-top:1px solid var(--border-dim);padding-top:10px;">' +
        '<span>' + T('ui.power.auto.kind', 'When') + '</span><select id="pr-kind" style="' + _pwInp + '"><option value="watch">' + kindName.watch + '</option><option value="daily">' + kindName.daily + '</option><option value="every">' + kindName.every + '</option></select>' +
        '<span>' + T('ui.power.auto.button', 'Run') + '</span><select id="pr-button" style="' + _pwInp + '">' + btns.map(b => '<option>' + _pwEsc(b.name) + '</option>').join('') + '</select>' +
        '<span id="pr-pathl">' + T('ui.power.auto.folder', 'Folder') + '</span><input id="pr-path" style="' + _pwInp + 'width:100%;" placeholder="/home/you/Inbox">' +
        '<span id="pr-whenl" style="display:none;">' + T('ui.power.auto.time', 'Time (24 h)') + '</span><input id="pr-when" style="' + _pwInp + 'width:120px;display:none;" value="08:00">' +
        '<span></span><label id="pr-exl" style="font-size:10.5px;"><input type="checkbox" id="pr-existing"> ' + T('ui.power.auto.existing', 'Also process the files already in the folder') + '</label>' +
        '<span>' + T('ui.power.auto.to', 'Answer goes to') + '</span><input id="pr-to" style="' + _pwInp + 'width:100%;" placeholder="' + _pwEsc(T('ui.power.auto.to.ph', 'empty = next to the file (folder) or the button\'s own output · notify · file=/full/path.md')) + '">' +
        '</div><div style="display:flex;gap:8px;margin-top:10px;align-items:center;"><button class="action-btn" id="pr-save" style="padding:4px 14px;">' + T('ui.power.auto.add', 'Add automation') + '</button><span id="pr-msg" style="font-size:10.5px;color:var(--text-muted);"></span></div>' +
        ((d.log || []).length ? '<div style="margin-top:12px;font-size:10px;color:var(--text-muted);white-space:pre-wrap;border-top:1px solid var(--border-dim);padding-top:8px;">' + _pwEsc(d.log.join('\n')) + '</div>' : '');
    const kindSel = document.getElementById('pr-kind'), upd = () => {
        const k = kindSel.value; document.getElementById('pr-pathl').textContent = k === 'watch' ? T('ui.power.auto.folder', 'Folder') : T('ui.power.auto.source', 'File or folder to work on');
        document.getElementById('pr-path').placeholder = k === 'watch' ? '/home/you/Inbox' : '/home/you/Notes  ' + T('ui.power.auto.optional', '(empty if the button needs no input)');
        document.getElementById('pr-whenl').style.display = document.getElementById('pr-when').style.display = k === 'watch' ? 'none' : ''; document.getElementById('pr-when').value = k === 'daily' ? '08:00' : '60';
        document.getElementById('pr-whenl').textContent = k === 'daily' ? T('ui.power.auto.time', 'Time (24 h)') : T('ui.power.auto.minutes', 'Minutes (5-1440)');
        document.getElementById('pr-exl').style.display = k === 'watch' ? '' : 'none';
    }; kindSel.onchange = upd; upd();
    document.getElementById('pr-save').onclick = async () => {
        const k = kindSel.value, rule = { kind: k, button: document.getElementById('pr-button').value, to: document.getElementById('pr-to').value.trim() };
        if (k === 'watch') { rule.folder = document.getElementById('pr-path').value.trim(); rule.existing = document.getElementById('pr-existing').checked; }
        else { rule.source = document.getElementById('pr-path').value.trim(); if (k === 'daily') rule.time = document.getElementById('pr-when').value.trim(); else rule.minutes = +document.getElementById('pr-when').value; }
        const r = await powerApi('rule_save', { rule }); const m = document.getElementById('pr-msg');
        if (!r.ok) { m.style.color = 'var(--accent-amber)'; m.textContent = r.error || 'failed'; return; } powerAutomations();
    };
    ed.querySelectorAll('button[data-d]').forEach(bt => bt.onclick = async () => { await powerApi('rule_delete', { id: bt.dataset.d }); powerAutomations(); });
    ed.querySelectorAll('button[data-t]').forEach(bt => bt.onclick = async () => { const r = (d.rules || []).find(x => x.id === bt.dataset.t); if (r) { r.enabled = !r.enabled; await powerApi('rule_save', { rule: r }); powerAutomations(); } });
}

// ── the panel header: Packs, Automations, Command line, File manager ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
const _pwOpenOrig = powerOpen;
powerOpen = function () {
    _pwOpenOrig();
    const nb = document.getElementById('power-new'); if (!nb || document.getElementById('power-more')) return;
    const mk = (id, label, tip, fn) => { const b = document.createElement('button'); b.className = 'rp-action-btn'; b.id = id; b.textContent = label; b.title = tip; b.style.marginLeft = '6px'; b.onclick = fn; return b; };
    const wrap = document.createElement('span'); wrap.id = 'power-more';
    wrap.appendChild(mk('power-auto', T('ui.power.auto', 'Automations'), T('ui.power.auto.tip', 'Watch a folder, or run a button every day or every few minutes'), powerAutomations));
    wrap.appendChild(mk('power-packs', T('ui.power.packs', 'Packs'), T('ui.power.packs.tip', 'Share your buttons as one file, or add buttons from a file someone gave you'), async function () {
        const v = await _pwDialog(T('ui.power.packs', 'Packs'), '<div style="font-size:11.5px;line-height:1.5;">' + T('ui.power.packs.body', 'A pack is one file of buttons to give to someone. It never holds a key, and the buttons you get always start on a model on your own computer. (Sharing through the Marketplace needs the Marketplace server, which is not part of this version.)') + '</div>', [{ label: T('ui.power.cancel', 'Cancel'), value: null }, { label: T('ui.power.pack.import', 'Add from a file…'), value: 'i' }, { label: T('ui.power.pack.export', 'Export my buttons'), value: 'e' }]);
        if (v === 'e') powerPackExport(); else if (v === 'i') powerPackImport();
    }));
    wrap.appendChild(mk('power-cli', T('ui.power.cli.btn', 'Command line'), T('ui.power.cli.tip', 'Install cockpit-run: use your buttons from scripts and pipes'), powerInstallCli));
    wrap.appendChild(mk('power-fm', T('ui.power.fm.btn', 'File manager'), T('ui.power.fm.tip', 'Add your buttons to the right-click menu of your file manager'), powerInstallFm));
    nb.parentNode.insertBefore(wrap, document.getElementById('power-close'));
};
