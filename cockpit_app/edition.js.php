<?php
// =============================================================================
// edition.js.php — emits a tiny blocking JS shim that stamps the edition onto
// the document BEFORE first paint, so SaaS UI in v1/demo is hidden with no flash.
//
// index.html loads this as the FIRST <script> in <head>:
//     <script src="edition.js.php"></script>
//
// It sets window.COCKPIT_EDITION and <html data-edition="…"> synchronously.
// CSS then hides `.saas-only` for v1/demo via :root[data-edition="…"] selectors.
// =============================================================================
require_once __DIR__ . '/edition.php';

header('Content-Type: application/javascript; charset=utf-8');
header('Cache-Control: no-store');   // edition is per-deploy; never cache cross-edition

$ed = edition();
?>
window.COCKPIT_EDITION = <?php echo json_encode($ed); ?>;
document.documentElement.setAttribute('data-edition', window.COCKPIT_EDITION);

/* ── per-edition settings ─────────────────────────────────────────────────────
   localStorage is scoped to the ORIGIN, not the path, so /cockpit/ and
   /cockpit-v1/ share one store: every one of the ~39 cockpit_* keys was
   literally the same variable in both editions. Switching theme or window mode
   in one changed the other, and so did the chat, the selected tabs, the mode and
   the style — reported 2026-09-26.

   Fixed by namespacing the key, here, before any other script runs:
     v2    keys unchanged   — existing installs keep every setting, no migration
     v1    keys prefixed    — its own tabs, chat, mode, style, model
     demo  keys prefixed    — the public demo never inherits a visitor's state

   APPEARANCE is deliberately exempt and stays shared, because wanting one look
   across both is the normal case. `cockpit_separate_appearance` (itself shared,
   so both editions agree) flips that per user.

   Kept as a wrapper rather than rewriting 39 call sites: one place to reason
   about, and nothing else in the app has to know an edition exists. */
(function () {
    var ed = window.COCKPIT_EDITION || 'v2';
    if (ed === 'v2') return;                      /* v2 owns the unprefixed keys */
    var APPEARANCE = {
        cockpit_theme: 1, cockpit_theme_custom: 1, cockpit_font: 1,
        cockpit_font_size: 1, cockpit_typography: 1, cockpit_frameless: 1,
        cockpit_win_mode: 1, cockpit_separate_appearance: 1
    };
    var ls;
    try { ls = window.localStorage; if (!ls) return; } catch (e) { return; }
    var raw = {
        get: ls.getItem.bind(ls), set: ls.setItem.bind(ls),
        rem: ls.removeItem.bind(ls), key: ls.key.bind(ls)
    };
    var sep = function () {
        try { return raw.get('cockpit_separate_appearance') === '1'; } catch (e) { return false; }
    };
    /* Appearance keys stay unprefixed unless the user asked for them to split.
       cockpit_separate_appearance itself is ALWAYS unprefixed — if it were
       namespaced the two editions could disagree about whether they agree. */
    var map = function (k) {
        if (k === 'cockpit_separate_appearance') return k;
        if (APPEARANCE[k] && !sep()) return k;
        return ed + ':' + k;
    };
    ls.getItem    = function (k) { return raw.get(map(k)); };
    ls.setItem    = function (k, v) { return raw.set(map(k), v); };
    ls.removeItem = function (k) { return raw.rem(map(k)); };
    window.cockpitLsKey = map;      /* for code that builds keys dynamically */
})();
