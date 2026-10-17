// Init
// =============================================================================
document.getElementById('init-time').textContent = formatTime(new Date());
_loadProjectsRoot().then(() => setWorkDir(COCKPIT_PROJECTS_ROOT));
// Previously only called after a manual Supplier Slots save — meant the
// card labels/model dropdowns reverted to the CLAUDE/GEMINI default on
// every normal reload, even though the actual dispatch (agent_loop.sh)
// was already correctly running the configured CLI the whole time.
loadSupplierSlots();

// 2026-05-09 fix: was hardcoded as setAgent('gemini') here, which clobbered
// the localStorage-restored selection. Use the value loaded by
// _initialActiveAgent() (saved selection or DOM default). We have to clear
// currentAgent first because setAgent() short-circuits when target === current.
{
    const _restoreAgent = currentAgent;
    currentAgent = null;
    setAgent(_restoreAgent);
}

// Remove the duplicate system msg added by setAgent on init
const sysMsgs = consoleBox.querySelectorAll('.msg-system');
if (sysMsgs.length > 1) sysMsgs[sysMsgs.length - 1].remove();

initFontControls();
updateClock();
updateClock();       // Show clock immediately, before the 1s interval fires
loadModels().catch(() => {});
refreshStatus()
    .then(() => hideInitSpinner())
    .catch(() => { try { hideInitSpinner(); } catch(e){} })
    .finally(async () => {
        // Nothing below may run before the request gate opens: in the native
        // window the auth check answers later than in Chromium and the whole
        // restore (chats, projects, files, right panel) used to fire into the
        // closed gate and stay empty ("Error loading chats") — 2026-09-16.
        if (_soloPanel) return;   // detached window: soloApply() runs on its own, before the gate
        try { await window.authGateReady(); } catch (e) {}
        try {
            const lastTab = localStorage.getItem('cockpit_last_left_tab') || 'chats';
            const tabEl = document.querySelector(`.sidebar-left .sidebar-vtab[onclick*="'${lastTab}'"]`);
            if (tabEl && lastTab !== 'chats') {
                switchLeftTab(lastTab, tabEl);
            }
            await ensureDefaultHome();   // seed default/default so lists are never empty
            await switchToChat(currentChat, currentProject);
            setTimeout(() => { consoleBox.scrollTop = consoleBox.scrollHeight; }, 100);
            if (lastTab === 'chats') loadChats();
            if (lastTab === 'projects') loadProjects();
            // Restore right sidebar tab
            const lastRight = localStorage.getItem('cockpit_last_right_tab') || 'preview';
            const rightTab = document.querySelector(`.sidebar-right .sidebar-vtab[onclick*="'${lastRight}'"]`);
            if (rightTab && lastRight !== 'preview') {
                switchTab('right', lastRight, rightTab);
            }
        } catch(e) { console.warn('_restoreLastSession:', e); try { loadChats(); } catch(e2){} }
    });
updateStatusbarPath(currentProject, currentChat);
renderUsageMeters();
if (!_inShell && 'Notification' in window && Notification.permission === 'default') Notification.requestPermission();
// These loaders used to start on fixed timers (0.8-1.3 s). In the native window the sign-in check can answer later than that,
// and a request made while the gate is still closed is swallowed ("suppressed"): the Workers and Tools lists then stayed EMPTY until
// reload (seen with build 192, whose one extra script request moved the gate's opening past the 1.0 s timer). They now wait for the gate.
const _afterGate = (fn, ms) => setTimeout(async () => { try { await window.authGateReady(); } catch (e) {} try { fn(); } catch (e) {} }, ms);
_afterGate(() => rpRefreshProposals(), 800);
_afterGate(() => workersLoadModels(), 1000);
_afterGate(() => workersUpdateMeter(), 1100);
_afterGate(() => toolsLoadPresets(), 1200);
_afterGate(() => toolsUpdateMeter(), 1300);
// One-time migration banner: poll tools.php?action=migration_status after load.
// If the server ran migrate_v2 and moved stale tool/worker files, show a brief
// system message so the user knows what happened. The notify flag is consumed
// server-side on first read — this fires at most once per rig upgrade.
setTimeout(async () => { try { await window.authGateReady(); } catch (e) {}
    try {
        const r = await fetch('tools.php?action=migration_status');
        const d = await r.json();
        if (d && d.migration_notify) {
            appendSystem(T('msg.tools.v2.migration.ran.stale.built.in.tool.c', 'ℹ️ Tools v2 migration ran: stale built-in tool copies moved to cockpit_data/tools/_backup/. User-added presets preserved in tools_state.json.'));
        }
    } catch(e) {}
}, 2000);
// Refresh workers meter periodically (every 30s) so it stays current as the
// auto-route system racks up calls in the background
setInterval(() => { try { workersUpdateMeter(); } catch(e) {} }, 30000);

// =============================================================================
// SUPPLIER CARD SYNC — keep inactive cards' display in sync with their data.
//
// Each supplier card shows the currently-selected model name in the inactive
// view (so a glance at the strip tells you what's loaded). The active card
// shows the agent label instead (CLAUDE / GEMINI / OLLAMA / WORKERS / TOOLS)
// since that's what the user is interacting with.
//
// refreshSupplierLabels() updates ALL cards based on currentAgent.
// It's safe to call from anywhere — model change handler, setAgent, init.
// =============================================================================
function refreshSupplierLabels() {
    // The active label uses uppercase agent name + a small subtitle; the
    // inactive label uses the currently-selected model name. The HTML for
    // active state mirrors the original AGENT button text (CLAUDE Arch, etc.).
    const claudeName = (window._primaryAlt && window._primaryName) ? window._primaryName : 'CLAUDE';
    const geminiName = (window._fallbackAlt && window._fallbackName) ? window._fallbackName : 'GEMINI';
    const activeLabels = {
        claude:  claudeName + '<span class="sup-name-sub">Arch</span>',
        gemini:  geminiName + '<span class="sup-name-sub">Spec</span>',
        ollama:  'OLLAMA<span class="sup-name-sub">Work</span>',
        workers: 'WORKERS<span class="sup-name-sub">Online</span>',
        tools:   'TOOLS<span class="sup-name-sub">Local</span>',
    };
    function inactiveLabel(agent) {
        if (agent === 'claude') {
            const sel = document.getElementById('claude-model');
            return sel?.options[sel.selectedIndex]?.textContent || 'Sonnet 4.6';
        }
        if (agent === 'gemini') {
            const sel = document.getElementById('gemini-model');
            return sel?.options[sel.selectedIndex]?.textContent || 'Auto';
        }
        if (agent === 'ollama') {
            const lbl = document.getElementById('ollama-selected-label');
            return lbl?.textContent || 'qwen2.5-coder:1.5b';
        }
        if (agent === 'workers') {
            const lbl = document.getElementById('workers-selected-label');
            return lbl?.textContent || '— configure —';
        }
        if (agent === 'tools') {
            const lbl = document.getElementById('tools-selected-label');
            return lbl?.textContent || '— no tools detected —';
        }
        return '';
    }
    ['claude','gemini','ollama','workers','tools'].forEach(a => {
        const card = document.getElementById('sup-card-' + a);
        const span = document.getElementById('sup-name-' + a);
        if (!card || !span) return;
        if (card.classList.contains('sup-active')) {
            span.innerHTML = activeLabels[a] || a.toUpperCase();
        } else {
            // textContent is safe — the model names don't contain HTML
            span.textContent = inactiveLabel(a);
        }
    });
}

// Wire change events for the static <select> dropdowns to refresh labels
(function wireSupplierSelectListeners() {
    ['claude-model', 'gemini-model'].forEach(id => {
        const sel = document.getElementById(id);
        if (sel) sel.addEventListener('change', refreshSupplierLabels);
    });
    // Initial render
    setTimeout(refreshSupplierLabels, 50);
})();

// ── Remember last chosen model/tool per supplier (localStorage) ─────────────
(function persistSelectedModels() {
    const keys = {
        'claude-model':  'cockpit_last_claude_model',
        'gemini-model':  'cockpit_last_gemini_model',
        'ollama-select': 'cockpit_last_ollama_model',
        'workers-model': 'cockpit_last_workers_model',
        'tools-preset':  'cockpit_last_tools_preset',
    };
    // Restore saved values
    for (const [id, sk] of Object.entries(keys)) {
        const saved = localStorage.getItem(sk);
        if (!saved) continue;
        const el = document.getElementById(id);
        if (!el) continue;
        if (el.tagName === 'SELECT') {
            const opt = el.querySelector(`option[value="${CSS.escape(saved)}"]`);
            if (opt) { el.value = saved; }
        } else {
            // hidden input — set value, update label + selected class
            el.value = saved;
        }
    }
    // Restore Ollama custom panel selected state + label
    const ollamaSaved = localStorage.getItem(keys['ollama-select']);
    if (ollamaSaved) {
        const panel = document.getElementById('ollama-panel');
        const opt = panel?.querySelector(`.cs-option[data-value="${CSS.escape(ollamaSaved)}"]`);
        if (opt) {
            panel.querySelectorAll('.cs-option').forEach(o => o.classList.remove('selected'));
            opt.classList.add('selected');
            const lbl = document.getElementById('ollama-selected-label');
            if (lbl) lbl.textContent = opt.querySelector('.cs-option-name')?.textContent?.trim() || ollamaSaved;
        }
    }
    // Wire save-on-change for native <select> (Claude, Gemini)
    ['claude-model', 'gemini-model'].forEach(id => {
        const sel = document.getElementById(id);
        if (sel) sel.addEventListener('change', () => localStorage.setItem(keys[id], sel.value));
    });
})();

// Mini-bar mirror — duplicate width changes from full bars to mini bars
// so the inactive cards still show meaningful progress at a glance.
(function wireMiniBars() {
    const pairs = [
        ['claude-bar',  'claude-bar-mini'],
        ['gemini-bar',  'gemini-bar-mini'],
        ['ollama-bar',  'ollama-bar-mini'],
        ['workers-bar', 'workers-bar-mini'],
        ['tools-bar',   'tools-bar-mini'],
    ];
    function syncAll() {
        for (const [src, dst] of pairs) {
            const s = document.getElementById(src);
            const d = document.getElementById(dst);
            if (s && d) d.style.width = s.style.width || '0%';
        }
    }
    // Sync periodically — cheap, robust to any code path that writes to bars
    setInterval(syncAll, 600);
    // And once at startup (after first paint)
    setTimeout(syncAll, 200);
})();

// Fetch cockpit version from version.php (with hardcoded fallback if PHP fails).
// The hardcoded fallback also lives in version.php; this dual-fallback ensures
// the version always shows something even if the PHP endpoint is broken.
const COCKPIT_VERSION_FALLBACK = '2.0.0';
// version.php sits behind the login: ask once the gate is open (before that the
// request is refused and the fallback hid the build number — rig, build 64).
(async () => {
    if (typeof authGateReady === 'function') await authGateReady();
    const verEl = document.getElementById('cockpit-version');
    if (!verEl) return;
    try {
        const r = await fetch('version.php', { cache: 'no-store' });   // max-age would show the pre-deploy build number
        const d = await r.json();
        // build number after the version (v2.0.0:65): which build this is, at a glance
        // v2.0.0:65 — version:build, plus · RC2 once a build is declared a
        // release candidate (Installs/RC_NUMBER). Nothing is shown otherwise:
        // the stage a build has not reached should not appear in the UI.
        verEl.textContent = 'v' + (d.version || COCKPIT_VERSION_FALLBACK)
                          + (d.build ? ':' + d.build : '')
                          ;
        if (d.rc) verEl.title = 'Release candidate ' + d.rc + ' — build ' + d.build;
        // The stage badge (BETA / PRE-RELEASE) is a fact about this BUILD, read
        // from the manifest, so every edition can show one. It used to be driven
        // by the site's pubconfig and the signed-in account's beta flag, which
        // the Stand-alone edition has no way to ask — so it never showed a stage
        // at all, however far from a final release the build was. 2026-09-26.
        // Three plates, one element: BETA (gold) · PRE-RELEASE (bronze) · RC n (teal). A release candidate (Installs/RC_NUMBER) wins over the stage; nothing shows for a final release.
        const stageEl = document.getElementById('beta-badge');
        const stageLabel = d.rc ? 'RC ' + d.rc : { 'beta': 'BETA', 'pre-release': 'PRE-RELEASE' }[d.stage || ''];
        if (stageEl && stageLabel) {
            stageEl.textContent = stageLabel;
            stageEl.classList.remove('gold', 'bronze', 'teal');
            stageEl.classList.add(d.rc ? 'teal' : (d.stage === 'beta' ? 'gold' : 'bronze'));
            stageEl.title = d.rc ? 'Release candidate ' + d.rc + ' — feature-complete, being checked before the release'
                : d.stage === 'beta'
                ? 'Public beta — everything is unlocked for all registered users; subscriptions arrive when beta ends'
                : 'Pre-release build — public and feature-complete, but not a final release';
            stageEl.style.display = 'inline-block';
        }
    } catch (e) {
        verEl.textContent = 'v' + COCKPIT_VERSION_FALLBACK;
    }
})();

// =============================================================================
// SCHEDULER UI — Scheduled Jobs panel
// All JS lives inside this existing script block to avoid double-body issues.
// =============================================================================

let _schedPanelOpen = false;
let _schedCronLine  = '';

async function schedulerOpenPanel() {
    _schedPanelOpen = true;
    document.getElementById('scheduler-panel-overlay').style.display = 'block';
    document.getElementById('scheduler-panel').style.display = 'block';
    await schedulerRefresh();
}

function schedulerClosePanel() {
    _schedPanelOpen = false;
    document.getElementById('scheduler-panel-overlay').style.display = 'none';
    document.getElementById('scheduler-panel').style.display = 'none';
}

async function schedulerRefresh() {
    try {
        const r = await fetch('scheduler.php?action=status');
        const d = await r.json();
        if (!d.ok) { _schedSetMsg('Error: ' + (d.error || 'failed')); return; }
        _schedRenderHeartbeat(d.heartbeat);
        _schedRenderCronLine(d.cron_line);
        schedulerCronState();
        _schedRenderJobs(d.jobs || []);
        _schedSetMsg('');
    } catch(e) { _schedSetMsg('Network error: ' + e.message); }
}

function schedulerUpdateDot(hb) {
    const dot = document.getElementById('scheduler-hb-dot');
    if (!dot || !hb) return;
    dot.style.background =
        hb.status === 'ok'    ? 'var(--accent-cyan)' :
        hb.status === 'stale' ? 'var(--gemini)'      :
                                'var(--claude)';
}

function _schedRenderHeartbeat(hb) {
    const lbl = document.getElementById('sched-hb-label');
    if (!lbl || !hb) return;
    schedulerUpdateDot(hb);
    if (hb.status === 'ok') {
        const ago = Math.round(hb.age_secs || 0);
        lbl.innerHTML = `<span style="color:var(--accent-cyan);"><span class="material-symbols-rounded ico">check</span> cron active — ${ago}s ago</span>`;
    } else if (hb.status === 'stale') {
        lbl.innerHTML = `<span style="color:var(--gemini);"><span class="material-symbols-rounded ico">warning</span> heartbeat stale (${Math.round(hb.age_secs)}s)</span>`;
    } else if (hb.status === 'dead') {
        lbl.innerHTML = `<span style="color:var(--claude);"><span class="material-symbols-rounded ico">close</span> cron not firing (&gt;5m)</span>`;
    } else {
        lbl.innerHTML = `<span style="color:var(--claude);"><span class="material-symbols-rounded ico">close</span> not installed — paste cron line</span>`;
    }
}

function _schedRenderCronLine(line) {
    // Build the one-liner install command from the raw cron line.
    // User pastes this in terminal — no editor needed.
    const rawCron = line || '';
    _schedCronLine = `(crontab -l 2>/dev/null | grep -v scheduler.php; echo '${rawCron}') | crontab -`;
    const el = document.getElementById('sched-cron-line');
    if (el) el.textContent = _schedCronLine;
}

// One-click install of the minute tick (scheduler.php?action=cron_install →
// sudo -u <owner> ~/scripts/cockpit_cron.sh). Jobs do nothing without it, and
// "paste this in a terminal" is not an answer inside an app (2026-09-22).
async function schedulerCronInstall() {
    const btn = document.getElementById('sched-cron-btn');
    const st  = document.getElementById('sched-cron-state');
    const installed = btn && /Remove/i.test(btn.innerText);
    if (btn) btn.disabled = true;
    if (st) st.textContent = installed ? 'Removing the minute tick…' : 'Installing the minute tick…';
    try {
        const r = await fetch('scheduler.php?action=' + (installed ? 'cron_remove' : 'cron_install'));
        const d = await r.json();
        if (!d.ok) { if (st) st.textContent = 'Could not change cron: ' + (d.error || 'unknown'); }
        else { if (typeof appendSystem === 'function') appendSystem(installed ? T('msg.scheduler.tick.removed.from.your.crontab', 'Scheduler tick removed from your crontab.') : T('msg.scheduler.tick.installed.jobs.now.run.every', 'Scheduler tick installed — jobs now run every minute.')); }
    } catch (e) { if (st) st.textContent = 'Could not change cron: ' + e.message; }
    if (btn) btn.disabled = false;
    schedulerCronState();
}
// Reflect the real crontab state in the banner.
async function schedulerCronState() {
    const btn = document.getElementById('sched-cron-btn');
    const st  = document.getElementById('sched-cron-state');
    if (!btn || !st) return;
    try {
        const d = await (await fetch('scheduler.php?action=cron_status')).json();
        if (d.ok && d.installed) {
            st.innerHTML = '<span style="color:var(--accent-cyan);">Minute tick installed</span> — jobs run every minute.';
            btn.innerHTML = '<span class="material-symbols-rounded" style="font-size:12px;">event_busy</span> Remove';
        } else {
            st.innerHTML = '<span style="color:var(--gemini);">Minute tick not installed</span> — jobs will not fire.';
            btn.innerHTML = '<span class="material-symbols-rounded" style="font-size:12px;">event_repeat</span> Install';
        }
    } catch (e) { st.textContent = 'Minute tick — state unknown (' + e.message + ')'; }
}

function schedulerCopyCron() {
    if (!_schedCronLine) return;
    navigator.clipboard.writeText(_schedCronLine).then(() => {
        _schedSetMsg('Copied!');
        setTimeout(() => _schedSetMsg(''), 2000);
    }).catch(() => _schedSetMsg('Copy failed — select manually'));
}

function _schedRenderJobs(jobs) {
    const container = document.getElementById('sched-job-list');
    if (!container) return;
    if (!jobs.length) {
        container.innerHTML = '<div style="color:var(--text-dim);font-size:10px;padding:4px 0;">No jobs scheduled.</div>';
        return;
    }
    const pending = jobs.filter(j => j.status === 'pending');
    const running = jobs.filter(j => j.status === 'running');
    const missed  = jobs.filter(j => j.status === 'missed');
    const recent  = jobs.filter(j => ['done','failed','cancelled'].includes(j.status))
                        .sort((a,b) => (b.completed_at||b.updated_at||'').localeCompare(a.completed_at||a.updated_at||''))
                        .slice(0, 10);
    let html = '';
    if (running.length) html += _schedSection('Running', running, 'var(--accent-cyan)');
    if (pending.length) html += _schedSection('Pending', pending, 'var(--text-primary)');
    if (missed.length)  html += _schedSection('Missed',  missed,  'var(--gemini)');
    if (recent.length)  html += _schedSection('Recent',  recent,  'var(--text-dim)');
    container.innerHTML = html;
}

function _schedSection(label, jobs, color) {
    return `<div style="margin-bottom:10px;">
        <div style="font-size:10px;color:${color};font-weight:600;
                    border-bottom:1px solid var(--border-dim);padding-bottom:3px;
                    margin-bottom:5px;">${escapeHtml(label)}</div>
        ${jobs.map(j => _schedJobRow(j)).join('')}
    </div>`;
}

function _schedJobRow(j) {
    const id     = escapeHtml(j.id || '');
    const cmd    = escapeHtml(j.command || '');
    const slug   = escapeHtml((j.params && (j.params.book_slug || j.params.message)) || '');
    const label  = cmd + (slug ? ` — ${slug}` : '');
    const sched  = j.scheduled_at  ? _schedFmtTime(j.scheduled_at)  : '—';
    const done   = j.completed_at  ? _schedFmtTime(j.completed_at)  : null;
    const status = j.status || '';
    const result = j.result || {};
    const badgeColor =
        status === 'done'      ? 'var(--accent-green)' :
        status === 'running'   ? 'var(--accent-cyan)'  :
        status === 'failed'    ? 'var(--claude)'       :
        status === 'missed'    ? 'var(--gemini)'       :
        status === 'cancelled' ? 'var(--text-dim)'     : 'var(--text-muted)';
    let actions = '';
    if (status === 'pending') {
        actions = `<button class="plan-tb-btn" onclick="schedulerCancel('${id}')" style="font-size:9.5px;padding:2px 6px;">Cancel</button>`;
    } else if (status === 'missed' || status === 'failed') {
        actions = `<button class="plan-tb-btn" onclick="schedulerRunNow('${id}')" style="font-size:9.5px;padding:2px 6px;">Run now</button>
                   <button class="plan-tb-btn" onclick="schedulerReschedulePrompt('${id}')" style="font-size:9.5px;padding:2px 6px;">Reschedule</button>
                   <button class="plan-tb-btn" onclick="schedulerDelete('${id}')" style="font-size:9.5px;padding:2px 6px;background:rgba(212,73,73,0.1);">Delete</button>`;
    } else if (status === 'done' || status === 'cancelled') {
        actions = `<button class="plan-tb-btn" onclick="schedulerDelete('${id}')" style="font-size:9.5px;padding:2px 6px;">Delete</button>`;
    }
    return `<div style="border:1px solid var(--border-dim);border-radius:3px;padding:6px 8px;margin-bottom:4px;background:var(--bg-darker);">
        <div style="display:flex;align-items:flex-start;gap:6px;">
            <div style="flex:1;min-width:0;">
                <span style="font-size:10.5px;color:var(--text-primary);">${label}</span>
                <span style="font-size:9.5px;color:${badgeColor};margin-left:6px;">${status}</span>
                <div style="font-size:9.5px;color:var(--text-dim);margin-top:2px;">
                    ${done ? 'Completed: ' + done : 'Scheduled: ' + sched}
                </div>
                ${result.message ? '<div style="font-size:9.5px;color:var(--text-dim);margin-top:2px;">' + escapeHtml(result.message) + '</div>' : ''}
            </div>
            <div style="display:flex;flex-direction:column;gap:3px;flex-shrink:0;">${actions}</div>
        </div>
    </div>`;
}

function _schedFmtTime(iso) {
    if (!iso) return '—';
    try {
        const d = new Date(iso);
        const diffMin = Math.round((Date.now() - d) / 60000);
        if (diffMin < 0) {
            const a = Math.abs(diffMin);
            return a < 60 ? `in ${a}m` : a < 1440 ? `in ${Math.round(a/60)}h` : `in ${Math.round(a/1440)}d`;
        }
        if (diffMin < 2)    return 'just now';
        if (diffMin < 60)   return `${diffMin}m ago`;
        if (diffMin < 1440) return `${Math.round(diffMin/60)}h ago`;
        return fmtDateTime(d);
    } catch(e) { return iso; }
}

function _schedSetMsg(msg) {
    const el = document.getElementById('sched-status-msg');
    if (el) el.textContent = msg;
}

async function schedulerCancel(jobId) {
    if (!await cockpitConfirm('Cancel job?', 'Cancel this scheduled job?', 'Cancel', {danger:true, icon:'cancel'})) return;
    _schedSetMsg('Cancelling…');
    try {
        const r = await fetch('scheduler.php?action=cancel', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({job_id: jobId}),
        });
        const d = await r.json();
        if (!d.ok) { _schedSetMsg('Error: ' + (d.error||'failed')); return; }
        await schedulerRefresh();
    } catch(e) { _schedSetMsg('Network error: ' + e.message); }
}

async function schedulerDelete(jobId) {
    if (!await cockpitConfirm('Delete job?', 'Delete this job from history?', 'Delete', {danger:true, icon:'delete'})) return;
    _schedSetMsg('Deleting…');
    try {
        const r = await fetch('scheduler.php?action=delete', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({job_id: jobId}),
        });
        const d = await r.json();
        if (!d.ok) { _schedSetMsg('Error: ' + (d.error||'failed')); return; }
        await schedulerRefresh();
    } catch(e) { _schedSetMsg('Network error: ' + e.message); }
}

async function schedulerRunNow(jobId) {
    if (!await cockpitConfirm('Run job now?', 'Run this job immediately? It may take several minutes.', 'Run', {icon:'play_arrow'})) return;
    _schedSetMsg('Running…');
    try {
        const r = await fetch('scheduler.php?action=run_now', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({job_id: jobId}),
        });
        const d = await r.json();
        _schedSetMsg(d.ok ? 'Done.' : 'Error: ' + (d.error || (d.result && d.result.message) || 'failed'));
        await schedulerRefresh();
    } catch(e) { _schedSetMsg('Network error: ' + e.message); }
}

async function schedulerReschedulePrompt(jobId) {
    const val = await cprompt('Reschedule to (e.g. "2026-05-17 03:00"):');
    if (!val) return;
    _schedSetMsg('Rescheduling…');
    try {
        const r = await fetch('scheduler.php?action=reschedule', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({job_id: jobId, scheduled_at: val}),
        });
        const d = await r.json();
        if (!d.ok) { _schedSetMsg('Error: ' + (d.error||'failed')); return; }
        _schedSetMsg('Rescheduled.');
        await schedulerRefresh();
    } catch(e) { _schedSetMsg('Network error: ' + e.message); }
}

async function schedulerRunEchoTest() {
    _schedSetMsg('Scheduling echo test…');
    try {
        const r = await fetch('scheduler.php?action=schedule', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
                command: 'echo_test',
                params: {message: 'echo test from cockpit UI at ' + new Date().toISOString()},
                scheduled_at: new Date().toISOString(),
            }),
        });
        const d = await r.json();
        if (!d.ok) { _schedSetMsg('Error: ' + (d.error||'failed')); return; }
        _schedSetMsg('Scheduled ' + d.job_id + ' — cron picks it up within 1 minute');
        await schedulerRefresh();
    } catch(e) { _schedSetMsg('Network error: ' + e.message); }
}

// Heartbeat dot update — background poll every 30s.
// Also updates the pending-jobs badge on the scheduler button.
// Delayed 5s on first load to avoid blocking page init.
(function _schedBadgePoll() {
    async function poll() {
        try {
            const r = await fetch('scheduler.php?action=status');
            const d = await r.json();
            if (!d.ok) return;

            // Update heartbeat dot
            schedulerUpdateDot(d.heartbeat);

            // Jobs chip on the scheduler button. It used to show the PENDING count
            // and hide at zero, which meant that most of the time the button showed
            // no number at all and you had to open the panel to learn you had any
            // jobs. It now shows how many jobs exist, and says in the tooltip how
            // many of those are pending or running; the accent colour carries that
            // second number so the chip still reads at a glance.
            const jobs    = d.jobs || [];
            const pending = jobs.filter(j => ['pending','running'].includes(j.status)).length;
            const badge   = document.getElementById('scheduler-pending-badge');
            if (badge) {
                badge.textContent   = jobs.length;
                badge.style.display = jobs.length > 0 ? 'block' : 'none';
                badge.style.color       = pending > 0 ? 'var(--accent-cyan)' : '';
                badge.style.borderColor = pending > 0 ? 'var(--accent-cyan)' : '';
                badge.title = jobs.length
                    ? jobs.length + ' scheduled job' + (jobs.length === 1 ? '' : 's') +
                      (pending ? ' \u00b7 ' + pending + ' pending or running' : ' \u00b7 none running')
                    : 'No scheduled jobs';
            }

            // If panel is open, re-render it too
            if (_schedPanelOpen) {
                _schedRenderHeartbeat(d.heartbeat);
                _schedRenderJobs(jobs);
            }

            // Update background tasks badge
            const bgRunning = jobs.filter(j => j.status === 'running' &&
                (j.command === 'goal_loop' || j.command === 'plan_sequence')).length;
            const bgDot = document.getElementById('bgtasks-running-dot');
            const bgBadge = document.getElementById('bgtasks-count-badge');
            if (bgDot) bgDot.style.display = bgRunning > 0 ? 'inline-block' : 'none';
            if (bgBadge) {
                bgBadge.textContent = bgRunning;
                bgBadge.style.display = bgRunning > 0 ? 'block' : 'none';
            }
        } catch(e) { /* silent */ }
    }
    setTimeout(() => { poll(); setInterval(poll, 30000); }, 5000);
})();

// Sanitizer badge — polls sanitizer.php?action=list_jobs every 30s.
// Shows pulsing dot while running, count badge of total results.
(function _accBadgePoll() {
    async function poll() {
        try {
            // Check for running accumulator jobs
            const jr = await fetch('sanitizer.php?action=list_jobs');
            const jd = await jr.json();
            const dot = document.getElementById('accumulator-running-dot');
            if (jd.ok && dot) {
                const running = (jd.jobs || []).some(j => j.status === 'running');
                dot.style.display = running ? 'inline-block' : 'none';
            }

            // Count total results for badge
            const rr = await fetch('sanitizer.php?action=list_results&filter=all');
            const rd = await rr.json();
            const badge = document.getElementById('accumulator-count-badge');
            if (rd.ok && badge) {
                const count = rd.count || 0;
                badge.textContent   = count > 99 ? '99+' : count;
                badge.style.display = count > 0 ? 'block' : 'none';
            }
        } catch(e) { /* silent */ }
    }
    setTimeout(() => { poll(); setInterval(poll, 30000); }, 8000);
})();

// =============================================================================
// AUTONOMOUS GOAL LOOP — schedule a goal-driven agent loop
// =============================================================================

async function autonomousGoalOpen() {
    let ov = document.getElementById('goal-loop-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'goal-loop-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(440px,90vw);padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<span class="material-symbols-rounded" style="font-size:18px;color:var(--accent-cyan);margin-right:8px;">smart_toy</span>' +
        '<h2 style="margin:0;font-size:14px;flex:1;">Autonomous Goal</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#goal-loop-overlay\').remove()">×</span></div>' +
        '<div style="font-size:10px;color:var(--text-dim);margin-bottom:10px;">Agent loops observe→think→act until goal is met or budget exhausted. Runs via scheduler cron.</div>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<textarea id="goal-loop-goal" placeholder="Describe the goal..." style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px;font-size:12px;border-radius:4px;min-height:60px;resize:vertical;font-family:var(--font-mono);"></textarea>' +
        '<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;">' +
        '<div><label style="font-size:10px;color:var(--text-dim);">Agent</label>' +
        '<select id="goal-loop-agent" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;font-size:11px;border-radius:4px;">' +
        '<option value="claude">Claude</option><option value="gemini">Gemini</option><option value="ollama">Ollama</option></select></div>' +
        '<div><label style="font-size:10px;color:var(--text-dim);">Max steps</label>' +
        '<input id="goal-loop-steps" type="number" value="10" min="1" max="50" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;font-size:11px;border-radius:4px;"></div>' +
        '</div>' +
        '<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;">' +
        '<div><label style="font-size:10px;color:var(--text-dim);" title="Wall-clock budget: the loop stops at this age even if steps remain. 0 = no time limit.">Stop after (minutes)</label>' +
        '<input id="goal-loop-deadline" type="number" value="30" min="0" max="1440" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 8px;font-size:11px;border-radius:3px;box-sizing:border-box;"></div>' +
        '<div><label style="font-size:10px;color:var(--text-dim);">Schedule</label>' +
        '<input id="goal-loop-when" type="text" value="now" placeholder="now, +2h, 2026-06-17 02:00" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;font-size:11px;border-radius:4px;"></div>' +
        '<div><label style="font-size:10px;color:var(--text-dim);">Repeat interval</label>' +
        '<select id="goal-loop-repeat" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;font-size:11px;border-radius:4px;">' +
        '<option value="0">Once (no repeat)</option><option value="3600">Every hour</option><option value="21600">Every 6 hours</option><option value="86400">Every day</option><option value="604800">Every week</option></select></div>' +
        '</div>' +
        '<div id="goal-loop-err" style="font-size:11px;color:var(--accent-orange);min-height:16px;"></div>' +
        '<button style="padding:9px;font-size:12px;font-weight:600;border:none;border-radius:4px;cursor:pointer;background:var(--accent-cyan);color:#000;" onclick="autonomousGoalSubmit()">Launch goal</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    document.getElementById('goal-loop-goal').focus();
}

async function autonomousGoalSubmit() {
    const goal = document.getElementById('goal-loop-goal').value.trim();
    const agent = document.getElementById('goal-loop-agent').value;
    const maxSteps = parseInt(document.getElementById('goal-loop-steps').value) || 10;
    const deadlineMin = Math.max(0, parseInt((document.getElementById('goal-loop-deadline') || {}).value) || 0);
    const when = document.getElementById('goal-loop-when').value.trim() || 'now';
    const repeat = parseInt(document.getElementById('goal-loop-repeat').value) || 0;
    const err = document.getElementById('goal-loop-err');
    if (!goal) { err.textContent = T('msg.enter.a.goal', 'Enter a goal'); return; }
    try {
        const r = await fetch('scheduler.php?action=schedule', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                command: 'goal_loop',
                scheduled_at: when === 'now' ? new Date().toISOString() : when,
                repeat_interval: repeat,
                params: {
                    goal: goal,
                    agent: agent,
                    project: currentProject || 'default',
                    max_steps: maxSteps,
                    deadline_minutes: deadlineMin,
                },
            }),
        });
        const d = await r.json();
        if (d.ok) {
            document.getElementById('goal-loop-overlay').remove();
            appendSystem(T('msg.autonomous.goal.scheduled.job.jobidrepeat.tr', 'Autonomous goal scheduled — job {jobid}{repeat}. Track in Background Tasks panel.', {jobid: d.job_id, repeat: (repeat ? ' (repeats every ' + (repeat/3600) + 'h)' : '')}));
        } else {
            err.textContent = d.error || 'Failed';
        }
    } catch(e) { err.textContent = 'Error: ' + e.message; }
}

// =============================================================================
// BACKGROUND TASKS PANEL — live view of running/recent autonomous tasks
// =============================================================================

let _bgTasksPanelOpen = false;
let _bgTasksPollTimer = null;

function bgTasksOpen() {
    _bgTasksPanelOpen = true;
    document.getElementById('bgtasks-panel-overlay').style.display = 'block';
    document.getElementById('bgtasks-panel').style.display = 'block';
    bgTasksRefresh();
    _bgTasksPollTimer = setInterval(bgTasksRefresh, 5000);
}

function bgTasksClose() {
    _bgTasksPanelOpen = false;
    document.getElementById('bgtasks-panel-overlay').style.display = 'none';
    document.getElementById('bgtasks-panel').style.display = 'none';
    if (_bgTasksPollTimer) { clearInterval(_bgTasksPollTimer); _bgTasksPollTimer = null; }
}

async function bgTasksRefresh() {
    try {
        const r = await fetch('scheduler.php?action=status');
        const d = await r.json();
        if (!d.ok) return;
        const jobs = (d.jobs || []).filter(j =>
            j.command === 'goal_loop' || j.command === 'plan_sequence' ||
            (j.repeat_interval && j.repeat_interval > 0));
        _bgTasksRender(jobs);
    } catch(e) {}
}

function _bgTasksRender(jobs) {
    const el = document.getElementById('bgtasks-list');
    if (!el) return;
    if (!jobs.length) {
        el.innerHTML = '<div style="color:var(--text-dim);font-size:11px;padding:12px 0;text-align:center;">No background tasks.<br><br>' +
            '<button class="action-btn" onclick="autonomousGoalOpen();bgTasksClose();" style="font-size:11px;padding:6px 14px;">' +
            '<span class="material-symbols-rounded" style="font-size:13px;">add</span> New autonomous goal</button></div>';
        return;
    }
    const running = jobs.filter(j => j.status === 'running');
    const pending = jobs.filter(j => j.status === 'pending');
    const done    = jobs.filter(j => !['running','pending'].includes(j.status))
                        .sort((a,b) => (b.updated_at||'').localeCompare(a.updated_at||''))
                        .slice(0, 8);
    let html = '';
    if (running.length) html += _bgSection('Running', running, 'var(--accent-cyan)');
    if (pending.length) html += _bgSection('Pending', pending, 'var(--text-muted)');
    if (done.length)    html += _bgSection('Completed', done, 'var(--text-dim)');
    el.innerHTML = html;
}

function _bgSection(label, jobs, color) {
    return `<div style="margin-bottom:10px;">
        <div style="font-size:10px;color:${color};font-weight:600;border-bottom:1px solid var(--border-dim);padding-bottom:3px;margin-bottom:5px;">${label}</div>
        ${jobs.map(j => _bgTaskRow(j)).join('')}</div>`;
}

// Step / budget / last action for an autonomous goal, so a running loop is not a
// black box: "step 3/10 · 40% · last: …" with a bar, and the wall-clock deadline
// when one was set (2026-09-22).
function _bgGoalProgress(j) {
    const g = j.goal_progress;
    if (!g || !g.max_steps) return '';
    const pct  = Math.max(0, Math.min(100, +g.progress || 0));
    const used = +g.steps_used || 0, max = +g.max_steps || 0;
    const dl   = g.deadline_at ? (' · until ' + (typeof fmtTsLocal === 'function' ? fmtTsLocal(g.deadline_at) : g.deadline_at.slice(11,16))) : '';
    const stateTxt = ({ stalled:'no progress for 3 steps', deadline_reached:'stopped at the deadline',
                        budget_exhausted:'step budget used up', complete:'goal reached', killed:'killed' })[g.status] || '';
    return `<div style="margin-top:4px;">
        <div style="height:3px;background:var(--bg-base);border-radius:2px;overflow:hidden;">
            <div style="height:100%;width:${pct}%;background:${g.status==='complete'?'var(--accent-green,#5a5)':(g.status==='stalled'?'var(--gemini)':'var(--accent-cyan)')};"></div>
        </div>
        <div style="font-size:9px;color:var(--text-muted);margin-top:2px;">
            step ${used}/${max} · ${pct}%${dl}${stateTxt ? ' · ' + stateTxt : ''}
            ${g.last_action ? '<br>last: ' + escapeHtml(g.last_action) : ''}
        </div></div>`;
}

function _bgTaskRow(j) {
    const id = j.id || '';
    const goal = (j.params && j.params.goal) || j.command || '?';
    const agent = (j.params && j.params.agent) || '?';
    const repeat = j.repeat_interval > 0 ? ' (every ' + (j.repeat_interval >= 86400 ? Math.round(j.repeat_interval/86400)+'d' : j.repeat_interval >= 3600 ? Math.round(j.repeat_interval/3600)+'h' : j.repeat_interval+'s') + ')' : '';
    const status = j.status || '';
    const statusColor = status === 'running' ? 'var(--accent-cyan)' :
                        status === 'done' ? 'var(--accent-green,#5a5)' :
                        status === 'failed' ? 'var(--claude)' : 'var(--text-dim)';
    let actions = '';
    if (status === 'running') {
        actions = `<button class="plan-tb-btn" style="font-size:9.5px;padding:2px 8px;color:var(--claude);" onclick="bgTaskKill('${id}')">
            <span class="material-symbols-rounded" style="font-size:11px;">stop</span> Kill</button>`;
    }
    if (status === 'running' && j.command === 'goal_loop') {
        actions += `<button class="plan-tb-btn" style="font-size:9.5px;padding:2px 8px;" onclick="bgTaskViewLog('${id}')">
            <span class="material-symbols-rounded" style="font-size:11px;">visibility</span> Log</button>`;
    }
    if (['done','failed'].includes(status) && j.command === 'goal_loop') {
        actions = `<button class="plan-tb-btn" style="font-size:9.5px;padding:2px 8px;" onclick="bgTaskViewLog('${id}')">
            <span class="material-symbols-rounded" style="font-size:11px;">visibility</span> Log</button>`;
    }
    return `<div style="border:1px solid var(--border-dim);border-radius:3px;padding:6px 8px;margin-bottom:4px;background:var(--bg-darker);">
        <div style="display:flex;align-items:center;gap:6px;">
            <span class="material-symbols-rounded" style="font-size:14px;color:${statusColor};">${status==='running'?'sync':'smart_toy'}</span>
            <div style="flex:1;min-width:0;">
                <div style="font-size:10.5px;color:var(--text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="${escapeHtml(goal)}">${escapeHtml(goal.slice(0,80))}</div>
                <div style="font-size:9.5px;color:var(--text-dim);">
                    ${escapeHtml(agent)} · <span style="color:${statusColor};">${status}</span>${repeat}
                    ${j.result && j.result.message ? ' · ' + escapeHtml(j.result.message) : ''}
                </div>
                ${_bgGoalProgress(j)}
            </div>
            <div style="display:flex;gap:3px;">${actions}</div>
        </div>
    </div>`;
}

async function bgTaskKill(jobId) {
    if (!await cockpitConfirm('Kill task?', 'Stop this running task?', 'Kill', {danger:true, icon:'stop'})) return;
    try {
        await fetch('scheduler.php?action=kill', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({job_id: jobId}),
        });
        appendSystem(T('msg.kill.signal.sent.to.job.jobid', 'Kill signal sent to job {jobid}', {jobid: jobId}));
        setTimeout(bgTasksRefresh, 1000);
    } catch(e) { appendError(T('msg.kill.failed.message', 'Kill failed: {message}', {message: e.message})); }
}

async function bgTaskViewLog(jobId) {
    try {
        const r = await fetch('scheduler.php?action=goal_status&job_id=' + encodeURIComponent(jobId));
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.no.log.error', 'No log: {error}', {error: (d.error||'')})); return; }
        const log = d.log;
        const lines = ['═══ Goal Loop Log: ' + (log.goal||'?') + ' ═══',
            'Status: ' + (log.status||'?'), 'Agent: ' + (log.agent||'?'), ''];
        (log.steps || []).forEach(s => {
            lines.push('─── Step ' + s.step + ' ───');
            if (s.error) { lines.push('ERROR: ' + s.error); return; }
            if (s.parsed) {
                lines.push('Action: ' + (s.parsed.action||''));
                lines.push('Observation: ' + (s.parsed.observation||''));
                lines.push('Progress: ' + (s.parsed.progress||0) + '%');
                if (s.parsed.done) lines.push('DONE');
                if (s.parsed.next) lines.push('Next: ' + s.parsed.next);
            } else {
                lines.push(s.response || '(no response)');
            }
            lines.push('');
        });
        appendSystem(lines.join('\n'));
    } catch(e) { appendError(T('msg.log.fetch.error.message', 'Log fetch error: {message}', {message: e.message})); }
}

// =============================================================================
// PER-MODEL CAP EDITOR
// =============================================================================

let _capsCache = null;

async function capsLoad() {
    try {
        const r = await fetch('caps.php?action=get');
        const d = await r.json();
        if (d.ok) _capsCache = d.caps;
        return _capsCache;
    } catch(e) { return null; }
}

async function capsEditorOpen() {
    const caps = await capsLoad();
    if (!caps) { appendError(T('msg.failed.to.load.caps', 'Failed to load caps')); return; }

    let ov = document.getElementById('caps-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'caps-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';

    const agents = ['claude','gemini','ollama'];
    const labels = {claude:'Claude',gemini:'Gemini',ollama:'Ollama'};

    let rows = '';
    for (const a of agents) {
        const c = caps[a] || {};
        rows += `
        <div style="border:1px solid var(--border-dim);border-radius:4px;padding:10px;background:var(--bg-darker);">
            <div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;">
                <label style="display:flex;align-items:center;gap:6px;cursor:pointer;">
                    <input type="checkbox" id="cap-en-${a}" ${c.enabled?'checked':''}>
                    <span style="font-weight:600;font-size:12px;">${labels[a]}</span>
                </label>
                <span style="font-size:9px;color:var(--text-dim);margin-left:auto;">warn at</span>
                <input id="cap-warn-${a}" type="number" value="${c.warn_pct||80}" min="0" max="100"
                    style="width:45px;background:var(--bg-base);color:var(--text-base);border:1px solid var(--border-dim);padding:3px 5px;font-size:10px;border-radius:3px;text-align:center;">
                <span style="font-size:9px;color:var(--text-dim);">%</span>
            </div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px;">
                <div>
                    <label style="font-size:9px;color:var(--text-dim);">Daily token cap</label>
                    <input id="cap-tok-${a}" type="number" value="${c.max_tokens_day||0}" min="0" step="1000"
                        style="width:100%;background:var(--bg-base);color:var(--text-base);border:1px solid var(--border-dim);padding:5px;font-size:11px;border-radius:3px;">
                </div>
                <div>
                    <label style="font-size:9px;color:var(--text-dim);">Daily cost cap ($)</label>
                    <input id="cap-usd-${a}" type="number" value="${c.max_usd_day||0}" min="0" step="0.50"
                        style="width:100%;background:var(--bg-base);color:var(--text-base);border:1px solid var(--border-dim);padding:5px;font-size:11px;border-radius:3px;">
                </div>
            </div>
        </div>`;
    }

    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(460px,90vw);padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<span class="material-symbols-rounded" style="font-size:18px;color:var(--accent-amber);margin-right:8px;">speed</span>' +
        '<h2 style="margin:0;font-size:14px;flex:1;">Usage Caps</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#caps-overlay\').remove()">×</span></div>' +
        '<div style="font-size:10px;color:var(--text-dim);margin-bottom:12px;">Set daily token and cost limits per supplier. Warns at threshold, soft-blocks at cap. Set 0 for unlimited.</div>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' + rows +
        '<div id="caps-err" style="font-size:11px;color:var(--accent-orange);min-height:16px;"></div>' +
        '<button style="padding:9px;font-size:12px;font-weight:600;border:none;border-radius:4px;cursor:pointer;background:var(--accent-amber);color:#000;" onclick="capsEditorSave()">Save caps</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}

async function capsEditorSave() {
    const agents = ['claude','gemini','ollama'];
    const caps = {};
    for (const a of agents) {
        caps[a] = {
            enabled: document.getElementById('cap-en-' + a).checked,
            max_tokens_day: parseInt(document.getElementById('cap-tok-' + a).value) || 0,
            max_usd_day: parseFloat(document.getElementById('cap-usd-' + a).value) || 0,
            warn_pct: parseInt(document.getElementById('cap-warn-' + a).value) || 80,
        };
    }
    try {
        const r = await fetch('caps.php?action=set', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({caps}),
        });
        const d = await r.json();
        if (d.ok) {
            _capsCache = d.caps;
            document.getElementById('caps-overlay').remove();
            appendSystem(T('msg.usage.caps.saved', 'Usage caps saved.'));
        } else {
            document.getElementById('caps-err').textContent = d.error || 'Failed';
        }
    } catch(e) { document.getElementById('caps-err').textContent = 'Error: ' + e.message; }
}

// Check caps before sending — called from sendPrompt flow
async function capsCheck(agent) {
    if (!_capsCache) await capsLoad();
    if (!_capsCache) return {allowed:true};
    const cap = _capsCache[agent];
    if (!cap || !cap.enabled) return {allowed:true};

    // Gather today's usage from usageStats
    const s = usageStats[agent] || {};
    let dayTokens = 0;
    if (agent === 'claude') {
        dayTokens = s.tokens || 0;
    } else if (agent === 'gemini') {
        const today = new Date().toDateString();
        dayTokens = (s.dayStart === today) ? (s.tokens || 0) : 0;
    } else {
        dayTokens = s.tokens || 0;
    }

    const result = {allowed: true, warnings: []};
    if (cap.max_tokens_day > 0) {
        const pct = (dayTokens / cap.max_tokens_day) * 100;
        if (pct >= 100) {
            result.allowed = false;
            result.warnings.push('Daily token cap reached (' + dayTokens + '/' + cap.max_tokens_day + ')');
        } else if (pct >= (cap.warn_pct || 80)) {
            result.warnings.push('Token usage at ' + Math.round(pct) + '% of daily cap');
        }
    }
    return result;
}

// Load caps on init
_afterGate(() => capsLoad(), 2000);

