    // =========================================================================
    // Signed-out request gate.
    //
    // Cockpit's polling loops start at page load, before anyone has logged in.
    // On an idle login screen that produced a measured 211 HTTP 401s in 3m14s
    // across 12 backends -- about one request a second, indefinitely, for a tab
    // showing nothing but a password box. Every one of them was refused by the
    // server, so the traffic bought nothing: it just burned CPU on both ends and
    // filled the access log.
    //
    // Teaching two dozen setInterval loops to back off individually would mean
    // touching all of them and getting all of them right. They already share one
    // chokepoint -- fetch -- so the gate goes there instead.
    //
    // It starts CLOSED and opens when the session is confirmed, rather than
    // opening after the first refusal: that way the burst never leaves the
    // browser at all, instead of being stopped one request late.
    //
    // What is never gated: auth.php (you must be able to log in), edition*.php
    // (the edition is resolved before auth), anything not a same-origin .php,
    // and every static asset. So the login page is untouched.
    //
    // This is NOT a security control and must never be treated as one -- the
    // server's own auth.php guard is what actually refuses these calls. This
    // only stops the client asking questions it already knows the answer to.
    // Hence it deliberately fails OPEN: if the session check never resolves, the
    // gate lifts after 10s and you are back to today's noisy-but-working
    // behaviour rather than a silently dead app.
    // =========================================================================
    (function () {
        var _authOK = false;        // has a valid local session been confirmed?
        var _authKnown = false;     // has the check answered at all?
        // 403 means "logged in, not allowed" (auth_require_admin/writer) and must
        // NOT latch the gate. Only the session guard's exact 401 shape counts.
        var NEVER = /(^|\/)(auth|edition|edition\.js|lang)\.php(\?|$)/;   // lang: the login screen needs its language before any session exists
        var origFetch = window.fetch.bind(window);

        function gateable(url) {
            if (!url) return false;
            // first-run account step (auth-gate.js): the account modal must reach saas.php
            // before any local session exists — the server lets first-run through
            if (window._firstRunAccountStep && /(^|\/)saas\.php(\?|$)/.test(url)) return false;
            if (/^[a-z][a-z0-9+.-]*:\/\//i.test(url) && url.indexOf(location.origin) !== 0) return false;
            return /\.php(\?|$)/.test(url) && !NEVER.test(url);
        }

        window.fetch = function (input, init) {
            var url = (typeof input === 'string') ? input : ((input && input.url) || '');
            var g = gateable(url);
            if (g && !_authOK) {
                // Answer locally in the same shape the server would have sent, so
                // callers take their existing error path and nothing new breaks.
                return Promise.resolve(new Response(
                    JSON.stringify({ ok: false, error: 'Authentication required', suppressed: true }),
                    { status: 401, headers: { 'Content-Type': 'application/json' } }));
            }
            return origFetch(input, init).then(function (r) {
                // A session that expires mid-use closes the gate again, so the
                // loops stop hammering instead of settling into the same storm.
                if (g && r.status === 401) { _authOK = false; }
                return r;
            });
        };

        // Called by the auth gate and by a successful login.
        // Opening the gate fires "cockpit-auth-open" once, so one-shot boot
        // fetches that ran while it was closed (theme load) can re-run.
        var _openFired = false;
        function gateOpened() { if (_openFired) return; _openFired = true; window._authGateOpen = true; try { document.dispatchEvent(new Event("cockpit-auth-open")); } catch (e) {} }
        // Promise form for boot code that must not run before the gate opens.
        window.authGateReady = function () { return window._authGateOpen ? Promise.resolve() : new Promise(function (res) { document.addEventListener("cockpit-auth-open", function () { res(); }, { once: true }); }); };
        window.cockpitAuthGateSet = function (ok) { _authKnown = true; _authOK = !!ok; if (_authOK) gateOpened(); };
        setTimeout(function () { if (!_authKnown) { _authOK = true; gateOpened(); } }, 10000);
    })();

    // Demo edition: gated features are explained as a one-line CANNED CHAT message
    // (never a modal). A backend that can't run here returns {edition_gate:true,...};
    // we surface that as text in the chat log, at most ONCE per feature, and only
    // after a real user interaction — so background pollers and the app's noisy
    // boot fetches never spew anything.
    var _edLastGesture = 0, _edReady = false, _edShown = {};
    ['pointerdown','keydown'].forEach(function(ev){
        document.addEventListener(ev, function(){ _edLastGesture = Date.now(); }, true);
    });
    // Mute for the first 2s so the burst of fetches Cockpit fires while booting
    // (status/usage/config probes) can't queue up a wall of explanations.
    setTimeout(function(){ _edReady = true; }, 2000);

    // Per-edition window/tab title. Set after the <title> tag has been parsed
    // (this head script runs before it), else the static tag wins.
    //
    // V1 needs this as much as the demo does: both editions shipped the same
    // static "AI Cockpit", so their windows were indistinguishable in the
    // taskbar, and cockpit_start.sh's already-open guard — which matches the
    // window title "AI Cockpit V1" — never fired for V1. That guard is what
    // stops a second window opening and focuses the existing one instead, so
    // V1 could stack duplicates. Worse, the edition switch closes windows
    // titled "AI Cockpit" when leaving V2, which matched a V1 window too.
    var _edTitle = {
        demo: 'AI Cockpit Demo (Unoperational)',
        v1:   'AI Cockpit V1'
    }[(window.COCKPIT_EDITION || 'v2')];
    if (_edTitle) {
        document.addEventListener('DOMContentLoaded', function(){
            document.title = _edTitle;
        });
    }

    // handleEditionGate(resp): returns true if the response was a demo gate (so a
    // caller that checks it can stop). Emits the canned chat line as a side effect.
    function handleEditionGate(resp){
        if (!resp || !resp.edition_gate) return false;
        var feat = resp.feature || 'This feature';
        if (_edShown[feat]) return true;                       // explained once already
        if (!_edReady) return true;                            // still in boot-mute window
        if (Date.now() - _edLastGesture > 1500) return true;   // not user-driven → stay silent
        _edShown[feat] = true;
        var msg = '<span class="material-symbols-rounded ico">lock</span> ' + feat + ' — ' + (resp.description || '') + ' ' +
                  (resp.message || 'Not available in the web demo.');
        if (typeof appendSystem === 'function') appendSystem(msg.trim());
        return true;
    }

    // Watch every fetch response for a gate payload — so the ~378 feature fetches
    // need no hand-wiring. The caller's own promise is returned untouched (peek a
    // clone only). SSE/non-JSON skipped. The once/gesture/boot guards live in
    // handleEditionGate, so this stays a thin tee.
    if ((window.COCKPIT_EDITION || 'v2') === 'demo') {
        const _origFetch = window.fetch;
        window.fetch = function(...args){
            const p = _origFetch.apply(this, args);
            p.then(resp => {
                try {
                    const ct = (resp.headers && resp.headers.get('content-type')) || '';
                    if (ct.indexOf('application/json') === -1) return;
                    resp.clone().json().then(d => { if (d && d.edition_gate) handleEditionGate(d); }).catch(()=>{});
                } catch(e){}
            }).catch(()=>{});
            return p;
        };
    }
