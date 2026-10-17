// Theme readability guard (2026-10-05).
//
// Two layers, both work for ANY theme (built-in, user-made, edited, imported):
//
//  1. themeGuardVars(theme)  — static: for every text colour a theme defines, checks it against EVERY
//     surface it can land on, per area. A mixed theme has two text sets (content text on the light
//     areas, textChrome on the dark ones) and the check pairs each set with the surfaces of its own kind.
//     Returns [{pair, fg, bg, ratio, min, fix}] and, with fix=true, a repaired copy of the theme.
//  2. themeAudit()           — dynamic: walks the rendered DOM, resolves each text node's real colour
//     and the real (composited) background behind it, and lists every node below the threshold.
//     This is what catches a rule that hands light text to a light area, whatever theme is active.
//
// Used by the Theme Editor (live report + auto-fix on save) and by tests/theme_guard_test.js.

(function (root) {
    'use strict';

    function hex2rgb(h) {
        if (!h) return null;
        h = String(h).trim();
        let m = /^#([0-9a-f]{3})$/i.exec(h);
        if (m) return m[1].split('').map(x => parseInt(x + x, 16));
        m = /^#([0-9a-f]{6})/i.exec(h);
        if (m) return [0, 2, 4].map(i => parseInt(m[1].substr(i, 2), 16));
        return null;
    }
    function rgb2hex(c) { return '#' + c.map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join(''); }
    function lum(c) {
        const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
    }
    function ratio(a, b) {
        const la = lum(a), lb = lum(b), hi = Math.max(la, lb), lo = Math.min(la, lb);
        return (hi + 0.05) / (lo + 0.05);
    }
    // move fg towards black or white (whichever direction can reach `min` against bg) until it passes
    function fixColor(fg, bg, min) {
        if (ratio(fg, bg) >= min) return fg;
        const toward = lum(bg) > 0.18 ? [0, 0, 0] : [255, 255, 255];
        for (let t = 0.04; t <= 1.0001; t += 0.04) {
            const c = fg.map((v, i) => Math.round(v + (toward[i] - v) * t));      // rounded: the hex we store must itself pass
            if (ratio(c, bg) >= min) return c;
        }
        return toward;
    }
    const isDark = c => lum(c) < 0.18;

    // ---- 1. static theme check ---------------------------------------------------------------
    // thresholds: body text 4.5, secondary
    const MIN = { primary: 4.5, base: 4.5, dim: 4.5, muted: 4.5 };

    function themeGuardVars(theme, fix) {
        const out = { problems: [], theme: fix ? JSON.parse(JSON.stringify(theme)) : null };
        if (!theme || !theme.colors) return out;
        const c = theme.colors, bg = c.background || {}, tx = c.text || {}, tc = c.textChrome || null;
        const mixed = theme.mode === 'mixed';
        const surf = k => hex2rgb(bg[k]);
        // which surfaces each text set must be readable on
        const content = ['base', 'console', 'hover', 'active', 'codeblock'];
        const chrome = ['panel', 'sidebar', 'darker'];
        const sets = [];
        if (mixed) {
            sets.push({ name: 'text', vals: tx, surfaces: content, group: 'text' });
            // a mixed theme without textChrome relies on the CSS fallbacks (#e8eaf0 ...), which are fine on dark surfaces
            if (tc) sets.push({ name: 'textChrome', vals: tc, surfaces: chrome, group: 'textChrome' });
            else sets.push({ name: 'textChrome', vals: { primary: '#e8eaf0', base: '#c9ccd6', dim: '#9a9eac', muted: '#8b8f9e' }, surfaces: chrome, group: null });
        } else {
            sets.push({ name: 'text', vals: tx, surfaces: content.concat(chrome), group: 'text' });
        }
        for (const s of sets) {
            for (const k of ['primary', 'base', 'dim', 'muted']) {
                const fg = hex2rgb(s.vals[k]); if (!fg) continue;
                let cur = fg;
                for (const sk of s.surfaces) {
                    const b = surf(sk); if (!b) continue;
                    const r = ratio(cur, b);
                    const need = MIN[k];
                    if (r < need) {
                        const fixed = fixColor(cur, b, need);
                        out.problems.push({ pair: s.name + '.' + k + ' on ' + sk, fg: rgb2hex(cur), bg: rgb2hex(b), ratio: +r.toFixed(2), min: need, fix: rgb2hex(fixed) });
                        cur = fixed;           // later surfaces see the repaired colour
                    }
                }
                if (fix && s.group && cur !== fg) theme.colors && (out.theme.colors[s.group][k] = rgb2hex(cur));
            }
        }
        // mixed theme sanity: the two sets must be on opposite sides, or one area is unreadable by construction
        if (mixed) {
            const t = hex2rgb(tx.base), b = surf('base');
            if (t && isDark(t) === false && b && !isDark(b))
                out.problems.push({ pair: 'text.base is light but the content area is light', fg: tx.base, bg: bg.base, ratio: +ratio(t, b).toFixed(2), min: 4.5, fix: null });
        }
        // Accent and agent colours are drawn as TEXT too (agent names, clock, supplier labels, active buttons). They sit on the
        // content surface, so each must reach 3:1 there. In a Mixed theme the accent group is tuned for the dark chrome (light
        // colours), so only the agent colours are held to the light content surface; the accents are checked on the chrome.
        const groupSurf = mixed ? { accents: ['panel'], agents: ['base', 'active'] } : { accents: ['base', 'active'], agents: ['base', 'active'] };
        for (const g of ['accents', 'agents']) {
            const grp = g === 'accents' ? Object.assign({ cyan: '#2ec4b6', orange: '#e08a3c' }, c.accents || {}) : (c[g] || {});   // cyan/orange are not part of every theme: the CSS defaults apply
            for (const k of Object.keys(grp)) {
                if (/Dim$/.test(k)) continue;           // *Dim values are fills, not text
                let cur = hex2rgb(grp[k]); if (!cur) continue;
                // in a Mixed theme the accent group is tuned for the dark chrome, except cyan/orange which the CSS draws on the content too
                const surfaces = (mixed && g === 'accents' && (k === 'cyan' || k === 'orange')) ? ['base', 'active'] : groupSurf[g];
                const need = 3.3;                        // 3:1 plus margin: agent labels are drawn at 0.9 opacity
                for (const sk of surfaces) {
                    const bb = surf(sk); if (!bb) continue;
                    const r = ratio(cur, bb);
                    if (r < need) {
                        const fixed = fixColor(cur, bb, need);
                        out.problems.push({ pair: g + '.' + k + ' on ' + sk, fg: rgb2hex(cur), bg: bg[sk], ratio: +r.toFixed(2), min: need, fix: rgb2hex(fixed) });
                        cur = fixed;
                    }
                }
                if (fix && (rgb2hex(cur) !== String(grp[k]).toLowerCase() || (g === "accents" && (k === "cyan" || k === "orange")))) {   /* cyan/orange always written: applyTheme must overwrite the previous theme's value */ out.theme.colors[g] = out.theme.colors[g] || {}; out.theme.colors[g][k] = rgb2hex(cur); }
            }
        }
        return out;
    }

    // ---- 2. DOM audit ---------------------------------------------------------------------------
    function parseCss(col) {
        const cm = /^color\(srgb ([^)]+)\)/.exec(col || "");
        if (cm) { const q = cm[1].split(/[ \/]+/).filter(Boolean).map(parseFloat); return { c: [q[0] * 255, q[1] * 255, q[2] * 255], a: q.length > 3 ? q[3] : 1 }; }
        const m = /rgba?\(([^)]+)\)/.exec(col || '');
        if (!m) return null;
        const p = m[1].split(/[ ,\/]+/).filter(Boolean).map(parseFloat);
        return { c: [p[0], p[1], p[2]], a: p.length > 3 ? p[3] : 1 };
    }
    function effectiveBg(el) {
        const layers = [];
        for (let n = el; n && n.nodeType === 1; n = n.parentElement) {
            const cs = getComputedStyle(n);
            const p = parseCss(cs.backgroundColor);
            if (p && p.a > 0) { layers.push(p); if (p.a >= 0.999) break; }
            if (cs.backgroundImage && cs.backgroundImage !== 'none' && /gradient/.test(cs.backgroundImage)) return null;   // can't resolve
        }
        let base = hex2rgb(getComputedStyle(document.body).backgroundColor) || [255, 255, 255];
        let cur = layers.length && layers[layers.length - 1].a >= 0.999 ? layers.pop().c : (parseCss(getComputedStyle(document.documentElement).backgroundColor) || { c: base }).c;
        for (let i = layers.length - 1; i >= 0; i--) cur = cur.map((v, j) => v * (1 - layers[i].a) + layers[i].c[j] * layers[i].a);
        return cur;
    }
    function describe(el) {
        let s = el.tagName.toLowerCase();
        if (el.id) s += '#' + el.id;
        else if (el.className && typeof el.className === 'string') s += '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.');
        const par = el.parentElement;
        if (par && !el.id) s = (par.id ? '#' + par.id : par.tagName.toLowerCase() + (typeof par.className === 'string' && par.className.trim() ? '.' + par.className.trim().split(/\s+/)[0] : '')) + ' > ' + s;
        return s;
    }
    function themeAudit(opts) {
        opts = opts || {};
        const min = opts.min || 3.0, rootEl = opts.root || document.body, bad = [];
        let total = 0;
        // transitions and entry animations would report mid-flight colours: jump every running one to its end state
        try { document.getAnimations().forEach(function (a) { try { a.finish(); } catch (e) {} }); } catch (e) {}
        const frozen = { remove: function () {} };
        const walker = document.createTreeWalker(rootEl, NodeFilter.SHOW_TEXT, null);
        const seen = new Set();
        for (let t = walker.nextNode(); t; t = walker.nextNode()) {
            if (!t.nodeValue.replace(/[\s ·•|\-–—\/:,.]+/g, '')) continue;      // punctuation-only separators are decoration
            const el = t.parentElement; if (!el || seen.has(el)) continue;
            const tag = el.tagName; if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') continue;
            const r = el.getBoundingClientRect(); if (r.width < 2 || r.height < 2) continue;
            const cs = getComputedStyle(el);
            if (cs.visibility === 'hidden' || cs.display === 'none') continue;
            let op = 1; for (let n = el; n && n.nodeType === 1; n = n.parentElement) { const o = parseFloat(getComputedStyle(n).opacity); if (!isNaN(o)) op *= o; }
            if (op < 0.05) continue;
            const fgp = parseCss(cs.color); if (!fgp) continue;
            const bgc = effectiveBg(el); if (!bgc) continue;
            seen.add(el); total++;
            let fg = fgp.c.map((v, i) => v * fgp.a * op + bgc[i] * (1 - fgp.a * op));
            const rr = ratio(fg, bgc);
            const icon = /material-symbols/.test(el.className && el.className.baseVal === undefined ? el.className : "");   // glyph icons are decoration next to a label: 2.4:1 is enough
            if (rr < (icon ? Math.min(min, 2.4) : min)) bad.push({ node: describe(el), text: t.nodeValue.trim().slice(0, 30), fg: rgb2hex(fg), bg: rgb2hex(bgc), ratio: +rr.toFixed(2) });
        }
        frozen.remove();
        return { total: total, bad: bad };
    }

    root.themeGuard = { ratio: (a, b) => ratio(hex2rgb(a), hex2rgb(b)), fixColor, hex2rgb, rgb2hex, themeGuardVars, themeAudit };
    if (typeof module !== 'undefined' && module.exports) module.exports = root.themeGuard;
})(typeof window !== 'undefined' ? window : globalThis);
