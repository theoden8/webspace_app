// Tier 1 — jsdom equivalence proof for the proposed CSS-only cosmetic
// shim. The current shim has TWO redundant mechanisms for selector-
// based hides:
//
//   1. Early `<style>` tag with `selector { display: none !important }`
//      — applied by the browser's CSS engine to every matching element,
//      now and in the future, automatically.
//   2. Runtime `querySelectorAll(selector).forEach(el => el.style.display
//      = 'none')` — JS-side inline-style writes, re-run on every
//      MutationObserver burst.
//
// (1) is sufficient for selector-based hides. (2) was added defensively
// but is the source of perceived typing lag on editor-heavy pages
// (test/js/perf/cosmetic_keystroke.bench.js). Text-content rules can't
// be expressed in CSS so they MUST stay in the runtime observer.
//
// This test asserts that — measured via `getComputedStyle()` rather
// than `el.style.display` — the current shim and a CSS-only variant
// produce indistinguishable observable state for every selector-based
// case the existing shim covers. If they disagree, the optimization
// is unsafe and the test must catch it.
//
// What CSS-only DROPS:
//   * The inline `style="display:none"` write. Page scripts that read
//     `el.style.display` will see `''` instead of `'none'`. This is
//     deliberate; equivalence is asserted at computed-style level
//     because that's what affects rendering.
//
// What CSS-only KEEPS:
//   * Early `<style>` injection with `!important`.
//   * MutationObserver re-running text-content rules (CSS can't match
//     by text content, so this stays).

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const COSMETIC = readFixture('content_blocker/cosmetic.js');

// Build a minimal CSS-only cosmetic shim equivalent to what we'd ship.
// Same `<style>` injection as the current shim, but no runtime
// `hideCSS()` and the MutationObserver only re-runs text rules.
//
// Selectors and text rules are exactly the ones baked into the
// `cosmetic.js` fixture (test/js_fixtures/content_blocker/cosmetic.js)
// — kept in sync via tool/dump_shim_js.dart. Hardcoding them here is
// acceptable for an equivalence test: if the dumper changes the
// fixture's selector set, this file is updated alongside it.
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
  // Text rules (CSS can't match on text content): keep the observer,
  // scoped to whole-document re-scan on debounce. Same shape as
  // current shim's hideText path.
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

const HOST_HTML = `<!doctype html><html><body>
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

// ---------- helpers ----------

function snapshotComputed(dom, ids) {
  const out = {};
  for (const id of ids) {
    const el = dom.window.document.getElementById(id);
    if (el == null) {
      out[id] = '<missing>';
      continue;
    }
    out[id] = dom.window.getComputedStyle(el).display;
  }
  return out;
}

function runShim(dom, shim) {
  runInDom(dom, shim);
}

const SELECTOR_IDS =
  ['ad1', 'sp1', 'sidebar-ad', 'slot', 'trk', 'keep', 'text-no-match'];

// ---------- existing-DOM equivalence ----------

test('equivalence: selector-based hides agree on getComputedStyle (static DOM)',
  () => {
    const domA = makeDom({ html: HOST_HTML });
    runShim(domA, COSMETIC);
    const a = snapshotComputed(domA, SELECTOR_IDS);

    const domB = makeDom({ html: HOST_HTML });
    runShim(domB, COSMETIC_CSS_ONLY);
    const b = snapshotComputed(domB, SELECTOR_IDS);

    assert.deepEqual(b, a,
      `CSS-only and current shim must produce identical computed-display ` +
      `for selector-based elements. got A=${JSON.stringify(a)} ` +
      `B=${JSON.stringify(b)}`);

    // Sanity: the shape that BOTH variants must agree on is non-trivial.
    // ad1/sp1/sidebar-ad/slot/trk should all be hidden; keep should not.
    assert.equal(a.ad1, 'none');
    assert.equal(a.keep !== 'none', true,
      'keep must be visible; if not, both variants are wrong but equal');
  });

// ---------- dynamically-added matches ----------

test('equivalence: late-added matches hide via getComputedStyle in both shapes',
  async () => {
    async function lateAddAndSnapshot(shim) {
      const dom = makeDom({
        html: '<!doctype html><html><body></body></html>',
      });
      runShim(dom, shim);
      const newAd = dom.window.document.createElement('div');
      newAd.className = 'ad-banner';
      newAd.id = 'late-ad';
      dom.window.document.body.appendChild(newAd);
      await new Promise((r) => setTimeout(r, 100));
      return dom.window.getComputedStyle(newAd).display;
    }
    const a = await lateAddAndSnapshot(COSMETIC);
    const b = await lateAddAndSnapshot(COSMETIC_CSS_ONLY);
    assert.equal(a, b,
      `late-added .ad-banner must reach the same computed display. ` +
      `current=${a} css-only=${b}`);
    assert.equal(a, 'none', 'both variants must hide the late-added ad');
  });

// ---------- class added LATER (deferred match) ----------

test('equivalence: class added after creation hides in both shapes',
  async () => {
    async function classFlipAndSnapshot(shim) {
      const dom = makeDom({
        html: '<!doctype html><html><body><div id="d">x</div></body></html>',
      });
      runShim(dom, shim);
      const d = dom.window.document.getElementById('d');
      d.className = 'ad-banner';   // becomes a match
      await new Promise((r) => setTimeout(r, 100));
      return dom.window.getComputedStyle(d).display;
    }
    const a = await classFlipAndSnapshot(COSMETIC);
    const b = await classFlipAndSnapshot(COSMETIC_CSS_ONLY);
    assert.equal(a, b,
      `element that GAINS .ad-banner must reach the same computed display. ` +
      `current=${a} css-only=${b}`);
    assert.equal(a, 'none',
      'both variants must hide an element after it gains a matching class');
  });

// ---------- text rules: must agree (both keep the observer) ----------

test('equivalence: text-content rules agree in both shapes', () => {
  const domA = makeDom({ html: HOST_HTML });
  runShim(domA, COSMETIC);
  const domB = makeDom({ html: HOST_HTML });
  runShim(domB, COSMETIC_CSS_ONLY);
  const ids = ['text-match', 'text-no-match'];
  // Text rules write inline style in BOTH variants — assert on inline
  // here, since computed-style for text-content matches relies on the
  // same mechanism in both shapes.
  for (const id of ids) {
    assert.equal(
      domA.window.document.getElementById(id).style.display,
      domB.window.document.getElementById(id).style.display,
      `${id}: text-rule outcome must match between shapes`,
    );
  }
});

// ---------- known non-equivalence (documented) ----------

test('NON-equivalence: current writes inline style, css-only does not',
  () => {
    // This test documents the ONE observable difference between the
    // two shapes: the current shim writes el.style.display = 'none'
    // for selector-based hides; CSS-only relies on the <style> rule.
    // Pages that introspect el.style.display (rather than computed
    // style) will see different values. This is deliberate; the
    // user-visible state (rendering) is the same.
    const domA = makeDom({ html: HOST_HTML });
    runShim(domA, COSMETIC);
    const domB = makeDom({ html: HOST_HTML });
    runShim(domB, COSMETIC_CSS_ONLY);
    const ad1A = domA.window.document.getElementById('ad1');
    const ad1B = domB.window.document.getElementById('ad1');
    assert.equal(ad1A.style.display, 'none',
      'current shim writes inline style');
    assert.equal(ad1B.style.display, '',
      'css-only does NOT write inline style');
  });
