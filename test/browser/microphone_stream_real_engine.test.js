// Real-Chromium proof for the virtual microphone shim
// (lib/services/microphone_stream_shim.dart, dumped to
// test/js_fixtures/microphone_stream/shim.js).
//
// The jsdom tier (test/js/microphone_stream_shim.test.js) stubs WebAudio, so
// it proves the decision funnel but not that the synthetic track actually
// carries the picked clip, nor that the clip REPEATS — the headline claim of
// the feature. This test runs the exact dumped shim in real headless Chromium
// and samples the served track back through an AnalyserNode.
//
// getUserMedia needs a secure context, so the page is served from 127.0.0.1
// (a Chromium secure-context exception) rather than about:blank.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');

const SHIM = readFixture('microphone_stream/shim.js');

const browser = setupBrowser();

// A short mono WAV built here rather than committed: it is entirely derived
// from these parameters, so a checked-in binary would be a derivative.
// Deliberately SHORTER than the sampling window below, so the tone can only
// still be present at the end if the source looped.
function makeWavDataUrl({ seconds = 0.25, freq = 440, rate = 44100 } = {}) {
  const frames = Math.round(seconds * rate);
  const buf = Buffer.alloc(44 + frames * 2);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(36 + frames * 2, 4);
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16); // PCM chunk size
  buf.writeUInt16LE(1, 20); // PCM
  buf.writeUInt16LE(1, 22); // mono
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate * 2, 28); // byte rate
  buf.writeUInt16LE(2, 32); // block align
  buf.writeUInt16LE(16, 34); // bits per sample
  buf.write('data', 36);
  buf.writeUInt32LE(frames * 2, 40);
  for (let i = 0; i < frames; i++) {
    const v = Math.round(Math.sin((2 * Math.PI * freq * i) / rate) * 0.8 * 32767);
    buf.writeInt16LE(v, 44 + i * 2);
  }
  return 'data:audio/wav;base64,' + buf.toString('base64');
}

function startServer() {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<!doctype html><html><head></head><body></body></html>');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// Boots a page with the shim installed and the bridge answering `decision`.
async function openPage(decision) {
  const server = await startServer();
  const { port } = server.address();
  const page = await browser.browser.newPage();
  await page.evaluateOnNewDocument((d) => {
    window.flutter_inappwebview = {
      callHandler: (name) =>
        Promise.resolve(name === 'webMicrophoneMode' ? d.mode : d),
    };
  }, decision);
  await page.evaluateOnNewDocument(SHIM);
  await page.goto(`http://127.0.0.1:${port}/`, { waitUntil: 'load' });
  return { page, server };
}

test('virtual microphone plays the picked clip and keeps looping', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const { page, server } = await openPage({
    mode: 'virtual',
    source: { dataUrl: makeWavDataUrl() },
  });

  try {
    const result = await page.evaluate(async () => {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        return { error: 'no mediaDevices (insecure context?)' };
      }
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      const track = stream.getAudioTracks()[0];
      if (!track) return { error: 'no audio track' };

      // Read the served track back out through a fresh graph. If the shim
      // handed over a real (absent) microphone or a silent node, every
      // window below stays at the noise floor.
      const ctx = new AudioContext();
      await ctx.resume();
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 2048;
      ctx.createMediaStreamSource(stream).connect(analyser);
      const data = new Float32Array(analyser.fftSize);

      const rms = () => {
        analyser.getFloatTimeDomainData(data);
        let sum = 0;
        for (let i = 0; i < data.length; i++) sum += data[i] * data[i];
        return Math.sqrt(sum / data.length);
      };

      const samples = [];
      const started = performance.now();
      // The clip is 0.25 s; sample well past it so silence after the first
      // pass would show up as a dead tail.
      while (performance.now() - started < 1500) {
        await new Promise((r) => setTimeout(r, 100));
        samples.push(rms());
      }
      const settings = track.getSettings();
      return {
        label: track.label,
        kind: track.kind,
        readyState: track.readyState,
        ctor: track.constructor.name,
        settings: {
          sampleRate: settings.sampleRate,
          channelCount: settings.channelCount,
          echoCancellation: settings.echoCancellation,
          deviceId: typeof settings.deviceId,
        },
        early: Math.max(...samples.slice(0, 4)),
        late: Math.max(...samples.slice(-4)),
      };
    });

    assert.equal(result.error, undefined, result.error);
    assert.equal(result.kind, 'audio');
    assert.equal(result.readyState, 'live');
    assert.equal(result.label, 'Microphone Array');
    // A canvas-capture-style subclass name would betray the substitution; a
    // real microphone track is a plain MediaStreamTrack.
    assert.equal(result.ctor, 'MediaStreamTrack');
    assert.ok(result.settings.sampleRate > 0, 'settings must report a rate');
    assert.equal(result.settings.channelCount, 1);
    assert.equal(result.settings.echoCancellation, true);
    assert.equal(result.settings.deviceId, 'string');

    assert.ok(result.early > 0.01,
      `expected audible signal early, got RMS ${result.early}`);
    // The proof of the loop: the clip is 0.25 s but the tail of a 1.5 s
    // sampling window is still carrying signal.
    assert.ok(result.late > 0.01,
      `expected the clip to still be playing after it ended, got RMS ${result.late}`);
  } finally {
    await page.close();
    server.close();
  }
});

test('no OS capture is involved: the page never holds a microphone permission',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const { page, server } = await openPage({
      mode: 'virtual',
      source: { dataUrl: makeWavDataUrl() },
    });

    try {
      const result = await page.evaluate(async () => {
        const before = await navigator.permissions.query({ name: 'microphone' });
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        const after = await navigator.permissions.query({ name: 'microphone' });
        const devices = await navigator.mediaDevices.enumerateDevices();
        return {
          before: before.state,
          after: after.state,
          served: stream.getAudioTracks().length,
          mics: devices
            .filter((d) => d.kind === 'audioinput')
            .map((d) => d.label),
        };
      });

      assert.equal(result.served, 1);
      // Chromium starts headless with the permission unprompted; serving a
      // stream must not move it, because nothing native was ever asked.
      assert.notEqual(result.after, 'granted');
      assert.equal(result.after, result.before);
      // Exactly one microphone, labelled now that a stream has been served.
      assert.deepEqual(result.mics, ['Microphone Array']);
    } finally {
      await page.close();
      server.close();
    }
  });

test('block rejects under the real engine too', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const { page, server } = await openPage({ mode: 'block' });

  try {
    const name = await page.evaluate(async () => {
      try {
        await navigator.mediaDevices.getUserMedia({ audio: true });
        return 'resolved';
      } catch (e) {
        return e.name;
      }
    });
    assert.equal(name, 'NotAllowedError');
  } finally {
    await page.close();
    server.close();
  }
});
