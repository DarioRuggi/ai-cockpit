// =============================================================================
// Status refresh
// =============================================================================
let _serverClockOffsetMs = null;   // server_now − local now, from status.php
function _fmtClock(d, tzMin) {
    const p = n => String(n).padStart(2, '0');
    // ISO week number
    const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
    const day = t.getUTCDay() || 7; t.setUTCDate(t.getUTCDate() + 4 - day);
    const wk = Math.ceil((((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 86400000) + 1) / 7);
    const wd = ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][d.getDay()];
    const tz = (tzMin >= 0 ? '+' : '-') + p(Math.floor(Math.abs(tzMin) / 60)) + (Math.abs(tzMin) % 60 ? ':' + p(Math.abs(tzMin) % 60) : '');
    return p(d.getDate()) + '/' + p(d.getMonth() + 1) + '/' + d.getFullYear() + ' ' + wd + ' W' + p(wk) +
           '  ' + p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + '  UTC' + tz;
}
let _serverTzMin = null;
let _serverTzName = '';
// The logo card (hover): what this is, version, edition, build, licence, the maker and the sites.
let _brandBuild = null;
async function _brandBuildLoad() { if (_brandBuild !== null) return; _brandBuild = false; try { const d = await (await fetch('integrity.php?action=status')).json(); if (d && d.ok) _brandBuild = d; } catch (e) {} }
_brandBuildLoad();
function brandTipHtml() {
    const ver = (document.getElementById('cockpit-version')?.textContent || '').trim();
    const ed = (window.COCKPIT_EDITION || 'v2');
    const edName = { v2: 'Full', v1: 'Stand-alone', demo: 'Web demo' }[ed] || ed;
    const b = _brandBuild || {};
    const row = (k, v, c) => '<div style="display:flex;gap:14px;justify-content:space-between;font-size:12px;"><span style="color:var(--text-muted);">' + k + '</span><span style="font-family:var(--font-mono);color:' + (c || 'var(--text-base)') + ';">' + v + '</span></div>';
    return '<div style="min-width:420px;max-width:460px;font-size:12.5px;line-height:1.55;">' +
        // ── AI Cockpit: big logo, name, slogan, centred
        '<div style="text-align:center;padding:6px 0 10px;">' +
            '<img src="assets/logo.png" alt="" style="width:72px;height:auto;filter:drop-shadow(0 0 14px color-mix(in srgb, var(--accent-cyan,#7ecfff) 55%, transparent));">' +
            '<div style="font-size:26px;font-weight:800;letter-spacing:0.02em;color:var(--text-primary);margin-top:4px;">AI Cockpit <span style="font-family:var(--font-mono);font-size:14px;font-weight:600;color:var(--gemini);">' + escHtml(ver) + '</span>' +
                (b.has_manifest && b.intact === true ? ' <span class="material-symbols-rounded" style="font-size:18px;color:var(--accent-green);vertical-align:-3px;">verified</span>' : '') + '</div>' +
            '<div style="font-size:14px;font-style:italic;color:var(--accent-cyan,#7ecfff);letter-spacing:0.03em;">Where Intelligence Compiles.</div>' +
        '</div>' +
        '<div style="margin-bottom:10px;">A local-first console that drives several AI agents from one prompt, one chat history and one set of files: paid CLIs (Claude Code, Gemini CLI), free REST workers, local models through Ollama or LocalAI, and file tools — with pipelines, broadcasts, multi-step plans, durable agent chains, a marketplace of Power Combos, and everything running on your own machine unless you choose otherwise.</div>' +
        row('Edition', escHtml(edName) + ' (' + escHtml(ed) + ')') +
        (b.has_manifest ? row('Build', (b.build ? ':' + b.build + ' · ' : '') + escHtml((b.build_id || '').slice(0, 16)) + '… · ' + (b.intact ? 'intact' : 'changed'), b.intact ? 'var(--accent-green)' : 'var(--accent-amber)') + row('Built', escHtml((b.built || '').replace('T', ' ').slice(0, 16))) : '') +
        row('Licence', 'Apache-2.0 · names, logos and cockpit_auth reserved') +
        // ── Ruggi Software: big mark + slogan at the head of its section
        '<div style="border-top:1px solid var(--border-dim);margin:12px 0 8px;"></div>' +
        '<div style="display:flex;align-items:center;gap:12px;">' +
            '<img src="assets/company/rs_logo.png" alt="" style="width:56px;height:56px;border-radius:8px;object-fit:cover;box-shadow:0 0 14px rgba(0,0,0,0.5);">' +
            '<div><div style="font-size:19px;font-weight:800;color:var(--text-primary);">Ruggi Software</div>' +
            '<div style="font-size:13px;font-style:italic;color:var(--warm,#e0b84e);">Where Intelligence Compiles.</div>' +
            '<div style="font-size:11.5px;color:var(--text-muted);">Dario Ruggi</div></div>' +
        '</div>' +
        '<div style="margin-top:8px;color:var(--text-base);">Tools, games and AI work from one workshop — <b>ruggi.site</b>. The app, accounts and the marketplace live at <b>cockpit.ruggi.site</b>.</div>' +
        '<div style="margin-top:8px;font-size:11px;color:var(--text-dim);">Click the logo for About · F1 for help</div></div>';
}
// The clock's detail card (hover): full names, offsets, ISO week, day of year, unix time, drift.
function clockTipHtml() {
    const p = n => String(n).padStart(2, '0');
    const now = new Date(), tzMin = -now.getTimezoneOffset();
    const tzName = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
    const longDate = now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
    const doy = Math.floor((now - new Date(now.getFullYear(), 0, 1)) / 86400000) + 1;
    const row = (k, v, c) => '<div style="display:flex;gap:10px;justify-content:space-between;"><span style="color:var(--text-muted);">' + k + '</span><span style="font-family:var(--font-mono);color:' + (c || 'var(--text-base)') + ';">' + v + '</span></div>';
    let srv = row('Live server', '<i>unreachable</i>', 'var(--text-dim)');
    if (_serverClockOffsetMs !== null && _serverTzMin !== null) {
        const sh = new Date(now.getTime() + _serverClockOffsetMs + _serverTzMin * 60000);
        srv = row('Live server', 'cockpit.ruggi.site', 'var(--workers,#c9a3e0)') +
              row('Server time', p(sh.getUTCHours()) + ':' + p(sh.getUTCMinutes()) + ':' + p(sh.getUTCSeconds()) + '  ' + p(sh.getUTCDate()) + '/' + p(sh.getUTCMonth() + 1) + '/' + sh.getUTCFullYear(), 'var(--workers,#c9a3e0)') +
              row('Server zone', escHtml(_serverTzName || '—') + ' (' + _tzLabel(_serverTzMin) + ')', 'var(--workers,#c9a3e0)') +
              row('Server − local', (Math.round(_serverClockOffsetMs / 100) / 10) + ' s clock drift · ' + ((_serverTzMin - tzMin) / 60) + ' h zone gap');
    }
    return '<div style="min-width:300px;"><div style="font-size:20px;font-weight:700;letter-spacing:0.06em;color:var(--accent-cyan,#7ecfff);text-align:center;margin-bottom:6px;">' + p(now.getHours()) + ':' + p(now.getMinutes()) + ':' + p(now.getSeconds()) + '</div>' +
        row('Local date', escHtml(longDate), 'var(--warm,#e0b84e)') +
        row('ISO week · day of year', 'W' + p(_isoWeek(now)) + ' · ' + doy + '/' + ((now.getFullYear() % 4 === 0 && (now.getFullYear() % 100 !== 0 || now.getFullYear() % 400 === 0)) ? 366 : 365)) +
        row('Local zone', escHtml(tzName) + ' (' + _tzLabel(tzMin) + ')', 'var(--accent-green,#7dc4a3)') +
        row('UTC now', now.toISOString().replace('T', ' ').slice(0, 19)) +
        row('Unix time', String(Math.floor(now.getTime() / 1000))) +
        '<div style="border-top:1px solid var(--border-dim);margin:6px 0 4px;"></div>' + srv + '</div>';
}
// Zone id → short 'REG·CTY' (Europe/Paris → EU·PAR): the ids are too long for the strip.
function _tzShort(id) { const p = String(id || '').split('/'); if (p.length < 2) return (id || '').toUpperCase().slice(0, 3); return p[0].slice(0, 3).toUpperCase() + '-' + p[p.length - 1].replace(/_/g, '').slice(0, 3).toUpperCase(); }
function _tzLabel(tzMin) { const p = n => String(n).padStart(2, '0'); const a = Math.abs(tzMin); return 'UTC' + (tzMin >= 0 ? '+' : '-') + p(Math.floor(a / 60)) + (a % 60 ? ':' + p(a % 60) : ''); }
function _isoWeek(d) { const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate())); const day = t.getUTCDay() || 7; t.setUTCDate(t.getUTCDate() + 4 - day); return Math.ceil((((t - Date.UTC(t.getUTCFullYear(), 0, 1)) / 86400000) + 1) / 7); }
function topbarClockTick() {
    const eT = document.getElementById('clock-time'); if (!eT) return;
    const p = n => String(n).padStart(2, '0');
    const now = new Date(), tzMin = -now.getTimezoneOffset();
    const wd = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'][now.getDay()];
    const tzName = (Intl.DateTimeFormat().resolvedOptions().timeZone || '');
    eT.textContent = p(now.getHours()) + ':' + p(now.getMinutes()) + ':' + p(now.getSeconds());
    document.getElementById('clock-date').textContent = wd + ' ' + p(now.getDate()) + '/' + p(now.getMonth() + 1) + '/' + now.getFullYear() + ' W' + p(_isoWeek(now));
    // Local zone, then (when the live server's clock is known) the gap to the server's zone: server minus local, in hours, bold in the
    // server line's colour. "+2h" = the server's clock is 2 hours ahead of yours. (Labels "Loc. TZ" / "Ser. TZ" dropped 2026-10-06.)
    const eTz = document.getElementById('clock-tz'), sv = document.getElementById('clock-server');
    let gap = '';
    if (_serverTzMin !== null && _serverClockOffsetMs !== null) {
        const g = _serverTzMin - tzMin, a = Math.abs(g);
        gap = ' <b style="color:var(--workers,#c9a3e0);" title="' + escHtml(g === 0 ? 'Server and local time are in the same zone' : 'The server clock is ' + Math.floor(a / 60) + (a % 60 ? ':' + p(a % 60) : '') + ' h ' + (g > 0 ? 'ahead of' : 'behind') + ' yours') + '">' +
              (g > 0 ? '+' : g < 0 ? '-' : '±') + Math.floor(a / 60) + (a % 60 ? ':' + p(a % 60) : '') + 'h</b>';
    }
    eTz.innerHTML = escHtml(_tzLabel(tzMin) + (tzName ? ' ' + _tzShort(tzName) : '')) + gap;
    if (_serverClockOffsetMs === null || _serverTzMin === null) { sv.textContent = '—'; return; }
    // the server's wall clock in ITS zone: shift the instant by its offset, read with UTC getters
    const shifted = new Date(now.getTime() + _serverClockOffsetMs + _serverTzMin * 60000);
    sv.textContent = _tzLabel(_serverTzMin) + (_serverTzName ? ' ' + _tzShort(_serverTzName) : '') + ' ' + p(shifted.getUTCHours()) + ':' + p(shifted.getUTCMinutes());
}
// The server row is the LIVE server (cockpit.ruggi.site — accounts, marketplace,
// relay), not the local Apache. Its clock comes through saas.php (server-side, from the
// account server this install is configured for) and ONLY in the Full edition while a
// Cockpit account is signed in: Stand-alone never contacts any server, and a signed-out
// Full install has nothing to ask yet. Otherwise the row shows a dash.
async function liveServerClockPoll() {
    let ok = false;
    try {
        if (typeof saasEnabled === 'function' && saasEnabled() && typeof _saasAcct !== 'undefined' && _saasAcct && _saasAcct.signed_in) {
            const t0 = Date.now();
            const d = await (await fetch('saas.php?action=server_time', {cache:'no-store'})).json();
            const rtt = Date.now() - t0;
            const t = Date.parse(d.now); const m = /([+-])(\d{2}):?(\d{2})$/.exec(d.now || '');
            if (d.ok && !isNaN(t)) {
                _serverClockOffsetMs = t + rtt / 2 - Date.now(); ok = true;
                if (m) _serverTzMin = (m[1] === '-' ? -1 : 1) * (parseInt(m[2], 10) * 60 + parseInt(m[3], 10));
                if (d.tz) _serverTzName = String(d.tz);
            }
        }
    } catch (e) {}
    if (!ok) _serverClockOffsetMs = null;
    setTimeout(liveServerClockPoll, ok ? 60000 : 15000);   // asks again soon while nothing is known (a sign-in can happen at any time)
}
setTimeout(liveServerClockPoll, 4000);
setInterval(topbarClockTick, 1000); topbarClockTick();

async function refreshStatus() {
    try {
        const res  = await fetch('status.php');
        const data = await res.json();
        if (typeof maSyncAgentChecks === 'function') { try { maSyncAgentChecks(data); } catch (e) {} }
        if (data && data.integrity_flag && data.integrity_flag.changed_at !== window._integrityFlagSeen) {
            // cockpit-guard saw a shipped file change: say so and open Integrity once per flag
            window._integrityFlagSeen = data.integrity_flag.changed_at;
            appendError(T('msg.icon.verified.user.guard.shipped.file.change', '[[icon:verified_user]] Guard: shipped file changed — {file} ({event}). Integrity panel opened.', {file: (data.integrity_flag.file || ''), event: (data.integrity_flag.event || '')}));
            if (typeof integrityShow === 'function' && !document.getElementById('integrity-ov')) integrityShow();
        }
        updateDot('claude', data.claude);
        updateDot('gemini', data.gemini);
        updateDot('ollama', data.ollama);
        updateRuntime(data.runtime);

        if (data.project && data.project.project_name) {
            document.getElementById('project-name').textContent = data.project.project_name;

            // Follow project_state.json when something OTHER than this tab
            // changed it (e.g. the Everywhere relay switching chats from a
            // phone) — same file bridge.php treats as the shared blackboard.
            // Guarded to only fire on an actual mismatch, not every 4s poll.
            const pName = data.project.project_name;
            const cName = data.project.chat_name || 'default';
            const projectOrChatChanged = (pName !== currentProject || cName !== currentChat);
            if (projectOrChatChanged && typeof switchToChat === 'function') {
                switchToChat(cName, pName);
                _lastKnownExchangeCount = (typeof data.exchange_count === 'number') ? data.exchange_count : null;
            } else if (typeof data.exchange_count === 'number') {
                // Same project/chat as before, but the message count grew —
                // something else (typically the Everywhere relay) added an
                // exchange to THIS chat. Reload content without treating it
                // as a chat switch (avoids re-running switch side effects
                // like style-reload on every single poll tick).
                if (_lastKnownExchangeCount !== null && data.exchange_count > _lastKnownExchangeCount &&
                    typeof switchToChat === 'function') {
                    switchToChat(cName, pName);
                }
                _lastKnownExchangeCount = data.exchange_count;
            }
        }
    } catch (e) {
        appendError(T('msg.status.check.failed.message', 'Status check failed: {message}', {message: e.message}));
    }
    // Always resolves so .then() in init works
}

// The status bar says who and which model, nothing else: the dot already says "running" (the full text stays in the hover).
function _statusShort(tool, versionText, extra) {
    let name = String(versionText).split(':')[0].trim().replace(/^Claude Code$/, 'Claude').replace(/^Gemini CLI$/, 'Gemini');
    if (/^[A-Z0-9 ]+$/.test(name)) name = ({ OPENCODE: 'OpenCode', LOCALAI: 'LocalAI' })[name] || (name.charAt(0) + name.slice(1).toLowerCase());
    if (tool === 'ollama') name = 'Local · ' + name;                         // card 3: Ollama / Dual / LocalAI
    let model = String(extra || '').replace(/^\s*·\s*/, '').split(' · ')[0].trim();
    if (tool === 'claude') model = model.replace(/^Claude\s+/, '');
    return model ? name + ' · ' + model : name;
}

function updateDot(tool, info) {
    const dot   = document.getElementById('dot-' + tool);
    const label = document.getElementById('lbl-' + tool);
    if (!dot || !label) return;
    if (info && info.ok) {
        dot.className = 'status-dot ok-' + tool;
        let extra = '';
        if (tool === 'claude') {
            const m = document.getElementById('claude-model');
            extra = m ? ' · ' + m.options[m.selectedIndex].text : '';
        } else if (tool === 'gemini') {
            const m = document.getElementById('gemini-model');
            extra = m ? ' · ' + m.options[m.selectedIndex].text : '';
        }
        // status.php's "version" text is a hardcoded per-tmux-session label
        // ("Claude Code"/"Gemini CLI") — doesn't know about the runtime
        // provider swap (Card 1/2 de-hardwire, window._primaryName/
        // _fallbackName). Swap the provider-name portion here so this pill
        // agrees with the card it's reporting on (2026-07-02, was a deferred
        // "builder not located" item from 2026-06-28).
        let versionText = info.version;
        if (tool === 'claude' && window._primaryAlt && window._primaryName) {
            versionText = versionText.replace(/^Claude Code/, window._primaryName);
        } else if (tool === 'gemini' && window._fallbackAlt && window._fallbackName) {
            versionText = versionText.replace(/^Gemini CLI/, window._fallbackName);
        } else if (tool === 'ollama' && window._localName && window._localName !== 'OLLAMA') {
            versionText = versionText.replace(/^Ollama/, window._localName);   // Card 3 may be Dual / LocalAI
        }
        label.textContent = _statusShort(tool, versionText, extra);
        label.title = versionText + extra;
    } else {
        dot.className = 'status-dot fail';
        label.textContent = tool.charAt(0).toUpperCase() + tool.slice(1) + ': not running';
    }
    // Reflect running state on the per-card power toggle.
    _updateSupplierPowerBtn(tool, !!(info && info.ok));

    // Update session status panel after all dots are updated
    if (tool === 'ollama') {
        // Count how many agent dots are healthy. Drives "Stop (n)" badge,
        // backend-down amber pulse on statusbar, and START button visibility.
        const upCount = ['claude','gemini','ollama'].reduce((n, t) => {
            const d = document.getElementById('dot-' + t);
            return n + (d && d.classList.contains('ok-' + t) ? 1 : 0);
        }, 0);
        updateSessionStatus(upCount === 3, upCount);
    }
}

// =============================================================================
// Browser notifications for long-running jobs
// =============================================================================
// Same, but only when the user is not looking: the native window reports
// whether it is focused; a browser tab uses document.hasFocus().
function cockpitNotifyIfAway(title, body) {
    if (_inShell) { shellCall('notify', { title, body, only_if_unfocused: true }).catch(() => {}); return; }
    if (!document.hasFocus()) cockpitNotify(title, body);
}
function cockpitNotify(title, body) {
    // Native window: a desktop notification through the shell (libnotify) with an
    // "Open Cockpit" action that brings the window up — no permission prompt.
    if (_inShell) { shellCall('notify', { title, body }).catch(() => {}); return; }
    if (!('Notification' in window)) return;
    if (Notification.permission === 'granted') {
        new Notification(title, { body, icon: 'favicon.ico', tag: 'cockpit-' + Date.now() });
    } else if (Notification.permission !== 'denied') {
        Notification.requestPermission().then(p => {
            if (p === 'granted') new Notification(title, { body, icon: 'favicon.ico' });
        });
    }
}


// The account card (hover): who is signed in, tier, e-mail (masked), the local login,
// and what its three buttons do. Rendered like the logo and clock cards (data-tip-fn).
function accountTipHtml() {
    const a = (typeof _saasAcct !== 'undefined' && _saasAcct) || null;
    const esc = (s) => (typeof escHtml === 'function' ? escHtml(String(s || '')) : String(s || ''));
    const row = (k, v) => '<div style="display:flex;gap:14px;justify-content:space-between;font-size:12px;"><span style="color:var(--text-muted);">' + k + '</span><span style="font-family:var(--font-mono);color:var(--text-base);">' + v + '</span></div>';
    const login = (document.getElementById('sup-strip-user')?.textContent || '').trim();
    const mail = a && a.email ? String(a.email).replace(/^(.).*(@.*)$/, '$1…$2') : '';
    return '<div style="min-width:320px;font-size:12.5px;line-height:1.5;">' +
        '<div style="font-weight:700;margin-bottom:6px;">Account</div>' +
        (a && a.signed_in ? row('Cockpit account', esc(a.nickname || a.username || '')) + row('Tier', esc((a.tier || 'free').toUpperCase()) + (a.beta ? ' · BETA' : '')) + (mail ? row('E-mail', esc(mail)) : '') : '<div style="color:var(--text-dim);margin-bottom:4px;">Not signed in to a Cockpit account (Full edition: free, no card).</div>') +
        (login ? row('This machine\'s login', esc(login)) : '') +
        '<div style="margin-top:8px;color:var(--text-dim);font-size:11.5px;">' +
        '<b>Users</b> — local logins on this machine, password, sign out.<br>' +
        '<b>Slots</b> — which supplier fills each card (Claude / Codex / local…).<br>' +
        '<b>Apps</b> — the terminal, file manager and browser the toolbar opens.</div></div>';
}

// =============================================================================
// Runtime indicator: which of the interchangeable parts is really in use (status.php "runtime", read from the running processes).
// Per agent:  <who keeps the loop alive> · <the loop that runs>   e.g. "sup · native", "sup · shell", "tmux · shell".
// Chip:       the engine switch and the scheduler.   Words, not colour alone.
// =============================================================================
function updateRuntime(rt) {
    const chip = document.getElementById('rt-chip');
    if (!rt || !rt.agents) { if (chip) chip.style.display = 'none'; return; }
    const hostWord = { supervisor: 'sup', tmux: 'tmux', other: '?', none: '–' };
    const hostName = {
        supervisor: T('ui.rt.host.supervisor', 'kept alive by the process supervisor (restarted if it dies)'),
        tmux: T('ui.rt.host.tmux', 'runs in a tmux session'),
        other: T('ui.rt.host.other', 'running outside both tmux and the supervisor'),
        none: T('ui.rt.host.none', 'not running')
    };
    const loopName = {
        native: T('ui.rt.loop.native', 'native loop (aicengine loop)'),
        shell: T('ui.rt.loop.shell', 'shell loop (agent_loop.sh)'),
        none: ''
    };
    ['claude', 'gemini', 'ollama'].forEach(a => {
        const el = document.getElementById('rt-' + a), r = rt.agents[a];
        if (!el) return;
        if (!r || r.loop === 'none') { el.style.display = 'none'; return; }
        el.style.display = '';
        // just the loop ("native" / "shell"): the supervisor is the usual host and is said in the hover; another host (tmux) is put in front
        el.textContent = (r.host === 'supervisor' ? '' : (hostWord[r.host] || '?') + ' · ') + (r.loop === 'native' ? 'native' : 'shell');
        el.classList.toggle('native', r.loop === 'native');
        el.title = (loopName[r.loop] || '') + ' — ' + (hostName[r.host] || '') + (r.pid ? ' (pid ' + r.pid + ')' : '');
    });
    if (!chip) return;
    const eng = rt.engine && rt.engine.on;
    const sch = rt.scheduler === 'supervisor' ? 'sup' : 'cron';
    // three small tags, like the ones beside each agent: engine, scheduler tick, web server
    const tEng = document.getElementById('rt-eng'), tSch = document.getElementById('rt-sch'), tWeb = document.getElementById('rt-web');
    // one word each; what it is, in the hover (the whole group's hover has the details)
    if (tEng) { tEng.textContent = eng ? 'on' : 'off'; tEng.title = T('ui.rt.tag.engine', 'Native engine: {state}', { state: eng ? T('ui.rt.on.short', 'on') : T('ui.rt.off', 'off') }); tEng.classList.toggle('native', !!eng); }
    if (tSch) { tSch.textContent = sch; tSch.title = T('ui.rt.tag.sched', 'Scheduler tick: {who}', { who: rt.scheduler === 'supervisor' ? T('ui.rt.sched.sup', 'a supervised job') : T('ui.rt.sched.cron', 'cron or none') }); tSch.classList.toggle('native', rt.scheduler === 'supervisor'); }
    if (tWeb) {
        const w = rt.web && rt.web !== 'none' ? (rt.web === 'aicserver' ? 'aic' : rt.web) : '';
        tWeb.textContent = w; tWeb.title = T('ui.rt.tag.web', 'Web server answering this page: {who}', { who: rt.web === 'aicserver' ? 'aicserver' : rt.web === 'apache' ? 'Apache' : (rt.web || '?') }); tWeb.style.display = w ? '' : 'none'; tWeb.classList.toggle('native', rt.web === 'aicserver');
    }
    chip.title = [
        T('ui.rt.tip.title', 'Runtime in use (read from the running processes)'),
        T('ui.rt.tip.hosting', 'Agent loops: {host}', { host: rt.host === 'supervisor' ? T('ui.rt.hosting.supervisor', 'kept alive by the process supervisor') : rt.host === 'tmux' ? T('ui.rt.hosting.tmux', 'tmux sessions') : rt.host === 'mixed' ? T('ui.rt.hosting.mixed', 'some under the supervisor, some in tmux') : T('ui.rt.hosting.none', 'none running') }),
        T('ui.rt.tip.engine', 'Native engine: {state}{installed}', { state: eng ? T('ui.rt.on', 'ON (file use_engine)') : T('ui.rt.off', 'off'), installed: rt.engine && rt.engine.installed ? '' : ' — ' + T('ui.rt.notinstalled', 'program not installed') }),
        T('ui.rt.tip.native', 'Native loop asked for by: {files}', { files: (rt.switches && rt.switches.length) ? rt.switches.join(', ') : T('ui.rt.none', 'nothing') }),
        T('ui.rt.tip.files', 'File and command windows: {who}', { who: rt.files_service === 'supervisor' ? T('ui.rt.files.sup', 'service running (supervisor)') : rt.files_service === 'other' ? T('ui.rt.files.other', 'service socket present') : T('ui.rt.files.none', 'service not running') }),
        T('ui.rt.tip.sched', 'Scheduler tick: {who}', { who: rt.scheduler === 'supervisor' ? T('ui.rt.sched.sup', 'a supervised job') : T('ui.rt.sched.cron', 'cron or none') }),
        T('ui.rt.tip.web', 'Web server answering this page: {who}', { who: rt.web === 'aicserver' ? T('ui.rt.web.aic', 'aicserver (the optional front, answers chat polls itself)') : rt.web === 'apache' ? 'Apache' : rt.web === 'php' ? T('ui.rt.web.php', "PHP's built-in server") : (rt.web || '?') })
    ].join('\n');
    chip.style.display = '';
}
