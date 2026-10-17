// =============================================================================
// cmdwin.js — the Command window: type a simple command, see what it printed. A floating window (js/core/ckwindow.js); backend cmd.php → the native
// engine, which runs ONE command line as the owner of this Cockpit under the kernel's sandbox: it can write only in your Public folder, read your
// project folders and the system's programs, nothing else; a time limit and an output limit apply. Not a full terminal: no full-screen programs
// (nano, vim, top), no passwords, each line runs on its own. `cd` is handled here (the folder is remembered between lines).
// Built-in words: cd, clear, help.   Up / Down = history, Ctrl+L = clear.
// =============================================================================
(function () {
    const API = 'cmd.php';
    const S = { win: null, cwd: 'public:', hist: [], hi: -1, busy: false, ok: false };
    let el = {};
    const esc = s => (typeof escHtml === 'function' ? escHtml(s) : String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])));

    function line(cls, text) {
        const d = document.createElement('div'); d.className = 'cw-line ' + cls; d.textContent = text; el.out.appendChild(d);
        el.out.scrollTop = el.out.scrollHeight; return d;
    }
    function prompt() { return S.cwd + ' $'; }
    function setPrompt() { el.ps.textContent = prompt(); }
    function saveHist() { try { localStorage.setItem('cockpit.cmd.hist', JSON.stringify(S.hist.slice(-200))); } catch (e) { } }

    async function post(body) {
        try {
            const r = await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
            return await r.json();
        } catch (e) { return { ok: false, error: e.message }; }
    }
    async function fm(action, params) {
        try { return await (await fetch('fm.php?action=' + action + '&' + new URLSearchParams(params).toString(), { cache: 'no-store' })).json(); }
        catch (e) { return { ok: false, error: e.message }; }
    }

    function help() {
        [T('ui.cw.help1', 'Commands run one line at a time, as you, confined by the system:'),
         T('ui.cw.help2', '  • they can write only in your Public folder (and its .tmp);'),
         T('ui.cw.help3', '  • they can read your project folders (read-only) and the usual system programs;'),
         T('ui.cw.help4', '  • nothing else on this machine is visible to them; there is a time limit (20 s) and an output limit.'),
         T('ui.cw.help5', 'Not here: full-screen programs (nano, vim, top), anything that asks for input or a password.'),
         T('ui.cw.help6', 'Built-in: cd <folder> (public:sub, projects:name, or a name inside this folder), clear, help.')].forEach(t => line('cw-info', t));
    }

    async function cd(arg) {
        arg = (arg || '').trim().replace(/^["']|["']$/g, '');
        if (!arg || arg === '~') { S.cwd = 'public:'; return setPrompt(); }
        let target;
        if (/^[a-z][a-z0-9_]*:/.test(arg)) target = arg;
        else {
            const z = S.cwd.slice(0, S.cwd.indexOf(':')); let rel = S.cwd.slice(S.cwd.indexOf(':') + 1).split('/').filter(Boolean);
            if (arg[0] === '/') rel = [];
            arg.split('/').forEach(p => { if (p === '..') rel.pop(); else if (p && p !== '.') rel.push(p); });
            target = z + ':' + rel.join('/');
        }
        const d = await fm('list', { path: target });
        if (!d.ok) { line('cw-err', 'cd: ' + (d.error || 'no such folder')); return; }
        S.cwd = target.replace(/\/+$/, ''); if (!/:/.test(S.cwd)) S.cwd += ':'; setPrompt();
    }

    async function run(text) {
        const cmdline = text.trim(); if (!cmdline) return;
        if (S.hist[S.hist.length - 1] !== cmdline) { S.hist.push(cmdline); saveHist(); }
        S.hi = -1;
        line('cw-cmd', prompt() + ' ' + cmdline);
        const w = cmdline.split(/\s+/)[0];
        if (w === 'clear') { el.out.innerHTML = ''; return; }
        if (w === 'help') return help();
        if (w === 'cd') return cd(cmdline.slice(2));
        if (!S.ok) { line('cw-err', T('ui.cw.unavailable', 'Commands are not available here.')); return; }
        S.busy = true; el.in.disabled = true; const wait = line('cw-info', '…');
        const d = await post({ action: 'run', cmd: cmdline, cwd: S.cwd });
        wait.remove(); S.busy = false; el.in.disabled = false; el.in.focus();
        if (!d.ok) { line('cw-err', d.error || T('ui.cw.failed', 'That did not work.')); return; }
        if (d.output) line('cw-stdout', d.output.replace(/\n$/, ''));
        if (d.timed_out) line('cw-err', T('ui.cw.timeout', 'Stopped: it ran longer than the time limit.'));
        if (d.truncated) line('cw-err', T('ui.cw.truncated', 'The output was cut at the limit.'));
        if (d.exit && !d.timed_out) line('cw-info', T('ui.cw.exit', 'exit status {n}', { n: d.exit }));
    }

    function build() {
        const root = document.createElement('div'); root.className = 'cw-root';
        el.banner = document.createElement('div'); el.banner.className = 'cw-banner';
        el.out = document.createElement('div'); el.out.className = 'cw-out'; el.out.tabIndex = 0;
        const row = document.createElement('div'); row.className = 'cw-row';
        el.ps = document.createElement('span'); el.ps.className = 'cw-ps';
        el.in = document.createElement('input'); el.in.type = 'text'; el.in.className = 'cw-in'; el.in.autocomplete = 'off'; el.in.spellcheck = false; el.in.setAttribute('aria-label', T('ui.cw.input', 'Command'));
        row.appendChild(el.ps); row.appendChild(el.in);
        root.appendChild(el.banner); root.appendChild(el.out); root.appendChild(row);
        el.in.addEventListener('keydown', ev => {
            if (ev.key === 'Enter') { const v = el.in.value; el.in.value = ''; run(v); }
            else if (ev.key === 'ArrowUp') { ev.preventDefault(); if (S.hist.length) { S.hi = S.hi < 0 ? S.hist.length - 1 : Math.max(0, S.hi - 1); el.in.value = S.hist[S.hi]; } }
            else if (ev.key === 'ArrowDown') { ev.preventDefault(); if (S.hi >= 0) { S.hi++; el.in.value = S.hi >= S.hist.length ? '' : S.hist[S.hi]; if (S.hi >= S.hist.length) S.hi = -1; } }
            else if (ev.ctrlKey && ev.key.toLowerCase() === 'l') { ev.preventDefault(); el.out.innerHTML = ''; }
        });
        root.addEventListener('click', ev => { if (!window.getSelection().toString()) el.in.focus(); });
        return root;
    }

    window.cmdwinOpen = async function () {
        if (S.win && ckWindowOpen('cmdwin')) { S.win.focus(); el.in && el.in.focus(); return; }
        let info; try { info = await (await fetch(API + '?action=info', { cache: 'no-store' })).json(); } catch (e) { info = { ok: false, error: e.message }; }
        if (info && info.edition_gate) return;
        try { S.hist = JSON.parse(localStorage.getItem('cockpit.cmd.hist') || '[]'); } catch (e) { S.hist = []; }
        S.cwd = 'public:'; S.hi = -1; S.ok = !!(info && info.ok && info.engine && info.sandbox && !info.viewer);
        const nat = typeof quickLaunchTerminal === 'function';
        S.win = ckWindow({ id: 'cmdwin', title: T('ui.cw.title', 'Commands'), icon: 'terminal', width: 760, height: 460, minWidth: 380, minHeight: 240, content: build(), onClose() { S.win = null; },
            buttons: nat ? [{ icon: 'desktop_windows', title: T('ui.cw.system', 'Open the system terminal'), onClick: () => quickLaunchTerminal() }] : [] });
        setPrompt();
        if (!info || !info.ok) { el.banner.textContent = (info && info.error) || T('ui.cw.nobackend', 'The command window is not available.'); el.banner.classList.add('bad'); el.in.disabled = true; el.ps.style.opacity = '0.3'; el.in.placeholder = ''; return; }
        if (!info.engine) { el.banner.textContent = T('ui.cw.noservice', 'The command service is not running. Start the agents (the supervisor hosts it) and open this window again.'); el.banner.classList.add('bad'); el.in.disabled = true; el.ps.style.opacity = '0.3'; el.in.placeholder = ''; return; }
        if (info.viewer) { el.banner.textContent = T('ui.cw.viewer', 'Your account cannot run commands.'); el.banner.classList.add('bad'); el.in.disabled = true; el.ps.style.opacity = '0.3'; el.in.placeholder = ''; return; }
        if (!info.sandbox) { el.banner.textContent = T('ui.cw.nosandbox', 'This machine cannot confine commands, so none are run. (It needs Linux with Landlock.)'); el.banner.classList.add('bad'); el.in.disabled = true; el.ps.style.opacity = '0.3'; el.in.placeholder = ''; return; }
        el.banner.textContent = T('ui.cw.banner', 'Simple commands only, confined to your Public folder. Type help for what that means.');
        el.in.focus();
    };
})();
