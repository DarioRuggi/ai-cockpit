// =============================================================================
// FILE TREE — load and render
// =============================================================================
async function loadFileTree() {
    const list = document.getElementById('filetree-list');
    list.innerHTML = '<div class="sidebar-empty">Loading...</div>';
    try {
        const res  = await fetch('files.php?action=tree&project=' + encodeURIComponent(currentProject));
        const data = await res.json();
        if (!data.ok) { list.innerHTML = '<div class="sidebar-empty">Error loading files.</div>'; return; }
        if (!data.tree.length) {
            list.innerHTML = '<div class="sidebar-empty">Project folder is empty.</div>';
            return;
        }
        list.innerHTML = '';
        renderTree(list, data.tree, '');
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Error loading file tree.</div>';
    }
}

// H3 — folio-gallery: show every image in the current project as a grid.
async function ftShowGallery() {
    if (!currentProject || currentProject === '_standalone') {
        appendSystem(T('msg.gallery.is.per.project.open.a.project.first', 'Gallery is per-project — open a project first (Projects tab).')); return;
    }
    // Flatten the project tree, collect image paths
    let tree = [];
    try {
        const r = await fetch('files.php?action=tree&project=' + encodeURIComponent(currentProject));
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.could.not.load.files', 'Could not load files.')); return; }
        tree = d.tree || [];
    } catch(e) { appendError(T('msg.gallery.load.failed.message', 'Gallery load failed: {message}', {message: e.message})); return; }
    const imgExts = ['png','jpg','jpeg','gif','webp','bmp','svg'];
    const images = [];
    (function walk(items, prefix) {
        items.forEach(it => {
            const rel = prefix + it.name;
            if (it.type === 'dir') { if (it.children) walk(it.children, rel + '/'); }
            else {
                const ext = (it.name.split('.').pop() || '').toLowerCase();
                if (imgExts.includes(ext)) images.push(rel);
            }
        });
    })(tree, '');

    let ov = document.getElementById('gallery-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'gallery-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.75);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    let grid = '';
    if (images.length === 0) {
        grid = '<div style="color:var(--text-muted);font-size:12px;padding:20px;text-align:center;">No images in this project.</div>';
    } else {
        grid = '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:8px;">' +
            images.map(rel => {
                const url = 'files.php?action=raw&project=' + encodeURIComponent(currentProject) +
                    '&path=' + encodeURIComponent(rel);
                return '<div style="border:1px solid var(--border-dim);border-radius:4px;overflow:hidden;background:var(--bg-darker,var(--bg-codeblock));">' +
                    '<img src="' + url + '" loading="lazy" title="' + escHtml(rel) + '" ' +
                    'onclick="window.open(this.src,\'_blank\')" ' +
                    'style="width:100%;height:120px;object-fit:contain;cursor:pointer;display:block;background:#000;">' +
                    '<div style="font-size:9px;color:var(--text-muted);padding:3px 5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' + escHtml(rel) + '">' + escHtml(rel) + '</div>' +
                    '</div>';
            }).join('') + '</div>';
    }
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(900px,94vw);max-height:90vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:12px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">grid_view</span> ' +
        'Gallery — ' + escHtml(currentProject) + ' (' + images.length + ')</h2>' +
        '<span class="rp-action-btn" id="gallery-close" style="cursor:pointer;">×</span></div>' +
        grid + '</div>';
    document.body.appendChild(ov);
    document.getElementById('gallery-close').onclick = () => ov.remove();
    ov.onclick = e => { if (e.target === ov) ov.remove(); };
}

function renderTree(container, items, prefix) {
    items.forEach(item => {
        const div = document.createElement('div');
        const relPath = prefix + item.name;

        if (item.type === 'dir') {
            div.className = 'ft-item ft-dir';
            div.innerHTML =
                '<span class="material-symbols-rounded">folder_open</span>' +
                escHtml(item.name);
            // Toggle children on click
            const children = document.createElement('div');
            children.className = 'ft-children sb-inactive-section';
            children.style.display = 'none';
            if (item.children.length) renderTree(children, item.children, relPath + '/');
            div.addEventListener('click', e => {
                e.stopPropagation();
                const willOpen = children.style.display === 'none';
                children.style.display = willOpen ? 'block' : 'none';
                div.querySelector('.material-symbols-rounded').textContent =
                    willOpen ? 'folder' : 'folder_open';
                // Promote opened folder, demote others at same level
                if (willOpen) {
                    Array.from(container.children).forEach(node => {
                        if (node.classList && node.classList.contains('ft-children') && node !== children) {
                            node.classList.remove('sb-active-section');
                            node.classList.add('sb-inactive-section');
                        }
                    });
                    container.querySelectorAll(':scope > .ft-dir.sb-item-with-section')
                        .forEach(n => n.classList.remove('sb-item-with-section'));
                    children.classList.remove('sb-inactive-section');
                    children.classList.add('sb-active-section');
                    div.classList.add('sb-item-with-section');
                } else {
                    children.classList.remove('sb-active-section');
                    children.classList.add('sb-inactive-section');
                    div.classList.remove('sb-item-with-section');
                }
            });
            container.appendChild(div);
            container.appendChild(children);
        } else {
            div.className = 'ft-item';
            const icon = ftIcon(item.ext);
            div.innerHTML =
                '<span class="material-symbols-rounded">' + icon + '</span>' +
                '<span style="flex:1;overflow:hidden;text-overflow:ellipsis;">' + escHtml(item.name) + '</span>' +
                '<span class="ft-action material-symbols-rounded mini-ctrl" ' +
                    'data-act="attach" ' +
                    'title="Attach reference to prompt" ' +
                    'style="color:var(--text-base);">attach_file</span>' +
                '<span class="ft-action material-symbols-rounded mini-ctrl" ' +
                    'data-act="delete" ' +
                    'title="Remove from project" ' +
                    'style="color:var(--text-base);">close</span>';
            // Click body opens viewer; clicks on action icons do their action
            div.addEventListener('click', e => {
                const act = e.target.dataset?.act;
                if (act === 'attach') { ftAttachToPrompt(relPath); return; }
                if (act === 'delete') { ftDelete(relPath); return; }
                ftViewFile(relPath);
            });
            container.appendChild(div);
        }
    });
}

function ftIcon(ext) {
    const map = {
        'pas':'code','pp':'code','lpr':'code','php':'code','sh':'terminal',
        'txt':'description','md':'description','json':'data_object',
        'html':'html','css':'css','js':'javascript','png':'image',
        'jpg':'image','gif':'image','pdf':'picture_as_pdf'
    };
    return map[ext?.toLowerCase()] || 'draft';
}

async function ftDelete(relPath) {
    if (!await cockpitConfirm('Remove file?', 'Remove "' + relPath + '" from project?', 'Remove', {danger:true, icon:'delete'})) return;
    await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'delete', project:currentProject, path:relPath})
    });
    loadFileTree();
}

async function ftNewFile() {
    // Open the floating editor in "new file" mode: a filename field + a language
    // dropdown (which also sets the suffix), an empty highlighted code area, and a
    // Save that writes the file into the current project.
    openFloatingEditor({
        id: 'ft-new-' + Date.now(),
        heading: 'New file',
        filename: 'in ' + (currentProject || 'project'),
        content: '',
        language: 'txt',
        fields: [
            { key:'name', label:'File name (without suffix)', value:'untitled', placeholder:'untitled' },
            { key:'lang', label:'Language / suffix', type:'language', value:'txt' },
        ],
        onSave: async (content, vals) => {
            const base = (vals.name || '').trim().replace(/[\/\\]+/g, '_');
            const suffix = (vals.lang || 'txt').trim().replace(/^\./, '');
            if (!base) return { ok:false, error:'File name required' };
            // Don't double-append a suffix the user already typed into the name.
            const path = base.toLowerCase().endsWith('.' + suffix.toLowerCase())
                ? base : base + '.' + suffix;
            try {
                const r = await fetch('files.php', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({action:'write_file', project:currentProject, path, content})
                });
                const d = await r.json();
                if (!d.ok) return { ok:false, error: d.error || 'unknown' };
                appendSystem(T('msg.created.path.size.bytes', 'Created {path} ({size} bytes).', {path: path, size: (d.size || content.length)}));
                loadFileTree();
                return { ok:true };
            } catch(e) { return { ok:false, error: e.message }; }
        }
    });
}

async function ftNewFolder() {
    const name = await cprompt('New folder name:');
    if (!name || !name.trim()) return;
    await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'new_folder', project:currentProject, path:name.trim()})
    });
    loadFileTree();
}

// Attach file content to prompt textarea
// =============================================================================
// FLOATING CODE EDITOR — reusable draggable window
// =============================================================================
// One editor used by both the file tree (ftEditFile) and library/snippet/source
// editing. Dark, protanopia-safe (no colour-only signals). Draggable by header,
// resizable, with optional metadata fields above the code area.
//
// opts = {
//   id,        unique key (one window per key; reopening replaces it)
//   heading,   window title text
//   filename,  subtitle shown under the heading
//   content,   initial textarea content
//   fields,    optional [{key,label,value,placeholder}] metadata inputs
//   onSave,    async (content, fieldValues) => { ok:bool, error?:string }
// }
// Language presets for the editor dropdown. `value` is the file suffix / lang
// token the cockpit stores; the Prism grammar is derived from it via _prismLang.
const LANG_PRESETS = [
    { label: 'Pascal (.pas)',     value: 'pas'  },
    { label: 'PHP (.php)',        value: 'php'  },
    { label: 'Bash (.sh)',        value: 'sh'   },
    { label: 'JavaScript (.js)',  value: 'js'   },
    { label: 'JSON (.json)',      value: 'json' },
    { label: 'YAML (.yml)',       value: 'yml'  },
    { label: 'CSS (.css)',        value: 'css'  },
    { label: 'HTML (.html)',      value: 'html' },
    { label: 'Markdown (.md)',    value: 'md'   },
    { label: 'Plain text (.txt)', value: 'txt'  },
];

// Map a cockpit language label / file extension to a Prism grammar key.
// Returns null when there's no good match (editor falls back to plain text).
function _prismLang(s) {
    const x = String(s || '').toLowerCase().replace(/^\./, '').trim();
    const map = {
        pas:'pascal', pp:'pascal', lpr:'pascal', pascal:'pascal', delphi:'pascal',
        php:'php', phtml:'php', php5:'php',
        sh:'bash', bash:'bash', zsh:'bash',
        js:'javascript', mjs:'javascript', cjs:'javascript', javascript:'javascript',
        json:'json', json5:'json5', jsonc:'json',
        yml:'yaml', yaml:'yaml',
        css:'css',
        html:'markup', htm:'markup', xml:'markup', svg:'markup', md:'markup',
    };
    return map[x] || null;
}

function openFloatingEditor(opts) {
    const winId = 'float-editor-' + (opts.id || 'default');
    const existing = document.getElementById(winId);
    if (existing) existing.remove();

    const win = document.createElement('div');
    win.id = winId;
    win.style.cssText =
        'position:fixed;top:14%;left:50%;transform:translateX(-50%);' +
        'width:min(760px,92vw);height:min(620px,80vh);z-index:10001;' +
        'display:flex;flex-direction:column;background:var(--bg-base);' +
        'border:1px solid var(--border-mid);border-radius:6px;' +
        'box-shadow:0 10px 40px rgba(0,0,0,0.6);font-family:var(--font-ui);overflow:hidden;';

    // above the OS-style windows (ckwindow.js) and back on top whenever it is clicked
    const _raiseEd = () => { if (window.ckNextZ) win.style.zIndex = ckNextZ(); };
    _raiseEd(); win.addEventListener('mousedown', _raiseEd, true);

    // ── Header (drag handle) ──
    const header = document.createElement('div');
    header.style.cssText =
        'display:flex;align-items:center;gap:8px;padding:8px 12px;cursor:move;' +
        'background:var(--bg-darker,rgba(255,255,255,0.04));' +
        'border-bottom:1px solid var(--border-dim);user-select:none;flex-shrink:0;';
    header.innerHTML =
        '<span class="material-symbols-rounded" style="font-size:16px;color:var(--accent-cyan);">edit_document</span>' +
        '<div style="flex:1;min-width:0;">' +
            '<div style="font-size:12px;font-weight:600;color:var(--text-base);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">' +
                escHtml(opts.heading || 'Editor') + '</div>' +
            (opts.filename ? '<div style="font-size:10px;color:var(--text-muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-family:var(--font-mono);">' +
                escHtml(opts.filename) + '</div>' : '') +
        '</div>';
    const closeBtn = document.createElement('span');
    closeBtn.className = 'material-symbols-rounded';
    closeBtn.style.cssText = 'font-size:18px;cursor:pointer;color:var(--text-base);';
    closeBtn.title = T('msg.close.editor', 'Close editor');
    closeBtn.textContent = T('msg.close', 'close');
    closeBtn.onclick = () => win.remove();
    header.appendChild(closeBtn);
    win.appendChild(header);

    // ── Optional metadata fields ──
    // Field types: 'text' (default), 'select' ({options}), and 'language'
    // (preset dropdown + "Custom…" suffix input). Each entry in fieldEls exposes
    // a `.value` and `.addEventListener` so the rest of the editor is type-agnostic.
    const fieldEls = {};
    if (Array.isArray(opts.fields) && opts.fields.length) {
        const fieldWrap = document.createElement('div');
        fieldWrap.style.cssText =
            'display:flex;flex-wrap:wrap;gap:8px;padding:8px 12px;' +
            'border-bottom:1px solid var(--border-dim);flex-shrink:0;';
        const _ctrlCss = 'background:var(--bg-darker);border:1px solid var(--border-dim);' +
            'color:var(--text-base);font-size:11px;padding:4px 6px;border-radius:3px;';
        opts.fields.forEach(f => {
            const lab = document.createElement('label');
            lab.style.cssText = 'display:flex;flex-direction:column;gap:2px;font-size:10px;color:var(--text-muted);flex:1;min-width:120px;';
            lab.textContent = f.label || f.key;

            if (f.type === 'language') {
                // Dropdown of presets + "Custom…" → reveals a free suffix input.
                const row = document.createElement('div');
                row.style.cssText = 'display:flex;gap:5px;';
                const sel = document.createElement('select');
                sel.style.cssText = _ctrlCss + 'flex:1;';
                LANG_PRESETS.forEach(p => {
                    const o = document.createElement('option'); o.value = p.value; o.textContent = p.label; sel.appendChild(o);
                });
                const customOpt = document.createElement('option'); customOpt.value = '__custom__'; customOpt.textContent = T('msg.custom', 'Custom…'); sel.appendChild(customOpt);
                const custom = document.createElement('input');
                custom.type = 'text'; custom.placeholder = T('msg.suffix', 'suffix'); custom.maxLength = 12;
                custom.style.cssText = _ctrlCss + 'width:70px;display:none;';
                // Initialise: preset match → select it; else Custom + fill input.
                const initVal = (f.value || '').toLowerCase();
                if (initVal && LANG_PRESETS.some(p => p.value === initVal)) {
                    sel.value = initVal;
                } else if (initVal) {
                    sel.value = '__custom__'; custom.value = initVal; custom.style.display = '';
                } else {
                    sel.value = 'txt';   // nothing chosen yet: plain text (the first entry of the list is Pascal, a poor default for most snippets)
                }
                const _emit = () => sel.dispatchEvent(new Event('cockpit-langchange'));
                sel.addEventListener('change', () => {
                    custom.style.display = (sel.value === '__custom__') ? '' : 'none';
                    if (sel.value === '__custom__') custom.focus();
                    _emit();
                });
                custom.addEventListener('input', _emit);
                row.append(sel, custom);
                lab.appendChild(row);
                fieldWrap.appendChild(lab);
                // Wrapper exposing a unified value + change subscription.
                fieldEls[f.key] = {
                    get value() { return sel.value === '__custom__' ? custom.value.trim() : sel.value; },
                    addEventListener(_ev, cb) { sel.addEventListener('cockpit-langchange', cb); },
                };
            } else if (f.type === 'select') {
                const sel = document.createElement('select');
                sel.style.cssText = _ctrlCss;
                (f.options || []).forEach(o => {
                    const opt = document.createElement('option');
                    opt.value = (typeof o === 'object') ? o.value : o;
                    opt.textContent = (typeof o === 'object') ? (o.label || o.value) : o;
                    sel.appendChild(opt);
                });
                if (f.value != null) sel.value = f.value;
                lab.appendChild(sel);
                fieldWrap.appendChild(lab);
                fieldEls[f.key] = sel;
            } else {
                const inp = document.createElement('input');
                inp.type = 'text';
                inp.value = f.value || '';
                if (f.placeholder) inp.placeholder = f.placeholder;
                inp.style.cssText = _ctrlCss;
                lab.appendChild(inp);
                fieldWrap.appendChild(lab);
                fieldEls[f.key] = inp;
            }
        });
        win.appendChild(fieldWrap);
    }

    // ── Toolbar (find / line-numbers / wrap toggles) ──
    let gutterOn = true, wrapOn = false;
    const toolbar = document.createElement('div');
    toolbar.style.cssText = 'display:flex;align-items:center;gap:6px;padding:5px 10px;border-bottom:1px solid var(--border-dim);flex-shrink:0;';
    const _mkToolBtn = (icon, label, title) => {
        const b = document.createElement('button');
        b.className = 'action-btn';
        b.style.cssText = 'padding:3px 8px;font-size:10px;display:flex;align-items:center;gap:3px;';
        b.innerHTML = '<span class="material-symbols-rounded" style="font-size:13px;">' + icon + '</span>' + label;
        b.title = title || label;
        return b;
    };
    const findToggleBtn = _mkToolBtn('search', 'Find', 'Find / replace (Ctrl+F)');
    const lineNumBtn    = _mkToolBtn('format_list_numbered', 'Lines', 'Show / hide line numbers');
    const wrapBtn       = _mkToolBtn('wrap_text', 'Wrap', 'Toggle word wrap');
    toolbar.append(findToggleBtn, lineNumBtn, wrapBtn);
    win.appendChild(toolbar);

    // ── Find / replace bar (hidden until toggled) ──
    const findBar = document.createElement('div');
    findBar.style.cssText = 'display:none;align-items:center;gap:5px;padding:5px 10px;flex-wrap:wrap;' +
        'border-bottom:1px solid var(--border-dim);background:var(--bg-darker,rgba(255,255,255,0.03));flex-shrink:0;';
    const _inpCss = 'background:var(--bg-base);border:1px solid var(--border-dim);color:var(--text-base);' +
        'font-size:11px;padding:3px 6px;border-radius:3px;font-family:var(--font-mono);';
    const findInput = document.createElement('input'); findInput.type='text'; findInput.placeholder=T('msg.find', 'Find');    findInput.style.cssText=_inpCss+'flex:1;min-width:90px;';
    const replInput = document.createElement('input'); replInput.type='text'; replInput.placeholder=T('msg.replace', 'Replace'); replInput.style.cssText=_inpCss+'flex:1;min-width:90px;';
    const findCount = document.createElement('span'); findCount.style.cssText='font-size:10px;color:var(--text-muted);min-width:58px;text-align:right;';
    const _mkMini = (icon, title) => { const b=document.createElement('button'); b.className='action-btn'; b.style.cssText='padding:3px 7px;'; b.title=title; b.innerHTML='<span class="material-symbols-rounded" style="font-size:13px;vertical-align:-2px;">'+icon+'</span>'; return b; };
    const prevBtn = _mkMini('keyboard_arrow_up', 'Previous (Shift+Enter)');
    const nextBtn = _mkMini('keyboard_arrow_down', 'Next (Enter)');
    const replOneBtn = document.createElement('button'); replOneBtn.className='action-btn'; replOneBtn.style.cssText='padding:3px 8px;font-size:10px;'; replOneBtn.textContent=T('msg.replace', 'Replace');
    const replAllBtn = document.createElement('button'); replAllBtn.className='action-btn'; replAllBtn.style.cssText='padding:3px 8px;font-size:10px;'; replAllBtn.textContent=T('msg.all', 'All');
    findBar.append(findInput, prevBtn, nextBtn, replInput, replOneBtn, replAllBtn, findCount);
    win.appendChild(findBar);

    // ── Code area: gutter + (highlight backdrop) + textarea ──
    const editorRow = document.createElement('div');
    editorRow.style.cssText = 'flex:1;display:flex;min-height:0;background:var(--bg-darker,var(--bg-codeblock));';
    const gutter = document.createElement('div');
    gutter.style.cssText = 'padding:10px 6px 10px 10px;margin:0;text-align:right;color:var(--text-muted);' +
        'font-family:var(--font-mono);font-size:12px;line-height:1.5;white-space:pre;overflow:hidden;' +
        'user-select:none;border-right:1px solid var(--border-dim);min-width:34px;box-sizing:border-box;';

    // Resolve a Prism grammar for the language (null → no highlighting).
    let plang = _prismLang(opts.language);
    let grammar = (window.Prism && plang && Prism.languages[plang]) ? Prism.languages[plang] : null;

    // codeWrap holds the absolute-positioned highlight backdrop + the textarea.
    const codeWrap = document.createElement('div');
    codeWrap.style.cssText = 'position:relative;flex:1;min-width:0;overflow:hidden;';
    const hlPre = document.createElement('pre');
    hlPre.className = 'float-hl-pre';
    hlPre.setAttribute('aria-hidden', 'true');
    hlPre.style.cssText += 'position:absolute;inset:0;overflow:auto;';
    const hlCode = document.createElement('code');
    hlPre.appendChild(hlCode);

    const area = document.createElement('textarea');
    area.spellcheck = false;
    area.value = opts.content || '';
    // When highlighting: textarea text is transparent (caret stays visible) so
    // the coloured backdrop shows through. Without a grammar: plain visible text.
    const _areaColor = grammar ? 'transparent' : 'var(--text-base)';
    area.style.cssText = 'position:relative;width:100%;height:100%;box-sizing:border-box;margin:0;padding:10px;' +
        'border:none;resize:none;background:transparent;color:' + _areaColor + ';caret-color:var(--text-base);' +
        'font-family:var(--font-mono);font-size:12px;line-height:1.5;outline:none;white-space:pre;overflow:auto;';
    if (grammar) codeWrap.appendChild(hlPre);
    codeWrap.appendChild(area);
    editorRow.append(gutter, codeWrap);
    win.appendChild(editorRow);

    function updateHighlight() {
        if (!grammar) return;
        // Trailing newline: append a space so Prism renders the final empty line.
        const txt = area.value.endsWith('\n') ? area.value + ' ' : area.value;
        hlCode.innerHTML = Prism.highlight(txt, grammar, plang);
        hlPre.scrollTop = area.scrollTop;
        hlPre.scrollLeft = area.scrollLeft;
    }
    function renderGutter() {
        if (!gutterOn) { gutter.style.display = 'none'; return; }
        gutter.style.display = 'block';
        const n = area.value.split('\n').length;
        let s = ''; for (let i = 1; i <= n; i++) s += i + '\n';
        gutter.textContent = s;
        gutter.scrollTop = area.scrollTop;
    }
    area.addEventListener('scroll', () => {
        gutter.scrollTop = area.scrollTop;
        if (grammar) { hlPre.scrollTop = area.scrollTop; hlPre.scrollLeft = area.scrollLeft; }
    });
    // Live re-language: if a "lang" metadata field exists, switching it updates
    // the grammar and re-highlights (useful for a brand-new snippet).
    if (fieldEls.lang) {
        fieldEls.lang.addEventListener('input', () => {
            plang = _prismLang(fieldEls.lang.value);
            grammar = (window.Prism && plang && Prism.languages[plang]) ? Prism.languages[plang] : null;
            if (grammar) {
                if (!hlPre.parentNode) codeWrap.insertBefore(hlPre, area);
                area.style.color = 'transparent';
                updateHighlight();
            } else {
                if (hlPre.parentNode) hlPre.remove();
                area.style.color = 'var(--text-base)';
            }
        });
    }

    // ── Footer ──
    const footer = document.createElement('div');
    footer.style.cssText = 'display:flex;align-items:center;gap:10px;padding:8px 12px;' +
        'border-top:1px solid var(--border-dim);flex-shrink:0;';
    const status = document.createElement('span');
    status.style.cssText = 'flex:1;font-size:11px;color:var(--text-muted);';
    const counter = document.createElement('span');
    counter.style.cssText = 'font-size:10px;color:var(--text-muted);';
    const _updCount = () => {
        const lines = area.value.split('\n').length;
        counter.textContent = lines + ' lines · ' + new Blob([area.value]).size + ' B';
    };
    area.addEventListener('input', () => { _updCount(); renderGutter(); updateHighlight(); });
    _updCount();
    renderGutter();
    updateHighlight();

    const _collectVals = () => { const v = {}; Object.keys(fieldEls).forEach(k => v[k] = fieldEls[k].value); return v; };
    const _runSave = async (fn) => {
        status.textContent = T('msg.saving', 'Saving…'); status.style.color = 'var(--text-muted)';
        try {
            const res = await (fn ? fn(area.value, _collectVals()) : Promise.resolve({ok:true}));
            if (res && res.ok === false) {
                status.textContent = 'Save failed: ' + (res.error || 'unknown');
                status.style.color = 'var(--accent-orange)';
                return;
            }
            status.textContent = T('msg.saved', 'Saved.'); status.style.color = 'var(--accent-cyan)';
            setTimeout(() => win.remove(), 600);
        } catch (e) {
            status.textContent = 'Save failed: ' + e.message;
            status.style.color = 'var(--accent-orange)';
        }
    };

    const cancelBtn = document.createElement('button');
    cancelBtn.className = 'action-btn';
    cancelBtn.style.cssText = 'padding:5px 14px;';
    cancelBtn.textContent = T('msg.cancel', 'Cancel');
    cancelBtn.onclick = () => win.remove();
    footer.append(status, counter);
    if (opts.onSaveAs) {
        const saveAsBtn = document.createElement('button');
        saveAsBtn.className = 'action-btn';
        saveAsBtn.style.cssText = 'padding:5px 14px;';
        saveAsBtn.innerHTML = '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-3px;">save_as</span> Save as…';
        saveAsBtn.onclick = () => _runSave(opts.onSaveAs);
        footer.appendChild(saveAsBtn);
    }
    const saveBtn = document.createElement('button');
    saveBtn.className = 'action-btn agent-claude';
    saveBtn.style.cssText = 'padding:5px 18px;';
    saveBtn.innerHTML = '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-3px;">save</span> Save';
    saveBtn.onclick = () => _runSave(opts.onSave);
    footer.append(cancelBtn, saveBtn);
    win.appendChild(footer);

    // ── Resize handle (bottom-right) ──
    const grip = document.createElement('div');
    grip.style.cssText = 'position:absolute;right:2px;bottom:2px;width:14px;height:14px;cursor:nwse-resize;' +
        'color:var(--text-muted);font-size:13px;line-height:14px;text-align:center;user-select:none;';
    grip.innerHTML = '<span class="material-symbols-rounded" style="font-size:13px;">resize</span>';
    win.appendChild(grip);

    document.body.appendChild(win);
    area.focus();

    // ── Toolbar / find behaviour ──
    lineNumBtn.onclick = () => { gutterOn = !gutterOn; renderGutter(); };
    wrapBtn.onclick     = () => { wrapOn = !wrapOn; area.style.whiteSpace = wrapOn ? 'pre-wrap' : 'pre'; };
    findToggleBtn.onclick = () => _toggleFind(findBar.style.display === 'none');
    function _toggleFind(show) {
        findBar.style.display = show ? 'flex' : 'none';
        if (show) { findInput.focus(); findInput.select(); _updFindCount(); } else { area.focus(); }
    }
    function _findAll(q) { if (!q) return []; const out=[]; let i=area.value.indexOf(q); while(i>=0){ out.push(i); i=area.value.indexOf(q, i+Math.max(1,q.length)); } return out; }
    function _updFindCount() { const q=findInput.value; findCount.textContent = q ? (_findAll(q).length + ' found') : ''; }
    function _doFind(dir) {
        const q = findInput.value; if (!q) return;
        const all = _findAll(q); if (!all.length) { findCount.textContent = T('msg.0.found', '0 found'); return; }
        const cur = area.selectionStart; let target;
        if (dir >= 0) { target = all.find(i => i >= cur + 1); if (target === undefined) target = all[0]; }
        else { const before = all.filter(i => i < cur); target = before.length ? before[before.length-1] : all[all.length-1]; }
        area.focus(); area.setSelectionRange(target, target + q.length);
        findCount.textContent = (all.indexOf(target)+1) + ' / ' + all.length;
    }
    function _replaceOne() {
        const q = findInput.value; if (!q) return;
        if (area.selectionStart !== area.selectionEnd &&
            area.value.substring(area.selectionStart, area.selectionEnd) === q) {
            const s = area.selectionStart;
            area.value = area.value.slice(0, s) + replInput.value + area.value.slice(area.selectionEnd);
            area.selectionStart = area.selectionEnd = s + replInput.value.length;
            _updCount(); renderGutter(); updateHighlight();
        }
        _doFind(1);
    }
    function _replaceAll() {
        const q = findInput.value; if (!q) return;
        const parts = area.value.split(q); const cnt = parts.length - 1;
        area.value = parts.join(replInput.value); _updCount(); renderGutter(); updateHighlight();
        findCount.textContent = cnt + ' replaced';
    }
    nextBtn.onclick = () => _doFind(1);
    prevBtn.onclick = () => _doFind(-1);
    replOneBtn.onclick = _replaceOne;
    replAllBtn.onclick = _replaceAll;
    findInput.addEventListener('input', _updFindCount);
    findInput.addEventListener('keydown', e => {
        if (e.key === 'Enter') { e.preventDefault(); _doFind(e.shiftKey ? -1 : 1); }
        if (e.key === 'Escape') { _toggleFind(false); }
    });

    // Tab inserts two spaces; Ctrl+F opens find; Esc closes it.
    area.addEventListener('keydown', e => {
        if (e.key === 'Tab') {
            e.preventDefault();
            const s = area.selectionStart, en = area.selectionEnd;
            area.value = area.value.slice(0, s) + '  ' + area.value.slice(en);
            area.selectionStart = area.selectionEnd = s + 2;
            _updCount(); renderGutter(); updateHighlight();
        }
        if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); _toggleFind(true); }
        if (e.key === 'Escape' && findBar.style.display !== 'none') { _toggleFind(false); }
    });

    // ── Drag + resize behaviour ──
    let dragX = 0, dragY = 0, dragging = false;
    let resizing = false, resX = 0, resY = 0, resW = 0, resH = 0;
    header.addEventListener('mousedown', e => {
        if (e.target === closeBtn) return;
        dragging = true;
        // Switch from transform-centering to explicit left/top on first drag.
        const r = win.getBoundingClientRect();
        win.style.transform = 'none';
        win.style.left = r.left + 'px';
        win.style.top  = r.top + 'px';
        dragX = e.clientX - r.left;
        dragY = e.clientY - r.top;
        e.preventDefault();
    });
    grip.addEventListener('mousedown', e => {
        resizing = true;
        const r = win.getBoundingClientRect();
        // Anchor top-left so resizing grows toward bottom-right predictably.
        win.style.transform = 'none';
        win.style.left = r.left + 'px';
        win.style.top  = r.top + 'px';
        resX = e.clientX; resY = e.clientY; resW = r.width; resH = r.height;
        e.preventDefault(); e.stopPropagation();
    });
    document.addEventListener('mousemove', _floatEditorMove);
    document.addEventListener('mouseup', _floatEditorUp);
    function _floatEditorMove(e) {
        if (dragging) {
            win.style.left = Math.max(0, Math.min(window.innerWidth  - 80, e.clientX - dragX)) + 'px';
            win.style.top  = Math.max(0, Math.min(window.innerHeight - 40, e.clientY - dragY)) + 'px';
        } else if (resizing) {
            win.style.width  = Math.max(360, resW + (e.clientX - resX)) + 'px';
            win.style.height = Math.max(220, resH + (e.clientY - resY)) + 'px';
            renderGutter();
        }
    }
    function _floatEditorUp() { dragging = false; resizing = false; }
    // Clean up listeners when the window is removed.
    const _obs = new MutationObserver(() => {
        if (!document.body.contains(win)) {
            document.removeEventListener('mousemove', _floatEditorMove);
            document.removeEventListener('mouseup', _floatEditorUp);
            _obs.disconnect();
        }
    });
    _obs.observe(document.body, { childList: true });

    return win;
}

// ---- the open file is watched (Lazarus / an agent / a chain can change it under the viewer) ----------
// Polls a cheap stat every 2.5 s while the viewer shows a file; when the mtime moves the viewer reloads
// itself, keeps its scroll position and says so. It waits while text in the viewer is selected (a Margin
// selection must not vanish) and while the window is hidden.
const _ftWatch = { rel: '', project: '', sig: '', timer: null, waiting: false };
function ftWatchStop() { if (_ftWatch.timer) clearInterval(_ftWatch.timer); _ftWatch.timer = null; _ftWatch.rel = ''; }
async function ftWatchStart(rel, mtime) {
    ftWatchStop(); _ftWatch.rel = rel; _ftWatch.project = currentProject; _ftWatch.sig = ''; _ftWatch.waiting = false;
    // take the baseline from the SAME stat the poll uses (read returns only mtime)
    try { const b = await (await fetch('files.php?action=stat&project=' + encodeURIComponent(currentProject) + '&path=' + encodeURIComponent(rel))).json(); if (b && b.ok) _ftWatch.sig = b.sig; } catch (e) {}
    _ftWatch.timer = setInterval(async function () {
        if (document.hidden) return;
        const pre = document.querySelector('#right-preview pre[data-margin-file]');
        if (!pre || pre.getAttribute('data-margin-file') !== _ftWatch.rel || currentProject !== _ftWatch.project) { ftWatchStop(); return; }
        let d; try { d = await (await fetch('files.php?action=stat&project=' + encodeURIComponent(_ftWatch.project) + '&path=' + encodeURIComponent(_ftWatch.rel))).json(); } catch (e) { return; }
        if (!d || !d.ok || !_ftWatch.sig || d.sig === _ftWatch.sig) return;
        const sel = window.getSelection ? String(window.getSelection()) : '';
        if (sel && pre.contains(window.getSelection().anchorNode)) { _ftWatch.waiting = true; return; }   // do not drop a selection
        const rel = _ftWatch.rel, top = pre.scrollTop;
        await ftViewFile(rel, { changed: true, scrollTop: top });
    }, 2500);
}
// ---- "Open in Lazarus" (Pascal / Lazarus files) ----------------------------------------------------------
const FT_LAZARUS_EXT = ['pas', 'pp', 'inc', 'lpr', 'lpi', 'lpk', 'lfm', 'lrs', 'dpr', 'dfm'];
let _ftLazAvail = null;
async function ftLazarusAvailable() {
    if (_ftLazAvail !== null) return _ftLazAvail;
    try { _ftLazAvail = !!(await (await fetch('launch_cli.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: 'lazarus_info' }) })).json()).available; }
    catch (e) { _ftLazAvail = false; }
    return _ftLazAvail;
}
async function ftOpenInLazarus(relPath) {
    try {
        const d = await (await fetch('launch_cli.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ mode: 'lazarus', project: currentProject, path: relPath }) })).json();
        if (!d.ok) { appendSystem(T('msg.lazarus.open.failed', 'Could not open Lazarus: {error}', { error: d.error || 'unknown' })); return; }
        appendSystem(T('msg.lazarus.opened', 'Opening in Lazarus: {files}. Changes you save there appear here by themselves.', { files: (d.opened || []).join(', ') }));
    } catch (e) { appendSystem(T('msg.lazarus.open.failed', 'Could not open Lazarus: {error}', { error: e.message })); }
}

async function ftViewFile(relPath, opts) {
    opts = opts || {};
    // Read file contents from server and display in the Preview panel
    try {
        const url  = 'files.php?action=read&project=' + encodeURIComponent(currentProject)
                   + '&path=' + encodeURIComponent(relPath);
        const res  = await fetch(url);
        const data = await res.json();
        if (!data.ok) {
            appendError(T('msg.could.not.read.file.error', 'Could not read file: {error}', {error: (data.error || 'unknown')}));
            return;
        }
        // Render into the right-side Preview panel
        const previewPanel = document.getElementById('right-preview');
        if (previewPanel) {
            // Switch to Preview tab using proper function
            const previewTab = document.querySelector('#sidebar-right .sidebar-vtab[onclick*="preview"]');
            if (previewTab) {
                switchTab('right', 'preview', previewTab);
            } else {
                // Fallback: manually activate preview panel
                document.querySelectorAll('#sidebar-right .sidebar-vtab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('#sidebar-right .sidebar-panel').forEach(p => { p.classList.remove('active'); p.style.display='none'; });
                previewPanel.classList.add('active');
                previewPanel.style.display = 'flex';
                _injectPanelTitle(previewPanel, 'preview');
            }

            const sizeKB = (data.size / 1024).toFixed(1);
            const dateStr = fmtDateTime(new Date(data.mtime * 1000));
            const ext = (relPath.split(".").pop() || '').toLowerCase();
            // H1: text files get an Edit button that swaps preview → editor
            const editable = ['pas','pp','lpr','php','sh','zsh','bash','txt','md','markdown',
                              'json','jsonl','html','htm','css','js','xml','yaml','yml','ini',
                              'conf','csv','tsv','log','sql','py','c','cpp','h'].includes(ext);
            previewPanel.innerHTML =
                '<div style="padding:8px 10px;border-bottom:1px solid var(--border-dim);' +
                'display:flex;align-items:center;gap:8px;font-size:10px;color:var(--text-muted);">' +
                    '<span class="material-symbols-rounded" style="font-size:14px;">' + ftIcon(ext) + '</span>' +
                    '<span style="font-weight:600;color:var(--text-base);">' + escHtml(relPath) + '</span>' +
                    // Re-read from disk. The preview is a snapshot: an agent, a chain or
                    // an applied Margin can change the file underneath it, and until
                    // 2026-09-30 the only way to see that was to click the file again.
                    '<button class="rp-action-btn" style="margin-left:6px;" title="Re-read this file from disk" ' +
                        'onclick="ftViewFile(' + JSON.stringify(relPath).replace(/"/g,'&quot;') + ')">' +
                        '<span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">refresh</span></button>' +
                    (FT_LAZARUS_EXT.includes(ext) ? '<button id="ft-laz-btn" class="rp-action-btn" style="margin-left:6px;display:none;" title="' + escHtml(T('files.lazarus.tip', 'Open this file (and its project) in the Lazarus IDE')) + '" ' +
                        'onclick="ftOpenInLazarus(' + JSON.stringify(relPath).replace(/"/g,'&quot;') + ')">' +
                        '<span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">code</span> ' + escHtml(T('files.lazarus', 'Lazarus')) + '</button>' : '') +
                    (FT_LAZARUS_EXT.includes(ext) ? '<button class="rp-action-btn" style="margin-left:6px;" title="' + escHtml(T('files.standards.tip', 'Check this project against the house rules: typed text, Windows-only code, comments')) + '" data-help="standards" onclick="standardsOpen()"><span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">rule</span> ' + escHtml(T('files.standards', 'Standards')) + '</button>' : '') +
                    (editable ? '<button class="rp-action-btn" style="margin-left:6px;" ' +
                        'onclick="ftEditFile(' + JSON.stringify(relPath).replace(/"/g,'&quot;') + ')">' +
                        '<span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">edit</span> Edit</button>' : '') +
                    (opts.changed ? '<span id="ft-changed" style="margin-left:8px;color:var(--accent-cyan,#7ecfff);">↻ ' + escHtml(T('files.changed', 'changed on disk — reloaded')) + '</span>' : '') +
                    '<span style="margin-left:auto;">' + sizeKB + ' KB · ' + dateStr + '</span>' +
                '</div>' +
                // data-margin-file marks this text as annotatable: selecting inside
                // it offers Margin, which needs to know WHICH file the lines are from.
                '<pre data-margin-file="' + escHtml(relPath) + '" ' +
                'style="margin:0;padding:10px;font-family:var(--font-mono);font-size:11px;' +
                'white-space:pre-wrap;word-wrap:break-word;color:var(--text-base);' +
                'overflow:auto;flex:1;">' + escHtml(data.content) + '</pre>';
            // Inject title AFTER setting innerHTML so it isn't overwritten
            _injectPanelTitle(previewPanel, 'preview');
            if (opts.scrollTop) { const _p = previewPanel.querySelector('pre[data-margin-file]'); if (_p) _p.scrollTop = opts.scrollTop; }
            if (opts.changed) setTimeout(function () { const c = document.getElementById('ft-changed'); if (c) c.remove(); }, 5000);
            ftWatchStart(relPath, data.mtime);          // from now on, changes made elsewhere reload this view
            if (FT_LAZARUS_EXT.includes(ext)) ftLazarusAvailable().then(function (ok) { const b = document.getElementById('ft-laz-btn'); if (b && ok) b.style.display = ''; });
        }
        // Silent — no appendSystem spam
    } catch(e) {
        appendError(T('msg.could.not.read.file.message', 'Could not read file: {message}', {message: e.message}));
    }
}

// H1 — edit a project file in-panel. Loads fresh content, swaps the preview
// for a textarea + Save/Cancel, writes back via files.php?action=write_file.
async function ftEditFile(relPath) {
    let content = '';
    try {
        const r = await fetch('files.php?action=read&project=' + encodeURIComponent(currentProject) +
                              '&path=' + encodeURIComponent(relPath));
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.could.not.read.file.error', 'Could not read file: {error}', {error: (d.error||'')})); return; }
        content = d.content || '';
    } catch(e) { appendError(T('msg.read.failed.message', 'Read failed: {message}', {message: e.message})); return; }

    const _writeFile = async (path, newContent) => {
        const r = await fetch('files.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({action:'write_file', project:currentProject, path, content:newContent})
        });
        const d = await r.json();
        if (!d.ok) return { ok:false, error: d.error || 'unknown' };
        appendSystem(T('msg.saved.path.size.bytes', 'Saved {path} ({size} bytes).', {path: path, size: d.size}));
        if (typeof loadFileTree === 'function') loadFileTree();
        return { ok:true };
    };
    openFloatingEditor({
        id: 'ft-' + relPath,
        heading: 'Editing file',
        filename: relPath,
        content,
        language: (relPath.split('.').pop() || ''),
        onSave: async (newContent) => _writeFile(relPath, newContent),
        onSaveAs: async (newContent) => {
            const np = await cprompt('Save as — new path (relative to project):', relPath);
            if (np === null) return { ok:false, error:'cancelled' };
            const target = np.trim();
            if (!target) return { ok:false, error:'empty path' };
            return _writeFile(target, newContent);
        }
    });
}

async function ftAttachToPrompt(relPath) {
    try {
        // files.php doesn't serve file contents yet, so we just note the
        // path and let the agent read it itself.
        const current = promptInput.value;
        const tag = '[File reference: ' + relPath + ' - use agent to read]\n\n';
        promptInput.value = tag + current;
        promptInput.focus();
        appendSystem(T('msg.file.referenced.in.prompt.relpath', 'File referenced in prompt: {relpath}', {relpath: relPath}));
    } catch(e) {
        appendError(T('msg.could.not.attach.file.message', 'Could not attach file: {message}', {message: e.message}));
    }
}

// =============================================================================
// Working directory display — strip cockpit root prefix
// =============================================================================
function setWorkDir(path) {
    const root = COCKPIT_PROJECTS_ROOT;
    const display = root && path.startsWith(root)
        ? path.slice(root.length) || '/'
        : path;
    document.getElementById('work-dir').textContent = display || '/';
}


// =============================================================================
// Artifacts panel (2026-09-22) — everything the project produced, in one list.
//
// Aggregates only; it never owns a file. Sources: the project folder (CRUD
// blocks, a CLI's own writes, tool outputs), generated media, transcripts, and
// the snippet/source stores where approved proposals land. Provenance (chat ·
// agent · model) is read back from the chat logs when a turn named the file.
// =============================================================================
const _ART_ICON = { image:'image', audio:'music_note', video:'movie', doc:'description',
                    code:'code', data:'table_chart', other:'draft' };

function _artSize(n) {
    n = +n || 0;
    if (n < 1024) return n + ' B';
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
    return (n / 1048576).toFixed(1) + ' MB';
}

async function artifactsRefresh() {
    const list = document.getElementById('artifacts-list');
    const cnt  = document.getElementById('artifacts-count');
    if (!list) return;
    const kind = (document.getElementById('artifacts-kind') || {}).value || 'all';
    const proj = (typeof currentProject === 'string' && currentProject) ? currentProject : '_standalone';
    list.innerHTML = '<div class="sidebar-empty">Looking…</div>';
    try {
        const r = await fetch('artifacts.php?action=list&kind=' + encodeURIComponent(kind) +
                              '&project=' + encodeURIComponent(proj));
        const d = await r.json();
        if (!d.ok) { list.innerHTML = '<div class="sidebar-empty">' + escHtml(d.error || 'failed') + '</div>'; return; }
        if (cnt) cnt.textContent = d.count ? (d.count + ' file' + (d.count > 1 ? 's' : '')) : '';
        if (!d.items.length) {
            list.innerHTML = '<div class="sidebar-empty">Nothing produced in <b>' + escHtml(proj) + '</b> yet.<br>' +
                'Files an agent writes, images and audio you generate, tool outputs and transcripts all land here.</div>';
            return;
        }
        list.innerHTML = d.items.map(it => {
            const icon = _ART_ICON[it.kind] || 'draft';
            const when = (typeof fmtTsLocal === 'function') ? fmtTsLocal(it.mtime) : (it.mtime || '').slice(0, 16);
            const by   = [it.agent && it.agent.toUpperCase(), it.model, it.chat && ('chat: ' + it.chat)].filter(Boolean).join(' · ');
            // Provenance is matched from what a chat turn SAID, so it is a label
            // and not a record. Only a turn that named the file with a full path
            // (tool output) is evidence it wrote it; anything else is a mention.
            const byWord = it.sure ? 'made by' : 'mentioned by';
            return '<div class="rp-item" style="display:flex;gap:6px;align-items:flex-start;padding:5px 8px;border-bottom:1px solid var(--border-dim);">' +
                '<span class="material-symbols-rounded" style="font-size:15px;color:var(--accent-blue);margin-top:1px;">' + icon + '</span>' +
                '<div style="flex:1;min-width:0;">' +
                    '<div style="font-size:11px;color:var(--text-primary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' + escAttr(it.path) + '">' + escHtml(it.name) + '</div>' +
                    '<div style="font-size:9.5px;color:var(--text-dim);">' + escHtml(_artSize(it.size)) + ' · ' + escHtml(when) +
                        ' · <span style="color:var(--text-muted);">' + escHtml(it.source) + '</span>' +
                        (by ? '<br><span style="color:var(--text-muted);"' +
                              (it.sure ? '' : ' title="This chat mentioned the file; that is not proof it created it."') +
                              '>' + byWord + ' ' + escHtml(by) + '</span>' : '') +
                    '</div>' +
                '</div>' +
                '<span class="material-symbols-rounded rp-act" title="Open with the desktop app" style="font-size:14px;cursor:pointer;" onclick="artifactOpen(' + JSON.stringify(it.path).replace(/"/g, '&quot;') + ')">open_in_new</span>' +
                '<span class="material-symbols-rounded rp-act" title="Show the folder" style="font-size:14px;cursor:pointer;" onclick="artifactReveal(' + JSON.stringify(it.path).replace(/"/g, '&quot;') + ')">folder_open</span>' +
                '<span class="material-symbols-rounded rp-act" title="Delete this file" style="font-size:14px;cursor:pointer;color:var(--claude);" onclick="artifactDelete(' + JSON.stringify(it.path).replace(/"/g, '&quot;') + ')">delete</span>' +
            '</div>';
        }).join('');
    } catch (e) {
        list.innerHTML = '<div class="sidebar-empty">Error: ' + escHtml(e.message) + '</div>';
    }
}

async function artifactOpen(path) {
    try {
        const d = await (await fetch('launch_cli.php', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ mode:'open', path }) })).json();
        if (!d.ok) appendSystem(T('msg.could.not.open.it.error', 'Could not open it: {error}', {error: (d.error || 'unknown')}));
    } catch (e) { appendSystem(T('msg.could.not.open.it.message', 'Could not open it: {message}', {message: e.message})); }
}
async function artifactReveal(path) {
    const dir = path.replace(/\/[^/]*$/, '');
    try {
        const d = await (await fetch('launch_cli.php', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ mode:'files', dir }) })).json();
        if (!d.ok) appendSystem(T('msg.could.not.show.the.folder.error', 'Could not show the folder: {error}', {error: (d.error || 'unknown')}));
    } catch (e) { appendSystem(T('msg.could.not.show.the.folder.message', 'Could not show the folder: {message}', {message: e.message})); }
}
async function artifactDelete(path) {
    const name = path.split('/').pop();
    if (typeof cockpitConfirm === 'function') {
        if (!await cockpitConfirm('Delete this file?', name + '\n\nIt is removed from disk — this cannot be undone.', 'Delete', { danger:true, icon:'delete' })) return;
    } else if (!await cconfirm(T('msg.delete.name', 'Delete {name}?', {name: name}))) return;
    try {
        const d = await (await fetch('artifacts.php?action=delete', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ path, project: (typeof currentProject === 'string' ? currentProject : '') }) })).json();
        if (!d.ok) { appendSystem(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (d.error || 'unknown')})); return; }
        appendSystem(T('msg.deleted.name', 'Deleted {name}.', {name: name}));
        artifactsRefresh();
    } catch (e) { appendSystem(T('msg.delete.failed.message', 'Delete failed: {message}', {message: e.message})); }
}
