// =============================================================================
// Auth gate — check session before rendering anything
// The chat's label for the person: their local login in capitals ([DARIO] was
// hard-coded — every user on every machine was greeted as Dario).
function _userLabel() { return '[' + String(window._cockpitUser || 'YOU').toUpperCase() + ']'; }
// =============================================================================
(async function _authGate() {
    let r, d;
    try {
        r = await fetch('auth.php?action=check');
        d = await r.json();
    } catch(e) { return; }
    // A definite "no" is still an answer: latch the request gate CLOSED so the
    // fail-open timer never fires. Only a check that does not answer at all
    // should lift the gate.
    if (!d.ok && window.cockpitAuthGateSet) cockpitAuthGateSet(false);
    if (d.ok) {
        try { sessionStorage.removeItem('cockpit_remember_tried'); } catch (e) {}
        window._cockpitUser = d.user;
        window._cockpitRole = d.role;
        window._cockpitId   = d.id;
        _cockpitLabelUser();
        if (window.cockpitAuthGateSet) cockpitAuthGateSet(true);   // open the request gate
        return;
    }
    const isSetup = !!d.needs_setup;
    // Full edition, first run: the person's Cockpit account comes FIRST and the
    // local login takes its name (one identity per machine; extra local logins
    // later may use any name). Stand-alone: local login only, any name.
    // Sequence: step 1 opens the account modal (saas.php is reachable during
    // first-run); its sign-in/registration fires 'cockpit-saas-signed-in';
    // step 2 is the local password with the username locked to the account.
    const fullFirstRun = isSetup && (window.COCKPIT_EDITION || 'v2') === 'v2';
    let lockedName = '';
    if (fullFirstRun) {
        window._firstRunAccountStep = true;
        lockedName = await new Promise(resolve => {
            const st = document.createElement('div');
            st.id = 'auth-gate';
            st.style.cssText = 'position:fixed;inset:0;z-index:99998;background:var(--bg-base,#0f141c);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui,sans-serif);';
            st.innerHTML =
                '<div style="width:min(420px,90vw);padding:30px;border:1px solid var(--border-mid,#2a2f3a);border-radius:8px;background:var(--bg-darker,#121824);box-shadow:0 8px 40px rgba(0,0,0,0.7);text-align:center;">' +
                '<div style="font-size:28px;margin-bottom:6px;">&#x2699;</div>' +
                '<h1 style="margin:0 0 6px;font-size:18px;color:var(--text-primary,#e2e8f0);">Welcome to AI Cockpit</h1>' +
                '<p style="margin:0 0 16px;font-size:12px;color:var(--text-dim,#a0aec0);line-height:1.5;">Step 1 of 2 — your Cockpit account (free, no card). Sign in if you have one, or create it. ' +
                'This machine\'s login will use the same name.</p>' +
                '<button id="auth-acct-btn" style="padding:10px 16px;font-size:13px;font-weight:600;border:none;border-radius:4px;cursor:pointer;background:var(--accent-blue,#2b6cb0);color:#fff;">Sign in or create your account</button>' +
                '<div id="auth-acct-hint" style="margin-top:10px;font-size:11px;color:var(--text-dim,#718096);"></div></div>';
            document.body.appendChild(st);
            const open = () => { if (typeof saasAccountOpen === 'function') saasAccountOpen('firstrun'); else document.getElementById('auth-acct-hint').textContent = T('msg.account.module.still.loading.try.again.in.a', 'Account module still loading — try again in a second.'); };
            document.getElementById('auth-acct-btn').addEventListener('click', open);
            document.addEventListener('cockpit-saas-signed-in', ev => { window._firstRunAccountStep = false; st.remove(); resolve((ev.detail && ev.detail.username) || ''); }, { once: true });
        });
    }
    // One attempt per page life (sessionStorage): a token that "works" but leaves
    // no session cookie would otherwise reload forever.
    let _remTried = false; try { _remTried = sessionStorage.getItem('cockpit_remember_tried') === '1'; sessionStorage.setItem('cockpit_remember_tried', '1'); } catch (e) {}
    if (!isSetup && !_remTried && await authTryRemember()) { location.reload(); return; }
    const ov = document.createElement('div');
    ov.id = 'auth-gate';
    ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:var(--bg-base,#0f141c);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui,sans-serif);';
    ov.innerHTML =
        '<div style="width:min(360px,90vw);padding:30px;border:1px solid var(--border-mid,#2a2f3a);border-radius:8px;background:var(--bg-darker,#121824);box-shadow:0 8px 40px rgba(0,0,0,0.7);">' +
        '<div style="text-align:center;margin-bottom:20px;">' +
        '<div style="font-size:28px;margin-bottom:6px;">&#x2699;</div>' +
        '<h1 style="margin:0;font-size:18px;color:var(--text-primary,#e2e8f0);">Cockpit App Login (Local)</h1>' +
        '<p style="margin:4px 0 0;font-size:11px;color:var(--text-dim,#718096);">' +
        (isSetup ? (lockedName ? 'Step 2 of 2 — choose the password that unlocks this app on this machine. The name is your account name.' : 'Create the local account that unlocks this app on this machine') : 'This machine’s local app access — separate from your online Cockpit Account') + '</p></div>' +
        '<div style="display:flex;flex-direction:column;gap:10px;">' +
        '<input id="auth-user" type="text" placeholder="Username (Local)" autocomplete="username" ' + (lockedName ? 'value="' + lockedName.replace(/"/g, '&quot;') + '" readonly title="Your Cockpit account name — the first login on this machine uses it" ' : '') +
        'style="background:var(--bg-base,#0f141c);color:var(--text-base,#cbd5e0);border:1px solid var(--border-dim,#2d3748);padding:8px 10px;font-size:13px;border-radius:4px;">' +
        _pwWrap('<input id="auth-pass" type="password" placeholder="Password (Local)" autocomplete="current-password" ' +
        'style="background:var(--bg-base,#0f141c);color:var(--text-base,#cbd5e0);border:1px solid var(--border-dim,#2d3748);padding:8px 10px;font-size:13px;border-radius:4px;width:100%;box-sizing:border-box;">', 'auth-pass') +
        (isSetup ? _pwWrap('<input id="auth-pass2" type="password" placeholder="Confirm password" autocomplete="new-password" style="background:var(--bg-base,#0f141c);color:var(--text-base,#cbd5e0);border:1px solid var(--border-dim,#2d3748);padding:8px 10px;font-size:13px;border-radius:4px;width:100%;box-sizing:border-box;">', 'auth-pass2') : '') +
        (isSetup ? '' : bwFillBtn('local', 'auth-user', 'auth-pass', 'auth-err')) +
        ((!isSetup && _inShell) ? '<label style="display:flex;align-items:flex-start;gap:6px;font-size:11px;color:var(--text-dim,#a0aec0);cursor:pointer;"><input id="auth-remember" type="checkbox" checked style="margin:2px 0 0;"><span>Keep me signed in on this computer — a sign-in token is kept in your OS keyring (GNOME Keyring / KWallet), not in Cockpit\'s files. Sign out removes it.</span></label>' : '') +
        '<div id="auth-err" style="font-size:11px;color:var(--accent-orange,#ffa500);min-height:16px;"></div>' +
        '<button id="auth-submit" style="padding:9px;font-size:13px;font-weight:600;border:none;border-radius:4px;cursor:pointer;' +
        'background:var(--accent-blue,#2b6cb0);color:#fff;">' +
        (isSetup ? 'Create account' : 'Sign in') + '</button></div></div>';
    document.body.appendChild(ov);

    const userEl = document.getElementById('auth-user');
    const passEl = document.getElementById('auth-pass');
    const pass2El = document.getElementById('auth-pass2');
    const errEl = document.getElementById('auth-err');
    const btn = document.getElementById('auth-submit');
    if (lockedName) passEl.focus(); else userEl.focus();

    async function submit() {
        const username = userEl.value.trim();
        const password = passEl.value;
        if (!username || !password) { errEl.textContent = T('msg.enter.username.and.password', 'Enter username and password'); return; }
        if (isSetup) {
            if (password !== pass2El.value) { errEl.textContent = T('msg.passwords.do.not.match', 'Passwords do not match'); return; }
            if (password.length < 6) { errEl.textContent = T('msg.password.must.be.at.least.6.characters', 'Password must be at least 6 characters'); return; }
        }
        btn.disabled = true;
        btn.textContent = '...';
        errEl.textContent = '';
        try {
            const action = isSetup ? 'setup' : 'login';
            const resp = await fetch('auth.php?action=' + action, {
                method: 'POST',
                headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({username, password, remember: !isSetup && _inShell && !!document.getElementById('auth-remember')?.checked, device: 'AI Cockpit window'}),
            });
            const result = await resp.json();
            if (result.ok) {
                if (result.remember_token) { if (!(await krSet(KR_LOCAL_KEY, result.remember_token))) console.warn('keyring unavailable — not kept signed in'); }
                window._cockpitUser = result.user;
                window._cockpitRole = result.role;
                window._cockpitId   = result.id;
                _cockpitLabelUser();
                if (window.cockpitAuthGateSet) cockpitAuthGateSet(true);   // open the request gate
                ov.remove();
                return;
            }
            errEl.textContent = result.error || 'Authentication failed';
        } catch(e) {
            errEl.textContent = T('msg.connection.error', 'Connection error');
        }
        btn.disabled = false;
        btn.textContent = isSetup ? 'Create account' : 'Sign in';
    }

    btn.addEventListener('click', submit);
    [userEl, passEl, pass2El].forEach(el => {
        if (el) el.addEventListener('keydown', e => { if (e.key === 'Enter') submit(); });
    });
})();

/* ── Orientation lock ── */
try { screen.orientation.lock('landscape').catch(()=>{}); } catch(e) {}

/* ── Mobile / responsive helpers ── */
function mobileToggleControls() {
    const p = document.getElementById('topbar-controls-panel');
    const ov = document.getElementById('mobile-overlay');
    if (p.classList.contains('mobile-open')) {
        p.classList.remove('mobile-open');
        ov.classList.remove('active');
    } else {
        mobileCloseAll();
        p.classList.add('mobile-open');
        ov.classList.add('active');
    }
}
function mobileCloseAll() {
    document.getElementById('topbar-controls-panel').classList.remove('mobile-open');
    document.getElementById('mobile-overlay').classList.remove('active');
    document.getElementById('sidebar-left').classList.remove('mobile-show');
    document.getElementById('sidebar-right').classList.remove('mobile-show');
}
function mobileShowSidebar(side) {
    const sb = document.getElementById('sidebar-' + side);
    const ov = document.getElementById('mobile-overlay');
    if (sb.classList.contains('mobile-show')) {
        sb.classList.remove('mobile-show');
        ov.classList.remove('active');
    } else {
        mobileCloseAll();
        sb.classList.add('mobile-show');
        ov.classList.add('active');
    }
}

async function cockpitLogout() {
    let tok = null;
    if (_inShell) { tok = await krGet(KR_LOCAL_KEY); await krDel(KR_LOCAL_KEY); }
    try { await fetch('auth.php?action=logout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(tok ? { remember_token: tok } : {}) }); } catch(e) {}
    location.reload();
}

