// =============================================================================
// Bookshelf — a book the agent can actually use.
//
// Converting a book was never the problem: pandoc reads epub/docx/odt/fb2 and
// calibre covers mobi and friends. The problem is scale. Over 50 KB of extracted
// text the agent gets a file path and a 1 KB preview — fine for an agent with
// file tools, useless for a local model.
//
// So a book is split into chapters and filed in the Library. push-RAG then pulls
// the chapter that matches the question and Receipts names it, which means a
// 400-page book works with a 7B model: it never sees more than the chapter it
// needs.
//
// The preview is shown before anything is written, because a bad split (a book
// with no headings, a PDF that extracts as one blob) is obvious in a chapter
// list and invisible afterwards.
// =============================================================================

async function bookshelfOpen(prefillPath) {
    document.getElementById('book-ov')?.remove();
    const ov = document.createElement('div');
    ov.id = 'book-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(620px,94vw);padding:18px;">' +
        '<div style="display:flex;align-items:center;margin-bottom:8px;">' +
        '<h2 style="margin:0;font-size:13px;flex:1;">' +
        '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">auto_stories</span> Bookshelf</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#book-ov\').remove()">×</span></div>' +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-bottom:6px;">' +
        'Split a book into chapters and file them in the Library, so questions pull the right chapter instead of the whole book. ' +
        'epub, pdf, docx, odt, fb2, txt — and mobi/azw3 when calibre is installed.</div>' +
        '<label style="font-size:10.5px;color:var(--text-muted);">Path to the book</label>' +
        '<input id="book-path" value="' + escAttr(prefillPath || '') + '" placeholder="/home/you/Books/thing.epub" ' +
        'style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:6px;font-size:11.5px;font-family:var(--font-mono);">' +
        '<label style="font-size:10.5px;color:var(--text-muted);margin-top:6px;display:block;">Title (optional)</label>' +
        '<input id="book-title" placeholder="taken from the filename" ' +
        'style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:6px;font-size:11.5px;">' +
        // Picking the file is the permission: the browser sends the bytes and
        // Cockpit stores them in its own folder, so no path from this dialog is
        // ever opened on the user's disk. The path field below stays for
        // libraries too big to copy.
        '<div style="display:flex;align-items:center;gap:8px;margin-top:7px;">' +
        '<button class="action-btn" onclick="bookshelfBrowse()">Browse…</button>' +
        '<span style="font-size:10px;color:var(--text-dim);">or type a path above</span>' +
        '<input type="file" id="book-file" style="display:none" ' +
        'accept=".epub,.pdf,.docx,.odt,.fb2,.rtf,.html,.htm,.txt,.md,.mobi,.azw3" ' +
        'onchange="bookshelfUpload(this.files[0])">' +
        '</div>' +
        '<div id="book-state" style="font-size:11px;color:var(--text-dim);min-height:16px;margin-top:8px;"></div>' +
        '<div id="book-list" style="display:none;max-height:240px;overflow:auto;background:var(--bg-darker);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:7px;font-size:11px;margin-bottom:8px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="this.closest(\'#book-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" id="book-preview-btn" onclick="bookshelfPreview()">Preview chapters</button>' +
        '<button class="action-btn" id="book-add-btn" style="background:var(--accent-blue);color:#fff;display:none;" onclick="bookshelfIngest()">Add to Library</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    document.getElementById('book-path').focus();
}

// Browse. In the Cockpit window this is the real GTK file chooser and returns an
// absolute path, so a large book is read where it lies instead of being copied;
// if that path is outside the folders Bookshelf may read, the refusal offers to
// add it. A plain browser has no such thing as a path -- its file dialog hands
// over bytes -- so there it falls back to the upload route.
async function bookshelfBrowse() {
    const state = document.getElementById('book-state');
    // Reopen where you were last time: a library is one folder you return to,
    // and re-navigating four levels of it every time is the kind of small tax
    // nobody reports but everybody feels.
    let lastDir = '';
    try { lastDir = localStorage.getItem('cockpit_book_lastdir') || ''; } catch (e) {}
    let paths = null;
    try {
        paths = await shellPickFiles(lastDir ? { title: 'Choose a book', dir: lastDir }
                                             : { title: 'Choose a book' });
    } catch (e) { paths = null; }
    if (paths === null) { document.getElementById('book-file').click(); return; }   // not in the shell
    if (!paths.length) return;                                                       // cancelled
    const p = paths[0];
    try { localStorage.setItem('cockpit_book_lastdir', p.replace(/\/[^/]*$/, '')); } catch (e) {}
    document.getElementById('book-path').value = p;
    const title = document.getElementById('book-title');
    if (title && !title.value) title.value = p.split('/').pop().replace(/\.[^.]+$/, '');
    if (state) state.textContent = T('msg.reading.chapters', 'reading chapters…');
    bookshelfPreview();
}

// Read the chosen file in the browser and hand Cockpit the bytes. Chunked
// base64 because btoa on a 40 MB string via apply() blows the argument limit.
async function bookshelfUpload(file) {
    if (!file) return;
    const state = document.getElementById('book-state');
    const path  = document.getElementById('book-path');
    const title = document.getElementById('book-title');
    if (file.size > 80 * 1024 * 1024) { state.textContent = T('msg.too.large.80.mb.limit', 'Too large (80 MB limit)'); return; }
    state.textContent = 'reading ' + file.name + '…';
    try {
        const buf = new Uint8Array(await file.arrayBuffer());
        let bin = '';
        for (let i = 0; i < buf.length; i += 0x8000) {
            bin += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000));
        }
        state.textContent = T('msg.copying.into.cockpit', 'copying into Cockpit…');
        const r = await (await fetch('bookshelf.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'upload', filename: file.name, data_b64: btoa(bin) }),
        })).json();
        if (!r.ok) { state.textContent = r.error || 'upload failed'; return; }
        path.value = r.path;
        if (title && !title.value) title.value = file.name.replace(/\.[^.]+$/, '');
        state.textContent = 'copied (' + Math.round(r.bytes / 1024) + ' KB) — reading chapters…';
        bookshelfPreview();
    } catch (e) { state.textContent = e.message; }
}

async function bookshelfPreview() {
    const path  = (document.getElementById('book-path') || {}).value || '';
    const state = document.getElementById('book-state');
    const list  = document.getElementById('book-list');
    if (!path.trim()) { state.textContent = T('msg.give.the.path.to.a.book.first', 'Give the path to a book first.'); return; }
    state.textContent = T('msg.converting.and.splitting', 'converting and splitting…');
    try {
        const d = await (await fetch('bookshelf.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'preview', path: path.trim(),
                                   title: (document.getElementById('book-title') || {}).value || '' }),
        })).json();
        if (!d.ok) {
            list.style.display = 'none';
            // A refusal that names the folders AND offers to add this one, rather
            // than leaving the user to guess where a book is allowed to live.
            if (d.suggest) {
                state.innerHTML = '';
                state.append(d.error + ' ');
                const b = document.createElement('button');
                b.className = 'action-btn';
                b.style.cssText = 'font-size:10px;padding:2px 7px;margin-left:4px;';
                b.textContent = 'Allow ' + d.suggest;
                b.onclick = async () => {
                    b.disabled = true;
                    const r = await (await fetch('bookshelf.php', {
                        method: 'POST', headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ action: 'roots_add', dir: d.suggest }),
                    })).json();
                    if (!r.ok) { state.textContent = r.error || 'could not allow that folder'; return; }
                    state.textContent = T('msg.allowed.reading', 'Allowed. Reading…');
                    bookshelfPreview();
                };
                state.append(b);
                const note = document.createElement('div');
                note.style.cssText = 'font-size:9.5px;color:var(--text-dim);margin-top:4px;';
                note.textContent = 'Bookshelf reads only inside: ' + (d.roots || []).join('  ·  ');
                state.append(note);
            } else {
                state.textContent = d.error || 'failed';
            }
            return;
        }
        state.textContent = d.title + ' · ' + d.chapters.length + ' chapter(s) · ' +
                            Math.round(d.total_bytes / 1024) + ' KB via ' + d.converter;
        list.style.display = 'block';
        list.innerHTML = d.chapters.map((c, i) =>
            '<div style="display:flex;gap:8px;"><span style="color:var(--text-dim);width:22px;">' + (i + 1) + '</span>' +
            '<span style="flex:1;">' + escHtml(c.title) + '</span>' +
            '<span style="color:var(--text-dim);">' + Math.round(c.bytes / 1024) + ' KB</span></div>').join('');
        document.getElementById('book-add-btn').style.display = '';
    } catch (e) { state.textContent = e.message; }
}

async function bookshelfIngest() {
    const path  = (document.getElementById('book-path') || {}).value || '';
    const title = (document.getElementById('book-title') || {}).value || '';
    const state = document.getElementById('book-state');
    const btn   = document.getElementById('book-add-btn');
    btn.disabled = true; state.textContent = T('msg.filing.chapters', 'filing chapters…');
    try {
        const d = await (await fetch('bookshelf.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'ingest', path: path.trim(), title: title }),
        })).json();
        if (!d.ok) { state.textContent = d.error || 'failed'; btn.disabled = false; return; }
        document.getElementById('book-ov')?.remove();
        appendSystem(T('msg.icon.auto.stories.title.filed.as.chapters.ch', '[[icon:auto_stories]] "{title}" filed as {chapters} chapter(s) in the Library — ask a question and the matching chapter comes with it.', {title: d.title, chapters: d.chapters}));
        if (typeof rpRefreshList === 'function') rpRefreshList('library');
    } catch (e) { state.textContent = e.message; btn.disabled = false; }
}
