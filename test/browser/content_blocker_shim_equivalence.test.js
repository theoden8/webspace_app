// Tier 2 — real-Chromium equivalence proof for the proposed CSS-only
// cosmetic shim. Companion to test/js/content_blocker_shim_equivalence.test.js
// (jsdom). The jsdom layer asserts equivalence in the CSS engine
// jsdom can model; this layer asserts it under a real engine, where
// CSS specificity, !important precedence, MutationObserver timing,
// and stylesheet-level matching all behave to spec.
//
// What this proves: dropping the runtime cosmetic-CSS sweep from
// `lib/services/content_blocker_shim.dart` does NOT change the
// observable computed-style of any element on a representative page
// — including dynamically-added matches and class-flipped matches.
// The user-visible privacy posture is identical for selector-based
// rules. Inline `el.style.display` differs (the css-only shape never
// writes inline style for selector matches), but rendering is the
// same; that is asserted via `getComputedStyle`.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const COSMETIC = readFixture('content_blocker/cosmetic.js');

// Same CSS-only shim shape as the tier-1 test. Inlined here so this
// file is self-contained and the contract under test is visible.
const COSMETIC_CSS_ONLY = `
(function() {
  var ID = '_webspace_content_blocker_style';
  if (!document.getElementById(ID)) {
    var s = document.createElement('style');
    s.id = ID;
    s.textContent =
      '.ad-banner { display: none !important; } ' +
      '.sponsored { display: none !important; } ' +
      '#sidebar-ad { display: none !important; } ' +
      '[data-ad-slot] { display: none !important; } ' +
      'a[href*="track."] { display: none !important; } ';
    (document.head || document.documentElement).appendChild(s);
  }
  var TEXT_RULES = [{sel:'div.article > p', pats:['Sponsored content']}];
  function hideText() {
    for (var i = 0; i < TEXT_RULES.length; i++) {
      var r = TEXT_RULES[i];
      try {
        document.querySelectorAll(r.sel).forEach(function(el) {
          var text = el.textContent || '';
          for (var j = 0; j < r.pats.length; j++) {
            if (text.indexOf(r.pats[j]) !== -1) {
              el.style.display = 'none';
              break;
            }
          }
        });
      } catch (e) {}
    }
  }
  hideText();
  var t = null;
  var obs = new MutationObserver(function() {
    if (t) clearTimeout(t);
    t = setTimeout(hideText, 50);
  });
  if (document.body) {
    obs.observe(document.body, { childList: true, subtree: true });
  } else {
    document.addEventListener('DOMContentLoaded', function() {
      hideText();
      obs.observe(document.body, { childList: true, subtree: true });
    });
  }
})();
`;

const browser = setupBrowser();

// Page deliberately ships its OWN stylesheet that says
// `.ad-banner { display: block }` etc., so we exercise the !important
// override on a real CSS engine. Without `!important` the early CSS
// would silently lose to the page rule.
const HOST_HTML = `<!doctype html><html><head>
<style>
  .ad-banner { display: block; }
  .sponsored { display: block; }
  #sidebar-ad { display: block; }
  [data-ad-slot] { display: block; }
  a[href*="track."] { display: inline; }
</style></head><body>
  <div class="ad-banner" id="ad1">ad</div>
  <div class="sponsored" id="sp1">sponsored block</div>
  <div id="sidebar-ad">sidebar</div>
  <div data-ad-slot="123" id="slot">slot</div>
  <a href="https://track.example.com/x" id="trk">tracker</a>
  <div class="article">
    <p id="text-match">Sponsored content here</p>
    <p id="text-no-match">Real article body</p>
  </div>
  <p id="keep">unrelated</p>
</body></html>`;

const SELECTOR_IDS =
  ['ad1', 'sp1', 'sidebar-ad', 'slot', 'trk', 'keep', 'text-no-match'];

function startHost() {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(HOST_HTML);
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}/`,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

// Run the shim post-load (same workaround as content_blocker_real.test.js)
// so document.head exists when the <style> tag is appended.
async function snapshotComputedAfterShim(shim, mutate) {
  const server = await startHost();
  const page = await browser.browser.newPage();
  try {
    await page.goto(server.url, { waitUntil: 'load' });
    await page.evaluate(shim);
    if (mutate) await mutate(page);
    return await page.evaluate((ids) => {
      const out = {};
      for (const id of ids) {
        const el = document.getElementById(id);
        out[id] = el == null ? '<missing>' : getComputedStyle(el).display;
      }
      return out;
    }, SELECTOR_IDS);
  } finally {
    await page.close();
    await server.close();
  }
}

// ---------- existing-DOM equivalence ----------

test('tier-2 equivalence: static DOM, both shapes agree on getComputedStyle',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const a = await snapshotComputedAfterShim(COSMETIC);
    const b = await snapshotComputedAfterShim(COSMETIC_CSS_ONLY);
    assert.deepEqual(b, a,
      `Real-engine: CSS-only must match current shim per-id. ` +
      `current=${JSON.stringify(a)} css-only=${JSON.stringify(b)}`);
    // Sanity — both must hide the targets in the face of the page's
    // competing display:block, otherwise the test is asserting
    // matching FAILURES.
    assert.equal(a.ad1, 'none', 'sanity: !important must beat page rule');
    assert.notEqual(a.keep, 'none', 'sanity: unrelated stays visible');
  });

// ---------- dynamically-added matches ----------

test('tier-2 equivalence: late-added .ad-banner agrees in both shapes',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    async function lateAdd(shim) {
      const server = await startHost();
      const page = await browser.browser.newPage();
      try {
        await page.goto(server.url, { waitUntil: 'load' });
        await page.evaluate(shim);
        return await page.evaluate(async () => {
          const newAd = document.createElement('div');
          newAd.className = 'ad-banner';
          newAd.id = 'late-ad';
          newAd.textContent = 'late';
          document.body.appendChild(newAd);
          // Allow time for any debounced sweep to settle.
          await new Promise((r) => setTimeout(r, 150));
          return getComputedStyle(newAd).display;
        });
      } finally {
        await page.close();
        await server.close();
      }
    }
    const a = await lateAdd(COSMETIC);
    const b = await lateAdd(COSMETIC_CSS_ONLY);
    assert.equal(a, b,
      `late-added .ad-banner: current=${a} css-only=${b}`);
    assert.equal(a, 'none', 'both must hide the late-added ad');
  });

// ---------- class added LATER (CSS-engine re-match required) ----------

test('tier-2 equivalence: class flip from no-match to .ad-banner agrees',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    async function flip(shim) {
      const server = await startHost();
      const page = await browser.browser.newPage();
      try {
        await page.goto(server.url, { waitUntil: 'load' });
        await page.evaluate(shim);
        return await page.evaluate(async () => {
          // #keep starts as a no-match. Flip its class to .ad-banner —
          // CSS engine re-matches automatically; current shim's
          // MutationObserver only watches childList (NOT attributes),
          // so its runtime sweep would NOT see the change. The test
          // confirms that, given CSS-engine-driven matching, both
          // shapes converge.
          const k = document.getElementById('keep');
          k.className = 'ad-banner';
          await new Promise((r) => setTimeout(r, 150));
          return getComputedStyle(k).display;
        });
      } finally {
        await page.close();
        await server.close();
      }
    }
    const a = await flip(COSMETIC);
    const b = await flip(COSMETIC_CSS_ONLY);
    assert.equal(a, b,
      `class flip: current=${a} css-only=${b}`);
    assert.equal(a, 'none',
      'CSS engine must hide #keep after it gains .ad-banner');
  });

// ---------- text rules ----------

test('tier-2 equivalence: text-content rules agree in both shapes',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    async function snap(shim) {
      const server = await startHost();
      const page = await browser.browser.newPage();
      try {
        await page.goto(server.url, { waitUntil: 'load' });
        await page.evaluate(shim);
        return await page.evaluate(() => ({
          match: getComputedStyle(document.getElementById('text-match')).display,
          nomatch: getComputedStyle(document.getElementById('text-no-match')).display,
        }));
      } finally {
        await page.close();
        await server.close();
      }
    }
    const a = await snap(COSMETIC);
    const b = await snap(COSMETIC_CSS_ONLY);
    assert.deepEqual(b, a, `text rules: current=${JSON.stringify(a)} ` +
      `css-only=${JSON.stringify(b)}`);
    assert.equal(a.match, 'none',
      'sanity: paragraph with "Sponsored content" must be hidden');
    assert.notEqual(a.nomatch, 'none',
      'sanity: clean paragraph must remain visible');
  });

// ---------- inline-style invariant ----------

test('tier-2: inline el.style.display empty for selector matches in both shapes',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    async function snap(shim) {
      const server = await startHost();
      const page = await browser.browser.newPage();
      try {
        await page.goto(server.url, { waitUntil: 'load' });
        await page.evaluate(shim);
        return await page.evaluate(() => ({
          inline: document.getElementById('ad1').style.display,
          computed: getComputedStyle(document.getElementById('ad1')).display,
        }));
      } finally {
        await page.close();
        await server.close();
      }
    }
    const a = await snap(COSMETIC);
    const b = await snap(COSMETIC_CSS_ONLY);
    // Computed style — what affects rendering — MUST agree.
    assert.equal(a.computed, b.computed,
      `computed-display must match: current=${a.computed} ` +
      `css-only=${b.computed}`);
    assert.equal(a.computed, 'none', 'sanity');
    // Neither shape writes inline style for selector matches now (the
    // pre-2026 runtime sweep that wrote `el.style.display = 'none'`
    // was dropped). Locked in here so any future change that re-
    // introduces the inline write must be deliberate.
    assert.equal(a.inline, '',
      'shipped shim does not write inline style for selector matches');
    assert.equal(b.inline, '',
      'reference shim does not write inline style for selector matches');
  });
