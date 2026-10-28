// Tier 1 — jsdom assertions for the simulated screen-sharing shim
// (lib/js/screen_share.js).
//
// jsdom has no getDisplayMedia, no canvas.captureStream and no image decode,
// so we stub the minimum surface the shim wraps and assert *routing + shape*:
//   - block    -> getDisplayMedia rejects NotAllowedError
//   - virtual  -> resolves a canvas-backed stream carrying the picked file
//   - real     -> starts the share over the bridge and draws the frames it
//                 pulls; a device track the deactivation stop ends
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
const CAPTURE = require('./helpers/capture_shims');
const { makeDom } = require('./helpers/load_shim');

const SHIM = CAPTURE.SCREEN_SHARE;

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
  share = null,
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
    constructor() {
      this.kind = 'video'; this._ended = null; this.readyState = 'live'; this.events = [];
    }
    get label() { return ''; }
    getSettings() { return {}; }
    getCapabilities() { return {}; }
    getConstraints() { return {}; }
    applyConstraints() { return Promise.resolve(); }
    clone() { return new MediaStreamTrack(); }
    stop() { this.readyState = 'ended'; calls.stopped.push(this); }
    addEventListener(type, cb) { if (type === 'ended') this._ended = cb; }
    dispatchEvent(e) {
      this.events.push(e.type);
      if (e.type === 'ended' && this._ended) this._ended(e);
      return true;
    }
  }
  window.MediaStreamTrack = MediaStreamTrack;
  calls.MediaStreamTrack = MediaStreamTrack;
  Object.defineProperty(window.navigator, 'mediaDevices', {
    value: mediaDevices,
    configurable: true,
  });

  if (!noBridge) {
    window.flutter_inappwebview = {
      callHandler(name, arg) {
        calls.bridge += 1;
        calls.lastHandler = name;
        if (share && name in share) return share[name](arg);
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
    set src(v) {
      this.url = v;
      setTimeout(() => this.onload && this.onload(), 0);
    }
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
      drawImage(media, x, y, w, h) {
        calls.drawn.push({
          x, y, w, h, canvasW: canvas.width, canvasH: canvas.height, url: media && media.url,
        });
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

test('the track reports a display surface, not a camera (SHARE-009)', async () => {
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
    Object.getOwnPropertyNames(track)
      .filter((k) => !['kind', '_ended', 'readyState', 'events'].includes(k)),
    [],
  );
});

test('a track the shim did not create keeps its real label and settings', () => {
  const { calls } = setupShareDom({ decision: { mode: 'block' } });
  const foreign = new calls.MediaStreamTrack();
  assert.equal(foreign.label, '');
  assert.deepEqual(foreign.getSettings(), {});
});

test('the served stream never carries an audio track (SHARE-015)', async () => {
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

test('a malformed bridge answer fails closed (SHARE-010)', async () => {
  // `{mode: 'real'}` reaches the start handler, which answers the same
  // malformed value here: no size, so no share.
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
    // Both shims register what they substituted in one cross-shim registry;
    // the camera's __wsStopRealCapture() skips anything in it. Without this
    // the surface would be torn down on every site switch (SHARE-012).
    const { window } = setupShareDom({
      decision: { mode: 'virtual', source: IMAGE_SOURCE },
    });
    const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
    const track = stream.getVideoTracks()[0];
    assert.equal(window.__wsStopRealCapture(), 0);
    assert.equal(track.readyState, 'live');
  });

test('stopping a clone leaves the shared surface playing', async () => {
  const { window, calls } = setupShareDom({
    decision: { mode: 'virtual', source: VIDEO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  track.clone().stop();
  assert.equal(calls.videoPaused, undefined, 'the original still loops the clip');
  track.stop();
  assert.equal(calls.videoPaused, true);
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

// --- The real screen (SHARE-018) --------------------------------------------

// Android's side as the bridge shows it: a start that answers the surface's
// size, and frames handed out one per pull. Past the last scripted frame a
// pull waits forever, as a pull does while the screen does not change.
function androidShare({ size = { width: 640, height: 1280 }, frames = [] } = {}) {
  const seen = { starts: [], pulls: [], stops: 0 };
  let next = 0;
  return {
    seen,
    handlers: {
      webScreenShareRequest: () => Promise.resolve({ mode: 'real' }),
      webScreenShareStart: (arg) => { seen.starts.push(arg); return Promise.resolve(size); },
      webScreenShareFrame: (after) => {
        seen.pulls.push(after);
        return next < frames.length ? Promise.resolve(frames[next++]) : new Promise(() => {});
      },
      webScreenShareStop: () => { seen.stops += 1; return Promise.resolve(null); },
    },
  };
}

const tick = (window) => new Promise((r) => window.setTimeout(r, 5));

test('a real grant starts the share with what the page asked (SHARE-018)', async () => {
  const android = androidShare();
  const { window, calls } = setupShareDom({ share: android.handlers });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({
    video: { width: { max: 800 }, height: { max: 600 }, frameRate: 5 },
  });
  // Built in the page's realm, so compared by value.
  assert.deepEqual(JSON.parse(JSON.stringify(android.seen.starts)),
    [{ maxWidth: 800, maxHeight: 600, fps: 5 }]);
  const track = stream.getVideoTracks()[0];
  const s = track.getSettings();
  assert.equal(s.displaySurface, 'monitor');
  assert.equal(s.width, 640);
  assert.equal(s.height, 1280);
  assert.equal(track.label, 'Screen');
  assert.equal(calls.capturedFps, undefined, 'captured on every draw, not on a timer');
});

test('each pulled frame is drawn whole, newest only', async () => {
  const android = androidShare({
    frames: [{ seq: 1, jpeg: 'QQ==' }, { seq: 1, jpeg: 'Qg==' }, { seq: 2 }, { seq: 3, jpeg: 'Qw==' }],
  });
  const { window, calls } = setupShareDom({ share: android.handlers });
  await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  for (let i = 0; i < 10; i++) await tick(window);
  assert.deepEqual(android.seen.pulls, [0, 1, 1, 1, 3],
    'each pull names the newest frame the page holds');
  assert.deepEqual(calls.drawn.map((d) => d.url), [
    'data:image/jpeg;base64,QQ==',
    'data:image/jpeg;base64,Qw==',
  ]);
  for (const d of calls.drawn) {
    assert.deepEqual([d.x, d.y, d.w, d.h], [0, 0, 640, 1280]);
  }
});

test("declining Android's prompt denies the request", async () => {
  const android = androidShare({ size: null });
  const { window } = setupShareDom({ share: android.handlers });
  await assert.rejects(
    () => window.navigator.mediaDevices.getDisplayMedia({ video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.deepEqual(android.seen.pulls, []);
});

test('a share Android ends, ends the track and says so', async () => {
  const android = androidShare({ frames: [{ seq: 1, jpeg: 'QQ==' }, { ended: true }] });
  const { window } = setupShareDom({ share: android.handlers });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  for (let i = 0; i < 10; i++) await tick(window);
  assert.equal(track.readyState, 'ended');
  assert.deepEqual(track.events, ['ended'], 'a call app learns the share is over');
  assert.equal(android.seen.pulls.length, 2, 'no pull after the end');
});

test('stopping the track stops the share, once', async () => {
  const android = androidShare();
  const { window } = setupShareDom({ share: android.handlers });
  const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
  const track = stream.getVideoTracks()[0];
  const copy = track.clone();
  track.stop();
  assert.equal(android.seen.stops, 0, 'a clone still shows the screen');
  copy.stop();
  copy.stop();
  assert.equal(android.seen.stops, 1);
});

test('the deactivation stop ends the real screen, unlike a simulated one (SHARE-017)',
  async () => {
    const android = androidShare();
    const { window } = setupShareDom({ share: android.handlers });
    const stream = await window.navigator.mediaDevices.getDisplayMedia({ video: true });
    const track = stream.getVideoTracks()[0];
    const copy = track.clone();
    assert.equal(window.__wsStopRealCapture(), 2);
    assert.equal(track.readyState, 'ended');
    assert.equal(copy.readyState, 'ended');
  });
