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
function setupCameraDom({ decision, mode, noBridge = false, realCameras = [] } = {}) {
  const dom = makeDom();
  const window = dom.window;
  const calls = { realGum: 0, lastConstraints: null };

  // Model the real interface, not a convenience stub: browsers expose these
  // as MediaDevices.prototype methods, and the shim deliberately patches the
  // prototype (patching the instance would leak own-properties a
  // fingerprinter reads). A plain object literal would exercise a code path
  // production never takes.
  class MediaDevices {
    getUserMedia(constraints) {
      calls.realGum += 1;
      calls.lastConstraints = constraints;
      return Promise.resolve({ __realStream: true, getVideoTracks: () => [] });
    }
    enumerateDevices() {
      return Promise.resolve([
        ...realCameras,
        { deviceId: 'mic', kind: 'audioinput', label: '', groupId: 'g' },
      ]);
    }
  }
  window.MediaDevices = MediaDevices;
  const mediaDevices = new MediaDevices();

  // Likewise for tracks: label/getSettings/stop live on the prototype.
  class MediaStreamTrack {
    constructor() { this.kind = 'video'; this._ended = null; }
    get label() { return ''; }
    getSettings() { return {}; }
    stop() {}
    addEventListener(type, cb) { if (type === 'ended') this._ended = cb; }
  }
  window.MediaStreamTrack = MediaStreamTrack;
  calls.MediaStreamTrack = MediaStreamTrack;
  Object.defineProperty(window.navigator, 'mediaDevices', {
    value: mediaDevices,
    configurable: true,
  });

  if (!noBridge) {
    window.flutter_inappwebview = {
      callHandler(name, _arg) {
        // Non-prompting mode read used by enumerateDevices; the decision
        // handler is the prompting one.
        if (name === 'webCameraMode') {
          return Promise.resolve(mode ?? (decision && decision.mode) ?? 'block');
        }
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
  // Video source: jsdom won't decode a data: URL, so hand back a fake
  // <video> that fires oncanplay and records the flags the shim sets. Real
  // <canvas> creation is delegated to jsdom so the captureStream stub below
  // still applies.
  calls.videos = [];
  const origCreate = window.document.createElement.bind(window.document);
  window.document.createElement = function createElement(tag) {
    if (String(tag).toLowerCase() === 'video') {
      const v = {
        muted: false, defaultMuted: false, loop: false, playsInline: false,
        videoWidth: 320, videoHeight: 240, oncanplay: null, onerror: null,
        setAttribute() {},
        play() { calls.videoPlayed = true; return { catch() {} }; },
        pause() { calls.videoPaused = true; },
        load() {},
        set src(_v) { setTimeout(() => this.oncanplay && this.oncanplay(), 0); },
      };
      calls.videos.push(v);
      return v;
    }
    return origCreate(tag);
  };

  const proto = window.HTMLCanvasElement.prototype;
  proto.getContext = function getContext() {
    return { drawImage() {} };
  };
  proto.captureStream = function captureStream() {
    const track = new window.MediaStreamTrack();
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

test('virtual decision with a video source loops a muted clip as the camera', async () => {
  const { window, calls } = setupCameraDom({
    decision: {
      mode: 'virtual',
      source: { kind: 'video', dataUrl: 'data:video/mp4;base64,AAAA' },
    },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  assert.ok(track, 'expected a synthetic video track');
  assert.equal(calls.realGum, 0, 'real camera must not be opened');
  assert.equal(calls.videos.length, 1, 'exactly one <video> element built');
  // The headline behaviour: the source clip is muted and looped so a scanner
  // sampling frames over time keeps seeing it.
  assert.equal(calls.videos[0].loop, true, 'source video must loop');
  assert.equal(calls.videos[0].muted, true, 'source video must be muted');
  assert.equal(calls.videoPlayed, true, 'source video must start playing');
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

test('real mode leaves the platform device list untouched', async () => {
  // Masking here would break a "pick a camera" UI: the page would request our
  // synthetic deviceId and the real getUserMedia would reject it.
  const realCam = { deviceId: 'real-cam', kind: 'videoinput', label: '', groupId: 'g' };
  const { window } = setupCameraDom({ decision: { mode: 'real' }, realCameras: [realCam] });
  const list = await window.navigator.mediaDevices.enumerateDevices();
  const cams = list.filter((d) => d.kind === 'videoinput');
  assert.equal(cams.length, 1);
  assert.equal(cams[0].deviceId, 'real-cam', 'the real camera must survive');
});

test('ask mode with a real camera leaves the list untouched', async () => {
  const realCam = { deviceId: 'real-cam', kind: 'videoinput', label: '', groupId: 'g' };
  const { window } = setupCameraDom({ mode: 'ask', decision: { mode: 'block' }, realCameras: [realCam] });
  const list = await window.navigator.mediaDevices.enumerateDevices();
  const cams = list.filter((d) => d.kind === 'videoinput');
  assert.equal(cams.length, 1);
  assert.equal(cams[0].deviceId, 'real-cam');
});

test('ask mode with NO real camera publishes one so the popup is reachable', async () => {
  // Otherwise a scanner page that enumerates first sees no camera, never
  // calls getUserMedia, and the user is never offered "use a media file".
  const { window } = setupCameraDom({ mode: 'ask', decision: { mode: 'block' }, realCameras: [] });
  const list = await window.navigator.mediaDevices.enumerateDevices();
  const cams = list.filter((d) => d.kind === 'videoinput');
  assert.equal(cams.length, 1);
  assert.equal(cams[0].label, '', 'label stays blank until a stream is served');
});

test('a synthetic deviceId is stripped when the user then picks the real camera', async () => {
  // Reachable path: on a camera-less device in `ask` mode the shim publishes
  // the synthetic videoinput (so the popup is reachable), the page selects it
  // by deviceId, and the user answers "Allow" — routing to the real camera
  // with an id it would reject as overconstrained.
  const { window, calls } = setupCameraDom({
    mode: 'ask',
    decision: { mode: 'real' },
    realCameras: [],
  });
  const list = await window.navigator.mediaDevices.enumerateDevices();
  const syntheticId = list.find((d) => d.kind === 'videoinput').deviceId;

  await window.navigator.mediaDevices.getUserMedia({
    video: { deviceId: { exact: syntheticId }, width: 640 },
  });
  assert.equal(calls.realGum, 1);
  assert.equal(calls.lastConstraints.video.deviceId, undefined,
    'the synthetic id must be stripped before hitting the real camera');
  assert.equal(calls.lastConstraints.video.width, 640, 'other constraints survive');
});

test('a real deviceId is passed through untouched', async () => {
  const realCam = { deviceId: 'real-cam', kind: 'videoinput', label: '', groupId: 'g' };
  const { window, calls } = setupCameraDom({
    decision: { mode: 'real' }, realCameras: [realCam] });
  await window.navigator.mediaDevices.getUserMedia({
    video: { deviceId: { exact: 'real-cam' } },
  });
  assert.deepEqual(calls.lastConstraints.video.deviceId, { exact: 'real-cam' });
});

test('enumerateDevices publishes one videoinput, label gated on a served grant', async () => {
  const { window } = setupCameraDom({
    decision: {
      mode: 'virtual',
      source: { kind: 'image', dataUrl: 'data:image/png;base64,AAAA' },
    },
    realCameras: [
      { deviceId: 'real-cam', kind: 'videoinput', label: '', groupId: 'g' },
    ],
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
