(async () => {
  if (!sessionStorage.getItem('m1')) { sessionStorage.setItem('m1', '1'); await fetch('auth.php?action=login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: 'tester', password: 'test-pw-123' }) }); location.reload(); return; }
  const R = e => { const q = e.getBoundingClientRect(); return [Math.round(q.left * 100) / 100, Math.round(q.right * 100) / 100, Math.round(q.top * 100) / 100, Math.round(q.bottom * 100) / 100]; };
  const leaf = e => [...e.querySelectorAll('button, select, #clock-time, #clock-date, #clock-tz, #theme-status-wrap')].filter(x => x.offsetParent && x.getBoundingClientRect().width > 0 && x.getBoundingClientRect().width < 400);
  const measure = () => {
    const out = { vw: innerWidth, sw: document.documentElement.scrollWidth, cards: [], inner: {} };
    const order = ['.sup-claude', '.sup-gemini', '.sup-ollama', '.sup-workers', '.sup-tools', '.sup-account-card', '#topbar-sessions', '#topbar-clock', '#topbar-settings'];
    for (const s of order) { const e = document.querySelector(s); if (e && e.offsetParent) out.cards.push({ s, r: R(e) }); }
    const b = document.querySelector('.topbar-brand-block'); if (b) out.brand = R(b);
    for (const [k, s] of Object.entries({ account: '.sup-account-card', control: '#topbar-sessions', clock: '#topbar-clock', settings: '#topbar-settings' })) {
      const c = document.querySelector(s); if (!c) continue; const cr = c.getBoundingClientRect(); let l = 1e9, r = -1e9;
      for (const x of leaf(c)) { const q = x.getBoundingClientRect(); l = Math.min(l, q.left); r = Math.max(r, q.right); }
      out.inner[k] = { gapL: l - cr.left, gapR: cr.right - r };
    }
    return out;
  };
  let last = '', same = 0, cur = null;
  for (let i = 0; i < 60 && same < 4; i++) {
    await new Promise(r => setTimeout(r, 700)); cur = measure();
    const key = JSON.stringify(cur.cards) + JSON.stringify(cur.brand) + (document.getElementById('clock-time') || {}).textContent.length;
    if (cur.cards.length === 9 && key.length > 20) { same = key === last ? same + 1 : 0; last = key; }
  }
  await fetch('rep.php', { method: 'POST', body: JSON.stringify(cur) });
})();
