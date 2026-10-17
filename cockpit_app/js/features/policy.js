// =============================================================================
// policy.js — Privacy & spending (the face of policy_lib.php / policy.php).
//
//   policyOpen()                    the Toolbar button: settings, this month's usage, a test box
//   policyDecide(policy, agent)     bridge.php refused a prompt — ask the person what to do
//   policyPreflight(agent, text)    the same check for routes that bypass bridge.php (Workers)
//
// One rule runs through all of it: nothing is decided for the person silently. A prompt is
// either sent as written, sent redacted (and the chat says what was removed), sent to a local
// model instead, or not sent at all.
// =============================================================================
(function () {
    'use strict';
    var pending = {};                 // one question at a time per kind of finding (a broadcast asks once)

    function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function closeModal() { var o = document.getElementById('policy-ov'); if (o) o.remove(); }
    function overlay(inner, width) {
        closeModal();
        var ov = document.createElement('div'); ov.id = 'policy-ov';
        ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.65);display:flex;align-items:center;justify-content:center;';
        ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(' + (width || 520) + 'px,94vw);max-height:90vh;overflow:auto;padding:18px;color:var(--text-primary);">' + inner + '</div>';
        document.body.appendChild(ov); return ov;
    }
    function btn(id, label, kind) {
        var st = kind === 'primary' ? 'background:var(--accent-blue);color:#fff;' : (kind === 'danger' ? 'color:var(--claude);' : '');
        return '<button class="action-btn" data-act="' + id + '" style="padding:4px 11px;font-size:11px;' + st + '">' + esc(label) + '</button>';
    }

    // ---- the question ----------------------------------------------------------------------------
    var LABELS = {
        redact:   function () { return T('policy.btn.redact', 'Redact and send'); },
        anyway:   function () { return T('policy.btn.anyway', 'Send anyway'); },
        local:    function () { return T('policy.btn.local', 'Use the local model instead'); },
        spend_ok: function () { return T('policy.btn.spend', 'Send this one anyway'); },
        settings: function () { return T('policy.btn.settings', 'Open Privacy & spending'); },
        cancel:   function () { return T('policy.btn.cancel', 'Cancel'); }
    };
    function ask(p) {
        return new Promise(function (resolve) {
            var rows = (p.findings || []).map(function (f) {
                return '<li><b>' + esc(f.label) + '</b>' + (f.count > 1 ? ' × ' + f.count : '') + ' <span style="color:var(--text-muted);font-family:var(--font-mono);">' + esc((f.previews || []).join('  ')) + '</span></li>';
            }).join('');
            var localOk = !!document.getElementById('ollama-select');
            var opts = (p.options || ['cancel']).filter(function (o) { return o !== 'local' || localOk; });
            var title = p.type === 'free_only' ? T('policy.title.free', 'Free agents only is on')
                      : p.type === 'budget'    ? T('policy.title.budget', 'Monthly paid-agent budget reached')
                      :                          T('policy.title.sensitive', 'This prompt looks sensitive');
            var ov = overlay(
                '<h2 style="margin:0 0 8px;font-size:14px;">' + esc(title) + '</h2>' +
                '<div style="font-size:12px;line-height:1.5;color:var(--text-base);">' + esc(p.message || '') + '</div>' +
                (rows ? '<ul style="margin:8px 0 0 18px;padding:0;font-size:11.5px;line-height:1.6;">' + rows + '</ul>' : '') +
                (/^sensitive/.test(p.type)
                    ? '<div style="margin-top:8px;font-size:10.5px;color:var(--text-dim);">' + esc(T('policy.note.local', 'Nothing has been sent. Redacting replaces each item with [REDACTED:type]; a local model never leaves this machine.')) + '</div>' : '') +
                '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px;flex-wrap:wrap;">' +
                    opts.map(function (o) { return btn(o, LABELS[o] ? LABELS[o]() : o, o === 'redact' || o === 'spend_ok' ? 'primary' : ((p.confirm || []).indexOf(o) >= 0 ? 'danger' : '')); }).join('') + '</div>', 540);
            function done(v) { document.removeEventListener('keydown', onKey, true); closeModal(); resolve(v); }
            function onKey(e) { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done('cancel'); } }
            document.addEventListener('keydown', onKey, true);
            // A choice that sends sensitive text as written, under a "strict" setting, needs a second explicit yes.
            function confirmSend() {
                var o2 = overlay(
                    '<h2 style="margin:0 0 8px;font-size:14px;">' + esc(T('policy.confirm.title', 'Send it as written?')) + '</h2>' +
                    '<div style="font-size:12px;line-height:1.5;">' + esc(T('policy.confirm.text', 'The items listed will leave this computer, unredacted, and go to {agent}.', { agent: p.agent || '' })) + '</div>' +
                    '<ul style="margin:8px 0 0 18px;padding:0;font-size:11.5px;line-height:1.6;">' + rows + '</ul>' +
                    '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:14px;">' + btn('back', T('policy.confirm.back', 'Back')) + btn('yes', T('policy.confirm.yes', 'Yes, send it unredacted'), 'danger') + '</div>', 480);
                o2.querySelector('[data-act="yes"]').onclick = function () { document.removeEventListener('keydown', onKey, true); closeModal(); resolve('anyway'); };
                o2.querySelector('[data-act="back"]').onclick = function () { document.removeEventListener('keydown', onKey, true); closeModal(); ask(p).then(resolve); };
            }
            ov.querySelectorAll('[data-act]').forEach(function (b) { b.onclick = function () { (p.confirm || []).indexOf(b.dataset.act) >= 0 ? confirmSend() : done(b.dataset.act); }; });
        });
    }
    // Callers that arrive while the question is still open (a broadcast to several agents) share it;
    // once answered the entry is dropped, so a later send is always asked afresh.
    window.policyDecide = function (p, agent) {
        var key = p.type + '|' + (p.findings || []).map(function (f) { return f.type + f.count; }).join(',') + '|' + (p.used || '');
        if (!pending[key]) {
            pending[key] = ask(p);
            pending[key].then(function () { delete pending[key]; });   // shared only WHILE the dialog is open: a resend asks again
        }
        return pending[key].then(function (choice) {
            if (choice === 'settings') { policyOpen(); return 'cancel'; }
            return choice;
        });
    };

    // ---- routes that do not pass through bridge.php (Workers) ---------------------------------------
    window.policyPreflight = async function (agent, text) {
        var ov = {}, t = text;
        for (var i = 0; i < 3; i++) {
            var r; try { r = await (await fetch('policy.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'check', agent: agent, text: t, policy: ov }) })).json(); }
            catch (e) { return { text: t }; }                      // the check is a safeguard, not a gate that can lock the app
            if (r && r.ok) { (r.notes || []).forEach(function (n) { appendSystem('🛡 ' + n); }); return { text: r.text }; }
            if (!r || !r.policy) return { text: t };
            var c = await policyDecide(r.policy, agent);
            if (c === 'cancel') { appendSystem(T('policy.notsent', '🛡 Not sent — nothing left this computer.')); return { cancel: true }; }
            if (c === 'local') return { local: true };
            if (c === 'redact') ov.gate = 'redact'; else if (c === 'anyway') ov.gate = 'anyway'; else if (c === 'spend_ok') ov.spend_ok = true;
        }
        return { text: t };
    };

    // ---- the settings dialog -------------------------------------------------------------------------
    var state = null;
    function field(label, inner, hint) {
        return '<div style="margin-top:12px;"><label style="font-size:11px;font-weight:600;display:block;margin-bottom:3px;">' + label + '</label>' + inner +
               (hint ? '<div style="font-size:10.5px;color:var(--text-dim);margin-top:3px;line-height:1.45;">' + hint + '</div>' : '') + '</div>';
    }
    window.policyOpen = async function () {
        var r; try { r = await (await fetch('policy.php?action=get')).json(); } catch (e) { r = null; }
        if (!r || !r.ok) { appendError(T('policy.err.load', 'Could not load Privacy & spending.')); return; }
        state = r; var p = r.policy;
        var agents = Object.keys(r.agents || {}).map(function (k) {
            var a = r.agents[k]; return '<span style="margin-right:12px;">' + esc(a.name) + ' <span style="color:var(--text-muted);">· ' + esc(a.cloud ? (a.paid ? T('policy.paid', 'online, paid') : T('policy.online', 'online')) : T('policy.local', 'on this machine')) + '</span></span>';
        }).join('');
        var ov = overlay(
            '<div style="display:flex;align-items:center;margin-bottom:2px;"><h2 style="margin:0;font-size:14px;flex:1;">' + esc(T('policy.dlg.title', 'Privacy & spending')) + '</h2>' +
            '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" id="policy-x">×</span></div>' +
            '<div style="font-size:10.5px;color:var(--text-dim);margin-bottom:4px;">' + esc(T('policy.dlg.agents', 'Agents on your cards now:')) + ' ' + agents + '</div>' +
            field(esc(T('policy.gate', 'Sensitivity gate')),
                '<label style="font-size:11.5px;"><input type="checkbox" id="pol-gate" ' + (p.gate.enabled ? 'checked' : '') + '> ' + esc(T('policy.gate.on', 'Check prompts for secrets and card numbers before they go to an online agent')) + '</label>' +
                '<select id="pol-act" class="ma-mode-btn" style="width:100%;margin-top:6px;"><option value="ask">' + esc(T('policy.act.ask', 'Ask me every time')) + '</option><option value="strict">' + esc(T('policy.act.strict', 'Never send them online, unless I choose to, each time')) + '</option><option value="redact">' + esc(T('policy.act.redact', 'Redact automatically and tell me')) + '</option><option value="block">' + esc(T('policy.act.block', 'Never send them online, no exceptions')) + '</option></select>',
                esc(T('policy.gate.hint', 'Looks for private keys, API keys and tokens, passwords in assignments, passwords inside connection strings, and payment-card, IBAN and US SSN numbers that pass their own checksum. It does not guess at names, e-mail addresses or phone numbers. Local agents are never checked: nothing leaves the machine.'))) +
            field(esc(T('policy.free', 'Free agents only')),
                '<label style="font-size:11.5px;"><input type="checkbox" id="pol-free" ' + (p.free_only ? 'checked' : '') + '> ' + esc(T('policy.free.on', 'Refuse agents that need a paid plan')) + '</label>' +
                '<label style="font-size:11.5px;display:block;margin-top:7px;"><input type="checkbox" id="pol-link" ' + (p.link_stay_free ? 'checked' : '') + '> ' + esc(T('policy.link', 'Link with Stay Free in the Suppliers dialog')) + '</label>',
                esc(T('policy.free.hint', 'On by default for a new install. An install that already has history keeps it off, so an update never starts refusing the agent you use.')) + ' ' +
                esc(T('policy.link.hint', 'Linked: pressing Stay Free (Suppliers) also turns this on, and while it is on the Suppliers dialog disables the paid agents. Untie them to use the two independently.'))) +
            field(esc(T('policy.budget', 'Monthly budget for paid agents')),
                '<input id="pol-cap" type="number" min="0" max="100000" value="' + (p.budget.paid_prompts_per_month || 0) + '" style="width:90px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:3px 6px;border-radius:4px;font-size:11px;"> ' + esc(T('policy.budget.unit', 'prompts a month (0 = no limit)')) +
                ' <span style="margin-left:10px;color:var(--text-muted);font-size:11px;">' + esc(T('policy.budget.used', 'This month:')) + ' <b>' + r.paid_used + '</b></span>',
                esc(T('policy.budget.hint', 'Cockpit cannot see what a subscription bills, so it counts prompts sent to paid agents. It warns at 80% and stops at 100%; you can override once per prompt.'))) +
            field(esc(T('policy.test', 'Try the gate')),
                '<textarea id="pol-test" rows="3" placeholder="' + esc(T('policy.test.ph', 'Paste text to see what it would catch. Nothing is stored or sent.')) + '" style="width:100%;box-sizing:border-box;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 7px;border-radius:4px;font-size:11px;font-family:var(--font-mono);"></textarea>' +
                '<div style="margin-top:5px;display:flex;gap:8px;align-items:center;"><button class="action-btn" id="pol-scan" style="padding:3px 9px;font-size:10.5px;">' + esc(T('policy.test.btn', 'Check')) + '</button><span id="pol-scan-out" style="font-size:11px;"></span></div>') +
            '<div id="pol-msg" style="font-size:11px;min-height:16px;margin-top:10px;color:var(--accent-orange);"></div>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;margin-top:6px;">' + btn('close', T('policy.btn.close', 'Close')) + btn('save', T('policy.btn.save', 'Save'), 'primary') + '</div>', 560);
        document.getElementById('pol-act').value = p.gate.action;
        ov.querySelector('#policy-x').onclick = closeModal;
        ov.querySelector('[data-act="close"]').onclick = closeModal;
        ov.querySelector('#pol-scan').onclick = async function () {
            var out = document.getElementById('pol-scan-out'); out.textContent = '…';
            try {
                var s = await (await fetch('policy.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'scan', text: document.getElementById('pol-test').value }) })).json();
                out.textContent = s.count ? s.findings.map(function (f) { return (f.count > 1 ? f.count + '× ' : '') + f.label + ' (' + f.previews.join(' ') + ')'; }).join('; ') : T('policy.test.none', 'Nothing sensitive found.');
                out.style.color = s.count ? 'var(--accent-orange)' : 'var(--accent-green,#7ec97e)';
                var rb = document.getElementById('pol-redacted');
                if (rb) rb.remove();
                if (s.count) { rb = document.createElement('pre'); rb.id = 'pol-redacted'; rb.style.cssText = 'margin:6px 0 0;padding:6px 8px;background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;font-size:10.5px;white-space:pre-wrap;word-break:break-word;max-height:110px;overflow:auto;';
                    rb.textContent = T('policy.test.would', 'Would be sent as:') + '\n' + s.redacted; out.parentNode.parentNode.appendChild(rb); }
            } catch (e) { out.textContent = e.message; }
        };
        ov.querySelector('[data-act="save"]').onclick = async function () {
            var msg = document.getElementById('pol-msg');
            try {
                var res = await (await fetch('policy.php', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'set',
                    gate: { enabled: document.getElementById('pol-gate').checked, action: document.getElementById('pol-act').value },
                    free_only: document.getElementById('pol-free').checked,
                    link_stay_free: document.getElementById('pol-link').checked,
                    budget: { paid_prompts_per_month: parseInt(document.getElementById('pol-cap').value, 10) || 0 } }) })).json();
                if (!res.ok) { msg.textContent = res.error || 'save failed'; return; }
                closeModal(); appendSystem(T('policy.saved', '🛡 Privacy & spending saved.'));
            } catch (e) { msg.textContent = e.message; }
        };
    };
})();
