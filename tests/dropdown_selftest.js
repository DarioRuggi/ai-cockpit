// =============================================================================
// dropdown_selftest.js — in-page checks for js/core/dropdown.js (Cockpit's own drop-down list).
//
// Run it in a browser against a running copy of the app, signed in, with the Theme Editor available:
//   1. open the app, press F12 (or use any browser automation), and paste this file into the console, or evaluate it;
//   2. it prints one line per check and returns { passed, failed, lines }.
// Part 1 exercises behaviour on a throw-away fixture (nothing in the app is changed). Part 2 opens the real theme
// picker under every theme and measures the contrast of the list and of the closed select (needs themeEditorOpen,
// themeLoadAndApply and themes.php, i.e. the real app). AA for small text is 4.5:1.
// Last run (2026-10-05, Chromium via the in-app browser): part 1 21/21, part 2 36 themes, list worst 4.96:1, select worst 7.02:1.
// =============================================================================
(async () => {
  const lines = []; let passed = 0, failed = 0;
  const ok = (n, c, d) => { c ? passed++ : failed++; lines.push((c ? 'PASS ' : 'FAIL ') + n + (c ? '' : '  -> ' + d)); };
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const md = el => el.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, button: 0 }));
  const key = (el, k, extra) => el.dispatchEvent(new KeyboardEvent('keydown', Object.assign({ key: k, bubbles: true, cancelable: true }, extra || {})));

  // ---- part 1: behaviour ------------------------------------------------------------------------------------------
  const host = document.createElement('div'); host.style.cssText = 'position:fixed;left:30px;bottom:6px;z-index:99999;background:#222;padding:6px;display:flex;gap:10px';
  host.innerHTML = '<select id="t1"><option value="a">Alpha</option><option value="b" disabled>Bravo (disabled)</option><option value="c">Charlie</option><optgroup label="Group Two"><option value="d">Delta</option><option value="e">Echo</option></optgroup><optgroup label="Off" disabled><option value="f">Foxtrot</option></optgroup></select>' +
    '<select id="t2" multiple><option>x</option><option>y</option></select><select id="t3" data-native><option>n1</option><option>n2</option></select><select id="t4" dir="rtl"><option value="1">אחד</option><option value="2">שניים</option></select>';
  document.body.appendChild(host);
  const t1 = host.querySelector('#t1'), t2 = host.querySelector('#t2'), t3 = host.querySelector('#t3'), t4 = host.querySelector('#t4');
  const events = []; t1.addEventListener('input', () => events.push('input')); t1.addEventListener('change', () => events.push('change'));
  t1.setAttribute('onchange', 'window.__ddAttrFired=(window.__ddAttrFired||0)+1'); window.__ddAttrFired = 0;
  const lab = () => document.querySelector('.ck-dd-opt.active .ck-dd-label').textContent;
  ok('eligible: plain yes, multiple no, data-native no', ckDropdown.eligible(t1) && !ckDropdown.eligible(t2) && !ckDropdown.eligible(t3), '');
  t1.focus(); md(t1); await wait(60);
  let p = document.querySelector('.ck-dd-panel');
  ok('list opens', !!p && ckDropdown.isOpen(), 'no panel');
  ok('opens UPWARD when there is no room below', p && p.classList.contains('up') && p.getBoundingClientRect().bottom <= t1.getBoundingClientRect().top + 1, '');
  ok('group labels rendered; disabled entries disabled', [...p.querySelectorAll('.ck-dd-group')].map(g => g.textContent).join('|') === 'Group Two|Off' && p.querySelectorAll('.ck-dd-opt.disabled').length === 2, '');
  ok('chosen entry has a check mark and aria-selected', p.querySelector('.ck-dd-opt.chosen .ck-dd-check').textContent === '✓' && p.querySelector('.ck-dd-opt.chosen').getAttribute('aria-selected') === 'true', '');
  ok('aria: expanded, activedescendant, listbox', t1.getAttribute('aria-expanded') === 'true' && !!t1.getAttribute('aria-activedescendant') && p.getAttribute('role') === 'listbox', '');
  key(document.activeElement, 'ArrowDown'); await wait(20); ok('ArrowDown skips the disabled entry', lab() === 'Charlie', lab());
  key(document.activeElement, 'End'); await wait(20); ok('End = last ENABLED entry', lab() === 'Echo', lab());
  key(document.activeElement, 'Home'); await wait(20); ok('Home = first enabled entry', lab() === 'Alpha', lab());
  key(document.activeElement, 'd'); await wait(20); ok('type-ahead "d" -> Delta', lab() === 'Delta', lab());
  key(document.activeElement, 'Escape'); await wait(20); ok('Escape closes, changes nothing', !ckDropdown.isOpen() && t1.value === 'a' && events.length === 0, '');
  md(t1); await wait(40); md(document.body); await wait(30); ok('click outside closes', !ckDropdown.isOpen(), '');
  md(t1); await wait(40); key(document.activeElement, 'ArrowDown'); key(document.activeElement, 'Enter'); await wait(40);
  ok('Enter chooses: input then change, onchange attribute ran once', t1.value === 'c' && events.join() === 'input,change' && window.__ddAttrFired === 1, t1.value + ' ' + events);
  ok('focus back on the select', document.activeElement === t1, '');
  events.length = 0; md(t1); await wait(40); key(document.activeElement, 'Enter'); await wait(30); ok('choosing the chosen entry fires nothing', events.length === 0, events);
  md(t1); await wait(40); [...document.querySelectorAll('.ck-dd-opt')].find(r => r.textContent.includes('Delta')).click(); await wait(30); ok('clicking an entry chooses it', t1.value === 'd', t1.value);
  md(t1); await wait(40); [...document.querySelectorAll('.ck-dd-opt')].find(r => r.textContent.includes('Bravo')).click(); await wait(30); ok('a disabled entry cannot be chosen', ckDropdown.isOpen() && t1.value === 'd', t1.value); ckDropdown.close();
  t1.value = 'e'; t1.add(new Option('Golf (added later)', 'g')); md(t1); await wait(40);
  ok('options added later and a value set by code are shown', [...document.querySelectorAll('.ck-dd-opt')].some(r => r.textContent.includes('Golf')) && document.querySelector('.ck-dd-opt.chosen .ck-dd-label').textContent === 'Echo', ''); ckDropdown.close();
  md(t4); await wait(40); p = document.querySelector('.ck-dd-panel');
  ok('RTL select -> RTL list aligned to its right edge', p && p.dir === 'rtl' && Math.abs(p.getBoundingClientRect().right - t4.getBoundingClientRect().right) < 3, ''); ckDropdown.close();
  md(t1); await wait(40); host.remove(); await wait(450); ok('removing the select closes the list', !ckDropdown.isOpen(), '');
  const t5 = document.createElement('select'); t5.innerHTML = '<option>q</option>'; document.body.appendChild(t5);
  localStorage.setItem('ck.nativeSelects', '1'); const off = ckDropdown.eligible(t5); localStorage.removeItem('ck.nativeSelects'); t5.remove();
  ok('opt-out switch turns it off', off === false, off);

  // ---- part 2: legibility under every theme (needs the real app) -----------------------------------------------------
  if (typeof themeEditorOpen === 'function' && typeof themeLoadAndApply === 'function') {
    await themeEditorOpen(); await wait(700);
    const cv = document.createElement('canvas'); cv.width = cv.height = 1; const cx = cv.getContext('2d', { willReadFrequently: true });
    const parse = c => { cx.clearRect(0, 0, 1, 1); cx.fillStyle = '#000'; cx.fillStyle = c; cx.fillRect(0, 0, 1, 1); const [r, g, b, a] = cx.getImageData(0, 0, 1, 1).data; return { r, g, b, a: a / 255 }; };
    const lum = c => { const f = v => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); }; return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b); };
    const ratio = (a, b) => (Math.max(lum(a), lum(b)) + 0.05) / (Math.min(lum(a), lum(b)) + 0.05);
    const over = (t, b) => ({ r: t.r * t.a + b.r * (1 - t.a), g: t.g * t.a + b.g * (1 - t.a), b: t.b * t.a + b.b * (1 - t.a), a: 1 });
    const dim = (fg, bg, o) => ({ r: fg.r * o + bg.r * (1 - o), g: fg.g * o + bg.g * (1 - o), b: fg.b * o + bg.b * (1 - o), a: 1 });
    const sel = document.getElementById('theme-picker'); const themes = (await (await fetch('themes.php?action=list')).json()).themes;
    let worstList = 99, worstSel = 99, bad = [];
    for (const t of themes) {
      await themeLoadAndApply(t.id); await wait(110);
      const c0 = getComputedStyle(sel); const closed = ratio(parse(c0.color), over(parse(c0.backgroundColor), { r: 0, g: 0, b: 0, a: 1 }));
      ckDropdown.close(); md(sel); await wait(50);
      const q = document.querySelector('.ck-dd-panel'); const cs = getComputedStyle(q); const bg = over(parse(cs.backgroundColor), { r: 0, g: 0, b: 0, a: 1 }), fg = parse(cs.color);
      const act = q.querySelector('.ck-dd-opt.active'), grp = q.querySelector('.ck-dd-group'), meta = q.querySelector('.ck-dd-meta');
      const m = Math.min(ratio(fg, bg), ratio(fg, over(parse(getComputedStyle(act).backgroundColor), bg)), ratio(dim(fg, bg, +getComputedStyle(grp).opacity), bg), ratio(dim(fg, bg, +getComputedStyle(meta).opacity), bg));
      worstList = Math.min(worstList, m); worstSel = Math.min(worstSel, closed); if (m < 4.5 || closed < 4.5) bad.push(t.id);
      ckDropdown.close();
    }
    ok('contrast under all ' + themes.length + ' themes: list >= 4.5 (worst ' + worstList.toFixed(2) + '), closed select >= 4.5 (worst ' + worstSel.toFixed(2) + ')', bad.length === 0, bad.join(','));
  } else lines.push('SKIP part 2: not running inside the real app');
  console.log(lines.join('\n'));
  return { passed, failed, lines };
})();
