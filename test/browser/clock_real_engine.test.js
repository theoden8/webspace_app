// ETP-012 in real Chromium: the clocks a page can read directly are rounded
// together, so none of them hands back the engine's resolution, and an event
// or a frame never reads later than a performance.now() taken after it. jsdom
// stamps events in epoch milliseconds, so only a real engine can show the
// clocks agree.
const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, pageJs } = require('./helpers/launch');

const SHIM = pageJs('anti_fingerprinting', { seed: 'alpha-fixture-seed', letterbox: false });
const browser = setupBrowser();

function readClocks() {
  return new Promise((done) => {
    requestAnimationFrame((frame) => {
      const channel = new MessageChannel();
      channel.port1.onmessage = (e) => {
        done({
          frame,
          event: e.timeStamp,
          after: performance.now(),
          timeOrigin: performance.timeOrigin,
          dateNow: Date.now(),
        });
      };
      channel.port2.postMessage(null);
    });
  });
}

test('every clock a page reads directly is in whole 5 ms steps', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  await page.setContent('<!doctype html><html><body></body></html>');
  await page.addScriptTag({ content: SHIM });
  for (let i = 0; i < 20; i++) {
    const c = await page.evaluate(readClocks);
    for (const [name, value] of Object.entries(c)) {
      assert.equal(value % 5, 0, `${name}=${value} is not a whole step`);
    }
    assert.ok(c.event <= c.after, `the event read ${c.event}, after it now() read ${c.after}`);
    assert.ok(c.frame <= c.after, `the frame read ${c.frame}, after it now() read ${c.after}`);
  }
  await page.close();
});
