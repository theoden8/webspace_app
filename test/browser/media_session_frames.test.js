// BGAUDIO-008: the media shim is injected with `forMainFrameOnly: false`, so
// every frame of the site runs a copy against the single `wsMediaSession`
// handler. Only the frame that is playing may speak for the site.
//
// Separate file from media_session_real_engine.test.js because node:test's
// per-file timeout applies to the file-level test as well as each subtest, and
// real playback costs seconds per case.

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

test('a frame with no media of its own never reports', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
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
