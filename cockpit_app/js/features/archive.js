// =============================================================================
// archive.js — Personal archive (the face of archive.php).
//
//   archiveOpen()   Toolbar button: add scans / photos / PDFs of your own papers, see what is due
//                   soon, correct the type and due date the reader guessed, search them in the Library.
//
// Documents are read on this computer (pdftotext, tesseract, or a local vision model). Nothing is
// sent to an online service.
// =============================================================================
(function () {
    'use strict';
    function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function post(b) { return fetch('archive.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(b) }).then(function (r) { return r.json(); }); }
    function close() { var o = document.getElementById('archive-ov'); if (o) o.remove(); }
    function b64(file) { return new Promise(function (res, rej) { var r = new FileReader(); r.onload = function () { res(String(r.result).split(',')[1] || ''); }; r.onerror = rej; r.readAsDataURL(file); }); }
    var TYPE = { warranty: 'Warranty', invoice: 'Invoice / receipt', insurance: 'Insurance', contract: 'Contract', id: 'ID / licence', tax: 'Tax', medical: 'Medical', manual: 'Manual', other: 'Other' };

    window.archiveOpen = async function () {
        close();
        var ov = document.createElement('div'); ov.id = 'archive-ov';
        ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
        ov.addEventListener('mousedown', function (e) { if (e.target === ov) close(); });
        document.body.appendChild(ov);
        var note = '';
        async function draw() {
            var r; try { r = await (await fetch('archive.php?action=status')).json(); } catch (e) { r = null; }
            if (!r || !r.ok) { ov.innerHTML = '<div style="background:var(--bg-base);padding:18px;border-radius:6px;">' + esc(T('archive.err', 'The archive is not available here.')) + '</div>'; return; }
            var rd = r.readers, readerLine = rd.tesseract ? 'tesseract' : (rd.vision_model ? T('archive.reader.vision', 'local vision model {m} (slower: about 20 s per page)', { m: rd.vision_model }) : T('archive.reader.none', 'none — only text PDFs can be read. Install tesseract-ocr or pull a vision model.'));
            var due = r.due_soon.map(function (d) { return '<div style="color:' + (d.overdue ? 'var(--claude)' : 'var(--text-base)') + ';">' + (d.overdue ? '⚠ ' : '') + esc(d.due) + ' — ' + esc(d.title) + (d.overdue ? ' (' + esc(T('archive.overdue', 'overdue')) + ')' : '') + '</div>'; }).join('');
            var rows = r.items.map(function (i) {
                var opts = r.types.map(function (t) { return '<option value="' + t + '"' + (t === i.type ? ' selected' : '') + '>' + esc(TYPE[t] || t) + '</option>'; }).join('');
                return '<tr data-id="' + esc(i.id) + '"><td style="padding:4px 6px;">' + esc(i.title) + (i.read ? '' : ' <i style="color:var(--claude);">(' + esc(T('archive.unread', 'not read')) + ')</i>') + '<div style="font-size:10px;color:var(--text-muted);">' + esc(i.method || '') + (i.amounts && i.amounts.length ? ' · ' + esc(i.amounts.join(', ')) : '') + '</div></td>' +
                    '<td style="padding:4px 6px;"><select data-f="type" style="font-size:11px;">' + opts + '</select></td>' +
                    '<td style="padding:4px 6px;"><input type="date" data-f="due" value="' + esc(i.due || '') + '" style="font-size:11px;"></td>' +
                    '<td style="padding:4px 6px;white-space:nowrap;"><a class="action-btn" href="archive.php?action=original&id=' + encodeURIComponent(i.id) + '" style="padding:2px 8px;font-size:11px;text-decoration:none;">' + esc(T('archive.original', 'Original')) + '</a> <button class="action-btn" data-del="' + esc(i.id) + '" style="padding:2px 8px;font-size:11px;">' + esc(T('archive.delete', 'Delete')) + '</button></td></tr>';
            }).join('');
            ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(820px,94vw);max-height:90vh;overflow:auto;padding:18px;color:var(--text-primary);">' +
                '<h2 style="margin:0 0 6px;font-size:14px;">' + esc(T('archive.title', 'Personal archive')) + '</h2>' +
                '<div style="font-size:12px;line-height:1.5;">' + esc(T('archive.intro', 'Add scans, photos or PDFs of your own papers — warranties, invoices, insurance, contracts. Cockpit reads them on this computer, files them in the Library (so you can ask about them), and shows what is due soon. Check what it guessed.')) + '</div>' +
                '<div style="margin-top:8px;font-size:10.5px;color:var(--text-dim);">' + esc(T('archive.reader', 'Reader for scans:')) + ' ' + esc(readerLine) + '</div>' +
                '<div style="margin-top:10px;"><input type="file" id="ar-file" multiple accept=".pdf,.png,.jpg,.jpeg,.webp,.tif,.tiff,.bmp,.txt,.md" style="font-size:11px;"> <button class="action-btn" id="ar-add" style="padding:3px 10px;font-size:11px;background:var(--accent-blue);color:#fff;">' + esc(T('archive.add', 'Add')) + '</button></div>' +
                (note ? '<div style="margin-top:8px;padding:8px;border:1px solid var(--border-mid);border-radius:4px;font-size:11.5px;">' + esc(note) + '</div>' : '') +
                '<h3 style="margin:14px 0 4px;font-size:12px;">' + esc(T('archive.due', 'Due in the next 60 days')) + '</h3><div style="font-size:11.5px;line-height:1.6;">' + (due || '<span style="color:var(--text-muted);">' + esc(T('archive.nodue', 'Nothing.')) + '</span>') + '</div>' +
                '<h3 style="margin:14px 0 4px;font-size:12px;">' + esc(T('archive.items', 'Everything filed')) + '</h3>' +
                (rows ? '<table style="width:100%;font-size:11.5px;border-collapse:collapse;">' + rows + '</table>' : '<div style="font-size:11.5px;color:var(--text-muted);">' + esc(T('archive.empty', 'Nothing yet.')) + '</div>') +
                '<div style="display:flex;justify-content:flex-end;margin-top:14px;"><button class="action-btn" id="ar-close" style="padding:4px 11px;font-size:11px;">' + esc(T('archive.close', 'Close')) + '</button></div></div>';
            ov.querySelector('#ar-close').onclick = close;
            ov.querySelector('#ar-add').onclick = async function () {
                var fs = ov.querySelector('#ar-file').files; if (!fs.length) { note = T('archive.choose', 'Choose one or more files first.'); draw(); return; }
                var msgs = [];
                for (var k = 0; k < fs.length; k++) {
                    note = T('archive.reading', 'Reading {name} ({i} of {n})…', { name: fs[k].name, i: k + 1, n: fs.length }); await draw();
                    var x; try { x = await post({ action: 'ingest', filename: fs[k].name, data_b64: await b64(fs[k]) }); } catch (e) { x = { ok: false, error: e.message }; }
                    msgs.push(x.ok ? (x.item.title + ': ' + (x.item.read ? TYPE[x.item.type] + (x.item.due ? ', ' + x.item.due : '') : (x.note || ''))) : (fs[k].name + ': ' + x.error));
                }
                note = msgs.join('  ·  '); draw();
            };
            ov.querySelectorAll('[data-f]').forEach(function (el) { el.onchange = async function () { var b = { action: 'set', id: el.closest('tr').dataset.id }; b[el.dataset.f] = el.value; await post(b); note = T('archive.saved', 'Saved.'); draw(); }; });
            ov.querySelectorAll('[data-del]').forEach(function (el) { el.onclick = async function () { if (!await cconfirm(T('archive.confirm.del', 'Delete this document and its Library text?'))) return; await post({ action: 'delete', id: el.dataset.del }); note = ''; draw(); }; });
        }
        draw();
    };
})();
