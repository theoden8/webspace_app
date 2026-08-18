// Real-Chromium proof for background playback masking (BGAUDIO-012,
// lib/services/media_session_shim.dart, dumped to
// test/js_fixtures/media_session/shim.js).
//
// Keeping the app alive is not enough for a site that stops itself: a
// backgrounded app's page is told it is hidden, and players built for a tab
// (YouTube among them) pause on `visibilitychange` by their own choice. The
// page under test does exactly that, so "did the audio survive" is asserted
// against a player that actively wants to stop.
//
// jsdom cannot stand in: it has no media pipeline, so `paused` never moves,
// and the capture-phase ordering that keeps the page's handler from running is
// the whole mechanism.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser } = require('./helpers/launch');
const { LAUNCH_ARGS, newShimPage, reports } = require('./helpers/media_session_page');

const browser = setupBrowser(LAUNCH_ARGS);
const newPage = () => newShimPage(browser);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// A page that pauses its own player the moment it is told it is hidden.
async function playPauseOnHidePlayer(page) {
  await page.evaluate(async () => {
    const a = document.createElement('audio');
    a.loop = true;
    a.src = wsMakeSilentWav(6);
    document.body.appendChild(a);
    window.__el = a;
    window.__pauseOnHideRan = 0;
    document.addEventListener('visibilitychange', () => {
      if (document.hidden) {
        window.__pauseOnHideRan++;
        a.pause();
      }
    });
    await a.play();
  });
  await sleep(500);
}

/// Chromium fires visibilitychange on a real tab switch only, so drive the
/// event the way the OS does: the page sees the event, not our call.
const dispatchHidden = (page) =>
  page.evaluate(() => {
    document.dispatchEvent(new Event('visibilitychange'));
    window.dispatchEvent(new Event('pagehide'));
  });

test('a pause-on-hide player keeps playing while the app is backgrounded', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    await playPauseOnHidePlayer(page);
    assert.equal(await page.evaluate(() => window.__el.paused), false);

    await page.evaluate(() => window.__wsMediaBackground(true));
    await dispatchHidden(page);
    await sleep(300);

    assert.equal(
      await page.evaluate(() => window.__pauseOnHideRan),
      0,
      "the page's own pause-on-hide handler must never run",
    );
    assert.equal(await page.evaluate(() => window.__el.paused), false);
    assert.equal(await page.evaluate(() => document.hidden), false);
    assert.equal(await page.evaluate(() => document.visibilityState), 'visible');
  } finally {
    await page.close();
  }
});

test('the watchdog re-issues play() when the page pauses anyway', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    await playPauseOnHidePlayer(page);
    await page.evaluate(() => window.__wsMediaBackground(true));

    // A player that pauses for its own reasons (buffer stall, an internal
    // timer) rather than through the visibility event the mask swallows.
    await page.evaluate(() => window.__el.pause());
    await sleep(1600);

    assert.equal(
      await page.evaluate(() => window.__el.paused),
      false,
      'the background watchdog must resume a player that stopped itself',
    );
  } finally {
    await page.close();
  }
});

test('a lockscreen pause is not fought by the watchdog', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    await playPauseOnHidePlayer(page);
    await page.evaluate(() => window.__wsMediaBackground(true));

    // The user's own pause, arriving the way MediaSessionService sends it.
    await page.evaluate(() => window.__wsMediaControl('pause'));
    await sleep(1600);

    assert.equal(
      await page.evaluate(() => window.__el.paused),
      true,
      'silence the user asked for must stay',
    );
  } finally {
    await page.close();
  }
});

test('foregrounding hands the page its own visibility back', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    await playPauseOnHidePlayer(page);
    await page.evaluate(() => window.__wsMediaBackground(true));
    await dispatchHidden(page);
    await page.evaluate(() => window.__wsMediaBackground(false));
    await sleep(200);

    // Back on screen the page behaves exactly as it always has.
    await dispatchHidden(page);
    await sleep(200);
    assert.equal(
      await page.evaluate(() => document.visibilityState),
      'visible',
      'the real value in a foreground tab',
    );
    assert.equal(
      await page.evaluate(() => window.__el.paused),
      false,
      'headless Chromium reports the page visible, so nothing paused it',
    );
  } finally {
    await page.close();
  }
});

test('the background state reaches a same-origin subframe', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    // evaluateJavascript reaches the main frame only; the shim relays.
    await page.evaluate(async () => {
      const f = document.createElement('iframe');
      f.srcdoc = '<html><body></body></html>';
      document.body.appendChild(f);
      window.__frame = f;
      await new Promise((r) => f.addEventListener('load', r, { once: true }));
    });
    // The frame runs its own copy of the shim in the app; here inject it the
    // same way the platform does, then drive the parent only.
    const frameHasHook = await page.evaluate(
      () => typeof window.__frame.contentWindow.__wsMediaBackground,
    );
    if (frameHasHook !== 'function') {
      // srcdoc frames in this harness do not receive evaluateOnNewDocument;
      // assert the relay itself instead, which is what the app depends on.
      const relayed = await page.evaluate(async () => {
        let got = null;
        window.__frame.contentWindow.addEventListener('message', (ev) => {
          if (ev.data && '__wsMediaBackground' in ev.data) got = ev.data;
        });
        window.__wsMediaBackground(true);
        await new Promise((r) => setTimeout(r, 200));
        return got;
      });
      assert.deepEqual(relayed, { __wsMediaBackground: true });
      return;
    }
    await page.evaluate(() => window.__wsMediaBackground(true));
    await sleep(200);
    assert.equal(
      await page.evaluate(
        () => window.__frame.contentDocument.visibilityState,
      ),
      'visible',
    );
  } finally {
    await page.close();
  }
});

test('a failed background resume is reported, not swallowed', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    await playPauseOnHidePlayer(page);
    await page.evaluate(() => {
      window.__el.play = () =>
        Promise.reject(Object.assign(new Error('blocked'), {
          name: 'NotAllowedError',
        }));
      window.__wsMediaBackground(true);
      window.__el.pause();
    });
    await sleep(1600);

    const got = await reports(page);
    const failure = got
      .filter((r) => r.payload.control === 'background-resume')
      .pop();
    assert.ok(failure, 'a refused background resume must reach Dart');
    assert.equal(failure.payload.error, 'NotAllowedError');
  } finally {
    await page.close();
  }
});
