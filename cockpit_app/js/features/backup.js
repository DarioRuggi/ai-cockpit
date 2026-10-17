// =============================================================================
// backup.js — Backup & restore (the face of backup.php).
//
//   backupOpen()   Toolbar button: make a backup, test one (restore into a scratch folder and
//                  compare every checksum), restore one, download or delete one.
//
// A backup is a plain .tar.gz. Restoring first saves the current state as a "pre-restore"
// backup, so a restore can itself be undone.
// =============================================================================
(function () {
    'use strict';
    function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function post(body) { return fetch('backup.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(function (r) { return r.json(); }); }
    function close() { var o = document.getElementById('backup-ov'); if (o) o.remove(); }
    function btn(act, file, label, kind) {
        var st = kind === 'primary' ? 'background:var(--accent-blue);color:#fff;' : (kind === 'danger' ? 'color:var(--claude);' : '');
        return '<button class="action-btn" data-act="' + act + '"' + (file ? ' data-file="' + esc(file) + '"' : '') + ' style="padding:3px 9px;font-size:11px;' + st + '">' + esc(label) + '</button>';
    }

    window.backupOpen = async function () {
        close();
        var ov = document.createElement('div'); ov.id = 'backup-ov';
        ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
        document.body.appendChild(ov);
        ov.addEventListener('mousedown', function (e) { if (e.target === ov) close(); });
        var note = '';
        async function draw() {
            var r; try { r = await (await fetch('backup.php?action=status')).json(); } catch (e) { r = null; }
            if (!r || !r.ok) { ov.innerHTML = '<div style="background:var(--bg-base);padding:18px;border-radius:6px;">' + esc(T('backup.err', 'Backup is not available here.')) + '</div>'; return; }
            var rows = r.backups.map(function (b) {
                var ver = b.verified ? (b.verified.ok ? T('backup.tested.ok', 'tested OK') : T('backup.tested.bad', 'FAILED its test')) : T('backup.untested', 'not tested yet');
                return '<tr><td style="padding:4px 6px;font-family:var(--font-mono);font-size:10.5px;">' + esc(b.file.replace('cockpit-backup-', '').replace('.tar.gz', '')) + (b.pre_restore ? ' <i>(' + esc(T('backup.pre', 'saved before a restore')) + ')</i>' : '') + '</td>' +
                    '<td style="padding:4px 6px;">' + esc(b.size) + (b.files != null ? ' · ' + b.files + ' ' + esc(T('backup.files', 'files')) : '') + '</td>' +
                    '<td style="padding:4px 6px;color:var(--text-muted);">' + esc(ver) + '</td>' +
                    '<td style="padding:4px 6px;white-space:nowrap;">' + btn('verify', b.file, T('backup.test', 'Test')) + ' ' + btn('restore', b.file, T('backup.restore', 'Restore'), 'danger') + ' <a class="action-btn" href="backup.php?action=download&file=' + encodeURIComponent(b.file) + '" style="padding:3px 9px;font-size:11px;text-decoration:none;">' + esc(T('backup.download', 'Download')) + '</a> ' + btn('delete', b.file, T('backup.delete', 'Delete')) + '</td></tr>';
            }).join('');
            ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(760px,94vw);max-height:90vh;overflow:auto;padding:18px;color:var(--text-primary);">' +
                '<h2 style="margin:0 0 8px;font-size:14px;">' + esc(T('backup.title', 'Backup & restore')) + '</h2>' +
                '<div style="font-size:12px;line-height:1.5;color:var(--text-base);">' + esc(T('backup.intro', 'One archive of your settings, library, chats and projects, as a plain .tar.gz you can open without Cockpit. Use it before a reinstall, a new machine, or a risky change.')) + '</div>' +
                '<div style="margin-top:10px;font-size:11.5px;line-height:1.8;">' +
                  '<label><input type="checkbox" id="bk-lib" checked> ' + esc(T('backup.g.library', 'Library (books, snippets, sources)')) + '</label><br>' +
                  '<label><input type="checkbox" id="bk-gen"> ' + esc(T('backup.g.generated', 'Generated images, audio and video (can be large)')) + '</label><br>' +
                  '<label><input type="checkbox" id="bk-keys"> ' + esc(T('backup.g.keys', 'API keys and account file (encrypted, but leave off unless you need them)')) + '</label>' +
                '</div>' +
                '<div style="margin-top:8px;font-size:10.5px;color:var(--text-dim);">' + esc(T('backup.would', 'A backup now holds about {n} files, {size}, before the optional parts. The Shelf index, Python environments and caches are never included — they can be rebuilt.', { n: r.would_contain.files, size: r.would_contain.size })) + '</div>' +
                '<div style="margin-top:10px;">' + btn('create', '', T('backup.create', 'Make a backup now'), 'primary') + '</div>' +
                (note ? '<div style="margin-top:10px;padding:8px;border:1px solid var(--border-mid);border-radius:4px;font-size:11.5px;">' + esc(note) + '</div>' : '') +
                '<h3 style="margin:14px 0 4px;font-size:12px;">' + esc(T('backup.existing', 'Your backups')) + '</h3>' +
                (rows ? '<table style="width:100%;font-size:11.5px;border-collapse:collapse;">' + rows + '</table>' : '<div style="font-size:11.5px;color:var(--text-muted);">' + esc(T('backup.none', 'None yet.')) + '</div>') +
                '<div style="margin-top:6px;font-size:10.5px;color:var(--text-dim);">' + esc(T('backup.where', 'Kept in {dir}', { dir: r.dir })) + '</div>' +
                '<div style="display:flex;justify-content:flex-end;margin-top:14px;">' + btn('close', '', T('backup.close', 'Close')) + '</div></div>';
            ov.querySelectorAll('[data-act]').forEach(function (b) { b.onclick = function () { act(b.dataset.act, b.dataset.file); }; });
        }
        async function act(a, file) {
            if (a === 'close') return close();
            if (a === 'create') {
                note = T('backup.working', 'Making the backup…'); await draw();
                var r = await post({ action: 'create', groups: { library: ov.querySelector('#bk-lib') ? ov.querySelector('#bk-lib').checked : true, generated: !!(ov.querySelector('#bk-gen') || {}).checked, keys: !!(ov.querySelector('#bk-keys') || {}).checked } });
                note = r.ok ? T('backup.made', 'Made {file} ({size}, {n} files). Press Test to prove it restores.', { file: r.file, size: r.size, n: r.files }) : (r.error || 'failed');
            } else if (a === 'verify') {
                note = T('backup.testing', 'Restoring into a scratch folder and comparing every file…'); await draw();
                var v = await post({ action: 'verify', file: file });
                note = v.message || v.error || 'failed'; if (v.problems && v.problems.length) note += ' — ' + v.problems.join('; ');
            } else if (a === 'restore') {
                if (!await cconfirm(T('backup.confirm', 'Restore this backup over your current data? The current state is saved first as a "pre-restore" backup, so you can undo it.'))) return;
                var s = await post({ action: 'restore', file: file, confirm: true });
                note = s.message || s.error || 'failed';
            } else if (a === 'delete') {
                if (!await cconfirm(T('backup.confirm.del', 'Delete this backup?'))) return;
                await post({ action: 'delete', file: file }); note = '';
            }
            draw();
        }
        draw();
    };
})();
