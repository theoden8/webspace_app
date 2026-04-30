// Tier 2 — proxy baseline tests for Chromium routing, the same engine
// the production WebView (Android System WebView, WPE on Linux) is
// built on. The Dart-side tests in test/proxy_*.dart cover the
// app's settings serialisation, secure-storage migration, and the
// resolveEffectiveProxy ladder. This tier closes the loop: when the
// app hands Chromium a `--proxy-server=http://...` config, does
// every byte actually flow through the proxy, including under
// authentication challenges? The recent fix `Fix per-site proxy
// auth wipe + apply global proxy to live webviews` (PR #266) shipped
// because the Dart-side bug silently dropped auth credentials and
// pages started 407-ing — these tests prove the Chromium-side
// routing we depend on after the Dart fix is intact.
//
// Scope:
//   - All HTTP page loads route through the proxy (ip-leakage spec
//     LEAK-001 webview path, validated against real Chromium).
//   - Authenticated proxy: page.authenticate satisfies the 407
//     challenge; the proxy logs see Basic Authorization with the
//     supplied credentials.
//   - Wrong-credentials path: the navigation fails closed (no
//     fall-through to direct origin connection — that would be the
//     leak the Dart-side fix prevents in production).
//   - WITHOUT proxy baseline (premise check): same navigation
//     reaches the origin directly. Catches a "test always passes
//     because the proxy is misconfigured and Chromium silently
//     bypassed it" failure mode.

const test = require('node:test');
const assert = require('node:assert/strict');
const { startProxy, startOrigin } = require('./helpers/proxy_server');

let puppeteer;
try { puppeteer = require('puppeteer'); } catch (_) {}

function requireBrowser(launchError, t) {
  if (!launchError) return true;
  const msg = `Puppeteer/Chromium not available: ${launchError.message}`;
  if (process.env.CI === 'true') {
    throw new Error(msg + ' (CI=true → hard fail)');
  }
  t.skip(msg);
  return false;
}

// Each test file gets its own browser per launch config — proxy
// settings are bound at launch time and Chromium can't change them
// per-page. We launch fresh per-test rather than sharing across the
// file so each test gets its own proxy auth state.
async function launch({ proxyHostPort } = {}) {
  if (!puppeteer) {
    return { error: new Error('puppeteer not installed') };
  }
  const args = ['--no-sandbox', '--disable-setuid-sandbox'];
  if (proxyHostPort) {
    // Chromium's --proxy-server accepts host:port (no scheme, no
    // trailing slash). Passing a full URL with scheme produces
    // ERR_NO_SUPPORTED_PROXIES.
    args.push(`--proxy-server=${proxyHostPort}`);
    // Chromium bypasses proxy for localhost / 127.0.0.1 by default.
    // The test harness binds origin + proxy on 127.0.0.1, so we MUST
    // disable that bypass — otherwise navigation goes direct and the
    // "with proxy" tests would silently false-pass against an empty
    // proxy log.
    args.push('--proxy-bypass-list=<-loopback>');
  }
  try {
    return { browser: await puppeteer.launch({ headless: true, args }) };
  } catch (e) {
    return { error: e };
  }
}

test('PREMISE: without --proxy-server, navigation hits origin directly',
  async (t) => {
    // Without this assertion, "with-proxy" tests below could be
    // false-passing if Chromium silently bypassed a misconfigured
    // proxy — the proxy log would just be empty and the page would
    // load anyway. Asserting the no-proxy direct-hit behaviour first
    // pins the test premise.
    const { browser, error } = await launch();
    if (!requireBrowser(error, t)) return;
    const origin = await startOrigin({ body: '<html>direct</html>' });
    const proxy = await startProxy();
    try {
      const page = await browser.newPage();
      await page.goto(origin.url, { waitUntil: 'load' });
      assert.equal(await page.evaluate(() => document.body.textContent), 'direct');
      assert.equal(proxy.log.length, 0,
        'proxy must see zero requests when not configured');
      assert.ok(origin.log.length >= 1,
        'origin must see the direct request');
    } finally {
      await browser.close();
      await proxy.close();
      await origin.close();
    }
  });

test('PROXY: every HTTP navigation routes through the proxy', async (t) => {
  const proxy = await startProxy();
  const { browser, error } = await launch({ proxyHostPort: `${proxy.host}:${proxy.port}` });
  if (!requireBrowser(error, t)) {
    await proxy.close();
    return;
  }
  const origin = await startOrigin({ body: '<html>proxied</html>' });
  try {
    const page = await browser.newPage();
    await page.goto(origin.url, { waitUntil: 'load' });
    assert.equal(await page.evaluate(() => document.body.textContent), 'proxied');
    // The proxy log is the integrity contract: every navigation
    // and subresource MUST appear here. Empty would mean Chromium
    // silently bypassed the proxy — the LEAK-007 coverage matrix
    // calls that out as the regression we're guarding against.
    // Chromium also fires background calls (clients2.google.com time
    // sync etc) through the proxy on first launch, so the test
    // origin's request may not be the first entry — filter by URL.
    const ourEntries = proxy.log.filter((e) =>
      e.type === 'http' && e.url.startsWith(origin.url));
    assert.ok(ourEntries.length >= 1,
      `proxy must record the origin request, got: ${JSON.stringify(proxy.log.map((e) => e.url))}`);
  } finally {
    await browser.close();
    await proxy.close();
    await origin.close();
  }
});

test('AUTH: page.authenticate satisfies the 407 challenge', async (t) => {
  const auth = { username: 'webspace', password: 'sekret' };
  const proxy = await startProxy({ auth });
  const { browser, error } = await launch({ proxyHostPort: `${proxy.host}:${proxy.port}` });
  if (!requireBrowser(error, t)) {
    await proxy.close();
    return;
  }
  const origin = await startOrigin({ body: '<html>authed</html>' });
  try {
    const page = await browser.newPage();
    // Mirrors the InAppWebView platform call: when the underlying
    // platform sees a 407 it surfaces a credentials prompt; on
    // Android / iOS / WPE we answer it with the stored
    // username/password. Puppeteer's page.authenticate is the
    // analogous pre-registration.
    await page.authenticate(auth);
    await page.goto(origin.url, { waitUntil: 'load' });
    assert.equal(await page.evaluate(() => document.body.textContent), 'authed');
    const httpEntries = proxy.log.filter((e) => e.type === 'http');
    assert.ok(httpEntries.length >= 1, 'proxy must see the request');
    assert.equal(httpEntries[0].authedAs, auth.username,
      'proxy must see the supplied Basic credentials');
  } finally {
    await browser.close();
    await proxy.close();
    await origin.close();
  }
});

test('AUTH: wrong credentials fail closed (no direct fall-through)',
  async (t) => {
    // The bug PR #266 fixed: the Dart layer was wiping passwords
    // on save, leading to perpetual 407s. The behaviour we depend
    // on at the Chromium layer is "stay 407 until correct
    // credentials are supplied; never silently bypass". Verify
    // Chromium does NOT silently retry without auth and reach the
    // origin directly.
    const auth = { username: 'webspace', password: 'right-password' };
    const proxy = await startProxy({ auth });
    const { browser, error } = await launch({ proxyHostPort: `${proxy.host}:${proxy.port}` });
    if (!requireBrowser(error, t)) {
      await proxy.close();
      return;
    }
    const origin = await startOrigin({ body: '<html>direct-leak</html>' });
    try {
      const page = await browser.newPage();
      // Wrong password.
      await page.authenticate({ username: 'webspace', password: 'wrong' });
      let response;
      try {
        response = await page.goto(origin.url, { waitUntil: 'load', timeout: 5000 });
      } catch (_) {
        // Some Chromium versions surface 407 as a navigation error;
        // others render the 407 body as a normal load. Either is
        // acceptable as long as origin is never reached.
      }
      // The integrity contract: origin MUST NOT have seen the
      // request. That's what would be the leak — the Dart-side bug
      // PR #266 fixed could have led to a fall-through if Chromium
      // retried without auth on 407, defeating the whole proxy.
      assert.equal(origin.log.length, 0,
        `origin must not be reached on wrong creds, saw: ${JSON.stringify(origin.log)}`);
      const challenges = proxy.log.filter((e) => e.type === 'auth_challenge');
      assert.ok(challenges.length >= 1,
        'proxy must have rejected at least one auth attempt');
      if (response) {
        assert.equal(response.status(), 407,
          `if navigation completed, status must be 407 not ${response.status()}`);
      }
    } finally {
      await browser.close();
      await proxy.close();
      await origin.close();
    }
  });

test('NO_LEAK: subresources also route through the proxy', async (t) => {
  // A page that loads an <img> from a different origin must route
  // that subresource through the proxy too. Easy to overlook in a
  // proxy implementation that only handles the top-level navigation.
  const proxy = await startProxy();
  const { browser, error } = await launch({ proxyHostPort: `${proxy.host}:${proxy.port}` });
  if (!requireBrowser(error, t)) {
    await proxy.close();
    return;
  }
  const subresource = await startOrigin({
    body: 'PNG-not-really',
    contentType: 'image/png',
  });
  const origin = await startOrigin({
    body: `<html><body><img src="${subresource.url}pixel.png"></body></html>`,
  });
  try {
    const page = await browser.newPage();
    await page.goto(origin.url, { waitUntil: 'networkidle0' });
    const proxyHosts = proxy.log
      .filter((e) => e.type === 'http')
      .map((e) => e.host);
    assert.ok(proxyHosts.some((h) => h.includes(`:${origin.port}`)),
      `proxy must see top-level navigation: ${JSON.stringify(proxyHosts)}`);
    assert.ok(proxyHosts.some((h) => h.includes(`:${subresource.port}`)),
      `proxy must see subresource fetch: ${JSON.stringify(proxyHosts)}`);
  } finally {
    await browser.close();
    await proxy.close();
    await subresource.close();
    await origin.close();
  }
});
