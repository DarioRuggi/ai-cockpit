// =============================================================================
// ckwindow.js — a floating window that looks and behaves like an operating-system window, for Cockpit's own tools (the file window, the command
// window). Title bar with icon and title (drag to move, double-click to maximise), minimise / maximise / close buttons, eight resize handles, click
// to raise, remembers where you left it, opens maximised on a narrow screen. Minimised windows wait as small chips in a dock at the bottom.
//
//   const w = ckWindow({ id:'fileman', title:'Files', icon:'folder_open', width:860, height:560, content:<element>, onClose(){…},
//                        buttons:[{icon:'open_in_new', title:'…', onClick(){…}}] });
//   w.body  w.el  w.setTitle(t)  w.focus()  w.close()  w.toggleMax()
// One window per id: calling it again raises the existing one.
// =============================================================================
(function () {
    const wins = {};
    let zTop = 10050;
    window.ckNextZ = function () { return ++zTop; };          // one stacking counter for every floating window, including the code editor (files.js)
    const KEY = 'cockpit.win.';
    function store(id, v) { try { if (v === undefined) return JSON.parse(localStorage.getItem(KEY + id) || 'null'); localStorage.setItem(KEY + id, JSON.stringify(v)); } catch (e) { return null; } }
    function dock() {
        let d = document.getElementById('ckwin-dock');
        if (!d) { d = document.createElement('div'); d.id = 'ckwin-dock'; document.body.appendChild(d); }
        return d;
    }
    function mkBtn(cls, icon, title, onClick) {
        const b = document.createElement('button');
        b.type = 'button'; b.className = 'ckwin-btn ' + cls; b.title = title; b.setAttribute('aria-label', title);
        b.innerHTML = '<span class="material-symbols-rounded">' + icon + '</span>';
        b.addEventListener('mousedown', e => e.stopPropagation());
        b.addEventListener('click', e => { e.stopPropagation(); onClick(); });
        return b;
    }

    window.ckWindow = function (o) {
        const id = o.id || ('w' + Date.now());
        if (wins[id]) { wins[id].focus(); return wins[id]; }
        const narrow = window.innerWidth < 720;
        const saved = store(id);
        const vw = window.innerWidth, vh = window.innerHeight;
        const minW = o.minWidth || 360, minH = o.minHeight || 220;
        let g = { w: Math.min(o.width || 800, vw - 16), h: Math.min(o.height || 520, vh - 60), x: 0, y: 0, max: false };
        if (saved && saved.w) g = Object.assign(g, saved, { w: Math.min(saved.w, vw - 8), h: Math.min(saved.h, vh - 40) });
        else { g.x = Math.max(8, Math.round((vw - g.w) / 2) + Object.keys(wins).length * 26); g.y = Math.max(8, Math.round((vh - g.h) / 3) + Object.keys(wins).length * 26); }
        if (narrow) g.max = true;

        const el = document.createElement('div');
        el.className = 'ckwin'; el.id = 'ckwin-' + id; el.setAttribute('role', 'dialog'); el.setAttribute('aria-label', o.title || id);
        const bar = document.createElement('div'); bar.className = 'ckwin-bar';
        const ic = document.createElement('span'); ic.className = 'material-symbols-rounded ckwin-icon'; ic.textContent = o.icon || 'web_asset';
        const tt = document.createElement('div'); tt.className = 'ckwin-title'; tt.textContent = o.title || '';
        const ctl = document.createElement('div'); ctl.className = 'ckwin-ctl';
        (o.buttons || []).forEach(b => ctl.appendChild(mkBtn('extra', b.icon, b.title, b.onClick)));
        const bMin = mkBtn('min', 'remove', T('ui.win.minimise', 'Minimise'), () => api.minimise());
        const bMax = mkBtn('max', 'crop_square', T('ui.win.maximise', 'Maximise'), () => api.toggleMax());
        const bClose = mkBtn('close', 'close', T('ui.win.close', 'Close'), () => api.close());
        ctl.appendChild(bMin); ctl.appendChild(bMax); ctl.appendChild(bClose);
        bar.appendChild(ic); bar.appendChild(tt); bar.appendChild(ctl);
        const body = document.createElement('div'); body.className = 'ckwin-body';
        if (o.content) body.appendChild(o.content);
        el.appendChild(bar); el.appendChild(body);
        ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw'].forEach(d => { const h = document.createElement('div'); h.className = 'ckwin-rs ckwin-rs-' + d; h.dataset.dir = d; el.appendChild(h); });
        document.body.appendChild(el);

        function apply() {
            if (g.max) { el.classList.add('max'); el.style.left = el.style.top = '0'; el.style.width = '100vw'; el.style.height = 'calc(100vh - 0px)'; }
            else {
                el.classList.remove('max');
                g.w = Math.max(minW, Math.min(g.w, window.innerWidth)); g.h = Math.max(minH, Math.min(g.h, window.innerHeight));
                g.x = Math.max(-g.w + 80, Math.min(g.x, window.innerWidth - 80)); g.y = Math.max(0, Math.min(g.y, window.innerHeight - 32));
                el.style.left = g.x + 'px'; el.style.top = g.y + 'px'; el.style.width = g.w + 'px'; el.style.height = g.h + 'px';
            }
            bMax.firstChild.textContent = g.max ? 'filter_none' : 'crop_square';
            bMax.title = bMax.ariaLabel = g.max ? T('ui.win.restore', 'Restore') : T('ui.win.maximise', 'Maximise');
        }
        function save() { if (!narrow) store(id, { w: g.w, h: g.h, x: g.x, y: g.y, max: g.max }); }
        function raise() { el.style.zIndex = ++zTop; Object.keys(wins).forEach(k => wins[k].el.classList.toggle('active', k === id)); }

        // drag
        bar.addEventListener('mousedown', e => {
            if (e.button !== 0 || e.target.closest('.ckwin-ctl')) return;
            raise();
            if (g.max) return;
            const sx = e.clientX, sy = e.clientY, ox = g.x, oy = g.y;
            const mv = ev => { g.x = ox + ev.clientX - sx; g.y = oy + ev.clientY - sy; apply(); };
            const up = () => { document.removeEventListener('mousemove', mv); document.removeEventListener('mouseup', up); document.body.classList.remove('ckwin-dragging'); save(); };
            document.body.classList.add('ckwin-dragging');
            document.addEventListener('mousemove', mv); document.addEventListener('mouseup', up);
            e.preventDefault();
        });
        bar.addEventListener('dblclick', e => { if (!e.target.closest('.ckwin-ctl')) api.toggleMax(); });
        // resize
        el.querySelectorAll('.ckwin-rs').forEach(h => h.addEventListener('mousedown', e => {
            if (e.button !== 0 || g.max) return;
            raise();
            const d = h.dataset.dir, sx = e.clientX, sy = e.clientY, o0 = { x: g.x, y: g.y, w: g.w, h: g.h };
            const mv = ev => {
                const dx = ev.clientX - sx, dy = ev.clientY - sy;
                if (d.includes('e')) g.w = Math.max(minW, o0.w + dx);
                if (d.includes('s')) g.h = Math.max(minH, o0.h + dy);
                if (d.includes('w')) { const nw = Math.max(minW, o0.w - dx); g.x = o0.x + (o0.w - nw); g.w = nw; }
                if (d.includes('n')) { const nh = Math.max(minH, o0.h - dy); g.y = o0.y + (o0.h - nh); g.h = nh; }
                apply();
            };
            const up = () => { document.removeEventListener('mousemove', mv); document.removeEventListener('mouseup', up); document.body.classList.remove('ckwin-dragging'); save(); };
            document.body.classList.add('ckwin-dragging');
            document.addEventListener('mousemove', mv); document.addEventListener('mouseup', up);
            e.preventDefault(); e.stopPropagation();
        }));
        el.addEventListener('mousedown', raise, true);
        window.addEventListener('resize', apply);

        let chip = null;
        const api = {
            el, body, id,
            setTitle(t) { tt.textContent = t; el.setAttribute('aria-label', t); if (chip) chip.lastChild.textContent = t; },
            focus() { if (chip) api.restore(); raise(); },
            toggleMax() { g.max = !g.max; apply(); save(); },
            minimise() {
                el.style.display = 'none';
                chip = document.createElement('button'); chip.type = 'button'; chip.className = 'ckwin-chip';
                chip.innerHTML = '<span class="material-symbols-rounded"></span><span></span>';
                chip.firstChild.textContent = o.icon || 'web_asset'; chip.lastChild.textContent = tt.textContent;
                chip.onclick = () => api.restore();
                dock().appendChild(chip);
            },
            restore() { el.style.display = ''; if (chip) { chip.remove(); chip = null; } raise(); },
            close() {
                if (o.onClose && o.onClose() === false) return;
                window.removeEventListener('resize', apply);
                if (chip) chip.remove();
                el.remove(); delete wins[id];
                const ks = Object.keys(wins); if (ks.length) wins[ks[ks.length - 1]].focus();
            }
        };
        wins[id] = api;
        apply(); raise();
        return api;
    };
    window.ckWindowOpen = id => wins[id] || null;
})();
