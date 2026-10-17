// Open tmux session in a new terminal
// =============================================================================
async function openSession(agent) {
    const session = 'cockpit_' + agent;
    const socket  = '/var/www/html/cockpit/tmux.sock';
    try {
        // Cards 4 and 5 (2026-09-13). Tools: its tmux session is created on
        // demand (tool runs are windows in it). Workers: there is no session —
        // calls are plain HTTP — so the button tails the activity log instead.
        if (agent === 'tools') {
            const e = await (await fetch('tools.php?action=ensure_session', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'})).json();
            if (!e.ok) { appendSystem(T('msg.tools.session.unavailable.tmux.not.reachable', 'Tools session unavailable (tmux not reachable from the web server).')); return; }
        } else if (agent === 'workers') {
            const r = await fetch('launch_cli.php', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({mode:'workers_log'})});
            const d = await r.json();
            if (!d.ok) appendSystem(T('msg.open.failed.error', 'Open failed: {error}', {error: (d.error || 'unknown')}));
            return;
        }
        if (_inShell) {   // a terminal attached to the session, opened by us — unless the agent is supervised: then it has no tmux pane, and launch_cli's attach shows its live log
            let supervised = false;
            try { supervised = !!(await (await fetch('launch_cli.php', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({agent, mode: 'session_kind'})})).json()).supervised; } catch (e) {}
            if (!supervised) { try { await shellCall('open_tmux', { session, socket }); return; } catch (e) {} }
        }
        const r = await fetch('launch_cli.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({agent, model: '', mode: 'attach', session, socket}),
        });
        const d = await r.json();
        if (!d.ok) appendSystem(T('msg.attach.failed.error', 'Attach failed: {error}', {error: (d.error || 'unknown')}));
    } catch(e) {
        appendSystem(T('msg.attach.error.message', 'Attach error: {message}', {message: e.message}));
    }
}

// =============================================================================
// QUICK LAUNCH — terminal, file browser, web browser
// Opens as the local machine's own owner user via launch_cli.php
// =============================================================================

// Real projects root, resolved once from the server (paths.php's
// projects_root, per-user-scoped) — never hardcode a path here, it has to
// work on every install, not just the dev machine this was written on.
let COCKPIT_PROJECTS_ROOT = '';
async function _loadProjectsRoot() {
    try {
        const r = await fetch('config.php?action=root');
        const d = await r.json();
        if (d.ok) COCKPIT_PROJECTS_ROOT = d.root;
    } catch (e) {}
}

// Build the current chat directory path from project + chat name
function _chatDir() {
    const base = COCKPIT_PROJECTS_ROOT;
    const proj = currentProject || '_standalone';
    // Return the project directory — most useful for terminal/file browser
    if (proj === '_standalone') return base;
    return base + '/' + proj;
}

// Open gnome-terminal in current chat directory
async function quickLaunchTerminal() {
    const dir = _chatDir();
    try {
        const r = await fetch('launch_cli.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({agent:'terminal', mode:'terminal', dir}),
        });
        const d = await r.json();
        if (!d.ok) appendSystem(T('msg.terminal.launch.failed.error', 'Terminal launch failed: {error}', {error: (d.error || 'unknown')}));
    } catch(e) { appendSystem(T('msg.terminal.error.message', 'Terminal error: {message}', {message: e.message})); }
}

// Open Nemo file browser in current chat directory
async function quickLaunchFiles() {
    const dir = _chatDir();
    try {
        const r = await fetch('launch_cli.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({agent:'files', mode:'files', dir}),
        });
        const d = await r.json();
        if (!d.ok) appendSystem(T('msg.file.browser.launch.failed.error', 'File browser launch failed: {error}', {error: (d.error || 'unknown')}));
    } catch(e) { appendSystem(T('msg.file.browser.error.message', 'File browser error: {message}', {message: e.message})); }
}

// Open Brave browser
function quickLaunchBrowser() {
    // Open a new tab in the user's CURRENT browser — instant, and never touches
    // the Cockpit window (same approach as the sidebar Search "Ask" buttons).
    // The old server-side launch_cli spawn was slow (~10s) and Brave's bare
    // --new-window reused/hijacked Cockpit's own window.
    // Start URL is configurable in the Apps modal (per machine, localStorage).
    // http(s) → window.open (fast). Anything else (file://, …) can't be opened
    // by window.open from an http page (browser cross-scheme block), so launch
    // it natively via launch_cli (a real browser window on the host).
    let url = cockpitBrowserHome();
    // file:// can't be opened by window.open from an http page — instead serve
    // the local file through cockpit (openlocal.php, PATH_INFO so relative
    // assets resolve) and open THAT over http: instant, same browser, no hijack.
    if (/^file:\/\//i.test(url)) {
        const p = url.replace(/^file:\/\//i, '');           // absolute path
        url = 'openlocal.php' + (p.charAt(0) === '/' ? '' : '/') + p;
    }
    // Inside the native window, go through launch_cli: it honours the Apps-panel choice
    // (e.g. the Cockpit Browser) and reports 'no browser' honestly; window.open there
    // would only reach the shell's xdg-open.
    if (typeof _inShell !== 'undefined' && _inShell) {
        fetch('launch_cli.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: 'browser', url }) })
            .then(r => r.json()).then(d => { if (!d.ok) appendSystem(T('msg.browser.error', 'Browser: {error}', {error: (d.error || 'unknown')})); })
            .catch(e => appendSystem(T('msg.browser.error.message', 'Browser error: {message}', {message: e.message})));
        return;
    }
    const w = window.open(url, '_blank');
    if (!w) appendSystem(T('msg.browser.open.was.blocked.allow.pop.ups.for.c', 'Browser open was blocked — allow pop-ups for Cockpit, then click Browser again.'));
}
// Configurable start page for the toolbar Browser button (Apps modal → Browser
// start URL). Per-machine via localStorage; default ruggi.site.
function cockpitBrowserHome() {
    try { return localStorage.getItem('cockpit_browser_home') || 'https://ruggi.site'; }
    catch(e) { return 'https://ruggi.site'; }
}

// ── Apps panel — choose which terminal / file manager / browser the toolbar
// Terminal/Files/Browser buttons open. Default = the rig's own default apps;
// the dropdowns list every app detected on the machine. Saved per-user via
// launch_cli.php (set_apps), which validates the choice against installed apps
// so the fixed sudoers allowlist still authorizes the launch.
async function appsOpen() {
    let data;
    try {
        const r = await fetch('launch_cli.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({mode:'list_apps'})
        });
        data = await r.json();
    } catch(e) { appendSystem(T('msg.apps.could.not.load.message', 'Apps: could not load ({message})', {message: e.message})); return; }
    if (!data || !data.ok) { appendSystem(T('msg.apps.data', 'Apps: {data}', {data: ((data && data.error) || 'unavailable on this platform')})); return; }
    const apps = data.apps || {};
    const cats = [
        ['terminal', 'Terminal',     'terminal'],
        ['files',    'File manager',  'folder_open'],
        ['browser',  'Web browser',   'public'],
    ];
    const _base = p => (p || '').split('/').pop() || p;
    const rowFor = ([key, label, icon]) => {
        const a = apps[key] || {candidates:[], choice:'', default:''};
        const defName = a.default ? _base(a.default) : 'none found';
        let opts = '<option value=""' + (!a.choice ? ' selected' : '') + '>System default (' + defName + ')</option>';
        (a.candidates || []).forEach(c => {
            opts += '<option value="' + c + '"' + (a.choice === c ? ' selected' : '') + '>' + _base(c) + '</option>';
        });
        return '<div style="display:flex;align-items:center;gap:10px;margin:10px 0;">' +
            '<span class="material-symbols-rounded" style="font-size:16px;color:var(--text-muted);">' + icon + '</span>' +
            '<label style="flex:0 0 110px;font-size:12px;color:var(--text-base);">' + label + '</label>' +
            '<select id="apps-sel-' + key + '" style="flex:1;padding:5px 8px;background:var(--bg-input,var(--bg-base));color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;font-size:12px;">' +
            opts + '</select></div>';
    };
    let ov = document.getElementById('apps-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'apps-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-panel,var(--bg-base));border:1px solid var(--border-bright);border-radius:8px;padding:18px 20px;width:min(460px,92vw);box-shadow:0 8px 40px rgba(0,0,0,0.5);">' +
            '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;">' +
                '<span class="material-symbols-rounded" style="font-size:18px;">apps</span>' +
                '<h3 style="margin:0;font-size:14px;color:var(--text-base);">Launch apps</h3></div>' +
            '<div style="font-size:11px;color:var(--text-muted);margin-bottom:6px;">Which apps the toolbar Terminal / Files / Browser buttons open. Only apps installed on this machine are listed.</div>' +
            cats.map(rowFor).join('') +
            '<div style="display:flex;align-items:center;gap:10px;margin:10px 0;">' +
                '<span class="material-symbols-rounded" style="font-size:16px;color:var(--text-muted);">home</span>' +
                '<label style="flex:0 0 110px;font-size:12px;color:var(--text-base);">Browser start URL</label>' +
                '<input id="apps-browser-url" type="text" placeholder="https://ruggi.site" value="' + escAttr(cockpitBrowserHome()) + '" style="flex:1;padding:5px 8px;background:var(--bg-input,var(--bg-base));color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;font-size:12px;"></div>' +
            '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:16px;">' +
                '<button id="apps-cancel" class="action-btn" style="padding:6px 14px;font-size:12px;">Cancel</button>' +
                '<button id="apps-save" class="action-btn" style="padding:6px 14px;font-size:12px;background:var(--accent,#2d7);color:#fff;border-color:transparent;">Save</button>' +
            '</div></div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    ov.addEventListener('click', e => { if (e.target === ov) close(); });
    document.getElementById('apps-cancel').onclick = close;
    document.getElementById('apps-save').onclick = async () => {
        const payload = { terminal:'', files:'', browser:'' };
        cats.forEach(([key]) => { const s = document.getElementById('apps-sel-' + key); if (s) payload[key] = s.value; });
        // Browser start URL (per-machine, localStorage). Normalize: blank → default,
        // add https:// if the user typed a bare host.
        let url = (document.getElementById('apps-browser-url')?.value || '').trim();
        if (!url) url = 'https://ruggi.site';
        // Only add https:// when there's NO scheme at all — leave file://, and
        // any other explicit scheme, untouched.
        else if (!/^[a-z][a-z0-9+.-]*:/i.test(url)) url = 'https://' + url;
        try { localStorage.setItem('cockpit_browser_home', url); } catch(e) {}
        try {
            const r = await fetch('launch_cli.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({mode:'set_apps', apps:payload})
            });
            const d = await r.json();
            if (d && d.ok) appendSystem(T('msg.launch.apps.saved', 'Launch apps saved.'));
            else appendSystem(T('msg.apps.save.failed.d', 'Apps save failed: {d}', {d: ((d && d.error) || 'unknown')}));
        } catch(e) { appendSystem(T('msg.apps.save.error.message', 'Apps save error: {message}', {message: e.message})); }
        close();
    };
}

// =============================================================================
// T1/F7 — Translation (local LibreTranslate via translate.php)
//
// Two entry points:
//   translateChat()    — translate all message bodies in the console, code
//                         blocks excluded, into a chosen target language.
//   translateTextBox()  — free-text translation box (paste anything).
// Target-language dropdowns are populated from translate.php?action=languages.
// =============================================================================
let _xlateLangs = null;   // cached language list
async function _xlateLoadLangs() {
    if (_xlateLangs) return _xlateLangs;
    try {
        const r = await fetch('translate.php?action=languages');
        const d = await r.json();
        if (d.ok && Array.isArray(d.languages) && d.languages.length) {
            _xlateLangs = d.languages;   // cache ONLY real data
            return _xlateLangs;
        }
    } catch(e) {}
    // LibreTranslate didn't answer (e.g. mid-restart) — return a minimal fallback
    // but do NOT cache it, so the next call retries and picks up the real list.
    // English only. This list used to be en/he/es -- the developer's own languages --
    // so a user whose LibreTranslate was merely restarting saw a picker reflecting
    // somebody else's preferences. Unpinned 2026-09-24: the real list comes from the
    // server, and this is only the stand-in until it answers.
    return [
        {code:'en',name:'English'},
    ];
}
function _xlateLangOptions(langs, sel) {
    return langs.map(l => '<option value="' + escHtml(l.code) + '"' +
        (l.code === sel ? ' selected' : '') + '>' + escHtml(l.name) + '</option>').join('');
}
// Repopulate any open Translate dialog's language dropdowns from a fresh
// /languages (busts the cache). Preserves the current selection where possible.
// Fetch the REAL loaded-language list directly (no fallback). Returns [] on failure.
async function _xlateFetchLangsRaw() {
    try {
        const r = await fetch('translate.php?action=languages');
        const d = await r.json();
        if (d.ok && Array.isArray(d.languages)) return d.languages;
    } catch(e) {}
    return [];
}
async function _xlateRefreshDropdowns() {
    const langs = await _xlateFetchLangsRaw();
    if (!langs.length) return;          // LibreTranslate down — keep current options
    _xlateLangs = langs;                // update cache with real data
    const chatT = document.getElementById('xlate-chat-target');
    if (chatT) { const v = chatT.value; chatT.innerHTML = _xlateLangOptions(langs, v); chatT.value = v; }
    const textS = document.getElementById('xlate-text-source');
    if (textS) { const v = textS.value; textS.innerHTML = '<option value="auto">Auto-detect</option>' + _xlateLangOptions(langs, ''); textS.value = v; }
    const textT = document.getElementById('xlate-text-target');
    if (textT) { const v = textT.value; textT.innerHTML = _xlateLangOptions(langs, v); textT.value = v; }
}
// Poll /languages until the loaded set EXACTLY matches the target set — so an
// added model has downloaded AND a removed one is gone (the old process, which
// still serves the removed language until the restart completes, won't match).
async function _xlatePollLangsReady(codes, timeoutMs) {
    const need = new Set(codes);
    const start = Date.now();
    await new Promise(r => setTimeout(r, 2000));   // let the restart begin first
    while (Date.now() - start < timeoutMs) {
        const langs = await _xlateFetchLangsRaw();
        if (langs.length) {
            const have = new Set(langs.map(l => l.code));
            if (have.size === need.size && [...need].every(c => have.has(c))) return true;
        }
        await new Promise(r => setTimeout(r, 5000));
    }
    return false;
}

// Strip fenced code blocks and inline code so we don't send code to translate.
// Returns {clean, placeholders} — code is replaced with ⟦C0⟧ markers that we
// could restore, but for chat translation we simply skip code entirely.
// The prose of a rendered chat message: code blocks (the whole snippet widget with its header, copy button and icon names), inline code and
// buttons are removed from a COPY of the message first. The rendered text has no ``` fences left to strip, so reading innerText sent the code
// (and the widget's own labels) to the translator.
function _chatBodyProse(bodyEl) {
    const c = bodyEl.cloneNode(true);
    c.querySelectorAll('pre, code, button, .material-symbols-rounded, .msg-receipts, [class*="snippet"], [class*="codeblock"], [class*="code-block"], [class*="code-header"], [class*="codehdr"]').forEach(x => x.remove());
    c.querySelectorAll('p, li, div, br, h1, h2, h3, h4, tr').forEach(x => x.insertAdjacentText('beforeend', '\n'));
    return (c.textContent || '').replace(/\n{3,}/g, '\n\n').trim();
}
function _stripCodeForTranslation(text) {
    // Remove fenced ``` blocks
    let t = text.replace(/```[\s\S]*?```/g, ' ');
    // Remove inline `code`
    t = t.replace(/`[^`]*`/g, ' ');
    return t.trim();
}

// In-app manager for which languages LibreTranslate loads. Writes via
// translate.php set_langs (runs the owner's manager through sudo) and restarts
// the service; newly-added languages download on first use.
async function manageTranslateLangs() {
    let data;
    try {
        const r = await fetch('translate.php?action=manage_langs');
        data = await r.json();
    } catch(e) { appendSystem(T('msg.language.manager.could.not.load.message', 'Language manager: could not load ({message})', {message: e.message})); return; }
    if (!data || !data.ok) { appendSystem(T('msg.language.manager.unavailable', 'Language manager unavailable.')); return; }
    if (!data.manageable) { appendSystem(T('msg.libretranslate.is.not.installed.on.this.mach', 'LibreTranslate is not installed on this machine.')); return; }
    const loaded = new Set(data.loaded || []);
    const cached = new Set(data.cached || []);   // model on disk but hidden — instant re-add
    const sup = data.supported || {};
    let ov = document.getElementById('xlate-langmgr-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'xlate-langmgr-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10000;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const boxes = Object.keys(sup).map(code => {
        const on = loaded.has(code) ? ' checked' : '';
        const forced = (code === 'en') ? ' disabled title="English is always loaded"' : '';
        const badge = (cached.has(code) && !loaded.has(code))
            ? ' <span title="Cached — model kept on disk; re-adding is instant (no download)" ' +
              'style="font-size:9px;padding:1px 5px;border-radius:8px;background:var(--bg-active);color:var(--text-muted);white-space:nowrap;">' +
              '<span class="material-symbols-rounded" style="font-size:10px;vertical-align:-1px;">inventory_2</span> cached</span>'
            : '';
        return '<label style="display:flex;align-items:center;gap:6px;font-size:12px;padding:3px 6px;">' +
            '<input type="checkbox" class="xlate-lang-cb" value="' + code + '"' + on + forced + '>' +
            escHtml(sup[code]) + ' <span style="opacity:0.5;">' + code + '</span>' + badge + '</label>';
    }).join('');
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-bright);border-radius:8px;padding:16px 20px;width:min(520px,94vw);max-height:88vh;overflow:auto;box-shadow:0 8px 40px rgba(0,0,0,0.5);">' +
        '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<span class="material-symbols-rounded" style="font-size:18px;">translate</span>' +
        '<h3 style="margin:0;font-size:14px;flex:1;">Translation languages</h3>' +
        '<span class="rp-action-btn" id="langmgr-close" style="cursor:pointer;">×</span></div>' +
        '<div style="font-size:11px;color:var(--text-muted);margin-bottom:8px;line-height:1.5;">' +
        'Tick the languages to make available, then Save &amp; restart. <b>Adding</b> a new one downloads its model (may take a minute). ' +
        '<b>Unticking</b> one hides it but keeps its model on disk — marked ' +
        '<span class="material-symbols-rounded" style="font-size:11px;vertical-align:-2px;">inventory_2</span> <b>cached</b>, so re-adding it is instant (no download). English is always loaded.</div>' +
        '<div style="display:grid;grid-template-columns:1fr 1fr;gap:2px;">' + boxes + '</div>' +
        '<div style="display:flex;justify-content:flex-end;gap:8px;margin-top:14px;align-items:center;">' +
        '<span id="langmgr-status" style="font-size:10px;color:var(--text-muted);flex:1;"></span>' +
        '<button class="rp-action-btn" id="langmgr-cancel">Cancel</button>' +
        '<button class="rp-action-btn" id="langmgr-save" style="background:var(--bg-active);">Save & restart</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('langmgr-close').onclick = close;
    document.getElementById('langmgr-cancel').onclick = close;
    document.getElementById('langmgr-save').onclick = async () => {
        const codes = Array.from(ov.querySelectorAll('.xlate-lang-cb'))
            .filter(cb => cb.checked || cb.value === 'en').map(cb => cb.value);
        if (!codes.includes('en')) codes.push('en');
        const st = document.getElementById('langmgr-status');
        st.textContent = T('msg.saving.restarting.libretranslate', 'Saving & restarting LibreTranslate…');
        try {
            const r = await fetch('translate.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'set_langs', langs:codes})
            });
            const d = await r.json();
            if (d && d.ok) {
                appendSystem(T('msg.translation.languages.set.langs.downloading', 'Translation languages set: {langs} — downloading models + reloading…', {langs: d.langs}));
                close();
                // Auto-refresh the open Translate dropdown(s) once the models load.
                _xlatePollLangsReady(codes, 180000).then(ready => {
                    _xlateRefreshDropdowns();
                    appendSystem(ready ? T('msg.translation.languages.ready.langs', 'Translation languages ready: {langs}.', {langs: d.langs}) : T('msg.languages.set.some.models.may.still.be.downl', 'Languages set — some models may still be downloading.'));
                });
            } else {
                st.textContent = 'Failed: ' + ((d && d.error) || 'unknown');
            }
        } catch(e) { st.textContent = 'Error: ' + e.message; }
    };
}

async function translateChat() {
    const langs = await _xlateLoadLangs();
    // Build target picker overlay
    let ov = document.getElementById('xlate-chat-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'xlate-chat-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(680px,94vw);max-height:90vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">translate</span> Translate chat</h2>' +
        '<span class="rp-action-btn" id="xlate-chat-close" style="cursor:pointer;">×</span></div>' +
        '<div style="display:flex;align-items:center;gap:8px;margin-bottom:10px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">Target language</label>' +
        '<select id="xlate-chat-target" style="font-size:12px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:4px 6px;">' +
        _xlateLangOptions(langs, 'en') + '</select>' +
        '<button class="rp-action-btn" id="xlate-chat-go" style="background:var(--bg-active);">Translate</button>' +
        '<button class="rp-action-btn" id="xlate-chat-selall" title="Select all translations">Select all</button>' +
        '<button class="rp-action-btn" id="xlate-chat-copy" title="Copy all translations to clipboard">Copy</button>' +
        '<button class="rp-action-btn" id="xlate-manage" title="Add or remove translation languages"><span class="material-symbols-rounded ico">settings</span> Languages</button>' +
        '<span id="xlate-chat-status" style="font-size:10px;color:var(--text-muted);flex:1;"></span>' +
        '</div>' +
        '<div id="xlate-chat-out" style="display:flex;flex-direction:column;gap:8px;"></div>' +
        '</div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    document.getElementById('xlate-chat-close').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('xlate-manage').onclick = () => manageTranslateLangs();
    document.getElementById('xlate-chat-selall').onclick = () => {
        const box = document.getElementById('xlate-chat-out');
        if (!box || !box.textContent.trim()) return;
        const sel = window.getSelection(); sel.removeAllRanges();
        const range = document.createRange(); range.selectNodeContents(box); sel.addRange(range);
    };
    document.getElementById('xlate-chat-copy').onclick = async () => {
        const rows = Array.from(document.querySelectorAll('#xlate-chat-out .xlate-tr-body')).map(d => d.innerText);
        const st = document.getElementById('xlate-chat-status');
        if (!rows.length) { if (st) st.textContent = T('msg.nothing.to.copy.translate.first', 'Nothing to copy — translate first.'); return; }
        const text = rows.join('\n\n');
        try { await navigator.clipboard.writeText(text); if (st) st.textContent = 'Copied ' + rows.length + ' translation' + (rows.length===1?'':'s') + '.'; }
        catch(e) { document.getElementById('xlate-chat-selall').click(); if (st) st.textContent = T('msg.selected.press.ctrl.cmd.c', 'Selected — press Ctrl/Cmd+C.'); }
    };
    document.getElementById('xlate-chat-go').onclick = async () => {
        const target = document.getElementById('xlate-chat-target').value;
        const status = document.getElementById('xlate-chat-status');
        const outBox = document.getElementById('xlate-chat-out');
        outBox.innerHTML = '';
        // Collect message bodies from the console (skip system/error)
        const msgs = Array.from(document.querySelectorAll('#console-box .msg, .msg'))
            .filter(m => !m.classList.contains('msg-system') && !m.classList.contains('msg-error'));
        if (msgs.length === 0) { status.textContent = T('msg.no.messages.to.translate', 'No messages to translate.'); return; }
        let done = 0;
        for (const m of msgs) {
            const tagEl = m.querySelector('.msg-tag');
            const bodyEl = m.querySelector('.msg-body');
            if (!bodyEl) continue;
            const label = tagEl ? tagEl.textContent : '';
            const raw = _chatBodyProse(bodyEl);
            const clean = _stripCodeForTranslation(raw);
            if (clean === '') continue;
            status.textContent = 'Translating ' + (done+1) + '/' + msgs.length + '…';
            let translated = '';
            try {
                const r = await fetch('translate.php?action=translate', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({q: clean, source:'auto', target: target})
                });
                const d = await r.json();
                if (d.ok) translated = d.translatedText || '';
                else translated = '[translation failed: ' + (d.error||'') + ']';
            } catch(e) { translated = '[error: ' + e.message + ']'; }
            const row = document.createElement('div');
            row.style.cssText = 'border-left:3px solid var(--border-mid);padding:4px 8px;';
            row.innerHTML = '<div style="font-size:10px;color:var(--text-muted);margin-bottom:2px;">' +
                escHtml(label) + '</div><div class="xlate-tr-body" style="font-size:12px;white-space:pre-wrap;">' +
                escHtml(translated) + '</div>';
            outBox.appendChild(row);
            done++;
        }
        status.textContent = 'Done — ' + done + ' message' + (done===1?'':'s') + ' translated (code excluded).';
    };
}

async function translateTextBox() {
    const langs = await _xlateLoadLangs();
    let ov = document.getElementById('xlate-text-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'xlate-text-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(720px,94vw);max-height:90vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">g_translate</span> Translate text</h2>' +
        '<span class="rp-action-btn" id="xlate-text-close" style="cursor:pointer;">×</span></div>' +
        '<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">From</label>' +
        '<select id="xlate-text-source" style="font-size:12px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:4px 6px;">' +
        '<option value="auto" selected>Auto-detect</option>' + _xlateLangOptions(langs, '') + '</select>' +
        '<label style="font-size:11px;color:var(--text-muted);">To</label>' +
        '<select id="xlate-text-target" style="font-size:12px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:4px 6px;">' +
        _xlateLangOptions(langs, 'en') + '</select>' +
        '<button class="rp-action-btn" id="xlate-text-go" style="background:var(--bg-active);">Translate</button>' +
        '<button class="rp-action-btn" id="xlate-text-swap" title="Swap source/target & text">⇄</button>' +
        '<button class="rp-action-btn" id="xlate-text-manage" title="Add or remove translation languages"><span class="material-symbols-rounded ico">settings</span> Languages</button>' +
        '</div>' +
        '<textarea id="xlate-text-in" placeholder="Type or paste text to translate…" ' +
        'style="width:100%;height:24vh;box-sizing:border-box;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:13px;padding:8px;resize:vertical;"></textarea>' +
        '<div style="font-size:10px;color:var(--text-muted);margin:4px 0;" id="xlate-text-status"></div>' +
        '<textarea id="xlate-text-out" readonly placeholder="Translation appears here…" ' +
        'style="width:100%;height:24vh;box-sizing:border-box;background:var(--bg-base);color:var(--text-base);border:1px solid var(--border-dim);font-size:13px;padding:8px;resize:vertical;"></textarea>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:8px;">' +
        '<button class="rp-action-btn" id="xlate-text-selall" title="Select all of the translation">Select all</button>' +
        '<button class="rp-action-btn" id="xlate-text-copy">Copy result</button>' +
        '<button class="rp-action-btn" id="xlate-text-toprompt" title="Insert translation into the prompt box">→ Prompt</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    document.getElementById('xlate-text-close').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('xlate-text-manage').onclick = () => manageTranslateLangs();
    const inEl  = document.getElementById('xlate-text-in');
    const outEl = document.getElementById('xlate-text-out');
    const stEl  = document.getElementById('xlate-text-status');
    document.getElementById('xlate-text-go').onclick = async () => {
        const q = inEl.value;
        if (!q.trim()) return;
        const source = document.getElementById('xlate-text-source').value;
        const target = document.getElementById('xlate-text-target').value;
        stEl.textContent = T('msg.translating', 'Translating…');
        try {
            const r = await fetch('translate.php?action=translate', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({q: q, source: source, target: target})
            });
            const d = await r.json();
            if (!d.ok) { stEl.textContent = 'Failed: ' + (d.error||''); return; }
            outEl.value = d.translatedText || '';
            stEl.textContent = 'Done.' + (d.detected ? ' Detected: ' + (d.detected.language||'') : '') +
                               (d.chunked ? ' (chunked)' : '');
        } catch(e) { stEl.textContent = 'Error: ' + e.message; }
    };
    document.getElementById('xlate-text-swap').onclick = () => {
        const s = document.getElementById('xlate-text-source');
        const t = document.getElementById('xlate-text-target');
        if (s.value === 'auto') return;   // can't swap into auto
        const sv = s.value; s.value = t.value; t.value = sv;
        const iv = inEl.value; inEl.value = outEl.value; outEl.value = iv;
    };
    document.getElementById('xlate-text-selall').onclick = () => {
        if (!outEl.value) return;
        outEl.focus(); outEl.select();
    };
    document.getElementById('xlate-text-copy').onclick = () => {
        if (!outEl.value) { stEl.textContent = T('msg.nothing.to.copy.yet', 'Nothing to copy yet.'); return; }
        navigator.clipboard.writeText(outEl.value).then(() => stEl.textContent = T('msg.copied', 'Copied.'))
            .catch(() => { outEl.focus(); outEl.select(); stEl.textContent = T('msg.selected.press.ctrl.cmd.c', 'Selected — press Ctrl/Cmd+C.'); });
    };
    document.getElementById('xlate-text-toprompt').onclick = () => {
        if (!outEl.value) return;
        promptInput.value = (promptInput.value || '') + (promptInput.value ? '\n' : '') + outEl.value;
        close();
        promptInput.focus();
    };
    setTimeout(() => inEl.focus(), 60);
}

// Calls launch_cli.php on the server which runs gnome-terminal via sudo.
async function launchCLI(agent) {
    // Current model for the card — the free local agents (Aider/Goose/opencode) need
    // it to build their interactive REPL; paid CLIs ignore it. Card 1 = claude-model,
    // Card 2 = gemini-model, Card 3 = the Ollama picker.
    let model = '';
    if (agent === 'ollama') {
        const sel = document.getElementById('ollama-model-hidden') ||
                    document.querySelector('#ollama-trigger');
        model = (sel ? (sel.dataset.value || sel.textContent || '').trim() : '')
                || 'qwen2.5-coder:1.5b';
        model = model.replace(/\s*[★(].*/g, '').trim();   // strip a legacy " ★" / " (Tier 1)" suffix from stored selections
    } else if (agent === 'claude') {
        model = (document.getElementById('claude-model') || {}).value || '';
    } else if (agent === 'gemini') {
        model = (document.getElementById('gemini-model') || {}).value || '';
    }
    try {
        const r = await fetch('launch_cli.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({agent, model}),
        });
        const d = await r.json();
        if (!d.ok) appendSystem(T('msg.launch.failed.error', 'Launch failed: {error}', {error: (d.error || 'unknown')}));
    } catch(e) {
        appendSystem(T('msg.launch.error.message', 'Launch error: {message}', {message: e.message}));
    }
}

// =============================================================================
