// Real-Chromium proof that the deactivation stop splits a MIXED stream
// (CAM-012 / MIC-012).
//
// The camera's own browser tier is video-only: it proves a device camera track
// ends and a canvas-backed one survives, and never requests audio at all. That
// was fine while audio had no device half. It no longer is: one hook over one
// shared registry (lib/services/capture_track_registry.dart) now covers both
// shims, and the case it can get wrong is a stream carrying one track of each
// kind, where exactly one of them must end.
//
// Both injection orders run, because that is the hazard the shared registry
// exists for. Whichever shim installs the hook owns it for both, and a shim
// that installed its own would silently take over depending only on the order
// webview.dart happens to add the user scripts.
//
// Chromium's fake devices stand in for the microphone and camera
// (--use-fake-device-for-media-stream); getUserMedia needs a secure context,
// so the page is served from 127.0.0.1.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');

const CAMERA_SHIM = readFixture('camera_stream/shim.js');
const MICROPHONE_SHIM = readFixture('microphone_stream/shim.js');

// 1x1 opaque PNG, enough for the camera shim to paint a canvas track.
const IMAGE_DATA_URL = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB'
  + 'CAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';

const browser = setupBrowser({
  args: [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--use-fake-device-for-media-stream',
    '--use-fake-ui-for-media-stream',
  ],
});

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<!doctype html><html><head></head><body></body></html>');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// A site with `microphoneMode == real` and `cameraMode == virtual`: the audio
// half comes from the device, the video half from a picked file. `order` names
// which shim is injected last, i.e. which one wraps the other.
async function openPage(port, order) {
  const page = await browser.browser.newPage();
  await page.evaluateOnNewDocument((image) => {
    window.flutter_inappwebview = {
      callHandler: (name) => {
        switch (name) {
          case 'webMicrophoneMode': return Promise.resolve('real');
          case 'webMicrophoneRequest': return Promise.resolve({ mode: 'real' });
          case 'webCameraMode': return Promise.resolve('virtual');
          default: return Promise.resolve({
            mode: 'virtual',
            source: { kind: 'image', dataUrl: image },
          });
        }
      },
    };
  }, IMAGE_DATA_URL);
  const shims = order === 'microphone last'
    ? [CAMERA_SHIM, MICROPHONE_SHIM]
    : [MICROPHONE_SHIM, CAMERA_SHIM];
  for (const shim of shims) await page.evaluateOnNewDocument(shim);
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'domcontentloaded' });
  return page;
}

for (const order of ['microphone last', 'camera last']) {
  test(`the stop ends the device audio and spares the simulated video (${order})`,
    async (t) => {
      if (!requireBrowser(browser, t)) return;
      const server = await startServer();
      const page = await openPage(server.address().port, order);
      try {
        const r = await page.evaluate(async () => {
          const stream = await navigator.mediaDevices.getUserMedia({
            audio: true, video: true,
          });
          const audio = stream.getAudioTracks()[0];
          const video = stream.getVideoTracks()[0];
          const before = { audio: audio.readyState, video: video.readyState };
          const stopped = globalThis.__wsStopRealCapture();
          return {
            before,
            stopped,
            after: { audio: audio.readyState, video: video.readyState },
          };
        });

        assert.deepEqual(r.before, { audio: 'live', video: 'live' },
          'both halves must be live before the stop');
        assert.equal(r.stopped, 1,
          'exactly the device audio track is ended, and it is counted once');
        assert.equal(r.after.audio, 'ended',
          'the device microphone must be released when the site leaves the screen');
        assert.equal(r.after.video, 'live',
          'the simulated camera is a local file on a canvas: ending it would '
            + 'drop a half-finished scan the user comes back to');
      } finally {
        await page.close();
        server.close();
      }
    });
}

test('a second stop is a no-op once the device half is already ended',
  async (t) => {
    // The hook is called on every deactivation, and a site can be switched
    // away from twice without capturing in between. A registry that kept dead
    // refs would report a phantom stop each time.
    if (!requireBrowser(browser, t)) return;
    const server = await startServer();
    const page = await openPage(server.address().port, 'microphone last');
    try {
      const r = await page.evaluate(async () => {
        await navigator.mediaDevices.getUserMedia({ audio: true, video: true });
        return [
          globalThis.__wsStopRealCapture(),
          globalThis.__wsStopRealCapture(),
        ];
      });
      assert.deepEqual(r, [1, 0]);
    } finally {
      await page.close();
      server.close();
    }
  });
