// Sidebar toggle
// =============================================================================
function toggleSidebar(side) {
    if (window.innerWidth <= 900) {
        mobileShowSidebar(side);
        return;
    }
    const el = document.getElementById('sidebar-' + side);
    el.classList.toggle('collapsed');
}

// =============================================================================
// Tab switching — left sidebar has live data loading
// =============================================================================
// Tab names and icons for title bars
const PANEL_TITLES = {
    // Right panel
    preview:      { icon: 'visibility',    label: 'Preview' },
    code:         { icon: 'code',          label: 'Code' },
    library:      { icon: 'menu_book',     label: 'Knowledge Library' },
    snippets:     { icon: 'code_blocks',   label: 'Snippets' },
    sources:      { icon: 'inventory_2',   label: 'Source Projects' },
    config:       { icon: 'settings',      label: 'Configuration' },
    search:       { icon: 'search',        label: 'Web Search' },
    capabilities: { icon: 'extension',     label: 'Capabilities' },
    plans:        { icon: 'list_alt',      label: 'Plans' },
    artifacts:    { icon: 'inventory_2',   label: 'Artifacts' },
    usage:        { icon: 'monitoring',    label: 'Usage' },
    // Left panel
    chats:        { icon: 'chat',          label: 'Chats' },
    projects:     { icon: 'folder_open',   label: 'Projects' },
    filetree:     { icon: 'description',   label: 'Files' },
};

// ?solo=<panelId> — this page is a detached window showing that panel alone.
const _soloPanel = new URLSearchParams(location.search).get('solo') || '';
if (_soloPanel) window.addEventListener('error', e => { window.__soloErr = (e && e.message) || 'error'; });
if (_soloPanel) document.addEventListener('DOMContentLoaded', () => { try { soloApply(); } catch (e) { console.warn('solo', e); } });
function detachPanel(panelId) {
    const side = document.getElementById('left-' + panelId) ? 'left' : 'right';
    const info = PANEL_TITLES[panelId] || { label: panelId };
    shellCall('open_window', {
        url: location.pathname + '?solo=' + encodeURIComponent(panelId),
        title: 'AI Cockpit — ' + info.label, w: 820, h: 760,
    }).catch(e => appendSystem(T('msg.detach.failed.message', 'Detach failed: {message}', {message: e.message})));
    void side;
}
// In a detached window: show that panel and nothing else, then keep it fed by
// the same refresh the sidebar uses.
function _soloNote(html) {
    const d = document.createElement('div');
    d.id = 'solo-note';
    d.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#0f141c;color:#cbd5e0;font:13px system-ui,sans-serif;padding:24px;line-height:1.7;overflow:auto';
    d.innerHTML = html;
    document.body.appendChild(d);
}
function soloApply() {
    if (!_soloPanel) return;
    const panel = document.getElementById('right-' + _soloPanel) || document.getElementById('left-' + _soloPanel);
    if (!panel) {
        document.title = 'Cockpit solo: no panel "' + _soloPanel + '"';
        _soloNote('<b>No panel called "' + _soloPanel + '"</b> in this build.<br>Close with Escape.');
        return;
    }
    document.body.classList.add('solo');
    document.querySelectorAll('.sidebar-panel').forEach(p => { p.classList.remove('active'); p.style.display = 'none'; });
    const side = panel.id.startsWith('left-') ? 'left' : 'right';
    document.getElementById('sidebar-' + (side === 'left' ? 'right' : 'left'))?.remove();
    panel.classList.add('active'); panel.style.display = 'flex';
    _injectPanelTitle(panel, _soloPanel);
    document.title = 'AI Cockpit - ' + (PANEL_TITLES[_soloPanel]?.label || _soloPanel);
    // Say what happened when the panel stays empty: a detached window with no
    // visible content is otherwise indistinguishable from a broken one.
    setTimeout(() => {
        const t = (document.body.innerText || '').replace(/\s+/g, ' ').trim();
        const pr = panel.getBoundingClientRect();
        document.title = 'Cockpit solo: ' + _soloPanel + ' ' + Math.round(pr.width) + 'x' + Math.round(pr.height) + ' text:' + t.length;
        if (t.length > 40) { document.title = 'AI Cockpit - ' + (PANEL_TITLES[_soloPanel]?.label || _soloPanel); return; }
        _soloNote('<b>' + (PANEL_TITLES[_soloPanel]?.label || _soloPanel) + '</b> has nothing to show here yet.<br>' +
            'Panel box: ' + Math.round(pr.width) + ' x ' + Math.round(pr.height) + ' · display: ' + getComputedStyle(panel).display + '<br>' +
            'Session: ' + (window._cockpitUser ? ('signed in as ' + window._cockpitUser) : 'not signed in') + '<br>' +
            'Gate: ' + (window._authGateOpen ? 'open' : 'closed') + ' · Project: ' + (currentProject || '-') + ' / ' + (currentChat || '-') + '<br>' +
            'Window: ' + innerWidth + ' x ' + innerHeight + ' · body: ' + document.body.className + '<br>' +
            'Last error: ' + (window.__soloErr || 'none') + '<br><br>' +
            'Ctrl+R reloads, Escape closes this window.');
    }, 3500);
    // The panel loads as soon as there is a session, then keeps itself current:
    // the chat is switched in the main window, so this page polls for it.
    const SOLO_LOADERS = {
        chats: () => loadChats(), projects: () => loadProjects(), filetree: () => loadFileTree(),
        notes: () => notesInit(), preview: () => {}, capabilities: () => capRefresh(),
        search: () => {}, library: () => rpRefreshList('library'), snippets: () => rpRefreshList('snippets'),
        sources: () => rpRefreshList('sources'), code: () => rpRefreshList('code'),
        artifacts: () => artifactsRefresh(),
    };
    const load = () => {
        try { refreshChatScopedPanels(); } catch (e) {}
        try { SOLO_LOADERS[_soloPanel] && SOLO_LOADERS[_soloPanel](); } catch (e) { console.warn('solo loader', e); }
    };
    if (window.authGateReady) window.authGateReady().then(load); else load();
    setInterval(load, 15000);
}

function _injectPanelTitle(panel, panelId) {
    if (!panel) return;
    // Remove existing title bar if present
    const existing = panel.querySelector('.sidebar-panel-title');
    if (existing) existing.remove();
    // Get title info
    const info = PANEL_TITLES[panelId] || { icon: 'circle', label: panelId };
    // Create title bar
    const bar = document.createElement('div');
    bar.className = 'sidebar-panel-title';
    bar.innerHTML =
        '<span class="material-symbols-rounded">' + info.icon + '</span>' +
        '<span>' + info.label + '</span>' +
        ((_inShell && !_soloPanel) ? '<span class="material-symbols-rounded sidebar-panel-detach" title="Open this panel in its own window">open_in_new</span>' : '');
    const det = bar.querySelector('.sidebar-panel-detach');
    if (det) det.onclick = (e) => { e.stopPropagation(); detachPanel(panelId); };
    // Hover hint from the panel's help topic (2026-09-13)
    const topic = panel.dataset.help && _helpData && _helpData.topics && _helpData.topics[panel.dataset.help];
    if (topic) { const t = document.createElement('div'); t.innerHTML = topic.body || ''; bar.title = (t.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 220); }
    else bar.title = info.label + ' panel';
    // Insert as first child of panel
    panel.insertBefore(bar, panel.firstChild);
}

function switchTab(side, panelId, tabEl) {
    const sidebar = document.getElementById('sidebar-' + side);
    sidebar.querySelectorAll('.sidebar-tab, .sidebar-vtab').forEach(t => t.classList.remove('active'));
    sidebar.querySelectorAll('.sidebar-panel').forEach(p => {
        p.classList.remove('active');
        p.style.display = 'none';
    });
    tabEl.classList.add('active');
    const panel = document.getElementById(side + '-' + panelId);
    if (panel) {
        panel.classList.add('active');
        panel.style.display = 'flex';
        _injectPanelTitle(panel, panelId);
    }

    // Persist selected tab
    localStorage.setItem('cockpit_last_' + side + '_tab', panelId);

    // Lazy-load tab contents on first activation (or refresh on each click)
    if (side === 'right') {
        if (panelId === 'config')        rpLoadConfig();
        if (panelId === 'capabilities')  capRefresh();
        if (panelId === 'plans')         plansRefresh();
        if (panelId === 'usage')         usageParserRefresh();
        if (panelId === 'attachments')   attachPanelRefresh();
        if (panelId === 'artifacts')     artifactsRefresh();
    }

    // Refresh Code panel if switching to code
    if (side === 'right' && panelId === 'code') rpRefreshList('code');
}

function switchLeftTab(panelId, tabEl) {
    switchTab('left', panelId, tabEl);
    localStorage.setItem('cockpit_last_left_tab', panelId);
    if (panelId === 'chats')    loadChats();
    if (panelId === 'projects') loadProjects();
    if (panelId === 'filetree') loadFileTree();
    if (panelId === 'notes')    notesInit();
}

// =============================================================================
// NOTES (Form A internal + Form B folder) — shared engine over notes.php
// =============================================================================
let _notesScope = 'internal';
let _notesOpenId = '';      // currently-open note id
let _notesOpenScope = '';   // scope the open note came from (for read-only foreign)
let _notesCfg = { auto_ai:false, ai_model:'gemma3:4b' };
let _notesInited = false;

async function notesInit() {
    const sel = document.getElementById('notes-scope'); if (sel) _notesScope = sel.value;
    if (!_notesInited) {
        try { const r = await fetch('notes.php?action=get_config'); const d = await r.json(); if (d.ok) _notesCfg = d.config; } catch(e){}
        _notesInited = true;
    }
    notesLoad();
}

function notesScopeChange() {
    _notesScope = document.getElementById('notes-scope').value;
    if (_notesScope === 'folder') { notesEnsureFolder().then(ok => { if (ok) notesLoad(); }); }
    else notesLoad();
}

// =============================================================================
// cockpitPathPicker — reusable server-side path/file browser.
//   opts.mode: 'folder' (default) | 'open' (pick a file) | 'save' (dir+filename)
//   opts.start, opts.title, opts.exts:[...], opts.defaultName (save)
//   → Promise resolving to an absolute path (folder, or file), or null on cancel.
// =============================================================================
function cockpitPathPicker(opts) {
    opts = opts || {};
    const mode = opts.mode || 'folder';
    const wantFiles = mode !== 'folder';
    const titles = { folder:'Select a folder', open:'Open a file', save:'Save file as' };
    const primaryLabel = { folder:'Use this folder', open:'Open', save:'Save' }[mode];
    return new Promise(resolve => {
        document.getElementById('cockpit-path-picker')?.remove();
        const ov = document.createElement('div');
        ov.id = 'cockpit-path-picker';
        ov.style.cssText = 'position:fixed;inset:0;z-index:100100;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        ov.innerHTML =
            '<div style="background:var(--bg-base);border:1px solid var(--accent-blue);border-radius:6px;width:min(560px,92vw);max-height:82vh;display:flex;flex-direction:column;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
            '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding:10px 14px;">' +
            '<span class="material-symbols-rounded" style="color:var(--accent-blue);font-size:18px;">' + (wantFiles?'description':'folder_open') + '</span>' +
            '<h2 style="margin:0;font-size:13px;color:var(--accent-blue);flex:1;">' + _esc(opts.title || titles[mode]) + '</h2>' +
            '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" data-role="x">×</span></div>' +
            '<div style="display:flex;gap:4px;padding:8px 14px;">' +
            '<input data-role="path" type="text" placeholder="/home/…" style="flex:1;background:var(--bg-panel);color:var(--text-base);border:1px solid var(--border-mid);border-radius:4px;font-family:var(--font-mono);font-size:11px;padding:5px 8px;">' +
            '<button class="action-btn" data-role="go" style="padding:4px 10px;">Go</button>' +
            '<button class="action-btn" data-role="up" title="Parent folder" style="padding:4px 10px;">↑ Up</button>' +
            '<button class="action-btn" data-role="mkdir" title="Create a new folder here" style="padding:4px 10px;"><span class="material-symbols-rounded" style="font-size:13px;vertical-align:-2px;">create_new_folder</span></button>' +
            '</div>' +
            '<div data-role="mkbar" style="display:none;gap:4px;padding:0 14px 8px;align-items:center;">' +
            '<span class="material-symbols-rounded" style="font-size:14px;color:var(--gemini);">create_new_folder</span>' +
            '<input data-role="mkname" type="text" placeholder="new folder name — Enter to create" style="flex:1;background:var(--bg-panel);color:var(--text-base);border:1px solid var(--accent-blue);border-radius:4px;font-size:11px;padding:4px 8px;">' +
            '<button class="action-btn" data-role="mkok" style="padding:3px 10px;">Create</button>' +
            '<button class="action-btn" data-role="mkcancel" style="padding:3px 8px;">×</button>' +
            '</div>' +
            '<div data-role="list" style="flex:1;overflow:auto;min-height:170px;max-height:46vh;padding:4px 8px;font-size:12px;"></div>' +
            (mode === 'save' ? '<div style="padding:6px 14px;border-top:1px solid var(--border-dim);"><input data-role="name" type="text" placeholder="filename" value="' + _esc(opts.defaultName||'') + '" style="width:100%;box-sizing:border-box;background:var(--bg-panel);color:var(--text-base);border:1px solid var(--border-mid);border-radius:4px;font-family:var(--font-mono);font-size:11px;padding:5px 8px;"></div>' : '') +
            '<div style="display:flex;gap:8px;justify-content:space-between;align-items:center;border-top:1px solid var(--border-dim);padding:10px 14px;">' +
            '<div style="display:flex;align-items:center;gap:10px;">' +
            '<label style="font-size:10px;color:var(--text-dim);"><input type="checkbox" data-role="hidden"> show hidden</label>' +
            (opts.onDeviceUpload ? '<button class="action-btn" data-role="deviceup" title="Upload a file from this device (your computer, not the server)" style="padding:4px 10px;display:inline-flex;align-items:center;gap:4px;"><span class="material-symbols-rounded" style="font-size:13px;">upload</span>Upload from device</button>' : '') +
            '</div>' +
            '<div style="display:flex;gap:8px;"><button class="action-btn" data-role="cancel" style="padding:5px 14px;">Cancel</button>' +
            '<button class="action-btn" data-role="use" style="padding:5px 16px;background:var(--accent-blue);color:var(--bg-base);border-color:var(--accent-blue);font-weight:600;">' + primaryLabel + '</button></div>' +
            '</div></div>';
        document.body.appendChild(ov);
        const $ = r => ov.querySelector('[data-role="'+r+'"]');
        let cur = opts.start || '';
        let selectedFile = null;
        const close = v => { ov.remove(); resolve(v); };
        async function nav(p) {
            const hidden = $('hidden').checked ? 1 : 0;
            try {
                const r = await fetch('browse.php?action=list', {method:'POST',headers:{'Content-Type':'application/json'},
                    body:JSON.stringify({path:p, files:wantFiles?1:0, hidden, exts:opts.exts||[]})});
                const d = await r.json();
                const list = $('list');
                if (!d.ok) { list.innerHTML = '<div style="color:var(--accent-orange);padding:6px;">'+_esc(d.error||'error')+'</div>'; return; }
                cur = d.path; $('path').value = d.path; selectedFile = null;
                $('up').dataset.parent = d.parent || '';
                let html = '';
                d.dirs.forEach(dir => {
                    html += '<div class="cpp-item" data-go="'+_esc(dir.path)+'" style="padding:4px 8px;cursor:pointer;display:flex;align-items:center;gap:6px;border-radius:3px;'+(dir.readable?'':'opacity:.5;')+'">'+
                        '<span class="material-symbols-rounded" style="font-size:14px;color:var(--gemini);">folder</span>'+_esc(dir.name)+'</div>';
                });
                (d.files||[]).forEach(f => {
                    html += '<div class="cpp-item cpp-file" data-file="'+_esc(f.path)+'" data-name="'+_esc(f.name)+'" style="padding:4px 8px;cursor:pointer;display:flex;align-items:center;gap:6px;border-radius:3px;color:var(--text-base);">'+
                        '<span class="material-symbols-rounded" style="font-size:14px;color:var(--text-dim);">draft</span>'+_esc(f.name)+
                        '<span style="margin-left:auto;color:var(--text-dim);font-size:10px;">'+Math.max(1,Math.round(f.size/1024))+'K</span></div>';
                });
                if (!html) html = '<div style="color:var(--text-dim);padding:6px;">(empty)</div>';
                list.innerHTML = html;
                list.querySelectorAll('[data-go]').forEach(el => el.onclick = () => nav(el.dataset.go));
                list.querySelectorAll('[data-file]').forEach(el => el.onclick = () => {
                    if (mode === 'open') { close(el.dataset.file); return; }
                    if (mode === 'save') { const ni=$('name'); if(ni) ni.value = el.dataset.name; }
                });
            } catch(e) { $('list').innerHTML = '<div style="color:var(--accent-orange);padding:6px;">'+_esc(e.message)+'</div>'; }
        }
        $('x').onclick = () => close(null);
        $('cancel').onclick = () => close(null);
        if (opts.onDeviceUpload) $('deviceup').onclick = () => { close(null); opts.onDeviceUpload(); };
        $('use').onclick = () => {
            if (mode === 'folder') return close(($('path').value || cur).trim() || null);
            if (mode === 'save') { const n=($('name')?.value||'').trim(); if(!n){ appendSystem(T('msg.enter.a.filename', 'Enter a filename.')); return; } return close((cur.replace(/\/+$/,''))+'/'+n); }
            // open mode: resolve typed path if it's a file path
            return close(($('path').value||'').trim() || null);
        };
        $('go').onclick = () => nav($('path').value.trim());
        $('up').onclick = () => { const p = $('up').dataset.parent; if (p) nav(p); };
        const doMkdir = async () => {
            const name = ($('mkname').value || '').trim();
            if (!name) return;
            const r = await fetch('browse.php?action=mkdir', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:cur, name})});
            const d = await r.json();
            if (!d.ok) { appendSystem(T('msg.new.folder.error', 'New folder: {error}', {error: (d.error||'failed')})); return; }
            $('mkbar').style.display = 'none'; $('mkname').value = '';
            nav(d.path);   // enter the new folder
        };
        $('mkdir').onclick = () => { const b=$('mkbar'); b.style.display = (b.style.display==='none'?'flex':'none'); if(b.style.display==='flex') $('mkname').focus(); };
        $('mkok').onclick = doMkdir;
        $('mkcancel').onclick = () => { $('mkbar').style.display='none'; $('mkname').value=''; };
        $('mkname').addEventListener('keydown', e => { if(e.key==='Enter'){ e.preventDefault(); doMkdir(); } if(e.key==='Escape'){ $('mkbar').style.display='none'; } });
        $('path').addEventListener('keydown', e => { if (e.key === 'Enter') nav($('path').value.trim()); });
        $('hidden').onchange = () => nav(cur);
        ov.addEventListener('click', e => { if (e.target === ov) close(null); });
        nav(opts.start || '');
    });
}
// Back-compat wrapper (Notepad folder).
function notesFolderPicker(startPath) {
    return cockpitPathPicker({ mode:'folder', start:startPath || '', title:'Select Notepad folder' });
}

// Fetch a server file's bytes and wrap as a File object (for import handlers).
async function cockpitServerFileToFile(path) {
    const r = await fetch('browse.php?action=read', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path})});
    const d = await r.json();
    if (!d.ok) { appendSystem(T('msg.read.failed.error', 'Read failed: {error}', {error: (d.error||'?')})); return null; }
    const bin = atob(d.b64); const arr = new Uint8Array(bin.length);
    for (let i=0;i<bin.length;i++) arr[i] = bin.charCodeAt(i);
    return new File([arr], d.name, { type: d.mime || '' });
}
// Cockpit picker → inject the chosen server file into a hidden <input type=file>
// and fire its change event, so existing import handlers work unchanged.
async function cockpitPickIntoInput(inputId, exts, title) {
    const path = await cockpitPathPicker({ mode:'open', exts: exts||[], title: title||'Select a file' });
    if (!path) return;
    const file = await cockpitServerFileToFile(path);
    if (!file) return;
    const input = document.getElementById(inputId);
    if (!input) return;
    try { const dt = new DataTransfer(); dt.items.add(file); input.files = dt.files; }
    catch(e) { appendSystem(T('msg.picker.not.supported.here.use.the.browser.up', 'Picker not supported here — use the browser upload.')); return; }
    input.dispatchEvent(new Event('change', { bubbles:true }));
}

// Manage scan folders for a store kind (snippets / library / sources).
async function scanFoldersManager(kind) {
    let all = { snippets:[], library:[], sources:[] };
    try { const r = await fetch('library.php?action=get_paths'); const d = await r.json(); if (d.ok && d.paths) all = Object.assign(all, d.paths); } catch(e){}
    let list = Array.isArray(all[kind]) ? all[kind].slice() : [];
    document.getElementById('scanfolders-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'scanfolders-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100050;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--accent-blue);border-radius:6px;width:min(520px,92vw);max-height:80vh;display:flex;flex-direction:column;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding:10px 14px;">' +
        '<span class="material-symbols-rounded" style="color:var(--accent-blue);font-size:18px;">create_new_folder</span>' +
        '<h2 style="margin:0;font-size:13px;color:var(--accent-blue);flex:1;">Scan folders — ' + _esc(kind) + '</h2>' +
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" data-role="x">×</span></div>' +
        '<div style="font-size:11px;color:var(--text-dim);padding:8px 14px 0;">Cockpit indexes files in these folders on Rescan' + (kind==='library'?' (and extracts text for search)':'') + '.</div>' +
        '<div data-role="list" style="flex:1;overflow:auto;min-height:80px;max-height:46vh;padding:8px 14px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:space-between;border-top:1px solid var(--border-dim);padding:10px 14px;">' +
        '<button class="action-btn" data-role="add"><span class="material-symbols-rounded" style="font-size:13px;vertical-align:-2px;">add</span> Add folder</button>' +
        '<div style="display:flex;gap:8px;"><button class="action-btn" data-role="cancel" style="padding:5px 14px;">Cancel</button>' +
        '<button class="action-btn" data-role="save" style="padding:5px 16px;background:var(--accent-blue);color:var(--bg-base);border-color:var(--accent-blue);font-weight:600;">Save &amp; rescan</button></div>' +
        '</div></div>';
    document.body.appendChild(ov);
    const $ = r => ov.querySelector('[data-role="'+r+'"]');
    const render = () => {
        if (!list.length) { $('list').innerHTML = '<div style="color:var(--text-dim);padding:6px;">No folders yet — click "Add folder".</div>'; return; }
        $('list').innerHTML = list.map((p,i) =>
            '<div style="display:flex;align-items:center;gap:6px;padding:4px 0;font-size:12px;font-family:var(--font-mono);">' +
            '<span class="material-symbols-rounded" style="font-size:14px;color:var(--gemini);">folder</span>' +
            '<span style="flex:1;word-break:break-all;">' + _esc(p) + '</span>' +
            '<span class="material-symbols-rounded" data-rm="' + i + '" style="font-size:15px;cursor:pointer;color:var(--accent-orange);">delete</span></div>'
        ).join('');
        $('list').querySelectorAll('[data-rm]').forEach(el => el.onclick = () => { list.splice(+el.dataset.rm,1); render(); });
    };
    $('x').onclick = $('cancel').onclick = () => ov.remove();
    $('add').onclick = async () => { const p = await cockpitPathPicker({mode:'folder', title:'Add a scan folder'}); if (p && !list.includes(p)) { list.push(p); render(); } };
    $('save').onclick = async () => {
        all[kind] = list;
        await fetch('library.php?action=set_paths', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({paths:all})});
        ov.remove();
        appendSystem(T('msg.scan.folders.saved.for.kind.rescanning', 'Scan folders saved for {kind} — rescanning…', {kind: kind}));
        if (typeof rpRescan === 'function') rpRescan(kind);
    };
    render();
}

// Library: add a book/article by picking a file (extracts text → searchable).
async function libraryAddViaPicker() {
    const p = await cockpitPathPicker({ mode:'open', title:'Add a book / article to Library',
        exts:['pdf','epub','chm','docx','odt','rtf','fb2','html','htm','txt','md','csv'] });
    if (!p) return;
    const r = await fetch('library.php?action=add_file', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p})});
    const d = await r.json();
    if (!d.ok) { appendSystem(T('msg.library.error', 'Library: {error}', {error: (d.error||'failed')})); return; }
    appendSystem(T('msg.added.to.libraryextracted.build.the.deep.sea', 'Added to Library{extracted} Build the deep-search index to include it.', {extracted: (d.extracted ? ' (text extracted — searchable).' : '.')}));
    if (typeof rpRefreshList === 'function') rpRefreshList('library');
}

async function notesEnsureFolder() {
    try {
        const r = await fetch('notes.php?action=get_folder'); const d = await r.json();
        if (d.ok && d.path) return true;
    } catch(e){}
    const p = await notesFolderPicker('');
    if (p === null || !p.trim()) { appendSystem(T('msg.notepad.no.folder.set', 'Notepad: no folder set.')); return false; }
    const r = await fetch('notes.php?action=set_folder', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p.trim()})});
    const d = await r.json();
    if (!d.ok) { appendSystem(T('msg.notepad.folder.error', 'Notepad folder: {error}', {error: (d.error||'failed')})); return false; }
    appendSystem(T('msg.notepad.folder.set.path', 'Notepad folder set: {path}', {path: d.path})); return true;
}

async function notesLoad() {
    const list = document.getElementById('notes-list'); if (!list) return;
    const q = (document.getElementById('notes-search')?.value || '').trim();
    const foreign = document.getElementById('notes-xlink')?.checked ? 1 : 0;
    try {
        const r = await fetch('notes.php?action=search', {method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({scope:_notesScope, q, include_foreign:foreign})});
        const d = await r.json();
        if (!d.ok) { list.innerHTML = '<div class="sidebar-empty">'+_esc(d.error||'error')+'</div>'; return; }
        if (!d.results.length) { list.innerHTML = '<div class="sidebar-empty">No notes.</div>'; return; }
        list.innerHTML = '';
        d.results.forEach(n => {
            const it = document.createElement('div');
            it.className = 'sb-item'; it.style.cssText = 'padding:5px 8px;cursor:pointer;font-size:11px;';
            const foreignTag = (n.scope && n.scope !== _notesScope) ? ' <span style="color:var(--text-dim);">['+n.scope+']</span>' : '';
            it.innerHTML = '<div style="font-weight:600;">'+_esc(n.title)+foreignTag+'</div>'+
                '<div style="color:var(--text-dim);font-size:10px;">'+_esc((n.tags||[]).join(', '))+'</div>';
            it.onclick = () => notesOpen(n.id, n.scope || _notesScope, n.title, (n.tags||[]).join(', '));
            list.appendChild(it);
        });
    } catch(e) { list.innerHTML = '<div class="sidebar-empty">'+_esc(e.message)+'</div>'; }
}

async function notesOpen(id, scope, title, tags) {
    _notesOpenId = id; _notesOpenScope = scope || _notesScope;
    try {
        const r = await fetch('notes.php?action=read', {method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({scope:_notesOpenScope, id})});
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.note.error', 'Note: {error}', {error: (d.error||'read failed')})); return; }
        document.getElementById('note-title').value = title || '';
        document.getElementById('note-tags').value = tags || '';
        document.getElementById('note-body').value = d.content || '';
        const ro = _notesOpenScope !== _notesScope;
        document.getElementById('note-summary').textContent = ro ? '[read-only — from '+_notesOpenScope+' store; Save copies into '+_notesScope+']' : '';
    } catch(e){ appendSystem(T('msg.note.error.message', 'Note error: {message}', {message: e.message})); }
}

function notesNew() {
    _notesOpenId = ''; _notesOpenScope = _notesScope;
    document.getElementById('note-title').value = '';
    document.getElementById('note-tags').value = '';
    document.getElementById('note-body').value = '';
    document.getElementById('note-summary').textContent = '';
}

async function notesSave() {
    const title = document.getElementById('note-title').value.trim() || 'Untitled';
    const content = document.getElementById('note-body').value;
    const tags = document.getElementById('note-tags').value.split(',').map(t=>t.trim()).filter(Boolean);
    // saving always writes to the CURRENT editing scope; foreign-opened notes copy in
    const id = (_notesOpenScope === _notesScope) ? _notesOpenId : '';
    try {
        const r = await fetch('notes.php?action=save', {method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({scope:_notesScope, id, title, content, tags})});
        const d = await r.json();
        if (!d.ok) { appendSystem(T('msg.save.error', 'Save: {error}', {error: (d.error||'failed')})); return; }
        _notesOpenId = d.id; _notesOpenScope = _notesScope;
        appendSystem(T('msg.note.saved', 'Note saved.'));
        notesLoad();
        if (_notesCfg.auto_ai) notesProcessNow(true);
    } catch(e){ appendSystem(T('msg.save.error.message', 'Save error: {message}', {message: e.message})); }
}

async function notesProcessNow(silent) {
    // Empty state, not a failure: Process now summarises the OPEN note.
    if (!_notesOpenId) { if(!silent) appendSystem(T('msg.nothing.to.process.yet.open.a.note.or.write', 'Nothing to process yet — open a note (or write one and press Save); Process now then summarises it with a small local model and suggests tags.')); return; }
    const sum = document.getElementById('note-summary');
    if (sum && !silent) sum.textContent = T('msg.processing.4b.model', 'Processing (≤4B model)…');
    try {
        const r = await fetch('notes.php?action=ai_process', {method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({scope:_notesScope, id:_notesOpenId})});
        const d = await r.json();
        if (!d.ok) { if(sum) sum.textContent = 'AI: '+(d.error||'failed'); return; }
        if (sum) sum.innerHTML = '<span class="material-symbols-rounded ico">check</span> '+_esc(d.summary||'')+(d.tags&&d.tags.length?'  ['+_esc(d.tags.join(', '))+']':'');
        if (d.tags && d.tags.length) document.getElementById('note-tags').value = d.tags.join(', ');
        notesLoad();
    } catch(e){ if(sum) sum.textContent = 'AI error: '+e.message; }
}

async function notesDelete() {
    if (!_notesOpenId) return;
    if (!await cockpitConfirm('Delete note', 'Delete this note? This cannot be undone.', 'Delete', {danger:true, icon:'delete'})) return;
    try {
        await fetch('notes.php?action=delete', {method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({scope:_notesOpenScope, id:_notesOpenId})});
        notesNew(); notesLoad();
    } catch(e){ appendSystem(T('msg.delete.error.message', 'Delete error: {message}', {message: e.message})); }
}

async function notesChatWith() {
    const scopes = [_notesScope];
    if (document.getElementById('notes-xlink')?.checked) scopes.push(_notesScope==='internal'?'folder':'internal');
    const q = (promptInput?.value || document.getElementById('note-title')?.value || '').trim();
    try {
        const r = await fetch('notes.php?action=rag_context', {method:'POST',headers:{'Content-Type':'application/json'},
            body:JSON.stringify({q, scopes, limit:5})});
        const d = await r.json();
        if (!d.ok || !d.context.length) { appendSystem(T('msg.no.matching.notes.for.context', 'No matching notes for context.')); return; }
        let block = '[Notes context]\n';
        d.context.forEach(c => { block += '— '+(c.title||c.id)+' ('+c.scope+'):\n'+c.content+'\n\n'; });
        block += '[End notes context]\n\n';
        if (typeof _injectBlock === 'function') _injectBlock(block);
        else { promptInput.value = block + promptInput.value; promptInput.focus(); }
        appendSystem(T('msg.injected.n.note.s.as.context.type.your.quest', 'Injected {n} note(s) as context. Type your question and send.', {n: d.context.length}));
    } catch(e){ appendSystem(T('msg.chat.with.notes.error.message', 'Chat-with-notes error: {message}', {message: e.message})); }
}

function notesSettings() {
    let ov = document.getElementById('notes-settings-ov'); if (ov) ov.remove();
    ov = document.createElement('div'); ov.id='notes-settings-ov';
    ov.style.cssText='position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(380px,92vw);padding:18px;display:flex;flex-direction:column;gap:10px;">'+
        '<div style="display:flex;align-items:center;"><h2 style="margin:0;font-size:14px;flex:1;">Notes settings</h2><span style="cursor:pointer;color:var(--text-dim);" onclick="this.closest(\'#notes-settings-ov\').remove()">×</span></div>'+
        '<label style="font-size:12px;display:flex;align-items:center;gap:8px;"><input type="checkbox" id="ns-autoai" '+(_notesCfg.auto_ai?'checked':'')+'> Auto-summarize &amp; tag on save (uses a local ≤4B model)</label>'+
        '<label style="font-size:12px;">AI model (≤4B) <input id="ns-model" value="'+_esc(_notesCfg.ai_model||'gemma3:4b')+'" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 7px;font-size:12px;border-radius:3px;"></label>'+
        '<label style="font-size:12px;">Notepad folder (Form B) <div style="display:flex;gap:4px;"><input id="ns-folder" placeholder="(set on first use)" style="flex:1;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 7px;font-size:12px;border-radius:3px;"><button class="sidebar-action-btn" onclick="notesBrowseFolderInto()">Browse</button><button class="sidebar-action-btn" onclick="notesSetFolderFromInput()">Set</button></div></label>'+
        '<button class="sidebar-action-btn" style="align-self:flex-end;" onclick="notesSaveSettings()">Save</button>'+
        '</div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e=>{ if(e.target===ov) ov.remove(); });
    fetch('notes.php?action=get_folder').then(r=>r.json()).then(d=>{ if(d.ok&&d.path) document.getElementById('ns-folder').value=d.path; });
}
async function notesBrowseFolderInto() {
    const p = await notesFolderPicker(document.getElementById('ns-folder')?.value || '');
    if (p) document.getElementById('ns-folder').value = p;
}
async function notesSetFolderFromInput() {
    const p = document.getElementById('ns-folder').value.trim(); if(!p) return;
    const r = await fetch('notes.php?action=set_folder',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:p})});
    const d = await r.json(); appendSystem(T('msg.notepad.folder.ok', 'Notepad folder: {ok}', {ok: (d.ok?d.path:(d.error||'failed'))}));
}
async function notesSaveSettings() {
    _notesCfg.auto_ai = document.getElementById('ns-autoai').checked;
    _notesCfg.ai_model = document.getElementById('ns-model').value.trim() || 'gemma3:4b';
    await fetch('notes.php?action=set_config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(_notesCfg)});
    document.getElementById('notes-settings-ov')?.remove();
    appendSystem(T('msg.notes.settings.saved', 'Notes settings saved.'));
}

// Form B entry point — toolbar "Notepad" button: open Notes in folder mode.
async function notepadOpen() {
    const tab = document.querySelector('.sidebar-vtab[title="Notes"]');
    switchLeftTab('notes', tab);
    const ok = await notesEnsureFolder();
    const sel = document.getElementById('notes-scope');
    if (ok) {
        if (sel) sel.value = 'folder';
        _notesScope = 'folder';
        notesLoad();
    } else {
        // no folder chosen → stay on Internal notes, don't open an empty folder pane
        if (sel) sel.value = 'internal';
        _notesScope = 'internal';
        notesLoad();
    }
}

// =============================================================================
// =============================================================================
// Integrity + Terms (2026-09-13). integrity.php compares the install against
// the manifest shipped with its build. Shown: on every account's first use
// (together with the licence terms, which must be accepted once), whenever a
// check finds changed or missing files, and on demand from About. The modal
// offers Restore (the bundle the installer kept, via cockpit_restore.sh in a
// terminal — sudo asked there when the web root needs it) or Re-download.
// =============================================================================
async function integrityStatus() { try { return await (await fetch('integrity.php?action=status', {cache:'no-store'})).json(); } catch (e) { return null; } }
function _mdLite(md) {   // enough markdown for the licence: headings, bold, paragraphs, numbered lines
    return escHtml(md).replace(/^### (.*)$/gm, '<h4 style="margin:10px 0 4px;">$1</h4>').replace(/^## (.*)$/gm, '<h3 style="margin:14px 0 6px;font-size:13px;">$1</h3>')
        .replace(/^# (.*)$/gm, '<h2 style="margin:0 0 8px;font-size:15px;">$1</h2>').replace(/\*\*(.+?)\*\*/g, '<b>$1</b>').replace(/(^|[^*])\*([^*\n]+?)\*(?!\*)/g, '$1<i>$2</i>').replace(/\n\n/g, '<p></p>');
}
async function integrityShow(opts = {}) {
    const st = await integrityStatus(); if (!st) return;
    const firstUse = !!opts.firstUse;
    let lic = '';
    if (firstUse || opts.terms) { try { const d = await (await fetch('integrity.php?action=license')).json(); if (d.ok) lic = d.text; } catch (e) {} }
    document.getElementById('integrity-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'integrity-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100012;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    let integ = '';
    if (!st.has_manifest) integ = '<div style="color:var(--text-muted);">This install carries no manifest (built before 2026-09-13); nothing to compare against.</div>';
    else if (st.intact) integ = '<div style="color:var(--accent-green);"><span class="material-symbols-rounded ico">verified</span> Every shipped file matches the official build ' + escHtml((st.version || '') + ' · ' + (st.build_id || '').slice(0, 12)) + '…</div>';
    else integ = '<div style="color:var(--accent-amber);"><span class="material-symbols-rounded ico">warning</span> This install differs from the build it was installed from.</div>' +
        (st.changed.length ? '<div style="margin-top:4px;"><b>Changed (' + st.changed.length + ')</b>: <code style="font-family:var(--font-mono);font-size:10.5px;">' + escHtml(st.changed.slice(0, 12).join(', ')) + (st.changed.length > 12 ? ' …' : '') + '</code></div>' : '') +
        (st.missing.length ? '<div style="margin-top:4px;"><b>Missing (' + st.missing.length + ')</b>: <code style="font-family:var(--font-mono);font-size:10.5px;">' + escHtml(st.missing.slice(0, 12).join(', ')) + (st.missing.length > 12 ? ' …' : '') + '</code></div>' : '') +
        '<div style="margin-top:6px;color:var(--text-muted);">A changed build keeps working locally. Cockpit account services (accounts, marketplace, relay, Cruise, AutoCognition) are provided to official builds only. ' +
        (st.bundle_kept ? 'The installer kept the bundle at <code style="font-family:var(--font-mono);font-size:10.5px;">' + escHtml(st.bundle_kept) + '</code> — Restore puts the shipped files back (your config and data are untouched).' : 'No kept bundle was found — re-download and re-run the installer, or upgrade.') + '</div>';
    const g = st.guard || {};
    const guardHtml = (opts.terms || !st.has_manifest) ? '' :
        '<div style="margin-top:8px;font-size:11px;color:var(--text-muted);">Guard: <b style="color:' + (g.active ? 'var(--accent-green)' : 'var(--text-muted)') + ';">' + escHtml(g.state || '—') + '</b>' +
        (g.locked === true ? ' · shipped files are root-owned, read-only' : (g.locked === false ? ' · shipped files are user-writable' : '')) +
        (g.flag ? '<div style="color:var(--accent-amber);margin-top:3px;">Last change seen: ' + escHtml(g.flag.file || '') + ' (' + escHtml(g.flag.event || '') + ', ' + escHtml(g.flag.changed_at || '') + ')</div>' : '') +
        ((g.log || []).length ? '<details style="margin-top:4px;"><summary style="cursor:pointer;">guard log (last ' + g.log.length + ')</summary><pre style="font-size:9.5px;background:var(--bg-darker);padding:6px;margin-top:4px;border-radius:3px;overflow:auto;max-height:140px;">' + escHtml(g.log.join('\n')) + '</pre></details>' : '') + '</div>';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(720px,94vw);max-height:90vh;display:flex;flex-direction:column;padding:16px 18px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<h2 style="margin:0 0 8px;font-size:14px;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">' + (firstUse ? 'gavel' : 'verified_user') + '</span> ' + (firstUse ? 'Welcome — terms, licence and integrity' : (opts.terms ? 'Terms of Use and Licence (Apache-2.0)' : 'Install integrity')) + '</h2>' +
        (lic ? '<div id="integrity-terms" style="flex:1;min-height:120px;max-height:46vh;overflow:auto;border:1px solid var(--border-dim);border-radius:5px;padding:10px 12px;font-size:11.5px;line-height:1.5;background:var(--bg-darker);">' + _mdLite(lic) + '</div>' : '') +
        (!opts.terms ? '<div style="font-size:12px;line-height:1.5;margin-top:10px;">' + integ + guardHtml + '</div>' : '') +
        '<div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;margin-top:12px;">' +
        (st.has_manifest && !st.intact && st.bundle_kept ? '<button class="action-btn" style="margin-right:auto;border-color:var(--accent-amber);color:var(--accent-amber);" data-x="restore"><span class="material-symbols-rounded ico">restore</span> Restore shipped files</button>' : '') +
        (st.has_manifest && !st.intact ? '<button class="action-btn" data-x="download"><span class="material-symbols-rounded ico">download</span> Re-download / upgrade</button>' : '') +
        (firstUse ? '<button class="action-btn agent-claude" data-x="accept"><span class="material-symbols-rounded ico">check</span> I accept the terms</button>' : '<button class="action-btn" data-x="close">Close</button>') +
        '</div></div>';
    document.body.appendChild(ov);
    ov.querySelectorAll('button[data-x]').forEach(b => b.onclick = async () => {
        const x = b.dataset.x;
        if (x === 'restore') { try { const d = await (await fetch('launch_cli.php', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'restore'})})).json(); appendSystem(d.ok ? T('msg.restore.opened.in.a.terminal.it.lists.what.i', 'Restore opened in a terminal — it lists what it puts back; sudo is asked there if the web root needs it.') : T('msg.restore.failed.error', 'Restore failed: {error}', {error: (d.error || 'unknown')})); } catch (e) {} return; }
        if (x === 'download') { window.open('https://cockpit.ruggi.site/download.php', '_blank'); return; }
        if (x === 'accept') { try { await fetch('integrity.php', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{"action":"seen"}'}); } catch (e) {} }
        if (g.flag) { try { await fetch('integrity.php', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{"action":"ack_flag"}'}); } catch (e) {} }
        ov.remove();
    });
}
// First use per install/account: terms + integrity once; later, integrity only when something changed.
setTimeout(async () => {
    const st = await integrityStatus(); if (!st) return;
    if (st.first_use) integrityShow({ firstUse: true });
    else if (st.has_manifest && !st.intact && !sessionStorage.getItem('cockpit_integrity_warned')) { sessionStorage.setItem('cockpit_integrity_warned', '1'); integrityShow(); }
}, 4000);
// Help us — the optional support link. Hidden until support.json (shipped with each build) names an https address.
// Nothing is fetched from a server of ours: it is a static file of the app; the link only opens when you click it. (2026-10-17)
let _supportUrl = '';
function supportInit() {
    fetch('support.json', { cache: 'no-store' }).then(r => r.json()).then(j => {
        const u = String((j && j.url) || '').trim(); _supportUrl = /^https:\/\/[^\s"'<>]+$/.test(u) ? u : '';
        const bar = document.getElementById('help-modal-titlebar');
        if (bar && _supportUrl && !document.getElementById('help-support-btn')) {
            const b = document.createElement('button'); b.id = 'help-support-btn'; b.className = 'action-btn'; b.type = 'button';
            b.style.cssText = 'padding:3px 10px;font-size:11px;'; b.textContent = T('support.btn', 'Help us');
            b.title = T('support.tip', 'Cockpit is made by one person. An optional gift keeps it going. It opens in your browser; nothing is asked of you.');
            b.onclick = ev => { ev.stopPropagation(); window.open(_supportUrl, '_blank', 'noopener'); };
            const first = bar.querySelector('button'); bar.insertBefore(b, first || null);
        }
    }).catch(() => {});
}
document.addEventListener('DOMContentLoaded', supportInit);
// About AI Cockpit — modal shown on logo click
// =============================================================================
function aboutCockpit() {
    let ov = document.getElementById('about-cockpit-ov'); if (ov) ov.remove();
    const ver = (document.getElementById('cockpit-version')?.textContent || '').trim() || 'v2.0.0';
    ov = document.createElement('div'); ov.id = 'about-cockpit-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(700px,95vw);max-height:90vh;overflow:auto;padding:22px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="height:3px;margin:-22px -22px 16px;border-radius:8px 8px 0 0;background:linear-gradient(90deg,var(--claude),var(--gemini),var(--ollama));"></div>' +
        '<div style="display:flex;align-items:center;gap:16px;margin-bottom:14px;">' +
        '<img src="assets/logo.png" alt="AI Cockpit" width="160" height="160" style="border-radius:8px;object-fit:cover;flex-shrink:0;" onerror="this.style.display=\'none\'">' +
        '<div style="flex:1;"><h2 class="cockpit-brand-name" style="margin:0;font-size:34px;">AI Cockpit</h2>' +
        '<div style="font-size:12px;color:var(--text-muted);">' + _esc(ver) + ' · by <img src="assets/company/rs_logo.png" alt="" style="width:18px;height:18px;border-radius:3px;vertical-align:middle;"> Ruggi Software —<br>Where Intelligence Compiles.</div></div>' +
        '<span style="cursor:pointer;font-size:20px;color:var(--text-dim);align-self:flex-start;" onclick="this.closest(\'#about-cockpit-ov\').remove()">×</span>' +
        '</div>' +
        '<p style="font-size:13px;line-height:1.5;color:var(--text-primary);margin:6px 0;">A local-first, open-source console that orchestrates multiple AI agents — ' +
        '<b>Claude</b>, <b>Gemini</b>, and local <b>Ollama</b> models — from one interface: single chat, pipelines, broadcast, plus local tools, skills, notes, and a community marketplace.</p>' +
        '<ul style="font-size:12px;color:var(--text-muted);line-height:1.6;padding-left:18px;margin:8px 0;">' +
        '<li>Local-first &amp; private — your machine, your keys, works offline with Ollama</li>' +
        '<li>Multi-agent: pipelines, broadcast, plans, workers &amp; tools</li>' +
        '<li>Free &amp; open source for local use</li>' +
        '</ul>' +
        '<div style="font-size:11px;color:var(--text-dim);border-top:1px solid var(--border-dim);padding-top:10px;margin-top:10px;line-height:1.6;">' +
        'License: <b>Apache-2.0</b> (with conditions, see Terms) · Stack: Free Pascal / PHP / Bash / vanilla JS<br>' +
        'All processing is local unless you explicitly use a paid API provider.<br>' +
        '© Ruggi Software. Press <b>?</b> for the full help guide.' +
        '</div>' +
        '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:12px;">' +
        (_supportUrl ? '<button class="action-btn" style="padding:6px 14px;font-size:12px;background:var(--accent-blue);color:#fff;" onclick="window.open(_supportUrl,\'_blank\',\'noopener\')" title="' + _esc(T('support.tip', 'Cockpit is made by one person. An optional gift keeps it going. It opens in your browser; nothing is asked of you.')) + '">' + _esc(T('support.btn', 'Help us')) + '</button>' : '') +
        '<button class="action-btn" style="padding:6px 14px;font-size:12px;margin-right:auto;" onclick="document.getElementById(\'about-cockpit-ov\').remove();integrityShow({terms:true})" title="The licence terms this copy is used under"><span class="material-symbols-rounded ico">gavel</span> Terms</button>' +
        '<button class="action-btn" style="padding:6px 14px;font-size:12px;" onclick="document.getElementById(\'about-cockpit-ov\').remove();integrityShow()" title="Compare this install with the build it came from"><span class="material-symbols-rounded ico">verified_user</span> Integrity</button>' +
        '<button class="action-btn" style="padding:6px 14px;font-size:12px;" onclick="document.getElementById(\'about-cockpit-ov\').remove()">Close</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}

// =============================================================================
// Generic clear (×) buttons on all search bars
// =============================================================================
const _COCKPIT_SEARCH_IDS = ['help-search','notes-search','search-input','search-q',
    'rp-search-library','rp-search-snippets','rp-search-sources','models-search-input',
    'semsearch-input','histsearch-input','san-results-filter'];
function _appendClearX(wrap, input) {
    if (wrap.querySelector('.search-clear-x')) return;
    const x = document.createElement('span');
    x.className = 'search-clear-x'; x.textContent = '×'; x.title = T('msg.clear', 'Clear');
    x.onclick = () => { input.value = ''; input.dispatchEvent(new Event('input', {bubbles:true})); input.focus(); };
    wrap.appendChild(x);
}
function _cockpitDecorateSearch(input) {
    if (!input || input._clearDecorated) return;
    if (input.tagName !== 'INPUT' && input.tagName !== 'TEXTAREA') return;  // never wrap containers
    const existing = input.closest('.search-clear-wrap');
    if (existing) { _appendClearX(existing, input); input._clearDecorated = true; return; }
    const cs = getComputedStyle(input);
    const grows = parseFloat(cs.flexGrow) > 0 || input.style.width === '100%' || cs.width === '100%';
    const wrap = document.createElement('span');
    wrap.className = 'search-clear-wrap';
    wrap.style.cssText = 'position:relative;display:inline-flex;align-items:center;' + (grows ? 'flex:1;' : '');
    input.parentNode.insertBefore(wrap, input);
    wrap.appendChild(input);
    input.style.width = '100%';
    if (parseFloat(cs.paddingRight) < 24) input.style.paddingRight = '24px';
    _appendClearX(wrap, input);
    input._clearDecorated = true;
}
function _cockpitDecorateAllSearches() {
    _COCKPIT_SEARCH_IDS.forEach(id => { const el = document.getElementById(id); if (el) _cockpitDecorateSearch(el); });
}
document.addEventListener('DOMContentLoaded', () => setTimeout(_cockpitDecorateAllSearches, 300));
document.addEventListener('focusin', e => {
    const t = e.target;
    if (t && t.tagName === 'INPUT' && _COCKPIT_SEARCH_IDS.includes(t.id)) _cockpitDecorateSearch(t);
});


// ── left sidebar: Projects/Chats vs Hive split ───────────────────────────────
// The Toolbar moved to the right sidebar (2026-09-26), freeing the bottom of the
// left column. Hive takes that space and the boundary is draggable. The height is
// stored per edition by the localStorage shim, so V1 and V2 keep their own split.
// V1 has no agent bus, so the section and its drag bar are removed outright rather
// than hidden — a panel that can never do anything is noise, and `display:none`
// still leaves it in the tab order.
function leftHiveApplyEdition() {
    if ((window.COCKPIT_EDITION || 'v2') !== 'v1') return;
    ['left-hive', 'left-hive-resize'].forEach(id => document.getElementById(id)?.remove());
}
function leftHiveRestore() {
    const el = document.getElementById('left-hive');
    if (!el) return;
    try {
        const h = localStorage.getItem('cockpit_left_hive_h');
        if (h && +h > 80) el.style.height = +h + 'px';
    } catch (e) {}
}
function leftHiveStartResize(ev) {
    const el = document.getElementById('left-hive');
    if (!el) return;
    ev.preventDefault();
    const startY = ev.clientY, startH = el.getBoundingClientRect().height;
    const col = el.parentElement ? el.parentElement.getBoundingClientRect().height : 600;
    const move = e => {
        // Dragging UP grows Hive (it sits below the bar), so the delta is inverted.
        let h = startH + (startY - e.clientY);
        h = Math.max(120, Math.min(h, Math.max(160, col - 160)));   // leave Projects/Chats usable
        el.style.height = h + 'px';
    };
    const up = () => {
        document.removeEventListener('mousemove', move);
        document.removeEventListener('mouseup', up);
        try { localStorage.setItem('cockpit_left_hive_h', String(Math.round(el.getBoundingClientRect().height))); } catch (e) {}
    };
    document.addEventListener('mousemove', move);
    document.addEventListener('mouseup', up);
}
document.addEventListener('DOMContentLoaded', () => { leftHiveApplyEdition(); leftHiveRestore(); });
