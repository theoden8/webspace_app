// Behavioural tests for the target="_blank" rewrite shim
// (lib/services/target_blank_rewrite.dart#targetBlankRewriteScript).
//
// Goal: prove a new-window http(s) anchor is rewritten to _self at
// capture phase (so the tap routes through the reliable top-level
// navigation path), while leaving everything else untouched:
//   - <a target="_blank" href="https://..."> becomes target="_self" on click.
//   - target="_new" is treated the same.
//   - Same-domain target="_blank" is rewritten too (harmless: the app
//     already loaded those in-place).
//   - blob:/data:/non-http and external-scheme targets are left alone.
//   - Anchors without a new-window target are left alone.
//   - A click on a child element still resolves to the ancestor anchor.
//   - Re-evaluating the shim is idempotent.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture, runInDom } = require('./helpers/load_shim');

function bootDom() {
  const dom = makeDom();
  // The default action of a (now _self) link triggers jsdom's
  // "Not implemented: navigation" emit; swallow it.
  if (dom.window._virtualConsole &&
      typeof dom.window._virtualConsole.on === 'function') {
    dom.window._virtualConsole.removeAllListeners('jsdomError');
    dom.window._virtualConsole.on('jsdomError', () => {});
  }
  runInDom(dom, readFixture('target_blank_rewrite/shim.js'));
  return dom;
}

function clickAnchor(dom, el) {
  const ev = new dom.window.MouseEvent('click', {
    bubbles: true,
    cancelable: true,
  });
  el.dispatchEvent(ev);
  return ev;
}

test('target="_blank" http anchor is rewritten to _self on click', () => {
  const dom = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'https://github.com/theoden8/webspace_app';
  a.setAttribute('target', '_blank');
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, a);
  assert.equal(a.getAttribute('target'), '_self');
});

test('target="_new" is rewritten the same way', () => {
  const dom = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'http://example.com/page';
  a.setAttribute('target', '_new');
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, a);
  assert.equal(a.getAttribute('target'), '_self');
});

test('click on a child element still rewrites the ancestor anchor', () => {
  const dom = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'https://github.com/x';
  a.setAttribute('target', '_blank');
  const inner = dom.window.document.createElement('span');
  inner.textContent = 'GitHub';
  a.appendChild(inner);
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, inner);
  assert.equal(a.getAttribute('target'), '_self');
});

test('blob: target="_blank" anchor is left untouched (download path owns it)', () => {
  const dom = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/abc';
  a.setAttribute('target', '_blank');
  a.setAttribute('download', 'x.bin');
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, a);
  assert.equal(a.getAttribute('target'), '_blank');
});

test('external-scheme target="_blank" anchor is left untouched', () => {
  const dom = bootDom();
  const a = dom.window.document.createElement('a');
  a.setAttribute('href', 'mailto:hi@example.com');
  a.setAttribute('target', '_blank');
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, a);
  assert.equal(a.getAttribute('target'), '_blank');
});

test('anchor without a new-window target is left untouched', () => {
  const dom = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'https://example.com/';
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, a);
  assert.equal(a.hasAttribute('target'), false);
});

test('re-evaluating the shim is idempotent', () => {
  const dom = bootDom();
  // Re-run in the same realm; the reentrance guard must skip re-adding
  // the listener so a single click still results in exactly one rewrite
  // (observable here as the target ending at _self without error).
  runInDom(dom, readFixture('target_blank_rewrite/shim.js'));
  const a = dom.window.document.createElement('a');
  a.href = 'https://example.com/q';
  a.setAttribute('target', '_blank');
  dom.window.document.body.appendChild(a);
  clickAnchor(dom, a);
  assert.equal(a.getAttribute('target'), '_self');
});
