// Shared Puppeteer/Chromium harness for tests under test/browser/.
//
// jsdom-based tests (test/js/) prove the shim builders emit the right
// JS shape. These browser tests prove the shim's effect under a real
// engine — real CSS evaluation in matchMedia, real Intl/Date timezone
// semantics, real Geolocation callback paths, real CSP enforcement,
// real RTCPeerConnection class semantics. Anything the jsdom layer
// can't simulate honestly belongs here.

const test = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

let puppeteer;
try {
  puppeteer = require('puppeteer');
} catch (_) {
  // Whole tier becomes inert; requireBrowser handles the message.
}

const FIXTURES_ROOT = path.resolve(__dirname, '..', '..', 'js_fixtures');

function readFixture(rel) {
  return fs.readFileSync(path.join(FIXTURES_ROOT, rel), 'utf8');
}

// Register before/after hooks at module load so each test file gets
// its own Chromium process. Returns a state object the tests close
// over; populate inside `before` so failures surface there, not at
// module load.
function setupBrowser(launchOpts = {}) {
  const state = { browser: null, error: null };
  test.before(async () => {
    if (!puppeteer) {
      state.error = new Error('puppeteer not installed');
      return;
    }
    try {
      state.browser = await puppeteer.launch({
        headless: true,
        args: ['--no-sandbox', '--disable-setuid-sandbox'],
        ...launchOpts,
      });
    } catch (e) {
      state.error = e;
    }
  });
  test.after(async () => {
    if (state.browser) await state.browser.close();
  });
  return state;
}

// Tests evaluate this at body time, not at registration time, because
// node:test resolves the `skip` option before `before` has populated
// the state. CI hard-fails so a missing Chromium can't silently turn
// the tier into a no-op; locally it just skips so devs without a
// downloaded Chromium aren't blocked.
function requireBrowser(state, t) {
  if (state.browser) return true;
  const reason = state.error ? state.error.message : 'unknown';
  const msg = `Puppeteer/Chromium not available: ${reason}`;
  if (process.env.CI === 'true') {
    throw new Error(
      msg + ' (CI=true hard-fails; install via `npx puppeteer browsers install chrome`)');
  }
  t.skip(msg);
  return false;
}

module.exports = { setupBrowser, requireBrowser, readFixture };
