// Tier 1 — jsdom assertions for the wider ABP rule shapes the
// content-blocker shim in lib/services/content_blocker_shim.dart
// has to render. The shim is fed selector/style/text rule lists by
// ContentBlockerService, sourced from the adblock-rust engine.
//
// The 2026 perf fix dropped the runtime querySelectorAll sweep that
// re-applied selector hides on every mutation burst. Selector-based
// hides now rely entirely on the early <style> tag; only text-content
// rules keep the MutationObserver. These tests prove the parser's two
// new selector shapes survive that simplification:
//
//   1. `:-abp-has(...)` — rewritten by the parser to standard CSS
//      `:has(...)` and routed as a regular cosmetic selector. With
//      the old shim a `:has(...)` rule was matched at observer time
//      via querySelectorAll; the dropped sweep means the early CSS
//      path is the ONLY thing keeping these hides alive. The CSS
//      engine handles `:has()` reactively, including when a child's
//      class flips later — a case the old JS sweep couldn't even see
//      since it only watched childList mutations.
//
//   2. `:has-text(...)` / `:contains(...)` — converted by the parser
//      to TextHideRule(selector, patterns). These flow into TEXT_RULES
//      and ride the kept MutationObserver path. Multi-pattern OR is
//      already covered by cosmetic_multi.js; here we assert the same
//      shape works against the dedicated abp_rules.js fixture so the
//      contract stays explicit.
//
// Exception rules (@@||domain^) are domain-only and never reach the
// cosmetic shim, so they're covered by the Dart-side unit tests in
// test/content_blocker_service_test.dart, not here.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const ABP_RULES = readFixture('content_blocker/abp_rules.js');

const ABP_HTML = `<!doctype html><html><body>
  <div class="post" id="p-with-ad"><span class="ad-tag">x</span>body</div>
  <div class="post" id="p-clean">body without ad-tag</div>
  <div class="banner" id="bare-banner">plain banner</div>
  <div id="post-without-class"><span class="ad-tag">x</span></div>

  <p class="notice" id="n-sponsored">Sponsored item</p>
  <p class="notice" id="n-promoted">Promoted item</p>
  <p class="notice" id="n-clean">Regular item</p>

  <article id="art-ad">An Advertisement appears here</article>
  <article id="art-clean">Regular article body</article>
</body></html>`;

// ---------- :-abp-has() → CSS :has() (early-CSS path) ----------

test('abp_rules :has(): div.post:has(.ad-tag) hides matching parents only',
  () => {
    const dom = makeDom({ html: ABP_HTML });
    runInDom(dom, ABP_RULES);
    const cs = (id) =>
      dom.window.getComputedStyle(dom.window.document.getElementById(id))
        .display;
    assert.equal(cs('p-with-ad'), 'none',
      'div.post containing .ad-tag must be hidden by :has()');
    assert.notEqual(cs('p-clean'), 'none',
      'div.post without .ad-tag must stay visible');
    assert.notEqual(cs('post-without-class'), 'none',
      'element with .ad-tag child but missing the post class must stay visible');
  });

test('abp_rules :has(): plain selectors next to :has() are unaffected',
  () => {
    const dom = makeDom({ html: ABP_HTML });
    runInDom(dom, ABP_RULES);
    const cs = (id) =>
      dom.window.getComputedStyle(dom.window.document.getElementById(id))
        .display;
    assert.equal(cs('bare-banner'), 'none',
      '.banner must hide via the same early <style> tag the :has() rule lives in');
  });

test('abp_rules :has(): late-added matching subtree triggers hide via CSS engine',
  async () => {
    // The dropped JS sweep only observed childList mutations on the
    // body. Even with the sweep, a div.post that LATER gains a child
    // .ad-tag would not re-fire querySelectorAll on the parent. The
    // CSS :has() engine re-matches reactively. Asserting that here
    // proves the perf fix didn't regress this case (it actually
    // improves it).
    const dom = makeDom({ html: '<!doctype html><html><body>' +
      '<div class="post" id="late"><p>body</p></div></body></html>' });
    runInDom(dom, ABP_RULES);
    const doc = dom.window.document;
    const post = doc.getElementById('late');
    assert.notEqual(dom.window.getComputedStyle(post).display, 'none',
      'pre-condition: post without .ad-tag is visible');
    const tag = doc.createElement('span');
    tag.className = 'ad-tag';
    post.appendChild(tag);
    // Yield once for jsdom's style cache to reflect the mutation.
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(dom.window.getComputedStyle(post).display, 'none',
      'div.post must be hidden once a .ad-tag descendant is inserted');
  });

// ---------- :has-text() / :contains() → TextHideRule path ----------

test('abp_rules text rule: multi-pattern OR-match hides any matching paragraph',
  () => {
    // Mirrors what the parser emits for
    //   notice##:has-text(Sponsored)
    //   notice##:contains(Promoted)
    // collapsed onto p.notice with patterns ['Sponsored', 'Promoted'].
    const dom = makeDom({ html: ABP_HTML });
    runInDom(dom, ABP_RULES);
    const doc = dom.window.document;
    assert.equal(doc.getElementById('n-sponsored').style.display, 'none',
      'paragraph with "Sponsored" must be hidden');
    assert.equal(doc.getElementById('n-promoted').style.display, 'none',
      'paragraph with "Promoted" must be hidden');
    assert.equal(doc.getElementById('n-clean').style.display, '',
      'paragraph matching neither pattern must stay visible');
  });

test('abp_rules text rule: independent text rule with its own selector applies',
  () => {
    const dom = makeDom({ html: ABP_HTML });
    runInDom(dom, ABP_RULES);
    const doc = dom.window.document;
    assert.equal(doc.getElementById('art-ad').style.display, 'none',
      'article with "Advertisement" must be hidden');
    assert.equal(doc.getElementById('art-clean').style.display, '',
      'article without the pattern must stay visible');
  });

test('abp_rules text rule: MutationObserver re-applies text rules to late inserts',
  async () => {
    // Text rules can't be expressed in CSS; they MUST keep the
    // observer the perf fix preserved. Drop here would mean dynamic
    // sponsored content slips through.
    const dom = makeDom({ html: '<!doctype html><html><body></body></html>' });
    runInDom(dom, ABP_RULES);
    const doc = dom.window.document;
    const late = doc.createElement('p');
    late.className = 'notice';
    late.id = 'late-notice';
    late.textContent = 'Sponsored late insertion';
    doc.body.appendChild(late);
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(late.style.display, 'none',
      'observer must re-run text rules on later inserts');
  });
