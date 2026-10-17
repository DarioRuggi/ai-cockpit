// =============================================================================
// i18n.js — the UI language of Cockpit itself.
//
// The model, in one paragraph: the English text lives IN THE CODE. A control that
// should be translatable carries data-i18n="key" (its text), data-i18n-title="key"
// (its hover hint) or data-i18n-placeholder="key"; script calls T('key', 'English').
// A language pack (lang.php?action=get&code=xx) maps key -> text and REPLACES the
// English; anything it does not translate stays English. So a half-finished
// translation is usable, English never needs to be fetched, and the en.json that
// translators work from is GENERATED from the code (Installs/lang_extract.php), so
// it cannot drift from what the app really says.
//
// Public surface:
//   T(key, english, vars)   the text for key in the current language ({name} filled from vars)
//   i18nApply(root)         (re)translate every data-i18n* element under root
//   i18nSet(code)           switch language now: loads the pack, saves the choice, re-applies
//   i18nLang()              the current code ('en' unless chosen)
//   i18nList()              Promise of the languages that exist [{code,native,coverage,…}]
//   i18nName(code)          a language's name in the CURRENT language ("Hebrew" / "עברית")
//   event 'cockpit-lang-changed'  {detail:{code,dir}} — for code that builds text itself
//
// Not here, deliberately: flipping the whole layout right-to-left. A right-to-left
// pack sets <html lang> and data-lang-dir="rtl" and the text itself renders correctly
// (the browser's bidi handles each label), but mirroring sidebars and strips is a
// separate piece of work, and an untested mirror is worse than none.
// =============================================================================
(function () {
    'use strict';
    var SAVED = 'cockpit_lang';                // the person's choice
    var PACK  = 'cockpit_lang_pack_';          // cached pack per language: instant next load
    var cur = 'en', strings = {}, meta = { code: 'en', dir: 'ltr' };
    var listCache = null;

    function okCode(c) { return typeof c === 'string' && /^[a-z]{2,3}(-[A-Za-z0-9]{2,8})?$/.test(c); }
    function ls(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
    function lsSet(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }

    // ---- the lookup ----------------------------------------------------------------
    window.T = function (key, english, vars) {
        var s = (cur !== 'en' && Object.prototype.hasOwnProperty.call(strings, key)) ? strings[key] : english;
        if (s === undefined || s === null) s = key;            // a missing key shows its name: loud, never blank
        if (vars) s = String(s).replace(/\{(\w+)\}/g, function (m, k) { return Object.prototype.hasOwnProperty.call(vars, k) ? vars[k] : m; });
        return s;
    };
    window.i18nLang = function () { return cur; };

    // ---- applying to the page ---------------------------------------------------------
    // The English is remembered on first sight (data-i18n-en…), so switching BACK to
    // English needs no fetch and no reload.
    window.i18nApply = function (root) {
        root = root || document;
        var n = root.querySelectorAll ? root : document;
        if (cur !== 'en') fitLock(n);                 // measure the English boxes BEFORE the text changes
        n.querySelectorAll('[data-i18n]').forEach(function (el) {
            if (el.dataset.i18nEn === undefined) el.dataset.i18nEn = el.textContent;
            // Text that script has changed since we last wrote it (a live status, a counter) is
            // not ours any more: leave it alone rather than overwrite it with the label.
            var now = el.textContent;
            if (now !== el.dataset.i18nEn && now !== el.dataset.i18nLast) return;
            var v = T(el.dataset.i18n, el.dataset.i18nEn);
            if (now !== v) el.textContent = v;
            el.dataset.i18nLast = v;
        });
        n.querySelectorAll('[data-i18n-title]').forEach(function (el) {
            // Cockpit's hint system lifts title= into data-tip on first hover and removes
            // the attribute; update whichever one is live, or the old language lingers.
            if (el.dataset.i18nEnTitle === undefined)
                el.dataset.i18nEnTitle = (el.dataset.tip !== undefined) ? el.dataset.tip : (el.getAttribute('title') || '');
            var v = T(el.dataset.i18nTitle, el.dataset.i18nEnTitle);
            if (el.dataset.tip !== undefined) el.dataset.tip = v; else el.setAttribute('title', v);
        });
        n.querySelectorAll('[data-i18n-placeholder]').forEach(function (el) {
            if (el.dataset.i18nEnPlaceholder === undefined) el.dataset.i18nEnPlaceholder = el.getAttribute('placeholder') || '';
            el.setAttribute('placeholder', T(el.dataset.i18nPlaceholder, el.dataset.i18nEnPlaceholder));
        });
        if (cur === 'en') fitRelease(n); else fitMarquee(n);
    };

    // ---- buttons keep their size in every language ------------------------------------
    // A translated label can be longer than the English one. Rather than let a button grow
    // (and push the top bar past the screen, or reflow a sidebar), the button KEEPS the size it
    // has in English; a label that no longer fits scrolls as a marquee inside it.
    //   * only buttons that carry a translated label are touched (a button whose text script sets
    //     itself is left alone)
    //   * a button that simply fills its parent (width:100%, flex:1) is not width-locked — it follows
    //     its parent as before — but its height is, and its label can still scroll
    //   * switching back to English removes every lock
    // Buttons and everything shaped like one: the plates in the header, chips, tabs, panel titles and the small "Project:" style labels.
    // Only the first two are always locked; the rest only when their English text sits on ONE line (a paragraph is allowed to wrap).
    var BTN_SEL = 'button, .action-btn';
    var FIT_SEL = BTN_SEL + ', .ck-plate, .ck-chip, .count-chip, .ma-mode-btn, .sidebar-vtab, .sidebar-panel-title, .rp-proposals-hdr, .rp-cfg-group-hdr, .tps-card, .cap-agent-badge, .topbar-project > .label';
    var ro = null, fitTimer = null;
    function candidates(root) {
        var out = [], seen = [];
        (root.querySelectorAll ? root : document).querySelectorAll('[data-i18n]').forEach(function (l) {
            var b = l.closest(FIT_SEL); if (b && seen.indexOf(b) < 0) { seen.push(b); out.push(b); }
        });
        return out;
    }
    function labelsOf(b) { var l = Array.prototype.slice.call(b.querySelectorAll('[data-i18n]')); if (b.hasAttribute('data-i18n')) l.unshift(b); return l; }
    function inEnglish(b, fn) {                        // run fn with the labels showing their English text
        var ls = labelsOf(b), now = ls.map(function (l) { return l.textContent; });
        ls.forEach(function (l) { if (l.dataset.i18nEn !== undefined) l.textContent = l.dataset.i18nEn; });
        try { return fn(); } finally { ls.forEach(function (l, i) { l.textContent = now[i]; }); }
    }
    function lockOne(b) {
        if (b.dataset.i18nBox !== undefined) return;
        var r = b.getBoundingClientRect();
        if (!r.width || !r.height) {                   // hidden now: lock it when it first shows
            if (ro && !b.dataset.i18nWatch) { b.dataset.i18nWatch = '1'; ro.observe(b); }
            return;
        }
        var cs = getComputedStyle(b), par = b.parentElement, fluid = false;
        if (!b.matches(BTN_SEL)) {                      // not a button: lock only a one-line label (a wrapped paragraph keeps flowing)
            var lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.3, padV = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
            if ((r.height - padV) / Math.max(lh, 20) > 1.6) return;
        }
        if (par) { var pc = getComputedStyle(par); fluid = Math.abs(r.width - (par.clientWidth - parseFloat(pc.paddingLeft) - parseFloat(pc.paddingRight))) <= 2; }
        // a plate / chip shrink-wraps its text, and its parent shrink-wraps IT, so "fills its parent" is true by accident: always lock the width of these
        if (b.matches('.ck-plate, .ck-chip, .count-chip, .tps-card, .cap-agent-badge')) fluid = false;
        b.dataset.i18nPrev = JSON.stringify([b.style.minWidth, b.style.maxWidth, b.style.height, b.style.boxSizing, b.style.overflow]);
        b.dataset.i18nBox = fluid ? 'h' : 'wh';
        b.style.boxSizing = 'border-box'; b.style.overflow = 'hidden';
        b.style.height = r.height + 'px';
        if (!fluid) { b.style.minWidth = r.width + 'px'; b.style.maxWidth = r.width + 'px'; }
    }
    function fitLock(root) {
        if (!ro && window.ResizeObserver) ro = new ResizeObserver(function (es) {
            es.forEach(function (e) {
                var b = e.target; if (b.dataset.i18nBox !== undefined || !e.contentRect.width) return;
                ro.unobserve(b); delete b.dataset.i18nWatch;
                inEnglish(b, function () { lockOne(b); });     // it was hidden while we translated: measure its English size now
                fitMarquee(b.parentNode || document);
            });
        });
        candidates(root).forEach(lockOne);
    }
    function fitRelease(root) {
        var all = (root.querySelectorAll ? root : document).querySelectorAll('[data-i18n-box],[data-i18n-mq]');
        all.forEach(function (b) {
            if (b.dataset.i18nPrev) { try { var p = JSON.parse(b.dataset.i18nPrev); b.style.minWidth = p[0]; b.style.maxWidth = p[1]; b.style.height = p[2]; b.style.boxSizing = p[3]; b.style.overflow = p[4]; } catch (e) {} }
            delete b.dataset.i18nPrev; delete b.dataset.i18nBox;
            labelsOf(b).forEach(function (l) { mqOff(l); });
        });
    }
    function mqOff(l) {
        if (l.dataset.i18nBox !== undefined || l.dataset.i18nPrev) { l.classList.remove('i18n-mq-self'); l.style.removeProperty('--mq'); l.style.whiteSpace = ''; delete l.dataset.i18nMq; return; }   // the button itself: keep its lock
        l.classList.remove('i18n-mq', 'i18n-mq-self'); l.style.removeProperty('--mq'); l.style.maxWidth = ''; l.style.display = ''; l.style.whiteSpace = ''; l.style.overflow = ''; l.style.verticalAlign = ''; delete l.dataset.i18nMq; }
    function fitMarquee(root) {
        candidates(root).forEach(function (b) {
            if (b.dataset.i18nBox === undefined) return;
            var cs = getComputedStyle(b), inner = b.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
            labelsOf(b).forEach(function (l) {
                mqOff(l);
                var self = (l === b), others = 0;
                if (!self) { Array.prototype.forEach.call(b.children, function (c) { if (c !== l && c.offsetWidth) others += c.offsetWidth; }); var gap = parseFloat(cs.columnGap) || 0; others += gap * Math.max(0, b.children.length - 1); }
                var avail = inner - others; if (avail < 8) return;
                var prev = l.style.whiteSpace; l.style.whiteSpace = 'nowrap';
                if (!self) l.style.display = 'inline-block';
                var need = self ? Math.max(b.scrollWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight), 0) : l.scrollWidth;
                if (need > avail + 1) {
                    l.style.setProperty('--mq', '-' + Math.ceil(need - avail) + 'px'); l.dataset.i18nMq = '1';
                    if (self) l.classList.add('i18n-mq-self');
                    else { l.style.maxWidth = avail + 'px'; l.style.overflow = 'hidden'; l.style.verticalAlign = 'bottom'; l.classList.add('i18n-mq'); }
                } else { l.style.whiteSpace = prev; if (!self) l.style.display = ''; }
            });
        });
    }
    window.addEventListener('resize', function () { clearTimeout(fitTimer); fitTimer = setTimeout(function () { if (cur !== 'en') fitMarquee(document); }, 200); });

    function adopt(code, pack) {
        cur = code; strings = (pack && pack.strings) || {}; meta = (pack && pack._meta) || { code: code, dir: 'ltr' };
        var h = document.documentElement;
        h.setAttribute('lang', code);
        h.setAttribute('data-lang-dir', meta.dir === 'rtl' ? 'rtl' : 'ltr');
        // a right-to-left pack may also ask for the LAYOUT to be mirrored (_meta.mirror, chosen by the translator in the Studio);
        // ?mirror=1 on the address tries it without changing the pack
        var qm = null; try { qm = new URLSearchParams(location.search).get('mirror'); } catch (e) {}
        h.setAttribute('data-lang-mirror', (meta.dir === 'rtl' && (meta.mirror === true || meta.mirror === 'true' || qm === '1')) ? '1' : '0');
    }
    function announce() {
        try { document.dispatchEvent(new CustomEvent('cockpit-lang-changed', { detail: { code: cur, dir: meta.dir || 'ltr' } })); } catch (e) {}
    }

    // ---- packs -----------------------------------------------------------------------
    function readCache(code) { try { var j = JSON.parse(ls(PACK + code) || 'null'); return (j && j.strings) ? j : null; } catch (e) { return null; } }
    function fetchPack(code) {
        return fetch('lang.php?action=get&code=' + encodeURIComponent(code)).then(function (r) { return r.ok ? r.json() : null; })
            .then(function (j) { if (j && j.strings) { lsSet(PACK + code, JSON.stringify(j)); return j; } return null; })
            .catch(function () { return null; });
    }

    // Switch language. Resolves true when it took effect.
    window.i18nSet = function (code, opts) {
        opts = opts || {};
        if (!okCode(code)) code = 'en';
        if (code === 'en') {
            adopt('en', null); if (!opts.transient) lsSet(SAVED, 'en');
            i18nApply(); announce(); return Promise.resolve(true);
        }
        var cached = readCache(code);
        if (cached) { adopt(code, cached); i18nApply(); }          // instant, from last time
        return fetchPack(code).then(function (fresh) {
            if (!fresh && !cached) return false;                    // unknown language and nothing cached: stay as we are
            if (fresh) { adopt(code, fresh); i18nApply(); }
            if (!opts.transient) lsSet(SAVED, code);
            announce(); return true;
        });
    };

    window.i18nList = function (force) {
        if (listCache && !force) return Promise.resolve(listCache);
        return fetch('lang.php?action=list').then(function (r) { return r.json(); })
            .then(function (j) { listCache = (j && j.languages) || []; listCache.folder = j && j.folder; return listCache; })
            .catch(function () { return []; });
    };

    // A language's name written in the CURRENT language, from the browser's own tables:
    // nothing to ship or maintain, and it follows the UI language ("Hebrew" -> "עברית").
    window.i18nName = function (code) {
        try { var n = new Intl.DisplayNames([cur], { type: 'language' }).of(code); if (n && n !== code) return n; } catch (e) {}
        return code;
    };

    // ---- boot -----------------------------------------------------------------------
    // ?lang=xx overrides for this page load only (never saved): for testing a pack.
    function boot() {
        var q = null; try { q = new URLSearchParams(location.search).get('lang'); } catch (e) {}
        var want = okCode(q) ? q : (ls(SAVED) || 'en');
        document.documentElement.setAttribute('lang', 'en');
        if (want !== 'en') i18nSet(want, { transient: okCode(q) });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot); else boot();
})();
