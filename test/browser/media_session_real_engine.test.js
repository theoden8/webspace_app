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
// Multi-frame reporting (BGAUDIO-008) lives in media_session_frames.test.js:
// node:test's per-file timeout covers the file-level test too, and real
// playback costs seconds per case.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser } = require('./helpers/launch');
const {
  LAUNCH_ARGS,
  RECONCILE_MS,
  newShimPage,
  reports,
  settle,
} = require('./helpers/media_session_page');

const browser = setupBrowser(LAUNCH_ARGS);

const newPage = () => newShimPage(browser);

test('reports playing:true with page metadata once audio actually plays', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
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
    // Opaque per-frame token; media_session_frames.test.js owns its semantics.
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
  const page = await newPage();
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
  const page = await newPage();
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
  const page = await newPage();
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

test('a transport that reaches nothing is reported, not swallowed', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    // "I hit play and nothing happened" is silent at every layer above the
    // page: no element, or an engine that refuses to start playback, look
    // identical to a dead bridge. Only the failure is reported, so the
    // ordinary playing/paused sequence above is unaffected.
    await page.evaluate(() => window.__wsMediaControl('play'));
    await settle();
    let got = await reports(page);
    assert.equal(got.length, 1, 'a control with no media must say so');
    assert.equal(got[0].payload.control, 'play');
    assert.equal(got[0].payload.error, 'no-media-element');

    const refused = await page.evaluate(async () => {
      const a = document.createElement('audio');
      a.src = wsMakeSilentWav(2);
      document.body.appendChild(a);
      // Reject the way a suspended/blocked engine does, which is the state
      // the iOS lockscreen play lands in.
      a.play = () =>
        Promise.reject(Object.assign(new Error('blocked'), {
          name: 'NotAllowedError',
        }));
      window.__wsMediaControl('play');
      await new Promise((r) => setTimeout(r, 200));
      return true;
    });
    assert.equal(refused, true);
    await settle();
    got = await reports(page);
    const failure = got.filter((r) => r.payload.control === 'play').pop();
    assert.equal(failure.payload.error, 'NotAllowedError');
  } finally {
    await page.close();
  }
});

test('does not re-report unchanged state', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
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

test('reports metadata that arrives after playback started', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
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
