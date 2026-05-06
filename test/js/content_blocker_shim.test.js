// Tier 1 — jsdom assertions for the content-blocker shims
// (lib/services/content_blocker_shim.dart).
//
// Two outputs:
//   - early_css.js — inserts a <style> tag with `display: none` rules.
//   - cosmetic.js — same <style> + runtime querySelectorAll passes
//     + MutationObserver + text-match hiding.
//
// jsdom evaluates querySelector / MutationObserver, so we can prove
// the wiring works at the shape level. Real CSS specificity (does
// `display: none !important` actually win against the page's own
// stylesheet?) is asserted at Tier 2 against a real engine.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim, makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const EARLY_CSS = readFixture('content_blocker/early_css.js');
const COSMETIC = readFixture('content_blocker/cosmetic.js');
const COSMETIC_MULTI = readFixture('content_blocker/cosmetic_multi.js');

// Shared HTML covering the same selectors the dumper bakes in.
// Includes both selectors that match and ones that don't, plus a
// text-match candidate.
const HOST_HTML = `<!doctype html><html><body>
  <div class="ad-banner" id="ad1">ad</div>
  <div class="sponsored" id="sp1">sponsored block</div>
  <div id="sidebar-ad">sidebar</div>
  <div data-ad-slot="123">slot</div>
  <a href="https://track.example.com/x" id="trk">tracker</a>
  <div class="article">
    <p id="text-match">Sponsored content here</p>
    <p id="text-no-match">Real article body</p>
  </div>
  <p id="keep">unrelated</p>
</body></html>`;

// ---------- early_css ----------

test('early_css fixture: inserts <style> tag with display:none rules',
  () => {
    const dom = makeDom({ html: HOST_HTML });
    runInDom(dom, EARLY_CSS);
    const style = dom.window.document.getElementById(
      '_webspace_content_blocker_style');
    assert.ok(style, 'style tag must be created');
    assert.match(style.textContent, /display: none !important/);
    assert.match(style.textContent, /\.ad-banner/);
    assert.match(style.textContent, /\.sponsored/);
    assert.match(style.textContent, /#sidebar-ad/);
  });

test('early_css is idempotent — second injection is a no-op', () => {
  const dom = makeDom({ html: HOST_HTML });
  runInDom(dom, EARLY_CSS);
  runInDom(dom, EARLY_CSS);
  const styles = dom.window.document.querySelectorAll(
    '#_webspace_content_blocker_style');
  assert.equal(styles.length, 1, 'only one style tag should exist');
});

// ---------- cosmetic ----------

test('cosmetic fixture: hides matching elements via early-CSS computed style',
  () => {
    // Selector-based hides are owned by the early <style> tag (the
    // cosmetic shim's runtime CSS sweep was dropped). Computed style
    // is the contract; el.style.display is empty for these (the only
    // inline writes the shim does are for text-content rules).
    const dom = makeDom({ html: HOST_HTML });
    runInDom(dom, COSMETIC);
    const cs = (id) =>
      dom.window.getComputedStyle(dom.window.document.getElementById(id))
        .display;
    assert.equal(cs('ad1'), 'none');
    assert.equal(cs('sp1'), 'none');
    assert.equal(cs('sidebar-ad'), 'none');
    assert.equal(cs('trk'), 'none');
    assert.notEqual(cs('keep'), 'none',
      'unrelated elements must not be hidden');
  });

test('cosmetic fixture: text-match hides matching paragraphs', () => {
  const dom = makeDom({ html: HOST_HTML });
  runInDom(dom, COSMETIC);
  const matched = dom.window.document.getElementById('text-match');
  const unmatched = dom.window.document.getElementById('text-no-match');
  assert.equal(matched.style.display, 'none',
    'paragraph containing "Sponsored content" must be hidden');
  assert.equal(unmatched.style.display, '',
    'paragraph without sponsor text must not be hidden');
});

test('cosmetic fixture: late-added matches hide via early-CSS (no JS sweep)',
  async () => {
    const dom = makeDom({ html: '<!doctype html><html><body></body></html>' });
    runInDom(dom, COSMETIC);
    // Append an ad-banner AFTER the shim runs. The CSS engine matches
    // it automatically — no debounced JS sweep involved.
    const doc = dom.window.document;
    const newAd = doc.createElement('div');
    newAd.className = 'ad-banner';
    newAd.id = 'late-ad';
    doc.body.appendChild(newAd);
    // Briefly wait so any text-rules observer pass settles (it only
    // affects #?# rules; this element is selector-only).
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(dom.window.getComputedStyle(newAd).display, 'none',
      'late-added .ad-banner must be hidden by the early <style>');
  });

test('cosmetic fixture: <style> tag survives MutationObserver passes', () => {
  const dom = makeDom({ html: HOST_HTML });
  runInDom(dom, COSMETIC);
  const styles = dom.window.document.querySelectorAll(
    '#_webspace_content_blocker_style');
  assert.equal(styles.length, 1);
});

// ---------- cosmetic_multi ----------
//
// 25 selectors -> two batches of [20, 5]. Selector index 20 is the
// malformed `>>>invalid<<<`, so batch #2's querySelectorAll throws and
// the per-batch try/catch must isolate the failure to that batch only.
// Two text rules: the first OR-matches "Promoted" and "Sponsored", the
// second is a single-pattern control.

const MULTI_HTML = `<!doctype html><html><body>
  <div class="batch1-a"></div><div class="batch1-b"></div>
  <div class="batch1-c"></div><div class="batch1-d"></div>
  <div class="batch1-e"></div><div class="batch1-f"></div>
  <div class="batch1-g"></div><div class="batch1-h"></div>
  <div class="batch1-i"></div><div class="batch1-j"></div>
  <div class="batch1-k"></div><div class="batch1-l"></div>
  <div class="batch1-m"></div><div class="batch1-n"></div>
  <div class="batch1-o"></div><div class="batch1-p"></div>
  <div class="batch1-q"></div><div class="batch1-r"></div>
  <div class="batch1-s"></div><div class="batch1-t"></div>
  <div class="batch2-b" id="b2b"></div>
  <div class="batch2-c" id="b2c"></div>
  <div class="batch2-d" id="b2d"></div>
  <div class="batch2-e" id="b2e"></div>
  <p class="notice" id="n-promoted">Promoted post here</p>
  <p class="notice" id="n-sponsored">Sponsored block</p>
  <p class="notice" id="n-clean">Regular news article</p>
  <div class="bio" id="b-editor">Editor's note: read this.</div>
  <div class="bio" id="b-reader">Reader response: thanks.</div>
</body></html>`;

test('cosmetic_multi: malformed selector is dropped by the CSS parser, others apply',
  () => {
    // Pre-2026 the shim ran a runtime querySelectorAll sweep grouped
    // into batches of 20 — a malformed selector would throw and
    // poison its whole batch. The runtime sweep was dropped; selector
    // hides are handled entirely by the early <style> tag now. CSS
    // parsers are forgiving of invalid rules: the malformed
    // `>>>invalid<<<` rule is silently discarded and EVERY other valid
    // selector in the same stylesheet still applies. That is a strict
    // improvement on the old behaviour, where 4 valid selectors were
    // collateral-damage hidden behind a malformed sibling.
    const dom = makeDom({ html: MULTI_HTML });
    runInDom(dom, COSMETIC_MULTI);
    const doc = dom.window.document;
    const cs = (id) =>
      dom.window.getComputedStyle(doc.getElementById(id)).display;

    const letters = 'abcdefghijklmnopqrst'.split('');
    for (const ch of letters) {
      const el = doc.querySelector('.batch1-' + ch);
      el.id = 'b1-' + ch;
      assert.equal(dom.window.getComputedStyle(el).display, 'none',
        '.batch1-' + ch + ' must be hidden by the early CSS');
    }
    // The selectors that previously shared a batch with `>>>invalid<<<`
    // are valid CSS by themselves. Under the early-CSS model they are
    // hidden — the malformed rule is discarded by the parser without
    // affecting the others.
    for (const id of ['b2b', 'b2c', 'b2d', 'b2e']) {
      assert.equal(cs(id), 'none',
        '#' + id + ' must be hidden — its rule is valid CSS, the ' +
        'malformed sibling no longer drags it down');
    }
  });

test('cosmetic_multi: malformed selector does not throw out of the shim',
  () => {
    // Smoke test — the early <style> tag accepts the full ruleset
    // including `>>>invalid<<<`; the CSS parser silently drops the
    // bad rule. Eval must not throw.
    const dom = makeDom({ html: MULTI_HTML });
    assert.doesNotThrow(() => runInDom(dom, COSMETIC_MULTI));
  });

test('cosmetic_multi: text rule with multiple patterns OR-matches',
  () => {
    const dom = makeDom({ html: MULTI_HTML });
    runInDom(dom, COSMETIC_MULTI);
    const doc = dom.window.document;
    assert.equal(doc.getElementById('n-promoted').style.display, 'none',
      'paragraph with "Promoted" must be hidden');
    assert.equal(doc.getElementById('n-sponsored').style.display, 'none',
      'paragraph with "Sponsored" must be hidden');
    assert.equal(doc.getElementById('n-clean').style.display, '',
      'paragraph matching neither pattern must stay visible');
  });

test('cosmetic_multi: a second text rule with its own selector still applies',
  () => {
    const dom = makeDom({ html: MULTI_HTML });
    runInDom(dom, COSMETIC_MULTI);
    const doc = dom.window.document;
    assert.equal(doc.getElementById('b-editor').style.display, 'none',
      '.bio with "Editor" must be hidden');
    assert.equal(doc.getElementById('b-reader').style.display, '',
      '.bio without "Editor" must stay visible');
  });

test('cosmetic_multi: MutationObserver re-applies text rules to dynamic DOM',
  async () => {
    const dom = makeDom({ html: '<!doctype html><html><body></body></html>' });
    runInDom(dom, COSMETIC_MULTI);
    const doc = dom.window.document;
    const late = doc.createElement('p');
    late.className = 'notice';
    late.id = 'late-sponsored';
    late.textContent = 'Sponsored late insertion';
    doc.body.appendChild(late);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(late.style.display, 'none',
      'MutationObserver must re-run text rules on later inserts');
  });
