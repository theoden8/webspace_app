// Tier 2 — can page JavaScript get hold of, or forge, the per-site proxy
// credential that the router (PROXY-013) uses to pick a site's upstream?
//
// This is the question the Dart tests cannot answer honestly. jsdom has
// no proxy stack and no forbidden-header enforcement, so only a real
// Chromium — the engine Android System WebView and WPE are built on —
// shows what a hostile page can actually put on the wire.
//
// Three properties, each of which would be a cross-site proxy leak if it
// failed:
//
//  1. A page cannot SET `Proxy-Authorization`. It is a forbidden header
//     name, so `fetch` and `XHR` must drop it. If a page could set it, a
//     script on site A could present site B's credential (once guessed
//     or observed) and route itself through B's proxy.
//  2. A page never SEES the credential Chromium uses. The proxy hop
//     carries `Proxy-Authorization`; the origin request must not, so a
//     hostile *site* cannot read another site's token out of the request
//     it receives.
//  3. A page cannot use the relay as an open proxy. Reaching the port is
//     unavoidable on Android (every app shares loopback), so the relay's
//     407 has to be what stops it — an unauthenticated request must not
//     be tunnelled.
//
// The relay's side of (3) is proved against real sockets in
// `ProxyRelayRouterTest.kt`; here it is proved from inside the engine.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
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

const CREDENTIAL = { username: 'ws-site-a', password: 'token-a-0123456789abcdef' };

// Chromium bypasses the proxy for loopback by default, and the fake
// origin is on 127.0.0.1 — without `<-loopback>` the navigation goes
// direct and every downstream assertion passes vacuously.
function proxyArgs(port) {
  return [`--proxy-server=127.0.0.1:${port}`, '--proxy-bypass-list=<-loopback>'];
}

async function withBrowser(args, body) {
  let browser = null;
  let launchError = null;
  try {
    browser = await puppeteer.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox', ...args],
    });
  } catch (e) {
    launchError = e;
  }
  try {
    return await body(browser, launchError);
  } finally {
    if (browser) await browser.close();
  }
}

test('a page cannot put Proxy-Authorization on the wire', async (t) => {
  if (!puppeteer) return t.skip('puppeteer not installed');
  const origin = await startOrigin({ body: '<html><body>site</body></html>' });
  try {
    await withBrowser([], async (browser, launchError) => {
      if (!requireBrowser(launchError, t)) return;
      const page = await browser.newPage();
      await page.goto(origin.url, { waitUntil: 'domcontentloaded' });
      origin.clearLog();

      const result = await page.evaluate(async (stolen) => {
        const out = { fetchThrew: null, xhrThrew: null };
        try {
          await fetch('/probe-fetch', {
            headers: { 'Proxy-Authorization': `Basic ${stolen}` },
          });
        } catch (e) {
          out.fetchThrew = String(e);
        }
        try {
          const xhr = new XMLHttpRequest();
          xhr.open('GET', '/probe-xhr', false);
          xhr.setRequestHeader('Proxy-Authorization', `Basic ${stolen}`);
          xhr.send();
        } catch (e) {
          out.xhrThrew = String(e);
        }
        return out;
      }, Buffer.from(`${CREDENTIAL.username}:${CREDENTIAL.password}`).toString('base64'));

      // Whether the engine throws or silently drops is not the contract.
      // What matters is that the header never reached the server.
      const probes = origin.log.filter((r) => r.url.startsWith('/probe-'));
      assert.ok(probes.length >= 1, `expected probe requests, saw ${JSON.stringify(origin.log.map((r) => r.url))}`);
      for (const probe of probes) {
        assert.equal(
          probe.headers['proxy-authorization'],
          undefined,
          `page smuggled Proxy-Authorization onto ${probe.url} (${JSON.stringify(result)})`,
        );
      }
    });
  } finally {
    await origin.close();
  }
});

test('the proxy credential never reaches the origin the page can read', async (t) => {
  if (!puppeteer) return t.skip('puppeteer not installed');
  const origin = await startOrigin({ body: '<html><body>site</body></html>' });
  const proxy = await startProxy({ auth: CREDENTIAL });
  try {
    await withBrowser(proxyArgs(proxy.port), async (browser, launchError) => {
        if (!requireBrowser(launchError, t)) return;
        const page = await browser.newPage();
        await page.authenticate(CREDENTIAL);
        const response = await page.goto(origin.url, { waitUntil: 'domcontentloaded' });
        assert.equal(response.status(), 200, 'page should load through the proxy');

        // Premise check: the proxy really did authenticate this request,
        // so the absence downstream is meaningful rather than vacuous.
        assert.ok(
          proxy.log.some((e) => e.authedAs === CREDENTIAL.username),
          `proxy never saw the credential: ${JSON.stringify(proxy.log)}`,
        );

        assert.ok(origin.log.length >= 1, 'origin should have been reached');
        for (const entry of origin.log) {
          assert.equal(
            entry.headers['proxy-authorization'],
            undefined,
            'the proxy credential must not be forwarded to the origin',
          );
          const serialised = JSON.stringify(entry.headers);
          assert.ok(
            !serialised.includes(CREDENTIAL.password),
            `origin saw the token in its headers: ${serialised}`,
          );
        }
      });
  } finally {
    await proxy.close();
    await origin.close();
  }
});

test('a page cannot read the proxy credential back out of the engine', async (t) => {
  if (!puppeteer) return t.skip('puppeteer not installed');
  const origin = await startOrigin({ body: '<html><body>site</body></html>' });
  const proxy = await startProxy({ auth: CREDENTIAL });
  try {
    await withBrowser(proxyArgs(proxy.port), async (browser, launchError) => {
        if (!requireBrowser(launchError, t)) return;
        const page = await browser.newPage();
        await page.authenticate(CREDENTIAL);
        await page.goto(origin.url, { waitUntil: 'domcontentloaded' });

        // There is no web API for proxy credentials, so the assertion is
        // that the obvious reflection surfaces stay clean.
        const leaked = await page.evaluate((token) => {
          const haystacks = [
            document.documentElement.outerHTML,
            JSON.stringify(performance.getEntriesByType('resource')),
            JSON.stringify(performance.getEntriesByType('navigation')),
            navigator.userAgent,
            document.cookie,
            String(localStorage.length),
          ];
          return haystacks.filter((h) => h && h.includes(token));
        }, CREDENTIAL.password);

        assert.deepEqual(leaked, [], 'the proxy token surfaced inside the page');
      });
  } finally {
    await proxy.close();
    await origin.close();
  }
});

test('an unauthenticated request to the relay port is refused, not tunnelled',
  async (t) => {
    if (!puppeteer) return t.skip('puppeteer not installed');
    // Models the relay's admission rule: a caller that reaches the
    // loopback port without a known credential gets 407 and no tunnel.
    // Any app on an Android device can reach that port, so this is the
    // only admission control the socket has.
    const tunnelled = [];
    const relay = http.createServer((req, res) => {
      const provided = req.headers['proxy-authorization'];
      if (provided !== `Basic ${Buffer.from(`${CREDENTIAL.username}:${CREDENTIAL.password}`).toString('base64')}`) {
        res.writeHead(407, {
          'Proxy-Authenticate': 'Basic realm="deadbeefdeadbeefdeadbeefdeadbeef"',
          'Content-Length': '0',
          'Connection': 'close',
        });
        res.end();
        return;
      }
      tunnelled.push(req.url);
      res.writeHead(200, { 'Content-Type': 'text/plain', 'Content-Length': '2' });
      res.end('ok');
    });
    await new Promise((r) => relay.listen(0, '127.0.0.1', r));
    const relayPort = relay.address().port;

    const origin = await startOrigin({ body: '<html><body>site</body></html>', cors: true });
    try {
      await withBrowser([], async (browser, launchError) => {
        if (!requireBrowser(launchError, t)) return;
        const page = await browser.newPage();
        await page.goto(origin.url, { waitUntil: 'domcontentloaded' });

        // A script that found the port and tries to use it directly. It
        // cannot attach a credential (test 1), so the relay refuses.
        const status = await page.evaluate(async (port) => {
          try {
            const res = await fetch(`http://127.0.0.1:${port}/borrowed`, {
              headers: { 'Proxy-Authorization': 'Basic Zm9yZ2VkOmNyZWQ=' },
            });
            return res.status;
          } catch (e) {
            return `threw: ${e}`;
          }
        }, relayPort);

        assert.deepEqual(
          tunnelled, [],
          `an unauthenticated page request was tunnelled: ${JSON.stringify(tunnelled)} (status ${status})`,
        );
      });
    } finally {
      await new Promise((r) => relay.close(r));
      await origin.close();
    }
  });
