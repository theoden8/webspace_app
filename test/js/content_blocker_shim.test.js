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

test('cosmetic fixture: hides matching elements via inline style', () => {
  // The cosmetic shim's hide() pass walks querySelectorAll for each
  // batched selector and sets el.style.display='none'. Checking the
  // inline style is the jsdom-friendly way to assert it ran;
  // computed-style assertions belong in Tier 2 against a real
  // engine.
  const dom = makeDom({ html: HOST_HTML });
  runInDom(dom, COSMETIC);
  const ad = dom.window.document.getElementById('ad1');
  const sp = dom.window.document.getElementById('sp1');
  const sidebar = dom.window.document.getElementById('sidebar-ad');
  const trk = dom.window.document.getElementById('trk');
  const keep = dom.window.document.getElementById('keep');
  assert.equal(ad.style.display, 'none');
  assert.equal(sp.style.display, 'none');
  assert.equal(sidebar.style.display, 'none');
  assert.equal(trk.style.display, 'none');
  assert.equal(keep.style.display, '',
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

test('cosmetic fixture: MutationObserver hides dynamically-added matches',
  async () => {
    const dom = makeDom({ html: '<!doctype html><html><body></body></html>' });
    runInDom(dom, COSMETIC);
    // Insert an ad after the shim has already run. The
    // MutationObserver's debounced 50ms hide() pass should catch it.
    const doc = dom.window.document;
    const newAd = doc.createElement('div');
    newAd.className = 'ad-banner';
    newAd.id = 'late-ad';
    doc.body.appendChild(newAd);
    // Wait past the shim's 50ms debounce.
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(newAd.style.display, 'none',
      'MutationObserver must hide ads inserted after the shim runs');
  });

test('cosmetic fixture: <style> tag survives MutationObserver passes', () => {
  const dom = makeDom({ html: HOST_HTML });
  runInDom(dom, COSMETIC);
  const styles = dom.window.document.querySelectorAll(
    '#_webspace_content_blocker_style');
  assert.equal(styles.length, 1);
});
