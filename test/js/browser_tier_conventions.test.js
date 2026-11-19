// The browser tier boots a fresh Chromium per file through one helper and
// injects page scripts where a production webview does (SHIM-TEST-006).
//
// A source gate (rung 5): which helper a test file calls and the order it
// registers scripts in are text, and the tier skips locally without a
// browser. Two files launch per test instead, each with its own proxy
// flags, which a per-file browser cannot give; they are named below, a list
// that only shrinks.

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');

const DIR = 'test/browser';
const PER_TEST_LAUNCH = {
  'proxy_baseline.test.js': 'each test launches with its own --proxy-server',
  'proxy_router_credential_isolation.test.js': 'each test launches with its own --proxy-server',
};

const files = fs.readdirSync(path.join(__dirname, '..', '..', DIR))
  .filter((f) => f.endsWith('.test.js'));

test('SHIM-TEST-006: every browser-tier file boots its Chromium through setupBrowser', () => {
  assert.ok(files.length > 0);
  for (const f of files) {
    const src = code(read(`${DIR}/${f}`));
    if (f in PER_TEST_LAUNCH) {
      assert.match(src, /puppeteer\.launch\(/, `${f} still launches per test, or leaves the list`);
      continue;
    }
    assert.match(src, /\bsetupBrowser\(/, `${f} boots Chromium through setupBrowser()`);
    assert.doesNotMatch(src, /puppeteer\.launch\(/, `${f} launches no browser of its own`);
  }
});

test('SHIM-TEST-006: setupBrowser launches per file without the sandbox and closes after', () => {
  const launch = code(read(`${DIR}/helpers/launch.js`));
  const body = launch.slice(launch.indexOf('function setupBrowser'));
  assert.match(body, /test\.before\(/);
  assert.match(body, /args:\s*\['--no-sandbox',\s*'--disable-setuid-sandbox'\]/);
  assert.match(body, /test\.after\([\s\S]*?\.close\(\)/);
});

test('SHIM-TEST-006: a pre-init script is registered before the shim', () => {
  const src = code(read(`${DIR}/location_spoof_real.test.js`));
  const helper = src.slice(src.indexOf('async function withShim'));
  const pre = helper.indexOf('evaluateOnNewDocument(preInit)');
  const shim = helper.indexOf('evaluateOnNewDocument(shim)');
  assert.ok(pre >= 0 && shim >= 0, 'withShim registers both');
  assert.ok(pre < shim, 'the test\'s fake is in place before the shim captures the real one');
});

test('SHIM-TEST-006: the desktop-mode shim injected after load says why', () => {
  const raw = read(`${DIR}/desktop_mode_real.test.js`);
  const consts = [...raw.matchAll(/const (\w+) = pageJs\('desktop_mode'/g)].map((m) => m[1]);
  assert.ok(consts.length > 0);
  const lines = raw.split('\n');
  let sites = 0;
  lines.forEach((line, i) => {
    const m = line.match(/page\.evaluate\((\w+)\)/);
    if (!m || !consts.includes(m[1])) return;
    sites++;
    const before = lines.slice(Math.max(0, i - 25), i).join('\n');
    assert.match(before, /\/\/.*evaluateOnNewDocument/,
      `line ${i + 1}: a post-load injection names the injection point it departs from`);
    assert.match(before, /\/\/.*documentElement/,
      `line ${i + 1}: and why (documentElement does not exist yet under Puppeteer)`);
  });
  assert.ok(sites > 0, 'the post-load path is still exercised');
});
