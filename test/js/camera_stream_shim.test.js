// Tier 1 — jsdom assertions for the virtual camera shim
// (lib/services/camera_stream_shim.dart, dumped to
// test/js_fixtures/camera_stream/shim.js).
//
// jsdom has no getUserMedia, no canvas.captureStream, and no image decode,
// so we stub the minimum surface the shim wraps and assert *routing + shape*:
//   - block  -> getUserMedia rejects NotAllowedError, real camera untouched
//   - real   -> getUserMedia calls through to the platform's original
//   - virtual-> getUserMedia resolves a canvas-backed stream, real untouched
//   - audio  -> any request with audio bypasses the shim entirely
//   - enumerateDevices publishes one videoinput (label gated on a served grant)
//   - no bridge -> fail closed (block)
// Real MediaStream semantics (frame content, liveness) are NOT and cannot be
// simulated here; that is deliberate — this file guards the decision funnel.

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const SHIM = readFixture('camera_stream/shim.js');

// The virtual path arms a setInterval to keep repainting the capture canvas;
// a real page clears it on track.stop(). In jsdom the timer would keep the
// Node event loop alive past the suite, so close every dom we create.
const _openDoms = [];
afterEach(() => {
  while (_openDoms.length) {
    try { _openDoms.pop().window.close(); } catch (_) { /* already closed */ }
  }
});

// Build a jsdom realm with a fake camera surface. `decision` is what the
// webCameraRequest bridge returns; pass `noBridge: true` to omit the bridge
// entirely. Returns { dom, window, calls } where calls.realGum counts
// pass-throughs to the platform getUserMedia.
function setupCameraDom({ decision, noBridge = false } = {}) {
  const dom = makeDom();
  const window = dom.window;
  const calls = { realGum: 0, lastConstraints: null };

  // Original platform getUserMedia + enumerateDevices (what the shim wraps).
  const mediaDevices = {
    getUserMedia(constraints) {
      calls.realGum += 1;
      calls.lastConstraints = constraints;
      return Promise.resolve({ __realStream: true, getVideoTracks: () => [] });
    },
    enumerateDevices() {
      return Promise.resolve([
        { deviceId: 'real-cam', kind: 'videoinput', label: '', groupId: 'g' },
        { deviceId: 'mic', kind: 'audioinput', label: '', groupId: 'g' },
      ]);
    },
  };
  Object.defineProperty(window.navigator, 'mediaDevices', {
    value: mediaDevices,
    configurable: true,
  });

  if (!noBridge) {
    window.flutter_inappwebview = {
      callHandler(_name, _origin) {
        return Promise.resolve(decision);
      },
    };
  }

  // Image: resolve onload asynchronously so loadImage() settles.
  window.Image = class FakeImage {
    constructor() {
      this.naturalWidth = 320;
      this.naturalHeight = 240;
      this.onload = null;
      this.onerror = null;
    }
    set src(_v) {
      setTimeout(() => this.onload && this.onload(), 0);
    }
  };

  // Canvas: jsdom returns a real element but getContext('2d') is null and
  // captureStream is absent. Stub both so streamFromMedia() completes.
  const proto = window.HTMLCanvasElement.prototype;
  proto.getContext = function getContext() {
    return { drawImage() {} };
  };
  proto.captureStream = function captureStream() {
    const track = {
      kind: 'video',
      _ended: null,
      addEventListener(type, cb) {
        if (type === 'ended') this._ended = cb;
      },
      stop() {},
      getSettings() {
        return {};
      },
    };
    return { getVideoTracks: () => [track] };
  };

  runInDom(dom, SHIM);
  _openDoms.push(dom);
  return { dom, window, calls };
}

test('block decision rejects with NotAllowedError and never opens the real camera', async () => {
  const { window, calls } = setupCameraDom({ decision: { mode: 'block' } });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0);
});

test('real decision calls through to the platform getUserMedia', async () => {
  const { window, calls } = setupCameraDom({ decision: { mode: 'real' } });
  const stream = await window.navigator.mediaDevices.getUserMedia({ video: true });
  assert.equal(stream.__realStream, true);
  assert.equal(calls.realGum, 1);
});

test('virtual decision resolves a synthetic stream and never opens the real camera', async () => {
  const { window, calls } = setupCameraDom({
    decision: {
      mode: 'virtual',
      source: { kind: 'image', dataUrl: 'data:image/png;base64,AAAA' },
    },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  assert.ok(track, 'expected a synthetic video track');
  assert.equal(track.label, 'Integrated Camera');
  assert.equal(calls.realGum, 0, 'real camera must not be opened in virtual mode');
});

test('virtual mode with no source rejects rather than opening the real camera', async () => {
  const { window, calls } = setupCameraDom({
    decision: { mode: 'virtual' }, // no source
  });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0);
});

test('a request bundling audio bypasses the shim entirely', async () => {
  // Even with a virtual decision, audio+video must fall through to the
  // platform so the grant can never widen into the microphone.
  const { window, calls } = setupCameraDom({
    decision: {
      mode: 'virtual',
      source: { kind: 'image', dataUrl: 'data:image/png;base64,AAAA' },
    },
  });
  await window.navigator.mediaDevices.getUserMedia({ video: true, audio: true });
  assert.equal(calls.realGum, 1);
  assert.deepEqual(calls.lastConstraints, { video: true, audio: true });
});

test('enumerateDevices publishes one videoinput, label gated on a served grant', async () => {
  const { window } = setupCameraDom({
    decision: {
      mode: 'virtual',
      source: { kind: 'image', dataUrl: 'data:image/png;base64,AAAA' },
    },
  });
  const before = await window.navigator.mediaDevices.enumerateDevices();
  const camsBefore = before.filter((d) => d.kind === 'videoinput');
  assert.equal(camsBefore.length, 1, 'exactly one videoinput before grant');
  assert.equal(camsBefore[0].label, '', 'label blank until a stream is served');
  // Non-video devices from the platform list survive.
  assert.ok(before.some((d) => d.kind === 'audioinput'));

  await window.navigator.mediaDevices.getUserMedia({ video: true });
  const after = await window.navigator.mediaDevices.enumerateDevices();
  const camsAfter = after.filter((d) => d.kind === 'videoinput');
  assert.equal(camsAfter.length, 1);
  assert.equal(camsAfter[0].label, 'Integrated Camera',
    'label revealed after a grant, matching a real permission gate');
});

test('missing flutter_inappwebview bridge fails closed (block)', async () => {
  const { window, calls } = setupCameraDom({ noBridge: true });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0);
});

test('getUserMedia stringifies as native code', () => {
  const { window } = setupCameraDom({ decision: { mode: 'block' } });
  assert.match(window.navigator.mediaDevices.getUserMedia.toString(), /\[native code\]/);
});

test('shim is idempotent (guards against double injection)', () => {
  const { window } = setupCameraDom({ decision: { mode: 'block' } });
  const first = window.navigator.mediaDevices.getUserMedia;
  runInDom({ window }, SHIM); // second injection is a no-op
  assert.equal(window.navigator.mediaDevices.getUserMedia, first);
});
