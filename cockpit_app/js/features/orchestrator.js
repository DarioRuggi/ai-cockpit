// ORCHESTRATOR + PLANNER — frontend
//
// Two systems unified under "Plan" mode:
//
//   PLANNER   — voting flow. Goal → fanout to N agents → each emits JSON plan
//               → synthesizer merges. Plan lives in <project>/plans/.
//
//   ORCHESTRATOR — execution loop. Runs each step on its assigned agent using
//               bridge.php's submit/poll machinery. Honors auto_run_mode for
//               approval gates between steps.
//
// Plans panel (right sidebar → list_alt icon) shows:
//   - List of plans for current chat
//   - Selecting one expands to full step view with run/edit/skip controls
// =============================================================================

let _activePlanId = null;     // currently expanded plan in the panel
let _activePlan   = null;     // cached full plan object

// ─── Public entry point: called when EXECUTE is hit in Plan mode ────────────
const WORKFLOW_PATTERNS = {
    chain:       'Use Prompt Chaining pattern: sequential LLM calls where each step builds on the previous output. Break the goal into a linear pipeline of steps.',
    parallel:    'Use Parallelization pattern: fork the goal into independent subtasks that run concurrently, then aggregate results.',
    router:      'Use Router pattern: classify the goal and route to the optimal specialized workflow branch.',
    orchestrator:'Use Orchestrator-Worker pattern: central orchestrator decomposes the goal and delegates to specialized worker agents.',
    evaluator:   'Use Evaluator-Optimizer pattern: generate candidate outputs, evaluate against criteria, loop with feedback until quality threshold is met.',
    autonomous:  'Use Autonomous Workflow pattern: agent acts, observes environment, decides next action, repeats until goal is complete.',
    reflection:  'Use Reflection pattern: generate output, self-evaluate for errors, correct before finalizing. Build self-correction into each step.',
    rewoo:       'Use ReWoo pattern: plan ALL steps upfront without waiting for results, then execute concurrently. Minimize sequential dependencies.',
    'plan-execute': 'Use Plan & Execute pattern: generate full execution plan, register in task queue, execute sequentially with milestone tracking and dynamic replanning.',
};

async function orchestratorBegin(goal) {
    if (!goal || goal.trim().length < 3) {
        appendError(T('msg.plan.mode.needs.a.real.goal.at.least.a.few.w', 'Plan mode needs a real goal (at least a few words).'));
        return;
    }

    // Resolve workflow pattern: #prefix in goal overrides dropdown
    let workflow = 'auto';
    const wfSelect = document.getElementById('ma-workflow-select');
    if (wfSelect) workflow = wfSelect.value;
    const prefixMatch = goal.match(/^#(chain|parallel|router|orchestrator|evaluator|autonomous|reflection|rewoo|plan-execute)\s+/i);
    if (prefixMatch) {
        workflow = prefixMatch[1].toLowerCase();
        goal = goal.slice(prefixMatch[0].length);
        if (wfSelect) wfSelect.value = workflow;
    }
    const wfInstruction = (workflow !== 'auto' && WORKFLOW_PATTERNS[workflow])
        ? '\n\nWORKFLOW PATTERN INSTRUCTION: ' + WORKFLOW_PATTERNS[workflow]
        : '';

    appendSystem(T('msg.plan.modeworkflow.voting.agents.are.drafting', '▶ Plan mode{workflow} — Voting agents are drafting plans for: "{slice}{n}"', {workflow: (workflow !== 'auto' ? ' [' + workflow + ']' : ''), slice: goal.slice(0, 100), n: (goal.length > 100 ? '…' : '')}));

    setLoading(true);
    try {
        const r = await fetch('orchestrator.php?action=create_plan', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                project: currentProject || 'default',
                chat:    currentChat   || 'default',
                goal: goal + wfInstruction,
                workflow,
                claude_model: sentClaudeModelGet(),
                gemini_model: sentGeminiModelGet(),
                ollama_model: sentOllamaModelGet(),
                agents: (typeof maGetSelectedAgents === 'function') ? maGetSelectedAgents() : [],
            })
        });
        const d = await r.json();
        if (!d.ok) {
            appendError(T('msg.plan.creation.failed.error', 'Plan creation failed: {error}', {error: (d.error||'unknown')}));
            return;
        }
        appendSystem(T('msg.plan.created.planid.voters.n.polling.outputs', 'Plan created ({planid}). Voters: {n}. Polling outputs…', {planid: d.plan_id, n: d.voters.join(', ')}));

        // Poll each voter token in parallel, collect raw outputs
        const voteOutputs = {};
        await Promise.all(d.voters.map(async (agent) => {
            const token = d.tokens[agent];
            if (!token) {
                voteOutputs[agent] = '';
                appendError(T('msg.touppercase.voter.never.started', '{touppercase} voter never started', {touppercase: agent.toUpperCase()}));
                return;
            }
            try {
                voteOutputs[agent] = await orchestratorPollToken(token, agent);
            } catch (e) {
                voteOutputs[agent] = '';
                appendError(T('msg.touppercase.voter.failed.message', '{touppercase} voter failed: {message}', {touppercase: agent.toUpperCase(), message: e.message}));
            }
        }));

        appendSystem(T('msg.all.votes.collected.synthesizing.merged.plan', 'All votes collected. Synthesizing merged plan…'));

        // Send votes back for synthesis
        const sr = await fetch('orchestrator.php?action=synthesize_plan', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                project: currentProject || 'default',
                plan_id: d.plan_id,
                votes:   voteOutputs,
            })
        });
        const sd = await sr.json();
        if (!sd.ok) {
            appendError(T('msg.synthesis.failed.error', 'Synthesis failed: {error}', {error: (sd.error||'unknown')}));
            return;
        }

        // Synthesizer may either be done immediately (single-voter mode or
        // fallback) or be running and need polling
        let finalPlan = sd.plan;
        if (sd.synth_token) {
            appendSystem(T('msg.synthesizer.synthagent.is.running', 'Synthesizer ({synthagent}) is running…', {synthagent: sd.synth_agent}));
            const synthOutput = await orchestratorPollToken(sd.synth_token, sd.synth_agent);
            const fr = await fetch('orchestrator.php?action=synthesize_finalize', {
                method: 'POST',
                headers: {'Content-Type':'application/json'},
                body: JSON.stringify({
                    project:      currentProject || 'default',
                    plan_id:      d.plan_id,
                    synth_output: synthOutput,
                })
            });
            const fd = await fr.json();
            if (!fd.ok) {
                appendError(T('msg.synthesis.finalize.failed.error', 'Synthesis finalize failed: {error}', {error: (fd.error||'unknown')}));
                return;
            }
            finalPlan = fd.plan;
        }

        appendSystem(T('msg.plan.ready.steps.steps.open.plans.tab.to.rev', 'Plan ready ({steps} steps). Open Plans tab to review and run.', {steps: (finalPlan.steps||[]).length}));
        cockpitNotify('Plan Ready', (finalPlan.steps||[]).length + ' steps — review and run.');
        plansRefresh();
        plansSelectPlan(finalPlan.id);

        // If auto_run_mode is 'auto', kick off execution immediately
        if (finalPlan.auto_run_mode === 'auto') {
            appendSystem(T('msg.auto.run.enabled.executing.plan.now', 'Auto-run enabled — executing plan now…'));
            await orchestratorRunPlan(finalPlan.id);
        }
    } catch (e) {
        appendError(T('msg.orchestrator.failed.message', 'Orchestrator failed: {message}', {message: e.message}));
    } finally {
        setLoading(false);
    }
}

// =============================================================================
// E2 — Summarize session. Gathers the visible chat, asks the active agent for a
// concise summary, shows it in an overlay, and offers to save it (append to the
// project's COCKPIT.md, or save as a snippet). Does not pollute the chat log.
// =============================================================================
async function summarizeSession() {
    // Gather message bodies from the console (skip system/error)
    const msgs = Array.from(document.querySelectorAll('#console-box .msg, .msg'))
        .filter(m => !m.classList.contains('msg-system') && !m.classList.contains('msg-error'));
    if (msgs.length === 0) { appendSystem(T('msg.nothing.to.summarize.yet', 'Nothing to summarize yet.')); return; }
    let transcript = '';
    msgs.forEach(m => {
        const tag = m.querySelector('.msg-tag');
        const body = m.querySelector('.msg-body');
        if (!body) return;
        const who = tag ? tag.textContent.replace(/[\[\]]/g,'') : '?';
        transcript += who + ': ' + (body.innerText || body.textContent || '').trim() + '\n\n';
    });
    // Cap transcript to keep the prompt reasonable
    if (transcript.length > 24000) transcript = transcript.slice(-24000);

    const agent = (typeof currentAgent === 'string' ? currentAgent : 'claude');
    if (agent === 'workers') { appendError(T('msg.switch.to.claude.gemini.ollama.to.summarize', 'Switch to Claude/Gemini/Ollama to summarize (Workers route differs).')); return; }

    const summaryPrompt =
        'Summarize the following work session concisely. Produce: (1) a one-line title, ' +
        '(2) 3-6 bullet points of what was done/decided, (3) any open items or next steps. ' +
        'Plain text, no preamble.\n\n--- SESSION ---\n' + transcript + '\n--- END ---';

    appendSystem(T('msg.summarizing.session.via.touppercase', 'Summarizing session via {touppercase}…', {touppercase: agent.toUpperCase()}));
    setLoading(true);
    let summary = '';
    try {
        // Submit to a throwaway chat slot so the summary doesn't land in history
        const sr = await fetch('bridge.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
                mode:'submit', agent: agent, prompt: summaryPrompt,
                model: (document.getElementById('ollama-select')?.value || ''),
                project: currentProject || 'default',
                chat: '_summary_scratch'
            })
        });
        const sd = await sr.json();
        if (!sd.ok || !sd.short) throw new Error(sd.error || 'submit failed');
        summary = await orchestratorPollToken(sd.short, agent);
    } catch(e) {
        setLoading(false);
        appendError(T('msg.summary.failed.message', 'Summary failed: {message}', {message: e.message}));
        return;
    }
    setLoading(false);
    summary = (summary || '').trim();
    if (!summary) { appendError(T('msg.empty.summary.returned', 'Empty summary returned.')); return; }
    _showSummaryDialog(summary);
}

function _showSummaryDialog(summary) {
    let ov = document.getElementById('summary-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'summary-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const proj = currentProject || '';
    const canCockpit = proj && proj !== '_standalone';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(680px,94vw);max-height:90vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">summarize</span> Session summary</h2>' +
        '<span class="rp-action-btn" id="summary-close" style="cursor:pointer;">×</span></div>' +
        '<textarea id="summary-text" style="width:100%;height:40vh;box-sizing:border-box;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:12px;padding:8px;resize:vertical;">' +
        escHtml(summary) + '</textarea>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:10px;flex-wrap:wrap;">' +
        '<button class="rp-action-btn" id="summary-copy">Copy</button>' +
        '<button class="rp-action-btn" id="summary-snippet">Save as Snippet</button>' +
        (canCockpit ? '<button class="rp-action-btn" id="summary-cockpit" style="background:var(--bg-active);">Append to COCKPIT.md</button>' : '') +
        '</div>' +
        (canCockpit ? '' : '<div style="font-size:10px;color:var(--text-muted);margin-top:6px;">Switch to a project to enable "Append to COCKPIT.md".</div>') +
        '</div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    document.getElementById('summary-close').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    document.getElementById('summary-copy').onclick = () => {
        navigator.clipboard.writeText(document.getElementById('summary-text').value)
            .then(() => appendSystem(T('msg.summary.copied', 'Summary copied.')));
    };
    document.getElementById('summary-snippet').onclick = () => {
        const txt = document.getElementById('summary-text').value;
        const title = _deriveTitleFromText(txt, 'Session summary');
        _showSaveLibraryDialog('snippet', txt, title, 'txt');
        close();
    };
    const cockpitBtn = document.getElementById('summary-cockpit');
    if (cockpitBtn) cockpitBtn.onclick = async () => {
        const txt = document.getElementById('summary-text').value;
        // Read existing COCKPIT.md, append a dated summary section
        let existing = '';
        try {
            const r = await fetch('files.php?action=read&project=' + encodeURIComponent(proj) +
                                  '&path=' + encodeURIComponent('COCKPIT.md'));
            const d = await r.json();
            if (d.ok) existing = d.content || '';
        } catch(e) {}
        const stamp = fmtDate(new Date()) + ' ' + fmtTime(new Date());
        const appended = (existing ? existing.replace(/\s*$/,'') + '\n\n' : '') +
            '## Session summary — ' + stamp + '\n' + txt + '\n';
        try {
            const r = await fetch('files.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'write_file', project:proj, path:'COCKPIT.md', content: appended})
            });
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.append.failed.error', 'Append failed: {error}', {error: (d.error||'')})); return; }
            appendSystem(T('msg.appended.summary.to.cockpit.md.proj', 'Appended summary to COCKPIT.md ({proj}).', {proj: proj}));
            close();
        } catch(e) { appendError(T('msg.append.failed.message', 'Append failed: {message}', {message: e.message})); }
    };
}

// ─── Poll a bridge.php token to completion, return final accumulated text ───
async function orchestratorPollToken(token, agentLabel) {
    let offset    = 0;
    let collected = '';
    const start   = Date.now();
    const maxMs   = 180 * 1000;
    while (true) {
        if (Date.now() - start > maxMs) throw new Error('Timeout polling ' + agentLabel);
        await new Promise(r => setTimeout(r, 200));
        const pr = await fetch('bridge.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({mode:'poll', token, offset}),
        });
        if (!pr.ok) continue;
        const pd = await pr.json();
        if (!pd.ok) throw new Error(pd.message || 'poll error');
        if (pd.chunk && pd.chunk.length > 0) {
            collected += pd.chunk;
            offset = pd.offset;
        } else if (pd.offset !== undefined) {
            offset = pd.offset;
        }
        if (pd.done) break;
    }
    return collected;
}

// ─── Refresh the Plans panel list ────────────────────────────────────────────
async function plansRefresh() {
    const list = document.getElementById('rp-list-plans');
    if (!list) return;
    try {
        const r = await fetch('orchestrator.php?action=list&project=' +
                              encodeURIComponent(currentProject || 'default') +
                              '&chat=' + encodeURIComponent(currentChat || 'default'));
        const d = await r.json();
        if (!d.ok) {
            list.innerHTML = '<div class="sidebar-empty">Error: ' + (d.error||'') + '</div>';
            return;
        }
        if (!d.plans || d.plans.length === 0) {
            list.innerHTML = '<div class="sidebar-empty">No plans yet.<br>' +
                'Switch prompt mode to <b>Plan</b>, type a goal, press Execute.</div>';
            return;
        }
        list.innerHTML = d.plans.map(p => `
            <div class="plan-item" data-plan-id="${p.id}">
              <div class="plan-row" onclick="plansSelectPlan('${p.id}')">
                <span class="material-symbols-rounded plan-status-icon plan-status-${p.status}">
                    ${planStatusIcon(p.status)}
                </span>
                <div class="plan-meta">
                  <div class="plan-goal">${escapeHtml(p.goal)}</div>
                  <div class="plan-info">${escapeHtml(p.status)} · ${p.step_count} steps · ${shortDate(p.created_at)}</div>
                </div>
              </div>
              <div class="plan-detail" id="plan-detail-${p.id}" style="display:none;"></div>
            </div>
        `).join('');
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Error: ' + e.message + '</div>';
    }
}

function planStatusIcon(status) {
    return ({
        voting:        'how_to_vote',
        synthesizing:  'merge',
        draft:         'draft',
        running:       'play_arrow',
        paused:        'pause',
        complete:      'check_circle',
        failed:        'error',
    })[status] || 'help';
}
function shortDate(iso) {
    if (!iso) return '';
    try {
        const d = new Date(iso);
        return fmtDateTime(d);
    } catch(e) { return iso; }
}

// ─── Select / expand a plan in the list, render full step view ──────────────
async function plansSelectPlan(planId) {
    // Toggle off if already open
    if (_activePlanId === planId) {
        const oldDetail = document.getElementById('plan-detail-' + planId);
        if (oldDetail) oldDetail.style.display = 'none';
        _activePlanId = null;
        _activePlan   = null;
        return;
    }
    // Close any other open detail
    if (_activePlanId) {
        const oldDetail = document.getElementById('plan-detail-' + _activePlanId);
        if (oldDetail) oldDetail.style.display = 'none';
    }
    _activePlanId = planId;

    const detail = document.getElementById('plan-detail-' + planId);
    if (!detail) {
        // Plan list isn't loaded yet, refresh first then try again
        await plansRefresh();
        return plansSelectPlan(planId);
    }
    detail.style.display = 'block';
    detail.innerHTML = '<div style="padding:8px;color:var(--text-muted);">Loading…</div>';

    try {
        const r = await fetch('orchestrator.php?action=get&id=' + encodeURIComponent(planId) +
                              '&project=' + encodeURIComponent(currentProject || 'default'));
        const d = await r.json();
        if (!d.ok) {
            detail.innerHTML = '<div style="padding:8px;color:var(--text-muted);">Error: ' + (d.error||'') + '</div>';
            return;
        }
        _activePlan = d.plan;
        plansRenderDetail(d.plan);
    } catch(e) {
        detail.innerHTML = '<div style="padding:8px;color:var(--text-muted);">Error: ' + e.message + '</div>';
    }
}

// ─── Render the full step view inside a plan's detail area ──────────────────
function plansRenderDetail(plan) {
    const detail = document.getElementById('plan-detail-' + plan.id);
    if (!detail) return;

    const stepHtml = (plan.steps || []).map((s, i) => {
        const editable = !['running','done'].includes(s.status);
        const descId = 'step-desc-' + plan.id + '-' + i;
        return `
            <div class="plan-step plan-step-${s.status||'pending'}">
              <div class="plan-step-row">
                <span class="material-symbols-rounded plan-step-icon plan-step-icon-${s.status||'pending'}"
                      title="Status: ${s.status||'pending'}">
                    ${planStepStatusIcon(s.status)}
                </span>
                <span class="plan-step-num">${i+1}.</span>
                <span class="cap-agent-badge cap-${s.agent}">${(s.agent||'?').toUpperCase()}</span>
                ${s.destructive ? '<span class="plan-step-destructive" title="This step writes/modifies state — will pause if approve_destructive mode is on"><span class="material-symbols-rounded ico">warning</span></span>' : ''}
                <div style="flex:1;"></div>
                <button class="plan-step-btn" onclick="planStepRun('${plan.id}', ${i})" title="Run this step now"
                    ${s.status==='running'?'disabled':''}>
                    <span class="material-symbols-rounded">play_arrow</span>
                </button>
                <button class="plan-step-btn" onclick="planStepSkip('${plan.id}', ${i})" title="Skip this step">
                    <span class="material-symbols-rounded">skip_next</span>
                </button>
                <button class="plan-step-btn" onclick="planStepEdit('${plan.id}', ${i})" title="Edit description"
                    ${!editable?'disabled':''}>
                    <span class="material-symbols-rounded">edit</span>
                </button>
              </div>
              <div class="plan-step-desc" id="${descId}">${escapeHtml(s.description||'')}</div>
              ${s.output ? `
                <div class="plan-step-output">
                  <div class="plan-step-output-hdr" onclick="this.nextElementSibling.classList.toggle('expanded')">
                    Output ▾ (${s.output.length} chars)
                  </div>
                  <pre class="plan-step-output-body">${escapeHtml(s.output)}</pre>
                </div>` : ''}
            </div>
        `;
    }).join('');

    const isDone = ['complete','halted','failed'].includes(plan.status);
    const isRunnable = !isDone && plan.status !== 'running' && plan.status !== 'sequencing';
    detail.innerHTML = `
        <div class="plan-summary">${escapeHtml(plan.summary || '(no summary)')}</div>
        <div class="plan-toolbar">
            ${isRunnable ? `<button class="plan-tb-btn" onclick="orchestratorRunPlan('${plan.id}')" title="Run now using the assigned agents (Claude/Gemini/Ollama). Interactive, uses paid CLI tokens.">
                <span class="material-symbols-rounded">play_arrow</span> Run
            </button>` : ''}
            ${plan.status === 'running' || plan.status === 'sequencing' ? `<button class="plan-tb-btn" onclick="orchestratorPausePlan('${plan.id}')" title="Pause execution">
                <span class="material-symbols-rounded">pause</span>
            </button>` : ''}
            <button class="plan-tb-btn" onclick="plansShowVotes('${plan.id}')" title="Show the original plans each voter agent proposed before synthesis">
                <span class="material-symbols-rounded">how_to_vote</span> Votes
            </button>
            ${isRunnable ? `<button class="plan-tb-btn" onclick="orchestratorSequence('${plan.id}')" title="Run using local Ollama model only. Each step gets isolated context + verification gate + loop detection. Free, private, slower.">
                <span class="material-symbols-rounded">precision_manufacturing</span> Sequence
            </button>
            <button class="plan-tb-btn" onclick="orchestratorScheduleSequence('${plan.id}')" title="Schedule Sequence for later (e.g. overnight). Runs unattended via cron with all guardrails. Review the log in the morning.">
                <span class="material-symbols-rounded">schedule</span>
            </button>` : ''}
            ${isDone ? `<button class="plan-tb-btn" onclick="planRerun('${plan.id}')" title="Reset all steps to pending and re-run. Previous results will be lost.">
                <span class="material-symbols-rounded">replay</span> Re-Run
            </button>` : ''}
            <span style="flex:1;"></span>
            ${isDone ? `<span style="font-size:11px;color:var(--text-muted);">${plan.status === 'complete' ? '<span class="material-symbols-rounded ico">check</span> Complete' : plan.status}</span>` : ''}
            <button class="plan-tb-btn" onclick="plansDelete('${plan.id}')" title="Delete plan">
                <span class="material-symbols-rounded">delete</span>
            </button>
        </div>
        <div class="plan-steps">${stepHtml || '<div class="sidebar-empty">No steps in plan.</div>'}</div>
        <div class="plan-mode-info">
            Auto-run: <b>${plan.auto_run_mode}</b> ·
            Goal: <em>${escapeHtml(plan.goal)}</em>
        </div>
    `;
}

function planStepStatusIcon(status) {
    return ({
        pending:  'radio_button_unchecked',
        running:  'sync',
        done:     'check_circle',
        skipped:  'skip_next',
        failed:   'error',
    })[status] || 'radio_button_unchecked';
}

// ─── Run all remaining steps, honoring auto_run_mode ────────────────────────
async function orchestratorRunPlan(planId) {
    // Always refetch to get latest state
    const r = await fetch('orchestrator.php?action=get&id=' + encodeURIComponent(planId) +
                          '&project=' + encodeURIComponent(currentProject || 'default'));
    const d = await r.json();
    if (!d.ok) { appendError(T('msg.plan.not.found', 'Plan not found')); return; }
    const plan = d.plan;
    const mode = plan.auto_run_mode || 'approve_destructive';

    appendSystem(T('msg.orchestrator.running.plan.id.mode.mode', '▶ Orchestrator running plan {id} (mode: {mode})', {id: plan.id, mode: mode}));

    for (let i = 0; i < (plan.steps || []).length; i++) {
        const s = plan.steps[i];
        if (['done','skipped'].includes(s.status)) continue;

        // Approval gates
        if (mode === 'manual_only') {
            appendSystem(T('msg.manual.mode.stopped.before.step.i.click.run', 'Manual mode — stopped before step {i}. Click Run on the step in the Plans panel to proceed.', {i: (i+1)}));
            return;
        }
        if (mode === 'approve_each') {
            if (!await cockpitConfirm('Run step ' + (i+1) + '?', 'Run step ' + (i+1) + ' (' + s.agent + '): "' + (s.description||'').slice(0,140) + '..."?', 'Run', {icon:'play_arrow'})) {
                appendSystem(T('msg.paused.before.step.i', 'Paused before step {i}', {i: (i+1)}));
                return;
            }
        }
        if (mode === 'approve_destructive' && s.destructive) {
            if (!await cockpitConfirm('Destructive step', 'Step ' + (i+1) + ' is destructive. Run?\n\n' + (s.description||''), 'Run', {danger:true, icon:'warning'})) {
                appendSystem(T('msg.paused.before.destructive.step.i', 'Paused before destructive step {i}', {i: (i+1)}));
                return;
            }
        }

        const ok = await planStepRun(planId, i);
        if (!ok) {
            appendError(T('msg.step.i.failed.pausing.plan', 'Step {i} failed; pausing plan.', {i: (i+1)}));
            return;
        }
    }
    appendSystem(T('msg.icon.check.plan.complete', '[[icon:check]] Plan complete.'));
}

// ─── Run a single step: submit, poll output, save it back ────────────────────
async function planStepRun(planId, stepN) {
    appendSystem(T('msg.running.step.stepn.of.plan', '▶ Running step {stepn} of plan', {stepn: (stepN+1)}));

    const sub = await fetch('orchestrator.php?action=run_step', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project:      currentProject || 'default',
            plan_id:      planId,
            step:         stepN,
            claude_model: sentClaudeModelGet(),
            gemini_model: sentGeminiModelGet(),
            ollama_model: sentOllamaModelGet(),
        }),
    });
    const sd = await sub.json();
    if (!sd.ok) {
        appendError(T('msg.step.stepn.submit.failed.error', 'Step {stepn} submit failed: {error}', {stepn: (stepN+1), error: (sd.error||'unknown')}));
        return false;
    }

    // Refresh detail so the step shows running state
    await plansSelectPlan(planId);   // toggle off
    await plansSelectPlan(planId);   // and back on

    // Poll the token, accumulate output
    let output;
    try {
        output = await orchestratorPollToken(sd.token, sd.agent);
    } catch (e) {
        appendError(T('msg.step.stepn.poll.failed.message', 'Step {stepn} poll failed: {message}', {stepn: (stepN+1), message: e.message}));
        await fetch('orchestrator.php?action=set_step_output', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                project: currentProject || 'default',
                plan_id: planId, step: stepN,
                output: '[error: ' + e.message + ']',
                status: 'failed',
            }),
        });
        return false;
    }

    // Save the output back into the plan
    await fetch('orchestrator.php?action=set_step_output', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project: currentProject || 'default',
            plan_id: planId, step: stepN, output, status: 'done',
        }),
    });

    appendSystem(T('msg.icon.check.step.stepn.done.agent.n.chars', '[[icon:check]] Step {stepn} done ({agent}, {n} chars)', {stepn: (stepN+1), agent: sd.agent, n: output.length}));

    // Refresh the detail view
    if (_activePlanId === planId) {
        await plansSelectPlan(planId);
        await plansSelectPlan(planId);
    }
    return true;
}

async function planStepSkip(planId, stepN) {
    await fetch('orchestrator.php?action=set_step_status', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project: currentProject || 'default',
            plan_id: planId, step: stepN, status: 'skipped',
        }),
    });
    appendSystem(T('msg.step.stepn.skipped', 'Step {stepn} skipped', {stepn: (stepN+1)}));
    if (_activePlanId === planId) {
        await plansSelectPlan(planId); await plansSelectPlan(planId);
    }
}

async function planStepEdit(planId, stepN) {
    if (!_activePlan || _activePlan.id !== planId) {
        appendError(T('msg.plan.not.loaded', 'Plan not loaded')); return;
    }
    const cur = _activePlan.steps[stepN].description || '';
    const nu  = await cprompt('Edit step ' + (stepN+1) + ':', cur);
    if (nu === null || nu === cur) return;
    _activePlan.steps[stepN].description = nu;
    const r = await fetch('orchestrator.php?action=update', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project: currentProject || 'default',
            plan_id: planId,
            patch:   { steps: _activePlan.steps },
        }),
    });
    const d = await r.json();
    if (!d.ok) { appendError(T('msg.edit.failed.error', 'Edit failed: {error}', {error: (d.error||'')})); return; }
    _activePlan = d.plan;
    plansRenderDetail(_activePlan);
}

async function orchestratorPausePlan(planId) {
    await fetch('orchestrator.php?action=update', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project: currentProject || 'default',
            plan_id: planId,
            patch:   { status: 'paused' },
        }),
    });
    appendSystem(T('msg.plan.paused.will.not.auto.progress.per.step', 'Plan paused (will not auto-progress; per-step Run still works)'));
    if (_activePlanId === planId) {
        await plansSelectPlan(planId); await plansSelectPlan(planId);
    }
}

// ─── Plan-and-Sequence: run with verification gates + guardrails ──────────
async function orchestratorSequence(planId) {
    const model = sentOllamaModelGet() || '';
    if (!model) {
        appendError(T('msg.select.an.ollama.model.first.the.executor.fo', 'Select an Ollama model first (the executor for Plan-and-Sequence).'));
        return;
    }
    if (!await cockpitConfirm('Start Plan-and-Sequence?', 'Executor: ' + model + ' (local)\nGuardrails: step-cap=20, failure-halt=3, loop-detection=on\n\nEach step runs in isolated context with verification gates.', 'Start', {icon:'rocket_launch'})) return;

    appendSystem(T('msg.plan.and.sequence.starting.with.model', '▶ Plan-and-Sequence starting with {model}…', {model: model}));

    try {
        // Start the sequence
        const sr = await fetch('orchestrator.php?action=run_sequence', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
                project: currentProject || 'default',
                plan_id: planId,
                executor_model: model,
                guardrails: { step_cap: 20, max_consecutive_fails: 3, loop_similarity_threshold: 0.85, loop_window: 3 },
            }),
        });
        const sd = await sr.json();
        if (!sd.ok) { appendError(T('msg.sequence.start.failed.error', 'Sequence start failed: {error}', {error: (sd.error||'')})); return; }

        // Tick through steps
        let running = true;
        let ticks = 0;
        while (running && ticks < 30) {
            ticks++;
            const tr = await fetch('orchestrator.php?action=run_sequence_tick', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({ project: currentProject || 'default', plan_id: planId }),
            });
            const td = await tr.json();

            if (!td.ok) {
                if (['complete','halted'].includes(td.status)) {
                    appendSystem(T('msg.sequence.statusreason', 'Sequence {status}{reason}', {status: td.status, reason: (td.reason ? ': ' + td.reason : '')}));
                    running = false; break;
                }
                appendError(T('msg.sequence.tick.error.error', 'Sequence tick error: {error}', {error: (td.error||'')}));
                running = false; break;
            }

            if (['complete','halted'].includes(td.status)) {
                appendSystem(T('msg.sequence.statusreason', 'Sequence {status}{reason}', {status: td.status, reason: (td.reason ? ': ' + td.reason : '')}));
                cockpitNotify('Sequence ' + td.status, td.reason || 'Plan sequence finished.');
                running = false; break;
            }

            // Poll for step output
            appendSystem(T('msg.step.step.running.agent', '  Step {step} running ({agent})…', {step: (td.step+1), agent: td.agent}));
            let output = '';
            if (td.token) {
                try { output = await orchestratorPollToken(td.token, td.agent); }
                catch(e) { output = '[poll error: ' + e.message + ']'; }
            }

            // Verify step
            const vr = await fetch('orchestrator.php?action=verify_step', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({
                    project: currentProject || 'default',
                    plan_id: planId, step: td.step, output: output,
                }),
            });
            const vd = await vr.json();
            if (vd.verified) {
                appendSystem(T('msg.icon.check.step.step.verified.detail', '  [[icon:check]] Step {step} verified: {detail}', {step: (td.step+1), detail: (vd.detail||'')}));
            } else {
                appendError(T('msg.icon.close.step.step.failed.reason', '  [[icon:close]] Step {step} failed: {reason}', {step: (td.step+1), reason: (vd.reason || vd.detail || '')}));
            }
            if (vd.plan_status && vd.plan_status !== 'sequencing') {
                appendSystem(T('msg.sequence.planstatus', 'Sequence {planstatus}', {planstatus: vd.plan_status}));
                running = false;
            }

            // Refresh plan view
            if (_activePlanId === planId) {
                await plansSelectPlan(planId); await plansSelectPlan(planId);
            }
        }
    } catch(e) {
        appendError(T('msg.sequence.error.message', 'Sequence error: {message}', {message: e.message}));
    }
}

async function orchestratorScheduleSequence(planId) {
    const when = await cprompt('Schedule Plan-and-Sequence run.\n\nEnter date/time (e.g. "2026-06-14 02:00", "tomorrow 3am", "+2h"):', '');
    if (!when) return;
    const model = sentOllamaModelGet() || '';

    try {
        const r = await fetch('scheduler.php?action=schedule', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
                command: 'plan_sequence',
                scheduled_at: when,
                params: {
                    project: currentProject || 'default',
                    plan_id: planId,
                    executor_model: model,
                    guardrails: { step_cap: 20, max_consecutive_fails: 3 },
                },
            }),
        });
        const d = await r.json();
        if (d.ok) {
            appendSystem(T('msg.scheduled.plan.and.sequence.for.scheduledat', 'Scheduled: Plan-and-Sequence for {scheduledat} (job {jobid})', {scheduledat: d.scheduled_at, jobid: d.job_id}));
        } else {
            appendError(T('msg.schedule.failed.error', 'Schedule failed: {error}', {error: (d.error||'')}));
        }
    } catch(e) { appendError(T('msg.schedule.error.message', 'Schedule error: {message}', {message: e.message})); }
}

async function plansShowVotes(planId) {
    const r = await fetch('orchestrator.php?action=get&id=' + encodeURIComponent(planId) +
                          '&project=' + encodeURIComponent(currentProject || 'default'));
    const d = await r.json();
    if (!d.ok) { appendError(T('msg.could.not.load.plan', 'Could not load plan')); return; }
    const votes = d.plan.votes || {};
    const lines = ['Original voter plans for: ' + d.plan.goal, ''];
    for (const [agent, info] of Object.entries(votes)) {
        const planObj = info.plan;
        if (!planObj) {
            lines.push('━━━ ' + agent.toUpperCase() + ' ━━━ (no valid plan)');
            if (info.error) lines.push('  Error: ' + info.error);
        } else {
            lines.push('━━━ ' + agent.toUpperCase() + ' ━━━');
            lines.push('  ' + (planObj.summary || ''));
            (planObj.steps || []).forEach((s, i) => {
                lines.push('  ' + (i+1) + '. (' + (s.agent||'?') + ') ' + (s.description||'').slice(0,160));
            });
        }
        lines.push('');
    }
    appendSystem(lines.join('\n'));
}

async function planRerun(planId) {
    if (!await cockpitConfirm('Re-run plan?', 'Re-Run will reset ALL steps to pending.\nPrevious results will be lost. Continue?', 'Re-run', {danger:true, icon:'restart_alt'})) return;
    const plan = _activePlan;
    if (!plan) return;
    const resetSteps = (plan.steps || []).map(s => {
        const c = Object.assign({}, s);
        c.status = 'pending';
        delete c.output;
        delete c.error;
        delete c.started_at;
        delete c.finished_at;
        return c;
    });
    const r = await fetch('orchestrator.php?action=update', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project: currentProject || 'default',
            plan_id: planId,
            patch: { steps: resetSteps, status: 'draft', current_step: 0 }
        })
    });
    const d = await r.json();
    if (!d.ok) { appendError(T('msg.re.run.reset.failed.error', 'Re-run reset failed: {error}', {error: (d.error||'unknown')})); return; }
    appendSystem(T('msg.plan.reset.ready.to.run.again', 'Plan reset — ready to run again.'));
    _activePlan = d.plan;
    plansRenderDetail(d.plan);
}

async function plansDelete(planId) {
    if (!await cockpitConfirm('Delete plan?', 'Delete this plan? This cannot be undone.', 'Delete', {danger:true, icon:'delete'})) return;
    await fetch('orchestrator.php?action=delete&project=' +
                encodeURIComponent(currentProject || 'default') +
                '&id=' + encodeURIComponent(planId), { method: 'POST' });
    appendSystem(T('msg.plan.deleted', 'Plan deleted'));
    _activePlanId = null;
    _activePlan   = null;
    plansRefresh();
}

async function plansShowSettings() {
    const r = await fetch('orchestrator.php?action=settings_get' +
                          '&project=' + encodeURIComponent(currentProject || 'default') +
                          '&chat='    + encodeURIComponent(currentChat   || 'default'));
    const d = await r.json();
    if (!d.ok) { appendError(T('msg.settings.load.failed', 'Settings load failed')); return; }
    const s = d.settings;

    const modes = ['auto', 'approve_each', 'approve_destructive', 'manual_only'];
    const cur   = s.auto_run_mode;
    const idx   = modes.indexOf(cur);
    const next  = modes[(idx + 1) % modes.length];

    if (!await cockpitConfirm('Cycle auto-run mode?', 'Current orchestrator settings (chat-level):\n  Auto-run mode: ' + cur + '\n  Planner mode: ' + s.planner_mode + '\n  Synthesizer: ' + s.synthesizer + '\n\nCycle Auto-run mode to: ' + next + '\n(For other settings, edit chat_*.json directly)', 'Cycle to ' + next, {icon:'swap_horiz'})) return;

    await fetch('orchestrator.php?action=settings_set', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({
            project: currentProject || 'default',
            chat:    currentChat || 'default',
            scope:   'chat',
            patch:   { auto_run_mode: next },
        }),
    });
    appendSystem(T('msg.auto.run.mode.changed.cur.next', 'Auto-run mode changed: {cur} → {next}', {cur: cur, next: next}));
}

// Helpers — read current model selections from the topbar selectors
function sentClaudeModelGet() {
    const el = document.getElementById('claude-model');
    return el ? el.value : 'sonnet';
}
function sentGeminiModelGet() {
    const el = document.getElementById('gemini-model');
    return el ? el.value : 'auto';
}
function sentOllamaModelGet() {
    const el = document.getElementById('ollama-model');
    return el ? el.value : '';
}

// =============================================================================
