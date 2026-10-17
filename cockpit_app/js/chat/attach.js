// =============================================================================
// attachFile — main pipeline. Saves to attachments.php, then routes.
// =============================================================================
async function attachFile(file, suggestedName) {
    const name = suggestedName || file.name || 'attachment';
    const route = resolveRoute(name);

    if (route.maxBytes && file.size > route.maxBytes) {
        appendError(T('msg.file.too.large.for.label.max.maxbytesmb.name', 'File too large for {label} (max {maxbytes}MB): {name}', {label: route.label, maxbytes: Math.round(route.maxBytes / (1024*1024)), name: name}));
        return;
    }

    // Show a pending status pill so the user sees something is happening
    const jobId = 'attach-' + Date.now() + '-' + Math.random().toString(36).slice(2,7);
    const pillId = _attachShowPending(name, route.label, jobId);

    try {
        // Step 1: upload to attachments.php
        const b64 = await _fileToBase64(file);
        const saveRes = await fetch('attachments.php', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action:   'save',
                project:  currentProject || '_standalone',
                chat:     currentChat    || 'default',
                filename: name,
                mime:     file.type || '',
                data_b64: b64,
            }),
        });
        const saved = await saveRes.json();
        if (!saved.ok) {
            _attachClearPending(pillId);
            appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (saved.error || 'unknown')}));
            return;
        }

        // Step 2: route based on plan
        await _attachDispatch(route, saved, file, name, pillId);
    } catch (err) {
        _attachClearPending(pillId);
        appendError(T('msg.attach.error.message', 'Attach error: {message}', {message: (err.message || err)}));
    }
}

// Shared routing for an already-saved attachment (used by browser upload + the
// server-file picker). fileObj only needs .text() (for inline-text route).
async function _attachDispatch(route, saved, fileObj, name, pillId) {
    switch (route.plan) {
        case 'inline-text':  await _attachInlineText(saved, fileObj, name, pillId); break;
        case 'tools-preset': await _attachRunTool(saved, route, name, pillId); break;
        case 'image-vision': await _attachImageVision(saved, name, pillId); break;
        case 'video-vision': await _attachVideoVision(saved, name, pillId); break;
        case 'save-only':
        default:
            _attachInjectReference(saved, name, route.label);
            _attachClearPending(pillId);
            appendSystem(T('msg.attached.label.filename.size.kb', 'Attached {label}: {filename} ({size} KB)', {label: route.label, filename: saved.filename, size: (saved.size < 10240 ? (Math.max(saved.size, 1) / 1024).toFixed(1) : Math.round(saved.size/1024))}));
            break;
    }
}

// Attach a file already on the server (picked via the Cockpit file picker).
async function attachServerFile(serverPath) {
    const name = serverPath.split('/').pop();
    const route = resolveRoute(name);
    const jobId = 'attach-' + Date.now() + '-' + Math.random().toString(36).slice(2,7);
    const pillId = _attachShowPending(name, route.label, jobId);
    try {
        const r = await fetch('attachments.php', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action:'ingest_path', path: serverPath,
                project: currentProject || '_standalone', chat: currentChat || 'default' }),
        });
        const saved = await r.json();
        if (!saved.ok) { _attachClearPending(pillId); appendError(T('msg.attach.failed.error', 'Attach failed: {error}', {error: (saved.error||'unknown')})); return; }
        if (route.maxBytes && saved.size > route.maxBytes) {
            _attachClearPending(pillId);
            appendError(T('msg.file.too.large.for.label.max.maxbytesmb.name', 'File too large for {label} (max {maxbytes}MB): {name}', {label: route.label, maxbytes: Math.round(route.maxBytes/(1024*1024)), name: name}));
            return;
        }
        // shim file: inline-text route reads .text(); server returned content for text files
        const fileObj = { name, size: saved.size, type: saved.mime || '',
            text: async () => (saved.content !== undefined ? saved.content : '') };
        await _attachDispatch(route, saved, fileObj, name, pillId);
    } catch (err) { _attachClearPending(pillId); appendError(T('msg.attach.error.message', 'Attach error: {message}', {message: (err.message || err)})); }
}

// Attach button → Cockpit server-file picker (no native browser dialog).
async function attachFromServer() {
    if (_inShell) {
        const paths = await shellPickFiles({ multiple: true, title: 'Attach files', dir: (currentProject ? _chatDir() : '') });
        if (paths) { for (const p of paths) attachServerFile(p); return; }
    }
    const p = await cockpitPathPicker({ mode:'open', title:'Attach a file', start:(currentProject? _chatDir():''),
        // Remote/SaaS users: pick a file from their own device. Routes through the
        // hidden #file-upload input → handleFileUpload (same path as drag/paste).
        onDeviceUpload: () => document.getElementById('file-upload')?.click() });
    if (p) attachServerFile(p);
}

// =============================================================================
// Plan handlers
// =============================================================================

// Inline-text — read the saved file via attachments.php?action=view, inject
async function _attachInlineText(saved, originalFile, name, pillId) {
    // B6: if file exceeds the inline threshold, switch to save-only with preview.
    const threshold = _inlineTextThreshold();
    if (saved.size > threshold) {
        const text = await originalFile.text();
        const preview = text.slice(0, 200) + (text.length > 200 ? '…' : '');
        _injectBlock('[Attached file (too large to inline): ' + saved.filename +
                     ' — ' + Math.round(saved.size/1024) + ' KB > ' +
                     Math.round(threshold/1024) + ' KB threshold]\n' +
                     '[Path: ' + saved.path + ']\n' +
                     '[Preview: ' + preview + ']\n\n');
        _attachClearPending(pillId);
        appendSystem(T('msg.attached.text.saved.not.inlined.filename.siz', 'Attached text (saved, not inlined): {filename} ({size} KB)', {filename: saved.filename, size: (saved.size < 10240 ? (Math.max(saved.size, 1) / 1024).toFixed(1) : Math.round(saved.size/1024))}));
        return;
    }
    // We already have the bytes in originalFile — read directly, no extra round-trip
    const text = await originalFile.text();
    _injectBlock('[Attached file: ' + saved.filename + ']\n' + text +
                 '\n[End of file]\n\n');
    _attachClearPending(pillId);
    appendSystem(T('msg.attached.text.filename.size.kb', 'Attached text: {filename} ({size} KB)', {filename: saved.filename, size: (saved.size < 10240 ? (Math.max(saved.size, 1) / 1024).toFixed(1) : Math.round(saved.size/1024))}));
}

// Tools-preset — call tools.php?action=run with the saved path
async function _attachRunTool(saved, route, name, pillId) {
    // Validate the preset exists; fall back to save-only with a hint
    const preset = _toolsPresets.find(p => p.value === route.preset);
    if (!preset) {
        _attachInjectReference(saved, name, route.label);
        // PDF Vision has nothing to do with the text preset, so a missing or
        // broken preset must not take it down with it. It used to sit only on
        // the success path below, which made it unreachable in precisely the
        // case it exists for: a scanned PDF, where extraction gives nothing.
        const _pv0 = await _attachPdfPagesIfPdf(saved, pillId);
        _attachClearPending(pillId);
        appendSystem(T('msg.attached.label.preset.preset.not.configured', 'Attached {label} (preset "{preset}" not configured — saved as reference): {filename}{pv0}', {label: route.label, preset: route.preset, filename: saved.filename, pv0: (_pv0 ? ' · ' + _pv0 + ' page(s) sent as images' : '')}));
        return;
    }

    _attachUpdatePending(pillId, 'Running ' + preset.tool + '…');
    try {
        const r = await fetch('tools.php?action=run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                tool:    preset.tool,
                preset:  preset.preset,
                input:   saved.path,
                project: currentProject || null,
                chat:    currentChat    || null,
            }),
        });
        const d = await r.json();
        if (!d.ok) {
            _attachInjectReference(saved, name, route.label);
            // Same reasoning as above: extraction failing is a REASON to look at
            // the pages, not a reason to skip looking at them.
            const _pv1 = await _attachPdfPagesIfPdf(saved, pillId);
            _attachClearPending(pillId);
            appendError(T('msg.tool.tool.failed.error.saved.as.referencepv1', 'Tool {tool} failed: {error} — saved as reference{pv1}.', {tool: preset.tool, error: (d.error || 'unknown'), pv1: (_pv1 ? ', ' + _pv1 + ' page(s) sent as images' : '')}));
            return;
        }

        // B2: If the tool produced text, inline it. Otherwise inject a reference
        // to the output path. Threshold (50 KB) keeps the prompt manageable.
        const INLINE_OUTPUT_THRESHOLD = 51200;
        if (d.output && /\.(txt|md|markdown|srt|vtt|json|jsonl|csv|tsv|log|html?|xml|ya?ml)$/i.test(d.output)) {
            let inlined = false;
            try {
                const r2 = await fetch('tools.php?action=read_output', {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({path: d.output}),
                });
                const d2 = await r2.json();
                if (d2.ok && typeof d2.content === 'string') {
                    if (d2.size <= INLINE_OUTPUT_THRESHOLD) {
                        _injectBlock('[Attached ' + route.label + ': ' + saved.filename +
                                     ' → processed by ' + preset.tool + ']\n' +
                                     '[Content (' + Math.round(d2.size/1024) + ' KB):]\n' +
                                     d2.content +
                                     '\n[End of content]\n\n');
                        inlined = true;
                    } else {
                        // Too big — inject path + first 1 KB preview
                        _injectBlock('[Attached ' + route.label + ': ' + saved.filename +
                                     ' → processed by ' + preset.tool + ']\n' +
                                     '[Output saved to: ' + d.output + ' (' + Math.round(d2.size/1024) + ' KB, too large to inline)]\n' +
                                     '[Preview:]\n' + d2.content.slice(0, 1024) + '\n[…]\n\n');
                        inlined = true;
                    }
                }
            } catch(e) { /* fall through to reference-only injection */ }
            if (!inlined) {
                _injectBlock('[Attached ' + route.label + ': ' + saved.filename +
                             ' → processed by ' + preset.tool + ']\n' +
                             '[Processed output saved to: ' + d.output + ']\n\n');
            }
        } else {
            _injectBlock('[Attached ' + route.label + ': ' + saved.filename + ']\n' +
                         '[Original saved at: ' + saved.path + ']\n' +
                         '[Processed by ' + preset.tool + ' → ' + d.output + ']\n\n');
        }
        // A PDF keeps its extracted text — that is the right primary source for
        // body text — but a page that is one chart extracts as an empty string.
        // With PDF Vision on, the first pages also go over as images.
        const _pv = await _attachPdfPagesIfPdf(saved, pillId);
        _attachClearPending(pillId);
        appendSystem(T('msg.processed.label.filename.via.tool.elapsedmsm', 'Processed {label}: {filename} via {tool} ({elapsedms}ms){pv}', {label: route.label, filename: saved.filename, tool: preset.tool, elapsedms: d.elapsed_ms, pv: (_pv ? ' · ' + _pv + ' page(s) also sent as images' : '')}));
    } catch (err) {
        _attachInjectReference(saved, name, route.label);
        _attachClearPending(pillId);
        appendError(T('msg.tool.dispatch.failed.message.saved.as.refere', 'Tool dispatch failed: {message} — saved as reference.', {message: err.message}));
    }
}

// Image vision — agent-aware dispatch:
//   - Claude   → hand it the PATH and let it look for itself (2026-09-23)
//   - Ollama / others → call vision:describe via tools.php, inline the result
//
// Until now every agent got the same thing: a paragraph written by the local
// vision model. That was correct when it was written — the CLIs could not be
// handed image data — but Claude Code reads image files with its own Read tool,
// so downgrading a paid model to a 4B describer's summary threw away exactly the
// detail people attach a screenshot for ("why is this button misaligned" cannot
// survive being turned into prose). Claude now gets the path; the local model
// stays the answer for everyone who cannot open a file themselves.
// Images the current turn should hand to the agent natively (paths only). The
// submit reads and clears this; agent_loop turns it into whatever that CLI wants.
let _pendingImages = [];
// Images handed to the worker's own API as image content (the Anthropic worker sees the picture itself, not a description of it): {filename, project, chat}
let _pendingNativeImages = [];
function takePendingNativeImages() { const p = _pendingNativeImages; _pendingNativeImages = []; return p; }
function takePendingImages() { const p = _pendingImages; _pendingImages = []; return p; }

/** What the ACTIVE card's agent can do with an image — from the catalog. */
function _imageModeForCurrentAgent() {
    if (typeof currentAgent === 'undefined') return 'describe';
    if (currentAgent === 'ollama') return 'describe';        // the vision model IS the local path
    if (currentAgent === 'workers' && /^anthropic:/.test(document.getElementById('workers-model')?.value || '')) return 'native';   // the Claude API takes image blocks
    const m = (window._slotImageMode || {})[currentAgent];
    return m || 'describe';
}

async function _attachImageVision(saved, name, pillId) {
    const mode = _imageModeForCurrentAgent();
    const kb = Math.round(saved.size / 1024);

    // 'path' — the agent opens the file itself (Claude Code's Read tool).
    if (mode === 'path') {
        _injectBlock('[Attached image: ' + saved.filename + ']\n' +
                     '[Path: ' + saved.path + ']\n' +
                     '[Open this file with your Read tool to look at it directly.]\n\n');
        _attachClearPending(pillId);
        appendSystem(T('msg.icon.visibility.filename.kb.kb.handed.to.the', '[[icon:visibility]] {filename} ({kb} KB) — handed to the agent directly; it opens the file itself.', {filename: saved.filename, kb: kb}));
        return;
    }
    // 'native' — the Anthropic worker: the picture goes to the API as an image block with the next send.
    if (mode === 'native') {
        _pendingNativeImages.push({ filename: saved.filename, project: (typeof currentProject === 'string' ? currentProject : ''), chat: (typeof currentChat === 'string' ? currentChat : '') });
        _injectBlock('[Attached image: ' + saved.filename + ']\n\n');
        _attachClearPending(pillId);
        appendSystem(T('msg.attach.native', '{filename} ({kb} KB): sent to the Claude API as an image with your next message.', { filename: saved.filename, kb: kb }));
        return;
    }
    // 'flag' — the path rides on the command line (codex --image FILE).
    if (mode === 'flag') {
        _pendingImages.push(saved.path);
        _injectBlock('[Attached image: ' + saved.filename + ']\n\n');
        _attachClearPending(pillId);
        appendSystem(T('msg.icon.visibility.filename.kb.kb.attached.to.t', '[[icon:visibility]] {filename} ({kb} KB) — attached to the agent\'s own image input.', {filename: saved.filename, kb: kb}));
        return;
    }
    // 'at' — @file reference the CLI expands itself (Gemini).
    if (mode === 'at') {
        _injectBlock('@' + saved.path + '\n[Attached image: ' + saved.filename + ']\n\n');
        _attachClearPending(pillId);
        appendSystem(T('msg.icon.visibility.filename.kb.kb.referenced.wi', '[[icon:visibility]] {filename} ({kb} KB) — referenced with @path for the agent to read.', {filename: saved.filename, kb: kb}));
        return;
    }
    // 'describe' — this agent cannot see images, so a local model writes what it
    // sees and THAT text is injected. Said plainly in the chat: the agent is
    // reading a description, not looking at the picture.
    _attachUpdatePending(pillId, 'Running vision…');
    try {
        const r = await fetch('tools.php?action=run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                tool:    'vision',
                preset:  'describe',
                input:   saved.path,
                project: currentProject || null,
                chat:    currentChat    || null,
            }),
        });
        const d = await r.json();
        let description = '';
        if (d.ok && d.output) {
            // Read the produced text file
            try {
                const r2 = await fetch('tools.php?action=read_output', {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({path: d.output}),
                });
                const d2 = await r2.json();
                if (d2.ok) description = (d2.content || '').trim();
            } catch(e) { /* fall through to path-only */ }
        }
        if (description !== '') {
            _injectBlock('[Attached image: ' + saved.filename + ']\n' +
                         '[Vision description: ' + description + ']\n' +
                         '[Path: ' + saved.path + ']\n\n');
        } else {
            // Nothing could describe it. Say so to the AGENT in words it cannot mistake for a task: a small
            // model shown only a path and a polite note will otherwise INVENT a picture (2026-10-02, vision
            // dispatch QA: opencode/qwen2.5:7b answered "a blue circle and a red square", then "a red circle,
            // a blue square and a green triangle" for the same file, having been given no image at all).
            _injectBlock('[Attached image: ' + saved.filename + ']\n' +
                         '[Path: ' + saved.path + ']\n' +
                         '[IMPORTANT: you cannot see this image and no description of it is available. ' +
                         'Do not describe it or guess what it shows. Tell the user you cannot see it.]\n\n');
        }
        _attachClearPending(pillId);
        if (description) {
            appendSystem(T('msg.icon.menu.book.filename.size.kb.described', '[[icon:menu_book]] {filename} ({size} KB) — described by the local vision model (this agent cannot see images): {text}…', {filename: saved.filename, size: Math.round(saved.size/1024), text: description.slice(0, 60)}));
        } else {
            // To the PERSON: what happened and the two ways out.
            appendError(T('msg.icon.menu.book.filename.size.kb.cannot.see', '{filename} ({size} KB) was saved, but this agent cannot see images and no local vision model could describe it, so the agent will not know what is in it. Install one with "ollama pull gemma3:4b", or move a card that can see (Claude, Codex) to this slot.', {filename: saved.filename, size: (saved.size < 10240 ? (Math.max(saved.size, 1) / 1024).toFixed(1) : Math.round(saved.size/1024))}));
        }
    } catch (err) {
        _injectBlock('[Attached image: ' + saved.filename + ']\n' +
                     '[Path: ' + saved.path + ']\n');
        _attachClearPending(pillId);
        appendError(T('msg.vision.dispatch.failed.message', 'Vision dispatch failed: {message}', {message: err.message}));
    }
}

// Video vision — extract keyframes via ffmpeg, describe each with vision model,
// then inject combined description. Also extracts audio transcript if whisper available.
async function _attachVideoVision(saved, name, pillId) {
    _attachUpdatePending(pillId, 'Extracting keyframes…');
    let descriptions = [];
    let transcript = '';

    // Step 1: extract keyframes via tools.php (ffmpeg:video-keyframes preset)
    try {
        const r = await fetch('tools.php?action=run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                tool:    'ffmpeg',
                preset:  'video-keyframes',
                input:   saved.path,
                project: currentProject || null,
                chat:    currentChat    || null,
            }),
        });
        const d = await r.json();
        if (d.ok && d.output) {
            // output is a directory or list of frame images
            _attachUpdatePending(pillId, 'Describing frames…');
            const framesRes = await fetch('tools.php?action=list_output', {
                method: 'POST',
                headers: {'Content-Type':'application/json'},
                body: JSON.stringify({path: d.output}),
            });
            const framesData = await framesRes.json();
            const frames = (framesData.ok && framesData.files) ? framesData.files : [];

            // Describe each frame (up to 8 keyframes)
            const maxFrames = Math.min(frames.length, 8);
            for (let i = 0; i < maxFrames; i++) {
                try {
                    const vr = await fetch('tools.php?action=run', {
                        method: 'POST',
                        headers: {'Content-Type':'application/json'},
                        body: JSON.stringify({
                            tool: 'vision', preset: 'describe',
                            input: frames[i],
                            project: currentProject || null,
                            chat: currentChat || null,
                        }),
                    });
                    const vd = await vr.json();
                    if (vd.ok && vd.output) {
                        const r2 = await fetch('tools.php?action=read_output', {
                            method: 'POST',
                            headers: {'Content-Type':'application/json'},
                            body: JSON.stringify({path: vd.output}),
                        });
                        const d2 = await r2.json();
                        if (d2.ok && d2.content) {
                            descriptions.push('Frame ' + (i+1) + ': ' + d2.content.trim());
                        }
                    }
                } catch(e) { /* skip frame */ }
            }
        }
    } catch(e) { /* keyframe extraction failed — continue */ }

    // Step 2: extract audio transcript if whisper is available
    _attachUpdatePending(pillId, 'Transcribing audio…');
    try {
        const ar = await fetch('tools.php?action=run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                tool:    'ffmpeg',
                preset:  'extract-audio',
                input:   saved.path,
                project: currentProject || null,
                chat:    currentChat    || null,
            }),
        });
        const ad = await ar.json();
        if (ad.ok && ad.output) {
            const wr = await fetch('tools.php?action=run', {
                method: 'POST',
                headers: {'Content-Type':'application/json'},
                body: JSON.stringify({
                    tool: 'whisper', preset: 'transcribe',
                    input: ad.output,
                    project: currentProject || null,
                    chat: currentChat || null,
                }),
            });
            const wd = await wr.json();
            if (wd.ok && wd.output) {
                const tr = await fetch('tools.php?action=read_output', {
                    method: 'POST',
                    headers: {'Content-Type':'application/json'},
                    body: JSON.stringify({path: wd.output}),
                });
                const td = await tr.json();
                if (td.ok && td.content) transcript = td.content.trim();
            }
        }
    } catch(e) { /* audio extraction failed — continue */ }

    // Step 3: inject combined result
    let block = '[Attached video: ' + saved.filename + ']\n' +
                '[Path: ' + saved.path + ']\n';
    if (descriptions.length) {
        block += '[Visual description (' + descriptions.length + ' keyframes):]\n' +
                 descriptions.join('\n') + '\n';
    }
    if (transcript) {
        block += '[Audio transcript:]\n' + transcript + '\n';
    }
    if (!descriptions.length && !transcript) {
        block += '[Video processing unavailable — saved as path reference. ' +
                 'Install ffmpeg + gemma3:4b for keyframe analysis, whisper for transcription.]\n';
    }
    block += '\n';
    _injectBlock(block);
    _attachClearPending(pillId);

    const summary = descriptions.length ? descriptions.length + ' frames described' : 'no vision';
    const transSummary = transcript ? ', transcript ' + transcript.length + ' chars' : '';
    appendSystem(T('msg.attached.video.filename.size.kb.summarytrans', 'Attached video: {filename} ({size} KB) — {summary}{transsummary}', {filename: saved.filename, size: Math.round(saved.size/1024), summary: summary, transsummary: transSummary}));
}

// =============================================================================
// Internal helpers — block injection + pending pill UI
// =============================================================================

function _injectBlock(block) {
    const current = promptInput.value;
    promptInput.value = block + current;
    promptInput.focus();
    // Move caret to end of injected block so user can keep typing after it
    const pos = block.length;
    promptInput.setSelectionRange(pos, pos);
}

function _attachInjectReference(saved, name, label) {
    _injectBlock('[Attached ' + label + ': ' + saved.filename + ']\n' +
                 '[Path: ' + saved.path + ']\n\n');
}

// fileToBase64 — wraps FileReader as a promise
function _fileToBase64(file) {
    return new Promise((resolve, reject) => {
        const r = new FileReader();
        r.onload  = () => {
            const s = r.result;
            const comma = s.indexOf(',');
            resolve(comma >= 0 ? s.slice(comma + 1) : s);  // strip data: prefix
        };
        r.onerror = () => reject(new Error('FileReader failed'));
        r.readAsDataURL(file);
    });
}

// Status pill — small floating chip near the Attach label while a job runs
function _attachShowPending(name, label, jobId) {
    const wrap = document.getElementById('attach-pending-tray') || (() => {
        const t = document.createElement('div');
        t.id = 'attach-pending-tray';
        t.style.cssText = 'display:flex;gap:4px;align-items:center;flex-wrap:wrap;' +
                          'max-width:60%;overflow:hidden;font-size:10px;' +
                          'color:var(--text-dim);';
        const footer = document.querySelector('.footer-hint');
        if (footer) footer.insertBefore(t, footer.lastElementChild);
        return t;
    })();
    const pill = document.createElement('span');
    pill.id = jobId;
    pill.style.cssText = 'display:inline-flex;align-items:center;gap:3px;' +
                        'padding:1px 6px;border-radius:8px;' +
                        'background:var(--bg-active);border:1px solid var(--border-mid);' +
                        'color:var(--text-base);';
    pill.innerHTML = '<span class="material-symbols-rounded" style="font-size:11px;' +
                    'animation:pulse 1s infinite;">hourglass_top</span>' +
                    '<span>' + _esc(name) + '</span>' +
                    '<span class="material-symbols-rounded attach-pill-status" ' +
                    'style="font-size:10px;color:var(--text-muted);"></span>';
    wrap.appendChild(pill);
    return jobId;
}

function _attachUpdatePending(jobId, statusText) {
    const pill = document.getElementById(jobId);
    if (!pill) return;
    const s = pill.querySelector('.attach-pill-status');
    if (s) s.textContent = statusText || '';
}

function _attachClearPending(jobId) {
    const pill = document.getElementById(jobId);
    if (pill) pill.remove();
    const tray = document.getElementById('attach-pending-tray');
    if (tray && !tray.children.length) tray.remove();
}

function _esc(s) {
    return String(s).replace(/[<>&"]/g, c => ({
        '<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;'
    }[c]));
}

// Wire the paste handler once at startup
setTimeout(() => {
    if (promptInput && !promptInput._pasteWired) {
        promptInput.addEventListener('paste', handlePromptPaste);
        promptInput._pasteWired = true;
    }
}, 0);



// ── Composer paste/drop wiring — moved here from js/chat/agents.js at the split
//    (it requires attachFile to exist when it runs). Byte-identical otherwise.
// Paste + drag-drop file/image attach on the composer → the attachFile pipeline.
if (promptInput && typeof attachFile === 'function') {
    promptInput.addEventListener('paste', e => {
        const items = (e.clipboardData && e.clipboardData.items) || [];
        let handled = false;
        for (const it of items) {
            if (it.kind === 'file') {
                const f = it.getAsFile();
                if (f) { attachFile(f, f.name || ('pasted-' + Date.now() + (/(png|jpe?g|gif|webp)/.test(f.type) ? '.' + f.type.split('/')[1] : '.bin'))); handled = true; }
            }
        }
        if (handled) e.preventDefault();
    });
    ['dragover', 'dragenter'].forEach(ev => promptInput.addEventListener(ev, e => { e.preventDefault(); promptInput.style.outline = '2px dashed var(--accent-blue,#5b8cff)'; }));
    ['dragleave', 'dragend'].forEach(ev => promptInput.addEventListener(ev, () => { promptInput.style.outline = ''; }));
    promptInput.addEventListener('drop', async e => {
        e.preventDefault(); promptInput.style.outline = '';
        if (_inShell) {   // real paths from the shell, no upload
            const paths = await shellDropPaths();
            if (paths && paths.length) for (const p of paths) attachServerFile(p);
            else appendSystem(T('msg.drop.received.but.no.file.path.arrived.from', 'Drop received but no file path arrived from the window — try again.'));
            return;
        }
        for (const f of (e.dataTransfer && e.dataTransfer.files) || []) attachFile(f);
    });
}

// =============================================================================
// PDF Vision — let the agent SEE the pages, not just the extracted text.
//
// A PDF still goes through text extraction, which is the right primary source
// for body text. But a page that is one chart extracts as an empty string: on a
// test PDF of a bar chart, pdftotext returned nothing whatsoever. So when the
// PDF Vision capability is on, the first pages are also rendered to images and
// handed to the agent the way it takes images (catalog image_mode), or described
// locally when it cannot see at all.
//
// Off by default and page-capped, because this is the expensive path: on an
// agent without native image support, every page is a separate vision call.
// =============================================================================
const PDF_VISION_MAX_PAGES = 6;

async function _pdfVisionEnabled() {
    try {
        const r = await (await fetch('capabilities.php?action=global_caps')).json();
        return !!(r.ok && r.enabled && r.enabled.pdf_vision);
    } catch (e) { return false; }
}

/**
 * PDF Vision for an attachment, on EVERY path a PDF can take.
 *
 * This wrapper exists because the call used to live only where text extraction
 * had succeeded. A scanned PDF — the whole reason the capability exists — takes
 * neither of the other two paths, so vision was unreachable exactly when it was
 * needed. Never throws: vision is an extra, and it must not break an attachment.
 */
async function _attachPdfPagesIfPdf(saved, pillId) {
    if (!/\.pdf$/i.test(saved.filename || '')) return 0;
    try { return await _attachPdfPages(saved, pillId); } catch (e) { return 0; }
}

/** Render the first pages and attach them; returns how many were handed over. */
async function _attachPdfPages(saved, pillId) {
    if (!await _pdfVisionEnabled()) return 0;
    _attachUpdatePending(pillId, 'Rendering pages…');
    let pages = [];
    try {
        const r = await (await fetch('tools.php?action=run', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ tool: 'pdfpages', preset: 'pages', input: saved.path,
                                   project: currentProject || null, chat: currentChat || null }),
        })).json();
        if (!r.ok || !r.output) return 0;
        const l = await (await fetch('tools.php?action=list_output', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: r.output }),
        })).json();
        pages = (l.files || l.outputs || []).filter(f => /\.png$/i.test(f.path || f)).slice(0, PDF_VISION_MAX_PAGES);
    } catch (e) { return 0; }
    if (!pages.length) return 0;

    const mode = (typeof _imageModeForCurrentAgent === 'function') ? _imageModeForCurrentAgent() : 'describe';
    const paths = pages.map(f => f.path || f);

    if (mode === 'path' || mode === 'at') {
        _injectBlock('[Pages of ' + saved.filename + ' rendered as images — look at these for anything the text does not carry ' +
                     '(charts, diagrams, scans):]\n' +
                     paths.map((p, i) => (mode === 'at' ? '@' + p : '[page ' + (i + 1) + '] ' + p)).join('\n') + '\n\n');
        return paths.length;
    }
    if (mode === 'flag') {
        if (typeof _pendingImages !== 'undefined') paths.forEach(p => _pendingImages.push(p));
        _injectBlock('[Pages of ' + saved.filename + ' are attached as images — ' + paths.length + ' page(s).]\n\n');
        return paths.length;
    }
    // Describe locally. Hard-capped: this is the slow path and a 40-page PDF
    // would otherwise run the vision model forty times.
    const cap = Math.min(paths.length, 3);
    let done = 0;
    for (let i = 0; i < cap; i++) {
        _attachUpdatePending(pillId, 'Looking at page ' + (i + 1) + '…');
        try {
            const v = await (await fetch('tools.php?action=run', {
                method: 'POST', headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ tool: 'vision', preset: 'describe', input: paths[i],
                                       project: currentProject || null, chat: currentChat || null }),
            })).json();
            if (v.ok && v.output) {
                const t = await (await fetch('tools.php?action=read_output', {
                    method: 'POST', headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ path: v.output }),
                })).json();
                if (t.ok && (t.content || '').trim()) {
                    _injectBlock('[Page ' + (i + 1) + ' of ' + saved.filename + ', as seen by the local vision model: ' +
                                 t.content.trim() + ']\n\n');
                    done++;
                }
            }
        } catch (e) { /* one page failing is not worth losing the rest */ }
    }
    if (paths.length > cap) {
        _injectBlock('[' + (paths.length - cap) + ' further page(s) were rendered but not described — ' +
                     'this agent cannot see images, and describing each one locally is slow. ' +
                     'Ask about a specific page to have it looked at.]\n\n');
    }
    return done;
}
