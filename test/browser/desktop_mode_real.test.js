// Real-Chromium tests for the desktop-mode shim
// (lib/services/desktop_mode_shim.dart, dumped to
// test/js_fixtures/desktop_mode/{linux,macos,windows}.js).
//
// jsdom's matchMedia is a stub returning {matches:false} for every
// query — the test/js/desktop_mode_shim.test.js file can only assert
// the shim's wrapper installs the right keyword regexes, not that
// `(pointer: coarse)` actually flips to false against a real CSS
// engine. Same story for navigator.userAgentData (jsdom never
// populates it; real Chromium does), navigator.maxTouchPoints (jsdom
// reports 0 by default; real Chromium can report >0), the
// MutationObserver-driven viewport rewrite (relies on real
// HTMLMetaElement attribute mutation), and `'ontouchstart' in window`.
//
// These tests load the dumped fixture into Chromium via
// evaluateOnNewDocument (matches DOCUMENT_START injection in the real
// WebView) and assert the post-injection state of a freshly loaded
// page.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const LINUX = readFixture('desktop_mode/linux.js');
const MACOS = readFixture('desktop_mode/macos.js');
const WINDOWS = readFixture('desktop_mode/windows.js');

const browser = setupBrowser();

// Tiny page with a viewport meta tag so the existing-meta rewrite
// path runs. Tests that need a different viewport pass a custom value.
function startServer(viewportContent) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(`<!doctype html><html><head>` +
        (viewportContent !== null
          ? `<meta name="viewport" content="${viewportContent}">`
          : '') +
        `</head><body></body></html>`);
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      resolve({
        url: `http://127.0.0.1:${port}/`,
        close: () => new Promise((r) => server.close(r)),
      });
    });
  });
}

async function withPage(t, shim, fn, { viewportContent = 'width=device-width, initial-scale=1' } = {}) {
  if (!requireBrowser(browser, t)) return;
  const server = await startServer(viewportContent);
  const page = await browser.browser.newPage();
  await page.setViewport({ width: 1280, height: 720 });
  await page.evaluateOnNewDocument(shim);
  try {
    await page.goto(server.url, { waitUntil: 'load' });
    await fn(page);
  } finally {
    await page.close();
    await server.close();
  }
}

test('navigator.platform reports the spoofed value (linux)', async (t) => {
  await withPage(t, LINUX, async (page) => {
    assert.equal(
      await page.evaluate(() => navigator.platform),
      'Linux x86_64');
  });
});

test('navigator.platform reports the spoofed value (macos)', async (t) => {
  await withPage(t, MACOS, async (page) => {
    assert.equal(
      await page.evaluate(() => navigator.platform),
      'MacIntel');
  });
});

test('navigator.platform reports the spoofed value (windows)', async (t) => {
  await withPage(t, WINDOWS, async (page) => {
    assert.equal(
      await page.evaluate(() => navigator.platform),
      'Win32');
  });
});

test('navigator.userAgentData is undefined under real Chromium', async (t) => {
  // Headless Chromium populates navigator.userAgentData by default
  // (Client Hints API). The shim must blank it so a Firefox-shaped UA
  // does not coexist with a Chromium-shaped Client Hints surface.
  await withPage(t, LINUX, async (page) => {
    assert.equal(
      await page.evaluate(() => navigator.userAgentData),
      undefined);
  });
});

test('navigator.userAgentData IS populated without the shim (premise check)',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const server = await startServer('width=device-width, initial-scale=1');
    const page = await browser.browser.newPage();
    try {
      await page.goto(server.url, { waitUntil: 'load' });
      // If this ever fails, headless Chromium has stopped exposing
      // Client Hints by default and the spoof above is testing
      // nothing — re-evaluate the shim's premise.
      const has = await page.evaluate(
        () => typeof navigator.userAgentData === 'object' &&
              navigator.userAgentData !== null);
      assert.ok(has,
        'headless Chromium should expose navigator.userAgentData; ' +
        'if not, the desktop_mode shim no longer needs to blank it');
    } finally {
      await page.close();
      await server.close();
    }
  });

test('navigator.maxTouchPoints is forced to 0', async (t) => {
  await withPage(t, LINUX, async (page) => {
    assert.equal(
      await page.evaluate(() => navigator.maxTouchPoints),
      0);
  });
});

test('window.ontouchstart is undefined after the shim runs', async (t) => {
  await withPage(t, LINUX, async (page) => {
    assert.equal(
      await page.evaluate(() => window.ontouchstart),
      undefined);
  });
});

test('matchMedia(pointer: fine) → matches=true under real CSS engine',
  async (t) => {
    // The real CSS engine in headless Chromium evaluates pointer/hover
    // queries against the embedder's actual input modality. The shim
    // forges a desktop-shaped answer so sites cannot tell.
    await withPage(t, LINUX, async (page) => {
      const r = await page.evaluate(() => {
        const fine = window.matchMedia('(pointer: fine)');
        const coarse = window.matchMedia('(pointer: coarse)');
        return { fine: fine.matches, coarse: coarse.matches };
      });
      assert.equal(r.fine, true);
      assert.equal(r.coarse, false);
    });
  });

test('matchMedia(hover: hover) → matches=true under real CSS engine',
  async (t) => {
    await withPage(t, LINUX, async (page) => {
      const r = await page.evaluate(() => {
        const hov = window.matchMedia('(hover: hover)');
        const none = window.matchMedia('(hover: none)');
        return { hov: hov.matches, none: none.matches };
      });
      assert.equal(r.hov, true);
      assert.equal(r.none, false);
    });
  });

test('matchMedia any-pointer / any-hover variants are also forged',
  async (t) => {
    await withPage(t, LINUX, async (page) => {
      const r = await page.evaluate(() => ({
        anyFine: window.matchMedia('(any-pointer: fine)').matches,
        anyCoarse: window.matchMedia('(any-pointer: coarse)').matches,
        anyHover: window.matchMedia('(any-hover: hover)').matches,
        anyNone: window.matchMedia('(any-hover: none)').matches,
      }));
      assert.deepEqual(r, {
        anyFine: true, anyCoarse: false,
        anyHover: true, anyNone: false,
      });
    });
  });

test('matchMedia width queries fall through to the real engine',
  async (t) => {
    // Viewport is 1280x720 (page.setViewport above). The shim must
    // NOT hijack non-pointer / non-hover queries — width-based
    // breakpoints are exactly how responsive sites pick a layout.
    await withPage(t, LINUX, async (page) => {
      const r = await page.evaluate(() => ({
        narrow: window.matchMedia('(min-width: 1px)').matches,
        wide: window.matchMedia('(min-width: 9999px)').matches,
        threshold1000: window.matchMedia('(min-width: 1000px)').matches,
      }));
      assert.equal(r.narrow, true,
        'min-width: 1px must match in any non-zero viewport');
      assert.equal(r.wide, false,
        'min-width: 9999px must not match a 1280px viewport');
      assert.equal(r.threshold1000, true,
        'min-width: 1000px must match a 1280px viewport (engine, not shim)');
    });
  });

test('matchMedia synthetic result has add/removeEventListener', async (t) => {
  // CSS-in-JS libraries call addEventListener('change', ...) on
  // MediaQueryList and unwrap or throw if it's missing.
  await withPage(t, LINUX, async (page) => {
    const r = await page.evaluate(() => {
      const fine = window.matchMedia('(pointer: fine)');
      return {
        hasAdd: typeof fine.addEventListener === 'function',
        hasRemove: typeof fine.removeEventListener === 'function',
        hasAddOld: typeof fine.addListener === 'function',
        hasRemoveOld: typeof fine.removeListener === 'function',
        media: fine.media,
      };
    });
    assert.equal(r.hasAdd, true);
    assert.equal(r.hasRemove, true);
    assert.equal(r.hasAddOld, true);
    assert.equal(r.hasRemoveOld, true);
    assert.equal(r.media, '(pointer: fine)');
  });
});

test('viewport rewrite covers existing AND dynamically inserted metas',
  async (t) => {
    // Puppeteer's evaluateOnNewDocument fires before
    // document.documentElement exists; the shim's MutationObserver
    // setup is guarded on `if (document.documentElement)` and
    // therefore never attaches in that injection model. Real-engine
    // WebViews (iOS WKUserScript atDocumentStart, Android Profile
    // 110+, WPE WebKit DOCUMENT_START) inject after documentElement
    // is created, so the production timing differs from Puppeteer's.
    //
    // To test the rewrite logic itself in real Chromium, inject the
    // shim post-load via page.evaluate. This exercises both code
    // paths — rewriteExistingViewports() finds the static meta, and
    // the MutationObserver catches the one we add after the shim
    // installs — using the real CSS engine's HTMLMetaElement and
    // MutationObserver implementations rather than jsdom's.
    if (!requireBrowser(browser, t)) return;
    const server = await startServer('width=device-width, initial-scale=1');
    const page = await browser.browser.newPage();
    try {
      await page.goto(server.url, { waitUntil: 'load' });
      await page.evaluate(LINUX);
      const beforeInsert = await page.evaluate(() =>
        document.querySelector('meta[name="viewport" i]').getAttribute('content'));
      assert.equal(beforeInsert, 'width=1280, initial-scale=1.0',
        'rewriteExistingViewports must rewrite the static meta');

      const afterInsert = await page.evaluate(async () => {
        const m = document.createElement('meta');
        m.setAttribute('name', 'viewport');
        m.setAttribute('content', 'width=device-width, initial-scale=1');
        document.head.appendChild(m);
        // MutationObserver callbacks queue as microtasks; yield twice
        // so the rewrite has settled before we read the attribute.
        await new Promise((r) => setTimeout(r, 50));
        return m.getAttribute('content');
      });
      assert.equal(afterInsert, 'width=1280, initial-scale=1.0',
        'MutationObserver must catch dynamically inserted viewport metas');
    } finally {
      await page.close();
      await server.close();
    }
  });

test('shim is idempotent — second injection is a no-op', async (t) => {
  // Real WebViews re-run initialUserScripts on every frame load. The
  // re-entry guard must short-circuit the second pass so the matchMedia
  // wrapper does not wrap itself.
  await withPage(t, LINUX, async (page) => {
    const flag = await page.evaluate((shim) => {
      const before = window.__ws_desktop_shim__;
      // Re-run the shim. The guard at the top should bail.
      // eslint-disable-next-line no-eval
      eval(shim);
      // matchMedia must still produce the same answer; if the wrapper
      // wrapped itself it would still work but we'd recurse on bind.
      const fine = window.matchMedia('(pointer: fine)').matches;
      const coarse = window.matchMedia('(pointer: coarse)').matches;
      return { before, fine, coarse };
    }, LINUX);
    assert.equal(flag.before, true);
    assert.equal(flag.fine, true);
    assert.equal(flag.coarse, false);
  });
});
