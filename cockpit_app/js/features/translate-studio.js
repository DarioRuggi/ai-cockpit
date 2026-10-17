// =============================================================================
// translate-studio.js — translate Cockpit WITHIN Cockpit.
//
// Opened from the Language menu ("Translate Cockpit…"). One screen to start a new language or finish one,
// working against lang.php (strings / check / save / template):
//   · every interface string with its English next to a box for the translation, a progress bar,
//     filters (not translated yet · translated · problems), search, pages of 40;
//   · the rules checked as you type: the {placeholders} must stay exactly as in English;
//   · AutoTranslate: a LOCAL model (Ollama) drafts the empty lines; drafts show as grey placeholders, Tab / Accept page / Accept all make them text;
//   · Save writes <cockpit data>/lang/<code>.json (survives updates); Use this language switches Cockpit to it;
//   · Download my file / Upload a file (checked before it is merged) to work offline or share the result.
// All text it shows goes through T(), so the Studio can itself be translated.
// =============================================================================
(function () {
    'use strict';
    var PAGE = 40;
    var S = null;                       // the open session: {code, meta, en, edits, keys, filter, q, page, dirty, writable, lt, isNew}
    var ov = null;

    function $(sel, root) { return (root || ov).querySelector(sel); }
    function el(tag, attrs, kids) {
        var e = document.createElement(tag);
        Object.keys(attrs || {}).forEach(function (k) {
            if (k === 'text') e.textContent = attrs[k];
            else if (k === 'style') e.style.cssText = attrs[k];
            else if (k.slice(0, 2) === 'on') e.addEventListener(k.slice(2), attrs[k]);
            else e.setAttribute(k, attrs[k]);
        });
        (kids || []).forEach(function (c) { if (c) e.appendChild(typeof c === 'string' ? document.createTextNode(c) : c); });
        return e;
    }
    function ph(s) { var m = String(s).match(/\{[A-Za-z0-9_]+\}/g) || []; return m.sort().join(' '); }
    function filled(k) { return (S.edits[k] || '').trim() !== ''; }
    function problem(k) {
        if (!filled(k)) return '';
        if (ph(S.edits[k]) !== ph(S.en[k])) {
            var want = ph(S.en[k]);
            return T('studio.ph.bad', 'Keep the placeholders exactly as in English: {want}', { want: want || T('studio.ph.none', '(none)') });
        }
        if (S.edits[k].length > 4000) return T('studio.too.long', 'Longer than 4000 characters.');
        return '';
    }
    function counts() {
        var done = 0, bad = 0;
        S.keys.forEach(function (k) { if (filled(k)) { done++; if (problem(k)) bad++; } });
        return { done: done, total: S.keys.length, bad: bad };
    }
    function say(msg, kind) {
        var b = $('#ts-msg'); if (!b) return;
        b.textContent = msg || ''; b.style.color = kind === 'err' ? 'var(--warn,#e6b43c)' : (kind === 'ok' ? 'var(--accent-green,#7dc4a3)' : 'var(--text-muted)');
    }

    // ---- open / load ---------------------------------------------------------------------
    window.translateStudioOpen = function (code) {
        if (ov) { ov.remove(); ov = null; }
        S = null;
        ov = el('div', { id: 'ts-ov', 'data-no-esc': '1', style: 'position:fixed;inset:0;z-index:10050;background:rgba(0,0,0,.62);display:flex;align-items:center;justify-content:center;font-family:var(--font-ui);' });
        ov.addEventListener('mousedown', function (e) { if (e.target === ov) ov._down = true; else ov._down = false; });
        ov.addEventListener('click', function (e) { if (e.target === ov && ov._down) close(); });
        ov.appendChild(el('div', { id: 'ts-box', style: 'background:var(--bg-base);border:1px solid var(--border-mid);border-radius:10px;width:min(1100px,96vw);height:min(86vh,900px);display:flex;flex-direction:column;overflow:hidden;color:var(--text-primary);box-shadow:0 12px 40px rgba(0,0,0,.6);' },
            [el('div', { style: 'padding:16px;color:var(--text-muted)', text: T('studio.loading', 'Loading…') })]));
        document.body.appendChild(ov);
        document.addEventListener('keydown', onKey, true);
        i18nList(true).then(function (list) { load(code || '', list); });
    };
    function onKey(e) {
        if (!ov) { document.removeEventListener('keydown', onKey, true); return; }
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); }
    }
    function close() {
        function go() { if (ov) ov.remove(); ov = null; S = null; document.removeEventListener('keydown', onKey, true); }
        if (S && S.dirty && typeof cockpitConfirm === 'function') {
            cockpitConfirm(T('studio.close.q', 'Close without saving?'), T('studio.close.t', 'Your changes to this translation are not saved yet.'), T('studio.discard', 'Discard'), { danger: true, icon: 'warning' })
                .then(function (ok) { if (ok) go(); });
        } else go();
    }
    function load(code, list) {
        fetch('lang.php?action=strings&code=' + encodeURIComponent(code === 'new' ? '' : code)).then(function (r) { return r.json(); }).then(function (j) {
            if (!j || !j.ok) { $('#ts-box').textContent = T('studio.load.fail', 'Could not load the strings.'); return; }
            var isNew = !code || code === 'new';
            S = { code: isNew ? '' : code, meta: isNew ? { name: '', native: '', dir: 'ltr', translator: '' } : Object.assign({ name: code, native: code, dir: 'ltr', translator: '' }, j.meta || {}),
                  en: j.en || {}, edits: {}, keys: Object.keys(j.en || {}).sort(), filter: 'todo', q: '', page: 0, dirty: false, writable: !!j.writable, folder: j.folder || '', isNew: isNew, list: list, sugg: {}, failed: {}, rowTa: {}, rowFx: {}, auto: { on: false, stop: false, done: 0, total: 0, model: '', models: [], err: '' } };
            Object.keys(j.mine || {}).forEach(function (k) { if (S.en[k] !== undefined) S.edits[k] = j.mine[k]; });
            if (!isNew && counts().done === 0) S.filter = 'all';
            build();
            // AutoTranslate: which local models are there (best translator first)
            fetch('lang.php?action=models').then(function (r) { return r.json(); }).then(function (h) {
                if (!S) return; S.auto.models = (h && h.models) || []; S.auto.err = (h && h.ok) ? '' : ((h && h.error) || '');
                if (S.auto.models.length && !S.auto.model) S.auto.model = S.auto.models[0].name;
                buildAutoModels(); renderAuto();
            }).catch(function () { if (S) { S.auto.err = T('studio.auto.nolocal', 'Cockpit could not ask Ollama which models are installed.'); renderAuto(); } });
        }).catch(function () { $('#ts-box').textContent = T('studio.load.fail', 'Could not load the strings.'); });
    }

    // ---- the screen ----------------------------------------------------------------------
    function btn(label, fn, strong, icon) {
        var b = el('button', { class: 'action-btn', style: 'font-size:12px;padding:5px 11px;' + (strong ? 'background:var(--accent-blue);color:#fff;' : ''), onclick: fn });
        if (icon) b.appendChild(el('span', { class: 'material-symbols-rounded', style: 'font-size:15px;vertical-align:-3px;margin-right:4px;', text: icon }));
        b.appendChild(document.createTextNode(label)); return b;
    }
    function build() {
        var box = $('#ts-box'); box.textContent = '';
        // title bar
        var head = el('div', { style: 'display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid var(--border-dim);' }, [
            el('span', { class: 'material-symbols-rounded', style: 'font-size:20px;color:var(--accent-blue);', text: 'translate' }),
            el('h2', { style: 'margin:0;font-size:15px;flex:1;', text: T('studio.title', 'Translate Cockpit') }),
            btn(T('studio.close', 'Close'), close, false)
        ]);
        box.appendChild(head);
        // language row
        var sel = el('select', { id: 'ts-lang', style: 'background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 8px;border-radius:4px;font-size:12px;', onchange: function () { switchLang(this.value); } });
        (S.list || []).forEach(function (l) { if (l.code === 'en') return; sel.appendChild(el('option', { value: l.code, text: l.native + (l.native !== l.name ? ' · ' + l.name : '') + ' (' + l.code + ')' })); });
        sel.appendChild(el('option', { value: 'new', text: '＋ ' + T('studio.new', 'A new language…') }));
        sel.value = S.isNew ? 'new' : S.code;
        var row1 = el('div', { style: 'display:flex;flex-wrap:wrap;align-items:center;gap:10px;padding:10px 16px;border-bottom:1px solid var(--border-dim);' }, [
            el('label', { style: 'font-size:12px;color:var(--text-muted);', text: T('studio.language', 'Language') }), sel,
            el('div', { id: 'ts-prog', style: 'flex:1;min-width:200px;' }),
            btn(T('studio.rules', 'Rules'), function () { var r = $('#ts-rules'); r.style.display = r.style.display === 'none' ? 'block' : 'none'; }, false, 'rule')
        ]);
        box.appendChild(row1);
        // rules
        var rules = el('div', { id: 'ts-rules', style: 'display:none;padding:10px 16px;border-bottom:1px solid var(--border-dim);font-size:12px;line-height:1.55;color:var(--text-base);background:var(--bg-darker);' });
        [T('studio.r1', 'Translate the meaning, not word by word, and keep the tone friendly and short: most of these texts sit in buttons and small labels.'),
         T('studio.r2', 'Keep every {placeholder} exactly as written (for example {name} or {n}); Cockpit fills it in. You may move it inside the sentence. The box turns red if one is missing or changed.'),
         T('studio.r3', 'Leave a box empty to keep English there. A half-finished translation works, and you can come back any time: only the empty ones are left.'),
         T('studio.r4', 'Do not translate product and file names (Cockpit, Ollama, Claude, Gemini, tmux, .json), keyboard keys written as Ctrl or Shift, or code in backticks.'),
         T('studio.r5', 'Buttons should stay about as short as the English: a long word may be cut off. Prefer the shorter word.'),
         T('studio.r6', 'Right-to-left languages: set Direction to right-to-left when you start the language. The text boxes then follow it.'),
         T('studio.r7', 'Save writes your file into the Cockpit data folder (it survives updates). Download my file gives you the same file; Send it to us opens the page where you can send it to be included in Cockpit.')
        ].forEach(function (t) { rules.appendChild(el('div', { style: 'margin:2px 0;', text: '• ' + t })); });
        box.appendChild(rules);
        // new-language form / meta
        box.appendChild(el('div', { id: 'ts-meta', style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 16px;border-bottom:1px solid var(--border-dim);font-size:12px;' }));
        // filters
        var fsel = el('select', { id: 'ts-filter', style: 'background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 8px;border-radius:4px;font-size:12px;', onchange: function () { S.filter = this.value; S.page = 0; render(); } }, [
            el('option', { value: 'todo', text: T('studio.f.todo', 'Not translated yet') }), el('option', { value: 'done', text: T('studio.f.done', 'Translated') }),
            el('option', { value: 'bad', text: T('studio.f.bad', 'With a problem') }), el('option', { value: 'all', text: T('studio.f.all', 'All') })]);
        fsel.value = S.filter;
        var q = el('input', { id: 'ts-q', type: 'text', placeholder: T('studio.search', 'Search the English, the key or your translation…'), style: 'flex:1;min-width:180px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 8px;border-radius:4px;font-size:12px;',
            oninput: function () { S.q = this.value.toLowerCase(); S.page = 0; render(); } });
        box.appendChild(el('div', { style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 16px;border-bottom:1px solid var(--border-dim);' }, [fsel, q,
            btn('‹', function () { if (S.page > 0) { S.page--; render(true); } }, false), el('span', { id: 'ts-pg', style: 'font-size:12px;color:var(--text-muted);min-width:90px;text-align:center;' }),
            btn('›', function () { S.page++; render(true); }, false)]));
        // AutoTranslate row
        box.appendChild(el('div', { id: 'ts-auto', style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:8px 16px;border-bottom:1px solid var(--border-dim);' }));
        autoBuildBar();
        // rows
        box.appendChild(el('div', { id: 'ts-rows', style: 'flex:1;overflow:auto;padding:6px 16px 12px;' }));
        // footer
        var file = el('input', { type: 'file', accept: '.json,application/json', style: 'display:none', onchange: function () { importFile(this.files[0]); this.value = ''; } });
        box.appendChild(el('div', { style: 'display:flex;flex-wrap:wrap;align-items:center;gap:8px;padding:10px 16px;border-top:1px solid var(--border-dim);' }, [
            btn(T('studio.save', 'Save'), save, true, 'save'),
            btn(T('studio.use', 'Use this language'), useIt, false, 'check_circle'),
            btn(T('studio.download', 'Download my file'), download, false, 'download'),
            btn(T('studio.upload', 'Upload a file'), function () { file.click(); }, false, 'upload'), file,
            btn(T('studio.share', 'Send it to us'), function () { window.open('https://cockpit.ruggi.site/translate.php', '_blank', 'noopener'); }, false, 'send'),
            el('span', { id: 'ts-msg', style: 'font-size:12px;flex:1;min-width:160px;' })
        ]));
        renderMeta(); render();
    }
    function renderMeta() {
        var m = $('#ts-meta'); m.textContent = '';
        function field(label, key, w, ph) {
            var i = el('input', { type: 'text', value: S.meta[key] || '', placeholder: ph || '', style: 'width:' + w + 'px;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:4px 7px;border-radius:4px;font-size:12px;',
                oninput: function () { S.meta[key] = this.value; S.dirty = true; if (key === 'code') S.code = this.value.trim(); } });
            return [el('label', { style: 'color:var(--text-muted);', text: label }), i];
        }
        var kids = [];
        if (S.isNew) kids = kids.concat(field(T('studio.m.code', 'Code'), 'code', 70, 'fr'));
        kids = kids.concat(field(T('studio.m.name', 'English name'), 'name', 130, 'French'), field(T('studio.m.native', 'Written in itself'), 'native', 130, 'Français'));
        var dir = el('select', { style: 'background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:4px 7px;border-radius:4px;font-size:12px;', onchange: function () { S.meta.dir = this.value; S.dirty = true; renderMeta(); render(); } },
            [el('option', { value: 'ltr', text: T('studio.m.ltr', 'left-to-right') }), el('option', { value: 'rtl', text: T('studio.m.rtl', 'right-to-left') })]);
        dir.value = S.meta.dir === 'rtl' ? 'rtl' : 'ltr';
        kids.push(el('label', { style: 'color:var(--text-muted);', text: T('studio.m.dir', 'Direction') }), dir);
        if (S.meta.dir === 'rtl') {      // the question every right-to-left language has to answer
            var mir = el('select', { title: T('studio.m.mirror.tip', 'Right-to-left text always reads right to left. This asks whether Cockpit should ALSO mirror its layout: sidebars, strips and buttons swapped left for right. Mirroring is experimental; the text-only choice is the safe one.'),
                style: 'background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:4px 7px;border-radius:4px;font-size:12px;max-width:290px;', onchange: function () { S.meta.mirror = this.value === '1'; S.dirty = true; } },
                [el('option', { value: '0', text: T('studio.m.mirror.no', 'Layout stays as it is (only the text is right-to-left)') }), el('option', { value: '1', text: T('studio.m.mirror.yes', 'Mirror the whole layout (experimental)') })]);
            mir.value = S.meta.mirror ? '1' : '0';
            kids.push(el('label', { style: 'color:var(--text-muted);', text: T('studio.m.mirror', 'Flip the layout?') }), mir);
        }
        kids = kids.concat(field(T('studio.m.by', 'Translator'), 'translator', 170, T('studio.m.by.ph', 'your name')));
        kids.forEach(function (k) { m.appendChild(k); });
        if (!S.writable) m.appendChild(el('span', { style: 'color:var(--warn,#e6b43c);', text: T('studio.nowrite', 'Cockpit cannot write to {folder} — Save will fail; use Download my file.', { folder: S.folder }) }));
    }
    function switchLang(v) {
        function go() { translateStudioOpen(v); }
        if (S && S.dirty && typeof cockpitConfirm === 'function') cockpitConfirm(T('studio.close.q', 'Close without saving?'), T('studio.close.t', 'Your changes to this translation are not saved yet.'), T('studio.discard', 'Discard'), { danger: true, icon: 'warning' }).then(function (ok) { if (ok) go(); else $('#ts-lang').value = S.isNew ? 'new' : S.code; });
        else go();
    }

    function visibleKeys() {
        return S.keys.filter(function (k) {
            var f = filled(k);
            if (S.filter === 'todo' && f) return false;
            if (S.filter === 'done' && !f) return false;
            if (S.filter === 'bad' && !(f && problem(k))) return false;
            if (S.q && (k.toLowerCase().indexOf(S.q) < 0 && String(S.en[k]).toLowerCase().indexOf(S.q) < 0 && String(S.edits[k] || '').toLowerCase().indexOf(S.q) < 0)) return false;
            return true;
        });
    }
    function render(keepScroll) {
        if (!ov || !S) return;
        var c = counts(), pct = c.total ? Math.round(100 * c.done / c.total) : 0;
        var p = $('#ts-prog'); p.textContent = '';
        p.appendChild(el('div', { style: 'font-size:12px;margin-bottom:3px;', text: T('studio.progress', '{done} of {total} translated ({pct}%)', { done: c.done, total: c.total, pct: pct }) + (c.bad ? ' · ' + T('studio.problems', '{n} with a problem', { n: c.bad }) : '') }));
        p.appendChild(el('div', { style: 'height:6px;background:var(--bg-darker);border-radius:3px;overflow:hidden;' }, [el('div', { style: 'height:100%;width:' + pct + '%;background:var(--accent-green,#7dc4a3);' })]));
        var keys = visibleKeys(), pages = Math.max(1, Math.ceil(keys.length / PAGE));
        if (S.page >= pages) S.page = pages - 1;
        $('#ts-pg').textContent = T('studio.page', 'Page {a} of {b} · {n} strings', { a: S.page + 1, b: pages, n: keys.length });
        var rows = $('#ts-rows'); rows.textContent = ''; S.rowTa = {}; S.rowFx = {};
        if (!keys.length) rows.appendChild(el('div', { style: 'padding:24px;text-align:center;color:var(--text-muted);', text: S.filter === 'todo' && !S.q ? T('studio.alldone', 'Nothing left to translate here.') : T('studio.nomatch', 'No strings match.') }));
        keys.slice(S.page * PAGE, S.page * PAGE + PAGE).forEach(function (k) { rows.appendChild(row(k)); });
        if (!keepScroll) rows.scrollTop = 0; else rows.scrollTop = 0;
    }
    function row(k) {
        var en = String(S.en[k]);
        var box = el('div', { style: 'display:grid;grid-template-columns:1fr 1fr;gap:10px;padding:8px 0;border-bottom:1px solid var(--border-dim);' });
        var left = el('div', { style: 'min-width:0;' });
        var t = el('div', { style: 'white-space:pre-wrap;word-break:break-word;font-size:13px;' });
        en.split(/(\{[A-Za-z0-9_]+\})/).forEach(function (part) {
            if (/^\{[A-Za-z0-9_]+\}$/.test(part)) t.appendChild(el('code', { style: 'background:var(--bg-darker);border:1px solid var(--border-dim);border-radius:3px;padding:0 3px;color:var(--accent-blue);', text: part }));
            else t.appendChild(document.createTextNode(part));
        });
        left.appendChild(t); left.appendChild(el('div', { style: 'font-size:10px;color:var(--text-muted);font-family:var(--font-mono);margin-top:2px;', text: k }));
        var right = el('div', { style: 'min-width:0;display:flex;flex-direction:column;gap:3px;' });
        var ta = el('textarea', { rows: Math.max(2, Math.min(6, Math.ceil(en.length / 60))), dir: S.meta.dir === 'rtl' ? 'rtl' : 'ltr', placeholder: S.sugg[k] || T('studio.keep.en', '(empty: stays English)'),
            style: 'width:100%;box-sizing:border-box;resize:vertical;background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);border-radius:4px;padding:6px 8px;font:13px var(--font-ui);' });
        ta.value = S.edits[k] || '';
        var msg = el('div', { style: 'font-size:11px;min-height:14px;color:var(--warn,#e6b43c);', text: problem(k) });
        function paint() {
            ta.style.borderColor = problem(k) ? 'var(--warn,#e6b43c)' : 'var(--border-dim)';
            var draft = !ta.value && S.sugg[k];
            ta.classList.toggle('ts-sug', !!draft); ta.placeholder = draft ? S.sugg[k] : T('studio.keep.en', '(empty: stays English)');
            msg.style.color = problem(k) ? 'var(--warn,#e6b43c)' : 'var(--text-muted)';
            msg.textContent = problem(k) || (draft ? T('studio.auto.hint', 'Draft from the local model — press Tab to accept it, or type your own.') : '');
        }
        S.rowTa[k] = ta; S.rowFx[k] = paint;
        ta.addEventListener('keydown', function (e) {                      // Tab on an empty box that holds a draft = accept the draft
            if (e.key === 'Tab' && !e.shiftKey && !e.ctrlKey && !e.altKey && !ta.value && S.sugg[k]) {
                e.preventDefault(); ta.value = S.sugg[k]; delete S.sugg[k]; ta.dispatchEvent(new Event('input', { bubbles: true })); renderAuto();
            }
        });
        ta.addEventListener('input', function () { S.edits[k] = this.value; S.dirty = true; paint(); var c = counts(); var pp = $('#ts-prog div'); if (pp) pp.textContent = T('studio.progress', '{done} of {total} translated ({pct}%)', { done: c.done, total: c.total, pct: c.total ? Math.round(100 * c.done / c.total) : 0 }) + (c.bad ? ' · ' + T('studio.problems', '{n} with a problem', { n: c.bad }) : ''); });
        paint();
        right.appendChild(ta); right.appendChild(msg);
        if (S.auto.model) {
            right.appendChild(el('div', {}, [el('button', { class: 'action-btn', style: 'font-size:10px;padding:2px 8px;', title: T('studio.suggest.tip', 'A draft of this line from the local model. Check it: it is a draft, not a translation.'),
                onclick: function () { autoOne(k, this); } }, [document.createTextNode(T('studio.suggest', 'Draft this line'))])]));
        }
        box.appendChild(left); box.appendChild(right); return box;
    }
    // ---- AutoTranslate: a LOCAL model (Ollama) drafts the lines; nothing leaves this computer ----------------------------------
    // The drafts are not text yet: each one is shown as the grey placeholder of its box. Tab in an empty box makes it real text;
    // "Accept page" and "Accept all" do it for many at once. A draft whose {placeholders} differ from the English is never offered.
    function autoBuildBar() {
        var bar = $('#ts-auto'); if (!bar) return; bar.textContent = '';
        bar.appendChild(el('button', { id: 'ts-auto-go', class: 'action-btn', style: 'font-size:12px;padding:5px 11px;background:var(--accent-blue);color:#fff;', onclick: autoRun, title: T('studio.auto.tip', 'The local model drafts every line that is still empty, starting with this page. The drafts appear in the boxes as grey text.') },
            [el('span', { class: 'material-symbols-rounded', style: 'font-size:15px;vertical-align:-3px;margin-right:4px;', text: 'auto_awesome' }), document.createTextNode(T('studio.auto', 'AutoTranslate'))]));
        bar.appendChild(el('select', { id: 'ts-auto-model', style: 'background:var(--bg-darker);color:var(--text-base);border:1px solid var(--border-dim);padding:5px 8px;border-radius:4px;font-size:12px;max-width:190px;', title: T('studio.auto.model', 'The local model that translates. Bigger ones translate better and slower.'), onchange: function () { S.auto.model = this.value; } }));
        bar.appendChild(btn(T('studio.auto.stop', 'Stop'), function () { S.auto.stop = true; renderAuto(); }, false, 'stop_circle'));
        bar.lastChild.id = 'ts-auto-stop';
        var ap = btn(T('studio.auto.page', 'Accept page'), acceptPage, false, 'done'); ap.id = 'ts-auto-page'; bar.appendChild(ap);
        var aa = btn(T('studio.auto.all', 'Accept all'), acceptAll, false, 'done_all'); aa.id = 'ts-auto-all'; bar.appendChild(aa);
        var cl = btn(T('studio.auto.clear', 'Drop the drafts'), function () { S.sugg = {}; S.failed = {}; render(true); renderAuto(); }, false, 'delete_sweep'); cl.id = 'ts-auto-clear'; bar.appendChild(cl);
        bar.appendChild(el('span', { id: 'ts-auto-st', style: 'font-size:12px;color:var(--text-muted);flex:1;min-width:200px;' }));
        buildAutoModels(); renderAuto();
    }
    function buildAutoModels() {
        var sel = $('#ts-auto-model'); if (!sel || !S) return; sel.textContent = '';
        S.auto.models.forEach(function (m) { sel.appendChild(el('option', { value: m.name, text: m.name + ' · ' + m.gb + ' GB' })); });
        if (S.auto.model) sel.value = S.auto.model;
    }
    function nDrafts() { return Object.keys(S.sugg).filter(function (k) { return !filled(k); }).length; }
    function renderAuto() {
        if (!ov || !S) return; var go = $('#ts-auto-go'); if (!go) return; var A = S.auto, d = nDrafts();
        go.disabled = A.on || !A.model; $('#ts-auto-stop').style.display = A.on ? '' : 'none'; $('#ts-auto-model').disabled = A.on;
        $('#ts-auto-page').disabled = !d; $('#ts-auto-all').disabled = !d; $('#ts-auto-clear').style.display = (d || Object.keys(S.failed).length) ? '' : 'none';
        var st = $('#ts-auto-st'), t = '';
        if (!A.models.length) t = A.err || T('studio.auto.none', 'No local model found. Install one in Ollama (for example gemma3:4b) and reopen this window.');
        else if (A.on && A.stop) t = T('studio.auto.stopping', 'Stopping after this batch…');
        else if (A.on) t = T('studio.auto.running', 'Drafting… {done} of {total} lines done · {n} drafts waiting', { done: A.done, total: A.total, n: d });
        else if (d) t = T('studio.auto.ready', '{n} drafts waiting: Tab in a box, Accept page, or Accept all.', { n: d });
        else t = T('studio.auto.idle', 'Drafts appear as grey text in the boxes; nothing becomes text until you accept it.');
        var f = Object.keys(S.failed).length; if (f && !A.on) t += ' ' + T('studio.auto.failed', '{n} lines the model could not translate safely are left for you.', { n: f });
        st.textContent = t;
    }
    function setDraft(k, t) {
        S.sugg[k] = t; var fx = S.rowFx[k]; if (fx && S.rowTa[k] && !S.rowTa[k].value) fx();
    }
    function autoOne(k, b) {
        if (!(S.meta.name || '').trim()) { say(T('studio.auto.name', 'Fill in the English name of the language first.'), 'err'); return; }
        b.disabled = true; var old = b.textContent; b.textContent = '…';
        post('auto', { keys: [k], lang_name: S.meta.name, code: S.code, model: S.auto.model }).then(function (j) {
            if (!S) return;
            if (j && j.ok && j.results && j.results[k]) setDraft(k, j.results[k]); else say((j && j.error) || T('studio.auto.nodraft', 'The model gave no safe draft for this line.'), 'err');
            renderAuto();
        }).catch(function () { say(T('studio.net', 'No answer from Cockpit.'), 'err'); }).then(function () { b.disabled = false; b.textContent = old; });
    }
    function autoRun() {
        var A = S.auto; if (A.on) return;
        if (!(S.meta.name || '').trim()) { say(T('studio.auto.name', 'Fill in the English name of the language first.'), 'err'); return; }
        if (!A.model) { say(A.err || T('studio.auto.none', 'No local model found. Install one in Ollama (for example gemma3:4b) and reopen this window.'), 'err'); return; }
        var seen = {}, todo = [];
        visibleKeys().slice(S.page * PAGE).concat(S.keys).forEach(function (k) { if (!seen[k] && !filled(k) && !S.sugg[k] && !S.failed[k]) { seen[k] = 1; todo.push(k); } });
        if (!todo.length) { say(T('studio.auto.nothing', 'Nothing left to draft.'), 'ok'); return; }
        A.on = true; A.stop = false; A.done = 0; A.total = todo.length; renderAuto(); say('');
        (function next() {
            if (!ov || !S) return;
            if (A.stop || !todo.length) { A.on = false; renderAuto(); say(A.stop ? T('studio.auto.stopped', 'Stopped. The drafts so far are kept.') : T('studio.auto.done', 'AutoTranslate finished.'), 'ok'); return; }
            var batch = todo.splice(0, 8);
            post('auto', { keys: batch, lang_name: S.meta.name, code: S.code, model: A.model }).then(function (j) {
                if (!ov || !S) return;
                if (!j || !j.ok) { A.on = false; renderAuto(); say((j && j.error) || T('studio.auto.err', 'The model did not answer.'), 'err'); return; }
                Object.keys(j.results || {}).forEach(function (k) { setDraft(k, j.results[k]); });
                (j.rejected || []).forEach(function (k) { S.failed[k] = 1; });
                A.done += batch.length; renderAuto(); next();
            }).catch(function () { if (S) { A.on = false; renderAuto(); say(T('studio.net', 'No answer from Cockpit.'), 'err'); } });
        })();
    }
    function takeDraft(k) { if (S.sugg[k] && !filled(k)) { S.edits[k] = S.sugg[k]; delete S.sugg[k]; S.dirty = true; return 1; } return 0; }
    function acceptPage() {
        var n = 0; visibleKeys().slice(S.page * PAGE, S.page * PAGE + PAGE).forEach(function (k) { n += takeDraft(k); });
        render(true); renderAuto(); say(T('studio.auto.acc', 'Accepted {n} lines.', { n: n }), 'ok');
    }
    function acceptAll() {
        var keys = Object.keys(S.sugg).filter(function (k) { return !filled(k); });
        if (!keys.length) return;
        function go() { var n = 0; keys.forEach(function (k) { n += takeDraft(k); }); render(true); renderAuto(); say(T('studio.auto.acc', 'Accepted {n} lines.', { n: n }), 'ok'); }
        if (typeof cockpitConfirm === 'function') cockpitConfirm(T('studio.auto.all.q', 'Accept all {n} drafts?', { n: keys.length }), T('studio.auto.all.t', 'They are machine drafts. They become your translation text (you can still edit every line, and Save is a separate step).'), T('studio.auto.all.ok', 'Accept all'), { icon: 'done_all' }).then(function (ok) { if (ok) go(); });
        else go();
    }
    // ---- save / use / download / upload ---------------------------------------------------
    function payload() {
        var strings = {}; S.keys.forEach(function (k) { if (filled(k)) strings[k] = S.edits[k].trim(); });
        return { code: (S.code || '').trim(), meta: { name: S.meta.name, native: S.meta.native, dir: S.meta.dir, mirror: !!S.meta.mirror, translator: S.meta.translator }, strings: strings };
    }
    function post(action, body) {
        return fetch('lang.php?action=' + action, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(function (r) { return r.json().catch(function () { return { ok: false, general: [T('studio.net', 'No answer from Cockpit.')] }; }); });
    }
    function report(j) {
        var parts = (j.general || []).slice();
        var bad = j.bad ? Object.keys(j.bad) : [];
        if (bad.length) parts.push(T('studio.badkeys', '{n} strings were left out because of a problem — see "With a problem".', { n: bad.length }));
        return parts.join(' ');
    }
    function save() {
        say(T('studio.saving', 'Saving…'));
        post('save', payload()).then(function (j) {
            if (!j.ok) { say(report(j) || j.error || T('studio.save.fail', 'Not saved.'), 'err'); return; }
            var wasNew = S.isNew; S.dirty = false; S.isNew = false;
            i18nList(true).then(function (l) { S.list = l; if (wasNew) { build(); say(T('studio.saved', 'Saved {n} strings to {file}', { n: j.count, file: j.saved || '' }), 'ok'); } });
            say(T('studio.saved', 'Saved {n} strings to {file}', { n: j.count, file: j.saved || '' }) + (report(j) ? ' · ' + report(j) : ''), (j.bad && Object.keys(j.bad).length) ? 'err' : 'ok');
        });
    }
    function useIt() {
        if (!S.code) { say(T('studio.use.none', 'Give the language a code and save it first.'), 'err'); return; }
        function go() { i18nSet(S.code).then(function (ok) { say(ok ? T('studio.using', 'Cockpit now shows this language.') : T('studio.use.fail', 'Save the language first.'), ok ? 'ok' : 'err'); }); }
        if (S.dirty) post('save', payload()).then(function (j) { if (j.ok) { S.dirty = false; go(); } else say(report(j) || T('studio.save.fail', 'Not saved.'), 'err'); }); else go();
    }
    function download() {
        var p = payload(), out = { _meta: Object.assign({ code: p.code }, p.meta, { send: 'When it is ready, send this file at https://cockpit.ruggi.site/translate.php (or Translate Cockpit… > Send it to us). To use it yourself, put it in the lang folder of your Cockpit data folder.' }), strings: p.strings };
        var a = el('a', { href: URL.createObjectURL(new Blob([JSON.stringify(out, null, 2) + '\n'], { type: 'application/json' })), download: (p.code || 'language') + '.json' });
        document.body.appendChild(a); a.click(); setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
    }
    function importFile(f) {
        if (!f) return;
        var rd = new FileReader();
        rd.onload = function () {
            var j; try { j = JSON.parse(String(rd.result)); } catch (e) { say(T('studio.up.notjson', 'That file is not valid JSON.'), 'err'); return; }
            var body = { code: (S.code || (j._meta && j._meta.code) || '').trim(), meta: Object.assign({}, S.meta, j._meta || {}), strings: j.strings || {} };
            post('check', body).then(function (r) {
                if (!r.ok) { say(report(r) || T('studio.up.bad', 'That file cannot be used.'), 'err'); return; }
                var n = 0, bad = r.bad ? r.bad : {};
                Object.keys(j.strings || {}).forEach(function (k) {
                    if (k.slice(-3) === '#en' || S.en[k] === undefined || bad[k] || typeof j.strings[k] !== 'string' || !j.strings[k].trim()) return;
                    S.edits[k] = j.strings[k].trim(); n++;
                });
                if (j._meta) { ['name', 'native', 'dir', 'translator'].forEach(function (m) { if (j._meta[m] && !S.meta[m]) S.meta[m] = j._meta[m]; }); if (S.isNew && j._meta.code) S.code = S.meta.code = j._meta.code; }
                S.dirty = true; renderMeta(); render();
                say(T('studio.up.ok', 'Merged {n} strings from the file.', { n: n }) + (Object.keys(bad).length ? ' ' + T('studio.up.skipped', '{k} were skipped (placeholders changed).', { k: Object.keys(bad).length }) : '') + (r.unknown_keys ? ' ' + T('studio.up.unknown', '{k} keys are not in this Cockpit and were ignored.', { k: r.unknown_keys }) : ''), 'ok');
            });
        };
        rd.readAsText(f);
    }
})();
