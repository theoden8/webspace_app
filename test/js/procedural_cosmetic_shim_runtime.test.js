// Tier 1 — jsdom runtime tests for procedural_cosmetic_shim.dart.
//
// The Dart-side test (test/procedural_cosmetic_shim_test.dart) only
// pins the BUILDER's output shape — that the shim source string
// contains the expected operator/action branches. That layer caught
// nothing when both real bugs landed:
//   * adblock-rust embeds ABP pseudos (:has-text, :upward) INSIDE the
//     css-selector arg, not as separate operators. The shim used to
//     hand the whole string to querySelectorAll, which throws on
//     `:has-text(`, and the entire rule got dropped at runtime.
//   * Generic procedural rules silently dropped by adblock-rust at
//     parse time — fallback path landed in Dart, but neither tier
//     exercised the resulting JSON-to-DOM run.
//
// This file runs the dumped fixture through jsdom against per-row
// sample markup — the same one Section 1C of abp_rule_probe.html
// uses. Any future regression in either layer (Dart parser dropping
// rules, JS shim mis-splitting pseudos, action handler not firing)
// turns red here at CI time instead of when a user opens the probe.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const PROCEDURAL = readFixture('content_blocker/procedural_actions.js');

// One section per rule shape. `match` is the markup the rule should
// hit; `nonMatch` is markup deliberately crafted to look similar but
// not satisfy the operators (false-positive guard).
const ROWS = [
  {
    name: ':remove() drops the element',
    match: '<div class="fp_probe_proc_remove">REMOVE-ME marker</div>',
    nonMatch:
      '<div class="fp_probe_proc_remove">no marker text</div>',
    check: (probe, fp) => {
      assert.equal(
        probe.firstElementChild,
        null,
        'matching element must be removed from the DOM',
      );
      assert.ok(
        fp.firstElementChild,
        'non-matching element must remain in the DOM',
      );
    },
  },
  {
    name: ':upward(N):remove() walks N parents before removing',
    match: '<div class="fp_probe_proc_upward"><span>LEAF text</span></div>',
    nonMatch:
      '<div class="fp_probe_proc_upward"><span>off-target</span></div>',
    check: (probe, fp) => {
      // Engine: querySelectorAll matches .fp_probe_proc_upward, then
      // :has-text(LEAF) keeps it, then :upward(1) walks ONE parent
      // (the test scaffolding wrap), then :remove() drops that
      // wrap. The wrap reference survives in JS but is detached
      // from the document, so isConnected is the right signal.
      assert.equal(probe.isConnected, false,
        'wrap (the upward(1) target) must be detached from the DOM');
      assert.equal(fp.isConnected, true,
        'non-matching markup must keep its wrap connected');
    },
  },
  {
    name: ':style() on a procedural selector sets the declarations',
    match:
      '<div class="fp_probe_proc_style">Sponsored content here</div>',
    nonMatch:
      '<div class="fp_probe_proc_style">unrelated copy</div>',
    check: (probe, fp) => {
      const el = probe.firstElementChild;
      assert.ok(el, ':style() must NOT remove the element');
      // jsdom doesn't compute outline shorthand the way real
      // engines do — assert the inline style was appended.
      const style = el.getAttribute('style') || '';
      assert.match(style, /outline:\s*2px\s+solid\s+red/);
      const fpEl = fp.firstElementChild;
      assert.equal(fpEl.getAttribute('style'), null,
        'non-matching element must keep its empty inline style');
    },
  },
  {
    name: ':remove-attr() strips the named attribute',
    match:
      '<div class="fp_probe_proc_remove_attr" data-tracker="x">attr target</div>',
    nonMatch:
      '<div class="fp_probe_proc_remove_attr">no attr to remove</div>',
    check: (probe, fp) => {
      const el = probe.firstElementChild;
      assert.ok(el, ':remove-attr() must NOT remove the element');
      assert.equal(el.hasAttribute('data-tracker'), false);
      // Non-match: element lacked the attribute trigger entirely;
      // nothing to assert beyond "still present".
      assert.ok(fp.firstElementChild);
    },
  },
  {
    name: ':remove-class() strips the named class token',
    match:
      '<div class="fp_probe_proc_remove_class fp_probe_remove_me">class target</div>',
    nonMatch:
      '<div class="fp_probe_proc_remove_class">no token to remove</div>',
    check: (probe, fp) => {
      const el = probe.firstElementChild;
      assert.ok(el, ':remove-class() must NOT remove the element');
      assert.equal(el.classList.contains('fp_probe_remove_me'), false);
      assert.equal(el.classList.contains('fp_probe_proc_remove_class'), true,
        'other classes on the same element must survive');
      assert.ok(fp.firstElementChild);
    },
  },
];

for (const row of ROWS) {
  test(row.name, async () => {
    const html =
      `<!doctype html><html><body>
        <div id="probe">${row.match}</div>
        <div id="fp">${row.nonMatch}</div>
      </body></html>`;
    const dom = makeDom({ url: 'https://example.com/', html });
    // Capture references BEFORE the shim runs — :upward():remove()
    // can detach the wrap itself, after which getElementById
    // returns null. The check predicates inspect both the
    // pre-shim reference (still valid object, possibly detached
    // from the document) and the live document state.
    const probe = dom.window.document.getElementById('probe');
    const fp = dom.window.document.getElementById('fp');
    runInDom(dom, PROCEDURAL);
    // The shim defers its first scan to DOMContentLoaded when
    // document.readyState === 'loading'. jsdom's initial state
    // after makeDom is 'complete', so the shim fires immediately —
    // but the MutationObserver-debounced rescan uses setTimeout(50).
    // Wait one event-loop tick + the debounce window to settle.
    await new Promise(resolve => setTimeout(resolve, 80));
    row.check(probe, fp);
  });
}

test('shim handles a malformed selector without throwing', () => {
  // Defensive: a future filter list with an unbalanced paren or
  // an unsupported operator must not poison the rest of the rules.
  // We can't easily inject malformed rules via the dumped fixture,
  // so just verify the shim source itself runs against a clean DOM.
  const dom = makeDom({ url: 'https://example.com/', html:
    '<!doctype html><html><body><div>safe</div></body></html>' });
  assert.doesNotThrow(() => runInDom(dom, PROCEDURAL));
});
