// =============================================================================
// Dossier — a researched answer with sources you can check.
//
// Ask a question; Cockpit searches several framings of it, reads the pages, and
// hands the agent a numbered source pack with one instruction: answer from these
// and cite them. The report is then saved into the project as Markdown, so it
// lands in Artifacts with everything else the project produced.
//
// The gathering is deterministic (dossier.php): the same question fetches the
// same pages whichever agent writes the report, and a small local model can do
// the writing without having to drive a search loop it would get lost in.
//
// The honest limit, stated in the report itself: this reads the first pages a
// search engine returns. It is a fast survey, not a literature review, and the
// sources are listed precisely so you can judge them.
// =============================================================================

let _dossierPending = null;

function dossierOpen() {
    document.getElementById('dossier-ov')?.remove();
    const ov = document.createElement('div');
    ov.id = 'dossier-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(560px,94vw);padding:18px;">' +
        '<div style="display:flex;align-items:center;margin-bottom:8px;">' +
        '<h2 style="margin:0;font-size:13px;flex:1;">' +
        '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">travel_explore</span> Dossier</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#dossier-ov\').remove()">×</span></div>' +
        '<div style="font-size:10.5px;color:var(--warn);border:1px solid var(--border-mid);border-radius:4px;padding:5px 8px;margin-bottom:8px;">' + T('ui.dossier.notice', 'Preview: free web search engines now block automated queries, so a search may return nothing from this network. Reading pages works. A key-based search comes in the next release.') + '</div>' +
        '<label style="font-size:10.5px;color:var(--text-muted);">What do you want to know?</label>' +
        '<textarea id="dossier-q" rows="2" placeholder="e.g. which local TTS engines handle French well, and how do they compare?" ' +
        'style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:6px;font-size:12px;"></textarea>' +
        '<div style="display:flex;gap:10px;margin-top:8px;font-size:10.5px;color:var(--text-muted);">' +
        '<label style="flex:1;">Searches<select id="dossier-angles" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:3px;font-size:11px;">' +
        '<option>2</option><option selected>4</option><option>6</option></select></label>' +
        '<label style="flex:1;">Pages to read<select id="dossier-pages" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:3px;font-size:11px;">' +
        '<option>3</option><option selected>6</option><option>10</option></select></label></div>' +
        '<div style="font-size:10px;color:var(--text-dim);margin-top:8px;">Cockpit reads the pages first, then the active agent writes the report from them and cites each claim. It is saved to the project as Markdown.</div>' +
        '<div id="dossier-state" style="font-size:11px;color:var(--text-dim);min-height:16px;margin-top:6px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="this.closest(\'#dossier-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" id="dossier-go" onclick="dossierRun()">Research</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    document.getElementById('dossier-q').focus();
}

async function dossierRun() {
    const q = (document.getElementById('dossier-q') || {}).value || '';
    const angles = parseInt((document.getElementById('dossier-angles') || {}).value || '4', 10);
    const pages  = parseInt((document.getElementById('dossier-pages')  || {}).value || '6', 10);
    const state = document.getElementById('dossier-state');
    const btn   = document.getElementById('dossier-go');
    if (!q.trim()) { state.textContent = T('msg.ask.something.first', 'Ask something first.'); return; }

    btn.disabled = true;
    state.textContent = T('msg.searching.and.reading.pages.this.takes.a.min', 'searching and reading pages… (this takes a minute)');
    let d;
    try {
        d = await (await fetch('dossier.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ question: q.trim(), angles: angles, pages: pages }),
        })).json();
    } catch (e) { state.textContent = 'Failed: ' + e.message; btn.disabled = false; return; }

    if (!d.ok)            { state.textContent = d.error || 'Gathering failed.'; btn.disabled = false; return; }
    if (!d.sources.length) {
        // dossier.php already collects WHY each engine came back empty; showing
        // only the note sent people to check their network when the real answer
        // was "the search engine is throttling this machine, wait a few minutes".
        const why = (d.errors || []).filter(Boolean).slice(0, 3).join(' · ');
        state.textContent = (d.note || 'Nothing could be read.') + (why ? '  —  ' + why : '');
        btn.disabled = false;
        return;
    }

    document.getElementById('dossier-ov')?.remove();
    appendSystem(T('msg.icon.travel.explore.dossier.read.read.page.s', '[[icon:travel_explore]] Dossier: read {read} page(s){skipped} across {n} searches.', {read: d.read, skipped: (d.skipped ? ', skipped ' + d.skipped + ' that would not load' : ''), n: d.queries.length}));

    const pack = d.sources.map(s =>
        '[' + s.n + '] ' + s.title + '\n' + s.url + '\n' + s.text).join('\n\n---\n\n');

    const prompt =
        'Write a short report answering this question:\n\n' + d.question + '\n\n' +
        'Use ONLY the sources below. Cite them inline as [1], [2] — every claim that comes from a source gets a marker. ' +
        'Where sources disagree, say so and cite both. Where they do not answer part of the question, say that plainly ' +
        'rather than filling the gap from memory. End with a "Sources" list of the numbers you actually used.\n\n' +
        '=== SOURCES ===\n\n' + pack;

    _dossierPending = { question: d.question, sources: d.sources, at: Date.now() };
    // The prompt box is #prompt-in — #promptInput never existed. This file was
    // never loaded until b131, so the wrong id sat here unnoticed: the assembled report prompt
    // went into null, sendPrompt() fired on an empty box, and nothing was sent.
    const input = document.getElementById('prompt-in');
    if (input) input.value = prompt;
    if (typeof sendPrompt === 'function') sendPrompt();
}

/** Save a finished report next to the project's other artifacts. */
async function dossierMaybeSave(answerText) {
    if (!_dossierPending || !answerText) return;
    if (Date.now() - _dossierPending.at > 20 * 60 * 1000) { _dossierPending = null; return; }
    const ctx = _dossierPending; _dossierPending = null;

    const stamp = new Date().toISOString().slice(0, 16).replace(/[:T]/g, '-');
    const slug  = ctx.question.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48) || 'dossier';
    const name  = 'dossier-' + slug + '-' + stamp + '.md';
    const md =
        '# ' + ctx.question + '\n\n' +
        '_Researched ' + new Date().toISOString().slice(0, 16).replace('T', ' ') + ' UTC · ' +
        ctx.sources.length + ' sources read by Cockpit_\n\n' +
        answerText + '\n\n---\n\n## Sources consulted\n\n' +
        ctx.sources.map(s => '[' + s.n + '] [' + s.title + '](' + s.url + ')').join('\n') + '\n\n' +
        '_These are the first pages the search engines returned for the question and a few rephrasings of it. ' +
        'A fast survey, not a literature review — judge the sources before relying on the report._\n';
    try {
        const w = await (await fetch('files.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'write_file', project: currentProject, path: name, content: md }),
        })).json();
        if (w.ok) {
            appendSystem(T('msg.icon.description.dossier.saved.as.name.it.is', '[[icon:description]] Dossier saved as {name} — it is in Artifacts.', {name: name}));
            if (typeof artifactsRefresh === 'function') artifactsRefresh();
        } else {
            appendError(T('msg.dossier.the.report.is.above.but.saving.it.fa', 'Dossier: the report is above, but saving it failed — {error}', {error: (w.error || '?')}));
        }
    } catch (e) { appendError(T('msg.dossier.could.not.save.the.report.message', 'Dossier: could not save the report — {message}', {message: e.message})); }
}
