// =============================================================================
// lang-ui.js — the two language pickers.
//
//   1. Settings → the translate button: the language Cockpit itself is shown in
//      (packs from lang.php; see js/core/i18n.js). English is the default.
//   2. Voice options → Language: the language you SPEAK, for whisper. This is a
//      different thing from (1) — you can read Cockpit in English and dictate in
//      Hebrew — so it has its own list: every language whisper knows (below), names
//      from the browser's own tables (Intl.DisplayNames) so they follow the UI language.
//      Default English (the old default, "Auto-detect", mis-heard Hebrew as other
//      languages); the choice is remembered.
// =============================================================================

// whisper.cpp's language codes (whisper-cli --help). Names come from Intl.DisplayNames.
var WHISPER_LANGS = ('en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su yue').split(' ');

(function () {
    'use strict';
    var VK = 'cockpit_voice_lang';
    function ls(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
    function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

    // ---- voice language ---------------------------------------------------------------
    window.voiceLangFill = function () {
        var sel = document.getElementById('mic-lang'); if (!sel) return;
        var keep = sel.value || ls(VK) || 'en';
        var lab = T('voice.language', 'Language');
        var rows = WHISPER_LANGS.map(function (c) { return { c: c, n: i18nName(c) }; });
        rows.sort(function (a, b) { return a.n.localeCompare(b.n, i18nLang()); });
        var html = '<option value="en">' + lab + ': ' + i18nName('en') + '</option>' +
                   '<option value="auto">' + lab + ': ' + T('voice.auto', 'Auto-detect') + '</option>';
        rows.forEach(function (r) { if (r.c !== 'en') html += '<option value="' + r.c + '">' + lab + ': ' + r.n + '</option>'; });
        sel.innerHTML = html;
        sel.value = (keep === 'auto' || WHISPER_LANGS.indexOf(keep) >= 0) ? keep : 'en';
    };
    document.addEventListener('DOMContentLoaded', function () {
        voiceLangFill();
        var sel = document.getElementById('mic-lang');
        if (sel) sel.addEventListener('change', function () { lsSet(VK, sel.value); });
    });
    document.addEventListener('cockpit-lang-changed', function () { voiceLangFill(); });

    // ---- UI language menu -------------------------------------------------------------
    function close() { var m = document.getElementById('lang-menu'); if (m) m.remove(); document.removeEventListener('mousedown', outside, true); }
    function outside(e) { var m = document.getElementById('lang-menu'); if (m && !m.contains(e.target)) close(); }
    function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

    window.langMenuOpen = function (ev) {
        if (ev) ev.stopPropagation();
        if (document.getElementById('lang-menu')) { close(); return; }
        var btn = document.getElementById('btn-lang'); if (!btn) return;
        var m = document.createElement('div'); m.id = 'lang-menu';
        m.style.cssText = 'position:fixed;z-index:10000;min-width:240px;max-width:320px;overflow:auto;background:var(--bg-base);' +
            'border:1px solid var(--border-mid);border-radius:6px;padding:6px;box-shadow:0 8px 24px rgba(0,0,0,.5);font-size:12px;color:var(--text-primary);';
        var r = btn.getBoundingClientRect();
        var room = innerHeight - r.bottom - 12;                   // never run off the bottom of the window
        if (room < 220 && r.top > room) { m.style.bottom = (innerHeight - r.top + 4) + 'px'; room = r.top - 12; }   // more space above: open upward
        else m.style.top = (r.bottom + 4) + 'px';
        m.style.maxHeight = Math.min(340, Math.max(160, room)) + 'px';   // compact: the window may extend past the visible screen
        m.style.left = Math.max(4, Math.min(r.left, innerWidth - 330)) + 'px';
        m.innerHTML = '<div style="padding:4px 6px;color:var(--text-muted)">…</div>';
        document.body.appendChild(m);
        document.addEventListener('mousedown', outside, true);
        i18nList(true).then(function (list) {
            var cur = i18nLang(), h = '<div style="padding:2px 6px 6px;font-weight:600">' + esc(T('lang.title', 'Language of Cockpit')) + '</div>';
            list.forEach(function (l) {
                var on = l.code === cur;
                h += '<div class="lang-row" data-code="' + esc(l.code) + '" style="display:flex;justify-content:space-between;gap:10px;padding:4px 6px;cursor:pointer;border-radius:4px;' +
                     (on ? 'background:var(--bg-card);font-weight:600;' : '') + '">' +
                     '<span>' + (on ? '✓ ' : '') + esc(l.native) + (l.native !== l.name ? ' <span style="color:var(--text-muted)">· ' + esc(l.name) + '</span>' : '') + '</span>' +
                     '<span style="color:var(--text-muted)">' + (l.coverage < 100 ? l.coverage + '%' : '') + '</span></div>';
            });
            h += '<div style="border-top:1px solid var(--border-dim);margin:6px 0 4px"></div>' +
                 '<div class="lang-studio" style="padding:5px 6px;cursor:pointer;border-radius:4px;font-weight:600;display:flex;gap:6px;align-items:center;" data-help="language"><span class="material-symbols-rounded" style="font-size:16px;color:var(--accent-blue)">translate</span>' + esc(T('lang.studio', 'Translate Cockpit…')) + '</div>' +
                 '<div style="padding:0 6px 4px;color:var(--text-muted);font-size:11px">' + esc(T('lang.studio.tip', 'Add a language or finish one, right here.')) + '</div>' +
                 '<div style="padding:2px 6px 4px;font-size:11px"><a href="lang.php?action=template" style="color:var(--accent,#6cf)" title="' + esc(T('lang.template.tip', 'The empty file with the rules and how to send it back. Put the finished file in:') + ' ' + (list.folder || '')) + '">' + esc(T('lang.template.small', 'Or download the empty template')) + '</a></div>';
            m.innerHTML = h;
            var st = m.querySelector('.lang-studio'); if (st) { st.onmouseenter = function () { st.style.background = 'var(--bg-card)'; }; st.onmouseleave = function () { st.style.background = ''; }; st.onclick = function () { close(); if (window.translateStudioOpen) translateStudioOpen(cur !== 'en' ? cur : ''); }; }
            m.querySelectorAll('.lang-row').forEach(function (row) {
                row.onmouseenter = function () { row.style.background = 'var(--bg-card)'; };
                row.onmouseleave = function () { row.style.background = row.dataset.code === cur ? 'var(--bg-card)' : ''; };
                row.onclick = function () { close(); i18nSet(row.dataset.code); };
            });
        });
    };

    // ---- the voice Language list as a menu that fits ------------------------------------
    // A native <select> of 99 languages opens at the prompt (bottom of the window) and its list
    // runs off the screen; the browser draws it and offers no way to reposition it. So the
    // select stays (it holds the value and the saved choice) but its list is ours: it opens
    // upward when low on the screen, scrolls inside 340px, and is searchable by typing.
    function pickMenu(anchor, sel) {
        var old = document.getElementById('pick-menu'); if (old) { old.remove(); return; }
        var m = document.createElement('div'); m.id = 'pick-menu';
        m.style.cssText = 'position:fixed;z-index:10001;min-width:220px;overflow:auto;background:var(--bg-base);border:1px solid var(--border-mid);' +
            'border-radius:6px;padding:4px;box-shadow:0 8px 24px rgba(0,0,0,.5);font-size:12px;color:var(--text-primary);';
        var r = anchor.getBoundingClientRect(), below = innerHeight - r.bottom - 12, above = r.top - 12;
        var up = below < 220 && above > below, room = up ? above : below;
        m.style.maxHeight = Math.min(340, Math.max(160, room)) + 'px';
        if (up) m.style.bottom = (innerHeight - r.top + 4) + 'px'; else m.style.top = (r.bottom + 4) + 'px';
        m.style.left = Math.max(4, Math.min(r.left, innerWidth - 240)) + 'px';
        var buf = '', t0 = 0;
        Array.prototype.forEach.call(sel.options, function (o) {
            var d = document.createElement('div'); d.textContent = o.textContent; d.dataset.v = o.value;
            d.style.cssText = 'padding:3px 8px;cursor:pointer;border-radius:4px;white-space:nowrap;' + (o.value === sel.value ? 'background:var(--bg-card);font-weight:600;' : '');
            d.onmouseenter = function () { d.style.background = 'var(--bg-card)'; };
            d.onmouseleave = function () { d.style.background = o.value === sel.value ? 'var(--bg-card)' : ''; };
            d.onclick = function () { sel.value = o.value; sel.dispatchEvent(new Event('change', { bubbles: true })); done(); };
            m.appendChild(d);
        });
        function done() { m.remove(); document.removeEventListener('mousedown', out, true); document.removeEventListener('keydown', key, true); }
        function out(e) { if (!m.contains(e.target)) done(); }
        function key(e) {                                   // Esc closes; typing jumps to the first match
            if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(); return; }
            if (e.key.length !== 1) return;
            var now = Date.now(); buf = (now - t0 > 900 ? '' : buf) + e.key.toLowerCase(); t0 = now;
            for (var i = 0; i < m.children.length; i++) {
                var txt = m.children[i].textContent.toLowerCase(), k = txt.indexOf(': '), name = k >= 0 ? txt.slice(k + 2) : txt;
                if (name.indexOf(buf) === 0) { m.children[i].scrollIntoView({ block: 'nearest' }); break; }
            }
        }
        m.addEventListener('mousedown', function (e) { e.stopPropagation(); });
        m.addEventListener('click', function (e) { e.stopPropagation(); });
        document.body.appendChild(m);
        document.addEventListener('mousedown', out, true); document.addEventListener('keydown', key, true);
        var cur = m.querySelector('[data-v="' + sel.value + '"]'); if (cur) cur.scrollIntoView({ block: 'nearest' });
    }
    document.addEventListener('DOMContentLoaded', function () {
        var sel = document.getElementById('mic-lang'); if (!sel) return;
        sel.addEventListener('mousedown', function (e) { e.preventDefault(); sel.focus(); pickMenu(sel, sel); });
        sel.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowDown') { e.preventDefault(); pickMenu(sel, sel); } });
    });
})();
