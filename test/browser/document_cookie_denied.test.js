// What "Access is denied for this document." actually means.
//
// A captcha stall (BUG-013) is reported with this console line:
//
//   Uncaught SecurityError: Failed to read the 'cookie' property from
//   'Document': Access is denied for this document.
//
// It is tempting to read that as "cookies are blocked for this site", and a
// first pass at BUG-013 did exactly that and blamed the third-party-cookie
// setting. Chromium picks the string in `Document::cookie()` only when the
// document's ORIGIN cannot access cookies at all, and it has more specific
// wording for the two cases people usually mean — so the string is a much
// narrower diagnosis than it looks, and the difference decides which code path
// to go and read.
//
// Only a real engine can settle this: jsdom has no cookie policy, no sandbox
// flags and no opaque origins. Each case below pins one branch, so a future
// reader can map a user's console line to a mechanism instead of guessing.
//
// Not covered here, because it needs a device: Android WebView additionally
// denies cookies to a `loadDataWithBaseURL` document, which is how
// `InAppWebViewInitialData(data, baseUrl:)` renders a cached snapshot
// (webview.dart `usesCachedHtml`). That is the app's own way of reaching the
// same branch, and it is the one to check first when a user reports this line.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { setupBrowser, requireBrowser } = require('./helpers/launch');

const DENIED = "Failed to read the 'cookie' property from 'Document': " +
  'Access is denied for this document.';

// `a.test` embeds `b.test` so the frame is genuinely cross-site: a same-origin
// iframe is first-party and no cookie policy touches it. Both names resolve to
// the loopback server, and the proxy is off so they cannot leave the machine.
// Passing `args` replaces the helper's defaults, so the sandbox flags are
// restated here the same way media_session_page.js does.
const CROSS_SITE_ARGS = [
  '--no-sandbox',
  '--disable-setuid-sandbox',
  '--host-resolver-rules=MAP a.test 127.0.0.1, MAP b.test 127.0.0.1',
  '--no-proxy-server',
];

// Default policy, and a second engine with third-party cookies blocked. The
// point of the pair is that the blocked one reads the SAME as the allowed one
// from JS: silence, not an exception.
const browser = setupBrowser({ args: CROSS_SITE_ARGS });
const blocked = setupBrowser({ args: [...CROSS_SITE_ARGS, '--block-third-party-cookies'] });

const PROBE = `(() => {
  try { return JSON.stringify(document.cookie); }
  catch (e) { return 'THREW ' + e.name + ': ' + e.message; }
})()`;

function startServer() {
  let server;
  return new Promise((resolve) => {
    server = http.createServer((req, res) => {
      // Read-only probe. Whether a third-party cookie STICKS depends on
      // SameSite and a secure context; whether reading one THROWS is the
      // question here, and that needs neither.
      if (req.url.startsWith('/frame')) {
        res.writeHead(200, { 'Content-Type': 'text/html' });
        return res.end(`<!doctype html><script>
          var out;
          try { out = JSON.stringify(document.cookie); }
          catch (e) { out = 'THREW ' + e.name + ': ' + e.message; }
          parent.postMessage(out, '*');
        </script>`);
      }
      const sandbox = req.url.includes('sandbox') ? ' sandbox="allow-scripts"' : '';
      const src = req.url.includes('sandbox')
        ? '/frame'
        : `http://b.test:${server.address().port}/frame`;
      res.writeHead(200, { 'Content-Type': 'text/html', 'Set-Cookie': 'sid=abc; Path=/' });
      res.end(`<!doctype html><body><iframe${sandbox} src="${src}"></iframe>
        <script>window.__r = new Promise((r) => addEventListener('message', (e) => r(e.data)));</script>`);
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

async function frameProbe(state, query) {
  const server = await startServer();
  const page = await state.browser.newPage();
  try {
    await page.goto(`http://a.test:${server.address().port}/${query}`,
      { waitUntil: 'networkidle0' });
    return await page.evaluate(() => window.__r);
  } finally {
    await page.close();
    server.close();
  }
}

// The reporter's line, reproduced. A top-level about:blank has an opaque
// origin with no initiator to inherit one from, which is the generic branch:
// not sandboxed, not data:, simply no origin that may hold cookies.
test('a document with no cookie-capable origin gives the reported wording', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  await page.goto('about:blank');
  const result = await page.evaluate(PROBE);
  await page.close();
  assert.match(result, /^THREW SecurityError/);
  assert.ok(result.includes(DENIED), `expected the generic denial, got: ${result}`);
});

// So the wording is NOT a statement about the cookie policy. Both engines
// answer the same way from JS, and neither throws: a blocked cookie is a
// cookie that silently does not stick.
test('blocking third-party cookies does not throw, it returns empty', async (t) => {
  if (!requireBrowser(browser, t) || !requireBrowser(blocked, t)) return;

  const allowedResult = await frameProbe(browser, '');
  const blockedResult = await frameProbe(blocked, '');

  assert.ok(!allowedResult.startsWith('THREW'),
    `cross-site frame threw with cookies allowed: ${allowedResult}`);
  assert.ok(!blockedResult.startsWith('THREW'),
    'blocking third-party cookies must not produce a SecurityError — reading ' +
    `one as evidence of the policy is the BUG-013 misdiagnosis: ${blockedResult}`);
});

// The two cases a reader is most likely to assume, both of which Chromium
// words differently. A console line naming either of these rules out the
// generic branch above, and vice versa.
test('a sandboxed frame is named as such, not denied generically', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const result = await frameProbe(browser, '?sandbox');
  assert.match(result, /^THREW SecurityError/);
  assert.match(result, /lacks the 'allow-same-origin' flag/);
  assert.ok(!result.includes(DENIED));
});

test("a data: document is named as such, not denied generically", async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  await page.goto('data:text/html,<title>d</title>');
  const result = await page.evaluate(PROBE);
  await page.close();
  assert.match(result, /^THREW SecurityError/);
  assert.match(result, /Cookies are disabled inside 'data:' URLs/);
  assert.ok(!result.includes(DENIED));
});

// The captcha popup (CAPTCHA-004/009) is a window.open the page made, so it is
// worth knowing that this shape is fine in a stock engine: the popup inherits
// the opener's origin and reads its cookies. A popup that DOES throw is
// therefore not "about:blank popups can't have cookies" — it is a popup that
// never inherited, which is a fact about how the app built it.
test('a page-opened about:blank popup inherits the opener and keeps cookies', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const server = await startServer();
  const page = await browser.browser.newPage();
  try {
    await page.goto(`http://a.test:${server.address().port}/`);
    assert.equal(await page.evaluate(PROBE), '"sid=abc"');

    const [popup] = await Promise.all([
      new Promise((resolve) => {
        browser.browser.once('targetcreated', async (target) => resolve(await target.page()));
      }),
      page.evaluate(() => window.open('about:blank', '_blank')),
    ]);
    assert.ok(popup, 'no popup page');
    assert.equal(await popup.evaluate(PROBE), '"sid=abc"');
    await popup.close();
  } finally {
    await page.close();
    server.close();
  }
});
