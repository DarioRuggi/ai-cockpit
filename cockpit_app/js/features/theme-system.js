// =============================================================================
// THEME SYSTEM
// =============================================================================
// Theme structure: a JSON object with {id, name, mode, builtin, colors}.
// `colors` is grouped into 5 semantic categories:
//   background, border, text, agents, accents
// Each category contains hex values keyed by purpose.
//
// applyTheme() flattens the grouped JSON into CSS variables on
// document.documentElement.style. Glow/dim derivations not stored in the
// JSON are computed from the base hex via tinting helpers below.
//
// Storage: themes.php → ~/scripts/cockpit_data/themes.json
//   .builtin themes are read-only (cockpit_original_dark, soft_terminal_dark,
//   cockpit_original_light, soft_paper_light). User-created themes save with
//   their own id and can be edited or deleted in place.
//
// State held in window._themeState:
//   active        — id of theme currently committed to the cockpit
//   editing       — id of theme being viewed in the editor (may differ from active)
//   editingDraft  — colors object the editor is currently mutating (preview-only)
//   themesIndex   — { id → {name, mode, builtin} } from list endpoint
//   lastDarkId    — most recently active dark theme (for toggle button)
//   lastLightId   — most recently active light theme (for toggle button)
// =============================================================================

window._themeState = {
    active: localStorage.getItem('cockpit_theme_active') || null,
    editing: null,
    editingDraft: null,
    themesIndex: {},
    lastDarkId:  localStorage.getItem('cockpit_theme_last_dark')  || 'cockpit_original_dark',
    lastLightId: localStorage.getItem('cockpit_theme_last_light') || 'cockpit_original_light',
    lastMixedId: localStorage.getItem('cockpit_theme_last_mixed') || null,
    last_darkId:  localStorage.getItem('cockpit_theme_last_dark')  || 'cockpit_original_dark',
    last_lightId: localStorage.getItem('cockpit_theme_last_light') || 'cockpit_original_light',
    last_mixedId: localStorage.getItem('cockpit_theme_last_mixed') || null,
};

// Convert "#rrggbb" → "r,g,b" for use inside rgba() expressions
function _hexToRgb(hex) {
    if (!hex) return '0,0,0';
    let h = hex.replace('#', '').trim();
    if (h.length === 3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
    const r = parseInt(h.substr(0, 2), 16);
    const g = parseInt(h.substr(2, 2), 16);
    const b = parseInt(h.substr(4, 2), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) return '0,0,0';
    return `${r},${g},${b}`;
}

// Glow derivation: 15% alpha tint of the base color. Used for agent-glow vars.
function _glow(hex) {
    return `rgba(${_hexToRgb(hex)}, 0.15)`;
}

// LocalAI's accent, derived from the theme's own Ollama color by rotating
// the hue well away from it. Themes written before LocalAI existed (every
// built-in one, plus any the user already saved/exported) carry no localai
// value — without this they'd leave --localai stuck at its static :root
// default while everything around it re-themed. Derivation keeps it moving
// with the theme AND visually distinct from Ollama, which matters here since
// the O/L chips sit side by side.
function _deriveLocalAI(ollamaHex) {
    const { h, s, l } = _hexToHsl(ollamaHex);
    return _hslToHex((h + 0.45) % 1, s, l);
}

// ─────────────────────────────────────────────────────────────────────────
// COLOR CONTRAST HELPERS (WCAG 2.1)
//
// _relLuminance(hex) — relative luminance per sRGB formula
// _contrastRatio(a,b) — 1.0..21.0; higher = more legible
// _adjustForContrast(textHex, bgHex, minRatio) — shifts the text color
//   toward white or black (whichever yields better ratio) until contrast
//   meets minRatio. Hue is preserved (HSL L* shifted, H+S kept).
//
// Used by ensureReadability() at the end of applyTheme to bulletproof
// any theme — builtin or user-supplied — against unreadable combinations.
// ─────────────────────────────────────────────────────────────────────────
function _relLuminance(hex) {
    const rgbStr = _hexToRgb(hex);
    const [r,g,b] = rgbStr.split(',').map(Number);
    const norm = v => {
        const s = v / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * norm(r) + 0.7152 * norm(g) + 0.0722 * norm(b);
}

function _contrastRatio(hexA, hexB) {
    const L1 = _relLuminance(hexA);
    const L2 = _relLuminance(hexB);
    const lighter = Math.max(L1, L2);
    const darker  = Math.min(L1, L2);
    return (lighter + 0.05) / (darker + 0.05);
}

// Convert hex → HSL components
function _hexToHsl(hex) {
    const [r,g,b] = _hexToRgb(hex).split(',').map(n => Number(n) / 255);
    const max = Math.max(r,g,b), min = Math.min(r,g,b);
    let h = 0, s = 0;
    const l = (max + min) / 2;
    if (max !== min) {
        const d = max - min;
        s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
        switch (max) {
            case r: h = (g - b) / d + (g < b ? 6 : 0); break;
            case g: h = (b - r) / d + 2; break;
            case b: h = (r - g) / d + 4; break;
        }
        h /= 6;
    }
    return { h, s, l };
}

function _hslToHex(h, s, l) {
    let r, g, b;
    if (s === 0) { r = g = b = l; }
    else {
        const hue2rgb = (p, q, t) => {
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1/6) return p + (q - p) * 6 * t;
            if (t < 1/2) return q;
            if (t < 2/3) return p + (q - p) * (2/3 - t) * 6;
            return p;
        };
        const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        const p = 2 * l - q;
        r = hue2rgb(p, q, h + 1/3);
        g = hue2rgb(p, q, h);
        b = hue2rgb(p, q, h - 1/3);
    }
    const toHex = v => Math.round(v * 255).toString(16).padStart(2, '0');
    return '#' + toHex(r) + toHex(g) + toHex(b);
}

// Shift `textHex` lightness toward white or black until contrast against
// `bgHex` meets minRatio. Returns the adjusted hex (or original if already OK).
// If goalDir is given ('lighter' or 'darker') it forces direction; otherwise
// the function picks whichever side is closer.
function _adjustForContrast(textHex, bgHex, minRatio, goalDir) {
    if (_contrastRatio(textHex, bgHex) >= minRatio) return textHex;

    const bgLum = _relLuminance(bgHex);
    const wantLighter = goalDir ? (goalDir === 'lighter') : (bgLum < 0.5);
    const hsl = _hexToHsl(textHex);

    // Step by 4% L* up to 25 iterations (full range coverage)
    const step = wantLighter ? 0.04 : -0.04;
    let l = hsl.l;
    for (let i = 0; i < 25; i++) {
        l = Math.max(0, Math.min(1, l + step));
        const candidate = _hslToHex(hsl.h, hsl.s, l);
        if (_contrastRatio(candidate, bgHex) >= minRatio) return candidate;
        if (l <= 0 || l >= 1) break;
    }
    // Last resort: pure white or black
    return wantLighter ? '#ffffff' : '#000000';
}

// Bulletproof readability after a theme is applied. Walks each text variable
// and bumps it if contrast against its primary background is too low. Also
// guards --ui-accent so accent text on bg-active stays readable.
//
// Thresholds chosen per WCAG:
//   primary/base → 4.5:1 (normal body text)
//   dim/muted    → 3.0:1 (large/secondary text; preserves intended subtlety)
//   ui-accent    → 3.0:1 (used as colored text, slightly relaxed)
function ensureReadability() {
    // Superseded 2026-10-05: the old five-pair check compared every text colour with ONE surface, which in a Mixed theme
    // lightened the dark-on-light text to suit the dark panel. js/features/theme-guard.js now checks each text set against
    // the surfaces of its own kind and repairs the theme copy before it is applied (see applyTheme).
}

// Apply a theme JSON object to document.documentElement. The theme's color
// groups become CSS variables. This is the ONLY function that touches the
// :root style; both runtime theme switches and the editor's "Apply" call it.
function applyTheme(theme) {
    if (!theme || !theme.colors) return;
    if (window.themeGuard) {
        try { const g = window.themeGuard.themeGuardVars(theme, true); window._themeGuardReport = g.problems; theme = g.theme || theme; }
        catch (e) { console.warn("themeGuard:", e); }
    }
    const c = theme.colors;
    // the native window's chrome follows the page: dark theme → dark GTK variant
    if (window._inShell && typeof shellCall === 'function') { try { shellCall('set_dark', { on: theme.mode !== 'light' }); } catch (e) {} }
    const r = document.documentElement.style;

    // Background group → --bg-* variables
    if (c.background) {
        if (c.background.base)      r.setProperty('--bg-base',      c.background.base);
        if (c.background.panel)     r.setProperty('--bg-panel',     c.background.panel);
        if (c.background.sidebar)   r.setProperty('--bg-sidebar',   c.background.sidebar);
        if (c.background.console)   r.setProperty('--bg-console',   c.background.console);
        if (c.background.hover)     r.setProperty('--bg-hover',     c.background.hover);
        if (c.background.active)    r.setProperty('--bg-active',    c.background.active);
        if (c.background.darker)    r.setProperty('--bg-darker',    c.background.darker);
        if (c.background.codeblock) r.setProperty('--bg-codeblock', c.background.codeblock);
    }

    // Border group → --border-*
    if (c.border) {
        if (c.border.dim)    r.setProperty('--border-dim',    c.border.dim);
        if (c.border.mid)    r.setProperty('--border-mid',    c.border.mid);
        if (c.border.bright) r.setProperty('--border-bright', c.border.bright);
    }

    // Text group → --text-*
    if (c.text) {
        if (c.text.primary) r.setProperty('--text-primary', c.text.primary);
        if (c.text.base)    r.setProperty('--text-base',    c.text.base);
        if (c.text.dim)     r.setProperty('--text-dim',     c.text.dim);
        if (c.text.muted)   r.setProperty('--text-muted',   c.text.muted);
    }

    // Mixed themes: the text group above is for the LIGHT surfaces, so it is also kept as --content-text-*;
    // the optional textChrome group is light text for the DARK areas (top bar, status bar, sidebars). css/base.css
    // chooses between them per area. A theme without textChrome falls back to the CSS defaults.
    if (c.text) {
        if (c.text.primary) r.setProperty('--content-text-primary', c.text.primary);
        if (c.text.base)    r.setProperty('--content-text-base',    c.text.base);
        if (c.text.dim)     r.setProperty('--content-text-dim',     c.text.dim);
        if (c.text.muted)   r.setProperty('--content-text-muted',   c.text.muted);
    }
    ['primary', 'base', 'dim', 'muted'].forEach(function (k) {
        if (c.textChrome && c.textChrome[k]) r.setProperty('--chrome-text-' + k, c.textChrome[k]);
        else r.removeProperty('--chrome-text-' + k);
    });

    // Agent colors — primary stored, glow derived at apply time
    if (c.agents) {
        const a = c.agents;
        if (a.claude)  { r.setProperty('--claude',  a.claude);  r.setProperty('--claude-glow',  _glow(a.claude)); }
        if (a.claudeDim)  r.setProperty('--claude-dim',  a.claudeDim);
        if (a.gemini)  { r.setProperty('--gemini',  a.gemini);  r.setProperty('--gemini-glow',  _glow(a.gemini)); }
        if (a.geminiDim)  r.setProperty('--gemini-dim',  a.geminiDim);
        if (a.ollama)  { r.setProperty('--ollama',  a.ollama);  r.setProperty('--ollama-glow',  _glow(a.ollama)); }
        if (a.ollamaDim)  r.setProperty('--ollama-dim',  a.ollamaDim);
        // Explicit localai wins; otherwise derive from this theme's Ollama so
        // it still re-themes (see _deriveLocalAI). Only truly skipped when the
        // theme defines neither, which can't happen — ollama is always set.
        const _la = a.localai || (a.ollama ? _deriveLocalAI(a.ollama) : null);
        if (_la) { r.setProperty('--localai', _la); r.setProperty('--localai-glow', _glow(_la)); }
        const _laDim = a.localaiDim || (a.ollamaDim ? _deriveLocalAI(a.ollamaDim) : null);
        if (_laDim) r.setProperty('--localai-dim', _laDim);
        if (a.workers) { r.setProperty('--workers', a.workers); r.setProperty('--workers-glow', _glow(a.workers)); }
        if (a.workersDim) r.setProperty('--workers-dim', a.workersDim);
        if (a.tools)   { r.setProperty('--tools',   a.tools);   r.setProperty('--tools-glow',   _glow(a.tools)); }
        if (a.toolsDim)   r.setProperty('--tools-dim',   a.toolsDim);
    }

    // Accent group
    if (c.accents) {
        if (c.accents.amber) r.setProperty('--accent-amber', c.accents.amber);
        if (c.accents.blue)  {
            r.setProperty('--accent-blue', c.accents.blue);
            r.setProperty('--accent-blue-dim',  `rgba(${_hexToRgb(c.accents.blue)}, 0.45)`);
            r.setProperty('--accent-blue-glow', `rgba(${_hexToRgb(c.accents.blue)}, 0.12)`);
        }
        if (c.accents.green) r.setProperty('--accent-green', c.accents.green);
        if (c.accents.cyan)  r.setProperty('--accent-cyan',  c.accents.cyan);
        if (c.accents.orange) r.setProperty('--accent-orange', c.accents.orange);
        if (c.accents.ui) {
            r.setProperty('--ui-accent', c.accents.ui);
            r.setProperty('--ui-accent-dim',  c.accents.uiDim || c.accents.ui);
            r.setProperty('--ui-accent-glow', `rgba(${_hexToRgb(c.accents.ui)}, 0.15)`);
        }
        if (c.accents.warm) r.setProperty('--warm', c.accents.warm);
    }

    // Tag the body with the theme mode for any mode-aware CSS hooks
    document.body.dataset.themeMode = theme.mode || 'dark';

    // Update the toggle icon — shows what mode you'll SWITCH TO next
    const modeOrder  = ['dark', 'light', 'mixed'];
    const curModeIdx = modeOrder.indexOf(theme.mode || 'dark');
    const nextMode   = modeOrder[(curModeIdx + 1) % modeOrder.length];
    const iconMap    = { dark: 'light_mode', light: 'wb_twilight', mixed: 'dark_mode' };
    const toggleIcon = document.getElementById('theme-toggle-icon');
    if (toggleIcon) toggleIcon.textContent = iconMap[theme.mode] || 'light_mode';

    // Remember the last-used theme per mode so the toggle has a target
    if (theme.id) {
        window._themeState['last_' + (theme.mode||'dark') + 'Id'] = theme.id;
        if (theme.mode === 'light') window._themeState.lastLightId = theme.id;
        else if (theme.mode === 'dark') window._themeState.lastDarkId = theme.id;
        else window._themeState.lastMixedId = theme.id;
        window._themeState.active = theme.id;
        // Persist per-mode choice + active to localStorage
        localStorage.setItem('cockpit_theme_last_' + (theme.mode||'dark'), theme.id);
        localStorage.setItem('cockpit_theme_active', theme.id);
    }

    // ── Auto-contrast safety net ────────────────────────────────────────
    // Walks each text variable and bumps it if its contrast against the
    // primary background is below WCAG threshold. Works on any theme —
    // builtin, user-created, or future ones — so the UI never goes
    // unreadable regardless of what colors the theme defines.
    try { ensureReadability(); } catch(e) { console.warn('ensureReadability:', e); }

    // Persist resolved colors for external pages (USER_GUIDE, SETUP_GUIDE)
    try {
        const cs = getComputedStyle(document.documentElement);
        localStorage.setItem('cockpit_theme_resolved', JSON.stringify({
            bgBase: cs.getPropertyValue('--bg-base').trim(),
            bgPanel: cs.getPropertyValue('--bg-panel').trim(),
            bgCode: cs.getPropertyValue('--bg-codeblock').trim(),
            textBase: cs.getPropertyValue('--text-base').trim(),
            textDim: cs.getPropertyValue('--text-dim').trim(),
            textMuted: cs.getPropertyValue('--text-muted').trim(),
            borderDim: cs.getPropertyValue('--border-dim').trim(),
            borderMid: cs.getPropertyValue('--border-mid').trim(),
            accent: cs.getPropertyValue('--accent-cyan').trim(),
            accentAmber: cs.getPropertyValue('--accent-amber').trim(),
            heading: cs.getPropertyValue('--gemini').trim() || '#4ea3f0'
        }));
    } catch(e) {}

    // Update theme status bar
    _updateThemeStatusBar(theme);
    // the Dual-model chips pick their text from their fill: redo it once the theme's colours have settled (they transition)
    setTimeout(function () { if (typeof dualChipInk === 'function') dualChipInk(); if (typeof ckPlateHeader === 'function') ckPlateHeader(); }, 700);
}

function _updateThemeStatusBar(theme) {
    const modeEl   = document.getElementById('tsb-mode');
    const nameEl   = document.getElementById('tsb-name');
    const originEl = document.getElementById('tsb-origin');
    if (!modeEl) return;
    const mode = (theme.mode || 'dark').charAt(0).toUpperCase() + (theme.mode || 'dark').slice(1);
    modeEl.textContent = mode;
    nameEl.textContent = theme.name || theme.id || '?';
    const id = theme.id || '';
    let origin = 'Custom';
    if (theme.builtin) origin = 'Built-in';
    else if (id.startsWith('user_vsc_')) origin = 'VS Code';
    originEl.textContent = origin;
    tsbMarqueeCheck();
}

// Enables the scrolling marquee only when the theme-status content is
// actually wider than the bar (measured after layout, on the next frame so
// the new text has already reflowed). Removes it otherwise — short theme
// names just sit still, centered, no unnecessary animation.
function tsbMarqueeCheck() {
    const bar   = document.getElementById('theme-status-bar');
    const track = document.getElementById('tsb-track');
    if (!bar || !track) return;
    track.classList.remove('tsb-marquee');
    // setTimeout, not requestAnimationFrame: rAF never fires while the tab is
    // hidden, and the theme loads at boot — possibly behind another window.
    setTimeout(() => {
        const overflow = track.scrollWidth - bar.clientWidth;
        if (overflow > 2) {
            track.style.setProperty('--tsb-marquee-distance', (-overflow - 4) + 'px');
            track.style.setProperty('--tsb-marquee-duration', Math.max(4, overflow / 15) + 's');
            track.classList.add('tsb-marquee');
        }
    }, 30);
}

// Fetch the active theme (or named theme) from the server and apply it.
// Called once at page load to restore the user's last choice.
async function themeLoadAndApply(id) {
    try {
        // First fetch the list to know the active id
        if (!id) {
            const lr = await fetch('themes.php?action=list');
            const ld = await lr.json();
            if (!ld.ok) return;
            id = ld.active;
            // Never chosen a theme → follow the desktop (prefers-color-scheme; in the
            // native window WebKit derives it from GTK's prefer-dark, which the shell
            // sets from the desktop). A dark app in a light window looked wrong (VM test).
            if (!ld.chosen && window.matchMedia && window.matchMedia('(prefers-color-scheme: light)').matches) {
                const lt = (ld.themes || []).find(t => t.id === 'cockpit_original_light') || (ld.themes || []).find(t => t.mode === 'light');
                if (lt) id = lt.id;
            }
            // Build the index for the picker
            window._themeState.themesIndex = {};
            for (const t of ld.themes) {
                window._themeState.themesIndex[t.id] = t;
                if (t.mode === 'dark'  && !window._themeState.lastDarkId)  window._themeState.lastDarkId  = t.id;
                if (t.mode === 'light' && !window._themeState.lastLightId) window._themeState.lastLightId = t.id;
            }
        }
        const r = await fetch('themes.php?action=get&id=' + encodeURIComponent(id));
        const d = await r.json();
        if (d.ok && d.theme) {
            applyTheme(d.theme);
        }
    } catch (e) {
        console.warn('themeLoadAndApply failed:', e);
        // Stay on the default :root colors — non-fatal
    }
}

// Toggle between dark and light modes. Picks the most recently used theme
// of the opposite mode, or falls back to the builtin in that mode.
async function themeToggleMode() {
    const cur = window._themeState.active;
    const idx = window._themeState.themesIndex;
    const curMode = (cur && idx[cur] && idx[cur].mode) || 'dark';

    // Cycle: dark → light → mixed → dark
    const modeOrder = ['dark', 'light', 'mixed'];
    const curIdx    = modeOrder.indexOf(curMode);
    const targetMode = modeOrder[(curIdx + 1) % modeOrder.length];

    // Find last-used theme for target mode, or fall back to first builtin
    let targetId = window._themeState['last_' + targetMode + 'Id'];
    if (!idx[targetId] || idx[targetId].mode !== targetMode) {
        for (const id in idx) {
            if (idx[id].mode === targetMode && idx[id].builtin) { targetId = id; break; }
        }
    }
    if (!targetId) return;

    await themeLoadAndApply(targetId);

    // Update toggle icon: show what mode comes NEXT
    const nextMode = modeOrder[(modeOrder.indexOf(targetMode) + 1) % modeOrder.length];
    const iconMap  = { dark: 'light_mode', light: 'wb_twilight', mixed: 'dark_mode' };
    const toggleIcon = document.getElementById('theme-toggle-icon');
    if (toggleIcon) toggleIcon.textContent = iconMap[targetMode] || 'light_mode';

    // Persist
    try {
        await fetch('themes.php?action=set_active', {
            method: 'POST',
            headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({id: targetId})
        });
    } catch(e) {}
}

