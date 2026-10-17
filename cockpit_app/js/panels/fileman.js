// =============================================================================
// fileman.js — the File window: a small, Nemo-like file manager in a floating window (js/core/ckwindow.js). Backend: fm.php → the native engine.
//   Your Public folder is yours: create, rename, move, copy, upload, download, delete (to the trash). Everything else (your project folders and any
//   area an admin added) is read-only: look, view, download, and COPY into Public. Nothing here can touch anything else on the disk.
// Keys: arrows / Enter / Backspace (up) / F2 rename / Delete / Ctrl+C X V A / Ctrl+Shift+N new folder / F5 / Ctrl+L type a path.
// =============================================================================
(function () {
    const API = 'fm.php';
    const CHUNK = 768 * 1024;
    const IMG = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'], AUD = ['mp3', 'ogg', 'wav', 'flac', 'm4a'], VID = ['mp4', 'webm', 'mkv'];
    const TXT = ['txt', 'md', 'json', 'log', 'csv', 'sh', 'php', 'py', 'js', 'css', 'html', 'xml', 'pas', 'c', 'ini', 'conf', 'yml', 'yaml'];
    const S = { win: null, zones: [], info: {}, cwd: '', back: [], fwd: [], entries: [], sel: new Set(), last: null, clip: null, grid: false, hidden: false, filter: '', sort: 'name', asc: true, busy: 0 };
    let el = {};

    const esc = s => (typeof escHtml === 'function' ? escHtml(s) : String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])));
    const ext = n => { const i = n.lastIndexOf('.'); return i > 0 ? n.slice(i + 1).toLowerCase() : ''; };
    function parse(p) { const i = p.indexOf(':'); return { zone: p.slice(0, i), rel: p.slice(i + 1).split('/').filter(Boolean) }; }
    function joinp(zone, rel) { return zone + ':' + rel.join('/'); }
    function child(p, name) { const q = parse(p); q.rel.push(name); return joinp(q.zone, q.rel); }
    function parentOf(p) { const q = parse(p); q.rel.pop(); return joinp(q.zone, q.rel); }
    function zoneOf(p) { return S.zones.find(z => z.name === parse(p).zone); }
    const isRW = p => !!(zoneOf(p) && zoneOf(p).rw) && !S.info.viewer;
    const inTrash = p => { const q = parse(p); return q.zone === 'public' && q.rel[0] === '.trash'; };
    function fmtSize(n) { if (n < 1024) return n + ' B'; const u = ['KB', 'MB', 'GB', 'TB']; let i = -1; do { n /= 1024; i++; } while (n >= 1024 && i < 3); return n.toFixed(n < 10 ? 1 : 0) + ' ' + u[i]; }
    function fmtDate(t) { try { const d = new Date(t * 1000); return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) + ' ' + d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' }); } catch (e) { return ''; } }
    function icon(e) {
        if (e.type === 'dir') return 'folder'; if (e.type === 'link') return 'link'; const x = ext(e.name);
        if (IMG.includes(x)) return 'image'; if (VID.includes(x)) return 'movie'; if (AUD.includes(x)) return 'audio_file'; if (x === 'pdf') return 'picture_as_pdf';
        if (['zip', 'tar', 'gz', 'xz', 'bz2', '7z', 'rar'].includes(x)) return 'folder_zip'; if (TXT.includes(x)) return 'description'; return 'draft';
    }

    async function call(action, params, post) {
        S.busy++;
        try {
            const r = post ? await fetch(API, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(Object.assign({ action }, params)) })
                           : await fetch(API + '?action=' + action + '&' + new URLSearchParams(params).toString(), { cache: 'no-store' });
            const d = await r.json();
            return d;
        } catch (e) { return { ok: false, error: e.message }; } finally { S.busy--; }
    }
    function toast(msg, bad) {
        el.toast.textContent = msg; el.toast.className = 'fm-toast show' + (bad ? ' bad' : '');
        clearTimeout(toast.t); toast.t = setTimeout(() => el.toast.classList.remove('show'), bad ? 6000 : 2500);
    }
    function dlUrl(p, inline) { return API + '?action=download&path=' + encodeURIComponent(p) + (inline ? '&inline=1' : ''); }

    // ---- navigation ------------------------------------------------------------------------------------------------------------------------
    async function go(path, push) {
        const d = await call('list', { path });
        if (!d.ok) { showError(d, path); return false; }
        if (push !== false && S.cwd && S.cwd !== path) { S.back.push(S.cwd); S.fwd = []; }
        S.cwd = path; S.entries = d.entries || []; S.sel.clear(); S.last = null; el.err.style.display = 'none';
        try { localStorage.setItem('cockpit.fm.path', path); } catch (e) { }
        render(d.truncated);
        return true;
    }
    function showError(d, path) {
        el.err.style.display = ''; el.list.innerHTML = '';
        el.err.innerHTML = '<span class="material-symbols-rounded">error</span><div><b>' + esc(d.engine === false ? T('ui.fm.noservice', 'The file service is not running') : T('ui.fm.cantopen', 'Cannot open this folder')) + '</b><div>' + esc(d.error || '') + '</div></div>';
        const b = document.createElement('button'); b.className = 'action-btn'; b.textContent = T('ui.fm.retry', 'Try again'); b.onclick = () => go(path, false); el.err.appendChild(b);
    }
    const refresh = () => go(S.cwd, false);
    function goBack() { if (S.back.length) { S.fwd.push(S.cwd); go(S.back.pop(), false); } }
    function goFwd() { if (S.fwd.length) { S.back.push(S.cwd); go(S.fwd.pop(), false); } }
    function goUp() { const q = parse(S.cwd); if (q.rel.length) go(parentOf(S.cwd)); }

    // ---- rendering -------------------------------------------------------------------------------------------------------------------------
    function visible() {
        const q0 = parse(S.cwd), top = q0.zone === 'projects' && !q0.rel.length;       // your Public folder is shown as its own place, not inside Projects
        let a = S.entries.filter(e => (S.hidden || e.name[0] !== '.') && !(top && e.name === 'Public') && (!S.filter || e.name.toLowerCase().includes(S.filter)));
        const dir = S.asc ? 1 : -1;
        a.sort((x, y) => {
            if ((x.type === 'dir') !== (y.type === 'dir')) return x.type === 'dir' ? -1 : 1;
            let c = S.sort === 'size' ? x.size - y.size : S.sort === 'mtime' ? x.mtime - y.mtime : x.name.localeCompare(y.name, undefined, { numeric: true, sensitivity: 'base' });
            return c * dir;
        });
        return a;
    }
    function render(trunc) {
        const q = parse(S.cwd), z = zoneOf(S.cwd);
        // path bar
        el.path.innerHTML = '';
        const seg = (label, p) => { const b = document.createElement('button'); b.type = 'button'; b.className = 'fm-seg'; b.textContent = label; b.onclick = () => go(p); el.path.appendChild(b); };
        seg(z ? z.label : q.zone, joinp(q.zone, []));
        q.rel.forEach((c, i) => { const s = document.createElement('span'); s.className = 'fm-sep'; s.textContent = '›'; el.path.appendChild(s); seg(c === '.trash' && i === 0 ? T('ui.fm.trash', 'Trash') : c, joinp(q.zone, q.rel.slice(0, i + 1))); });
        // places
        el.places.querySelectorAll('.fm-place').forEach(b => b.classList.toggle('on', parse(S.cwd).zone === b.dataset.zone && !(b.dataset.trash && !inTrash(S.cwd)) && !(!b.dataset.trash && b.dataset.zone === 'public' && inTrash(S.cwd))));
        // buttons
        const rw = isRW(S.cwd);
        ['newdir', 'newfile', 'upload'].forEach(k => { if (el[k]) el[k].disabled = !rw || inTrash(S.cwd); });
        el.up.disabled = !q.rel.length; el.back.disabled = !S.back.length; el.fwd.disabled = !S.fwd.length;
        el.empty.style.display = inTrash(S.cwd) && !S.info.viewer ? '' : 'none';
        // list
        const list = visible();
        el.list.className = 'fm-list' + (S.grid ? ' fm-grid' : '');
        el.list.innerHTML = '';
        if (!S.grid) {
            const h = document.createElement('div'); h.className = 'fm-row fm-head';
            [['name', T('ui.fm.name', 'Name')], ['size', T('ui.fm.size', 'Size')], ['mtime', T('ui.fm.modified', 'Modified')]].forEach(([k, l]) => {
                const c = document.createElement('div'); c.className = 'fm-c fm-' + k; c.textContent = l + (S.sort === k ? (S.asc ? ' ▲' : ' ▼') : '');
                c.onclick = () => { if (S.sort === k) S.asc = !S.asc; else { S.sort = k; S.asc = true; } render(); }; h.appendChild(c);
            });
            el.list.appendChild(h);
        }
        if (!list.length) { const m = document.createElement('div'); m.className = 'fm-empty'; m.textContent = S.filter ? T('ui.fm.nomatch', 'Nothing matches the filter.') : T('ui.fm.empty', 'This folder is empty.'); el.list.appendChild(m); }
        list.forEach(e => el.list.appendChild(rowFor(e)));
        status(trunc);
    }
    function rowFor(e) {
        const p = child(S.cwd, e.name), r = document.createElement('div');
        r.className = 'fm-row fm-item' + (S.sel.has(e.name) ? ' sel' : ''); r.dataset.name = e.name; r.draggable = true; r.title = e.name + (e.link ? ' → ' + e.link : '');
        const ic = '<span class="material-symbols-rounded fm-ico' + (e.type === 'dir' ? ' dir' : '') + '">' + icon(e) + '</span>';
        r.innerHTML = '<div class="fm-c fm-name">' + ic + '<span class="fm-nm">' + esc(e.name) + '</span></div>' +
            (S.grid ? '' : '<div class="fm-c fm-size">' + (e.type === 'file' ? fmtSize(e.size) : '') + '</div><div class="fm-c fm-mtime">' + fmtDate(e.mtime) + '</div>');
        r.addEventListener('click', ev => select(e.name, ev));
        r.addEventListener('dblclick', () => openItem(e));
        r.addEventListener('contextmenu', ev => { ev.preventDefault(); if (!S.sel.has(e.name)) select(e.name, {}); menu(ev.clientX, ev.clientY, e); });
        r.addEventListener('dragstart', ev => { if (!S.sel.has(e.name)) select(e.name, {}); ev.dataTransfer.setData('application/x-ckfm', JSON.stringify([...S.sel].map(n => child(S.cwd, n)))); ev.dataTransfer.effectAllowed = 'copyMove'; });
        if (e.type === 'dir') {
            r.addEventListener('dragover', ev => { ev.preventDefault(); r.classList.add('drop'); });
            r.addEventListener('dragleave', () => r.classList.remove('drop'));
            r.addEventListener('drop', ev => { ev.preventDefault(); ev.stopPropagation(); r.classList.remove('drop'); dropOn(child(S.cwd, e.name), ev); });
        }
        return r;
    }
    function status(trunc) {
        const total = visible(), sel = total.filter(e => S.sel.has(e.name));
        let t = total.length + ' ' + T('ui.fm.items', 'items');
        if (sel.length) t += ' · ' + sel.length + ' ' + T('ui.fm.selected', 'selected') + (sel.some(e => e.type === 'file') ? ' (' + fmtSize(sel.reduce((a, e) => a + (e.type === 'file' ? e.size : 0), 0)) + ')' : '');
        if (trunc) t += ' · ' + T('ui.fm.truncated', 'only the first 5000 are shown');
        el.stat.textContent = t;
        el.ro.style.display = isRW(S.cwd) ? 'none' : '';
    }
    function select(name, ev) {
        const names = visible().map(e => e.name);
        if (ev.shiftKey && S.last) { const a = names.indexOf(S.last), b = names.indexOf(name); S.sel = new Set(names.slice(Math.min(a, b), Math.max(a, b) + 1)); }
        else if (ev.ctrlKey || ev.metaKey) { S.sel.has(name) ? S.sel.delete(name) : S.sel.add(name); S.last = name; }
        else { S.sel = new Set([name]); S.last = name; }
        el.list.querySelectorAll('.fm-item').forEach(r => r.classList.toggle('sel', S.sel.has(r.dataset.name)));
        status();
    }

    // ---- opening and viewing ---------------------------------------------------------------------------------------------------------------
    function openItem(e) {
        const p = child(S.cwd, e.name);
        if (e.type === 'dir') return go(p);
        if (e.type !== 'file') { toast(T('ui.fm.cantview', 'Links and special files are not opened.'), true); return; }
        const x = ext(e.name);
        if (IMG.includes(x) || AUD.includes(x) || VID.includes(x) || x === 'pdf' || TXT.includes(x)) return view(p, e, x);
        download(p);
    }
    function download(p) { const a = document.createElement('a'); a.href = dlUrl(p); a.download = ''; document.body.appendChild(a); a.click(); a.remove(); }
    async function view(p, e, x) {
        const c = document.createElement('div'); c.className = 'fm-view';
        if (IMG.includes(x)) c.innerHTML = '<img alt="">', c.firstChild.src = dlUrl(p, true);
        else if (AUD.includes(x)) c.innerHTML = '<audio controls autoplay></audio>', c.firstChild.src = dlUrl(p, true);
        else if (VID.includes(x)) c.innerHTML = '<video controls autoplay></video>', c.firstChild.src = dlUrl(p, true);
        else if (x === 'pdf') c.innerHTML = '<iframe title="PDF"></iframe>', c.firstChild.src = dlUrl(p, true);
        else {
            const pre = document.createElement('pre'); pre.textContent = T('ui.fm.loading', 'Loading…'); c.appendChild(pre);
            try { const r = await fetch(dlUrl(p, true), { headers: { Range: 'bytes=0-1048575' } }); pre.textContent = await r.text(); const tot = ((r.headers.get('Content-Range') || '').match(/\/(\d+)$/) || [])[1]; if (r.status === 206 && tot && +tot > 1048576) pre.textContent += '\n\n… ' + T('ui.fm.firstmb', 'only the first 1 MB is shown — download the file for the rest'); }
            catch (err) { pre.textContent = err.message; }
        }
        ckWindow({ id: 'fmview-' + p, title: e.name, icon: icon(e), width: 720, height: 520, content: c, buttons: [{ icon: 'download', title: T('ui.fm.download', 'Download'), onClick: () => download(p) }] });
    }
    // ---- Edit: Cockpit's own code editor (openFloatingEditor: highlighting, line numbers, find/replace) on a file in a read-write folder; saved whole ----
    async function edit(p, e) {
        if (typeof openFloatingEditor !== 'function') { toast(T('ui.fm.noeditor', 'The editor is not available'), true); return; }
        if (e.size > 1048576) { toast(T('ui.fm.toobig', 'Files over 1 MB are not edited here - download it instead'), true); return; }
        let text;
        try { const r = await fetch(dlUrl(p, true)); if (!r.ok) throw new Error('HTTP ' + r.status); text = await r.text(); }
        catch (err) { toast(err.message, true); return; }
        if (text.indexOf('\u0000') >= 0) { toast(T('ui.fm.binary', 'This is not a text file'), true); return; }
        openFloatingEditor({
            id: 'fm-' + p, heading: T('ui.fm.edit', 'Edit'), filename: p, content: text, language: ext(e.name) || 'txt',
            onSave: async (content) => {
                const bytes = new TextEncoder().encode(content); let bin = '';
                for (let i = 0; i < bytes.length; i += 32768) bin += String.fromCharCode.apply(null, bytes.subarray(i, i + 32768));
                const d = await call('write', { path: p, offset: 0, data_b64: btoa(bin) }, true);
                if (!d.ok) return { ok: false, error: d.error || 'could not save' };
                refresh(); return { ok: true };
            }
        });
    }
    async function openSystem(e) {
        const d = await call('open', { path: child(S.cwd, e.name) }, true);
        if (!d.ok) toast(d.error || T('ui.fm.noopen', 'Could not open it'), true);
    }

    // ---- changes ---------------------------------------------------------------------------------------------------------------------------
    async function act(action, params, okMsg) {
        const d = await call(action, params, true);
        if (!d.ok) { toast(d.error || T('ui.fm.failed', 'That did not work'), true); return d; }
        if (okMsg) toast(okMsg);
        return d;
    }
    function uniq(base, ext_) { const names = new Set(S.entries.map(e => e.name)); if (!names.has(base + ext_)) return base + ext_; let i = 2; while (names.has(base + ' ' + i + ext_)) i++; return base + ' ' + i + ext_; }
    async function newItem(kind) {
        if (!isRW(S.cwd)) return;
        const name = kind === 'dir' ? uniq(T('ui.fm.newfolder', 'New folder'), '') : uniq(T('ui.fm.newfile', 'New file'), '.txt');
        const d = await act(kind === 'dir' ? 'mkdir' : 'newfile', { path: child(S.cwd, name) });
        if (d.ok) { await refresh(); S.sel = new Set([name]); render(); rename(name); }
    }
    function rename(name) {
        const row = [...el.list.querySelectorAll('.fm-item')].find(r => r.dataset.name === name); if (!row || !isRW(S.cwd)) return;
        const span = row.querySelector('.fm-nm'), inp = document.createElement('input'); inp.type = 'text'; inp.value = name; inp.className = 'fm-rename';
        span.replaceWith(inp); inp.focus(); const dot = name.lastIndexOf('.'); inp.setSelectionRange(0, dot > 0 ? dot : name.length);
        let done = false;
        const finish = async ok => {
            if (done) return; done = true;
            const nv = inp.value.trim();
            if (ok && nv && nv !== name) { const d = await act('rename', { path: child(S.cwd, name), name: nv }); if (d.ok) { await refresh(); S.sel = new Set([nv]); render(); return; } }
            render();
        };
        inp.onkeydown = ev => { ev.stopPropagation(); if (ev.key === 'Enter') finish(true); else if (ev.key === 'Escape') finish(false); };
        inp.onblur = () => finish(true); inp.onclick = ev => ev.stopPropagation(); inp.ondblclick = ev => ev.stopPropagation();
    }
    async function del() {
        const names = [...S.sel]; if (!names.length || !isRW(S.cwd)) return;
        const perm = inTrash(S.cwd);
        if (perm && !await cconfirm(T('ui.fm.confirmperm', 'Delete {n} item(s) permanently? This cannot be undone.', { n: names.length }))) return;
        let n = 0; for (const nm of names) { const d = await act('delete', { path: child(S.cwd, nm) }); if (d.ok) n++; else break; }
        await refresh(); if (n) toast(perm ? T('ui.fm.deleted', 'Deleted') : T('ui.fm.totrash', 'Moved to the trash'));
    }
    async function emptyTrash() {
        if (!await cconfirm(T('ui.fm.confirmempty', 'Empty the trash? Everything in it is deleted for good.'))) return;
        const d = await act('empty_trash', { zone: 'public' }, T('ui.fm.trashempty', 'The trash is empty')); if (d.ok) refresh();
    }
    function copySel(cut) { if (!S.sel.size) return; S.clip = { cut: !!cut, items: [...S.sel].map(n => child(S.cwd, n)) }; toast((cut ? T('ui.fm.cutn', 'Cut') : T('ui.fm.copiedn', 'Copied')) + ': ' + S.sel.size); }
    async function paste(target) {
        target = target || S.cwd;
        if (!S.clip || !isRW(target)) { if (S.clip) toast(T('ui.fm.cantpaste', 'You can only paste into your Public folder.'), true); return; }
        let ok = 0;
        for (const src of S.clip.items) {
            const move = S.clip.cut && zoneOf(src) && zoneOf(src).rw && parse(src).zone === parse(target).zone;
            if (S.clip.cut && !move) { toast(T('ui.fm.cutnoin', 'Items from a read-only area can only be copied.'), true); continue; }
            if (move && parentOf(src) === target) continue;
            const d = await act(move ? 'move' : 'copy', { path: src, to_dir: target }); if (d.ok) ok++; else break;
        }
        if (S.clip.cut) S.clip = null; await refresh(); if (ok) toast(T('ui.fm.done', 'Done'));
    }
    async function dropOn(target, ev) {
        const raw = ev.dataTransfer.getData('application/x-ckfm');
        if (raw) {
            if (!isRW(target)) { toast(T('ui.fm.cantpaste', 'You can only paste into your Public folder.'), true); return; }
            const items = JSON.parse(raw);
            for (const src of items) {
                if (src === target || parentOf(src) === target) continue;
                const sameRW = zoneOf(src) && zoneOf(src).rw && parse(src).zone === parse(target).zone;
                const d = await act(sameRW && !ev.ctrlKey ? 'move' : 'copy', { path: src, to_dir: target }); if (!d.ok) break;
            }
            return refresh();
        }
        if (ev.dataTransfer.files && ev.dataTransfer.files.length) uploadFiles([...ev.dataTransfer.files], target);
    }
    async function uploadFiles(files, target) {
        target = target || S.cwd;
        if (!isRW(target)) { toast(T('ui.fm.cantupload', 'You can only upload into your Public folder.'), true); return; }
        for (const f of files) {
            let name = f.name, tries = 0, off = 0, started = false;
            while (off < f.size || !started) {
                const buf = new Uint8Array(await f.slice(off, off + CHUNK).arrayBuffer());
                let bin = ''; for (let i = 0; i < buf.length; i += 8192) bin += String.fromCharCode.apply(null, buf.subarray(i, i + 8192));
                const d = await call('write', { path: child(target, name), offset: off, data_b64: btoa(bin), create_only: off === 0 }, true);
                if (!d.ok) {
                    if (off === 0 && /already exists/.test(d.error || '') && tries < 50) { tries++; const dot = f.name.lastIndexOf('.'); name = (dot > 0 ? f.name.slice(0, dot) : f.name) + ' (' + (tries + 1) + ')' + (dot > 0 ? f.name.slice(dot) : ''); continue; }
                    toast(d.error || T('ui.fm.uploadfail', 'Upload failed'), true); return refresh();
                }
                started = true; off += buf.length; el.stat.textContent = T('ui.fm.uploading', 'Uploading') + ' ' + name + ' · ' + Math.min(100, Math.round(f.size ? off * 100 / f.size : 100)) + '%';
                if (!buf.length) break;
            }
        }
        await refresh(); toast(T('ui.fm.uploaded', 'Uploaded'));
    }

    // ---- context menu ----------------------------------------------------------------------------------------------------------------------
    function closeMenu() { const m = document.getElementById('fm-menu'); if (m) m.remove(); }
    function menu(x, y, e) {
        closeMenu(); const m = document.createElement('div'); m.id = 'fm-menu'; m.className = 'fm-menu';
        const rw = isRW(S.cwd), many = S.sel.size > 1;
        const items = [];
        if (e) {
            items.push([T('ui.fm.open', 'Open'), 'open_in_new', () => openItem(e), false]);
            if (rw && e.type === 'file' && !many) items.push([T('ui.fm.edit', 'Edit'), 'edit_note', () => edit(child(S.cwd, e.name), e), false]);
            if (S.info.can_open && !many) items.push([T('ui.fm.opensys', 'Open with the system'), 'desktop_windows', () => openSystem(e), false]);
            if (e.type === 'file' && !many) items.push([T('ui.fm.download', 'Download'), 'download', () => download(child(S.cwd, e.name)), false]);
            if (e.type === 'file' && !many && typeof powerRunOnFile === 'function') items.push([T('ui.fm.power', 'Power Buttons…'), 'bolt', () => powerRunOnFile(child(S.cwd, e.name), e, dlUrl(child(S.cwd, e.name), true)), false]);
            items.push(null, [T('ui.fm.copy', 'Copy'), 'content_copy', () => copySel(false), false]);
            if (rw) items.push([T('ui.fm.cut', 'Cut'), 'content_cut', () => copySel(true), false]);
            if (rw && !many) items.push([T('ui.fm.rename', 'Rename'), 'edit', () => rename(e.name), false]);
            if (rw) items.push([inTrash(S.cwd) ? T('ui.fm.deleteperm', 'Delete permanently') : T('ui.fm.delete', 'Move to the trash'), 'delete', del, false]);
        } else {
            if (rw) { items.push([T('ui.fm.newfolder2', 'New folder'), 'create_new_folder', () => newItem('dir'), false], [T('ui.fm.newfile2', 'New file'), 'note_add', () => newItem('file'), false], [T('ui.fm.upload', 'Upload…'), 'upload', () => el.file.click(), false]); }
            items.push([T('ui.fm.paste', 'Paste'), 'content_paste', () => paste(), !S.clip || !rw], [T('ui.fm.refresh', 'Refresh'), 'refresh', refresh, false]);
        }
        items.forEach(it => {
            if (!it) { const h = document.createElement('div'); h.className = 'fm-menu-sep'; m.appendChild(h); return; }
            const b = document.createElement('button'); b.type = 'button'; b.disabled = !!it[3]; b.innerHTML = '<span class="material-symbols-rounded">' + it[1] + '</span><span>' + esc(it[0]) + '</span>';
            b.onclick = () => { closeMenu(); it[2](); }; m.appendChild(b);
        });
        document.body.appendChild(m);
        const r = m.getBoundingClientRect(); m.style.left = Math.max(4, Math.min(x, innerWidth - r.width - 4)) + 'px'; m.style.top = Math.max(4, Math.min(y, innerHeight - r.height - 4)) + 'px';
        setTimeout(() => document.addEventListener('mousedown', function f(ev) { if (!m.contains(ev.target)) { closeMenu(); } document.removeEventListener('mousedown', f, true); }, true), 0);
    }

    // ---- keys ------------------------------------------------------------------------------------------------------------------------------
    function onKey(ev) {
        if (ev.target.tagName === 'INPUT') return;
        const names = visible().map(e => e.name), k = ev.key, ctrl = ev.ctrlKey || ev.metaKey;
        if (k === 'ArrowDown' || k === 'ArrowUp') {
            ev.preventDefault(); if (!names.length) return;
            let i = names.indexOf(S.last); i = k === 'ArrowDown' ? Math.min(names.length - 1, i + 1) : Math.max(0, i < 0 ? 0 : i - 1);
            select(names[i], ev); const r = [...el.list.querySelectorAll('.fm-item')].find(x => x.dataset.name === names[i]); if (r) r.scrollIntoView({ block: 'nearest' });
        } else if (k === 'Enter') { const e = S.entries.find(x => x.name === S.last); if (e) openItem(e); }
        else if (k === 'Backspace') { ev.preventDefault(); goUp(); }
        else if (k === 'F2') { if (S.last) rename(S.last); }
        else if (k === 'Delete') del();
        else if (k === 'F5') { ev.preventDefault(); refresh(); }
        else if (ctrl && k.toLowerCase() === 'a') { ev.preventDefault(); S.sel = new Set(names); render(); }
        else if (ctrl && k.toLowerCase() === 'c') copySel(false);
        else if (ctrl && k.toLowerCase() === 'x') copySel(true);
        else if (ctrl && k.toLowerCase() === 'v') paste();
        else if (ctrl && ev.shiftKey && k.toLowerCase() === 'n') { ev.preventDefault(); newItem('dir'); }
        else if (ctrl && k.toLowerCase() === 'l') { ev.preventDefault(); typePath(); }
    }
    function typePath() {
        const inp = document.createElement('input'); inp.type = 'text'; inp.className = 'fm-pathinput'; inp.value = S.cwd; el.path.style.display = 'none'; el.pathwrap.appendChild(inp); inp.focus(); inp.select();
        const end = ok => { const v = inp.value.trim(); inp.remove(); el.path.style.display = ''; if (ok && v && v !== S.cwd) go(v.includes(':') ? v : S.cwd.split(':')[0] + ':' + v); };
        inp.onkeydown = ev => { ev.stopPropagation(); if (ev.key === 'Enter') end(true); else if (ev.key === 'Escape') end(false); }; inp.onblur = () => end(false);
    }

    // ---- building the window ---------------------------------------------------------------------------------------------------------------
    function btn(icon_, title, fn, id) { const b = document.createElement('button'); b.type = 'button'; b.className = 'fm-btn'; b.title = title; b.setAttribute('aria-label', title); b.innerHTML = '<span class="material-symbols-rounded">' + icon_ + '</span>'; b.onclick = fn; if (id) el[id] = b; return b; }
    function build() {
        const root = document.createElement('div'); root.className = 'fm-root'; root.tabIndex = 0;
        const tb = document.createElement('div'); tb.className = 'fm-toolbar';
        tb.appendChild(btn('arrow_back', T('ui.fm.back', 'Back'), goBack, 'back')); tb.appendChild(btn('arrow_forward', T('ui.fm.forward', 'Forward'), goFwd, 'fwd'));
        tb.appendChild(btn('arrow_upward', T('ui.fm.up', 'Up'), goUp, 'up')); tb.appendChild(btn('refresh', T('ui.fm.refresh', 'Refresh'), refresh));
        el.pathwrap = document.createElement('div'); el.pathwrap.className = 'fm-pathwrap'; el.path = document.createElement('div'); el.path.className = 'fm-path';
        el.path.title = T('ui.fm.pathtip', 'Double-click (or Ctrl+L) to type a path'); el.path.ondblclick = typePath; el.pathwrap.appendChild(el.path); tb.appendChild(el.pathwrap);
        const f = document.createElement('input'); f.type = 'search'; f.className = 'fm-filter'; f.placeholder = T('ui.fm.filter', 'Filter'); f.oninput = () => { S.filter = f.value.trim().toLowerCase(); render(); }; tb.appendChild(f);
        tb.appendChild(btn('create_new_folder', T('ui.fm.newfolder2', 'New folder'), () => newItem('dir'), 'newdir')); tb.appendChild(btn('note_add', T('ui.fm.newfile2', 'New file'), () => newItem('file'), 'newfile'));
        el.file = document.createElement('input'); el.file.type = 'file'; el.file.multiple = true; el.file.style.display = 'none'; el.file.onchange = () => { uploadFiles([...el.file.files]); el.file.value = ''; };
        tb.appendChild(el.file); tb.appendChild(btn('upload', T('ui.fm.upload', 'Upload…'), () => el.file.click(), 'upload'));
        tb.appendChild(btn('grid_view', T('ui.fm.viewtoggle', 'List / icons'), () => { S.grid = !S.grid; try { localStorage.setItem('cockpit.fm.grid', S.grid ? '1' : '0'); } catch (e) { } render(); }));
        tb.appendChild(btn('visibility', T('ui.fm.hidden', 'Show hidden files'), () => { S.hidden = !S.hidden; render(); }));
        const em = btn('delete_forever', T('ui.fm.emptytrash', 'Empty the trash'), emptyTrash, 'empty'); em.style.display = 'none'; tb.appendChild(em);
        root.appendChild(tb);
        const main = document.createElement('div'); main.className = 'fm-main';
        el.places = document.createElement('div'); el.places.className = 'fm-places';
        el.list = document.createElement('div'); el.list.className = 'fm-list'; el.list.tabIndex = 0;
        el.err = document.createElement('div'); el.err.className = 'fm-err'; el.err.style.display = 'none';
        const col = document.createElement('div'); col.className = 'fm-col'; col.appendChild(el.err); col.appendChild(el.list);
        main.appendChild(el.places); main.appendChild(col); root.appendChild(main);
        const sb = document.createElement('div'); sb.className = 'fm-status';
        el.stat = document.createElement('span'); el.ro = document.createElement('span'); el.ro.className = 'fm-ro'; el.ro.textContent = T('ui.fm.readonly', 'Read-only: you can look, view, download and copy into Public.');
        sb.appendChild(el.stat); sb.appendChild(el.ro); root.appendChild(sb);
        el.toast = document.createElement('div'); el.toast.className = 'fm-toast'; root.appendChild(el.toast);
        root.addEventListener('keydown', onKey);
        col.addEventListener('contextmenu', ev => { if (!ev.target.closest('.fm-item')) { ev.preventDefault(); S.sel.clear(); render(); menu(ev.clientX, ev.clientY, null); } });
        col.addEventListener('click', ev => { if (!ev.target.closest('.fm-item') && !ev.target.closest('.fm-head')) { S.sel.clear(); render(); } });
        col.addEventListener('dragover', ev => { ev.preventDefault(); }); col.addEventListener('drop', ev => { ev.preventDefault(); dropOn(S.cwd, ev); });
        return root;
    }
    function buildPlaces() {
        el.places.innerHTML = '';
        const add = (label, ic, zone, path, trash) => {
            const b = document.createElement('button'); b.type = 'button'; b.className = 'fm-place'; b.dataset.zone = zone; if (trash) b.dataset.trash = '1';
            b.innerHTML = '<span class="material-symbols-rounded">' + ic + '</span><span class="fm-pl">' + esc(label) + '</span>' + (!trash && !S.zones.find(z => z.name === zone).rw ? '<span class="fm-lock material-symbols-rounded" title="' + esc(T('ui.fm.readonlyshort', 'Read-only')) + '">lock</span>' : '');
            b.onclick = () => go(path); b.addEventListener('dragover', ev => { ev.preventDefault(); b.classList.add('drop'); }); b.addEventListener('dragleave', () => b.classList.remove('drop'));
            b.addEventListener('drop', ev => { ev.preventDefault(); b.classList.remove('drop'); dropOn(path, ev); }); el.places.appendChild(b);
        };
        S.zones.forEach(z => { add(z.label, z.name === 'public' ? 'home' : z.name === 'projects' ? 'folder_special' : 'folder_shared', z.name, z.name + ':'); if (z.name === 'public') add(T('ui.fm.trash', 'Trash'), 'delete', 'public', 'public:.trash', true); });
    }

    window.filemanOpen = async function (startPath) {
        if (S.win && ckWindowOpen('fileman')) { S.win.focus(); if (startPath) go(startPath); return; }
        const info = await call('zones', {});
        if (info && info.edition_gate) return;
        S.info = info || {}; S.zones = (info && info.zones) || [];
        if (!S.zones.length) { appendError(T('ui.fm.nozones', 'The file window is not available: {e}', { e: (info && info.error) || 'no folders' })); return; }
        try { S.grid = localStorage.getItem('cockpit.fm.grid') === '1'; } catch (e) { }
        S.back = []; S.fwd = []; S.cwd = ''; S.clip = null; S.sel = new Set();
        const nat = typeof quickLaunchFiles === 'function';
        S.win = ckWindow({ id: 'fileman', title: T('ui.fm.title', 'Files'), icon: 'folder_open', width: 900, height: 560, minWidth: 460, minHeight: 280, content: build(), onClose() { closeMenu(); S.win = null; },
            buttons: nat ? [{ icon: 'desktop_windows', title: T('ui.fm.systemfm', 'Open the system file manager'), onClick: () => quickLaunchFiles() }] : [] });
        buildPlaces();
        if (!info.engine) { showError({ engine: false, error: T('ui.fm.noservice2', 'Start the agents (the supervisor hosts the file service) and press Try again.') }, 'public:'); return; }
        let start = startPath; try { start = start || localStorage.getItem('cockpit.fm.path'); } catch (e) { }
        if (!(start && S.zones.some(z => z.name === parse(start).zone)) || !(await go(start, false))) await go('public:', false);
        el.list.focus();
    };
})();
