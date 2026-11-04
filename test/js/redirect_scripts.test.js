// The redirect scripts this repository writes for the adblock library to
// serve (rust/webspace_adblock/resources/, CB-010), each run in jsdom against
// the API its header documents and held to the page scripts' ESLint. Which
// names serve a script, and that each file is served at all, is the crate's
// own test (src/redirect_resources.rs). jsdom is not an engine: these hold the
// shape of what a script leaves on the page.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { VirtualConsole } = require('jsdom');
const { read, files } = require('./helpers/source');
const { makeDom } = require('./helpers/load_shim');
const { pageEslint } = require('./helpers/page_eslint');

const DIR = 'rust/webspace_adblock/resources';
const SCRIPTS = new Map(files(DIR, /\.js$/).map((rel) => [path.basename(rel), read(rel)]));
const tick = () => new Promise((resolve) => setTimeout(resolve, 20));

/** A page that ran [name], and the own properties it added to the window. */
function run(name, { html, virtualConsole, before } = {}) {
  const dom = makeDom({ html, virtualConsole });
  before?.(dom.window);
  const had = new Set(Object.getOwnPropertyNames(dom.window));
  dom.window.eval(SCRIPTS.get(name));
  const added = Object.getOwnPropertyNames(dom.window).filter((k) => !had.has(k)).sort();
  return { window: dom.window, added };
}

const BOILERPLATE = '<style amp-boilerplate>body{animation:-amp-start 8s steps(1,end) 0s 1 normal both}</style>';
const hex32 = /^[0-9a-f]{32}$/;

// Each script: the globals it adds, and the API its header documents.
const CHECKS = {
  'nofab.js': {
    globals: ['BlockAdBlock', 'FuckAdBlock', 'blockAdBlock', 'fuckAdBlock'],
    async check() {
      const { window } = run('nofab.js');
      for (const [type, instance] of [['FuckAdBlock', 'fuckAdBlock'], ['BlockAdBlock', 'blockAdBlock']]) {
        const detector = window[instance];
        assert.ok(detector instanceof window[type], `${instance} is a ${type}`);
        const calls = [];
        assert.equal(detector.onDetected(() => calls.push('detected')), detector);
        assert.equal(detector.on(true, () => calls.push('detected')), detector);
        assert.equal(detector.onNotDetected(() => calls.push('not detected')), detector);
        assert.equal(detector.on(false, () => calls.push('not detected, by on')), detector);
        assert.deepEqual(calls, [], 'a handler runs a tick later, as after a check');
        await tick();
        assert.deepEqual(calls, ['not detected', 'not detected, by on']);
        assert.equal(detector.check(), true);
        await tick();
        assert.equal(calls.length, 2, 'each handler runs once');

        detector.onNotDetected(() => calls.push('cleared'));
        assert.equal(detector.clearEvent(), detector);
        await tick();
        detector.onNotDetected(() => calls.push('emitted'));
        assert.equal(detector.emitEvent(true), detector);
        assert.equal(calls.length, 2, 'a detection runs no handler');
        detector.emitEvent(false);
        assert.deepEqual(calls.slice(2), ['emitted'], 'emitEvent(false) runs the waiting ones now');
        await tick();
        assert.equal(calls.length, 3);
        assert.equal(detector.setOption({ checkOnLoad: false }), detector);
        assert.equal(detector.setOption('debug', true), detector);
        assert.ok(new window[type]({ checkOnLoad: true }) instanceof window[type]);
      }
      const kept = run('nofab.js', { before: (w) => { w.fuckAdBlock = false; } });
      assert.equal(kept.window.fuckAdBlock, false, "a page's own value stops the instance being made");
      assert.equal(typeof kept.window.blockAdBlock.check, 'function');
    },
  },
  'noeval.js': {
    globals: [],
    async check() {
      const warned = [];
      const virtualConsole = new VirtualConsole();
      virtualConsole.on('warn', (...args) => warned.push(args));
      const { window } = run('noeval.js', { virtualConsole });
      assert.equal(window.eval('globalThis.ran = 1; 2'), undefined);
      assert.equal(window.ran, undefined, 'the code did not run');
      assert.equal(window.Function('return 2')(), 2, 'Function() still runs');
      assert.deepEqual(warned, [['eval() was kept from running', 'globalThis.ran = 1; 2']]);
    },
  },
  'noeval-silent.js': {
    globals: [],
    async check() {
      const said = [];
      const virtualConsole = new VirtualConsole();
      for (const level of ['log', 'info', 'warn', 'error']) virtualConsole.on(level, (...args) => said.push(args));
      const { window } = run('noeval-silent.js', { virtualConsole });
      assert.equal(window.eval('globalThis.ran = 1; 2'), undefined);
      assert.equal(window.ran, undefined, 'the code did not run');
      assert.equal(window.Function('return 2')(), 2, 'Function() still runs');
      assert.deepEqual(said, [], 'and nothing is said');
    },
  },
  'popads.js': {
    globals: ['PopAds', 'popns'],
    async check() {
      const { window } = run('popads.js');
      for (const name of ['PopAds', 'popns']) {
        assert.equal(window[name], undefined);
        assert.throws(() => { window[name] = {}; }, (e) => e.name === 'ReferenceError', `a write to ${name}`);
        assert.throws(() => Object.defineProperty(window, name, { value: 1 }), (e) => e.name === 'TypeError',
          `${name} cannot be redefined`);
      }
      const kept = run('popads.js', {
        before: (w) => Object.defineProperty(w, 'popns', { value: 'the page', configurable: false }),
      });
      assert.equal(kept.window.popns, 'the page', 'a name the page fixed is left as it is');
      assert.throws(() => { kept.window.PopAds = {}; }, (e) => e.name === 'ReferenceError');
    },
  },
  'prebid-ads.js': {
    globals: ['canRunAds', 'isAdBlockActive'],
    async check() {
      const { window } = run('prebid-ads.js');
      assert.equal(window.canRunAds, true);
      assert.equal(window.isAdBlockActive, false);
    },
  },
  'fingerprint2.js': {
    globals: ['Fingerprint2'],
    async check() {
      const { Fingerprint2 } = run('fingerprint2.js').window;
      const id = Fingerprint2.x64hash128('a', 31);
      assert.match(id, hex32);
      assert.equal(Fingerprint2.x64hash128('b', 0), id, 'one id for the page load');
      const got = [];
      Fingerprint2.get((components) => got.push(['get', components]));
      Fingerprint2.get({ excludes: { userAgent: true } }, (components) => got.push(['get with options', components]));
      Fingerprint2.getV18({}, (result, components) => got.push(['getV18', result, components]));
      new Fingerprint2({}).get((result, components) => got.push(['1.8', result, components]));
      assert.deepEqual(got, [], 'a callback runs a tick later');
      await tick();
      assert.deepEqual(got.map(([call, ...rest]) => [call, ...rest.map((v) => (Array.isArray(v) ? v.length : v))]), [
        ['get', 0], ['get with options', 0], ['getV18', id, 0], ['1.8', id, 0],
      ]);
      assert.equal((await Fingerprint2.getPromise({})).length, 0);
      assert.deepEqual([Fingerprint2.NOT_AVAILABLE, Fingerprint2.ERROR, Fingerprint2.EXCLUDED],
        ['not available', 'error', 'excluded']);
      assert.notEqual(run('fingerprint2.js').window.Fingerprint2.x64hash128('a', 31), id, 'another load, another id');
    },
  },
  'fingerprint3.js': {
    globals: ['FingerprintJS'],
    async check() {
      const { FingerprintJS } = run('fingerprint3.js').window;
      const result = await (await FingerprintJS.load({ monitoring: false })).get();
      assert.match(result.visitorId, hex32);
      assert.equal(result.confidence.score, 0);
      assert.deepEqual(Object.keys(result.components), []);
      assert.equal(result.version, '3.4.2');
      assert.equal(FingerprintJS.hashComponents(result.components), result.visitorId);
      assert.equal(FingerprintJS.componentsToDebugString(result.components), '{}');
      const again = await (await run('fingerprint3.js').window.FingerprintJS.load()).get();
      assert.notEqual(again.visitorId, result.visitorId, 'another load, another id');
    },
  },
  'ampproject_v0.js': {
    globals: [],
    async check() {
      const html = `<!doctype html><html><head>${BOILERPLATE}<style amp-custom>p{}</style></head><body><p>x</p></body></html>`;
      const { document } = run('ampproject_v0.js', { html }).window;
      assert.equal(document.querySelectorAll('style[amp-boilerplate]').length, 0, 'the boilerplate is lifted');
      assert.equal(document.querySelectorAll('style[amp-custom]').length, 1, "the page's own style stays");

      const parsing = run('ampproject_v0.js', {
        before: (w) => Object.defineProperty(w.document, 'readyState', { get: () => 'loading', configurable: true }),
      }).window;
      parsing.document.head.insertAdjacentHTML('beforeend', BOILERPLATE);
      assert.equal(parsing.document.querySelectorAll('style[amp-boilerplate]').length, 1);
      parsing.document.dispatchEvent(new parsing.Event('DOMContentLoaded'));
      assert.equal(parsing.document.querySelectorAll('style[amp-boilerplate]').length, 0,
        'one parsed after the script is lifted once the document is');
    },
  },
};

test('every redirect script this repository writes has its checks (CB-010)', () => {
  assert.deepEqual([...SCRIPTS.keys()].sort(), Object.keys(CHECKS).sort());
});

for (const [name, { globals, check }] of Object.entries(CHECKS)) {
  test(`${name} adds only the globals it stands in for (CB-010)`, () => {
    if (!SCRIPTS.has(name)) return;
    assert.deepEqual(run(name).added, [...globals].sort());
  });

  test(`${name} gives the page the API its header documents (CB-010)`, async () => {
    if (!SCRIPTS.has(name)) return;
    await check();
  });

  test(`${name} passes the page scripts' ESLint`, async () => {
    if (!SCRIPTS.has(name)) return;
    const source = SCRIPTS.get(name);
    const [result] = await pageEslint.lintText(source, { filePath: name });
    const lines = source.split('\n');
    assert.deepEqual(result.messages.map((m) => `${m.ruleId}: ${m.message} — ${(lines[m.line - 1] || '').trim()}`), []);
  });
}
