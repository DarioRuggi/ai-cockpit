// =============================================================================
// Chat export / import
// =============================================================================

// Export a chat as a single .zip containing both .json and .md
function exportChat(chatSlug, project) {
    const url = 'export.php'
              + '?project=' + encodeURIComponent(project || '_standalone')
              + '&chat=' + encodeURIComponent(chatSlug);
    // Trigger download via a hidden anchor — the server sends Content-Disposition
    const a = document.createElement('a');
    a.href = url;
    a.download = '';
    document.body.appendChild(a);
    a.click();
    setTimeout(() => a.remove(), 500);
    appendSystem(T('msg.exporting.chat.chatslug.download.should.star', 'Exporting chat "{chatslug}" — download should start.', {chatslug: chatSlug}));
}

function batchExportChats() {
    const proj = currentProject || '_standalone';
    let ov = document.getElementById('batchexport-overlay');
    if (ov) { ov.remove(); }
    ov = document.createElement('div');
    ov.id = 'batchexport-overlay';
    ov.style.cssText = 'position:fixed;inset:0;z-index:9999;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
    ov.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(400px,90vw);padding:20px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
        '<div style="display:flex;align-items:center;margin-bottom:14px;">' +
        '<h2 style="margin:0;font-size:14px;flex:1;"><span class="material-symbols-rounded" style="font-size:16px;vertical-align:-3px;">file_download</span> Batch export</h2>' +
        '<span style="cursor:pointer;font-size:18px;color:var(--text-dim);" onclick="this.closest(\'#batchexport-overlay\').remove()">×</span></div>' +
        '<p style="font-size:11px;color:var(--text-muted);margin:0 0 12px;">Export all chats as a ZIP (JSON + Markdown per chat).</p>' +
        '<div style="display:flex;flex-direction:column;gap:8px;">' +
        '<button class="action-btn" style="padding:8px 12px;font-size:12px;text-align:left;" onclick="_batchExportRun(\'project\')">' +
        '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">folder</span> Current project: <b>' + escHtml(proj) + '</b></button>' +
        '<button class="action-btn" style="padding:8px 12px;font-size:12px;text-align:left;" onclick="_batchExportRun(\'all\')">' +
        '<span class="material-symbols-rounded" style="font-size:14px;vertical-align:-2px;">cloud_download</span> All projects (full backup)</button>' +
        '</div></div>';
    document.body.appendChild(ov);
    ov.addEventListener('click', e => { if (e.target === ov) ov.remove(); });
}

function _batchExportRun(scope) {
    const ov = document.getElementById('batchexport-overlay');
    if (ov) ov.remove();
    let url;
    if (scope === 'all') {
        url = 'export.php?scope=all';
        appendSystem(T('msg.exporting.all.chats.across.all.projects.down', 'Exporting ALL chats across all projects — download should start.'));
    } else {
        const proj = currentProject || '_standalone';
        url = 'export.php?scope=project&project=' + encodeURIComponent(proj);
        appendSystem(T('msg.exporting.all.chats.in.proj.download.should', 'Exporting all chats in "{proj}" — download should start.', {proj: proj}));
    }
    const a = document.createElement('a');
    a.href = url;
    a.download = '';
    document.body.appendChild(a);
    a.click();
    setTimeout(() => a.remove(), 500);
}

// Handle file picker change for chat import
async function importChatFile(event) {
    const file = event.target.files?.[0];
    if (!file) return;
    event.target.value = '';   // reset so picking same file again triggers change

    // Ask user where to put it. Default: current project (or _standalone).
    const targetProject = await cprompt(
        'Import "' + file.name + '" into which project?\n\n' +
        'Type project name, or leave empty for _standalone:',
        (currentProject && currentProject !== '_standalone') ? currentProject : ''
    );
    if (targetProject === null) return;   // user cancelled
    const project = targetProject.trim() || '_standalone';

    await uploadImport(file, project, '', false);
}

async function uploadImport(file, project, chatName, overwrite) {
    const fd = new FormData();
    fd.append('file', file);
    fd.append('project',   project);
    fd.append('chat_name', chatName);
    if (overwrite) fd.append('overwrite', '1');

    appendSystem(T('msg.uploading.name.to.project.project', 'Uploading "{name}" to project "{project}"...', {name: file.name, project: project}));
    try {
        const res  = await fetch('import.php', { method:'POST', body: fd });
        const data = await res.json();
        if (data.ok) {
            appendSystem(T('msg.icon.check.imported.chat.into.project.exchan', '[[icon:check]] Imported "{chat}" into "{project}" — {exchangescount} exchanges.', {chat: data.chat, project: data.project, exchangescount: data.exchanges_count}));
            // Refresh sidebar lists so the new chat appears
            if (typeof loadChats === 'function')    loadChats();
            if (typeof loadProjects === 'function') loadProjects();
            return;
        }
        // Conflict — offer rename or overwrite
        if (data.conflict && data.suggested) {
            const ch = await cockpitChoice('Chat already exists', 'A chat named "' + chatName + '" already exists in "' + project + '".', [
                {label: 'Overwrite existing', value: 'overwrite', accent: 'var(--accent-orange)'},
                {label: 'Save as "' + data.suggested + '"', value: 'rename'}
            ]);
            if (ch === 'overwrite') {
                await uploadImport(file, project, chatName || file.name.replace(/\.(zip|json)$/i,''), true);
            } else if (ch === 'rename') {
                await uploadImport(file, project, data.suggested, false);
            }
            return;
        }
        appendError(T('msg.import.failed.error', 'Import failed: {error}', {error: (data.error || 'unknown error')}));
    } catch(e) {
        appendError(T('msg.import.failed.message', 'Import failed: {message}', {message: e.message}));
    }
}

async function moveChatToProject(chatSlug, fromProject) {
    const res0 = await fetch('files.php?action=projects');
    const d0   = await res0.json();
    if (!d0.ok || !d0.projects.length) { appendSystem(T('msg.no.projects.to.move.to', 'No projects to move to.')); return; }
    const names = d0.projects.map(p => p.name);
    const target = await cprompt('Move to project:\n' + names.join('\n'));
    if (!target || !names.includes(target)) return;

    // Does this chat carry accumulated cost? If so, ask Transfer / Reset / Cancel.
    let costMode = 'transfer';
    try {
        const cr = await fetch('stats.php?action=get&project=' + encodeURIComponent(fromProject) + '&chat=' + encodeURIComponent(chatSlug));
        const cd = await cr.json();
        const c  = cd.ok ? cd.chat : null;
        if (c && ((c.tin + c.tout) > 0 || c.usd > 0)) {
            costMode = await _askCostMove(c, target);   // 'transfer' | 'reset' | null(cancel)
            if (costMode === null) { appendSystem(T('msg.move.cancelled', 'Move cancelled.')); return; }
        }
    } catch (e) {}

    const res = await fetch('files.php', {
        method: 'POST', headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'move_chat', project:fromProject, target, chat:chatSlug})
    });
    const data = await res.json();
    if (!data.ok) { appendError(T('msg.move.failed.error', 'Move failed: {error}', {error: (data.error || 'unknown')})); return; }
    // Migrate the cost ledger to match the chosen mode.
    try {
        await fetch('stats.php?action=move_chat', { method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({ from_project: fromProject, to_project: target, slug: chatSlug, mode: costMode }) });
    } catch (e) {}
    appendSystem(T('msg.chat.moved.to.project.target.cost.costmode', 'Chat moved to project: {target} (cost {costmode}).', {target: target, costmode: costMode}));
    loadChats(); loadProjects();
    if (typeof costLoadForChat === 'function') costLoadForChat();
}

// Styled Transfer/Reset/Cancel modal for chat-cost migration. Resolves to the
// chosen mode ('transfer'|'reset') or null (cancel).
function _askCostMove(cost, target) {
    return new Promise(resolve => {
        document.getElementById('cost-move-modal')?.remove();
        const tok = (cost.tin || 0) + (cost.tout || 0);
        const usd = (cost.usd || 0) > 0 ? ' · $' + (+cost.usd).toFixed(cost.usd < 1 ? 4 : 2) : '';
        const ov = document.createElement('div');
        ov.id = 'cost-move-modal';
        ov.style.cssText = 'position:fixed;inset:0;z-index:10002;background:rgba(0,0,0,0.6);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);';
        ov.innerHTML =
            '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(460px,92vw);padding:18px 22px;box-shadow:0 8px 32px rgba(0,0,0,0.6);">' +
            '<h2 style="margin:0 0 10px 0;font-size:14px;color:var(--gemini);">Move chat cost?</h2>' +
            '<p style="font-size:12px;color:var(--text-base);line-height:1.55;margin:0 0 8px 0;">This chat has accumulated <b>' +
                (typeof _fmtK === 'function' ? _fmtK(tok) : tok) + ' tokens' + usd + '</b>. What should happen to it when moving to <b>' + escHtml(target) + '</b>?</p>' +
            '<ul style="font-size:11px;color:var(--text-muted);margin:0 0 14px 18px;padding:0;">' +
                '<li><b>Transfer</b> — the cost follows the chat into ' + escHtml(target) + '.</li>' +
                '<li><b>Reset</b> — chat starts at $0 in ' + escHtml(target) + '; the old project loses it.</li>' +
            '</ul>' +
            '<div style="display:flex;gap:8px;justify-content:flex-end;">' +
                '<button class="action-btn" id="cm-cancel" style="padding:5px 14px;">Cancel</button>' +
                '<button class="action-btn" id="cm-reset" style="padding:5px 14px;">Reset</button>' +
                '<button class="action-btn agent-claude" id="cm-transfer" style="padding:5px 16px;">Transfer</button>' +
            '</div></div>';
        document.body.appendChild(ov);
        const done = (v) => { ov.remove(); resolve(v); };
        ov.querySelector('#cm-cancel').onclick   = () => done(null);
        ov.querySelector('#cm-reset').onclick     = () => done('reset');
        ov.querySelector('#cm-transfer').onclick  = () => done('transfer');
        ov.addEventListener('click', e => { if (e.target === ov) done(null); });
    });
}

// Detach an owned chat back to Free
async function detachChat(chatSlug, fromProject) {
    if (!await cockpitConfirm('Detach chat?', 'Detach "' + chatSlug + '" from project "' + fromProject + '" and move to Free?', 'Detach', {icon:'link_off'})) return;
    const res = await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'move_chat', project:fromProject, target:'_standalone', chat:chatSlug})
    });
    const data = await res.json();
    if (data.ok) {
        appendSystem(T('msg.chat.detached.to.free', 'Chat detached to Free.'));
        loadChats(); loadProjects();
    }
}

// Keep newChat as alias for backward compatibility
async function newChat() { return newFreeChat(); }

async function deleteChat(chatName, projectName) {
    if (!await cockpitConfirm('Remove chat?', 'Remove chat "' + chatName + '"? This cannot be undone.', 'Remove', {danger:true, icon:'delete'})) return;
    const proj = projectName || currentProject;
    const _r = await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'delete', project:proj,
            path:'chat_' + chatName + '.json'})
    });
    const _d = await _r.json().catch(() => ({ok:false}));
    if (!_d.ok) { appendSystem(_d.message || T('msg.could.not.delete.chat', 'Could not delete chat.')); return; }  // e.g. last-chat guard
    // B5: also clean the per-chat contexts dir so attachments don't linger
    try {
        await fetch('attachments.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({action:'clear', project:proj, chat:chatName})
        });
    } catch(e) { /* non-fatal — contexts dir may not exist */ }
    if (currentChat === chatName) {
        currentChat = 'default';
        consoleBox.innerHTML = '';
        appendSystem(T('msg.chat.deleted.starting.fresh', 'Chat deleted. Starting fresh.'));
        // Phase 2b: load default chat's saved style (or fall back to 'build')
        if (typeof loadStyleForCurrentChat === 'function') {
            loadStyleForCurrentChat();
        }
    }
    loadChats();
}

async function renameChat(oldName, projectName, nameEl) {
    const input = document.createElement('input');
    input.className = 'sb-rename-input';
    input.value = nameEl.textContent;
    nameEl.replaceWith(input);
    input.focus(); input.select();
    let cancelled = false;
    const commit = async () => {
        if (cancelled) { loadChats(); return; }   // Esc: leave the name as it was
        const newName = input.value.trim() || oldName;
        const res = await fetch('files.php', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({action:'rename_chat',
                project: projectName || currentProject,
                old:oldName, new:newName})
        });
        const d = await res.json().catch(() => ({ok:false}));
        if (!d.ok && d.message) appendSystem(d.message);   // e.g. name already taken
        // renaming the chat you are IN: the slug (file name) changed, so the working state and the header must follow
        if (d.ok && d.slug && d.slug !== oldName && (projectName || currentProject) === currentProject && currentChat === oldName) {
            currentChat = d.slug;
            if (typeof updateStatusbarPath === 'function') updateStatusbarPath(currentProject, currentChat);
        }
        loadChats(); loadProjects();
    };
    input.addEventListener('blur', commit);
    input.addEventListener('keydown', e => {
        if (e.key === 'Enter') { e.preventDefault(); input.blur(); }
        if (e.key === 'Escape') { cancelled = true; e.stopPropagation(); input.blur(); }
    });
}

// =============================================================================
// PROJECTS — load, switch, new
// =============================================================================
async function loadProjects() {
    const list = document.getElementById('projects-list');
    if (!list) return;
    list.innerHTML = '<div class="sidebar-empty">Loading...</div>';
    try {
        const res  = await fetch('files.php?action=projects');
        const data = await res.json();
        if (!data.ok || !data.projects.length) {
            list.innerHTML = '<div class="sidebar-empty">No projects found.</div>';
            return;
        }
        list.innerHTML = '';
        data.projects.forEach(p => {
            const wrap = document.createElement('div');

            // Project row
            const div = document.createElement('div');
            div.className = 'sb-item' + (p.active ? ' active' : '');
            div.title = p.modified + ' · ' + p.chats.length + ' chats' + (p.description ? '\n' + p.description : '');
            wrap.dataset.filterText = (p.name + ' ' + (p.description || '') + ' ' + p.chats.map(x => (x.display || x.slug) + ' ' + (x.description || '')).join(' ')).toLowerCase();
            div.innerHTML =
                '<span class="material-symbols-rounded sb-item-icon" id="proj-icon-' +
                    escHtml(p.name) + '">folder</span>' +
                '<div class="sb-item-body">' +
                    '<div class="sb-item-name">' + escHtml(p.name) + '</div>' +
                    '<div class="sb-item-meta">' + p.chats.length + ' chat' +
                        (p.chats.length!==1?'s':'') + ' · ' + escHtml(p.modified) + '</div>' +
                    (p.description ? '<div class="sb-item-desc" title="' + escHtml(p.description) + '">' + escHtml(p.description) + '</div>' : '') +
                '</div>' +
                '<span class="material-symbols-rounded mini-ctrl proj-delete-btn" style="color:var(--text-base);" ' +
                    'title="Delete this project and all its chats">delete</span>' +
                '<span class="material-symbols-rounded mini-ctrl" style="color:var(--text-base);">chevron_right</span>';

            // Bind delete via JS closure (NOT inline onclick): embedding the
            // raw project name in an HTML attribute lets the JS parser
            // re-interpret backslash sequences like "פ" back into real
            // Unicode, so a click on a corrupted "פ..." row would target
            // the REAL Hebrew project. Closing over p.name avoids that entirely.
            const _delBtn = div.querySelector('.proj-delete-btn');
            if (_delBtn) _delBtn.addEventListener('click', e => {
                e.stopPropagation();
                deleteProject(p.name);
            });

            // Expandable sub-panel — class swaps based on active state
            const sub = document.createElement('div');
            sub.className = p.active ? 'sb-active-section' : 'sb-inactive-section';
            sub.style.display = 'none';

            // Config files
            if (p.configs && p.configs.length) {
                const cfHdr = document.createElement('div');
                cfHdr.className = 'sb-section-hdr';
                cfHdr.style.cssText = 'padding:4px 8px 2px;font-size:9.5px;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;';
                cfHdr.textContent = T('msg.config', 'Config');
                sub.appendChild(cfHdr);
                p.configs.forEach(cf => {
                    const cfDiv = document.createElement('div');
                    cfDiv.className = 'ft-item';
                    cfDiv.style.fontSize = '10.5px';
                    cfDiv.innerHTML =
                        '<span class="material-symbols-rounded" style="font-size:11px;">description</span>' +
                        escHtml(cf.name);
                    sub.appendChild(cfDiv);
                });
            }

            // Chats header + New Chat button
            const chHdrRow = document.createElement('div');
            chHdrRow.className = 'sb-section-hdr';
            chHdrRow.style.cssText = 'display:flex;align-items:center;padding:4px 8px 2px;';
            chHdrRow.innerHTML =
                '<span style="font-size:9.5px;color:var(--text-muted);text-transform:uppercase;letter-spacing:0.05em;flex:1;">Chats</span>' +
                '<span class="material-symbols-rounded mini-ctrl proj-newchat-btn" style="color:var(--text-base);" ' +
                    'title="New chat in this project">add</span>';
            const _newChatBtn = chHdrRow.querySelector('.proj-newchat-btn');
            if (_newChatBtn) _newChatBtn.addEventListener('click', e => {
                e.stopPropagation();
                newProjectChat(p.name);
            });
            sub.appendChild(chHdrRow);

            // Chats under this project — with Detach button. Show ALL chats
            // (including brand-new empty ones) so the list matches the header
            // count and every chat is visible + selectable.
            const shownChats = p.chats;
            if (shownChats.length) {
                shownChats.forEach(c => {
                    // Use buildChatItem with showMove=false (Detach button)
                    const chatData = {
                        slug: c.slug, display: c.display, project: p.name,
                        exchanges: c.exchanges, updated: c.updated,
                        last_agent: '', configs: [],
                        active: (p.name === currentProject && c.slug === currentChat)
                    };
                    const cItem = buildChatItem(chatData, { showMove: false });
                    cItem.style.paddingLeft = '4px';
                    sub.appendChild(cItem);
                });
            } else {
                const empty = document.createElement('div');
                empty.style.cssText = 'font-size:10px;color:var(--text-muted);padding:4px 10px;font-style:italic;';
                empty.textContent = T('msg.no.chats.yet', 'No chats yet');
                sub.appendChild(empty);
            }

            // Toggle expand on click — swap section class to reflect active state
            div.addEventListener('click', () => {
                const isOpen = sub.style.display !== 'none';
                sub.style.display = isOpen ? 'none' : 'block';
                const icon = document.getElementById('proj-icon-' + p.name);
                if (icon) icon.textContent = isOpen ? 'folder' : 'folder_open';
                const chev = div.querySelector('span:last-child');
                if (chev) chev.style.transform = isOpen ? '' : 'rotate(90deg)';

                // Visual distinction: expanding a project makes ITS section active,
                // and the project row itself gets the accent border
                if (!isOpen) {
                    // Demote any other open section to inactive
                    document.querySelectorAll('#projects-list .sb-active-section')
                        .forEach(s => { if (s !== sub) s.className = 'sb-inactive-section'; });
                    // Demote any other project row's accent
                    document.querySelectorAll('#projects-list .sb-item-with-section')
                        .forEach(s => s.classList.remove('sb-item-with-section'));
                    sub.className = 'sb-active-section';
                    div.classList.add('sb-item-with-section');
                    switchToProject(p.name);
                }
            });

            // Auto-expand active project
            if (p.active) {
                sub.style.display = 'block';
                const icon = document.getElementById('proj-icon-' + p.name);
                if (icon) icon.textContent = T('msg.folder.open', 'folder_open');
            }

            wrap.appendChild(div);
            wrap.appendChild(sub);
            list.appendChild(wrap);
        });
        sidebarFilter('projects-list');
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Error loading projects.</div>';
    }
}

async function switchToProject(projectName) {
    // Land on the project's most-recent chat, not a phantom "default". Projects
    // always have at least one chat now; if somehow empty, make a Welcome.
    let slug = null;
    try {
        const r = await fetch('files.php?action=chats');
        const d = await r.json();
        if (d && d.ok) {
            const sec = (d.sections || []).find(s => s.project === projectName);
            if (sec && sec.chats && sec.chats.length) slug = sec.chats[0].slug;  // sorted newest-first
        }
    } catch(e) {}
    if (!slug) {
        try {
            const cr = await fetch('files.php', { method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'new_chat', project:projectName, name:'Welcome', intro:_PROJECT_CHAT_INTRO}) });
            const cd = await cr.json();
            if (cd && cd.ok) slug = cd.slug;
        } catch(e) {}
    }
    if (slug) {
        await switchToChat(slug, projectName);   // handles set_active, history load, style, path
        appendSystem(T('msg.switched.to.project.projectname', 'Switched to project: {projectname}', {projectname: projectName}));
        loadProjects(); loadFileTree(); focusPromptDeferred();
        return;
    }
    // Last-resort fallback (should not happen).
    currentProject = projectName; currentChat = 'default';
    localStorage.setItem('cockpit_last_project', currentProject);
    updateStatusbarPath(projectName, 'default');
    loadProjects(); loadFileTree();
}

async function newProject() {
    if (!ckOnce('newProject', 1500)) return;       // a double click opened two name dialogs
    const name = await cprompt('Project name (leave blank for auto-name):');
    if (name === null) return;   // Cancel / Esc / click outside = no project
    const finalName = name.trim() || 'New Project';
    // The goal travels with the project and is prepended to every prompt in it —
    // asked here because the moment of creation is when you know why (2026-09-22).
    const goalAns = await cprompt('Project goal — one sentence, sent with every prompt (optional):', '', finalName);
    if (goalAns === null) return;   // Cancel at the goal step also cancels (blank + OK = no goal)
    const goal = goalAns || '';
    const res  = await fetch('files.php', {
        method: 'POST',
        headers: {'Content-Type':'application/json'},
        body: JSON.stringify({action:'new_project', name:finalName, goal:goal.trim()})
    });
    const data = await res.json();
    if (data.ok) {
        // Every new project starts with a "Welcome" chat carrying the project
        // intro, so it's never empty. Then land on it.
        let welcomeSlug = null;
        try {
            const cr = await fetch('files.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({action:'new_chat', project:data.name, name:'Welcome', intro:_PROJECT_CHAT_INTRO})
            });
            const cd = await cr.json();
            if (cd && cd.ok) welcomeSlug = cd.slug;
        } catch(e) {}
        if (welcomeSlug) await switchToChat(welcomeSlug, data.name);
        else await switchToProject(data.name);
        loadProjects();
    }
}

