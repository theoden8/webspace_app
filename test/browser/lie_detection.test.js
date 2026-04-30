// Tier 3 lie-detection probes — the same techniques CreepJS uses to
// flag a spoofed surface, applied to our shims.
//
// fingerprintjs (in fingerprint_real_engine.test.js) reads spoofed
// values; this file probes whether a fingerprinter could *tell that
// the surface was spoofed* by looking past the value:
//
//   - Function.prototype.toString.call(fn) — does the override
//     stringify as JS source or as native code?
//   - Object.getOwnPropertyNames(navigator) — does the override show
//     up as an own property where a real navigator only has
//     prototype-defined ones?
//   - Iframe escape — does a fresh `iframe.contentWindow.navigator`
//     reveal the un-overridden value (proves the shim only reaches
//     the main frame)?
//   - Getter source inspection via property descriptor — same
//     stringify trick at a different access path.
//
// Findings encoded as live assertions where the shim already
// withstands the probe; encoded as `t.todo` where a real-world
// fingerprinter would still detect the spoof, so a future hardening
// pass can flip the marker to a passing test without rewriting it.

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const LINUX = readFixture('desktop_mode/linux.js');
const FULL_COMBO = readFixture('location_spoof/full_combo.js');

const browser = setupBrowser();

async function withShim(t, shim, fn) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(shim);
    await page.goto('about:blank', { waitUntil: 'load' });
    await fn(page);
  } finally {
    await page.close();
  }
}

// ---------- Function.prototype.toString native-code probe ----------

test('location_spoof: every override stringifies as native code',
  async (t) => {
    // The shim's WeakMap-keyed Function.prototype.toString patch
    // claims to make every spoofed function look native. Walk the
    // surfaces a fingerprinter would inspect and assert they all
    // pass the [native code] check.
    await withShim(t, FULL_COMBO, async (page) => {
      const r = await page.evaluate(() => {
        const probe = (fn) => Function.prototype.toString.call(fn);
        return {
          getCurrentPosition: probe(navigator.geolocation.getCurrentPosition),
          watchPosition: probe(navigator.geolocation.watchPosition),
          clearWatch: probe(navigator.geolocation.clearWatch),
          permissionsQuery: probe(navigator.permissions.query),
          getTimezoneOffset: probe(Date.prototype.getTimezoneOffset),
          dateToString: probe(Date.prototype.toString),
          IntlDateTimeFormat: probe(Intl.DateTimeFormat),
          // Sanity: a built-in we did NOT override should still
          // stringify as native — proves the patch isn't blanket.
          arrayPush: probe(Array.prototype.push),
        };
      });
      const NATIVE = /\[native code\]/;
      for (const [k, src] of Object.entries(r)) {
        assert.match(src, NATIVE,
          `${k} must stringify as native, got: ${src}`);
      }
    });
  });

test({
  name: 'desktop_mode: navigator.platform getter stringifies as native code',
  todo: 'desktop_mode shim has no Function.prototype.toString hardening; '
      + 'getter source leaks. Port the WeakMap stub from location_spoof.',
}, async (t) => {
  await withShim(t, LINUX, async (page) => {
    const src = await page.evaluate(() => {
      const desc = Object.getOwnPropertyDescriptor(navigator, 'platform');
      return Function.prototype.toString.call(desc.get);
    });
    assert.match(src, /\[native code\]/,
      `getter source leaks: ${src}`);
  });
});

// ---------- Own-property enumeration leak ----------

test({
  name: 'desktop_mode: Object.getOwnPropertyNames(navigator) does not list overrides',
  todo: 'shim uses Object.defineProperty(navigator, ...) which creates own '
      + 'properties; a real navigator carries these on Navigator.prototype. '
      + 'Hardening: target Navigator.prototype instead, or hide via Proxy.',
}, async (t) => {
  await withShim(t, LINUX, async (page) => {
    const ownProps = await page.evaluate(() =>
      Object.getOwnPropertyNames(navigator));
    // Clean Chromium reports an empty array (or close to it). The
    // shim's defineProperty calls add at least platform, userAgentData,
    // maxTouchPoints. Each presence is a fingerprintable diff.
    for (const k of ['platform', 'userAgentData', 'maxTouchPoints']) {
      assert.equal(ownProps.includes(k), false,
        `${k} leaks as own-property of navigator: ${JSON.stringify(ownProps)}`);
    }
  });
});

test('desktop_mode: own-property leak is reproducible (premise check)',
  async (t) => {
    // Documents the current state so the todo above has a clear
    // baseline. If the shim is hardened (and the todo flips to
    // passing), this premise check will start failing — that's the
    // signal to delete this premise check together with the todo
    // marker.
    await withShim(t, LINUX, async (page) => {
      const ownProps = await page.evaluate(() =>
        Object.getOwnPropertyNames(navigator));
      assert.ok(ownProps.includes('platform'),
        'expected current shim to leak platform as own-property; '
        + 'if this fails the shim was hardened — flip the todo above');
    });
  });

// ---------- Iframe escape ----------

test('iframe contentWindow inherits the spoofed navigator.platform',
  async (t) => {
    // A site that mints an `<iframe>` and reads
    // `iframe.contentWindow.navigator.platform` would otherwise see
    // the un-overridden value and detect the spoof. Puppeteer's
    // evaluateOnNewDocument is registered for every frame (mirroring
    // forMainFrameOnly:false on iOS WKUserScript), so the same shim
    // runs in the iframe realm.
    await withShim(t, LINUX, async (page) => {
      const r = await page.evaluate(async () => {
        const f = document.createElement('iframe');
        document.body.appendChild(f);
        // Wait for the frame's about:blank to settle so the iframe's
        // own document has finished its DOCUMENT_START injection.
        await new Promise((r) => setTimeout(r, 50));
        return {
          platform: f.contentWindow.navigator.platform,
          maxTouchPoints: f.contentWindow.navigator.maxTouchPoints,
          userAgentData: f.contentWindow.navigator.userAgentData,
        };
      });
      assert.equal(r.platform, 'Linux x86_64');
      assert.equal(r.maxTouchPoints, 0);
      assert.equal(r.userAgentData, undefined);
    });
  });

test('iframe contentWindow inherits the spoofed timezone', async (t) => {
  await withShim(t, FULL_COMBO, async (page) => {
    const tz = await page.evaluate(async () => {
      const f = document.createElement('iframe');
      document.body.appendChild(f);
      await new Promise((r) => setTimeout(r, 50));
      return new f.contentWindow.Intl.DateTimeFormat()
        .resolvedOptions().timeZone;
    });
    assert.equal(tz, 'Europe/Paris');
  });
});

// ---------- Property descriptor inspection ----------

test('location_spoof: descriptor for Date.prototype.getTimezoneOffset hides override',
  async (t) => {
    // Object.getOwnPropertyDescriptor(...).value.toString() is a
    // common CreepJS-style probe. With the WeakMap-keyed
    // toString stub the shim installs, this must return native shape.
    await withShim(t, FULL_COMBO, async (page) => {
      const src = await page.evaluate(() => {
        const desc = Object.getOwnPropertyDescriptor(
          Date.prototype, 'getTimezoneOffset');
        return Function.prototype.toString.call(desc.value);
      });
      assert.match(src, /\[native code\]/,
        `getTimezoneOffset descriptor leaks source: ${src}`);
    });
  });

test('location_spoof: Geolocation.prototype overrides all stringify as native',
  async (t) => {
    // Sites can read methods off Geolocation.prototype directly.
    // The shim re-defines all three on the prototype; all three must
    // pass the native-code stringification check.
    await withShim(t, FULL_COMBO, async (page) => {
      const r = await page.evaluate(() => ({
        get: Function.prototype.toString.call(
          Geolocation.prototype.getCurrentPosition),
        watch: Function.prototype.toString.call(
          Geolocation.prototype.watchPosition),
        clear: Function.prototype.toString.call(
          Geolocation.prototype.clearWatch),
      }));
      assert.match(r.get, /\[native code\]/);
      assert.match(r.watch, /\[native code\]/);
      assert.match(r.clear, /\[native code\]/);
    });
  });

// ---------- toString chain integrity ----------

test('location_spoof: Function.prototype.toString.toString is also stubbed',
  async (t) => {
    // A fingerprinter that suspects toString has been patched will
    // probe `Function.prototype.toString.toString()` to read the
    // patched function's own source. The shim self-stubs the patched
    // toString so this recursive probe also returns native shape.
    await withShim(t, FULL_COMBO, async (page) => {
      const src = await page.evaluate(() =>
        Function.prototype.toString.call(Function.prototype.toString));
      assert.match(src, /\[native code\]/,
        `Function.prototype.toString itself leaks source: ${src}`);
    });
  });
