// =============================================================================
// Live clock + session status display
// =============================================================================
const DAYS   = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
let sessionStartTime = null;  // Set when sessions are confirmed running

// The status row used to carry a second live clock; the topbar clock card
// (time, date, local and server zones) replaced it in 2026-09. The slot now
// says when this Cockpit window was opened, which nothing else shows.
const _appStartedAt = new Date(performance.timeOrigin || Date.now());
function updateClock() {
    const el = document.getElementById('live-clock');
    if (!el) return;
    const d  = _appStartedAt;
    const hh = String(d.getHours()).padStart(2,'0');
    const mm = String(d.getMinutes()).padStart(2,'0');
    const dd = String(d.getDate()).padStart(2,'0');
    const mo = String(d.getMonth()+1).padStart(2,'0');
    const ss = String(d.getSeconds()).padStart(2,'0');
    el.textContent = 'Started ' + dd + '/' + mo + '/' + d.getFullYear() + ' ' + hh + ':' + mm + ':' + ss;
    el.title = 'This Cockpit window was opened at ' + d.toLocaleString();
}

function updateSessionStatus(allRunning, upCount) {
    const lbl = document.getElementById('session-status-label');
    const val = document.getElementById('session-status-val');

    // Default upCount when called from legacy paths (e.g. the 1Hz tick loop)
    if (typeof upCount !== 'number') upCount = allRunning ? 3 : 0;

    // ─ Update the legacy status label/value pair if both still exist in DOM.
    //   Some cockpit topbar revisions removed `session-status-label`; we still
    //   want to drive the lifecycle controls (START button, count badge, amber
    //   pulse) regardless of whether those legacy text elements are present.
    //   Bug fix 2026-05-09: previous version returned early when either was
    //   missing, which silently disabled all the new Phase 2a behaviors.
    if (lbl && val) {
        if (allRunning) {
            if (!sessionStartTime) sessionStartTime = Date.now();
            lbl.style.color = 'var(--gemini)';
            lbl.textContent = T('msg.sessions', 'SESSIONS');
            const sec  = Math.floor((Date.now() - sessionStartTime) / 1000);
            const h    = Math.floor(sec / 3600);
            const m    = Math.floor((sec % 3600) / 60);
            const s    = sec % 60;
            const dur  = (h ? h + 'h ' : '') + (m ? m + 'm ' : '') + s + 's';
            val.textContent = 'Running · ' + dur;
            val.style.color = 'var(--gemini)';
        } else {
            sessionStartTime = null;
            lbl.style.color  = 'var(--ollama)';
            lbl.textContent  = T('msg.sessions', 'SESSIONS');
            val.textContent  = (upCount > 0) ? ('Partial (' + upCount + '/3)') : 'Stopped';
            val.style.color  = 'var(--text-muted)';
        }
    } else if (val) {
        // Modern topbar: only the value span remains (no separate label).
        // Update it with a compact status text driven by upCount.
        if (allRunning) {
            if (!sessionStartTime) sessionStartTime = Date.now();
            const sec = Math.floor((Date.now() - sessionStartTime) / 1000);
            const h   = Math.floor(sec / 3600);
            const m   = Math.floor((sec % 3600) / 60);
            const s   = sec % 60;
            const dur = (h ? h + 'h ' : '') + (m ? m + 'm ' : '') + s + 's';
            val.textContent = 'Sessions: ' + dur;
            val.style.color = 'var(--gemini)';
        } else {
            sessionStartTime = null;
            val.textContent = (upCount > 0) ? ('Sessions: ' + upCount + '/3') : 'Sessions: stopped';
            val.style.color = (upCount > 0) ? 'var(--accent-amber)' : 'var(--text-muted)';
        }
    }

    // 1.3c: Pulse the status bar amber when the backend is fully down.
    // Independent of the label/value elements above — these new Phase 2a
    // controls all live elsewhere in the topbar so they should always
    // run regardless of legacy element presence.
    const sb = document.querySelector('.statusbar');
    if (sb) sb.classList.toggle('backend-down', upCount === 0);

    // 1.3a (2026-07-02): only 2 control buttons visible at a time — Start+
    // Restart when stopped, Stop+Restart when running. Was Stop always
    // visible (even at 0/3, i.e. a "Stop" button with nothing to stop).
    const startBtn = document.getElementById('btn-cockpit-start');
    const stopBtn  = document.getElementById('btn-cockpit-stop');
    if (startBtn) startBtn.style.display = (upCount === 0) ? '' : 'none';
    if (stopBtn)  stopBtn.style.display  = (upCount === 0) ? 'none' : '';

    // Sessions count — a corner chip ON the button (2026-09-30), the same shape
    // Jobs and the Accumulator use. It sits on BOTH buttons because only one of
    // them is ever visible: at 0/3 the Stop button is hidden and Start is shown,
    // so a chip on Stop alone would vanish at exactly the count worth reading.
    // NOTE: .count-chip is display:none by default — force it visible here.
    const cntTxt = upCount + '/3';
    for (const id of ['sessions-count', 'sessions-count-start']) {
        const cnt = document.getElementById(id);
        if (cnt) { cnt.textContent = cntTxt; cnt.style.display = 'inline-block'; }
    }
}

// Start the clock ticking every second
setInterval(() => {
    updateClock();
    // Also update running duration every second if sessions are up
    const dot = document.getElementById('dot-claude');
    if (dot && dot.classList.contains('ok-claude')) {
        updateSessionStatus(true);
    }
}, 1000);

// 1.3 — Periodic status polling. refreshStatus() polls status.php and updates
// per-agent dots. Without this setInterval, the cockpit only refreshed status
// at init and after Stop/Restart clicks, meaning if a tmux session crashed
// outside the cockpit (or recovered), the UI wouldn't reflect it.
//
// 4-second cadence balances responsiveness against load. status.php is cheap
// (3 tmux has-session calls + a stat) so this is fine on the local machine.
setInterval(() => {
    refreshStatus();
}, 4000);

// =============================================================================
// Session control — Stop / Restart tmux agent sessions
// =============================================================================
async function sessionControl(action, opts) {
    const label = action === 'stop' ? 'Stopping' : 'Restarting';
    appendSystem(T('msg.label.agent.sessions', '{label} agent sessions...', {label: label}));

    try {
        if (action === 'restart') {
            // Step 1: Stop sessions
            appendSystem(T('msg.step.1.3.stopping.sessions', 'Step 1/3 — Stopping sessions...'));
            const r1 = await fetch('session.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'action=stop'
            });
            const d1 = await r1.json();
            if (!d1.ok) {
                appendError(T('msg.session.error.stop.failed.error', '[SESSION ERROR] Stop failed: {error}', {error: (d1.error || d1.output || '')}));
                return;
            }
            appendSystem(T('msg.step.2.3.waiting.4.seconds', 'Step 2/3 — Waiting 4 seconds...'));
            await new Promise(r => setTimeout(r, 4000));

            // Step 2: Start sessions
            appendSystem(T('msg.step.3.3.starting.sessions', 'Step 3/3 — Starting sessions...'));
            const r2 = await fetch('session.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'action=start'
            });
            const d2 = await r2.json();
            if (!d2.ok) {
                appendError(T('msg.session.error.start.failed.error', '[SESSION ERROR] Start failed: {error}', {error: (d2.error || d2.output || '')}));
                return;
            }
            appendSystem(T('msg.sessions.restarted.reloading.cockpit.in.3.se', 'Sessions restarted. Reloading cockpit in 3 seconds...'));
            setTimeout(() => location.reload(), 3000);

        } else {
            // Stop only
            const res  = await fetch('session.php', {
                method: 'POST',
                headers: {'Content-Type': 'application/x-www-form-urlencoded'},
                body: 'action=stop' + (opts && opts.leave ? '&leave=1' : '')
            });
            const data = await res.json();
            if (data.ok) {
                appendSystem(T('msg.sessions.stopped', 'Sessions stopped.'));
                refreshStatus();
            } else {
                appendError(T('msg.session.error.error', '[SESSION ERROR] {error}', {error: (data.error || data.output || 'Unknown error')}));
            }
        }
    } catch(e) {
        appendError(T('msg.session.error.message', '[SESSION ERROR] {message}', {message: e.message}));
    }
}

// =============================================================================
// Per-supplier start/stop — toggle a single agent's tmux session.
// Backend: session.php accepts action=start|stop & target=claude|gemini|ollama.
// Requires per-agent sudoers entries (see /etc/sudoers.d/cockpit-session-env).
// =============================================================================
function _updateSupplierPowerBtn(agent, isUp) {
    const btn = document.getElementById('sup-power-' + agent);
    if (!btn) return;
    // Color is a SECONDARY cue only — the text label carries the meaning so it
    // stays readable for colour-vision-deficient users.
    btn.style.color = isUp ? 'var(--ollama)' : 'var(--accent-cyan)';
    // Use the actual supplier name for the slot (Card 1 = primary, Card 2 = fallback),
    // not the hardcoded slot id — so a Codex-in-Card-2 reads "Codex", not "Gemini".
    let name = agent.charAt(0).toUpperCase() + agent.slice(1);
    if (agent === 'claude' && window._primaryName)  name = window._primaryName;
    else if (agent === 'gemini' && window._fallbackName) name = window._fallbackName;
    btn.title = (isUp ? 'Stop ' : 'Start ') + name + ' session';
    const lbl = document.getElementById('sup-power-label-' + agent);
    if (lbl) lbl.textContent = isUp ? 'ON' : 'OFF';
}

async function supplierToggle(agent) {
    if (!['claude','gemini','ollama'].includes(agent)) return;
    const dot    = document.getElementById('dot-' + agent);
    const isUp   = !!(dot && dot.classList.contains('ok-' + agent));
    const action = isUp ? 'stop' : 'start';
    const btn    = document.getElementById('sup-power-' + agent);
    if (btn) { btn.disabled = true; btn.style.opacity = '0.55'; }
    appendSystem(T('msg.isupagent.session', '{isup}{agent} session...', {isup: (isUp ? 'Stopping ' : 'Starting '), agent: agent}));

    try {
        const r = await fetch('session.php', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'action=' + action + '&target=' + encodeURIComponent(agent)
        });
        const d = await r.json();
        if (!d.ok) {
            appendError(T('msg.session.error.agent.action.failed.error', '[SESSION ERROR] {agent} {action} failed: {error}', {agent: agent, action: action, error: (d.error || d.output || 'unknown')}));
        } else {
            appendSystem(T('msg.agent.session.action', '{agent} session {action}.', {agent: agent, action: (action === 'start' ? 'started' : 'stopped')}));
        }
    } catch(e) {
        appendError(T('msg.session.error.message', '[SESSION ERROR] {message}', {message: e.message}));
    } finally {
        if (btn) { btn.disabled = false; btn.style.opacity = ''; }
        // Give tmux a moment, then re-read status so dots + button colors update.
        setTimeout(refreshStatus, 1500);
    }
}

// =============================================================================
// Load-time lifecycle suggestion (once per browser session)
// On page load, read status.php and offer the relevant action:
//   • nothing running  → suggest Start
//   • all running      → suggest Stop / Restart
//   • partial          → suggest Restart / Stop
// Shown at most once per browser session via sessionStorage, and never
// traps the user (Dismiss is always available).
// =============================================================================
async function lifecycleLoadPrompt() {
    if (sessionStorage.getItem('cockpit_lifecycle_prompted')) return;

    let upCount = 0;
    const up = { claude:false, gemini:false, ollama:false };
    try {
        const res = await fetch('status.php', { cache: 'no-store' });
        const d   = await res.json();
        ['claude','gemini','ollama'].forEach(a => {
            const ok = !!(d[a] && d[a].ok);
            up[a] = ok;
            if (ok) upCount++;
        });
    } catch(e) {
        return; // status unreadable — stay silent rather than guess
    }

    // Mark as prompted only once we actually have a state to show.
    sessionStorage.setItem('cockpit_lifecycle_prompted', '1');

    // 2026-09-13: launching the app IS the request to have the agents up. Start
    // whatever is down (cockpit_start skips sessions already running) instead
    // of asking Start / Dismiss; the modal is kept only for a failed start.
    if (upCount === 3) return;
    const down = ['claude','gemini','ollama'].filter(a => !up[a]);
    appendSystem(T('msg.agent.sessions.down.n.starting', 'Agent sessions down: {n} — starting.', {n: down.join(', ')}));
    try { await lifecycleStart(); } catch (e) {}
    // First launch on a fresh install: cockpit_start.sh (the launcher) is still
    // bringing the CLI sessions up while we look — 6 s was not enough on a VM
    // and a "did not start" modal greeted every new user. Poll up to 40 s.
    let still = [];
    for (let i = 0; i < 13; i++) {
        await new Promise(r => setTimeout(r, 3000));
        try {
            const d = await (await fetch('status.php', { cache: 'no-store' })).json();
            still = ['claude','gemini','ollama'].filter(a => !(d[a] && d[a].ok));
        } catch (e) { still = []; break; }
        if (!still.length) break;
    }
    if (still.length) _showLifecycleLoadModal('Agent sessions did not start', 'Still down: ' + still.join(', ') + '. Try again, or start them from a terminal: ~/scripts/cockpit_start.sh',
        [{ label:'Start again', accent:'var(--accent-cyan)', run: lifecycleStart }]);
}

// onDismiss (optional) fires when the modal is closed WITHOUT picking one of
// the action buttons — backdrop click, Escape, or Dismiss. Callers that need
// to clean up something they staged before opening the modal (e.g. a chat
// placeholder awaiting an answer) can't otherwise tell those apart.
function _showLifecycleLoadModal(title, message, buttons, onDismiss) {
    const existing = document.getElementById('lifecycle-load-modal');
    if (existing) existing.remove();

    const modal = document.createElement('div');
    modal.id = 'lifecycle-load-modal';
    modal.style.cssText =
        'position:fixed;inset:0;z-index:99998;display:flex;align-items:center;' +
        'justify-content:center;background:rgba(0,0,0,.6);';
    let chose = false;
    const close = () => {
        modal.remove();
        document.removeEventListener('keydown', escH);
        if (!chose && typeof onDismiss === 'function') onDismiss();
    };
    const escH  = e => { if (e.key === 'Escape') close(); };
    modal.addEventListener('click', e => { if (e.target === modal) close(); });

    let btnHtml = '';
    buttons.forEach((b, i) => {
        btnHtml += '<button data-i="' + i + '" style="background:' + b.accent + ';border:none;' +
            'color:var(--bg-base);font-weight:700;font-size:12px;padding:7px 16px;border-radius:5px;' +
            'cursor:pointer;">' + b.label + '</button>';
    });
    btnHtml += '<button data-dismiss="1" style="background:none;border:1px solid var(--border-mid);' +
        'color:var(--text-base);font-size:12px;padding:7px 16px;border-radius:5px;cursor:pointer;">Dismiss</button>';

    modal.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;' +
        'min-width:340px;max-width:460px;padding:18px 20px;box-shadow:0 8px 32px rgba(0,0,0,.6);' +
        'font-size:12px;color:var(--text-base);">' +
        '<div style="font-weight:700;font-size:14px;color:var(--text-bright);margin-bottom:8px;">' + title + '</div>' +
        '<div style="color:var(--text-muted);line-height:1.5;margin-bottom:16px;">' + message + '</div>' +
        // wrap: callers with more than ~3 choices (the dual-model score modal
        // has five plus Dismiss) would otherwise overflow the 460px box.
        '<div style="display:flex;gap:8px;justify-content:flex-end;flex-wrap:wrap;">' + btnHtml + '</div></div>';

    document.body.appendChild(modal);
    document.addEventListener('keydown', escH);
    modal.querySelectorAll('button').forEach(btn => {
        btn.addEventListener('click', () => {
            const di = btn.getAttribute('data-i');
            if (di !== null) chose = true;      // set before close() so onDismiss stays quiet
            close();
            if (di !== null) { const b = buttons[+di]; if (b && b.run) b.run(); }
        });
    });
}

document.addEventListener('DOMContentLoaded', () => {
    // Only once the request gate is open (a confirmed local session): on a
    // slow first run the 1.8 s timer fired before the gate and the start went
    // out as "Authentication required" (Fedora VM). Then a slight delay so the
    // first status poll and base UI settle first.
    const go = () => setTimeout(lifecycleLoadPrompt, 1800);
    if (typeof authGateReady === 'function') authGateReady().then(go); else go();
});

// =============================================================================
// 1.3 Lifecycle widgets — START + RESTART (with confirm + poll-then-reload)
// =============================================================================
//
// Companions to the existing sessionControl(). The differences:
//   * lifecycleStart()        — used by the new START button (visible only when
//                               all sessions are down). Same call shape as
//                               sessionControl('start') but follows up with a
//                               poll-status-until-up loop, then reloads the
//                               page so the freshly-running backend is picked
//                               up cleanly. Replaces the "click Stop ; manually
//                               run cockpit_start.sh in a terminal" workaround.
//   * lifecycleRestart()      — replaces the 3-second blind setTimeout reload
//                               in sessionControl('restart') with a real
//                               poll-status-until-up loop. The blind reload
//                               raced the backend coming back, sometimes
//                               briefly showing "backend down" right after a
//                               restart. The new path waits for proof.
//   * lifecycleConfirmRestart — gates Restart behind the lifecycle confirm
//                               modal (single-purpose for now; designed to be
//                               reusable for other confirmable actions later).
//
// `pollUntilStatus(predicate, opts)` is the shared helper. It polls
// status.php repeatedly with backoff until the predicate is satisfied, OR
// the timeout elapses. Returns the final status object on success, throws
// on timeout. Used by both lifecycleStart and lifecycleRestart.
// =============================================================================

// Holds the action queued by lifecycleConfirmRestart() until the user clicks
// Proceed in the modal. Pattern lets the same modal be reused for other
// confirmable lifecycle actions in the future without per-action wiring.
window._lifecyclePending = null;

async function pollUntilStatus(predicate, opts) {
    opts = opts || {};
    const timeoutMs   = opts.timeoutMs || 30000;   // total cap
    const intervalMs  = opts.intervalMs || 700;    // poll cadence
    const onProgress  = opts.onProgress || null;   // optional UI tick
    const startedAt   = Date.now();
    let attempt = 0;

    while (Date.now() - startedAt < timeoutMs) {
        attempt++;
        let data = null;
        try {
            const res = await fetch('status.php', { cache: 'no-store' });
            data = await res.json();
        } catch (e) {
            // Network blip — keep polling. Apache may be mid-restart, etc.
        }
        if (data && predicate(data)) return data;
        if (onProgress) onProgress(attempt, data);
        await new Promise(r => setTimeout(r, intervalMs));
    }
    throw new Error('pollUntilStatus: timed out after ' + timeoutMs + 'ms');
}

// Predicate: all three named tmux sessions reporting ok:true
function _allSessionsUp(data) {
    return data && data.claude && data.gemini && data.ollama
        && data.claude.ok && data.gemini.ok && data.ollama.ok;
}

async function lifecycleStart() {
    const btn = document.getElementById('btn-cockpit-start');
    if (btn) { btn.disabled = true; btn.style.opacity = '0.55'; }
    appendSystem(T('msg.starting.agent.sessions', 'Starting agent sessions...'));

    try {
        const r = await fetch('session.php', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'action=start'
        });
        const d = await r.json();
        if (!d.ok) {
            appendError(T('msg.session.error.start.failed.error', '[SESSION ERROR] Start failed: {error}', {error: (d.error || d.output || '')}));
            if (btn) { btn.disabled = false; btn.style.opacity = ''; }
            return;
        }
        appendSystem(T('msg.start.script.returned.waiting.for.tmux.sessi', 'Start script returned. Waiting for tmux sessions to come up...'));
        await pollUntilStatus(_allSessionsUp, {
            timeoutMs: 30000,
            onProgress: (n) => {
                if (n === 6 || n === 12 || n === 20) {
                    appendSystem(T('msg.still.waiting.ns.elapsed', '  …still waiting ({n}s elapsed)', {n: (n * 0.7).toFixed(0)}));
                }
            }
        });
        appendSystem(T('msg.all.sessions.up.reloading.cockpit', 'All sessions up. Reloading cockpit...'));
        // Defensive reload — if location.reload() throws (rare, seen on some
        // browsers when the page is mid-transition), fall back to forcing a
        // full navigation to the same URL.
        setTimeout(() => {
            try {
                location.reload();
            } catch (e) {
                window.location.href = window.location.href;
            }
        }, 600);
    } catch(e) {
        appendError(T('msg.session.error.message.check.tmux.manually.wi', '[SESSION ERROR] {message} — the agent sessions did not answer. Try again, or start them from a terminal with ~/scripts/cockpit_start.sh', {message: e.message}));
        if (btn) { btn.disabled = false; btn.style.opacity = ''; }
    }
}

async function lifecycleRestart() {
    appendSystem(T('msg.restarting.agent.sessions', 'Restarting agent sessions...'));

    try {
        // Step 1: stop
        appendSystem(T('msg.step.1.3.stopping.sessions', 'Step 1/3 — Stopping sessions...'));
        const r1 = await fetch('session.php', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'action=stop'
        });
        const d1 = await r1.json();
        if (!d1.ok) {
            appendError(T('msg.session.error.stop.failed.error', '[SESSION ERROR] Stop failed: {error}', {error: (d1.error || d1.output || '')}));
            return;
        }

        // Step 2: short settle so any in-flight bridge polls drain
        appendSystem(T('msg.step.2.3.waiting.4.seconds.for.sockets.to.dr', 'Step 2/3 — Waiting 4 seconds for sockets to drain...'));
        await new Promise(r => setTimeout(r, 4000));

        // Step 3: start
        appendSystem(T('msg.step.3.3.starting.sessions', 'Step 3/3 — Starting sessions...'));
        const r2 = await fetch('session.php', {
            method: 'POST',
            headers: {'Content-Type': 'application/x-www-form-urlencoded'},
            body: 'action=start'
        });
        const d2 = await r2.json();
        if (!d2.ok) {
            appendError(T('msg.session.error.start.failed.error', '[SESSION ERROR] Start failed: {error}', {error: (d2.error || d2.output || '')}));
            return;
        }

        // Wait for actual readiness (replaces the previous blind 3s setTimeout
        // that sometimes raced the backend coming back up and briefly painted
        // a "backend down" state right after a restart).
        appendSystem(T('msg.start.returned.polling.status.until.backend', 'Start returned. Polling status until backend is up...'));
        await pollUntilStatus(_allSessionsUp, {
            timeoutMs: 30000,
            onProgress: (n) => {
                if (n === 6 || n === 12 || n === 20) {
                    appendSystem(T('msg.still.waiting.ns.elapsed', '  …still waiting ({n}s elapsed)', {n: (n * 0.7).toFixed(0)}));
                }
            }
        });
        appendSystem(T('msg.sessions.confirmed.up.reloading.cockpit', 'Sessions confirmed up. Reloading cockpit...'));
        setTimeout(() => {
            try {
                location.reload();
            } catch (e) {
                window.location.href = window.location.href;
            }
        }, 600);
    } catch(e) {
        appendError(T('msg.session.error.message', '[SESSION ERROR] {message}', {message: e.message}));
    }
}

// Open the confirm modal, queueing lifecycleRestart as the action to fire
// if the user proceeds. Clicking Cancel or hitting Esc/click-backdrop both
// close the modal without running anything.
function lifecycleConfirmRestart() {
    window._lifecyclePending = {
        action: 'restart',
        run: lifecycleRestart,
        title: 'Restart agent sessions?',
        message: 'This will stop and restart the Claude, Gemini, and Ollama tmux sessions. ' +
                 'Any in-flight prompt requests will be cancelled.',
        icon: 'restart_alt',
        proceedLabel: 'Restart'
    };
    _lifecycleConfirmShow();
}

function _lifecycleConfirmShow() {
    const p = window._lifecyclePending;
    if (!p) return;
    const m = document.getElementById('lifecycle-confirm-modal');
    if (!m) return;

    document.getElementById('lifecycle-confirm-title').textContent   = p.title;
    document.getElementById('lifecycle-confirm-message').textContent = p.message;
    document.getElementById('lifecycle-confirm-icon').textContent    = p.icon || 'help';
    const btn = document.getElementById('lifecycle-confirm-proceed-btn');
    if (btn && p.proceedLabel) btn.textContent = p.proceedLabel;

    m.style.display = 'flex';

    // Focus the proceed button so Enter confirms; Esc cancels via the global
    // listener below.
    setTimeout(() => { if (btn) btn.focus(); }, 30);
}

function lifecycleConfirmCancel() {
    const m = document.getElementById('lifecycle-confirm-modal');
    if (m) m.style.display = 'none';
    window._lifecyclePending = null;
}

async function lifecycleConfirmProceed() {
    const p = window._lifecyclePending;
    const m = document.getElementById('lifecycle-confirm-modal');
    if (m) m.style.display = 'none';
    window._lifecyclePending = null;
    if (p && typeof p.run === 'function') {
        try { await p.run(); }
        catch (e) { appendError(T('msg.lifecycle.message', '[LIFECYCLE] {message}', {message: e.message})); }
    }
}

// Backdrop click + Escape both cancel the modal — matches the convention
// the existing modals (workers-modal, tools-modal, help-modal) already use.
document.addEventListener('click', (e) => {
    if (e.target?.id === 'lifecycle-confirm-modal') lifecycleConfirmCancel();
});
document.addEventListener('keydown', (e) => {
    const m = document.getElementById('lifecycle-confirm-modal');
    if (!m || m.style.display === 'none') return;
    if (e.key === 'Escape') { e.preventDefault(); lifecycleConfirmCancel(); }
    // Enter on Proceed button is handled natively by the focused button.
});

