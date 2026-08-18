// Real-Chromium proof for the media stop (BGAUDIO-009,
// lib/services/media_session_shim.dart `buildMediaPauseJs`, dumped to
// test/js_fixtures/media_session/pause_media.js).
//
// This is the snippet the app evaluates on a site WITHOUT the background-audio
// toggle when it loses the screen. jsdom cannot prove anything about it:
// `paused` and `currentTime` never move there, so a page that never stopped
// playing looks identical to one that did. Here real audio plays in headless
// Chromium and the assertion is the element's own state.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, readFixture } = require('./helpers/launch');
const { LAUNCH_ARGS, newShimPage } = require('./helpers/media_session_page');

const PAUSE_JS = readFixture('media_session/pause_media.js');

const browser = setupBrowser(LAUNCH_ARGS);

// The page harness is shared with the BGAUDIO-006 tiers: it installs the
// bridge stub and `wsMakeSilentWav`. The media-session shim it also installs
// is inert here — it only reports, it never pauses anything.
const newPage = () => newShimPage(browser);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('a playing element is paused and stops advancing', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    const played = await page.evaluate(async () => {
      const a = document.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(4);
      document.body.appendChild(a);
      window.__el = a;
      try {
        await a.play();
        return true;
      } catch (e) {
        return e.name;
      }
    });
    assert.equal(played, true, 'autoplay must be allowed in this tier');
    await sleep(600);

    const before = await page.evaluate(() => ({
      paused: window.__el.paused,
      t: window.__el.currentTime,
    }));
    assert.equal(before.paused, false, 'precondition: audio is playing');
    assert.ok(before.t > 0, 'precondition: playback advanced');

    await page.evaluate(PAUSE_JS);

    const after = await page.evaluate(() => ({
      paused: window.__el.paused,
      t: window.__el.currentTime,
    }));
    assert.equal(after.paused, true, 'the element must be paused');

    // The reported bug in one assertion: the audio kept going after the site
    // lost the screen.
    await sleep(700);
    const later = await page.evaluate(() => window.__el.currentTime);
    assert.equal(
      later,
      after.t,
      `currentTime advanced from ${after.t} to ${later} — still playing`,
    );
  } finally {
    await page.close();
  }
});

test('every playing element is caught, video included', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    await page.evaluate(async () => {
      window.__els = [];
      for (let i = 0; i < 2; i++) {
        const a = document.createElement('audio');
        a.loop = true;
        a.src = wsMakeSilentWav(4);
        document.body.appendChild(a);
        window.__els.push(a);
      }
      const canvas = document.createElement('canvas');
      canvas.width = 32;
      canvas.height = 32;
      canvas.getContext('2d').fillRect(0, 0, 32, 32);
      const v = document.createElement('video');
      v.muted = true;
      v.playsInline = true;
      v.srcObject = canvas.captureStream(10);
      document.body.appendChild(v);
      window.__els.push(v);
      await Promise.all(window.__els.map((e) => e.play().catch(() => {})));
    });
    await sleep(600);
    assert.deepEqual(
      await page.evaluate(() => window.__els.map((e) => e.paused)),
      [false, false, false],
      'precondition: all three playing',
    );

    await page.evaluate(PAUSE_JS);

    assert.deepEqual(
      await page.evaluate(() => window.__els.map((e) => e.paused)),
      [true, true, true],
    );
  } finally {
    await page.close();
  }
});

test('a player in a same-origin iframe is caught too', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    // evaluateJavascript reaches the main frame only, so the snippet walks
    // same-origin frames itself.
    await page.evaluate(async () => {
      const f = document.createElement('iframe');
      document.body.appendChild(f);
      window.__frame = f;
      const d = f.contentDocument;
      const a = d.createElement('audio');
      a.loop = true;
      a.src = wsMakeSilentWav(4);
      d.body.appendChild(a);
      await a.play().catch(() => {});
    });
    await sleep(600);
    const paused = () =>
      page.evaluate(
        () => window.__frame.contentDocument.querySelector('audio').paused,
      );
    assert.equal(await paused(), false, 'precondition: iframe audio playing');

    await page.evaluate(PAUSE_JS);
    assert.equal(await paused(), true);
  } finally {
    await page.close();
  }
});

test('an already-paused element is left alone and no media is fine', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await newPage();
  try {
    // No media at all: the snippet must not throw, or every later injected
    // script in the same evaluation would be skipped.
    assert.equal(await page.evaluate(`${PAUSE_JS}; 'ok';`), 'ok');

    await page.evaluate(async () => {
      const a = document.createElement('audio');
      a.src = wsMakeSilentWav(4);
      document.body.appendChild(a);
      window.__el = a;
      await a.play().catch(() => {});
      a.pause();
      a.currentTime = 0;
      window.__pauseEvents = 0;
      a.addEventListener('pause', () => {
        window.__pauseEvents++;
      });
    });

    // Let the `pause` event from the setup above land before counting.
    await sleep(300);
    await page.evaluate(() => {
      window.__pauseEvents = 0;
    });

    await page.evaluate(PAUSE_JS);
    await page.evaluate(PAUSE_JS);
    await sleep(300);

    // Re-pausing would fire spurious `pause` events at the site's own player,
    // which listens to them (the media-session shim reports off them).
    assert.equal(await page.evaluate(() => window.__pauseEvents), 0);
    assert.equal(await page.evaluate(() => window.__el.paused), true);
  } finally {
    await page.close();
  }
});
