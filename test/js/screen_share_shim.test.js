// Tier 1 — jsdom assertions for the simulated screen-sharing shim
// (lib/services/screen_share_shim.dart, dumped to
// test/js_fixtures/screen_share/shim.js).
//
// jsdom has no getDisplayMedia, no canvas.captureStream and no image decode,
// so we stub the minimum surface the shim wraps and assert *routing + shape*:
//   - block    -> getDisplayMedia rejects NotAllowedError
//   - virtual  -> resolves a canvas-backed stream carrying the picked file
//   - no mode  -> there is no answer that yields a real display surface
//   - subframe -> denied before the bridge is even asked
//   - no bridge-> fail closed (block)
//   - never an audio track, whatever the page asked for
// Real MediaStream semantics (frame content, liveness) are NOT and cannot be
// simulated here; that is deliberate — this file guards the decision funnel.
// The real-engine assertions live in
// test/browser/screen_share_real_engine.test.js.

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture } = require('./helpers/load_shim');

const SHIM = readFixture('screen_share/shim.js');

const IMAGE_SOURCE = { kind: 'image', dataUrl: 'data:image/png;base64,QUJD' };
const VIDEO_SOURCE = { kind: 'video', dataUrl: 'data:video/mp4;base64,QUJD' };

// The virtual path arms a setInterval to keep repainting the capture canvas;
// a real page clears it on track.stop(). In jsdom the timer would keep the
// Node event loop alive past the suite, so close every dom we create.
const _openDoms = [];
afterEach(() => {
  while (_openDoms.length) {
    try { _openDoms.pop().window.close(); } catch (_) { /* already closed */ }
  }
});

// Build a jsdom realm with a fake display-capture surface. `decision` is what
// the webScreenShareRequest bridge returns; `noBridge` omits the bridge;
// `subframe` runs the shim inside a real iframe, which is the only faithful
// way to get `window.top !== window` (jsdom's `top` is non-configurable, and
// stubbing it would test the stub). `platformGetDisplayMedia` installs an
// engine-provided getDisplayMedia so the override-the-real-one path is
// covered too.
function setupShareDom({
  decision,
  noBridge = false,
  subframe = false,
  platformGetDisplayMedia = false,
} = {}) {
  const dom = makeDom({
    html: '<!doctype html><html><head></head><body><iframe></iframe></body></html>',
  });
  const window = subframe
    ? dom.window.document.querySelector('iframe').contentWindow
    : dom.window;
  const calls = { bridge: 0, platformGdm: 0, stopped: [] };

  // Model the real interface, not a convenience stub: browsers expose this as
  // a MediaDevices.prototype method, and the shim deliberately patches the
  // prototype (patching the instance would leak own-properties a
  // fingerprinter reads).
  class MediaDevices {}
  if (platformGetDisplayMedia) {
    MediaDevices.prototype.getDisplayMedia = function getDisplayMedia() {
      calls.platformGdm += 1;
      return Promise.resolve({ __realScreen: true });
    };
  }
  window.MediaDevices = MediaDevices;
  const mediaDevices = new MediaDevices();

  class MediaStreamTrack {
    constructor() { this.kind = 'video'; this._ended = null; this.readyState = 'live'; }
    get label() { return ''; }
    getSettings() { return {}; }
    getCapabilities() { return {}; }
    getConstraints() { return {}; }
    applyConstraints() { return Promise.resolve(); }
    clone() { return new MediaStreamTrack(); }
    stop() { this.readyState = 'ended'; calls.stopped.push(this); }
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
        calls.bridge += 1;
        calls.lastHandler = name;
        return Promise.resolve(decision);
      },
    };
  }

  // Image: resolve onload asynchronously so loadImage() settles.
  window.Image = class FakeImage {
    constructor() {
      this.naturalWidth = 1600;
      this.naturalHeight = 900;
      this.onload = null;
      this.onerror = null;
    }
    set src(_v) { setTimeout(() => this.onload && this.onload(), 0); }
  };

  // Video source: jsdom won't decode a data: URL, so hand back a fake <video>
  // that fires oncanplay and records the flags the shim sets. Real <canvas>
  // creation is delegated to jsdom so the captureStream stub below applies.
  calls.videos = [];
  const origCreate = window.document.createElement.bind(window.document);
  window.document.createElement = function createElement(tag) {
    if (String(tag).toLowerCase() === 'video') {
      const v = {
        muted: false, defaultMuted: false, loop: false, playsInline: false,
        videoWidth: 1600, videoHeight: 900, oncanplay: null, onerror: null,
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

  // Canvas: jsdom returns a real element but getContext('2d') is null and
  // captureStream is absent. Stub both so streamFromMedia() completes.
  calls.drawn = [];
  const proto = window.HTMLCanvasElement.prototype;
  proto.getContext = function getContext() {
    const canvas = this;
    return {
      drawImage(_media, x, y, w, h) {
        calls.drawn.push({ x, y, w, h, canvasW: canvas.width, canvasH: canvas.height });
      },
    };
  };
  proto.captureStream = function captureStream(fps) {
    calls.capturedFps = fps;
    const track = new window.MediaStreamTrack();
    return {
      getVideoTracks: () => [track],
      getAudioTracks: () => [],
      getTracks: () => [track],
    };
  };

  window.eval(SHIM);
  _openDoms.push(dom);
  return { dom, window, calls };
}

test('getDisplayMedia exists even where the engine has none', () => {
  const { window } = setupShareDom({ decision: { mode: 'block' } });
  assert.equal(typeof window.navigator.mediaDevices.getDisplayMedia, 'function');
  // On MediaDevices.prototype, not the instance: a real browser defines it
  // only there, and an own property is exactly what a fingerprinter reads.
  assert.deepEqual(
    Object.getOwnPropertyNames(window.navigator.mediaDevices), [],
  );
  assert.ok(
    Object.prototype.hasOwnProperty.call(
      window.MediaDevices.prototype, 'getDisplayMedia'),
  );
});

test('the override stringifies as native code', () => {
  const { window } = setupShareDom({ decision: { mode: 'block' } });
  assert.match(
    String(window.navigator.mediaDevices.getDisplayMedia),
    /\[native code\]/,
  );
});

test('block rejects with NotAllowedError', async () => {
  const { window } = setupShareDom({ decision: { mode: 'block' } });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
});

test('the platform picker is never reached, even where one exists', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'block' },
    platformGetDisplayMedia: true,
  });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.platformGdm, 0, 'the engine picker must stay unreachable');
});

test('a virtual grant serves the picked image, never the platform', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
    platformGetDisplayMedia: true,
  });
  const stream = await window.navigator.mediaDevices.getDisplayMedia();
  const track = stream.getVideoTracks()[0];
  assert.ok(track, 'expected a synthetic surface track');
  assert.equal(calls.platformGdm, 0);
  assert.equal(track.label, 'Screen');
});

test('a virtual grant loops a picked video', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: VIDEO_SOURCE },
  });
  await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  assert.equal(calls.videos.length, 1);
  assert.equal(calls.videos[0].loop, true, 'the surface clip must repeat');
  assert.equal(calls.videoPlayed, true);
});

test('the surface is served whole, at its own size, never cropped', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
  });
  await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  const draw = calls.drawn[0];
  // A camera cover-fits into the requested frame; a shared screen is shown
  // entire, so the canvas takes the source's own 1600x900.
  assert.deepEqual(
    { x: draw.x, y: draw.y, w: draw.w, h: draw.h },
    { x: 0, y: 0, w: 1600, h: 900 },
  );
});

test('a max-width constraint scales the surface down without distorting it',
  async () => {
    const { window, calls } = setupShareDom({
      decision: { mode: 'virtual', source: IMAGE_SOURCE },
    });
    await window.navigator.mediaDevices.getDisplayMedia({
      video: { width: { max: 800 } },
    });
    const draw = calls.drawn[0];
    assert.equal(draw.w, 800);
    assert.equal(draw.h, 450, 'aspect ratio preserved');
  });

test('the track reports a display surface, not a camera', async () => {
  const { window } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  const s = track.getSettings();
  assert.equal(s.displaySurface, 'monitor');
  assert.equal(s.logicalSurface, true);
  assert.equal(s.cursor, 'never');
  assert.equal(s.width, 1600);
  assert.equal(s.height, 900);
  assert.equal(s.facingMode, undefined, 'a screen has no facing mode');
  assert.equal(track.getCapabilities().displaySurface, 'monitor');
  // No own properties: the overrides live on MediaStreamTrack.prototype.
  assert.deepEqual(
    Object.getOwnPropertyNames(track).filter((k) => k !== 'kind' && k !== '_ended' && k !== 'readyState'),
    [],
  );
});

test('a track the shim did not create keeps its real label and settings', () => {
  const { window, calls } = setupShareDom({ decision: { mode: 'block' } });
  const foreign = new calls.MediaStreamTrack();
  assert.equal(foreign.label, '');
  assert.deepEqual(foreign.getSettings(), {});
});

test('the served stream never carries an audio track', async () => {
  const { window } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({
    video: true,
    audio: true,
  });
  assert.deepEqual(stream.getAudioTracks(), [],
    'system audio capture must be impossible by construction');
});

test('an audio-only request is a TypeError, as in a real browser', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
  });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: false, audio: true }),
    // Constructed inside the jsdom realm, so `instanceof TypeError` is false
    // here for the same reason it is across a real frame boundary.
    (err) => err && err.name === 'TypeError',
  );
  assert.equal(calls.bridge, 0, 'a malformed request must not raise the popup');
});

test('a subframe is denied without even asking the bridge (SHARE-005)', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
    subframe: true,
  });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.bridge, 0,
    'a third-party frame must not be able to raise the popup');
});

test('a missing bridge fails closed', async () => {
  const { window } = setupShareDom({ noBridge: true });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
});

test('a malformed bridge answer fails closed', async () => {
  for (const answer of [null, undefined, 'virtual', 42, { mode: 'real' }, {}]) {
    const { window } = setupShareDom({ decision: answer });
    await assert.rejects(
      () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
      (err) => err && err.name === 'NotAllowedError',
      `answer ${JSON.stringify(answer)} must not be read as a grant`,
    );
  }
});

test('a virtual grant with no picked source is denied', async () => {
  const { window } = setupShareDom({ decision: { mode: 'virtual' } });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
});

test('a burst of requests asks the bridge once', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: IMAGE_SOURCE },
  });
  await Promise.all([
    window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    window.navigator.mediaDevices.getDisplayMedia({ video: true }),
  ]);
  assert.equal(calls.bridge, 1, 'the share button must not stack popups');
  assert.equal(calls.lastHandler, 'webScreenShareRequest');
});

test('the simulated surface is exempt from the camera deactivation stop',
  async () => {
    // Both shims register what they substituted in one cross-shim set; the
    // camera's __wsStopRealCapture() skips anything in it. Without this the
    // surface would be torn down on every site switch (SHARE-012).
    const { window } = setupShareDom({
      decision: { mode: 'virtual', source: IMAGE_SOURCE },
    });
    const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
    const track = stream.getVideoTracks()[0];
    assert.ok(window.__wsSyntheticTracks.has(track));
  });

test('stopping the track drops the repaint loop', async () => {
  const { window } = setupShareDom({
    decision: { mode: 'virtual', source: VIDEO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  track.stop();
  assert.equal(track.readyState, 'ended');
});
