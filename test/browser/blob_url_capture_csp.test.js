// Real-browser tests proving the blob_url_capture fix actually bypasses
// CSP `connect-src` enforcement.
//
// jsdom does not enforce CSP at all, so the lower-tier
// test/js/blob_*.test.js files can only verify shim mechanics
// (URL.createObjectURL is wrapped, the IIFE selects the right branch,
// handler call shapes are correct). They cannot prove the *premise* of
// the fix: that under a CSP-strict origin, fetch(blob:) actually fails.
//
// This file boots a real Chromium via Puppeteer, serves a page with
// `Content-Security-Policy: connect-src 'none'`, and asserts:
//   1. WITHOUT the shim, fetch(blob:URL) is blocked by the browser's
//      CSP enforcer — the IIFE falls back to fetch and reports an
//      error. This is the bug we fixed.
//   2. WITH the shim, the IIFE uses the captured-Blob fast path and
//      reads the bytes via FileReader without ever invoking fetch —
//      the download succeeds.
//
// Tests are skipped if Puppeteer cannot launch (e.g. on a sandbox
// without a usable Chromium sandbox); CI is responsible for providing
// a working environment via `npx puppeteer browsers install`.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

let puppeteer;
try {
  puppeteer = require('puppeteer');
} catch (_) {
  // Puppeteer not installed; whole file is skipped.
}

const { start } = require('./helpers/csp_server');

const FIXTURES_ROOT = path.resolve(__dirname, '..', 'js_fixtures');
const SHIM = fs.readFileSync(
  path.join(FIXTURES_ROOT, 'blob_url_capture', 'shim.js'), 'utf8');
const IIFE_TEMPLATE = fs.readFileSync(
  path.join(FIXTURES_ROOT, 'blob_url_capture', 'download_iife.js'), 'utf8');
// The fixture bakes in this URL; we replace it with the live URL the
// browser mints so the IIFE's blobUrl matches what __webspaceBlobs has.
const FIXTURE_URL_LITERAL = '"blob:https://example.test/test-blob-1"';

function buildIife(blobUrl) {
  return IIFE_TEMPLATE.replace(FIXTURE_URL_LITERAL, JSON.stringify(blobUrl));
}

// Common page setup: install a recording stub for
// flutter_inappwebview.callHandler so the test can read every handler
// invocation back as plain data.
const BRIDGE_STUB = `
window.__calls = [];
window.flutter_inappwebview = {
  callHandler(name) {
    var args = Array.prototype.slice.call(arguments, 1);
    window.__calls.push({ name: name, args: args });
    return Promise.resolve();
  },
};`;

let browser;
let server;
let launchError;

test.before(async () => {
  if (!puppeteer) {
    launchError = new Error('puppeteer not installed');
    return;
  }
  try {
    browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
    });
    server = await start();
  } catch (e) {
    launchError = e;
  }
});

test.after(async () => {
  if (browser) await browser.close();
  if (server) await server.close();
});

// node:test evaluates the `skip` option at test-registration time, which
// is before `test.before` runs. Defer the check to the test body so the
// browser/server state from `before` is observable.
//
// In CI (process.env.CI === 'true'), missing Chromium is a hard failure
// — the whole point of running these tests in CI is to PROVE the fix
// works on a real browser, so silently skipping defeats the purpose.
// Locally the same condition skips gracefully so a dev without Chromium
// installed isn't blocked.
function requireBrowser(t) {
  if (browser && server) return true;
  const msg = `Puppeteer/Chromium not available: ${launchError ? launchError.message : 'unknown'}`;
  if (process.env.CI === 'true') {
    throw new Error(msg + ' (CI=true → hard fail; install via `npx puppeteer browsers install chromium`)');
  }
  t.skip(msg);
  return false;
}

test('PREMISE: without the shim, fetch(blob:) is blocked by CSP connect-src',
  async (t) => {
    if (!requireBrowser(t)) return;
    // No init script — page loads with the original URL.createObjectURL.
    // The IIFE will miss the captured-blob lookup and fall through to
    // fetch, which the browser must reject under
    // `connect-src 'none'`.
    const page = await browser.newPage();
    try {
      await page.goto(server.url, { waitUntil: 'load' });

      const blobUrl = await page.evaluate(() => window.__pageBlobUrl);
      assert.ok(blobUrl.startsWith('blob:'),
        'page must have minted a real blob URL');

      await page.evaluate(BRIDGE_STUB);
      await page.evaluate(buildIife(blobUrl));

      // FileReader / fetch are async; wait for either handler.
      await page.waitForFunction(
        () => window.__calls.some((c) =>
          c.name === '_webspaceBlobDownload' ||
          c.name === '_webspaceBlobDownloadError'),
        { timeout: 3000 });

      const calls = await page.evaluate(() => window.__calls);
      const ok = calls.find((c) => c.name === '_webspaceBlobDownload');
      const err = calls.find((c) => c.name === '_webspaceBlobDownloadError');
      assert.equal(ok, undefined,
        'without the shim the fetch path runs and CSP must block it');
      assert.ok(err, 'expected _webspaceBlobDownloadError under CSP');

      // The browser fires a `securitypolicyviolation` event for the
      // blocked fetch. If this assertion ever stops holding, either
      // Chromium changed its CSP semantics or our test page is wrong —
      // the whole premise of the fix needs re-checking.
      const violations = await page.evaluate(() => window.__cspViolations);
      const connectViolation = violations.find(
        (v) => v.directive && v.directive.startsWith('connect-src'));
      assert.ok(connectViolation,
        'expected a connect-src CSP violation event for fetch(blob:)');
    } finally {
      await page.close();
    }
  });

test('PREMISE: without the shim, page-driven fetch(blob:) is blocked by CSP',
  async (t) => {
    if (!requireBrowser(t)) return;
    // Mirrors the github.com failure: page JS itself (e.g.
    // fetch-utilities-*.js) calls fetch(blobUrl) — no IIFE involved.
    // The browser must reject under `connect-src 'none'`.
    const page = await browser.newPage();
    try {
      await page.goto(server.url, { waitUntil: 'load' });
      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        try {
          const res = await fetch(url);
          const text = await res.text();
          return { ok: true, text };
        } catch (e) {
          return { ok: false, error: String(e) };
        }
      });
      assert.equal(result.ok, false,
        'expected fetch(blob:) to fail under connect-src none');

      const violations = await page.evaluate(() => window.__cspViolations);
      const connectViolation = violations.find(
        (v) => v.directive && v.directive.startsWith('connect-src'));
      assert.ok(connectViolation,
        'expected a connect-src CSP violation event for page-driven fetch(blob:)');
    } finally {
      await page.close();
    }
  });

test('FIX: with the shim installed, page-driven fetch(blob:) is serviced locally',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      // Page JS calls fetch(blobUrl) the same way github.githubassets.com
      // 's fetch-utilities-*.js does. The wrapped fetch must recognise
      // the blob: URL, resolve from the captured Blob, and never dispatch
      // a real request — so CSP connect-src never fires.
      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        try {
          const res = await fetch(url);
          const text = await res.text();
          return { ok: true, text, type: res.headers.get('content-type') };
        } catch (e) {
          return { ok: false, error: String(e) };
        }
      });
      assert.equal(result.ok, true,
        'page-driven fetch(blob:) must succeed when shim is installed');
      assert.equal(result.text, 'hello world');
      assert.equal(result.type, 'text/plain');

      const violations = await page.evaluate(() => window.__cspViolations);
      const connectViolation = violations.find(
        (v) => v.directive && v.directive.startsWith('connect-src'));
      assert.equal(connectViolation, undefined,
        'wrapped fetch must not produce a CSP connect-src violation');

      // Function.prototype.toString must hide the wrapper so the page
      // can't fingerprint our patch.
      const stringified = await page.evaluate(
        () => Function.prototype.toString.call(window.fetch));
      assert.match(stringified, /\[native code\]/,
        'wrapped fetch should toString as native code');
    } finally {
      await page.close();
    }
  });

test('FIX: aborted signal rejects with AbortError instead of resolving',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        const ac = new AbortController();
        ac.abort();
        try {
          await fetch(url, { signal: ac.signal });
          return { rejected: false };
        } catch (e) {
          return {
            rejected: true,
            name: e && e.name,
            isDomException: e instanceof DOMException,
          };
        }
      });
      assert.equal(result.rejected, true,
        'pre-aborted signal must reject — not resolve with the captured Blob');
      assert.equal(result.name, 'AbortError');
    } finally {
      await page.close();
    }
  });

test('FIX: non-GET methods fall through to native fetch (which CSP-blocks)',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      // POST on a blob: URL is meaningless. We must NOT silently return
      // the captured Blob — the page should see the same TypeError /
      // CSP rejection it would get without the shim.
      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        try {
          await fetch(url, { method: 'POST', body: 'x' });
          return { ok: true };
        } catch (e) {
          return { ok: false, error: String(e) };
        }
      });
      assert.equal(result.ok, false,
        'POST(blob:) must not be serviced by the wrapper');
    } finally {
      await page.close();
    }
  });

test('FIX: HEAD returns headers without a body',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        const res = await fetch(url, { method: 'HEAD' });
        return {
          status: res.status,
          contentType: res.headers.get('content-type'),
          contentLength: res.headers.get('content-length'),
          bodyLen: (await res.text()).length,
        };
      });
      assert.equal(result.status, 200);
      assert.equal(result.contentType, 'text/plain');
      assert.equal(result.contentLength, '11');
      assert.equal(result.bodyLen, 0,
        'HEAD response must have empty body');
    } finally {
      await page.close();
    }
  });

test('FIX: fetch(new Request(blobUrl)) is intercepted',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        const req = new Request(url);
        const res = await fetch(req);
        return { text: await res.text() };
      });
      assert.equal(result.text, 'hello world');
    } finally {
      await page.close();
    }
  });

test('FIX: Request method=POST is honored over default GET',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      const result = await page.evaluate(async () => {
        const url = window.__pageBlobUrl;
        // Request with POST + blob URL is itself an error in the browser
        // (constructor rejects), so wrap.
        try {
          const req = new Request(url, { method: 'POST', body: 'x' });
          await fetch(req);
          return { ok: true };
        } catch (e) {
          return { ok: false, error: String(e) };
        }
      });
      // Either Request constructor or fetch rejects; the wrapper must
      // not silently service it as GET.
      assert.equal(result.ok, false,
        'POST Request must not get serviced as GET');
    } finally {
      await page.close();
    }
  });

test('FIX: with the shim installed, the captured-blob path bypasses CSP',
  async (t) => {
    if (!requireBrowser(t)) return;
    const page = await browser.newPage();
    try {
      // evaluateOnNewDocument runs at DOCUMENT_START, beating the
      // page's inline blob-mint script by exactly the same amount our
      // production user-script registration does.
      await page.evaluateOnNewDocument(SHIM);
      await page.goto(server.url, { waitUntil: 'load' });

      const blobUrl = await page.evaluate(() => window.__pageBlobUrl);
      assert.ok(blobUrl.startsWith('blob:'));

      // Sanity: the shim's map should contain the page's blob.
      const captured = await page.evaluate((url) =>
        !!(window.__webspaceBlobs && window.__webspaceBlobs.get(url)), blobUrl);
      assert.ok(captured, 'shim must have captured the page-minted Blob');

      await page.evaluate(BRIDGE_STUB);
      // Sentinel: assert fetch is never called when the shim is active.
      // We replace fetch with a flag-setter; if the IIFE wrongly took
      // the fallback branch the assertion below would catch it.
      await page.evaluate(() => {
        window.__fetchInvocations = 0;
        const origFetch = window.fetch;
        window.fetch = function (...args) {
          window.__fetchInvocations += 1;
          return origFetch.apply(window, args);
        };
      });

      await page.evaluate(buildIife(blobUrl));
      await page.waitForFunction(
        () => window.__calls.some((c) => c.name === '_webspaceBlobDownload'),
        { timeout: 3000 });

      const result = await page.evaluate(() => ({
        calls: window.__calls,
        fetchInvocations: window.__fetchInvocations,
        violations: window.__cspViolations,
      }));

      const ok = result.calls.find((c) => c.name === '_webspaceBlobDownload');
      assert.ok(ok, 'expected success handler to fire');
      const [filename, base64, mimeType, taskId] = ok.args;
      assert.equal(filename, 'hello.txt');
      assert.equal(taskId, 'task-fixture');
      assert.equal(mimeType, 'text/plain');
      assert.equal(Buffer.from(base64, 'base64').toString('utf8'),
        'hello world');

      assert.equal(result.fetchInvocations, 0,
        'fast path must not invoke fetch — that would trip CSP');

      const connectViolation = result.violations.find(
        (v) => v.directive && v.directive.startsWith('connect-src'));
      assert.equal(connectViolation, undefined,
        'fast path must not produce a CSP connect-src violation');

      const err = result.calls.find(
        (c) => c.name === '_webspaceBlobDownloadError');
      assert.equal(err, undefined, 'success path must not also report error');
    } finally {
      await page.close();
    }
  });
