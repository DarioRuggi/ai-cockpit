// B3 — Attachments panel: list, view, delete, clear-all
// =============================================================================
async function attachPanelRefresh() {
    const list = document.getElementById('rp-list-attachments');
    const cnt  = document.getElementById('attach-panel-count');
    if (!list) return;
    const proj = currentProject || '_standalone';
    const chat = currentChat    || 'default';
    list.innerHTML = '<div class="sidebar-empty">Loading…</div>';
    try {
        const r = await fetch('attachments.php?action=list&project=' +
            encodeURIComponent(proj) + '&chat=' + encodeURIComponent(chat));
        const d = await r.json();
        if (!d.ok) throw new Error(d.error || 'list failed');
        if (cnt) cnt.textContent = (d.count || 0) + ' file' + (d.count===1?'':'s');
        const items = d.attachments || [];
        if (items.length === 0) {
            list.innerHTML = '<div class="sidebar-empty">No attachments for this chat.<br>' +
                'Use the paperclip on the prompt bar to attach files.</div>';
            return;
        }
        // kind → icon (using existing material symbols vocabulary)
        const iconMap = {
            text:'description', image:'image', audio:'music_note', video:'movie',
            document:'article', subtitle:'subtitles', archive:'folder_zip'
        };
        list.innerHTML = '';
        items.forEach(it => {
            const row = document.createElement('div');
            row.className = 'rp-cfg-file exists';
            row.style.cssText = 'padding:6px 8px;margin-bottom:4px;';
            const sizeKB = Math.round((it.size||0)/1024);
            const ts = it.created ? new Date(it.created) : null;
            const tsStr = ts ? (fmtDate(ts) + ' ' + fmtTime(ts)) : '';
            // H2: inline thumbnail for image attachments (browser-scaled preview
            // via the view endpoint — no extra thumbnail file needed)
            let thumbHtml = '';
            if (it.kind === 'image') {
                const thumbUrl = 'attachments.php?action=view&project=' +
                    encodeURIComponent(proj) + '&chat=' + encodeURIComponent(chat) +
                    '&filename=' + encodeURIComponent(it.filename);
                thumbHtml = '<img src="' + thumbUrl + '" loading="lazy" ' +
                    'style="max-width:100%;max-height:120px;border-radius:3px;margin-top:4px;' +
                    'border:1px solid var(--border-dim);object-fit:contain;" alt="' + escHtml(it.filename) + '">';
            }
            row.innerHTML =
                '<div style="display:flex;align-items:center;gap:6px;">' +
                '<span class="material-symbols-rounded" style="font-size:14px;opacity:0.75;">' +
                escHtml(iconMap[it.kind] || 'insert_drive_file') + '</span>' +
                '<span style="flex:1;font-family:var(--font-mono);font-size:10.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="' +
                escHtml(it.filename) + '">' + escHtml(it.filename) + '</span>' +
                '<span class="rp-cfg-pill" style="font-size:9px;background:var(--bg-darker,var(--bg-codeblock));padding:1px 5px;border-radius:8px;">' +
                escHtml(it.kind || '?') + '</span>' +
                '</div>' +
                thumbHtml +
                '<div style="display:flex;align-items:center;gap:6px;margin-top:3px;font-size:9.5px;color:var(--text-muted);">' +
                '<span>' + sizeKB + ' KB</span>' +
                (tsStr ? '<span>· ' + escHtml(tsStr) + '</span>' : '') +
                '<span style="flex:1;"></span>' +
                '<button class="rp-action-btn" data-act="view" title="Open in new tab">View</button>' +
                '<button class="rp-action-btn" data-act="attach" title="Re-attach to prompt">↗ Attach</button>' +
                '<button class="rp-action-btn" data-act="del" title="Delete this attachment">×</button>' +
                '</div>';
            row.addEventListener('click', async e => {
                const act = e.target.dataset?.act;
                if (!act) return;
                if (act === 'view') {
                    const url = 'attachments.php?action=view&project=' +
                        encodeURIComponent(proj) + '&chat=' + encodeURIComponent(chat) +
                        '&filename=' + encodeURIComponent(it.filename);
                    window.open(url, '_blank');
                } else if (act === 'attach') {
                    // Inject a reference into the prompt (no re-upload needed)
                    promptInput.value = (promptInput.value || '') +
                        (promptInput.value ? '\n' : '') +
                        '[Attached ' + (it.kind||'file') + ': ' + it.filename + ']\n' +
                        '[Path: ' + (it.path || '') + ']\n';
                    promptInput.focus();
                    appendSystem(T('msg.re.attached.filename', 'Re-attached: {filename}', {filename: it.filename}));
                } else if (act === 'del') {
                    if (!await cockpitConfirm('Delete attachment?', 'Delete "' + it.filename + '"?', 'Delete', {danger:true, icon:'delete'})) return;
                    const rd = await fetch('attachments.php', {
                        method:'POST', headers:{'Content-Type':'application/json'},
                        body: JSON.stringify({action:'delete', project:proj, chat:chat, filename:it.filename})
                    });
                    const dd = await rd.json();
                    if (!dd.ok) { appendError(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (dd.error||'')})); return; }
                    attachPanelRefresh();
                }
            });
            list.appendChild(row);
        });
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Error: ' + escHtml(e.message) + '</div>';
    }
}

async function attachPanelClearAll() {
    const proj = currentProject || '_standalone';
    const chat = currentChat    || 'default';
    if (!await cockpitConfirm('Delete all attachments?', 'Delete ALL attachments for chat "' + chat + '"? This cannot be undone.', 'Delete All', {danger:true, icon:'delete_sweep'})) return;
    try {
        const r = await fetch('attachments.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({action:'clear', project:proj, chat:chat})
        });
        const d = await r.json();
        if (Array.isArray(d.rag) && d.rag.length && typeof appendSystem === 'function') {
            appendSystem(T('msg.icon.menu.book.rag.added.n.itemn2.from.your', '[[icon:menu_book]] RAG added {n} item{n2} from your library: {n3}', {n: d.rag.length, n2: (d.rag.length > 1 ? 's' : ''), n3: d.rag.join(' \u00b7 ')}));
        }
        if (!d.ok) { appendError(T('msg.clear.failed.error', 'Clear failed: {error}', {error: (d.error||'')})); return; }
        appendSystem(T('msg.all.attachments.cleared', 'All attachments cleared.'));
        attachPanelRefresh();
    } catch(e) { appendError(T('msg.clear.failed.message', 'Clear failed: {message}', {message: e.message})); }
}

function _renderUsagePanel(d, range, list) {
    if (!list) return;
    const rangeLabel = {today:'Today',week:'This week',month:'This month',all:'All time'}[range] || range;
    let html = '';

    // ── CLAUDE ────────────────────────────────────────────────────────────────
    const c = d.claude || {};
    html += `<div style="margin-bottom:10px;">
        <div style="font-size:10px;font-weight:700;color:var(--claude);
                    text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px;">
            <span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">star</span>
            Claude Code — ${rangeLabel}
        </div>`;
    if ((c.messages||0) === 0) {
        html += `<div style="font-size:10px;color:var(--text-dim);">No Claude usage in this range.</div>`;
    } else {
        const pct = Math.min(100, Math.round((c.total_tokens||0) / 44000 * 100));
        html += `
        <div style="font-size:10px;color:var(--text-dim);margin-bottom:3px;">
            ${c.sessions||0} sessions · ${c.messages||0} messages
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:3px;font-size:10px;margin-bottom:5px;">
            <div style="color:var(--text-dim);">Input:</div>
            <div style="color:var(--text-base);text-align:right;">${c.input_fmt||0}</div>
            <div style="color:var(--text-dim);">Output:</div>
            <div style="color:var(--text-base);text-align:right;">${c.output_fmt||0}</div>
            <div style="color:var(--text-dim);">Cache write:</div>
            <div style="color:var(--text-base);text-align:right;">${c.cache_create_fmt||0}</div>
            <div style="color:var(--text-dim);">Cache read:</div>
            <div style="color:var(--accent-cyan);text-align:right;">${c.cache_read_fmt||0}
                ${c.cache_savings_pct > 0 ? '<span style="font-size:9px;opacity:.7;">('+c.cache_savings_pct+'% saved)</span>' : ''}
            </div>
            <div style="color:var(--text-dim);">Total:</div>
            <div style="color:var(--text-primary);text-align:right;font-weight:600;">${c.total_tokens_fmt||0}</div>
        </div>
        <div style="background:var(--bg-darker);border-radius:3px;height:5px;overflow:hidden;">
            <div style="background:var(--claude);height:100%;width:${pct}%;transition:width .3s;"></div>
        </div>
        <div style="font-size:9px;color:var(--text-dim);text-align:right;margin-top:2px;">
            ${pct}% of ~44K 5-hour window
        </div>`;
    }
    html += `</div>`;

    // ── GEMINI ────────────────────────────────────────────────────────────────
    const g = d.gemini || {};
    html += `<div style="margin-bottom:10px;padding-top:8px;border-top:1px solid var(--border-dim);">
        <div style="font-size:10px;font-weight:700;color:var(--gemini);
                    text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px;">
            <span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">add</span>
            Gemini CLI — ${rangeLabel}
        </div>`;
    if ((g.messages||0) === 0) {
        html += `<div style="font-size:10px;color:var(--text-dim);">No Gemini usage in this range.</div>`;
    } else {
        html += `
        <div style="font-size:10px;color:var(--text-dim);margin-bottom:3px;">
            ${g.sessions||0} sessions · ${g.messages||0} messages
        </div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:3px;font-size:10px;margin-bottom:4px;">
            <div style="color:var(--text-dim);">Input:</div>
            <div style="color:var(--text-base);text-align:right;">${g.input_fmt||0}</div>
            <div style="color:var(--text-dim);">Output:</div>
            <div style="color:var(--text-base);text-align:right;">${g.output_fmt||0}</div>
            <div style="color:var(--text-dim);">Cached:</div>
            <div style="color:var(--accent-cyan);text-align:right;">${g.cached_fmt||0}</div>
            <div style="color:var(--text-dim);">Thoughts:</div>
            <div style="color:var(--text-base);text-align:right;">${g.thoughts_fmt||0}</div>
            <div style="color:var(--text-dim);">Total:</div>
            <div style="color:var(--text-primary);text-align:right;font-weight:600;">${g.total_fmt||0}</div>
        </div>
        <div style="font-size:9px;color:var(--text-dim);font-style:italic;">${g.cost_note||''}</div>`;
    }
    html += `</div>`;

    // ── OLLAMA ────────────────────────────────────────────────────────────────
    const o = d.ollama || {};
    html += `<div style="margin-bottom:10px;padding-top:8px;border-top:1px solid var(--border-dim);">
        <div style="font-size:10px;font-weight:700;color:var(--ollama);
                    text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px;">
            <span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">pets</span>
            Ollama — ${rangeLabel}
        </div>`;
    if (o.note) {
        html += `<div style="font-size:10px;color:var(--text-dim);">${escHtml(o.note)}</div>`;
    } else if ((o.calls||0) === 0) {
        html += `<div style="font-size:10px;color:var(--text-dim);">No Ollama usage in this range.</div>`;
    } else {
        const ctxPct = Math.min(100, Math.round((o.prompt_tokens||0) / (o.context_window||32768) * 100));
        html += `
        <div style="font-size:10px;color:var(--text-dim);margin-bottom:3px;">${o.calls||0} calls · avg ${o.avg_ms||0}ms</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:3px;font-size:10px;margin-bottom:5px;">
            <div style="color:var(--text-dim);">Prompt:</div>
            <div style="color:var(--text-base);text-align:right;">${o.prompt_tokens_fmt||0}</div>
            <div style="color:var(--text-dim);">Output:</div>
            <div style="color:var(--text-base);text-align:right;">${o.output_tokens_fmt||0}</div>
        </div>
        <div style="background:var(--bg-darker);border-radius:3px;height:5px;overflow:hidden;">
            <div style="background:var(--ollama);height:100%;width:${ctxPct}%;transition:width .3s;"></div>
        </div>
        <div style="font-size:9px;color:var(--text-dim);text-align:right;margin-top:2px;">
            ~${ctxPct}% of ${(o.context_window/1024).toFixed(0)}K context window
        </div>`;
        if (Object.keys(o.by_model||{}).length > 0) {
            html += `<div style="font-size:9px;color:var(--text-dim);margin-top:4px;">`;
            for (const [mdl, stats] of Object.entries(o.by_model)) {
                html += `<div>${escHtml(mdl)}: ${stats.calls} calls</div>`;
            }
            html += `</div>`;
        }
    }
    html += `</div>`;

    // ── PAID API SPEND ──────────────────────────────────────────────────────
    const ps = d.paid_spend || {};
    const globalUsd = ps.global_usd || 0;
    const globalCap = ps.global_cap || 0;
    const byModel = ps.by_model || {};
    const modelCaps = ps.per_model_caps || {};
    if (globalUsd > 0 || globalCap > 0 || Object.keys(byModel).length > 0) {
        const gPct = globalCap > 0 ? Math.min(100, Math.round(globalUsd / globalCap * 100)) : 0;
        const gBar = gPct > 80 ? 'var(--accent-orange)' : 'var(--accent-amber)';
        html += `<div style="margin-bottom:10px;padding-top:8px;border-top:1px solid var(--border-dim);">
            <div style="font-size:10px;font-weight:700;color:var(--accent-amber);
                        text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px;">
                <span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">paid</span>
                Paid API spend (monthly)
            </div>
            <div style="display:grid;grid-template-columns:1fr 1fr;gap:3px;font-size:10px;margin-bottom:5px;">
                <div style="color:var(--text-dim);">Total spend:</div>
                <div style="color:var(--accent-amber);text-align:right;font-weight:600;">$${globalUsd.toFixed(4)}</div>
                ${globalCap > 0 ? `<div style="color:var(--text-dim);">Global cap:</div>
                <div style="color:var(--text-base);text-align:right;">$${globalCap.toFixed(2)}</div>` : ''}
            </div>`;
        if (globalCap > 0) {
            html += `<div style="background:var(--bg-darker);border-radius:3px;height:5px;overflow:hidden;">
                <div style="background:${gBar};height:100%;width:${gPct}%;transition:width .3s;"></div>
            </div>
            <div style="font-size:9px;color:var(--text-dim);text-align:right;margin-top:2px;">${gPct}% of cap</div>`;
        }
        if (Object.keys(byModel).length > 0) {
            html += `<div style="font-size:9px;color:var(--text-dim);margin-top:6px;">`;
            for (const [mk, usd] of Object.entries(byModel)) {
                const mc = (modelCaps[mk] || 0);
                const mPct = mc > 0 ? Math.round(usd / mc * 100) : 0;
                html += `<div style="display:flex;justify-content:space-between;padding:1px 0;">
                    <span>${escHtml(mk)}</span>
                    <span>$${usd.toFixed(4)}${mc > 0 ? ' / $' + mc.toFixed(2) + ' (' + mPct + '%)' : ''}</span>
                </div>`;
            }
            html += `</div>`;
        }
        html += `</div>`;
    }

    // ── WORKERS (FREE TIERS) ─────────────────────────────────────────────────
    const w = d.workers?.providers || {};
    const provKeys = Object.keys(w);
    html += `<div style="padding-top:8px;border-top:1px solid var(--border-dim);">
        <div style="font-size:10px;font-weight:700;color:var(--workers);
                    text-transform:uppercase;letter-spacing:.06em;margin-bottom:5px;">
            <span class="material-symbols-rounded" style="font-size:12px;vertical-align:-2px;">cloud</span>
            Workers (free tiers)
        </div>`;
    if (provKeys.length === 0) {
        html += `<div style="font-size:10px;color:var(--text-dim);">No workers configured.</div>`;
    } else {
        for (const prov of provKeys) {
            const p = w[prov];
            const cpct = p.calls_pct || 0;
            const barColor = cpct > 85 ? 'var(--accent-orange)' : cpct > 60 ? 'var(--accent-amber)' : 'var(--accent-cyan)';
            html += `
            <div style="margin-bottom:6px;">
                <div style="display:flex;justify-content:space-between;font-size:10px;margin-bottom:2px;">
                    <span style="color:var(--text-base);font-weight:600;">${escHtml(p.name||prov)}</span>
                    <span style="color:var(--text-dim);font-size:9px;">resets in ${escHtml(p.reset_in||'?')}</span>
                </div>
                <div style="display:flex;justify-content:space-between;font-size:9px;
                            color:var(--text-dim);margin-bottom:2px;">
                    <span>${p.calls_used||0} / ${p.calls_limit||'∞'} calls</span>
                    <span>${cpct}%</span>
                </div>
                <div style="background:var(--bg-darker);border-radius:3px;height:4px;overflow:hidden;">
                    <div style="background:${barColor};height:100%;width:${cpct}%;transition:width .3s;"></div>
                </div>
            </div>`;
        }
    }
    html += `</div>`;

    list.innerHTML = html;
}

// Auto-refresh usage panel when it's active (every 60s)
setInterval(() => {
    const panel = document.getElementById('right-usage');
    if (panel && panel.classList.contains('active')) usageParserRefresh();
}, 60000);
//   { ok: true,
//     server_time: <ISO>,
//     rows: [
//       { provider, name, kind, anchor, last_verified_at, verified_age_days,
//         free_models: [{id, label}, ...],
//         usage: {calls, errors, tokens_in, tokens_out, last_call_at, last_reset_at, by_kind},
//         quota?: {rpd, rpm, tpm, used_today, remaining_rpd,
//                  cycle_resets_at, seconds_to_reset, per_model, shared_across_models}
//       }, ... ]
//   }
// =============================================================================

let _usageLastRows = null;       // last successful payload — for offline display
let _usageRefreshing = false;    // re-entry guard

async function usageRefresh() {
    if (_usageRefreshing) return;
    _usageRefreshing = true;
    try {
        const r = await fetch('workers.php?action=usage_with_quota');
        const d = await r.json();
        if (!d.ok) {
            usageRender(null, 'Failed to load: ' + (d.error || 'unknown'));
            return;
        }
        _usageLastRows = d.rows || [];
        usageRender(d, null);
        usageUpdateInlineIndicator(_usageLastRows);
    } catch(e) {
        usageRender(null, 'Network error: ' + e.message);
    } finally {
        _usageRefreshing = false;
    }
}

// Format seconds-until-reset as "Nh Mm" or "Md Nh" depending on scale.
function _usageFormatCountdown(secs) {
    if (secs == null || secs < 0) return '—';
    if (secs < 60)        return secs + 's';
    if (secs < 3600)      return Math.floor(secs/60) + 'm';
    if (secs < 86400)     return Math.floor(secs/3600) + 'h ' + Math.floor((secs%3600)/60) + 'm';
    return Math.floor(secs/86400) + 'd ' + Math.floor((secs%86400)/3600) + 'h';
}

// Pick a CSS modifier class for the quota bar based on % used.
// >85% → danger, >65% → warn, else default.
function _usageBarClass(used, limit) {
    if (!limit || limit <= 0) return '';
    const pct = used / limit;
    if (pct >= 0.85) return 'danger';
    if (pct >= 0.65) return 'warn';
    return '';
}

// Render the side-panel content from the latest payload. `errMsg` non-null
// means the fetch failed; we show last-known data with an error caption if
// available, otherwise just the error.
function usageRender(payload, errMsg) {
    const list = document.getElementById('rp-list-usage');
    if (!list) return;

    const rows  = (payload && payload.rows) || _usageLastRows;
    const stamp = document.getElementById('usage-server-time');
    if (stamp && payload && payload.server_time) {
        stamp.textContent = 'updated ' + fmtTime(new Date(payload.server_time));
    }

    if (!rows || rows.length === 0) {
        list.innerHTML = '<div class="sidebar-empty">' +
            (errMsg ? escHtml(errMsg) :
             'No enabled workers. Configure providers via the Workers card → settings.') +
            '</div>';
        return;
    }

    // Split into FREE TIER (quota tracking) and CONSUMPTION (credit-based).
    // Daily-request providers go in FREE TIER; consumption_only providers
    // go in CONSUMPTION. Both sections always render (with empty state if
    // no rows match).
    const quotaRows   = rows.filter(r => r.kind === 'daily_requests');
    const consumeRows = rows.filter(r => r.kind === 'consumption_only');

    let html = '';
    if (errMsg) {
        html += '<div class="sidebar-empty" style="color:var(--accent-amber,#e0b84e);font-size:9.5px;">' +
                escHtml(errMsg) + ' (showing last known data)</div>';
    }

    // ── MAIN AGENTS (Claude / Gemini / Ollama) ──
    // 2026-05-09 (Pass 2): show the per-card token data also in the side
    // panel, so opening the panel gives a unified view of EVERYTHING the
    // cockpit is tracking — not just workers. Data source is the same
    // `usageStats` object that drives the inline meters on each card,
    // persisted in localStorage.cockpit_usage. Numbers are estimated
    // (Claude window-based, Gemini daily, Ollama session-based) and
    // rendered with the same caveat captions as the cards themselves.
    html += '<div class="usage-section-hdr">Main agents · this cycle</div>';
    html += _usageRenderMainAgentsSection();

    // ── FREE TIER ──
    html += '<div class="usage-section-hdr">Workers · free tier daily quotas</div>';
    if (quotaRows.length === 0) {
        html += '<div class="sidebar-empty" style="font-size:9.5px;padding:6px 10px;">' +
                'No quota-tracked workers enabled.</div>';
    } else {
        for (const row of quotaRows) html += _usageRenderQuotaRow(row);
    }

    // ── CONSUMPTION ──
    html += '<div class="usage-section-hdr">Workers · credit-based consumption</div>';
    if (consumeRows.length === 0) {
        html += '<div class="sidebar-empty" style="font-size:9.5px;padding:6px 10px;">' +
                'No credit-based workers enabled.</div>';
    } else {
        for (const row of consumeRows) html += _usageRenderConsumeRow(row);
    }

    list.innerHTML = html;
}

// Pass 2 — render Claude/Gemini/Ollama using the same data the per-card
// meters use. Each row mirrors the visual structure of the worker rows
// but reads from `usageStats` (localStorage) instead of workers.php data.
function _usageRenderMainAgentsSection() {
    if (typeof usageStats !== 'object' || !usageStats) {
        return '<div class="sidebar-empty" style="font-size:9.5px;padding:6px 10px;">' +
               'Local usage data not yet available.</div>';
    }

    const now = Date.now();
    let html = '';

    // ── Claude ── 5-hour window, ~44K token cap (per Anthropic Claude Code)
    const cTok    = (usageStats.claude && usageStats.claude.tokens) || 0;
    const cMax    = (typeof CLAUDE_TOKEN_MAX !== 'undefined') ? CLAUDE_TOKEN_MAX : 44000;
    const cPct    = Math.min(100, Math.round(cTok / cMax * 100));
    const cBarCls = _usageBarClass(cTok, cMax);
    let cReset    = '—';
    if (usageStats.claude && usageStats.claude.windowStart && typeof CLAUDE_WINDOW_MS !== 'undefined') {
        const msLeft = (usageStats.claude.windowStart + CLAUDE_WINDOW_MS) - now;
        cReset = (typeof fmtRemaining === 'function') ? fmtRemaining(msLeft) : '—';
    }
    html += `<div class="usage-row" style="cursor:pointer;" onclick="openUsageDetailModal('claude')" title="Click for in-depth Claude usage">
        <div class="usage-row-head">
            <span class="usage-row-name" style="color:var(--claude);">Claude</span>
            <span class="usage-row-meta">${cTok.toLocaleString()} / ~${(cMax/1000).toFixed(0)}K tok</span>
        </div>
        <div class="usage-row-bar">
            <span class="usage-row-bar-fill ${cBarCls}" style="width:${cPct}%;background:var(--claude);"></span>
        </div>
        <div class="usage-row-footer">
            <span>5-hour window resets in ${cReset}</span>
        </div>
    </div>`;

    // ── Gemini ── daily reset at midnight local
    const gCalls  = (usageStats.gemini && usageStats.gemini.calls)  || 0;
    const gTok    = (usageStats.gemini && usageStats.gemini.tokens) || 0;
    const gMax    = 500;  // arbitrary daily call ceiling for visualization
    const gPct    = Math.min(100, Math.round(gCalls / gMax * 100));
    const gBarCls = _usageBarClass(gCalls, gMax);
    const midnight = new Date(); midnight.setHours(24, 0, 0, 0);
    const gReset = (typeof fmtRemaining === 'function')
                       ? fmtRemaining(midnight - now) : '—';
    html += `<div class="usage-row" style="cursor:pointer;" onclick="openUsageDetailModal('gemini')" title="Click for in-depth Gemini usage">
        <div class="usage-row-head">
            <span class="usage-row-name" style="color:var(--gemini);">Gemini</span>
            <span class="usage-row-meta">${gCalls} calls · ~${gTok.toLocaleString()} tok</span>
        </div>
        <div class="usage-row-bar">
            <span class="usage-row-bar-fill ${gBarCls}" style="width:${gPct}%;background:var(--gemini);"></span>
        </div>
        <div class="usage-row-footer">
            <span>Daily window resets in ${gReset}</span>
        </div>
    </div>`;

    // ── Ollama ── session-based (no quota, just consumption display)
    const oCalls = (usageStats.ollama && usageStats.ollama.calls)     || 0;
    const oTok   = (usageStats.ollama && usageStats.ollama.tokens)    || 0;
    const oTime  = (usageStats.ollama && usageStats.ollama.totalTime) || 0;
    const oTimeStr = (typeof fmtTime === 'function') ? fmtTime(oTime) : (oTime + 'ms');
    html += `<div class="usage-row" style="cursor:pointer;" onclick="openUsageDetailModal('ollama')" title="Click for in-depth Ollama usage">
        <div class="usage-row-head">
            <span class="usage-row-name" style="color:var(--ollama);">Ollama</span>
            <span class="usage-row-meta">${oCalls} calls · ~${oTok.toLocaleString()} tok · ${oTimeStr}</span>
        </div>
        <div class="usage-row-footer" style="color:var(--text-muted);font-style:italic;">
            <span>Local — no external quota</span>
        </div>
    </div>`;

    return html;
}

// ─────────────────────────────────────────────────────────────────────────
// In-depth usage detail modal — opened by clicking a Main-agents usage row.
// Combines live client-side usageStats with the latest server parser data
// (usage_parser.php) so the modal shows everything the cockpit tracks for
// one agent: input/output/cache breakdown, window/reset, and source notes.
// ─────────────────────────────────────────────────────────────────────────
function _closeUsageDetailModal() {
    const m = document.getElementById('usage-detail-modal');
    if (m) m.remove();
    document.removeEventListener('keydown', _usageModalEsc);
}
function _usageModalEsc(e) { if (e.key === 'Escape') _closeUsageDetailModal(); }

async function openUsageDetailModal(agent) {
    _closeUsageDetailModal();

    let server = {};
    try {
        const r = await fetch('usage_parser.php?action=all&range=today');
        server = await r.json();
    } catch(e) { /* offline — fall back to client only */ }

    const accent = { claude:'var(--accent-amber)', gemini:'var(--accent-blue)', ollama:'var(--accent-cyan)' }[agent] || 'var(--text-muted)';
    const body = _buildUsageDetailBody(agent, server);

    const modal = document.createElement('div');
    modal.id = 'usage-detail-modal';
    modal.style.cssText =
        'position:fixed;inset:0;z-index:99999;display:flex;align-items:center;' +
        'justify-content:center;background:rgba(0,0,0,.6);';
    modal.addEventListener('click', e => { if (e.target === modal) _closeUsageDetailModal(); });

    modal.innerHTML =
        '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;' +
        'min-width:340px;max-width:480px;max-height:80vh;overflow:auto;padding:14px 18px;' +
        'box-shadow:0 8px 32px rgba(0,0,0,.6);font-size:12px;color:var(--text-base);">' +
        '<div style="display:flex;align-items:center;justify-content:space-between;' +
        'margin-bottom:12px;padding-bottom:8px;border-bottom:1px solid var(--border-dim);">' +
        '<span style="font-weight:700;font-size:14px;color:' + accent + ';text-transform:capitalize;">' +
        agent + ' — usage detail</span>' +
        '<button id="usage-detail-close" ' +
        'style="background:none;border:none;color:var(--text-base);font-size:22px;cursor:pointer;' +
        'line-height:1;padding:0 4px;">&times;</button>' +
        '</div><div id="usage-detail-content">' + body + '</div></div>';

    document.body.appendChild(modal);
    document.getElementById('usage-detail-close').addEventListener('click', _closeUsageDetailModal);
    document.addEventListener('keydown', _usageModalEsc);
}

function _buildUsageDetailBody(agent, server) {
    const row = (label, val, color) =>
        '<div style="display:flex;justify-content:space-between;padding:3px 0;' +
        'border-bottom:1px solid var(--border-dim,#2a2d34);">' +
        '<span style="color:var(--text-dim);">' + label + '</span>' +
        '<span style="color:' + (color || 'var(--text-base)') + ';font-weight:600;">' + val + '</span></div>';
    const note = txt =>
        '<div style="margin-top:10px;font-size:10px;font-style:italic;color:var(--text-muted);">' + txt + '</div>';

    if (agent === 'claude') {
        const s = (server && server.claude) || {};
        const cl = usageStats.claude || {};
        const inT  = (s.input  || 0) || (cl.input  || 0);
        const outT = (s.output || 0) || (cl.output || 0);
        const total = inT + outT;
        let reset = '—';
        if (cl.windowStart) {
            const rem = CLAUDE_WINDOW_MS - (Date.now() - cl.windowStart);
            if (rem > 0) reset = fmtRemaining(rem);
        }
        return row('Input tokens', inT.toLocaleString()) +
               row('Output tokens', outT.toLocaleString()) +
               row('Cache read', (s.cache_read || 0).toLocaleString(), 'var(--accent-cyan)') +
               row('Cache write', (s.cache_create || 0).toLocaleString()) +
               row('Total tokens', total.toLocaleString(), 'var(--claude)') +
               row('Sessions', String(s.sessions || 0)) +
               row('Messages', String(s.messages || 0)) +
               row('5h window resets in', reset) +
               note((s.input || s.output) ? 'Source: server parser (~/.claude logs).'
                                          : 'Source: live in-session estimate (server logs unreadable).');
    }
    if (agent === 'gemini') {
        const s = (server && server.gemini) || {};
        const gl = usageStats.gemini || {};
        const inT  = (s.input  || 0) || (gl.input  || 0);
        const outT = (s.output || 0) || (gl.output || 0);
        return row('Input tokens', inT.toLocaleString()) +
               row('Output tokens', outT.toLocaleString()) +
               row('Cached', (s.cached || 0).toLocaleString(), 'var(--accent-cyan)') +
               row('Thoughts', (s.thoughts || 0).toLocaleString()) +
               row('Calls today', String(gl.calls || 0)) +
               row('Sessions', String(s.sessions || 0)) +
               row('Messages', String(s.messages || 0)) +
               note((s.input || s.output) ? 'Source: server parser.'
                                          : 'Source: live in-session estimate. Resets daily at midnight.');
    }
    // ollama
    const s = (server && server.ollama) || {};
    const ol = usageStats.ollama || {};
    return row('Prompt tokens', (s.prompt_tokens || ol.input || 0).toLocaleString()) +
           row('Output tokens', (s.output_tokens || ol.output || 0).toLocaleString()) +
           row('Calls', String(s.calls || ol.calls || 0)) +
           row('Avg latency', (s.avg_ms || 0) + ' ms') +
           row('Total time', fmtTime(ol.totalTime || 0)) +
           note('Local model — no external quota. Session-based counters.');
}

function _usageRenderQuotaRow(row) {
    const q     = row.quota || {};
    const used  = q.used_today  || 0;
    const limit = q.rpd         || 0;
    const pct   = limit > 0 ? Math.min(100, (used / limit) * 100) : 0;
    const barCls = _usageBarClass(used, limit);
    const cd    = _usageFormatCountdown(q.seconds_to_reset);
    const stale = (row.verified_age_days != null && row.verified_age_days > 30);
    const verifyMeta = (row.last_verified_at
        ? 'verified ' + row.verified_age_days + 'd ago'
        : 'never verified');

    const tokens = (row.usage.tokens_in + row.usage.tokens_out).toLocaleString();
    const sharedHint = q.shared_across_models
        ? '<span style="opacity:0.7;font-style:italic;"> · shared pool</span>' : '';

    return '<div class="usage-row usage-quota">' +
      '<div class="usage-row-head">' +
        '<span class="usage-row-name">' + escHtml(row.name) + '</span>' +
        '<span class="usage-row-meta' + (stale ? ' stale' : '') + '" title="Last verified: ' +
            escHtml(row.last_verified_at || 'never') + '">' +
            escHtml(verifyMeta) + '</span>' +
      '</div>' +
      '<div class="usage-row-stats">' +
        '<span><b>' + used + '</b> / ' + (limit || '?') + ' req' + sharedHint + '</span>' +
        '<span>resets in <b>' + cd + '</b></span>' +
      '</div>' +
      '<div class="usage-bar-wrap"><div class="usage-bar-fill ' + barCls +
        '" style="width:' + pct + '%;"></div></div>' +
      '<div class="usage-row-stats">' +
        '<span>' + tokens + ' tokens</span>' +
        '<span>' + row.free_model_count + ' free model' +
          (row.free_model_count === 1 ? '' : 's') + '</span>' +
      '</div>' +
      '<div class="usage-row-actions">' +
        '<button onclick="usageResetProvider(\'' + escAttr(row.provider) + '\')" ' +
                'title="Zero this provider\'s counters. Doesn\'t affect the actual cycle reset on the provider side.">Reset</button>' +
        '<button onclick="usageEditQuota(\'' + escAttr(row.provider) + '\')" ' +
                'title="Edit the quota config (limits, anchor, model overrides)">Edit quota</button>' +
      '</div>' +
    '</div>';
}

function _usageRenderConsumeRow(row) {
    const tokens = (row.usage.tokens_in + row.usage.tokens_out).toLocaleString();
    const stale = (row.verified_age_days != null && row.verified_age_days > 30);
    const verifyMeta = (row.last_verified_at
        ? 'verified ' + row.verified_age_days + 'd ago'
        : 'never verified');
    const lastReset = row.usage.last_reset_at
        ? fmtDate(new Date(row.usage.last_reset_at))
        : '—';

    return '<div class="usage-row usage-consume">' +
      '<div class="usage-row-head">' +
        '<span class="usage-row-name">' + escHtml(row.name) + '</span>' +
        '<span class="usage-row-meta' + (stale ? ' stale' : '') + '">' +
            escHtml(verifyMeta) + '</span>' +
      '</div>' +
      '<div class="usage-row-stats">' +
        '<span><b>' + (row.usage.calls || 0) + '</b> calls</span>' +
        '<span><b>' + tokens + '</b> tokens</span>' +
      '</div>' +
      '<div class="usage-row-stats" style="margin-top:3px;">' +
        '<span style="font-style:italic;opacity:0.8;">credit-based — see provider for balance</span>' +
        '<span>since ' + lastReset + '</span>' +
      '</div>' +
      '<div class="usage-row-actions">' +
        '<button onclick="usageResetProvider(\'' + escAttr(row.provider) + '\')" ' +
                'title="Zero this provider\'s consumption counter">Reset</button>' +
      '</div>' +
    '</div>';
}

// Update the inline indicator on the Workers supplier card to show the
// most-throttled current state (lowest % remaining among enabled providers).
// Falls back to the existing aggregate view if no quota-tracked providers
// are enabled.
function usageUpdateInlineIndicator(rows) {
    if (!rows || rows.length === 0) return;
    const quotaRows = rows.filter(r => r.kind === 'daily_requests' && r.quota);
    if (quotaRows.length === 0) return;

    // Find the row with the highest % used (most-throttled)
    let worst = null, worstPct = -1;
    for (const r of quotaRows) {
        const used = r.quota.used_today || 0;
        const limit = r.quota.rpd || 0;
        if (limit > 0) {
            const pct = used / limit;
            if (pct > worstPct) { worst = r; worstPct = pct; }
        }
    }
    if (!worst) return;

    const cv = document.getElementById('workers-calls-val');
    const pv = document.getElementById('workers-providers-val');
    if (cv) {
        cv.textContent = worst.name + ': ' + (worst.quota.used_today || 0) +
                         '/' + (worst.quota.rpd || '?') + ' req';
    }
    if (pv) {
        pv.textContent = 'resets in ' + _usageFormatCountdown(worst.quota.seconds_to_reset);
    }
}

// Reset a single provider's counters (zero in place; provider's actual
// daily reset is handled separately by the provider on midnight UTC).
async function usageResetProvider(pid) {
    if (!await cockpitConfirm('Reset usage?', 'Reset usage counters for "' + pid + '"?\n\nThis zeroes the cockpit-side counter for this provider. The actual free-tier quota on the provider\'s side resets on its own schedule.', 'Reset', {danger:true, icon:'restart_alt'})) return;
    try {
        const r = await fetch('workers.php?action=reset_usage', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid}),
        });
        const d = await r.json();
        if (d.ok) {
            appendSystem(T('msg.usage.counter.reset.for.pid', 'Usage counter reset for {pid}', {pid: pid}));
            usageRefresh();
        } else {
            appendError(T('msg.reset.failed.error', 'Reset failed: {error}', {error: (d.error || 'unknown')}));
        }
    } catch(e) {
        appendError(T('msg.reset.error.message', 'Reset error: {message}', {message: e.message}));
    }
}

// Reset ALL providers — single backend call (vs old workersResetAllUsage
// which iterated client-side). Faster, atomic-ish.
async function usageResetAll() {
    if (!await cockpitConfirm('Reset all usage?', 'Reset usage counters for ALL providers?\n\nThis is cosmetic — actual provider-side quotas remain whatever they are. Confirm to zero cockpit\'s tracking.', 'Reset All', {danger:true, icon:'restart_alt'})) return;
    try {
        const r = await fetch('workers.php?action=reset_all_usage', {method:'POST'});
        const d = await r.json();
        if (d.ok) {
            appendSystem(T('msg.all.workers.usage.counters.reset.resetcount', 'All workers usage counters reset ({resetcount} provider{resetcount2})', {resetcount: (d.reset_count || 0), resetcount2: ((d.reset_count === 1) ? '' : 's')}));
            usageRefresh();
        } else {
            appendError(T('msg.reset.all.failed.error', 'Reset all failed: {error}', {error: (d.error || 'unknown')}));
        }
    } catch(e) {
        appendError(T('msg.reset.all.error.message', 'Reset all error: {message}', {message: e.message}));
    }
}

// Edit-quota dialog — opens a small prompt-based editor. Could be a proper
// modal in v2; for now a sequence of prompts gets the job done with no new
// modal HTML/CSS. The user edits raw JSON for the provider's quota block.
async function usageEditQuota(pid) {
    try {
        // Fetch current config: easiest is to read the latest rows and find this provider
        const row = (_usageLastRows || []).find(r => r.provider === pid);
        if (!row) {
            appendError(T('msg.cannot.find.current.quota.for.pid', 'Cannot find current quota for {pid}', {pid: pid}));
            return;
        }
        // Build a JSON skeleton from what we have. We re-derive what we know;
        // the user can paste a more complete config if they want.
        const current = {
            kind: row.kind,
            anchor: row.anchor,
            last_verified_at: row.last_verified_at,
            models: (row.quota && row.quota.per_model) || {},
        };
        const edited = await cprompt(
            'Edit quota config for "' + pid + '" (JSON):\n\n' +
            'Tip: keep the structure — kind, anchor, models. The "*" entry under ' +
            '"models" is the wildcard fallback. Numbers are RPD (requests per day), ' +
            'TPM (tokens per minute), RPM (requests per minute).',
            JSON.stringify(current, null, 2)
        );
        if (!edited) return;

        let parsed;
        try { parsed = JSON.parse(edited); }
        catch(e) { appendError(T('msg.invalid.json.message', 'Invalid JSON: {message}', {message: e.message})); return; }

        const r = await fetch('workers.php?action=update_quota', {
            method: 'POST',
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({provider: pid, config: parsed}),
        });
        const d = await r.json();
        if (d.ok) {
            appendSystem(T('msg.quota.config.updated.for.pid', 'Quota config updated for {pid}', {pid: pid}));
            usageRefresh();
        } else {
            appendError(T('msg.quota.update.failed.error', 'Quota update failed: {error}', {error: (d.error || 'unknown')}));
        }
    } catch(e) {
        appendError(T('msg.edit.quota.error.message', 'Edit quota error: {message}', {message: e.message}));
    }
}

// Hook into the existing 4-second status poll. This piggybacks on the
// refreshStatus interval set up earlier so we don't add yet another timer.
// The first call happens shortly after page load via the refreshStatus
// init at the bottom of this script.
setTimeout(() => usageRefresh(), 1500);
setInterval(() => usageRefresh(), 4000);

// Tiny attribute-escape helper used in inline onclick strings above
function escAttr(s) {
    return String(s).replace(/['"<>&]/g, c =>
        ({'\'':'&#39;','"':'&quot;','<':'&lt;','>':'&gt;','&':'&amp;'}[c]));
}

// ─── sendToWorker — submit prompt to selected worker, render response ──────
//
// Called from sendToOne when agent === 'workers'. Behaves like sendToOne but
// dispatches to workers.php?action=invoke instead of bridge.php.
// Task kind of the worker preset currently selected ('text' when unknown).
function workersSelectedTask() {
    const v = document.getElementById('workers-model')?.value || '';
    if (!v || v === '__cascade__') return 'text';
    const meta = (_workersModels || []).find(m => m.value === v);
    return ((meta && meta.kinds) || ['text'])[0];
}
// The pictures attached since the last send, as the Anthropic API wants them ({media_type, data: base64}). Each is fetched from the attachment store; one over 3.5 MB is left out and said so
// (the API's limit is 5 MB of base64). The list is always emptied, so a picture never rides on a later message by accident.
async function _nativeImagesForRequest(useThem) {
    const pending = (typeof takePendingNativeImages === 'function') ? takePendingNativeImages() : [];
    if (!useThem || !pending.length) return [];
    const out = [];
    for (const it of pending.slice(0, 5)) {
        try {
            const r = await fetch('attachments.php?action=view&project=' + encodeURIComponent(it.project) + '&chat=' + encodeURIComponent(it.chat) + '&filename=' + encodeURIComponent(it.filename));
            if (!r.ok) throw new Error('HTTP ' + r.status);
            const b = await r.blob(), mt = (b.type || '').split(';')[0];
            if (!/^image\/(png|jpeg|gif|webp)$/.test(mt)) { appendSystem(T('msg.native.type', '{f}: this picture type cannot be sent as an image.', { f: it.filename })); continue; }
            if (b.size > 3.5 * 1024 * 1024) { appendSystem(T('msg.native.big', '{f} is over 3.5 MB: left out (the API takes at most 5 MB per image). Shrink it with the Image tools.', { f: it.filename })); continue; }
            const data = await new Promise((res, rej) => { const fr = new FileReader(); fr.onload = () => res(String(fr.result).split(',')[1] || ''); fr.onerror = () => rej(fr.error); fr.readAsDataURL(b); });
            out.push({ media_type: mt, data: data });
        } catch (e) { appendSystem(T('msg.native.fail', 'Could not attach {f}: {e}', { f: it.filename, e: e.message })); }
    }
    return out;
}
async function sendToWorker(text, cavemanEligible = true) {
    const sel = document.getElementById('workers-model');
    const value = sel ? sel.value : '';
    if (!value) {
        appendError(T('msg.no.worker.model.selected.configure.providers', 'No worker model selected. Configure providers via the WORKERS settings button.'));
        return null;
    }
    if (value === '__cascade__') return sendToWorkerCascade(text, cavemanEligible);
    const [provider, ...modelParts] = value.split(':');
    const model = modelParts.join(':');
    if (!provider || !model) {
        appendError(T('msg.invalid.worker.selection.value', 'Invalid worker selection: {value}', {value: value}));
        return null;
    }
    // Find the model meta to know its kinds
    const meta = _workersModels.find(m => m.value === value);
    const kinds = (meta && meta.kinds) || ['text'];
    // Default task = first kind
    const task = kinds[0];

    setLoading(true);
    // (sendPrompt already rendered the [DARIO] bubble; this path used to add a second one)
    const placeholderId = 'msg-worker-' + Date.now();
    appendMsg('worker', 'WORKERS · ' + (meta?.label || value), 'worker',
              '⏳ Calling ' + provider + '...', new Date(), '', '', placeholderId);
    const bodyEl = document.getElementById(placeholderId)?.querySelector('.msg-body');

    // Global directives: prepend ONLY for text tasks. Image/audio/video tasks
    // must receive the raw prompt — a directive preamble would corrupt them.
    let promptToSend = text;
    if (task === 'text') {
        // Caveman compression (Workers is an online supplier) — text tasks only.
        if (cavemanState && cavemanEligible) {
            const cv = await cavemanCompress(promptToSend);
            promptToSend = cv.text;
            if (cv.note) appendSystem(cv.note);
        }
        try {
            const pre = await _directivePreamble('workers');
            if (pre) promptToSend = pre + promptToSend;
        } catch (e) {}
    }

    const nativeImages = await _nativeImagesForRequest(provider === 'anthropic' && task === 'text');
    try {
        const _ac = new AbortController();
        var _fid = inflightAdd('worker', (meta?.label || value), async () => _ac.abort(), { warnAfterMs: 120000 });
        const r = await fetch('workers.php?action=invoke', {
            method: 'POST', signal: _ac.signal,
            headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                provider, model, task, prompt: promptToSend,
                extra: (nativeImages.length ? { images: nativeImages } : {}),
                // Chat context: the server gates + selects history from the chat
                // index and writes the exchange to this chat afterwards.
                project: currentProject, chat: currentChat, user_text: text,
                ma_mode: (typeof maMode !== 'undefined' ? maMode : ''), style: (typeof currentStyle !== 'undefined' ? currentStyle : ''),
                stream: task === 'text',   // asks for a stream; the server streams when the provider can (Anthropic and the OpenAI-compatible ones) and answers in one piece otherwise
            }),
        });
        let d;
        if ((r.headers.get('content-type') || '').includes('text/event-stream') && r.body) {
            const rd = r.body.getReader(), dec = new TextDecoder(); let buf = '', acc = '';
            for (;;) {
                const { value, done } = await rd.read(); if (done) break;
                buf += dec.decode(value, { stream: true }); let i;
                while ((i = buf.indexOf('\n\n')) >= 0) {
                    const line = buf.slice(0, i).trim(); buf = buf.slice(i + 2);
                    if (!line.startsWith('data:') || line === 'data: [DONE]') continue;
                    try { const j = JSON.parse(line.slice(5)); if (j.chunk) { acc += j.chunk; if (bodyEl) bodyEl.textContent = acc; } else if (j.final) d = j.final; } catch (e) {}
                }
            }
            if (!d) d = { ok: false, error: T('msg.worker.stream.cut', 'the answer stream ended before it was complete') };
        } else d = await r.json();
        if (!d.ok) {
            if (bodyEl) bodyEl.textContent = '[ERROR] ' + (d.error || 'unknown');
            appendError(T('msg.worker.call.failed.error', 'Worker call failed: {error}', {error: (d.error || 'unknown')}));
            return null;
        }
        // Cost tiers: record this worker turn (tokens + real $ for paid providers).
        if (typeof costRecordTurn === 'function')
            costRecordTurn(d.tokens_in || 0, d.tokens_out || 0, d.cost_usd || 0);
        _checkSpendWarnings(d);
        // Render — text inline, image as <img>, audio as <audio>
        if (bodyEl) {
            if (d.kind === 'image' && d.output.startsWith('data:image')) {
                bodyEl.innerHTML = '';
                const img = document.createElement('img');
                img.src = d.output;
                img.style.cssText = 'max-width:100%;max-height:600px;border-radius:4px;';
                img.title = provider + ' · ' + model;
                bodyEl.appendChild(img);
            } else if (d.kind === 'image' && d.output.startsWith('http')) {
                bodyEl.innerHTML = '';
                const img = document.createElement('img');
                img.src = d.output;
                img.style.cssText = 'max-width:100%;max-height:600px;border-radius:4px;';
                bodyEl.appendChild(img);
                const lnk = document.createElement('div');
                lnk.style.cssText = 'font-size:9.5px;color:var(--text-muted);margin-top:4px;';
                lnk.innerHTML = '<a href="' + d.output + '" target="_blank">Open image</a>';
                bodyEl.appendChild(lnk);
            } else if (d.kind === 'audio' && d.output.startsWith('data:audio')) {
                bodyEl.innerHTML = '';
                const audio = document.createElement('audio');
                audio.src = d.output;
                audio.controls = true;
                audio.style.cssText = 'max-width:100%;';
                bodyEl.appendChild(audio);
            } else {
                bodyEl.textContent = d.output || '(empty)';
            }
        }
        appendSystem(T('msg.provider.model.done.elapsedmsmstokensin', '{provider} · {model} done ({elapsedms}ms{tokensin})', {provider: provider, model: model, elapsedms: (d.elapsed_ms||0), tokensin: (d.tokens_in ? ', '+d.tokens_in+' in / '+d.tokens_out+' out' : '')}));
        workersUpdateMeter();
        return d.output;
    } catch(e) {
        if (bodyEl) bodyEl.textContent = '[ERROR] ' + e.message;
        appendError(T('msg.worker.call.failed.message', 'Worker call failed: {message}', {message: e.message}));
        return null;
    } finally {
        if (typeof _fid !== 'undefined' && _fid) inflightDone(_fid);
        setLoading(false);
    }
}

// Auto (cascade) sender — server walks the priority list of free workers,
// advancing past any that are quota-exhausted or 429, and returns the first
// success (with served_by) or a summary when all are spent.
async function sendToWorkerCascade(text, cavemanEligible = true) {
    setLoading(true);
    // (sendPrompt already rendered the [DARIO] bubble; this path used to add a second one)
    const placeholderId = 'msg-worker-' + Date.now();
    appendMsg('worker', 'WORKERS · Auto (cascade)', 'worker', '⏳ Finding an available worker…', new Date(), '', '', placeholderId);
    const bodyEl = document.getElementById(placeholderId)?.querySelector('.msg-body');

    let promptToSend = text;
    if (cavemanState && cavemanEligible) {
        const cv = await cavemanCompress(promptToSend);
        promptToSend = cv.text;
        if (cv.note) appendSystem(cv.note);
    }
    try {
        const pre = await _directivePreamble('workers');
        if (pre) promptToSend = pre + promptToSend;
    } catch (e) {}

    try {
        const _ac = new AbortController();
        var _fid = inflightAdd('worker', 'Auto (cascade)', async () => _ac.abort(), { warnAfterMs: 120000 });
        const r = await fetch('workers.php?action=cascade_invoke', {
            method: 'POST', signal: _ac.signal, headers: {'Content-Type':'application/json'},
            body: JSON.stringify({ task: 'text', prompt: promptToSend, extra: {},
                                   project: currentProject, chat: currentChat, user_text: text }),
        });
        const d = await r.json();
        if (!d.ok) {
            const when = d.next_available_at ? (' Next worker frees up ' + new Date(d.next_available_at).toLocaleString() + '.') : '';
            const msg = (d.cascade_empty ? 'No free workers configured — add one in WORKERS settings.' : ('All workers exhausted for now.' + when));
            if (bodyEl) bodyEl.textContent = '[' + msg + ']';
            appendError(T('msg.cascade.msg', 'Cascade: {msg}', {msg: msg}));
            return null;
        }
        const skipped = (d.attempts || []).filter(a => a.skipped || a.failed).length;
        if (bodyEl) {
            if (d.kind === 'image' && String(d.output).startsWith('data:image')) {
                bodyEl.innerHTML = ''; const img = document.createElement('img');
                img.src = d.output; img.style.cssText = 'max-width:100%;max-height:600px;border-radius:4px;'; bodyEl.appendChild(img);
            } else {
                bodyEl.textContent = d.output || '(empty)';
            }
        }
        if (typeof costRecordTurn === 'function') costRecordTurn(d.tokens_in || 0, d.tokens_out || 0, d.cost_usd || 0);
        appendSystem(T('msg.served.by.servedbyskipped.elapsedmsmstokensi', 'Served by {servedby}{skipped} · {elapsedms}ms{tokensin}', {servedby: (d.served_by || (d.provider+':'+d.model)), skipped: (skipped ? (' (skipped ' + skipped + ' exhausted)') : ''), elapsedms: (d.elapsed_ms||0), tokensin: (d.tokens_in ? (', '+d.tokens_in+' in / '+d.tokens_out+' out') : '')}));
        workersUpdateMeter();
        return d.output;
    } catch(e) {
        if (bodyEl) bodyEl.textContent = '[ERROR] ' + e.message;
        appendError(T('msg.cascade.call.failed.message', 'Cascade call failed: {message}', {message: e.message}));
        return null;
    } finally {
        if (typeof _fid !== 'undefined' && _fid) inflightDone(_fid);
        setLoading(false);
    }
}

// =============================================================================
// TOOLS — local CLI binaries (ffmpeg, whisper, pandoc, etc.)
//
// 5th provider class. Pure local execution. No internet, no API keys, no
// usage tracking. The cockpit treats "tools" as an agent that, when active,
// shows a file-input modal instead of streaming text.
//
// Auto-route also supported: main agents emit %%TOOL:tool:preset:input%%
// markers, crud_executor.sh dispatches them via tools.php.
// =============================================================================

let _toolsPresets = [];      // populated from tools.php?action=presets
let _toolsActivePreset = null;   // captured when run modal opens

// Load preset list and populate the topbar selector
async function toolsLoadPresets() {
    try {
        const r = await fetch('tools.php?action=presets');
        const d = await r.json();
        const panel = document.getElementById('tools-panel');
        const hidden = document.getElementById('tools-preset');
        if (!panel) return;
        _toolsPresets = d.presets || [];
        if (!_toolsPresets.length) {
            panel.innerHTML = '<div class="cs-option disabled"><span class="cs-option-name">— no tools detected —</span></div>';
            if (hidden) hidden.value = '';
            document.getElementById('tools-selected-label').textContent = T('msg.no.tools.detected', '— no tools detected —');
            const btn = document.getElementById('btn-agent-tools');
            if (btn) btn.style.opacity = '0.5';
            toolsUpdateMeter();
            return;
        }
        const btn = document.getElementById('btn-agent-tools');
        if (btn) btn.style.opacity = '1';
        const byTool = {};
        for (const p of _toolsPresets) (byTool[p.tool] = byTool[p.tool] || []).push(p);
        let html = '';
        for (const [tid, presets] of Object.entries(byTool).sort((a, b) => a[1][0].label.split(' · ')[0].localeCompare(b[1][0].label.split(' · ')[0], undefined, { sensitivity: 'base', numeric: true }))) {
            presets.sort((a, b) => ((a.label.split(' · ')[1]||a.preset)).localeCompare(b.label.split(' · ')[1]||b.preset));
            const groupName = presets[0].label.split(' · ')[0];
            html += `<div class="cs-group-header" data-tier="${tid}">${groupName} <button type="button" class="cs-sort-combo" value="alpha" title="Sort this section: A to Z, or the order they were added" onclick="event.stopPropagation();csCycleSort(this,sortToolsTier)">A→Z</button></div>`;
            for (const p of presets) {
                const kindMark = ({
                    audio:'<span class="material-symbols-rounded ico">volume_up</span>', video:'<span class="material-symbols-rounded ico">movie</span>', text:'<span class="material-symbols-rounded ico">edit</span>', document:'<span class="material-symbols-rounded ico">description</span>',
                    image:'<span class="material-symbols-rounded ico">image</span>', subtitle:'⊟', 'image-sequence':'<span class="material-symbols-rounded ico">image</span>',
                }[p.output_kind] || '·');
                const label = (p.label.split(' · ')[1] || p.preset) +
                              (p.output_ext ? ' → .' + p.output_ext : '') + ' ' + kindMark;
                html += `<div class="cs-option" data-value="${p.value}" onclick="selectToolsPreset(this)"><span class="cs-option-name">${label}</span></div>`;
            }
        }
        panel.innerHTML = html;
        wireCollapsibleGroupHeaders('tools-panel');
        const saved = localStorage.getItem('cockpit_last_tools_preset') || hidden.value;
        const savedOpt = saved ? panel.querySelector(`.cs-option[data-value="${CSS.escape(saved)}"]`) : null;
        const pick = savedOpt || panel.querySelector('.cs-option:not(.disabled)');
        if (pick) {
            panel.querySelectorAll('.cs-option').forEach(o => o.classList.remove('selected'));
            pick.classList.add('selected');
            hidden.value = pick.dataset.value;
            document.getElementById('tools-selected-label').textContent = pick.querySelector('.cs-option-name').textContent.trim();
        }
        toolsUpdateMeter();
        if (typeof refreshSupplierLabels === 'function') refreshSupplierLabels();
    } catch(e) {
        console.warn('toolsLoadPresets failed:', e);
    }
}

async function toolsUpdateMeter() {
    try {
        const r = await fetch('tools.php?action=tools');
        const d = await r.json();
        if (!d.ok) return;
        const enabled  = (d.tools || []).filter(t => t.enabled && t.binary_available);
        const presets  = enabled.reduce((n, t) => n + (t.presets || []).length, 0);
        const cv = document.getElementById('tools-count-val');
        const pv = document.getElementById('tools-presets-val');
        const bar = document.getElementById('tools-bar');
        if (cv) { cv.textContent = enabled.length + ' tool' + (enabled.length === 1 ? '' : 's'); cv.title = enabled.length + ' of ' + ((d.tools || []).length) + ' tools are ready to use (turned on, and their program is installed here). The Tools window lists all of them.'; }
        if (pv) pv.textContent = presets + ' preset' + (presets === 1 ? '' : 's');
        // Bar shows enabled vs total
        if (bar) {
            const total = (d.tools || []).length || 1;
            bar.style.width = Math.min(100, (enabled.length / total) * 100) + '%';
        }
    } catch(e) {}
}

// Open the Tools settings modal
// =============================================================================
