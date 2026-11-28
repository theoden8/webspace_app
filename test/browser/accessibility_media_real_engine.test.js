// Real-Chromium tier: the accessibility media features a page reads, with
// every page script installed at document start (each with its sample config,
// Tracking Protection's anti_fingerprinting.js among them), answer as the
// engine does, in matchMedia and in a CSS @media rule, alone and beside
// prefers-color-scheme, which the theme shim answers from the app theme
// (dark in its sample). They are fingerprint bits Tracking Protection leaves
// alone on purpose (accessibility spec).
//
// Then the page itself: no script, alone or with all the others, leaves a
// viewport meta that limits zoom or hides an element that carries a role or
// an aria-* attribute.
//
// What this does not check: inverted-colors, which Chromium cannot emulate
// (test/js/accessibility_passthrough.test.js hands it through a fake engine
// instead), and WebKit, where iOS, macOS and Linux run these scripts.
//
// Planted mistakes: anti_fingerprinting.js's matchMedia wrapper answering
// any prefers-reduced-motion query with matches:false failed both of that
// feature's tests; theme_color_scheme.js answering any query naming
// prefers-color-scheme from the theme alone, as it once did, failed all nine
// "beside prefers-color-scheme" tests; default_viewport.js writing
// `maximum-scale=1` into the viewport it adds failed its run on /bare once
// loaded; page_zoom_viewport.js adding `user-scalable=no` failed its runs
// and every script together at start; generic_cosmetic.js adding a style
// that hides `[role="navigation"]` failed its runs and every script
// together's.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser } = require('./helpers/launch');
const { listen, originOf, closeServer } = require('./helpers/blank_server');
const { SAMPLES } = require('../js/helpers/page_js_samples');

const FEATURES = {
  'prefers-reduced-motion': ['reduce', 'no-preference'],
  'prefers-contrast': ['more', 'less', 'no-preference'],
  'forced-colors': ['active', 'none'],
  'prefers-reduced-transparency': ['reduce', 'no-preference'],
};

const probe = (name, value) => `--a11y-${name}-${value}`;
const STYLE = Object.entries(FEATURES)
  .flatMap(([name, values]) => values.map((value) =>
    `@media (${name}: ${value}) { :root { ${probe(name, value)}: 1; } }`))
  .join('\n');
const VIEWPORT = '<meta name="viewport" content="width=device-width, initial-scale=1">';
const LABELLED = [
  '<nav role="navigation" aria-label="Main"><a href="#a">a</a></nav>',
  '<div role="dialog" aria-modal="true" aria-labelledby="t"><h2 id="t">t</h2></div>',
  '<button aria-pressed="false">b</button>',
  '<div role="complementary" aria-label="Sponsored">s</div>',
  '<div role="status" aria-live="polite">l</div>',
].join('');
const page = (head) => `<!doctype html><html><head>${head}<style>${STYLE}</style></head>`
  + `<body><p>x</p>${LABELLED}</body></html>`;
const PAGES = { '/': page(VIEWPORT), '/bare': page('') };

const browser = setupBrowser();

let host = null;
test.before(async () => {
  const server = await listen((req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(PAGES[req.url] ?? PAGES['/']);
  });
  host = { origin: originOf(server), server };
});
test.after(async () => {
  if (host) await closeServer(host.server);
});

// `when` is where the scripts run: at document start, where Chromium has no
// documentElement yet (so a script that needs one stops), or once the page
// has loaded, as a re-run on a live page does and where WebKit's document
// start already has one.
async function withPage(t, {
  emulate = [], scripts = Object.values(SAMPLES), path = '/', when = 'start',
}, body) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    if (when === 'start') {
      for (const script of scripts) await page.evaluateOnNewDocument(script);
    }
    await page.emulateMediaFeatures(emulate);
    await page.goto(`${host.origin}${path}`, { waitUntil: 'load' });
    if (when === 'loaded') {
      for (const content of scripts) await page.addScriptTag({ content });
    }
    await body(page);
  } finally {
    await page.close();
  }
}

// Each value of [name]: whether matchMedia and the CSS rule say it holds.
const read = (page, name) => page.evaluate((feature, values, prefix) => {
  const style = getComputedStyle(document.documentElement);
  return Object.fromEntries(values.map((value) => [value, {
    matchMedia: matchMedia(`(${feature}: ${value})`).matches,
    css: style.getPropertyValue(`${prefix}${feature}-${value}`).trim() === '1',
  }]));
}, name, FEATURES[name], '--a11y-');

for (const [name, values] of Object.entries(FEATURES)) {
  for (const emulated of values) {
    test(`${name}: ${emulated} reaches matchMedia and CSS through every page script`, async (t) => {
      await withPage(t, { emulate: [{ name, value: emulated }] }, async (page) => {
        const want = Object.fromEntries(values.map((value) =>
          [value, { matchMedia: value === emulated, css: value === emulated }]));
        assert.deepEqual(await read(page, name), want);
      });
    });
  }
}

// The theme sample is dark, so `dark and X` is X and `light and X` never holds.
const beside = (page, name) => page.evaluate((feature, values) =>
  Object.fromEntries(values.map((value) => [value, {
    dark: matchMedia(`(prefers-color-scheme: dark) and (${feature}: ${value})`).matches,
    light: matchMedia(`(prefers-color-scheme: light) and (${feature}: ${value})`).matches,
    either: matchMedia(`(prefers-color-scheme: light), (${feature}: ${value})`).matches,
  }])), name, FEATURES[name]);

for (const [name, values] of Object.entries(FEATURES)) {
  for (const emulated of values) {
    test(`${name}: ${emulated} answers from the engine beside prefers-color-scheme`, async (t) => {
      await withPage(t, { emulate: [{ name, value: emulated }] }, async (page) => {
        const want = Object.fromEntries(values.map((value) =>
          [value, { dark: value === emulated, light: false, either: value === emulated }]));
        assert.deepEqual(await beside(page, name), want);
      });
    });
  }
}

const LIMITS = /user-scalable\s*=\s*(no|0)\b|maximum-scale|minimum-scale/i;

// Every viewport meta's content, and each labelled element that no longer
// shows or has been hidden from assistive technology.
const audit = (page) => page.evaluate(async () => {
  await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 50)));
  const viewports = [...document.querySelectorAll('meta[name="viewport" i]')]
    .map((m) => m.getAttribute('content'));
  const hidden = [...document.querySelectorAll('body *')]
    .filter((el) => [...el.attributes].some((a) => a.name === 'role' || a.name.startsWith('aria-')))
    .filter((el) => {
      const style = getComputedStyle(el);
      return style.display === 'none' || style.visibility === 'hidden'
        || el.closest('[aria-hidden="true"], [inert], [hidden]') !== null;
    })
    .map((el) => el.outerHTML.slice(0, 80));
  const labelled = document.querySelectorAll('[role], [aria-label], [aria-pressed]').length;
  return { viewports, hidden, labelled };
});

const RUNS = [
  ['every page script together', Object.values(SAMPLES)],
  ...Object.entries(SAMPLES).map(([name, script]) => [`${name}.js`, [script]]),
];

for (const [label, scripts] of RUNS) {
  for (const path of Object.keys(PAGES)) {
    for (const when of ['start', 'loaded']) {
      test(`${label} at ${when} on ${path} limits no zoom and hides nothing by role or aria`, async (t) => {
        await withPage(t, { scripts, path, when }, async (page) => {
          const { viewports, hidden, labelled } = await audit(page);
          for (const content of viewports) {
            assert.doesNotMatch(content ?? '', LIMITS, `viewport content ${content}`);
          }
          assert.ok(labelled >= 5, 'the labelled elements are still in the page');
          assert.deepEqual(hidden, []);
        });
      });
    }
  }
}
