// Camera + microphone shims in one realm (MIC-012).
//
// A combined audio+video getUserMedia is served by BOTH shims and comes back
// as one stream carrying a track from each. The camera's deactivation stop
// (CAM-012) ends the device tracks it handed out and skips substituted ones —
// so it has to recognise a track the *other* shim substituted, or switching
// sites would kill the simulated microphone. The shims share one
// `globalThis.__wsSyntheticTracks` set for exactly this.
//
// Both injection orders are exercised: the outer shim is the one that sees
// the other's track, and which one that is depends only on the order
// webview.dart happens to add the user scripts.

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const CAMERA = readFixture('camera_stream/shim.js');
const MICROPHONE = readFixture('microphone_stream/shim.js');

const IMAGE_SOURCE = { kind: 'image', dataUrl: 'data:image/png;base64,AAAA' };
const AUDIO_SOURCE = { dataUrl: 'data:audio/wav;base64,QUJD' };

const _openDoms = [];
afterEach(() => {
  while (_openDoms.length) {
    try { _openDoms.pop().window.close(); } catch (_) { /* already closed */ }
  }
});

// A realm with both capture surfaces stubbed. `order` decides which shim is
// injected last, i.e. which one ends up wrapping the other.
function setupBothShims({ cameraMode = 'virtual', order = 'camera-first' } = {}) {
  const dom = makeDom();
  const window = dom.window;
  const calls = { realGum: 0 };

  class MediaStreamTrack {
    constructor(kind) {
      this.kind = kind || 'video';
      this.readyState = 'live';
      this._ended = null;
    }
    get label() { return ''; }
    getSettings() { return {}; }
    getCapabilities() { return {}; }
    getConstraints() { return {}; }
    applyConstraints() { return Promise.resolve(); }
    clone() { return new MediaStreamTrack(this.kind); }
    stop() { this.readyState = 'ended'; }
    addEventListener(type, cb) { if (type === 'ended') this._ended = cb; }
  }
  window.MediaStreamTrack = MediaStreamTrack;

  window.MediaStream = class MediaStream {
    constructor(tracks) { this._tracks = tracks || []; }
    getTracks() { return this._tracks; }
    getAudioTracks() { return this._tracks.filter((t) => t.kind === 'audio'); }
    getVideoTracks() { return this._tracks.filter((t) => t.kind === 'video'); }
    addTrack(t) { this._tracks.push(t); }
  };

  class MediaDevices {
    getUserMedia(_constraints) {
      calls.realGum += 1;
      // The platform only ever gets asked for video here: the microphone
      // shim strips the audio half before delegating.
      const track = new MediaStreamTrack('video');
      calls.lastRealTrack = track;
      return Promise.resolve(new window.MediaStream([track]));
    }
    enumerateDevices() { return Promise.resolve([]); }
  }
  window.MediaDevices = MediaDevices;
  Object.defineProperty(window.navigator, 'mediaDevices', {
    value: new MediaDevices(),
    configurable: true,
  });

  // Camera surface: canvas capture + image decode.
  window.Image = class FakeImage {
    constructor() {
      this.naturalWidth = 320;
      this.naturalHeight = 240;
      this.onload = null;
      this.onerror = null;
    }
    set src(_v) { setTimeout(() => this.onload && this.onload(), 0); }
  };
  const canvasProto = window.HTMLCanvasElement.prototype;
  canvasProto.getContext = function getContext() { return { drawImage() {} }; };
  canvasProto.captureStream = function captureStream() {
    const track = new window.MediaStreamTrack('video');
    return { getVideoTracks: () => [track], getTracks: () => [track] };
  };

  // Microphone surface: a WebAudio graph that yields one audio track.
  window.AudioContext = class AudioContext {
    constructor() { this.sampleRate = 48000; this.state = 'running'; }
    decodeAudioData() { return Promise.resolve({ duration: 1 }); }
    createBufferSource() {
      return { loop: false, buffer: null, connect() {}, start() {}, stop() {} };
    }
    createMediaStreamDestination() {
      const track = new window.MediaStreamTrack('audio');
      return { stream: new window.MediaStream([track]) };
    }
    resume() { return Promise.resolve(); }
    close() { return Promise.resolve(); }
  };

  window.flutter_inappwebview = {
    callHandler(name) {
      switch (name) {
        case 'webCameraMode': return Promise.resolve(cameraMode);
        case 'webCameraRequest':
          return Promise.resolve(cameraMode === 'virtual'
            ? { mode: 'virtual', source: IMAGE_SOURCE }
            : { mode: cameraMode });
        case 'webMicrophoneMode': return Promise.resolve('virtual');
        case 'webMicrophoneRequest':
          return Promise.resolve({ mode: 'virtual', source: AUDIO_SOURCE });
        default: return Promise.resolve(null);
      }
    },
  };

  const scripts = order === 'camera-first'
    ? [CAMERA, MICROPHONE]
    : [MICROPHONE, CAMERA];
  for (const s of scripts) runInDom(dom, s);
  _openDoms.push(dom);
  return { dom, window, calls };
}

for (const order of ['camera-first', 'microphone-first']) {
  test(`[${order}] a combined request is served by both shims`, async () => {
    const { window, calls } = setupBothShims({ order });
    const stream = await window.navigator.mediaDevices.getUserMedia({
      audio: true,
      video: true,
    });
    const kinds = [...stream.getTracks().map((t) => t.kind)].sort();
    assert.deepEqual(kinds, ['audio', 'video']);
    assert.equal(calls.realGum, 0, 'neither device is opened');
  });

  test(`[${order}] the capture stop spares both substituted tracks`, async () => {
    const { window } = setupBothShims({ order });
    const stream = await window.navigator.mediaDevices.getUserMedia({
      audio: true,
      video: true,
    });
    const stopped = window.__wsStopRealCapture();
    assert.equal(stopped, 0, 'nothing device-backed was captured to stop');
    for (const t of stream.getTracks()) {
      assert.equal(t.readyState, 'live',
        `the substituted ${t.kind} track must survive a site switch`);
    }
  });

  test(`[${order}] a device track is still stopped`, async () => {
    // Control for the assertion above: the exemption must not have widened
    // into "never stop anything".
    const { window, calls } = setupBothShims({ order, cameraMode: 'real' });
    const stream = await window.navigator.mediaDevices.getUserMedia({
      video: true,
    });
    assert.equal(calls.realGum, 1, 'the device camera was opened');
    const stopped = window.__wsStopRealCapture();
    assert.equal(stopped, 1);
    assert.equal(stream.getVideoTracks()[0].readyState, 'ended');
  });

  test(`[${order}] both shims share one synthetic-track registry`, async () => {
    const { window } = setupBothShims({ order });
    const stream = await window.navigator.mediaDevices.getUserMedia({
      audio: true,
      video: true,
    });
    // The set is what makes the exemption readable across shims; assert the
    // membership directly so a regression names the cause, not the symptom.
    for (const t of stream.getTracks()) {
      assert.equal(window.__wsSyntheticTracks.has(t), true,
        `the ${t.kind} track must be registered as substituted`);
    }
  });
}
