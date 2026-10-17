// =============================================================================
// dropdown.js — Cockpit's own drop-down list for every <select>.
//
// Why: an opened <select> is drawn by the operating system (in the native window, a GTK menu), so it ignored every
// theme: wrong colours, wrong font, and no room for anything but plain text. This replaces ONLY the opened list.
//
// How (and why it is safe): the <select> element itself stays exactly where it is, so layout, sizing, labels, `.value`,
// `.options`, `selectedIndex`, `disabled` and every existing `onchange` handler keep working untouched. One set of
// listeners on the document (so selects created later are covered too) stops the system popup from opening and shows
// our list instead; choosing an entry sets the select's value and fires the same `input` and `change` events a person
// choosing in the system list would.
//
// What the list does:  groups (optgroup) with their labels · disabled entries · a check mark AND bold for the chosen
// one (never colour alone) · optional right-hand tag (data-dd-meta) and colour swatches (data-dd-swatch="#111,#eee,#48f")
// on an <option> · opens upward when there is no room below · keyboard: ↑ ↓ Home End PageUp PageDown, Enter / Space to
// choose, Esc to cancel, Tab leaves, typing jumps to a match · screen readers: listbox / option roles, aria-expanded,
// aria-activedescendant · the look is the Ollama model picker's (theme variables, a sticky header per group, tinted chosen
// row), legible in every theme, Mixed ones included (css/base.css makes the list a dark area there) · right-to-left aware.
//
// Left alone on purpose: <select multiple>, <select size=N>, selects marked data-native, and touch devices (a phone's own
// picker is the better control there). Opt-out for a person who prefers the system list: in the browser console,
// localStorage.setItem('ck.nativeSelects','1')  (and removeItem to undo).
// =============================================================================
(function () {
    'use strict';
    if (window.ckDropdown) return;

    var st = null;                       // the open list: { sel, panel, items, active, typed, typedAt, timer }
    var seq = 0;

    function fine() {
        try { return !window.matchMedia || window.matchMedia('(hover: hover) and (pointer: fine)').matches; } catch (e) { return true; }
    }
    function optedOut() {
        try { return window.localStorage && window.localStorage.getItem('ck.nativeSelects') === '1'; } catch (e) { return false; }
    }
    function eligible(sel) {
        if (!sel || sel.tagName !== 'SELECT') return false;
        if (sel.multiple || sel.size > 1 || sel.disabled || sel.hasAttribute('data-native')) return false;
        if (!sel.getClientRects().length) return false;
        return fine() && !optedOut();
    }

    // ---- building the list -------------------------------------------------------------------------------------
    function collect(sel) {
        var items = [];
        function addOption(o, inGroupDisabled) {
            items.push({ type: 'opt', opt: o, disabled: !!(o.disabled || inGroupDisabled), text: o.textContent || '', meta: o.dataset ? (o.dataset.ddMeta || '') : '',
                         swatch: o.dataset && o.dataset.ddSwatch ? o.dataset.ddSwatch.split(',') : null, title: o.title || '' });
        }
        Array.prototype.forEach.call(sel.children, function (c) {
            if (c.tagName === 'OPTGROUP') {
                items.push({ type: 'group', text: c.label || '' });
                Array.prototype.forEach.call(c.children, function (o) { if (o.tagName === 'OPTION') addOption(o, c.disabled); });
            } else if (c.tagName === 'OPTION') addOption(c, false);
        });
        return items;
    }
    function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

    function open(sel) {
        close(true);
        var items = collect(sel);
        if (!items.some(function (i) { return i.type === 'opt'; })) return;
        var cs = getComputedStyle(sel);
        var panel = el('div', 'ck-dd-panel');
        panel.id = 'ck-dd-' + (++seq);
        panel.setAttribute('role', 'listbox');
        if (sel.getAttribute('aria-label')) panel.setAttribute('aria-label', sel.getAttribute('aria-label'));
        // look: the theme's own variables (see css/ui-polish.css), the same as the Ollama model picker; only the size follows the select
        panel.style.fontSize = Math.max(11, parseFloat(cs.fontSize) || 12) + 'px';
        panel.dir = cs.direction || document.dir || 'ltr';
        // a select that lives on a supplier card borrows that card's agent colour (border, tint, chosen row)
        var card = sel.closest ? sel.closest(".sup-card") : null, ag = card && /sup-(claude|gemini|ollama|workers|tools)/.exec(card.className);
        if (ag) { panel.setAttribute("data-agent", ag[1]); panel.style.setProperty("--dd-accent", "var(--" + ag[1] + ")"); }

        var chosen = sel.selectedIndex;
        items.forEach(function (it, i) {
            if (it.type === 'group') { panel.appendChild(el('div', 'ck-dd-group', it.text)); return; }
            var row = el('div', 'ck-dd-opt');
            row.id = panel.id + '-' + i;
            row.setAttribute('role', 'option');
            if (it.disabled) { row.classList.add('disabled'); row.setAttribute('aria-disabled', 'true'); }
            var isChosen = it.opt.index === chosen;
            if (isChosen) { row.classList.add('chosen'); row.setAttribute('aria-selected', 'true'); } else row.setAttribute('aria-selected', 'false');
            row.appendChild(el('span', 'ck-dd-check', isChosen ? '✓' : ''));
            if (it.swatch) {
                var sw = el('span', 'ck-dd-swatch'); sw.setAttribute('aria-hidden', 'true');
                it.swatch.forEach(function (c) { var b = el('i'); b.style.background = c; sw.appendChild(b); });
                row.appendChild(sw);
            }
            row.appendChild(el('span', 'ck-dd-label', it.text));
            if (it.meta) row.appendChild(el('span', 'ck-dd-meta', it.meta));
            if (it.title) row.title = it.title;
            it.el = row; it.index = i;
            row.addEventListener('mousemove', function () { if (!it.disabled && st && st.active !== i) setActive(i, false); });
            row.addEventListener('mousedown', function (e) { e.preventDefault(); });          // keep focus on the select
            row.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); if (!it.disabled) choose(i); });
            panel.appendChild(row);
        });
        document.body.appendChild(panel);
        st = { sel: sel, panel: panel, items: items, active: -1, typed: '', typedAt: 0, timer: null };
        sel.setAttribute('aria-expanded', 'true');
        sel.setAttribute('aria-controls', panel.id);
        place();
        var start = items.findIndex(function (it) { return it.type === 'opt' && it.opt.index === chosen && !it.disabled; });
        if (start < 0) start = next(-1, 1);
        setActive(start, true);
        // watching: a click elsewhere, a scroll, a resize, the select vanishing
        document.addEventListener('mousedown', onOutside, true);
        document.addEventListener('keydown', onKey, true);
        window.addEventListener('resize', place);
        document.addEventListener('scroll', onScroll, true);
        st.timer = setInterval(function () { if (!st) return; if (!document.contains(st.sel) || !st.sel.getClientRects().length || st.sel.disabled) close(); }, 300);
    }

    function place() {
        if (!st) return;
        var sel = st.sel, p = st.panel, r = sel.getBoundingClientRect();
        var vw = document.documentElement.clientWidth, vh = document.documentElement.clientHeight;
        p.style.minWidth = Math.round(r.width) + 'px';
        p.style.maxWidth = Math.min(560, vw - 16) + 'px';
        p.style.maxHeight = 'none';
        p.style.left = '0px'; p.style.top = '0px';
        var h = p.offsetHeight, w = p.offsetWidth;
        var below = vh - r.bottom - 8, above = r.top - 8;
        var up = h > below && above > below;
        var room = Math.max(80, up ? above : below);
        p.style.maxHeight = Math.min(room, Math.round(vh * 0.7)) + 'px';
        h = p.offsetHeight;
        var rtl = p.dir === 'rtl';
        var left = rtl ? r.right - w : r.left;
        left = Math.max(8, Math.min(left, vw - w - 8));
        p.style.left = Math.round(left) + 'px';
        p.style.top = Math.round(up ? Math.max(8, r.top - h - 3) : r.bottom + 3) + 'px';
        p.classList.toggle('up', up);
    }

    function close(silent) {
        if (!st) return;
        var s = st; st = null;
        clearInterval(s.timer);
        document.removeEventListener('mousedown', onOutside, true);
        document.removeEventListener('keydown', onKey, true);
        window.removeEventListener('resize', place);
        document.removeEventListener('scroll', onScroll, true);
        s.panel.remove();
        s.sel.removeAttribute('aria-expanded'); s.sel.removeAttribute('aria-controls'); s.sel.removeAttribute('aria-activedescendant');
        if (!silent) { try { s.sel.focus({ preventScroll: true }); } catch (e) {} }
    }

    // ---- moving and choosing ------------------------------------------------------------------------------------
    function next(from, dir) {
        var i = from + dir, n = st.items.length;
        while (i >= 0 && i < n) { var it = st.items[i]; if (it.type === 'opt' && !it.disabled) return i; i += dir; }
        return -1;
    }
    function setActive(i, center) {
        if (!st || i < 0) return;
        if (st.active >= 0 && st.items[st.active] && st.items[st.active].el) st.items[st.active].el.classList.remove('active');
        st.active = i;
        var row = st.items[i].el;
        row.classList.add('active');
        st.sel.setAttribute('aria-activedescendant', row.id);
        var p = st.panel, top = row.offsetTop, bot = top + row.offsetHeight;
        if (center) p.scrollTop = Math.max(0, top - (p.clientHeight - row.offsetHeight) / 2);
        else if (top < p.scrollTop) p.scrollTop = top;
        else if (bot > p.scrollTop + p.clientHeight) p.scrollTop = bot - p.clientHeight;
    }
    function choose(i) {
        if (!st) return;
        var sel = st.sel, it = st.items[i];
        if (!it || it.type !== 'opt' || it.disabled) return;
        var changed = sel.selectedIndex !== it.opt.index;
        close();
        if (!changed) return;
        sel.selectedIndex = it.opt.index;
        sel.dispatchEvent(new Event('input', { bubbles: true }));
        sel.dispatchEvent(new Event('change', { bubbles: true }));
    }

    // ---- events while open --------------------------------------------------------------------------------------
    function onOutside(e) { if (st && !st.panel.contains(e.target) && e.target !== st.sel) close(true); else if (st && e.target === st.sel) { /* handled by the opener */ } }
    function onScroll(e) { if (!st) return; if (st.panel.contains(e.target)) return; place(); }
    function onKey(e) {
        if (!st) return;
        var k = e.key, it;
        function eat() { e.preventDefault(); e.stopPropagation(); }
        if (k === 'ArrowDown') { eat(); var n = next(st.active, 1); if (n >= 0) setActive(n); }
        else if (k === 'ArrowUp') { eat(); var m = next(st.active, -1); if (m >= 0) setActive(m); }
        else if (k === 'Home') { eat(); var f = next(-1, 1); if (f >= 0) setActive(f); }
        else if (k === 'End') { eat(); var l = next(st.items.length, -1); if (l >= 0) setActive(l); }
        else if (k === 'PageDown' || k === 'PageUp') {
            eat(); var dir = k === 'PageDown' ? 1 : -1, j = st.active;
            for (var c = 0; c < 8; c++) { var q = next(j, dir); if (q < 0) break; j = q; }
            if (j >= 0) setActive(j);
        }
        else if (k === 'Enter' || k === ' ') {
            if (k === ' ' && st.typed) { st.typed += ' '; st.typedAt = Date.now(); eat(); return; }     // a space inside a type-ahead word
            eat(); choose(st.active);
        }
        else if (k === 'Escape') { eat(); close(); }
        else if (k === 'Tab') { close(true); }
        else if (k.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) {
            eat();
            var now = Date.now();
            st.typed = (now - st.typedAt > 700 ? '' : st.typed) + k.toLowerCase(); st.typedAt = now;
            var n2 = st.items.length, start = st.active >= 0 ? st.active : 0, hit = -1, i2, cand;
            var from = (st.typed.length === 1) ? start + 1 : start;       // the first letter moves on to the NEXT match, more letters refine the current one
            for (i2 = 0; i2 < n2; i2++) {
                cand = st.items[(from + i2) % n2];
                if (cand.type === 'opt' && !cand.disabled && cand.text.trim().toLowerCase().indexOf(st.typed) === 0) { hit = (from + i2) % n2; break; }
            }
            if (hit >= 0) setActive(hit);
        }
    }

    // ---- opening it: the system popup is stopped, ours is shown ---------------------------------------------------------
    document.addEventListener('mousedown', function (e) {
        if (e.button !== 0 || e.defaultPrevented) return;
        var s = e.target && e.target.closest ? e.target.closest('select') : null;
        if (!s || !eligible(s)) return;
        e.preventDefault();                                                // no system popup
        try { s.focus({ preventScroll: true }); } catch (x) {}
        if (st && st.sel === s) close(); else open(s);
    }, true);
    document.addEventListener('keydown', function (e) {
        if (st || e.defaultPrevented) return;
        var s = e.target;
        if (!s || s.tagName !== 'SELECT' || !eligible(s)) return;
        if (e.key === ' ' || e.key === 'Enter' || e.key === 'F4' || ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && e.altKey)) {
            e.preventDefault(); e.stopPropagation(); open(s);
        }
    }, true);

    window.ckDropdown = { open: open, close: function () { close(); }, isOpen: function () { return !!st; }, eligible: eligible };
})();

// =============================================================================
// Lists that live INSIDE a card (the Ollama, LocalAI, Workers and Tools pickers: .custom-select-panel) are positioned on the screen, but they stay in
// the stacking layer of the card they belong to, and that layer sits below the chat area: an open list was drawn UNDER the chat (found 2026-10-07).
// While such a list is open it is shown in the browser's top layer (Popover API: above every layer and clip); where that is unavailable, every enclosing
// layer is lifted above everything else instead, and put back exactly as it was when the list closes.
// Done once here for every list by watching the lists' own "open" class, not by touching each picker.
// =============================================================================
(function () {
    const LIFT_Z = '100000';
    const saved = new WeakMap();          // element -> {z, pos}
    function makesLayer(cs) {
        return (cs.position !== 'static' && cs.zIndex !== 'auto') || parseFloat(cs.opacity) < 1 || (cs.transform && cs.transform !== 'none') ||
               (cs.filter && cs.filter !== 'none') || cs.isolation === 'isolate' || /paint|layout|strict|content/.test(cs.contain || '') ||
               (cs.position === 'fixed' || cs.position === 'sticky');
    }
    window.ckLiftLayers = function (panel, on) {
        for (let a = panel.parentElement; a && a !== document.body && a !== document.documentElement; a = a.parentElement) {
            if (on) {
                if (saved.has(a)) continue;
                const cs = getComputedStyle(a);
                if (!makesLayer(cs)) continue;
                saved.set(a, { z: a.style.zIndex, pos: a.style.position });
                if (cs.position === 'static') a.style.position = 'relative';      // z-index only counts on a positioned element
                a.style.zIndex = LIFT_Z;
            } else if (saved.has(a)) {
                const s = saved.get(a); a.style.zIndex = s.z; a.style.position = s.pos; saved.delete(a);
            }
        }
    };
    function watch() {
        new MutationObserver(muts => {
            muts.forEach(m => {
                const t = m.target;
                if (!(t instanceof HTMLElement) || !t.classList.contains('custom-select-panel')) return;
                const open = t.classList.contains('open');
                // The browser's TOP LAYER (Popover API) is above every layer and every clip, whatever the list sits inside; without it, lift the layers.
                if (typeof t.showPopover === 'function') {
                    try {
                        if (!t.hasAttribute('popover')) t.setAttribute('popover', 'manual');
                        if (open && !t.matches(':popover-open')) t.showPopover();
                        else if (!open && t.matches(':popover-open')) t.hidePopover();
                    } catch (e) { window.ckLiftLayers(t, open); }
                } else window.ckLiftLayers(t, open);
            });
        }).observe(document.body, { subtree: true, attributes: true, attributeFilter: ['class'] });
    }
    if (document.body) watch(); else document.addEventListener('DOMContentLoaded', watch);
})();
