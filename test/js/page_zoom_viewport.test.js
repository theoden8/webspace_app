// Behavioural tests for the mobile page-zoom shim
// (lib/services/page_zoom_shim.dart).
//
// The shim owns `<meta name="viewport">` on Android and iOS. jsdom has no
// layout, so these assert the *emitted directives* — which is where
// BUG-008 keeps recurring: a viewport meta that names a scale but no
// width makes Android System WebView swap the layout width for its 980px
// UA fallback (PageScaleConstraintsSet::AdjustForAndroidWebViewQuirks),
// serving every site its desktop layout at any zoom other than 100%.
//
// The other half of the contract is where the width comes from. Anything
// the page can see is either spoofed by the anti-fingerprinting shim
// (screen.*) or already moved by the zoom itself (innerWidth), so the
// fixtures carry Flutter's view extents and sample innerWidth exactly
// once. These tests pin both halves.

const test = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

// The view extents baked into the fixtures (Pixel 5 shaped).
const PORTRAIT = 393;
const LANDSCAPE = 851;

const withViewport = (content) =>
  `<!doctype html><html><head>
    <meta name="viewport" content="${content}">
  </head><body></body></html>`;

// jsdom's window is 1024x768, i.e. landscape by its own metrics. The shim
// asks matchMedia for the orientation, and jsdom's stub answers false for
// every query, so fixtures resolve to the portrait extent unless a test
// says otherwise.
function setOrientation(dom, landscape) {
  const real = dom.window.matchMedia;
  dom.window.matchMedia = (query) => {
    if (/orientation:\s*landscape/i.test(query)) {
      return { matches: landscape, media: query, addListener() {}, removeListener() {},
        addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; } };
    }
    return real ? real.call(dom.window, query) : { matches: false, media: query };
  };
}

function runZoomShim(fixture, { html, landscape = false, innerWidth } = {}) {
  const dom = makeDom({ html });
  setOrientation(dom, landscape);
  if (innerWidth !== undefined) {
    Object.defineProperty(dom.window, 'innerWidth', {
      value: innerWidth,
      configurable: true,
      writable: true,
    });
  }
  runInDom(dom, readFixture(fixture));
  return dom;
}

function viewportContent(dom) {
  const meta = dom.window.document.querySelector('meta[name="viewport"]');
  assert.ok(meta, 'expected a viewport meta');
  return meta.getAttribute('content');
}

// deviceWidth / zoom, the layout width a desktop browser reflows into.
const layoutWidth = (scale, deviceWidth) => Math.floor(deviceWidth / scale);

// The view extent, unless the one-shot innerWidth sample saw a smaller box.
const expectedBase = (dom, extent = PORTRAIT) =>
  Math.min(extent, dom.window.innerWidth);

test('Android: page-shipped width=device-width becomes an explicit layout width', () => {
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width, initial-scale=1'),
    innerWidth: PORTRAIT,
  });
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
});

test('Android: the emitted meta always names a width (980px quirk guard)', () => {
  // The regression this guards: `initial-scale=z` with no width. Any
  // future edit that drops the width directive on Android puts every
  // zoomed site back on the 980px desktop layout.
  for (const fixture of [
    'page_zoom/android_80.js',
    'page_zoom/android_150.js',
    'page_zoom/android_80_no_extents.js',
  ]) {
    const dom = runZoomShim(fixture, {
      html: withViewport('width=device-width, initial-scale=1'),
    });
    assert.match(
      viewportContent(dom),
      /^width=\d+,\s*initial-scale=/,
      `${fixture} must pin a numeric layout width`,
    );
  }
});

test('Android: zoom above 100% narrows the layout width', () => {
  const dom = runZoomShim('page_zoom/android_150.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(1.5, PORTRAIT)}, initial-scale=1.5`,
  );
  assert.ok(layoutWidth(1.5, PORTRAIT) < PORTRAIT);
});

test('WebKit: scale only, so the engine resolves extend-to-zoom itself', () => {
  // WKWebView has no wide-viewport quirk and sizes the layout against the
  // real WebView (split view, Stage Manager), which no page-visible width
  // tracks. Leaving width out keeps that engine-side.
  const dom = runZoomShim('page_zoom/webkit_80.js', {
    html: withViewport('width=device-width, initial-scale=1'),
  });
  assert.equal(viewportContent(dom), 'initial-scale=0.8');
});

test('a page shipping no viewport meta gets one injected', () => {
  const dom = runZoomShim('page_zoom/android_80.js', { innerWidth: PORTRAIT });
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
});

test('viewport meta added later is rewritten via MutationObserver', async () => {
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  const meta = dom.window.document.createElement('meta');
  meta.setAttribute('name', 'viewport');
  meta.setAttribute('content', 'width=device-width, initial-scale=1');
  dom.window.document.head.appendChild(meta);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(
    meta.getAttribute('content'),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
});

test('a physically smaller box (letterbox, split screen) wins over the extent', () => {
  // Letterbox mode resizes the WebView itself, so the view extent is too
  // wide. The one-shot innerWidth sample is the only thing that sees it.
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: 300,
  });
  assert.equal(viewportContent(dom), `width=${layoutWidth(0.8, 300)}, initial-scale=0.8`);
});

test('a box wider than the view extent does not widen the layout', () => {
  // innerWidth reads deviceWidth/z once our own scale is in effect. If a
  // stale one leaked into the sample, the extent must still cap it —
  // otherwise every navigation would zoom further out.
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: 4096,
  });
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
});

test('repeated resizes do not compound the zoom', () => {
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  const first = viewportContent(dom);
  for (let i = 0; i < 3; i += 1) {
    // What a real engine does after the meta lands: innerWidth becomes the
    // zoomed visual viewport.
    dom.window.innerWidth = Math.round(PORTRAIT / 0.8);
    dom.window.dispatchEvent(new dom.window.Event('resize'));
  }
  assert.equal(viewportContent(dom), first);
});

test('rotation re-pins against the landscape extent', () => {
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
  setOrientation(dom, true);
  dom.window.dispatchEvent(new dom.window.Event('orientationchange'));
  // The portrait sample must not follow the device into landscape.
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, LANDSCAPE)}, initial-scale=0.8`,
  );
});

test('without view extents the innerWidth sample carries the pin', () => {
  const dom = runZoomShim('page_zoom/android_80_no_extents.js', {
    html: withViewport('width=device-width'),
    innerWidth: 360,
  });
  assert.equal(viewportContent(dom), `width=${layoutWidth(0.8, 360)}, initial-scale=0.8`);
});

test('a pin wider than the WebView is snapped back after layout', () => {
  // The view extents describe the window, not the box: letterbox mode and
  // split screen make the WebView narrower. Once the page has laid out the
  // engine reports the box as the visual viewport, and a layout viewport
  // wider than it means the pin overshot.
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
  // What a real engine reports for a 320px box at this scale.
  dom.window.visualViewport = { width: 400 };
  Object.defineProperty(dom.window.document.documentElement, 'clientWidth', {
    value: layoutWidth(0.8, PORTRAIT),
    configurable: true,
  });
  dom.window.dispatchEvent(new dom.window.Event('load'));
  assert.equal(viewportContent(dom), 'width=400, initial-scale=0.8');
});

test('the snap stops once the layout viewport fits the box', () => {
  const dom = runZoomShim('page_zoom/android_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  const pinned = layoutWidth(0.8, PORTRAIT);
  dom.window.visualViewport = { width: pinned };
  Object.defineProperty(dom.window.document.documentElement, 'clientWidth', {
    value: pinned,
    configurable: true,
  });
  dom.window.dispatchEvent(new dom.window.Event('load'));
  assert.equal(viewportContent(dom), `width=${pinned}, initial-scale=0.8`);
});

test('WebKit is never snapped: it owns its own layout width', () => {
  const dom = runZoomShim('page_zoom/webkit_80.js', {
    html: withViewport('width=device-width'),
    innerWidth: PORTRAIT,
  });
  dom.window.visualViewport = { width: 400 };
  Object.defineProperty(dom.window.document.documentElement, 'clientWidth', {
    value: 490,
    configurable: true,
  });
  dom.window.dispatchEvent(new dom.window.Event('load'));
  assert.equal(viewportContent(dom), 'initial-scale=0.8');
});

test('screen.width is never read: the AFP shim owns it', () => {
  // Tracking Protection redefines Screen.prototype.width (pinned 1920, or
  // mirrored to innerWidth in letterbox mode) and is injected first. A
  // width derived from it would compound on every re-application.
  const dom = makeDom({ html: withViewport('width=device-width') });
  setOrientation(dom, false);
  Object.defineProperty(dom.window.screen, 'width', {
    value: 1920,
    configurable: true,
  });
  Object.defineProperty(dom.window, 'innerWidth', {
    value: PORTRAIT,
    configurable: true,
    writable: true,
  });
  runInDom(dom, readFixture('page_zoom/android_80.js'));
  assert.equal(
    viewportContent(dom),
    `width=${layoutWidth(0.8, PORTRAIT)}, initial-scale=0.8`,
  );
  assert.doesNotMatch(
    readFixture('page_zoom/android_80.js'),
    /(window|globalThis)\s*\.\s*screen|\bScreen\s*\.\s*prototype|[^a-z]screen\s*\.\s*(width|height|avail)/,
  );
});

test('the emitted width never exceeds the box it has to fit', () => {
  // Overshooting is the one direction the engine cannot repair: an
  // under-estimate is raised back to extend-to-zoom, an over-estimate
  // pushes content off-screen.
  for (const inner of [200, 320, 393, 800, 4096]) {
    const dom = runZoomShim('page_zoom/android_80.js', {
      html: withViewport('width=device-width'),
      innerWidth: inner,
    });
    const width = Number(/^width=(\d+)/.exec(viewportContent(dom))[1]);
    assert.ok(
      width <= Math.ceil(expectedBase(dom) / 0.8),
      `innerWidth ${inner}: pinned ${width}`,
    );
  }
});
