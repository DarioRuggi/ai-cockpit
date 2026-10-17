// =============================================================================
// Profile — what every agent should know about you.
//
// Global directives say how agents should behave; this says who they are working
// with: units, language, timezone, how you like answers, what you are building.
// It rides on every prompt, which is exactly why it is capped and why the editor
// shows the size — a profile that grows into an essay quietly taxes every request
// and crowds out the actual question.
//
// Two ways in: the editor, and "Remember this" on any message, which appends one
// line. The second is the one that gets used, so it refuses duplicates and keeps
// lines short.
// =============================================================================

const PROFILE_LIMIT = 4096;   // must match PROFILE_MAX_BYTES in profile.php

async function profileOpen() {
    document.getElementById('profile-ov')?.remove();
    let d = { text: '', enabled: true };
    try { d = await (await fetch('profile.php?action=get')).json(); }
    catch (e) { appendError(T('msg.profile.message', 'Profile: {message}', {message: e.message})); return; }

    const ov = document.createElement('div');
    ov.id = 'profile-ov';
    ov.style.cssText = 'position:fixed;inset:0;z-index:100060;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(640px,94vw);padding:18px;">' +
        '<div style="display:flex;align-items:center;margin-bottom:6px;">' +
        '<h2 style="margin:0;font-size:13px;flex:1;">' +
        '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">badge</span> Profile</h2>' +
        '<label style="font-size:10.5px;color:var(--text-muted);margin-right:10px;">' +
        '<input type="checkbox" id="profile-enabled"' + (d.enabled ? ' checked' : '') + '> send with every prompt</label>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#profile-ov\').remove()">×</span></div>' +
        '<div style="font-size:10.5px;color:var(--text-dim);margin-bottom:6px;">' +
        'Facts about you that every agent should have — units, language, tone, what you are working on. ' +
        'Not instructions for the agent: those belong in Rules.</div>' +
        // A sample is shown when no profile exists yet. Say so plainly: it is not
        // stored and no agent has seen it, and it must not be mistaken for something
        // the user (or a previous user of this machine) wrote.
        (d.sample ?
            '<div style="font-size:10.5px;color:var(--warn,#e6b43c);border:1px solid var(--warn,#e6b43c);' +
            'border-radius:4px;padding:6px 8px;margin-bottom:6px;">' +
            '<b>This is a sample.</b> Nothing is saved yet and no agent has seen it. ' +
            'Replace the example lines with facts about you, then Save.</div>' : '') +
        '<textarea id="profile-text" rows="12" spellcheck="false" ' +
        'style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);' +
        'border:1px solid var(--border-dim);border-radius:4px;padding:8px;font-family:var(--font-mono);font-size:11.5px;" ' +
        'placeholder="- I use metric units and British English.&#10;- Answers: direct, no preamble.&#10;- I am building a local-first AI cockpit in PHP and Free Pascal."></textarea>' +
        '<div style="display:flex;align-items:center;gap:8px;margin-top:6px;">' +
        '<span id="profile-count" style="font-size:10px;color:var(--text-dim);"></span>' +
        '<span id="profile-err" style="font-size:11px;color:var(--accent-orange);flex:1;"></span>' +
        '<button class="action-btn" onclick="this.closest(\'#profile-ov\').remove()">Cancel</button>' +
        '<button class="action-btn" style="background:var(--accent-blue);color:#fff;" onclick="profileSave()">Save</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    const ta = document.getElementById('profile-text');
    ta.value = d.text || '';
    window._profileSampleText = d.sample ? (d.text || '') : null;   // the unchanged sample must not be saved as if it were the person's own profile
    const count = () => {
        const n = new Blob([ta.value]).size;
        const el = document.getElementById('profile-count');
        el.textContent = n + ' / ' + PROFILE_LIMIT + ' bytes';
        el.style.color = n > PROFILE_LIMIT ? 'var(--accent-orange)' : 'var(--text-dim)';
    };
    ta.addEventListener('input', count); count(); ta.focus();
}

async function profileSave() {
    const text = (document.getElementById('profile-text') || {}).value || '';
    const enabled = !!(document.getElementById('profile-enabled') || {}).checked;
    const err = document.getElementById('profile-err');
    if (window._profileSampleText !== null && window._profileSampleText !== undefined && text.trim() === window._profileSampleText.trim()) { if (err) err.textContent = T('msg.profile.still.sample', 'This is still the sample. Replace the example lines with facts about you, then Save.'); return; }
    try {
        const r = await (await fetch('profile.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'save', text: text, enabled: enabled }),
        })).json();
        if (!r.ok) { err.textContent = r.error || 'save failed'; return; }
        document.getElementById('profile-ov')?.remove();
        appendSystem(T('msg.icon.badge.profile.saved.bytes.bytes.enabled', '[[icon:badge]] Profile saved ({bytes} bytes){enabled}', {bytes: r.bytes, enabled: (enabled ? ' — it goes with every prompt from now on.' : ' — switched off, nothing is sent.')}));
    } catch (e) { err.textContent = e.message; }
}

/** "Remember this" — append the selection (or a prompted line) to the profile. */
async function profileRemember(el) {
    let text = (window.getSelection ? String(window.getSelection()) : '').trim();
    if (!text && el) {
        const body = el.closest('.msg')?.querySelector('.msg-body');
        // the text a person reads: not the code-block header ("CODE snippet · 1 lines"), not the icon-font ligature names on the buttons
        let clone = body ? body.cloneNode(true) : null;
        if (clone) clone.querySelectorAll('.material-symbols-rounded, .code-header, .codehdr, button, .msg-receipts').forEach(x => x.remove());
        text = (clone ? clone.textContent : '').replace(/\s+/g, ' ').trim().slice(0, 300);
    }
    if (!text) { appendError(T('msg.profile.select.the.part.worth.remembering.fi', 'Profile: select the part worth remembering first.')); return; }
    try {
        const r = await (await fetch('profile.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'remember', text: text }),
        })).json();
        if (!r.ok) { appendError(T('msg.profile.error', 'Profile: {error}', {error: (r.error || 'could not save')})); return; }
        if (r.duplicate) appendSystem(T('msg.icon.badge.already.in.your.profile.nothing.a', '[[icon:badge]] Already in your profile — nothing added.'));
        else appendSystem(T('msg.icon.badge.added.to.your.profile.line', '[[icon:badge]] Added to your profile: {line}', {line: r.line}));
    } catch (e) { appendError(T('msg.profile.message', 'Profile: {message}', {message: e.message})); }
}
