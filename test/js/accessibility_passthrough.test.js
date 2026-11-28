// The engine's own accessibility passes through the app (accessibility spec).
//
// First the media features a page reads: with every page script installed
// over a fake engine (helpers/fake_media_engine.js), each feature answers
// what the engine says, alone and beside prefers-color-scheme. This is the
// only check inverted-colors has, since Chromium cannot emulate it; the
// others are also held on a real engine by
// test/browser/accessibility_media_real_engine.test.js. No script names one
// of them, so none can write a CSS rule over them either.
//
// Then what the app may not write anywhere: a viewport that limits zoom, a
// rule or attribute that hides an element by its role or aria-* attributes,
// accessibilityIgnoresInvertColors. These read source text (rung 5): no type
// says what a string a page receives contains. A webview whose `supportZoom`
// is false counts as a viewport that limits zoom: on iOS and macOS the fork
// then injects `maximum-scale=1.0, user-scalable=no` into its main frame
// (its SupportZoomJS).
//
// Planted mistakes: anti_fingerprinting.js answering `(inverted-colors:
// inverted)` with matches:false failed the inverted-colors test and the one
// that no script names a feature; `maximum-scale=1` in default_viewport.js
// and `user-scalable=no` in a string of ios/Runner/AppDelegate.swift each
// failed the viewport test; `supportZoom = false` in WebViewFactory failed
// the zoom test; `[aria-hidden]` in generic_cosmetic.js failed the role
// test; `accessibilityIgnoresInvertColors = true` in WebViewFactory failed
// the Smart Invert test.

const test = require('node:test');
const assert = require('node:assert/strict');
const { VirtualConsole } = require('jsdom');
const { makeDom, runInDom } = require('./helpers/load_shim');
const { fakeMediaEngine } = require('./helpers/fake_media_engine');
const { SAMPLES } = require('./helpers/page_js_samples');
const { read, files, code, lineAt, jsFiles } = require('./helpers/source');

const FEATURES = {
  'prefers-reduced-motion': ['reduce', 'no-preference'],
  'prefers-contrast': ['more', 'less', 'no-preference', 'custom'],
  'forced-colors': ['active', 'none'],
  'inverted-colors': ['inverted', 'none'],
  'prefers-reduced-transparency': ['reduce', 'no-preference'],
};

// Every script, the theme's (dark in its sample) last so its matchMedia
// wraps every other wrapper's, over an engine whose own scheme is light.
function everyScript(t) {
  const dom = makeDom({ virtualConsole: new VirtualConsole() });
  const engine = fakeMediaEngine({ 'prefers-color-scheme': 'light' });
  dom.window.matchMedia = engine.matchMedia;
  const { theme_color_scheme: theme, ...rest } = SAMPLES;
  for (const [name, source] of [...Object.entries(rest), ['theme_color_scheme', theme]]) {
    try {
      runInDom(dom, source);
    } catch (e) {
      if (!(e instanceof dom.window.Error)) throw e;
      assert.notEqual(name, 'theme_color_scheme', `the theme shim threw: ${e.message}`);
    }
  }
  t.after(() => dom.window.close());
  return { engine, mm: (q) => dom.window.matchMedia(q).matches };
}

for (const [name, values] of Object.entries(FEATURES)) {
  test(`${name} answers from the engine through every page script`, (t) => {
    const { engine, mm } = everyScript(t);
    for (const set of values) {
      engine.set(name, set);
      for (const value of values) {
        const holds = value === set;
        assert.equal(mm(`(${name}: ${value})`), holds, `(${name}: ${value}) with ${set}`);
        assert.equal(mm(`(prefers-color-scheme: dark) and (${name}: ${value})`), holds,
          `beside the dark theme, (${name}: ${value}) with ${set}`);
        assert.equal(mm(`(prefers-color-scheme: light) and (${name}: ${value})`), false,
          `beside the light scheme the dark theme rules out, (${name}: ${value})`);
        assert.equal(mm(`not all and (${name}: ${value})`), !holds, `not (${name}: ${value})`);
      }
    }
  });
}

test('no page script names an accessibility media feature', () => {
  const names = new RegExp(Object.keys(FEATURES).join('|'));
  for (const f of jsFiles()) {
    const src = code(read(f));
    const m = names.exec(src);
    assert.equal(m, null, m && `${f}:${lineAt(src, m.index)} names ${m[0]}`);
  }
});

// The source the app ships: Dart and page scripts, and the native runners.
const NATIVE = /\.(swift|mm?|h|kt|java|cc|c|cpp|js|html|css)$/;
const SKIP = /\/(build|Pods|ephemeral|\.gradle|\.cxx|\.symlinks|test|androidTest|RunnerTests)\//;
const shipped = [
  ...files('lib', /\.(dart|js|html|css)$/).filter((f) => !f.startsWith('lib/l10n/gen/')),
  ...['ios', 'macos', 'android', 'linux'].flatMap((d) => files(d, NATIVE)),
].filter((f) => !SKIP.test(f));

test('the shipped sources are found', () => {
  for (const f of [
    'lib/js/default_viewport.js',
    'lib/services/webview.dart',
    'ios/Runner/AppDelegate.swift',
    'linux/my_application.cc',
  ]) assert.ok(shipped.includes(f), f);
  assert.ok(shipped.some((f) => f.startsWith('android/app/src/main/')));
});

function hits(re) {
  const out = [];
  for (const f of shipped) {
    const src = code(read(f));
    for (const m of src.matchAll(re)) out.push(`${f}:${lineAt(src, m.index)}: ${m[0]}`);
  }
  return out;
}

test('no viewport the app writes limits zoom', () => {
  assert.deepEqual(hits(/user-scalable\s*=\s*(no|0)\b|maximum-scale|minimum-scale/gi), []);
});

// A webview showing a page the app built itself, never a site's.
const OWN_PAGES = {
  'lib/widgets/virtual_source_preview.dart': 'a preview of the virtual camera clip the user picked',
};

test('every webview showing a site supports zoom', () => {
  const off = hits(/\bsupportZoom\s*[:=]\s*(?!\s|true\b)[^,;\n)]+/g)
    .filter((h) => !(h.split(':')[0] in OWN_PAGES));
  assert.deepEqual(off, []);
  const sites = hits(/\bsupportZoom\s*[:=]\s*true\b/g);
  assert.ok(sites.some((h) => h.startsWith('lib/services/webview.dart:')),
    'the site webview settings say supportZoom true');
});

test('nothing hides an element by its role or aria-* attributes', () => {
  assert.deepEqual(hits(new RegExp([
    String.raw`\[\s*(role|aria-[a-z-]+)\s*[\]=~|^$*]`,
    String.raw`setAttribute\(\s*['"](aria-hidden|role|inert)['"]`,
    String.raw`\.(ariaHidden|inert|role)\s*=[^=]`,
    String.raw`aria-hidden\s*=\s*["']?true`,
  ].join('|'), 'g')), []);
});

test('no webview ignores Smart Invert', () => {
  assert.deepEqual(hits(/accessibilityIgnoresInvertColors/g), []);
});
