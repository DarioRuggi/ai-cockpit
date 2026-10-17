// =============================================================================
// CHATS — load, switch, new, rename
// =============================================================================
// Build a chat item div — reused by both Chats tab and Projects tab
// Highlight exactly one chat item across both lists (no refetch).
function chatMarkActive(project, slug) {
    document.querySelectorAll('.sb-item[data-chat-slug]').forEach(el => {
        el.classList.toggle('active', el.dataset.chatSlug === slug && (el.dataset.chatProject || '') === (project || ''));
    });
}
// Filter box above the Chats and Projects lists: matches the name AND the description (and, for a project, its chats' names and
// descriptions), case-insensitively. Re-applied after every reload of a list.
function sidebarFilter(listId, q) {
    const list = document.getElementById(listId); if (!list) return;
    const needle = String(q === undefined ? ((document.getElementById(listId + '-filter') || {}).value || '') : q).trim().toLowerCase();
    const old = list.querySelector(':scope > .sb-nomatch'); if (old) old.remove();
    let shown = 0, total = 0;
    Array.prototype.forEach.call(list.children, el => {
        const t = el.dataset.filterText || (el.querySelector('[data-filter-text]') || { dataset: {} }).dataset.filterText;
        const show = (!needle || t === undefined || t.indexOf(needle) >= 0);
        el.style.display = show ? '' : 'none';
        if (t !== undefined) { total++; if (show) shown++; }
    });
    // a filter that matches nothing used to leave a blank list; say so (2026-10-17)
    if (needle && total && !shown) { const h = document.createElement('div'); h.className = 'sb-nomatch'; h.style.cssText = 'padding:10px 12px;font-size:11px;color:var(--text-muted);'; h.textContent = T('sb.nomatch', 'Nothing matches “{q}”.', { q: needle }); list.appendChild(h); }
}
function buildChatItem(c, opts = {}) {
    const wrap = document.createElement('div');

    const div = document.createElement('div');
    div.className = 'sb-item' + (c.active ? ' active' : '');
    div.dataset.chatSlug = c.slug || ''; div.dataset.chatProject = c.project || '';   // for chatMarkActive()
    div.title = fmtTsLocal(c.updated) + ' · ' + c.exchanges + ' turns · ' + (c.last_agent || '') + (c.description ? '\n' + c.description : '');
    div.dataset.filterText = ((c.display || c.slug || '') + ' ' + (c.description || '')).toLowerCase();

    // Move/Detach button
    const moveTitle = opts.showMove ? 'Move to project' : 'Detach to Free';
    const moveIcon  = opts.showMove ? 'drive_file_move' : 'logout';

    // NOTE: c.project may be Hebrew/Unicode. We must NOT embed it into inline
    // onclick HTML-attribute JS strings — the HTML→JS parse chain re-decodes
    // \uXXXX sequences, turning escaped names into real Hebrew before the
    // handler runs (the bug that nearly deleted a real project). Instead we
    // build the markup without handlers and bind via addEventListener closures
    // over the real c.slug / c.project values below.
    div.innerHTML =
        '<span class="material-symbols-rounded sb-item-icon">chat</span>' +
        '<div class="sb-item-body">' +
            '<div class="sb-item-name">' +
                escHtml(c.display || c.slug) + '</div>' +
            '<div class="sb-item-meta">' + fmtTsLocal(c.updated) +
                ' · ' + c.exchanges + ' turns</div>' +
            (c.description ? '<div class="sb-item-desc" title="' + escHtml(c.description) + '">' + escHtml(c.description) + '</div>' : '') +
        '</div>' +
        '<span class="material-symbols-rounded mini-ctrl sb-item-export" style="color:var(--text-base);" ' +
            'title="Export this chat (.zip with .json + .md)">download</span>' +
        '<span class="material-symbols-rounded mini-ctrl sb-item-move" style="color:var(--text-base);" ' +
            'title="' + moveTitle + '">' + moveIcon + '</span>' +
        '<span class="material-symbols-rounded mini-ctrl sb-item-del" style="color:var(--text-base);" ' +
            'title="Remove chat">close</span>';

    // Bind handlers via closures over the real (un-escaped) values.
    // data-slug/data-project let other code (auto-rename on create) locate this
    // row without parsing an inline handler attribute (which no longer exists).
    const _nameEl = div.querySelector('.sb-item-name');
    if (_nameEl) {
        _nameEl.dataset.slug    = c.slug;
        _nameEl.dataset.project = c.project || '';
    }
    // Click vs. dblclick race: a single click triggers switchToChat → loadChats,
    // which rebuilds this list and would destroy the rename input a dblclick
    // creates. Debounce: hold the single-click action ~250ms; a dblclick cancels
    // it and opens the rename editor instead.
    let _clickTimer = null;

    const _exportEl = div.querySelector('.sb-item-export');
    if (_exportEl) _exportEl.addEventListener('click', e => {
        e.stopPropagation(); exportChat(c.slug, c.project);
    });

    const _moveEl = div.querySelector('.sb-item-move');
    if (_moveEl) _moveEl.addEventListener('click', e => {
        e.stopPropagation();
        if (opts.showMove) moveChatToProject(c.slug, c.project);
        else               detachChat(c.slug, c.project);
    });

    const _delEl = div.querySelector('.sb-item-del');
    if (_delEl) _delEl.addEventListener('click', e => {
        e.stopPropagation(); deleteChat(c.slug, c.project);
    });

    // Config files sub-panel — class reflects active state for visual distinction
    const configPanel = document.createElement('div');
    configPanel.className = c.active ? 'sb-active-section' : 'sb-inactive-section';
    configPanel.style.display = 'none';
    if (c.configs && c.configs.length) {
        const cfHdr = document.createElement('div');
        cfHdr.className = 'sb-section-hdr';
        cfHdr.style.cssText = 'padding:4px 8px 2px;font-size:9.5px;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;';
        cfHdr.textContent = T('msg.config', 'Config');
        configPanel.appendChild(cfHdr);

        c.configs.forEach(cf => {
            const cfDiv = document.createElement('div');
            cfDiv.className = 'ft-item';
            cfDiv.style.fontSize = '10.5px';
            cfDiv.innerHTML =
                '<span class="material-symbols-rounded" style="font-size:11px;">description</span>' +
                escHtml(cf.name);
            configPanel.appendChild(cfDiv);
        });
    }

    // Double-click the name → rename. Cancel the pending single-click switch so
    // its loadChats() rebuild doesn't wipe the rename input.
    if (_nameEl) _nameEl.addEventListener('dblclick', e => {
        e.stopPropagation();
        if (_clickTimer) { clearTimeout(_clickTimer); _clickTimer = null; }
        renameChat(c.slug, c.project, _nameEl);
    });

    div.addEventListener('click', e => {
        if (e.target.classList.contains('sb-item-del')) return;
        if (e.target.classList.contains('sb-item-export')) return;
        if (e.target.classList.contains('sb-item-move')) return;
        if (e.target.tagName === 'INPUT') return;

        // Debounce: defer the switch so a follow-up dblclick (rename) can cancel it.
        if (_clickTimer) { clearTimeout(_clickTimer); _clickTimer = null; }
        _clickTimer = setTimeout(() => {
            _clickTimer = null;

            // Demote any other active section in this list, promote this one
            document.querySelectorAll('#chats-list .sb-active-section')
                .forEach(s => { if (s !== configPanel) s.className = 'sb-inactive-section'; });
            document.querySelectorAll('#chats-list .sb-item-with-section')
                .forEach(s => s.classList.remove('sb-item-with-section'));

            switchToChat(c.slug, c.project);
            if (c.configs && c.configs.length) {
                const isOpen = configPanel.style.display !== 'none';
                configPanel.style.display = isOpen ? 'none' : 'block';
                if (!isOpen) {
                    configPanel.className = 'sb-active-section';
                    div.classList.add('sb-item-with-section');
                }
            } else {
                div.classList.add('sb-item-with-section');
            }
        }, 230);
    });

    wrap.appendChild(div);
    if (c.configs && c.configs.length) wrap.appendChild(configPanel);
    if (c.active && c.configs && c.configs.length) {
        configPanel.style.display = 'block';
        configPanel.className = 'sb-active-section';
        div.classList.add('sb-item-with-section');
    }
    return wrap;
}

// Sidebar panels whose content depends on the current project or chat, with
// their loader. Called by loadChat() for the panel(s) currently active so a
// chat switch (and the boot restore, where the tab is re-selected before the
// chat is loaded and the first load may run before the request gate opens)
// never leaves a stale or empty panel behind.
const CHAT_SCOPED_PANELS = [
    { id: 'right-code',        load: () => rpRefreshList('code') },
    { id: 'right-library',     load: () => rpRefreshList('library') },
    { id: 'right-snippets',    load: () => rpRefreshList('snippets') },
    { id: 'right-sources',     load: () => rpRefreshList('sources') },
    { id: 'right-config',      load: () => rpLoadConfig() },
    { id: 'right-plans',       load: () => plansRefresh() },
    { id: 'right-usage',       load: () => usageParserRefresh() },
    { id: 'right-attachments', load: () => attachPanelRefresh() },
    { id: 'left-filetree',     load: () => loadFileTree() },
];
function refreshChatScopedPanels() {
    for (const p of CHAT_SCOPED_PANELS) {
        const el = document.getElementById(p.id);
        if (!el || !el.classList.contains('active')) continue;
        try { const r = p.load(); if (r && r.catch) r.catch(() => {}); } catch (e) { console.warn('refreshChatScopedPanels', p.id, e); }
    }
}

async function loadChats() {
    const list = document.getElementById('chats-list');
    if (!list) return;
    list.innerHTML = '<div class="sidebar-empty">Loading...</div>';
    try {
        const res  = await fetch('files.php?action=chats');
        const data = await res.json();
        if (!data.ok) { list.innerHTML = '<div class="sidebar-empty">Error loading chats.</div>'; return; }

        // Chats tab shows ONLY Free (standalone) chats
        const freeSection = (data.sections || []).find(s => s.project === '_standalone');
        list.innerHTML = '';

        if (!freeSection || !freeSection.chats.length) {
            list.innerHTML = '<div class="sidebar-empty">No free chats yet.<br>Click "+ New Free" to create one.</div>';
            return;
        }

        freeSection.chats.forEach(c => {
            // showMove=true: show "Move to project" button
            list.appendChild(buildChatItem(c, { showMove: true }));
        });
        sidebarFilter('chats-list');
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Error loading chats.</div>';
    }
}

// =============================================================================
// F6 — Time tracking. A single active timer; toggle start/stop from the top
// bar, live elapsed display, per-project report. Backend: time.php.
// =============================================================================
let _timeActive = null;     // {project,chat,label,started} | null
let _timeTicker = null;     // setInterval handle

function _fmtDuration(secs) {
    secs = Math.max(0, Math.floor(secs));
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const s = secs % 60;
    if (h > 0) return h + 'h ' + String(m).padStart(2,'0') + 'm';
    if (m > 0) return m + 'm ' + String(s).padStart(2,'0') + 's';
    return s + 's';
}

async function timeRefreshStatus() {
    try {
        const r = await fetch('time.php?action=status');
        const d = await r.json();
        if (!d.ok) return;
        _timeActive = d.active;
        _timeUpdateButton(d.elapsed);
        if (_timeActive && !_timeTicker) {
            _timeTicker = setInterval(_timeTick, 1000);
        } else if (!_timeActive && _timeTicker) {
            clearInterval(_timeTicker); _timeTicker = null;
        }
    } catch(e) {}
}

function _timeTick() {
    if (!_timeActive || !_timeActive.started) return;
    const elapsed = Math.floor(Date.now()/1000) - _timeActive.started;
    _timeUpdateButton(elapsed);
}

function _timeUpdateButton(elapsed) {
    const btn = document.getElementById('time-btn');
    const lbl = document.getElementById('time-btn-label');
    if (!btn || !lbl) return;
    if (_timeActive) {
        lbl.textContent = _fmtDuration(elapsed || 0);
        btn.style.color = 'var(--accent-orange, var(--ollama))';   // active indicator (not red/green)
        btn.title = 'Tracking "' + (_timeActive.project || '(none)') + '" — click to stop (right-click for report)';
    } else {
        lbl.textContent = T('msg.track', 'Track');
        btn.style.color = '';
        btn.title = T('msg.start.time.tracking.for.this.project.right.c', 'Start time tracking for this project (right-click for report)');
    }
}

async function timeToggle() {
    if (_timeActive) {
        // stop
        try {
            const r = await fetch('time.php?action=stop', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'});
            const d = await r.json();
            if (d.ok && d.entry) appendSystem(T('msg.stopped.timer.fmtduration.on.project', 'Stopped timer — {fmtduration} on "{project}".', {fmtduration: _fmtDuration(d.entry.seconds), project: (d.entry.project||'(none)')}));
        } catch(e) { appendError(T('msg.stop.failed.message', 'Stop failed: {message}', {message: e.message})); }
    } else {
        // start for current project/chat
        try {
            const r = await fetch('time.php?action=start', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({project: currentProject || '', chat: currentChat || '', label: ''})
            });
            const d = await r.json();
            if (d.ok) appendSystem(T('msg.started.timer.for.currentproject', 'Started timer for "{currentproject}".', {currentproject: (currentProject||'(none)')}));
        } catch(e) { appendError(T('msg.start.failed.message', 'Start failed: {message}', {message: e.message})); }
    }
    timeRefreshStatus();
}

async function timeReportOpen() {
    let ov = document.getElementById('time-overlay');
    if (ov) { ov.style.display = 'flex'; timeReportRefresh(); return; }
    ov = document.createElement('div');
    ov.id = 'time-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(720px,94vw);max-height:88vh;overflow:hidden;display:flex;flex-direction:column;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">timer</span> Time tracking</h2>' +
        '<select id="time-range" style="font-size:11px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:3px 5px;margin-right:6px;">' +
        '<option value="today">Today</option><option value="week">This week</option><option value="month">This month</option><option value="all" selected>All time</option>' +
        '</select>' +
        '<span class="rp-action-btn" id="time-close" style="cursor:pointer;">×</span></div>' +
        '<div id="time-report" style="overflow:auto;flex:1;"></div>' +
        '</div>';
    document.body.appendChild(ov);
    document.getElementById('time-close').onclick = () => ov.style.display = 'none';
    ov.onclick = e => { if (e.target === ov) ov.style.display = 'none'; };
    document.getElementById('time-range').onchange = timeReportRefresh;
    timeReportRefresh();
}

async function timeReportRefresh() {
    const box = document.getElementById('time-report');
    if (!box) return;
    const range = document.getElementById('time-range')?.value || 'all';
    box.innerHTML = '<div style="font-size:11px;opacity:0.6;">Loading…</div>';
    try {
        const r = await fetch('time.php?action=report&range=' + encodeURIComponent(range));
        const d = await r.json();
        if (!d.ok) { box.innerHTML = '<div style="font-size:11px;">Error: ' + escHtml(d.error||'') + '</div>'; return; }
        let html = '<div style="font-size:13px;margin-bottom:10px;">Total: <b>' + _fmtDuration(d.total_seconds) + '</b>' +
            (d.active ? ' <span style="color:var(--accent-orange,var(--ollama));font-size:10px;">(timer running)</span>' : '') + '</div>';
        // By project
        const projs = Object.keys(d.by_project || {});
        if (projs.length) {
            html += '<div style="font-size:11px;font-weight:600;margin:6px 0;">By project</div>';
            html += '<div style="display:flex;flex-direction:column;gap:3px;margin-bottom:12px;">';
            projs.forEach(p => {
                html += '<div style="display:flex;font-size:11px;padding:3px 6px;background:var(--bg-darker,var(--bg-codeblock));border-radius:3px;">' +
                    '<span style="flex:1;">' + escHtml(p) + '</span><b>' + _fmtDuration(d.by_project[p]) + '</b></div>';
            });
            html += '</div>';
        }
        // Entries
        html += '<div style="font-size:11px;font-weight:600;margin:6px 0;">Entries (' + (d.entries||[]).length + ')</div>';
        if (!d.entries || !d.entries.length) {
            html += '<div style="font-size:10px;opacity:0.6;">No entries in this range.</div>';
        } else {
            html += '<div style="display:flex;flex-direction:column;gap:3px;">';
            d.entries.forEach(e => {
                const when = e.ended ? (fmtDate(new Date(e.ended*1000)) + ' ' + fmtTime(new Date(e.ended*1000))) : '';
                html += '<div style="display:flex;align-items:center;gap:6px;font-size:10.5px;padding:3px 6px;border:1px solid var(--border-dim);border-radius:3px;">' +
                    '<span style="flex:1;">' + escHtml(e.project || '(none)') + (e.label ? ' · ' + escHtml(e.label) : '') +
                    '<span style="opacity:0.6;"> — ' + escHtml(when) + (e.manual ? ' · manual' : '') + '</span></span>' +
                    '<b>' + _fmtDuration(e.seconds) + '</b>' +
                    '<span class="material-symbols-rounded" style="font-size:13px;cursor:pointer;opacity:0.6;" ' +
                    'onclick="timeDeleteEntry(\'' + e.id + '\')" title="Delete entry">delete</span>' +
                    '</div>';
            });
            html += '</div>';
        }
        box.innerHTML = html;
    } catch(e) { box.innerHTML = '<div style="font-size:11px;">Failed: ' + escHtml(e.message) + '</div>'; }
}

async function timeDeleteEntry(id) {
    if (!await cockpitConfirm('Delete time entry?', 'Delete this time entry?', 'Delete', {danger:true, icon:'delete'})) return;
    try {
        await fetch('time.php?action=delete', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id})});
        timeReportRefresh();
        timeRefreshStatus();
    } catch(e) { appendError(T('msg.delete.failed.message', 'Delete failed: {message}', {message: e.message})); }
}

// Initialize the timer status on load (and recover a running timer across reloads)
setTimeout(timeRefreshStatus, 800);

// =============================================================================
// F1 — Skills system. Skills are reusable prompt templates invoked with
// /trigger. They expand (with {arg} substitution) into the agent-bound prompt.
// Manager modal: list / create / edit / delete. Storage via skills.php.
// =============================================================================
let _skillsCache = null;   // array of skill summaries

async function skillsLoad(force) {
    if (_skillsCache && !force) return _skillsCache;
    try {
        const r = await fetch('skills.php?action=list');
        const d = await r.json();
        _skillsCache = d.ok ? (d.skills || []) : [];
    } catch(e) { _skillsCache = []; }
    return _skillsCache;
}

// =============================================================================
// Auto-triggering (design doc §5). When the user does NOT explicitly invoke a
// /trigger, match the prompt against folder-skill descriptions (Tier 1) and
// inject the matched SKILL.md body (Tier 2) as context — for ALL suppliers
// (Cockpit does the matching uniformly; deterministic keyword score, no LLM).
// =============================================================================
function skillsAutoOn() { return (localStorage.getItem('cockpit_skills_autotrigger') ?? '1') === '1'; }
function skillsAutoSet(on) { try { localStorage.setItem('cockpit_skills_autotrigger', on ? '1' : '0'); } catch(e) {} }

const _SKILL_STOP = new Set(['the','and','for','with','use','when','user','asks','task','this','that','your','our','you','are','using','via','help','helps','content','from','into','them','then','also','etc','long','form','kind','type','types','want','wants','need','needs','make','given','about']);
function _skillKeywords(desc) {
    const words = String(desc).toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/)
        .filter(w => w.length >= 4 && !_SKILL_STOP.has(w));
    return [...new Set(words)];
}
// Return up to 2 matching folder skills, best first. Conservative thresholds to
// avoid false fires (a wrong auto-load wastes tokens + skews the answer).
function skillsMatch(text, skills) {
    const t = ' ' + String(text).toLowerCase().replace(/[^a-z0-9\s]/g, ' ').replace(/\s+/g, ' ') + ' ';
    const scored = [];
    for (const s of skills) {
        if (s.format !== 'folder' || !s.valid || !s.description) continue;
        const kw = _skillKeywords(s.description);
        if (!kw.length) continue;
        let hits = 0; for (const w of kw) if (t.includes(' ' + w)) hits++;
        const ratio = hits / kw.length;
        const nameHit = String(s.name).split('-').filter(w => w.length >= 4).some(w => t.includes(w));
        const score = hits + (nameHit ? 3 : 0);
        if ((hits >= 3 && ratio >= 0.18) || (nameHit && hits >= 1)) scored.push({ s, score });
    }
    scored.sort((a, b) => b.score - a.score);
    return scored.slice(0, 2).map(x => x.s);
}
// Match + inject Tier-2 bodies. Returns augmented text (original unchanged on no match).
async function skillsAutoInject(text) {
    if (!skillsAutoOn()) return text;
    let skills; try { skills = await skillsLoad(); } catch (e) { return text; }
    const matches = skillsMatch(text, skills);
    if (!matches.length) return text;
    // Progressive disclosure (load_skill): capable models (Gemini) get only a
    // catalog + a load instruction, and pull the full body on demand via the
    // %%LOAD_SKILL:id%% marker. Weak/local models (Ollama) and Claude (native
    // skills) keep the eager full-body injection — small models can't be trusted
    // to self-select reliably.
    if (typeof currentAgent !== 'undefined' && currentAgent === 'gemini') {
        const cat = matches.map(m => '- ' + m.id + ' — ' + (m.description || m.name || '')).join('\n');
        matches.forEach(m => appendSystem(T('msg.icon.psychology.skill.available.name.loads.o', '[[icon:psychology]] Skill available: {name} (loads on demand)', {name: (m.name || m.id)})));
        return text + '\n\n--- Skills available for this task (load on demand) ---\n' + cat +
            '\nIf one applies, emit %%LOAD_SKILL:<id>%% on its own line to get its full instructions, then continue.\n';
    }
    let inject = '';
    for (const m of matches) {
        try {
            const d = await (await fetch('skills.php?action=body&id=' + encodeURIComponent(m.id))).json();
            if (d.ok && d.body) {
                inject += '\n\n[SKILL: ' + (d.name || m.id) + ']\n' + d.body + '\n';
                if (d.refs && d.refs.length) inject += '(Referenced files available on request: ' + d.refs.join(', ') + ')\n';
                appendSystem(T('msg.icon.psychology.skill.auto.loaded.name', '[[icon:psychology]] Skill auto-loaded: {name}', {name: (d.name || m.id)}));
            }
        } catch (e) {}
    }
    if (!inject) return text;
    return text + '\n\n--- Relevant skill(s), auto-loaded as context ---' + inject;
}

// Expand "/trigger arg1 arg2" → skill body with {argName} substituted.
// Positional args fill the skill's declared args in order; a trailing remainder
// fills {input} / {args} if present. Returns expanded string, or null if no
// matching skill (so the prompt is sent verbatim).
async function skillsExpandInvocation(rawText) {
    const m = rawText.match(/^\/([a-z0-9_\-]+)\s*([\s\S]*)$/i);
    if (!m) return null;
    const trigger = m[1].toLowerCase();
    const rest = m[2];
    let skills = await skillsLoad();
    let summary = skills.find(s => (s.trigger || '').toLowerCase() === trigger);
    // A skill saved elsewhere (another tab, the API, a sync) is not in this tab's
    // cache yet: one refresh before deciding the /trigger is not a skill.
    if (!summary) { skills = await skillsLoad(true); summary = skills.find(s => (s.trigger || '').toLowerCase() === trigger); }
    if (!summary) return null;   // not a known skill — send verbatim
    // Fetch full skill (body lives server-side)
    let skill = null;
    try {
        const r = await fetch('skills.php?action=get&id=' + encodeURIComponent(summary.id));
        const d = await r.json();
        if (d.ok) skill = d.skill;
    } catch(e) {}
    if (!skill) return null;
    let body = skill.body || '';
    // Positional fill of declared args (split rest on whitespace, but the LAST
    // declared arg gets the remainder so multi-word values work).
    const declared = (skill.args || []).map(a => a.name);
    if (declared.length) {
        const parts = rest.trim().length ? rest.trim().split(/\s+/) : [];
        declared.forEach((name, i) => {
            let val;
            if (i === declared.length - 1) val = parts.slice(i).join(' ');
            else val = parts[i] || '';
            body = body.split('{' + name + '}').join(val);
        });
    }
    // Generic {input}/{args} = the full remainder
    body = body.split('{input}').join(rest.trim());
    body = body.split('{args}').join(rest.trim());
    appendSystem(T('msg.skill.trigger.name.expanded', 'Skill /{trigger} ({name}) expanded.', {trigger: trigger, name: (skill.name || '')}));
    return body;
}

// =============================================================================
// RULES — task delegation (2026-07-02). See rules.php for the full design
// note. UI: manage rules (list/add/delete) + the ambiguous-match picker.
// The actual per-prompt hook lives in sendPrompt() (rulesInterceptPrompt()).
// =============================================================================
let _rulesCache = [];

async function rulesManagerOpen() {
    document.getElementById('rules-overlay')?.remove();
    const ov = document.createElement('div'); ov.id = 'rules-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100004;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(560px,95vw);max-height:88vh;display:flex;flex-direction:column;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;gap:8px;padding:13px 16px;border-bottom:1px solid var(--border-dim);">' +
        '<span class="material-symbols-rounded" style="color:var(--gemini);">alt_route</span><h2 style="margin:0;font-size:15px;flex:1;">Delegate — task auto-routing</h2>' +
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'rules-overlay\').remove()">×</span></div>' +
        '<div style="padding:10px 16px;font-size:11px;color:var(--text-dim);border-bottom:1px solid var(--border-dim);">' +
        'Tasks matching a delegation rule\'s keywords get sent to the chosen supplier/model/combo first — the result is folded into your prompt before the normally-selected agent continues. If keyword matching is unclear, a small local model tries to classify it; if that\'s not confident either, you\'ll be asked. (Not to be confused with the "Rules" Directives button — that injects static context into every prompt; this routes specific tasks elsewhere.)</div>' +
        '<div id="rules-list" style="flex:1;overflow:auto;padding:10px 16px;font-size:12px;">Loading…</div>' +
        '<div style="padding:10px 16px;border-top:1px solid var(--border-dim);">' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="rulesFormOpen()">＋ New Delegation Rule</button></div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    await rulesRefreshList();
}
async function rulesRefreshList() {
    const list = document.getElementById('rules-list'); if (!list) return;
    list.innerHTML = 'Loading…';
    try {
        const r = await (await fetch('rules.php?action=list')).json();
        if (!r.ok) { list.innerHTML = '<div style="color:var(--warn);">Failed to load rules.</div>'; return; }
        _rulesCache = r.rules || [];
        if (!_rulesCache.length) { list.innerHTML = '<div style="color:var(--text-dim);padding:10px;">No rules yet. Tasks dispatch normally until you add one.</div>'; return; }
        list.innerHTML = _rulesCache.map(rule => {
            const kindLabel = {worker:'Worker', combo:'Combo', ollama_model:'Ollama model', tool:'Tool'}[rule.target.kind] || rule.target.kind;
            return '<div style="border:1px solid var(--border-dim);border-radius:6px;padding:8px 10px;margin-bottom:6px;display:flex;align-items:center;gap:8px;">' +
                '<label style="display:flex;align-items:center;gap:6px;flex:1;min-width:0;cursor:pointer;">' +
                '<input type="checkbox" ' + (rule.enabled ? 'checked' : '') + ' onchange="rulesToggle(\'' + rule.id + '\', this.checked)">' +
                '<div style="min-width:0;">' +
                '<div style="font-weight:600;">' + escapeHtml(rule.name) + '</div>' +
                '<div style="font-size:10px;color:var(--text-dim);">' + escapeHtml(rule.keywords.join(', ')) + ' → ' + kindLabel + ': ' + escapeHtml(rule.target.id) + '</div>' +
                '</div></label>' +
                '<button class="action-btn" onclick="rulesDelete(\'' + rule.id + '\')" style="padding:4px 8px;">Delete</button>' +
                '</div>';
        }).join('');
    } catch(e) { list.innerHTML = '<div style="color:var(--warn);">Error: ' + e.message + '</div>'; }
}
async function rulesToggle(id, enabled) {
    const rule = _rulesCache.find(r => r.id === id); if (!rule) return;
    rule.enabled = enabled;
    await fetch('rules.php?action=save', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({rule})});
}
async function rulesDelete(id) {
    if (!await cockpitConfirm('Delete rule', 'Remove this delegation rule?', 'Delete', {danger:true})) return;
    await fetch('rules.php?action=delete', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id})});
    rulesRefreshList();
}

// Collect available delegation targets from what's already loaded client-side
// (no new endpoints needed — the Workers/Combos/Ollama panels already fetched
// this data for their own dropdowns).
async function rulesAvailableTargets(kind) {
    if (kind === 'ollama_model') {
        return [...document.querySelectorAll('#ollama-panel .cs-option[data-value]')]
            .map(el => ({id: el.dataset.value, name: el.querySelector('.cs-option-name')?.textContent?.trim() || el.dataset.value}))
            .filter(o => o.id && !o.id.startsWith('combo:'));
    }
    if (kind === 'combo') {
        return (_combosData || []).map(c => ({id: c.id, name: c.name}));
    }
    if (kind === 'worker') {
        try {
            const r = await (await fetch('workers.php?action=providers')).json();
            return r.ok ? (r.providers || []).map(p => ({id: p.id, name: p.name})) : [];
        } catch(e) { return []; }
    }
    return [];
}
async function rulesFormOpen() {
    document.getElementById('rules-form-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'rules-form-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100005;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const fld = (l,h)=>'<label style="font-size:11px;color:var(--text-dim);display:block;margin-top:8px;">'+l+'</label>'+h;
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(420px,94vw);padding:18px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:6px;"><h2 style="margin:0;font-size:14px;flex:1;">New Delegation Rule</h2>' +
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'rules-form-ov\').remove()">×</span></div>' +
        fld('Name', '<input id="rf-name" placeholder="Translation tasks" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;border-radius:4px;font-size:12px;">') +
        fld('Keywords / phrases (comma-separated)', '<input id="rf-keywords" placeholder="translate, into french, summarise" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;border-radius:4px;font-size:12px;">') +
        fld('Delegate to', '<select id="rf-kind" onchange="rulesFormKindChange()" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;border-radius:4px;font-size:12px;"><option value="worker">Worker (REST API)</option><option value="combo">Power Combo</option><option value="ollama_model">Ollama model</option></select>') +
        fld('Target', '<select id="rf-target" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;border-radius:4px;font-size:12px;"></select>') +
        '<div id="rf-err" style="font-size:11px;color:var(--warn);min-height:14px;margin-top:8px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px;"><button class="action-btn" onclick="document.getElementById(\'rules-form-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="rulesFormSave()">Save</button></div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    rulesFormKindChange();
}
async function rulesFormKindChange() {
    const kind = document.getElementById('rf-kind')?.value;
    const sel  = document.getElementById('rf-target');
    if (!sel) return;
    sel.innerHTML = '<option value="">Loading…</option>';
    const opts = await rulesAvailableTargets(kind);
    sel.innerHTML = opts.length
        ? opts.map(o => '<option value="' + escAttr(o.id) + '">' + escHtml(o.name) + '</option>').join('')
        : '<option value="">— none available —</option>';
}
async function rulesFormSave() {
    const err = document.getElementById('rf-err');
    const name = (document.getElementById('rf-name').value || '').trim();
    const keywords = (document.getElementById('rf-keywords').value || '').split(',').map(s=>s.trim()).filter(Boolean);
    const kind = document.getElementById('rf-kind').value;
    const tid  = document.getElementById('rf-target').value;
    if (!name) { err.textContent = T('msg.name.required', 'Name required.'); return; }
    if (!keywords.length) { err.textContent = T('msg.at.least.one.keyword.phrase.required', 'At least one keyword/phrase required.'); return; }
    if (!tid) { err.textContent = T('msg.pick.a.target', 'Pick a target.'); return; }
    const r = await (await fetch('rules.php?action=save', {method:'POST',headers:{'Content-Type':'application/json'},
        body: JSON.stringify({rule: {name, keywords, enabled: true, target: {kind, id: tid}}})})).json();
    if (r.ok) { document.getElementById('rules-form-ov').remove(); rulesRefreshList(); }
    else err.textContent = 'Save failed: ' + (r.error || 'unknown');
}

// Ambiguous-match picker — small modal, resolves to a rule id or null ("none").
function rulesAskUser(candidates) {
    return new Promise(resolve => {
        document.getElementById('rules-ask-ov')?.remove();
        const ov = document.createElement('div'); ov.id = 'rules-ask-ov';
        ov.style.cssText = 'position:fixed;inset:0;z-index:100006;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        const opts = candidates.map(c => '<button class="action-btn" style="display:block;width:100%;text-align:left;margin-bottom:6px;" onclick="window._rulesAskResolve(\'' + c.id + '\')">' + escapeHtml(c.name) + '</button>').join('');
        ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(360px,92vw);padding:16px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
            '<h2 style="margin:0 0 10px;font-size:14px;">Which rule applies?</h2>' +
            '<div style="font-size:11px;color:var(--text-dim);margin-bottom:10px;">Not sure this task matches automatically — pick one, or continue without delegating.</div>' +
            opts +
            '<button class="action-btn" style="display:block;width:100%;margin-top:4px;" onclick="window._rulesAskResolve(null)">None — continue normally</button></div>';
        document.body.appendChild(ov);
        window._rulesAskResolve = (id) => { ov.remove(); delete window._rulesAskResolve; resolve(id); };
    });
}

// Called from sendPrompt() before dispatch. Returns the (possibly augmented)
// text to actually send. Fully transparent when no rule fires — same text
// back immediately, no delay, no UI.
// =============================================================================
// Timestamp line.
//
// No local model can know the date; without it "what time is it?" gets a
// confidently wrong or a confidently unhelpful answer. One line, APPENDED so a
// prompt that starts with a CLI /command still starts with it. ISO date, not
// the locale form: "12/09/2026" reads as December 9th to half the world's models.
//
// NOTE: cross-agent context is NOT done here, on purpose. It already exists
// server-side -- agent_loop.sh reads the last MAX_HISTORY exchanges from the
// chat file and prepends them to every CLI prompt, whichever agent answered
// last. A client-side hand-off was added and then removed the same day: it
// duplicated that, and would have fed the model the same six exchanges twice.
// The reason Claude once saw "no previous messages" was a persistence bug --
// append_to_chat() silently dropped turns after a Power Combo had rewritten the
// chat file -- fixed in scripts/agent_loop.sh, not here.
// =============================================================================
function timestampEnabled() { return localStorage.getItem('cockpit_timestamp') !== '0'; }
function timestampToggle(on){ localStorage.setItem('cockpit_timestamp', on ? '1' : '0'); }

function timestampIntercept(text) {
    if (!timestampEnabled()) return text;
    const d = new Date();
    const tz = (Intl.DateTimeFormat().resolvedOptions().timeZone || '');
    const p = n => String(n).padStart(2, '0');
    const wd = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][d.getDay()];
    const stamp = d.getFullYear() + '-' + p(d.getMonth()+1) + '-' + p(d.getDate()) + ' ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ' ' + wd;
    return text + '\n\n(Now: ' + stamp + (tz ? ', ' + tz : '') + ')';
}

async function rulesInterceptPrompt(text) {
    try {
        const cls = await (await fetch('rules.php?action=classify', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({prompt:text})})).json();
        if (!cls.ok) return text;
        let ruleId = null;
        if (cls.matched) {
            ruleId = cls.rule_id;
            appendSystem(T('msg.rule.rulename.matched.method.delegating.firs', 'Rule "{rulename}" matched ({method}) — delegating first…', {rulename: cls.rule_name, method: cls.method}));
        } else if (cls.method === 'ambiguous' && cls.candidates && cls.candidates.length) {
            ruleId = await rulesAskUser(cls.candidates);
        }
        if (!ruleId) return text;
        const del = await (await fetch('rules.php?action=delegate', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({rule_id:ruleId, prompt:text})})).json();
        if (!del.ok) { appendSystem(T('msg.rule.delegation.failed.error.continuing.norm', 'Rule delegation failed ({error}) — continuing normally.', {error: (del.error||'unknown')})); return text; }
        appendSystem(T('msg.delegated.result.from.source.incorporated', 'Delegated result from {source} incorporated.', {source: del.source}));
        return '[Delegated result from ' + del.source + ']:\n' + del.outcome + '\n\n---\n\nOriginal task: ' + text;
    } catch(e) {
        return text;   // never block the normal flow on a Rules failure
    }
}

function skillsManagerOpen() {
    let ov = document.getElementById('skills-overlay');
    if (ov) { ov.style.display = 'flex'; skillsManagerRefresh(); return; }
    ov = document.createElement('div');
    ov.id = 'skills-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(820px,95vw);max-height:90vh;overflow:hidden;display:flex;flex-direction:column;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">bolt</span> Skills</h2>' +
        '<label style="font-size:10px;color:var(--text-muted);display:flex;align-items:center;gap:3px;margin-right:8px;cursor:pointer;" title="Auto-load a folder skill when its description matches your prompt (no /trigger needed)">' +
        '<input type="checkbox" id="skills-autotrigger"> Auto-trigger</label>' +
        '<button class="action-btn svc-guide-btn" onclick="skillVsCapGuide()" title="Skill · Capability · Tool — when to use which" style="display:flex;align-items:center;gap:3px;padding:3px 8px;font-size:10px;margin-right:6px;"><span class="material-symbols-rounded" style="font-size:13px;">help</span></button>' +
        '<button class="rp-action-btn" id="skills-import" title="Import a Claude-format skill (.zip with SKILL.md). Validated + scripts gated.">⤒ Import</button>' +
        '<input type="file" id="skills-import-file" accept=".zip" style="display:none;">' +
        '<button class="rp-action-btn" id="skills-new" title="New inline skill — you write a prompt body and invoke it by typing /trigger (with {args}). Best for quick reusable prompts." style="margin-left:6px;">+ Snippet</button>' +
        '<button class="rp-action-btn" id="skills-new-folder" title="New folder skill (Claude SKILL.md format) — auto-runs when your prompt matches its description (no /trigger). Can bundle reference files. Best for richer, auto-triggered skills." style="margin-left:6px;">+ SKILL.md</button>' +
        '<span class="rp-action-btn" id="skills-close" style="cursor:pointer;margin-left:6px;">×</span></div>' +
        '<div style="font-size:10px;color:var(--text-muted);margin-bottom:8px;line-height:1.5;">' +
        '<b>+ Snippet</b> = inline skill you run by typing <code>/trigger</code> (args fill positionally via <code>{argName}</code>, <code>{input}</code>, <code>{args}</code>). ' +
        '<b>+ SKILL.md</b> = folder skill that <i>auto-runs</i> when your prompt matches its description — no <code>/trigger</code> needed.</div>' +
        '<div style="display:flex;gap:12px;overflow:hidden;flex:1;">' +
        '<div id="skills-list" style="width:240px;overflow:auto;border-right:1px solid var(--border-dim);padding-right:8px;display:flex;flex-direction:column;gap:4px;"></div>' +
        '<div id="skills-editor" style="flex:1;overflow:auto;"></div>' +
        '</div></div>';
    document.body.appendChild(ov);
    const close = () => ov.style.display = 'none';
    document.getElementById('skills-close').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('skills-new').onclick = () => skillsEditorRender(null);
    const fnew = document.getElementById('skills-new-folder');
    if (fnew) fnew.onclick = () => skillsFolderEditor(null);
    document.getElementById('skills-import').onclick = () => cockpitPickIntoInput('skills-import-file',['zip'],'Import skill');
    document.getElementById('skills-import-file').onchange = skillsImport;
    const at = document.getElementById('skills-autotrigger');
    at.checked = skillsAutoOn();
    at.onchange = () => skillsAutoSet(at.checked);
    skillsManagerRefresh();
}

// Import a Claude-format skill zip (SKILL.md folder). Validated + scripts gated server-side.
async function skillsImport(e) {
    const f = e.target.files && e.target.files[0];
    e.target.value = '';
    if (!f) return;
    if (f.size > 10 * 1024 * 1024) { appendError(T('msg.skill.zip.too.large.10mb', 'Skill zip too large (>10MB).')); return; }
    const b64 = await new Promise((res, rej) => {
        const fr = new FileReader();
        fr.onload = () => res(String(fr.result).split(',')[1] || '');
        fr.onerror = rej; fr.readAsDataURL(f);
    });
    let d = await (await fetch('skills.php', { method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify({ action:'import', zip_b64:b64 }) })).json();
    if (!d.ok && d.exists) {
        if (!await cockpitConfirm('Overwrite skill?', 'Skill "' + (d.error||'') + '" — overwrite existing?', 'Overwrite', {icon:'upload'})) return;
        d = await (await fetch('skills.php', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ action:'import', zip_b64:b64, overwrite:true }) })).json();
    }
    if (!d.ok) { appendError(T('msg.import.failed.errorerrors', 'Import failed: {error}{errors}', {error: (d.error||''), errors: (d.errors? ' — '+d.errors.join('; '):'')})); return; }
    appendSystem(T('msg.imported.skill.namewarnings', 'Imported skill: {name}{warnings}', {name: d.name, warnings: (d.warnings&&d.warnings.length? ' [[icon:warning]] '+d.warnings.join('; '):'')}));
    if (d.note) appendSystem(T('msg.icon.warning.note', '[[icon:warning]] {note}', {note: d.note}));
    skillsManagerRefresh();
}

// Export a folder skill as a portable .zip (usable in Claude.ai / Claude Code).
async function skillsExportFolder(id, ev) {
    ev.stopPropagation();
    try {
        const d = await (await fetch('skills.php?action=export&id=' + encodeURIComponent(id))).json();
        if (!d.ok) { appendError(T('msg.export.failed.error', 'Export failed: {error}', {error: (d.error||'')})); return; }
        const a = document.createElement('a');
        a.href = 'data:application/zip;base64,' + d.zip_b64;
        a.download = d.filename || (id + '.zip');
        document.body.appendChild(a); a.click(); a.remove();
    } catch (e) { appendError(T('msg.export.failed.message', 'Export failed: {message}', {message: e.message})); }
}

async function skillsManagerRefresh() {
    const list = document.getElementById('skills-list');
    if (!list) return;
    const skills = await skillsLoad(true);
    if (!skills.length) {
        list.innerHTML = '<div style="font-size:11px;opacity:0.6;padding:8px;">No skills yet. Click "+ Snippet" (a /trigger skill) or "+ SKILL.md" (auto-matched folder skill).</div>';
    } else {
        list.innerHTML = '';
        skills.forEach(s => {
            const row = document.createElement('div');
            row.style.cssText = 'padding:6px 8px;border:1px solid var(--border-dim);border-radius:4px;cursor:pointer;';
            row.onmouseover = () => row.style.background = 'var(--bg-hover,var(--bg-active))';
            row.onmouseout  = () => row.style.background = '';
            // Folder skills (SKILL.md) get a badge, validity flag, and Export.
            let badge = '', warn = '', exportBtn = '';
            if (s.format === 'folder') {
                badge = '<span style="font-size:8px;padding:1px 5px;border-radius:7px;background:var(--bg-codeblock);color:var(--accent-cyan);border:1px solid var(--border-dim);">SKILL.md</span>';
                if (!s.valid)         warn = '<span title="' + escAttr((s.errors||[]).join('; ')) + '" style="color:var(--accent-orange);font-size:9px;">▲ invalid</span>';
                else if ((s.warnings||[]).length) warn = '<span title="' + escAttr((s.warnings||[]).join('; ')) + '" style="color:var(--accent-amber);font-size:9px;">▲ ' + s.warnings.length + '</span>';
                if (s.has_scripts) warn += ' <span title="bundles scripts/ — not auto-run" style="color:var(--accent-amber);font-size:9px;"><span class="material-symbols-rounded ico">settings</span> scripts</span>';
                exportBtn = '<span class="skl-export" title="Export as portable .zip" style="cursor:pointer;color:var(--accent-cyan);font-size:11px;margin-left:auto;">⤓</span>';
            }
            row.innerHTML =
                '<div style="display:flex;align-items:center;gap:5px;"><span style="font-size:11px;font-weight:600;">' + escHtml(s.name) + '</span>' + badge + exportBtn + '</div>' +
                '<div style="font-size:10px;color:var(--text-muted);font-family:var(--font-mono);">/' + escHtml(s.trigger) + (warn ? ' · ' + warn : '') + '</div>' +
                (s.description ? '<div style="font-size:9.5px;color:var(--text-muted);margin-top:2px;">' + escHtml(s.description) + '</div>' : '');
            row.onclick = () => (s.format === 'folder') ? skillsFolderEditor(s.id) : skillsEditorRender(s.id);
            const exp = row.querySelector('.skl-export');
            if (exp) exp.onclick = (ev) => skillsExportFolder(s.id, ev);
            list.appendChild(row);
        });
    }
    skillsEditorRender(null, true);   // reset editor to empty/hint state
}

// Description coach (design §6): score a description on the [what]+[when/triggers]
// +[capabilities] formula. Returns {len, level, issues:[{sev,msg}]}.
function skillDescCoach(desc) {
    const d = String(desc || '').trim();
    const issues = [];
    if (d === '') { issues.push({ sev:'err', msg:'Empty — describe what it does AND when to use it.' }); return { len:0, level:'err', issues }; }
    if (d.length > 1024) issues.push({ sev:'err', msg:'Over 1024 chars (' + d.length + ').' });
    if (/[<>]/.test(d)) issues.push({ sev:'err', msg:'Remove angle brackets < > (injection risk).' });
    const hasTrigger = /\b(use when|when (the )?user|when you|use this (skill )?(to|when)|trigger)\b/i.test(d);
    if (!hasTrigger) issues.push({ sev:'warn', msg:'No trigger phrase — add "Use when the user asks to…" (top reason skills do not fire).' });
    if (/^\s*helps?\s+(with|you)\b/i.test(d) || d.split(/\s+/).length < 6)
        issues.push({ sev:'warn', msg:'Too vague — name concrete tasks, phrases, and file types.' });
    if (!/\b(blog|code|pdf|image|file|post|article|review|diff|data|csv|json|email|sql)\b/i.test(d))
        issues.push({ sev:'info', msg:'Consider naming concrete nouns/file types the task involves.' });
    const errs = issues.filter(i => i.sev === 'err').length;
    const warns = issues.filter(i => i.sev === 'warn').length;
    const level = errs ? 'err' : warns ? 'warn' : 'ok';
    return { len:d.length, level, issues };
}

// Folder-skill editor (Claude SKILL.md) with live coaching + trigger test matrix.
async function skillsFolderEditor(id) {
    const ed = document.getElementById('skills-editor');
    if (!ed) return;
    let name = id || '', description = '', body = '', refs = [];
    if (id) {
        try {
            const d = await (await fetch('skills.php?action=body&id=' + encodeURIComponent(id))).json();
            if (d.ok) { name = d.name || id; description = d.description || ''; body = d.body || ''; refs = d.refs || []; }
        } catch (e) {}
    }
    const cyan = 'var(--accent-cyan)', amber = 'var(--accent-amber)', orange = 'var(--accent-orange,var(--ollama))';
    ed.innerHTML =
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<div style="font-size:10px;color:var(--text-muted);">Claude <code>SKILL.md</code> folder skill — auto-triggered by its description. Folder = kebab-case name.</div>' +
        '<label style="font-size:11px;color:var(--text-muted);">Name (kebab-case)' +
          '<input id="fsk-name" value="' + escAttr(name) + '" ' + (id ? 'readonly' : '') + ' placeholder="blog-content-writer" style="width:100%;box-sizing:border-box;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:12px;padding:6px;border-radius:3px;font-family:var(--font-mono);"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Description <span style="font-size:9px;">[what it does] + [when to use it] + [key capabilities]</span>' +
          '<textarea id="fsk-desc" placeholder="Writes blog posts in our house style. Use when the user asks to write a blog post, article, or draft long-form content." style="width:100%;box-sizing:border-box;min-height:54px;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:11.5px;padding:6px;border-radius:3px;">' + escHtml(description) + '</textarea></label>' +
        '<div id="fsk-coach" style="font-size:10px;"></div>' +
        '<label style="font-size:11px;color:var(--text-muted);">SKILL.md body (instructions, workflow, examples)' +
          '<textarea id="fsk-body" style="width:100%;box-sizing:border-box;min-height:120px;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:11.5px;padding:6px;border-radius:3px;font-family:var(--font-mono);">' + escHtml(body) + '</textarea></label>' +
        (refs.length ? '<div style="font-size:10px;color:var(--text-muted);">Tier-3 refs: ' + refs.map(escHtml).join(', ') + '</div>' : '') +
        // Test matrix (§7)
        '<div style="border-top:1px solid var(--border-dim);padding-top:8px;">' +
          '<div style="font-size:11px;font-weight:600;margin-bottom:4px;">Trigger test matrix <span style="font-size:9px;color:var(--text-muted);">— aim ≥90% should-trigger</span></div>' +
          '<div style="display:flex;gap:8px;">' +
            '<label style="flex:1;font-size:10px;color:' + cyan + ';">SHOULD trigger (one phrase/line)' +
              '<textarea id="fsk-pos" style="width:100%;box-sizing:border-box;min-height:60px;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:10.5px;padding:5px;border-radius:3px;">write a blog post about cats\ndraft an article on AI</textarea></label>' +
            '<label style="flex:1;font-size:10px;color:' + amber + ';">should NOT trigger' +
              '<textarea id="fsk-neg" style="width:100%;box-sizing:border-box;min-height:60px;background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);font-size:10.5px;padding:5px;border-radius:3px;">summarize this article\nfix the login bug</textarea></label>' +
          '</div>' +
          '<button class="rp-action-btn" id="fsk-runtests" style="margin-top:6px;">▶ Run tests</button>' +
          '<div id="fsk-testout" style="font-size:10px;margin-top:6px;"></div>' +
        '</div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;border-top:1px solid var(--border-dim);padding-top:8px;">' +
          (id ? '<button class="rp-action-btn" id="fsk-del" style="color:' + orange + ';">Delete</button>' : '') +
          '<button class="rp-action-btn" id="fsk-save">Save SKILL.md</button>' +
        '</div></div>';

    const descEl = document.getElementById('fsk-desc');
    const coachEl = document.getElementById('fsk-coach');
    const renderCoach = () => {
        const c = skillDescCoach(descEl.value);
        const col = c.level === 'err' ? orange : c.level === 'warn' ? amber : cyan;
        const glyph = c.level === 'err' ? '<span class="material-symbols-rounded ico">close</span>' : c.level === 'warn' ? '▲' : '●';
        coachEl.innerHTML = '<span style="color:' + col + ';font-weight:700;">' + glyph + ' ' + c.len + '/1024</span> ' +
            c.issues.map(i => '<div style="color:' + (i.sev==='err'?orange:i.sev==='warn'?amber:'var(--text-muted)') + ';margin-top:2px;">• ' + escHtml(i.msg) + '</div>').join('');
    };
    descEl.oninput = renderCoach; renderCoach();

    document.getElementById('fsk-runtests').onclick = () => {
        const liveDesc = descEl.value;
        const liveName = (document.getElementById('fsk-name').value || 'x').trim();
        const skill = [{ id:liveName, name:liveName, format:'folder', valid:true, description:liveDesc }];
        const run = (lines) => lines.split('\n').map(s => s.trim()).filter(Boolean)
            .map(q => ({ q, hit: skillsMatch(q, skill).length > 0 }));
        const pos = run(document.getElementById('fsk-pos').value);
        const neg = run(document.getElementById('fsk-neg').value);
        const posPass = pos.filter(r => r.hit).length, negPass = neg.filter(r => !r.hit).length;
        const pct = pos.length ? Math.round(100 * posPass / pos.length) : 0;
        const line = (r, want) => '<div style="color:' + (r.hit === want ? cyan : orange) + ';">' +
            (r.hit === want ? '<span class="material-symbols-rounded ico">check</span>' : '<span class="material-symbols-rounded ico">close</span>') + ' ' + (r.hit ? 'fires' : 'no') + ' — ' + escHtml(r.q) + '</div>';
        document.getElementById('fsk-testout').innerHTML =
            '<b style="color:' + (pct >= 90 ? cyan : amber) + ';">Should-trigger: ' + posPass + '/' + pos.length + ' (' + pct + '%)' + (pct < 90 ? ' — below 90% target' : '') + '</b>' +
            pos.map(r => line(r, true)).join('') +
            '<b style="color:' + (negPass === neg.length ? cyan : orange) + ';">Should-NOT: ' + negPass + '/' + neg.length + ' correct</b>' +
            neg.map(r => line(r, false)).join('');
    };

    document.getElementById('fsk-save').onclick = async () => {
        const nm = (document.getElementById('fsk-name').value || '').trim();
        const c = skillDescCoach(descEl.value);
        if (c.level === 'err') { appendError(T('msg.fix.description.errors.first.filter', 'Fix description errors first: {filter}', {filter: c.issues.filter(i=>i.sev==='err').map(i=>i.msg).join('; ')})); return; }
        const d = await (await fetch('skills.php', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ action:'save_folder', id:nm, description:descEl.value, body:document.getElementById('fsk-body').value }) })).json();
        if (!d.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error||'')})); return; }
        appendSystem(T('msg.saved.skill.idwarnings', 'Saved skill: {id}{warnings}', {id: d.id, warnings: (d.warnings&&d.warnings.length? ' [[icon:warning]] '+d.warnings.join('; '):'')}));
        _skillsCache = null;
        skillsManagerRefresh();
    };
    const del = document.getElementById('fsk-del');
    if (del) del.onclick = async () => {
        if (!await cockpitConfirm('Delete folder skill?', 'Delete folder skill "' + id + '"?', 'Delete', {danger:true, icon:'delete'})) return;
        await fetch('skills.php', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ action:'delete_folder', id }) });
        _skillsCache = null; skillsManagerRefresh();
    };
}

async function skillsEditorRender(id, hintOnly) {
    const ed = document.getElementById('skills-editor');
    if (!ed) return;
    if (hintOnly && !id) {
        ed.innerHTML = '<div style="font-size:11px;opacity:0.6;padding:8px;">Select a skill to edit, or create a new one.</div>';
        return;
    }
    let skill = { id:'', name:'', trigger:'', description:'', body:'', args:[] };
    if (id) {
        try {
            const r = await fetch('skills.php?action=get&id=' + encodeURIComponent(id));
            const d = await r.json();
            if (d.ok) skill = d.skill;
        } catch(e) {}
    }
    const argsStr = (skill.args || []).map(a => a.name + (a.desc ? ':' + a.desc : '')).join(', ');
    ed.innerHTML =
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">Name' +
        '<input id="sk-name" type="text" value="' + escHtml(skill.name) + '" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:12px;padding:5px 6px;"></label>' +
        '<div style="display:flex;gap:8px;">' +
        '<label style="font-size:11px;color:var(--text-muted);flex:1;">ID (immutable once set)' +
        '<input id="sk-id" type="text" value="' + escHtml(skill.id) + '"' + (skill.id ? ' readonly' : '') + ' placeholder="my-skill" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:12px;padding:5px 6px;' + (skill.id?'opacity:0.6;':'') + '"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);flex:1;">Trigger (/word)' +
        '<input id="sk-trigger" type="text" value="' + escHtml(skill.trigger) + '" placeholder="myskill" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:12px;padding:5px 6px;"></label>' +
        '</div>' +
        '<label style="font-size:11px;color:var(--text-muted);">Description' +
        '<input id="sk-desc" type="text" value="' + escHtml(skill.description) + '" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:12px;padding:5px 6px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Args (comma-separated names, optional :description)' +
        '<input id="sk-args" type="text" value="' + escHtml(argsStr) + '" placeholder="topic, language" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:11px;padding:5px 6px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Body — use {argName}, {input}, {args}' +
        '<textarea id="sk-body" rows="9" style="width:100%;margin-top:3px;box-sizing:border-box;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:11px;padding:6px;resize:vertical;">' + escHtml(skill.body) + '</textarea></label>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;align-items:center;">' +
        '<span id="sk-status" style="font-size:10px;flex:1;color:var(--text-muted);"></span>' +
        (skill.id ? '<button class="rp-action-btn" id="sk-delete" style="border-color:var(--ollama);color:var(--ollama);">Delete</button>' : '') +
        '<button class="rp-action-btn" id="sk-save" style="background:var(--bg-active);">Save</button>' +
        '</div></div>';
    document.getElementById('sk-save').onclick = async () => {
        const payload = {
            id:      (document.getElementById('sk-id').value || '').trim().toLowerCase().replace(/[^a-z0-9_\-]/g,''),
            name:    document.getElementById('sk-name').value.trim(),
            trigger: (document.getElementById('sk-trigger').value || '').trim().toLowerCase().replace(/[^a-z0-9_\-]/g,''),
            description: document.getElementById('sk-desc').value.trim(),
            body:    document.getElementById('sk-body').value,
            args:    document.getElementById('sk-args').value.split(',').map(s => {
                        const [name, desc] = s.split(':');
                        return name.trim() ? { name: name.trim(), desc: (desc||'').trim() } : null;
                     }).filter(Boolean),
        };
        const _st = document.getElementById('sk-status');
        const _err = m => { if (_st) { _st.textContent = m; _st.style.color = 'var(--ollama)'; } appendError(m); };
        if (!payload.id)   { _err('ID is required (lowercase letters/digits/-/_).'); return; }
        if (!payload.name) { _err('Name is required.'); return; }
        if (!payload.body.trim()) { _err('Body is required.'); return; }
        if (!payload.trigger) payload.trigger = payload.id;
        if (_st) { _st.textContent = T('msg.saving', 'Saving…'); _st.style.color = 'var(--text-muted)'; }
        try {
            const r = await fetch('skills.php?action=save', {
                method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(payload)
            });
            const d = await r.json();
            if (!d.ok) { _err('Save failed: ' + (d.error||'unknown')); return; }
            if (_st) { _st.innerHTML = 'Saved <span class="material-symbols-rounded ico">check</span>  Use it with /' + escHtml(payload.trigger); _st.style.color = 'var(--claude,#3c8)'; }
            appendSystem(T('msg.skill.name.saved.trigger', 'Skill "{name}" saved (/{trigger}).', {name: payload.name, trigger: payload.trigger}));
            skillsManagerRefresh();
        } catch(e) { _err('Save failed: ' + e.message); }
    };
    const delBtn = document.getElementById('sk-delete');
    if (delBtn) delBtn.onclick = async () => {
        if (!await cockpitConfirm('Delete skill?', 'Delete skill "' + skill.name + '"?', 'Delete', {danger:true, icon:'delete'})) return;
        try {
            const r = await fetch('skills.php?action=delete', {
                method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id: skill.id})
            });
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (d.error||'')})); return; }
            appendSystem(T('msg.skill.deleted', 'Skill deleted.'));
            skillsManagerRefresh();
        } catch(e) { appendError(T('msg.delete.failed.message', 'Delete failed: {message}', {message: e.message})); }
    };
}

// =============================================================================
// C4 — Semantic (deep) search UI. Build index (embeds all items via Ollama),
// then meaning-based query ranking. Vector math runs server-side in PHP.
// =============================================================================
function semanticSearchOpen() {
    let ov = document.getElementById('semsearch-overlay');
    if (ov) { ov.style.display = 'flex'; document.getElementById('semsearch-input').focus(); return; }
    ov = document.createElement('div');
    ov.id = 'semsearch-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:flex-start;justify-content:center;padding-top:8vh;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(720px,94vw);max-height:80vh;overflow:hidden;display:flex;flex-direction:column;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">neurology</span> Deep search (semantic)</h2>' +
        '<span class="rp-action-btn" id="semsearch-close" style="cursor:pointer;">×</span></div>' +
        '<div style="font-size:10px;color:var(--text-muted);margin-bottom:8px;">' +
        'Meaning-based search over chats, snippets, knowledge, and sources using local embeddings (' +
        'nomic-embed-text via Ollama). Build the index after adding new items.</div>' +
        '<div style="display:flex;gap:6px;margin-bottom:8px;">' +
        '<input id="semsearch-input" type="text" placeholder="Describe what you\'re looking for…" ' +
        'style="flex:1;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:13px;padding:6px 8px;">' +
        '<button class="rp-action-btn" id="semsearch-go" style="background:var(--bg-active);">Search</button>' +
        '<button class="rp-action-btn" id="semsearch-build" title="Embed all catalog items (run after adding new ones)">Build index</button>' +
        '</div>' +
        '<div id="semsearch-status" style="font-size:10px;color:var(--text-muted);margin-bottom:6px;"></div>' +
        '<div id="semsearch-results" style="overflow:auto;flex:1;display:flex;flex-direction:column;gap:4px;"></div>' +
        '</div>';
    document.body.appendChild(ov);
    const close = () => ov.style.display = 'none';
    document.getElementById('semsearch-close').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    const input = document.getElementById('semsearch-input');
    document.getElementById('semsearch-go').onclick = () => semanticSearchRun();
    input.addEventListener('keydown', e => { if (e.key === 'Enter') semanticSearchRun(); });
    document.getElementById('semsearch-build').onclick = async () => {
        const status = document.getElementById('semsearch-status');
        status.textContent = T('msg.building.index.embedding.all.items.may.take', 'Building index… (embedding all items — may take a moment)');
        try {
            const r = await fetch('library.php?action=build_embeddings', {method:'POST'});
            const d = await r.json();
            if (!d.ok) { status.innerHTML = '<span class="material-symbols-rounded ico">warning</span> ' + escHtml(d.error || 'Build failed'); return; }
            status.innerHTML = '<span class="material-symbols-rounded ico">check</span> Indexed ' + d.indexed + ' new, ' + d.skipped + ' unchanged · ' +
                                 d.total + ' total vectors (' + d.model + ')';
        } catch(e) { status.textContent = 'Build failed: ' + e.message; }
    };
    setTimeout(() => input.focus(), 50);
}

async function semanticSearchRun() {
    const q = document.getElementById('semsearch-input').value.trim();
    const status = document.getElementById('semsearch-status');
    const results = document.getElementById('semsearch-results');
    if (!q) { status.textContent = T('msg.describe.what.you.want.to.find', 'Describe what you want to find.'); return; }
    status.textContent = T('msg.searching', 'Searching…');
    results.innerHTML = '';
    try {
        const r = await fetch('library.php?action=semantic_search&q=' + encodeURIComponent(q) + '&limit=10');
        const d = await r.json();
        if (!d.ok) { status.innerHTML = '<span class="material-symbols-rounded ico">warning</span> ' + escHtml(d.error || ''); return; }
        status.textContent = d.results.length + ' results (over ' + d.indexed + ' indexed items)';
        if (!d.results.length) { results.innerHTML = '<div style="font-size:11px;opacity:0.6;padding:10px;">No matches.</div>'; return; }
        d.results.forEach(h => {
            const pct = Math.round(h.score * 100);
            const row = document.createElement('div');
            row.style.cssText = 'border:1px solid var(--border-dim);border-radius:4px;padding:6px 8px;' +
                (h.kind === 'chat' ? 'cursor:pointer;' : '');
            row.innerHTML =
                '<div style="display:flex;align-items:center;gap:6px;font-size:11px;">' +
                '<span class="rp-cfg-pill" style="font-size:9px;background:var(--bg-darker,var(--bg-codeblock));padding:1px 5px;border-radius:8px;">' + escHtml(h.kind) + '</span>' +
                '<b style="flex:1;">' + escHtml(h.title || h.id) + '</b>' +
                (h.lang ? '<span style="opacity:0.6;font-size:10px;">' + escHtml(h.lang) + '</span>' : '') +
                '<span style="font-size:10px;color:var(--accent-cyan,var(--text-muted));" title="cosine similarity">' + pct + '%</span>' +
                '</div>';
            if (h.kind === 'chat' && h.id.startsWith('chat:')) {
                const parts = h.id.slice(5).split('/');
                row.title = T('msg.click.to.open.this.chat', 'Click to open this chat');
                row.addEventListener('click', () => {
                    const overlay = document.getElementById('semsearch-overlay');
                    if (overlay) overlay.style.display = 'none';
                    switchToChat(parts[1], parts[0]);
                });
            }
            results.appendChild(row);
        });
    } catch(e) { status.textContent = 'Search failed: ' + e.message; }
}

// =============================================================================
// E7 — Conversation history search. Searches all chat JSONs (server-side via
// files.php?action=search_history), shows ranked hits, click to jump to chat.
// =============================================================================
function historySearchOpen() {
    let ov = document.getElementById('histsearch-overlay');
    if (ov) { ov.style.display = 'flex'; document.getElementById('histsearch-input').focus(); return; }
    ov = document.createElement('div');
    ov.id = 'histsearch-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:flex-start;justify-content:center;padding-top:8vh;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(720px,94vw);max-height:80vh;overflow:hidden;display:flex;flex-direction:column;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">manage_search</span> Search conversation history</h2>' +
        '<span class="rp-action-btn" id="histsearch-close" style="cursor:pointer;">×</span></div>' +
        '<div style="display:flex;gap:6px;margin-bottom:8px;">' +
        '<input id="histsearch-input" type="text" placeholder="Search all chats… (all terms must match)" ' +
        'style="flex:1;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:13px;padding:6px 8px;">' +
        '<label style="display:flex;align-items:center;gap:4px;font-size:10px;color:var(--text-muted);white-space:nowrap;">' +
        '<input type="checkbox" id="histsearch-scope"> This project only</label>' +
        '<button class="rp-action-btn" id="histsearch-go" style="background:var(--bg-active);">Search</button>' +
        '</div>' +
        '<div id="histsearch-status" style="font-size:10px;color:var(--text-muted);margin-bottom:6px;"></div>' +
        '<div id="histsearch-results" style="overflow:auto;flex:1;display:flex;flex-direction:column;gap:4px;"></div>' +
        '</div>';
    document.body.appendChild(ov);
    const close = () => ov.style.display = 'none';
    document.getElementById('histsearch-close').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    const input = document.getElementById('histsearch-input');
    const run = () => historySearchRun();
    document.getElementById('histsearch-go').onclick = run;
    input.addEventListener('keydown', e => { if (e.key === 'Enter') run(); });
    setTimeout(() => input.focus(), 50);
}

async function historySearchRun() {
    const q = document.getElementById('histsearch-input').value.trim();
    const status = document.getElementById('histsearch-status');
    const results = document.getElementById('histsearch-results');
    if (!q) { status.textContent = T('msg.type.something.to.search', 'Type something to search.'); return; }
    const scoped = document.getElementById('histsearch-scope').checked;
    status.textContent = T('msg.searching', 'Searching…');
    results.innerHTML = '';
    try {
        let url = 'files.php?action=search_history&q=' + encodeURIComponent(q);
        if (scoped && currentProject) url += '&project=' + encodeURIComponent(currentProject);
        const r = await fetch(url);
        const d = await r.json();
        if (!d.ok) { status.textContent = 'Error: ' + (d.error || ''); return; }
        status.textContent = d.count + ' match' + (d.count===1?'':'es') +
                             (d.count >= 100 ? ' (showing first 100)' : '');
        if (!d.hits.length) { results.innerHTML = '<div style="font-size:11px;opacity:0.6;padding:10px;">No matches.</div>'; return; }
        d.hits.forEach(h => {
            const row = document.createElement('div');
            row.style.cssText = 'border:1px solid var(--border-dim);border-radius:4px;padding:6px 8px;cursor:pointer;';
            row.onmouseover = () => row.style.background = 'var(--bg-hover,var(--bg-active))';
            row.onmouseout  = () => row.style.background = '';
            const projLabel = h.project === '_standalone' ? 'Free' : h.project;
            const who = (h.role === 'user') ? 'You' : (h.agent || h.role || 'agent').toUpperCase();
            row.innerHTML =
                '<div style="display:flex;align-items:center;gap:6px;font-size:10px;color:var(--text-muted);margin-bottom:3px;">' +
                '<span class="material-symbols-rounded" style="font-size:12px;">chat</span>' +
                '<b style="color:var(--text-base);">' + escHtml(projLabel) + '</b> / ' + escHtml(h.chat) +
                '<span style="margin-left:auto;">' + escHtml(who) + (h.ts ? ' · ' + escHtml(fmtTsLocal(h.ts)) : '') + '</span>' +
                '</div>' +
                '<div style="font-size:11px;white-space:pre-wrap;">' + escHtml(h.snippet) + '</div>';
            row.onclick = async () => {
                document.getElementById('histsearch-overlay').style.display = 'none';
                await switchToChat(h.chat, h.project);
            };
            results.appendChild(row);
        });
    } catch(e) { status.textContent = 'Search failed: ' + e.message; }
}

async function switchToChat(chatName, projectName) {
    // Update current project if switching from a different one
    if (projectName && projectName !== '_standalone') currentProject = projectName;
    if (projectName === '_standalone') currentProject = '_standalone';
    // Set active in state
    await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'set_active', project:currentProject, chat:chatName})
    });
    currentChat = chatName;
    _realChatActive = true;
    localStorage.setItem('cockpit_last_project', currentProject);
    localStorage.setItem('cockpit_last_chat', currentChat);
    updateStatusbarPath(currentProject, currentChat);

    // Phase 2b: load this chat's persisted working-style. Each chat has its
    // own independent style slot in localStorage, so switching chats may
    // also flip the active style and prefix accordingly.
    if (typeof loadStyleForCurrentChat === 'function') {
        loadStyleForCurrentChat();
    }

    // Load chat history into console
    const res  = await fetch('files.php?action=chat&project=' +
        encodeURIComponent(currentProject) + '&chat=' + encodeURIComponent(chatName));
    const data = await res.json();
    if (!data.ok || !data.chat) return;

    // Update chat-name with display name from chat data
    const cn = document.getElementById('chat-name');
    if (cn) cn.textContent = data.chat.chat || chatName;

    // Clear console and replay exchanges
    consoleBox.innerHTML = '';
    lastMsgTime = null;
    msgCounter  = 0;
    const exchanges = data.chat.exchanges || [];
    exchanges.forEach(ex => {
        const ts = ex.timestamp ? parseTs(ex.timestamp) : new Date();
        if (ex.role === 'user') {
            appendMsg('dario', _userLabel(), 'dario', ex.text, ts, '', '');
        } else if (ex.agent === 'system') {
            // Seeded intro / welcome message — render as a system note.
            appendSystem(ex.text);
        } else {
            const ag = ex.agent || 'ollama';
            const m  = ex.model || '';
            const shortM = m.includes('/') ? m.split('/').pop() : m;
            const _cap = s => s ? s.charAt(0).toUpperCase() + s.slice(1) : '';
            const _mod = ex.mode  ? ' · ' + _cap(ex.mode) : '';
            const _sty = ex.style ? ' · ' + (ex.style === 'plan' ? 'Outline' : _cap(ex.style)) : '';
            // Slot ids (claude/gemini/ollama) are not supplier names: Card 2 may hold
            // opencode, Card 3 may be Dual. agent_loop.sh stores the supplier with
            // the turn (2026-09-21); older turns fall back to the slot's current name.
            const _supName = ex.supplier ? String(ex.supplier).toUpperCase()
                : ag === 'claude' ? (window._primaryName  || 'CLAUDE')
                : ag === 'gemini' ? (window._fallbackName || 'GEMINI')
                : ag === 'ollama' ? (window._localName    || 'OLLAMA') : '';
            const _inner = ag === 'claude'
                ? _supName
                : ag === 'gemini'
                    ? _supName
                    : ag === 'workers'
                        ? 'WORKERS' + (shortM ? ' · ' + shortM.toUpperCase() : '')
                    : ag === 'tools'
                        ? 'TOOLS' + (m ? ' · ' + m.toUpperCase() : '')
                        : _supName + (shortM ? ' · ' + shortM.toUpperCase() : '');
            const lbl = '[' + _inner + _mod + _sty + ']';
            // Worker turns are stored as agent "workers" (workers.php saves them
            // since 2026-09-12); the live bubble uses the "worker" class.
            const cls = (ag === 'workers' || ag === 'tools') ? 'worker' : ag;
            appendMsg(cls, lbl, cls, ex.text, ts,
                ex.duration_s ? ex.duration_s.toFixed(1) + 's' : '', '');
            if (ag === 'tools' && typeof pathOpenDecorate === 'function') pathOpenDecorate(consoleBox.lastElementChild);
        }
    });

    // Scroll to bottom to show latest messages
    consoleBox.scrollTop = consoleBox.scrollHeight;

    // Refresh every open sidebar panel whose content is scoped to the current
    // project or chat (one table instead of one fix per tab — 2026-09-14). Only
    // the active panel is reloaded; the others load when their tab is selected.
    refreshChatScopedPanels();

    // Update the active highlight in every list that shows chats (Chats tab and the
    // Projects tree) — the tree used to keep the previous chat highlighted until its
    // next reload (2026-09-13). Then refresh the Chats tab from the server.
    chatMarkActive(currentProject, chatName);
    loadChats();
    if (document.getElementById('left-projects')?.classList.contains('active') && typeof loadProjects === 'function') loadProjects();
    if (typeof costLoadForChat === 'function') costLoadForChat();   // refresh cost tiers for this chat
    appendSystem(T('msg.loaded.chat.chatname.n.exchanges', 'Loaded chat: {chatname} ({n} exchanges)', {chatname: chatName, n: Math.floor(exchanges.length/2)}));
    focusPromptDeferred();
}

// Create a Free (standalone) chat — called from Chats tab
async function newFreeChat() {
    if (!ckOnce('newFreeChat', 900)) return;       // a double click made two chats
    // E5: instant create with auto-name "Chat N" (N = existing free-chat count + 1).
    // User can then rename inline from the chat list.
    let n = 1;
    try {
        const lr = await fetch('files.php?action=list_chats&project=_standalone');
        const ld = await lr.json();
        if (ld.ok && Array.isArray(ld.chats)) n = ld.chats.length + 1;
    } catch(e) {}
    const finalName = 'Chat ' + n;
    const res  = await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'new_chat', project:'_standalone', name:finalName})
    });
    const data = await res.json();
    if (data.ok) {
        await switchToChat(data.slug, '_standalone');
        await loadChats();
        // Auto-focus the rename input on the freshly created row. Locate it by
        // data-slug (the inline ondblclick attribute was removed in the Hebrew
        // escaping fix, so the old attribute-scan no longer works).
        setTimeout(() => {
            const nameEl = document.querySelector(
                '#chats-list .sb-item-name[data-slug="' + (window.CSS && CSS.escape ? CSS.escape(data.slug) : data.slug) + '"]');
            if (nameEl) renameChat(data.slug, '_standalone', nameEl);
        }, 150);
    }
}

// Create an owned chat — called from Projects tab
async function newProjectChat(projectName) {
    if (!ckOnce('newProjectChat:' + projectName, 900)) return;
    // E5: same instant-create pattern, scoped per project
    let n = 1;
    try {
        const lr = await fetch('files.php?action=list_chats&project=' + encodeURIComponent(projectName));
        const ld = await lr.json();
        if (ld.ok && Array.isArray(ld.chats)) n = ld.chats.length + 1;
    } catch(e) {}
    const finalName = 'Chat ' + n;
    const res  = await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'new_chat', project:projectName, name:finalName})
    });
    const data = await res.json();
    if (data.ok) {
        await switchToChat(data.slug, projectName);
        await loadProjects();
        setTimeout(() => {
            const nameEl = document.querySelector(
                '.sb-item-name[data-slug="' + (window.CSS && CSS.escape ? CSS.escape(data.slug) : data.slug) + '"]');
            if (nameEl) renameChat(data.slug, projectName, nameEl);
        }, 150);
    }
}

// Delete an entire project (folder + all its chats). Irreversible — guarded
// by a confirm dialog. The "+ New" project flow lives above; this is its
// counterpart on the project row's trash icon.
async function deleteProject(name) {
    if (!name) return;
    if (!await cockpitConfirm('Delete project?', 'Delete project "' + name + '" and ALL of its chats?\n\nThis permanently removes the folder and cannot be undone.', 'Delete', {danger:true, icon:'delete'})) return;
    try {
        const r = await fetch('files.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({action:'delete_project', project:name})
        });
        const d = await r.json();
        if (d.ok) {
            appendSystem(T('msg.deleted.project.name.removed.files', 'Deleted project: {name} ({removed} files).', {name: name, removed: (d.removed ?? 0)}));
            // If we were inside the deleted project, drop back to a safe default.
            if (typeof currentProject !== 'undefined' && currentProject === name) {
                // Land on a real chat of the default project (switchToProject sets the project, the chat, the header, the status path
                // and the remembered project), so nothing keeps pointing at the folder that no longer exists.
                currentProject = 'default';
                currentChat    = 'default';
                try { localStorage.removeItem('cockpit_last_project'); } catch (e) {}
                if (typeof switchToProject === 'function') await switchToProject('default');
                else if (typeof updateStatusbarPath === 'function') updateStatusbarPath('default', 'default');
            }
            loadProjects();
        } else {
            appendSystem(d.message || ('[DELETE PROJECT] ' + (d.error || 'unknown error')));
        }
    } catch(e) {
        appendError(T('msg.delete.project.message', '[DELETE PROJECT] {message}', {message: e.message}));
    }
}

// Move a Free chat to a project
