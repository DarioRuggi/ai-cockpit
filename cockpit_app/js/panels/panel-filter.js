// =============================================================================
// panel-filter.js — a filter box on every list in the two sidebars, and Find inside the Preview.
//
// Chats, Projects, Notes, Library, Snippets and Sources already had a search; the rest (Files, Code, Config, Capabilities,
// Plans, Artifacts, Attachments, Usage, Proposals, Toolbar and the web-search RESULTS) did not. One small piece of code now
// puts the same box on each of them (2026-10-17): it hides what does not match (every word you type must be in the row,
// any order), says "Nothing matches" when it hides everything, and keeps working when the panel redraws itself.
//
// Hiding uses a class (.pf-hide), never inline display, so what a panel hides for its own reasons stays hidden.
// The Preview gets a find bar (Ctrl+F while the Preview has the focus, or its magnifier): highlights, count, next/previous.
// =============================================================================
(function () {
    'use strict';
    var PANELS = [
        { panel: 'left-filetree',      list: '#filetree-list',       mode: 'tree', after: '.sidebar-actions' },
        { panel: 'right-code',         list: '#rp-list-code',        after: '.rp-toolbar' },
        { panel: 'right-config',       list: '#rp-list-config',      group: '.rp-cfg-group', items: '.rp-cfg-file', after: '.rp-toolbar' },
        { panel: 'right-capabilities', list: '#rp-list-capabilities', after: '.rp-toolbar' },
        { panel: 'right-plans',        list: '#rp-list-plans',       after: '.rp-toolbar' },
        { panel: 'right-artifacts',    list: '#artifacts-list',      after: '.rp-toolbar' },
        { panel: 'right-attachments',  list: '#rp-list-attachments', after: '.rp-toolbar' },
        { panel: 'right-usage',        list: '#rp-list-usage',       after: '.rp-toolbar' },
        { panel: 'right-search',       list: '#rp-list-search',      after: '.rp-toolbar', ph: 'Filter these results…' },
        { panel: 'right-proposals',    list: '#rp-proposals-list',   items: '.rp-proposal', before: true },
        { panel: 'right-toolbar',      list: '__toolbar__',          items: 'button', after: '.rp-proposals-hdr' }
    ];

    function words(s) { return String(s || '').toLowerCase().split(/\s+/).filter(Boolean); }
    function textOf(e) { return ((e.textContent || '') + ' ' + (e.title || '') + ' ' + (e.getAttribute('data-help') || '')).toLowerCase(); }
    function hit(e, toks) { if (!toks.length) return true; var t = textOf(e); return toks.every(function (w) { return t.indexOf(w) >= 0; }); }

    function attach(c) {
        var panel = document.getElementById(c.panel); if (!panel || panel.querySelector(':scope > .pf-bar')) return;
        var list = c.list === '__toolbar__' ? panel.querySelector(':scope > div[style*="overflow-y:auto"]') : panel.querySelector(c.list);
        if (!list) return;
        var bar = document.createElement('div'); bar.className = 'pf-bar';
        var inp = document.createElement('input'); inp.type = 'search'; inp.className = 'sb-filter pf-input';
        inp.placeholder = T('pf.filter', c.ph || 'Filter…'); inp.setAttribute('aria-label', inp.placeholder); inp.autocomplete = 'off';
        bar.appendChild(inp);
        var anchor = c.after ? panel.querySelector(':scope > ' + c.after) : null;
        if (anchor) anchor.insertAdjacentElement('afterend', bar);
        else if (c.before && list.parentElement) list.parentElement.insertBefore(bar, list);
        else panel.insertBefore(bar, panel.firstElementChild ? panel.firstElementChild.nextElementSibling : null);
        var st = { c: c, list: list, inp: inp, busy: false, timer: 0 };
        function run() { st.busy = true; try { apply(st); } finally { st.busy = false; obs.takeRecords(); } }
        var obs = new MutationObserver(function () { if (st.busy) return; clearTimeout(st.timer); st.timer = setTimeout(run, 60); });
        obs.observe(list, { childList: true, subtree: c.mode === 'tree' });
        inp.addEventListener('input', run);
        inp.addEventListener('keydown', function (e) { if (e.key === 'Escape') { e.stopPropagation(); if (inp.value) { inp.value = ''; run(); } else inp.blur(); } });
    }

    function apply(st) {
        var toks = words(st.inp.value), list = st.list;
        var old = list.querySelector(':scope > .pf-nomatch'); if (old) old.remove();
        var shown = 0, total = 0;
        if (st.c.mode === 'tree') { var r = tree(list, toks); shown = r.shown; total = r.total; }
        else {
            var sel = st.c.items || ':scope > *';
            var all = [].slice.call(list.querySelectorAll(sel)).filter(function (e) { return !e.classList.contains('pf-nomatch') && !e.classList.contains('sidebar-empty'); });
            if (st.c.group) {
                [].forEach.call(list.querySelectorAll(st.c.group), function (g) {
                    var hdr = g.querySelector(':scope > [class*="hdr"]'), hdrOk = !!(hdr && toks.length && hit(hdr, toks));
                    var kids = [].slice.call(g.querySelectorAll(sel)), any = false;
                    kids.forEach(function (k) { var ok = hdrOk || hit(k, toks); k.classList.toggle('pf-hide', !ok); if (ok) any = true; total++; if (ok) shown++; });
                    g.classList.toggle('pf-hide', toks.length > 0 && !any && !hdrOk);
                });
            } else {
                all.forEach(function (e) { var ok = hit(e, toks); e.classList.toggle('pf-hide', !ok); total++; if (ok) shown++; });
            }
        }
        if (toks.length && total && !shown) {
            var h = document.createElement('div'); h.className = 'pf-nomatch'; h.style.cssText = 'padding:10px 12px;font-size:11px;color:var(--text-muted);';
            h.textContent = T('sb.nomatch', 'Nothing matches “{q}”.', { q: st.inp.value.trim() }); list.appendChild(h);
        }
    }

    // The file tree: a file row shows when its name matches; a folder shows when its own name or anything under it matches, and opens while you filter.
    function tree(root, toks) {
        var shown = 0, total = 0;
        (function walk(box) {
            var kids = [].slice.call(box.children), any = false;
            kids.forEach(function (n, i) {
                if (!n.classList || !n.classList.contains('ft-item')) return;
                if (n.classList.contains('ft-dir')) {
                    var sub = kids[i + 1] && kids[i + 1].classList && kids[i + 1].classList.contains('ft-children') ? kids[i + 1] : null;
                    var inner = sub ? walk(sub) : false, own = hit(n, toks), ok = !toks.length || own || inner;
                    n.classList.toggle('pf-hide', !ok); if (sub) {
                        sub.classList.toggle('pf-hide', !ok);
                        if (toks.length && ok && inner) { if (sub.dataset.pfOpen === undefined) sub.dataset.pfOpen = sub.style.display; sub.style.display = 'block'; }
                        else if (sub.dataset.pfOpen !== undefined) { sub.style.display = sub.dataset.pfOpen; delete sub.dataset.pfOpen; }
                    }
                    total++; if (ok) { shown++; any = true; }
                } else { var okf = hit(n, toks); n.classList.toggle('pf-hide', !okf); total++; if (okf) { shown++; any = true; } }
            });
            return any;
        })(root);
        return { shown: shown, total: total };
    }

    // ---- Find inside the Preview ------------------------------------------------------------
    var PV = { hits: [], cur: -1, bar: null };
    function pvPanel() { return document.getElementById('right-preview'); }
    function pvRoots() {
        var p = pvPanel(), r = [p];
        [].forEach.call(p.querySelectorAll('iframe'), function (f) { try { if (f.contentDocument && f.contentDocument.body) r.push(f.contentDocument.body); } catch (e) {} });
        return r;
    }
    function pvClear() {
        pvRoots().forEach(function (root) {
            [].forEach.call(root.querySelectorAll('mark.pf-hit'), function (m) { var t = document.createTextNode(m.textContent); m.parentNode.replaceChild(t, m); if (t.parentNode) t.parentNode.normalize(); });
        });
        PV.hits = []; PV.cur = -1;
    }
    function pvFind(q) {
        pvClear();
        var toks = String(q || '').trim(); if (!toks) { pvCount(); return; }
        var needle = toks.toLowerCase();
        pvRoots().forEach(function (root) {
            var doc = root.ownerDocument, w = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT, { acceptNode: function (n) {
                var p = n.parentNode; if (!p || /^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA)$/.test(p.nodeName) || (p.closest && p.closest('.pf-pvbar'))) return NodeFilter.FILTER_REJECT;
                return n.nodeValue && n.nodeValue.toLowerCase().indexOf(needle) >= 0 ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT; } });
            var nodes = []; while (w.nextNode() && nodes.length < 4000) nodes.push(w.currentNode);
            nodes.forEach(function (n) {
                var s = n.nodeValue, low = s.toLowerCase(), i = 0, last = 0, frag = doc.createDocumentFragment(), found = false;
                while ((i = low.indexOf(needle, last)) >= 0 && PV.hits.length < 3000) {
                    found = true; frag.appendChild(doc.createTextNode(s.slice(last, i)));
                    var m = doc.createElement('mark'); m.className = 'pf-hit'; m.textContent = s.slice(i, i + needle.length); frag.appendChild(m); PV.hits.push(m); last = i + needle.length;
                }
                if (found) { frag.appendChild(doc.createTextNode(s.slice(last))); n.parentNode.replaceChild(frag, n); }
            });
        });
        PV.cur = -1; pvStep(1);
    }
    function pvCount() {
        if (!PV.bar) return; var c = PV.bar.querySelector('.pf-pvcount'), q = PV.bar.querySelector('input').value.trim();
        c.textContent = !q ? '' : (PV.hits.length ? (PV.cur + 1) + ' / ' + PV.hits.length : T('pf.pv.none', 'No match'));
    }
    function pvStep(d) {
        if (!PV.hits.length) { pvCount(); return; }
        if (PV.cur >= 0 && PV.hits[PV.cur]) PV.hits[PV.cur].classList.remove('pf-cur');
        PV.cur = (PV.cur + d + PV.hits.length) % PV.hits.length;
        var m = PV.hits[PV.cur]; m.classList.add('pf-cur'); try { m.scrollIntoView({ block: 'center', inline: 'nearest' }); } catch (e) {}
        pvCount();
    }
    function pvBar() {
        var p = pvPanel(); if (!p) return;
        if (PV.bar && p.contains(PV.bar)) return PV.bar;
        var b = document.createElement('div'); b.className = 'pf-pvbar';
        b.innerHTML = '<span class="material-symbols-rounded" style="font-size:15px;color:var(--text-muted)">search</span>' +
            '<input type="search" autocomplete="off" aria-label="Find in the preview">' +
            '<span class="pf-pvcount"></span>' +
            '<button type="button" class="pf-prev" title="Previous (Shift+Enter)"><span class="material-symbols-rounded">keyboard_arrow_up</span></button>' +
            '<button type="button" class="pf-next" title="Next (Enter)"><span class="material-symbols-rounded">keyboard_arrow_down</span></button>';
        var inp = b.querySelector('input'); inp.placeholder = T('pf.pv.find', 'Find in the preview…');
        b.querySelector('.pf-prev').title = T('pf.pv.prev', 'Previous (Shift+Enter)'); b.querySelector('.pf-next').title = T('pf.pv.next', 'Next (Enter)');
        inp.addEventListener('input', function () { clearTimeout(PV.t); PV.t = setTimeout(function () { pvFind(inp.value); }, 150); });
        inp.addEventListener('keydown', function (e) {
            if (e.key === 'Enter') { e.preventDefault(); if (!PV.hits.length) pvFind(inp.value); else pvStep(e.shiftKey ? -1 : 1); }
            else if (e.key === 'Escape') { e.stopPropagation(); if (inp.value) { inp.value = ''; pvClear(); pvCount(); } else inp.blur(); }
        });
        b.querySelector('.pf-prev').addEventListener('click', function () { pvStep(-1); });
        b.querySelector('.pf-next').addEventListener('click', function () { pvStep(1); });
        p.insertBefore(b, p.firstChild); PV.bar = b; return b;
    }
    function pvKeep() {            // the Preview redraws itself by replacing its content: put the bar back on top, drop stale highlights
        var p = pvPanel(); if (!p) return;
        new MutationObserver(function () {
            if (!PV.bar || !p.contains(PV.bar)) { var inp = PV.bar && PV.bar.querySelector('input'), v = inp ? inp.value : ''; PV.bar = null; var nb = pvBar(); PV.hits = []; PV.cur = -1; if (v) { nb.querySelector('input').value = v; pvFind(v); } }
        }).observe(p, { childList: true });
    }
    document.addEventListener('keydown', function (e) {                         // Ctrl+F with the focus inside the Preview opens its find bar
        if (!(e.ctrlKey && !e.shiftKey && !e.altKey && (e.key === 'f' || e.key === 'F'))) return;
        var p = pvPanel(); if (!p || !p.contains(document.activeElement) && !(p.classList.contains('active') && document.activeElement === document.body)) return;
        e.preventDefault(); e.stopImmediatePropagation(); var b = pvBar(); var i = b.querySelector('input'); i.focus(); i.select();
    }, true);

    function init() {
        PANELS.forEach(attach); pvBar(); pvKeep();
        var p = pvPanel(); if (p) p.addEventListener('dblclick', function (e) { if (e.target === p) { var i = pvBar().querySelector('input'); i.focus(); } });
    }
    window.panelFilterInit = init;
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', function () { setTimeout(init, 400); }); else setTimeout(init, 400);
})();
