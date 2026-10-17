// =============================================================================
// Margin — write in the margin of a file, get a proposal back.
//
// Select a few lines in the Files viewer (the Code panel is not a live file view), say what should
// change, and the agent answers with the replacement for exactly those lines.
// Nothing is written until you have seen the change and pressed Apply.
//
// Why it works this way rather than letting the agent edit the file:
//   - The anchor travels with the request (file + line range + the exact text),
//     so the agent is not asked to find the place again and cannot drift onto a
//     similar-looking passage elsewhere in the file.
//   - Only the REPLACEMENT is asked for. Asking a model to re-emit a whole file
//     to change three lines invites silent losses in the parts nobody reviewed.
//   - The splice happens here, against the file as it is on disk right now, and
//     is shown as a diff before anything is saved. The file write goes through
//     files.php?action=write_file, the same path the editor uses.
//
// The agent never touches the file: it produces text, Cockpit does the edit, and
// only after you agree.
// =============================================================================

let _marginCtx = null;      // the anchor awaiting an answer
let _marginBtn = null;      // the floating affordance

/** Containers whose text can be annotated: [data-margin-file] carries the path. */
function marginInit() {
    document.addEventListener('selectionchange', _marginOnSelect);
    document.addEventListener('mousedown', e => {
        if (_marginBtn && !_marginBtn.contains(e.target)) _marginHideBtn();
    });
}

function _marginHideBtn() { if (_marginBtn) { _marginBtn.remove(); _marginBtn = null; } }

function _marginOnSelect() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) { _marginHideBtn(); return; }
    const text = sel.toString();
    if (!text.trim() || text.length > 8000) { _marginHideBtn(); return; }

    // Only inside a container that declares which file it is showing.
    let node = sel.anchorNode;
    if (node && node.nodeType === 3) node = node.parentElement;
    const host = node && node.closest ? node.closest('[data-margin-file]') : null;
    if (!host) { _marginHideBtn(); return; }

    const rect = sel.getRangeAt(0).getBoundingClientRect();
    if (!rect || (!rect.width && !rect.height)) { _marginHideBtn(); return; }

    _marginHideBtn();
    _marginBtn = document.createElement('button');
    _marginBtn.className = 'action-btn';
    _marginBtn.innerHTML = '<span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">edit_note</span> Margin';
    _marginBtn.title = T('msg.ask.for.a.change.to.just.these.lines', 'Ask for a change to just these lines');
    _marginBtn.style.cssText = 'position:fixed;z-index:100050;font-size:10.5px;padding:2px 8px;' +
        'left:' + Math.round(rect.left) + 'px;top:' + Math.round(Math.max(4, rect.top - 26)) + 'px;';
    _marginBtn.onclick = () => marginOpen(host.getAttribute('data-margin-file'), text);
    document.body.appendChild(_marginBtn);
}

/**
 * Line range of `snippet` inside `content` — 1-based, inclusive, or null.
 *
 * Two rules, both learned from a test that would otherwise have corrupted a file:
 *
 * LINE-ALIGNED. A plain indexOf matches mid-line. Selecting "TARGET a\nTARGET b"
 * still matches after someone edits the second line to "TARGET b changed" — the
 * splice would then replace the anchor and leave " changed" dangling. So the
 * match must begin at the start of a line and end at the end of one.
 *
 * UNAMBIGUOUS. If the same lines appear twice, there is no way to know which the
 * person selected, and picking one is a coin flip with somebody's file. Refuse.
 */
function _marginLocate(content, snippet) {
    if (!snippet) return null;
    const hits = [];
    let i = content.indexOf(snippet);
    while (i !== -1) {
        const endsAt = i + snippet.length;
        const startOk = (i === 0) || content[i - 1] === '\n';
        const endOk   = (endsAt === content.length) || content[endsAt] === '\n';
        if (startOk && endOk) hits.push(i);
        i = content.indexOf(snippet, i + 1);
    }
    if (hits.length !== 1) return null;        // absent, or appears more than once
    const idx    = hits[0];
    const first  = content.slice(0, idx).split('\n').length;
    const last   = first + snippet.split('\n').length - 1;
    return { first: first, last: last, index: idx, ambiguous: false };
}

async function marginOpen(filePath, selected) {
    _marginHideBtn();
    if (!filePath) { appendError(T('msg.margin.this.view.does.not.say.which.file.it', 'Margin: this view does not say which file it is showing.')); return; }

    // Read the file as it is NOW: the panel may be showing something older, and
    // an edit spliced against stale text would quietly damage the file.
    let content = '';
    try {
        const r = await (await fetch('files.php?action=read&project=' + encodeURIComponent(currentProject) +
                                     '&path=' + encodeURIComponent(filePath))).json();
        if (!r.ok) { appendError(T('msg.margin.could.not.read.filepath.error', 'Margin: could not read {filepath} — {error}', {filepath: filePath, error: (r.error || '?')})); return; }
        content = r.content || '';
    } catch (e) { appendError(T('msg.margin.message', 'Margin: {message}', {message: e.message})); return; }

    const loc = _marginLocate(content, selected);
    if (!loc) {
        appendError(T('msg.margin.cannot.anchor.that.selection.it.eithe', 'Margin: cannot anchor that selection — it either no longer matches the file, or appears more than once so there is no way to tell which you meant. Select whole lines, including something unique.'));
        return;
    }

    document.getElementById('margin-ov')?.remove();
    const ov = document.createElement('div');
    ov.id = 'margin-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(620px,94vw);padding:18px;">' +
        '<div style="display:flex;align-items:center;margin-bottom:8px;">' +
        '<h2 style="margin:0;font-size:13px;flex:1;">Margin — ' + escHtml(filePath) +
        ' <span style="color:var(--text-dim);font-weight:400;">lines ' + loc.first + '–' + loc.last + '</span></h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#margin-ov\').remove()">×</span></div>' +
        '<pre style="max-height:150px;overflow:auto;background:var(--bg-darker);border:1px solid var(--border-dim);' +
        'border-radius:4px;padding:7px;font-size:11px;margin:0 0 8px 0;">' + escHtml(selected) + '</pre>' +
        '<label style="font-size:10.5px;color:var(--text-muted);">What should change here?</label>' +
        '<textarea id="margin-note" rows="3" placeholder="e.g. handle the empty case, and drop the duplicated check" ' +
        'style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:6px;font-size:12px;"></textarea>' +
        '<div style="font-size:10px;color:var(--text-dim);margin-top:6px;">The agent gets these lines and your note, and answers with a replacement. Nothing is written until you see it and press Apply.</div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px;">' +
        '<button class="action-btn" onclick="this.closest(\'#margin-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="marginSend()">Ask</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    document.getElementById('margin-note').focus();

    _marginCtx = { file: filePath, selected: selected, content: content, loc: loc };
}

/** Compose the prompt and send it down the normal chat path, so the request and
 *  the answer are part of the conversation rather than a hidden side channel. */
function marginSend() {
    const note = (document.getElementById('margin-note') || {}).value || '';
    document.getElementById('margin-ov')?.remove();
    if (!_marginCtx) return;
    if (!note.trim()) { appendError(T('msg.margin.say.what.should.change', 'Margin: say what should change.')); return; }
    _marginCtx.note = note.trim();
    _marginCtx.asked = Date.now();

    const p = 'Change these lines of ' + _marginCtx.file + ' (lines ' +
              _marginCtx.loc.first + '–' + _marginCtx.loc.last + ').\n\n' +
              'What to change: ' + _marginCtx.note + '\n\n' +
              'The lines as they are now:\n```\n' + _marginCtx.selected + '\n```\n\n' +
              'Reply with ONLY the replacement for those exact lines, in a single fenced code block. ' +
              'No explanation, no surrounding lines, no file markers — just the lines that should stand there instead.';

    // #prompt-in, not #promptInput — the latter has never existed. Same wrong id
    // as dossier.js and intercom.js carried: the edit request went into null and
    // sendPrompt() fired on an empty box, so Margin asked for nothing.
    const input = document.getElementById('prompt-in');
    if (input) { input.value = p; }
    if (typeof sendPrompt === 'function') sendPrompt();
    else appendError(T('msg.margin.the.prompt.box.is.not.available', 'Margin: the prompt box is not available.'));
}

/** Called when an answer arrives. If a Margin request is outstanding and the
 *  reply carries a fenced block, offer to apply it. */
function marginMaybeOffer(answerText) {
    if (!_marginCtx || !_marginCtx.asked || !answerText) return;
    if (Date.now() - _marginCtx.asked > 15 * 60 * 1000) { _marginCtx = null; return; }
    const m = answerText.match(/```[a-zA-Z0-9_+-]*\n([\s\S]*?)```/);
    if (!m) return;                       // no block: the agent chose to discuss instead
    const replacement = m[1].replace(/\s+$/, '');
    const ctx = _marginCtx; _marginCtx = null;
    marginShowDiff(ctx, replacement);
}

function marginShowDiff(ctx, replacement) {
    const before = ctx.selected;
    document.getElementById('margin-diff-ov')?.remove();
    const ov = document.createElement('div');
    ov.id = 'margin-diff-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';
    const pane = (title, text, colour) =>
        '<div style="flex:1;min-width:0;"><div style="font-size:10px;color:' + colour + ';margin-bottom:3px;">' + title + '</div>' +
        '<pre style="margin:0;max-height:320px;overflow:auto;background:var(--bg-darker);border:1px solid var(--border-dim);' +
        'border-radius:4px;padding:7px;font-size:11px;white-space:pre-wrap;">' + escHtml(text) + '</pre></div>';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(900px,96vw);padding:18px;">' +
        '<div style="display:flex;align-items:center;margin-bottom:8px;">' +
        '<h2 style="margin:0;font-size:13px;flex:1;">Apply to ' + escHtml(ctx.file) +
        ' <span style="color:var(--text-dim);font-weight:400;">lines ' + ctx.loc.first + '–' + ctx.loc.last + '</span></h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#margin-diff-ov\').remove()">×</span></div>' +
        '<div style="display:flex;gap:10px;">' + pane('now', before, 'var(--text-dim)') +
        pane('proposed', replacement, 'var(--ollama)') + '</div>' +
        '<div id="margin-diff-err" style="font-size:11px;color:var(--accent-orange);min-height:16px;margin-top:6px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="this.closest(\'#margin-diff-ov\').remove()">Discard</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" id="margin-apply">Apply</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    document.getElementById('margin-apply').onclick = () => marginApply(ctx, replacement);
}

async function marginApply(ctx, replacement) {
    const err = document.getElementById('margin-diff-err');
    try {
        // Re-read and re-locate: between asking and applying, the file may have
        // been edited by you, by an agent, or by a chain. Splicing by the old
        // offset would then land in the wrong place, so a moved anchor stops the
        // write rather than guessing.
        const r = await (await fetch('files.php?action=read&project=' + encodeURIComponent(currentProject) +
                                     '&path=' + encodeURIComponent(ctx.file))).json();
        if (!r.ok) { err.textContent = 'Could not re-read the file: ' + (r.error || '?'); return; }
        const fresh = r.content || '';
        const loc = _marginLocate(fresh, ctx.selected);
        if (!loc) { err.textContent = T('msg.those.lines.no.longer.match.the.file.or.now', 'Those lines no longer match the file (or now appear more than once) — nothing was written.'); return; }

        const updated = fresh.slice(0, loc.index) + replacement + fresh.slice(loc.index + ctx.selected.length);
        const w = await (await fetch('files.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'write_file', project: currentProject, path: ctx.file, content: updated }),
        })).json();
        if (!w.ok) { err.textContent = 'Write failed: ' + (w.error || '?'); return; }
        document.getElementById('margin-diff-ov')?.remove();
        appendSystem(T('msg.icon.edit.note.margin.applied.to.file.lines', '[[icon:edit_note]] Margin applied to {file} (lines {first}–{last}).', {file: ctx.file, first: loc.first, last: loc.last}));
        if (typeof rpRefreshList === 'function') rpRefreshList('files');
        // rpRefreshList redraws the file LIST; the open preview kept showing the
        // text from before the edit until you clicked the file again, which reads
        // as "Margin did nothing". Re-render the viewer too, but only when it is
        // actually showing the file we just wrote.
        const shown = document.querySelector('[data-margin-file]');
        if (shown && shown.dataset.marginFile === ctx.file && typeof ftViewFile === 'function') {
            ftViewFile(ctx.file);
        }
    } catch (e) { err.textContent = e.message; }
}

document.addEventListener('DOMContentLoaded', marginInit);
