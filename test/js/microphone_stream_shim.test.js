// Tier 1 — jsdom assertions for the virtual microphone shim
// (lib/services/microphone_stream_shim.dart, dumped to
// test/js_fixtures/microphone_stream/shim.js).
//
// jsdom has no WebAudio and no getUserMedia, so we stub the minimum surface
// the shim drives and assert *routing + shape*:
//   - block   -> any audio request rejects NotAllowedError, nothing native
//   - virtual -> getUserMedia resolves a WebAudio-backed stream, on loop
//   - video-only -> passes straight through, shim stays out of the way
//   - audio+video -> audio synthesised here, video re-issued through the
//                    public entry point so a camera shim can serve it
//   - enumerateDevices publishes one audioinput (label gated on a served grant)
//   - no bridge -> fail closed (block)
// Real audio semantics (decoding, sample content) are NOT and cannot be
// simulated here; that is deliberate — this file guards the decision funnel.
// The real-engine assertions live in
// test/browser/microphone_stream_real_engine.test.js.

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, runInDom, readFixture } = require('./helpers/load_shim');

const SHIM = readFixture('microphone_stream/shim.js');

const _openDoms = [];
afterEach(() => {
  while (_openDoms.length) {
    try { _openDoms.pop().window.close(); } catch (_) { /* already closed */ }
  }
});

const AUDIO_SOURCE = { dataUrl: 'data:audio/wav;base64,QUJD' };

// Build a jsdom realm with a fake capture surface. `decision` is what the
// webMicrophoneRequest bridge returns; pass `noBridge: true` to omit the
// bridge entirely. Returns { window, calls } where calls.realGum counts
// pass-throughs to the platform getUserMedia.
function setupMicDom({ decision, mode, noBridge = false, realMics = [] } = {}) {
  const dom = makeDom();
  const window = dom.window;
  const calls = { realGum: 0, lastConstraints: null, buffers: [] };

  // Model the real interface, not a convenience stub: browsers expose these
  // as MediaDevices.prototype methods, and the shim deliberately patches the
  // prototype (patching the instance would leak own-properties a
  // fingerprinter reads).
  class MediaDevices {
    getUserMedia(constraints) {
      calls.realGum += 1;
      calls.lastConstraints = constraints;
      return Promise.resolve({
        __realStream: true,
        getTracks: () => [{ kind: 'video', __real: true, stop() {} }],
      });
    }
    enumerateDevices() {
      return Promise.resolve([
        ...realMics,
        { deviceId: 'cam', kind: 'videoinput', label: '', groupId: 'g' },
      ]);
    }
  }
  window.MediaDevices = MediaDevices;
  const mediaDevices = new MediaDevices();

  // Likewise for tracks: label/getSettings/stop live on the prototype.
  class MediaStreamTrack {
    constructor(kind) { this.kind = kind || 'audio'; this._ended = null; }
    get label() { return ''; }
    getSettings() { return {}; }
    getCapabilities() { return {}; }
    getConstraints() { return {}; }
    applyConstraints() { return Promise.resolve(); }
    clone() { return new MediaStreamTrack(this.kind); }
    stop() { calls.trackStopped = true; }
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
  Object.defineProperty(window.navigator, 'mediaDevices', {
    value: mediaDevices,
    configurable: true,
  });

  // WebAudio: jsdom has none. Stub just enough of the graph the shim builds
  // (decode -> looping buffer source -> MediaStreamAudioDestinationNode) and
  // record the flags that make the clip repeat.
  window.AudioContext = class AudioContext {
    constructor() {
      this.sampleRate = 48000;
      this.state = 'running';
      calls.contexts = (calls.contexts || 0) + 1;
    }
    decodeAudioData(buf) {
      calls.decodedBytes = buf.byteLength;
      return Promise.resolve({ duration: 1, __buffer: true });
    }
    createBufferSource() {
      const src = { loop: false, buffer: null, connect() {}, start() { calls.started = true; }, stop() { calls.srcStopped = true; } };
      calls.buffers.push(src);
      return src;
    }
    createMediaStreamDestination() {
      const track = new window.MediaStreamTrack('audio');
      return { stream: new window.MediaStream([track]) };
    }
    resume() { return Promise.resolve(); }
    close() { calls.ctxClosed = true; return Promise.resolve(); }
  };

  if (!noBridge) {
    window.flutter_inappwebview = {
      callHandler(name, _arg) {
        // Non-prompting mode read used by enumerateDevices; the decision
        // handler is the prompting one.
        if (name === 'webMicrophoneMode') {
          return Promise.resolve(mode ?? (decision && decision.mode) ?? 'block');
        }
        return Promise.resolve(decision);
      },
    };
  }

  runInDom(dom, SHIM);
  _openDoms.push(dom);
  return { dom, window, calls };
}

test('block rejects with NotAllowedError and never reaches the platform', async () => {
  const { window, calls } = setupMicDom({ decision: { mode: 'block' } });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ audio: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0);
});

test('block rejects a combined audio+video request as a whole', async () => {
  const { window, calls } = setupMicDom({ decision: { mode: 'block' } });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ audio: true, video: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0, 'must not silently downgrade to video-only');
});

test('virtual resolves a looped synthetic track without touching the device', async () => {
  const { window, calls } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({ audio: true });
  const track = stream.getAudioTracks()[0];
  assert.ok(track, 'expected a synthetic audio track');
  assert.equal(track.label, 'Microphone Array');
  assert.equal(calls.realGum, 0, 'the real microphone must never be opened');
  // The headline behaviour: the clip repeats forever.
  assert.equal(calls.buffers.length, 1);
  assert.equal(calls.buffers[0].loop, true, 'source buffer must loop');
  assert.equal(calls.started, true, 'source must start playing');
  assert.equal(calls.decodedBytes, 3, 'the data: payload is decoded, not fetched');
});

test('the synthetic track reports a real capture shape, not an empty one', async () => {
  const { window } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({
    audio: { channelCount: 2, echoCancellation: false },
  });
  const track = stream.getAudioTracks()[0];
  const s = track.getSettings();
  assert.equal(s.sampleRate, 48000);
  assert.equal(s.sampleSize, 16);
  assert.equal(s.channelCount, 2, 'requested channel count is honoured');
  assert.equal(s.echoCancellation, false, 'requested processing flag is mirrored');
  assert.equal(s.autoGainControl, true);
  assert.equal(typeof s.deviceId, 'string');
  assert.ok(s.deviceId.length > 0);
  const caps = track.getCapabilities();
  // Structural compare: values built inside the jsdom realm do not share a
  // prototype with this realm's, so deepStrictEqual would reject them.
  assert.equal(JSON.stringify(caps.echoCancellation), '[true,false]');
  assert.equal(caps.sampleSize.min, 16);
});

test('overrides live on the prototype and stringify as native', async () => {
  const { window } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const md = window.navigator.mediaDevices;
  // A real browser defines these only on MediaDevices.prototype; an own
  // property on the instance is a giveaway a fingerprinter reads.
  assert.equal(Object.getOwnPropertyNames(md).includes('getUserMedia'), false);
  assert.equal(
    Object.prototype.hasOwnProperty.call(window.MediaDevices.prototype, 'getUserMedia'),
    true,
  );
  assert.match(md.getUserMedia.toString(), /\[native code\]/);
  assert.match(md.enumerateDevices.toString(), /\[native code\]/);

  const stream = await md.getUserMedia({ audio: true });
  const track = stream.getAudioTracks()[0];
  assert.equal(Object.getOwnPropertyNames(track).includes('label'), false);
  const labelDesc = Object.getOwnPropertyDescriptor(
    window.MediaStreamTrack.prototype, 'label');
  assert.match(labelDesc.get.toString(), /\[native code\]/);
});

test('a track the shim did not create keeps its real label and settings', async () => {
  const { window } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const foreign = new window.MediaStreamTrack('audio');
  assert.equal(foreign.label, '');
  assert.equal(JSON.stringify(foreign.getSettings()), '{}');
});

test('a clone of the synthetic track keeps presenting as the same device', async () => {
  const { window } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({ audio: true });
  const copy = stream.getAudioTracks()[0].clone();
  assert.equal(copy.label, 'Microphone Array');
});

test('stopping the track tears the audio graph down', async () => {
  const { window, calls } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({ audio: true });
  stream.getAudioTracks()[0].stop();
  assert.equal(calls.srcStopped, true);
  assert.equal(calls.ctxClosed, true);
});

test('virtual with no source rejects rather than opening the device', async () => {
  const { window, calls } = setupMicDom({ decision: { mode: 'virtual' } });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ audio: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0);
});

test('a video-only request passes through untouched', async () => {
  const { window, calls } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({ video: true });
  assert.equal(stream.__realStream, true);
  assert.equal(calls.realGum, 1);
  assert.equal(JSON.stringify(calls.lastConstraints), '{"video":true}');
});

test('a combined request synthesises audio and re-issues video without it', async () => {
  const { window, calls } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  const stream = await window.navigator.mediaDevices.getUserMedia({
    audio: true,
    video: { width: 640 },
  });
  // The video half is delegated with the audio constraint stripped, so a
  // camera shim further down the chain sees a plain video request.
  assert.equal(calls.realGum, 1);
  assert.equal(JSON.stringify(calls.lastConstraints), '{"video":{"width":640}}');
  assert.equal(Object.prototype.hasOwnProperty.call(calls.lastConstraints, 'audio'), false);
  const kinds = [...stream.getTracks().map((t) => t.kind)].sort();
  assert.deepEqual(kinds, ['audio', 'video']);
});

test('a failed video half does not leave the audio graph running', async () => {
  const { window, calls } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  window.MediaDevices.prototype.__origGum = window.MediaDevices.prototype.getUserMedia;
  const md = window.navigator.mediaDevices;
  const shimGum = md.getUserMedia;
  // Make only the delegated video request fail.
  Object.defineProperty(window.MediaDevices.prototype, 'getUserMedia', {
    value: function (c) {
      if (c && c.audio) return shimGum.call(this, c);
      return Promise.reject(new Error('no camera'));
    },
    configurable: true,
  });
  await assert.rejects(
    () => md.getUserMedia({ audio: true, video: true }),
    (err) => err && err.message === 'no camera',
  );
  assert.equal(calls.ctxClosed, true, 'the synthetic audio must be torn down');
});

test('enumerateDevices publishes one audioinput in virtual mode', async () => {
  const { window } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
    realMics: [{ deviceId: 'real-mic', kind: 'audioinput', label: 'Built-in', groupId: 'g' }],
  });
  const md = window.navigator.mediaDevices;
  let devices = await md.enumerateDevices();
  const mics = devices.filter((d) => d.kind === 'audioinput');
  assert.equal(mics.length, 1, 'the real microphone is masked');
  assert.notEqual(mics[0].deviceId, 'real-mic');
  assert.equal(mics[0].label, '', 'label is gated until a stream is served');
  // Audio output devices are untouched — they are not capture.
  assert.equal(devices.filter((d) => d.kind === 'videoinput').length, 1);

  await md.getUserMedia({ audio: true });
  devices = await md.enumerateDevices();
  assert.equal(devices.find((d) => d.kind === 'audioinput').label, 'Microphone Array');
});

test('ask mode publishes a synthetic mic only when the device has none', async () => {
  const withMic = setupMicDom({
    mode: 'ask',
    realMics: [{ deviceId: 'real-mic', kind: 'audioinput', label: '', groupId: 'g' }],
  });
  const listed = await withMic.window.navigator.mediaDevices.enumerateDevices();
  assert.deepEqual(
    [...listed.filter((d) => d.kind === 'audioinput').map((d) => d.deviceId)],
    ['real-mic'],
    'a device with a real microphone keeps the platform list',
  );

  const without = setupMicDom({ mode: 'ask' });
  const listed2 = await without.window.navigator.mediaDevices.enumerateDevices();
  assert.equal(
    listed2.filter((d) => d.kind === 'audioinput').length, 1,
    'otherwise a synthetic mic keeps the page calling getUserMedia',
  );
});

test('block mode leaves the platform device list alone', async () => {
  const { window } = setupMicDom({
    mode: 'block',
    realMics: [{ deviceId: 'real-mic', kind: 'audioinput', label: '', groupId: 'g' }],
  });
  const devices = await window.navigator.mediaDevices.enumerateDevices();
  assert.deepEqual(
    [...devices.filter((d) => d.kind === 'audioinput').map((d) => d.deviceId)],
    ['real-mic'],
  );
});

test('no bridge fails closed', async () => {
  const { window, calls } = setupMicDom({ noBridge: true });
  await assert.rejects(
    () => window.navigator.mediaDevices.getUserMedia({ audio: true }),
    (err) => err && err.name === 'NotAllowedError',
  );
  assert.equal(calls.realGum, 0);
});

test('one bridge round trip serves a burst of requests', async () => {
  const { window } = setupMicDom({
    decision: { mode: 'virtual', source: AUDIO_SOURCE },
  });
  let handlerCalls = 0;
  const inner = window.flutter_inappwebview.callHandler;
  window.flutter_inappwebview.callHandler = function (name, arg) {
    if (name === 'webMicrophoneRequest') handlerCalls += 1;
    return inner(name, arg);
  };
  const md = window.navigator.mediaDevices;
  await Promise.all([
    md.getUserMedia({ audio: true }),
    md.getUserMedia({ audio: true }),
    md.getUserMedia({ audio: true }),
  ]);
  assert.equal(handlerCalls, 1);
});
