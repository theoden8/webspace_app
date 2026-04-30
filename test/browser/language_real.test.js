// Tier 2 — real-Chromium tests for the language shim
// (lib/services/language_shim.dart, dumped to test/js_fixtures/language/*.js).
//
// jsdom asserts the shim installs the right shape; this tier asserts
// real Chromium's navigator.language / navigator.languages /
// Intl.DateTimeFormat actually return the spoofed values, that the
// shim doesn't leak as own-properties of navigator (the desktop_mode
// shim has this bug; the language shim targets Navigator.prototype so
// it should be clean), and that the override propagates into iframes
// (cross-realm coverage is what makes a same-origin iframe escape
// detectable).

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const EN = readFixture('language/en.js');
const FR = readFixture('language/fr_FR.js');
const JA = readFixture('language/ja.js');

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

test('en fixture: navigator.language reports "en" under real Chromium',
  async (t) => {
    // Headless Chromium normally reports 'en-US'. The shim flips
    // navigator.language on Navigator.prototype; this test proves the
    // override is read by JS that traverses the prototype chain (most
    // sites do a plain `navigator.language` read).
    await withShim(t, EN, async (page) => {
      const lang = await page.evaluate(() => navigator.language);
      assert.equal(lang, 'en');
    });
  });

test('fr-FR fixture: navigator.language reports "fr-FR"', async (t) => {
  await withShim(t, FR, async (page) => {
    const lang = await page.evaluate(() => navigator.language);
    assert.equal(lang, 'fr-FR');
  });
});

test('ja fixture: navigator.language reports "ja"', async (t) => {
  await withShim(t, JA, async (page) => {
    const lang = await page.evaluate(() => navigator.language);
    assert.equal(lang, 'ja');
  });
});

test('navigator.languages is a frozen single-element array', async (t) => {
  await withShim(t, FR, async (page) => {
    const r = await page.evaluate(() => ({
      langs: Array.from(navigator.languages),
      len: navigator.languages.length,
      frozen: Object.isFrozen(navigator.languages),
    }));
    assert.deepEqual(r.langs, ['fr-FR']);
    assert.equal(r.len, 1);
    assert.equal(r.frozen, true);
  });
});

test('Intl.DateTimeFormat resolvedOptions.locale reports spoofed lang',
  async (t) => {
    // Headless Chromium normally resolves to 'en-US'. The shim wraps
    // Intl.DateTimeFormat.prototype.resolvedOptions to override the
    // locale field; sites doing locale-aware formatting (date parsing,
    // number formatting) must see the spoofed value, not the host's.
    await withShim(t, JA, async (page) => {
      const locale = await page.evaluate(() =>
        new Intl.DateTimeFormat().resolvedOptions().locale);
      assert.equal(locale, 'ja');
    });
  });

test('shim does not leak language as an own-property of navigator',
  async (t) => {
    // Unlike the desktop_mode shim's def(navigator, 'platform', ...)
    // which creates an own-property leak, this shim hits
    // Navigator.prototype so navigator stays clean. Asserting it stays
    // clean catches a future regression that switches to the leaky
    // pattern.
    await withShim(t, EN, async (page) => {
      const own = await page.evaluate(() =>
        Object.getOwnPropertyNames(navigator));
      assert.equal(own.includes('language'), false,
        `language leaks as own-property: ${JSON.stringify(own)}`);
      assert.equal(own.includes('languages'), false);
    });
  });

test('iframe contentWindow inherits the spoofed language', async (t) => {
  // evaluateOnNewDocument runs for every frame in Puppeteer (mirrors
  // forMainFrameOnly:false on iOS). An iframe opening a same-origin
  // about:blank must see the spoofed lang too — otherwise a site
  // could escape via a fresh contentWindow.
  await withShim(t, FR, async (page) => {
    const r = await page.evaluate(async () => {
      const f = document.createElement('iframe');
      document.body.appendChild(f);
      await new Promise((r) => setTimeout(r, 50));
      return {
        lang: f.contentWindow.navigator.language,
        intlLocale: new f.contentWindow.Intl.DateTimeFormat()
          .resolvedOptions().locale,
      };
    });
    assert.equal(r.lang, 'fr-FR');
    assert.equal(r.intlLocale, 'fr-FR');
  });
});

test('shim survives Object.freeze attempts on Navigator.prototype',
  async (t) => {
    // Some defensive sites freeze prototypes to detect monkey-patches.
    // The shim sets configurable:true on its descriptors, so a later
    // Object.freeze would lock them in (defensible). This test just
    // checks the shim survives a freeze without throwing.
    await withShim(t, EN, async (page) => {
      const r = await page.evaluate(() => {
        try { Object.freeze(Navigator.prototype); } catch (_) {}
        return navigator.language;
      });
      assert.equal(r, 'en');
    });
  });
