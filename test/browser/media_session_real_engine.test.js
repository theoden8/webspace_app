// Real-Chromium proof for the media-session bridge shim (BGAUDIO-006,
// lib/services/media_session_shim.dart, dumped to
// test/js_fixtures/media_session/shim.js).
//
// The Dart tier (test/media_session_shim_test.dart) only asserts substrings of
// the builder's output, which passes whether or not the shim ever reports
// anything. jsdom has no media pipeline: `paused`/`currentTime` never move, so
// the shim's own liveness predicate cannot be exercised there either. This
// tier plays a real <audio> in headless Chromium and asserts the exact payload
// sequence Dart's `wsMediaSession` handler consumes, in both directions.
//
// Autoplay is forced on because the app sets
// `mediaPlaybackRequiresUserGesture = false` (lib/services/webview.dart).

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');

const SHIM = readFixture('media_session/shim.js');

const browser = setupBrowser({
  args: [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--autoplay-policy=no-user-gesture-required',
  ],
});

// 2s of silence as a WAV blob. A data: URI would work too, but building the
// buffer in-page keeps the fixture readable and the duration explicit.
const MAKE_AUDIO = `
  function wsMakeSilentWav(seconds) {
    var sr = 8000, n = sr * seconds;
    var buf = new ArrayBuffer(44 + n * 2), dv = new DataView(buf);
    function str(o, s) {
      for (var i = 0; i < s.length; i++) dv.setUint8(o + i, s.charCodeAt(i));
    }
    str(0, 'RIFF'); dv.setUint32(4, 36 + n * 2, true); str(8, 'WAVEfmt ');
    dv.setUint32(16, 16, true); dv.setUint16(20, 1, true);
    dv.setUint16(22, 1, true); dv.setUint32(24, sr, true);
    dv.setUint32(28, sr * 2, true); dv.setUint16(32, 2, true);
    dv.setUint16(34, 16, true); str(36, 'data'); dv.setUint32(40, n * 2, true);
    return URL.createObjectURL(new Blob([buf], { type: 'audio/wav' }));
  }
`;

// Event-driven reports clear a 300ms debounce; anything that has to wait for
// the shim's own 3s reconcile tick uses RECONCILE_MS.
const FIRST_REPORT_MS = 1500;
const RECONCILE_MS = 4000;

async function newShimPage() {
  const page = await browser.browser.newPage();
  // Stand in for flutter_inappwebview's bridge, recording every call the way
  // the Dart `wsMediaSession` handler would receive it.
  await page.evaluateOnNewDocument(() => {
    window.__reports = [];
    window.flutter_inappwebview = {
      callHandler: (name, payload) => {
        // Every frame of the site shares ONE native handler, so a subframe's
        // report must land in the same log Dart would see it in.
        let sink = window;
        try {
          if (window.top && window.top.__reports) sink = window.top;
        } catch (e) {
          /* cross-origin top: keep the local sink */
        }
        sink.__reports.push({ name, payload });
        return Promise.resolve();
      },
    };
  });
  await page.evaluateOnNewDocument(MAKE_AUDIO);
  await page.evaluateOnNewDocument(SHIM);
  await page.goto('about:blank', { waitUntil: 'load' });
  return page;
}

const reports = (page) => page.evaluate(() => window.__reports);
const settle = (ms = FIRST_REPORT_MS) => new Promise((r) => setTimeout(r, ms));

test('reports playing:true with page metadata once audio actually plays', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    const played = await page.evaluate(async () => {
      document.title = 'Fallback Title';
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      navigator.mediaSession.metadata = new MediaMetadata({
        title: 'Track One',
        artist: 'The Artist',
        album: 'The Album',
        artwork: [
          { src: 'https://example.invalid/small.png', sizes: '96x96' },
          { src: 'https://example.invalid/large.png', sizes: '512x512' },
        ],
      });
      try {
        await a.play();
        return true;
      } catch (e) {
        return e.name;
      }
    });
    assert.equal(played, true, 'autoplay must be allowed in this tier');

    await settle();
    const got = await reports(page);
    assert.ok(got.length >= 1, 'shim reported nothing while audio was playing');
    assert.equal(got[0].name, 'wsMediaSession');
    // Opaque per-frame token; its value is checked in the iframe test below.
    const { frame, ...payload } = got[0].payload;
    assert.match(frame, /^f[a-z0-9]+$/);
    // Every remaining key MediaSessionService.report destructures.
    assert.deepEqual(payload, {
      playing: true,
      title: 'Track One',
      artist: 'The Artist',
      album: 'The Album',
      // Largest declared artwork last, by MediaSession convention.
      artwork: 'https://example.invalid/large.png',
    });
  } finally {
    await page.close();
  }
});

test('falls back to document.title when the page declares no metadata', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    await page.evaluate(async () => {
      document.title = 'Radio Station';
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      await a.play();
    });
    await settle();
    const got = await reports(page);
    assert.ok(got.length >= 1, 'shim reported nothing');
    assert.equal(got[0].payload.playing, true);
    assert.equal(got[0].payload.title, 'Radio Station');
    assert.equal(got[0].payload.artist, '');
    assert.equal(got[0].payload.artwork, '');
  } finally {
    await page.close();
  }
});

test('picks up an element created and played before it enters the DOM', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    // No appendChild: the MutationObserver never fires, so the only path that
    // can catch this is the HTMLMediaElement.prototype.play patch.
    await page.evaluate(async () => {
      document.title = 'Detached Player';
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      window.__detached = a;
      await a.play();
    });
    await settle();
    const got = await reports(page);
    assert.ok(
      got.some((r) => r.payload.playing === true),
      'a detached element that is playing must still be reported',
    );
  } finally {
    await page.close();
  }
});

test('transport control round-trip drives the element and re-reports', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    await page.evaluate(async () => {
      document.title = 'Transport';
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      await a.play();
    });
    await settle();

    // Dart -> page, exactly what MediaSessionService.onTransport evaluates.
    const pausedState = await page.evaluate(async () => {
      window.__wsMediaControl('pause');
      await new Promise((r) => setTimeout(r, 1000));
      return document.querySelector('audio').paused;
    });
    assert.equal(pausedState, true, 'pause must reach the media element');

    let got = await reports(page);
    assert.equal(
      got[got.length - 1].payload.playing,
      false,
      'pausing must be reported back so the notification flips to resumable',
    );

    const resumedState = await page.evaluate(async () => {
      window.__wsMediaControl('play');
      await new Promise((r) => setTimeout(r, 1000));
      return document.querySelector('audio').paused;
    });
    assert.equal(resumedState, false, 'play must reach the media element');

    await settle();
    got = await reports(page);
    assert.equal(got[got.length - 1].payload.playing, true);
  } finally {
    await page.close();
  }
});

test('does not re-report unchanged state', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    await page.evaluate(async () => {
      document.title = 'Steady';
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      await a.play();
    });
    await settle();
    const first = (await reports(page)).length;
    // Two full reconcile ticks with nothing changing.
    await settle(7000);
    const second = (await reports(page)).length;
    assert.equal(
      second,
      first,
      'the 3s reconcile tick must not spam Dart while state is unchanged',
    );
  } finally {
    await page.close();
  }
});

test('a frame with no media of its own never reports', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    // BGAUDIO-008. The shim is injected with forMainFrameOnly:false, so every
    // iframe of the site runs a copy against the same wsMediaSession handler.
    // A media-less frame reporting `playing:false` used to flip the site's
    // notification to paused right after the main frame raised it. The frame
    // here stands in for a YouTube ad/comments iframe: DOM churn, no media.
    await page.evaluate(async () => {
      document.title = 'Host Page';
      const f = document.createElement('iframe');
      f.srcdoc = '<html><body><div id="x"></div></body></html>';
      document.body.appendChild(f);
      await new Promise((r) => f.addEventListener('load', r, { once: true }));
      const d = f.contentDocument;
      for (let i = 0; i < 5; i++) {
        d.getElementById('x').appendChild(d.createElement('span'));
      }
    });
    await settle(RECONCILE_MS);
    assert.deepEqual(
      await reports(page),
      [],
      'a frame with no media element must stay silent',
    );

    // ...and once the main frame plays, the iframe's continued churn must not
    // undo it.
    const frames = await page.evaluate(async () => {
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      await a.play();
      const d = document.querySelector('iframe').contentDocument;
      for (let i = 0; i < 5; i++) {
        d.getElementById('x').appendChild(d.createElement('b'));
      }
      return null;
    });
    assert.equal(frames, null);
    await settle(RECONCILE_MS);

    const got = await reports(page);
    assert.ok(got.length >= 1, 'the main frame must still report');
    assert.ok(
      got.every((r) => r.payload.playing === true),
      'the media-less iframe must not report playing:false',
    );
    const tokens = new Set(got.map((r) => r.payload.frame));
    assert.equal(tokens.size, 1, 'only the playing frame may report');
    assert.match(got[0].payload.frame, /^f[a-z0-9]+$/);
  } finally {
    await page.close();
  }
});

test('reports metadata that arrives after playback started', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newShimPage();
  try {
    await page.evaluate(async () => {
      document.title = 'Before Metadata';
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      await a.play();
    });
    await settle();
    const before = await reports(page);
    assert.equal(before[before.length - 1].payload.title, 'Before Metadata');

    // Streaming players set metadata once the track resolves, well after the
    // first play event. The reconcile tick is what has to catch this.
    await page.evaluate(() => {
      navigator.mediaSession.metadata = new MediaMetadata({
        title: 'Resolved Track',
        artist: 'Resolved Artist',
      });
    });
    await settle(RECONCILE_MS);
    const after = await reports(page);
    assert.ok(after.length > before.length, 'late metadata was never reported');
    assert.equal(after[after.length - 1].payload.title, 'Resolved Track');
    assert.equal(after[after.length - 1].payload.artist, 'Resolved Artist');
    assert.equal(after[after.length - 1].payload.playing, true);
  } finally {
    await page.close();
  }
});
