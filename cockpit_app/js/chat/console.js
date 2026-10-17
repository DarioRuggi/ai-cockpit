// =============================================================================
// appendMsg — add a labeled message to the console
// =============================================================================
// ── Receipts ─────────────────────────────────────────────────────────────────
// push-RAG asks the agent to end with "SOURCES: a | b" naming the knowledge items
// it actually used. Injected context is otherwise unverifiable: a confident
// answer arrives and nobody can tell which note it leaned on, or whether it used
// any at all. The line is lifted out of the body and shown as chips that open the
// item, so an answer can be checked against what it claims to have read.
function _extractReceipts(body) {
    if (!body) return { body: body, sources: [] };
    const m = body.match(/\n?\s*SOURCES:\s*([^\n]+)\s*$/i);
    if (!m) return { body: body, sources: [] };
    const names = m[1].split('|').map(x => x.trim())
                      .filter(x => x && !/^←/.test(x) && x.length < 120);
    if (!names.length) return { body: body, sources: [] };
    return { body: body.slice(0, m.index).replace(/\s+$/, ''), sources: names };
}

function appendMsg(cssClass, label, tagClass, body, timestamp, duration, model, msgId) {
    // the hidden date line Cockpit adds for the model ("(Now: <date> <time> <weekday>, <time zone>)") is part of what is SENT and SAVED,
    // not something the person typed: it is not shown back to them
    if (cssClass === 'dario' && typeof body === 'string') body = body.replace(/\n\n\(Now: [^)\n]*\)\s*$/, '');
    const _rc = _extractReceipts(body);
    body = _rc.body;
    const div = document.createElement('div');
    div.className = 'msg msg-' + cssClass;
    if (msgId) div.id = msgId;
    msgCounter++;
    const lineNum = document.createElement('span');
    lineNum.className = 'msg-linenum';
    lineNum.textContent = msgCounter;
    div.appendChild(lineNum);

    const ts       = timestamp ? formatTime(timestamp) : '';
    const durStr   = duration  ? ' · ' + duration : '';
    const modelStr = model     ? '<span class="msg-model"> · ' + escHtml(model) + '</span>' : '';

    // Content wrapper — gets the border-left color (works in both normal and line-number mode)
    const contentWrap = document.createElement('div');
    contentWrap.style.borderLeftColor = cssClass === 'dario'
        ? 'var(--warm)' : cssClass === 'claude'
        ? 'var(--claude)' : cssClass === 'gemini'
        ? 'var(--gemini)' : cssClass === 'ollama'
        ? 'var(--ollama)' : 'var(--border-mid)';
    contentWrap.className = 'msg-wrap';
    contentWrap.style.setProperty('--msg-accent', contentWrap.style.borderLeftColor);
    contentWrap.innerHTML =
        '<div class="msg-header" onclick="if(!event.target.closest(\'.msg-action-btn,button,a\'))this.closest(\'.msg\').classList.toggle(\'msg-collapsed\')" title="Click to fold / unfold">' +
            '<span class="msg-fold material-symbols-rounded">expand_more</span>' +
            '<span class="msg-tag tag-' + tagClass + '">' + iconTokens(escHtml(label)) + '</span>' +
            modelStr +
            '<span class="msg-meta">' + ts + durStr + '</span>' +
            // F2/F3: Save to Snippets / Library buttons on agent messages only
            (['claude','gemini','ollama','worker'].includes(cssClass) ?
                '<span style="flex:1;"></span>' +
                '<span class="msg-action-btn" title="Save selected text (or full response) to Snippets" ' +
                'onclick="saveResponseToLibrary(this,\'snippet\')" style="cursor:pointer;opacity:0.6;margin-left:6px;font-size:11px;"><span class="material-symbols-rounded ico">content_paste</span></span>' +
                '<span class="msg-action-btn" title="Save selected text (or full response) to Library" ' +
                'onclick="saveResponseToLibrary(this,\'library\')" style="cursor:pointer;opacity:0.6;margin-left:4px;font-size:11px;"><span class="material-symbols-rounded ico">library_books</span></span>' +
                '<span class="msg-action-btn" title="Remember this about me (adds a line to your Profile)" ' +
                'onclick="profileRemember(this)" style="cursor:pointer;opacity:0.6;margin-left:4px;font-size:11px;"><span class="material-symbols-rounded" style="font-size:12px;">badge</span></span>'
                : '') +
        '</div>' +
        '<div class="msg-body" dir="auto">' + (body ? iconTokens(renderMarkdown(escHtml(body))) : '') + '</div>' +
        (_rc.sources.length
            ? '<div class="msg-receipts" style="margin:4px 0 2px 0;display:flex;flex-wrap:wrap;gap:4px;align-items:center;">' +
              '<span style="font-size:9.5px;color:var(--text-dim);" title="Knowledge items this answer says it used">' +
              '<span class="material-symbols-rounded" style="font-size:11px;vertical-align:-2px;">menu_book</span> used</span>' +
              _rc.sources.map(n =>
                  '<span onclick="receiptOpen(' + JSON.stringify(n).replace(/"/g, '&quot;') + ')" ' +
                  'title="Open this item in the Library" ' +
                  'style="cursor:pointer;font-size:9.5px;padding:1px 6px;border-radius:9px;' +
                  'background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);">' +
                  escHtml(n) + '</span>').join('') +
              '</div>'
            : '');

    div.appendChild(contentWrap);
    consoleBox.appendChild(div);
    consoleBox.scrollTop = consoleBox.scrollHeight;

    // ── Auto-extract code blocks from agent responses into the Code panel ──
    // Only fire for agent responses, not for streaming placeholders (those
    // call rpExtractCodeBlocks themselves once streaming completes).
    if (!msgId && ['claude','gemini','ollama'].includes(cssClass) &&
        typeof rpExtractCodeBlocks === 'function' && body) {
        rpExtractCodeBlocks(body, cssClass);
    }
    if (!msgId && ['claude','gemini','ollama'].includes(cssClass) &&
        typeof rpParseProposals === 'function' && body) {
        rpParseProposals(body, cssClass);
    }
}

// Update the bottom status bar (Cockpit announcements / transient status).
function iconTokens(s) {   // [[icon:name]] / [[icon:name.fill]] → monochrome Material Symbol (after escaping)
    return s.replace(/\[\[icon:([a-z_]+)(\.fill)?\]\]/g, (m, n, fill) => '<span class="material-symbols-rounded ico' + (fill ? ' ico-fill' : '') + '">' + n + '</span>');
}
function stripIconTokens(s) { return String(s).replace(/\[\[icon:[a-z_.]+\]\]\s?/g, ''); }
function setStatusBar(text) {
    const el = document.getElementById('status-bar-msg');
    if (el) el.textContent = stripIconTokens(text);
}
function appendSystem(text) {
    setStatusBar(text);   // mirror the latest system line into the status bar
    const div = document.createElement('div');
    div.className = 'msg msg-system';
    msgCounter++;
    const ln = document.createElement('span');
    ln.className = 'msg-linenum'; ln.textContent = msgCounter;
    div.appendChild(ln);
    const cw = document.createElement('div');
    cw.style.borderLeftColor = 'var(--border-mid)';
    cw.innerHTML =
        '<div class="msg-header"><span class="msg-tag tag-system">System</span>' +
        '<span class="msg-meta">' + formatTime(new Date()) + '</span></div>' +
        '<div class="msg-body" style="color:var(--text-muted)">' + iconTokens(escHtml(text)) + '</div>';
    div.appendChild(cw);
    consoleBox.appendChild(div);
    consoleBox.scrollTop = consoleBox.scrollHeight;
    clearTimeout(window._sysFoldTimer);
    window._sysFoldTimer = setTimeout(_foldSystemMessages, 500);
}

function appendError(text) {
    const div = document.createElement('div');
    div.className = 'msg msg-error';
    div.innerHTML =
        '<div class="msg-header"><span class="msg-tag tag-error">Error</span>' +
        '<span class="msg-meta">' + formatTime(new Date()) + '</span></div>' +
        '<div class="msg-body" style="color:#c0724a">' + iconTokens(escHtml(text)) + '</div>';
    consoleBox.appendChild(div);
    consoleBox.scrollTop = consoleBox.scrollHeight;
}

function _checkSpendWarnings(d) {
    if (d && Array.isArray(d.spend_warnings)) {
        d.spend_warnings.forEach(w => appendSystem(T('msg.icon.warning.spend.warning.w', '[[icon:warning]] SPEND WARNING: {w}', {w: w})));
    }
}

// =============================================================================
// F2/F3 — Save selected text (or full response) to Snippets / Library
//
// Triggered by the  /  buttons in agent message headers. The click handler
// passes the clicked element; we walk up to the message and pull the body text.
// If the user has selected text inside the message, that selection wins.
// =============================================================================
// Derive a clean title from free text: first non-empty line that is NOT a pure
// %%MARKER%% line (e.g. %%PROPOSE:snippet%%, %%WORKER:...%%), capped at 60 chars
// with leading markdown punctuation stripped. Shared by every save-title path so
// a derived title never starts with a cockpit marker line.
function _deriveTitleFromText(text, fallback) {
    const line = (String(text || '').split(/\n/).find(
        l => l.trim() !== '' && !/^%%[A-Z_]+[^%]*%%/.test(l.trim())
    ) || '').trim();
    return line.slice(0, 60).replace(/^[#*\->\s]+/, '') || (fallback || 'Untitled');
}

function saveResponseToLibrary(btn, kind) {
    // 'kind' is 'snippet' or 'library'
    const msg = btn.closest('.msg');
    const body = msg ? msg.querySelector('.msg-body') : null;
    if (!body) { appendError(T('msg.cannot.locate.message.body', 'Cannot locate message body')); return; }
    // If user has a selection inside the body, use that
    const sel = window.getSelection();
    let text = '';
    if (sel && !sel.isCollapsed) {
        const range = sel.getRangeAt(0);
        if (body.contains(range.commonAncestorContainer) || range.commonAncestorContainer === body) {
            text = sel.toString();
        }
    }
    if (!text) text = body.innerText || body.textContent || '';
    text = text.trim();
    if (!text) { appendError(T('msg.nothing.to.save', 'Nothing to save')); return; }
    // Detect language from fenced ```pascal etc.
    let lang = '';
    const fence = text.match(/^```([a-z0-9_+\-]+)/im);
    if (fence) lang = fence[1].toLowerCase();
    // Title: first non-empty, non-marker line, max 60 chars
    const defaultTitle = _deriveTitleFromText(text, 'Untitled');
    _showSaveLibraryDialog(kind, text, defaultTitle, lang);
}

function _showSaveLibraryDialog(kind, content, defaultTitle, defaultLang) {
    const isSnippet = (kind === 'snippet');
    const labelKind = isSnippet ? 'Snippets' : 'Library';
    // Build overlay (reuses inline modal style from elsewhere in the app)
    let ov = document.getElementById('save-lib-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'save-lib-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(620px,92vw);max-height:88vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<h2 style="margin:0 0 10px 0;font-size:14px;">Save to ' + labelKind + '</h2>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">Title' +
        '<input id="slib-title" type="text" value="' + escHtml(defaultTitle) + '"' +
        ' style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:5px 6px;font-size:12px;"></label>' +
        (isSnippet ?
            '<label style="font-size:11px;color:var(--text-muted);">Language' +
            '<input id="slib-lang" type="text" placeholder="pascal, php, bash, …" value="' + escHtml(defaultLang) + '"' +
            ' style="width:140px;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:5px 6px;font-size:12px;font-family:var(--font-mono);"></label>'
            : '<label style="font-size:11px;color:var(--text-muted);">Format/kind' +
            '<input id="slib-lang" type="text" placeholder="md, txt, html, …" value="md"' +
            ' style="width:140px;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:5px 6px;font-size:12px;font-family:var(--font-mono);"></label>') +
        '<label style="font-size:11px;color:var(--text-muted);">Notes (optional)' +
        '<input id="slib-notes" type="text" placeholder="why save this, where to use…"' +
        ' style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:5px 6px;font-size:12px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Content (' + content.length + ' chars)' +
        '<textarea id="slib-content" rows="10"' +
        ' style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);padding:5px 6px;font-size:11px;font-family:var(--font-mono);resize:vertical;">' +
        escHtml(content) + '</textarea></label>' +
        '<label style="font-size:11px;color:var(--text-muted);display:flex;align-items:center;gap:6px;">' +
        '<input id="slib-scope-project" type="checkbox" checked>' +
        'Save under current project (' + escHtml(currentProject || 'default') + ')</label>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:8px;">' +
        '<button class="rp-action-btn" id="slib-cancel">Cancel</button>' +
        '<button class="rp-action-btn" id="slib-save" style="background:var(--bg-active);">Save to ' + labelKind + '</button>' +
        '</div></div></div>';
    document.body.appendChild(ov);
    document.getElementById('slib-cancel').onclick = () => ov.remove();
    ov.onclick = e => { if (e.target === ov) ov.remove(); };
    document.getElementById('slib-save').onclick = async () => {
        const title  = document.getElementById('slib-title').value.trim() || defaultTitle;
        const lang   = document.getElementById('slib-lang').value.trim();
        const notes  = document.getElementById('slib-notes').value.trim();
        const ct     = document.getElementById('slib-content').value;
        const scoped = document.getElementById('slib-scope-project').checked;
        const proj   = scoped ? (currentProject || '') : '';
        // Use the existing proposal pipeline — same path that %%PROPOSE%% takes.
        // Approving it directly via library.php:proposal_act is the equivalent
        // of "save now" without a review step.
        try {
            const r = await fetch('library.php?action=add_proposal', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({
                    kind:     kind,       // 'snippet' or 'library'
                    proposer: 'user',
                    project:  proj,
                    payload:  { title:title, lang:lang, content:ct, notes:notes }
                })
            });
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error||'')})); return; }
            // Auto-approve so it lands in the index immediately
            const r2 = await fetch('library.php?action=proposal_act', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({ action:'proposal_act', id:d.id, act:'approve', target_scope: proj ? 'project' : 'global' })
            });
            const d2 = await r2.json();
            if (!d2.ok) { appendError(T('msg.approve.failed.error.proposal.saved.for.manu', 'Approve failed: {error} (proposal saved for manual review)', {error: (d2.error||'')})); }
            else appendSystem(T('msg.saved.to.issnippet.title', 'Saved to {issnippet}: {title}', {issnippet: (isSnippet?'Snippets':'Library'), title: title}));
            ov.remove();
            // Refresh the right panel if it's currently showing the matching list
            if (typeof rpRefreshList === 'function') {
                rpRefreshList(isSnippet ? 'snippets' : 'library');
            }
            if (typeof rpRefreshProposals === 'function') rpRefreshProposals();
        } catch(e) { appendError(T('msg.save.failed.message', 'Save failed: {message}', {message: e.message})); }
    };
}

// F2/F3: also wire a "save selected" via the prompt textarea (right-click context menu)
function _wirePromptSaveContextMenu() {
    if (!promptInput) return;
    promptInput.addEventListener('contextmenu', e => {
        const sel = promptInput.value.substring(promptInput.selectionStart, promptInput.selectionEnd);
        const hasSel = sel && sel.trim() !== '';
        const items = [];
        if (hasSel) {
            items.push({ label: 'Cut', icon: 'content_cut', action: () => { navigator.clipboard.writeText(sel); promptInput.setRangeText('', promptInput.selectionStart, promptInput.selectionEnd, 'end'); } });
            items.push({ label: 'Copy', icon: 'content_copy', action: () => navigator.clipboard.writeText(sel) });
        }
        items.push({ label: 'Paste', icon: 'content_paste', action: () => navigator.clipboard.readText().then(t => { promptInput.setRangeText(t, promptInput.selectionStart, promptInput.selectionEnd, 'end'); }) });
        items.push({ label: 'Select All', icon: 'select_all', action: () => promptInput.select() });
        if (hasSel) {
            items.push('---');
            items.push({ label: 'Save to Snippets', icon: 'bookmark', action: () => _showSaveLibraryDialog('snippet', sel, sel.split('\n')[0].slice(0,60) || 'Snippet', '') });
            items.push({ label: 'Save to Library', icon: 'library_books', action: () => _showSaveLibraryDialog('library', sel, sel.split('\n')[0].slice(0,60) || 'Library entry', 'md') });
        }
        cockpitContextMenu(e, items);
    });
}
// Wire on DOM ready (idempotent)
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', _wirePromptSaveContextMenu);
} else {
    _wirePromptSaveContextMenu();
}

// Generic Cockpit context menu for any input/textarea (replaces native menu).
function _wireFieldCtxMenu(el, withSave) {
    if (!el || el._ctxWired) return;
    el._ctxWired = true;
    el.addEventListener('contextmenu', e => {
        const sel = el.value.substring(el.selectionStart, el.selectionEnd);
        const hasSel = sel && sel.trim() !== '';
        const items = [];
        if (hasSel) {
            items.push({ label: 'Cut', icon: 'content_cut', action: () => { navigator.clipboard.writeText(sel); el.setRangeText('', el.selectionStart, el.selectionEnd, 'end'); } });
            items.push({ label: 'Copy', icon: 'content_copy', action: () => navigator.clipboard.writeText(sel) });
        }
        items.push({ label: 'Paste', icon: 'content_paste', action: () => navigator.clipboard.readText().then(t => el.setRangeText(t, el.selectionStart, el.selectionEnd, 'end')) });
        items.push({ label: 'Select All', icon: 'select_all', action: () => el.select() });
        if (withSave && hasSel) {
            items.push('---');
            items.push({ label: 'Save to Snippets', icon: 'bookmark', action: () => _showSaveLibraryDialog('snippet', sel, sel.split('\n')[0].slice(0,60) || 'Snippet', '') });
            items.push({ label: 'Save to Library', icon: 'library_books', action: () => _showSaveLibraryDialog('library', sel, sel.split('\n')[0].slice(0,60) || 'Library entry', 'md') });
        }
        cockpitContextMenu(e, items);
    });
}
function _wireNotesFieldMenus() {
    _wireFieldCtxMenu(document.getElementById('note-title'), false);
    _wireFieldCtxMenu(document.getElementById('note-tags'), false);
    _wireFieldCtxMenu(document.getElementById('note-body'), true);
}
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', _wireNotesFieldMenus);
else _wireNotesFieldMenus();


// Open the library item a receipt names. The chip carries the TITLE (that is
// what the agent echoed back), so this filters the Library panel by it rather
// than pretending to have an id the model never saw.
function receiptOpen(name) {
    try {
        const tab = document.querySelector('.sidebar-vtab[onclick*="\'library\'"]');
        if (typeof switchTab === 'function') switchTab('right', 'library', tab || null);
        setTimeout(() => {
            const box = document.getElementById('rp-search-library');
            if (box) {
                box.value = name;
                box.dispatchEvent(new Event('input', { bubbles: true }));
                box.focus();
            }
            if (typeof appendSystem === 'function' && !box)
                appendSystem(T('msg.library.look.for.name', 'Library: look for "{name}".', {name: name}));
        }, 220);
    } catch (e) { if (typeof appendError === 'function') appendError(T('msg.could.not.open.the.library.message', 'Could not open the Library: {message}', {message: e.message})); }
}
