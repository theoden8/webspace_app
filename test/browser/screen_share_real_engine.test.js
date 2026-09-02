// Real-Chromium proof for the simulated screen-sharing shim
// (lib/services/screen_share_shim.dart, dumped to
// test/js_fixtures/screen_share/shim.js).
//
// The jsdom tier (test/js/screen_share_shim.test.js) stubs canvas /
// captureStream, so it proves the decision funnel but not that the served
// stream actually carries the picked surface. It also cannot prove the thing
// that matters most here: that the override wins over a REAL engine
// getDisplayMedia. Chromium has one; jsdom does not.
//
// getDisplayMedia needs a secure context, so the page is served from
// 127.0.0.1 (a Chromium secure-context exception) rather than about:blank.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');

const SHIM = readFixture('screen_share/shim.js');

// A surface the test can recognise pixel-by-pixel: solid, unmistakable, and
// nothing a real screen capture of a blank page would ever produce.
const SURFACE_RGB = [0, 128, 255];

const browser = setupBrowser();

function startServer(html) {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(html ?? '<!doctype html><html><head></head><body></body></html>');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// Installs the bridge stub + the dumped shim before any document loads.
async function armPage(page, decisionFactory) {
  await page.evaluateOnNewDocument((rgb) => {
    window.__wsSurface = null;
    window.__wsBridgeCalls = 0;
    window.flutter_inappwebview = {
      callHandler: (name) => {
        window.__wsBridgeCalls += 1;
        window.__wsLastHandler = name;
        return Promise.resolve(window.__wsDecision ?? { mode: 'block' });
      },
    };
    window.__wsSurfaceRgb = rgb;
  }, SURFACE_RGB);
  if (decisionFactory) await page.evaluateOnNewDocument(decisionFactory);
  await page.evaluateOnNewDocument(SHIM);
}

// Paints a solid canvas and hands back its data: URL, so the served frames
// have a known colour.
const MAKE_SURFACE = `
  window.__wsMakeSurface = function (w, h) {
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const ctx = c.getContext('2d');
    const [r, g, b] = window.__wsSurfaceRgb;
    ctx.fillStyle = 'rgb(' + r + ',' + g + ',' + b + ')';
    ctx.fillRect(0, 0, w, h);
    return { kind: 'image', dataUrl: c.toDataURL('image/png') };
  };
`;

// Reads one frame off a stream into a canvas and returns its centre pixel.
// Retried across frames: the first frame a canvas-capture <video> presents
// can be blank before the stream commits.
const SAMPLE_STREAM = `
  window.__wsSample = async function (stream) {
    const video = document.createElement('video');
    video.muted = true;
    video.playsInline = true;
    video.srcObject = stream;
    await video.play();
    const canvas = document.createElement('canvas');
    const start = performance.now();
    while (performance.now() - start < 5000) {
      if (video.readyState >= 2 && video.videoWidth > 0) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0);
        const px = ctx.getImageData(
          Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
        if (px[3] !== 0) {
          return { rgb: [px[0], px[1], px[2]],
                   width: video.videoWidth, height: video.videoHeight };
        }
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    return { rgb: null };
  };
`;

test('a virtual grant serves the picked surface under real Chromium',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const server = await startServer();
    const { port } = server.address();
    const page = await browser.browser.newPage();
    try {
      await armPage(page);
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
      await page.evaluate(MAKE_SURFACE);
      await page.evaluate(SAMPLE_STREAM);

      const result = await page.evaluate(async () => {
        window.__wsDecision = {
          mode: 'virtual',
          source: window.__wsMakeSurface(1280, 720),
        };
        const stream = await navigator.mediaDevices.getDisplayMedia({
          video: true,
        });
        const track = stream.getVideoTracks()[0];
        const settings = track.getSettings();
        const sampled = await window.__wsSample(stream);
        const out = {
          label: track.label,
          kind: track.kind,
          constructorName: track.constructor.name,
          ownProps: Object.getOwnPropertyNames(track),
          audioTracks: stream.getAudioTracks().length,
          displaySurface: settings.displaySurface,
          cursor: settings.cursor,
          logicalSurface: settings.logicalSurface,
          settingsWidth: settings.width,
          ...sampled,
        };
        track.stop();
        return out;
      });

      assert.deepEqual(result.rgb, SURFACE_RGB,
        'the served frames must carry the picked surface, not a real screen');
      assert.equal(result.width, 1280);
      assert.equal(result.height, 720);
      assert.equal(result.settingsWidth, 1280);
      // Presents as an ordinary display capture, not as a canvas track.
      assert.equal(result.label, 'Screen');
      assert.equal(result.kind, 'video');
      assert.equal(result.constructorName, 'MediaStreamTrack',
        'Chromium hands a canvas capture a CanvasCaptureMediaStreamTrack; the '
        + 'shim must re-point the prototype so the class does not betray it');
      assert.deepEqual(result.ownProps, [],
        'overrides must live on the prototype, not as own properties');
      assert.equal(result.displaySurface, 'monitor');
      assert.equal(result.cursor, 'never');
      assert.equal(result.logicalSurface, true);
      assert.equal(result.audioTracks, 0,
        'system audio capture must be impossible by construction');
    } finally {
      await page.close();
      server.close();
    }
  });

test("the engine's own getDisplayMedia is unreachable once the shim is in",
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    // The point of the tier: Chromium HAS a getDisplayMedia, and a `block`
    // decision must reject rather than fall through to it. Under jsdom this
    // could only be checked against a stub.
    const server = await startServer();
    const { port } = server.address();
    const page = await browser.browser.newPage();
    try {
      await armPage(page);
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
      const result = await page.evaluate(async () => {
        window.__wsDecision = { mode: 'block' };
        try {
          await navigator.mediaDevices.getDisplayMedia({ video: true });
          return { rejected: false };
        } catch (e) {
          return { rejected: true, name: e.name, bridge: window.__wsBridgeCalls };
        }
      });
      assert.equal(result.rejected, true);
      assert.equal(result.name, 'NotAllowedError',
        'a blocked site must see what a dismissed browser picker looks like');
      assert.equal(result.bridge, 1);
    } finally {
      await page.close();
      server.close();
    }
  });

test('a cross-origin iframe cannot obtain the surface (SHARE-005)',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    // The shim ships forMainFrameOnly:true, so in production a subframe never
    // receives it. This proves the second layer: even injected everywhere,
    // the shim refuses a frame — and refuses it without touching the bridge,
    // so the frame cannot raise a popup in the host site's name either.
    const frameServer = await startServer(
      '<!doctype html><html><head></head><body>frame</body></html>');
    const framePort = frameServer.address().port;
    const server = await startServer(
      `<!doctype html><html><head></head><body>`
      + `<iframe src="http://localhost:${framePort}/"></iframe></body></html>`);
    const { port } = server.address();
    const page = await browser.browser.newPage();
    try {
      await armPage(page);
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
      // 127.0.0.1 vs localhost are different origins to the same server.
      const frame = page.frames().find((f) => f !== page.mainFrame());
      assert.ok(frame, 'expected the cross-origin child frame');

      const result = await frame.evaluate(async () => {
        window.__wsDecision = { mode: 'virtual', source: { kind: 'image', dataUrl: 'data:image/png;base64,QUJD' } };
        try {
          await navigator.mediaDevices.getDisplayMedia({ video: true });
          return { rejected: false };
        } catch (e) {
          return { rejected: true, name: e.name, bridge: window.__wsBridgeCalls };
        }
      });
      assert.equal(result.rejected, true,
        'a third-party frame must not be served the surface the user granted '
        + 'the host site');
      assert.equal(result.name, 'NotAllowedError');
      assert.equal(result.bridge, 0,
        'the frame must not even be able to raise the popup');

      // The top-level document still works, so the deny is about the frame
      // rather than a shim that failed to install.
      await page.evaluate(MAKE_SURFACE);
      const top = await page.evaluate(async () => {
        window.__wsDecision = {
          mode: 'virtual',
          source: window.__wsMakeSurface(320, 240),
        };
        const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
        const n = stream.getVideoTracks().length;
        stream.getVideoTracks()[0].stop();
        return n;
      });
      assert.equal(top, 1);
    } finally {
      await page.close();
      server.close();
      frameServer.close();
    }
  });

test('the shim does not answer a page it was never asked to serve', async (t) => {
  if (!requireBrowser(browser, t)) return;
  // getUserMedia is another shim's business. Installing the screen-share shim
  // must not disturb it, or a camera request would start resolving here.
  const server = await startServer();
  const { port } = server.address();
  const page = await browser.browser.newPage();
  try {
    await armPage(page);
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
    const untouched = await page.evaluate(() => {
      const d = Object.getOwnPropertyDescriptor(
        MediaDevices.prototype, 'getUserMedia');
      return {
        present: typeof navigator.mediaDevices.getUserMedia === 'function',
        native: /\[native code\]/.test(String(d.value)),
        enumerateNative: /\[native code\]/.test(
          String(MediaDevices.prototype.enumerateDevices)),
      };
    });
    assert.equal(untouched.present, true);
    assert.equal(untouched.native, true,
      'getUserMedia must be the engine\'s own, unwrapped by this shim');
    assert.equal(untouched.enumerateNative, true,
      'a display capture never appears in enumerateDevices, so the shim has '
      + 'no business patching it');
  } finally {
    await page.close();
    server.close();
  }
});
