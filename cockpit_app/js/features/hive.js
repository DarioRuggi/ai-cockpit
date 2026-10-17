// HIVE panel (H4) — window onto the local multi-agent bus (hive.php).
// Local-first: the sidebar Hive section only goes live when the hive folder exists on this machine.
// =============================================================================
let _hivePoll = null;
async function hiveAvailProbe() {
    try {
        // Ungated probe — reveals only availability + this caller's caps. Sidebar shows
        // for Basic+ (Cruise users reach the toggle inside the panel); the badge
        // poll (active-chains) only runs for Cognition (its own manual chains).
        const d = await (await fetch('hive.php?action=avail')).json();
        if (d && d.ok && d.available && (capCan('cruise') || capCan('cognition'))) {
            if (typeof hiveBarStatus === 'function') hiveBarStatus();
        }
    } catch (e) { /* no hive here — leave the sidebar in its idle state */ }
}
try { hiveBarInit(); } catch (e) {}          // Phase 1: sidebar status + PLAN gating
setInterval(() => { try { hiveBarStatus(); } catch (e) {} }, 30000);

// Phase 2 — scope the modal to ONE concern. The whole modal is nine concerns in
// one scroll; the sidebar buttons each mean a single thing, so honour that.
// hiveApplyView()          -> everything (no scope: every Hive control)
// hiveApplyView('agents')  -> roster + manual send
// hiveApplyView('chains')  -> goal box + task board
// hiveApplyView('broker')  -> broker state + pending proposals
// Pure show/hide: no polling, endpoint or entitlement logic moves.
var HIVE_VIEW_TITLES = {
    agents: 'Hive — Agents on the bus',
    chains: 'Hive — Task chains',
    broker: 'Hive — Consent broker'
};
function hiveApplyView(view) {
    if (!HIVE_VIEW_TITLES[view]) view = null;          // unknown/absent = show all
    document.querySelectorAll('#hive-modal [data-hview]').forEach(el => {
        el.style.display = (!view || el.getAttribute('data-hview') === view) ? '' : 'none';
    });
    const t = document.getElementById('hive-modal-title');
    if (t) t.textContent = view ? HIVE_VIEW_TITLES[view] : 'Hive — AutoCognition';
    const all = document.getElementById('hive-show-all');
    if (all) all.style.display = view ? '' : 'none';
}
function hiveOpen(view) {
    const m = document.getElementById('hive-modal'); if (!m) return;
    m.style.display = 'flex';
    hiveApplyView(view);   // Phase 2: scope the modal to one concern (or show everything)
    const gcb = document.getElementById('hive-run-now');   // Phase 4: inverted sense — checked means SKIP the review
    if (gcb) gcb.checked = !hiveGateEnabled();
    // AutoCognition (bus, chains, broker, manual send) is Pro. Not entitled →
    // read-only: no polling of gated endpoints, manual controls disabled, banner.
    hiveApplyCognitionGate();
    if (!capCan('cognition')) { if (_hivePoll) { clearInterval(_hivePoll); _hivePoll = null; } return; }
    hiveRefresh();
    if (_hivePoll) clearInterval(_hivePoll);
    _hivePoll = setInterval(hiveRefresh, 4000);
}
// Disable the Cognition-only controls + show an upsell banner when not entitled.
function hiveApplyCognitionGate() {
    const ok = capCan('cognition');
    ['hive-to','hive-type','hive-subject','hive-body','hive-cmd'].forEach(id => {
        const el = document.getElementById(id); if (el) el.disabled = !ok;
    });
    // the Send button is the button right after #hive-body's row — mark by title/onclick
    document.querySelectorAll('#hive-modal button[onclick^="hiveSend"]').forEach(b => { b.disabled = !ok; b.style.opacity = ok ? '' : '.5'; });
    let banner = document.getElementById('hive-cog-gate');
    if (!ok) {
        if (!banner) {
            banner = document.createElement('div');
            banner.id = 'hive-cog-gate';
            banner.style.cssText = 'font-size:11px;color:var(--text-dim);background:var(--bg-darker,var(--bg-codeblock));border:1px solid var(--border-dim);border-radius:4px;padding:7px 9px;margin-bottom:12px;';
            banner.innerHTML = '<span class="material-symbols-rounded ico">lock</span> <b>AutoCognition</b> (agent bus, task chains, broker, quorum) is a <b>Pro</b> feature — shown read-only.' + ((typeof capCan === 'function' && capCan('cruise')) ? ' <b>Autopilot Cruise</b> above stays available.' : ' Autopilot Cruise needs the <b>Plus</b> plan or higher.');
            // Anchor it ABOVE the first scoped block, not inside one — otherwise the
            // upsell disappears in every view that isn't 'agents'.
            const anchor = document.querySelector('#hive-modal [data-hview]');
            if (anchor && anchor.parentNode) anchor.parentNode.insertBefore(banner, anchor);
        }
        banner.style.display = '';
    } else if (banner) { banner.style.display = 'none'; }
}
function hiveClose() {
    const m = document.getElementById('hive-modal'); if (m) m.style.display = 'none';
    if (_hivePoll) { clearInterval(_hivePoll); _hivePoll = null; }
}
function hiveTypeChange() {
    const t = document.getElementById('hive-type').value;
    document.getElementById('hive-cmd').style.display = (t === 'call') ? '' : 'none';
}
let _hiveBrokerCmd = '';
function hiveCopyBrokerCmd() { if (_hiveBrokerCmd) navigator.clipboard?.writeText(_hiveBrokerCmd); }
async function hiveDecline(to, id) {
    try {
        await fetch('hive.php?action=decline', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ to, id }) });
        hiveRefresh();
    } catch (e) { /* ignore */ }
}
async function hiveChainResume(id) {
    try {
        await fetch('hive.php?action=chain_resume', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }) });
        hiveRefresh();
    } catch (e) { /* ignore */ }
}
// C1b: drive a chain through the durable engine — run each step until done,
// blocked (needs a non-local agent), or failed. Live progress via hiveRefresh.
const _hiveChainRunning = {};
async function hiveChainRun(id) {
    if (_hiveChainRunning[id]) return;
    _hiveChainRunning[id] = true;
    try {
        let lastRemaining = -1;
        for (let i = 0; i < 100; i++) {
            // chain_run_step drives single/quorum/non-local steps; it hands parallel
            // groups to chain_run_group (curl_multi concurrent).
            let d = await (await fetch('hive.php?action=chain_run_step', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }) })).json();
            if (hiveGated(d)) break;   // server refused (e.g. a quorum/parallel step needs Pro)
            if (d && d.parallel) d = await (await fetch('hive.php?action=chain_run_group', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id }) })).json();
            if (hiveGated(d)) break;
            hiveRefresh();
            if (!d) break;
            if (d.done) { if (typeof appendSystem === 'function') appendSystem(T('msg.icon.link.chain.complete', '[[icon:link]] Chain complete.')); break; }
            if (d.ok === false) { if (typeof appendSystem === 'function') appendSystem(T('msg.icon.link.chain.failed.a.step.errored', '[[icon:link]] Chain failed (a step errored).')); break; }
            if (d.blocked) { if (typeof appendSystem === 'function') appendSystem(T('msg.icon.link.chain.paused.at.step.step.needs.ag', '[[icon:link]] Chain paused at step {step} — needs agent {agent} (run via the bus/broker, then ▶ Run again).', {step: d.step, agent: (d.agent || '?')})); break; }
            if (Array.isArray(d.routed) && d.routed.length && (!d.ran || !d.ran.length)) {
                if (typeof appendSystem === 'function') appendSystem(T('msg.icon.link.chain.paused.step.s.routed.to.agen', '[[icon:link]] Chain paused — step(s) routed to agent(s): {map} (run those via the bus/broker, then ▶ Run again).', {map: d.routed.map(r => r.agent).join(', ')}));
                break;   // no local progress possible this pass — waiting on non-local agents
            }
            if (typeof d.remaining === 'number') { if (d.remaining === lastRemaining) break; lastRemaining = d.remaining; }
        }
    } catch (e) { if (typeof appendSystem === 'function') appendSystem(T('msg.chain.run.error.message', 'Chain run error: {message}', {message: e.message})); }
    finally { _hiveChainRunning[id] = false; }
}
const _hiveChainOpen = {};
function hiveChainToggle(id) {
    _hiveChainOpen[id] = !_hiveChainOpen[id];
    const el = document.getElementById('hive-chain-steps-' + id);
    if (el) el.style.display = _hiveChainOpen[id] ? '' : 'none';
    if (_hiveChainOpen[id]) hiveChainLoadSteps(id);
}
async function hiveChainLoadSteps(id) {
    const el = document.getElementById('hive-chain-steps-' + id);
    if (!el) return;
    try {
        const d = await (await fetch('hive.php?action=chain&id=' + encodeURIComponent(id))).json();
        if (d && d.ok) {
            const dotc = s => ({ done: 'var(--accent-green,#3cba7c)', running: 'var(--accent-amber,#e6b43c)', pending: 'var(--text-muted)', failed: 'var(--claude,#d44)' }[s] || 'var(--text-muted)');
            const g = (d.chain && d.chain.granularity) || 'normal';
            const ar = (d.chain && d.chain.auto_resume) || 'on';
            const gsel = '<div style="display:flex;align-items:center;gap:6px;flex-wrap:wrap;padding:2px 0 4px 14px;color:var(--text-muted);font-size:10px;">' +
                'granularity: ' +
                '<select onchange="hiveChainSetGranularity(\'' + escAttr(id) + '\',this.value)" style="background:var(--bg-active);color:var(--text-primary);border:1px solid var(--border-dim);border-radius:3px;font-size:10px;padding:1px 3px;">' +
                ['fine', 'normal', 'coarse'].map(o => '<option value="' + o + '"' + (o === g ? ' selected' : '') + '>' + o + (o === 'fine' ? ' (critical)' : '') + '</option>').join('') +
                '</select>' +
                '<label style="display:inline-flex;align-items:center;gap:3px;cursor:pointer;" title="Auto-resume this chain if a step is killed mid-work">' +
                '<input type="checkbox"' + (ar === 'on' ? ' checked' : '') + ' onchange="hiveChainSetAutoResume(\'' + escAttr(id) + '\',this.checked?\'on\':\'off\')"> auto-resume on kill</label>' +
                '</div>';
            el.innerHTML = gsel + (d.steps || []).map(s =>
                '<div style="display:flex;align-items:center;gap:6px;padding:2px 0 2px 14px;">' +
                '<span style="width:7px;height:7px;border-radius:50%;background:' + dotc(s.status) + ';flex:0 0 auto;"></span>' +
                '<span style="color:var(--text-muted);">' + escHtml(s.idx) + '</span>' +
                '<b style="color:var(--text-primary);">' + escHtml(s.agent) + '</b>' +
                (s.agent === 'auto' && s.need ? '<span title="routes to best agent for: ' + escAttr(s.need) + '" style="color:var(--gemini,#e6b43c);font-size:9px;">→' + escHtml(s.need) + '</span>' : '') +
                (s.quorum ? '<span title="quorum: ' + s.quorum + ' voters + judge" style="color:var(--accent-cyan);font-size:9px;"><span class="material-symbols-rounded ico">balance</span>' + s.quorum + '</span>' : '') +
                (s.parallel ? '<span title="runs in parallel" style="color:var(--text-dim);font-size:9px;">∥</span>' : '') +
                '<span style="color:var(--text-dim);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + escHtml(s.action) + '</span>' +
                (s.checkpoint ? '<span title="last checkpoint" style="color:var(--accent-cyan);font-size:9px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:110px;"><span class="material-symbols-rounded ico">flag</span> ' + escHtml(s.checkpoint) + '</span>' : '') +
                '<span style="margin-left:auto;color:' + dotc(s.status) + ';font-size:10px;">' + escHtml(s.status) + '</span>' +
                '</div>').join('');
        }
    } catch (e) { /* ignore */ }
}
async function hiveChainSetGranularity(id, g) {
    try {
        await fetch('hive.php?action=chain_granularity', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, granularity: g }) });
        hiveChainLoadSteps(id);
    } catch (e) { /* ignore */ }
}
async function hiveChainSetAutoResume(id, v) {
    try {
        await fetch('hive.php?action=chain_autoresume', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ id, auto_resume: v }) });
    } catch (e) { /* ignore */ }
}
async function hiveSetAutoResumeDefault(v) {
    try {
        await fetch('hive.php?action=config', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ auto_resume_default: v }) });
    } catch (e) { /* ignore */ }
}
// Phase 3 — Autopilot Cruise is no longer a hidden mode. It used to be a
// checkbox in this modal that silently changed what the Enter key did, and it
// defaulted ON. Planning now happens only when the user presses  PLAN.
//
// This stub exists to clear the persisted preference. Leaving the key behind
// would mean a future read could resurrect a mode the UI no longer exposes —
// exactly the ghost-setting failure this phase removes. Drop it once, quietly.
function hiveCruiseRetire() {
    try {
        if (localStorage.getItem('cockpit_autocruise') !== null) {
            localStorage.removeItem('cockpit_autocruise');
        }
    } catch (e) { /* private mode / storage blocked — nothing to clean */ }
}
// Is this a trivial message that doesn't need multi-step planning? (short, single
// task, no sequencing/list). Trivial → one routed step, skip the planner (faster).
function _isTrivialGoal(t) {
    const s = (t || '').trim();
    if (s.split(/\s+/).length > 14) return false;
    if (/\b(then|after that|and then|next,|step\s*\d)\b/i.test(s)) return false;
    if (/\n\s*[-*\d]/.test(s)) return false;                 // a list
    if ((s.match(/[.?!]/g) || []).length > 2) return false;  // multiple sentences
    return true;
}
// Main-chat Autopilot Cruise: plan the message into a chain, run it durably,
// and post the final result back into the chat. Returns true if it handled the send.
async function hivePlanAndRun(goal) {
    if (!capCan('cruise')) return false;   // not entitled → fall through to Manual send
    try {
        const _lm = (typeof _localModelFor === 'function') ? _localModelFor('ollama') : null;
        const model = (_lm && _lm.model) || 'qwen2.5:7b';
        let d;
        if (_isTrivialGoal(goal)) {
            // Fast-path: one routed step, no planner call.
            if (typeof appendSystem === 'function') appendSystem(T('msg.icon.flight.cruise.direct', '[[icon:flight]] Cruise (direct)…'));
            const combo = { id: 'direct', name: goal.slice(0, 48), pattern: 'sequential', steps: [{ runner: 'auto', need: 'text', model, prompt: goal }] };
            d = await (await fetch('hive.php?action=combo_to_chain', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ combo }) })).json();
            if (d && d.ok) d.count = 1;
        } else {
            if (typeof appendSystem === 'function') appendSystem(T('msg.icon.flight.autopilot.cruise.planning', '[[icon:flight]] Autopilot Cruise — planning…'));
            d = await (await fetch('hive.php?action=plan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ goal, planner_model: '' }) })).json();   // '' = use the server's planner default (qwen2.5:14b)
        }
        if (hiveGated(d)) return false;       // server refused (e.g. beta lapsed) → Manual
        if (!d || !d.ok) return false;
        if (Array.isArray(d.steps) && typeof appendSystem === 'function') appendSystem(T('msg.icon.flight.plan.count.stepcount2.escalated', '[[icon:flight]] Plan ({count} step{count2}){escalated}:\n{map}', {count: d.count, count2: (d.count > 1 ? 's' : ''), escalated: (d.escalated ? ' — re-planned with ' + d.planner_used : ''), map: d.steps.map((s, i) => '  ' + (i + 1) + '. ' + (s.need ? '[' + s.need + '] ' : '') + s.action).join('\n')}));
        if (typeof hiveBarStatus === 'function') hiveBarStatus();   // surface the new chain in the sidebar
        // C7: read-before-run. Cancelling leaves the chain in Task Chains (status
        // 'building'), so nothing is lost — it can be run or edited from the panel.
        if (hiveGateEnabled() && Array.isArray(d.steps) && d.steps.length) {
            const approved = await hiveApprovalCard(d.steps, d.chain_id);
            if (!approved) {
                if (typeof appendSystem === 'function') appendSystem(T('msg.icon.flight.cruise.cancelled.the.plan.is.wai', '[[icon:flight]] Cruise cancelled — the plan is waiting in Task Chains (Hive → Chains).'));
                return true;   // handled: do NOT fall through to manual dispatch
            }
        }
        await hiveChainRun(d.chain_id);
        const rr = await (await fetch('hive.php?action=chain_result&id=' + d.chain_id)).json();
        if (rr && rr.ok && rr.output) {
            if (typeof appendMsg === 'function') appendMsg('cockpit', '[AUTOPILOT]', 'ollama', rr.output, new Date(), '');
            else if (typeof appendSystem === 'function') appendSystem(rr.output);
        }
        return true;
    } catch (e) { if (typeof appendSystem === 'function') appendSystem(T('msg.cruise.error.message', 'Cruise error: {message}', {message: e.message})); return false; }
}
// Read-before-run for the PLAN path.
// The planner is a small local model, so a plan can be structurally valid yet
// semantically wrong (observed: "edit the file" -> "check the live site" with no
// deploy step between them). So the plan is shown and waits for Run.
//
// Phase 4 rewords the control rather than reversing what it does. It used to read
// "Approve plans", where ticking a box meant "stop and ask me" — a checkbox whose
// checked state means MORE friction reads backwards. It is now "Run immediately
// after planning", where ticking means what it says. Reviewing stays the default:
// pressing PLAN says which text to plan, not that the plan is right.
//
// STORAGE IS UNCHANGED. cockpit_cruise_gate still stores the gate ('off' = no
// review), and hiveGateEnabled() is still the single source of truth; only the
// checkbox is inverted, at the UI layer. Anyone who had already turned the gate
// off keeps that preference with no migration.
function hiveGateEnabled() {
    try { return localStorage.getItem('cockpit_cruise_gate') !== 'off'; } catch (e) { return true; }
}
function hiveSetGate(on) {
    try { localStorage.setItem('cockpit_cruise_gate', on ? 'on' : 'off'); } catch (e) {}
}
// UI-facing inverse of the above: the checkbox asks to SKIP the review.
function hiveSetRunNow(on) {
    hiveSetGate(!on);
    if (typeof appendSystem === 'function') {
        appendSystem(on ? T('msg.span.class.material.symbols.rounded.ico.flig', '<span class="material-symbols-rounded ico">flight</span> Plans will now run immediately — you will not be shown the steps first.') : T('msg.span.class.material.symbols.rounded.ico.flig.839a', '<span class="material-symbols-rounded ico">flight</span> Plans will be shown for review before they run.'));
    }
}
// Renders the plan with Run / Cancel and resolves true only on an explicit Run.
function hiveApprovalCard(steps, chainId) {
    return new Promise(function (resolve) {
        const box = (typeof consoleBox !== 'undefined' && consoleBox) || document.getElementById('console');
        if (!box) { resolve(true); return; }                 // no UI to ask in — don't block the task
        const div = document.createElement('div');
        div.className = 'msg msg-system';
        const rows = steps.map(function (s, i) {
            return '<div style="display:flex;gap:6px;padding:2px 0;">' +
                   '<span style="color:var(--text-muted);min-width:14px;">' + (i + 1) + '.</span>' +
                   (s.need ? '<span style="color:var(--accent-amber,#e6b43c);min-width:74px;">[' + escHtml(s.need) + ']</span>' : '') +
                   '<span>' + escHtml(s.action) + '</span></div>';
        }).join('');
        div.innerHTML =
            '<div class="msg-header"><span class="msg-tag tag-system">Cruise — approve plan</span>' +
            '<span class="msg-meta">' + formatTime(new Date()) + '</span></div>' +
            '<div class="msg-body" style="color:var(--text-primary);">' +
              '<div style="margin-bottom:6px;color:var(--text-muted);font-size:11px;">' +
                steps.length + ' step' + (steps.length > 1 ? 's' : '') + ' — read them, then Run. ' +
                'Cancelling keeps the plan in Task Chains so you can run or edit it there.</div>' +
              rows +
              '<div style="display:flex;gap:6px;margin-top:8px;">' +
                '<button class="action-btn" data-gate="run" style="padding:3px 12px;">▶ Run</button>' +
                '<button class="action-btn" data-gate="cancel" style="padding:3px 12px;">Cancel</button>' +
                '<label style="display:inline-flex;align-items:center;gap:4px;font-size:10px;color:var(--text-muted);cursor:pointer;margin-left:auto;">' +
                  '<input type="checkbox" data-gate="never" title="Stop showing plans before they run. Reversible in Hive → Run immediately after planning."> run future plans without asking</label>' +
              '</div>' +
            '</div>';
        box.appendChild(div);
        box.scrollTop = box.scrollHeight;
        let settled = false;
        div.addEventListener('click', function (ev) {
            const act = ev.target && ev.target.getAttribute && ev.target.getAttribute('data-gate');
            if (!act || settled) return;
            // Checkbox only — same setting as the header toggle, said the other way round.
            if (act === 'never') { hiveSetRunNow(ev.target.checked); return; }
            settled = true;
            const btns = div.querySelectorAll('button[data-gate]');
            for (let i = 0; i < btns.length; i++) btns[i].disabled = true;
            div.querySelector('.msg-tag').textContent =
                act === 'run' ? 'Cruise — approved' : 'Cruise — cancelled';
            resolve(act === 'run');
        });
    });
}

// ── Hive sidebar + PLAN button (Phase 1) ────────────────────────────────────
// Take the text already in the main prompt box and hand it to the planner, so
// the user never types a goal twice. EXECUTE and PLAN sit side by side: the
// choice is made visibly, per prompt, instead of via a hidden mode toggle.
async function hivePlanFromPrompt() {
    const el = document.getElementById('prompt-in');
    const goal = (el ? el.value : '').trim();
    if (!goal) {
        if (typeof appendSystem === 'function') appendSystem(T('msg.icon.flight.type.a.goal.in.the.prompt.box.fi', '[[icon:flight]] Type a goal in the prompt box first, then press PLAN.'));
        if (el) el.focus();
        return;
    }
    if (goal.startsWith('/')) {          // slash commands are dispatch, never plans
        if (typeof appendSystem === 'function') appendSystem(T('msg.icon.flight.slash.commands.run.with.execute', '[[icon:flight]] Slash commands run with EXECUTE, not PLAN.'));
        return;
    }
    if (typeof capCan === 'function' && !capCan('cruise')) {
        if (typeof appendSystem === 'function') appendSystem(T('msg.icon.lock.autopilot.cruise.is.a.basic.featur', '[[icon:lock]] Autopilot Cruise needs the Plus plan or higher — see your account for the plans.'));
        return;
    }
    if (el) el.value = '';               // mirror EXECUTE: the box empties on send
    if (typeof appendMsg === 'function') appendMsg('dario', _userLabel(), 'dario', goal, new Date(), '');
    await hivePlanAndRun(goal);
    hiveBarStatus();
}

// Sidebar status line. Cheap: reuses the ungated 'avail' probe plus the chain
// count, so it works for Basic (Cruise) without requiring Pro (AutoCognition).
async function hiveBarStatus() {
    const st = document.getElementById('hivebar-status');
    const ag = document.getElementById('hivebar-agents');
    const ch = document.getElementById('hivebar-chains');
    if (!st) return;
    const dim = 'color:var(--text-muted);';
    // AutoCognition (roster/chains) is Pro. Basic still gets Cruise, so degrade to a
    // one-line state rather than showing empty panes or firing gated endpoints.
    if (typeof capCan === 'function' && !capCan('cognition')) {
        hiveBarStatusPlain(st);
        st.textContent = (typeof capCan === 'function' && capCan('cruise')) ? '● Cruise' : '○';
        const msg = (typeof capCan === 'function' && capCan('cruise'))
            ? 'AutoCognition (roster, bus, broker) is a Pro feature.'
            : ((typeof _saasAcct !== 'undefined' && _saasAcct && _saasAcct.signed_in) ? 'The Hive needs the Plus plan or higher (AutoCognition: Pro).' : 'Sign in to use the Hive.');
        if (ag) ag.innerHTML = '<span style="' + dim + '">' + msg + '</span>';
        if (ch) ch.innerHTML = '<span style="' + dim + '">—</span>';
        return;
    }
    try {
        const [ps, cs] = await Promise.all([
            fetch('hive.php?action=ps').then(r => r.json()).catch(() => null),
            fetch('hive.php?action=chains').then(r => r.json()).catch(() => null)
        ]);
        // Both probes swallow their own errors (.catch(() => null)), so a dead backend
        // never throws — without this it rendered '● 0·0', i.e. a healthy idle bus.
        if (!ps && !cs) throw new Error('hive endpoints unreachable');
        let live = 0, open = 0, stalled = 0;
        if (ag) {
            const list = (ps && ps.ok && Array.isArray(ps.agents)) ? ps.agents : [];
            live = list.filter(a => a.state === 'live').length;
            ag.innerHTML = list.length ? list.slice(0, 8).map(a => {
                const dot = a.state === 'live' ? 'var(--accent-green,#3cba7c)'
                          : a.state === 'stale' ? 'var(--warn,#e6b43c)' : 'var(--text-muted)';
                const caps = (a.caps || []).slice(0, 2).join(',');
                return '<div style="display:flex;gap:4px;align-items:baseline;">'
                     + '<span style="color:' + dot + ';">●</span>'
                     + '<span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">'
                     + escHtml(a.slug) + (a.instance ? '/' + escHtml(a.instance) : '') + '</span>'
                     + '<span style="' + dim + 'font-size:10px;">' + escHtml(caps) + '</span></div>';
            }).join('') : '<span style="' + dim + '">no agents registered</span>';
        }
        if (ch) {
            const list = (cs && cs.ok && Array.isArray(cs.chains)) ? cs.chains : [];
            open = list.filter(c => c.status !== 'done').length;
            stalled = list.filter(c => c.interrupted).length;   // carried over from the retired FAB badge
            ch.innerHTML = list.length ? list.slice(0, 6).map(c => {
                const goal = (c.goal || c.id || '').toString();
                const col = c.interrupted ? 'var(--warn,#e6b43c)'
                          : c.status === 'done' ? 'var(--text-muted)' : 'var(--accent-green,#3cba7c)';
                return '<div style="display:flex;gap:4px;align-items:baseline;cursor:pointer;" onclick="hiveBarOpen(\'chains\')">'
                     + '<span style="color:' + col + ';">▸</span>'
                     + '<span style="flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + escHtml(goal.slice(0, 34)) + '</span>'
                     + '<span style="' + dim + 'font-size:10px;">' + c.done + '/' + c.total + '</span></div>';
            }).join('') : '<span style="' + dim + '">no chains yet</span>';
        }
        // A stalled chain is the one thing worth interrupting the user for, so it
        // takes over the dot. This is the signal the  FAB's amber badge used to
        // carry; the FAB is gone, the warning is not.
        st.innerHTML = (stalled ? '<span class="material-symbols-rounded ico">warning</span> ' : '● ') + live + '·' + open;
        st.style.color = stalled ? 'var(--warn,#e6b43c)' : 'var(--text-muted)';
        st.style.fontWeight = stalled ? '700' : '400';
        st.title = live + ' live agent(s), ' + open + ' open chain(s)'
                 + (stalled ? ' — ' + stalled + ' INTERRUPTED, click Chains to resume' : '');
    } catch (e) {
        hiveBarStatusPlain(st);
        st.textContent = '○';
        if (ag) ag.innerHTML = '<span style="' + dim + '">offline</span>';
    }
}
// Clear any warning styling left over from a previous poll — otherwise a chain
// that stalled and was then resumed (or a probe that later fails) leaves the dot
// stuck amber, warning about nothing.
function hiveBarStatusPlain(st) {
    st.style.color = 'var(--text-muted)';
    st.style.fontWeight = '400';
    st.title = '';   // drop the previous poll's counts; they no longer describe anything
}


// The sidebar buttons open the modal scoped to their own view (Phase 2).
// hiveOpen() with no argument still yields the full, unscoped modal.
function hiveBarOpen(view) {
    if (typeof hiveOpen === 'function') hiveOpen(view);
}
function hiveBarInit() {
    // Runs at load AND again once the account is known (saasAccountLoad), so the buttons follow the real entitlement both ways.
    const plan = document.getElementById('btn-plan');
    if (plan && typeof capCan === 'function') {
        if (plan.dataset.ckTitle === undefined) plan.dataset.ckTitle = plan.title;
        const ok = capCan('cruise');
        plan.disabled = !ok;
        plan.style.opacity = ok ? '' : '0.45';
        plan.title = ok ? plan.dataset.ckTitle : T('msg.autopilot.cruise.is.a.basic.feature', 'Autopilot Cruise needs the Plus plan or higher');
    }
    // Reflect entitlement in the  Durable button the same way, rather than
    // letting the click be the first sign the tier does not cover it.
    const dur = document.getElementById('ma-durable');
    if (dur && typeof capCan === 'function') {
        if (dur.dataset.ckTitle === undefined) dur.dataset.ckTitle = dur.title;
        const ok = capCan('cruise') || capCan('cognition');
        dur.disabled = !ok;
        dur.style.opacity = ok ? '' : '0.45';
        dur.title = ok ? dur.dataset.ckTitle : T('msg.durable.chains.are.an.autopilot.cruise.basic', 'Durable chains need the Plus plan or higher (Autopilot Cruise)');
    }
    hiveBarStatus();
}
// C3: plan a goal into a draft chain (Proposal) that appears in Task Chains.
// Phase 3: the modal's own goal box is gone. There is ONE place to type a goal —
// the main prompt box. This drafts it into a reviewable Proposal without running
// it; the sidebar's  PLAN plans AND runs. Same source text either way.
async function hivePlan() {
    const note = document.getElementById('hive-plan-note');
    const el = document.getElementById('prompt-in');
    const goal = (el ? el.value : '').trim();
    if (!goal) { if (note) note.textContent = T('msg.type.a.goal.in.the.prompt.box.first', 'type a goal in the prompt box first'); return; }
    if (note) note.textContent = T('msg.planning', 'planning…');
    try {
        const _lm = (typeof _localModelFor === 'function') ? _localModelFor('ollama') : null;
        const model = (_lm && _lm.model) || 'qwen2.5:7b';
        const d = await (await fetch('hive.php?action=plan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ goal, planner_model: '' }) })).json();   // '' = use the server's planner default (qwen2.5:14b)
        if (d && d.ok) {
            if (note) note.textContent = 'drafted ' + d.count + ' steps — review below, then ▶ Run';
            if (el) el.value = '';
            _hiveChainOpen[d.chain_id] = true;   // auto-expand the proposal
            hiveRefresh();
        } else if (note) note.textContent = 'plan failed: ' + (d.error || '?');
    } catch (e) { if (note) note.textContent = 'error: ' + e.message; }
}
// C2: resolve an agent slug → {runner, model} for a chain step. Local agents carry
// their backend in _slotBackends; the Ollama card uses its own picker; cloud/CLI
// agents keep their slug as the runner (chain routing handles non-local).
function _runnerModelFor(agent) {
    const bk = (window._slotBackends || {})[agent];
    if (bk && bk.runner) return { runner: bk.runner, model: bk.model || '' };
    if (agent === 'ollama') { const s = document.getElementById('ollama-select'); return { runner: 'ollama', model: (s ? s.value : '') || '' }; }
    const m = document.getElementById(agent + '-model');
    return { runner: agent, model: m ? m.value : '' };
}
// C2: build + run a durable chain from a Pipeline (sequential) or Broadcast
// (parallel) spec — the modes become thin builders on the AutoCognition engine.
async function hiveChainFromMode(mode, prompt, agents) {
    const pattern = mode === 'pipeline' ? 'sequential' : 'parallel';
    const steps = (agents || []).map((a, i) => {
        const rm = _runnerModelFor(a);
        return { runner: rm.runner, model: rm.model, prompt: (pattern === 'sequential' && i > 0) ? ('%PREV%\n\n' + prompt) : prompt };
    });
    const combo = { id: 'mode_' + mode, name: (mode === 'pipeline' ? 'Pipeline' : 'Broadcast') + ': ' + (agents || []).join(mode === 'pipeline' ? ' → ' : ' + '), pattern, steps };
    try {
        const d = await (await fetch('hive.php?action=combo_to_chain', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ combo }) })).json();
        // hive.php answers every action with available:false (and nothing else)
        // when the bus directory is absent. Say so — the old silent `return false`
        // looked identical to "the button did nothing".
        if (d && d.available === false) {
            if (typeof appendSystem === 'function') appendSystem(T('msg.the.hive.bus.is.not.available.on.this.instal', 'The Hive bus is not available on this install — the run stays in-page.'));
            return false;
        }
        if (hiveGated(d)) return false;   // sequential needs Basic, parallel needs Pro — server decides
        if (d && d.ok) {
            if (typeof appendSystem === 'function') appendSystem(T('msg.icon.link.name.durable.chain.steps.steps.run', '[[icon:link]] {name} → durable chain ({steps} steps). Running through AutoCognition…', {name: combo.name, steps: d.steps}));
            if (typeof hiveBarStatus === 'function') hiveBarStatus();   // surface the new chain in the sidebar
            await hiveChainRun(d.chain_id);
            return true;
        }
        if (typeof appendSystem === 'function') appendSystem(T('msg.durable.chain.failed.d', 'Durable chain failed: {d}', {d: ((d && d.error) || 'unknown')}));
    } catch (e) { if (typeof appendSystem === 'function') appendSystem(T('msg.durable.chain.error.message', 'Durable chain error: {message}', {message: e.message})); }
    return false;
}

// The  Durable button in the mode strip. Takes what is on screen RIGHT NOW —
// the prompt text and the agents you ticked, with each one's runner+model
// resolved live by _runnerModelFor — and builds a checkpointed chain from it.
//
// This is the gap the other two chain paths leave: PLAN hands step selection to
// the planner model, and a Power Combo runs an author's fixed recipe. Neither
// can make YOUR ad-hoc selection resumable, which is what matters for a long
// pipeline that dies halfway.
async function hiveChainFromModeNow() {
    const el = document.getElementById('prompt-in');
    const text = (el ? el.value : '').trim();
    if (maMode !== 'pipeline' && maMode !== 'broadcast') {
        appendError(T('msg.durable.chains.run.from.pipeline.or.broadcas', 'Durable chains run from Pipeline or Broadcast mode.'));
        return;
    }
    if (!text) { appendError(T('msg.type.a.prompt.first.the.durable.chain.runs.t', 'Type a prompt first — the durable chain runs the text in the prompt box.')); return; }
    const agents = maGetSelectedAgents();
    const min = maMode === 'pipeline' ? 2 : 1;
    if (agents.length < min) {
        appendError(T('msg.mamode.needs.at.least.min.agentmin2.selected', '{mamode} needs at least {min} agent{min2} selected.', {mamode: (maMode === 'pipeline' ? 'Pipeline' : 'Broadcast'), min: min, min2: (min > 1 ? 's' : '')}));
        return;
    }
    const ok = await hiveChainFromMode(maMode, text, agents);
    // Clear only on success: a refusal leaves the prompt where the user can
    // retry it in-page with Enter, instead of silently eating what they typed.
    if (ok && el) el.value = '';
}
// C1: promote a Power Combo to a durable, resumable HIVE chain (Autopilot Cruise).
async function hiveComboToChain(comboId) {
    try {
        const d = await (await fetch('hive.php?action=combo_to_chain', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ combo_id: comboId, backend: (typeof combosActiveBackend === 'function' ? combosActiveBackend() : null) }) })).json();
        if (hiveGated(d)) return;   // parallel/judge combos need Pro; sequential need Basic
        if (d && d.ok) {
            if (typeof appendSystem === 'function') appendSystem(T('msg.icon.link.durable.chain.created.from.combo.s', '[[icon:link]] Durable chain created from combo ({steps} steps, {pattern}). Open Hive → Chains in the sidebar.', {steps: d.steps, pattern: d.pattern}));
            if (typeof hiveBarStatus === 'function') hiveBarStatus();   // surface the new chain in the sidebar
            if (document.getElementById('hive-modal') && document.getElementById('hive-modal').style.display === 'flex') hiveRefresh();
        } else if (typeof appendSystem === 'function') appendSystem(T('msg.chain.create.failed.error', 'Chain create failed: {error}', {error: (d.error || '?')}));
    } catch (e) { if (typeof appendSystem === 'function') appendSystem(T('msg.chain.create.error.message', 'Chain create error: {message}', {message: e.message})); }
}
async function hiveRefresh() {
    try {
        const [ps, lg, bs, pd, ch] = await Promise.all([
            fetch('hive.php?action=ps').then(r => r.json()),
            fetch('hive.php?action=log&n=30').then(r => r.json()),
            fetch('hive.php?action=broker_status').then(r => r.json()),
            fetch('hive.php?action=pending').then(r => r.json()),
            fetch('hive.php?action=chains').then(r => r.json()),
        ]);
        // Broker status + start hint
        const bstate = document.getElementById('hive-broker-state');
        const bhint = document.getElementById('hive-broker-hint');
        if (bstate && bs && bs.ok) {
            _hiveBrokerCmd = bs.start_cmd || '';
            if (bs.running) { bstate.textContent = '● running (pid ' + bs.pid + ')'; bstate.style.color = 'var(--accent-green,#3cba7c)'; if (bhint) bhint.style.display = 'none'; }
            else { bstate.textContent = T('msg.stopped', '○ stopped'); bstate.style.color = 'var(--text-muted)'; if (bhint) { bhint.style.display = ''; const c = document.getElementById('hive-broker-cmd'); if (c) c.textContent = _hiveBrokerCmd; } }
        }
        // Pending proposals (approvals queue)
        const pend = document.getElementById('hive-pending');
        const pcount = document.getElementById('hive-pending-count');
        if (pend && pd && pd.ok) {
            const items = pd.pending || [];
            if (pcount) pcount.textContent = items.length ? '(' + items.length + ')' : '';
            pend.innerHTML = items.length ? items.map(p =>
                '<div style="display:flex;align-items:center;gap:8px;border:1px solid var(--border-dim);border-radius:4px;padding:5px 8px;">' +
                '<span style="color:var(--accent-amber,#e6b43c);font-weight:600;">' + escHtml(p.type) + '</span>' +
                '<span style="color:var(--text-dim);">' + escHtml(p.from) + ' → ' + escHtml(p.to) + '</span>' +
                (p.cmd ? '<code style="color:var(--accent-cyan);font-family:var(--font-mono);font-size:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:180px;">' + escHtml(p.cmd) + '</code>' : '<span style="color:var(--text-muted);">' + escHtml(p.subject) + '</span>') +
                '<button class="action-btn" onclick="hiveDecline(\'' + escAttr(p.to) + '\',\'' + escAttr(p.id) + '\')" style="margin-left:auto;padding:2px 8px;font-size:10px;" title="Remove this proposal (do not run)">Decline</button>' +
                '</div>').join('') : '<div style="color:var(--text-muted);">none</div>';
        }
        // Task chains (H6) — durable resumable boards
        const chains = document.getElementById('hive-chains');
        const ccount = document.getElementById('hive-chains-count');
        if (chains && ch && ch.ok) {
            const items = ch.chains || [];
            if (ccount) ccount.textContent = items.length ? '(' + items.length + ')' : '';
            const cdot = c => c.status === 'done' ? 'var(--accent-green,#3cba7c)' : (c.status === 'failed' ? 'var(--claude,#d44)' : (c.interrupted ? 'var(--accent-amber,#e6b43c)' : 'var(--accent-cyan)'));
            chains.innerHTML = items.length ? items.map(c => {
                const needResume = c.interrupted || c.status === 'failed';
                return '<div style="border:1px solid var(--border-dim);border-radius:4px;padding:5px 8px;">' +
                    '<div style="display:flex;align-items:center;gap:8px;cursor:pointer;" onclick="hiveChainToggle(\'' + escAttr(c.id) + '\')">' +
                    '<span style="width:8px;height:8px;border-radius:50%;background:' + cdot(c) + ';flex:0 0 auto;"></span>' +
                    '<span style="color:var(--text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + escHtml(c.goal || '(no goal)') + '</span>' +
                    '<span style="color:var(--text-dim);font-size:10px;">' + c.done + '/' + c.total + '</span>' +
                    '<span style="margin-left:auto;color:' + cdot(c) + ';font-size:10px;">' + escHtml(c.status) + (c.interrupted ? ' · interrupted' : '') + '</span>' +
                    ((c.status === 'building' || c.status === 'running') && c.done < c.total && !c.interrupted ? '<button class="action-btn" onclick="event.stopPropagation();hiveChainRun(\'' + escAttr(c.id) + '\')" style="padding:2px 8px;font-size:10px;" title="Run the chain through the durable engine (Autopilot Cruise)">▶ Run</button>' : '') +
                    (needResume ? '<button class="action-btn" onclick="event.stopPropagation();hiveChainResume(\'' + escAttr(c.id) + '\')" style="padding:2px 8px;font-size:10px;" title="Reset the interrupted step and continue">Resume</button>' : '') +
                    '</div>' +
                    '<div id="hive-chain-steps-' + escAttr(c.id) + '" style="display:' + (_hiveChainOpen[c.id] ? '' : 'none') + ';margin-top:4px;"></div>' +
                    '</div>';
            }).join('') : '<div style="color:var(--text-muted);">none</div>';
            // re-hydrate any open chain's steps (render rebuilt the empty containers)
            items.forEach(c => { if (_hiveChainOpen[c.id]) hiveChainLoadSteps(c.id); });
        }
        // global auto-resume default toggle
        try {
            const cfg = await (await fetch('hive.php?action=config')).json();
            const arb = document.getElementById('hive-ar-default');
            if (arb && cfg && cfg.ok) arb.checked = (cfg.auto_resume_default !== 'off');
        } catch (e) { /* ignore */ }
        const roster = document.getElementById('hive-roster');
        if (roster && ps && ps.ok) {
            const dot = s => ({ live: 'var(--accent-green,#3cba7c)', stale: 'var(--accent-amber,#e6b43c)', down: 'var(--text-muted)' }[s] || 'var(--text-muted)');
            roster.innerHTML = (ps.agents || []).map(a =>
                '<div style="display:flex;align-items:center;gap:8px;">' +
                '<span style="width:8px;height:8px;border-radius:50%;background:' + dot(a.state) + ';flex:0 0 auto;" title="' + escAttr(a.state) + '"></span>' +
                '<b style="color:var(--text-primary);">' + escHtml(a.slug) + '</b>' +
                '<span style="color:var(--text-muted);font-size:10px;">' + escHtml(a.instance) + ' · ' + escHtml(a.kind) + ' · ' + a.age + 's</span>' +
                '<span style="color:var(--text-dim);font-size:10px;margin-left:auto;">' + escHtml((a.caps || []).join(', ')) + '</span>' +
                '</div>').join('') || '<div style="color:var(--text-muted);">no agents registered</div>';
        }
        const log = document.getElementById('hive-log');
        if (log && lg && lg.ok) {
            log.innerHTML = (lg.events || []).slice().reverse().map(e => escHtml(e)).join('<br>') || '(quiet)';
        }
    } catch (e) { /* transient */ }
}
async function hiveSend() {
    const to = document.getElementById('hive-to').value.trim();
    const type = document.getElementById('hive-type').value;
    const note = document.getElementById('hive-send-note');
    if (!to) { if (note) note.textContent = T('msg.need.a.recipient.slug', 'need a recipient slug'); return; }
    const payload = { to, type,
        subject: document.getElementById('hive-subject').value,
        body: document.getElementById('hive-body').value };
    if (type === 'call') payload.cmd = document.getElementById('hive-cmd').value;
    try {
        const d = await (await fetch('hive.php?action=send', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })).json();
        if (note) note.textContent = d.ok ? ('sent → ' + to + (['call', 'wake'].includes(type) ? ' (proposal; broker asks consent)' : '')) : ('error: ' + (d.error || '?'));
        if (d.ok) { document.getElementById('hive-subject').value = ''; document.getElementById('hive-body').value = ''; document.getElementById('hive-cmd').value = ''; hiveRefresh(); }
    } catch (e) { if (note) note.textContent = 'send failed: ' + e.message; }
}
document.addEventListener('DOMContentLoaded', () => { hiveAvailProbe(); hiveCruiseRetire(); });

// =============================================================================

// =============================================================================
// A2A (agent-to-agent) — the switch for the protocol server in a2a.php.
//
// The server implements the A2A REST subset (agent card, message/send, task
// state, cancel) but had no UI and required a Cockpit session, so no peer could
// ever reach it. This dialog is the missing half: off by default; turning it on
// mints a token, and only callers from the listed addresses may use it
// (2026-09-22).
// =============================================================================
async function a2aOpen() {
    let d = {};
    try { d = await (await fetch('a2a.php?action=config')).json(); } catch (e) { d = { ok:false, error:e.message }; }
    if (!d.ok) { appendSystem(T('msg.a2a.could.not.read.the.settings.error', 'A2A: could not read the settings ({error})', {error: (d.error || '?')})); return; }
    let ov = document.getElementById('a2a-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'a2a-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const tok = d.token || '';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(600px,94vw);max-height:88vh;overflow:auto;padding:16px 20px;">' +
          '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
            '<span class="material-symbols-rounded" style="font-size:18px;color:var(--gemini);">hub</span>' +
            '<h2 style="margin:0;font-size:14px;flex:1;">Agent-to-Agent (A2A)</h2>' +
            '<span id="a2a-x" style="cursor:pointer;color:var(--text-dim);font-size:18px;">×</span>' +
          '</div>' +
          '<p style="font-size:11px;color:var(--text-muted);line-height:1.5;margin:0 0 10px;">' +
            'Lets another agent — or another Cockpit — send this one work over the A2A protocol (agent card, message/send, task state, cancel). ' +
            'It answers as your active agent and writes into your projects, so it stays <b>off</b> until you turn it on, needs the token below, ' +
            'and only accepts callers from the addresses you list.</p>' +
          '<label style="display:flex;align-items:center;gap:8px;font-size:12px;margin-bottom:10px;">' +
            '<input type="checkbox" id="a2a-enabled"' + (d.enabled ? ' checked' : '') + '> Accept A2A calls on this machine</label>' +
          '<div style="font-size:11px;color:var(--text-muted);margin-bottom:3px;">Endpoint</div>' +
          '<code style="display:block;font-family:var(--font-mono);font-size:10.5px;background:var(--bg-darker);padding:5px 8px;border-radius:3px;word-break:break-all;margin-bottom:10px;">' + escHtml(d.url || '') + '</code>' +
          '<div style="font-size:11px;color:var(--text-muted);margin-bottom:3px;">Token — sent by the caller as <code>X-Cockpit-A2A-Token</code></div>' +
          '<div style="display:flex;gap:6px;align-items:center;margin-bottom:10px;">' +
            '<code id="a2a-token" style="flex:1;font-family:var(--font-mono);font-size:10.5px;background:var(--bg-darker);padding:5px 8px;border-radius:3px;word-break:break-all;">' + escHtml(tok ? tok : '(none yet — turning A2A on creates one)') + '</code>' +
            '<button class="rp-action-btn" id="a2a-copy">Copy</button>' +
            '<button class="rp-action-btn" id="a2a-new">New token</button>' +
          '</div>' +
          '<div style="font-size:11px;color:var(--text-muted);margin-bottom:3px;">Allowed callers — one per line: an IP, a CIDR range, or * for any</div>' +
          '<textarea id="a2a-allow" rows="3" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:3px;font-family:var(--font-mono);font-size:11px;padding:5px 8px;">' + escHtml((d.allow || []).join('\n')) + '</textarea>' +
          '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px;">' +
            '<button class="rp-action-btn" id="a2a-cancel">Cancel</button>' +
            '<button class="action-btn" id="a2a-save" style="background:var(--accent-blue);color:#fff;">Save</button>' +
          '</div>' +
        '</div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    ov.querySelector('#a2a-x').onclick = close;
    ov.querySelector('#a2a-cancel').onclick = close;
    ov.querySelector('#a2a-copy').onclick = () => { navigator.clipboard.writeText(document.getElementById('a2a-token').textContent.trim()); appendSystem(T('msg.a2a.token.copied', 'A2A token copied.')); };
    ov.querySelector('#a2a-new').onclick  = () => a2aSave(true);
    ov.querySelector('#a2a-save').onclick = () => a2aSave(false);
}
async function a2aSave(regenerate) {
    const enabled = document.getElementById('a2a-enabled').checked;
    const allow   = document.getElementById('a2a-allow').value.split('\n').map(s => s.trim()).filter(Boolean);
    try {
        const d = await (await fetch('a2a.php?action=set_config', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ enabled, allow, regenerate: !!regenerate }) })).json();
        if (!d.ok) { appendSystem(T('msg.a2a.save.failed', 'A2A: save failed')); return; }
        appendSystem(d.enabled ? T('msg.a2a.is.on.peers.with.the.token.may.send.this', 'A2A is ON — peers with the token may send this Cockpit work.') : T('msg.a2a.is.off', 'A2A is off.'));
        document.getElementById('a2a-overlay')?.remove();
        if (regenerate) a2aOpen();
    } catch (e) { appendSystem(T('msg.a2a.save.failed.message', 'A2A: save failed ({message})', {message: e.message})); }
}
