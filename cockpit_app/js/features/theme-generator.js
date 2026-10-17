// Theme generator (2026-10-06) — the palette maker behind "New theme → Auto Generate".
//
//   themeGenerate({ mode, palette, pick, rand }) -> colors   (the same shape a theme file stores)
//
//   mode     'dark' | 'light' | 'mixed'   (mixed = light content, dark chrome, with its own light text set: textChrome)
//   palette  'normal'        random hue, agent hues spread round the wheel
//            'contrast'      near-black / near-white surfaces, pure text, saturated bright agent colours
//            'protanopia'    colours that stay apart for red-weak / red-blind eyes   (also protanomaly)
//            'deuteranopia'  ... for green-weak / green-blind eyes                    (also deuteranomaly)
//            'tritanopia'    ... for blue-weak / blue-blind eyes                      (also tritanomaly)
//            'achromatopsia' no colour at all: greys, the six agents told apart by LIGHTNESS
//   pick     { bg, chrome, accent } — optional '#rrggbb' choices; a missing one is random.
//              bg      the hue (and, up to a limit, the saturation) of the content / base surfaces
//              chrome  the same for panels, sidebars and the dark areas of a Mixed theme
//              accent  the UI accent colour (and the hue the agent colours are spread from, in the normal palette)
//            Lightness always follows the mode, so a picked mid-blue gives a dark-blue background in a dark theme and a pale blue one in a
//            light theme; the picked HUE is what you get.
//   rand     optional () => [0,1) for repeatable output (tests)
//
// The colour-blind sets are drawn from published colour-blind-safe palettes (Okabe-Ito and kin) and are CHECKED with a colour-vision
// simulation in tests/theme_generator_test.js; they are approximations of what a person with that condition can tell apart, not a
// medical guarantee. Whatever is generated, js/features/theme-guard.js still lifts any text colour that cannot be read.

(function (root) {
    'use strict';

    const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
    function hsl2hex(h, s, l) {
        h = ((h % 360) + 360) % 360; s = clamp(s, 0, 100) / 100; l = clamp(l, 0, 100) / 100;
        const a = s * Math.min(l, 1 - l);
        const f = n => { const k = (n + h / 30) % 12; return l - a * Math.max(Math.min(k - 3, 9 - k, 1), -1); };
        return '#' + [f(0), f(8), f(4)].map(x => Math.round(x * 255).toString(16).padStart(2, '0')).join('');
    }
    function hex2hsl(hex) {
        const m = /^#?([0-9a-f]{6})$/i.exec(String(hex || '').trim());
        if (!m) return null;
        const r = parseInt(m[1].substr(0, 2), 16) / 255, g = parseInt(m[1].substr(2, 2), 16) / 255, b = parseInt(m[1].substr(4, 2), 16) / 255;
        const mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn, l = (mx + mn) / 2;
        let h = 0, s = 0;
        if (d) {
            s = d / (1 - Math.abs(2 * l - 1));
            h = mx === r ? ((g - b) / d) % 6 : mx === g ? (b - r) / d + 2 : (r - g) / d + 4;
            h *= 60; if (h < 0) h += 360;
        }
        return { h: h, s: s * 100, l: l * 100 };
    }

    // Colour-blind-safe agent colours, in the order claude, gemini, ollama, workers, tools, localai. Their lightness is re-set for the mode.
    const SAFE = {
        protanopia:   ['#E69F00', '#56B4E9', '#F0E442', '#CC79A7', '#0072B2', '#009E73'],
        deuteranopia: ['#E69F00', '#56B4E9', '#F0E442', '#CC79A7', '#0072B2', '#009E73'],
        tritanopia:   ['#D7263D', '#1B998B', '#F46036', '#2E294E', '#9FE0D8', '#E8A0BF']
    };
    // accents + the ui accent per safe palette: [amber, blue, green, warm, cyan, orange, ui]
    const SAFE_ACC = {
        protanopia:   ['#E69F00', '#0072B2', '#009E73', '#D55E00', '#56B4E9', '#E69F00', '#56B4E9'],
        deuteranopia: ['#E69F00', '#0072B2', '#009E73', '#D55E00', '#56B4E9', '#E69F00', '#56B4E9'],
        tritanopia:   ['#F46036', '#1B998B', '#9FE0D8', '#D7263D', '#1B998B', '#F46036', '#1B998B']
    };
    // ---- colour-vision simulation (Machado 2009, severity 1.0) and CIE Lab, used to ARRANGE the safe palettes ------------------------
    const CVD = {
        protanopia:   [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
        deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
        tritanopia:   [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
    };
    const lin = v => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    const unlin = v => { v = clamp(v, 0, 1); return 255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055); };
    const hex2rgb = h => [1, 3, 5].map(i => parseInt(h.substr(i, 2), 16));
    function labOf(rgb) {
        const c = rgb.map(lin);
        const x = (0.4124 * c[0] + 0.3576 * c[1] + 0.1805 * c[2]) / 0.95047, y = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2], z = (0.0193 * c[0] + 0.1192 * c[1] + 0.9505 * c[2]) / 1.08883;
        const f = t => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
        return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
    }
    function simLab(hex, kind) {
        const c = hex2rgb(hex).map(lin), m = CVD[kind];
        return labOf([0, 1, 2].map(i => unlin(m[i][0] * c[0] + m[i][1] * c[1] + m[i][2] * c[2])));
    }
    const dE = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
    // the hex of hue h / saturation s whose perceptual lightness L* is (closest to) target, by bisection on HSL lightness
    function hexAtL(h, s, target) {
        let lo = 3, hi = 97;
        for (let i = 0; i < 24; i++) { const mid = (lo + hi) / 2; if (labOf(hex2rgb(hsl2hex(h, s, mid)))[0] < target) lo = mid; else hi = mid; }
        return hsl2hex(h, s, (lo + hi) / 2);
    }
    function* perms(a) { if (a.length <= 1) { yield a; return; } for (let i = 0; i < a.length; i++) for (const p of perms(a.slice(0, i).concat(a.slice(i + 1)))) yield [a[i]].concat(p); }
    // Six hues from a safe set, six evenly spaced lightness steps across a band; the hues are dealt out to the steps in the order that keeps
    // the closest pair of colours, AS SEEN with the given deficiency, as far apart as possible (720 arrangements, tried exhaustively).
    function fitSafe(hexes, kind, onDark) {
        const band = onDark ? [54, 94] : [14, 44], steps = hexes.map((_, i) => band[0] + (band[1] - band[0]) * i / (hexes.length - 1));
        const hs = hexes.map(hx => hex2hsl(hx));
        const table = hs.map(c => steps.map(L => { const hx = hexAtL(c.h, clamp(c.s, 55, 100), L); return { hx: hx, lab: simLab(hx, kind) }; }));
        let best = null, bestGap = -1;
        for (const p of perms(steps.map((_, i) => i))) {          // p[i] = lightness step given to hue i
            let mn = 1e9;
            for (let i = 0; i < p.length && mn > bestGap; i++) for (let j = i + 1; j < p.length; j++) mn = Math.min(mn, dE(table[i][p[i]].lab, table[j][p[j]].lab));
            if (mn > bestGap) { bestGap = mn; best = p; }
        }
        return best.map((st, i) => table[i][st].hx);
    }
    const AGENTS = ['claude', 'gemini', 'ollama', 'workers', 'tools', 'localai'];

    function themeGenerate(opts) {
        opts = opts || {};
        const mode = opts.mode === 'light' || opts.mode === 'mixed' ? opts.mode : 'dark';
        const palette = ['contrast', 'protanopia', 'deuteranopia', 'tritanopia', 'achromatopsia'].indexOf(opts.palette) >= 0 ? opts.palette : 'normal';
        const rnd = typeof opts.rand === 'function' ? opts.rand : Math.random;
        const pick = opts.pick || {};
        const mixed = mode === 'mixed', dark = mode === 'dark';
        const grey = palette === 'achromatopsia', hc = palette === 'contrast';

        const pBg = hex2hsl(pick.bg), pCh = hex2hsl(pick.chrome), pAc = hex2hsl(pick.accent);
        const baseHue = pBg ? pBg.h : Math.floor(rnd() * 360);
        const chromeHue = pCh ? pCh.h : baseHue;
        const accHue = pAc ? pAc.h : baseHue;
        // saturation of surfaces: the picked colour's own (capped, so a vivid pick does not give a neon background); random: low
        const satOf = (p, dflt) => grey ? 0 : p ? clamp(p.s * 0.55, 8, 45) : dflt;
        const sBase = satOf(pBg, 15), sChrome = satOf(pCh, 13);
        const S = (h, s, l) => hsl2hex(h, grey ? 0 : s, l);

        // ---- surfaces ------------------------------------------------------------------------------------------------------
        // light-area and dark-area lightness sets (contrast palette pushes them to the extremes)
        const LIGHT = hc ? { base: 100, console: 100, hover: 90, active: 82, codeblock: 96, panel: 96, sidebar: 94, darker: 88 }
                         : { base: 95, console: 97, hover: 85, active: 82, codeblock: 93, panel: 92, sidebar: 90, darker: 88 };
        const DARK  = hc ? { base: 3, console: 0, hover: 14, active: 20, codeblock: 5, panel: 7, sidebar: 5, darker: 0 }
                         : { base: 10, console: 8, hover: 18, active: 22, codeblock: 7, panel: 14, sidebar: 12, darker: 6 };
        let bg;
        if (mixed) {
            const L = hc ? { base: 100, console: 100, hover: 90, active: 82, codeblock: 97 } : { base: 92, console: 95, hover: 87, active: 82, codeblock: 94 };
            const K = hc ? { panel: 7, sidebar: 10, darker: 5 } : { panel: 14, sidebar: 11, darker: 8 };
            bg = {
                base: S(baseHue, sBase, L.base), panel: S(chromeHue, sChrome, K.panel), sidebar: S(chromeHue, sChrome, K.sidebar), console: S(baseHue, sBase, L.console),
                hover: S(baseHue, sBase, L.hover), active: S(baseHue, sBase, L.active), darker: S(chromeHue, sChrome, K.darker), codeblock: S(baseHue, sBase * 0.6, L.codeblock)
            };
        } else {
            const T = dark ? DARK : LIGHT;
            bg = {
                base: S(baseHue, sBase, T.base), panel: S(pCh ? chromeHue : baseHue, sChrome, T.panel), sidebar: S(pCh ? chromeHue : baseHue, sChrome + 1, T.sidebar), console: S(baseHue, sBase * 0.7, T.console),
                hover: S(baseHue, sBase * 0.8, T.hover), active: S(baseHue, sBase, T.active), darker: S(pCh ? chromeHue : baseHue, sChrome * 0.7, T.darker), codeblock: S(baseHue, sBase * 0.5, T.codeblock)
            };
        }

        // ---- text ----------------------------------------------------------------------------------------------------------
        const textDark = hc ? { primary: '#000000', base: '#101010', dim: '#404040', muted: '#585858' } : null;
        const textLight = hc ? { primary: '#ffffff', base: '#f2f2f2', dim: '#d0d0d0', muted: '#b4b4b4' } : null;
        const darkText = textDark || { primary: S(baseHue, 6, 8), base: S(baseHue, 6, 16), dim: S(baseHue, 6, 30), muted: S(baseHue, 6, 38) };
        const lightText = textLight || { primary: S(chromeHue, 5, 95), base: S(chromeHue, 5, 82), dim: S(chromeHue, 5, 62), muted: S(chromeHue, 5, 55) };
        const text = dark ? (textLight || { primary: S(baseHue, 5, 95), base: S(baseHue, 5, 82), dim: S(baseHue, 5, 62), muted: S(baseHue, 5, 55) }) : darkText;

        // ---- agents + accents ----------------------------------------------------------------------------------------------
        // agents sit on the CONTENT surface: light in 'light' and 'mixed', dark in 'dark'
        const onDarkContent = dark;
        const aL = hc ? (onDarkContent ? 72 : 28) : (onDarkContent ? 66 : 40);
        const aDimL = onDarkContent ? 35 : (mixed ? 80 : 65);
        let agentHex;
        if (grey) {
            const steps = onDarkContent ? [97, 89, 81, 73, 65, 57] : [5, 12, 19, 26, 33, 40];
            agentHex = steps.map(l => hsl2hex(0, 0, l));
        } else if (SAFE[palette]) {
            agentHex = fitSafe(SAFE[palette], palette, onDarkContent);
        } else {
            const hues = [accHue, accHue + 90, accHue + 180, accHue + 270, accHue + 45, accHue + 225];     // claude, gemini, ollama, workers, tools, localai
            agentHex = hues.map(h => hexAtL(h, hc ? 100 : 70, onDarkContent ? (hc ? 80 : 72) : (hc ? 30 : 42)));      // placed by perceptual lightness: a yellow and a blue of equal HSL lightness are not equally readable
        }
        const agents = {};
        AGENTS.forEach((n, i) => { const c = hex2hsl(agentHex[i]); agents[n] = agentHex[i]; agents[n + 'Dim'] = hsl2hex(c.h, grey ? 0 : c.s * 0.55, aDimL); });

        // accents: in a Mixed theme they are drawn on the dark chrome (light colours); elsewhere on the content surface
        const accL = mixed ? 66 : onDarkContent ? 62 : (hc ? 26 : 32);
        // on a light content surface a colour needs a perceptual lightness (L*) of about 42 or less to reach 3.3:1 against the 'active' tint; HSL lightness
        // misleads for yellows and cyans, so those accents are placed by L*
        const onLight = (h, s) => hexAtL(h, s, hc ? 30 : 42);
        const accLc = mixed ? (hc ? 26 : 30) : accL;     // cyan and orange are drawn on the CONTENT surface even in a Mixed theme
        let accents;
        if (grey) {
            const g = l => hsl2hex(0, 0, l);
            accents = { amber: g(accL), blue: g(accL), green: g(accL), warm: g(accL), cyan: g(accLc), orange: g(accLc), ui: g(accL), uiDim: g(accL - 25) };
        } else if (SAFE_ACC[palette]) {
            const a = SAFE_ACC[palette].map((hx, i) => { const c = hex2hsl(hx), s = clamp(c.s, 55, 100), content = !onDarkContent && (!mixed || i === 4 || i === 5); return content ? onLight(c.h, s) : hsl2hex(c.h, s, mixed ? accL : accL); });
            accents = { amber: a[0], blue: a[1], green: a[2], warm: a[3], cyan: a[4], orange: a[5], ui: a[6], uiDim: hsl2hex(hex2hsl(a[6]).h, 55, mixed ? 32 : onDarkContent ? 30 : 62) };
        } else {
            accents = {
                amber: !mixed && !onDarkContent ? onLight(40, 85) : hsl2hex(40, 85, accL), blue: !mixed && !onDarkContent ? onLight(210, 80) : hsl2hex(210, 80, accL),
                green: !mixed && !onDarkContent ? onLight(140, 65) : hsl2hex(140, 65, accL - 5), warm: !mixed && !onDarkContent ? onLight(accHue + 30, 55) : hsl2hex(accHue + 30, 55, accL + 5),
                cyan: onDarkContent ? hsl2hex(174, 65, accL) : onLight(174, 65), orange: onDarkContent ? hsl2hex(28, 75, accL) : onLight(28, 75),
                ui: (!mixed && !onDarkContent) ? onLight(pAc ? accHue : accHue + 200, pAc ? clamp(pAc.s, 50, 100) : 80) : (pAc ? hsl2hex(accHue, clamp(pAc.s, 50, 100), accL) : hsl2hex(accHue + 200, hc ? 100 : 80, accL)),
                uiDim: hsl2hex(pAc ? accHue : accHue + 200, 55, mixed ? 32 : onDarkContent ? 30 : 62)
            };
        }
        if (pAc && grey) accents.ui = hsl2hex(0, 0, accL);

        // ---- borders ------------------------------------------------------------------------------------------------------
        const border = mixed
            ? { dim: S(chromeHue, 8, hc ? 12 : 16), mid: S(baseHue, 8, hc ? 62 : 68), bright: grey ? hsl2hex(0, 0, 40) : hsl2hex(accHue, 80, hc ? 45 : 50) }
            : dark ? { dim: S(baseHue, 8, hc ? 28 : 18), mid: S(baseHue, 8, hc ? 50 : 28), bright: S(baseHue, 10, hc ? 72 : 42) }
                   : { dim: S(baseHue, 8, hc ? 70 : 80), mid: S(baseHue, 8, hc ? 45 : 70), bright: S(baseHue, 10, hc ? 22 : 55) };

        const colors = { background: bg, text: text, border: border, agents: agents, accents: accents };
        if (mixed) colors.textChrome = lightText;
        return colors;
    }

    root.themeGenerator = { themeGenerate: themeGenerate, hsl2hex: hsl2hex, hex2hsl: hex2hsl, AGENTS: AGENTS };
    root.themeGenerate = themeGenerate;
    if (typeof module !== 'undefined' && module.exports) module.exports = root.themeGenerator;
})(typeof window !== 'undefined' ? window : globalThis);
