// theme_generator_test.js — checks js/features/theme-generator.js (Auto Generate) for every palette type and mode.
// Run on the build machine:  node tests/theme_generator_test.js          (prints measured numbers, exits 1 on a failure)
//
//   * every generated theme has all colour groups and valid #rrggbb values (a Mixed one has textChrome)
//   * after the readability guard no text/accent problem is left, and the guard is idempotent
//   * the colour-blind palettes are MEASURED, not assumed: the six agent colours are run through a colour-vision simulation
//     (Machado 2009 matrices, severity 1.0) and must stay apart (CIE76 distance); the normal palette is measured the same way for comparison
//   * achromatopsia is grey throughout and its agents differ in lightness
const path = require('path');
const G = require(path.join(__dirname, '../cockpit_app/js/features/theme-guard.js'));
const GEN = require(path.join(__dirname, '../cockpit_app/js/features/theme-generator.js'));

let seed = 12345; const rand = () => { seed = (seed * 1664525 + 1013904223) % 4294967296; return seed / 4294967296; };
const HEX = /^#[0-9a-f]{6}$/;
const M = {
    protanopia:   [[0.152286, 1.052583, -0.204868], [0.114503, 0.786281, 0.099216], [-0.003882, -0.048116, 1.051998]],
    deuteranopia: [[0.367322, 0.860646, -0.227968], [0.280085, 0.672501, 0.047413], [-0.011820, 0.042940, 0.968881]],
    tritanopia:   [[1.255528, -0.076749, -0.178779], [-0.078411, 0.930809, 0.147602], [0.004733, 0.691367, 0.303900]]
};
const lin = v => { v /= 255; return v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
const unlin = v => { v = Math.min(1, Math.max(0, v)); return 255 * (v <= 0.0031308 ? v * 12.92 : 1.055 * Math.pow(v, 1 / 2.4) - 0.055); };
function lab(rgb) {                                   // sRGB 0-255 -> CIE Lab (D65)
    const [r, g, b] = rgb.map(lin);
    let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b, z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    const f = t => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
    return [116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
}
const sim = (hex, kind) => { const c = G.hex2rgb(hex).map(lin); const m = M[kind]; return [0, 1, 2].map(i => unlin(m[i][0] * c[0] + m[i][1] * c[1] + m[i][2] * c[2])); };
const dE = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
function minAgentGap(colors, kind) {
    const labs = GEN.AGENTS.map(n => lab(kind ? sim(colors.agents[n], kind) : G.hex2rgb(colors.agents[n])));
    let mn = 1e9; for (let i = 0; i < labs.length; i++) for (let j = i + 1; j < labs.length; j++) mn = Math.min(mn, dE(labs[i], labs[j]));
    return mn;
}

let fail = 0, n = 0; const bad = m => { fail++; console.log('FAIL ' + m); };
const palettes = ['normal', 'contrast', 'protanopia', 'deuteranopia', 'tritanopia', 'achromatopsia'], modes = ['dark', 'light', 'mixed'];
const picks = [{}, { bg: '#2255cc' }, { bg: '#cc3322', chrome: '#115544', accent: '#ffaa00' }, { chrome: '#7a1f5c' }];
const worst = {}, worstAt = {};
let lifted = 0;
for (const palette of palettes) for (const mode of modes) for (const pick of picks) for (let k = 0; k < 6; k++) {
    n++;
    const colors = GEN.themeGenerate({ mode, palette, pick, rand });
    const tag = palette + '/' + mode + '/' + JSON.stringify(pick);
    for (const g of ['background', 'text', 'border', 'agents', 'accents']) if (!colors[g]) bad(tag + ': missing ' + g);
    if (mode === 'mixed' && !colors.textChrome) bad(tag + ': mixed without textChrome');
    if (mode !== 'mixed' && colors.textChrome) bad(tag + ': textChrome on a non-mixed theme');
    for (const g of Object.keys(colors)) for (const [kk, v] of Object.entries(colors[g])) if (!HEX.test(v)) bad(tag + ': ' + g + '.' + kk + ' = ' + v);
    const theme = { mode, colors };
    const r = G.themeGuardVars(theme, true);
    if (r.problems.length) lifted++;
    if (G.themeGuardVars(r.theme, false).problems.length) bad(tag + ': not readable after the guard');
    if (palette === 'achromatopsia') {
        for (const g of ['background', 'text', 'border', 'agents', 'accents']) for (const [kk, v] of Object.entries(colors[g])) { const c = G.hex2rgb(v); if (c[0] !== c[1] || c[1] !== c[2]) bad(tag + ': ' + g + '.' + kk + ' is not grey (' + v + ')'); }
        const L = GEN.AGENTS.map(nm => lab(G.hex2rgb(colors.agents[nm]))[0]).sort((a, b) => a - b);
        for (let i = 1; i < L.length; i++) if (L[i] - L[i - 1] < 5) bad(tag + ': two agents are only ' + (L[i] - L[i - 1]).toFixed(1) + ' L* apart');
    }
    const kind = M[palette] ? palette : 'protanopia';
    const gapRaw = minAgentGap(r.theme.colors, M[palette] ? palette : null), gap = minAgentGap(r.theme.colors, kind);
    if (palette !== 'achromatopsia' && gap < (worst[palette] === undefined ? 1e9 : worst[palette])) worstAt[palette] = tag;
    if (palette !== 'achromatopsia') worst[palette] = Math.min(worst[palette] === undefined ? 1e9 : worst[palette], M[palette] ? gap : gap);
}
// the colour-blind palettes must keep every pair of agents clearly apart under their own deficiency; "normal" is shown for comparison
const MIN_GAP = 15;     // measured: protanopia 16, deuteranopia 22, tritanopia 24 (the "normal" palette: about 1, i.e. two agents look identical)
for (const p of ['protanopia', 'deuteranopia', 'tritanopia']) if (worst[p] < MIN_GAP) bad(p + ': two agent colours come within ' + worst[p].toFixed(1) + ' of each other under simulation (need ' + MIN_GAP + ')');
console.log('closest pair of agent colours under simulation (CIE76; bigger = easier to tell apart):');
for (const p of palettes) if (worst[p] !== undefined) console.log('  ' + p.padEnd(14) + worst[p].toFixed(1) + '  worst: ' + (worstAt[p] || '-').slice(0, 40) + (p === 'normal' || p === 'contrast' ? '   (measured under protanopia)' : ''));
console.log('theme_generator_test: ' + n + ' themes, ' + lifted + ' needed the guard to lift a colour, ' + fail + ' failure(s)');
process.exit(fail ? 1 : 0);
