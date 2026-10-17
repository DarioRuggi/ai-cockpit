// CAPABILITIES PANEL — unified MCP / Skills / Tool-shim management
//
// One UI for the three layers underneath: MCP servers (Claude/Gemini),
// Anthropic Skills (Claude only), and tool shims (Ollama). Each capability
// declares which agents it supports; the cockpit handles routing when the
// agent runs a prompt.
//
// State is kept in two places:
//   - The capability folder itself (CAP.json + supporting files)
//   - Per-project enablement: <project>/capabilities.json
//
// Functions:
//   capRefresh()           — reload list, render with toggles
//   capCreatePrompt()      — prompt for new capability id+name, scaffold it
//   capShowRegistry()      — show "downloadable" suggestions (placeholder)
//   capApplyNow()          — force a refresh of agent configs (normally
//                            done automatically before each prompt)
//   capSetGlobal(id, bool) — turn a capability ON/OFF globally (all projects)
//   capExpand(id)          — show capability details inline
// =============================================================================

let _capList    = [];   // last fetched capability manifests
let _capEnabled = {};   // GLOBAL effective on/off: { "<id>": bool }

async function capRefresh() {
    const listEl = document.getElementById('rp-list-capabilities');
    if (!listEl) return;
    listEl.innerHTML = '<div class="sidebar-empty">Loading capabilities…</div>';

    try {
        // Capability list + the GLOBAL on/off map (one switch, all projects +
        // free chats, all suppliers).
        const [allRes, gblRes] = await Promise.all([
            fetch('capabilities.php?action=list'),
            fetch('capabilities.php?action=global_caps'),
        ]);
        const all = await allRes.json();
        const gbl = await gblRes.json();

        if (!all.ok) {
            listEl.innerHTML = '<div class="sidebar-empty">Error: ' +
                (all.error || 'failed to load') + '</div>';
            return;
        }

        _capList    = all.capabilities || [];
        _capEnabled = (gbl && gbl.enabled) ? gbl.enabled : {};

        capRender();
    } catch (e) {
        listEl.innerHTML = '<div class="sidebar-empty">Error: ' + e.message + '</div>';
    }
}

function capRender() {
    const listEl = document.getElementById('rp-list-capabilities');
    if (!_capList.length) {
        listEl.innerHTML = '<div class="sidebar-empty">No capabilities installed.<br>' +
            'Run <code>./install_capabilities.sh</code> to install built-ins.</div>';
        return;
    }

    const html = _capList.map(cap => {
        const on       = !!_capEnabled[cap.id];   // GLOBAL effective state
        const impls    = cap.implementations || {};
        const agents   = [];
        if (impls.claude || impls['claude-skill']) agents.push({n:'Claude', c:'claude'});
        if (impls.gemini)                          agents.push({n:'Gemini', c:'gemini'});
        if (impls.ollama)                          agents.push({n:'Ollama', c:'ollama'});

        const badges = agents.map(a =>
            '<span class="cap-agent-badge cap-' + a.c + '">' + a.n + '</span>'
        ).join('');

        // One global on/off switch — applies to every project, free chats, and all
        // the capability's suppliers. Text label ("ON"/"OFF") so it never relies on
        // colour alone (protanopia-safe).
        const stateBtn = on
            ? `<button class="cap-toggle on" onclick="event.stopPropagation();capSetGlobal('${cap.id}',false)" title="Enabled globally — click to turn OFF"><span class="material-symbols-rounded">toggle_on</span><span class="cap-toggle-lbl">ON</span></button>`
            : `<button class="cap-toggle"    onclick="event.stopPropagation();capSetGlobal('${cap.id}',true)"  title="Disabled — click to turn ON globally"><span class="material-symbols-rounded">toggle_off</span><span class="cap-toggle-lbl">OFF</span></button>`;

        const builtinBadge = cap._builtin ?
            '<span class="cap-builtin-badge" title="Built-in capability — cannot be deleted">built-in</span>' : '';
        const editBtn = cap._builtin ? '' :
            `<button class="cap-del" onclick="event.stopPropagation();capEditManifest('${cap.id}')" title="Edit CAP.json">
                <span class="material-symbols-rounded">edit</span>
            </button>`;
        const deleteBtn = cap._builtin ? '' :
            `<button class="cap-del" onclick="event.stopPropagation();capDelete('${cap.id}')" title="Delete this user capability">
                <span class="material-symbols-rounded">delete</span>
            </button>`;

        return `
        <div class="cap-item" data-cap-id="${cap.id}">
          <div class="cap-row" onclick="capExpand('${cap.id}')">
            ${stateBtn}
            <div class="cap-meta">
              <div class="cap-name">${escapeHtml(cap.name || cap.id)} ${builtinBadge}</div>
              <div class="cap-desc">${escapeHtml(cap.description || '')}</div>
              <div class="cap-badges">${badges}</div>
            </div>
            ${editBtn}
            ${deleteBtn}
          </div>
          <div class="cap-detail" id="cap-detail-${cap.id}" style="display:none;"></div>
        </div>`;
    }).join('');

    listEl.innerHTML = html;
}

// Skill vs Capability decision guide (design §16). Surfaced in both managers so
// authors put knowledge → Skill, action → Capability, and don't grow two
// overlapping systems. Protanopia-safe (text + shape, blue/amber, no red-only).
function skillVsCapGuide() {
    document.getElementById('svc-guide')?.remove();
    const ov = document.createElement('div');
    ov.id = 'svc-guide';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10010;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(660px,94vw);padding:18px 22px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<h2 style="margin:0 0 10px 0;font-size:14px;color:var(--workers);">▤ Skill, Capability, or Tool?</h2>' +
        '<div style="font-size:11.5px;line-height:1.5;color:var(--text-base);">' +
        '<p style="margin:0 0 8px 0;"><b style="color:var(--accent-cyan);">Skill = knowledge.</b> Teaches the agent HOW to do a task well — voice, standards, multi-step method. A <code>SKILL.md</code> folder loaded into context (progressive disclosure). The agent reasons WITH it. Portable to/from Claude.ai.</p>' +
        '<p style="margin:0 0 8px 0;"><b style="color:var(--accent-amber);">Capability = agent action.</b> Gives the agent a new thing it can DO and get a result back — call a service, search, run an MCP. A <code>CAP.json</code> the AGENT dispatches via marker (it decides when). May use AI/network/keys.</p>' +
        '<p style="margin:0 0 8px 0;"><b style="color:var(--accent-violet,#b48cff);">Tool = deterministic transform.</b> A local binary you run on a file → file out. ffmpeg / whisper / pandoc / imagemagick. <b>No AI, no network, no keys.</b> YOU click it (5th provider class); same input always gives same output.</p>' +
        '<div style="border-top:1px solid var(--border-dim);margin:8px 0;padding-top:8px;">' +
        '<div style="margin-bottom:4px;">▸ "Follow OUR style / standards / process" → <b style="color:var(--accent-cyan);">Skill</b></div>' +
        '<div style="margin-bottom:4px;">▸ "Let the AGENT decide to DO a thing and get a result" → <b style="color:var(--accent-amber);">Capability</b></div>' +
        '<div style="margin-bottom:4px;">▸ "Convert/transcode/transcribe a FILE deterministically, no AI" → <b style="color:var(--accent-violet,#b48cff);">Tool</b></div>' +
        '<div>▸ "A workflow that USES an action" → make the <b style="color:var(--accent-amber);">Capability</b> (or <b style="color:var(--accent-violet,#b48cff);">Tool</b>), then a <b style="color:var(--accent-cyan);">Skill</b> whose instructions invoke it.</div>' +
        '</div>' +
        '<p style="margin:8px 0 0 0;font-size:10px;color:var(--text-muted);">Who runs it: Skill → agent reasons · Capability → agent dispatches · Tool → you click. AI involved: Skill/Capability yes · Tool never.</p>' +
        '</div>' +
        '<div style="text-align:right;margin-top:12px;"><button class="action-btn" onclick="document.getElementById(\'svc-guide\').remove()" style="padding:5px 16px;">Got it</button></div>' +
        '</div>';
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
    document.body.appendChild(ov);
}

// Edit a user capability's CAP.json in the floating editor (JSON-highlighted).
async function capEditManifest(id) {
    let content = '';
    try {
        const r = await fetch('capabilities.php?action=get_raw&id=' + encodeURIComponent(id));
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.cannot.edit.error', 'Cannot edit: {error}', {error: (d.error || '')})); return; }
        content = d.content || '';
    } catch (e) { appendError(T('msg.read.failed.message', 'Read failed: {message}', {message: e.message})); return; }

    openFloatingEditor({
        id: 'cap-' + id,
        heading: 'Editing capability: ' + id,
        filename: id + '/CAP.json',
        content,
        language: 'json',
        onSave: async (newContent) => {
            // Friendly client-side JSON check before the round-trip.
            try { JSON.parse(newContent); }
            catch (e) { return { ok:false, error:'Invalid JSON: ' + e.message }; }
            try {
                const r = await fetch('capabilities.php', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({ action:'save_raw', id, content:newContent })
                });
                const d = await r.json();
                if (!d.ok) return { ok:false, error: d.error || 'unknown' };
                appendSystem(T('msg.saved.cap.json.for.id.restart.the.agent.for', 'Saved CAP.json for "{id}". Restart the agent for changes to take effect.', {id: id}));
                capRefresh();
                return { ok:true };
            } catch (e) { return { ok:false, error: e.message }; }
        }
    });
}

// Flip a capability ON/OFF GLOBALLY (all projects, free chats, all its suppliers).
async function capSetGlobal(id, enabled) {
    try {
        const r = await fetch('capabilities.php?action=global_set', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ cap_id: id, enabled: !!enabled })
        });
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.capability.toggle.failed.error', 'Capability toggle failed: {error}', {error: (d.error || 'unknown')})); return; }
        appendSystem(T('msg.capability.id.enabled.globally.restart.the.a', 'Capability "{id}" {enabled} globally. Restart the agent for changes to take effect.', {id: id, enabled: (enabled ? 'enabled' : 'disabled')}));
        // Re-stage configs for the current context immediately (also runs before
        // each prompt automatically via bridge.php).
        fetch('capabilities.php?action=apply', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ project: currentProject || 'default' })
        }).catch(() => {});
        capRefresh();
    } catch(e) {
        appendError(T('msg.capability.toggle.failed.message', 'Capability toggle failed: {message}', {message: e.message}));
    }
}

async function capExpand(id) {
    const detail = document.getElementById('cap-detail-' + id);
    if (!detail) return;
    if (detail.style.display !== 'none') {
        detail.style.display = 'none';
        return;
    }
    detail.style.display = 'block';
    detail.innerHTML = '<div style="padding:8px;color:var(--text-muted);">Loading…</div>';
    try {
        const r = await fetch('capabilities.php?action=get&id=' + encodeURIComponent(id));
        const d = await r.json();
        if (!d.ok) {
            detail.innerHTML = '<div style="padding:8px;color:var(--text-muted);">Error: ' +
                (d.error||'failed to load') + '</div>';
            return;
        }
        // Render readme + per-agent impl summary
        const m = d.manifest || {};
        let html = '';
        if (d.readme) {
            html += '<div class="cap-readme">' +
                escapeHtml(d.readme).replace(/\n/g,'<br>') + '</div>';
        }
        const impls = m.implementations || {};
        html += '<div class="cap-impls"><div class="cap-impls-title">Per-agent setup:</div>';
        for (const [agent, impl] of Object.entries(impls)) {
            html += '<div class="cap-impl"><b>' + escapeHtml(agent) + '</b>: ' +
                    escapeHtml(impl.type || '') + '</div>';
        }
        html += '</div>';
        detail.innerHTML = html;
    } catch(e) {
        detail.innerHTML = '<div style="padding:8px;color:var(--text-muted);">Error: ' + e.message + '</div>';
    }
}

async function capCreatePrompt() {
    let ov = document.getElementById('capcreate-overlay');
    if (ov) ov.remove();
    ov = document.createElement('div');
    ov.id = 'capcreate-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(600px,94vw);max-height:90vh;overflow:auto;padding:16px 20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;border-bottom:1px solid var(--border-dim);padding-bottom:8px;margin-bottom:10px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">extension</span> New capability</h2>' +
        '<span class="rp-action-btn" id="capc-close" style="cursor:pointer;">×</span></div>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<label style="font-size:11px;color:var(--text-muted);">ID (lowercase, a-z 0-9 _ -)' +
        '<input id="capc-id" type="text" placeholder="my-tool" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:12px;padding:5px 6px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Display name' +
        '<input id="capc-name" type="text" placeholder="My Tool" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:12px;padding:5px 6px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Description' +
        '<input id="capc-desc" type="text" placeholder="What it does, one sentence" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:12px;padding:5px 6px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Type' +
        '<select id="capc-type" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-size:12px;padding:5px 6px;">' +
        '<option value="tool_shim">tool_shim — wraps a local CLI binary</option>' +
        '<option value="mcp_server">mcp_server — an MCP server command</option>' +
        '<option value="prompt_shim">prompt_shim — injects extra prompt instructions</option>' +
        '</select></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Command (optional — the binary or server to run)' +
        '<input id="capc-cmd" type="text" placeholder="/usr/bin/sometool" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:12px;padding:5px 6px;"></label>' +
        '<label style="font-size:11px;color:var(--text-muted);">Args (optional, space-separated)' +
        '<input id="capc-args" type="text" placeholder="--flag value" style="width:100%;margin-top:3px;background:var(--bg-darker,var(--bg-codeblock));color:var(--text-base);border:1px solid var(--border-dim);font-family:var(--font-mono);font-size:12px;padding:5px 6px;"></label>' +
        '<div id="capc-err" style="font-size:11px;color:var(--warn);min-height:14px;"></div>' +
        '<div style="font-size:10px;color:var(--text-muted);">Leave Command blank to scaffold an empty capability and wire it later by editing CAP.json.</div>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:8px;">' +
        '<button class="rp-action-btn" id="capc-cancel">Cancel</button>' +
        '<button class="rp-action-btn" id="capc-save" style="background:var(--bg-active);">Create</button>' +
        '</div></div></div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    document.getElementById('capc-close').onclick = close;
    document.getElementById('capc-cancel').onclick = close;
    ov.onclick = e => { if (e.target === ov) close(); };
    setTimeout(() => document.getElementById('capc-id').focus(), 50);
    document.getElementById('capc-save').onclick = async () => {
        const id   = document.getElementById('capc-id').value.trim().toLowerCase().replace(/[^a-z0-9_\-]/g,'');
        const name = document.getElementById('capc-name').value.trim();
        const desc = document.getElementById('capc-desc').value.trim();
        const cap_type = document.getElementById('capc-type').value;
        const command  = document.getElementById('capc-cmd').value.trim();
        const args     = document.getElementById('capc-args').value.trim();
        const cerr = m => { const e = document.getElementById('capc-err'); if (e) e.textContent = m; };   // inside the dialog: the chat is hidden behind it
        if (!id)   { cerr(T('msg.capability.id.required', 'Capability ID required')); document.getElementById('capc-id').focus(); return; }
        if (!name) { cerr(T('msg.display.name.required', 'Display name required')); document.getElementById('capc-name').focus(); return; }
        try {
            const r = await fetch('capabilities.php?action=create', {
                method: 'POST', headers: {'Content-Type':'application/json'},
                body: JSON.stringify({id, name, description: desc, cap_type, command, args}),
            });
            const d = await r.json();
            if (!d.ok) { cerr(T('msg.create.failed.error', 'Create failed: {error}', {error: (d.error||'unknown')})); return; }
            appendSystem(T('msg.capability.id.createdwired', 'Capability "{id}" created{wired}', {id: id, wired: (d.wired ? ' and wired.' : ' (empty — edit CAP.json to wire it).')}));
            close();
            capRefresh();
        } catch(e) { appendError(T('msg.create.failed.message', 'Create failed: {message}', {message: e.message})); }
    };
}

async function capDelete(id) {
    if (!await cockpitConfirm('Delete capability?', 'Delete user capability "' + id + '"? This cannot be undone.', 'Delete', {danger:true, icon:'delete'})) return;
    try {
        const r = await fetch('capabilities.php?action=delete&id=' + encodeURIComponent(id), {
            method: 'POST',
        });
        const d = await r.json();
        if (!d.ok) {
            appendError(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (d.error||'unknown')}));
            return;
        }
        appendSystem(T('msg.capability.id.deleted', 'Capability "{id}" deleted.', {id: id}));
        capRefresh();
    } catch(e) {
        appendError(T('msg.delete.failed.message', 'Delete failed: {message}', {message: e.message}));
    }
}

async function capShowRegistry() {
    try {
        const r = await fetch('capabilities.php?action=registry');
        const d = await r.json();
        if (!d.ok) return;
        const lines = [
            'Suggested capabilities you can add manually:',
            '',
            ...d.suggestions.map(s => `• ${s.name} (${s.id})  —  ${s.desc}\n  Package: ${s.pkg}`),
            '',
            'To add: create a folder under ~/scripts/cockpit_data/capabilities/<id>/',
            'with a CAP.json wiring the package as the MCP "command".',
        ];
        appendSystem(lines.join('\n'));
    } catch(e) {
        appendError(T('msg.registry.fetch.failed.message', 'Registry fetch failed: {message}', {message: e.message}));
    }
}

async function capApplyNow() {
    try {
        const r = await fetch('capabilities.php?action=apply&project=' +
                              encodeURIComponent(currentProject || 'default'), {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({project: currentProject || 'default'}),
        });
        const d = await r.json();
        if (!d.ok) {
            appendError(T('msg.apply.failed.error', 'Apply failed: {error}', {error: (d.error||'unknown')}));
            return;
        }
        appendSystem(`Applied ${d.enabled_count} capabilities · Claude MCP: ${d.claude_mcp_count}, ` +
                     `Gemini MCP: ${d.gemini_mcp_count}, Claude skills: ${d.claude_skill_count}, ` +
                     `Ollama shim: ${d.ollama_shim_count}. Restart agents to pick up changes.`);
    } catch(e) {
        appendError(T('msg.apply.failed.message', 'Apply failed: {message}', {message: e.message}));
    }
}

// Helper: escape HTML for safe insertion
function escapeHtml(s) {
    if (s === null || s === undefined) return '';
    return String(s)
        .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
        .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

// =============================================================================
