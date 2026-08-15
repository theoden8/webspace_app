// Real-Chromium proof for the virtual camera shim
// (lib/services/camera_stream_shim.dart, dumped to
// test/js_fixtures/camera_stream/shim.js).
//
// The jsdom tier (test/js/camera_stream_shim.test.js) stubs canvas /
// captureStream, so it proves the decision funnel but not that the synthetic
// stream actually carries the picked image. This test runs the exact dumped
// shim in real headless Chromium and asserts a scanner can DECODE A QR CODE
// off the getUserMedia stream — the end-to-end claim the feature makes.
//
// getUserMedia needs a secure context, so the page is served from 127.0.0.1
// (a Chromium secure-context exception) rather than about:blank.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');

const SHIM = readFixture('camera_stream/shim.js');
const JSQR = fs.readFileSync(
  path.resolve(__dirname, '..', '..', 'node_modules', 'jsqr', 'dist', 'jsQR.js'),
  'utf8',
);
const QR_PAYLOAD = 'WEBSPACE-CAM-OK-42';

const browser = setupBrowser();

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<!doctype html><html><head></head><body></body></html>');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

test('virtual camera stream carries a decodable QR under real Chromium', async (t) => {
  if (!requireBrowser(browser, t)) return;

  const qrDataUrl = await require('qrcode').toDataURL(QR_PAYLOAD, {
    margin: 2,
    width: 400,
  });
  const server = await startServer();
  const { port } = server.address();
  const page = await browser.browser.newPage();

  try {
    // Bridge stub returns whatever source the page stashes (built from the
    // QR below); the dumped shim and jsQR are injected before any page load.
    await page.evaluateOnNewDocument(() => {
      window.__wsCamSource = null;
      window.flutter_inappwebview = {
        callHandler: () => Promise.resolve({
          mode: 'virtual',
          source: window.__wsCamSource,
        }),
      };
    });
    await page.evaluateOnNewDocument(SHIM);
    await page.evaluateOnNewDocument(JSQR); // sets window.jsQR
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });

    const result = await page.evaluate(async (qrUrl) => {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        return { error: 'no mediaDevices (insecure context?)' };
      }
      const loadImage = (src) => new Promise((res, rej) => {
        const im = new Image();
        im.onload = () => res(im);
        im.onerror = rej;
        im.src = src;
      });

      // Compose a 640x480 "camera frame" with the QR centered so the shim's
      // camera-style cover-fit (scale 1) leaves the whole code visible
      // instead of cropping a square out of the 4:3 frame.
      const qr = await loadImage(qrUrl);
      const src = document.createElement('canvas');
      src.width = 640; src.height = 480;
      const sctx = src.getContext('2d');
      sctx.fillStyle = '#ffffff';
      sctx.fillRect(0, 0, 640, 480);
      const s = 440;
      sctx.drawImage(qr, (640 - s) / 2, (480 - s) / 2, s, s);
      window.__wsCamSource = { kind: 'image', dataUrl: src.toDataURL('image/png') };

      // The real getUserMedia path the shim intercepts.
      const stream = await navigator.mediaDevices.getUserMedia({ video: true });
      const track = stream.getVideoTracks()[0];
      const label = track.label;
      const video = document.createElement('video');
      video.muted = true;
      video.playsInline = true;
      video.srcObject = stream;
      await video.play();

      const canvas = document.createElement('canvas');
      const decodeOnce = () => {
        const w = video.videoWidth || 640;
        const h = video.videoHeight || 480;
        canvas.width = w; canvas.height = h;
        const ctx = canvas.getContext('2d');
        ctx.drawImage(video, 0, 0, w, h);
        const img = ctx.getImageData(0, 0, w, h);
        const code = window.jsQR(img.data, w, h);
        return code ? code.data : null;
      };

      // Retry across frames: the first frame a canvas-capture <video>
      // presents can be blank before the stream commits.
      const start = performance.now();
      let decoded = null;
      while (performance.now() - start < 5000) {
        if (video.readyState >= 2 && video.videoWidth > 0) {
          decoded = decodeOnce();
          if (decoded) break;
        }
        await new Promise((r) => setTimeout(r, 100));
      }
      track.stop();
      return { decoded, label };
    }, qrDataUrl);

    assert.equal(result.error, undefined, result.error || '');
    assert.equal(result.decoded, QR_PAYLOAD,
      'a scanner must decode the picked QR off the synthetic getUserMedia stream');
    // The synthetic track presents as an ordinary camera.
    assert.equal(result.label, 'Integrated Camera');
  } finally {
    await page.close();
    server.close();
  }
});

test('a video virtual source plays and loops under real Chromium', async (t) => {
  if (!requireBrowser(browser, t)) return;

  // Single source of truth: the same committed clip the emulator tier feeds
  // the device (integration_test/fixtures/virtual_camera_video.dart).
  const fixtureSrc = fs.readFileSync(
    path.resolve(__dirname, '..', '..', 'integration_test', 'fixtures',
      'virtual_camera_video.dart'), 'utf8');
  const b64 = /'data:video\/webm;base64,'\s*'([^']+)'/.exec(fixtureSrc)[1];
  const colours = [...fixtureSrc.matchAll(/kVirtualCameraVideoColor[AB] = \[([^\]]+)\]/g)]
    .map((m) => m[1].split(',').map((n) => parseInt(n.trim(), 10)));
  assert.equal(colours.length, 2, 'fixture should declare both colours');

  const server = await startServer();
  const { port } = server.address();
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument((dataUrl) => {
      window.flutter_inappwebview = {
        callHandler: (name) => Promise.resolve(
          name === 'webCameraMode'
            ? 'virtual'
            : { mode: 'virtual', source: { kind: 'video', dataUrl } }),
      };
    }, `data:video/webm;base64,${b64}`);
    await page.evaluateOnNewDocument(SHIM);
    await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });

    const r = await page.evaluate(async () => {
      const stream = await navigator.mediaDevices.getUserMedia({ video: true });
      const video = document.createElement('video');
      video.muted = true;
      video.playsInline = true;
      video.srcObject = stream;
      await video.play();
      const canvas = document.createElement('canvas');
      const samples = [];
      const start = performance.now();
      while (performance.now() - start < 4000) {
        if (video.readyState >= 2 && video.videoWidth > 0) {
          canvas.width = video.videoWidth;
          canvas.height = video.videoHeight;
          const ctx = canvas.getContext('2d');
          ctx.drawImage(video, 0, 0);
          const d = ctx.getImageData(
            Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
          if (d[0] + d[1] + d[2] > 12) samples.push([d[0], d[1], d[2]]);
        }
        await new Promise((res) => setTimeout(res, 100));
      }
      let changes = 0;
      for (let i = 1; i < samples.length; i++) {
        const p = samples[i - 1], q = samples[i];
        if (Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) + Math.abs(p[2] - q[2]) > 40) changes++;
      }
      return { samples, changes };
    });

    const near = (a, b) => Math.abs(a - b) <= 24;
    const saw = (want) => r.samples.some(
      (p) => near(p[0], want[0]) && near(p[1], want[1]) && near(p[2], want[2]));
    assert.ok(saw(colours[0]), `clip's first colour never appeared: ${JSON.stringify(r.samples.slice(0, 6))}`);
    assert.ok(saw(colours[1]), `clip's second colour never appeared: ${JSON.stringify(r.samples.slice(0, 6))}`);
    // ~0.5s clip watched for 4s: a frozen first frame yields 0 transitions.
    assert.ok(r.changes >= 2,
      `the clip must keep looping, got ${r.changes} transitions over ${r.samples.length} samples`);
  } finally {
    await page.close();
    server.close();
  }
});
