// =============================================================================
// RIGHT-SIDEBAR PANELS — Code / Library / Snippets / Sources / Config
// =============================================================================
//
// Conceptual model:
//   LIBRARY  — paths/URLs to read-only knowledge (books, articles, docs).
//              No file content stored. Just a catalog with location pointers.
//   SNIPPETS — functions/procedures saved as files on disk, with index.
//              Cockpit can propose new snippets; user approves to add.
//   SOURCES  — whole projects/programs saved as files/folders on disk.
//              Cockpit can propose new sources; user approves to add.
//   CODE     — auto-extracted code blocks from agent responses (volatile).
//
// Storage (defaults, configurable in Config tab):
//   GLOBAL  bases: ~/scripts/cockpit_data/{library,snippets,sources}/
//   PROJECT bases: <project>/{library,snippets,sources}/
//   index.json under each base, plus actual files for snippets/sources.
//
// Proposals queue (always visible at bottom of right sidebar):
//   ~/scripts/cockpit_data/proposals.json — pending agent suggestions

let rpAutoExtract = true;
// Content of code blocks already proposed this session — prevents the same
// snippet being re-proposed (e.g. broadcast/pipeline echoing identical code).
const _rpProposedContent = new Set();

// Which books are unfolded in the Library panel. Books start COLLAPSED — the
// panel should show you your books, not forty chapter titles per book — but a
// book you opened stays open across a refresh, so removing one does not fold
// everything else back up underneath you.
const _rpOpenBooks = new Set();

function rpToggleAutoExtract() {
    rpAutoExtract = !rpAutoExtract;
    const lbl = document.getElementById('rp-auto-extract');
    if (lbl) lbl.innerHTML = (rpAutoExtract ? '<span class="material-symbols-rounded ico">check</span>' : '<span class="material-symbols-rounded ico">radio_button_unchecked</span>') + ' Propose';
}

// ── Rescan: rebuild index from on-disk files (handles external changes) ──────
async function rpRescan(kind) {
    if (!await cockpitConfirm('Rescan storage?', 'Rescan ' + kind + ' storage directory and rebuild the index from disk?\n\nNew files will be added with auto-titles. Existing entries are preserved.', 'Rescan', {icon:'sync'})) return;
    // Run for both global and project scopes
    const scopes = (currentProject && currentProject !== '_standalone') ? ['global','project'] : ['global'];
    let total = 0;
    for (const sc of scopes) {
        const r = await fetch('library.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({action:'rescan', kind, project:currentProject, scope:sc})
        });
        const d = await r.json();
        if (d.ok) total += d.count || 0;
        else appendError(T('msg.rescan.sc.failed.error', 'Rescan {sc} failed: {error}', {sc: sc, error: (d.error||'')}));
    }
    appendSystem(T('msg.rescanned.kind.total.total.entries', 'Rescanned {kind}: {total} total entries.', {kind: kind, total: total}));
    rpRefreshList(kind);
}

// ── Help modal ───────────────────────────────────────────────────────────────
// =============================================================================
// HELP SYSTEM — JSON-driven (cockpit_data/help.json). Unified guide (TOC +
// content), context help (F1 → topic for the element under the cursor via
// data-help), and a first-run welcome. Editable in-app via the floating editor.
// =============================================================================
// =============================================================================
// Hover hints (2026-09-13). Browser tooltips (the title attribute) are drawn by
// the browser: no control over position, cut off at screen edges, no styling,
// one line. Cockpit now draws its own: every title= is lifted into data-tip on
// first hover (so the browser one never appears), shown in a positioned box that
// is clamped to the viewport (flips above when there is no room below, slides
// left/right), wraps, and — on a long hover, or at once in First-Use mode —
// expands with a summary of the object taken from its help topic (data-help).
// =============================================================================
const CK_HINT_DELAY = 350, CK_HINT_LONG = 1300;
let _tipEl = null, _tipTarget = null, _tipTimer = null, _tipLongTimer = null;
let firstUseMode = (localStorage.getItem('cockpit_first_use') === '1');
function _tipBox() {
    if (_tipEl) return _tipEl;
    _tipEl = document.createElement('div'); _tipEl.id = 'ck-tip';
    _tipEl.style.cssText = 'position:fixed;z-index:100020;max-width:380px;padding:6px 9px;border:1px solid var(--border-mid);border-radius:5px;' +
        'background:var(--bg-active);color:var(--text-base);font-family:var(--font-ui);font-size:11px;line-height:1.45;box-shadow:0 6px 24px rgba(0,0,0,0.45);' +
        'pointer-events:none;display:none;white-space:normal;word-break:break-word;';
    document.body.appendChild(_tipEl);
    return _tipEl;
}
function _tipHostFor(el) {   // nearest element carrying a hint or a help topic
    while (el && el !== document.body) {
        if (el.getAttribute && (el.getAttribute('title') || el.dataset.tip || el.dataset.tipFn || (firstUseMode && el.dataset.help))) return el;
        el = el.parentElement;
    }
    return null;
}
function _helpSummary(topicId) {
    const t = _helpData && _helpData.topics && _helpData.topics[topicId];
    if (!t) return null;
    const tmp = document.createElement('div'); tmp.innerHTML = t.body || '';
    tmp.querySelectorAll('nav,table,pre,script,style').forEach(x => x.remove());
    // textContent glues block elements together ("…automatically.How they workRules…"): put a space after every block first
    tmp.querySelectorAll('p,li,h1,h2,h3,h4,h5,div,br,tr,dt,dd').forEach(x => x.insertAdjacentText('beforeend', ' '));
    let txt = (tmp.textContent || '').replace(/\s+/g, ' ').trim();
    if (txt.length > 320) txt = txt.slice(0, 317).replace(/\s+\S*$/, '') + '…';
    const title = (t.title || '').replace(/<[^>]+>/g, '').trim();
    return { title, text: txt };
}
function _tipRender(el, expanded) {
    const box = _tipBox();
    const tip = el.dataset.tip || '';
    let html = tip ? escHtml(tip) : '';
    // A hint rendered by one of OUR functions (data-tip-fn): trusted HTML, e.g. the clock's detail card.
    if (el.dataset.tipFn && typeof window[el.dataset.tipFn] === 'function') { try { html = window[el.dataset.tipFn](el) || html; } catch (e) {} }
    if (expanded) {
        const s = _helpSummary(el.dataset.help || (el.closest('[data-help]') || {}).dataset?.help);
        if (s && s.text) html += (html ? '<div style="height:5px;"></div>' : '') +
            '<div style="font-weight:700;color:var(--text-primary);margin-bottom:2px;">' + escHtml(s.title) + '</div>' +
            '<div style="color:var(--text-muted);">' + escHtml(s.text) + '</div>' +
            '<div style="margin-top:4px;font-size:10px;color:var(--text-dim);">F1 opens the full topic</div>';
    }
    if (!html) return false;
    box.innerHTML = html; box.style.display = 'block';
    _tipPlace(el); return true;
}
function _tipPlace(el) {
    const box = _tipBox(), r = el.getBoundingClientRect(), vw = window.innerWidth, vh = window.innerHeight, m = 6;
    box.style.left = '0px'; box.style.top = '0px';           // measure at natural width
    const bw = Math.min(box.offsetWidth, vw - 2 * m), bh = box.offsetHeight;
    let x = r.left, y = r.bottom + m;
    if (y + bh > vh - m) y = r.top - bh - m;                  // no room below → above
    if (y < m) y = Math.max(m, Math.min(vh - bh - m, r.bottom + m));   // nor above → best fit
    if (x + bw > vw - m) x = vw - bw - m;                     // slide in from the right edge
    if (x < m) x = m;
    box.style.left = x + 'px'; box.style.top = y + 'px';
}
function _tipHide() {
    clearTimeout(_tipTimer); clearTimeout(_tipLongTimer); _tipTimer = _tipLongTimer = null;
    if (_tipEl) _tipEl.style.display = 'none';
    _tipTarget = null;
}
document.addEventListener('mouseover', e => {
    const host = _tipHostFor(e.target);
    if (!host) { if (_tipTarget) _tipHide(); return; }
    if (host === _tipTarget) return;
    _tipHide(); _tipTarget = host;
    if (host.getAttribute('title')) { host.dataset.tip = host.getAttribute('title'); host.removeAttribute('title'); }
    _tipTimer = setTimeout(() => {
        if (_tipTarget !== host) return;
        if (!_tipRender(host, firstUseMode)) return;
        if (!firstUseMode) _tipLongTimer = setTimeout(() => { if (_tipTarget === host) _tipRender(host, true); }, CK_HINT_LONG - CK_HINT_DELAY);
    }, firstUseMode ? 120 : CK_HINT_DELAY);
}, true);
document.addEventListener('mouseout', e => { if (_tipTarget && !_tipTarget.contains(e.relatedTarget)) _tipHide(); }, true);
['mousedown', 'keydown', 'wheel'].forEach(ev => document.addEventListener(ev, _tipHide, true));
window.addEventListener('scroll', _tipHide, true);
window.addEventListener('resize', _tipHide);
function firstUseToggle(on) {
    firstUseMode = (on === undefined) ? !firstUseMode : !!on;
    try { localStorage.setItem('cockpit_first_use', firstUseMode ? '1' : '0'); } catch (e) {}
    const b = document.getElementById('btn-first-use'); if (b) b.classList.toggle('ma-active', firstUseMode);
    if (firstUseMode) _helpLoad();
    appendSystem(firstUseMode ? T('msg.first.use.hints.on.hovering.anything.shows.w', 'First-Use hints on: hovering anything shows what it is, with a summary from the guide.') : T('msg.first.use.hints.off.short.hints.summaries.on', 'First-Use hints off: short hints, summaries on a long hover.'));
}
if (firstUseMode) { setTimeout(() => { const b = document.getElementById('btn-first-use'); if (b) b.classList.add('ma-active'); _helpLoad(); }, 800); }

// =============================================================================
// Tutorial (2026-09-13): a guided tour of everything Cockpit offers. Each step
// spotlights one element (or none, for an overview card), explains it, and
// waits for Next. Steps whose element is not on screen are skipped. Escape
// ends the tour. F1 on any step opens the matching help topic.
// =============================================================================
const TUTORIAL_STEPS = [
 { id: 'welcome-to-ai-cockpit', sel: '.topbar-brand-block', help: 'about', title: 'Welcome to AI Cockpit', text: 'A local console that drives several AI agents at once — paid CLIs, free workers, local models and file tools — from one prompt, one chat history and one set of files. This tour walks through every part of the screen. Next / Back below, Esc to leave; press F1 on any step for the full help topic.' },
 { id: 'card-1-the-primary-cli-agent', sel: '#sup-card-claude', help: 'cards', title: 'Card 1 — the primary CLI agent', text: 'Claude Code by default (any paid CLI can sit here via Slots). Pick the model and effort, toggle power, open its tmux session or a terminal with the ↗ buttons. The bar shows today\'s usage against its cap.' },
 { id: 'card-2-the-fallback-cli-free-pro', sel: '#sup-card-gemini', help: 'cards', title: 'Card 2 — the fallback CLI / free provider', text: 'Gemini CLI by default; can be a free REST provider or another CLI. Same controls as card 1. The active card (highlighted) is where Execute sends the prompt.' },
 { id: 'card-3-local-models', sel: '#sup-card-ollama', help: 'cards', title: 'Card 3 — local models', text: 'Ollama (or LocalAI) on this machine: Tier-1 picks recommended for the 4 GB GPU, favourites, the model manager (database icon) and Power Combos — multi-model recipes that run several local models on one prompt.' },
 { id: 'card-4-workers', sel: '#sup-card-workers', help: 'workers', title: 'Card 4 — Workers', text: 'Free and paid REST providers (Groq, OpenRouter, Cloudflare…). "Auto (cascade)" walks your priority list and moves on when a quota runs out. Keys are pasted in the settings gear; the ↗ opens a live activity log.' },
 { id: 'card-5-tools', sel: '#sup-card-tools', help: 'tools', title: 'Card 5 — Tools', text: 'Local programs as file→file presets: ffmpeg, pandoc, whisper, ImageMagick, yt-dlp. Pick a preset, Execute opens the input dialog (Browse uploads a file, Server picks one on the machine). Runs are windows in the Tools tmux session (↗) and are recorded in the chat.' },
 { id: 'account-and-users', sel: '.sup-account-card', help: 'account', title: 'Account and users', text: 'The button showing your name (with a small cog) opens your Cockpit Account, and inside it the Local users button: accounts on this machine, your password, sign out (in the Stand-alone edition the name button opens the user manager directly). Profile holds durable facts about you, sent with every prompt. Slots: which supplier fills each card. Apps: the terminal, file manager and browser the toolbar buttons open.' },
 { id: 'sessions-and-the-window', sel: '#topbar-sessions', help: 'sessions', title: 'Sessions and the window', text: 'The agent sessions run in tmux and start with the app: Stop and Restart control them (the chip on Stop counts how many are up, e.g. 3/3), Exit shows what is still running — tool jobs, calls, streams — with the ways to stop it. In the native window the card also holds Reopen, Reload (bypasses the cache), Refresh (re-reads status and account now) and ⛶ frameless; with the frame off, ▁ ▢ beside Exit minimise and maximise.' },
 { id: 'clock', sel: '#topbar-clock', help: 'clock', title: 'Clock', text: 'Local time (this browser) and the server\'s time, each with weekday, ISO week and UTC offset — handy when the Cockpit runs on another machine.' },
 { id: 'mode-and-theme', sel: '#btn-theme-toggle', help: 'themes', title: 'Mode and Theme', text: 'Dark/light mode and the theme editor (36 themes, protanopia-safe Dalton set).' },
 { id: 'language', sel: '#btn-lang', help: 'language', title: 'Language', text: 'The translate button picks the language Cockpit is shown in — English by default, with a growing list of other languages, right-to-left ones (Arabic, Hebrew, Persian...) included. Missing yours? The menu has an empty template to translate.' },
 { id: 'help', sel: '#btn-help', help: 'suppliers', title: 'Help', text: 'The full guide, searchable. F1 anywhere opens the topic for what is under the mouse. Hover hints appear on everything; the First-Use toggle expands them with summaries.' },
 { id: 'info-bar', sel: '.topbar-info', help: 'usage', title: 'Info bar', text: 'Current project and chat, the working folder, machine summary, live GPU memory, network latency and session state.' },
 { id: 'left-sidebar-tabs', sel: '#sidebar-left .sidebar-vtab', help: 'left-sidebar', title: 'Left sidebar tabs', text: 'Four tabs: Chats, Projects, Files and Notes. The Hive stays open below them. Each tab is a panel; drag the edge to resize. The next four steps look at each tab in turn — Skip section jumps past them.' },
 { id: 'chats', sel: '#left-chats', ltab: 'chats', help: 'left-chats', group: 'left', title: 'Chats', text: 'Every chat in the current project. + New starts a fresh one; click a chat to switch to it; double-click its name to rename it. Export saves it as JSON and Import loads one back; Detach moves it to the Free pool.' },
 { id: 'projects', sel: '#left-projects', ltab: 'projects', help: 'left-projects', group: 'left', title: 'Projects', text: 'Your projects: each groups chats, files and context. + New creates one (a name and a working folder). Click a project to switch — the chat list, file tree and rules follow. Config edits that project\'s COCKPIT.md, its own rules and context.' },
 { id: 'files', sel: '#left-filetree', ltab: 'filetree', help: 'left-files', group: 'left', title: 'Files', text: 'The project\'s working folder as a tree. Click a file to open it in the right sidebar. Map builds a unit map of Pascal and PHP sources; Refresh re-reads the tree from disk.' },
 { id: 'notes', sel: '#left-notes', ltab: 'notes', help: 'notes', group: 'left', title: 'Notes', text: 'A Markdown note store kept inside Cockpit. The scope dropdown switches between Internal (Cockpit\'s own notes) and Folder (your Notepad folder); ticking +other also searches the other store, read-only.' },
 { id: 'hive-autocognition', sel: '#left-hive', help: 'autocognition', title: 'Hive — AutoCognition', text: 'The agent bus: who is on it, task chains (durable, resumable plans) and the consent broker. PLAN on the prompt turns a goal into a chain.' },
 { id: 'toolbar', sel: '#right-toolbar', tab: 'toolbar', help: 'toolbar', title: 'Toolbar', text: 'Every quick-launch tool, in alphabetical order — twenty-one buttons. Jobs and Stop carry small count chips. The next steps take the buttons one at a time; Skip section jumps past them.' },
 { id: 'toolbar-accumulator', sel: '#btn-accumulator', tab: 'toolbar', help: 'accumulator', group: 'toolbar', title: 'Toolbar · Accumulator', text: 'Pulls reusable knowledge out of PDFs and documents with a local pipeline and stores it for retrieval. The chip on the button counts the results gathered so far.' },
 { id: 'toolbar-bookshelf', sel: '#right-toolbar button[onclick*="bookshelfOpen"]', tab: 'toolbar', help: 'bookshelf', group: 'toolbar', title: 'Toolbar · Bookshelf', text: 'Splits a book (epub, docx, odt, fb2, mobi…) into chapters and files them in the Library as one foldable row, so even a small local model can work with a whole book. You see the chapter list before anything is written.' },
 { id: 'toolbar-browser', sel: '#right-toolbar button[onclick*="quickLaunchBrowser"]', tab: 'toolbar', help: 'browser-btn', group: 'toolbar', title: 'Toolbar · Browser', text: 'Opens a web browser window.' },
 { id: 'toolbar-delegate', sel: '#right-toolbar button[onclick*="rulesManagerOpen"]', tab: 'toolbar', help: 'delegate', group: 'toolbar', title: 'Toolbar · Delegate', text: 'Auto-routes tasks that match your rules to a chosen supplier, model or combo before the normal agent carries on.' },
 { id: 'toolbar-dossier', sel: '#right-toolbar button[onclick*="dossierOpen"]', tab: 'toolbar', help: 'dossier', group: 'toolbar', title: 'Toolbar · Dossier', text: 'Researches a question on the web and saves a cited report in the project. It needs web search, which some networks block, so it can come back empty.' },
 { id: 'toolbar-files', sel: '#right-toolbar button[onclick*="filemanOpen"]', tab: 'toolbar', help: 'files-btn', group: 'toolbar', title: 'Toolbar · Files', text: 'Opens the file window: your Public folder (yours to change) and your project folders (to look at and copy from).' },
 { id: 'toolbar-image', sel: '#right-toolbar button[onclick*="genOpenDialog(\'image\')"]', tab: 'toolbar', help: 'generate', group: 'toolbar', title: 'Toolbar · Image', text: 'Generates an image locally with stable-diffusion.cpp.' },
 { id: 'toolbar-jobs', sel: '#btn-scheduler', tab: 'toolbar', help: 'jobs', group: 'toolbar', title: 'Toolbar · Jobs', text: 'Scheduled jobs: a cron-driven task scheduler. The chip counts your jobs and takes the accent colour while any are pending or running.' },
 { id: 'toolbar-keys', sel: '#btn-keys', tab: 'toolbar', help: 'keys-btn', group: 'toolbar', title: 'Toolbar · Keys', text: 'Shows the keyboard shortcuts.' },
 { id: 'toolbar-notepad', sel: '#right-toolbar button[onclick*="notepadOpen"]', tab: 'toolbar', help: 'notepad', group: 'toolbar', title: 'Toolbar · Notepad', text: 'AI-aware notes over a local folder you choose.' },
 { id: 'toolbar-privacy', sel: '#right-toolbar button[onclick*="policyOpen"]', tab: 'toolbar', help: 'policy', group: 'toolbar', title: 'Toolbar · Privacy', text: 'Privacy and spending: a check for secrets and card numbers before a prompt goes to an online agent, a free-agents-only switch, and a monthly budget for paid agents.' },
 { id: 'toolbar-rules', sel: '#btn-directives', tab: 'toolbar', help: 'rules', group: 'toolbar', title: 'Toolbar · Rules', text: 'Directives: global standing rules applied to every supplier (Claude, Gemini, Ollama and Workers), sent with every prompt.' },
 { id: 'toolbar-power', sel: '#right-toolbar button[onclick*="powerOpen"]', tab: 'toolbar', help: 'power', group: 'toolbar', title: 'Toolbar · Power Buttons', text: 'One click runs a saved prompt on what you copied (proofread, summarise, make it polite…), with a model on this computer or a supplier you choose, and puts the answer on your clipboard.' },
 { id: 'toolbar-skills', sel: '#right-toolbar button[onclick*="skillsManagerOpen"]', tab: 'toolbar', help: 'skills', group: 'toolbar', title: 'Toolbar · Skills', text: 'Reusable /trigger prompt templates: type the trigger and the template is expanded into your prompt.' },
 { id: 'toolbar-sound', sel: '#right-toolbar button[onclick*="genOpenDialog(\'sound\')"]', tab: 'toolbar', help: 'generate', group: 'toolbar', title: 'Toolbar · Sound', text: 'Generates sound locally: speech, effects, a melody or background audio.' },
 { id: 'toolbar-summarize', sel: '#right-toolbar button[onclick*="summarizeSession"]', tab: 'toolbar', help: 'summarize', group: 'toolbar', title: 'Toolbar · Summarize', text: 'Summarizes the current chat with the active agent, and lets you save the summary.' },
 { id: 'toolbar-tasks', sel: '#right-toolbar button[onclick*="bgTasksOpen"]', tab: 'toolbar', help: 'bgtasks', group: 'toolbar', title: 'Toolbar · Tasks', text: 'Background tasks: autonomous goals and recurring jobs.' },
 { id: 'toolbar-terminal', sel: '#right-toolbar button[onclick*="cmdwinOpen"]', tab: 'toolbar', help: 'terminal', group: 'toolbar', title: 'Toolbar · Terminal', text: 'Opens the command window: simple commands, confined by the system to your Public folder.' },
 { id: 'toolbar-track', sel: '#time-btn', tab: 'toolbar', help: 'time', group: 'toolbar', title: 'Toolbar · Track', text: 'Starts or stops time tracking. Right-click it for the report.' },
 { id: 'toolbar-transcriber', sel: '#btn-transcriber', tab: 'toolbar', help: 'transcriber', group: 'toolbar', title: 'Toolbar · Transcriber', text: 'Turns a YouTube video\'s transcript into an analysed, structured PDF.' },
 { id: 'toolbar-translate-chat', sel: '#right-toolbar button[onclick*="translateChat"]', tab: 'toolbar', help: 'translate', group: 'toolbar', title: 'Toolbar · Translate chat', text: 'Translates every message in this chat (code excluded) with local LibreTranslate — nothing leaves your machine.' },
 { id: 'toolbar-translate-text', sel: '#right-toolbar button[onclick*="translateTextBox"]', tab: 'toolbar', help: 'translate', group: 'toolbar', title: 'Toolbar · Translate text', text: 'Opens a free-text translation box, also on local LibreTranslate.' },
 { id: 'toolbar-video', sel: '#right-toolbar button[onclick*="genOpenDialog(\'video\')"]', tab: 'toolbar', help: 'generate', group: 'toolbar', title: 'Toolbar · Video', text: 'Generates a short animated GIF locally.' },
 { id: 'the-chat', sel: '#console-box', help: 'chat', title: 'The chat', text: 'Every turn is a card: click its title row to fold it; the row stays visible while a long answer scrolls. Copy / save-to-library actions sit on the row. Ctrl+F searches the chat. Tool runs and worker calls are recorded here too.' },
 { id: 'modes', sel: '#ma-strip', help: 'modes', title: 'Modes', text: 'Single sends to the active card. Pipeline chains cards in order. Broadcast asks several at once. Plan drafts and runs a multi-step plan. Caveman compresses prompts to online suppliers.' },
 { id: 'power-strip', sel: '#power-strip', help: 'power', title: 'Power Buttons strip', text: 'Your Power Buttons, one click each: copy some text (or a picture), click a button, and the answer comes back in a small card. Add buttons from Toolbar → Power Buttons.' },
 { id: 'styles', sel: '#style-strip', help: 'styles', title: 'Styles', text: 'Chat, Outline, Research, Build, Debug, Analyze, Report — a short instruction prefixed to the prompt. Build is the plain default. "auto model" lets a style pick its preferred model.' },
 { id: 'the-prompt', sel: '#prompt-in', help: 'prompt', title: 'The prompt', text: 'Type here. Enter sends; Ctrl+Enter or Shift+Enter add a line; ↑/↓ walk your history; Esc cancels a running reply. Slash commands (/skill) and attachments (paperclip, or drop a file) work here.' },
 { id: 'voice-input', sel: '#mic-btn', help: 'voice', title: 'Voice input', text: 'Press to dictate: it records, transcribes on this machine with whisper.cpp and drops the words into the prompt. While you speak, a bar opens beside the button so you can see the microphone is live. The ▾ menu picks the model, language and microphone, and Test level checks the input.' },
 { id: 'intercom', sel: '#intercom-btn', help: 'intercom', title: 'Intercom', text: 'Hands-free: it listens, notices when you stop talking, sends what you said, speaks the answer and listens again. Press again to stop.' },
 { id: 'execute-plan-clear-save-attach', sel: '#btn-execute', help: 'execute-btn', title: 'Execute, PLAN, Clear, Save, Attach', text: 'Execute sends to the active card. PLAN hands the goal to the planner (Autopilot Cruise) for a reviewable chain. Save keeps the prompt text; Attach adds files whose content is folded into the prompt.' },
 { id: 'right-sidebar-tabs', sel: '#sidebar-right .sidebar-vtab', help: 'right-sidebar', title: 'Right sidebar tabs', text: 'Fourteen tabs: Toolbar, Proposals, Preview, Code, Library, Snippets, Sources, Config, Search, Capabilities, Plans, Artifacts, Attachments and Usage. The Toolbar was covered above; the next steps take the rest in turn — Skip section jumps past them.' },
 { id: 'proposals', sel: '.rp-proposals-hdr', tab: 'proposals', help: 'proposals', group: 'right', title: 'Proposals', text: 'When an agent proposes a file change (%%CREATE%% / %%APPEND%%), it lands here first; a count shows on this tab\'s icon from anywhere. Nothing touches your files until you approve — one by one, or all at once.' },
 { id: 'preview-right-sidebar', sel: '#right-preview', tab: 'preview', help: 'preview', group: 'right', title: 'Preview (right sidebar)', text: 'Live preview of the file you select in the file tree: HTML and Markdown are rendered.' },
 { id: 'code-right-sidebar', sel: '#right-code', tab: 'code', help: 'editor', group: 'right', title: 'Code (right sidebar)', text: 'The code editor, with syntax highlighting, find and replace, line numbers and word wrap. Code blocks from agent answers are extracted here too.' },
 { id: 'library-right-sidebar', sel: '#right-library', tab: 'library', help: 'library', group: 'right', title: 'Library (right sidebar)', text: 'Your knowledge base: books, articles, notes and links. Add a file or scan a folder and the text becomes searchable. Books filed by Bookshelf show as one foldable row. A prompt that matches something here gets the passage added — or the chat says nothing fitted well enough.' },
 { id: 'snippets-right-sidebar', sel: '#right-snippets', tab: 'snippets', help: 'snippets', group: 'right', title: 'Snippets (right sidebar)', text: 'Short reusable code and text blocks, one file each, searchable by keyword or by meaning (Deep search). Save one from a chat with F2.' },
 { id: 'sources-right-sidebar', sel: '#right-sources', tab: 'sources', help: 'sources', group: 'right', title: 'Sources (right sidebar)', text: 'Whole external projects and programs you refer to — entire codebases, not single files like Snippets. Register one, upload a zip, or let Cockpit scan a folder.' },
 { id: 'config-right-sidebar', sel: '#right-config', tab: 'config', help: 'config', group: 'right', title: 'Config (right sidebar)', text: 'Settings that are not on a card: storage paths, attachment routes (which tool handles which file type) and import/export.' },
 { id: 'search-right-sidebar', sel: '#right-search', tab: 'search', help: 'search', group: 'right', title: 'Search (right sidebar)', text: 'Web search: Brave first, then DuckDuckGo. Open a result, read it into your prompt, or save it to the Library. Public engines increasingly refuse automated queries, so it can come back empty — it says which engine refused.' },
 { id: 'capabilities-right-sidebar', sel: '#right-capabilities', tab: 'capabilities', help: 'capabilities', group: 'right', title: 'Capabilities (right sidebar)', text: 'MCP servers and tool-shims that extend what agents can do. One ON/OFF switch per capability, applying to every project and supplier from your next prompt.' },
 { id: 'plans-right-sidebar', sel: '#right-plans', tab: 'plans', help: 'plans', group: 'right', title: 'Plans (right sidebar)', text: 'Plan mode breaks a goal into steps using several agents as voters. Here you view the steps, run them, sequence them or schedule them.' },
 { id: 'artifacts-right-sidebar', sel: '#right-artifacts', tab: 'artifacts', help: 'artifacts', group: 'right', title: 'Artifacts (right sidebar)', text: 'Everything this project produced, in one list: files agents wrote, generated images and audio, tool outputs and transcripts. Each row says where it came from; open it, reveal its folder, or delete it.' },
 { id: 'attachments-right-sidebar', sel: '#right-attachments', tab: 'attachments', help: 'attachments', group: 'right', title: 'Attachments (right sidebar)', text: 'Files attached to this chat. Text and code go in inline; images and video are processed so the agent can use them; a PDF has its text extracted, and with PDF Vision on its first pages are rendered as images too.' },
 { id: 'usage-right-sidebar', sel: '#right-usage', tab: 'usage', help: 'usage', group: 'right', title: 'Usage (right sidebar)', text: 'Token use and quota for every supplier and worker, and paid API spend.' },
 { id: 'status-bar', sel: '.statusbar', help: 'usage', title: 'Status bar', text: 'The latest system message, the sidebar toggles, line numbers and the connection state. The Ready/Thinking indicator shows a reply in progress.' },
 { id: 'that-is-the-cockpit', sel: null, help: 'walkthrough', title: 'That is the cockpit', text: 'Suggested first flight: pick a card, type a question, Enter. Then try PLAN on a small goal, a Power Combo on card 3, and a pandoc conversion on the Tools card. The full guide (Help) has a step-by-step walkthrough and every setting.' },
];
let _tourIdx = -1, _tourEl = null, _tourPrev = null;
// A step may name a tab (`tab:` right sidebar, `ltab:` left) and the runner opens it
// first. Without this, a step whose element lives in a tab that is not the open one
// measures as zero-width and is SKIPPED -- silently. That is what happened to the
// Toolbar and Proposals steps: the tour never mentioned the home of twenty-one tools
// unless you had happened to open that tab yourself.
function _tourOpenTab(id, side) {
    side = side || 'right';
    const b = document.querySelector('#sidebar-' + side + ' .sidebar-vtab[onclick*="\'' + id + '\'"]');
    if (!b) return;
    try {
        if (side === 'left' && typeof switchLeftTab === 'function') switchLeftTab(id, b);
        else if (typeof switchTab === 'function') switchTab(side, id, b);
    } catch (e) {}
}
// The id of the tab that is open now: the right strip's handler is switchTab('right','x',this)
// (the id is the SECOND quoted word), the left's is switchLeftTab('x',this) (the first).
function _tourActiveTab(side) {
    const b = document.querySelector('#sidebar-' + side + ' .sidebar-vtab.active');
    if (!b) return null;
    const w = ((b.getAttribute('onclick') || '').match(/'([a-z-]+)'/g) || []).map(x => x.slice(1, -1));
    return side === 'left' ? (w[0] || null) : (w[1] || null);
}
function _tourRestoreTab() {              // leave the screen as the person had it
    const p = _tourPrev; _tourPrev = null;
    if (!p) return;
    if (p.left)  _tourOpenTab(p.left, 'left');
    if (p.right) _tourOpenTab(p.right, 'right');
}
function tutorialStart() { _tourIdx = -1; _tourPrev = { left: _tourActiveTab('left'), right: _tourActiveTab('right') }; tutorialNext(1); }
function tutorialEnd() { if (_tourEl) { _tourEl.remove(); _tourEl = null; } _tourIdx = -1; document.removeEventListener('keydown', _tourKeys, true); _tourRestoreTab(); }
// Skip the rest of the current section (a run of steps sharing a `group`): forty-odd
// steps for every tab and button is a lot to walk through if you only want one.
function tutorialSkipGroup() {
    const g = (TUTORIAL_STEPS[_tourIdx] || {}).group;
    if (!g) { tutorialNext(1); return; }
    let i = _tourIdx;
    while (i + 1 < TUTORIAL_STEPS.length && TUTORIAL_STEPS[i + 1].group === g) i++;
    _tourIdx = i; tutorialNext(1);
}
function _tourKeys(e) { if (e.key === 'Escape') { e.preventDefault(); tutorialEnd(); } else if (e.key === 'ArrowRight' || e.key === 'Enter') { e.preventDefault(); tutorialNext(1); } else if (e.key === 'ArrowLeft') { e.preventDefault(); tutorialNext(-1); } else if (e.key === 'F1') { e.preventDefault(); const s = TUTORIAL_STEPS[_tourIdx]; if (s && s.help) showHelp(s.help); } }
function tutorialNext(dir) {
    let i = _tourIdx;
    for (;;) {
        i += dir;
        if (i < 0) { i = 0; break; }
        if (i >= TUTORIAL_STEPS.length) { tutorialEnd(); appendSystem(T('msg.tour.finished.help.walkthrough.continues.fro', 'Tour finished. Help → Walkthrough continues from here.')); return; }
        const s = TUTORIAL_STEPS[i];
        if (!s.sel) break;
        if (s.ltab) _tourOpenTab(s.ltab, 'left');
        if (s.tab)  _tourOpenTab(s.tab, 'right');
        const el = document.querySelector(s.sel);
        if (el && el.getBoundingClientRect().width > 0) break;     // skip what is not on screen
    }
    _tourIdx = i; _tourShow(TUTORIAL_STEPS[i]);
}
function _tourShow(step) {
    if (!_tourEl) {
        _tourEl = document.createElement('div'); _tourEl.id = 'ck-tour';
        _tourEl.style.cssText = 'position:fixed;inset:0;z-index:100015;pointer-events:none;';
        document.body.appendChild(_tourEl);
        document.addEventListener('keydown', _tourKeys, true);
    }
    const el = step.sel ? document.querySelector(step.sel) : null;
    const r = el ? el.getBoundingClientRect() : null;
    if (el && typeof el.scrollIntoView === 'function') { try { el.scrollIntoView({ block: 'nearest', inline: 'nearest' }); } catch (e) {} }
    const R = el ? el.getBoundingClientRect() : { left: window.innerWidth / 2 - 1, top: window.innerHeight / 2 - 1, width: 2, height: 2, right: 0, bottom: 0 };
    const pad = 6, n = _tourIdx + 1, total = TUTORIAL_STEPS.length;
    // spotlight: one box with a huge shadow dims everything but the target
    const spot = 'position:fixed;left:' + (R.left - pad) + 'px;top:' + (R.top - pad) + 'px;width:' + (R.width + 2 * pad) + 'px;height:' + (R.height + 2 * pad) + 'px;' +
        'border:2px solid var(--accent-amber,#e6b43c);border-radius:6px;box-shadow:0 0 0 9999px rgba(0,0,0,0.55);pointer-events:none;transition:all 0.2s;' + (el ? '' : 'border-color:transparent;');
    // card position: below the target when there is room, else above, else beside; clamped
    const vw = window.innerWidth, vh = window.innerHeight, cw = Math.min(420, vw - 24), ch = 200;
    let cx = R.left, cy = R.bottom + pad + 10;
    if (!el) { cx = vw / 2 - cw / 2; cy = vh / 2 - ch / 2; }
    else if (cy + ch > vh - 12) { cy = R.top - pad - 10 - ch; if (cy < 12) { cy = Math.max(12, Math.min(vh - ch - 12, R.top)); cx = R.right + pad + 10; if (cx + cw > vw - 12) cx = R.left - pad - 10 - cw; } }
    if (cx + cw > vw - 12) cx = vw - cw - 12; if (cx < 12) cx = 12;
    _tourEl.innerHTML = '<div style="' + spot + '"></div>' +
        '<div style="position:fixed;left:' + cx + 'px;top:' + cy + 'px;width:' + cw + 'px;pointer-events:auto;background:var(--bg-base);border:1px solid var(--border-mid);border-radius:8px;padding:12px 14px;box-shadow:0 8px 40px rgba(0,0,0,0.6);font-family:var(--font-ui);">' +
        '<div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;"><span class="material-symbols-rounded" style="font-size:16px;color:var(--accent-amber,#e6b43c);">tour</span>' +
        '<b style="font-size:13px;flex:1;">' + escHtml(T('tour.' + step.id + '.title', step.title)) + '</b><span style="font-size:10px;color:var(--text-muted);">' + n + ' / ' + total + '</span></div>' +
        '<div style="font-size:11.5px;line-height:1.5;color:var(--text-base);">' + escHtml(T('tour.' + step.id + '.text', step.text)) + '</div>' +
        '<div style="display:flex;gap:6px;justify-content:flex-end;margin-top:10px;">' +
        (step.help ? '<button class="action-btn" style="padding:3px 9px;margin-right:auto;" onclick="showHelp(\'' + step.help + '\')" title="' + escAttr(T('tour.helptopic.tip', 'Open the full help topic (F1)')) + '">' + escHtml(T('tour.helptopic', 'Help topic')) + '</button>' : '') +
        (step.group ? '<button class="action-btn" style="padding:3px 9px;" onclick="tutorialSkipGroup()" title="' + escAttr(T('tour.skip.tip', 'Skip the rest of this section')) + '">' + escHtml(T('tour.skip', 'Skip section')) + '</button>' : '') +
        '<button class="action-btn" style="padding:3px 9px;" onclick="tutorialEnd()">' + escHtml(T('tour.leave', 'Leave tour')) + '</button>' +
        '<button class="action-btn" style="padding:3px 9px;" onclick="tutorialNext(-1)" ' + (_tourIdx === 0 ? 'disabled' : '') + '>' + escHtml(T('tour.back', 'Back')) + '</button>' +
        '<button class="action-btn agent-claude" style="padding:3px 12px;" onclick="tutorialNext(1)">' + (n === total ? T('tour.finish', 'Finish') : T('tour.next', 'Next')) + '</button></div></div>';
}

let _helpData = null;
async function _helpLoad(force) {
    if (_helpData && !force) return _helpData;
    try {
        const r = await fetch('help.php?action=get');
        const d = await r.json();
        if (d.ok && d.help) _helpData = d.help;
    } catch (e) {}
    return _helpData;
}
async function showHelp(topicId) {
    const m = document.getElementById('help-modal');
    if (!m) return;
    await _helpLoad();
    const si = document.getElementById('help-search');
    if (si) { si.value = ''; }
    _helpRenderToc(topicId);
    _helpShowTopic(topicId);
    m.style.display = 'flex';
    const inner = document.getElementById('help-modal-inner');
    if (inner) {
        const saved = JSON.parse(localStorage.getItem('cockpit_help_pos') || 'null');
        if (saved) {
            inner.style.left = saved.x + 'px'; inner.style.top = saved.y + 'px';
            if (saved.w) inner.style.width = saved.w + 'px';
            if (saved.h) inner.style.height = saved.h + 'px';
        } else {
            inner.style.left = Math.max(0, (window.innerWidth - inner.offsetWidth) / 2) + 'px';
            inner.style.top = Math.max(0, (window.innerHeight - inner.offsetHeight) / 2) + 'px';
        }
    }
    if (si && !topicId) setTimeout(() => si.focus(), 100);
}
(function(){
    const bar = document.getElementById('help-modal-titlebar');
    const inner = document.getElementById('help-modal-inner');
    if (!bar || !inner) return;
    let dx=0, dy=0, mx=0, my=0, dragging=false;
    bar.addEventListener('mousedown', e => {
        if (e.target.closest('button')) return;
        dragging = true; mx = e.clientX; my = e.clientY;
        dx = inner.offsetLeft; dy = inner.offsetTop;
        e.preventDefault();
    });
    document.addEventListener('mousemove', e => {
        if (!dragging) return;
        inner.style.left = (dx + e.clientX - mx) + 'px';
        inner.style.top = (dy + e.clientY - my) + 'px';
    });
    document.addEventListener('mouseup', () => {
        if (!dragging) return;
        dragging = false;
        _helpSavePos();
    });
    const ro = new ResizeObserver(() => _helpSavePos());
    ro.observe(inner);
    function _helpSavePos() {
        if (inner.offsetParent === null) return;
        localStorage.setItem('cockpit_help_pos', JSON.stringify({
            x: inner.offsetLeft, y: inner.offsetTop,
            w: inner.offsetWidth, h: inner.offsetHeight
        }));
    }
})();
function hideHelp() {
    const m = document.getElementById('help-modal');
    if (m) m.style.display = 'none';
}
function _helpFilter(query) {
    const q = query.trim().toLowerCase();
    if (!_helpData) return;
    const toc = document.getElementById('help-toc');
    const content = document.getElementById('help-content');
    if (!toc || !content) return;
    const topics = _helpData.topics || {};
    if (!q) { _helpRenderToc(null); _helpShowTopic(null); return; }
    const matches = [];
    if (_helpData.welcome) {
        const w = _helpData.welcome;
        if ((w.title + ' ' + w.body).toLowerCase().includes(q)) matches.push({ id: '__welcome__', title: w.title, body: w.body });
    }
    for (const [id, t] of Object.entries(topics)) {
        if ((t.title + ' ' + t.body).toLowerCase().includes(q)) matches.push({ id, title: t.title, body: t.body });
    }
    let tocHtml = '<div style="padding:4px 14px;font-size:10px;color:var(--text-dim);">' + matches.length + ' result' + (matches.length !== 1 ? 's' : '') + '</div>';
    matches.forEach(m => {
        tocHtml += '<div class="help-toc-item" data-id="' + escAttr(m.id) + '" style="padding:5px 14px;cursor:pointer;font-size:11.5px;color:var(--text-base);">' + escHtml(m.title) + '</div>';
    });
    toc.innerHTML = tocHtml;
    toc.querySelectorAll('.help-toc-item').forEach(el =>
        el.addEventListener('click', () => { _helpShowTopic(el.dataset.id); el.style.background = 'var(--bg-active)'; el.style.color = 'var(--gemini)'; }));
    if (matches.length > 0) {
        _helpShowTopic(matches[0].id);
        const first = toc.querySelector('.help-toc-item');
        if (first) { first.style.background = 'var(--bg-active)'; first.style.color = 'var(--gemini)'; }
    } else {
        content.innerHTML = '<div style="color:var(--text-dim);padding:20px;">No topics match "' + escHtml(q) + '"</div>';
    }
    // Highlight matches in content
    if (q.length >= 2 && matches.length > 0) {
        const escaped = q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        content.innerHTML = content.innerHTML.replace(new RegExp('(' + escaped + ')', 'gi'),
            '<mark style="background:var(--accent-amber);color:var(--bg-base);padding:0 2px;border-radius:2px;">$1</mark>');
    }
}
function _helpSetSort(v) {
    try { localStorage.setItem('cockpit_help_sort', v); } catch(e){}
    _helpRenderToc(window._helpActive);
}
function _helpRenderToc(active) {
    const toc = document.getElementById('help-toc');
    if (!toc || !_helpData) return;
    window._helpActive = active;
    const topics = _helpData.topics || {};
    let mode = 'alpha';
    try { mode = localStorage.getItem('cockpit_help_sort') || 'alpha'; } catch(e){}
    const sortSel = document.getElementById('help-sort'); if (sortSel) sortSel.value = mode;

    const item = (id, title) =>
        '<div class="help-toc-item' + (id === active ? ' active' : '') + '" data-id="' + escAttr(id) + '">' +
        escHtml(title || id) + '</div>';

    let html = '';
    if (_helpData.welcome) {
        html += '<div class="help-toc-item help-toc-welcome' + ((active === '__welcome__' || !active) ? ' active' : '') +
            '" data-id="__welcome__"><span class="material-symbols-rounded ico ico-fill">star</span> ' + escHtml(_helpData.welcome.title || 'Welcome') + '</div>';
    }
    let entries = Object.keys(topics).map(id => ({ id, title: topics[id].title || id }));
    if (mode === 'alpha' || mode === 'grouped') {
        entries.sort((a, b) => a.title.localeCompare(b.title));
    }
    if (mode === 'grouped') {
        let lastLetter = '';
        entries.forEach(e => {
            const L = (e.title[0] || '#').toUpperCase();
            if (L !== lastLetter) { html += '<div class="help-group-letter">' + escHtml(L) + '</div>'; lastLetter = L; }
            html += item(e.id, e.title);
        });
    } else {
        html += entries.map(e => item(e.id, e.title)).join('');
    }
    toc.innerHTML = html;
    toc.querySelectorAll('.help-toc-item').forEach(el =>
        el.addEventListener('click', () => { _helpRenderToc(el.dataset.id); _helpShowTopic(el.dataset.id); }));
}
function _helpNavStep(dir) {
    const toc = document.getElementById('help-toc');
    if (!toc) return;
    const items = Array.from(toc.querySelectorAll('.help-toc-item'));
    if (!items.length) return;
    const active = window._helpActive || '__welcome__';
    let idx = items.findIndex(el => el.dataset.id === active);
    if (idx === -1) idx = 0;
    idx = (idx + dir + items.length) % items.length;
    const id = items[idx].dataset.id;
    _helpRenderToc(id);
    _helpShowTopic(id);
    items[idx].scrollIntoView({ block: 'nearest' });
}
let _helpHist = [];
let _helpHistPos = -1;
function _helpShowTopic(topicId, _fromHist) {
    const c = document.getElementById('help-content');
    const t = document.getElementById('help-title');
    if (!c || !_helpData) return;
    const topics = _helpData.topics || {};
    let topic = (topicId && topicId !== '__welcome__') ? topics[topicId] : null;
    if (!topic) topic = _helpData.welcome || topics[Object.keys(topics)[0]] || { title: 'Help', body: '' };
    if (t) t.textContent = topic.title || 'Help';
    c.innerHTML = topic.body || '';
    c.scrollTop = 0;
    if (!_fromHist) {
        const id = topicId || '__welcome__';
        if (_helpHist[_helpHistPos] !== id) {
            _helpHist = _helpHist.slice(0, _helpHistPos + 1);
            _helpHist.push(id);
            _helpHistPos = _helpHist.length - 1;
        }
    }
}
function _helpBack() {
    if (_helpHistPos <= 0) return;
    _helpHistPos--;
    const id = _helpHist[_helpHistPos];
    _helpRenderToc(id);
    _helpShowTopic(id, true);
}
function _helpForward() {
    if (_helpHistPos >= _helpHist.length - 1) return;
    _helpHistPos++;
    const id = _helpHist[_helpHistPos];
    _helpRenderToc(id);
    _helpShowTopic(id, true);
}

// Context help: track the cursor; F1 opens the topic for the nearest [data-help]
// ancestor of the element under the mouse (else the unified guide).
let _helpMouseX = 0, _helpMouseY = 0;
document.addEventListener('mousemove', e => { _helpMouseX = e.clientX; _helpMouseY = e.clientY; });
// Close on Escape, click outside; ? = unified guide; F1 = context help
document.addEventListener('keydown', e => {
    if (e.key === 'Escape') hideHelp();
    if (e.key === '?' && !['INPUT','TEXTAREA'].includes(document.activeElement?.tagName)) showHelp();
    if (e.key === 'F1') {
        e.preventDefault();
        let el = document.elementFromPoint(_helpMouseX, _helpMouseY);
        let topic = null;
        while (el) { if (el.dataset && el.dataset.help) { topic = el.dataset.help; break; } el = el.parentElement; }
        showHelp(topic);
    }
});
document.addEventListener('click', e => {
    if (e.target?.id === 'help-modal') hideHelp();
});
// First-run welcome — show the guide (welcome topic) once.
document.addEventListener('DOMContentLoaded', () => {
    setTimeout(() => {
        try {
            if (!localStorage.getItem('cockpit_welcomed')) {
                showHelp('__welcome__');
                localStorage.setItem('cockpit_welcomed', '1');
            }
        } catch (e) {}
    }, 1200);
});
let rpUploadKind  = null;
let rpItemsCache  = {};
let rpFilterState = {};   // C6: per-kind {lang, text} filter state
let rpProposalsCache = [];

// ── Generic list loader ──────────────────────────────────────────────────────
async function rpRefreshList(kind) {
    const listEl = document.getElementById('rp-list-' + kind);
    if (!listEl) return;
    listEl.innerHTML = '<div class="sidebar-empty">Loading…</div>';
    try {
        const url = 'library.php?action=list&kind=' + encodeURIComponent(kind)
                  + '&project=' + encodeURIComponent(currentProject || '');
        const res  = await fetch(url);
        const data = await res.json();
        if (!data.ok) {
            listEl.innerHTML = '<div class="sidebar-empty">Error: ' + escHtml(data.error || 'unknown') + '</div>';
            return;
        }
        rpItemsCache[kind] = data.items || [];
        rpRenderList(kind);
    } catch(e) {
        listEl.innerHTML = '<div class="sidebar-empty">Failed to load.</div>';
    }
}

function rpRenderList(kind) {
    const listEl = document.getElementById('rp-list-' + kind);
    const items  = rpItemsCache[kind] || [];
    if (!items.length) {
        listEl.innerHTML = '<div class="sidebar-empty">Nothing in catalog yet.</div>';
        return;
    }
    // C6: filter bar for snippets/sources (by language + free text).
    // Filter state is kept per-kind on the cache object.
    rpFilterState = rpFilterState || {};
    const fs = rpFilterState[kind] || { lang: '', text: '' };
    rpFilterState[kind] = fs;

    let filtered = items.slice();
    if ((kind === 'snippets' || kind === 'sources' || kind === 'code')) {
        if (fs.lang) filtered = filtered.filter(it => (it.lang || '').toLowerCase() === fs.lang.toLowerCase());
        if (fs.text) {
            const q = fs.text.toLowerCase();
            filtered = filtered.filter(it =>
                (it.title || '').toLowerCase().includes(q) ||
                (it.notes || '').toLowerCase().includes(q) ||
                (it.file  || '').toLowerCase().includes(q));
        }
    }
    const sorted = filtered.sort((a, b) => {
        if (a.scope !== b.scope) return a.scope === 'project' ? -1 : 1;
        return (b.updated || '').localeCompare(a.updated || '');
    });
    listEl.innerHTML = '';

    // Books: one COLLAPSIBLE header per book, with its chapters nested inside and
    // folded away by default. One novel is 20-40 chapter rows; three books and the
    // Library is a wall of near-identical titles you cannot read past. Collapsed by
    // default means the panel shows you your books, not their contents.
    //
    // Removal stays on the header for the same reason it was put there: a novel is
    // not something you delete a row at a time, and the usual reason to remove one
    // is that the split went wrong.
    const bookItems = new Set();
    if (kind === 'library') {
        const books = new Map();
        for (const it of sorted) {
            const tags = it.tags || [];
            if (!tags.includes('book')) continue;
            const name = tags.find(t => t !== 'book');
            if (!name) continue;
            if (!books.has(name)) books.set(name, []);
            books.get(name).push(it);
            bookItems.add(it);
        }
        for (const [name, chapters] of books) {
            const n    = chapters.length;
            const open = _rpOpenBooks.has(name);

            const row = document.createElement('div');
            row.style.cssText = 'display:flex;align-items:center;gap:6px;padding:4px 6px;margin-bottom:3px;' +
                'background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:4px;font-size:11px;cursor:pointer;';
            row.title = T('msg.show.or.hide.this.book.s.chapters', 'Show or hide this book’s chapters');
            const chev = document.createElement('span');
            chev.className = 'material-symbols-rounded';
            chev.style.cssText = 'font-size:14px;color:var(--text-dim);';
            chev.textContent = open ? 'expand_more' : 'chevron_right';
            const ico = document.createElement('span');
            ico.className = 'material-symbols-rounded';
            ico.style.cssText = 'font-size:13px;color:var(--text-dim);';
            ico.textContent = T('msg.menu.book', 'menu_book');
            const lbl = document.createElement('span');
            lbl.style.cssText = 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;';
            lbl.textContent = name + '  \u00b7  ' + n + ' chapter' + (n === 1 ? '' : 's');

            const body = document.createElement('div');
            body.style.cssText = 'margin:0 0 6px 10px;padding-left:6px;border-left:1px solid var(--border-dim);' +
                                 'display:' + (open ? '' : 'none') + ';';
            chapters.forEach(it => body.appendChild(rpBuildItemEl(kind, it)));

            const btn = document.createElement('button');
            btn.className = 'action-btn';
            btn.style.cssText = 'font-size:9.5px;padding:1px 6px;';
            btn.textContent = T('msg.remove.book', 'Remove book');
            btn.title = T('msg.remove.all.of.this.book.s.chapters.from.the', 'Remove all of this book’s chapters from the Library (the book file itself is not touched)');
            btn.onclick = async (ev) => {
                ev.stopPropagation();                 // the header row is a toggle
                if (!await cockpitConfirm('Remove book?',
                        'Remove all ' + n + ' chapters of "' + name + '" from the Library? The book file itself is not touched.',
                        'Remove', { danger: true })) return;
                btn.disabled = true;
                try {
                    const r = await (await fetch('library.php', {
                        method: 'POST', headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ action: 'delete_book', book: name, scope: 'global' }),
                    })).json();
                    if (!r.ok) { btn.disabled = false; appendSystem(T('msg.icon.error.error', '[[icon:error]] {error}', {error: (r.error || 'remove failed')})); return; }
                    appendSystem(T('msg.icon.menu.book.removed.removed.chapter.s.of', '[[icon:menu_book]] Removed {removed} chapter(s) of "{name}" from the Library.', {removed: r.removed, name: name}));
                    _rpOpenBooks.delete(name);
                    rpRefreshList('library');
                } catch (e) { btn.disabled = false; appendSystem(T('msg.icon.error.message', '[[icon:error]] {message}', {message: e.message})); }
            };

            row.onclick = () => {
                const nowOpen = body.style.display === 'none';
                body.style.display = nowOpen ? '' : 'none';
                chev.textContent   = nowOpen ? 'expand_more' : 'chevron_right';
                if (nowOpen) _rpOpenBooks.add(name); else _rpOpenBooks.delete(name);
            };

            row.append(chev, ico, lbl, btn);
            listEl.appendChild(row);
            listEl.appendChild(body);
        }
    }

    // Render the filter bar (snippets/sources/code only)
    if (kind === 'snippets' || kind === 'sources' || kind === 'code') {
        const langs = Array.from(new Set(items.map(it => (it.lang || '').trim()).filter(Boolean))).sort();
        const bar = document.createElement('div');
        bar.className = 'rp-filter-bar';
        bar.style.cssText = 'display:flex;gap:4px;align-items:center;padding:3px 2px 6px;flex-wrap:wrap;';
        bar.innerHTML =
            '<select class="rp-filter-lang" style="font-size:10px;background:var(--bg-base);color:var(--text-base);border:1px solid var(--border-dim);border-radius:3px;padding:2px 4px;">' +
            '<option value="">All languages</option>' +
            langs.map(l => '<option value="' + escHtml(l) + '"' + (fs.lang===l?' selected':'') + '>' + escHtml(l) + '</option>').join('') +
            '</select>' +
            '<input class="rp-filter-text" type="text" placeholder="filter…" value="' + escHtml(fs.text) + '" ' +
            'style="flex:1;min-width:60px;font-size:10px;background:var(--bg-base);color:var(--text-base);border:1px solid var(--border-dim);border-radius:3px;padding:2px 5px;">' +
            '<span style="font-size:9px;color:var(--text-muted);">' + sorted.length + '/' + items.length + '</span>';
        bar.querySelector('.rp-filter-lang').addEventListener('change', e => {
            fs.lang = e.target.value; rpRenderList(kind);
        });
        const txtEl = bar.querySelector('.rp-filter-text');
        txtEl.addEventListener('input', e => {
            fs.text = e.target.value;
            // re-render but keep focus + caret in the filter box
            rpRenderList(kind);
            const again = document.querySelector('#rp-list-' + kind + ' .rp-filter-text');
            if (again) { again.focus(); again.setSelectionRange(again.value.length, again.value.length); }
        });
        listEl.appendChild(bar);
    }

    if (!sorted.length) {
        const none = document.createElement('div');
        none.className = 'sidebar-empty';
        none.innerHTML = 'No items match the filter.';
        listEl.appendChild(none);
        return;
    }
    // Chapters already went inside their book's fold above; rendering them again
    // here is what the fold is there to prevent.
    sorted.filter(it => !bookItems.has(it)).forEach(it => listEl.appendChild(rpBuildItemEl(kind, it)));
}

function rpBuildItemEl(kind, item) {
    const div = document.createElement('div');
    div.className = 'rp-item';
    div.dataset.id = item.id;
    div.dataset.scope = item.scope;

    const scopeBadge = item.scope === 'project' ? 'rp-scope-project' : 'rp-scope-global';
    const scopeText  = item.scope === 'project' ? 'PROJ' : 'GLOBAL';

    let title = escHtml(item.title || item.id || '(untitled)');
    if (item.lang) title += ' <span style="opacity:0.5;font-weight:400;">[' + escHtml(item.lang) + ']</span>';

    // Meta line varies by kind
    let meta = '';
    if (kind === 'library') {
        const loc = item.location || '';
        const isUrl = (item.kind === 'url') || /^https?:\/\//i.test(loc);
        meta = (isUrl ? '<span class="material-symbols-rounded ico">link</span> ' : '<span class="material-symbols-rounded ico">description</span> ') + escHtml(loc);
        if (item.notes) meta += '<br><span style="opacity:0.7;">' + escHtml(item.notes) + '</span>';
    } else if (kind === 'snippets' || kind === 'sources') {
        const parts = [];
        if (item.file) parts.push('<span class="material-symbols-rounded ico">description</span> ' + escHtml(item.file));
        if (item.size) parts.push((item.size) + ' B');
        if (item.notes) parts.push(escHtml(item.notes));
        meta = parts.join('  ·  ');
    } else if (kind === 'code') {
        if (item.source) meta = 'from: ' + escHtml(item.source);
        if (item.size)   meta += '  ·  ' + item.size + ' B';
    }

    div.innerHTML =
        '<div class="rp-item-hdr">' +
            '<span class="rp-item-title">' + title + '</span>' +
            '<span class="rp-item-scope ' + scopeBadge + '">' + scopeText + '</span>' +
        '</div>' +
        (meta ? '<div class="rp-item-meta">' + meta + '</div>' : '') +
        '<div class="rp-item-body">Loading...</div>' +
        '<div class="rp-item-actions">' +
            (kind === 'library' && item.location
                ? '<button class="rp-action-btn" data-act="open">Open ↗</button>'
                : '') +
            ((kind === 'snippets' || kind === 'sources') && item.file
                ? '<button class="rp-action-btn" data-act="prompt">→ Prompt</button>'
                : '') +
            '<button class="rp-action-btn" data-act="move">' +
                (item.scope === 'project' ? '⤴ Make Global' : '⤵ To Project') +
            '</button>' +
            '<button class="rp-action-btn" data-act="edit">Edit</button>' +
            '<button class="rp-action-btn" data-act="delete">Delete</button>' +
        '</div>';

    div.addEventListener('click', async e => {
        const act = e.target.dataset?.act;
        if (act) {
            e.stopPropagation();
            rpItemAction(kind, item, act);
            return;
        }
        const wasActive = div.classList.contains('active');
        document.querySelectorAll('#rp-list-' + kind + ' .rp-item.active')
            .forEach(el => el.classList.remove('active'));
        if (!wasActive) {
            div.classList.add('active');
            // Lazy-load content for snippets/sources/code on first activation
            const body = div.querySelector('.rp-item-body');
            if ((kind === 'snippets' || kind === 'sources' || kind === 'code') && item.file && body) {
                try {
                    const url = 'library.php?action=read_content'
                              + '&kind=' + kind
                              + '&project=' + encodeURIComponent(currentProject || '')
                              + '&scope='   + item.scope
                              + '&id='      + encodeURIComponent(item.id);
                    const r = await fetch(url);
                    const d = await r.json();
                    body.textContent = d.ok ? d.content : ('Error: ' + (d.error || ''));
                } catch (err) {
                    body.textContent = T('msg.failed.to.load', 'Failed to load.');
                }
            } else if (kind === 'library') {
                const loc = item.location || '';
                body.textContent = (loc ? 'Location: ' + loc + '\n\n' : '') + (item.notes || '(no notes)');
            } else if (body) {
                body.textContent = T('msg.no.preview.available', '(no preview available)');
            }
        }
    });

    return div;
}

async function rpItemAction(kind, item, act) {
    if (act === 'prompt') {
        // Read the file content first
        const url = 'library.php?action=read_content'
                  + '&kind=' + kind
                  + '&project=' + encodeURIComponent(currentProject || '')
                  + '&scope='   + item.scope
                  + '&id='      + encodeURIComponent(item.id);
        const r = await fetch(url);
        const d = await r.json();
        if (!d.ok) { appendError(T('msg.read.failed.error', 'Read failed: {error}', {error: (d.error || '')})); return; }
        promptInput.value = d.content + (promptInput.value ? '\n\n' + promptInput.value : '');
        promptInput.focus();
        appendSystem(T('msg.inserted.kind.title.into.prompt', 'Inserted {kind} "{title}" into prompt', {kind: kind, title: (item.title || item.id)}));
        return;
    }
    if (act === 'open' && item.location) {
        if (/^https?:\/\//i.test(item.location)) {
            window.open(item.location, '_blank');
        } else {
            // Local path — try to open in the previewer
            appendSystem(T('msg.local.path.location', 'Local path: {location}', {location: item.location}));
        }
        return;
    }
    if (act === 'move') {
        const from = item.scope;
        const to   = item.scope === 'project' ? 'global' : 'project';
        if (to === 'project' && (!currentProject || currentProject === '_standalone')) {
            appendError(T('msg.select.a.project.first', 'Select a project first.')); return;
        }
        const res = await fetch('library.php', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                action:'move', kind, project:currentProject,
                id:item.id, from, to
            })
        });
        const data = await res.json();
        if (!data.ok) { appendError(T('msg.move.failed.error', 'Move failed: {error}', {error: (data.error || '')})); return; }
        appendSystem(T('msg.moved.title.to', 'Moved "{title}" → {to}', {title: (item.title || item.id), to: to}));
        rpRefreshList(kind);
        return;
    }
    if (act === 'edit') {
        // Snippets/sources → floating code editor; library refs → floating form
        // (Title + Location fields, Notes as the editable body).
        if (kind === 'snippets' || kind === 'sources') editEntryInFloatingEditor(kind, item);
        else if (kind === 'library')                   editLibraryInFloatingEditor(item);
        else                                           rpAddItem(kind, item);
        return;
    }
    if (act === 'delete') {
        if (!await cockpitConfirm('Delete entry?', 'Delete "' + (item.title || item.id) + '"' +
                     ((kind === 'snippets' || kind === 'sources') ? ' (incl. file on disk)?' : '?'), 'Delete', {danger:true, icon:'delete'})) return;
        const res = await fetch('library.php', {
            method: 'POST', headers: {'Content-Type':'application/json'},
            body: JSON.stringify({
                action:'delete', kind, project:currentProject,
                scope:item.scope, id:item.id
            })
        });
        const data = await res.json();
        if (!data.ok) { appendError(T('msg.delete.failed.error', 'Delete failed: {error}', {error: (data.error || '')})); return; }
        rpRefreshList(kind);
    }
}

// Create OR edit a snippet/source entry in the floating code editor.
//   item == null  → create a new entry (empty editor)
//   item provided → edit it (loads raw file content)
// Title/lang/notes are editable fields; Save persists metadata + file content.
// "Save as…" always creates a NEW entry from the current buffer.
async function editEntryInFloatingEditor(kind, item) {
    const isEdit = !!(item && item.id);
    const cur = item || {};
    const singular = kind.replace(/s$/, '');

    let content = '';
    if (isEdit) {
        try {
            const url = 'library.php?action=read_content&kind=' + encodeURIComponent(kind) +
                        '&project=' + encodeURIComponent(currentProject || '') +
                        '&scope='   + encodeURIComponent(cur.scope || 'global') +
                        '&id='      + encodeURIComponent(cur.id);
            const r = await fetch(url);
            const d = await r.json();
            if (d.ok) content = d.content || '';
            else appendError(T('msg.could.not.load.content.error', 'Could not load content: {error}', {error: (d.error || '')}));
        } catch (e) { appendError(T('msg.read.failed.message', 'Read failed: {message}', {message: e.message})); return; }
    }

    // Create a brand-new entry (used by create-mode Save and by Save as…).
    const _addEntry = async (newContent, vals) => {
        let scope = 'global';
        if (currentProject && currentProject !== '_standalone') {
            scope = await cockpitChoice('Save scope', 'Where to save?', [
                {label: 'Project (' + currentProject + ')', value: 'project', accent: 'var(--accent-blue)'},
                {label: 'Global', value: 'global'}
            ]);
            if (scope === null) return { ok:false, error: 'cancelled' };
            scope = scope === 'project' ? 'project' : 'global';
        }
        const r = await fetch('library.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
                action:'add', kind, project:currentProject, scope,
                item: { title:(vals.title||'').trim() || 'Untitled', lang:(vals.lang||'').trim(), notes:vals.notes||'' },
                content: newContent,
            })
        });
        const d = await r.json();
        if (!d.ok) return { ok:false, error: d.error || 'unknown' };
        appendSystem(T('msg.added.singular.title', 'Added {singular} "{title}"', {singular: singular, title: ((vals.title||'').trim() || 'Untitled')}));
        rpRefreshList(kind);
        return { ok:true };
    };

    openFloatingEditor({
        id: kind + '-' + (isEdit ? cur.id : 'new'),
        heading: (isEdit ? 'Editing ' : 'New ') + singular + (isEdit ? ': ' + (cur.title || cur.id) : ''),
        filename: cur.file || (cur.lang ? '(' + cur.lang + ')' : ''),
        content,
        language: cur.lang || '',
        fields: [
            { key:'title', label:'Title', value:cur.title || '' },
            { key:'lang',  label:'Language', type:'language', value:cur.lang || '' },
            { key:'notes', label:'Notes',  value:cur.notes || '' },
        ],
        onSave: async (newContent, vals) => {
            if (!isEdit) return _addEntry(newContent, vals);
            try {
                const r = await fetch('library.php', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({
                        action:'edit', kind, project:currentProject,
                        scope: cur.scope || 'global', id: cur.id,
                        item: { title:(vals.title||'').trim(), lang:(vals.lang||'').trim(), notes:vals.notes||'' },
                        content: newContent,
                    })
                });
                const d = await r.json();
                if (!d.ok) return { ok:false, error: d.error || 'unknown' };
                appendSystem(T('msg.updated.singular.title', 'Updated {singular} "{title}"', {singular: singular, title: (vals.title || cur.id)}));
                rpRefreshList(kind);
                return { ok:true };
            } catch (e) { return { ok:false, error: e.message }; }
        },
        onSaveAs: async (newContent, vals) => _addEntry(newContent, vals),
    });
}

// Create OR edit a LIBRARY reference (title + location + notes) in the floating
// editor. Library entries have no code file, so the body holds the free-form
// Notes; Location/kind are metadata fields.
//   item == null → create new.
async function editLibraryInFloatingEditor(item) {
    const isEdit = !!(item && item.id);
    const cur = item || {};

    const _persist = async (notes, vals, mode, id) => {
        const location = (vals.location || '').trim();
        const body = {
            action: mode, kind: 'library', project: currentProject,
            scope: cur.scope || 'global',
            item: {
                title: (vals.title || '').trim() || 'Untitled',
                location,
                kind: /^https?:\/\//i.test(location) ? 'url' : 'path',
                notes,
            },
        };
        if (mode === 'edit') body.id = id;
        else {
            // New library entry: choose scope like rpAddItem does.
            if (currentProject && currentProject !== '_standalone') {
                const _sc = await cockpitChoice('Save scope', 'Where to save?', [
                    {label: 'Project (' + currentProject + ')', value: 'project', accent: 'var(--accent-blue)'},
                    {label: 'Global', value: 'global'}
                ]);
                if (_sc === null) return { ok:false, error: 'cancelled' };
                body.scope = _sc === 'project' ? 'project' : 'global';
            } else body.scope = 'global';
        }
        const r = await fetch('library.php', {
            method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(body)
        });
        const d = await r.json();
        if (!d.ok) return { ok:false, error: d.error || 'unknown' };
        appendSystem(T('msg.mode.library.title', '{mode} library "{title}"', {mode: (mode === 'edit' ? 'Updated' : 'Added'), title: body.item.title}));
        rpRefreshList('library');
        return { ok:true };
    };

    openFloatingEditor({
        id: 'library-' + (isEdit ? cur.id : 'new'),
        heading: (isEdit ? 'Editing library reference' : 'New library reference'),
        filename: cur.location || '',
        content: cur.notes || '',
        language: '',                       // notes are plain text — no highlighting
        fields: [
            { key:'title',    label:'Title',           value:cur.title || '' },
            { key:'location', label:'Location (path or URL)', value:cur.location || '', placeholder:'/path/to/ref or https://…' },
        ],
        onSave:   async (notes, vals) => _persist(notes, vals, isEdit ? 'edit' : 'add', cur.id),
        onSaveAs: async (notes, vals) => _persist(notes, vals, 'add', null),
    });
}

// ── Add / Edit dialog (kind-specific) ────────────────────────────────────────
async function rpAddItem(kind, existing) {
    const isEdit = !!existing;
    const cur    = existing || {};
    const title  = await cprompt(kind.toUpperCase() + ' — title:', cur.title || '');
    if (title === null) return;

    let item = { title: title.trim() };

    if (kind === 'library') {
        const loc = await cprompt('Location (path or URL):', cur.location || '');
        if (loc === null) return;
        item.location = loc.trim();
        item.kind     = /^https?:\/\//i.test(item.location) ? 'url' : 'path';
        const notes   = await cprompt('Notes (optional):', cur.notes || '');
        if (notes !== null) item.notes = notes;

    } else if (kind === 'snippets' || kind === 'sources') {
        const lang = await cprompt('Language (pas, php, sh, js, ...):', cur.lang || '');
        if (lang === null) return;
        item.lang = lang.trim();

        const notes = await cprompt('Notes (optional):', cur.notes || '');
        if (notes !== null) item.notes = notes;

        // For new items, ask for content; for edits, allow blank to leave file untouched
        const content = await cprompt('Content (function body / file content):', cur.content || '');
        if (content === null) return;
        if (content) item.content = content;
    }

    // Scope decision
    let scope = cur.scope || 'global';
    if (!isEdit && currentProject && currentProject !== '_standalone') {
        scope = await cockpitChoice('Save scope', 'Where to save?', [
            {label: 'Project (' + currentProject + ')', value: 'project', accent: 'var(--accent-blue)'},
            {label: 'Global', value: 'global'}
        ]);
        if (scope === null) return;
        scope = scope === 'project' ? 'project' : 'global';
    }

    // The new library.php expects `content` at top level (not inside item)
    // for snippets/sources, so it can be saved as a real file on disk.
    const content = item.content;
    delete item.content;

    const body = isEdit
        ? { action:'edit', kind, project:currentProject, scope, id:cur.id, item, content }
        : { action:'add',  kind, project:currentProject, scope, item, content };
    const res  = await fetch('library.php', {
        method:'POST', headers:{'Content-Type':'application/json'},
        body: JSON.stringify(body)
    });
    const data = await res.json();
    if (!data.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (data.error || '')})); return; }
    appendSystem((isEdit ? 'Updated' : 'Added') + ' ' + kind + ' "' + title + '"');
    rpRefreshList(kind);
}

// ── Upload from disk (Code / Snippets / Sources) ─────────────────────────────
function rpUploadFile(kind) {
    rpUploadKind = kind;
    cockpitPickIntoInput('rp-upload-input',[],'Upload file');
}

async function rpHandleUpload(e) {
    const file = e.target.files?.[0];
    if (!file || !rpUploadKind) return;

    // ZIP upload — only for sources (whole projects)
    if (rpUploadKind === 'sources' && /\.zip$/i.test(file.name)) {
        if (file.size > 10 * 1024 * 1024) {
            appendError(T('msg.zip.too.large.max.10mb.name', 'ZIP too large (max 10MB): {name}', {name: file.name}));
            e.target.value = ''; return;
        }
        const reader = new FileReader();
        reader.onload = async () => {
            const b64 = reader.result.split(',')[1];   // strip data: prefix
            const scope = (currentProject && currentProject !== '_standalone') ? 'project' : 'global';
            const res = await fetch('library.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({
                    action:'upload_zip', kind:'sources',
                    project:currentProject, scope,
                    filename: file.name, data_b64: b64,
                    title: file.name.replace(/\.zip$/i, '')
                })
            });
            const data = await res.json();
            if (!data.ok) { appendError(T('msg.zip.upload.failed.error', 'ZIP upload failed: {error}', {error: (data.error || '')})); return; }
            appendSystem(T('msg.extracted.zip.name.sources.scope', 'Extracted ZIP "{name}" → sources ({scope})', {name: file.name, scope: scope}));
            rpRefreshList('sources');
            rpUploadKind = null;
        };
        reader.readAsDataURL(file);
        e.target.value = '';
        return;
    }

    // Regular text file upload
    if (file.size > 1024 * 1024) {
        appendError(T('msg.file.too.large.max.1mb.name', 'File too large (max 1MB): {name}', {name: file.name}));
        e.target.value = ''; return;
    }
    const reader = new FileReader();
    reader.onload = async () => {
        const ext  = (file.name.split('.').pop() || '').toLowerCase();
        const content = reader.result;
        const item = {
            title:   file.name,
            lang:    ext,
            notes:   'uploaded ' + new Date().toISOString().slice(0,10),
        };
        const scope = (currentProject && currentProject !== '_standalone') ? 'project' : 'global';
        const res   = await fetch('library.php', {
            method:'POST', headers:{'Content-Type':'application/json'},
            body: JSON.stringify({
                action:'add', kind:rpUploadKind, project:currentProject, scope,
                item, content
            })
        });
        const data = await res.json();
        if (!data.ok) { appendError(T('msg.upload.failed.error', 'Upload failed: {error}', {error: (data.error || '')})); return; }
        appendSystem(T('msg.uploaded.name.rpuploadkind.scope', 'Uploaded "{name}" → {rpuploadkind} ({scope})', {name: file.name, rpuploadkind: rpUploadKind, scope: scope}));
        rpRefreshList(rpUploadKind);
        rpUploadKind = null;
    };
    reader.readAsText(file);
    e.target.value = '';
}

// =============================================================================
// RAG SEARCH — keyword search across snippets, library, sources
// Results appear as Pending Proposals so user can approve injection
// =============================================================================
async function rpSearch(kind) {
    const input = document.getElementById('rp-search-' + kind);
    const q = input ? input.value.trim() : '';
    if (!q) { rpRefreshList(kind); return; }

    const listEl = document.getElementById('rp-list-' + kind);
    if (listEl) listEl.innerHTML = '<div class="sidebar-empty">Searching…</div>';

    try {
        const url = 'library.php?action=search'
                  + '&kind=' + encodeURIComponent(kind)
                  + '&q='    + encodeURIComponent(q)
                  + '&project=' + encodeURIComponent(currentProject || '')
                  + '&limit=10';
        const r = await fetch(url);
        const d = await r.json();

        if (!d.ok) {
            if (listEl) listEl.innerHTML = '<div class="sidebar-empty">Search failed: ' + escHtml(d.error||'') + '</div>';
            return;
        }

        if (!d.results || d.results.length === 0) {
            if (listEl) listEl.innerHTML = '<div class="sidebar-empty">No results for "' + escHtml(q) + '".<br>Try different keywords.</div>';
            return;
        }

        // Render results in the panel list — reuse rpItemsCache mechanism
        rpItemsCache[kind] = d.results.map(r => ({
            id:       r.id,
            title:    r.title || r.name || '—',
            lang:     r.language || r.lang || '',
            notes:    (r.purpose || '') + (r.from_book ? ' · From: ' + r.from_book : ''),
            scope:    r.scope || 'global',
            source:   r.source || '',
            size:     r.content ? r.content.length : 0,
            updated:  r.updated || '',
            _score:   r.score || 0,
            _content: r.content || '',
            _kind:    r.kind || kind,
        }));
        rpRenderList(kind);

        // Also offer as RAG proposals in Pending Proposals panel
        if (d.results.length > 0) {
            _ragOfferAsProposals(q, kind, d.results);
        }

    } catch(e) {
        if (listEl) listEl.innerHTML = '<div class="sidebar-empty">Error: ' + escHtml(e.message) + '</div>';
    }
}

// Offer RAG search results as Pending Proposals so user can inject them
function _ragOfferAsProposals(query, kind, results) {
    // Build a proposal block
    const label = 'RAG: ' + results.length + ' ' + kind + ' match' +
                  (results.length !== 1 ? 'es' : '') + ' for "' + query + '"';

    // Check if addProposal exists (from the proposals system)
    if (typeof addProposal === 'function') {
        results.slice(0, 3).forEach(r => {
            const content = r.content || r.source_code || '';
            const header  = '**' + (r.title||r.name||'?') + '** (' +
                            (r.kind||kind) + (r.language ? ' · ' + r.language : '') +
                            (r.from_book ? ' · from ' + r.from_book : '') + ')\n\n';
            const body    = r.kind === 'snippet'
                ? '```' + (r.language||'') + '\n' + content + '\n```'
                : content;
            addProposal({
                type:    'rag_inject',
                title:   (r.title || r.name || '?') + ' [' + (r.kind||kind) + ']',
                content: header + body,
                score:   r.score || 0,
                source:  'library.php',
            });
        });
        appendSystem(T('msg.rag.found.n.kind.results.for.query.see.pendi', 'RAG: found {n} {kind} results for "{query}" — see Pending Proposals.', {n: results.length, kind: kind, query: query}));
    }
}

// Global RAG search across ALL stores — called by agent or user command
// e.g. agent says "I want to search the library for Pascal file I/O"
async function ragSearchAll(query) {
    if (!query) return [];
    try {
        const r = await fetch('library.php?action=search&kind=all&limit=5'
                  + '&q=' + encodeURIComponent(query)
                  + '&project=' + encodeURIComponent(currentProject || ''));
        const d = await r.json();
        return d.ok ? (d.results || []) : [];
    } catch(e) { return []; }
}

// ── Auto-extract code blocks from agent responses (Code panel only) ──────────
// Auto-PROPOSE: every fenced code block in a NEW agent response is added to the
// Pending Proposals queue (kind:snippet). It stays there until the user approves
// it into Snippets or deletes it — nothing is auto-saved. Named via _codeMeta
// (name · type). Deduped by content so the same snippet isn't proposed twice.
async function rpExtractCodeBlocks(text, agentName) {
    if (!rpAutoExtract || !text) return;
    const re = /```([a-zA-Z0-9_+-]*)\n([\s\S]*?)```/g;
    const blocks = [];
    let m;
    while ((m = re.exec(text)) !== null) {
        const lang    = m[1] || '';
        const content = m[2].trim();
        if (content.length < 5) continue;
        blocks.push({ lang, content });
    }
    if (!blocks.length) return;

    let added = 0;
    for (const b of blocks) {
        // Session key mirrors the server hash: CODE + LANGUAGE only (not name).
        const key = (b.lang || '').toLowerCase() + '\u0000' + b.content;
        if (_rpProposedContent.has(key)) continue;
        _rpProposedContent.add(key);
        const meta  = (typeof _codeMeta === 'function') ? _codeMeta(b.content, b.lang) : { name:'', type:'snippet' };
        const lines = b.content.split('\n').length;
        const title = (meta.name ? meta.name + ' · ' : '') + meta.type +
                      (b.lang ? ' (' + b.lang + ')' : '');
        // Server is authoritative on dedup (hash of code+lang vs proposals AND
        // snippets) and on name-collision disambiguation. Count only what it
        // actually accepted.
        const res = await addProposal({
            kind:     'snippet',
            proposer: agentName || 'agent',
            title:    title,
            lang:     b.lang || '',
            notes:    lines + ' lines · from ' + (agentName || 'agent') + ' · ' +
                      new Date().toISOString().slice(11,16),
            content:  b.content,
            project:  (typeof currentProject !== 'undefined' ? currentProject : ''),
        });
        if (res && res.ok && !res.duplicate) added++;
    }
    if (added && typeof appendSystem === 'function') {
        appendSystem(T('msg.agentname.generated.added.code.blockadded2.a', '{agentname} generated {added} code block{added2} — added to Pending Proposals.', {agentname: (agentName ? (typeof agentDisplayName === 'function' ? agentDisplayName(agentName) : agentName.toUpperCase()) : 'Agent'), added: added, added2: (added > 1 ? 's' : '')}));
    }
}

// =============================================================================
// addProposal — write one proposal entry to proposals.json via library.php
//
// Called by:
//   - rpParseProposals()  when agent text contains %%PROPOSE:kind%% blocks
//   - _ragOfferAsProposals() for RAG search results
//
// Entry format stored in proposals.json:
//   { id, kind, proposer, ts, project, payload:{title,lang,content,notes} }
// =============================================================================
async function addProposal(opts) {
    try {
        const r = await fetch('library.php', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                action:   'add_proposal',
                kind:     opts.kind     || 'snippet',
                proposer: opts.proposer || 'agent',
                project:  opts.project  || (typeof currentProject !== 'undefined' ? currentProject : ''),
                payload: {
                    title:   opts.title   || '(no title)',
                    lang:    opts.lang    || '',
                    content: opts.content || '',
                    notes:   opts.notes   || '',
                },
            }),
        });
        const d = await r.json();
        if (d.ok && !d.duplicate && typeof rpRefreshProposals === 'function') {
            rpRefreshProposals();
        }
        return d;   // {ok, duplicate?, skipped?, hash?} — callers may inspect
    } catch(e) {
        return { ok: false };
    }
}

// =============================================================================
// rpParseProposals — scan agent response text for %%PROPOSE:kind%% blocks
//
// Expected agent syntax (kind = snippet | source | library):
//
//   %%PROPOSE:snippet%%
//   title: MyHelper
//   lang: pascal
//   notes: utility for file I/O
//   [code or content body]
//   %%END%%
//
// Tolerates common LLM mistakes:
//   - Backticks around the markers
//   - Stray whitespace / case mismatches
//   - 'proposed:' instead of 'PROPOSE:' (small models flip this)
//
// Multiple blocks in one response are all captured.
// =============================================================================
async function rpParseProposals(text, agentName) {
    if (!text) return;
    if (!/%%\s*(PROPOSE|proposed)\s*:/i.test(text)) return;

    const blockRe = /%%\s*(?:PROPOSE|proposed)\s*:\s*(snippet|source|library)\s*%%\s*([\s\S]*?)%%\s*END\s*%%/gi;
    let m;
    let found = 0;

    while ((m = blockRe.exec(text)) !== null) {
        const kind = m[1].toLowerCase();
        const body = m[2].trim();

        const meta  = { title: '', lang: '', notes: '' };
        const lines = body.split('\n');
        let contentStart = 0;

        for (let i = 0; i < lines.length; i++) {
            const kv = lines[i].match(/^(title|lang|notes|purpose)\s*:\s*(.+)$/i);
            if (kv) {
                const key = kv[1].toLowerCase();
                if (key === 'purpose') meta.notes = kv[2].trim();
                else meta[key] = kv[2].trim();
                contentStart = i + 1;
            } else {
                break;
            }
        }

        const content = lines.slice(contentStart).join('\n').trim();

        await addProposal({
            kind:     kind,
            proposer: agentName || 'agent',
            title:    meta.title || (kind + ' from ' + (agentName || 'agent')),
            lang:     meta.lang  || '',
            notes:    meta.notes || '',
            content:  content,
            project:  (typeof currentProject !== 'undefined' ? currentProject : ''),
        });
        found++;
    }

    if (found > 0 && typeof appendSystem === 'function') {
        appendSystem(
            T('msg.agentname.proposed.found.itemfound2.see.pend', '{agentname} proposed {found} item{found2} — see Pending Proposals.', {agentname: (agentName ? agentName.toUpperCase() : 'Agent'), found: found, found2: (found > 1 ? 's' : '')})
        );
    }
}

// ── PROPOSALS QUEUE — persistent bottom section ──────────────────────────────
async function rpRefreshProposals() {
    const el = document.getElementById('rp-proposals-list');
    if (!el) return;
    try {
        const r = await fetch('library.php?action=proposals');
        const d = await r.json();
        if (!d.ok) { el.innerHTML = '<div class="sidebar-empty">Error.</div>'; return; }
        const prevCount = rpProposalsCache.length;
        rpProposalsCache = d.proposals || [];
        rpRenderProposals();
        // Update the badge counter
        // Two badges since 2026-09-26: the one inside the panel header, and the one
        // on the right-sidebar TAB. Proposals used to be a strip pinned under the
        // open panel, so its count was always on screen; as a tab it is only visible
        // when that tab is open, which is exactly when you least need telling.
        const _n = rpProposalsCache.length;
        ['rp-proposals-badge', 'rp-proposals-tabbadge'].forEach(id => {
            const b = document.getElementById(id);
            if (!b) return;
            b.textContent = _n > 99 ? '99+' : _n;
            b.style.display = _n ? 'inline-block' : 'none';
        });
        // Auto-expand the drawer if a NEW proposal appeared since last poll
        if (rpProposalsCache.length > prevCount) {
            const wrap = document.getElementById('rp-proposals-wrap');
            if (wrap && wrap.classList.contains('collapsed')) {
                wrap.classList.remove('collapsed');
                const ic = document.getElementById('rp-proposals-toggle-icon');
                if (ic) ic.textContent = T('msg.expand.more', 'expand_more');
                // Brief flash to draw attention
                wrap.style.transition = 'box-shadow 0.4s';
                wrap.style.boxShadow  = '0 -3px 12px rgba(80,130,200,0.45)';
                setTimeout(() => { wrap.style.boxShadow = ''; }, 1600);
            }
            // Sound or counter pulse
            if (badge) {
                badge.style.transition = 'transform 0.2s';
                badge.style.transform  = 'scale(1.4)';
                setTimeout(() => { badge.style.transform = 'scale(1)'; }, 250);
            }
        }
    } catch(e) {
        el.innerHTML = '<div class="sidebar-empty">Failed.</div>';
    }
}

function rpRenderProposals() {
    const el = document.getElementById('rp-proposals-list');
    if (!rpProposalsCache.length) {
        el.innerHTML = '<div class="sidebar-empty" style="padding:12px 8px;font-size:10px;">No pending proposals.</div>';
        return;
    }
    el.innerHTML = '';
    rpProposalsCache.forEach(p => {
        const div = document.createElement('div');
        div.className = 'rp-proposal';

        const payload = p.payload || {};
        const ts = fmtTsLocal(p.ts);   // ISO with offset from the server; shown in the viewer's zone
        let preview = '';
        if (p.kind === 'library') {
            preview = '<span class="material-symbols-rounded ico">description</span> ' + escHtml(payload.location || '');
        } else if (payload.content) {
            const pv = payload.content.slice(0, 150);
            preview = '<span style="opacity:0.7;">' + escHtml(pv) + (payload.content.length > 150 ? '…' : '') + '</span>';
        }

        div.innerHTML =
            '<div class="rp-prop-hdr">' +
                '<span class="rp-prop-kind rp-prop-kind-' + p.kind + '">' + p.kind.toUpperCase() + '</span>' +
                '<span class="rp-prop-title">' + escHtml(payload.title || '(no title)') + '</span>' +
                (payload.lang ? '<span class="rp-prop-lang">' + escHtml(payload.lang) + '</span>' : '') +
            '</div>' +
            '<div class="rp-prop-meta">' +
                'by <b>' + escHtml(p.proposer) + '</b>  ·  ' + escHtml(ts) +
                (p.project ? '  ·  proj: ' + escHtml(p.project) : '') +
                (payload.notes ? '<br>' + escHtml(payload.notes) : '') +
            '</div>' +
            (preview ? '<div class="rp-prop-preview">' + preview + '</div>' : '') +
            '<div class="rp-prop-actions">' +
                '<button class="rp-action-btn" style="border-color:var(--gemini);color:var(--gemini);" data-act="approve-global"><span class="material-symbols-rounded ico">check</span> Approve (Global)</button>' +
                (p.project
                    ? '<button class="rp-action-btn" style="border-color:var(--gemini);color:var(--gemini);" data-act="approve-project"><span class="material-symbols-rounded ico">check</span> Approve (Proj)</button>'
                    : '') +
                '<button class="rp-action-btn" style="border-color:var(--ollama);color:var(--ollama);" data-act="reject"><span class="material-symbols-rounded ico">close</span> Reject</button>' +
            '</div>';

        div.addEventListener('click', async e => {
            const act = e.target.dataset?.act;
            if (!act) return;
            if (act === 'reject') {
                await fetch('library.php', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({ action:'proposal_act', id:p.id, act:'reject' })
                });
                appendSystem(T('msg.rejected.proposal.title', 'Rejected proposal: {title}', {title: (payload.title || p.id)}));
            } else if (act.startsWith('approve')) {
                const target = act === 'approve-project' ? 'project' : 'global';
                const res = await fetch('library.php', {
                    method:'POST', headers:{'Content-Type':'application/json'},
                    body: JSON.stringify({ action:'proposal_act', id:p.id, act:'approve', target_scope: target })
                });
                const data = await res.json();
                if (!data.ok) { appendError(T('msg.approve.failed.error', 'Approve failed: {error}', {error: (data.error || '')})); return; }
                appendSystem(T('msg.approved.kind.target.title', 'Approved → {kind} ({target}): {title}', {kind: p.kind, target: target, title: (payload.title || p.id)}));
                // Refresh the matching catalog tab if open
                const catalogKind = p.kind === 'snippet' ? 'snippets'
                                  : p.kind === 'source'  ? 'sources'
                                  : 'library';
                rpRefreshList(catalogKind);
            }
            rpRefreshProposals();
        });

        el.appendChild(div);
    });
}

// E6 — bulk approve/reject all pending proposals.
// Approve uses project scope when the proposal carries a project, else global.
async function rpApproveAll() {
    const items = (rpProposalsCache || []).slice();
    if (items.length === 0) { appendSystem(T('msg.no.pending.proposals', 'No pending proposals.')); return; }
    if (!await cockpitConfirm('Approve all?', 'Approve all ' + items.length + ' pending proposal' + (items.length===1?'':'s') + '?', 'Approve', {icon:'check_circle'})) return;
    let ok = 0, fail = 0;
    for (const p of items) {
        const target = p.project ? 'project' : 'global';
        try {
            const r = await fetch('library.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({ action:'proposal_act', id:p.id, act:'approve', target_scope: target })
            });
            const d = await r.json();
            if (d.ok) ok++; else fail++;
        } catch(e) { fail++; }
    }
    appendSystem(T('msg.approved.ok.proposalok2fail', 'Approved {ok} proposal{ok2}{fail}.', {ok: ok, ok2: (ok===1?'':'s'), fail: (fail ? (', ' + fail + ' failed') : '')}));
    rpRefreshProposals();
    ['snippets','sources','library'].forEach(k => { try { rpRefreshList(k); } catch(e){} });
}

async function rpRejectAll() {
    const items = (rpProposalsCache || []).slice();
    if (items.length === 0) { appendSystem(T('msg.no.pending.proposals', 'No pending proposals.')); return; }
    if (!await cockpitConfirm('Reject all?', 'Reject (discard) all ' + items.length + ' pending proposal' + (items.length===1?'':'s') + '?', 'Reject', {danger:true, icon:'cancel'})) return;
    let ok = 0, fail = 0;
    for (const p of items) {
        try {
            const r = await fetch('library.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({ action:'proposal_act', id:p.id, act:'reject' })
            });
            const d = await r.json();
            if (d.ok) ok++; else fail++;
        } catch(e) { fail++; }
    }
    appendSystem(T('msg.rejected.ok.proposalok2fail', 'Rejected {ok} proposal{ok2}{fail}.', {ok: ok, ok2: (ok===1?'':'s'), fail: (fail ? (', ' + fail + ' failed') : '')}));
    rpRefreshProposals();
}

// Toggle proposals panel collapse
function rpToggleProposals() {
    const wrap = document.getElementById('rp-proposals-wrap');
    if (!wrap) return;
    wrap.classList.toggle('collapsed');
    const icon = document.getElementById('rp-proposals-toggle-icon');
    if (icon) icon.textContent = wrap.classList.contains('collapsed') ? 'expand_less' : 'expand_more';
}

// Resize proposals panel
let rpResizing = false;
let rpResizeStartY = 0;
let rpResizeStartH = 0;
function rpStartResize(e) {
    rpResizing = true;
    rpResizeStartY = e.clientY;
    const wrap = document.getElementById('rp-proposals-wrap');
    rpResizeStartH = wrap.offsetHeight;
    document.body.style.userSelect = 'none';
    _showResizeHint('proposals: ' + rpResizeStartH + 'px', e.clientX, e.clientY);
    e.preventDefault();
}
document.addEventListener('mousemove', e => {
    if (!rpResizing) return;
    const wrap = document.getElementById('rp-proposals-wrap');
    if (!wrap) return;
    const delta = rpResizeStartY - e.clientY;  // dragging up grows it
    const newH  = Math.min(380, Math.max(243, rpResizeStartH + delta));
    wrap.style.height = newH + 'px';
    _showResizeHint('proposals: ' + newH + 'px', e.clientX, e.clientY);
});
document.addEventListener('mouseup', () => {
    if (rpResizing) {
        rpResizing = false;
        document.body.style.userSelect = '';
        _hideResizeHint();
    }
});

// ── Config panel — load and render ───────────────────────────────────────────
// ── WEB SEARCH — Brave Search (primary) / DuckDuckGo (fallback) ────────────
//
// Three user actions are supported:
//   rpDoSearch     — runs a regular search via search.php; results render in
//                    this panel with Open / Read & Insert / Save to Library.
//   rpSearchAsk    — opens the AI "Ask" page for the current query in a new
//                    browser tab. Brave's summary mode and DuckDuckGo's chat
//                    interface both accept a prefilled query in the URL.
//   rpSearchHealth — pings the search engine, prints the result inline.
//
// Browser-side AI is "outside" the cockpit — we don't try to render it here.
// The user gets a full-featured AI chat in a separate tab and can copy
// snippets back into the prompt manually.

async function rpSearchAsk(engine) {
    const q = document.getElementById('search-q').value.trim();
    if (!q) {
        appendError(T('msg.type.a.query.first', 'Type a query first.'));
        return;
    }
    try {
        const r = await fetch('search.php?action=ask&q=' + encodeURIComponent(q));
        const d = await r.json();
        if (!d.ok || !d.urls || !d.urls[engine]) {
            appendError(T('msg.ask.failed.error', 'Ask failed: {error}', {error: (d.error || 'no URL')}));
            return;
        }
        window.open(d.urls[engine], '_blank');
        appendSystem(T('msg.opened.touppercase.ai.for.q', 'Opened {touppercase} AI for: "{q}"', {touppercase: engine.toUpperCase(), q: q}));
    } catch(e) {
        appendError(T('msg.ask.failed.message', 'Ask failed: {message}', {message: e.message}));
    }
}

async function rpSearchHealth() {
    const list = document.getElementById('rp-list-search');
    list.innerHTML = '<div class="sidebar-empty">Checking network…</div>';
    try {
        const r = await fetch('search.php?action=health');
        const d = await r.json();
        list.innerHTML = '<div class="sidebar-empty" style="font-family:var(--font-mono);font-size:10.5px;">'
            + (d.ok ? '<span class="material-symbols-rounded ico">check</span> Online — engine: ' + (d.engine || 'unknown') + ' (HTTP ' + d.http + ')'
                    : '<span class="material-symbols-rounded ico">close</span> Offline or blocked (HTTP ' + (d.http||'-') + ')')
            + '</div>';
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Health check failed: ' + escHtml(e.message) + '</div>';
    }
}

async function rpDoSearch() {
    const q  = document.getElementById('search-q').value.trim();
    if (!q) return;
    const list = document.getElementById('rp-list-search');
    list.innerHTML = '<div class="sidebar-empty">Searching: <b>' + escHtml(q) + '</b>…</div>';

    try {
        const url = 'search.php?action=search&n=8&q=' + encodeURIComponent(q);
        const r = await fetch(url);
        const d = await r.json();
        if (!d.ok) {
            list.innerHTML = '<div class="sidebar-empty">Error: ' + escHtml(d.error || 'unknown') + '</div>';
            return;
        }
        if (!d.results || !d.results.length) {
            list.innerHTML = '<div class="sidebar-empty">No results for "' + escHtml(q) + '".</div>';
            return;
        }
        list.innerHTML = '';
        d.results.forEach((res, idx) => list.appendChild(rpBuildSearchResult(res, idx, q)));
    } catch(e) {
        list.innerHTML = '<div class="sidebar-empty">Search failed: ' + escHtml(e.message) + '</div>';
    }
}

function rpBuildSearchResult(res, idx, query) {
    const div = document.createElement('div');
    div.className = 'rp-item';
    div.innerHTML =
        '<div class="rp-item-hdr">' +
            '<span class="rp-item-title" style="color:var(--gemini);">' +
                escHtml(res.title) + '</span>' +
            '<span class="rp-item-scope rp-scope-global">#' + (idx+1) + '</span>' +
        '</div>' +
        '<div class="rp-item-meta" style="color:var(--text-muted);"><span class="material-symbols-rounded ico">link</span> ' + escHtml(res.url) + '</div>' +
        (res.snippet
            ? '<div style="font-size:10.5px;color:var(--text-base);margin-top:4px;line-height:1.4;">'
                + escHtml(res.snippet) + '</div>'
            : '') +
        '<div class="rp-item-actions">' +
            '<button class="rp-action-btn" data-act="open">Open ↗</button>' +
            '<button class="rp-action-btn" data-act="read">Read & Insert</button>' +
            '<button class="rp-action-btn" data-act="save">⤴ Save to Library</button>' +
        '</div>';

    div.addEventListener('click', async e => {
        const act = e.target.dataset?.act;
        if (!act) {
            // toggle active
            const wasActive = div.classList.contains('active');
            document.querySelectorAll('#rp-list-search .rp-item.active')
                .forEach(el => el.classList.remove('active'));
            if (!wasActive) div.classList.add('active');
            return;
        }
        e.stopPropagation();
        if (act === 'open') {
            window.open(res.url, '_blank');
            return;
        }
        if (act === 'read') {
            appendSystem(T('msg.fetching.url', 'Fetching: {url}', {url: res.url}));
            const r = await fetch('search.php?action=fetch&url=' + encodeURIComponent(res.url));
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.fetch.failed.error', 'Fetch failed: {error}', {error: (d.error || '')})); return; }
            const block = '[Web search result for "' + query + '"]\n' +
                          '[Source: ' + res.url + ']\n\n' + d.text + '\n\n[End of source]\n\n';
            promptInput.value = block + (promptInput.value || '');
            promptInput.focus();
            appendSystem(T('msg.inserted.bytesb.from.url.into.prompt', 'Inserted {bytes}B from {url} into prompt', {bytes: d.bytes, url: res.url}));
            return;
        }
        if (act === 'save') {
            const item = {
                title:    res.title,
                location: res.url,
                kind:     'url',
                notes:    'Saved from search: "' + query + '"' + (res.snippet ? '\n\n' + res.snippet : ''),
            };
            let scope = 'global';
            if (currentProject && currentProject !== '_standalone') {
                scope = await cockpitChoice('Save scope', 'Where to save?', [
                    {label: 'Project (' + currentProject + ')', value: 'project', accent: 'var(--accent-blue)'},
                    {label: 'Global', value: 'global'}
                ]);
                if (scope === null) return;
                scope = scope === 'project' ? 'project' : 'global';
            }
            const r = await fetch('library.php', {
                method:'POST', headers:{'Content-Type':'application/json'},
                body: JSON.stringify({
                    action:'add', kind:'library', project:currentProject, scope, item
                })
            });
            const d = await r.json();
            if (!d.ok) { appendError(T('msg.save.failed.error', 'Save failed: {error}', {error: (d.error || '')})); return; }
            appendSystem(T('msg.saved.title.to.library.scope', 'Saved "{title}" to Library ({scope})', {title: res.title, scope: scope}));
        }
    });

    return div;
}

// =============================================================================
