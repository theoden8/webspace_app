// The deactivation stop must survive a hostile page (CAM-012 / MIC-012 /
// MIC-014).
//
// `__wsStopRealCapture` is the only thing that ends a device capture when a
// site stops being the one on screen, and Dart can only reach it by name from
// the page's own realm. So the page can call it — that is harmless — but must
// not be able to defeat it. Every assertion below is a bypass that worked
// while the hook was a writable global over globals: one assignment, or one
// `__wsRealTracks = []`, and the microphone kept recording with the app
// reporting the capture ended.
//
// The clone case is a bypass that needed no tampering at all: a cloned track
// is independently live, so a page that cloned its device track before the
// switch kept capturing through the copy.
//
// Cross-links:
//   openspec/specs/web-camera-access/spec.md      CAM-012
//   openspec/specs/web-microphone-access/spec.md  MIC-012 / MIC-014

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const CAMERA = readFixture('camera_stream/shim.js');

const _openDoms = [];
afterEach(() => {
  while (_openDoms.length) {
    try { _openDoms.pop().window.close(); } catch (_) { /* already closed */ }
  }
});

// A realm running the camera shim in `real` mode, i.e. one that has handed the
// page a device track and registered it for the stop.
function setupRealCapture() {
  const dom = makeDom();
  const window = dom.window;

  class MediaStreamTrack {
    constructor(kind) {
      this.kind = kind || 'video';
      this.readyState = 'live';
    }
    get label() { return ''; }
    getSettings() { return {}; }
    getCapabilities() { return {}; }
    getConstraints() { return {}; }
    applyConstraints() { return Promise.resolve(); }
    clone() { return new MediaStreamTrack(this.kind); }
    stop() { this.readyState = 'ended'; }
    addEventListener() {}
  }
  window.MediaStreamTrack = MediaStreamTrack;

  window.MediaStream = class MediaStream {
    constructor(tracks) { this._tracks = tracks || []; }
    getTracks() { return this._tracks; }
    getAudioTracks() { return this._tracks.filter((t) => t.kind === 'audio'); }
    getVideoTracks() { return this._tracks.filter((t) => t.kind === 'video'); }
    clone() { return new window.MediaStream(this._tracks.map((t) => t.clone())); }
    addTrack(t) { this._tracks.push(t); }
  };

  class MediaDevices {
    getUserMedia() {
      return Promise.resolve(new window.MediaStream([new MediaStreamTrack('video')]));
    }
    enumerateDevices() { return Promise.resolve([]); }
  }
  Object.defineProperty(window.navigator, 'mediaDevices', {
    value: new MediaDevices(),
    configurable: true,
  });

  window.flutter_inappwebview = {
    callHandler(name) {
      switch (name) {
        case 'webCameraMode': return Promise.resolve('real');
        case 'webCameraRequest': return Promise.resolve({ mode: 'real' });
        default: return Promise.resolve(null);
      }
    },
  };

  runInDom(dom, CAMERA);
  _openDoms.push(dom);
  return { dom, window };
}

const grabDeviceTrack = async (window) =>
  (await window.navigator.mediaDevices.getUserMedia({ video: true }))
    .getVideoTracks()[0];

test('the hook cannot be replaced by the page', async () => {
  const { window } = setupRealCapture();
  const track = await grabDeviceTrack(window);

  // Sloppy-mode assignment to a non-writable property fails silently, which is
  // exactly what a page attempting this would see.
  window.eval('window.__wsStopRealCapture = function () { return 0; };');

  assert.equal(window.__wsStopRealCapture(), 1,
    'the hook still ends the capture it registered');
  assert.equal(track.readyState, 'ended');
});

test('the hook cannot be deleted by the page', async () => {
  const { window } = setupRealCapture();
  const track = await grabDeviceTrack(window);

  window.eval('try { delete window.__wsStopRealCapture; } catch (e) {}');

  assert.equal(typeof window.__wsStopRealCapture, 'function');
  assert.equal(window.__wsStopRealCapture(), 1);
  assert.equal(track.readyState, 'ended');
});

test('the registry is not reachable through a global', async () => {
  const { window } = setupRealCapture();
  const track = await grabDeviceTrack(window);

  // The old design kept both lists on globalThis; emptying either one left the
  // capture running. Re-creating them must now be inert.
  window.eval('window.__wsRealTracks = []; window.__wsSyntheticTracks = new WeakSet();');

  assert.equal(window.__wsStopRealCapture(), 1);
  assert.equal(track.readyState, 'ended');
});

test('a device track cannot be laundered into the skip list', async () => {
  const { window } = setupRealCapture();
  const track = await grabDeviceTrack(window);

  // The registrar the sibling shims use is reachable from the page. Adding
  // tracks to be stopped is harmless; marking a device track as substituted is
  // not, and is refused because the track is already registered.
  window.__wsStopRealCapture.s(track);

  assert.equal(window.__wsStopRealCapture(), 1);
  assert.equal(track.readyState, 'ended');
});

test('a clone of a device track is stopped too', async () => {
  const { window } = setupRealCapture();
  const track = await grabDeviceTrack(window);
  const clone = track.clone();

  assert.equal(window.__wsStopRealCapture(), 2,
    'the clone is independently live and must be ended as well');
  assert.equal(track.readyState, 'ended');
  assert.equal(clone.readyState, 'ended');
});

test('a clone of the whole stream is stopped too', async () => {
  const { window } = setupRealCapture();
  const stream = await window.navigator.mediaDevices.getUserMedia({ video: true });
  const copy = stream.clone();

  assert.equal(window.__wsStopRealCapture(), 2);
  assert.equal(copy.getVideoTracks()[0].readyState, 'ended');
});

test('the stop is relayed to subframes', async () => {
  const { window } = setupRealCapture();
  await grabDeviceTrack(window);

  // Dart evaluates in the main frame only, and the capture shims are injected
  // forMainFrameOnly:false — a cross-origin subframe holds a registry the main
  // frame's hook cannot see, so the stop has to travel to it.
  const posted = [];
  Object.defineProperty(window, 'frames', {
    value: [{ postMessage: (msg, origin) => posted.push([msg, origin]) }],
    configurable: true,
  });

  window.__wsStopRealCapture();
  assert.deepEqual(posted, [['__wsStopRealCapture', '*']]);
});

test('a relayed stop ends the receiving frame\'s capture', async () => {
  const { window } = setupRealCapture();
  const track = await grabDeviceTrack(window);

  const event = new window.MessageEvent('message', { data: '__wsStopRealCapture' });
  window.dispatchEvent(event);

  assert.equal(track.readyState, 'ended',
    'a subframe must end its own capture when the relay reaches it');
});
