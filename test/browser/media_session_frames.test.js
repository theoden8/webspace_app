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
  waitForReports,
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
      // Long enough that the observation window below cannot reach the end of
      // the clip, so no loop restart is involved. Looping a 2s clip across a
      // 4s wait meant a stall at the loop boundary on a loaded machine showed
      // up as a genuine playing:false from the *main* frame, failing an
      // assertion whose message blamed the iframe.
      a.src = wsMakeSilentWav(30);
      document.body.appendChild(a);
      await a.play();
      const d = document.querySelector('iframe').contentDocument;
      for (let i = 0; i < 5; i++) {
        d.getElementById('x').appendChild(d.createElement('b'));
      }
      return null;
    });
    assert.equal(frames, null);

    const got = await waitForReports(page, (r) => r.length >= 1);
    assert.ok(got.length >= 1, 'the main frame must still report');

    // This is the BGAUDIO-008 invariant: exactly one frame speaks for the
    // site. If the media-less iframe had reported anything, playing:false
    // included, its own token would be here as a second entry.
    const tokens = new Set(got.map((r) => r.payload.frame));
    assert.equal(tokens.size, 1, 'only the playing frame may report');
    assert.match(got[0].payload.frame, /^f[a-z0-9]+$/);

    // Asserted separately, and only of the frame that is actually playing.
    // Requiring it of *every* report conflated "the iframe stayed silent"
    // with "playback never hiccuped", and only the first is the invariant.
    assert.ok(
      got.some((r) => r.payload.playing === true),
      'the playing frame must report playing:true',
    );
  } finally {
    await page.close();
  }
});
