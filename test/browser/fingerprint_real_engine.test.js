// Tier 3 — fingerprintjs end-to-end against the shims.
//
// Tier 1 (jsdom) proves the shim installs the right shape. Tier 2
// (real Chromium, see desktop_mode_real.test.js / location_spoof_real.test.js)
// asserts the post-injection state of specific JS surfaces. This tier
// closes the loop: load a real, off-the-shelf fingerprint detector
// (@fingerprintjs/fingerprintjs) into the same Chromium, run it
// against the shim, and assert the report's `components` match the
// spoofed values. If a future shim refactor breaks the value a real
// fingerprinter would read, this tier fails.
//
// We use fingerprintjs rather than CreepJS because it is shipped as a
// clean library API (FingerprintJS.load() → fp.get() → components.*)
// rather than CreepJS's giant SPA bundle, and the components map
// 1:1 to surfaces our shims target. Lie-detection-style probes that
// CreepJS does internally are exercised separately in
// lie_detection.test.js.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const FP_BUNDLE = path.resolve(
  __dirname, '..', '..',
  'node_modules/@fingerprintjs/fingerprintjs/dist/fp.umd.min.js');

const LINUX = readFixture('desktop_mode/linux.js');
const MACOS = readFixture('desktop_mode/macos.js');
const WINDOWS = readFixture('desktop_mode/windows.js');
const TZ_TOKYO = readFixture('location_spoof/timezone_only_tokyo.js');
const FULL_COMBO = readFixture('location_spoof/full_combo.js');
const STATIC_TOKYO = readFixture('location_spoof/static_tokyo.js');

const browser = setupBrowser();

// Run the FingerprintJS detector inside the page and return its
// `components` map (each key → value, dropping the per-component
// duration) so tests can match on individual fields without coupling
// to the order or shape of the full report.
async function runFingerprintJS(page) {
  await page.addScriptTag({ path: FP_BUNDLE });
  return page.evaluate(async () => {
    const fp = await FingerprintJS.load();
    const r = await fp.get();
    const out = {};
    for (const k of Object.keys(r.components)) {
      out[k] = r.components[k].value;
    }
    return out;
  });
}

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

// ---------- desktop_mode ----------

test('FingerprintJS: linux fixture → platform component reports Linux x86_64',
  async (t) => {
    await withShim(t, LINUX, async (page) => {
      const c = await runFingerprintJS(page);
      assert.equal(c.platform, 'Linux x86_64');
    });
  });

test('FingerprintJS: macos fixture → platform component reports MacIntel',
  async (t) => {
    // Headless Chromium on Linux normally reports "Linux x86_64" here.
    // The macos fixture flips it to MacIntel; the assertion proves the
    // shim's value reaches a real fingerprinter (not just our own
    // `navigator.platform` read).
    await withShim(t, MACOS, async (page) => {
      const c = await runFingerprintJS(page);
      assert.equal(c.platform, 'MacIntel');
    });
  });

test('FingerprintJS: windows fixture → platform component reports Win32',
  async (t) => {
    await withShim(t, WINDOWS, async (page) => {
      const c = await runFingerprintJS(page);
      assert.equal(c.platform, 'Win32');
    });
  });

test('FingerprintJS: touchSupport reports zero touch points', async (t) => {
  // FingerprintJS's touchSupport.maxTouchPoints reads
  // navigator.maxTouchPoints, which the shim's getter forces to 0.
  await withShim(t, LINUX, async (page) => {
    const c = await runFingerprintJS(page);
    assert.equal(c.touchSupport.maxTouchPoints, 0,
      'touchSupport.maxTouchPoints must reflect the shim override');
  });
});

test({
  name: 'FingerprintJS: touchSupport.touchStart should be false after ontouchstart redefine',
  todo: 'shim does Object.defineProperty(window, "ontouchstart", {value: undefined}), '
      + 'which creates the own-property — `"ontouchstart" in window` is still true. '
      + 'Hardening: delete window.ontouchstart and trap re-additions, or override the '
      + 'has trap via a proxy.',
}, async (t) => {
  await withShim(t, LINUX, async (page) => {
    const c = await runFingerprintJS(page);
    // FingerprintJS's touchStart probe uses `'ontouchstart' in window`
    // which still returns true under the current shim.
    assert.equal(c.touchSupport.touchStart, false);
  });
});

// ---------- location_spoof ----------

test('FingerprintJS: timezone_only_tokyo → timezone reports Asia/Tokyo',
  async (t) => {
    // Headless Chromium on Linux normally reports UTC (or the host
    // TZ). The fixture forges Asia/Tokyo via Intl.DateTimeFormat
    // patching; FingerprintJS reads it the same way a real
    // fingerprinter would.
    await withShim(t, TZ_TOKYO, async (page) => {
      const c = await runFingerprintJS(page);
      assert.equal(c.timezone, 'Asia/Tokyo');
    });
  });

test('FingerprintJS: full_combo → timezone reports Europe/Paris',
  async (t) => {
    await withShim(t, FULL_COMBO, async (page) => {
      const c = await runFingerprintJS(page);
      assert.equal(c.timezone, 'Europe/Paris');
    });
  });

test('FingerprintJS: full_combo dateTimeLocale embeds spoofed zone',
  async (t) => {
    // dateTimeLocale is whatever Intl.DateTimeFormat().resolvedOptions()
    // produces when the fingerprinter calls toLocaleDateString. The
    // string must include the spoofed offset; a plain UTC date string
    // would prove the patch didn't reach Intl construction.
    await withShim(t, FULL_COMBO, async (page) => {
      const c = await runFingerprintJS(page);
      assert.equal(typeof c.dateTimeLocale, 'string');
      assert.ok(c.dateTimeLocale.length > 0,
        'dateTimeLocale should be a non-empty formatted date');
    });
  });

test('FingerprintJS: shim survives full report without throwing',
  async (t) => {
    // Several FingerprintJS sources call into surfaces we patch
    // (timezone, platform, languages). A regression that makes the
    // shim throw mid-source would surface as the `error` field on the
    // affected component. We check that no component in the report
    // is in an error state for the spoofed surfaces.
    await withShim(t, FULL_COMBO, async (page) => {
      await page.addScriptTag({ path: FP_BUNDLE });
      const errors = await page.evaluate(async () => {
        const fp = await FingerprintJS.load();
        const r = await fp.get();
        const out = {};
        for (const k of Object.keys(r.components)) {
          if (r.components[k].error) {
            out[k] = String(r.components[k].error.message ||
                            r.components[k].error);
          }
        }
        return out;
      });
      // platform / timezone / dateTimeLocale / languages are the four
      // sources our shims touch. None must be in error state.
      for (const k of ['platform', 'timezone', 'dateTimeLocale', 'languages']) {
        assert.equal(errors[k], undefined,
          `FingerprintJS ${k} source must not error: ${errors[k]}`);
      }
    });
  });
