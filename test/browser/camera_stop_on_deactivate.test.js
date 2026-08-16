// Real-Chromium proof for CAM-012: when the site stops being the one on
// screen, the device camera stops, and the simulated camera does not.
//
// The jsdom tier (test/js/camera_stream_shim.test.js) drives the same hook,
// but its MediaStreamTrack is a stub whose stop() is whatever the test says it
// is. Only a real engine can show a genuine device track transitioning to
// readyState 'ended' with its live frames gone, and a canvas-backed track
// surviving the same call. Chromium's fake device stands in for the camera
// (--use-fake-device-for-media-stream), which is what makes a real grant
// possible on a headless runner at all.
//
// getUserMedia needs a secure context, so the page is served from 127.0.0.1.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');

const SHIM = readFixture('camera_stream/shim.js');

// The virtual source is painted in-page (below) rather than pasted in as a
// base64 blob, so its colour is known and opaque: a transparent fixture would
// make "still delivering frames" indistinguishable from "delivering nothing".
const SOURCE_RGB = [30, 200, 122];

const browser = setupBrowser({
  args: [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    // Grant + synthesise a camera so `mode: 'real'` can actually resolve.
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

// Loads a page with the dumped shim installed and the bridge answering
// `decision`, exactly as the Dart handler would. A `virtual` decision picks up
// whatever source the page stashes in `__wsCamSource`.
async function openPage(port, decision) {
  const page = await browser.browser.newPage();
  await page.evaluateOnNewDocument((d) => {
    window.__wsCamSource = null;
    window.flutter_inappwebview = {
      callHandler: (name) =>
        Promise.resolve(
          name === 'webCameraMode'
            ? d.mode
            : { ...d, source: window.__wsCamSource || d.source },
        ),
    };
  }, decision);
  await page.evaluateOnNewDocument(SHIM);
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'domcontentloaded' });
  return page;
}

test('deactivation ends a real camera track and spares the simulated one', async (t) => {
  if (!requireBrowser(browser, t)) return;

  const server = await startServer();
  const { port } = server.address();

  try {
    const realPage = await openPage(port, { mode: 'real' });
    const real = await realPage.evaluate(async () => {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true });
      const track = stream.getVideoTracks()[0];
      const before = track.readyState;
      const ended = await new Promise((resolve) => {
        track.addEventListener('ended', () => resolve(true));
        // The event is the page-observable half of the claim; the readyState
        // below is the state half. Don't hang the suite if it never fires.
        setTimeout(() => resolve(false), 2000);
        window.__wsStopRealCapture();
      });
      return { before, after: track.readyState, ended, kind: track.kind };
    });
    assert.equal(real.kind, 'video');
    assert.equal(real.before, 'live', 'the fake device must hand out a live track');
    assert.equal(real.after, 'ended', 'a device track must end on deactivation');
    await realPage.close();

    const virtualPage = await openPage(port, { mode: 'virtual' });
    const virtual = await virtualPage.evaluate(async (rgb) => {
      const src = document.createElement('canvas');
      src.width = 64;
      src.height = 48;
      const sctx = src.getContext('2d');
      sctx.fillStyle = `rgb(${rgb[0]},${rgb[1]},${rgb[2]})`;
      sctx.fillRect(0, 0, src.width, src.height);
      window.__wsCamSource = { kind: 'image', dataUrl: src.toDataURL('image/png') };

      const stream = await navigator.mediaDevices.getUserMedia({ video: true });
      const track = stream.getVideoTracks()[0];
      const stopped = window.__wsStopRealCapture();
      // Frames must still arrive afterwards: a track that is 'live' but no
      // longer painted would pass a readyState check and still be dead.
      const canvas = document.createElement('canvas');
      canvas.width = 32;
      canvas.height = 32;
      const video = document.createElement('video');
      video.muted = true;
      video.playsInline = true;
      video.srcObject = stream;
      await video.play();
      await new Promise((r) => setTimeout(r, 300));
      const ctx = canvas.getContext('2d');
      ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
      const px = ctx.getImageData(16, 16, 1, 1).data;
      return {
        stopped,
        state: track.readyState,
        px: [px[0], px[1], px[2]],
      };
    }, SOURCE_RGB);
    assert.equal(virtual.stopped, 0, 'nothing device-backed to end');
    assert.equal(virtual.state, 'live', 'the simulated camera must keep running');
    const near = (a, b) => Math.abs(a - b) <= 8;
    assert.ok(
      virtual.px.every((v, i) => near(v, SOURCE_RGB[i])),
      `frames must still carry the picked image after the stop; got ${virtual.px}`,
    );
    await virtualPage.close();
  } finally {
    server.close();
  }
});
