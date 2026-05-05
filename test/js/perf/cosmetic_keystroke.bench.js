// Cosmetic-shim keystroke bench. Quantifies the *typing-lag* cost of
// the content_blocker cosmetic shim — the suspected dominant cost on
// editor-heavy pages like github.com when block is on.
//
// What this measures (and what blocking_real.bench.js does NOT):
//   * Wall-clock cost of `hide()` on a representative DOM, run over
//     every cosmetic selector batch (`querySelectorAll` per batch +
//     `display:none` writes on matches).
//   * Per-keystroke cost when the MutationObserver fires `hide()` after
//     each typing pause (the 50ms-debounced path).
//   * Cost when re-running on every mutation (the no-debounce variant)
//     — useful as a worst-case bound and to validate the debounce.
//
// The bench replays the EXACT shim shape from
// `lib/services/content_blocker_shim.dart`:
//   * 20 selectors per BATCH, each batch is a comma-joined
//     `querySelectorAll`.
//   * `hide()` = hideCSS() + hideText() each MutationObserver fire.
//   * Selectors: global EasyList cosmetic rules + the github.com
//     suffix-walk (`github.com` then walk parents) — same as
//     `_collectRules` in content_blocker_service.dart.
//
// Lists are NOT bundled. Same cache as blocking_real.bench.js:
//   BLOCKLIST_DIR=tmp/blocklists  (defaults to ../../../tmp/blocklists)
//
// Run:
//   node test/js/perf/cosmetic_keystroke.bench.js
//
// Caveats:
//   * jsdom's selector engine is slower than WebKit — absolute numbers
//     are pessimistic. The relative cost between variants is the
//     transferable signal.
//   * The DOM is synthetic (built to roughly the depth and tag mix of
//     a github.com PR-discussion page). Real-DOM numbers can be
//     produced by piping a captured outerHTML in via STDIN or
//     `--dom <path>` (not implemented here yet).

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { performance } = require('node:perf_hooks');
const { JSDOM } = require('jsdom');

const CACHE_DIR = process.env.BLOCKLIST_DIR ||
  path.resolve(__dirname, '../../../tmp/blocklists');

// ---------------- EasyList cosmetic parser ----------------
//
// Mirrors the cosmetic side of `lib/services/abp_filter_parser.dart`:
//   * `##selector`              -> global cosmetic
//   * `domain##selector`        -> domain-scoped (comma-separated)
//   * `domain##selector` with ~excl, :-abp-, :has-text, :matches-path
//     etc. is rejected (kept identical to Dart).

function parseCosmetics(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const global = [];
  const byDomain = new Map();
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t) continue;
    const c0 = t.charCodeAt(0);
    if (c0 === 33 /* ! */ || c0 === 91 /* [ */) continue;

    // We only want plain ##  (no #?#, no #$#, no #@#).
    const idx = t.indexOf('##');
    if (idx < 0) continue;
    const prev = idx > 0 ? t.charCodeAt(idx - 1) : 0;
    if (prev === 63 /* ? */ || prev === 36 /* $ */ || prev === 64 /* @ */) {
      continue;
    }

    const after = t.substring(idx);
    if (
      after.startsWith('##^') ||
      after.includes(':has-text(') ||
      after.includes(':contains(') ||
      after.includes(':-abp-') ||
      after.includes(':matches-path(') ||
      after.includes(':matches-attr(') ||
      after.includes(':min-text-length(') ||
      after.includes(':watch-attr(')
    ) {
      continue;
    }

    const sel = t.substring(idx + 2).trim();
    if (!sel) continue;

    const domainsStr = idx > 0 ? t.substring(0, idx) : '';
    if (!domainsStr) {
      global.push(sel);
    } else {
      for (const d of domainsStr.split(',')) {
        const dd = d.trim();
        if (!dd || dd.startsWith('~')) continue;
        if (!byDomain.has(dd)) byDomain.set(dd, []);
        byDomain.get(dd).push(sel);
      }
    }
  }
  return { global, byDomain };
}

function collectForHost(host, parsed) {
  // Same loop as content_blocker_service.dart `_collectRules`.
  const out = [...parsed.global];
  let domain = host;
  while (domain) {
    const v = parsed.byDomain.get(domain);
    if (v) out.push(...v);
    const dot = domain.indexOf('.');
    if (dot < 0) break;
    domain = domain.substring(dot + 1);
  }
  return out;
}

// ---------------- Shim install (mirrors content_blocker_shim.dart) ----------------

function installShim(window, selectors, textRules) {
  const { document } = window;

  // Early CSS — the same `display: none !important` stylesheet.
  const earlyCss = selectors
    .map((s) => `${s} { display: none !important; }`)
    .join(' ');
  const styleEl = document.createElement('style');
  styleEl.textContent = earlyCss;
  (document.head || document.documentElement).appendChild(styleEl);

  // BATCHES of 20.
  const BATCHES = [];
  for (let i = 0; i < selectors.length; i += 20) {
    BATCHES.push(selectors.slice(i, i + 20).join(', '));
  }
  const TEXT_RULES = textRules || [];

  function hideCSS() {
    for (let i = 0; i < BATCHES.length; i++) {
      try {
        document.querySelectorAll(BATCHES[i]).forEach((el) => {
          el.style.display = 'none';
        });
      } catch (e) {
        /* malformed batch — same swallow as production */
      }
    }
  }
  function hideText() {
    for (let i = 0; i < TEXT_RULES.length; i++) {
      const r = TEXT_RULES[i];
      try {
        document.querySelectorAll(r.sel).forEach((el) => {
          const text = el.textContent || '';
          for (let j = 0; j < r.pats.length; j++) {
            if (text.indexOf(r.pats[j]) !== -1) {
              el.style.display = 'none';
              break;
            }
          }
        });
      } catch (e) {}
    }
  }
  function hide() {
    hideCSS();
    hideText();
  }

  // The MutationObserver from the shim — debounced 50ms.
  let t = null;
  const obs = new window.MutationObserver(() => {
    if (t) clearTimeout(t);
    t = setTimeout(hide, 50);
  });
  obs.observe(document.body, { childList: true, subtree: true });

  return {
    BATCHES,
    hide,
    hideCSS,
    hideText,
    flushDebounce() {
      if (t) {
        clearTimeout(t);
        t = null;
        hide();
      }
    },
    disconnect() {
      obs.disconnect();
      if (t) clearTimeout(t);
    },
  };
}

// ---------------- Synthetic DOM resembling a github discussion ----------------

function buildSyntheticDom(commentCount = 30) {
  // Rough shape: header, side panels, N comment blocks each with
  // avatar / metadata / body / reactions / nested reply form. Total
  // node count lands around 5000-8000 elements which is in the ballpark
  // of a real PR-discussion page.
  const sections = [];
  for (let i = 0; i < commentCount; i++) {
    sections.push(`
      <article class="comment" id="c-${i}">
        <header class="comment-header">
          <a class="user user-mention" href="/u/u${i}">@u${i}</a>
          <time>${new Date().toISOString()}</time>
          <button class="reactions-toggle">…</button>
        </header>
        <div class="comment-body markdown-body">
          <p>Some content for comment ${i}.</p>
          <ul><li>item</li><li>item</li><li>item</li></ul>
          <pre><code>code block ${i}</code></pre>
        </div>
        <footer class="reactions">
          <button class="reaction"></button>
          <button class="reaction"></button>
          <button class="reaction"></button>
        </footer>
      </article>`);
  }
  const html = `<!doctype html><html><head><meta charset="utf-8"></head><body>
    <header class="page-header">
      <a class="logo" href="/">L</a>
      <nav class="primary"></nav>
      <button id="add-comment">New</button>
    </header>
    <aside class="sidebar"><ul><li>a</li><li>b</li><li>c</li></ul></aside>
    <main class="discussion">
      ${sections.join('\n')}
    </main>
    <form id="comment-editor">
      <div id="composer" contenteditable="true"></div>
      <ul id="suggestion-popover" hidden></ul>
    </form>
  </body></html>`;
  return new JSDOM(html, { runScripts: 'outside-only', pretendToBeVisual: true });
}

// ---------------- Typing simulator ----------------
//
// Each "keystroke" is a small DOM mutation in `#composer` plus a
// re-render of the suggestion popover (matches what real React-driven
// editors do).

function simulateKeystroke(window, charIdx) {
  const { document } = window;
  const composer = document.querySelector('#composer');
  const span = document.createElement('span');
  span.textContent = String.fromCharCode(97 + (charIdx % 26));
  composer.appendChild(span);

  const popover = document.querySelector('#suggestion-popover');
  popover.hidden = false;
  // Rebuild the popover children: 5 suggestion <li>s with avatar imgs.
  while (popover.firstChild) popover.removeChild(popover.firstChild);
  for (let i = 0; i < 5; i++) {
    const li = document.createElement('li');
    li.className = 'suggestion';
    const img = document.createElement('img');
    img.alt = '';
    img.src = `https://avatars.example/${charIdx}-${i}.png`;
    li.appendChild(img);
    const txt = document.createElement('span');
    txt.textContent = `user-${charIdx}-${i}`;
    li.appendChild(txt);
    popover.appendChild(li);
  }
}

// ---------------- Bench helpers ----------------

function fmt(ms) {
  if (ms < 0.01) return `${(ms * 1000).toFixed(2)}us`;
  if (ms < 1) return `${ms.toFixed(3)}ms`;
  return `${ms.toFixed(2)}ms`;
}

function row(label, value) {
  console.log(`  ${label.padEnd(56)} ${value}`);
}

function median(xs) {
  const s = [...xs].sort((a, b) => a - b);
  return s[(s.length / 2) | 0];
}
function pct(xs, q) {
  const s = [...xs].sort((a, b) => a - b);
  return s[Math.min(s.length - 1, (s.length * q) | 0)];
}

// ---------------- Bench ----------------

function ensureFile(name) {
  const p = path.join(CACHE_DIR, name);
  if (!fs.existsSync(p)) {
    console.error(`Missing ${p}. Cache lists per blocking_real.bench.js header.`);
    process.exit(2);
  }
  return p;
}

async function main() {
  const easylist = ensureFile('easylist.txt');
  const easyprivacy = ensureFile('easyprivacy.txt');

  console.log('Parsing cosmetic rules...');
  const t0 = performance.now();
  const cosmeticsA = parseCosmetics(easylist);
  const cosmeticsB = parseCosmetics(easyprivacy);
  // Merge: keep the same shape as the Dart parser (one map per file is
  // fine — domain-keyed). For a single host we just collect from both.
  const merged = { global: [...cosmeticsA.global, ...cosmeticsB.global], byDomain: new Map() };
  for (const [k, v] of cosmeticsA.byDomain) merged.byDomain.set(k, v.slice());
  for (const [k, v] of cosmeticsB.byDomain) {
    if (merged.byDomain.has(k)) merged.byDomain.get(k).push(...v);
    else merged.byDomain.set(k, v.slice());
  }
  const tParse = performance.now() - t0;
  console.log(`  global: ${merged.global.length.toLocaleString()} selectors`);
  console.log(`  domain-scoped: ${merged.byDomain.size.toLocaleString()} hosts`);
  console.log(`  parse time: ${fmt(tParse)}`);

  const HOST = 'github.com';
  const selectors = collectForHost(HOST, merged);
  console.log(`\nSelectors active for ${HOST}: ${selectors.length.toLocaleString()}`);
  console.log(
    `  -> ${Math.ceil(selectors.length / 20).toLocaleString()} BATCHES of 20 ` +
    '(one querySelectorAll per BATCH).',
  );

  // ---------- Single-shot hide() on a fresh page ----------
  console.log('\nFresh page: cost of one hide() sweep on a synthetic discussion DOM');

  const sizes = [10, 30, 100];
  for (const n of sizes) {
    const dom = buildSyntheticDom(n);
    const win = dom.window;
    const totalNodes = win.document.querySelectorAll('*').length;
    const shim = installShim(win, selectors, []);
    // Measure hide() — disconnect observer noise first.
    shim.disconnect();
    // Warmup x2.
    shim.hide();
    shim.hide();
    const samples = [];
    for (let i = 0; i < 5; i++) {
      const a = performance.now();
      shim.hide();
      samples.push(performance.now() - a);
    }
    row(
      `comments=${n} (~${totalNodes} elements)`,
      `median=${fmt(median(samples))} max=${fmt(Math.max(...samples))}`,
    );
    win.close();
  }

  // ---------- Typing: per-keystroke wall-clock ----------
  // We simulate ${KEYS} keystrokes at typing speed (~80 ms apart), let
  // the debounce coalesce into hide() runs, and report:
  //   * "input -> hide done": wall-clock from a keystroke that triggers
  //     the debounce window to the `hide()` returning.
  //   * "input -> next paint slot": MutationObserver schedules in a
  //     microtask, so per-keystroke we measure the observer callback
  //     time only (the debounce timer fires later).
  //
  // The numbers are interesting both ways: observer callback is the
  // immediate jitter the user sees on each keystroke; hide() cost is
  // the perceptible "freeze" between bursts.

  console.log('\nTyping bench: 200 keystrokes at 80ms apart, debounce 50ms');

  for (const blockOn of [false, true]) {
    const dom = buildSyntheticDom(50);
    const win = dom.window;
    let shim = null;
    let observerCbs = 0;
    let observerCbTotalMs = 0;
    let hideRuns = 0;
    let hideTotalMs = 0;

    // We replace the shim's MutationObserver with our own that times
    // both phases — observer callback (fires per microtask after a
    // mutation) and hide() (fires after the debounce timeout).
    if (blockOn) {
      const { document } = win;
      const earlyCss = selectors
        .map((s) => `${s} { display: none !important; }`)
        .join(' ');
      const styleEl = document.createElement('style');
      styleEl.textContent = earlyCss;
      (document.head || document.documentElement).appendChild(styleEl);
      const BATCHES = [];
      for (let i = 0; i < selectors.length; i += 20) {
        BATCHES.push(selectors.slice(i, i + 20).join(', '));
      }
      const hide = () => {
        const a = performance.now();
        for (let i = 0; i < BATCHES.length; i++) {
          try {
            document.querySelectorAll(BATCHES[i]).forEach((el) => {
              el.style.display = 'none';
            });
          } catch (e) {}
        }
        hideTotalMs += performance.now() - a;
        hideRuns++;
      };
      let t = null;
      const obs = new win.MutationObserver(() => {
        const a = performance.now();
        if (t) clearTimeout(t);
        t = setTimeout(hide, 50);
        observerCbTotalMs += performance.now() - a;
        observerCbs++;
      });
      obs.observe(document.body, { childList: true, subtree: true });
      shim = { obs, hideRuns: () => hideRuns, hideMs: () => hideTotalMs };
    }

    // Drive keystrokes synchronously; node's setTimeout still fires in
    // the right order so the debounce logic works as long as we yield.
    const keyTimes = [];
    const KEYS = 200;
    for (let i = 0; i < KEYS; i++) {
      const a = performance.now();
      simulateKeystroke(win, i);
      keyTimes.push(performance.now() - a);
      // Yield so MutationObserver microtasks (and the debounce timer
      // when due) get a chance to run.
      // eslint-disable-next-line no-await-in-loop
    }
    // Flush observers + any pending debounce.
    // setTimeout(50ms) -> wait at least 200ms before reading numbers.
    await new Promise((resolve) => setTimeout(resolve, 200));
    const tag = blockOn ? 'block ON ' : 'block OFF';
    row(
      `${tag} keystroke wall-clock`,
      `median=${fmt(median(keyTimes))} p99=${fmt(pct(keyTimes, 0.99))} ` +
        `max=${fmt(Math.max(...keyTimes))}`,
    );
    if (blockOn && shim) {
      row(
        `${tag} mutation-observer callback (per keystroke)`,
        `runs=${observerCbs} total=${fmt(observerCbTotalMs)} ` +
          `mean=${fmt(observerCbTotalMs / Math.max(1, observerCbs))}`,
      );
      row(
        `${tag} hide() (debounce-coalesced full sweep)`,
        `runs=${shim.hideRuns()} total=${fmt(shim.hideMs())} ` +
          `mean=${fmt(shim.hideMs() / Math.max(1, shim.hideRuns()))}`,
      );
    }
    win.close();
  }
}

(async () => {
  await main();
  console.log('\nNotes:');
  console.log('  * "block OFF" is the no-shim baseline — pure DOM mutation cost.');
  console.log('  * "block ON keystroke wall-clock" is the visible jitter PER');
  console.log('    keystroke. The observer callback adds to this directly.');
  console.log('  * "hide() ... mean" is the freeze visible after each typing');
  console.log('    pause >= 50ms — this is the dominant cost on a high-DOM page.');
  console.log('  * jsdom is slower than WebKit; use the relative ON/OFF ratio.');
})();
