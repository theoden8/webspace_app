// Behavioural tests for the blob-download IIFE
// (lib/services/blob_url_capture.dart — buildBlobDownloadIife).
//
// Coverage:
//   1. Fast path: when the URL is in window.__webspaceBlobs, the IIFE
//      reads the captured Blob via FileReader and reports base64 +
//      mimeType + taskId via _webspaceBlobDownload — without invoking
//      fetch.
//   2. Fetch fallback: when the URL is NOT in __webspaceBlobs, the
//      IIFE calls fetch(blobUrl). We intercept fetch with a stub that
//      hands back a Blob; the same FileReader path runs and reports
//      success.
//   3. Fetch error: when fetch rejects (the production failure mode on
//      a CSP-strict origin), the IIFE routes the message through
//      _webspaceBlobDownloadError without leaving the task hanging.
//
// jsdom has no CSP enforcement, so this file proves the IIFE's branch
// selection and handler shapes — not that the fix actually bypasses
// CSP. That proof lives in the browser-level (Puppeteer) tier.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim, readFixture, runInDom } = require('./helpers/load_shim');

const IIFE = readFixture('blob_url_capture/download_iife.js');
// The dumped IIFE bakes in this URL — the polyfill in helpers/load_shim.js
// returns it for the first createObjectURL call so the fast-path test
// can mint a real Blob and have the IIFE find it.
const FIXTURE_URL = 'blob:https://example.test/test-blob-1';
const FIXTURE_FILENAME = 'hello.txt';
const FIXTURE_TASK_ID = 'task-fixture';

function installBridge(dom) {
  const calls = [];
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      calls.push({ name, args });
      return Promise.resolve();
    },
  };
  return calls;
}

function findCall(calls, name) {
  return calls.find((c) => c.name === name);
}

function decodeBase64(b64) {
  return Buffer.from(b64, 'base64').toString('utf8');
}

// FileReader resolves on a microtask + timer in jsdom; give it a tick.
function flushAsync() {
  return new Promise((r) => setTimeout(r, 30));
}

test('fast path: reads captured Blob via FileReader, reports base64', async () => {
  const dom = loadShim('blob_url_capture/shim.js');
  const calls = installBridge(dom);
  // Sentinel: assert fetch is NOT called on the fast path.
  let fetchCalls = 0;
  dom.window.fetch = function fetchStub() {
    fetchCalls += 1;
    return Promise.reject(new Error('fetch should not be invoked on fast path'));
  };

  const blob = new dom.window.Blob(['hello world'], { type: 'text/plain' });
  const url = dom.window.URL.createObjectURL(blob);
  assert.equal(url, FIXTURE_URL,
    'polyfill must mint the URL the dumped IIFE references');

  runInDom(dom, IIFE);
  await flushAsync();

  const dl = findCall(calls, '_webspaceBlobDownload');
  assert.ok(dl, 'expected _webspaceBlobDownload to fire');
  const [filename, base64, mimeType, taskId] = dl.args;
  assert.equal(filename, FIXTURE_FILENAME);
  assert.equal(decodeBase64(base64), 'hello world');
  assert.equal(mimeType, 'text/plain');
  assert.equal(taskId, FIXTURE_TASK_ID);
  assert.equal(fetchCalls, 0, 'fast path must not call fetch');

  // Progress should fire at least once (start) and converge to total.
  const progressCalls = calls.filter((c) => c.name === '_webspaceBlobProgress');
  assert.ok(progressCalls.length >= 1, 'expected at least one progress event');
  const last = progressCalls[progressCalls.length - 1];
  // [taskId, done, total]
  assert.equal(last.args[0], FIXTURE_TASK_ID);
  assert.equal(last.args[1], last.args[2],
    'final progress event should have done==total');
});

test('fallback: when URL is not captured, IIFE calls fetch and reads result', async () => {
  // Same dom but DO NOT mint via createObjectURL — leaves __webspaceBlobs
  // empty for the fixture URL, forcing the fallback branch.
  const dom = loadShim('blob_url_capture/shim.js');
  const calls = installBridge(dom);

  const fetched = [];
  dom.window.fetch = function fetchStub(url) {
    fetched.push(url);
    const blob = new dom.window.Blob(['from fetch'], { type: 'application/octet-stream' });
    return Promise.resolve({
      blob() { return Promise.resolve(blob); },
    });
  };

  runInDom(dom, IIFE);
  await flushAsync();

  assert.deepEqual(fetched, [FIXTURE_URL],
    'fallback must call fetch with the original blob URL');

  const dl = findCall(calls, '_webspaceBlobDownload');
  assert.ok(dl, 'expected _webspaceBlobDownload after fetch path');
  const [filename, base64, mimeType, taskId] = dl.args;
  assert.equal(filename, FIXTURE_FILENAME);
  assert.equal(decodeBase64(base64), 'from fetch');
  assert.equal(mimeType, 'application/octet-stream');
  assert.equal(taskId, FIXTURE_TASK_ID);
});

test('fallback: fetch rejection routes through _webspaceBlobDownloadError', async () => {
  // Production failure mode under CSP `connect-src` that blocks blob:.
  // The IIFE must not silently drop the error — Dart needs the rejection
  // to fail the DownloadTask.
  const dom = loadShim('blob_url_capture/shim.js');
  const calls = installBridge(dom);

  dom.window.fetch = function fetchStub() {
    return Promise.reject(new Error(
      "Refused to connect to 'blob:...' because it violates the document's CSP"));
  };

  runInDom(dom, IIFE);
  await flushAsync();

  const dl = findCall(calls, '_webspaceBlobDownload');
  assert.equal(dl, undefined,
    'must not report success when fetch failed');
  const err = findCall(calls, '_webspaceBlobDownloadError');
  assert.ok(err, 'expected _webspaceBlobDownloadError when fetch rejects');
  const [msg, taskId] = err.args;
  assert.match(msg, /violates the document's CSP/);
  assert.equal(taskId, FIXTURE_TASK_ID);
});

test('fast path: synchronous throw routes through _webspaceBlobDownloadError', async () => {
  // If the captured Blob is somehow mutated into something readBlob can't
  // handle, the synchronous catch in the IIFE must fire the error
  // handler — not crash silently.
  const dom = loadShim('blob_url_capture/shim.js');
  const calls = installBridge(dom);

  // Mint the URL so the fast path engages, then break FileReader so
  // readAsDataURL throws synchronously.
  const blob = new dom.window.Blob(['x'], { type: 'text/plain' });
  dom.window.URL.createObjectURL(blob);
  dom.window.FileReader = function FailingFileReader() {
    throw new Error('FileReader unavailable');
  };

  runInDom(dom, IIFE);
  await flushAsync();

  const err = findCall(calls, '_webspaceBlobDownloadError');
  assert.ok(err, 'expected error handler to fire on synchronous throw');
  assert.match(err.args[0], /FileReader unavailable/);
  assert.equal(err.args[1], FIXTURE_TASK_ID);
});
