// Attacker-page tier: what can ordinary page script do with the JS
// bridge that the user-script shim installs?
//
// The rest of test/browser/ asks whether our shims behave correctly.
// This file assumes an adversary is already running script in the page
// — a third-party tag, a compromised dependency, an XSS payload — and
// asks what the shim hands them that the browser would otherwise deny.
//
// Two capabilities come out of it, both by design for user scripts and
// both reachable by anyone else in the same document:
//
//   1. Inline <script> elements are routed to a privileged Dart handler
//      that evaluates them outside the page's CSP. An injection the
//      browser refuses to run becomes an injection that runs.
//   2. window.fetch is patched to retry cross-origin failures through
//      the same bridge, which answers with the response body. Reads the
//      same-origin policy and connect-src refuse become readable.
//
// Neither is a claim that the shim is wrong — the CORS and CSP bypasses
// are the feature. The tests pin the blast radius so that a change in
// who can reach the bridge (a wider injection scope, a new caller) has
// to break a test first. The Dart half of the contract, including the
// absent confirmation prompt on the fetch path, lives in
// test/user_script_bridge_authz_test.dart.

const test = require('node:test');
const assert = require('node:assert/strict');

const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');
const { startVictim, startThirdParty } = require('./helpers/attacker_server');

// Handler names are baked into the dumped fixture.
const SHIM = readFixture('user_script/shim.js');
const INLINE_HANDLER = '__ws_i_test';
const FETCH_HANDLER = '__ws_f_test';

const EXFIL = 'window.__pwned = true;';

// Stands in for the native bridge. Records every call so a test can see
// what crossed into Dart, and answers the fetch handler with the shape
// the real handler returns.
const BRIDGE_STUB = `
window.__calls = [];
window.flutter_inappwebview = {
  callHandler: function (name) {
    var args = Array.prototype.slice.call(arguments, 1);
    window.__calls.push({ name: name, args: args });
    if (name === ${JSON.stringify(FETCH_HANDLER)}) {
      return Promise.resolve({
        status: 200,
        body: window.__bridgeBody,
        contentType: 'application/json',
      });
    }
    return Promise.resolve(true);
  },
};`;

const browser = setupBrowser();

// Page script that mimics an injection sink: build an inline <script>
// and put it in the document. Under `script-src 'self'` the browser
// must refuse to run it.
const ATTACK_INLINE = `
window.__attack = (function () {
  var s = document.createElement('script');
  s.textContent = ${JSON.stringify(EXFIL)};
  document.head.appendChild(s);
  return { inDom: document.documentElement.outerHTML.indexOf('__pwned') !== -1 };
})();`;

function typedAttack(type) {
  return `
window.__attack = (function () {
  var s = document.createElement('script');
  s.type = ${JSON.stringify(type)};
  s.textContent = ${JSON.stringify(EXFIL)};
  document.head.appendChild(s);
  return {};
})();`;
}

async function withVictim(t, { csp, scripts, shim = true, body }, fn) {
  if (!requireBrowser(browser, t)) return;
  const victim = await startVictim({ csp, scripts });
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(
      `${BRIDGE_STUB}\nwindow.__bridgeBody = ${JSON.stringify(body || '')};`);
    if (shim) await page.evaluateOnNewDocument(SHIM);
    await page.goto(victim.url, { waitUntil: 'load' });
    await fn(page, victim);
  } finally {
    await page.close();
    await victim.close();
  }
}

// ---------- CSP: inline <script> injection ----------

test('PREMISE: without the shim, CSP refuses a page-injected inline script',
  async (t) => {
    await withVictim(t, { shim: false, scripts: { 'attack.js': ATTACK_INLINE } },
      async (page) => {
        const r = await page.evaluate(() => ({
          pwned: window.__pwned,
          violations: window.__cspViolations.map((v) => v.directive),
          calls: window.__calls.length,
        }));
        assert.equal(r.pwned, undefined,
          'inline script must not run under script-src self');
        // Chromium reports the narrower script-src-elem for element
        // insertion; older engines report script-src.
        assert.ok(r.violations.some((d) => d.startsWith('script-src')),
          `expected a script-src violation, got ${JSON.stringify(r.violations)}`);
        assert.equal(r.calls, 0);
      });
  });

test('with the shim, the same injection is handed to the privileged handler',
  async (t) => {
    await withVictim(t, { scripts: { 'attack.js': ATTACK_INLINE } },
      async (page) => {
        const r = await page.evaluate((h) => ({
          bridged: window.__calls.filter((c) => c.name === h).map((c) => c.args[0]),
          inDom: window.__attack.inDom,
          pwned: window.__pwned,
        }), INLINE_HANDLER);

        assert.deepEqual(r.bridged, [EXFIL],
          'the injected source crossed into the privileged bridge');
        assert.equal(r.inDom, false,
          'the element is swallowed by the shim, never appended');
        assert.equal(r.pwned, undefined,
          'the stub bridge does not evaluate; the real one does');
      });
  });

test('replayed the way the Dart handler replays it, the payload executes',
  async (t) => {
    // The inline handler calls evaluateJavascript, which runs outside the
    // page's CSP — as does CDP Runtime.evaluate, which is what
    // page.evaluate compiles to. Replaying the captured source through it
    // models the real handler and completes the escalation: a payload the
    // browser refused now runs with the document's full authority.
    await withVictim(t, { scripts: { 'attack.js': ATTACK_INLINE } },
      async (page) => {
        const [source] = await page.evaluate(
          (h) => window.__calls.filter((c) => c.name === h).map((c) => c.args[0]),
          INLINE_HANDLER);
        await page.evaluate(source);

        assert.equal(await page.evaluate(() => window.__pwned), true);
        const violations = await page.evaluate(() => window.__cspViolations.length);
        assert.equal(violations, 0,
          'the bridged path never trips CSP — nothing was appended to block');
      });
  });

test('every patched DOM sink reaches the privileged handler', async (t) => {
  // The shim wraps appendChild, insertBefore and Element.append (the
  // last is a separate path in the DOM impl, not a wrapper over
  // appendChild). An injection sink that uses any of them escalates the
  // same way, so all three belong in the blast radius.
  const sinks = {
    appendChild: 'document.head.appendChild(s);',
    insertBefore: 'document.head.insertBefore(s, document.head.firstChild);',
    append: 'document.head.append(s);',
  };
  for (const [name, call] of Object.entries(sinks)) {
    const attack = `
window.__attack = (function () {
  var s = document.createElement('script');
  s.textContent = ${JSON.stringify(EXFIL)};
  ${call}
  return {};
})();`;
    await withVictim(t, { scripts: { 'attack.js': attack } }, async (page) => {
      const bridged = await page.evaluate(
        (h) => window.__calls.filter((c) => c.name === h).map((c) => c.args[0]),
        INLINE_HANDLER);
      assert.deepEqual(bridged, [EXFIL], `${name} did not reach the bridge`);
    });
  }
});

test('non-classic script types are not bridged', async (t) => {
  // Existing hardening: modules and data blocks would be mangled by a
  // classic-script eval, so the shim leaves them alone. That also keeps
  // them out of the privileged path.
  for (const type of ['module', 'application/json', 'importmap']) {
    await withVictim(t, { scripts: { 'attack.js': typedAttack(type) } },
      async (page) => {
        const bridged = await page.evaluate(
          (h) => window.__calls.filter((c) => c.name === h).length, INLINE_HANDLER);
        assert.equal(bridged, 0, `type=${type} must not reach the bridge`);
      });
  }
});

// ---------- Same-origin policy: the patched window.fetch ----------

test('PREMISE: without the shim, a no-CORS cross-origin read fails',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const third = await startThirdParty();
    try {
      await withVictim(t, {
        shim: false,
        csp: "default-src 'self'; script-src 'self'; connect-src *",
        scripts: {},
      }, async (page) => {
        const r = await page.evaluate(async (u) => {
          try {
            const res = await fetch(u);
            return { ok: true, body: await res.text() };
          } catch (e) {
            return { ok: false, name: e.constructor.name };
          }
        }, `${third.origin}/secret.json`);
        assert.equal(r.ok, false);
        assert.equal(r.name, 'TypeError');
      });
    } finally {
      await third.close();
    }
  });

test('with the shim, the failed cross-origin read is re-issued and returned',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const third = await startThirdParty();
    const secret = '{"secret":"third-party-only"}';
    try {
      await withVictim(t, {
        csp: "default-src 'self'; script-src 'self'; connect-src *",
        body: secret,
      }, async (page) => {
        const r = await page.evaluate(async (u, h) => {
          const res = await fetch(u);
          return {
            body: await res.text(),
            bridged: window.__calls.filter((c) => c.name === h).map((c) => c.args[0]),
          };
        }, `${third.origin}/secret.json`, FETCH_HANDLER);

        assert.equal(r.body, secret,
          'page script reads a body the same-origin policy denied it');
        assert.deepEqual(r.bridged, [`${third.origin}/secret.json`]);
      });
    } finally {
      await third.close();
    }
  });

test('connect-src none is bypassed the same way', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const third = await startThirdParty();
  const secret = '{"secret":"csp-denied"}';
  try {
    await withVictim(t, {
      csp: "default-src 'self'; script-src 'self'; connect-src 'none'",
      body: secret,
    }, async (page) => {
      const r = await page.evaluate(async (u, h) => {
        const res = await fetch(u);
        return {
          body: await res.text(),
          bridged: window.__calls.filter((c) => c.name === h).length,
        };
      }, `${third.origin}/secret.json`, FETCH_HANDLER);

      assert.equal(r.body, secret);
      assert.equal(r.bridged, 1);
    });
  } finally {
    await third.close();
  }
});

test('__wsFetch is a plain global — no handler name needed, no whitelist',
  async (t) => {
    // The whitelist in the shim gates <script src> interception only.
    // Anything in the page can call __wsFetch for an arbitrary host, so
    // the handler-name obfuscation buys nothing here.
    await withVictim(t, { body: '{"any":"host"}' }, async (page) => {
      const r = await page.evaluate(async (h) => {
        const res = await window.__wsFetch('https://not-whitelisted.example/x');
        return {
          body: await res.text(),
          bridged: window.__calls.filter((c) => c.name === h).map((c) => c.args[0]),
        };
      }, FETCH_HANDLER);

      assert.equal(r.body, '{"any":"host"}');
      assert.deepEqual(r.bridged, ['https://not-whitelisted.example/x']);
    });
  });

test('a same-origin failure is not re-issued through the bridge', async (t) => {
  // Retrying same-origin through Dart would drop the WebView's cookies
  // and silently log the user out, so the shim rethrows instead.
  await withVictim(t, { csp: "default-src 'self'; script-src 'self'" },
    async (page, victim) => {
      const r = await page.evaluate(async (u, h) => {
        let name = 'resolved';
        try { await fetch(u); } catch (e) { name = e.constructor.name; }
        return { name, bridged: window.__calls.filter((c) => c.name === h).length };
      }, `${victim.origin}/__reset`, FETCH_HANDLER);

      assert.equal(r.name, 'TypeError');
      assert.equal(r.bridged, 0);
    });
});

// ---------- Reach: which frames get the capability ----------

test('a subframe does not inherit the bridge globals when injection is '
  + 'main-frame-only', async (t) => {
    if (!requireBrowser(browser, t)) return;
    // User scripts are registered without forMainFrameOnly, which the
    // plugin defaults to true, so the shim lands in the top document
    // only. Modelled by evaluating it after load instead of on every
    // document. Flipping that default would widen the capability to
    // every embedded frame — this test is the tripwire.
    const victim = await startVictim({ csp: "default-src 'self'; script-src 'self'" });
    const page = await browser.browser.newPage();
    try {
      await page.goto(victim.url, { waitUntil: 'load' });
      await page.evaluate(BRIDGE_STUB);
      await page.evaluate(SHIM);
      await page.evaluate((src) => new Promise((resolve) => {
        const f = document.createElement('iframe');
        f.src = src;
        f.onload = resolve;
        document.body.appendChild(f);
      }), victim.url);

      const r = await page.evaluate(() => {
        const w = document.querySelector('iframe').contentWindow;
        return {
          parentHasFetch: typeof window.__wsFetch,
          frameHasFetch: typeof w.__wsFetch,
          frameAppendPatched: w.Node.prototype.appendChild
            !== window.Node.prototype.appendChild,
        };
      });

      assert.equal(r.parentHasFetch, 'function');
      assert.equal(r.frameHasFetch, 'undefined',
        'same-origin subframe must not get the capability');
      assert.equal(r.frameAppendPatched, true,
        'the frame keeps its own unpatched appendChild');
    } finally {
      await page.close();
      await victim.close();
    }
  });

test('a cross-origin subframe cannot reach the parent capability', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const third = await startThirdParty();
  const victim = await startVictim({
    csp: `default-src 'self'; script-src 'self'; frame-src ${third.origin}`,
  });
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(BRIDGE_STUB);
    await page.evaluateOnNewDocument(SHIM);
    await page.goto(victim.url, { waitUntil: 'load' });
    await page.evaluate((src) => new Promise((resolve) => {
      const f = document.createElement('iframe');
      f.src = src;
      f.onload = resolve;
      document.body.appendChild(f);
    }), `${third.origin}/frame.html`);

    const frame = page.frames().find((f) => f.url().startsWith(third.origin));
    assert.ok(frame, 'third-party frame did not attach');

    const reach = await frame.evaluate(() => {
      try {
        return typeof parent.__wsFetch;
      } catch (e) {
        return e.name;
      }
    });
    assert.ok(reach === 'SecurityError' || reach === 'undefined',
      `cross-origin frame reached the parent capability: ${reach}`);
  } finally {
    await page.close();
    await victim.close();
    await third.close();
  }
});
