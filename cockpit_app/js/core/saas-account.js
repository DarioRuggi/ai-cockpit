// =============================================================================
// SaaS account (V2) — talks to saas.php broker → cockpit_auth → cockpit.ruggi.site
// =============================================================================
let _saasAcct = null;
// The server's verdict on this machine, from saas.php?action=status → machine-status.php.
// { known:true|false|null, needs_account:bool|null, reason:string }. null `known`
// means the server did not answer — that is NOT a refusal, see saasRegistrationGate().
let _saasUnofficial = false;   // ruggi.site refused this build id (see integrity)
let _saasMachine = null;
// Only the full (v2) edition has the SaaS/account layer. In v1/demo the SaaS
// backends 404 and the SaaS UI is hidden (.saas-only) — this short-circuits the
// client so no account fetch fires and no registration modal is ever forced.
function saasEnabled() { return (window.COCKPIT_EDITION || 'v2') === 'v2'; }

// Paid-tier entitlement check — MIRRORS entitle.php server-side (which is the
// real wall; this is UX only). cruise=Basic+, cognition=Pro+, everywhere=add-on.
// Local editions (no saas) are ungated; beta opens every gate; unknown → deny.
function capCan(cap) {
    if (!saasEnabled()) return true;            // v1/demo: no billing to enforce
    const a = _saasAcct;
    if (a && a.offline && (cap === 'cruise' || cap === 'cognition')) return false;   // account server not reached: Cruise and AutoCognition wait (the server side says the same, entitle.php)
    if (a && a.beta) return true;               // public beta opens paid gates
    if (!a) return false;
    if (cap === 'cruise')     return !!a.can_cruise;
    if (cap === 'cognition')  return !!a.can_cognition;
    if (cap === 'everywhere') return !!a.can_everywhere;
    return false;
}
// True when a hive.php response was refused by the server entitlement gate.
// Surfaces a one-line upsell in chat and returns true so callers can bail.
function hiveGated(d) {
    if (!d || !d.entitlement_gate) return false;
    if (typeof appendSystem === 'function') appendSystem(T('msg.icon.lock.message', '[[icon:lock]] {message}', {message: (d.message || 'This feature needs a higher tier.')}));
    return true;
}

async function saasApi(action, body) {
    if (!saasEnabled()) return { ok:false, error:'saas_disabled', disabled:true };
    try {
        const opt = body ? { method:'POST', body: JSON.stringify(body) } : {};
        const r = await fetch('saas.php?action=' + action, opt);
        const j = await r.json();
        // The server is the authority on whether this install has an account.
        // When it says no, raise the gate here rather than letting the caller
        // fail with some feature-specific error the user cannot act on.
        // An unofficial/changed build is refused account SERVICES, not local use —
        // the server says so itself. Say it once; never trap the person in a
        // closeless modal for it (the rig after build 64: files.php differed).
        if (j && j.needs_account && j.reason === 'unofficial_build') {
            if (!window._unofficialSaid) { window._unofficialSaid = true; appendSystem(T('msg.cockpit.account.services.are.off.this.instal', 'Cockpit account services are off: this install differs from its official build (Logo → Integrity shows what changed and offers Restore). Everything local keeps working.')); }
        } else if (j && j.needs_account) {
            appendSystem(T('msg.this.needs.a.cockpit.account.opening.sign.in', 'This needs a Cockpit account — opening sign-in.'));
            if (typeof saasAccountOpen === 'function') saasAccountOpen(true);
        }
        return j;
    } catch(e) { return { ok:false, error:'network' }; }
}
// The BETA badge used to be driven from here — the site's pubconfig and the
// account's beta flag. It is now stamped into the build manifest and rendered
// in boot.js, because the stage belongs to the build rather than to the
// viewer's account, and the Stand-alone edition has no account to ask.
// This is kept as a no-op so the call sites read the same. 2026-09-26.
let _betaKnown = false;
async function saasBetaBadge() { return; }
async function _saasBetaBadgeRetired() {
    if (_betaKnown || !saasEnabled()) return;
    try { const r = await saasApi('pubconfig'); if (r && r.ok) { _betaKnown = true; const bb = document.getElementById('beta-badge'); if (bb && r.beta) bb.style.display = 'inline-block'; } } catch (e) {}
}
async function saasAccountLoad() {
    saasBetaBadge();
    const r = await saasApi('status');
    const chip = document.getElementById('saas-tier-chip');
    if (!r || !r.ok) { if (chip) chip.textContent = ''; _saasAcct = null; _saasMachine = null; updateLicenseStatus(); return; }
    _saasAcct = r.account;
    _saasMachine = r.machine || null; window._saasMachine = _saasMachine;
    if (chip) {
        const a = r.account;
        _saasChip(a);
        // (The BETA badge moved to the build manifest — see boot.js.)
        chip.style.color = a.signed_in ? (a.offline ? 'var(--warn)' : 'var(--gemini)') : 'var(--text-dim)';
    }
    updateLicenseStatus();
    // If signed in, query the server (by machine id) for the live subscription
    // state so the label reflects the real tier, not just the cached one.
    if (r.account && r.account.signed_in) {
        const fr = await saasApi('refresh');
        if (fr && fr.account) { _saasAcct = fr.account; _saasChip(fr.account); }
        updateLicenseStatus();
        // is_admin isn't part of the cached account (it's a users-table flag,
        // not a license field) — fetch it once so _saasView can show an Admin
        // panel link. Convenience only; the panel itself is separately gated.
        try { const pr = await saasApi('account_profile'); if (pr && pr.ok) _saasAcct.is_admin = !!pr.is_admin; } catch(e) {}
    }
    // combosInitTier0() fires on DOMContentLoaded without waiting for account
    // status — if it already showed the empty-state, refresh it now that
    // _saasAcct is accurate (avoids a stale "Register" prompt for signed-in users).
    if (!_combosData && typeof combosRenderEmptyTier0 === 'function') combosRenderEmptyTier0();
    saasRegistrationGate();
    // Entitlement is now known — re-evaluate the tier-gated hive UI (the initial
    // DOMContentLoaded pass ran before _saasAcct loaded, so the sidebar Hive section defaulted off).
    try { if (typeof hiveBarInit === 'function') hiveBarInit(); if (typeof hiveAvailProbe === 'function') hiveAvailProbe(); if (typeof hiveCruiseRetire === 'function') hiveCruiseRetire(); } catch (e) {}
}

// Forced registration gate: blocks the app until the user registers or logs
// in to their (free) SaaS account — once, at first run. Local features are
// still free forever; this only registers the install. Skipped when genuinely
// offline at first run (can't reach cockpit.ruggi.site) so a truly offline
// machine isn't locked out — it re-prompts next launch once online, and never
// prompts again once signed in (see saasAccountLoad()).
// Shared credential-types explainer — same content lives on the website
// (cockpit.ruggi.site/account.php), keep the four descriptions in sync if edited.
function ckShowCredHelp() {
    let ov = document.getElementById('ck-cred-help-ov'); if (ov) ov.remove();
    ov = document.createElement('div'); ov.id = 'ck-cred-help-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100010;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(460px,92vw);padding:22px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<h2 style="margin:0 0 12px;font-size:16px;color:var(--text-primary);">Four kinds of password</h2>' +
        '<div style="font-size:12.5px;line-height:1.55;color:var(--text-dim);">' +
        '<p style="margin:0 0 10px;"><b style="color:var(--text-primary);">Local</b> — your login for this specific installed Cockpit. Only gates this app\'s web UI on your machine, nothing to do with any account.</p>' +
        '<p style="margin:0 0 10px;"><b style="color:var(--text-primary);">Saas</b> — your free/paid Cockpit account (Marketplace, subscription). Same username+password whether you sign in here or on the website\'s Account page.</p>' +
        '<p style="margin:0 0 10px;"><b style="color:var(--text-primary);">Admin</b> — an is_admin Saas account, for the moderation/control panels. Same login mechanics as Saas, just privileged.</p>' +
        '<p style="margin:0;"><b style="color:var(--text-primary);">Token</b> — not a password, a single secret string appended to a URL (<code>?token=...</code>) for one-click admin auto-login. Never typed into a form.</p>' +
        '</div>' +
        '<button class="action-btn" style="width:100%;margin-top:16px;background:var(--accent-blue);color:#fff;padding:8px;" onclick="document.getElementById(\'ck-cred-help-ov\').remove()">Got it</button>' +
        '</div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}

function saasRegistrationGate() {
    if (!saasEnabled()) return;   // v1/demo: never force the account gate
    const up = () => { if (!document.getElementById('saas-acct-ov')) saasAccountOpen(true); };

    // The SERVER's answer outranks everything below it. _saasMachine.known is
    // false only when cockpit.ruggi.site looked this machine_id up in
    // user_machines and did not find a live licence behind it. A local account
    // file cannot override that — the file lives on a machine the user controls,
    // the registry does not. This is what makes the gate enforceable rather than
    // advisory, and it is why there is no client-sent "I am signed in" flag:
    // a client-asserted signal would just be the same unenforceable claim again.
    // Keyed on `known`, NOT on needs_account: this is a REGISTRATION gate, and it
    // asks "does an account exist behind this install", not "is the subscription
    // current". A registered machine whose licence lapsed keeps its account —
    // it is the per-feature entitlement checks that must say no to it, not this.
    if (_saasMachine && _saasMachine.known === false && _saasMachine.reason === 'unofficial_build') {
        // ruggi.site refused the build id (integrity): say why, once.
        if (!_saasUnofficial) {
            _saasUnofficial = true;
            appendError(T('msg.icon.verified.user.this.install.is.not.an.of', '[[icon:verified_user]] This install is not an official AI Cockpit build (its files differ from the published bundle). Local use is unrestricted; Cockpit account services are provided to official builds only. Logo → Integrity shows what changed and offers Restore.'));
        }
        // No gate for this: registration is refused too, so a closeless modal would be
        // a dead end — and local use is unrestricted by design. (rig, build 64)
        document.getElementById('saas-acct-ov')?.remove(); return;
    }
    if (_saasMachine && _saasMachine.known === false) {
        up(); return;
    }

    // known === null means the server did not answer at all (offline, endpoint
    // not deployed yet, old server). Deliberately NOT treated as a refusal —
    // falling through to the local checks below keeps offline paid installs
    // working. A refusal already received is cached server-side of this call
    // (saas.php keeps the last verdict while unreachable), so cutting the
    // network after being refused does not reopen the app.

    // Signed in locally and not refused → take the gate down.
    if (_saasAcct && _saasAcct.signed_in) { document.getElementById('saas-acct-ov')?.remove(); return; }
    // _saasAcct === null means we could not determine the account state at all
    // (saas.php missing, erroring, or the fetch threw). That used to take the
    // same branch as "signed in" and silently removed the gate — an entitlement
    // check that fails OPEN. Unknown is not permission: gate stays up.
    if (!_saasAcct) { up(); return; }
    // Known-offline with a cached licence: don't lock someone out of their own
    // paid install because the network is down. This is a deliberate pass, and
    // it requires an account to have existed in the first place.
    if (_saasAcct.offline) return;
    up();
}

// Gate decline path: this install stays on V2 (already downloaded), but this
// person doesn't want an account at all — send them to the download page,
// where re-running the (single, unified) installer and picking Stand-alone
// switches this same install to account-free/local-only. Leaves the gate up
// on THIS install (still needs an account or the Stand-alone flag to
// proceed) so they don't get stuck thinking this tab "worked" — the real
// next step is re-running install_cockpit.sh with Stand-alone selected.
// No new tab, no download page (that sent a freshly installed user back to
// cockpit.ruggi.site/download.php — seen on the first VM test). Everything
// needed is already on this machine: the kept install bundle re-runs with
// Stand-alone picked, and a side-by-side V1 (installer choice "both") is one
// link away. The gate stays up on THIS install by design.
async function saasDeclineToV1() {
    const body = document.getElementById('saas-acct-body'); if (!body) return;
    let v1 = false;
    try { const r = await fetch('../cockpit-v1/', { method: 'HEAD', cache: 'no-store' }); v1 = r.ok; } catch (e) {}
    const cmd = 'cd ~/scripts/cockpit_data/install_src && tar -xzf cockpit_install.tar.gz && bash cockpit/install_cockpit.sh';
    body.innerHTML =
        '<div style="font-weight:600;margin-bottom:6px;">No account — switch this install to Stand-alone</div>' +
        '<div style="color:var(--text-dim);font-size:12px;line-height:1.5;margin-bottom:10px;">This is the Full edition: it stays locked without a (free, no-card) account. ' +
        'The Stand-alone edition is the same app with no account and no calls to our server — no Marketplace, Cruise, AutoCognition or Everywhere relay; everything local works.</div>' +
        (v1 ? '<a class="action-btn" style="display:block;text-align:center;padding:8px;margin-bottom:10px;" href="../cockpit-v1/">Open the Stand-alone edition installed beside this one →</a>' : '') +
        '<div style="font-size:12px;margin-bottom:4px;">Or switch this install (re-runs the kept installer; pick <b>Stand-alone</b> at the edition question, nothing else changes):</div>' +
        '<pre style="font-size:11px;white-space:pre-wrap;user-select:all;padding:8px;background:rgba(0,0,0,.25);border-radius:6px;margin:0 0 10px;">' + cmd + '</pre>' +
        '<div style="display:flex;gap:8px;">' +
        '<button class="action-btn" onclick="navigator.clipboard&&navigator.clipboard.writeText(\'' + cmd + '\');appendSystem(\'Command copied — paste it in a terminal.\')">Copy command</button>' +
        '<button class="action-btn" onclick="saasAccountOpen()">Back</button></div>';
}

// Gate for online features: returns true if signed in, else nudges to register.
function saasRequireAccount(feature) {
    if (_saasAcct && _saasAcct.signed_in) return true;
    appendSystem(T('msg.feature.needs.a.free.account.opening.registr', '{feature} needs a free account — opening registration.', {feature: (feature || 'This feature')}));
    if (typeof saasAccountOpen === 'function') saasAccountOpen();
    return false;
}

// Map account + connectivity → the licence plate: the plan's name on a plate in its own finish (css/ui-polish.css .ck-plate), plus a joined EVERYWHERE plate when the account has the add-on.
// Offline / unregistered keep their symbol (the cue that does not depend on colour). The names are the plan names of plans_lib.php; the legacy names map the way the server maps them.
function _licenseLabel(a, online) {
    const P = (sym, txt, fin) => ({ t: (sym ? sym + ' ' : '') + txt, fin: fin, ew: false });
    if (!online)            return P('!', 'OFFLINE',      'red');
    if (!a || !a.signed_in) return P('○', 'UNREGISTERED', 'graphite');
    if (a.offline)          return P('!', 'OFFLINE',      'red');
    const LEGACY = { starter: 'free', content: 'plus', basic: 'plus', ultimate: 'max', combined: 'max', everywhere: 'free' };
    const FIN = { free: 'steel', plus: 'brass', pro: 'bronze', max: 'gold', family: 'teal', founder: 'obsidian' };
    let raw = String(a.tier || 'free').toLowerCase().trim();
    const plan = LEGACY[raw] || (FIN[raw] ? raw : 'free');
    const l = P('', plan.toUpperCase(), FIN[plan] || 'steel');
    l.ew = !!a.can_everywhere || plan === 'max' || raw === 'everywhere';   // Max includes Everywhere; the add-on alone shows on a Free plate
    return l;
}
// The brand plate's finish follows the header: a light plate on a dark header, a dark plate on a light one (body[data-hdr]).
function ckPlateHeader() {
    try {
        let e = document.querySelector('.cockpit-brand') || document.body, c = null;
        while (e) { c = getComputedStyle(e).backgroundColor; if (c && !/rgba\(0, 0, 0, 0\)|transparent/.test(c)) break; e = e.parentElement; }
        const m = (c || 'rgb(0,0,0)').match(/[\d.]+/g).map(Number);
        const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
        document.body.dataset.hdr = (0.2126 * f(m[0]) + 0.7152 * f(m[1]) + 0.0722 * f(m[2])) > 0.4 ? 'light' : 'dark';
    } catch (e) {}
}
function updateLicenseStatus() {
    const el = document.getElementById('license-status'); if (!el) return;
    // Connectivity comes from the SaaS layer (account.offline), NOT navigator.onLine
    // — the latter is unreliable in this runtime (reports false while truly online).
    const l = _licenseLabel(_saasAcct, true);
    el.textContent = '';
    const base = document.createElement('span'); base.className = 'ck-plate lic ' + l.fin; base.textContent = l.t; el.appendChild(base);
    if (l.ew) { const ew = document.createElement('span'); ew.className = 'ck-plate lic ew indigo'; ew.textContent = T('msg.everywhere', 'EVERYWHERE'); el.appendChild(ew); }
    el.setAttribute('aria-label', l.t + (l.ew ? ' + EVERYWHERE' : ''));
    ckPlateHeader();
}
window.addEventListener('online',  updateLicenseStatus);
window.addEventListener('offline', updateLicenseStatus);
function _saasTierLabel(t) {
    const m = {free:'Free',plus:'Plus',pro:'Pro',max:'Max',family:'Family',founder:'Founder',starter:'Starter',basic:'Basic',ultimate:'Ultimate',everywhere:'Everywhere',combined:'Combined',content:'Content'};
    t = String(t || 'free').toLowerCase();
    return m[t] || (t.charAt(0).toUpperCase() + t.slice(1));
}
function _saasChip(a) {
    const chip = document.getElementById('saas-tier-chip'); if (!chip) return;
    chip.textContent = a && a.signed_in ? _saasTierLabel(a.tier).toUpperCase() : 'FREE';   // BETA is a badge on the logo card, and a line in the account modal
    chip.style.color = a && a.signed_in ? (a.offline ? 'var(--warn)' : 'var(--gemini)') : 'var(--text-dim)';
}
function _saasInput(id, ph, type, onEnter) {
    return '<input id="'+id+'" '+(onEnter ? 'onkeydown="if(event.key===\'Enter\'){'+onEnter+';return false;}" ' : '')+'type="'+(type||'text')+'" placeholder="'+ph+'" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:7px 9px;font-size:12px;border-radius:4px;">';
}
// Format a recovery ISO timestamp (date('c'), carries server tz offset) as
// "DD/MM/YYYY HH:MM:SS (server) · <local> (local)".
function _fmtRecovered(iso){
    try {
        const d = new Date(iso);
        const m = String(iso).match(/(\d{4})-(\d{2})-(\d{2})T(\d{2}:\d{2}:\d{2})/);
        const srv = m ? `${m[3]}/${m[2]}/${m[1]} ${m[4]}` : String(iso);
        return `${srv} (server) · ${d.toLocaleString()} (local)`;
    } catch(e){ return String(iso); }
}
function _saasView(a, binPresent, gateMode) {
    if (!binPresent) return '<div style="font-size:12px;color:var(--text-dim);">Auth component not installed — local features work; account/marketplace unavailable.</div>';

    // ── Not signed in → LOGIN form (+ Register [+ Decline, gate mode only]) ──
    if (!a.signed_in) return '<div style="font-size:11px;font-weight:700;color:var(--text-primary);margin-bottom:2px;">Cockpit Account Login (Saas)</div>' +
        '<div style="font-size:12.5px;color:var(--text-dim);margin-bottom:10px;">Your online SaaS account (marketplace, subscription) — separate from the app login you used to open Cockpit.</div>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        _saasInput('saas-user','Username (Saas)') +
        _saasInput('saas-pass','Password (Saas)','password','saasDoLogin()') +
        bwFillBtn('saas', 'saas-user', 'saas-pass', 'saas-err') +
        '<div id="saas-err" style="font-size:11px;color:var(--warn);min-height:14px;"></div>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;padding:7px;" onclick="saasDoLogin()">Log in (Saas)</button>' +
        '<div style="text-align:center;font-size:10px;"><a href="'+_esc((typeof _saasAcct !== 'undefined' && _saasAcct && _saasAcct.account_url) || 'https://cockpit.ruggi.site/account.php')+'" target="_blank" style="color:var(--text-dim);">Forgot password?</a> · <a href="#" onclick="ckShowCredHelp();return false;" style="color:var(--text-dim);">Which password?</a></div>' +
        '<div style="text-align:center;font-size:10px;color:var(--text-dim);margin:2px 0;">— new here? —</div>' +
        '<button class="action-btn" style="padding:7px;" onclick="saasShowRegister()"><span class="material-symbols-rounded ico">auto_awesome</span> Create an account (free, no card)</button>' +
        (gateMode ?
            '<div style="text-align:center;font-size:10px;color:var(--text-dim);margin:6px 0 0;">— or —</div>' +
            '<button class="action-btn" style="padding:7px;color:var(--text-dim);" onclick="saasDeclineToV1()">I don\'t want to create an account →</button>'
            : '') +
        '</div>';

    // ── Signed in → profile ──
    const tierName = _saasTierLabel(a.tier);
    const verify = a.email_verified
        ? '<span class="action-btn" style="padding:2px 8px;border-color:var(--accent-green,#7dc4a3);color:var(--accent-green,#7dc4a3);"><span class="material-symbols-rounded ico">check</span> Email verified</span>'
        : '<button class="action-btn" style="padding:2px 8px;border-color:var(--warn);color:var(--warn);" onclick="saasResendVerify(this)" title="Resend the verification link to your email"><span class="material-symbols-rounded ico">warning</span> Verify email — resend link</button>';
    return '<div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;">' +
        '<span style="font-weight:700;font-size:14px;">'+_esc(a.nickname||a.username||a.email||'You')+'</span>' + (a.username && a.nickname && a.username !== a.nickname ? '<span style="font-size:11px;color:var(--text-dim);margin-left:6px;">@'+_esc(a.username)+'</span>' : '') +
        '<span class="action-btn" style="padding:3px 10px;">'+_esc(tierName)+'</span>' +
        (a.lifetime ? '<span style="margin-left:6px;font-size:11px;color:var(--text-dim);" title="A lifetime plan never expires; it covers this version and the next ones up to the version shown.">'+_esc(T('ui.plan.lifetime', 'Lifetime') + (a.major_max ? ' · ' + T('ui.plan.covers.to', 'covers versions up to {n}', {n: a.major_max}) : ''))+'</span>' : '') +
        (a.offline?'<span class="action-btn" style="padding:3px 10px;border-color:var(--warn);color:var(--warn);">● Offline'+(a.grace_days_left!=null?(' ('+a.grace_days_left+'d)'):'')+'</span>':'') +
        '</div>' +
        '<div style="margin-top:8px;display:flex;gap:6px;flex-wrap:wrap;">'+verify+'</div>' +
        (a.beta?'<div style="margin-top:8px;font-size:11px;color:var(--accent-blue);"><span style="font-family:var(--font-mono);font-size:10px;font-weight:800;letter-spacing:.06em;color:#ffd84a;background:#000;padding:1px 5px;border-radius:3px;margin-right:6px;">BETA</span>Public beta — everything is unlocked for all registered users. Subscriptions arrive when beta ends.</div>'
               :'<div style="margin-top:8px;font-size:12px;">'+(a.can_cruise?'<span class="material-symbols-rounded ico">check</span>':'<span class="material-symbols-rounded ico">close</span>')+' Autopilot Cruise &nbsp; '+(a.can_cognition?'<span class="material-symbols-rounded ico">check</span>':'<span class="material-symbols-rounded ico">close</span>')+' AutoCognition &nbsp; '+(a.can_everywhere?'<span class="material-symbols-rounded ico">check</span>':'<span class="material-symbols-rounded ico">close</span>')+' Everywhere</div>') +
        ((a.beta || a.can_everywhere) ?
            '<div style="margin-top:10px;">' +
            '<button class="action-btn" style="background:var(--accent-purple,#c084fc);color:#12081f;" onclick="saasOpenRelay()" title="Open on your phone/tablet to pair with this machine">'+
            '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">smartphone</span> Everywhere — pair a device</button>' +
            '<button class="action-btn" style="margin-left:6px;" onclick="saasRelayAuthorise()" title="Let this machine\'s relay poller sign in to Cockpit without storing your password"><span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">key</span> Authorise this machine</button>' +
            '<div style="margin-top:6px;display:flex;gap:6px;align-items:center;">' +
            '<label style="font-size:10.5px;color:var(--text-muted);">This machine is called</label>' +
            '<input id="machine-name" placeholder="the study laptop" maxlength="40" ' +
            'style="flex:1;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);' +
            'border-radius:4px;padding:3px 6px;font-size:11px;">' +
            '<button class="action-btn" style="font-size:10px;padding:2px 8px;" onclick="machineNameSave()">Save</button></div>' +
            '<div id="relay-auth-note" style="margin-top:4px;font-size:10.5px;color:var(--text-dim);">The relay starts with Cockpit, but it can only answer once this machine is authorised. Then open the pairing link on your phone.</div>' +
            '</div>'
            : '') +
        '<div style="margin-top:6px;font-size:11px;color:var(--text-dim);">'+_esc(a.email||'')+' · '+_esc(a.license_masked||'')+'</div>' +
        (a.recovered_at ? '<div style="margin-top:3px;font-size:10.5px;color:var(--text-dim);"><span class="material-symbols-rounded ico">recycling</span> Recovered last at: '+_esc(_fmtRecovered(a.recovered_at))+'</div>' : '') +
        '<div style="margin-top:10px;display:flex;gap:8px;flex-wrap:wrap;align-items:center;">' +
            '<button class="action-btn" style="background:var(--gemini);color:#fff;" data-help="marketplace" onclick="saasMarketplaceOpen()"><span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">storefront</span> Marketplace</button>' +
        '</div>' +
        '<div style="margin-top:12px;display:flex;gap:8px;flex-wrap:wrap;">' +
            '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasPortalOpen()" title="Profile, machines, subscription"><span class="material-symbols-rounded ico">settings</span> Account portal</button>' +
            '<button class="action-btn" onclick="saasRefresh()">Refresh</button>' +
            '<button class="action-btn" onclick="saasChangeAccountPassword()" title="Change your account (and admin) password"><span class="material-symbols-rounded ico">key</span> Password</button>' +
            '<button class="action-btn" onclick="saasChangeUser()" title="Switch to another account on this machine">⇄ Change user</button>' +
            '<button class="action-btn" onclick="saasRecoveryToken()" title="Your recovery token restores this account on a new machine after an OS reinstall. Show its state, or mint a new one (the old one stops working)."><span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">vpn_key</span> Recovery token</button>' +
            '<button class="action-btn" onclick="saasShowRecover()" title="Enter a recovery token to restore your real account/tier on this machine (safe — a wrong token changes nothing)"><span class="material-symbols-rounded ico">recycling</span> Recover with token</button>' +
            '<button class="action-btn" onclick="saasSignout()">Sign out</button></div>' +
        (a.is_admin ? '<div style="margin-top:8px;"><button class="action-btn" onclick="saasAdminPanelOpen()" style="border-color:var(--warn);color:var(--warn);"><span class="material-symbols-rounded ico">build</span> Admin panel</button></div>' : '');
}
// Admin panel launcher — opens moderation.php in a LOCAL browser window (same
// mechanism as the toolbar's  Browser button, via launch_cli.php on this
// machine), instead of a plain <a target=_blank> tab from inside the app.
// Asks once for the admin token (remembered in localStorage on THIS machine
// only) and passes it as ?token= so moderation.php auto-logs the session in —
// same trust level as pasting it into the page's own token field, one click
// fewer. Directory-Privacy (the browser's native Basic-Auth popup, if cPanel
// has it set) still applies first and can't be skipped from here — that's a
// separate credential this doesn't touch.
const ADMIN_PANEL_URL = 'https://cockpit.ruggi.site/admin/moderation.php';
function saasAdminPanelOpen() {
    document.getElementById('admin-launch-ov')?.remove();
    const saved = localStorage.getItem('cockpit_admin_token') || '';
    const ov = document.createElement('div'); ov.id = 'admin-launch-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100003;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(380px,92vw);padding:18px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:6px;"><h2 style="margin:0;font-size:14px;flex:1;">Cockpit Admin Login</h2>' +
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'admin-launch-ov\').remove()">×</span></div>' +
        '<div style="font-size:11.5px;color:var(--text-dim);margin-bottom:10px;">Opens the admin panel in a local browser window. Paste the admin token (optional — you can also log in with an admin account on the page itself), remembered on this machine only.</div>' +
        '<input id="admin-launch-token" type="password" placeholder="Admin token (optional)" value="'+escapeHtml(saved)+'" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:7px 9px;font-size:12px;border-radius:4px;font-family:var(--font-mono);">' +
        '<div id="admin-launch-err" style="font-size:11px;color:var(--text-dim);min-height:14px;margin-top:6px;"></div>' + bwFillBtn('admin_token', '', 'admin-launch-token', 'admin-launch-err') +
        '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px;"><button class="action-btn" onclick="document.getElementById(\'admin-launch-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasAdminPanelLaunch()">Launch</button></div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}
async function saasAdminPanelLaunch() {
    const tok = (document.getElementById('admin-launch-token')?.value || '').trim();
    if (tok) localStorage.setItem('cockpit_admin_token', tok); else localStorage.removeItem('cockpit_admin_token');
    const url = tok ? (ADMIN_PANEL_URL + '?token=' + encodeURIComponent(tok)) : ADMIN_PANEL_URL;
    document.getElementById('admin-launch-ov')?.remove();
    try {
        const r = await (await fetch('launch_cli.php', {method:'POST',headers:{'Content-Type':'application/json'},
            body: JSON.stringify({agent:'browser', mode:'browser', url})})).json();
        if (!r.ok) appendSystem(T('msg.admin.panel.launch.failed.error', 'Admin panel launch failed: {error}', {error: (r.error || 'unknown')}));
    } catch(e) { appendSystem(T('msg.admin.panel.launch.error.message', 'Admin panel launch error: {message}', {message: e.message})); }
}
async function saasAccountOpen(gateMode) {
    if (!saasEnabled()) return;   // v1/demo: no account UI (defense in depth; trigger is hidden too)
    const r = await saasApi('status');
    if (r && r.account && _saasAcct) r.account.is_admin = !!_saasAcct.is_admin;
    document.getElementById('saas-acct-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'saas-acct-ov';
    if (gateMode) ov.dataset.gate = '1';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const closeBtn = gateMode ? '' :
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'saas-acct-ov\').remove()">×</span>';
    // The local logins (the Users button used to sit in the account card, making it a row taller than the others)
    const usersBtn = gateMode ? '' :
        '<div style="margin-top:12px;padding-top:10px;border-top:1px solid var(--border-dim);display:flex;align-items:center;gap:8px;">' +
        '<button class="action-btn" onclick="document.getElementById(\'saas-acct-ov\').remove();cockpitUserManager()" title="Manage local users (accounts on this machine), change your password, sign out" style="display:inline-flex;align-items:center;gap:4px;padding:3px 10px;font-size:11px;"><span class="material-symbols-rounded" style="font-size:14px;">group</span>Local users</button>' +
        '<span style="font-size:10px;color:var(--text-muted);">accounts on this machine, your password, sign out</span></div>';
    const gateNote = gateMode ?
        '<div style="font-size:12px;color:var(--text-dim);margin-bottom:12px;">A free account is required once, at first run — no card, ever. Everything local stays free forever; this just registers the install.</div>' : '';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(420px,92vw);padding:20px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="height:3px;margin:-20px -20px 16px;border-radius:8px 8px 0 0;background:linear-gradient(90deg,var(--claude),var(--gemini),var(--ollama));"></div>' +
        '<div style="display:flex;align-items:center;margin-bottom:12px;"><h2 style="margin:0;font-size:15px;flex:1;">Cockpit Account</h2>' + closeBtn + '</div>' +
        gateNote +
        '<div id="saas-acct-body">'+ (r&&r.ok ? _saasView(r.account, r.binary_present, gateMode) : '<div style="color:var(--warn);">Account service unavailable.</div>') +'</div>' + usersBtn + '</div>';
    document.body.appendChild(ov);
    // Fill in what this machine is currently called (set name, else hostname).
    if (typeof machineNameLoad === 'function') machineNameLoad();
    if (!gateMode) ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}

// ── Account Portal — self-service: profile, machines, credits, subscription ──
function saasPortalOpen(tab) {
    tab = tab || 'profile';
    document.getElementById('saas-portal-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'saas-portal-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100002;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const tabBtn = (id, label) => '<button class="action-btn" data-ptab="' + id + '" onclick="saasPortalTab(\'' + id + '\')">' + label + '</button>';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(560px,94vw);max-height:88vh;display:flex;flex-direction:column;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="height:3px;border-radius:8px 8px 0 0;background:linear-gradient(90deg,var(--claude),var(--gemini),var(--ollama));"></div>' +
        '<div style="display:flex;align-items:center;gap:8px;padding:12px 16px;border-bottom:1px solid var(--border-dim);"><h2 style="margin:0;font-size:15px;flex:1;">Account Portal</h2><span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'saas-portal-ov\').remove()">×</span></div>' +
        '<div style="display:flex;gap:6px;padding:10px 16px;border-bottom:1px solid var(--border-dim);flex-wrap:wrap;">' +
        tabBtn('profile', 'Profile') + tabBtn('machines', 'Machines') + tabBtn('subscription', 'Subscription') + ((_saasAcct && _saasAcct.tier === 'family') ? tabBtn('family', 'Family') : '') + '</div>' +
        '<div id="saas-portal-body" style="padding:16px;overflow:auto;">Loading…</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    saasPortalTab(tab);
}
function saasPortalTab(tab) {
    document.querySelectorAll('#saas-portal-ov [data-ptab]').forEach(b =>
        b.style.cssText = (b.dataset.ptab === tab) ? 'background:var(--accent-blue);color:#fff;' : '');
    const body = document.getElementById('saas-portal-body'); if (!body) return;
    body.innerHTML = '<span style="color:var(--text-dim);font-size:12px;">Loading…</span>';
    ({ profile: saasPortalProfile, machines: saasPortalMachines, subscription: saasPortalSubscription, family: saasPortalFamily }[tab] || saasPortalProfile)(body);
}
async function saasPortalProfile(body) {
    const r = await saasApi('account_profile');
    if (!r || !r.ok) { body.innerHTML = '<span style="color:var(--warn);">' + _saasErr(r) + '</span>'; return; }
    const p = r.profile || {};
    const row = (k, v) => '<div style="display:flex;padding:5px 0;border-bottom:1px solid var(--border-dim);"><span style="width:120px;color:var(--text-muted);font-size:12px;">' + k + '</span><span style="flex:1;font-size:12.5px;">' + escHtml(v || '—') + '</span></div>';
    body.innerHTML = row('Name', ((p.first_name || '') + ' ' + (p.last_name || '')).trim()) + row('Username', p.username) + row('Nickname', p.nickname) +
        row('Email', (p.email || '') + (p.email_verified ? ' <span class="material-symbols-rounded ico">check</span>' : ' (unverified)')) + row('Location', ((p.city || '') + (p.country ? ', ' + p.country : '')).replace(/^, /, '')) +
        row('Tier', (r.tier || '').toUpperCase() + ' · ' + (r.cadence || '')) + row('Expires', r.expires_at || 'never') + row('Member since', (p.created_at || '').slice(0, 10));
}
async function saasPortalMachines(body) {
    const r = await saasApi('account_machines');
    if (!r || !r.ok) { body.innerHTML = '<span style="color:var(--warn);">' + _saasErr(r) + '</span>'; return; }
    const ms = r.machines || [];
    let h = '<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;">' + ms.length + ' of ' + r.max + ' machine slots used.</div>';
    h += ms.map(m => '<div style="display:flex;align-items:center;gap:8px;padding:7px 0;border-bottom:1px solid var(--border-dim);">' +
        '<div style="flex:1;"><b style="font-size:12.5px;">' + escHtml(m.machine_name || m.machine_id) + '</b>' + (m.current ? ' <span style="font-size:9px;color:var(--gemini);">(this machine)</span>' : '') +
        '<div style="font-size:10px;color:var(--text-muted);">last seen ' + (m.last_seen || '').slice(0, 16) + '</div></div>' +
        (m.current ? '' : '<button class="action-btn" style="font-size:10px;" onclick="saasPortalDeregister(\'' + escAttr(m.machine_id) + '\')">Remove</button>') + '</div>').join('');
    body.innerHTML = h;
}
// ── Family seats: up to five people (you included) share one Family plan. An invitation is taken when the person signs in with that e-mail
// address VERIFIED, so an address that is not theirs cannot take a seat.
async function saasPortalFamily(body) {
    const r = await saasApi('family', { op: 'seats' });
    if (!r || !r.ok) { body.innerHTML = '<span style="color:var(--warn);">' + _saasErr(r) + '</span>'; return; }
    const seats = r.seats || [], cap = r.capacity || 5;
    const used = seats.filter(s => s.status !== 'removed').length;
    let h = '<div style="font-size:12px;color:var(--text-muted);margin-bottom:8px;">' + used + ' of ' + cap + ' seats used (you are one of them). Invite someone by e-mail: they take their seat when they sign in with that address, verified.</div>';
    h += seats.map(s => '<div style="display:flex;align-items:center;gap:8px;padding:7px 0;border-bottom:1px solid var(--border-dim);">' +
        '<div style="flex:1;"><b style="font-size:12.5px;">' + escHtml(s.email || '(you)') + '</b> <span style="font-size:10px;color:var(--text-muted);">' + escHtml(s.role === 'owner' ? 'owner' : (s.status === 'active' ? 'member' : 'invited, not signed in yet')) + '</span></div>' +
        (s.role === 'owner' ? '' : '<button class="action-btn" style="font-size:10px;" onclick="saasFamilyRemove(' + (parseInt(s.id, 10) || 0) + ')">Remove</button>') + '</div>').join('');
    h += '<div style="display:flex;gap:6px;margin-top:12px;"><input id="fam-email" type="email" placeholder="name@example.com" style="flex:1;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;font-size:12px;border-radius:4px;" onkeydown="if(event.key===\'Enter\'){saasFamilyInvite();return false;}">' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" ' + (used >= cap ? 'disabled title="All seats are taken"' : '') + ' onclick="saasFamilyInvite()">Invite</button></div>' +
        '<div id="fam-msg" style="font-size:11px;min-height:14px;margin-top:6px;color:var(--warn);">' + (used >= cap ? 'All seats are taken: remove someone to invite another person.' : '') + '</div>';
    body.innerHTML = h;
}
async function saasFamilyInvite() {
    const em = (document.getElementById('fam-email') || {}).value || '';
    const msg = document.getElementById('fam-msg');
    if (!em.trim()) { if (msg) msg.textContent = T('msg.type.the.e.mail.address.first', 'Type the e-mail address first.'); return; }
    if (msg) msg.textContent = T('msg.inviting', 'Inviting…');
    const r = await saasApi('family', { op: 'invite', email: em.trim() });
    if (r && r.ok) { appendSystem(T('msg.family.invited', 'Invitation recorded for {e}. They take the seat when they sign in with that address.', { e: em.trim() })); saasPortalTab('family'); }
    else if (msg) msg.textContent = 'Could not invite: ' + _saasErr(r);
}
async function saasFamilyRemove(id) {
    if (typeof cockpitConfirm === 'function' && !(await cockpitConfirm('Remove this seat?', 'The person loses the Family features on their next sign-in.', 'Remove', { danger: true, icon: 'person_remove' }))) return;
    const r = await saasApi('family', { op: 'remove', seat_id: id });
    if (r && r.ok) saasPortalTab('family'); else appendSystem(T('msg.remove.failed.saaserr', 'Remove failed: {saaserr}', {saaserr: _saasErr(r)}));
}
async function saasPortalDeregister(id) {
    if (typeof cockpitConfirm === 'function' && !(await cockpitConfirm('Remove this machine? It will need to re-register on next use.'))) return;
    const r = await saasApi('account_deregister', { target: id });
    if (r && r.ok) { appendSystem(T('msg.machine.removed', 'Machine removed.')); saasPortalTab('machines'); }
    else appendSystem(T('msg.remove.failed.saaserr', 'Remove failed: {saaserr}', {saaserr: _saasErr(r)}));
}
async function saasPortalSubscription(body) {
    const r = await saasApi('account_renewal');
    if (!r || !r.ok) { body.innerHTML = '<span style="color:var(--warn);">' + _saasErr(r) + '</span>'; return; }
    const fmt = c => '$' + ((c || 0) / 100).toFixed(2);
    let h = '<div style="font-size:12.5px;">Tier: <b>' + (r.tier || '').toUpperCase() + '</b> · ' + (r.cadence || '') + '</div>' +
        '<div style="font-size:12px;color:var(--text-muted);margin:4px 0;">Next renewal: ' + fmt(r.next_amount_cents) + (r.expires_at ? (' on ' + r.expires_at.slice(0, 10)) : '') + '</div>';
    h += '<div style="margin-top:12px;padding-top:10px;border-top:1px solid var(--border-dim);font-size:11px;color:var(--text-muted);">To change plan or cancel, manage your subscription at the billing provider.</div>';
    body.innerHTML = h;
}

async function saasDoLogin() {
    const username = document.getElementById('saas-user')?.value.trim() || '';
    const password = document.getElementById('saas-pass')?.value || '';
    const err = document.getElementById('saas-err');
    if (!username || !password) { if(err) err.textContent = T('msg.enter.username.and.password.1241', 'Enter username and password.'); return; }
    if (err) err.textContent = T('msg.logging.in', 'Logging in…');
    const r = await saasApi('login', { username, password });
    if (r && r.ok) {
        document.getElementById('saas-acct-ov')?.remove();
        // first-run (no local login yet): the auth gate takes over — local login = this account name
        if (window._firstRunAccountStep) { document.dispatchEvent(new CustomEvent('cockpit-saas-signed-in', { detail: { username } })); return; }
        await saasAccountLoad(); saasAccountOpen();
    }
    else if (err) err.textContent = 'Login failed: ' + _saasErr(r);
}
// Weak-password rule shared by sign-up and Change password (the account server applies the same one).
function _saasPwWeak(pw, user) {
    if (pw.length < 8) return 'short';
    const low = pw.toLowerCase();
    if (/^(.)\1+$/.test(pw) || /^\d+$/.test(pw)) return 'easy';
    if (['password','passw0rd','qwertyui','qwertyuiop','letmein1','iloveyou','abcdefgh','admin123','welcome1','cockpit1'].some(w => low.indexOf(w) === 0)) return 'easy';
    return '';
}
// The phone/tablet page of the account server THIS install is set up for (the live site on a normal install, the stand-in in a test).
function saasOpenRelay() {
    const base = (_saasAcct && _saasAcct.account_url) ? _saasAcct.account_url.replace(/account\.php$/, '') : 'https://cockpit.ruggi.site/';
    window.open(base + 'relay.html', '_blank');
}
// Friendly text for a server status code.
function _saasErr(r) {
    const m = { invalid_credentials:'wrong username or password', username_taken:'username already taken',
        email_taken:'email already registered', bad_username:'username: 3–40 letters/numbers/_',
        weak_password:'password too short or too easy to guess (min 8)', bad_email:'invalid email', city_required:'city is required',
        country_required:'country is required', terms_required:'please accept the terms', bad_nickname:'nickname required',
        bad_first_name:'first name required', bad_last_name:'last name required',
        wrong_password:'current password is incorrect', not_family:'only the person who bought the Family plan can manage its seats', seats_full:'all five seats are taken', already_invited:'that address already has a seat or an invitation', inactive:'the Family plan is not active', bad_email:'that does not look like an e-mail address', captcha_failed:'human verification failed — try again',
        missing_fields:'please fill all fields', 'not signed in':'not signed in',
        recovery_not_available:'this account server has not enabled recovery tokens yet (migration pending)',
        no_match:'username, email, or recovery token did not match', rate_limited:'too many attempts — wait an hour and retry',
        no_license:'no license found for this account', suspended:'this account is suspended — contact support',
        'recover failed':'recovery failed' };
    const e = r && (r.error || r.status) ? (r.error || r.status) : 'unknown';
    return m[e] || e;
}
let _turnstileSite = null;   // cached site key ('' = not configured)
function _loadTurnstile() {
    if (document.getElementById('cf-turnstile-js')) return;
    const s = document.createElement('script');
    s.id = 'cf-turnstile-js';
    s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js';
    s.async = true; s.defer = true;
    document.head.appendChild(s);
}
async function saasShowRegister() {
    const body = document.getElementById('saas-acct-body'); if (!body) return;
    if (_turnstileSite === null) {
        try { const c = await saasApi('pubconfig'); _turnstileSite = (c && c.turnstile_site_key) || ''; }
        catch(e) { _turnstileSite = ''; }
    }
    const widget = _turnstileSite
        ? '<div class="cf-turnstile" id="cf-turnstile" data-sitekey="'+escapeHtml(_turnstileSite)+'" data-theme="dark" style="margin-top:4px;"></div>'
        : '';
    body.innerHTML = '<div style="font-size:12.5px;color:var(--text-dim);margin-bottom:8px;">Create your AI Cockpit account (Saas). Free, no card.</div>' +
        '<div style="display:flex;flex-direction:column;gap:7px;">' +
        '<div style="display:flex;gap:7px;">'+_saasInput('rg-first','First name')+_saasInput('rg-last','Surname')+'</div>' +
        _saasInput('rg-user','Username (Saas)') +
        _saasInput('rg-nick','Nickname (shown to others, in chat)') +
        _saasInput('rg-pass','Password (Saas, min 8)','password') +
        _saasInput('rg-email','Email (you\'ll get a verification link)','email') +
        '<div style="display:flex;gap:7px;">'+_saasInput('rg-country','Country (e.g. IL)')+_saasInput('rg-city','City')+'</div>' +
        '<label style="font-size:11px;color:var(--text-dim);display:flex;align-items:center;gap:6px;margin-top:2px;"><input type="checkbox" id="rg-terms"> I accept the terms &amp; the marketplace uploader agreement.</label>' +
        widget +
        '<div id="saas-err" style="font-size:11px;color:var(--warn);min-height:14px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="saasAccountOpen()">Back</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasDoRegister()">Create account (Saas)</button></div>' +
        '<div style="text-align:center;margin-top:6px;"><a href="#" onclick="saasShowRecover(document.getElementById(\'rg-user\')?.value||\'\',document.getElementById(\'rg-email\')?.value||\'\');return false;" style="font-size:11px;color:var(--accent-blue);">Reinstalled or new machine? Recover an existing account →</a></div></div>';
    if (_turnstileSite) {
        _loadTurnstile();
        // explicit render once the script is ready (auto-render also works)
        const tryRender = () => { if (window.turnstile) { try { window.turnstile.render('#cf-turnstile', {sitekey:_turnstileSite, theme:'dark'}); } catch(e){} } else setTimeout(tryRender, 200); };
        setTimeout(tryRender, 300);
    }
}
async function saasDoRegister() {
    const v = id => (document.getElementById(id)?.value || '').trim();
    const err = document.getElementById('saas-err');
    const payload = {
        first_name:v('rg-first'), last_name:v('rg-last'), username:v('rg-user'),
        nickname:v('rg-nick'), password:document.getElementById('rg-pass')?.value || '',
        email:v('rg-email'), country:v('rg-country').toUpperCase(), city:v('rg-city'),
        accept_terms: !!document.getElementById('rg-terms')?.checked,
    };
    if (!payload.accept_terms) { err.textContent = T('msg.please.accept.the.terms', 'Please accept the terms.'); return; }
    if (_saasPwWeak(payload.password, payload.username)) { err.textContent = T('msg.password.too.easy', 'Choose a stronger password: at least 8 characters, not only digits or one repeated letter and not a common password.'); return; }
    if (window._saasRegBusy) return;   // one submit at a time
    window._saasRegBusy = true;
    const _regBtn = document.querySelector('#saas-acct-body button[onclick="saasDoRegister()"]'); if (_regBtn) _regBtn.disabled = true;
    try { await _saasDoRegisterGo(payload, err); } finally { window._saasRegBusy = false; if (_regBtn) _regBtn.disabled = false; }
}
async function _saasDoRegisterGo(payload, err) {
    // Human verification (Turnstile) — required only when configured.
    if (_turnstileSite) {
        let tok = '';
        try { tok = window.turnstile ? window.turnstile.getResponse() : ''; } catch(e) {}
        if (!tok) { const inp = document.querySelector('[name="cf-turnstile-response"]'); tok = inp ? inp.value : ''; }
        if (!tok) { err.textContent = T('msg.please.complete.the.human.verification', 'Please complete the human verification.'); return; }
        payload.captcha_token = tok;
    }
    // Returning-user check: if an account with THIS username+email already
    // exists, this is almost certainly a reinstall on a new machine — steer to
    // recovery instead of creating a duplicate (which would fail on the UNIQUE
    // constraint anyway, but with a confusing "taken" error).
    err.textContent = T('msg.checking', 'Checking…');
    const ex = await saasApi('account_exists', { username: payload.username, email: payload.email });
    if (ex && ex.ok && ex.exists) {
        saasShowRecover(payload.username, payload.email, !!ex.has_recovery);
        return;
    }
    err.textContent = T('msg.creating.account', 'Creating account…');
    const r = await saasApi('register', payload);
    if (r && r.ok) {
        // Reveal the recovery token ONCE before closing — the only time it's
        // ever shown. Account refresh happens after the user confirms they saved.
        const done = () => {
            document.getElementById('saas-acct-ov')?.remove();
            appendSystem(T('msg.account.createdverifysent', 'Account created{verifysent}', {verifysent: (r.verify_sent ? ' — check your email to verify.' : ' (verification email could not be sent; verify later).')}));
            if (window._firstRunAccountStep) { document.dispatchEvent(new CustomEvent('cockpit-saas-signed-in', { detail: { username: payload.username } })); return; }
            saasAccountLoad(); saasAccountOpen();
        };
        if (r.recovery_token) saasRevealRecovery(r.recovery_token, done);
        else done();
    } else {
        // Turnstile tokens are single-use and expire: after any failure the widget
        // must be reset or every retry fails with "timeout-or-duplicate".
        const codes = (r && r.captcha_codes || []).join(', ');
        err.textContent = 'Sign-up failed: ' + _saasErr(r) + (codes ? ' (' + codes + ')' : '');
        if (r && r.error === 'captcha_failed') { try { window.turnstile && window.turnstile.reset(); } catch (e) {} }
    }
}

// ── Recovery: restore a paid account on a reinstalled machine ────────────────
// Opened either from saasDoRegister (returning user detected) or the "Reinstalled?"
// link on the register/sign-in screens.
function saasShowRecover(prefillUser, prefillEmail, hasRecovery) {
    const body = document.getElementById('saas-acct-body'); if (!body) return;
    const noTok = (hasRecovery === false)
        ? '<div style="font-size:11px;color:var(--warn);margin-top:6px;">This account predates recovery tokens. Contact support to reset access.</div>'
        : '';
    body.innerHTML =
        '<div style="font-size:12.5px;color:var(--text-dim);margin-bottom:8px;">Restore an existing account on this machine. Enter the recovery token you saved when you first created it.</div>' +
        '<div style="display:flex;flex-direction:column;gap:7px;">' +
        _saasInput('rc-user','Username (Saas)') +
        _saasInput('rc-email','Email','email') +
        _saasInput('rc-token','Recovery token (CRT-XXXX-XXXX-XXXX-XXXX-XXXX)') +
        noTok +
        '<div id="saas-err" style="font-size:11px;color:var(--warn);min-height:14px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="saasAccountOpen()">Back</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasDoRecover()">Recover account</button></div></div>';
    if (prefillUser)  { const el = document.getElementById('rc-user');  if (el) el.value = prefillUser; }
    if (prefillEmail) { const el = document.getElementById('rc-email'); if (el) el.value = prefillEmail; }
}
async function saasDoRecover() {
    const v = id => (document.getElementById(id)?.value || '').trim();
    const err = document.getElementById('saas-err');
    const payload = { username:v('rc-user'), email:v('rc-email'), recovery_token:v('rc-token') };
    if (!payload.username || !payload.email || !payload.recovery_token) { err.textContent = T('msg.fill.username.email.and.recovery.token', 'Fill username, email, and recovery token.'); return; }
    err.textContent = T('msg.recovering', 'Recovering…');
    const r = await saasApi('account_recover', payload);
    if (r && r.ok) {
        document.getElementById('saas-acct-ov')?.remove();
        appendSystem(T('msg.account.recovered.this.machine.is.signed.in', 'Account recovered — this machine is signed in again.'));
        saasAccountLoad(); saasAccountOpen();
    } else err.textContent = 'Recovery failed: ' + _saasErr(r);
}

// One-time recovery-token reveal. Three steps: (1) show + copy, (2) confirm
// saved, (3) closed — after which it's gone forever (server keeps only a hash).
function saasRevealRecovery(token, afterFn) {
    const done = () => { document.getElementById('crt-reveal-ov')?.remove(); if (typeof afterFn === 'function') afterFn(); };
    let ov = document.getElementById('crt-reveal-ov'); if (ov) ov.remove();
    ov = document.createElement('div'); ov.id = 'crt-reveal-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100020;background:rgba(0,0,0,0.75);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const card = 'background:var(--bg-base);border:1px solid var(--border-mid);border-radius:10px;width:min(480px,92vw);padding:24px;box-shadow:0 8px 40px rgba(0,0,0,0.6);';
    const step1 = () => {
        ov.innerHTML = '<div style="'+card+'">' +
            '<h2 style="margin:0 0 8px;font-size:16px;color:var(--text-primary);">Save your recovery token</h2>' +
            '<p style="font-size:12.5px;line-height:1.55;color:var(--text-dim);margin:0 0 12px;">This is the <b>only</b> time it will be shown. If you reinstall your OS or lose this machine, this token restores your account and subscription. Store it somewhere safe — a password manager is ideal.</p>' +
            '<div style="display:flex;gap:8px;align-items:center;margin-bottom:14px;">' +
            '<code id="crt-value" style="flex:1;font-size:14px;letter-spacing:.5px;background:var(--bg-darker);border:1px solid var(--border-dim);padding:10px 12px;border-radius:6px;color:var(--gemini);user-select:all;">'+escapeHtml(token)+'</code>' +
            '<button class="action-btn" id="crt-copy" onclick="saasCopyRecovery()">Copy</button></div>' +
            '<div style="display:flex;justify-content:flex-end;">' +
            '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="_crtStep2()">I\'ve saved it →</button></div></div>';
    };
    window._crtStep2 = () => {
        ov.innerHTML = '<div style="'+card+'">' +
            '<h2 style="margin:0 0 8px;font-size:16px;color:var(--text-primary);">Are you sure it\'s saved?</h2>' +
            '<p style="font-size:12.5px;line-height:1.55;color:var(--text-dim);margin:0 0 16px;">The token cannot be shown again. Without it, recovering this account after a reinstall requires contacting support.</p>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
            '<button class="action-btn" onclick="_crtBack()">Show it again</button>' +
            '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="_crtDone()">Yes, it\'s saved</button></div></div>';
    };
    window._crtBack = step1;
    window._crtDone = done;
    step1();
    document.body.appendChild(ov);
}
async function saasCopyRecovery() {
    const el = document.getElementById('crt-value'); if (!el) return;
    const txt = el.textContent || '';
    try { await navigator.clipboard.writeText(txt); }
    catch(e) { try { const r = document.createRange(); r.selectNode(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); document.execCommand('copy'); s.removeAllRanges(); } catch(e2){} }
    const b = document.getElementById('crt-copy'); if (b) { b.textContent = T('msg.copied.a588', 'Copied'); setTimeout(()=>{ if(b) b.textContent=T('msg.copy', 'Copy'); }, 1500); }
}
// Multi-account: show the roster of accounts saved on this machine — switch
// between them with no re-login (license-key keyed), forget, or add a new one.
async function saasResendVerify(btn) {
    if (btn) { btn.disabled = true; btn.textContent = T('msg.sending', 'Sending…'); }
    const r = await saasApi('account_resend_verify');
    if (r && r.ok && r.already_verified) { appendSystem(T('msg.your.email.is.already.verified', 'Your email is already verified.')); saasAccountLoad(); }
    else if (r && r.ok && r.sent) appendSystem(T('msg.verification.link.re.sent.to.email.check.you', 'Verification link re-sent to {email}. Check your inbox.', {email: (r.email || 'your email')}));
    else if (r && r.ok) appendSystem(T('msg.could.not.send.the.email.right.now.try.again', 'Could not send the email right now — try again later.'));
    else appendSystem(T('msg.resend.failed.saaserr', 'Resend failed: {saaserr}', {saaserr: _saasErr(r)}));
    if (btn) { btn.disabled = false; btn.innerHTML = '<span class="material-symbols-rounded ico">warning</span> Verify email — resend link'; }
}
async function saasChangeUser() {
    const r = await saasApi('accounts_list');
    const accts = (r && r.ok && r.accounts) ? r.accounts : [];
    const body = document.getElementById('saas-acct-body'); if (!body) return;
    let h = '<div style="font-size:12.5px;color:var(--text-muted);margin-bottom:10px;">Accounts on this machine — switch with one click, no password needed.</div>';
    if (!accts.length) {
        h += '<div style="font-size:12px;color:var(--text-muted);margin-bottom:10px;">No saved accounts yet.</div>';
    } else {
        h += accts.map(a => '<div style="display:flex;align-items:center;gap:8px;padding:8px 0;border-bottom:1px solid var(--border-dim);">' +
            '<div style="flex:1;"><b style="font-size:12.5px;">' + escHtml(a.nickname || a.email || a.license_masked) + '</b>' +
            (a.active ? ' <span style="font-size:9px;color:var(--gemini);">(active)</span>' : '') +
            '<div style="font-size:10px;color:var(--text-muted);">' + escHtml(a.email) + ' · ' + (a.tier || '').toUpperCase() + ' · ' + escHtml(a.license_masked) + '</div></div>' +
            (a.active ? '' : '<button class="action-btn" style="font-size:10px;background:var(--accent-blue);color:#fff;" onclick="saasSwitchAccount(\'' + escAttr(a.license_key) + '\')">Switch</button>') +
            '<button class="action-btn" style="font-size:10px;" onclick="saasForgetAccount(\'' + escAttr(a.license_key) + '\')" title="Remove from this machine">Forget</button></div>').join('');
    }
    h += '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px;">' +
        '<button class="action-btn" onclick="saasAccountOpen()">Back</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasAddAccount()">+ Add account</button></div>';
    body.innerHTML = h;
}
async function saasSwitchAccount(key) {
    const r = await saasApi('account_switch', { license_key: key });
    if (r && r.ok) {
        _saasAcct = r.account;
        document.getElementById('saas-acct-ov')?.remove();
        saasAccountLoad();
        appendSystem(T('msg.switched.account.nickname', 'Switched account → {nickname}.', {nickname: (r.account.nickname || r.account.email || 'account')}));
    } else appendSystem(T('msg.switch.failed.saaserr', 'Switch failed: {saaserr}', {saaserr: _saasErr(r)}));
}
async function saasForgetAccount(key) {
    if (typeof cockpitConfirm === 'function' && !(await cockpitConfirm('Forget this account on this machine? (Your subscription is unaffected; you can log in again anytime.)'))) return;
    await saasApi('account_forget', { license_key: key });
    _saasAcct = null; saasAccountLoad();
    saasChangeUser();
}
// Add a new account = sign out of the active one, then show the login form.
async function saasAddAccount() {
    await saasApi('signout');
    _saasAcct = null; saasAccountLoad();
    document.getElementById('saas-acct-ov')?.remove();
    saasAccountOpen();
}
function saasChangeAccountPassword() {
    const body = document.getElementById('saas-acct-body'); if (!body) return;
    body.innerHTML = '<div style="font-size:12.5px;color:var(--text-dim);margin-bottom:8px;">Change your account password (also your admin password if you are an admin).</div>' +
        '<div style="display:flex;flex-direction:column;gap:7px;">' +
        _saasInput('cp-cur','Current password','password') +
        _saasInput('cp-new','New password (min 8)','password') +
        _saasInput('cp-confirm','Confirm new password','password') +
        '<div id="saas-err" style="font-size:11px;color:var(--warn);min-height:14px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
        '<button class="action-btn" onclick="saasAccountOpen()">Back</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasDoChangePassword()">Update password</button></div></div>';
}
async function saasDoChangePassword() {
    const cur = document.getElementById('cp-cur')?.value || '';
    const np  = document.getElementById('cp-new')?.value || '';
    const nc  = document.getElementById('cp-confirm')?.value || '';
    const err = document.getElementById('saas-err');
    if (!cur || !np) { err.textContent = T('msg.fill.all.fields', 'Fill all fields.'); return; }
    if (np.length < 8) { err.textContent = T('msg.new.password.too.short.min.8', 'New password too short (min 8).'); return; }
    if (_saasPwWeak(np, (_saasAcct && _saasAcct.username) || '')) { err.textContent = T('msg.password.too.easy', 'Choose a stronger password: at least 8 characters, not only digits or one repeated letter and not a common password.'); return; }
    if (np !== nc) { err.textContent = T('msg.new.passwords.do.not.match', 'New passwords do not match.'); return; }
    err.textContent = T('msg.updating', 'Updating…');
    const r = await saasApi('change_password', { current_password: cur, new_password: np });
    if (r && r.ok) { document.getElementById('saas-acct-ov')?.remove(); appendSystem(T('msg.account.password.updated', 'Account password updated.')); saasAccountLoad(); }
    else err.textContent = 'Failed: ' + _saasErr(r);
}
async function saasRefresh() {
    const r = await saasApi('refresh');
    if (!r || !r.account) return;
    // Fetch is_admin fresh here too (don't rely on the old cached value — that's
    // the bug this replaces: saasAccountLoad() below also re-fetches it, but
    // async/fire-and-forget, so the render right after would've used stale data).
    try { const pr = await saasApi('account_profile'); r.account.is_admin = !!(pr && pr.ok && pr.is_admin); } catch(e) { r.account.is_admin = !!(_saasAcct && _saasAcct.is_admin); }
    _saasAcct = r.account;
    document.getElementById('saas-acct-body').innerHTML = _saasView(r.account, true);
    saasAccountLoad();
}
async function saasSignout() { await saasApi('signout'); document.getElementById('saas-acct-ov')?.remove(); saasAccountLoad(); }

// Show the give-back credit balance in the account modal.

// Protanopia-safe compat badge (symbol + text; colour is only a hint).
function _compatBadge(c) {
    if (!c || !c.badge) return '';
    const b = c.badge;
    const styles = {
        ok:'background:rgba(125,196,163,.16);color:var(--accent-green,#7dc4a3);border-color:rgba(125,196,163,.5)',
        warn:'background:rgba(230,180,60,.16);color:#e6b43c;border-color:rgba(230,180,60,.5)',
        alt:'background:rgba(120,160,255,.16);color:#78a0ff;border-color:rgba(120,160,255,.5)',
        bad:'background:rgba(212,73,73,.16);color:var(--claude,#d44949);border-color:rgba(212,73,73,.5)',
        unknown:'background:rgba(150,150,150,.14);color:var(--text-muted);border-color:rgba(150,150,150,.4)'
    };
    const s = styles[b.cls] || styles.unknown;
    const tip = (c.reason||'') + (c.missing && c.missing.length ? (' — missing: '+c.missing.join(', ')) : '');
    return `<span title="${escapeHtml(tip)}" style="display:inline-flex;align-items:center;gap:3px;font-size:9px;font-weight:700;padding:1px 6px;border-radius:8px;border:1px solid;${s}">${b.symbol} ${escapeHtml(b.label)}</span>`;
}

// ── MARKETPLACE (Phase 6 client) ─────────────────────────────────────────────
async function saasMarketplaceOpen() {
    if (!saasRequireAccount('The Marketplace')) return;
    document.getElementById('saas-mkt-ov')?.remove();
    const ov = document.createElement('div'); ov.id = 'saas-mkt-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100001;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(700px,95vw);max-height:86vh;display:flex;flex-direction:column;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;gap:8px;padding:13px 16px;border-bottom:1px solid var(--border-dim);">' +
        '<span class="material-symbols-rounded" style="color:var(--gemini);">storefront</span><h2 style="margin:0;font-size:15px;flex:1;">Marketplace</h2>' +
        '<select id="mkt-kind" onchange="saasMarketRefresh()" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);font-size:11px;padding:4px;border-radius:4px;">' +
        '<option value="">All kinds</option><option value="skill">Skills</option><option value="capability">Capabilities</option><option value="tool">Tools</option><option value="tool_preset">Tool presets</option><option value="worker_card">Worker cards</option><option value="pipeline">Pipelines</option><option value="theme">Themes</option><option value="prompt">Prompts</option><option value="combo">Power Combos</option></select>' +
        '<label style="font-size:10px;color:var(--text-dim);display:flex;align-items:center;gap:4px;"><input type="checkbox" id="mkt-mine" onchange="saasMarketRefresh()"> mine</label>' +
        '<label style="font-size:10px;color:var(--text-dim);display:flex;align-items:center;gap:4px;" title="Everything you have downloaded before — re-download after a reinstall"><input type="checkbox" id="mkt-downloaded" onchange="saasMarketRefresh()"> my downloads</label>' +
        '<button class="action-btn" onclick="saasRestoreAllContent()" title="Re-download everything on your account (your downloads + your uploads) onto this machine — for after a reinstall" style="padding:4px 10px;">⤓ Restore all mine</button>' +
        '<button class="action-btn" onclick="saasMarketUploadOpen()" style="padding:4px 10px;background:var(--accent-blue);color:#fff;font-weight:700;">＋ Publish</button>' +
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'saas-mkt-ov\').remove()">×</span></div>' +
        '<div id="mkt-list" style="flex:1;overflow:auto;padding:8px 10px;font-size:12px;">Loading…</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    saasMarketRefresh();
}
async function saasMarketRefresh() {
    const list = document.getElementById('mkt-list'); if (!list) return;
    list.innerHTML = 'Loading…';
    const kind = document.getElementById('mkt-kind')?.value || '';
    const mine = document.getElementById('mkt-mine')?.checked ? 1 : 0;
    const dl   = document.getElementById('mkt-downloaded')?.checked ? 1 : 0;
    const r = await saasApi('content_list', { kind: kind || undefined, owner_only: mine, downloaded_only: dl });
    if (!r || !r.ok) { list.innerHTML = '<div style="color:var(--warn);padding:10px;">' + (r&&r.error?escapeHtml(r.error):'Failed to load') + '</div>'; return; }
    const items = r.items || [];
    if (!items.length) { list.innerHTML = '<div style="color:var(--text-dim);padding:14px;">No items.</div>'; return; }
    // Resolve compatibility for every item against THIS machine (Phase 5).
    let compat = [];
    try {
        const cc = await (await fetch('compat_check.php', {method:'POST',headers:{'Content-Type':'application/json'},
            body: JSON.stringify({items: items.map(it=>({requirements: it.requirements||{}, compatibility: it.compat||{}}))})})).json();
        if (cc.ok) compat = cc.compat || [];
    } catch(e) {}
    const canPaid = !!(_saasAcct && (_saasAcct.can_content || _saasAcct.beta));
    list.innerHTML = items.map((it,i) => {
        const badge = _compatBadge(compat[i]);
        const isCombo = it.kind === 'combo';
        const comboTier = (it.requirements && it.requirements.combo_tier) || 'base';
        const isPremiumCombo = isCombo && comboTier === 'premium';
        const earn = isCombo
            ? (isPremiumCombo ? '<span class="action-btn" style="padding:1px 6px;font-size:9px;border-color:var(--accent);color:var(--accent-2);">premium pack</span>' : '<span class="action-btn" style="padding:1px 6px;font-size:9px;border-color:var(--accent-green,#7dc4a3);color:var(--accent-green,#7dc4a3);">base pack</span>')
            : (it.earnable ? '<span class="action-btn" style="padding:1px 6px;font-size:9px;border-color:var(--accent-green,#7dc4a3);color:var(--accent-green,#7dc4a3);">community</span>' : '<span class="action-btn" style="padding:1px 6px;font-size:9px;border-color:var(--accent-green,#7dc4a3);color:var(--accent-green,#7dc4a3);">free</span>');
        const sz = (it.size_bytes/1024).toFixed(1) + 'K';
        const del = it.is_owner ? `<button class="action-btn" onclick="saasMarketDelete(${it.id})" style="padding:4px 8px;">Delete</button>` : '';
        // Marketplace is free for any registered account (2026-09-05: paid-content
        // model retired with the payouts) — nothing is paywall-locked. The server
        // (content/get.php) serves every kind free; the account must just be signed in.
        const locked = false;
        const dlDate = it.downloaded_at ? String(it.downloaded_at).slice(0,10) : '';
        const getLabel = it.is_downloaded ? '<span class="material-symbols-rounded ico">refresh</span> Re-download' : '<span class="material-symbols-rounded ico">download</span> Get';
        const getBtn = locked
            ? `<button class="action-btn" title="Subscribe to a Content plan to download paid items" onclick="appendSystem('“${escapeHtml(it.title)}” needs a Content plan — free accounts can download free items only.')" style="padding:5px 12px;opacity:.8;">[[icon:lock]] Content</button>`
            : `<button class="action-btn" style="background:var(--accent-blue);color:#fff;padding:5px 12px;" onclick="saasMarketDownload(${it.id})">${getLabel}</button>`;
        return `<div style="border:1px solid var(--border-dim);border-radius:6px;padding:8px 10px;margin-bottom:6px;display:flex;align-items:center;gap:8px;flex-wrap:wrap;">
          <div style="flex:1;min-width:170px;">
            <div style="font-weight:600;display:flex;align-items:center;gap:6px;flex-wrap:wrap;">${escapeHtml(it.title)} <span style="font-size:9px;color:var(--text-dim);text-transform:uppercase;">${escapeHtml(it.kind)}</span> ${earn} ${badge}</div>
            <div style="font-size:10px;color:var(--text-dim);">${escapeHtml((it.description||'').slice(0,120))}</div>
            <div style="font-size:9px;color:var(--text-muted);">${escapeHtml(it.origin_os)} · ${sz} · ${it.downloads} dl · ${it.usages||0} used${dlDate?` · <span style="color:var(--accent-green,#7dc4a3);"><span class="material-symbols-rounded ico">check</span> downloaded ${dlDate}</span>`:''}</div>
          </div>
          ${getBtn} ${del}
        </div>`;
    }).join('');
}
// Restore everything this account owns onto THIS machine after a reinstall:
// every item the user has downloaded before PLUS every item they published
// themselves. Re-downloads each (install is idempotent — already-present items
// are simply overwritten), so no local-presence check is needed.
async function saasRestoreAllContent() {
    if (!(_saasAcct && _saasAcct.signed_in)) { appendSystem(T('msg.sign.in.first.to.restore.your.content', 'Sign in first to restore your content.')); return; }
    appendSystem(T('msg.gathering.your.content.list', 'Gathering your content list…'));
    const seen = new Set(), items = [];
    for (const flag of [{ downloaded_only: 1 }, { owner_only: 1 }]) {
        const r = await saasApi('content_list', flag);
        if (r && r.ok) (r.items || []).forEach(it => { if (!seen.has(it.id)) { seen.add(it.id); items.push(it); } });
    }
    if (!items.length) { appendSystem(T('msg.nothing.to.restore.your.account.has.no.downl', 'Nothing to restore — your account has no downloads or uploads.')); return; }
    if (!await cconfirm(T('msg.restore.n.item.s.to.this.machine.this.re.dow', 'Restore {n} item(s) to this machine?\n\nThis re-downloads everything on your account — items you previously downloaded AND items you published. Already-present items are overwritten. This can take a while for large accounts.', {n: items.length}))) return;
    let ok = 0, fail = 0, i = 0;
    for (const it of items) {
        i++;
        appendSystem(T('msg.restoring.i.n.title', 'Restoring {i}/{n}: {title}…', {i: i, n: items.length, title: (it.title || it.id)}));
        try { await saasMarketDownload(it.id, true); ok++; } catch (e) { fail++; }
    }
    appendSystem(T('msg.restore.complete.ok.installedfail', 'Restore complete: {ok} installed{fail}.', {ok: ok, fail: (fail ? (', ' + fail + ' failed') : '')}));
    if (typeof saasMarketRefresh === 'function') saasMarketRefresh();
}
// Compare a combo's referenced models against a fresh `ollama list` (via
// combos.php?action=installed_models) and confirm with the user BEFORE
// downloading if any are missing — no auto-install, just an informed choice.
// Returns true to proceed, false if the user cancelled. No dialog at all
// when everything's already installed (no point interrupting the happy path).
async function comboConfirmModels(combo) {
    const needed = [];
    (combo.steps || []).forEach(s => { if (s.model) needed.push(s.model); });
    if (combo.judge && combo.judge.model) needed.push(combo.judge.model);
    if (!needed.length) return true;
    let installed = [];
    try { installed = ((await (await fetch('combos.php?action=installed_models')).json()).models || []); }
    catch (e) { return true; }   // can't check → don't block the download over it
    const have = new Set(installed.map(m => m.toLowerCase()));
    const missing = [...new Set(needed)].filter(m => !have.has(m.toLowerCase()));
    if (!missing.length) return true;
    return await cconfirm(
        T('msg.this.combo.needs.n.model.s.new.missing.on.th', 'This combo needs {n} model(s):\n  {new}\n\nMissing on this machine (run `ollama pull <name>` to get them):\n  {n2}\n\nYou can still download it — it\'ll just show as unavailable in Tier 0 until you pull the missing model(s). Continue?', {n: needed.length, new: [...new Set(needed)].join(', '), n2: missing.join(', ')})
    );
}
// quiet=true (bulk restore): skip per-item model-confirm dialogs, suppress
// success chatter, and never trigger a browser-download fallback. Returns true
// on successful install, false otherwise.
async function saasMarketDownload(id, quiet=false) {
    const say = m => { if (!quiet) appendSystem(m); };
    const r = await saasApi('content_get', { content_id: id });
    if (!r || !r.ok) { say('Download failed: ' + (r&&r.error?r.error:'?')); return false; }
    const it = r.item || {};
    // Combo Store: decrypt-at-rest merge into combos_<scope>.enc (combos_core.php
    // decrypts+merges at load) instead of the generic Skills/Tools install path.
    if (it.kind === 'combo') {
        let combo;
        try { combo = JSON.parse(atob(r.payload_b64 || '')); }
        catch(e) { say('Combo download failed: bad payload.'); return false; }
        if (!quiet && !(await comboConfirmModels(combo))) { appendSystem(T('msg.download.cancelled', 'Download cancelled.')); return false; }
        const scope = ((it.requirements && it.requirements.combo_tier) === 'premium') ? 'store' : 'base';
        try {
            const ins = await (await fetch('combos.php?action=install', {method:'POST',headers:{'Content-Type':'application/json'},
                body: JSON.stringify({ scope, merge: 1, combos: [combo] })})).json();
            if (ins && ins.ok) {
                say('Installed combo "' + (it.title||it.slug) + '" (' + scope + ' pack, ' + ins.count + ' total).');
                if (typeof combosRefresh === 'function') combosRefresh();
                return true;
            }
            say('Combo install failed: ' + (ins && ins.error ? ins.error : 'unknown'));
        } catch(e) { say('Combo install failed: ' + e.message); }
        return false;
    }
    if (it.kind === 'user_combo') {
        let combo;
        try { combo = JSON.parse(atob(r.payload_b64 || '')); }
        catch(e) { say('Combo download failed: bad payload.'); return false; }
        if (!quiet && !(await comboConfirmModels(combo))) { appendSystem(T('msg.download.cancelled', 'Download cancelled.')); return false; }
    }
    // Auto-install into the matching local store (Skills / Tools / Capabilities).
    try {
        const ins = await (await fetch('mkt_install.php', {method:'POST',headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ kind: it.kind, slug: it.slug, content_b64: r.payload_b64,
                                    content_id: it.id, author: it.owner_nickname })})).json();
        if (ins && ins.ok) {
            say('Installed "' + (it.title||it.slug) + '" → ' + ins.installed_to + '.');
            if (it.kind === 'skill' && typeof skillsLoad === 'function') skillsLoad(true);
            return true;
        }
        say('Install issue: ' + (ins && ins.error ? ins.error : 'unknown') + (quiet?'':' — saving the file instead.'));
    } catch(e) { say('Install failed (' + e.message + ')' + (quiet?'':' — saving the file instead.')); }
    if (quiet) return false;   // bulk restore: no 200 browser-download popups
    // Fallback: browser-download the raw object so the user can import manually.
    const bin = atob(r.payload_b64 || ''); const arr = new Uint8Array(bin.length);
    for (let i=0;i<bin.length;i++) arr[i] = bin.charCodeAt(i);
    const url = URL.createObjectURL(new Blob([arr]));
    const a = document.createElement('a'); a.href = url; a.download = (it.slug||'item') + '-' + (it.kind||''); a.click(); URL.revokeObjectURL(url);
    return false;
}
async function saasMarketDelete(id) {
    if (!await cockpitConfirm('Delete item', 'Remove this marketplace item? (soft-delete)', 'Delete', {danger:true})) return;
    const r = await saasApi('content_delete', { content_id: id });
    if (r && r.ok) saasMarketRefresh(); else appendSystem(T('msg.delete.failed.r', 'Delete failed: {r}', {r: (r&&r.error?r.error:'?')}));
}

// ── PUBLISH (upload) ─────────────────────────────────────────────────────────
let _mktUploadPath = null;   // chosen source file (server path)
async function saasMarketUploadOpen() {
    document.getElementById('mkt-up-ov')?.remove();
    // origin OS from this machine's platform profile (Phase 5).
    let os = 'linux';
    try { const cc = await (await fetch('compat_check.php',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'})).json(); if (cc.ok && cc.platform) os = cc.platform.os; } catch(e) {}
    _mktUploadPath = null;
    const ov = document.createElement('div'); ov.id = 'mkt-up-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100002;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    const fld = (l,h)=>'<label style="font-size:11px;color:var(--text-dim);display:block;margin-top:8px;">'+l+'</label>'+h;
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;width:min(460px,94vw);padding:18px;box-shadow:0 8px 40px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:6px;"><h2 style="margin:0;font-size:14px;flex:1;">Publish to Marketplace</h2>' +
        '<span style="cursor:pointer;color:var(--text-dim);font-size:18px;" onclick="document.getElementById(\'mkt-up-ov\').remove()">×</span></div>' +
        fld('Kind', '<select id="up-kind" onchange="saasMarketUploadKindChange()" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;border-radius:4px;font-size:12px;"><option value="skill">Skill</option><option value="capability">Capability</option><option value="tool">Tool</option><option value="tool_preset">Tool preset</option><option value="worker_card">Worker card</option><option value="pipeline">Pipeline</option><option value="theme">Theme</option><option value="prompt">Prompt</option><option value="user_combo">My Combo (earns credit)</option><option value="combo">Power Combo (admin only)</option></select>') +
        fld('Slug (lowercase id)', '<input id="up-slug" placeholder="my-cool-skill" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;border-radius:4px;font-size:12px;font-family:var(--font-mono);">') +
        fld('Title', '<input id="up-title" placeholder="My Cool Skill" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;border-radius:4px;font-size:12px;">') +
        fld('Description', '<input id="up-desc" placeholder="what it does" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;border-radius:4px;font-size:12px;">') +
        '<div id="up-bins-row">' + fld('Required binaries (comma-sep, optional)', '<input id="up-bins" placeholder="ffmpeg, pandoc" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px 8px;border-radius:4px;font-size:12px;font-family:var(--font-mono);">') + '</div>' +
        '<div id="up-combo-tier-row" style="display:none;">' + fld('Combo tier', '<select id="up-combo-tier" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;border-radius:4px;font-size:12px;"><option value="base">Base (free, register-unlock)</option><option value="premium">Premium (the extended set)</option></select>') + '</div>' +
        '<input type="hidden" id="up-os" value="'+escapeHtml(os)+'">' +
        '<div id="up-file-row">' + fld('File to publish', '<div style="display:flex;gap:6px;align-items:center;"><button class="action-btn" onclick="saasMarketPickFile()">Choose file…</button><span id="up-file" style="font-size:10px;color:var(--text-dim);">none</span></div>') + '</div>' +
        '<div id="up-combo-pick-row" style="display:none;">' + fld('Your combo', '<select id="up-combo-pick" onchange="saasMarketComboPick()" style="width:100%;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:6px;border-radius:4px;font-size:12px;"><option value="">— pick one —</option></select>') + '</div>' +
        '<div id="up-err" style="font-size:11px;color:var(--warn);min-height:14px;margin-top:8px;"></div>' +
        '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:10px;"><button class="action-btn" onclick="document.getElementById(\'mkt-up-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="saasMarketPublish()">Publish</button></div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}
let _mktUserCombos = [];
// Toggle the binaries/combo-tier/file-vs-combo-picker fields based on the chosen kind.
async function saasMarketUploadKindChange() {
    const kind = document.getElementById('up-kind')?.value;
    const isCombo = kind === 'combo';
    const isUserCombo = kind === 'user_combo';
    const bins = document.getElementById('up-bins-row'); if (bins) bins.style.display = isCombo ? 'none' : '';
    const tier = document.getElementById('up-combo-tier-row'); if (tier) tier.style.display = isCombo ? '' : 'none';
    const fileRow = document.getElementById('up-file-row'); if (fileRow) fileRow.style.display = isUserCombo ? 'none' : '';
    const pickRow = document.getElementById('up-combo-pick-row'); if (pickRow) pickRow.style.display = isUserCombo ? '' : 'none';
    if (isUserCombo) {
        const sel = document.getElementById('up-combo-pick');
        sel.innerHTML = '<option value="">Loading…</option>';
        try {
            const d = await (await fetch('combos.php?action=user_list')).json();
            _mktUserCombos = d.combos || [];
            sel.innerHTML = '<option value="">— pick one —</option>' +
                _mktUserCombos.map(c => '<option value="' + escAttr(c.id) + '">' + escHtml(c.name || c.id) + '</option>').join('');
        } catch (e) { sel.innerHTML = '<option value="">(failed to load)</option>'; }
    }
}
function saasMarketComboPick() {
    const id = document.getElementById('up-combo-pick').value;
    const c = _mktUserCombos.find(x => x.id === id);
    if (!c) return;
    document.getElementById('up-slug').value = c.id;
    document.getElementById('up-title').value = c.name || c.id;
    document.getElementById('up-desc').value = c.desc || '';
}
async function saasMarketPickFile() {
    const p = await cockpitPathPicker({ mode:'open', title:'Pick the object file to publish' });
    if (!p) return;
    _mktUploadPath = p;
    const el = document.getElementById('up-file'); if (el) el.textContent = p.split('/').pop();
}
async function saasMarketPublish() {
    const err = document.getElementById('up-err');
    const slug = (document.getElementById('up-slug').value||'').trim().toLowerCase();
    const title = (document.getElementById('up-title').value||'').trim();
    if (!/^[a-z0-9][a-z0-9._-]{0,159}$/.test(slug)) { err.textContent = T('msg.slug.lowercase.letters.numbers.only', 'Slug: lowercase letters/numbers/-/_ only.'); return; }
    if (!title) { err.textContent = T('msg.title.required', 'Title required.'); return; }
    const kind = document.getElementById('up-kind').value;
    const isCombo = kind === 'combo';
    const isUserCombo = kind === 'user_combo';
    let b64 = '';
    if (isUserCombo) {
        const picked = _mktUserCombos.find(c => c.id === document.getElementById('up-combo-pick').value);
        if (!picked) { err.textContent = T('msg.pick.one.of.your.combos', 'Pick one of your combos.'); return; }
        b64 = btoa(unescape(encodeURIComponent(JSON.stringify(picked))));
    } else {
        if (!_mktUploadPath) { err.textContent = T('msg.choose.a.file.to.publish', 'Choose a file to publish.'); return; }
        err.textContent = T('msg.reading.file', 'Reading file…');
        try {
            const rd = await (await fetch('browse.php?action=read', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({path:_mktUploadPath})})).json();
            if (!rd.ok) { err.textContent = 'Read failed: ' + (rd.error||'?'); return; }
            b64 = rd.b64 || rd.content_b64 || '';
        } catch(e) { err.textContent = 'Read error: ' + e.message; return; }
    }
    const bins = (document.getElementById('up-bins').value||'').split(',').map(s=>s.trim()).filter(Boolean);
    const reqs = isCombo ? { combo_tier: document.getElementById('up-combo-tier').value || 'base' }
                         : (bins.length ? { binaries: bins } : {});
    err.textContent = T('msg.publishing', 'Publishing…');
    const r = await saasApi('content_put', {
        kind, slug, title,
        description: (document.getElementById('up-desc').value||'').trim(),
        origin_os: document.getElementById('up-os').value || 'linux',
        requirements_json: reqs,
        compat_json: {},
        payload_b64: b64,
    });
    if (r && r.ok) {
        document.getElementById('mkt-up-ov').remove();
        appendSystem(T('msg.published.title.iscombo', 'Published "{title}" ({iscombo}).', {title: title, iscombo: (isCombo ? 'combo/' + reqs.combo_tier : (r.earnable?'earnable':'free'))}));
        if (isUserCombo) {
            // Tag the local combo with its Marketplace content_id — enables the
            // Unpublish button and future usage-credit reporting for OTHER
            // people who download it (this account's own runs never self-credit).
            const picked = _mktUserCombos.find(c => c.id === document.getElementById('up-combo-pick').value);
            if (picked) {
                picked._content_id = r.id;
                fetch('combos.php?action=user_save', {
                    method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({combo: picked}),
                });
            }
        }
        saasMarketRefresh();
        if (typeof combosRefresh === 'function') combosRefresh();
    }
    else if (r && r.status === 'admin_only') { err.textContent = T('msg.only.the.admin.account.can.publish.combos', 'Only the admin account can publish combos.'); }
    else if (r && r.status === 'upgrade_required') { err.textContent = T('msg.content.tier.subscription.required.to.publis', 'Publishing needs the Plus plan or higher.'); }
    else { err.textContent = 'Publish failed: ' + (r&&r.error?r.error:r&&r.status?r.status:'unknown'); }
}
// status chip on load + heartbeat every 300s when signed in
document.addEventListener('DOMContentLoaded', () => {
    // after the login gate, not 800 ms after DOM: before the session is confirmed saas.php answers 401 and
    // the tier chip / BETA badge stayed empty until the 10-minute re-poll (rig, build 64)
    const first = () => setTimeout(saasAccountLoad, 300);
    if (typeof authGateReady === 'function') authGateReady().then(first); else first();
    setInterval(() => { if (_saasAcct && _saasAcct.signed_in) saasApi('heartbeat'); }, 300000);
    // Pulsating entitlement check: re-validate the tier every 10 min so a lapsed/
    // downgraded subscription flips the gates (and their read-only degradation)
    // without a reload. saasAccountLoad() re-runs refresh + re-evals the hive UI.
    setInterval(() => { if (saasEnabled()) saasAccountLoad(); }, 600000); });

function cockpitChangePassword() {
    let ov = document.getElementById('chgpass-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'chgpass-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(360px,90vw);padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;">Change password</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#chgpass-overlay\').remove()">×</span></div>' +
        '<div style="display:flex;flex-direction:column;gap:10px;">' +
        _pwWrap('<input id="chgpass-cur" type="password" placeholder="Current password" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;width:100%;box-sizing:border-box;">', 'chgpass-cur') +
        _pwWrap('<input id="chgpass-new" type="password" placeholder="New password (min 6 chars)" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;width:100%;box-sizing:border-box;">', 'chgpass-new') +
        _pwWrap('<input id="chgpass-confirm" type="password" placeholder="Confirm new password" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;width:100%;box-sizing:border-box;">', 'chgpass-confirm') +
        '<div id="chgpass-err" style="font-size:11px;color:var(--accent-orange);min-height:16px;"></div>' +
        '<button style="padding:9px;font-size:12px;font-weight:600;border:none;border-radius:4px;cursor:pointer;background:var(--accent-blue);color:#fff;" onclick="cockpitChangePasswordSubmit()">Update password</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    document.getElementById('chgpass-cur').focus();
}

async function cockpitChangePasswordSubmit() {
    const cur = document.getElementById('chgpass-cur').value;
    const np = document.getElementById('chgpass-new').value;
    const nc = document.getElementById('chgpass-confirm').value;
    const err = document.getElementById('chgpass-err');
    if (!cur) { err.textContent = T('msg.enter.current.password', 'Enter current password'); return; }
    if (np.length < 6) { err.textContent = T('msg.new.password.must.be.at.least.6.characters', 'New password must be at least 6 characters'); return; }
    if (np !== nc) { err.textContent = T('msg.passwords.do.not.match', 'Passwords do not match'); return; }
    try {
        const r = await fetch('auth.php?action=change_password', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({current: cur, new_password: np}),
        });
        const d = await r.json();
        if (d.ok) {
            document.getElementById('chgpass-overlay').remove();
            appendSystem(T('msg.password.updated', 'Password updated.'));
        } else {
            err.textContent = d.error || 'Failed';
        }
    } catch(e) { err.textContent = 'Error: ' + e.message; }
}

// The local role is about THIS install's logins only (who may add or remove
// local logins here). It is not a cockpit.ruggi.site role: site admins are
// defined on the server alone. 'admin' in users.json reads as Owner here.
function _localRoleLabel(r) { return r === 'admin' ? 'Owner (this machine)' : r === 'viewer' ? 'Viewer (read-only)' : 'Normal'; }
async function cockpitUserManager() {
    if (window._cockpitRole !== 'admin') { appendSystem(T('msg.admin.access.required', 'Admin access required.')); return; }
    let ov = document.getElementById('usermgr-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'usermgr-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(480px,92vw);max-height:80vh;padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);overflow-y:auto;">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;">Local logins <span style="font-weight:400;opacity:.7;font-size:11px;">— this machine only; not cockpit.ruggi.site accounts</span></h2>' +
        // Change password / Sign out live here since 2026-09-13 (were two card buttons).
        '<button class="action-btn" onclick="document.getElementById(\'usermgr-overlay\').remove();cockpitChangePassword()" title="Change your password" style="padding:3px 9px;font-size:10.5px;margin-right:6px;"><span class="material-symbols-rounded" style="font-size:13px;vertical-align:-3px;">key</span> Password</button>' +
        '<button class="action-btn" onclick="cockpitLogout()" title="Sign out" style="padding:3px 9px;font-size:10.5px;margin-right:10px;"><span class="material-symbols-rounded" style="font-size:13px;vertical-align:-3px;">logout</span> Sign out</button>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="document.getElementById(\'usermgr-overlay\').remove()">×</span></div>' +
        ((window._saasMachine && window._saasMachine.first_login_ok === false) ? '<div style="margin:0 0 10px;padding:6px 8px;border:1px solid var(--warn,#e6b43c);border-radius:4px;font-size:11px;color:var(--warn,#e6b43c);">The first login on this machine should be your Cockpit account name (' + _esc(window._saasMachine.account_username || '') + '). It is not — sign-in and the Marketplace still work, but a reinstall will create the login under the account name.</div>' : '') +
        '<div id="usermgr-list" style="margin-bottom:16px;font-size:12px;">Loading...</div>' +
        '<div style="border-top:1px solid var(--border-dim);padding-top:14px;">' +
        '<div style="font-size:12px;font-weight:600;margin-bottom:8px;">Add new user</div>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<input id="usermgr-newuser" placeholder="Username" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;">' +
        _pwWrap('<input id="usermgr-newpass" type="password" placeholder="Password (min 6 chars)" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;width:100%;box-sizing:border-box;">', 'usermgr-newpass') +
        '<select id="usermgr-newrole" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;">' +
        '<option value="normal">Normal</option><option value="admin">Owner (this machine)</option><option value="viewer">Viewer (read-only)</option></select>' +
        '<div id="usermgr-err" style="font-size:11px;color:var(--accent-orange);min-height:14px;"></div>' +
        '<button onclick="_usermgrAdd()" style="padding:8px;font-size:12px;font-weight:600;border:none;border-radius:4px;cursor:pointer;background:var(--accent-blue);color:#fff;">Add user</button>' +
        '</div></div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    _usermgrRefresh();
}

async function _usermgrRefresh() {
    const el = document.getElementById('usermgr-list');
    if (!el) return;
    try {
        const r = await fetch('auth.php?action=list_users');
        const d = await r.json();
        if (!d.ok) { el.textContent = d.error || 'Error'; return; }
        if (!d.users.length) { el.textContent = T('msg.no.users', 'No users.'); return; }
        let html = '<table style="width:100%;border-collapse:collapse;">' +
            '<tr style="border-bottom:1px solid var(--border-dim);">' +
            '<th style="text-align:left;padding:4px 6px;font-size:11px;color:var(--text-dim);">Username</th>' +
            '<th style="text-align:left;padding:4px 6px;font-size:11px;color:var(--text-dim);">Role</th>' +
            '<th style="text-align:left;padding:4px 6px;font-size:11px;color:var(--text-dim);">Created</th>' +
            '<th style="text-align:right;padding:4px 6px;font-size:11px;color:var(--text-dim);">Actions</th></tr>';
        d.users.forEach(u => {
            const isSelf = u.username === window._cockpitUser;
            const created = u.created_at ? new Date(u.created_at).toLocaleDateString() : '—';
            html += '<tr style="border-bottom:1px solid var(--border-dim);">' +
                '<td style="padding:5px 6px;">' + _esc(u.username) + ' <span style="color:var(--text-muted);font-size:10px;">(' + (u.id ?? '?') + ')</span>' + (isSelf ? ' <span style="color:var(--text-dim);">(you)</span>' : '') + '</td>' +
                '<td style="padding:5px 6px;">' + _esc(_localRoleLabel(u.role)) + '</td>' +
                '<td style="padding:5px 6px;color:var(--text-dim);">' + created + '</td>' +
                '<td style="padding:5px 6px;text-align:right;">' +
                '<button onclick="_usermgrEdit(\'' + _esc(u.username) + '\',\'' + _esc(u.role) + '\')" style="background:none;border:none;cursor:pointer;color:var(--accent-cyan);font-size:11px;padding:2px 4px;" title="Edit">edit</button>' +
                (isSelf ? '' : ' <button onclick="_usermgrDel(\'' + _esc(u.username) + '\')" style="background:none;border:none;cursor:pointer;color:var(--accent-orange);font-size:11px;padding:2px 4px;" title="Delete">delete</button>') +
                '</td></tr>';
        });
        html += '</table>';
        el.innerHTML = html;
    } catch(e) { el.textContent = 'Error: ' + e.message; }
}

function _usermgrEdit(username, currentRole) {
    let ov2 = document.getElementById('usermgr-edit-overlay');
    if (ov2) ov2.remove();
    ov2 = document.createElement('div');
    ov2.id = 'usermgr-edit-overlay';
    ov2.style.cssText = 'position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,0.5);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov2.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(360px,90vw);padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;">Edit: ' + _esc(username) + '</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="document.getElementById(\'usermgr-edit-overlay\').remove()">×</span></div>' +
        '<div style="display:flex;flex-direction:column;gap:10px;">' +
        '<input id="usermgr-ed-user" placeholder="New username (leave empty to keep)" value="" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;">' +
        _pwWrap('<input id="usermgr-ed-pass" type="password" placeholder="New password (leave empty to keep)" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;width:100%;box-sizing:border-box;">', 'usermgr-ed-pass') +
        '<select id="usermgr-ed-role" style="background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:8px 10px;font-size:12px;border-radius:4px;">' +
        '<option value="admin"' + (currentRole === 'admin' ? ' selected' : '') + '>Owner (this machine)</option>' +
        '<option value="normal"' + (currentRole === 'normal' ? ' selected' : '') + '>Normal</option>' +
        '<option value="viewer"' + (currentRole === 'viewer' ? ' selected' : '') + '>Viewer (read-only)</option></select>' +
        '<div id="usermgr-ed-err" style="font-size:11px;color:var(--accent-orange);min-height:14px;"></div>' +
        '<button onclick="_usermgrEditSubmit(\'' + _esc(username) + '\')" style="padding:8px;font-size:12px;font-weight:600;border:none;border-radius:4px;cursor:pointer;background:var(--accent-blue);color:#fff;">Save changes</button>' +
        '</div></div>';
    document.body.appendChild(ov2);
    ov2.addEventListener('click', e => { if (e.target === ov2) ov2.remove(); });
}

async function _usermgrEditSubmit(target) {
    const newUser = document.getElementById('usermgr-ed-user').value.trim();
    const newPass = document.getElementById('usermgr-ed-pass').value;
    const newRole = document.getElementById('usermgr-ed-role').value;
    const err = document.getElementById('usermgr-ed-err');
    const body = { target };
    if (newUser) body.new_username = newUser;
    if (newPass) body.new_password = newPass;
    body.new_role = newRole;
    try {
        const r = await fetch('auth.php?action=edit_user', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify(body),
        });
        const d = await r.json();
        if (d.ok) {
            document.getElementById('usermgr-edit-overlay').remove();
            _usermgrRefresh();
        } else { err.textContent = d.error || 'Failed'; }
    } catch(e) { err.textContent = 'Error: ' + e.message; }
}

async function _usermgrAdd() {
    const u = document.getElementById('usermgr-newuser').value.trim();
    const p = document.getElementById('usermgr-newpass').value;
    const role = document.getElementById('usermgr-newrole').value;
    const err = document.getElementById('usermgr-err');
    if (u.length < 2) { err.textContent = T('msg.username.must.be.2.32.characters', 'Username must be 2-32 characters'); return; }
    if (p.length < 6) { err.textContent = T('msg.password.must.be.at.least.6.characters', 'Password must be at least 6 characters'); return; }
    try {
        const r = await fetch('auth.php?action=add_user', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({username: u, password: p, role}),
        });
        const d = await r.json();
        if (d.ok) {
            document.getElementById('usermgr-newuser').value = '';
            document.getElementById('usermgr-newpass').value = '';
            err.textContent = '';
            _usermgrRefresh();
        } else { err.textContent = d.error || 'Failed'; }
    } catch(e) { err.textContent = 'Error: ' + e.message; }
}

async function _usermgrDel(username) {
    if (!await cockpitConfirm('Delete user', 'Delete user "' + username + '"? This cannot be undone.', 'Delete', {danger:true, icon:'person_remove'})) return;
    try {
        const r = await fetch('auth.php?action=remove_user', {
            method: 'POST', headers: {'Content-Type': 'application/json'},
            body: JSON.stringify({username}),
        });
        const d = await r.json();
        if (d.ok) _usermgrRefresh();
        else appendSystem(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (d.error || 'Unknown error')}));
    } catch(e) { appendSystem(T('msg.error.message', 'Error: {message}', {message: e.message})); }
}

// Shows the current LOCAL APP user next to the account-type chip, e.g.
// "dario (3)" — the (id) disambiguates same-named accounts (two local users
// could pick the same display name; ids are unique, assigned by auth.php).
// Called from _authGate() directly (both the already-signed-in path and the
// just-logged-in path) instead of relying only on DOMContentLoaded, which can
// fire before or after that async check resolves.
// The identity button is shared by both editions but leads somewhere different:
// v1 has no cloud account, so it opens the local user manager instead of the
// subscription dialog. Keeping one button avoids a second, near-identical one.
function editionAccountOpen() {
    // 'v1' / 'v2' are STRINGS. They were written here as bare identifiers (build 129,
    // 2026-09-26), which is a ReferenceError the moment the line runs — so the button
    // showing who you are signed in as did nothing at all, in either edition, for
    // five days. It rendered fine; the failure only happens on click.
    if ((window.COCKPIT_EDITION || 'v2') === 'v1') return cockpitUserManager();
    return saasAccountOpen();
}

function _cockpitLabelUser() {
    const lbl = document.getElementById('sup-strip-user');
    if (!lbl || !window._cockpitUser) return;
    lbl.textContent = String(window._cockpitUser || '');   // name only (the id is in the Users modal)
    lbl.title = 'Local app user' + (window._cockpitId != null ? ' #' + window._cockpitId : '') + (window._cockpitRole ? ' · role: ' + window._cockpitRole : '');
}
document.addEventListener('DOMContentLoaded', _cockpitLabelUser);



// ── Recovery token ──────────────────────────────────────────────────────────
// Restoring an account needed a token, but nothing in the app could tell you
// whether you had one or give you a new one — accounts made before the feature,
// or a lost piece of paper, were simply stuck. Status + one-time reveal
// (2026-09-22). The plaintext is never stored locally.
async function saasRecoveryToken() {
    let st = {};
    try { st = await (await fetch('saas.php?action=recovery_status')).json(); } catch (e) { st = { ok:false, error:e.message }; }
    const known = st.ok ? !!st.has_recovery : null;
    const when  = st.set_at && typeof fmtTsLocal === 'function' ? fmtTsLocal(st.set_at) : (st.set_at || '');
    const body =
        (known === null ? '<p style="color:var(--accent-orange);font-size:12px;">Could not ask the account server: ' + escHtml(st.error || '?') + '</p>' : '') +
        '<p style="font-size:12px;line-height:1.55;">A <b>recovery token</b> is the only way to bring this account back on a machine that ' +
        'has been reinstalled — it proves the account is yours when the machine id no longer matches. Keep it on paper, ' +
        'not on the computer it protects.</p>' +
        (known === true
            ? '<p style="font-size:12px;color:var(--accent-cyan);">This account has a recovery token' + (when ? ' (set ' + escHtml(when) + ')' : '') + '. ' +
              'Cockpit cannot show it again — only you have it. Lost it? Mint a new one; the old one stops working immediately.</p>'
            : known === false
                ? '<p style="font-size:12px;color:var(--gemini);">This account has <b>no</b> recovery token. Without one it cannot be restored after an OS reinstall.</p>'
                : '') +
        '<div id="recovery-reveal" style="display:none;margin-top:10px;"></div>';
    const ov = document.createElement('div');
    ov.id = 'recovery-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100070;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(560px,94vw);padding:16px 20px;">' +
          '<div style="display:flex;align-items:center;gap:8px;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
            '<span class="material-symbols-rounded" style="font-size:18px;color:var(--warm);">vpn_key</span>' +
            '<h2 style="margin:0;font-size:14px;flex:1;">Recovery token</h2>' +
            '<span id="rec-x" style="cursor:pointer;color:var(--text-dim);font-size:18px;">×</span></div>' +
          body +
          '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:12px;">' +
            '<button class="rp-action-btn" id="rec-close">Close</button>' +
            '<button class="action-btn" id="rec-issue" style="background:var(--accent-blue);color:#fff;">' +
              (known === true ? 'Mint a new token' : 'Create a recovery token') + '</button>' +
          '</div></div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    ov.querySelector('#rec-x').onclick = close;
    ov.querySelector('#rec-close').onclick = close;
    ov.querySelector('#rec-issue').onclick = async () => {
        const btn = ov.querySelector('#rec-issue'); btn.disabled = true; btn.textContent = T('msg.asking.the.server', 'Asking the server…');
        try {
            const d = await (await fetch('saas.php?action=recovery_issue')).json();
            if (!d.ok) {
                const wait = d.retry_after_secs ? (' Try again in ' + Math.ceil(d.retry_after_secs / 60) + ' min.') : '';
                ov.querySelector('#recovery-reveal').style.display = 'block';
                ov.querySelector('#recovery-reveal').innerHTML = '<p style="color:var(--accent-orange);font-size:12px;">' + escHtml(d.error || 'failed') + wait + '</p>';
                btn.disabled = false; btn.textContent = T('msg.try.again', 'Try again');
                return;
            }
            const box = ov.querySelector('#recovery-reveal');
            box.style.display = 'block';
            box.innerHTML =
                '<div style="border:1px solid var(--warm);border-radius:4px;padding:10px;background:var(--bg-darker);">' +
                  '<div style="font-size:11px;color:var(--warm);margin-bottom:6px;">Write this down now — it is shown once and never stored on this machine.</div>' +
                  '<code style="font-family:var(--font-mono);font-size:15px;letter-spacing:0.05em;">' + escHtml(d.recovery_token || '') + '</code>' +
                  '<div style="margin-top:8px;"><button class="rp-action-btn" id="rec-copy">Copy</button></div>' +
                '</div>';
            box.querySelector('#rec-copy').onclick = () => { navigator.clipboard.writeText(d.recovery_token || ''); appendSystem(T('msg.recovery.token.copied.paste.it.somewhere.off', 'Recovery token copied — paste it somewhere off this machine.')); };
            btn.style.display = 'none';
            appendSystem(T('msg.a.new.recovery.token.was.issued.the.previous', 'A new recovery token was issued. The previous one no longer works.'));
        } catch (e) {
            btn.disabled = false; btn.textContent = T('msg.try.again', 'Try again');
            appendSystem(T('msg.recovery.token.message', 'Recovery token: {message}', {message: e.message}));
        }
    };
}


// ── Everywhere relay: authorise this machine ─────────────────────────────────
// Mints a remember token from THIS signed-in session and writes it where the
// relay poller reads it. The poller previously wanted the account password in a
// plaintext file; this replaces that. The raw token stays on the machine — the
// response only confirms which file was written.
async function saasRelayAuthorise() {
    const note = document.getElementById('relay-auth-note');
    const say  = m => { if (note) note.textContent = m; };
    say('Authorising…');
    try {
        const r = await (await fetch('auth.php?action=relay_token', {
            method:'POST', headers:{'Content-Type':'application/json'}, body:'{}'
        })).json();
        if (!r.ok) { say('Authorise failed: ' + (r.error || 'unknown')); return; }
        say('Authorised as ' + r.user + ' until ' + (r.expires_at||'').slice(0,10) +
            '. Restart Cockpit (or run ~/scripts/relay_start.sh) so the relay picks it up.');
        if (typeof appendSystem === 'function')
            appendSystem(T('msg.icon.key.everywhere.relay.authorised.for.thi', '[[icon:key]] Everywhere relay authorised for this machine — no password stored.'));
    } catch (e) { say('Authorise failed: ' + e.message); }
}


// ── What this machine is called ──────────────────────────────────────────────
// The relay listed rigs by machine_id — 32 hex characters, fine for a database
// and no use to a person with two machines. The name is sent with every
// heartbeat, so it appears on the phone within seconds of being saved.
async function machineNameLoad() {
    const el = document.getElementById('machine-name');
    if (!el) return;
    try {
        const r = await (await fetch('machine.php?action=get')).json();
        if (r.ok) {
            el.value = r.source === 'set' ? r.name : '';
            el.placeholder = r.source === 'set' ? r.name : (r.name + ' (hostname)');
        }
    } catch (e) { /* the field simply stays empty */ }
}

async function machineNameSave() {
    const el = document.getElementById('machine-name');
    const note = document.getElementById('relay-auth-note');
    if (!el) return;
    try {
        const r = await (await fetch('machine.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'set', name: el.value }),
        })).json();
        if (!r.ok) { if (note) note.textContent = r.error || 'Could not save the name.'; return; }
        if (note) note.textContent = 'This machine will show as "' + r.name + '" on the relay' +
                                     (r.source === 'hostname' ? ' (its hostname — no name set)' : '') +
                                     ' within a few seconds.';
        el.placeholder = r.name;
    } catch (e) { if (note) note.textContent = e.message; }
}
