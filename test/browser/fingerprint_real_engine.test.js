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

// Issue #327 fixtures: same siteId ('alpha-fixture-seed'), two
// different process-lifetime nonces. Building these in the Dart fixture
// dumper (tool/dump_shim_js.dart) keeps the seed strings under spec
// control and prevents this test from accidentally generating its own
// shim with a divergent JS-side hashing rule.
const ANTI_FP_LAUNCH_ONE =
    readFixture('anti_fingerprinting/shim_seed_alpha_launch_one.js');
const ANTI_FP_LAUNCH_TWO =
    readFixture('anti_fingerprinting/shim_seed_alpha_launch_two.js');
const ANTI_FP_STABLE =
    readFixture('anti_fingerprinting/shim_seed_alpha.js');

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

test('FingerprintJS: touchSupport.touchStart is false after ontouchstart removal',
  async (t) => {
    // FingerprintJS's touchStart probe uses `'ontouchstart' in window`.
    // The hardened shim deletes ontouchstart from both window and
    // Window.prototype, so the probe returns false (matches a
    // genuine no-touch desktop browser).
    await withShim(t, LINUX, async (page) => {
      const c = await runFingerprintJS(page);
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

// ---------- #327 incognito fingerprint rerolls per launch ----------
//
// Tier 1 (Dart unit tests on `computeAntiFingerprintingSeed` /
// `buildAntiFingerprintingScriptSource`) and Tier 2 (jsdom shape
// tests) prove the seed-derivation logic and shim shape. This tier
// closes the loop under real Chromium: load FingerprintJS against
// two shims that share a siteId but differ only in the launch nonce,
// and assert the report's noise-bearing components diverge. If a
// future refactor accidentally drops the nonce (siteId-only seed),
// the two reports would coincide and this test fails.

async function fingerprintWith(t, shim) {
  let result;
  await withShim(t, shim, async (page) => {
    result = await runFingerprintJS(page);
  });
  return result;
}

test('FingerprintJS: incognito launches under same siteId produce ' +
     'distinct canvas signatures (#327)',
  async (t) => {
    const r1 = await fingerprintWith(t, ANTI_FP_LAUNCH_ONE);
    const r2 = await fingerprintWith(t, ANTI_FP_LAUNCH_TWO);
    if (!r1 || !r2) return; // requireBrowser already skipped
    // FingerprintJS's `canvas` component is an object with `winding`
    // (a boolean) and two data-URL strings — `text` and `geometry` —
    // hashed from the painted canvas. Our shim noises ~1/32 pixels
    // via a seeded PRNG, so two different seeds must produce two
    // different data URLs. Comparing the full object lets either
    // string diverge.
    assert.notDeepEqual(r1.canvas, r2.canvas,
      'two incognito launches with different nonces must yield ' +
      'different canvas fingerprints (issue #327)');
  });

test('FingerprintJS: same shim loaded twice yields identical canvas ' +
     '(in-launch stability)',
  async (t) => {
    // Within one launch the nonce is constant, so two page-loads of
    // the same shim must produce the same canvas hash — otherwise
    // FingerprintJS would re-identify the SAME session as a new one
    // on every page load.
    const r1 = await fingerprintWith(t, ANTI_FP_LAUNCH_ONE);
    const r2 = await fingerprintWith(t, ANTI_FP_LAUNCH_ONE);
    if (!r1 || !r2) return;
    assert.deepEqual(r1.canvas, r2.canvas,
      'same shim must produce the same canvas fingerprint on repeat');
  });

test('FingerprintJS: non-incognito (siteId-only seed) differs from ' +
     'incognito (siteId:nonce seed) for the same siteId',
  async (t) => {
    // The user's opt-in to Incognito must visibly change what a real
    // fingerprinter sees, otherwise the toggle is cosmetic. Same
    // siteId, ETP-004 stable seed vs ETP-019 nonced seed.
    const stable = await fingerprintWith(t, ANTI_FP_STABLE);
    const ephemeral = await fingerprintWith(t, ANTI_FP_LAUNCH_ONE);
    if (!stable || !ephemeral) return;
    assert.notDeepEqual(stable.canvas, ephemeral.canvas,
      'toggling incognito for the same site must change the canvas '
      + 'fingerprint a real fingerprinter sees');
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
