// Behavioural tests for the blob-url-capture shim
// (lib/services/blob_url_capture.dart).
//
// Goal: lock in the contract that the blob-download IIFE relies on:
//   - URL.createObjectURL keeps returning the original URL string.
//   - The Blob is queryable via window.__webspaceBlobs.get(url).
//   - URL.revokeObjectURL drops the entry.
//   - Re-running the shim is a no-op (idempotent on hydrated SPAs).
//   - The map is bounded so a page that never revokes can't grow it
//     without limit.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim } = require('./helpers/load_shim');

test('createObjectURL returns the original URL string', () => {
  const dom = loadShim('blob_url_capture/shim.js');
  const blob = new dom.window.Blob(['hello'], { type: 'text/plain' });
  const url = dom.window.URL.createObjectURL(blob);
  assert.match(url, /^blob:/, 'url should be a blob: URL');
});

test('window.__webspaceBlobs.get returns the captured Blob', () => {
  const dom = loadShim('blob_url_capture/shim.js');
  const blob = new dom.window.Blob(['hello'], { type: 'text/plain' });
  const url = dom.window.URL.createObjectURL(blob);
  const captured = dom.window.__webspaceBlobs.get(url);
  assert.equal(captured, blob, 'should hand back the exact Blob instance');
  assert.equal(captured.type, 'text/plain');
});

test('revokeObjectURL drops the map entry', () => {
  const dom = loadShim('blob_url_capture/shim.js');
  const blob = new dom.window.Blob(['hello']);
  const url = dom.window.URL.createObjectURL(blob);
  assert.ok(dom.window.__webspaceBlobs.get(url), 'preconditioned: blob in map');
  dom.window.URL.revokeObjectURL(url);
  assert.equal(dom.window.__webspaceBlobs.get(url), undefined);
});

test('createObjectURL with a non-Blob (e.g. MediaSource) is not tracked', () => {
  const dom = loadShim('blob_url_capture/shim.js');
  const fake = { not: 'a blob' };
  const url = dom.window.URL.createObjectURL(fake);
  // Original behaviour: still returns a URL string. Map: not tracked.
  assert.match(url, /^blob:/);
  assert.equal(dom.window.__webspaceBlobs.get(url), undefined);
});

test('shim is idempotent — second run does not re-wrap or reset state', () => {
  const dom = loadShim('blob_url_capture/shim.js');
  const blob = new dom.window.Blob(['hello']);
  const url = dom.window.URL.createObjectURL(blob);
  // Re-eval the same shim. The early `if (window.__webspaceBlobs) return`
  // guard must keep the existing map intact.
  const fs = require('node:fs');
  const path = require('node:path');
  const src = fs.readFileSync(
    path.join(__dirname, '..', 'js_fixtures', 'blob_url_capture', 'shim.js'),
    'utf8',
  );
  dom.window.eval(src);
  assert.equal(dom.window.__webspaceBlobs.get(url), blob,
    'previously-captured blob still resolvable after re-eval');
});

test('map is bounded — oldest entries evicted past MAX (64)', () => {
  const dom = loadShim('blob_url_capture/shim.js');
  // Register 65 blobs. The first one should have been evicted by the time
  // the 65th is registered.
  const urls = [];
  for (let i = 0; i < 65; i++) {
    const blob = new dom.window.Blob([String(i)]);
    urls.push(dom.window.URL.createObjectURL(blob));
  }
  assert.equal(dom.window.__webspaceBlobs.get(urls[0]), undefined,
    'oldest blob should have been evicted');
  assert.ok(dom.window.__webspaceBlobs.get(urls[1]),
    'second-oldest blob should still be retained');
  assert.ok(dom.window.__webspaceBlobs.get(urls[64]),
    'newest blob should be retained');
});

test('window.__webspaceBlobs is non-enumerable', () => {
  // Page scripts iterating window keys (e.g. for fingerprinting) should
  // not stumble over our shim.
  const dom = loadShim('blob_url_capture/shim.js');
  const desc = Object.getOwnPropertyDescriptor(
    dom.window, '__webspaceBlobs');
  assert.ok(desc, 'descriptor should exist');
  assert.equal(desc.enumerable, false);
});
