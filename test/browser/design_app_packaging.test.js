// The packed designer app has to boot from a subdirectory, inside an iframe,
// with no service worker: that is how the Claude Design project serves it, and
// none of it is exercised by a normal `flutter build web`. A wrong <base href>
// or a surviving service-worker registration produces a frame that loads,
// prints nothing, and renders an empty document.
//
// Needs `scripts/design_web.sh app && node tool/design_gallery/pack_app.js`;
// skipped when that output is absent, since CI does not build for web.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { setupBrowser, requireBrowser } = require('./helpers/launch');
const { serve } = require('../../tool/design_gallery/static_server');

const PACKED = path.resolve(__dirname, '..', '..', 'build', 'design_app_upload');
// Same resolution as tool/design_gallery/shoot.js: this sandbox ships Chromium
// at a fixed path rather than through puppeteer's own download.
const CHROMIUM = process.env.PUPPETEER_EXECUTABLE_PATH ||
  (fs.existsSync('/opt/pw-browsers/chromium') ? '/opt/pw-browsers/chromium' : undefined);
const state = setupBrowser({
  args: ['--no-sandbox', '--disable-setuid-sandbox', '--disable-gpu'],
  ...(CHROMIUM ? { executablePath: CHROMIUM } : {}),
});

function requirePacked(t) {
  if (fs.existsSync(path.join(PACKED, 'index.html'))) return true;
  t.skip('build/design_app_upload absent; run tool/design_gallery/pack_app.js');
  return false;
}

test('the packed app declares a relative base and no service worker', (t) => {
  if (!requirePacked(t)) return;
  const index = fs.readFileSync(path.join(PACKED, 'index.html'), 'utf8');
  assert.match(index, /<base href="\.\/">/);
  // The minified loader mentions serviceWorkerSettings in its own parameter
  // list; what must be gone is the call at the tail that passes one.
  const boot = fs.readFileSync(path.join(PACKED, 'flutter_bootstrap.js'), 'utf8');
  const call = boot.slice(boot.lastIndexOf('_flutter.buildConfig'));
  assert.ok(!call.includes('serviceWorkerSettings'), 'service worker settings survived packing');
  assert.ok(!fs.existsSync(path.join(PACKED, 'flutter_service_worker.js')));
});

test('it boots inside an iframe served from a subdirectory', async (t) => {
  if (!requireBrowser(state, t) || !requirePacked(t)) return;

  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ws-design-'));
  fs.cpSync(PACKED, path.join(root, 'app'), { recursive: true });
  fs.writeFileSync(
    path.join(root, 'card.html'),
    '<!doctype html><meta charset="utf-8"><body style="margin:0">' +
      '<iframe src="app/index.html" style="width:420px;height:780px;border:0"></iframe>',
  );

  const server = await serve(root, 8131);
  const page = await state.browser.newPage();
  try {
    await page.setViewport({ width: 460, height: 820 });
    await page.goto('http://127.0.0.1:8131/card.html', { waitUntil: 'load' });
    const frame = await page.waitForFrame((f) => f.url().endsWith('/app/index.html'), { timeout: 30000 });
    // The engine downloads ~12MB before the first frame; the glass pane is the
    // first thing that exists only once it has actually started rendering.
    await frame.waitForSelector('flt-glass-pane', { timeout: 60000 });
    const baseURI = await frame.evaluate(() => document.baseURI);
    assert.match(baseURI, /\/app\/$/);
  } finally {
    await page.close();
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
});
