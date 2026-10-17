// =============================================================================
// standards.js — Standards check for Lazarus / Free Pascal projects (the face of standards.php).
//
//   standardsOpen()   scans the current project (read-only): text typed into code instead of a
//                     resourcestring, Windows-only code outside an IFDEF, no dark/light switch,
//                     thin comments. Offers a generated resourcestring unit to copy.
// =============================================================================
(function () {
    'use strict';
    function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function close() { var o = document.getElementById('standards-ov'); if (o) o.remove(); }
    var NAMES = { strings: function () { return T('standards.rule.strings', 'Text typed into code'); }, portable: function () { return T('standards.rule.portable', 'Windows-only code'); },
                  theme: function () { return T('standards.rule.theme', 'Dark / light switch'); }, comments: function () { return T('standards.rule.comments', 'Comment density'); } };

    window.standardsOpen = async function () {
        close();
        var proj = (typeof currentProject === 'string' && currentProject) ? currentProject : '';
        var ov = document.createElement('div'); ov.id = 'standards-ov';
        ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
        ov.addEventListener('mousedown', function (e) { if (e.target === ov) close(); });
        ov.innerHTML = '<div style="background:var(--bg-base);padding:18px;border-radius:6px;">' + esc(T('standards.scanning', 'Checking the project…')) + '</div>';
        document.body.appendChild(ov);
        var r; try { r = await (await fetch('standards.php?project=' + encodeURIComponent(proj))).json(); } catch (e) { r = null; }
        if (!r || !r.ok) { ov.firstChild.textContent = (r && r.error) || T('standards.err', 'The check could not run.'); return; }
        var groups = {};
        r.findings.forEach(function (f) { (groups[f.rule] = groups[f.rule] || []).push(f); });
        var body = Object.keys(groups).map(function (k) {
            return '<h3 style="margin:12px 0 4px;font-size:12px;">' + esc((NAMES[k] ? NAMES[k]() : k)) + ' <span style="color:var(--text-muted);">(' + (r.counts[k] || groups[k].length) + ')</span></h3>' +
                '<div style="font-size:11px;line-height:1.6;font-family:var(--font-mono);">' + groups[k].slice(0, 40).map(function (f) {
                    return '<div><span style="color:var(--text-muted);">' + esc(f.file) + (f.line ? ':' + f.line : '') + '</span> ' + esc(f.message) + '</div>'; }).join('') +
                (groups[k].length > 40 ? '<div style="color:var(--text-muted);">… ' + esc(T('standards.more', '{n} more', { n: groups[k].length - 40 })) + '</div>' : '') + '</div>';
        }).join('');
        ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(820px,94vw);max-height:90vh;overflow:auto;padding:18px;color:var(--text-primary);">' +
            '<h2 style="margin:0 0 6px;font-size:14px;">' + esc(T('standards.title', 'Standards check')) + ' — ' + esc(proj) + '</h2>' +
            '<div style="font-size:12px;">' + esc(r.findings.length ? T('standards.summary', '{files} source files checked; {n} findings. Nothing was changed.', { files: r.files, n: Object.keys(r.counts).reduce(function (a, k) { return a + r.counts[k]; }, 0) }) : T('standards.clean', '{files} source files checked; nothing to report.', { files: r.files })) + '</div>' +
            body +
            '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px;">' +
              ((r.counts.strings || 0) ? '<button class="action-btn" id="st-res" style="padding:4px 11px;font-size:11px;">' + esc(T('standards.resources', 'Copy a resourcestring unit for the typed text')) + '</button>' : '') +
              '<button class="action-btn" id="st-close" style="padding:4px 11px;font-size:11px;">' + esc(T('standards.close', 'Close')) + '</button></div></div>';
        ov.querySelector('#st-close').onclick = close;
        var rb = ov.querySelector('#st-res');
        if (rb) rb.onclick = async function () {
            var t = await (await fetch('standards.php?resources=1&project=' + encodeURIComponent(proj))).text();
            try { await navigator.clipboard.writeText(t); rb.textContent = T('standards.copied', 'Copied — paste it into a new unit'); } catch (e) { rb.textContent = T('standards.copyfail', 'Copy failed'); }
        };
    };
})();
