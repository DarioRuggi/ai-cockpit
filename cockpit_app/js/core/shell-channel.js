function _pwToggleBtn(inputId) {
    return '<button type="button" onclick="_pwToggle(this,\'' + inputId + '\')" style="position:absolute;right:6px;top:50%;transform:translateY(-50%);background:none;border:none;cursor:pointer;color:var(--text-dim,#718096);padding:2px;line-height:1;" title="Show/hide password">' +
        '<span class="material-symbols-rounded" style="font-size:16px;">visibility</span></button>';
}
function _pwWrap(inputHtml, inputId) {
    return '<div style="position:relative;">' + inputHtml + _pwToggleBtn(inputId) + '</div>';
}
function _pwToggle(btn, inputId) {
    const inp = document.getElementById(inputId);
    if (!inp) return;
    const show = inp.type === 'password';
    inp.type = show ? 'text' : 'password';
    btn.querySelector('span').textContent = show ? 'visibility_off' : 'visibility';
}

// =============================================================================
// Native shell channel (cockpit_shell) — request/reply over WebKit script
// messages. Page → shell: postMessage(JSON); shell → page: cockpitShellReply().
// Used for the Bitwarden fill buttons; the shell is the only side that ever
// runs `bw`, and the master password is typed into bw's own terminal prompt.
// =============================================================================
const _inShell = /AICockpitShell\//.test(navigator.userAgent);
const _shellReqs = new Map(); let _shellSeq = 0;
function shellCall(cmd, extra) {
    return new Promise((res, rej) => {
        const port = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.cockpit;
        if (!_inShell || !port) return rej(new Error('Not running in the Cockpit window'));
        const id = 's' + (++_shellSeq);
        _shellReqs.set(id, { res, rej, t: setTimeout(() => { _shellReqs.delete(id); rej(new Error('No answer from the Cockpit window')); }, 240000) });
        port.postMessage(JSON.stringify(Object.assign({ id, cmd }, extra || {})));
    });
}
window.cockpitShellReply = function (r) {
    const p = r && _shellReqs.get(r.id); if (!p) return;
    clearTimeout(p.t); _shellReqs.delete(r.id);
    r.ok ? p.res(r) : p.rej(new Error(r.error || 'shell error'));
};
// Bitwarden fill button — only in the native window (the browser fallback
// has its own extensions). kind picks the vault item name to look for.
const BW_ITEM_NAMES = { local: 'AI Cockpit Local', saas: 'AI Cockpit SAAS', admin_token: 'AI Cockpit Admin Token' };
function bwFillBtn(kind, userId, passId, errId) {
    if (!_inShell) return '';
    return '<button type="button" class="action-btn bw-fill-btn" title="Fill from Bitwarden (item: ' + BW_ITEM_NAMES[kind] + ')" ' +
        'onclick="bwFill(\'' + kind + '\',\'' + (userId || '') + '\',\'' + passId + '\',\'' + errId + '\')" ' +
        'style="display:inline-flex;align-items:center;gap:5px;padding:5px 9px;font-size:11px;align-self:flex-start;">' +
        '<span class="material-symbols-rounded ico">key</span> Fill from Bitwarden</button>';
}
async function bwFill(kind, userId, passId, errId) {
    const err = document.getElementById(errId);
    const say = (m) => { if (err) err.textContent = m; };
    const q = BW_ITEM_NAMES[kind] || 'AI Cockpit';
    try {
        say('Bitwarden…');
        let r = await shellCall('bw_search', { q });
        let items = r.items || [];
        if (!items.length && q !== 'AI Cockpit') { r = await shellCall('bw_search', { q: 'AI Cockpit' }); items = r.items || []; }
        if (!items.length) { say('No Bitwarden login item matches "' + q + '".'); return; }
        const item = items.length === 1 ? items[0] : await bwChoose(items);
        if (!item) { say(''); return; }
        const g = await shellCall('bw_get', { item: item.id });
        const u = userId && document.getElementById(userId), p = document.getElementById(passId);
        if (u) { u.value = g.username || ''; u.dispatchEvent(new Event('input', { bubbles: true })); }
        if (p) { p.value = g.password || ''; p.dispatchEvent(new Event('input', { bubbles: true })); p.focus(); }
        say('Filled from Bitwarden: ' + (g.name || item.name));
    } catch (e) { say(e.message || String(e)); }
}
function bwChoose(items) {
    return new Promise((res) => {
        document.getElementById('bw-choose-ov')?.remove();
        const ov = document.createElement('div'); ov.id = 'bw-choose-ov';
        ov.style.cssText = 'position:fixed;inset:0;z-index:100020;background:rgba(0,0,0,0.55);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(420px,92vw);padding:16px 18px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
            '<h2 style="margin:0 0 10px;font-size:13px;"><span class="material-symbols-rounded ico">key</span> Which Bitwarden item?</h2>' +
            '<div style="display:flex;flex-direction:column;gap:6px;">' +
            items.map((it, i) => '<button class="action-btn" data-i="' + i + '" style="justify-content:flex-start;text-align:left;padding:7px 10px;">' +
                '<b>' + escapeHtml(it.name) + '</b>' + (it.username ? ' <span style="color:var(--text-dim);font-size:11px;">· ' + escapeHtml(it.username) + '</span>' : '') + '</button>').join('') +
            '</div><div style="text-align:right;margin-top:10px;"><button class="action-btn" data-i="-1">Cancel</button></div></div>';
        document.body.appendChild(ov);
        ov.querySelectorAll('button[data-i]').forEach(b => b.onclick = () => { const i = +b.dataset.i; ov.remove(); res(i >= 0 ? items[i] : null); });
        ov.addEventListener('click', e => { if (e.target === ov) { ov.remove(); res(null); } });
    });
}

// Native file paths (native window only). Browsers hide where a dropped or
// chosen file lives; the shell hands the page the real absolute path, so the
// file is attached by path (attachments.php ingest_path) instead of uploaded.
// Drops: the shell calls cockpitShellDrop({paths}) for every file drop on the
// window, from WebKit's data request — which can come before or after the DOM
// drop event, and regardless of where the drop landed. So the paths are held,
// and the prompt's own DOM drop event (it fires only there, the one element
// that accepts drags) picks them up; anything not claimed within 3 s is dropped.
let _shellDropPending = null;
window.cockpitShellDrop = function (d) {
    const paths = (d && d.paths) || [];
    if (!paths.length) return;
    _shellDropPending = { paths, at: Date.now() };
    // Not claimed by the prompt within a moment → it was dropped elsewhere on
    // the window: open the file(s) in the floating editor instead.
    setTimeout(() => {
        if (!_shellDropPending || _shellDropPending.paths !== paths) return;
        _shellDropPending = null;
        for (const p of paths) openDroppedFile(p);
    }, 700);
};
// Open a file by absolute path in the floating editor (text) — dropped on the
// window outside the prompt. Binary files just get a note with the path.
async function openDroppedFile(path) {
    try {
        const d = await (await fetch('browse.php?action=read', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path }) })).json();
        if (!d.ok) { appendError(T('msg.cannot.open.path.error', 'Cannot open {path}: {error}', {path: path, error: (d.error || 'unknown')})); return; }
        const bytes = Uint8Array.from(atob(d.b64 || ''), c => c.charCodeAt(0));
        let binary = false; for (let i = 0; i < Math.min(bytes.length, 8000); i++) { if (bytes[i] === 0) { binary = true; break; } }
        if (binary || (d.mime && !/^text\/|json|xml|javascript|x-sh|x-php|x-empty/.test(d.mime) && bytes.length > 0 && /^(image|video|audio|application\/(pdf|zip|octet))/.test(d.mime))) {
            appendSystem(T('msg.dropped.file.not.text.path.attach.it.via.the', 'Dropped file (not text): {path} — attach it via the prompt, or open it with its app.', {path: path}));
            if (typeof pathOpenDecorate === 'function') pathOpenDecorate(consoleBox.lastElementChild);
            return;
        }
        const content = new TextDecoder('utf-8').decode(bytes);
        const name = path.split('/').pop();
        openFloatingEditor({
            id: 'abs-' + path.replace(/[^a-zA-Z0-9]/g, '_'),
            heading: 'Editing file',
            filename: path,
            content,
            language: (name.split('.').pop() || ''),
            onSave: async (newContent) => {
                const r = await (await fetch('browse.php?action=write', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ path, content: newContent }) })).json();
                if (!r.ok) return { ok: false, error: r.error || 'unknown' };
                appendSystem(T('msg.saved.path.size.bytes', 'Saved {path} ({size} bytes).', {path: path, size: r.size}));
                return { ok: true };
            }
        });
    } catch (e) { appendError(T('msg.cannot.open.path.message', 'Cannot open {path}: {message}', {path: path, message: (e.message || e)})); }
}
function shellDropPaths() {
    // Called from a DOM drop handler: hand over the pending paths, or wait a
    // moment for them if the shell's call has not landed yet.
    return new Promise(res => {
        let n = 0;
        const tick = () => { if (_shellDropPending) { const p = _shellDropPending.paths; _shellDropPending = null; res(p); } else if (++n > 20) res(null); else setTimeout(tick, 100); };
        tick();
    });
}
// Native file chooser → absolute paths ([] when cancelled, null when not in the shell).
async function shellPickFiles(opts) {
    if (!_inShell) return null;
    try { const r = await shellCall('pick_files', Object.assign({ multiple: false, title: 'Choose a file' }, opts || {})); return r.paths || []; }
    catch (e) { return null; }
}

// "Keep me signed in": a per-device token the server issues at login, held in
// the OS keyring by the native window (GNOME Keyring / KWallet via libsecret),
// turned back into a session at boot without a password. Revoked on Sign out.
const KR_LOCAL_KEY = 'local_remember';
async function krGet(key) { try { const r = await shellCall('kr_get', { key }); return (r.available && r.found) ? r.value : null; } catch (e) { return null; } }
async function krSet(key, value) { try { const r = await shellCall('kr_set', { key, value }); return !!(r.available && r.ok); } catch (e) { return false; } }
async function krDel(key) { try { await shellCall('kr_del', { key }); } catch (e) {} }
async function krAvailable() { try { const r = await shellCall('kr_get', { key: '_probe' }); return !!r.available; } catch (e) { return false; } }
// Try the keyring token; true when a session was established (caller reloads).
async function authTryRemember() {
    if (!_inShell) return false;
    const tok = await krGet(KR_LOCAL_KEY);
    if (!tok) return false;
    try {
        const d = await (await fetch('auth.php?action=remember', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token: tok }) })).json();
        if (d.ok) return true;
    } catch (e) {}
    await krDel(KR_LOCAL_KEY);     // expired or revoked: forget it
    return false;
}


// ── Frameless main window: ▁ ▢ beside Exit, header drag, double-click maximise ──
// Shown only inside the native window AND only when it runs frameless (the WM's
// own buttons are gone then). The shell does the moving (GTK begin_move_drag),
// so the drag feels native; a double-click on empty header space maximises.
function _winButtons(on) {
    const box = document.getElementById('win-controls'); if (box) box.style.display = on ? 'flex' : 'none';
    document.body.classList.toggle('frameless', !!on);
    _winGrips(!!on);
}
// The sessions card's window row (Reopen / Reload / Refresh / Frameless) exists only inside the native window.
function _winRow(state) {
    const row = document.getElementById('win-row'); if (!row) return;
    row.style.display = 'flex';
    document.querySelectorAll('.win-only').forEach(b => { b.style.display = ''; });
    const b = document.getElementById('btn-frameless'); if (!b || !state) return;
    b.classList.toggle('active', !!state.wanted);
    b.style.color = state.wanted ? 'var(--accent-cyan,#7ecfff)' : '';
    b.title = 'Frameless window: no title bar — Exit, the logo card and ▁ ▢ stand in for it' + (state.pending ? ' · saved, takes effect on Reopen' : '') + (state.wanted ? ' (on)' : ' (off)');
}
// `frameless || wanted`, not `frameless` alone: the shell reports `frameless` as
// what the window ACTUALLY is at that instant, and a WM that re-frames lazily (and
// Wayland, which defers to the next map) still answers false right after the call.
// The page then left its own window controls hidden while the title bar was already
// gone -- a window with no visible way to close it until you toggled back.
// Narrowed from a wrong first guess on 2026-09-26: _winRow IS called here; the
// stale-looking button was this, not a missing re-render.
async function winFramelessToggle() {
    try { const s = await shellCall('win_state'); const r = await shellCall('set_frameless', { on: !(s && s.wanted) }); _winButtons(!!(r && (r.frameless || r.wanted))); _winRow(r); if (r && r.pending) appendSystem(T('msg.frameless.saved.takes.effect.on.reopen.wayla', 'Frameless saved — takes effect on Reopen (Wayland sets the frame when a window first opens).')); }
    catch (e) { appendSystem(T('msg.window.message', 'Window: {message}', {message: e.message})); }
}
// Frameless window: handles along the border, because with no title bar the window manager has no edges to grab. Eight resize strips (four sides, four corners) and, in the
// middle 15% of each side, a MOVE strip: pressing it moves the window (nothing is resized). A press is handed to the shell (win_resize / win_drag → GTK begin_resize_drag /
// begin_move_drag, so the window manager does it natively); a maximised window ignores both. Edge numbers are GdkWindowEdge: 0 NW, 1 N, 2 NE, 3 W, 4 E, 5 SW, 6 S, 7 SE.
// Resize strips are 4 px wide on the sides (a page scrollbar still gets most of its width) and 10 px at the corners; move strips are 8 px so they are easy to hit.
const _GRIP_MOVE = 'move', _GRIP_CORNER = 10, _GRIP_MID = 15;   // _GRIP_MID: percent of a side's length that moves the window
const _RESIZE_GRIPS = (function () {
    const lo = (100 - _GRIP_MID) / 2, hi = lo + _GRIP_MID, c = _GRIP_CORNER + 'px', g = [];
    g.push([0, 'nwse-resize', 'top:0;left:0;width:' + c + ';height:' + c], [2, 'nesw-resize', 'top:0;right:0;width:' + c + ';height:' + c],
           [5, 'nesw-resize', 'bottom:0;left:0;width:' + c + ';height:' + c], [7, 'nwse-resize', 'bottom:0;right:0;width:' + c + ';height:' + c]);
    for (const [edge, side] of [[1, 'top'], [6, 'bottom']]) {
        g.push([edge, 'ns-resize', side + ':0;left:' + c + ';width:calc(' + lo + '% - ' + c + ');height:4px'], [edge, 'ns-resize', side + ':0;left:' + hi + '%;width:calc(' + lo + '% - ' + c + ');height:4px'],
               [_GRIP_MOVE, 'move', side + ':0;left:' + lo + '%;width:' + _GRIP_MID + '%;height:8px']);
    }
    for (const [edge, side] of [[3, 'left'], [4, 'right']]) {
        g.push([edge, 'ew-resize', side + ':0;top:' + c + ';height:calc(' + lo + '% - ' + c + ');width:4px'], [edge, 'ew-resize', side + ':0;top:' + hi + '%;height:calc(' + lo + '% - ' + c + ');width:4px'],
               [_GRIP_MOVE, 'move', side + ':0;top:' + lo + '%;height:' + _GRIP_MID + '%;width:8px']);
    }
    return g;
})();
function _winGrips(on) {
    let box = document.getElementById('ck-resize-grips');
    if (!on) { if (box) box.remove(); return; }
    if (box) return;
    box = document.createElement('div'); box.id = 'ck-resize-grips';
    for (const [edge, cur, pos] of _RESIZE_GRIPS) {
        const g = document.createElement('div'); g.className = 'ck-rz'; g.dataset.edge = edge;
        g.style.cssText = 'position:fixed;z-index:2147483000;background:transparent;cursor:' + cur + ';' + pos;
        g.addEventListener('mousedown', (e) => {
            if (e.button !== 0) return; e.preventDefault(); e.stopPropagation();
            (edge === _GRIP_MOVE ? shellCall('win_drag') : shellCall('win_resize', { edge: edge })).catch(() => {});
        });
        box.appendChild(g);
    }
    document.body.appendChild(box);
}
function winMinimize() { shellCall('win_minimize').catch(() => {}); }
function winMaximize() { shellCall('win_maximize').catch(() => {}); }
(function () {
    if (!_inShell) return;
    document.addEventListener('DOMContentLoaded', () => {
        shellCall('win_state').then(s => { _winButtons(!!(s && s.frameless)); _winRow(s); }).catch(() => {});
        const bar = document.querySelector('.topbar'); if (!bar) return;
        // Empty header space only — never a button, input, select or the cards' controls.
        const inert = (t) => !t.closest('button, input, select, textarea, a, [contenteditable], .agent-card, #win-controls, .material-symbols-rounded, label');
        // Double-click on empty header space maximises. Moving the window is done with the move handles on the border (_winGrips), not by dragging the header.
        bar.addEventListener('dblclick', (e) => {
            if (!document.body.classList.contains('frameless') || !inert(e.target)) return;
            winMaximize(); e.preventDefault();
        });
    });
})();

// =============================================================================
// Minimised windows in the status bar (native window only). Each Cockpit Browser window lists itself in a small file; the shell hands the minimised ones over
// (win_list) and obeys win_cmd restore / close. A chip: click restores, right-click opens Restore / Close, hover says what the window is.
// =============================================================================
let _minWinsKey = '';
function _minWinsMenu(ev, w) {
    ev.preventDefault(); ev.stopPropagation(); _minWinsMenuClose();
    const m = document.createElement('div'); m.id = 'min-wins-menu';
    m.style.cssText = 'position:fixed;z-index:2147483000;min-width:150px;padding:4px;border-radius:6px;background:var(--bg-elevated,var(--bg-base));border:1px solid var(--border-dim);box-shadow:0 6px 22px rgba(0,0,0,.45);font-size:12px;color:var(--text-primary);';
    const item = (icon, label, act) => {
        const b = document.createElement('div'); b.style.cssText = 'display:flex;align-items:center;gap:8px;padding:5px 9px;border-radius:4px;cursor:pointer;';
        b.innerHTML = '<span class="material-symbols-rounded" style="font-size:15px;">' + icon + '</span><span></span>'; b.lastChild.textContent = label;
        b.onmouseenter = () => { b.style.background = 'var(--bg-hover,rgba(127,127,127,.2))'; }; b.onmouseleave = () => { b.style.background = ''; };
        b.onclick = () => { _minWinsMenuClose(); shellCall('win_cmd', { pid: w.pid, action: act }).then(_minWinsPoll).catch(() => {}); };
        m.appendChild(b);
    };
    item('open_in_full', T('ui.minwin.restore', 'Restore'), 'restore');
    item('close', T('ui.minwin.close', 'Close window'), 'close');
    m.addEventListener('mousedown', (e) => e.stopPropagation());   // the click on a row must land before the outside-click closer sees anything
    document.body.appendChild(m);
    m.style.left = Math.max(4, Math.min(ev.clientX, innerWidth - m.offsetWidth - 4)) + 'px';
    m.style.top = Math.max(4, ev.clientY - m.offsetHeight - 4) + 'px';   // the bar is at the bottom: open upward
    setTimeout(() => { document.addEventListener('mousedown', _minWinsMenuClose, { once: true }); document.addEventListener('keydown', _minWinsMenuClose, { once: true }); }, 0);
}
function _minWinsMenuClose() { const m = document.getElementById('min-wins-menu'); if (m) m.remove(); }
function _minWinsRender(wins) {
    const box = document.getElementById('status-bar-wins'); if (!box) return;
    const key = JSON.stringify(wins.map(w => [w.pid, w.title, w.url]));
    if (key === _minWinsKey) return; _minWinsKey = key;
    box.textContent = ''; box.style.display = wins.length ? 'flex' : 'none';
    for (const w of wins) {
        const name = (w.title || '').trim() || (w.url || '').replace(/^https?:\/\//, '') || 'Cockpit Browser';
        const b = document.createElement('button'); b.type = 'button'; b.className = 'min-win-chip';
        b.style.cssText = 'display:inline-flex;align-items:center;gap:4px;max-width:190px;padding:1px 7px;font-size:10.5px;border-radius:10px;cursor:pointer;color:var(--text-primary);background:var(--bg-hover,rgba(127,127,127,.15));border:1px solid var(--border-dim);';
        b.innerHTML = '<span class="material-symbols-rounded" style="font-size:13px;">tab</span><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"></span>';
        b.lastChild.textContent = name;
        b.title = T('ui.minwin.tip', 'Minimised Cockpit Browser window: {name}', { name }) + (w.url ? '\n' + w.url : '') + '\n' + T('ui.minwin.hint', 'Click to restore it, right-click for more.');
        b.onclick = () => shellCall('win_cmd', { pid: w.pid, action: 'restore' }).then(_minWinsPoll).catch(() => {});
        b.oncontextmenu = (ev) => _minWinsMenu(ev, w);
        box.appendChild(b);
    }
}
function _minWinsPoll() { return shellCall('win_list').then(r => _minWinsRender((r && r.wins) || [])).catch(() => {}); }
(function () {
    if (!_inShell) return;
    setInterval(() => { if (!document.hidden) _minWinsPoll(); }, 500);
})();