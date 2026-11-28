// Tier 1 — jsdom assertions for the theme/color-scheme shim
// (lib/js/theme_color_scheme.js).
//
// jsdom's matchMedia answers false to everything, so these run the shim
// over a fake engine (helpers/fake_media_engine.js) that evaluates what the
// shim hands it: the shim answers only the colour-scheme feature, and the
// rest of a query is the engine's (accessibility spec). Real CSS engine behaviour is
// asserted at Tier 2.

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim, makeDom, runInDom, pageJs } = require('./helpers/load_shim');
const { fakeMediaEngine } = require('./helpers/fake_media_engine');

const DARK = pageJs('theme_color_scheme', { theme: 'dark' });
const LIGHT = pageJs('theme_color_scheme', { theme: 'light' });

function themed(shim, env) {
  const dom = makeDom();
  const engine = fakeMediaEngine(env);
  dom.window.matchMedia = engine.matchMedia;
  runInDom(dom, shim);
  return { dom, engine, mm: (q) => dom.window.matchMedia(q) };
}

test('dark fixture: matchMedia(prefers-color-scheme: dark) → matches=true', () => {
  const { mm } = themed(DARK, { 'prefers-color-scheme': 'light' });
  assert.equal(mm('(prefers-color-scheme: dark)').matches, true);
  assert.equal(mm('(prefers-color-scheme: light)').matches, false);
});

test('light fixture: matchMedia(prefers-color-scheme: light) → matches=true', () => {
  const { mm } = themed(LIGHT, { 'prefers-color-scheme': 'dark' });
  assert.equal(mm('(prefers-color-scheme: light)').matches, true);
  assert.equal(mm('(prefers-color-scheme: dark)').matches, false);
});

test('an engine that does not answer the stand-ins still gets the app scheme', () => {
  const dark = themed(DARK, { grid: '1', 'prefers-color-scheme': 'light' });
  assert.equal(dark.mm('(prefers-color-scheme: dark)').matches, true);
  assert.equal(dark.mm('(prefers-color-scheme: light)').matches, false);
  const light = themed(LIGHT, { grid: '1', 'prefers-color-scheme': 'dark' });
  assert.equal(light.mm('(prefers-color-scheme: light)').matches, true);
  assert.equal(light.mm('(prefers-color-scheme: dark)').matches, false);
});

test('a compound query keeps its other features for the engine', () => {
  const { mm, engine } = themed(DARK, { 'prefers-contrast': 'more' });
  const q = '(prefers-color-scheme: dark) and (prefers-contrast: more)';
  assert.equal(mm(q).matches, true);
  assert.ok(engine.seen.includes('(grid: 0) and (prefers-contrast: more)'),
    `the engine saw ${JSON.stringify(engine.seen)}`);
  engine.set('prefers-contrast', 'no-preference');
  assert.equal(mm(q).matches, false, 'the contrast half is the engine\'s');
  assert.equal(themed(LIGHT, { 'prefers-contrast': 'more' }).mm(q).matches, false,
    'the colour-scheme half is the app theme\'s');
});

test('not, only and a list are evaluated around the app theme', () => {
  const dark = themed(DARK, { 'prefers-contrast': 'more' }).mm;
  const light = themed(LIGHT, { 'prefers-contrast': 'no-preference' }).mm;
  assert.equal(dark('not all and (prefers-color-scheme: dark)').matches, false);
  assert.equal(light('not all and (prefers-color-scheme: dark)').matches, true);
  assert.equal(dark('only screen and (prefers-color-scheme: dark)').matches, true);
  assert.equal(dark('print and (prefers-color-scheme: dark)').matches, false);
  assert.equal(dark('(prefers-color-scheme: light), (prefers-contrast: more)').matches, true);
  assert.equal(light('(prefers-color-scheme: dark), (prefers-contrast: more)').matches, false);
});

test('case and spacing name the same feature', () => {
  const { mm } = themed(DARK, { 'prefers-color-scheme': 'light' });
  assert.equal(mm('( PREFERS-COLOR-SCHEME :  Dark )').matches, true);
  assert.equal(mm('(prefers-color-scheme)').matches, true);
});

test('text that only contains the name is the engine\'s', () => {
  const { mm, engine } = themed(DARK, { 'prefers-color-scheme': 'light' });
  for (const q of [
    '(x-prefers-color-scheme: dark)',
    '(prefers-color-scheme-dark)',
    '(prefers-color-scheme: no-preference)',
  ]) {
    const r = mm(q);
    assert.equal(r.matches, false, q);
    assert.equal(engine.seen.at(-1), q, `${q} must reach the engine as written`);
  }
});

test('media is the query as the page wrote it', () => {
  const { mm } = themed(DARK);
  const q = '(prefers-color-scheme: dark) and (prefers-contrast: more)';
  assert.equal(mm(q).media, q);
});

test('a theme flip fires a compound query\'s listener only when its answer moves', () => {
  const { dom, mm, engine } = themed(DARK, { 'prefers-contrast': 'more' });
  const seen = [];
  const q = '(prefers-color-scheme: dark) and (prefers-contrast: more)';
  mm(q).addEventListener('change', (e) => seen.push([e.matches, e.media]));
  mm('(prefers-color-scheme: dark) and (prefers-contrast: less)')
    .addEventListener('change', (e) => seen.push(['never', e.media]));
  runInDom(dom, LIGHT);
  assert.deepEqual(seen, [[false, q]]);
  runInDom(dom, LIGHT);
  assert.deepEqual(seen, [[false, q]], 'the same theme again moves nothing');
  runInDom(dom, DARK);
  assert.deepEqual(seen, [[false, q], [true, q]]);
  assert.equal(engine.listening(), 2, 'one engine listener per page listener');
});

test('a change of the engine\'s own feature reaches a compound query\'s listener', () => {
  const { mm, engine } = themed(DARK, { 'prefers-contrast': 'no-preference' });
  const seen = [];
  const q = '(prefers-color-scheme: dark) and (prefers-contrast: more)';
  mm(q).addEventListener('change', (e) => seen.push([e.matches, e.media]));
  engine.set('prefers-contrast', 'more');
  assert.deepEqual(seen, [[true, q]]);
});

test('after a theme flip the listener follows the engine under the new theme', () => {
  const { dom, mm, engine } = themed(LIGHT, { 'prefers-contrast': 'no-preference' });
  const seen = [];
  const q = '(prefers-color-scheme: dark) and (prefers-contrast: more)';
  mm(q).addEventListener('change', (e) => seen.push(e.matches));
  runInDom(dom, DARK);
  assert.deepEqual(seen, []);
  engine.set('prefers-contrast', 'more');
  assert.deepEqual(seen, [true]);
  assert.equal(engine.listening(), 1, 'the listener under the old theme was let go');
});

test('removeEventListener lets go of the engine too', () => {
  const { mm, engine } = themed(DARK);
  const list = mm('(prefers-color-scheme: dark) and (prefers-contrast: more)');
  const listener = () => {};
  list.addEventListener('change', listener);
  assert.equal(engine.listening(), 1);
  list.removeEventListener('change', listener);
  assert.equal(engine.listening(), 0);
});

test('non-color-scheme matchMedia queries fall through to the wrapper', () => {
  // The shim only forges prefers-color-scheme answers; width-based
  // and other queries must defer to the real (or jsdom-stub) matchMedia.
  const dom = loadShim(pageJs('theme_color_scheme', { theme: 'dark' }));
  const r = dom.window.matchMedia('(min-width: 100px)');
  // jsdom polyfill returns {matches:false}; the wrapper must propagate
  // that without synthesising a fake answer.
  assert.equal(typeof r.matches, 'boolean');
  assert.equal(r.media, '(min-width: 100px)');
});

test('shim creates <meta name="color-scheme"> with the resolved theme', () => {
  const dom = loadShim(pageJs('theme_color_scheme', { theme: 'dark' }));
  const meta = dom.window.document.querySelector('meta[name="color-scheme"]');
  assert.ok(meta, 'meta tag must be created');
  assert.equal(meta.getAttribute('content'), 'dark');
});

test('shim sets documentElement.style.colorScheme', () => {
  const dom = loadShim(pageJs('theme_color_scheme', { theme: 'light' }));
  assert.equal(dom.window.document.documentElement.style.colorScheme, 'light');
});

test('synthetic MediaQueryList carries addEventListener / removeEventListener', () => {
  const dom = loadShim(pageJs('theme_color_scheme', { theme: 'dark' }));
  const mql = dom.window.matchMedia('(prefers-color-scheme: dark)');
  assert.equal(typeof mql.addEventListener, 'function');
  assert.equal(typeof mql.removeEventListener, 'function');
  assert.equal(typeof mql.addListener, 'function');
  assert.equal(typeof mql.removeListener, 'function');
});

test('addEventListener registers a change listener for theme flips', () => {
  const dom = loadShim(pageJs('theme_color_scheme', { theme: 'dark' }));
  const mql = dom.window.matchMedia('(prefers-color-scheme: dark)');
  mql.addEventListener('change', () => {});
  // The shim queues listeners on window.__themeChangeListeners and
  // fires them when the theme changes (driven by re-injection in
  // production). Verify the queue picked up the listener.
  assert.equal(dom.window.__themeChangeListeners.length, 1);
  assert.equal(dom.window.__themeChangeListeners[0].query,
    '(prefers-color-scheme: dark)');
});

test('removeEventListener unregisters a previously added change listener', () => {
  const dom = loadShim(pageJs('theme_color_scheme', { theme: 'dark' }));
  const mql = dom.window.matchMedia('(prefers-color-scheme: dark)');
  const listener = () => {};
  mql.addEventListener('change', listener);
  assert.equal(dom.window.__themeChangeListeners.length, 1);
  mql.removeEventListener('change', listener);
  assert.equal(dom.window.__themeChangeListeners.length, 0);
});
