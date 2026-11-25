// Real-Chromium tier: the accessibility media features a page reads, with
// every page script installed at document start (each with its sample config,
// Tracking Protection's anti_fingerprinting.js among them), answer as the
// engine does, in matchMedia and in a CSS @media rule. They are fingerprint
// bits Tracking Protection leaves alone on purpose (accessibility spec).
//
// What this does not check: inverted-colors, which Chromium cannot emulate,
// and a query that pairs one of these with prefers-color-scheme, which the
// theme shim answers from the app theme alone (the todo below).
//
// Planted mistake: anti_fingerprinting.js's matchMedia wrapper answering
// any prefers-reduced-motion query with matches:false failed both of that
// feature's tests.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser } = require('./helpers/launch');
const { startBlankServer, originOf, closeServer } = require('./helpers/blank_server');
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
const PAGE = `<!doctype html><html><head><style>${STYLE}</style></head>`
  + '<body><p>x</p></body></html>';

const browser = setupBrowser();

let host = null;
test.before(async () => {
  const server = await startBlankServer(PAGE, 'text/html; charset=utf-8');
  host = { url: `${originOf(server)}/`, server };
});
test.after(async () => {
  if (host) await closeServer(host.server);
});

async function withPage(t, { emulate }, body) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    for (const script of Object.values(SAMPLES)) await page.evaluateOnNewDocument(script);
    await page.emulateMediaFeatures(emulate);
    await page.goto(host.url, { waitUntil: 'load' });
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

test('a contrast query beside prefers-color-scheme answers from the engine', {
  todo: 'theme_color_scheme.js answers any query naming prefers-color-scheme from the app theme alone',
}, async (t) => {
  await withPage(t, { emulate: [{ name: 'prefers-contrast', value: 'no-preference' }] }, async (page) => {
    const matches = await page.evaluate(() =>
      matchMedia('(prefers-color-scheme: dark) and (prefers-contrast: more)').matches);
    assert.equal(matches, false);
  });
});
