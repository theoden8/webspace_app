// Real-Chromium proof for the screen-sharing shim (lib/js/screen_share.js).
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
const CAPTURE = require('../js/helpers/capture_shims');
const { setupBrowser, requireBrowser } = require('./helpers/launch');
const { startBlankServer } = require('./helpers/blank_server');

const SHIM = CAPTURE.SCREEN_SHARE;

// A surface the test can recognise pixel-by-pixel: solid, unmistakable, and
// nothing a real screen capture of a blank page would ever produce.
const SURFACE_RGB = [0, 128, 255];

const browser = setupBrowser();

// Installs the bridge stub + the shim before any document loads.
async function armPage(page, decisionFactory) {
  await page.evaluateOnNewDocument((rgb) => {
    window.__wsSurface = null;
    window.__wsBridgeCalls = 0;
    window.flutter_inappwebview = {
      callHandler: (name, arg) => {
        window.__wsBridgeCalls += 1;
        window.__wsLastHandler = name;
        const share = window.__wsShare;
        if (share && name in share) return Promise.resolve(share[name](arg));
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
function makeSurface() {
  window.__wsMakeSurface = function (w, h) {
    const c = document.createElement('canvas');
    c.width = w; c.height = h;
    const ctx = c.getContext('2d');
    const [r, g, b] = window.__wsSurfaceRgb;
    ctx.fillStyle = 'rgb(' + r + ',' + g + ',' + b + ')';
    ctx.fillRect(0, 0, w, h);
    return { kind: 'image', dataUrl: c.toDataURL('image/png') };
  };
}

// Reads one frame off a stream into a canvas and returns its centre pixel.
// Retried across frames: the first frame a canvas-capture <video> presents
// can be blank before the stream commits.
function sampleStream() {
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
}

test('a virtual grant serves the picked surface under real Chromium (SHARE-008)',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const server = await startBlankServer();
    const { port } = server.address();
    const page = await browser.browser.newPage();
    try {
      await armPage(page);
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
      await page.evaluate(makeSurface);
      await page.evaluate(sampleStream);

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

test("a real grant serves Android's frames under real Chromium (SHARE-018)",
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    // Android WebView has no display capture, so the shim draws the frames
    // Android shares with the app onto a canvas. This proves the pixels a
    // pulled JPEG carries are the pixels the page's track carries, and that
    // the deactivation stop ends it as a device capture (SHARE-017).
    const server = await startBlankServer();
    const { port } = server.address();
    const page = await browser.browser.newPage();
    try {
      await armPage(page);
      await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
      await page.evaluate(sampleStream);
      const result = await page.evaluate(async () => {
        const c = document.createElement('canvas');
        c.width = 320; c.height = 240;
        const ctx = c.getContext('2d');
        const [r, g, b] = window.__wsSurfaceRgb;
        ctx.fillStyle = 'rgb(' + r + ',' + g + ',' + b + ')';
        ctx.fillRect(0, 0, 320, 240);
        const jpeg = c.toDataURL('image/jpeg', 0.95).split(',')[1];
        const seen = { pulls: [], stops: 0 };
        window.__wsDecision = { mode: 'real' };
        window.__wsShare = {
          webScreenShareStart: () => ({ width: 320, height: 240 }),
          webScreenShareFrame: (after) => {
            seen.pulls.push(after);
            return after < 1 ? { seq: 1, jpeg } : new Promise(() => {});
          },
          webScreenShareStop: () => { seen.stops += 1; return null; },
        };
        const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
        const track = stream.getVideoTracks()[0];
        const sampled = await window.__wsSample(stream);
        const stopped = window.__wsStopRealCapture();
        return {
          ...sampled,
          constructorName: track.constructor.name,
          label: track.label,
          stopped,
          readyState: track.readyState,
          pulls: seen.pulls,
        };
      });
      assert.ok(result.rgb, 'the track must carry a frame');
      result.rgb.forEach((v, i) => assert.ok(Math.abs(v - SURFACE_RGB[i]) <= 8,
        `channel ${i}: ${v} is not the shared frame's ${SURFACE_RGB[i]}`));
      assert.equal(result.width, 320);
      assert.equal(result.height, 240);
      assert.equal(result.constructorName, 'MediaStreamTrack');
      assert.equal(result.label, 'Screen');
      assert.deepEqual(result.pulls, [0, 1]);
      assert.equal(result.stopped, 1,
        'the real screen is a device capture: the deactivation stop ends it');
      assert.equal(result.readyState, 'ended');
    } finally {
      await page.close();
      server.close();
    }
  });

test('a hidden page still sends the frames it pulls (SHARE-020)', async (t) => {
  if (!requireBrowser(browser, t)) return;
  // The share is for showing other apps, so the page is hidden while it
  // runs. Frames arrive as bridge replies, not timers, and the canvas track
  // must carry one delivered while the page is hidden. Read through a
  // MediaStreamTrackProcessor, which needs no rendering of its own.
  const server = await startBlankServer();
  const { port } = server.address();
  const page = await browser.browser.newPage();
  const other = await browser.browser.newPage();
  try {
    await armPage(page);
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
    await page.bringToFront();
    await page.evaluate(async () => {
      const jpeg = (rgb) => {
        const c = document.createElement('canvas');
        c.width = 64; c.height = 64;
        const ctx = c.getContext('2d');
        ctx.fillStyle = 'rgb(' + rgb + ')';
        ctx.fillRect(0, 0, 64, 64);
        return c.toDataURL('image/jpeg', 0.95).split(',')[1];
      };
      window.__wsJpeg = { red: jpeg('255,0,0'), blue: jpeg('0,0,255') };
      window.__wsPulls = [];
      window.__wsDecision = { mode: 'real' };
      window.__wsShare = {
        webScreenShareStart: () => ({ width: 64, height: 64 }),
        webScreenShareFrame: () => new Promise((r) => window.__wsPulls.push(r)),
      };
      const stream = await navigator.mediaDevices.getDisplayMedia({ video: true });
      const reader = new MediaStreamTrackProcessor({ track: stream.getVideoTracks()[0] })
        .readable.getReader();
      window.__wsGot = [];
      (async () => {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) return;
          const c = new OffscreenCanvas(1, 1).getContext('2d');
          c.drawImage(await createImageBitmap(value), 0, 0, 1, 1);
          const d = c.getImageData(0, 0, 1, 1).data;
          window.__wsGot.push({ rgb: [d[0], d[1], d[2]], seen: document.visibilityState });
          value.close();
        }
      })();
    });
    const deliver = (colour, seq) => page.evaluate((colour, seq) => {
      const pull = window.__wsPulls.shift();
      if (pull) pull({ seq, jpeg: window.__wsJpeg[colour] });
      return !!pull;
    }, colour, seq);
    const settle = () => new Promise((r) => setTimeout(r, 600));
    await settle();
    assert.ok(await deliver('red', 1));
    await settle();
    await other.bringToFront();
    await settle();
    assert.equal(await page.evaluate(() => document.visibilityState), 'hidden');
    assert.ok(await deliver('blue', 2));
    await settle();
    const got = await page.evaluate(() => window.__wsGot);
    const last = got[got.length - 1];
    assert.ok(last, 'the track must carry frames');
    assert.equal(last.seen, 'hidden');
    assert.ok(last.rgb[2] > 200 && last.rgb[0] < 40,
      `the frame delivered while hidden must reach the track: ${JSON.stringify(last.rgb)}`);
  } finally {
    await other.close();
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
    const server = await startBlankServer();
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
    const frameServer = await startBlankServer(
      '<!doctype html><html><head></head><body>frame</body></html>');
    const framePort = frameServer.address().port;
    const server = await startBlankServer(
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
      await page.evaluate(makeSurface);
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
  const server = await startBlankServer();
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
