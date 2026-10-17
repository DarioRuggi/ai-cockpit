// =============================================================================
// The prompt draft: what you have typed and not sent survives a reload, a crash or a switch of chat (2026-10-18, slice 9: a
// half-typed prompt was lost on reload). One draft per chat, in this browser; it is removed when the box is emptied (a send empties it).
// =============================================================================
const _draftKey = () => 'cockpit_draft_' + ((typeof currentProject !== 'undefined' && currentProject) || '_') + '__' + ((typeof currentChat !== 'undefined' && currentChat) || 'default');
let _draftT = 0;
promptInput.addEventListener('input', () => {
    clearTimeout(_draftT);
    const k = _draftKey();                          // the chat it was typed in, not the one open when the timer fires
    _draftT = setTimeout(() => { try { const v = promptInput.value; if (v.trim()) localStorage.setItem(k, v); else localStorage.removeItem(k); } catch (e) {} }, 400);
});
function promptDraftRestore() {                    // only into an EMPTY box: never over something being typed
    try { if (promptInput.value) return; const v = localStorage.getItem(_draftKey()); if (v) { promptInput.value = v; promptInput.dispatchEvent(new Event('input')); } } catch (e) {}
}
setTimeout(promptDraftRestore, 2500);               // after the chat has loaded

// =============================================================================
// Keyboard shortcuts
// =============================================================================
promptInput.addEventListener('keydown', e => {
    // Enter sends; Ctrl+Enter and Shift+Enter insert a newline (2026-09-13,
    // was the other way round). IME composition Enter is left alone.
    if (e.key === 'Enter' && !e.isComposing) {
        if (e.ctrlKey || e.shiftKey || e.metaKey) {
            e.preventDefault();
            const a = promptInput.selectionStart, b = promptInput.selectionEnd, v = promptInput.value;
            promptInput.value = v.slice(0, a) + '\n' + v.slice(b);
            promptInput.selectionStart = promptInput.selectionEnd = a + 1;
            promptInput.dispatchEvent(new Event('input'));
            return;
        }
        if (!e.altKey) { e.preventDefault(); sendPrompt(); return; }
    }
    if (e.key === 'Escape') { cancelPrompt(); return; }

    // ── Shell-style history navigation ────────────────────────────────────
    // Up at first line → previous prompt; Down at last line → next prompt
    // (or restore live draft when stepping past the newest entry).
    // Ignores modifier-combos so Shift+Up/Down still selects text.
    if ((e.key === 'ArrowUp' || e.key === 'ArrowDown')
        && !e.shiftKey && !e.ctrlKey && !e.altKey && !e.metaKey) {

        if (e.key === 'ArrowUp' && _promptCaretOnFirstLine(promptInput)) {
            const text = PromptHistory.prev(promptInput.value);
            if (text !== null) {
                e.preventDefault();
                promptInput.value = text;
                // Move caret to end so further Up presses keep walking back
                const end = text.length;
                promptInput.setSelectionRange(end, end);
            }
        } else if (e.key === 'ArrowDown' && _promptCaretOnLastLine(promptInput)) {
            const text = PromptHistory.next();
            if (text !== null) {
                e.preventDefault();
                promptInput.value = text;
                const end = text.length;
                promptInput.setSelectionRange(end, end);
            }
        }
    }
});
document.addEventListener('keydown', e => {
    if (e.ctrlKey && e.key === 'f') {
        e.preventDefault();
        document.getElementById('search-input').focus();
        document.getElementById('search-input').select();
    }
    // Esc clears search highlights and blurs the search input
    if (e.key === 'Escape' && document.activeElement === document.getElementById('search-input')) {
        clearSearchHighlights();
        document.getElementById('search-input').value = '';
        document.getElementById('search-count').textContent = '';
        searchMatches = [];
        searchCurrent = -1;
        document.getElementById('search-input').blur();
    }
});

// =============================================================================
// 1. Init spinner — hide after status check completes
// =============================================================================
function hideInitSpinner() {
    const sp = document.getElementById('init-spinner');
    if (sp) {
        sp.style.animation = 'none';
        sp.innerHTML = '<span class="material-symbols-rounded ico">check</span>';
        sp.style.color = 'var(--gemini)';
        setTimeout(() => {
            const wrap = sp.parentElement?.parentElement?.parentElement;
            if (wrap) wrap.style.opacity = '0.5';
        }, 1500);
    }
}

// =============================================================================
// 5. Sidebar resize
// =============================================================================
let resizing = null;
let resizeStartX = 0;
let resizeStartW = 0;

// Resize hint label: a small badge that follows the cursor while dragging a
// panel or the proposals pane, showing the live dimension in pixels. Helps the
// owner dial in exact sizes at a glance.
function _showResizeHint(label, clientX, clientY) {
    let hint = document.getElementById('resize-width-hint');
    if (!hint) {
        hint = document.createElement('div');
        hint.id = 'resize-width-hint';
        hint.style.cssText = 'position:fixed;z-index:99999;pointer-events:none;'
            + 'background:var(--gemini,#4a90e2);color:#fff;font-family:var(--font-mono,monospace);'
            + 'font-size:12px;font-weight:700;padding:3px 8px;border-radius:4px;'
            + 'box-shadow:0 2px 8px rgba(0,0,0,0.4);white-space:nowrap;';
        document.body.appendChild(hint);
    }
    hint.textContent = label;
    hint.style.left = (clientX + 14) + 'px';
    hint.style.top  = (clientY + 14) + 'px';
    hint.style.display = 'block';
}
function _hideResizeHint() {
    const hint = document.getElementById('resize-width-hint');
    if (hint) hint.style.display = 'none';
}

function startResize(e, side) {
    resizing    = side;
    resizeStartX = e.clientX;
    resizeStartW = document.getElementById('sidebar-' + side).offsetWidth;
    document.getElementById('resize-' + side).classList.add('dragging');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
    _showResizeHint(side + ' panel: ' + resizeStartW + 'px', e.clientX, e.clientY);
    e.preventDefault();
}

document.addEventListener('mousemove', e => {
    if (!resizing) return;
    const sidebar = document.getElementById('sidebar-' + resizing);
    const delta   = resizing === 'left'
        ? e.clientX - resizeStartX
        : resizeStartX - e.clientX;
    const lim   = resizing === 'left' ? { min: 268, max: 370 } : { min: 334, max: 370 };
    const newW  = Math.max(lim.min, Math.min(lim.max, resizeStartW + delta));
    sidebar.style.width = newW + 'px';
    _showResizeHint(resizing + ' panel: ' + newW + 'px', e.clientX, e.clientY);
});

document.addEventListener('mouseup', () => {
    if (!resizing) return;
    document.getElementById('resize-' + resizing).classList.remove('dragging');
    document.body.style.cursor = '';
    document.body.style.userSelect = '';
    _hideResizeHint();
    resizing = null;
});

// =============================================================================
// 6. Update path in statusbar
// =============================================================================
function updateStatusbarPath(project, chat) {
    const el = document.getElementById('statusbar-path');
    if (el) { el.textContent = '/' + (project || 'default') + '/chat_' + (chat || 'default') + '.json'; el.title = el.textContent; }
    const pn = document.getElementById('project-name');
    if (pn) { pn.textContent = project || 'default'; pn.title = pn.textContent; }   // long names are cut with an ellipsis (css/topbar.css); the tooltip has the whole name
    const cn = document.getElementById('chat-name');
    if (cn) { cn.textContent = chat || 'default'; cn.title = cn.textContent; }
    // Third segment = working dir for the active project (was a static bare "/"
    // because setWorkDir only ran once at init with the root). Show the
    // project-relative folder so it stays meaningful as chats switch.
    const wd = document.getElementById('work-dir');
    if (wd) wd.textContent = '/' + (project || 'default');
    projectGoalShow(project, chat || 'default');
    projectKindShow(project, chat || 'default');
    projectDescShow(project, chat || 'default');
}

// ── Project goal and kind ───────────────────────────────────────────────────
// Scope (2026-10-06): the KIND belongs to the PROJECT (every chat in it inherits it); the GOAL belongs to the CHAT (stored in
// <project>/.chat_meta/<chat>.json; a project's older goal is shown as the default for a chat that has none). A free chat has no
// project to hold a kind, so it keeps both of its own. agent_loop.sh sends the goal and the kind note with every prompt.
//
// The chips used to paint "General" and "+ goal" first and the real values a moment later. They now stay hidden until the values are
// known (one request answers both), and a late answer for a chat you have already left is dropped.
window._ckEff = window._ckEff || {};            // "project/chat" -> {goal, goal_inherited, kind, kind_name, kind_note}
const _ckInflight = {};
let _ckSeqGoal = 0, _ckSeqKind = 0, _ckSeqDesc = 0;     // the newest request wins; an older one that finishes late is dropped
function _ckCur() { return { p: (typeof currentProject === 'string' && currentProject) ? currentProject : '_standalone',
                              c: (typeof currentChat === 'string' && currentChat) ? currentChat : 'default' }; }
function _ckIsFree(p) { return p === '_standalone' || p === 'default' || p === ''; }
async function chatMetaGet(project, chat) {
    const p = _ckIsFree(project) ? '_standalone' : project, c = chat || 'default', key = p + '/' + c;
    if (window._ckEff[key]) return window._ckEff[key];
    if (!_ckInflight[key]) {
        _ckInflight[key] = (async () => {
            try {
                const d = await (await fetch('files.php?action=project_meta&project=' + encodeURIComponent(p) + '&chat=' + encodeURIComponent(c))).json();
                if (d && d.ok && d.effective) window._ckEff[key] = d.effective;
            } catch (e) {}
            delete _ckInflight[key];
            return window._ckEff[key] || null;
        })();
    }
    return _ckInflight[key];
}
function _ckForget(project, chat) {             // drop cached values: one chat, or (no chat) every chat of the project
    const p = _ckIsFree(project) ? '_standalone' : project;
    Object.keys(window._ckEff).forEach(k => { if (chat ? k === p + '/' + chat : k.indexOf(p + '/') === 0) delete window._ckEff[k]; });
}
async function projectGoalShow(project, chat) {
    const el = document.getElementById('project-goal');
    if (!el) return;
    const cur = _ckCur(), p = project || cur.p, c = chat || cur.c;
    const my = ++_ckSeqGoal;
    const eff = window._ckEff[(_ckIsFree(p) ? '_standalone' : p) + '/' + c] || (el.style.visibility = 'hidden', await chatMetaGet(p, c));
    if (my !== _ckSeqGoal) return;                                      // you moved to another chat while this was loading
    const goal = (eff && eff.goal) || '';
    el.textContent = goal ? ('“' + goal.slice(0, 90) + (goal.length > 90 ? '…' : '') + '”') : '+ goal';
    el.title = goal ? ('Goal of this chat — prepended to every prompt in it. Click to edit.' + (eff.goal_inherited ? ' (Inherited from the project; saving here sets this chat\'s own.)' : '') + '\n\n' + goal)
                    : 'No goal for this chat yet. Click to write one sentence saying what this chat is for; every agent in it gets that line.';
    el.classList.toggle('empty', !goal);
    el.style.visibility = '';
}
// ── Description (2026-10-06) ─────────────────────────────────────────────────
// The person's own note on what a chat or a project is for, or what it achieved: for the many-chats, many-projects case, where names
// stop being enough. Shown as a second line in the Chats and Projects lists and searchable there. It is NOT sent to the agent unless
// "also send to the agent" is switched on, separately for the chat and for the project.
async function projectDescShow(project, chat) {
    const el = document.getElementById('project-desc');
    if (!el) return;
    const cur = _ckCur(), p = project || cur.p, c = chat || cur.c;
    const my = ++_ckSeqDesc;
    const eff = window._ckEff[(_ckIsFree(p) ? '_standalone' : p) + '/' + c] || (el.style.visibility = 'hidden', await chatMetaGet(p, c));
    if (my !== _ckSeqDesc) return;
    const own = (eff && eff.description) || '', proj = (eff && eff.project_description) || '';
    const text = own || proj;
    el.textContent = text ? text.slice(0, 40) + (text.length > 40 ? '…' : '') : T('desc.add', '+ note');
    el.title = text ? ((own ? T('desc.tip.chat', 'Description of this chat') : T('desc.tip.project', 'Description of the project (this chat has none)')) + (((own ? eff.desc_send : eff.project_desc_send)) ? ' — also sent to the agent' : ' — only for you') + '\n\n' + text + '\n\n' + T('desc.tip.click', 'Click to edit.'))
                     : T('desc.tip.empty', 'No description yet. Click to write a note for yourself about what this chat (or project) is for or what it achieved.');
    el.classList.toggle('empty', !text);
    el.style.visibility = '';
}
async function projectDescEdit() {
    const cc = _ckCur(), p = cc.p, ch = cc.c, free = _ckIsFree(p);
    const eff = (await chatMetaGet(p, ch)) || {};
    document.getElementById('desc-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'desc-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
    const block = (id, title, val, send) =>
        '<div style="margin-bottom:12px;"><div style="font-size:12px;font-weight:700;margin-bottom:3px;">' + escHtml(title) + '</div>' +
        '<textarea id="' + id + '" maxlength="300" rows="3" style="width:100%;box-sizing:border-box;font-size:12px;padding:5px 7px;background:var(--bg-active);color:var(--text-primary);border:1px solid var(--border-mid);border-radius:4px;resize:vertical;font-family:var(--font-ui);">' + escHtml(val) + '</textarea>' +
        '<label style="display:flex;gap:6px;align-items:center;font-size:11px;color:var(--text-dim);margin-top:3px;cursor:pointer;"><input type="checkbox" id="' + id + '-send"' + (send ? ' checked' : '') + '> ' + escHtml(T('desc.send', 'Also send this to the agent with every prompt')) + '</label></div>';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(520px,94vw);max-height:90vh;overflow:auto;padding:18px;color:var(--text-primary);">' +
        '<h2 style="margin:0 0 4px;font-size:14px;">' + escHtml(T('desc.title', 'Description')) + '</h2>' +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-bottom:10px;">' + escHtml(T('desc.hint', 'Your own note, up to 300 characters. It is shown under the name in the lists and can be searched there. Agents only see it where you tick the box.')) + '</div>' +
        block('desc-chat', free ? T('desc.this.free', 'This free chat — ') + ch : T('desc.this.chat', 'This chat — ') + ch, eff.description || '', !!eff.desc_send) +
        (free ? '' : block('desc-proj', T('desc.this.project', 'This project — ') + p, eff.project_description || '', !!eff.project_desc_send)) +
        '<div style="display:flex;gap:8px;justify-content:flex-end;"><button class="action-btn" id="desc-cancel" style="padding:4px 11px;font-size:11px;">' + escHtml(T('kind.cancel', 'Cancel')) + '</button>' +
        '<button class="action-btn" id="desc-save" style="padding:4px 11px;font-size:11px;background:var(--accent-blue);color:#fff;">' + escHtml(T('kind.save', 'Save')) + '</button></div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    ov.querySelector('#desc-cancel').onclick = () => ov.remove();
    ov.querySelector('#desc-chat').focus();
    ov.querySelector('#desc-save').onclick = async () => {
        const post = body => fetch('files.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Object.assign({ action: 'set_project_meta', project: p }, body)) }).then(r => r.json());
        try {
            const d1 = await post({ chat: ch, description: ov.querySelector('#desc-chat').value, desc_send: ov.querySelector('#desc-chat-send').checked });
            let d2 = { ok: true };
            if (!free) d2 = await post({ description: ov.querySelector('#desc-proj').value, desc_send: ov.querySelector('#desc-proj-send').checked });
            if (!d1.ok || !d2.ok) { appendSystem(T('desc.save.failed', 'Could not save the description: {error}', { error: d1.error || d2.error || 'unknown' })); return; }
            _ckForget(p, '');                                            // the project's text is shared by every chat of it
            ov.remove(); projectDescShow(p, ch);
            try { loadChats(); } catch (e) {} try { loadProjects(); } catch (e) {}
            appendSystem(T('desc.saved', 'Description saved.'));
        } catch (e) { appendSystem(T('desc.save.failed', 'Could not save the description: {error}', { error: e.message })); }
    };
}
// ── Project kind ────────────────────────────────────────────────────────────────
// What the project IS. The kind's one-paragraph note rides on every prompt beside the goal; later it will also
// choose the checker and the knowledge pack. Stored in .cockpit_project.json (kind, kind_name, kind_note); a free chat keeps its own.
window._projectKind = window._projectKind || {};
let _kindList = null;
// Only a list that really loaded is kept. This used to cache whatever the first request answered, so one early call made
// before the session was confirmed ("Authentication required") left the list EMPTY for the rest of the page's life: the
// chip showed the raw id and the picker opened with nothing to pick (seen 2026-10-05).
async function projectKindList() {
    if (_kindList && _kindList.length) return _kindList;
    try {
        const d = await (await fetch('files.php?action=kinds')).json();
        if (d && d.ok && Array.isArray(d.kinds) && d.kinds.length) _kindList = d.kinds;
    } catch (e) {}
    return _kindList || [];
}
async function projectKindShow(project, chat) {
    const el = document.getElementById('project-kind');
    if (!el) return;
    const cur = _ckCur(), p = project || cur.p, c = chat || cur.c;
    const my = ++_ckSeqKind;
    const eff = window._ckEff[(_ckIsFree(p) ? '_standalone' : p) + '/' + c] || (el.style.visibility = 'hidden', await chatMetaGet(p, c));
    const list = await projectKindList();
    if (my !== _ckSeqKind) return;
    const k = (eff && eff.kind) || 'general';
    const info = list.find(x => x.id === k) || { name: (eff && eff.kind_name) || k, icon: 'folder' };
    el.innerHTML = '<span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">' + escHtml(info.icon || 'folder') + '</span> ' + escHtml(info.name);
    el.title = _ckIsFree(p) ? T('kind.tip.free', 'Kind of this chat: {name}. Its standing note is sent with every prompt in this chat. Click to change.', { name: info.name })
                            : T('kind.tip', 'Project kind: {name}. Its standing note is sent with every prompt in this project. Click to change.', { name: info.name });
    el.style.display = ''; el.style.visibility = '';
}
// The order of the fields in the picker; any other group (your own) follows alphabetically, "My kinds" last.
const _KIND_GROUP_ORDER = ['General', 'Writing & documents', 'Home & life', 'Work & community', 'Media', 'Research & learning', 'Data & numbers', 'Software & games', 'Hardware & making', 'System & servers'];
function _kindGroups(list) {
    const by = {};
    list.forEach(k => { const g = k.group || (k.source === 'user' ? 'My kinds' : 'Other'); (by[g] = by[g] || []).push(k); });
    const rank = g => { const i = _KIND_GROUP_ORDER.indexOf(g); return i >= 0 ? i : (g === 'My kinds' ? 9998 : (g === 'Other' ? 9999 : 100)); };
    return Object.keys(by).sort((a, b) => rank(a) - rank(b) || a.localeCompare(b)).map(g => ({ name: g, kinds: by[g].sort((a, b) => (a.id === 'general' ? -1 : b.id === 'general' ? 1 : a.name.localeCompare(b.name))) }));
}
function _kindMatches(k, q) {
    if (!q) return true; q = q.toLowerCase();
    return [k.name, k.description, k.details, k.group, (k.examples || []).join(' ')].join(' ').toLowerCase().includes(q);
}
async function projectKindEdit() {
    const cc = _ckCur(), p = cc.p, ch = cc.c;
    const list = await projectKindList(); const effNow = await chatMetaGet(p, ch); const cur = (effNow && effNow.kind) || 'general';
    if (!list.length) { appendSystem(T('kind.list.failed', 'Could not load the list of project kinds — are you signed in? Try again in a moment.')); return; }
    projectKindShow(p, ch);                               // the chip may have been drawn before the list was available: redraw it with the real name
    let sug = null; try { sug = (await (await fetch('files.php?action=detect_kind&project=' + encodeURIComponent(p))).json()).suggest; } catch (e) {}
    let collapsed = []; try { collapsed = JSON.parse(localStorage.getItem('ck.kind.collapsed') || '[]'); } catch (e) {}
    let sel = cur; if (!list.find(k => k.id === sel)) sel = 'general';
    document.getElementById('kind-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'kind-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(900px,96vw);height:min(660px,90vh);display:flex;flex-direction:column;padding:14px 16px;color:var(--text-primary);">' +
        '<div style="display:flex;align-items:baseline;gap:10px;flex-wrap:wrap;"><h2 style="margin:0;font-size:14px;">' + escHtml(T('kind.title', 'Project kind')) + ' — ' + escHtml(p) + '</h2>' +
        '<span style="font-size:10.5px;color:var(--text-dim);flex:1;min-width:200px;">' + escHtml(T('kind.hint', 'A kind tells every agent in this project what it is working on, with a short standing note sent beside the goal.')) + '</span></div>' +
        (sug && sug.kind !== cur ? '<div style="font-size:11px;background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;padding:5px 8px;margin-top:6px;">💡 ' + escHtml(T('kind.detected', 'This project has {file}: it looks like "{name}".', { file: sug.found, name: sug.name })) + '</div>' : '') +
        '<div style="display:grid;grid-template-columns:minmax(220px,300px) 1fr;gap:12px;flex:1;min-height:0;margin-top:8px;">' +
        '<div style="display:flex;flex-direction:column;min-height:0;border:1px solid var(--border-dim);border-radius:5px;"><input id="kind-q" placeholder="' + escHtml(T('kind.search', 'Search kinds…')) + '" style="border:0;border-bottom:1px solid var(--border-dim);background:var(--bg-darker);color:var(--text-base);padding:6px 8px;font-size:12px;border-radius:5px 5px 0 0;">' +
        '<div id="kind-list" style="overflow:auto;flex:1;padding:4px 0;"></div></div>' +
        '<div id="kind-detail" style="overflow:auto;border:1px solid var(--border-dim);border-radius:5px;padding:12px 14px;font-size:12px;line-height:1.5;"></div></div>' +
        '<div id="kind-foot" style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px;flex-wrap:wrap;">' +
        '<button class="action-btn" id="kind-new" type="button" style="padding:4px 11px;font-size:11px;">+ ' + escHtml(T('kind.new', 'New kind…')) + '</button>' +
        '<button class="action-btn" id="kind-export" type="button" style="padding:4px 11px;font-size:11px;" title="' + escHtml(T('kind.export.tip', 'Save the selected kind as a .kind.json file (any kind, shipped ones too)')) + '">' + escHtml(T('kind.export.btn', 'Export')) + '</button>' +
        '<button class="action-btn" id="kind-import" type="button" style="padding:4px 11px;font-size:11px;margin-right:auto;">' + escHtml(T('kind.import', 'Import…')) + '</button>' +
        '<button class="action-btn" id="kind-cancel" style="padding:4px 11px;font-size:11px;">' + escHtml(T('kind.cancel', 'Cancel')) + '</button>' +
        '<button class="action-btn" id="kind-save" style="padding:4px 11px;font-size:11px;background:var(--accent-blue);color:#fff;">' + escHtml(T('kind.save', 'Save')) + '</button></div></div>';
    document.body.appendChild(ov);
    const $ = s => ov.querySelector(s); const listEl = $('#kind-list'), detEl = $('#kind-detail'), qEl = $('#kind-q');
    const saveCollapsed = () => { try { localStorage.setItem('ck.kind.collapsed', JSON.stringify(collapsed)); } catch (e) {} };

    function renderList() {
        const q = qEl.value.trim(), groups = _kindGroups(list); let html = '';
        groups.forEach(g => {
            const ks = g.kinds.filter(k => _kindMatches(k, q)); if (!ks.length) return;
            const open = q !== '' || !collapsed.includes(g.name) || ks.some(k => k.id === sel);
            html += '<div class="kg-head" data-g="' + escHtml(g.name) + '" style="display:flex;align-items:center;gap:5px;padding:5px 8px;cursor:pointer;font-size:10.5px;letter-spacing:.04em;text-transform:uppercase;color:var(--text-muted);user-select:none;">' +
                '<span class="material-symbols-rounded" style="font-size:15px;">' + (open ? 'expand_more' : 'chevron_right') + '</span><span style="flex:1;">' + escHtml(g.name) + '</span><span>' + ks.length + '</span></div>';
            if (open) ks.forEach(k => {
                const isSel = k.id === sel;
                html += '<div class="kg-row" data-id="' + escHtml(k.id) + '" style="display:flex;align-items:center;gap:7px;padding:5px 8px 5px 24px;cursor:pointer;' + (isSel ? 'background:var(--bg-card);border-left:2px solid var(--accent-blue);padding-left:22px;' : '') + '">' +
                    '<span class="material-symbols-rounded" style="font-size:15px;color:var(--text-muted);">' + escHtml(k.icon || 'folder') + '</span><span style="flex:1;font-size:12px;' + (isSel ? 'font-weight:600;' : '') + '">' + escHtml(k.name) + '</span>' +
                    (k.id === cur ? '<span title="' + escHtml(T('kind.current', 'the current kind of this project')) + '" class="material-symbols-rounded" style="font-size:14px;color:var(--accent-green);">check_circle</span>' : '') +
                    (sug && sug.kind === k.id && k.id !== cur ? '<span title="' + escHtml(T('kind.suggested', 'suggested for this project')) + '" style="font-size:11px;">💡</span>' : '') +
                    (k.source === 'user' ? '<span style="font-size:9px;border:1px solid var(--border-bright);border-radius:3px;padding:0 4px;color:var(--text-muted);">' + escHtml(T('kind.mine', 'yours')) + '</span>' : '') + '</div>';
            });
        });
        listEl.innerHTML = html || '<div style="padding:12px;font-size:11px;color:var(--text-muted);">' + escHtml(T('kind.nomatch', 'No kind matches.')) + '</div>';
    }
    function renderDetail() {
        const k = list.find(x => x.id === sel); if (!k) { detEl.innerHTML = ''; return; }
        const sec = (t, body) => body ? '<div style="margin-top:12px;"><div style="font-size:10px;letter-spacing:.05em;text-transform:uppercase;color:var(--text-muted);margin-bottom:3px;">' + escHtml(t) + '</div>' + body + '</div>' : '';
        let h = '<div style="display:flex;align-items:center;gap:8px;"><span class="material-symbols-rounded" style="font-size:22px;">' + escHtml(k.icon || 'folder') + '</span><span style="font-size:16px;font-weight:600;flex:1;">' + escHtml(k.name) + '</span>' +
            (k.id === cur ? '<span style="font-size:10px;color:var(--accent-green);">✓ ' + escHtml(T('kind.current.short', 'current')) + '</span>' : '') +
            (k.source === 'user' ? '<span style="font-size:10px;border:1px solid var(--border-bright);border-radius:3px;padding:0 5px;color:var(--text-muted);">' + escHtml(k.overrides ? T('kind.mine.over', 'yours · replaces the shipped one') : T('kind.mine', 'yours')) + '</span>' : '') + '</div>' +
            '<div style="color:var(--text-muted);margin-top:2px;">' + escHtml(k.description || '') + '</div>';
        h += sec(T('kind.about', 'About this kind'), k.details ? '<div>' + escHtml(k.details) + '</div>' : '<div style="color:var(--text-muted);">' + escHtml(k.source === 'user' ? T('kind.nodetails', 'No longer explanation yet: add one with Edit.') : '') + '</div>');
        h += sec(T('kind.examples', 'Examples'), (k.examples && k.examples.length) ? '<ul style="margin:0;padding-left:18px;">' + k.examples.map(e => '<li>' + escHtml(e) + '</li>').join('') + '</ul>' : '');
        h += sec(T('kind.judge.h', 'Judged by'), k.verify ? '<div>' + escHtml(k.verify) + '</div>' : '');
        h += sec(T('kind.detect.h', 'Recognised by these files'), (k.detect && k.detect.length) ? '<code style="font-family:var(--font-mono);font-size:11px;">' + k.detect.map(escHtml).join('  ') + '</code>' : '');
        h += sec(T('kind.needs', 'Tools'), (k.tools && k.tools.length) ? k.tools.map(t => '<div><span style="color:' + (t.installed ? 'var(--accent-green)' : 'var(--accent-orange)') + ';">' + (t.installed ? '✓' : '✗') + '</span> <b>' + escHtml(t.name || t.tool) + '</b>' +
            (t.why ? ' <span style="color:var(--text-muted);">— ' + escHtml(t.why) + '</span>' : '') + (!t.installed && t.hint ? '<div style="font-size:10.5px;color:var(--text-muted);padding-left:16px;">' + escHtml(t.hint) + '</div>' : '') + '</div>').join('') : '');
        h += sec(T('kind.starter.h', 'Starter files'), (k.starter && k.starter.length && p && p !== '_standalone') ? '<div><code style="font-family:var(--font-mono);font-size:11px;">' + k.starter.map(escHtml).join('  ') + '</code></div><div style="margin-top:4px;"><a href="#" data-kact="starter" style="color:var(--accent-cyan);">' + escHtml(T('kind.starter.add', 'Add these to this project…')) + '</a> <span style="font-size:10.5px;color:var(--text-muted);">' + escHtml(T('kind.starter.note', 'you see the list first; a file that already exists is never touched')) + '</span></div>' : '');
        if (k.source === 'user') h += '<div style="margin-top:14px;font-size:11px;">' + [['edit', T('kind.edit', 'Edit')], ['copy', T('kind.copy', 'Duplicate')], ['export', T('kind.export', 'Export')], ['delete', k.overrides ? T('kind.restore', 'Use the shipped one again') : T('kind.delete', 'Delete')]]
            .map(a => '<a href="#" data-kact="' + a[0] + '" style="color:var(--accent-cyan);margin-right:12px;">' + escHtml(a[1]) + '</a>').join('') + '</div>';
        else h += '<div style="margin-top:14px;font-size:11px;"><a href="#" data-kact="copy" style="color:var(--accent-cyan);margin-right:12px;">' + escHtml(T('kind.copy.mine', 'Duplicate into my kinds')) + '</a><a href="#" data-kact="export" style="color:var(--accent-cyan);">' + escHtml(T('kind.export', 'Export')) + '</a><div style="margin-top:6px;font-size:10.5px;color:var(--text-muted);">' + escHtml(T('kind.shipped.note', 'A shipped kind: it is replaced by updates. To change it, duplicate it into your own kinds, or export it, edit the file and import it back (yours then replaces it for you).')) + '</div></div>';
        detEl.innerHTML = h;
    }
    function select(id) { sel = id; renderList(); renderDetail(); }
    listEl.addEventListener('click', e => {
        const head = e.target.closest('.kg-head'), row = e.target.closest('.kg-row');
        if (head) { const g = head.dataset.g; collapsed = collapsed.includes(g) ? collapsed.filter(x => x !== g) : collapsed.concat(g); saveCollapsed(); renderList(); }
        else if (row) select(row.dataset.id);
    });
    listEl.addEventListener('dblclick', e => { if (e.target.closest('.kg-row')) $('#kind-save').click(); });
    qEl.addEventListener('input', renderList);
    detEl.addEventListener('click', async ev => {
        const a = ev.target.closest('a[data-kact]'); if (!a) return; ev.preventDefault();
        const k = list.find(x => x.id === sel); if (!k) return; const act = a.dataset.kact;
        if (act === 'edit') kindWizard(k, true);
        else if (act === 'copy') kindWizard(Object.assign({}, k, { id: '', _src: k.id, name: k.name + ' 2', source: 'new', group: k.group }), false);
        else if (act === 'starter') {
            const call = async confirmIt => (await (await fetch('files.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'kind_starter', id: k.id, project: p, confirm: confirmIt }) })).json());
            const pre = await call(false); if (!pre.ok) { appendSystem(T('kind.err', 'Kinds: {error}', { error: pre.error || 'unknown' })); return; }
            const fresh = pre.files.filter(f => f.status === 'new'), kept = pre.files.filter(f => f.status !== 'new');
            if (!fresh.length) { appendSystem(T('kind.starter.none', 'Nothing to add: every starter file already exists in "{p}".', { p: p })); return; }
            if (!await cconfirm(T('kind.starter.ask', 'Add {n} file(s) to "{p}"?', { n: fresh.length, p: p }) + '\n\n' + fresh.map(f => '+ ' + f.path).join('\n') + (kept.length ? '\n\n' + T('kind.starter.kept', 'Left alone (already there):') + '\n' + kept.map(f => '= ' + f.path).join('\n') : ''))) return;
            const done = await call(true); if (!done.ok) { appendSystem(T('kind.err', 'Kinds: {error}', { error: done.error || 'unknown' })); return; }
            appendSystem(T('kind.starter.done', 'Added {n} starter file(s) to "{p}".', { n: done.files.filter(f => f.status === 'created').length, p: p }));
        }
        else if (act === 'export') kindExport(k.id);
        else if (act === 'delete') {
            if (!await cconfirm(T('kind.delete.ask', 'Delete your kind "{name}"? Projects that use it keep the note they already have.', { name: k.name }))) return;
            const d = await (await fetch('files.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'kind_delete', id: k.id }) })).json();
            if (!d.ok) { appendSystem(T('kind.err', 'Kinds: {error}', { error: d.error || 'unknown' })); return; }
            _kindList = null; ov.remove(); projectKindEdit();
        }
    });
    $('#kind-new').onclick = () => kindWizard(null, false);
    $('#kind-import').onclick = () => kindImportDialog();
    $('#kind-export').onclick = () => kindExport(sel);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    $('#kind-cancel').onclick = () => ov.remove();
    $('#kind-save').onclick = async () => {
        try {
            const d = await (await fetch('files.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'set_project_meta', project: p, chat: ch, kind: sel }) })).json();
            if (!d.ok) { appendSystem(T('kind.save.failed', 'Could not save the kind: {error}', { error: d.error || 'unknown' })); return; }
            _ckForget(p, _ckIsFree(p) ? ch : ''); ov.remove(); projectKindShow(p, ch);
            appendSystem(T('kind.saved', 'Project kind for "{p}" is now {name}. Its note goes with every prompt in the project.', { p: p, name: (d.meta && d.meta.kind_name) || sel }));
        } catch (e) { appendSystem(T('kind.save.failed', 'Could not save the kind: {error}', { error: e.message })); }
    };
    renderList(); renderDetail();
    const selRow = listEl.querySelector('.kg-row[data-id="' + sel + '"]'); if (selRow) selRow.scrollIntoView({ block: 'nearest' });
}
async function kindExport(id) {
    try {
        const d = await (await fetch('files.php?action=kind_export&id=' + encodeURIComponent(id))).json();
        if (!d.ok) { appendSystem(T('kind.err', 'Kinds: {error}', { error: d.error || 'unknown' })); return; }
        const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([JSON.stringify(d.kind, null, 2) + '\n'], { type: 'application/json' }));
        a.download = id + '.kind.json'; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 4000);
    } catch (e) { appendSystem(T('kind.err', 'Kinds: {error}', { error: e.message })); }
}
function kindImportDialog() {
    document.getElementById('kind-imp-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'kind-imp-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10004;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(560px,94vw);padding:16px;color:var(--text-primary);">' +
        '<h2 style="margin:0 0 6px;font-size:14px;">' + escHtml(T('kind.import.title', 'Import a kind')) + '</h2>' +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-bottom:8px;">' + escHtml(T('kind.import.hint', 'Paste the JSON of a kind (a .kind.json file, or what the agent wrote for "Draft with the agent"), or choose the file. Nothing is saved until you press Import; a kind never carries a command line.')) + '</div>' +
        '<textarea id="kimp-text" rows="10" spellcheck="false" style="width:100%;box-sizing:border-box;font:11px/1.4 var(--font-mono);background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:6px;"></textarea>' +
        '<div id="kimp-msg" style="font-size:11px;color:var(--accent-orange);min-height:16px;margin:6px 0;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;"><input type="file" id="kimp-file" accept=".json,application/json" style="margin-right:auto;font-size:11px;">' +
        '<button class="action-btn" id="kimp-cancel" style="padding:4px 11px;font-size:11px;">' + escHtml(T('kind.cancel', 'Cancel')) + '</button>' +
        '<button class="action-btn" id="kimp-go" style="padding:4px 11px;font-size:11px;background:var(--accent-blue);color:#fff;">' + escHtml(T('kind.import.go', 'Import')) + '</button></div></div>';
    document.body.appendChild(ov);
    const msg = ov.querySelector('#kimp-msg'), ta = ov.querySelector('#kimp-text');
    ov.querySelector('#kimp-cancel').onclick = () => ov.remove();
    ov.querySelector('#kimp-file').onchange = async e => { const f = e.target.files[0]; if (f) ta.value = await f.text(); };
    ov.querySelector('#kimp-go').onclick = async () => {
        let txt = ta.value.trim(); const m = txt.match(/\{[\s\S]*\}/); if (m) txt = m[0];       // an agent's answer may have words around the JSON
        const send = async (overwrite, confirmTools) => (await (await fetch('files.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'kind_import', json: txt, overwrite: overwrite, confirm_tools: !!confirmTools }) })).json());
        try {
            let overwriteAsked = false; let d = await send(false);
            if (!d.ok && d.exists) {
                overwriteAsked = true;
                if (!await cconfirm(T('kind.import.exists', 'A kind with the id "{id}" already exists{mine}. Replace it?', { id: d.id, mine: d.mine ? ' (one of yours)' : ' (a shipped one: yours will replace it)' }))) return;
                d = await send(true);
            }
            if (!d.ok && d.needs_confirm_tools) {
                const lines = d.tools.map(t => '• ' + t.name + ' (' + t.binary + ')\n' + t.commands.map(c => '     ' + c).join('\n')).join('\n');
                if (!await cconfirm(T('kind.import.tools', 'This kind carries its own tool(s). They will run these commands on files you give them (nothing runs until you use them):') + '\n\n' + lines + '\n\n' + T('kind.import.tools.ok', 'Install the kind and its tool(s)?'))) return;
                d = await send(!!overwriteAsked, true);
            }
            if (!d.ok) { msg.textContent = d.error || 'not accepted'; return; }
            _kindList = null; ov.remove(); document.getElementById('kind-ov')?.remove(); appendSystem(T('kind.imported', 'Kind "{name}" imported.', { name: d.kind.name })); projectKindEdit();
        } catch (e) { msg.textContent = e.message; }
    };
}
// The wizard's two advanced fields. Pure functions so they can be tested: rows of {path, content} -> the starter list (empty paths dropped, at most 12, a clear message on a bad path),
// and the tools text (JSON: a list of tool definitions) -> the list, or an error. The server checks everything again; this only keeps a typo from reaching it.
function _kwStarter(rows) {
    const out = [];
    for (const r of rows || []) {
        const path = String((r && r.path) || '').trim(), content = String((r && r.content) || '');
        if (!path && !content.trim()) continue;
        if (!path) return { error: T('kind.wiz.starter.nopath', 'A starter file has text but no file name.') };
        if (!/^[A-Za-z0-9_][A-Za-z0-9_. \/-]{0,119}$/.test(path) || path.includes('..') || path.includes('//') || path.endsWith('/')) return { error: T('kind.wiz.starter.badpath', 'Starter file name not accepted: {p} (relative, no "..", letters, digits and . _ - / only)', { p: path.slice(0, 40) }) };
        if (content.length > 20000) return { error: T('kind.wiz.starter.long', 'Starter file {p} is longer than 20000 characters.', { p: path }) };
        out.push({ path: path, content: content });
    }
    if (out.length > 12) return { error: T('kind.wiz.starter.many', 'At most 12 starter files.') };
    return { list: out };
}
function _kwTools(text) {
    const t = String(text || '').trim(); if (!t) return { list: [] };
    let j; try { j = JSON.parse(t); } catch (e) { return { error: T('kind.wiz.tools.json', 'The tools box is not valid JSON: {e}', { e: e.message }) }; }
    if (!Array.isArray(j)) return { error: T('kind.wiz.tools.array', 'The tools box must hold a list: [ { "id": ..., "binary": ..., "presets": [...] } ]') };
    if (j.length > 4) return { error: T('kind.wiz.tools.many', 'At most 4 tools.') };
    return { list: j };
}
async function kindWizard(base, editing) {
    let tl = []; try { tl = (await (await fetch('tools.php?action=tools')).json()).tools || []; } catch (e) {}
    const k = base || {}; const have = {}; (k.tools || []).forEach(t => have[t.tool] = t);
    // the list carries only the starter file NAMES; the contents and the tool definitions come from the kind itself
    let full = {}; const srcId = k._src || (editing ? k.id : ''); if (srcId) { try { const e = await (await fetch('files.php?action=kind_export&id=' + encodeURIComponent(srcId))).json(); if (e.ok && e.kind) full = e.kind; } catch (e) {} }
    const hadTools = !!(full.tool_defs && full.tool_defs.length);
    document.getElementById('kind-wiz-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'kind-wiz-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10003;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
    const fld = (id, label, val, extra) => '<label style="display:block;font-size:10.5px;color:var(--text-dim);margin-top:7px;">' + escHtml(label) + '<input id="' + id + '" value="' + escHtml(val || '') + '" ' + (extra || '') + ' style="display:block;width:100%;box-sizing:border-box;margin-top:2px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:5px 7px;font-size:12px;"></label>';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(600px,95vw);max-height:92vh;overflow:auto;padding:16px;color:var(--text-primary);">' +
        '<h2 style="margin:0 0 2px;font-size:14px;">' + escHtml(editing ? T('kind.wiz.edit', 'Edit your kind') : T('kind.wiz.new', 'New kind')) + '</h2>' +
        '<div style="font-size:10.5px;color:var(--text-dim);">' + escHtml(T('kind.wiz.hint', 'A kind is a standing note sent with every prompt in a project of that kind, plus the tools it uses. It is kept in your own folder; updates never touch it.')) + '</div>' +
        fld('kw-name', T('kind.wiz.name', 'Name'), k.name) + fld('kw-id', T('kind.wiz.id', 'Id (letters, digits, hyphens; the file name)'), k.id, editing ? 'readonly' : '') +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-top:7px;">' + escHtml(T('kind.wiz.icon', 'Icon')) + '</div><div style="margin-top:2px;">' + ckIconFieldHtml('kw-icon', k.icon || 'folder') + '</div>' + fld('kw-desc', T('kind.wiz.desc', 'One line: what this kind of project is'), k.description, 'maxlength="300"') +
        fld('kw-group', T('kind.wiz.group', 'Field it is listed under (pick one or type a new one)'), k.group || '', 'list="kw-groups" maxlength="40"') + '<datalist id="kw-groups">' + _kindGroups(_kindList || []).map(g => '<option value="' + escHtml(g.name) + '">').join('') + '</datalist>' +
        '<label style="display:block;font-size:10.5px;color:var(--text-dim);margin-top:7px;">' + escHtml(T('kind.wiz.note', 'Standing note: how the agent should work on this kind of project (up to 900 characters)')) +
        '<textarea id="kw-note" rows="6" maxlength="900" style="display:block;width:100%;box-sizing:border-box;margin-top:2px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:6px 7px;font-size:12px;">' + escHtml(k.note || '') + '</textarea></label>' +
        '<label style="display:block;font-size:10.5px;color:var(--text-dim);margin-top:7px;">' + escHtml(T('kind.wiz.details', 'Longer explanation (shown in the picker beside the list)')) + '<textarea id="kw-details" rows="4" maxlength="1500" style="display:block;width:100%;box-sizing:border-box;margin-top:2px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:6px 7px;font-size:12px;">' + escHtml(k.details || '') + '</textarea></label>' +
        '<label style="display:block;font-size:10.5px;color:var(--text-dim);margin-top:7px;">' + escHtml(T('kind.wiz.examples', 'Examples, one per line (up to 6)')) + '<textarea id="kw-examples" rows="3" style="display:block;width:100%;box-sizing:border-box;margin-top:2px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:6px 7px;font-size:12px;">' + escHtml((k.examples || []).join('\n')) + '</textarea></label>' +
        fld('kw-detect', T('kind.wiz.detect', 'Recognise it by these file names (comma separated, for example *.srt, *.vtt)'), (k.detect || []).join(', ')) +
        fld('kw-verify', T('kind.wiz.verify', 'What judges the work (a short phrase)'), k.verify, 'maxlength="120"') +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-top:9px;">' + escHtml(T('kind.wiz.tools', 'Tools this kind uses')) + '</div>' +
        '<div id="kw-tools" style="display:grid;grid-template-columns:1fr 1fr;gap:2px 12px;max-height:150px;overflow:auto;border:1px solid var(--border-dim);border-radius:4px;padding:6px;margin-top:2px;">' +
        (tl.length ? tl.map(t => '<label style="font-size:11px;display:flex;gap:5px;align-items:center;"><input type="checkbox" value="' + escHtml(t.id) + '"' + (have[t.id] ? ' checked' : '') + '> ' +
            '<span style="color:' + (t.binary_available ? 'var(--accent-green)' : 'var(--accent-orange)') + ';">' + (t.binary_available ? '✓' : '✗') + '</span> ' + escHtml(t.name || t.id) + '</label>').join('') : '<span style="font-size:11px;color:var(--text-muted);">' + escHtml(T('kind.wiz.notools', 'The tool list is not available right now.')) + '</span>') + '</div>' +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-top:9px;">' + escHtml(T('kind.wiz.starter', 'Starter files (up to 12): offered with "Add these to this project"; a file that already exists is never overwritten')) + '</div>' +
        '<div id="kw-starter" style="margin-top:2px;"></div><button class="action-btn" id="kw-starter-add" type="button" style="padding:3px 9px;font-size:10.5px;margin-top:4px;">+ ' + escHtml(T('kind.wiz.starter.add', 'Add a file')) + '</button>' +
        '<label style="display:block;font-size:10.5px;color:var(--text-dim);margin-top:9px;">' + escHtml(T('kind.wiz.tools.own', 'Tools this kind carries (advanced, JSON; leave empty for none). Plain commands only: the program, arguments and {INPUT} {OUTPUT} {ARGS} {NAME}; you are shown every command and asked before anything is installed')) +
        '<textarea id="kw-tooldefs" rows="5" spellcheck="false" placeholder="[ { &quot;id&quot;: &quot;copykit&quot;, &quot;binary&quot;: &quot;cp&quot;, &quot;presets&quot;: [ { &quot;id&quot;: &quot;dup&quot;, &quot;label&quot;: &quot;Make a copy&quot;, &quot;command&quot;: &quot;cp {INPUT} {OUTPUT}&quot;, &quot;output_ext&quot;: &quot;txt&quot; } ] } ]" style="display:block;width:100%;box-sizing:border-box;margin-top:2px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:6px 7px;font-size:11px;font-family:var(--font-mono);">' + escHtml(hadTools ? JSON.stringify(full.tool_defs, null, 1) : '') + '</textarea></label>' +
        '<div id="kw-msg" style="font-size:11px;color:var(--accent-orange);min-height:16px;margin:8px 0 4px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap;"><button class="action-btn" id="kw-draft" type="button" style="padding:4px 11px;font-size:11px;margin-right:auto;" title="' + escHtml(T('kind.wiz.drafttip', 'Puts a request in the prompt box; the agent writes the kind, then you import it')) + '"><span class="material-symbols-rounded ico">auto_fix_high</span> ' + escHtml(T('kind.wiz.draft', 'Draft with the agent…')) + '</button>' +
        '<button class="action-btn" id="kw-cancel" type="button" style="padding:4px 11px;font-size:11px;">' + escHtml(T('kind.cancel', 'Cancel')) + '</button>' +
        '<button class="action-btn" id="kw-save" type="button" style="padding:4px 11px;font-size:11px;background:var(--accent-blue);color:#fff;">' + escHtml(T('kind.save', 'Save')) + '</button></div></div>';
    document.body.appendChild(ov);
    const $ = s => ov.querySelector(s), msg = $('#kw-msg');
    if (!editing) $('#kw-name').addEventListener('input', () => { if (!$('#kw-id').dataset.touched) $('#kw-id').value = $('#kw-name').value.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40); });
    $('#kw-id').addEventListener('input', () => { $('#kw-id').dataset.touched = '1'; });
    const addStarterRow = (path, content) => {
        const row = document.createElement('div'); row.className = 'kw-srow'; row.style.cssText = 'border:1px solid var(--border-dim);border-radius:4px;padding:5px;margin-top:4px;';
        row.innerHTML = '<div style="display:flex;gap:6px;"><input class="kw-spath" placeholder="' + escHtml(T('kind.wiz.starter.ph', 'file name, e.g. chapters/01.md')) + '" style="flex:1;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:3px;padding:3px 6px;font-size:11px;font-family:var(--font-mono);">' +
            '<button type="button" class="action-btn kw-sdel" style="padding:2px 8px;font-size:11px;" title="' + escHtml(T('kind.wiz.starter.del', 'Remove this file')) + '">×</button></div>' +
            '<textarea class="kw-scontent" rows="3" spellcheck="false" style="display:block;width:100%;box-sizing:border-box;margin-top:4px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:3px;padding:4px 6px;font-size:11px;font-family:var(--font-mono);"></textarea>';
        row.querySelector('.kw-spath').value = path || ''; row.querySelector('.kw-scontent').value = content || '';
        row.querySelector('.kw-sdel').onclick = () => row.remove(); $('#kw-starter').appendChild(row);
    };
    (full.starter || []).forEach(s => addStarterRow(s.path, s.content));
    $('#kw-starter-add').onclick = () => { if (ov.querySelectorAll('.kw-srow').length >= 12) { msg.textContent = T('kind.wiz.starter.many', 'At most 12 starter files.'); return; } addStarterRow('', ''); };
    $('#kw-cancel').onclick = () => ov.remove();
    $('#kw-draft').onclick = async () => {
        const what = await cprompt(T('kind.wiz.draft.ask', 'Describe this kind of project in a sentence:'), $('#kw-desc').value || $('#kw-name').value || '', T('kind.wiz.draft.title', 'Draft a kind'));
        if (!what) return;
        const ids = tl.filter(t => t.binary_available).map(t => t.id).join(', ');
        const ta = document.getElementById('prompt-in'); if (!ta) return;
        ta.value = 'Write the JSON of a Cockpit project kind for: ' + what + '\n\nReply with ONLY one JSON object with these fields: id (lower-case letters, digits and hyphens, at most 40), name (at most 80 characters), icon (a Material Symbols icon name), description (one sentence), note (the standing note sent with every prompt in such a project: 3 to 5 sentences telling an agent how to work, what to check and what judges the result; at most 900 characters), detect (a list of file name patterns that identify such a project, for example ["*.srt"]), verify (a short phrase: what judges the work), tools (a list of {"tool": "<id>"} chosen only from these installed tools: ' + (ids || 'none') + ').';
        ov.remove(); document.getElementById('kind-ov')?.remove(); ta.focus(); if (typeof ta.oninput === 'function') ta.oninput();
        appendSystem(T('kind.wiz.draft.done', 'The request is in the prompt box. Send it, then use "+ New kind…", "Import…" and paste the answer.'));
    };
    $('#kw-save').onclick = async () => {
        const kind = { id: $('#kw-id').value.trim(), name: $('#kw-name').value.trim(), icon: $('#kw-icon').value.trim() || 'folder', description: $('#kw-desc').value.trim(), note: $('#kw-note').value.trim(), group: $('#kw-group').value.trim(), details: $('#kw-details').value.trim(), examples: $('#kw-examples').value.split('\n').map(s => s.trim()).filter(Boolean),
            detect: $('#kw-detect').value.split(',').map(s => s.trim()).filter(Boolean), verify: $('#kw-verify').value.trim(),
            tools: [...ov.querySelectorAll('#kw-tools input:checked')].map(c => Object.assign({ tool: c.value }, have[c.value] && have[c.value].why ? { why: have[c.value].why } : {})) };
        const st = _kwStarter([...ov.querySelectorAll('.kw-srow')].map(r => ({ path: r.querySelector('.kw-spath').value, content: r.querySelector('.kw-scontent').value })));
        if (st.error) { msg.textContent = st.error; return; }
        const td = _kwTools($('#kw-tooldefs').value);
        if (td.error) { msg.textContent = td.error; return; }
        kind.starter = st.list; if (td.list.length) kind.tool_defs = td.list;
        const post = async (confirmTools) => (await (await fetch('files.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'kind_save', kind: kind, confirm_tools: !!confirmTools, drop_tools: hadTools && !td.list.length }) })).json());
        try {
            let d = await post(false);
            if (!d.ok && d.needs_confirm_tools) {
                const lines = d.tools.map(t => '• ' + t.name + ' (' + t.binary + ')\n' + t.commands.map(c => '     ' + c).join('\n')).join('\n');
                if (!await cconfirm(T('kind.import.tools', 'This kind carries its own tool(s). They will run these commands on files you give them (nothing runs until you use them):') + '\n\n' + lines + '\n\n' + T('kind.import.tools.ok', 'Install the kind and its tool(s)?'))) return;
                d = await post(true);
            }
            if (!d.ok) { msg.textContent = d.error || 'not accepted'; return; }
            _kindList = null; ov.remove(); document.getElementById('kind-ov')?.remove();
            appendSystem(T('kind.wiz.saved', 'Kind "{name}" saved in your own folder.', { name: d.kind.name })); projectKindEdit();
        } catch (e) { msg.textContent = e.message; }
    };
    setTimeout(() => $('#kw-name').focus(), 50);
}

async function projectGoalEdit() {
    const cc = _ckCur(), p = cc.p, ch = cc.c;
    const eff = await chatMetaGet(p, ch);
    const cur = (eff && eff.goal) || '';
    const next = await cprompt('Goal of this chat — one sentence, sent with every prompt in it:', cur, (_ckIsFree(p) ? 'Free chat: ' : 'Project: ' + p + ' · chat: ') + ch);
    if (next === null) return;
    try {
        const r = await fetch('files.php', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ action:'set_project_meta', project:p, chat:ch, goal:next }) });
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.could.not.save.the.goal.error', 'Could not save the goal: {error}', {error: (d.error || 'unknown')})); return; }
        _ckForget(p, ch);
        projectGoalShow(p, ch);
        appendSystem(next.trim() ? T('msg.chat.goal.saved', 'Goal saved — every prompt in this chat now carries it.') : T('msg.chat.goal.cleared', 'Goal cleared for this chat.'));
    } catch (e) { appendSystem(T('msg.could.not.save.the.goal.message', 'Could not save the goal: {message}', {message: e.message})); }
}

// =============================================================================
// 7. Search through chat pane
// =============================================================================
let searchMatches  = [];
let searchCurrent  = -1;

function clearSearchHighlights() {
    consoleBox.querySelectorAll('.search-highlight').forEach(el => {
        const parent = el.parentNode;
        parent.replaceChild(document.createTextNode(el.textContent), el);
        parent.normalize();
    });
}

function searchChat(query) {
    clearSearchHighlights();
    searchMatches = [];
    searchCurrent = -1;
    document.getElementById('search-count').textContent = '';
    if (!query.trim()) return;

    const re = new RegExp(escRegex(query), 'gi');

    consoleBox.querySelectorAll('.msg-body').forEach(body => {
        // Walk text nodes and wrap matches
        const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
        const toReplace = [];
        let node;
        while (node = walker.nextNode()) {
            if (re.test(node.textContent)) toReplace.push(node);
            re.lastIndex = 0;
        }
        toReplace.forEach(textNode => {
            const frag = document.createDocumentFragment();
            let last = 0;
            let m;
            re.lastIndex = 0;
            while ((m = re.exec(textNode.textContent)) !== null) {
                frag.appendChild(document.createTextNode(textNode.textContent.slice(last, m.index)));
                const span = document.createElement('span');
                span.className = 'search-highlight';
                span.textContent = m[0];
                frag.appendChild(span);
                searchMatches.push(span);
                last = m.index + m[0].length;
            }
            frag.appendChild(document.createTextNode(textNode.textContent.slice(last)));
            textNode.parentNode.replaceChild(frag, textNode);
        });
    });

    document.getElementById('search-count').textContent =
        searchMatches.length ? '1 / ' + searchMatches.length : 'No matches';
    if (searchMatches.length) { searchCurrent = 0; scrollToMatch(0); }
}

function searchNav(dir) {
    if (!searchMatches.length) return;
    searchMatches[searchCurrent].classList.remove('current');
    searchCurrent = (searchCurrent + dir + searchMatches.length) % searchMatches.length;
    scrollToMatch(searchCurrent);
    document.getElementById('search-count').textContent =
        (searchCurrent + 1) + ' / ' + searchMatches.length;
}

function scrollToMatch(idx) {
    searchMatches[idx].classList.add('current');
    searchMatches[idx].scrollIntoView({ behavior: 'smooth', block: 'center' });
}

function escRegex(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

// =============================================================================
// 8. Line numbers
// =============================================================================
let lineNumbersOn = false;
let msgCounter    = 0;

function toggleLineNumbers(on) {
    // Called with no arg from the Msg# chip (flip), or with a boolean elsewhere.
    lineNumbersOn = (on === undefined) ? !lineNumbersOn : on;
    consoleBox.classList.toggle('line-numbers', lineNumbersOn);
    const chip = document.getElementById('line-numbers-toggle');
    if (chip) {
        chip.style.color           = lineNumbersOn ? '#fff' : 'var(--text-muted)';
        chip.style.background       = lineNumbersOn ? 'var(--gemini)' : '';
        chip.style.borderColor      = lineNumbersOn ? 'var(--gemini)' : '';
    }
}

// Patch appendMsg to add line number badge
// (stored as data attribute, shown via CSS toggle)
const _origAppendMsg = appendMsg;  // will be set after definition

// =============================================================================
// 9. Attachments — file upload + paste handling + routing to text/workers/tools
//
// User-facing entry points:
//   - handleFileUpload(input)     — wired to the Attach button's <input type=file>
//   - handlePromptPaste(event)    — wired to the prompt textarea paste event
//   - attachFromPath(absPath)     — used by ftAttachToPrompt() and from agents
//
// Internal pipeline:
//   1. The file is saved to /attachments/<chat>/<filename> via attachments.php
//   2. ATTACHMENT_ROUTER picks a handler based on the file extension
//   3. The handler either reads text inline OR dispatches to a tool/worker
//   4. When processing finishes, the result (extracted text, transcript,
//      description, etc.) is prepended to the prompt textarea in a clear
//      [Attached …] block, with a reference to the saved path
// =============================================================================

// Live state — one "pending" attachment placeholder per in-flight job
const _attachJobs = new Map();  // jobId → { name, startedAt, statusEl }

// =============================================================================
// ATTACHMENT_ROUTER — extension → processing plan
//
// Each entry is { test(file) → bool, plan: 'inline-text' | 'tools-preset'
//                                       | 'image-vision' | 'archive-zip'
//                                       | 'save-only',
//                 preset?: string,    // e.g. 'pandoc:pdf-to-markdown'
//                 maxBytes?: number,  // hard upload cap for this kind
//                 label: string }
//
// Order matters — first match wins. The table is a "best default" — users
// can override per-extension via attachments-settings (localStorage key
// "cockpit_attach_routes"). The override layer is applied in resolveRoute().
//
// Hardcoded defaults (configurable via attachmentsConfigureRoute()):
// =============================================================================

// B6: large text-file threshold. Text routes with a body bigger than this get
// switched from "inline-text" to "save-only" with a short preview. Default 64KB.
// Override via localStorage "cockpit_inline_threshold" (bytes).
const INLINE_TEXT_THRESHOLD_DEFAULT = 65536;
function _inlineTextThreshold() {
    const v = parseInt(localStorage.getItem('cockpit_inline_threshold') || '', 10);
    return (v > 0 && v < 16777216) ? v : INLINE_TEXT_THRESHOLD_DEFAULT;
}

const ATTACHMENT_ROUTER_DEFAULTS = [
    // Plain text and source code → inline directly into the prompt
    {
        match: /\.(txt|md|markdown|json|jsonl|csv|tsv|xml|yaml|yml|ini|conf|cfg|log|html?|css|js|ts|tsx|jsx|pas|pp|inc|lpr|dpr|dpk|php|py|sh|bash|zsh|rb|go|rs|java|c|cc|cpp|h|hpp|cs|swift|kt|sql|toml|env|gitignore|dockerfile|makefile)$/i,
        plan:  'inline-text',
        maxBytes: 1024 * 1024,         // 1 MB — generous for text
        label: 'text',
    },
    // PDF → pdftotext. It used to be lumped in with the pandoc route below, at a
    // preset ('pandoc:to-markdown') that has never existed in any shipped tool
    // definition -- and pandoc cannot read PDF in any case. Every attached PDF
    // therefore hit "preset not configured" and was saved as a bare reference
    // with no text extracted at all (found 2026-09-30, while testing PDF Vision,
    // which sits downstream of this same branch).
    {
        match: /\.pdf$/i,
        plan:  'tools-preset',
        preset: 'poppler:pdf-to-text',
        maxBytes: 25 * 1024 * 1024,
        label: 'document',
    },
    // Other documents → pandoc to markdown
    {
        match: /\.(docx|odt|rtf|epub|chm|mobi|tex)$/i,
        plan:  'tools-preset',
        preset: 'pandoc:docx-to-md',  // user can override via config
        maxBytes: 25 * 1024 * 1024,
        label: 'document',
    },
    // Audio → whisper transcription
    {
        match: /\.(mp3|wav|flac|ogg|m4a|opus|aac|wma)$/i,
        plan:  'tools-preset',
        preset: 'whisper:transcribe',
        maxBytes: 50 * 1024 * 1024,
        label: 'audio',
    },
    // Video → video-vision (keyframe extraction + vision describe, or Gemini native)
    {
        match: /\.(mp4|webm|mkv|mov|avi|flv|wmv)$/i,
        plan:  'video-vision',
        maxBytes: 100 * 1024 * 1024,
        label: 'video',
    },
    // Images → Ollama vision (gemma3:4b or whichever is configured)
    {
        match: /\.(png|jpe?g|webp|gif|bmp)$/i,
        plan:  'image-vision',
        maxBytes: 10 * 1024 * 1024,
        label: 'image',
    },
    // ZIP → save only, mention path (existing Sources upload covers project ZIPs)
    {
        match: /\.(zip|tar|gz|tgz|7z|rar)$/i,
        plan:  'save-only',
        maxBytes: 50 * 1024 * 1024,
        label: 'archive',
    },
    // Everything else → save, inject a path reference
    {
        match: /.*/,
        plan:  'save-only',
        maxBytes: 50 * 1024 * 1024,
        label: 'binary',
    },
];

// Resolve user overrides on top of defaults
function resolveRoute(filename) {
    let userRoutes = {};
    try {
        userRoutes = JSON.parse(localStorage.getItem('cockpit_attach_routes') || '{}');
    } catch(e) { userRoutes = {}; }
    const ext = (filename.split('.').pop() || '').toLowerCase();
    if (userRoutes[ext]) return Object.assign({}, userRoutes[ext], { ext });
    for (const r of ATTACHMENT_ROUTER_DEFAULTS) {
        if (r.match.test(filename)) return Object.assign({}, r, { ext });
    }
    return ATTACHMENT_ROUTER_DEFAULTS[ATTACHMENT_ROUTER_DEFAULTS.length - 1];
}

// =============================================================================
// File upload entry point — called from the Attach button
// =============================================================================
function handleFileUpload(input) {
    if (!input.files.length) return;
    for (const f of input.files) attachFile(f, f.name);
    input.value = '';  // reset so same file can be re-attached
}

// =============================================================================
// Paste handler — looks for image/file blobs in the clipboard
//
// Wired to the prompt textarea. Plain text pastes fall through to the
// browser's default behavior. Image or file blobs are uploaded as
// attachments and routed via the same pipeline as the Attach button.
// =============================================================================
function handlePromptPaste(e) {
    // A file copied in the file manager reaches the page as a nameless blob (or
    // nothing at all). In the native window the clipboard's file list is read
    // for real, so the file is attached by path — no copy, no rename to 'image.png'.
    if (_inShell) {
        shellCall('clipboard_files').then(r => {
            const paths = (r && r.paths) || [];
            if (paths.length) for (const p of paths) attachServerFile(p);
        }).catch(() => {});
    }
    const cd = e.clipboardData || window.clipboardData;
    if (!cd || !cd.items) return;
    const files = [];
    for (const item of cd.items) {
        if (item.kind === 'file') {
            const f = item.getAsFile();
            if (f) files.push(f);
        }
    }
    if (!files.length) return;             // plain text paste — let it through
    e.preventDefault();                    // we're handling this
    for (const f of files) {
        // Browsers usually name pasted images "image.png" with the timestamp
        // stripped. Generate a unique name so multiple pastes don't collide.
        const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
        const ext = (f.type.split('/')[1] || 'bin').toLowerCase().replace(/[^a-z0-9]/g, '');
        const name = (f.name && f.name !== 'image.png')
                     ? f.name
                     : 'paste-' + stamp + '.' + (ext || 'bin');
        attachFile(f, name);
    }
}

// =============================================================================
// VOICE INPUT — record mic in-browser, transcribe locally via whisper (offline).
// Audio never leaves the machine: MediaRecorder → transcribe.php → whisper.cpp.
// =============================================================================
let _micCap = null, _micStream = null;   // _micCap = the active capture handle

// ── Recording: Web Audio, not MediaRecorder ──────────────────────────────────
// MediaRecorder is unusable in the native window: WebKitGTK offers only
// audio/mp4 and then delivers EMPTY blobs (measured 2026-09-23 — 0 bytes with
// and without a timeslice, while an AnalyserNode on the same stream showed a
// peak deviation of 116/128, i.e. plenty of audio). The old code then hit
// `if (!blob.size) return;` and the button simply went back to idle: you spoke,
// nothing happened, nothing was said.
//
// Web Audio works in both engines, so there is one path instead of two, and it
// yields 16 kHz mono WAV — exactly what whisper.cpp wants, so transcribe.php's
// ffmpeg step has nothing to convert. Costs bandwidth (~32 KB/s against opus's
// ~4 KB/s) which is irrelevant over localhost.
const MIC_TARGET_RATE = 16000;

function _micEncodeWav(samples, rate) {
    const buf = new ArrayBuffer(44 + samples.length * 2);
    const view = new DataView(buf);
    const str = (off, s) => { for (let i = 0; i < s.length; i++) view.setUint8(off + i, s.charCodeAt(i)); };
    str(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); str(8, 'WAVE');
    str(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true);
    view.setUint16(22, 1, true); view.setUint32(24, rate, true);
    view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    str(36, 'data'); view.setUint32(40, samples.length * 2, true);
    let off = 44;
    for (let i = 0; i < samples.length; i++, off += 2) {
        const v = Math.max(-1, Math.min(1, samples[i]));
        view.setInt16(off, v < 0 ? v * 0x8000 : v * 0x7FFF, true);
    }
    return new Blob([view], { type: 'audio/wav' });
}

// Average-decimate to the target rate. Averaging rather than picking every Nth
// sample: plain decimation aliases, and whisper hears the artefacts.
function _micDownsample(chunks, fromRate, toRate) {
    let total = 0;
    for (const c of chunks) total += c.length;
    const flat = new Float32Array(total);
    let o = 0;
    for (const c of chunks) { flat.set(c, o); o += c.length; }
    if (toRate >= fromRate) return flat;
    const ratio = fromRate / toRate;
    const out = new Float32Array(Math.floor(flat.length / ratio));
    for (let i = 0; i < out.length; i++) {
        const start = Math.floor(i * ratio), end = Math.min(Math.floor((i + 1) * ratio), flat.length);
        let sum = 0, n = 0;
        for (let j = start; j < end; j++) { sum += flat[j]; n++; }
        out[i] = n ? sum / n : 0;
    }
    return out;
}

/** Start capturing. Returns a handle with stop() → Promise<{blob, seconds, peak}>. */
function _micCapture(stream, onLevel) {
    const Ctx = window.AudioContext || window.webkitAudioContext;
    const ctx = new Ctx();
    const src = ctx.createMediaStreamSource(stream);
    // ScriptProcessor is deprecated in favour of AudioWorklet, but it is present
    // in both engines and needs no separate module file; the worklet path is a
    // later refinement, not a correctness issue.
    const node = ctx.createScriptProcessor(4096, 1, 1);
    const chunks = [];
    let peak = 0;
    node.onaudioprocess = e => {
        const d = e.inputBuffer.getChannelData(0);
        let block = 0;
        for (let i = 0; i < d.length; i++) { const a = Math.abs(d[i]); if (a > peak) peak = a; if (a > block) block = a; }
        chunks.push(new Float32Array(d));
        if (onLevel) onLevel(block);
    };
    src.connect(node);
    // ScriptProcessor only runs while connected to a destination. A zero gain
    // keeps it running without playing the microphone back through the speakers.
    const mute = ctx.createGain();
    mute.gain.value = 0;
    node.connect(mute);
    mute.connect(ctx.destination);
    return {
        async stop() {
            node.onaudioprocess = null;
            try { node.disconnect(); mute.disconnect(); src.disconnect(); } catch (e) {}
            const rate = ctx.sampleRate;
            try { await ctx.close(); } catch (e) {}
            const samples = _micDownsample(chunks, rate, MIC_TARGET_RATE);
            return {
                blob: _micEncodeWav(samples, MIC_TARGET_RATE),
                seconds: Math.round((samples.length / MIC_TARGET_RATE) * 10) / 10,
                peak: Math.round(peak * 100) / 100,
            };
        },
    };
}
function _micSet(state) {
    const icon = document.getElementById('mic-icon');
    const lbl  = document.getElementById('mic-label');
    const btn  = document.getElementById('mic-btn');
    if (!icon || !lbl || !btn) return;
    if (state === 'recording') {
        icon.textContent = T('msg.stop.circle', 'stop_circle'); lbl.textContent = T('msg.stop', 'Stop');
        btn.style.borderColor = 'var(--accent-orange)'; btn.style.color = 'var(--accent-orange)';
    } else if (state === 'transcribing') {
        icon.textContent = T('msg.hourglass.top', 'hourglass_top'); lbl.textContent = '…';
        btn.style.borderColor = 'var(--accent-cyan)'; btn.style.color = 'var(--accent-cyan)';
    } else {
        icon.textContent = T('msg.mic', 'mic'); lbl.textContent = T('msg.voice', 'Voice');
        // Clear inline overrides so the .ma-mode-btn class (incl. :hover) takes over.
        btn.style.borderColor = ''; btn.style.color = ''; btn.style.boxShadow = '';
    }
}
async function micToggle() {
    if (_micCap) {                     // second click = stop
        const cap = _micCap; _micCap = null;
        _micLevelShow(false); _micLevelSet(0);
        _micSet('transcribing');
        let rec;
        try { rec = await cap.stop(); }
        catch (e) { _micStop(); _micSet('idle'); appendError(T('msg.recording.failed.message', 'Recording failed: {message}', {message: e.message})); return; }
        _micStop();

        // Say what happened. Every one of these used to be a silent return.
        if (!rec.blob.size || rec.seconds < 0.3) {
            _micSet('idle');
            appendError(T('msg.voice.nothing.was.recorded.secondss.check.th', 'Voice: nothing was recorded ({seconds}s). Check the input device in your sound settings.', {seconds: rec.seconds}));
            return;
        }
        if (rec.peak < 0.01) {
            _micSet('idle');
            appendError(T('voice.err.silent', 'Voice: the microphone was silent for {s}s — nothing to transcribe. Is the right input selected, and unmuted?', { s: rec.seconds }));
            return;
        }
        try {
            const fd = new FormData();
            fd.append('audio', rec.blob, 'rec.wav');
            const _langSel  = document.getElementById('mic-lang');
            fd.append('language', _langSel ? _langSel.value : 'auto');
            const _modelSel = document.getElementById('mic-model');
            fd.append('model', _modelSel ? _modelSel.value : 'auto');
            const r = await fetch('transcribe.php', { method: 'POST', body: fd });
            const d = await r.json();
            if (!d.ok) {
                appendError(T('msg.transcription.failed.errorhint', 'Transcription failed: {error}{hint}', {error: (d.error || 'unknown'), hint: (d.hint ? ' — ' + d.hint : '')}));
            } else {
                const txt = (d.text || '').trim();
                if (txt) {
                    const cur = promptInput.value;
                    promptInput.value = cur ? (cur.replace(/\s*$/, '') + ' ' + txt) : txt;
                    promptInput.focus();
                    appendSystem(T('voice.done', 'Voice transcribed ({engine}, {s}s).', { engine: (d.engine || 'whisper') + (d.model ? ' · ' + d.model : ''), s: rec.seconds }));
                } else {
                    appendSystem(T('msg.voice.secondss.recorded.but.no.speech.was.re', 'Voice: {seconds}s recorded, but no speech was recognised.', {seconds: rec.seconds}));
                }
            }
        } catch (e) { appendError(T('msg.transcription.error.message', 'Transcription error: {message}', {message: e.message})); }
        _micSet('idle');
        return;
    }

    if (!navigator.mediaDevices || !window.AudioContext && !window.webkitAudioContext) {
        appendError(T('msg.voice.input.not.supported.by.this.browser', 'Voice input not supported by this browser.')); return;
    }
    try {
        _micStream = await _micGetStream();
    } catch (e) { appendError(T('voice.err.denied', 'Microphone access denied or unavailable: {why}', { why: e.message })); return; }
    micDevicesRefresh();                    // device labels are only readable once permitted

    _micLevelShow(true);
    try { _micCap = _micCapture(_micStream, _micLevelSet); }
    catch (e) { _micStop(); _micLevelShow(false); appendError(T('msg.could.not.start.recording.message', 'Could not start recording: {message}', {message: e.message})); return; }
    _micSet('recording');
}

/** Release the microphone — the light must go out the moment we stop. */
function _micStop() {
    if (_micStream) { _micStream.getTracks().forEach(t => t.stop()); _micStream = null; }
}

// ── Input device + level meter ───────────────────────────────────────────────
// A machine's default input is frequently an empty analog jack: it records hum,
// whisper returns "*Painful Music*" or ".", and the feature looks broken. The
// picker names the alternatives and the meter shows whether anything is arriving.
const MIC_DEV_KEY = 'cockpit_mic_device';

function micDeviceSave() {
    const sel = document.getElementById('mic-device');
    if (!sel) return;
    try { localStorage.setItem(MIC_DEV_KEY, sel.value || ''); } catch (e) {}
}

/** The constraint for getUserMedia — a saved device, else whatever is default. */
function _micConstraint() {
    let id = '';
    try { id = localStorage.getItem(MIC_DEV_KEY) || ''; } catch (e) {}
    const sel = document.getElementById('mic-device');
    if (sel && sel.value) id = sel.value;
    return id ? { audio: { deviceId: { exact: id } } } : { audio: true };
}

/**
 * Get the microphone stream, surviving a SAVED DEVICE THAT IS GONE.
 *
 * The saved id is applied as `exact:`, so when that device is unplugged — or the
 * browser regenerates its ids, which WebKit does when site data is cleared — every
 * click throws OverconstrainedError. The picker itself quietly falls back to
 * "Default input" (it only selects a saved id that is still listed), so the screen
 * shows a sensible choice while the saved one keeps failing underneath it, and the
 * only visible symptom is "Microphone access denied" on a microphone that is fine.
 * On that failure: forget the dead id, say so, and use the default input.
 */
async function _micGetStream() {
    const c = _micConstraint();
    try { return await navigator.mediaDevices.getUserMedia(c); }
    catch (e) {
        const stale = c.audio && c.audio.deviceId && (e.name === 'OverconstrainedError' || e.name === 'NotFoundError');
        if (!stale) throw e;
        try { localStorage.removeItem(MIC_DEV_KEY); } catch (x) {}
        const sel = document.getElementById('mic-device'); if (sel) sel.value = '';
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        appendSystem(T('msg.icon.mic.the.microphone.you.picked.earlier.i', '[[icon:mic]] The microphone you picked earlier is not available any more — using the default input.'));
        return stream;
    }
}

/** Fill the picker. Labels stay blank until the mic has been permitted once, so
 *  this is called again after the first successful getUserMedia. */
async function micDevicesRefresh() {
    const sel = document.getElementById('mic-device');
    if (!sel || !navigator.mediaDevices || !navigator.mediaDevices.enumerateDevices) return;
    let devs = [];
    try { devs = await navigator.mediaDevices.enumerateDevices(); } catch (e) { return; }
    const ins = devs.filter(d => d.kind === 'audioinput');
    let saved = '';
    try { saved = localStorage.getItem(MIC_DEV_KEY) || ''; } catch (e) {}
    sel.innerHTML = '<option value="">Mic: Default input</option>' +
        ins.map((d, i) => '<option value="' + d.deviceId + '">Mic: ' +
            escapeHtml(d.label || ('Microphone ' + (i + 1))) + '</option>').join('');
    if (saved && ins.some(d => d.deviceId === saved)) sel.value = saved;
}

function _micLevelShow(on) {
    const w = document.getElementById('mic-level-wrap');
    const n = document.getElementById('mic-level-note');
    if (w) w.style.display = on ? 'block' : 'none';
    if (n && !on) n.style.display = 'none';
    _micMeterShow(on);
}
/** The wide bar to the left of the mic button — shown only while listening. Kept
 *  separate from _micLevelShow because the "Test level" verdict must stay on screen
 *  after the four seconds, and hiding the popup's note along with the bar would
 *  take the verdict with it. */
function _micMeterShow(on) {
    const m = document.getElementById('mic-meter');
    if (m) m.style.display = on ? 'inline-flex' : 'none';
    if (!on) { const b = document.getElementById('mic-meter-bar'); if (b) b.style.width = '0'; }
}

function _micLevelSet(v) {
    const col = v > 0.95 ? 'var(--claude)' : (v > 0.02 ? 'var(--ollama)' : 'var(--text-dim)');
    // The level ALSO fills the mic button itself. The bar below lives inside the
    // Voice-options popup, which is closed on an ordinary press of the mic — so a
    // person dictating saw an orange "Stop" and nothing else, and could not tell a
    // working microphone from a dead one, which is the one thing the meter is for.
    const btn = document.getElementById('mic-btn');
    if (btn) {
        const px = Math.min(22, Math.round(v * 30));
        btn.style.boxShadow = v > 0 ? 'inset 0 -' + px + 'px 0 0 ' + col : '';
    }
    const w = Math.min(100, Math.round(v * 140)) + '%';
    const big = document.getElementById('mic-meter-bar');
    if (big) { big.style.width = w; big.style.background = col; }
    const bar = document.getElementById('mic-level-bar');
    if (!bar) return;
    bar.style.width = w;
    // Red past 0.95: clipping is why a loud room transcribes as nonsense.
    bar.style.background = col;
}

/** Listen for four seconds and report the level. No upload, no transcription —
 *  the point is to tell a dead device from a working one before blaming whisper. */
async function micTestLevel(ev) {
    if (ev) ev.stopPropagation();
    const note = document.getElementById('mic-level-note');
    const say = m => { if (note) { note.style.display = 'block'; note.textContent = m; } };
    let stream;
    try { stream = await _micGetStream(); }
    catch (e) { say('No access: ' + e.message); return; }
    await micDevicesRefresh();               // labels are readable once permitted
    _micLevelShow(true); say('Listening… say something.');
    let peak = 0;
    const cap = _micCapture(stream, v => { if (v > peak) peak = v; _micLevelSet(v); });
    setTimeout(async () => {
        await cap.stop();
        stream.getTracks().forEach(t => t.stop());
        _micLevelSet(0);
        _micMeterShow(false);
        const p = Math.round(peak * 100);
        if (peak < 0.02)      say('Silent (' + p + '%) — wrong input, or muted.');
        else if (peak > 0.95) say('Clipping (' + p + '%) — lower the input volume.');
        else                  say('Good: peak ' + p + '%.');
    }, 4000);
}

// On load, show which whisper model is active in the Voice button's tooltip.
async function _micRefreshInfo() {
    const btn = document.getElementById('mic-btn');
    if (!btn) return;
    try {
        // Wait for the request gate (js/head.js). Until the session is confirmed it answers
        // any boot-time .php fetch LOCALLY with a fake 401 {suppressed:true}, and this runs
        // 800 ms after load -- often inside that window. The fake answer has no `available`,
        // so the old code read it as "whisper is not installed": the mic tooltip said so and
        // the model dropdown stayed empty. The server saw the call only once all day.
        if (typeof authGateReady === 'function') await authGateReady();
        const r = await fetch('transcribe.php?action=info');
        const d = await r.json();
        // An error or a suppressed call is not an answer about whisper. Say nothing rather
        // than something false.
        if (!d || d.suppressed || d.error) return;
        btn.title = d.available
            ? 'Voice input — press to record, press again to stop. A bar opens beside this button while you speak. Local whisper, offline (model: ' + (d.model || '?') + ')'
            : 'Voice input — whisper.cpp not installed yet (records, but can\'t transcribe)';
        // Populate the model picker from installed models (preserve current choice).
        const sel = document.getElementById('mic-model');
        if (sel && Array.isArray(d.models)) {
            const prev = sel.value;
            sel.innerHTML = '<option value="auto">Model: Auto' + (d.model ? ' (' + d.model + ')' : '') + '</option>' +
                d.models.map(m => '<option value="' + m + '">Model: ' + m + '</option>').join('');
            sel.value = d.models.includes(prev) || prev === 'auto' ? prev : 'auto';
        }
    } catch (e) { /* leave default tooltip */ }
}
document.addEventListener('DOMContentLoaded', () => {
    setTimeout(_micRefreshInfo, 800);
    // Populate the input picker early. Labels stay blank until the microphone
    // has been permitted once, so it is refreshed again after the first grant.
    setTimeout(micDevicesRefresh, 850);
});

