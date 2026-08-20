// Shared page harness for the media-session browser tiers (BGAUDIO-006/007/008,
// lib/services/media_session_shim.dart, dumped to
// test/js_fixtures/media_session/shim.js).
//
// Split across two test files because node:test's per-file timeout applies to
// the file-level test as well as each subtest, and real playback costs seconds
// per case. Everything the two share lives here.

const { readFixture } = require('./launch');

const SHIM = readFixture('media_session/shim.js');

// Event-driven reports clear a 300ms debounce; anything that has to wait for
// the shim's own 3s reconcile tick uses RECONCILE_MS.
const FIRST_REPORT_MS = 1500;
const RECONCILE_MS = 4000;

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

// Autoplay is forced on because the app sets
// `mediaPlaybackRequiresUserGesture = false` (lib/services/webview.dart).
const LAUNCH_ARGS = {
  args: [
    '--no-sandbox',
    '--disable-setuid-sandbox',
    '--autoplay-policy=no-user-gesture-required',
  ],
};

async function newShimPage(browser) {
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

// Wait until the reports satisfy `predicate`, then return them. For positive
// assertions ("the frame reported") this beats sleeping a fixed interval: it
// returns as soon as the report lands, and tolerates a loaded machine taking
// longer, instead of encoding one guess that is both slow and flaky. On
// timeout it returns whatever it has so the assertion prints a real diff
// rather than a timeout.
//
// Negative assertions ("nothing reported") cannot use this - there is no
// event to wait for, so they still have to sleep past the shim's reconcile.
async function waitForReports(page, predicate, { timeout = 10000, interval = 100 } = {}) {
  const deadline = Date.now() + timeout;
  for (;;) {
    const got = await reports(page);
    if (predicate(got)) return got;
    if (Date.now() >= deadline) return got;
    await settle(interval);
  }
}

module.exports = {
  FIRST_REPORT_MS,
  LAUNCH_ARGS,
  RECONCILE_MS,
  newShimPage,
  reports,
  settle,
  waitForReports,
};
