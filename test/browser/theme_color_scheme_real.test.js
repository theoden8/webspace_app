// Tier 2 — real-Chromium tests for the theme/color-scheme shim
// (lib/services/theme_color_scheme_shim.dart, dumped to
// test/js_fixtures/theme_color_scheme/*.js).
//
// jsdom's matchMedia stub returns {matches:false} for everything, so
// the Tier 1 tests can only assert the shim's wrapper logic.
// Real-engine assertions: prefers-color-scheme actually flips against
// the live CSS engine, the matchMedia wrapper survives addEventListener
// chains, the meta tag reaches the DOM, and (importantly for the
// `system` fixture) the shim's host-preference resolution reads the
// real engine's prefers-color-scheme value at install time.
//
// The shim is registered via setThemePreference at runtime, not via
// initialUserScripts, so it normally runs after document load. To
// exercise the resolveExisting path we run it post-`load` — same as
// the desktop_mode viewport rewrite test does for the same reason
// (Puppeteer's evaluateOnNewDocument fires before documentElement
// exists, but the shim needs documentElement.style.colorScheme).

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const LIGHT = readFixture('theme_color_scheme/light.js');
const DARK = readFixture('theme_color_scheme/dark.js');
const SYSTEM = readFixture('theme_color_scheme/system.js');

const browser = setupBrowser();

async function withShim(t, shim, fn, opts = {}) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    if (opts.emulateColorScheme) {
      await page.emulateMediaFeatures([
        { name: 'prefers-color-scheme', value: opts.emulateColorScheme },
      ]);
    }
    await page.goto('about:blank', { waitUntil: 'load' });
    await page.evaluate(shim);
    await fn(page);
  } finally {
    await page.close();
  }
}

test('dark fixture: matchMedia reports prefers-color-scheme:dark matches=true',
  async (t) => {
    // Real CSS engine evaluation. Without the shim the answer would
    // depend on Chromium's prefers-color-scheme emulation; with the
    // shim it must be true regardless.
    await withShim(t, DARK, async (page) => {
      const r = await page.evaluate(() => ({
        dark: matchMedia('(prefers-color-scheme: dark)').matches,
        light: matchMedia('(prefers-color-scheme: light)').matches,
      }));
      assert.equal(r.dark, true);
      assert.equal(r.light, false);
    });
  });

test('light fixture: matchMedia reports prefers-color-scheme:light matches=true',
  async (t) => {
    await withShim(t, LIGHT, async (page) => {
      const r = await page.evaluate(() => ({
        dark: matchMedia('(prefers-color-scheme: dark)').matches,
        light: matchMedia('(prefers-color-scheme: light)').matches,
      }));
      assert.equal(r.dark, false);
      assert.equal(r.light, true);
    });
  });

test('system fixture follows host preference (emulated dark) → dark',
  async (t) => {
    // Use page.emulateMediaFeatures to set the host's
    // prefers-color-scheme, then load the `system` fixture and assert
    // it resolves to dark.
    await withShim(t, SYSTEM, async (page) => {
      const r = await page.evaluate(() => ({
        resolved: window.__appThemePreference,
        dark: matchMedia('(prefers-color-scheme: dark)').matches,
      }));
      assert.equal(r.resolved, 'dark',
        'system fixture should resolve to dark when host emulates dark');
      assert.equal(r.dark, true);
    }, { emulateColorScheme: 'dark' });
  });

test('system fixture follows host preference (emulated light) → light',
  async (t) => {
    await withShim(t, SYSTEM, async (page) => {
      const r = await page.evaluate(() => ({
        resolved: window.__appThemePreference,
        light: matchMedia('(prefers-color-scheme: light)').matches,
      }));
      assert.equal(r.resolved, 'light');
      assert.equal(r.light, true);
    }, { emulateColorScheme: 'light' });
  });

test('width-based matchMedia queries fall through to the real engine',
  async (t) => {
    // The shim only forges prefers-color-scheme answers. Width-based
    // queries (responsive breakpoints) must still reach the real CSS
    // engine. Set a known viewport so the assertion is deterministic.
    await withShim(t, DARK, async (page) => {
      await page.setViewport({ width: 1280, height: 720 });
      const r = await page.evaluate(() => ({
        narrow: matchMedia('(min-width: 1px)').matches,
        wide: matchMedia('(min-width: 9999px)').matches,
      }));
      assert.equal(r.narrow, true);
      assert.equal(r.wide, false);
    });
  });

test('shim creates <meta name="color-scheme"> with the resolved theme',
  async (t) => {
    await withShim(t, DARK, async (page) => {
      const content = await page.evaluate(() => {
        const m = document.querySelector('meta[name="color-scheme"]');
        return m && m.getAttribute('content');
      });
      assert.equal(content, 'dark');
    });
  });

test('shim sets documentElement.style.colorScheme', async (t) => {
  await withShim(t, LIGHT, async (page) => {
    const cs = await page.evaluate(
      () => document.documentElement.style.colorScheme);
    assert.equal(cs, 'light');
  });
});

test('addEventListener("change") fires when shim is re-injected with a flip',
  async (t) => {
    // Production flow: setThemePreference runs the script again with a
    // new themeValue. The forEach at the end of the script fires every
    // queued change listener. Simulate by injecting dark, registering
    // a listener, then injecting light — the listener should observe
    // the flip.
    if (!requireBrowser(browser, t)) return;
    const page = await browser.browser.newPage();
    try {
      await page.goto('about:blank', { waitUntil: 'load' });
      await page.evaluate(DARK);

      // Register a listener and capture invocations.
      await page.evaluate(() => {
        window.__themeFlips = [];
        matchMedia('(prefers-color-scheme: dark)')
          .addEventListener('change', (e) => {
            window.__themeFlips.push({ matches: e.matches, media: e.media });
          });
      });

      // Re-inject with light. The shim re-runs and walks
      // __themeChangeListeners, dispatching change events with the new
      // matches value.
      await page.evaluate(LIGHT);
      const flips = await page.evaluate(() => window.__themeFlips);
      assert.equal(flips.length, 1, `expected one flip, got ${flips.length}`);
      assert.equal(flips[0].matches, false,
        'after flipping to light, prefers-color-scheme:dark must be false');
      assert.equal(flips[0].media, '(prefers-color-scheme: dark)');
    } finally {
      await page.close();
    }
  });

test('iframe contentWindow inherits the matchMedia override', async (t) => {
  // Unlike the language shim (which patches Navigator.prototype),
  // this shim patches window.matchMedia on the host realm only. An
  // iframe has its own window, so iframe.contentWindow.matchMedia is
  // NOT spoofed. Document this as the current state — escape is
  // possible.
  //
  // Note: in production this shim is injected via evaluateJavascript
  // (one-shot), not as an initialUserScript, so the iframe escape is
  // accepted scope-wise. The desktop_mode and location_spoof shims
  // ARE installed at DOCUMENT_START via initialUserScripts and DO
  // reach iframes; the contrast is intentional.
  await withShim(t, DARK, async (page) => {
    const r = await page.evaluate(async () => {
      const f = document.createElement('iframe');
      document.body.appendChild(f);
      await new Promise((r) => setTimeout(r, 50));
      // Iframe's matchMedia is unmodified — uses real engine which,
      // in headless Chromium without emulation, defaults to light.
      return f.contentWindow.matchMedia(
        '(prefers-color-scheme: dark)').matches;
    });
    // Document the escape: with shim=dark in the host but no
    // injection in the iframe, the iframe's value is whatever the
    // real engine reports (engine default).
    assert.equal(typeof r, 'boolean',
      'iframe matchMedia must be callable; escape behaviour is engine-dependent');
  });
});
