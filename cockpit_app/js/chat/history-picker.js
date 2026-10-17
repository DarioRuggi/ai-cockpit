// =============================================================================
// history-picker.js — the prompt History picker: filter hundreds of earlier prompts, then choose one.
//
// Open it with the History button in the prompt box, or Ctrl+R while the prompt box has the focus (the shell's
// "search history"). Type to filter (every word must be in the prompt, any order); ↑ ↓ choose; Enter puts the prompt in
// the box (it does not send it); Esc closes. The three tabs are the SCOPE of the history (this chat · this project ·
// everywhere), the same setting the ↑ ↓ keys use, and it is remembered. See PromptHistory in js/chat/agents.js.
// =============================================================================
(function () {
    'use strict';
    var SCOPES = [['chat', 'This chat'], ['project', 'This project'], ['all', 'Everywhere']];
    var box = null, sel = 0, rows = [];

    function ago(t) {
        if (!t) return '';
        var s = Math.max(0, Math.round((Date.now() - t) / 1000));
        if (s < 90) return T('hist.now', 'just now');
        if (s < 5400) return T('hist.min', '{n} min ago', { n: Math.round(s / 60) });
        if (s < 129600) return T('hist.hour', '{n} h ago', { n: Math.round(s / 3600) });
        return T('hist.day', '{n} d ago', { n: Math.round(s / 86400) });
    }
    function close() { if (box) { box.remove(); box = null; } document.removeEventListener('mousedown', outside, true); }
    function outside(e) { if (box && !box.contains(e.target) && !(e.target.closest && e.target.closest('#hist-btn'))) close(); }

    function choose(i) {
        var e = rows[i]; if (!e) return;
        var pi = document.getElementById('prompt-in'); close(); if (!pi) return;
        pi.value = e.text; pi.focus(); pi.setSelectionRange(e.text.length, e.text.length);
        pi.dispatchEvent(new Event('input', { bubbles: true }));
        if (typeof PromptHistory !== 'undefined') PromptHistory.resetCursor();
    }
    function paint() {
        var list = box.querySelector('.hp-list'), q = box.querySelector('input').value, sc = PromptHistory.scope();
        rows = PromptHistory.search(q, sc);
        list.textContent = '';
        if (!rows.length) {
            var d = document.createElement('div'); d.className = 'hp-empty';
            d.textContent = q.trim() ? T('hist.nomatch', 'No prompt matches “{q}”.', { q: q.trim() }) : T('hist.empty', 'Nothing here yet: prompts you send are kept for the next time.');
            list.appendChild(d); sel = 0; counts(); return;
        }
        if (sel >= rows.length) sel = rows.length - 1; if (sel < 0) sel = 0;
        rows.slice(0, 400).forEach(function (e, i) {
            var r = document.createElement('div'); r.className = 'hp-row' + (i === sel ? ' sel' : ''); r.dataset.i = i;
            var t = document.createElement('div'); t.className = 'hp-text'; t.textContent = e.text.replace(/\s+/g, ' ').slice(0, 300); t.title = e.text.slice(0, 1200);
            var m = document.createElement('div'); m.className = 'hp-meta';
            m.textContent = (sc === 'chat' ? '' : (sc === 'all' && e.p ? e.p + ' › ' : '') + (e.c || '') + ' · ') + ago(e.t);
            r.appendChild(t); r.appendChild(m);
            r.addEventListener('mouseenter', function () { sel = i; mark(); });
            r.addEventListener('click', function () { choose(i); });
            list.appendChild(r);
        });
        counts();
    }
    function mark() { [].forEach.call(box.querySelectorAll('.hp-row'), function (r) { r.classList.toggle('sel', +r.dataset.i === sel); }); }
    function counts() {
        var c = box.querySelector('.hp-count'); if (!c) return;
        c.textContent = rows.length > 400 ? T('hist.first400', 'first 400 of {n}', { n: rows.length }) : T('hist.n', '{n} prompts', { n: rows.length });
    }
    function tabs() {
        var bar = box.querySelector('.hp-tabs'); bar.textContent = ''; var sc = PromptHistory.scope();
        SCOPES.forEach(function (s) {
            var b = document.createElement('button'); b.type = 'button'; b.className = 'hp-tab' + (s[0] === sc ? ' on' : ''); b.textContent = T('hist.scope.' + s[0], s[1]);
            b.addEventListener('click', function () { PromptHistory.setScope(s[0]); sel = 0; tabs(); paint(); box.querySelector('input').focus(); });
            bar.appendChild(b);
        });
    }
    function step(d) {
        if (!rows.length) return; sel = (sel + d + Math.min(rows.length, 400)) % Math.min(rows.length, 400); mark();
        var r = box.querySelector('.hp-row.sel'); if (r) r.scrollIntoView({ block: 'nearest' });
    }

    window.historyPickerOpen = function () {
        if (box) { close(); return; }
        var pi = document.getElementById('prompt-in'); if (!pi || typeof PromptHistory === 'undefined') return;
        box = document.createElement('div'); box.id = 'hist-picker';
        box.innerHTML = '<div class="hp-head"><div class="hp-tabs"></div><span class="hp-count"></span></div>' +
            '<input type="search" autocomplete="off" class="hp-q">' +
            '<div class="hp-list"></div>' +
            '<div class="hp-foot"></div>';
        var q = box.querySelector('input'); q.placeholder = T('hist.filter', 'Filter your earlier prompts…');
        box.querySelector('.hp-foot').textContent = T('hist.keys', '↑ ↓ choose · Enter put it in the prompt box · Tab changes the scope · Esc closes');
        var r = pi.getBoundingClientRect(), w = Math.max(360, Math.min(760, r.width));
        box.style.cssText = 'left:' + Math.max(8, Math.min(r.left, innerWidth - w - 8)) + 'px;width:' + w + 'px;bottom:' + (innerHeight - r.top + 6) + 'px;';
        document.body.appendChild(box);
        tabs(); sel = 0; paint(); q.focus();
        document.addEventListener('mousedown', outside, true);
        q.addEventListener('input', function () { sel = 0; paint(); });
        q.addEventListener('keydown', function (e) {
            if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); pi.focus(); }
            else if (e.key === 'ArrowDown') { e.preventDefault(); step(1); }
            else if (e.key === 'ArrowUp') { e.preventDefault(); step(-1); }
            else if (e.key === 'Enter') { e.preventDefault(); choose(sel); }
            else if (e.key === 'Tab') {
                e.preventDefault(); var order = SCOPES.map(function (s) { return s[0]; }), i = order.indexOf(PromptHistory.scope());
                PromptHistory.setScope(order[(i + (e.shiftKey ? 2 : 1)) % 3]); sel = 0; tabs(); paint();
            }
        });
    };
    document.addEventListener('keydown', function (e) {           // Ctrl+R in the prompt box (and nowhere else): the shell's "search history"
        if (e.ctrlKey && !e.shiftKey && !e.altKey && !e.metaKey && (e.key === 'r' || e.key === 'R') && document.activeElement && document.activeElement.id === 'prompt-in') {
            e.preventDefault(); e.stopPropagation(); historyPickerOpen();
        }
    }, true);
})();
