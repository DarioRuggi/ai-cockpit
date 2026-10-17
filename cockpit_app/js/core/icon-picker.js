// =============================================================================
// icon-picker.js — choose an icon by looking at it, not by knowing its name.
//
// ckIconFieldHtml(id, value)  → a field: a hidden <input id=…> that holds the icon NAME (so `document.getElementById(id).value` works as it did for a text box) and a button that shows the
//                               current icon and opens the picker.
// The picker: a "suggested" set of common icons, and a search box over ALL the icons Cockpit carries (the vendored Material Symbols list, ~4300 names): type a word ("mail", "heart",
// "print", "book") or a plain idea ("write", "fix", "translate", "shorter") and the matching icons appear; click one. Esc or a click outside closes it. Used by the Power Buttons editor and
// the kind wizard.
// =============================================================================
let _ckIconNames = null, _ckIconLoading = null;
const _CK_ICON_SUGGESTED = ['bolt', 'touch_app', 'spellcheck', 'edit', 'draw', 'auto_fix_high', 'translate', 'summarize', 'lightbulb', 'help', 'school', 'psychology', 'handshake', 'sentiment_satisfied', 'favorite', 'mail', 'forward_to_inbox', 'chat', 'forum', 'comment',
    'description', 'article', 'note', 'edit_note', 'checklist', 'fact_check', 'rule', 'search', 'manage_search', 'travel_explore', 'public', 'language', 'code', 'terminal', 'bug_report', 'build', 'compress', 'short_text', 'segment', 'format_list_bulleted',
    'table_chart', 'calculate', 'receipt_long', 'gavel', 'balance', 'work', 'business', 'schedule', 'event', 'folder', 'image', 'photo_camera', 'movie', 'music_note', 'mic', 'headphones', 'book', 'menu_book', 'science', 'star', 'rocket_launch', 'flash_on', 'magic_button', 'smart_toy'];
// plain ideas → icon names that carry them (the picker matches these as well as the names themselves)
const _CK_ICON_IDEAS = { write: ['edit', 'draw', 'edit_note', 'history_edu', 'ink_pen', 'create'], fix: ['build', 'auto_fix_high', 'handyman', 'construction', 'spellcheck'], correct: ['spellcheck', 'check_circle', 'rule', 'done_all'], proofread: ['spellcheck', 'fact_check'],
    translate: ['translate', 'g_translate', 'language', 'public'], explain: ['lightbulb', 'help', 'school', 'psychology', 'info'], shorter: ['compress', 'short_text', 'content_cut', 'unfold_less'], summary: ['summarize', 'segment', 'notes', 'short_text'], summarise: ['summarize', 'segment', 'notes'],
    email: ['mail', 'alternate_email', 'forward_to_inbox', 'drafts', 'send'], reply: ['reply', 'reply_all', 'forum', 'chat'], polite: ['handshake', 'sentiment_satisfied', 'favorite', 'thumb_up'], friendly: ['sentiment_satisfied', 'mood', 'handshake', 'favorite'],
    check: ['spellcheck', 'check_circle', 'fact_check', 'rule', 'done'], search: ['search', 'manage_search', 'travel_explore', 'find_in_page'], web: ['public', 'language', 'travel_explore', 'link'], code: ['code', 'terminal', 'data_object', 'bug_report'],
    list: ['format_list_bulleted', 'checklist', 'list', 'view_list'], table: ['table_chart', 'grid_on', 'view_list'], money: ['payments', 'attach_money', 'savings', 'receipt_long', 'account_balance'], law: ['gavel', 'balance', 'policy', 'description'], legal: ['gavel', 'balance', 'policy'],
    simple: ['segment', 'lightbulb', 'sentiment_satisfied', 'child_care'], plain: ['segment', 'lightbulb', 'short_text'], idea: ['lightbulb', 'psychology', 'tips_and_updates', 'emoji_objects'], learn: ['school', 'menu_book', 'import_contacts', 'psychology'], study: ['school', 'menu_book', 'auto_stories'],
    music: ['music_note', 'headphones', 'library_music', 'piano'], photo: ['photo_camera', 'image', 'photo_library', 'camera_alt'], video: ['movie', 'videocam', 'play_circle'], voice: ['mic', 'record_voice_over', 'graphic_eq', 'hearing'], speak: ['record_voice_over', 'mic', 'volume_up'],
    clean: ['cleaning_services', 'auto_fix_high', 'format_clear', 'delete_sweep'], format: ['format_align_left', 'format_paint', 'text_fields', 'format_size'], rewrite: ['edit', 'auto_fix_high', 'cached', 'sync_alt'], notes: ['note', 'edit_note', 'sticky_note_2', 'description'],
    meeting: ['groups', 'event', 'forum', 'videocam'], task: ['task_alt', 'checklist', 'assignment', 'check_box'], magic: ['auto_fix_high', 'magic_button', 'auto_awesome', 'flash_on'], fast: ['bolt', 'flash_on', 'rocket_launch', 'speed'] };

function _ckIconLoad() {
    if (_ckIconNames) return Promise.resolve(_ckIconNames);
    if (!_ckIconLoading) _ckIconLoading = fetch('assets/fonts/material-symbols.names').then(r => r.text()).then(t => (_ckIconNames = t.split('\n').map(s => s.trim()).filter(s => /^[a-z0-9_]{1,60}$/.test(s)))).catch(() => (_ckIconNames = _CK_ICON_SUGGESTED.slice()));
    return _ckIconLoading;
}
/** The icons that match what the person typed: first the ones that carry a plain idea ("write", "fix"…), then every name that holds all the typed words, short and "starts with" first. */
function ckIconSearch(all, text) {
    const words = String(text || '').trim().toLowerCase().split(/[\s_]+/).filter(Boolean); if (!words.length) return [];
    const idea = []; for (const w of words) for (const k of Object.keys(_CK_ICON_IDEAS)) if (k.startsWith(w) || w.startsWith(k)) for (const n of _CK_ICON_IDEAS[k]) if (all.includes(n) && !idea.includes(n)) idea.push(n);
    const hit = all.filter(n => words.every(w => n.includes(w)) && !idea.includes(n));
    hit.sort((a, b) => (a.startsWith(words[0]) ? 0 : 1) - (b.startsWith(words[0]) ? 0 : 1) || a.length - b.length);
    return idea.concat(hit);
}
function _ckIconEsc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }

function ckIconFieldHtml(id, value) {
    const v = /^[a-z0-9_]{1,60}$/.test(value || '') ? value : 'bolt';
    return '<input type="hidden" id="' + id + '" value="' + _ckIconEsc(v) + '">' +
        '<button type="button" id="' + id + '-btn" class="action-btn" onclick="ckIconPickerOpen(\'' + id + '\')" title="' + _ckIconEsc(T('ui.iconpick.tip', 'Choose an icon: look through the list or search')) + '" style="display:inline-flex;align-items:center;gap:8px;padding:4px 10px;">' +
        '<span class="material-symbols-rounded" style="font-size:20px;">' + _ckIconEsc(v) + '</span><span style="font-size:11px;color:var(--text-muted);">' + _ckIconEsc(v) + '</span>' +
        '<span style="font-size:10px;color:var(--text-muted);margin-left:4px;">' + T('ui.iconpick.change', 'Change…') + '</span></button>';
}
function ckIconSet(id, name) {
    const inp = document.getElementById(id), btn = document.getElementById(id + '-btn'); if (!inp) return;
    inp.value = name; inp.dispatchEvent(new Event('change', { bubbles: true }));
    if (btn) { const s = btn.querySelectorAll('span'); s[0].textContent = name; s[1].textContent = name; }
}

function ckIconPickerOpen(id) {
    document.getElementById('ck-iconpick')?.remove();
    const ov = document.createElement('div'); ov.id = 'ck-iconpick';
    ov.style.cssText = 'position:fixed;inset:0;z-index:10050;background:rgba(0,0,0,0.55);display:flex;align-items:center;justify-content:center;';
    ov.innerHTML = '<div style="background:var(--bg-base);border:1px solid var(--border-mid);border-radius:6px;width:min(560px,94vw);max-height:80vh;display:flex;flex-direction:column;padding:12px;color:var(--text-primary);">' +
        '<div style="display:flex;align-items:center;gap:8px;margin-bottom:8px;"><b style="font-size:13px;flex:1;">' + T('ui.iconpick.title', 'Choose an icon') + '</b><span id="ckip-x" class="rp-action-btn" style="cursor:pointer;">×</span></div>' +
        '<input id="ckip-q" type="search" autocomplete="off" placeholder="' + _ckIconEsc(T('ui.iconpick.ph', 'Search: a word like mail, heart, book, or an idea like write, fix, translate, shorter')) + '" style="background:var(--bg-darker);border:1px solid var(--border-dim);color:var(--text-base);padding:6px 8px;border-radius:3px;font-size:12px;width:100%;box-sizing:border-box;">' +
        '<div id="ckip-note" style="font-size:10.5px;color:var(--text-muted);margin:6px 0 4px;min-height:14px;"></div>' +
        '<div id="ckip-grid" style="display:grid;grid-template-columns:repeat(auto-fill,minmax(44px,1fr));gap:4px;overflow:auto;padding:2px;"></div></div>';
    document.body.appendChild(ov);
    const close = () => ov.remove();
    ov.onclick = e => { if (e.target === ov) close(); }; document.getElementById('ckip-x').onclick = close;
    const onKey = e => { if (e.key === 'Escape') { close(); document.removeEventListener('keydown', onKey, true); e.stopPropagation(); } }; document.addEventListener('keydown', onKey, true);
    const grid = document.getElementById('ckip-grid'), note = document.getElementById('ckip-note'), q = document.getElementById('ckip-q');
    const cur = document.getElementById(id) ? document.getElementById(id).value : '';
    const draw = (names, msg) => {
        note.textContent = msg || '';
        grid.innerHTML = names.map(n => '<button type="button" data-n="' + _ckIconEsc(n) + '" title="' + _ckIconEsc(n.replace(/_/g, ' ')) + '" style="display:flex;align-items:center;justify-content:center;height:44px;border-radius:4px;cursor:pointer;color:var(--text-primary);background:' + (n === cur ? 'var(--bg-hover,rgba(127,127,127,.25))' : 'var(--bg-darker)') + ';border:1px solid ' + (n === cur ? 'var(--accent-cyan)' : 'var(--border-dim)') + ';"><span class="material-symbols-rounded" style="font-size:24px;">' + _ckIconEsc(n) + '</span></button>').join('');
        grid.querySelectorAll('button').forEach(b => b.onclick = () => { ckIconSet(id, b.dataset.n); close(); });
    };
    const search = async () => {
        const t = q.value.trim().toLowerCase().replace(/\s+/g, '_');
        if (!t) { draw(_CK_ICON_SUGGESTED, T('ui.iconpick.sugg', 'Suggested icons. Type above to search all of them.')); return; }
        const all = await _ckIconLoad(); const list = ckIconSearch(all, t), shown = list.slice(0, 150);
        draw(shown, list.length ? (list.length > shown.length ? T('ui.iconpick.more', '{n} icons match; showing the first {s}. Type more to narrow it down.', { n: list.length, s: shown.length }) : T('ui.iconpick.count', '{n} icons match.', { n: list.length })) : T('ui.iconpick.none', 'No icon matches that. Try another word.'));
    };
    q.oninput = search; draw(_CK_ICON_SUGGESTED, T('ui.iconpick.sugg', 'Suggested icons. Type above to search all of them.')); _ckIconLoad(); q.focus();
}
