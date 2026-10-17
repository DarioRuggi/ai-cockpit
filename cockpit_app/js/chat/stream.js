// =============================================================================
// cancelPrompt
// =============================================================================
// =============================================================================
// In-flight registry + long-run watchdog + Stop-everything (2026-09-13).
//
// Every long operation the page starts registers here with a way to stop it:
// tool jobs (server-side kill), worker calls (AbortController), agent streams
// (the tmux cleanup below). The watchdog asks about anything that runs past
// its warn threshold — once, then again every 5 minutes — with Stop / Keep
// waiting. The Stop button stops ALL of it, then asks the server what is still
// running and says so. Closing the page kills this session's tool jobs.
// =============================================================================
const _inflight = new Map();
let _inflightSeq = 0;
function inflightAdd(kind, label, cancel, opts = {}) {
    const id = 'f' + (++_inflightSeq);
    _inflight.set(id, { id, kind, label, cancel, started: Date.now(), warnAfterMs: opts.warnAfterMs || 120000, nextWarnAt: 0, asking: false });
    return id;
}
function inflightTouch(id, elapsedMs) { const e = _inflight.get(id); if (e && elapsedMs) e.started = Date.now() - elapsedMs; }
function inflightDone(id) { _inflight.delete(id); }
function _fmtDur(ms) { const s = Math.round(ms / 1000); return s < 60 ? s + 's' : Math.floor(s / 60) + 'm ' + (s % 60) + 's'; }
async function inflightWatchdog() {
    for (const e of _inflight.values()) {
        const age = Date.now() - e.started;
        if (e.asking || age < e.warnAfterMs || Date.now() < e.nextWarnAt) continue;
        e.asking = true;
        try {
            const stop = await cockpitConfirm('Still running', e.label + ' has been running for ' + _fmtDur(age) + '.\n\nStop it, or keep waiting? (You will be asked again in 5 minutes.)', 'Stop it', {icon:'timer', cancelLabel:'Keep waiting'});
            if (stop && _inflight.has(e.id)) { appendSystem(T('msg.stopping.label', 'Stopping: {label}', {label: e.label})); await e.cancel(); }
            else e.nextWarnAt = Date.now() + 5 * 60 * 1000;
        } catch (err) { e.nextWarnAt = Date.now() + 5 * 60 * 1000; }
        e.asking = false;
    }
}
setInterval(inflightWatchdog, 10000);
// Stop everything this page started; then report what the server still shows.
async function stopEverything() {
    const entries = [..._inflight.values()];
    for (const e of entries) { try { await e.cancel(); } catch (err) {} }
    try { await fetch('tools.php?action=kill_all', {method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'}); } catch (e) {}
    setLoading(false);
    setTimeout(async () => {
        const left = [];
        try { const r = await (await fetch('tools.php?action=jobs')).json(); for (const j of (r.jobs || [])) left.push('tool: ' + j.label + ' (' + _fmtDur(j.elapsed_ms) + ')'); } catch (e) {}
        for (const e of _inflight.values()) left.push(e.kind + ': ' + e.label);
        if (left.length) {
            const again = await cockpitConfirm('Still running after Stop', left.join('\n') + '\n\nTry to kill again?', 'Kill again', {danger:true, icon:'warning'});
            if (again) stopEverything();
        } else if (entries.length) appendSystem(T('msg.everything.stopped', 'Everything stopped.'));
    }, 1500);
}
// Exit procedure (2026-09-13). Closing the window used to end the app on the
// spot. Now: when anything is running, the browser's own leave dialog is raised
// (the only thing a page may do at that moment) and Cockpit's exit modal is put
// up behind it, so cancelling the dialog lands on the choices: kill processes,
// terminate the agent sessions, wait for completion, or leave anyway. The same
// modal is what the Exit button and any other exit path call.
async function cockpitExitStatus() {
    const st = { jobs: [], inflight: [..._inflight.values()].map(e => e.kind + ': ' + e.label), streams: activeStreamTokens.size, sessions: 0 };
    try { const r = await (await fetch('tools.php?action=jobs')).json(); st.jobs = (r.jobs || []).map(j => j.label); } catch (e) {}
    try { const d = await (await fetch('status.php', {cache:'no-store'})).json(); st.sessions = ['claude','gemini','ollama'].filter(a => d[a] && d[a].ok).length; } catch (e) {}
    return st;
}
let _exitModalUp = false;
async function cockpitExit(reason) {
    if (_exitModalUp) return; _exitModalUp = true;
    const st = await cockpitExitStatus();
    const running = st.jobs.length + st.inflight.length + st.streams;
    const lines = [];
    if (st.jobs.length)     lines.push('Tool runs: ' + st.jobs.join(', '));
    if (st.inflight.length) lines.push('In flight: ' + st.inflight.join(', '));
    if (st.streams)         lines.push('Agent replies streaming: ' + st.streams);
    lines.push('Agent sessions running: ' + st.sessions + '/3 (tmux; they keep running after the page closes)');
    document.getElementById('exit-overlay')?.remove();
    const ov = document.createElement('div'); ov.id = 'exit-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100010;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const btn = (label, icon, fn, accent) => '<button class="action-btn" data-x="' + fn + '" style="padding:6px 12px;' + (accent ? 'border-color:' + accent + ';color:' + accent + ';' : '') + '"><span class="material-symbols-rounded" style="font-size:14px;vertical-align:-3px;">' + icon + '</span> ' + label + '</button>';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(520px,92vw);padding:18px 20px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<h2 style="margin:0 0 8px;font-size:14px;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">power_settings_new</span> Leaving Cockpit' + (reason === 'close' ? ' — the window is closing' : '') + '</h2>' +
        '<div style="font-size:12px;color:var(--text-base);line-height:1.5;margin-bottom:14px;white-space:pre-line;">' + escapeHtml(lines.join('\n')) + '</div>' +
        '<div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;">' +
        (running ? btn('Kill processes', 'cancel', 'kill', 'var(--accent-amber)') : '') +
        (st.sessions ? btn('Terminate sessions', 'stop_circle', 'sessions', 'var(--accent-amber)') : '') +
        (st.sessions ? btn('Terminate and leave', 'power_settings_new', 'sessions_leave', 'var(--accent-amber)') : '') +
        (running ? btn('Wait for completion', 'hourglass_top', 'wait') : btn('Stay', 'arrow_back', 'wait')) +
        btn('Leave anyway', 'logout', 'leave') + '</div></div>';
    document.body.appendChild(ov);
    ov.querySelectorAll('button[data-x]').forEach(b => b.onclick = async () => {
        const x = b.dataset.x;
        if (x === 'kill')     { await stopEverything(); appendSystem(T('msg.processes.stopped', 'Processes stopped.')); }
        if (x === 'sessions') { await sessionControl('stop'); }
        if (x === 'sessions_leave') {   // stop the agent sessions, then close the window
            b.disabled = true; b.textContent = T('msg.stopping', 'Stopping…');
            try { await sessionControl('stop', {leave: true}); } catch (e) {}
            if (running) { try { await stopEverything(); } catch (e) {} }
            ov.remove(); _exitModalUp = false; _exitConfirmed = true; cockpitShellQuit(); return;
        }
        if (x === 'leave')    { ov.remove(); _exitModalUp = false; _exitConfirmed = true; cockpitShellQuit(); return; }
        ov.remove(); _exitModalUp = false;
    });
}
let _exitConfirmed = false;
// Native shell (cockpit_shell, shell/cockpit_shell.pas): the window's close button,
// Alt+F4 and the dock's Quit all land in cockpitShellClose() instead of closing;
// the page quits the shell by setting the title sentinel. In a plain browser
// tab the same call falls back to window.close().
window.cockpitShellClose = function () { cockpitExit('close'); };
function cockpitShellQuit() {
    if (_inShell) { try { shellCall('quit').catch(() => {}); } catch (e) {} document.title = T('msg.cockpit.quit', '__COCKPIT_QUIT__'); return; }
    window.close();
    appendSystem(T('msg.if.this.tab.did.not.close.close.it.yourself', 'If this tab did not close, close it yourself — Cockpit is ready to leave.'));
}
window.addEventListener('beforeunload', (e) => {
    if (_inShell) return;                    // the shell owns closing; no browser dialog
    if (_exitConfirmed) return;
    const busy = _inflight.size > 0 || activeStreamTokens.size > 0;
    if (!busy) return;                       // nothing running: leave silently
    e.preventDefault(); e.returnValue = '';  // browser's own leave dialog
    setTimeout(() => cockpitExit('close'), 0);   // behind it, for a cancelled close
});
function cancelPrompt() {
    if (abortController) abortController.abort();
    stopEverything();
    // Real stop: tell the server to SIGINT the running CLI in its tmux pane,
    // so generation actually halts (not just the client poll).
    if (_activeAgent) {
        const tok = activeStreamTokens.size ? [...activeStreamTokens][0] : '';
        fetch('bridge.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ mode: 'cleanup', token: tok, agent: _activeAgent })
        }).catch(() => {});
        appendSystem(T('msg.typeof.generation.stopped', '{typeof}: generation stopped.', {typeof: (typeof agentDisplayName === 'function' ? agentDisplayName(_activeAgent) : _activeAgent.toUpperCase())}));
        _activeAgent = null;
    }
}

// On page unload (refresh, close tab, navigate away) — best-effort cleanup
// of any tokens that are still streaming. We use sendBeacon because it's the
// only fetch-style API guaranteed to fire during unload (regular fetch may be
// killed before completing). One beacon per token.
window.addEventListener('beforeunload', () => {
    for (const token of activeStreamTokens) {
        try {
            const blob = new Blob([JSON.stringify({ mode:'cleanup', token, unload: 1 })],
                                  { type: 'application/json' });
            navigator.sendBeacon('bridge.php', blob);
        } catch(e) {}
    }
});

