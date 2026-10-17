// =============================================================================
// redesign.js — Redesign mode: plan first, you approve, then small steps.
//
//   redesignStart()   the REDESIGN button beside PLAN. The prompt box holds the goal ("split the main
//                     unit", "take the database code out of the form").
//
//   1. PROPOSE   the current agent is asked for a written proposal ONLY — structure now, problems,
//                structure after, numbered steps, risks — and told to change nothing. The proposal is
//                saved in the project (redesign/PLAN-<time>.md).
//   2. APPROVE   you see the steps and can untick any. Nothing runs until you press Start.
//   3. STEP      for each approved step: a checkpoint of the project is taken, the agent does ONLY that
//                step and checks the build, and you decide: keep going, undo the step (the checkpoint
//                is restored), or stop here.
//
// This is the plain version: it uses the agent you already selected, in the project you are in, and
// the checkpoints are file snapshots (checkpoint.php), not git — your own repository is never touched.
// =============================================================================
(function () {
    'use strict';
    function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function ov(inner, id) {
        var o = document.getElementById('redesign-ov'); if (o) o.remove();
        o = document.createElement('div'); o.id = 'redesign-ov';
        o.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
        o.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(720px,94vw);max-height:90vh;overflow:auto;padding:18px;color:var(--text-primary);">' + inner + '</div>';
        document.body.appendChild(o); return o;
    }
    function closeOv() { var o = document.getElementById('redesign-ov'); if (o) o.remove(); }
    function btn(id, label, kind) {
        var st = kind === 'primary' ? 'background:var(--accent-blue);color:#fff;' : (kind === 'danger' ? 'color:var(--claude);' : '');
        return '<button class="action-btn" data-act="' + id + '" style="padding:4px 11px;font-size:11px;' + st + '">' + esc(label) + '</button>';
    }
    // Resolves with the id of the button pressed.
    function choose(title, bodyHtml, buttons) {
        return new Promise(function (resolve) {
            var o = ov('<h2 style="margin:0 0 8px;font-size:14px;">' + esc(title) + '</h2>' + bodyHtml +
                '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px;flex-wrap:wrap;">' + buttons.map(function (b) { return btn(b[0], b[1], b[2]); }).join('') + '</div>');
            o.querySelectorAll('[data-act]').forEach(function (b) { b.onclick = function () { resolve({ act: b.dataset.act, root: o }); }; });
        });
    }
    function post(url, body) { return fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(function (r) { return r.json(); }); }

    // "Step 3: Move the SQL out of the form — ..." (also "**Step 3**", "3." under a Steps heading is NOT guessed:
    // an agent that did not number its steps "Step N" is asked to, rather than having its prose guessed at.)
    function parseSteps(text) {
        var lines = String(text || '').split('\n'), steps = [], cur = null;
        var re = /^\s*(?:[-*]\s*)?(?:\*\*|__)?\s*Step\s+(\d+)\s*[:.)\-–—]\s*(?:\*\*|__)?\s*(.+?)\s*$/i;
        var done = false;
        lines.forEach(function (l) {
            if (done) return;
            var m = l.match(re);
            if (m) { cur = { n: parseInt(m[1], 10), title: m[2].replace(/(\*\*|__)\s*$/, '').trim(), detail: '' }; steps.push(cur); return; }
            if (/^\s*#{1,6}\s/.test(l)) { cur = null; if (steps.length) done = true; return; }   // the heading after the steps ends the list
            if (cur && l.trim()) cur.detail += (cur.detail ? '\n' : '') + l.trim();
        });
        return steps;
    }
    window.redesignParseSteps = parseSteps;

    function proposalPrompt(goal) {
        return 'REDESIGN PROPOSAL. Do not change, create or delete any file in this reply — this is a proposal only.\n\n' +
            'Goal: ' + goal + '\n\n' +
            'Look at this project as it is now, then answer with exactly these sections:\n' +
            '## Now\nThe structure today: the main units/modules/files and which depends on which.\n' +
            '## Problems\nWhat is wrong with it, tied to the goal.\n' +
            '## After\nThe proposed structure, and a before → after list of the moves (split X into Y and Z; extract a class; remove the dependency A → B).\n' +
            '## Steps\nBetween 3 and 8 lines, each written exactly as "Step N: <title> — <what changes, in which files>". Every step must leave the project building and working. Step 1 must be the smallest safe one.\n' +
            '## Risks\nWhat could break, and how each step can be checked.\n\n' +
            'Do not start any step.';
    }
    function stepPrompt(step, all, goal) {
        return 'REDESIGN STEP ' + step.n + ' of ' + all.length + ': ' + step.title + '\n\n' +
            (step.detail ? step.detail + '\n\n' : '') +
            'Overall goal: ' + goal + '\nThe approved steps, for context only:\n' + all.map(function (s) { return '  Step ' + s.n + ': ' + s.title; }).join('\n') + '\n\n' +
            'Do ONLY this step. Change only what it needs. Then check the project the way its kind says (compile it; run its tests if it has any) and report: the files you changed, the build result, and anything you could not verify. Do not start the next step.';
    }

    window.redesignStart = async function () {
        var el = document.getElementById('prompt-in');
        var goal = (el ? el.value : '').trim();
        if (!goal) { appendSystem(T('msg.redesign.goal', 'Type what should change in the prompt box first (for example: split the main unit), then press REDESIGN.')); if (el) el.focus(); return; }
        if (typeof currentProject !== 'string' || !currentProject || currentProject === 'default') { appendSystem(T('msg.redesign.project', 'Redesign works on a project. Open or create a project first.')); return; }
        if (currentAgent === 'tools') { appendSystem(T('msg.redesign.agent', 'Pick a model agent (not Tools) for Redesign.')); return; }
        if (!(await ensureActiveChat())) return;
        var proj = currentProject;          // pinned: switching projects while a redesign runs must not redirect a checkpoint or an undo
        if (el) el.value = '';
        appendMsg('dario', _userLabel(), 'dario', '[Redesign] ' + goal, new Date(), '');

        // 1. PROPOSE
        appendSystem(T('msg.redesign.asking', 'Redesign: asking for a proposal. Nothing will be changed yet.'));
        var reply = await sendToOne(currentAgent, proposalPrompt(goal));
        if (typeof reply !== 'string' || !reply.trim()) { appendSystem(T('msg.redesign.noreply', 'Redesign stopped: no proposal came back.')); return; }
        var steps = parseSteps(reply);
        var stamp = new Date().toISOString().replace(/[-:T]/g, '').slice(0, 12);
        var planPath = 'redesign/PLAN-' + stamp + '.md';
        try { await post('files.php', { action: 'write_file', project: proj, path: planPath, content: '# Redesign proposal\n\nGoal: ' + goal + '\n\n' + reply + '\n' }); } catch (e) {}
        if (steps.length < 2) {
            appendSystem(T('msg.redesign.nosteps', 'The proposal has no steps written as "Step N: …", so there is nothing to approve one by one. Reply in the chat asking for the Steps section in that form, then press REDESIGN again. (The proposal is saved in {path}.)', { path: planPath }));
            return;
        }

        // 2. APPROVE
        var list = steps.map(function (s, i) {
            return '<label style="display:block;margin:6px 0;font-size:12px;"><input type="checkbox" data-i="' + i + '" checked> <b>' + esc(T('redesign.step', 'Step {n}', { n: s.n })) + '</b> — ' + esc(s.title) +
                (s.detail ? '<div style="margin:2px 0 0 22px;font-size:11px;color:var(--text-muted);white-space:pre-wrap;">' + esc(s.detail.slice(0, 300)) + '</div>' : '') + '</label>';
        }).join('');
        var a = await choose(T('redesign.approve.title', 'Approve the redesign plan'),
            '<div style="font-size:12px;line-height:1.5;">' + esc(T('redesign.approve.text', 'The proposal is in the chat and saved as {path}. Untick any step you do not want. Nothing has been changed. Each step you start takes a checkpoint of the project first, and you decide after every step whether to continue.', { path: planPath })) + '</div>' + list,
            [['cancel', T('redesign.cancel', 'Cancel')], ['go', T('redesign.start', 'Start step by step'), 'primary']]);
        var picked = [].slice.call(a.root.querySelectorAll('input[data-i]')).filter(function (c) { return c.checked; }).map(function (c) { return steps[+c.dataset.i]; });
        closeOv();
        if (a.act !== 'go' || !picked.length) { appendSystem(T('msg.redesign.cancelled', 'Redesign cancelled. The proposal stays in the chat and in {path}; nothing was changed.', { path: planPath })); return; }

        // 3. STEP
        for (var k = 0; k < picked.length; k++) {
            var s = picked[k];
            var cp = await fetch('checkpoint.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'create', project: proj, label: 'redesign step ' + s.n }) }).then(function (r) { return r.json(); }).catch(function () { return { ok: false, error: 'checkpoint unavailable' }; });
            if (!cp.ok) {
                var c = await choose(T('redesign.nocp.title', 'No checkpoint could be taken'), '<div style="font-size:12px;">' + esc(cp.error || '') + '<br>' + esc(T('redesign.nocp.text', 'Without it, this step cannot be undone from here.')) + '</div>',
                    [['stop', T('redesign.stop', 'Stop here')], ['go', T('redesign.nocp.go', 'Continue without a checkpoint'), 'danger']]);
                closeOv(); if (c.act !== 'go') { appendSystem(T('msg.redesign.stopped', 'Redesign stopped before step {n}.', { n: s.n })); return; }
            } else appendSystem(T('msg.redesign.cp', 'Checkpoint taken ({files} files). Step {n} of {m}: {title}', { files: cp.files, n: s.n, m: steps.length, title: s.title }));
            var out = await sendToOne(currentAgent, stepPrompt(s, picked, goal));
            if (typeof out !== 'string') { appendSystem(T('msg.redesign.steperr', 'Step {n} did not complete. Nothing further was started.', { n: s.n })); return; }
            var last = k === picked.length - 1;
            var d = await choose(T('redesign.done.title', 'Step {n} finished', { n: s.n }),
                '<div style="font-size:12px;line-height:1.5;">' + esc(T('redesign.done.text', 'Read the agent\'s report in the chat: files changed and whether it builds. You can keep it, or undo this step — the project goes back to the checkpoint taken just before it.')) + '</div>',
                [['undo', T('redesign.undo', 'Undo this step'), 'danger'], ['stop', last ? T('redesign.finish', 'Finish') : T('redesign.stop', 'Stop here')]].concat(last ? [] : [['next', T('redesign.next', 'Keep it, next step'), 'primary']]));
            closeOv();
            if (d.act === 'undo' && cp.ok) {
                var r = await post('checkpoint.php', { action: 'restore', project: proj, name: cp.name, confirm: true });
                appendSystem(r.message || r.error || T('msg.restore.failed', 'restore failed'));
                if (typeof ftRefresh === 'function') try { ftRefresh(); } catch (e) {}
                return;
            }
            if (d.act !== 'next') { appendSystem(T('msg.redesign.end', 'Redesign ended after step {n}. Checkpoints stay available.', { n: s.n })); return; }
        }
    };
})();
