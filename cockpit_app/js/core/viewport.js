// =============================================================================
// viewport.js — Cockpit on a small screen: the whole app, at full size, that you pan and zoom.
//
// Cockpit is a desktop program. On a small screen it no longer squeezes itself into a phone layout (that layout is still
// there, opt-in: ?compact=1, or localStorage cockpit_compact=1 — css/mobile.css, html.ck-compact). Instead:
//   · a small TOUCH device (phone, small tablet) first sees a friendly screen: what this is, and — in the web demo — a short
//     tour in pictures, with an "Open it anyway" button;
//   · "Open it anyway" (or any window that is simply smaller than the app) shows the app at FULL size: on a touch device the
//     page is laid out 1100 px wide and scaled to fit, so two fingers zoom (pinch) and drag, the browser's own gestures;
//     on a computer with a mouse the window scrolls in whichever direction the app is larger than the window (css/base.css
//     keeps the app at least 1100 x 580).
// The page stays at the same layout in portrait and landscape; turning the phone sideways simply gives more room.
// ?gate=1 shows the first screen on any device (to look at it), ?gate=demo also with the demo's tour.
// =============================================================================
(function () {
    'use strict';
    var MIN_W = 1100, root = document.documentElement;
    var q = new URLSearchParams(location.search);
    function ls(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) {} return null; }
    function ss(k, v) { try { if (v === undefined) return sessionStorage.getItem(k); sessionStorage.setItem(k, v); } catch (e) {} return null; }
    if (q.get('compact') === '1' || ls('cockpit_compact') === '1') { root.classList.add('ck-compact'); return; }   // the old narrow layout, on request

    var touch = !!(window.matchMedia && matchMedia('(pointer: coarse)').matches && !matchMedia('(pointer: fine)').matches);
    var force = q.get('gate');
    var small = touch && Math.min(screen.width || 9999, screen.height || 9999) < 800 && (window.innerWidth || 9999) < MIN_W;   // a phone or a small tablet
    if (force) small = true;
    var consent = ss('ck_small_ok') === '1';

    function meta() { var m = document.querySelector('meta[name="viewport"]'); if (!m) { m = document.createElement('meta'); m.name = 'viewport'; document.head.appendChild(m); } return m; }
    function canvas() {                       // the app at full size; the browser does the pinch and drag
        if (touch && (screen.width || 0) < MIN_W + 1) meta().setAttribute('content', 'width=' + MIN_W + ', minimum-scale=0.2, maximum-scale=5, user-scalable=yes');
        root.classList.add('ck-canvas');
    }
    if (!small || consent) { if (touch && (window.innerWidth || 9999) < MIN_W) canvas(); return; }

    // ---- the first screen --------------------------------------------------------------------
    root.classList.add('ck-gate');
    var DEMO = force === 'demo' || root.getAttribute('data-edition') === 'demo';
    var TOUR = [['home-hero', 'One window for every AI', 'Claude, Codex, Gemini and models on your own computer, side by side.'],
                ['cat-projects', 'Projects that know what they are', 'Tell Cockpit what you are working on and it brings the right helpers.'],
                ['cat-fly', 'Let it fly the task', 'Type a goal. Cockpit plans it, does it step by step, and picks up after a crash.'],
                ['cat-documents', 'Ask your own documents', 'Search your files by words or by meaning; answers say where they came from.'],
                ['cat-make', 'Make things', 'Pictures, speech, translations, subtitles, scores and documents, on your machine.'],
                ['cat-free-private', 'Free and private by design', 'AI on your own computer, free cloud models, and only the spending you choose.']];
    function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
    function build() {
        var t = window.T || function (k, e) { return e; };
        var g = document.createElement('div'); g.id = 'small-gate';
        var slides = DEMO ? TOUR.map(function (s, i) {
            return '<figure class="sg-slide"><img src="../assets/shots/' + s[0] + '.webp" alt="" loading="' + (i ? 'lazy' : 'eager') + '"><figcaption><b>' + esc(t('gate.tour.' + i + '.t', s[1])) + '</b><span>' + esc(t('gate.tour.' + i + '.d', s[2])) + '</span></figcaption></figure>';
        }).join('') : '';
        g.innerHTML =
            '<div class="sg-card">' +
              '<img class="sg-logo" src="assets/logo.png" alt="" width="72" height="72">' +
              '<h1>' + esc(t('gate.title', 'AI Cockpit')) + (DEMO ? ' <small>' + esc(t('gate.demo', 'demo')) + '</small>' : '') + '</h1>' +
              '<p>' + esc(DEMO ? t('gate.demo.text', 'This is a look at AI Cockpit, a program that runs on your own computer and puts Claude, Codex, Gemini and local AI models in one window. It is made for a big screen, so on a phone the demo is best seen in the pictures below, or opened at full size.')
                                : t('gate.text', 'AI Cockpit is made for a big screen. You can still open it here at full size: it is the same program, which you move around by pinching and dragging.')) + '</p>' +
              (DEMO ? '<div class="sg-tour" tabindex="0">' + slides + '</div><div class="sg-dots">' + TOUR.map(function (s, i) { return '<i class="' + (i ? '' : 'on') + '"></i>'; }).join('') + '</div>' : '') +
              '<button type="button" class="sg-open">' + esc(t('gate.open', 'Open it anyway')) + '</button>' +
              '<p class="sg-how">' + esc(t('gate.how', 'It opens at full size. Pinch to zoom, drag with two fingers to move around. Turning the phone sideways gives more room.')) + '</p>' +
              (DEMO ? '<p class="sg-link"><a href="../" target="_top">' + esc(t('gate.site', 'About AI Cockpit, and how to install it')) + '</a></p>' : '') +
            '</div>';
        document.body.appendChild(g);
        g.querySelector('.sg-open').addEventListener('click', function () {
            ss('ck_small_ok', '1'); g.remove(); root.classList.remove('ck-gate'); canvas();
        });
        var tour = g.querySelector('.sg-tour');
        if (tour) tour.addEventListener('scroll', function () {
            var i = Math.round(tour.scrollLeft / Math.max(1, tour.clientWidth)); [].forEach.call(g.querySelectorAll('.sg-dots i'), function (d, k) { d.classList.toggle('on', k === i); });
        }, { passive: true });
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', build); else build();
})();
