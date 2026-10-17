/* _engine.js - the page side of a web worker (cockpit_app/webworker_lib.php injects this, then calls __ww.send / __ww.probe).
   It types the prompt into the site's own box, presses its own send button, watches the answer appear and reports back through
   window.webkit.messageHandlers.cockpit (cockpit_shell --worker). cfg comes from the provider's adapter in workers_providers.json:
     input[]   selectors of the prompt box        send[]  selectors of the send button       answer[] selectors of the answer blocks (the last new one is the answer)
     busy[]    selectors visible while the site is still writing (a stop button)               login[] selectors/ids that only exist on a login wall
     dismiss[] exact texts of cookie-banner buttons to press first (the private choice)   blocked[] texts of a bot check ("verify you are human", "just a moment")                  stable  ms the answer must stay unchanged to count as finished
     timeout   ms to wait for the whole answer                                                 trim[]  regex strings removed from the end of a heuristic answer   trimStart[]  from its start   dropLines[]  regexes; a line (after the first) that matches one is removed
   Nothing here solves a CAPTCHA or logs in: a wall is reported ({t:"login"} / {t:"blocked"}) and the person deals with it in the shown window. */
(function () {
  if (window.__ww && window.__ww.v === 1) return;
  const post = o => { try { window.webkit.messageHandlers.cockpit.postMessage(JSON.stringify(o)); } catch (e) {} };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const vis = el => { if (!el || !el.getBoundingClientRect) return false; const r = el.getBoundingClientRect(), cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none'; };
  const all = (sels, onlyVisible) => { for (const s of sels || []) { try { const l = [...document.querySelectorAll(s)].filter(e => !onlyVisible || vis(e)); if (l.length) return l; } catch (e) {} } return []; };
  const text = el => (el ? (el.innerText || el.textContent || '') : '').trim();
  // The page's visible text as plain text: block elements break lines, anything hidden is skipped, and a maths formula (KaTeX draws it twice, a visual copy and a hidden
  // MathML copy, so innerText would print it twice and one token per line) becomes its own TeX once, between dollar signs.
  const BLOCK = /^(P|DIV|LI|UL|OL|H[1-6]|TR|TABLE|PRE|BLOCKQUOTE|SECTION|ARTICLE|BR|HR|FIGURE|DD|DT)$/;
  function nodeText(root) {
    const out = [];
    const walk = (n) => {
      if (n.nodeType === 3) { out.push(n.nodeValue); return; }
      if (n.nodeType !== 1) return;
      const tag = n.tagName;
      if (/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|SVG|HEAD)$/.test(tag)) return;
      if (n.classList && n.classList.contains('katex')) { const a = n.querySelector('annotation[encoding="application/x-tex"]'); out.push(a ? '$' + a.textContent.trim() + '$' : (n.textContent || '')); return; }
      if (tag === 'IMG') { const al = n.getAttribute('alt') || ''; const cl = String(n.className || ''); if (al && (/\\[a-zA-Z]|[\^_][{a-zA-Z0-9]/.test(al) || (/align-middle/.test(cl) && /invert/.test(cl)))) out.push('$' + al.trim() + '$'); return; }   // a formula drawn as a picture keeps its TeX in alt
      const cs = getComputedStyle(n); if (cs.display === 'none' || cs.visibility === 'hidden') return;
      const blk = BLOCK.test(tag) || cs.display === 'block' || cs.display === 'flex' || cs.display === 'list-item' || cs.display === 'table-row';
      if (blk) out.push('\n');
      for (const c of n.childNodes) walk(c);
      if (blk) out.push('\n');
    };
    if (root) walk(root);
    let t = out.join('').replace(/[ \t\xa0]+/g, ' ').replace(/ ?\n ?/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    // text drawn one letter per element ("Thought for 1s" animated) comes out one letter per line: join a run of 4 or more one-character lines
    t = t.replace(/(?:^|\n)(?:[^\s\n]\n){3,}[^\s\n](?=\n|$)/g, m => (m[0] === '\n' ? '\n' : '') + m.replace(/\n/g, ''));
    return t;
  }
  const pageText = () => nodeText(document.body);
  const ntext = (el) => { try { return nodeText(el); } catch (e) { return text(el); } };
  const bodyText = () => { try { return pageText(); } catch (e) { return (document.body ? document.body.innerText : '') || ''; } };
  const hasText = list => { const t = bodyText().toLowerCase(); return (list || []).some(x => t.includes(String(x).toLowerCase())); };
  function findInput(cfg) {
    let l = all(cfg.input, true); if (l.length) return l[l.length - 1];
    // no selector matched: the visible text box lowest on the page is the prompt box on every chat site
    const c = [...document.querySelectorAll('textarea,[contenteditable="true"],[contenteditable=""],input[type="text"]')].filter(vis);
    c.sort((a, b) => b.getBoundingClientRect().bottom - a.getBoundingClientRect().bottom); return c[0] || null;
  }
  function setText(el, t) {
    el.focus();
    if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
      const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, t);              // the page's own setter would hide the change from React
      el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      const sel = getSelection(), r = document.createRange(); r.selectNodeContents(el); sel.removeAllRanges(); sel.addRange(r);
      document.execCommand('delete'); document.execCommand('insertText', false, t);
      if (!text(el).includes(t.slice(0, Math.min(20, t.length)))) {                   // an editor that ignores execCommand: paste it
        const dt = new DataTransfer(); dt.setData('text/plain', t);
        el.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
      }
    }
  }
  const boxText = el => (el.value !== undefined ? el.value : text(el));
  function findSend(cfg, input) {
    let l = all(cfg.send, true).filter(b => !b.disabled && b.getAttribute('aria-disabled') !== 'true'); if (l.length) return l[l.length - 1];
    const scope = (input.closest('form') || input.parentElement.parentElement || document);
    const c = [...scope.querySelectorAll('button,[role="button"]')].filter(b => vis(b) && !b.disabled && b.getAttribute('aria-disabled') !== 'true' && /send|submit|ask|\u05e9\u05dc\u05d7/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.getAttribute('title') || '') + ' ' + (b.getAttribute('data-testid') || '') + ' ' + b.type));
    return c[c.length - 1] || null;
  }
  function pressEnter(el) {
    for (const t of ['keydown', 'keypress', 'keyup']) el.dispatchEvent(new KeyboardEvent(t, { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true }));
    const f = el.closest && el.closest('form'); if (f && f.requestSubmit) { try { f.requestSubmit(); } catch (e) {} }
  }
  function answerNow(cfg, base, promptTail) {
    const l = all(cfg.answer, false);
    if (l.length && cfg.answerJoin) { const parts = l.slice(base.count).map(ntext).filter(Boolean); const t = parts.join('\n\n'); return t && (l.length > base.count) ? tidy(cfg, t) : ''; }   // a site that splits one reply into several blocks (text, code, text): all the new ones, in order
    if (l.length) { const t = ntext(l[l.length - 1]); if (l.length > base.count || t !== base.last) return tidy(cfg, t); return ''; }
    // no answer selector: whatever follows the prompt's last words on the page
    const b = bodyText(), i = b.lastIndexOf(promptTail); if (i < 0) return '';
    return tidy(cfg, b.slice(i + promptTail.length).trim());
  }
  // what the page prints around the answer (a copy toolbar, source chips, a footer): removed with the adapter's own patterns, whichever way the answer was found
  function tidy(cfg, r) {
    for (const re of cfg.trim || []) { try { r = r.replace(new RegExp(re, 'i'), '').trim(); } catch (e) {} }          // what the page prints after the answer
    for (const re of cfg.trimStart || []) { try { r = r.replace(new RegExp(re, 'i'), '').trim(); } catch (e) {} }     // and before it ("Duck.ai said / model name")
    if (cfg.dropLines && cfg.dropLines.length) {   // whole lines the page prints inside the answer (source chips): never the first line of the answer
        let seen = false; const res = cfg.dropLines.map(x => { try { return new RegExp(x, 'i'); } catch (e) { return null; } }).filter(Boolean);
        r = r.split('\n').filter(l => { const t = l.trim(); if (!seen) { if (t) seen = true; return true; } return !t || !res.some(re => re.test(t)); }).join('\n').replace(/\n{3,}/g, '\n\n').trim();
    }
    return r;
  }
  window.__ww = {
    v: 1,
    async send(id, prompt, cfg) {
      cfg = cfg || {};
      try {
        // the page must have stopped moving: the same address, fully loaded, for 1.2 s (a client-side redirect or a late render would otherwise swallow what is typed)
        { let same = location.href, since = Date.now(), t0s = Date.now(); while (Date.now() - since < 1200 && Date.now() - t0s < 10000) { await sleep(200); if (location.href !== same || document.readyState !== 'complete') { same = location.href; since = Date.now(); } } }
        // a cookie banner: the most private answer, never "accept all" (cfg.dismiss = the exact texts of the buttons to press)
        for (const t of cfg.dismiss || []) { const b = [...document.querySelectorAll('button,[role="button"]')].filter(vis).find(x => text(x).toLowerCase() === String(t).toLowerCase()); if (b) { b.click(); await sleep(500); } }
        let input = null, t0 = Date.now();
        while (Date.now() - t0 < (cfg.inputWait || 20000)) {
          if (hasText(cfg.blocked)) { post({ id, t: 'blocked' }); return; }
          input = findInput(cfg); if (input && !all(cfg.login, true).length) break; input = null;
          if (all(cfg.login, true).length) { post({ id, t: 'login' }); return; }
          await sleep(400);
        }
        if (!input) { post({ id, t: hasText(cfg.loginText) ? 'login' : 'error', msg: 'no prompt box found on the page' }); return; }
        const answers0 = all(cfg.answer, false), base = { count: answers0.length, last: answers0.length ? ntext(answers0[answers0.length - 1]) : '' };
        const tail = prompt.trim().slice(-40);
        setText(input, prompt); await sleep(350);
        if (!boxText(input).trim()) { post({ id, t: 'error', msg: 'the prompt box did not accept the text' }); return; }
        let sent = false;
        for (let k = 0; k < 4 && !sent; k++) {
          const b = findSend(cfg, input);
          if (b && k < 2) b.click(); else { input.focus(); pressEnter(input); }
          for (let w = 0; w < 10 && !sent; w++) { await sleep(300); if (!boxText(input).trim() || all(cfg.busy, true).length || all(cfg.answer, false).length > base.count) sent = true; }
        }
        if (!sent) { post({ id, t: hasText(cfg.loginText) || all(cfg.login, true).length ? 'login' : 'error', msg: 'the site did not take the message' }); return; }
        const stable = cfg.stable || (cfg.busy && cfg.busy.length ? 2500 : 5000), limit = cfg.timeout || 180000;
        let cur = '', lastChange = Date.now(), t1 = Date.now(), lastPost = 0;
        while (Date.now() - t1 < limit) {
          await sleep(250);
          if (hasText(cfg.blocked)) { post({ id, t: 'blocked', text: cur }); return; }
          if (all(cfg.login, true).length) { post({ id, t: 'login' }); return; }
          const a = answerNow(cfg, base, tail);
          if (a !== cur) { cur = a; lastChange = Date.now(); if (Date.now() - lastPost > 150) { post({ id, t: 'text', text: cur }); lastPost = Date.now(); } }
          const busy = all(cfg.busy, true).length > 0;
          if (cur && !busy && Date.now() - lastChange > stable) { post({ id, t: 'final', text: cur }); return; }
        }
        post({ id, t: 'error', msg: 'timed out waiting for the answer', text: cur });
      } catch (e) { post({ id, t: 'error', msg: String(e && e.message || e) }); }
    },
    probe(id) {   // what a person needs to tell me to tune an adapter: the boxes, the buttons, the first words of the page
      const d = e => ({ tag: e.tagName, id: e.id || '', cls: String(e.className || '').slice(0, 80), name: e.getAttribute('name') || '', aria: e.getAttribute('aria-label') || '', ph: e.getAttribute('placeholder') || '', testid: e.getAttribute('data-testid') || '', type: e.type || '', role: e.getAttribute('role') || '', ce: e.getAttribute('contenteditable') || '', txt: text(e).slice(0, 30) });
      post({ id, t: 'probe', url: location.href, title: document.title,
        inputs: [...document.querySelectorAll('textarea,[contenteditable],input[type="text"]')].filter(vis).map(d),
        buttons: [...document.querySelectorAll('button,[role="button"]')].filter(vis).slice(-25).map(d),
        login: hasText(['log in', 'sign in', 'sign up', 'continue with google']), blocked: hasText(['verify you are human', 'just a moment', 'are you a robot']),
        sample: bodyText().replace(/\s+/g, ' ').slice(0, 300) });
    }
  };
})();
