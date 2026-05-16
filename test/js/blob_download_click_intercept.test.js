// Behavioural tests for the blob-download click-intercept shim
// (lib/services/blob_url_capture.dart#blobDownloadClickInterceptScript).
//
// Goal: prove the two activation paths bridge to Dart correctly without
// breaking anything that should fall through:
//   - In-DOM click on <a download href="blob:"> preventDefaults and
//     fires _webspaceBlobDownloadStart with (href, filename).
//   - Detached link.click() (the SaveAs idiom that never appends to the
//     DOM) does the same via HTMLAnchorElement.prototype.click.
//   - Non-blob hrefs and blob hrefs without `download` fall through to
//     the original click semantics (no bridge, no preventDefault).
//   - Re-evaluating the shim is idempotent — no double-bridge.
//   - Click on a child of the anchor still resolves to the anchor.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture, runInDom } = require('./helpers/load_shim');

function bootDom() {
  const dom = makeDom();
  // Fallthrough cases let the browser run the link's default action,
  // which makes jsdom emit "Not implemented: navigation". Swallow the
  // emit so a passing test isn't polluted with stderr-shaped noise.
  if (dom.window._virtualConsole &&
      typeof dom.window._virtualConsole.on === 'function') {
    dom.window._virtualConsole.removeAllListeners('jsdomError');
    dom.window._virtualConsole.on('jsdomError', () => {});
  }
  // Record handler invocations so each test can assert what (if anything)
  // bridged through.
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push({ name, args });
    },
  };
  runInDom(dom, readFixture('blob_url_capture/click_intercept.js'));
  return { dom, calls };
}

test('in-DOM <a download href="blob:"> click bridges to Dart', () => {
  const { dom, calls } = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/abc';
  a.download = 'report.pdf';
  dom.window.document.body.appendChild(a);
  // Use a cancellable click event so preventDefault() is observable.
  const ev = new dom.window.MouseEvent('click', {
    bubbles: true,
    cancelable: true,
  });
  a.dispatchEvent(ev);
  assert.equal(ev.defaultPrevented, true,
    'shim must preventDefault so the browser does not navigate to blob:');
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0], {
    name: '_webspaceBlobDownloadStart',
    args: ['blob:https://example.com/abc', 'report.pdf'],
  });
});

test('click on a child of <a download> still bridges via parentNode walk', () => {
  const { dom, calls } = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/xyz';
  a.download = 'icon.svg';
  const inner = dom.window.document.createElement('span');
  inner.textContent = 'click me';
  a.appendChild(inner);
  dom.window.document.body.appendChild(a);
  const ev = new dom.window.MouseEvent('click', {
    bubbles: true,
    cancelable: true,
  });
  inner.dispatchEvent(ev);
  assert.equal(calls.length, 1, 'inner-element click must resolve to anchor');
  assert.deepEqual(calls[0].args, [
    'blob:https://example.com/xyz',
    'icon.svg',
  ]);
});

test('detached link.click() bridges via prototype patch', () => {
  // The SaveAs idiom: build an anchor, set href + download, call click(),
  // throw it away. The event never bubbles to document so the capturing
  // listener cannot fire — only the prototype patch saves us.
  const { dom, calls } = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/q';
  a.download = 'save.bin';
  a.click();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args,
    ['blob:https://example.com/q', 'save.bin']);
});

test('empty `download` attribute still bridges (filename = "")', () => {
  // The Dart handler treats empty string as "no suggested filename"
  // and falls back to a mime-based default. The shim must still
  // intercept rather than treating the missing value as no-download.
  const { dom, calls } = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/v';
  a.setAttribute('download', '');
  dom.window.document.body.appendChild(a);
  a.click();
  assert.equal(calls.length, 1);
  assert.deepEqual(calls[0].args,
    ['blob:https://example.com/v', '']);
});

test('blob href WITHOUT `download` attribute falls through (navigation intent)', () => {
  // A bare <a href="blob:"> is a navigation request, not a download.
  // The page wants the blob displayed inline; intercepting would
  // break image viewers, PDF previewers, etc.
  const { dom, calls } = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/inline';
  dom.window.document.body.appendChild(a);
  const ev = new dom.window.MouseEvent('click', {
    bubbles: true,
    cancelable: true,
  });
  a.dispatchEvent(ev);
  assert.equal(calls.length, 0);
  assert.equal(ev.defaultPrevented, false);
});

test('non-blob href with `download` attribute falls through', () => {
  // HTTP downloads go through onDownloadStartRequest, not this shim.
  // If we hijacked them too we would race against the native path.
  const { dom, calls } = bootDom();
  const a = dom.window.document.createElement('a');
  a.href = 'https://example.com/file.zip';
  a.download = 'file.zip';
  dom.window.document.body.appendChild(a);
  const ev = new dom.window.MouseEvent('click', {
    bubbles: true,
    cancelable: true,
  });
  a.dispatchEvent(ev);
  assert.equal(calls.length, 0);
  assert.equal(ev.defaultPrevented, false);
});

test('re-evaluating the shim is idempotent (no double bridge)', () => {
  const { dom, calls } = bootDom();
  // Re-run the fixture in the same realm. The reentrance guard must
  // skip re-installing both the document listener and the prototype
  // patch — otherwise a single click fires the handler twice and
  // DownloadsService starts two tasks for one click.
  runInDom(dom, readFixture('blob_url_capture/click_intercept.js'));
  const a = dom.window.document.createElement('a');
  a.href = 'blob:https://example.com/dupe';
  a.download = 'dupe.bin';
  dom.window.document.body.appendChild(a);
  a.click();
  assert.equal(calls.length, 1, 'must bridge exactly once after re-eval');
});

test('toString stub is registered with __wsFnStubs when available', () => {
  // Anti-fingerprinting hardening: page scripts calling
  // HTMLAnchorElement.prototype.click.toString() should still see
  // "[native code]" so the patch is invisible. The capture shim sets
  // up window.__wsFnStubs (a WeakMap); when present, the click
  // intercept shim populates an entry for its replacement.
  const dom = makeDom();
  dom.window.flutter_inappwebview = { callHandler() {} };
  // Pre-install the capture shim so the WeakMap exists.
  runInDom(dom, readFixture('blob_url_capture/shim.js'));
  runInDom(dom, readFixture('blob_url_capture/click_intercept.js'));
  const stub = dom.window.__wsFnStubs.get(
    dom.window.HTMLAnchorElement.prototype.click);
  assert.equal(stub, 'function click() { [native code] }');
});
