// Tier 1 — jsdom assertions for the passkey block shim
// (buildPasskeyBlockShim in lib/services/passkey_shim.dart, dumped to
// test/js_fixtures/passkey/block_shim.js).
//
// On iOS and macOS the WebView is WebKit, which answers WebAuthn itself
// through AuthenticationServices in the app's process. Where a site's
// passkeys are off (an archive-tier site's) this shim is all
// that stands between the page and WebKit's own implementation
// (PASSKEY-013). The realm is given what WebKit exposes: a
// `CredentialsContainer`, and a `PublicKeyCredential` whose static methods
// answer the way an entitled build would. Every engine entry point records
// its calls, so "the engine was never asked" is observable.
// test/browser/passkey_block_real_engine.test.js repeats the central cases
// against a real engine with a virtual authenticator behind it.

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, readFixture } = require('./helpers/load_shim');
const { read, blockAfter, dartFiles, code } = require('./helpers/source');

const SHIM = readFixture('passkey/block_shim.js');

const _doms = [];
afterEach(() => {
  while (_doms.length) {
    try { _doms.pop().window.close(); } catch (_) { /* closed */ }
  }
});

const STATICS = [
  'isUserVerifyingPlatformAuthenticatorAvailable',
  'isConditionalMediationAvailable',
  'getClientCapabilities',
  'signalUnknownCredential',
  'signalAllAcceptedCredentials',
  'signalCurrentUserDetails',
];

function setup({ credentials = true, pkc = true, statics = STATICS } = {}) {
  const dom = makeDom({ url: 'https://login.example.com/' });
  _doms.push(dom);
  const { window } = dom;
  window.__engineCalls = [];
  window.eval(`
    class Credential {}
    class CredentialsContainer {}
    CredentialsContainer.prototype.create = function create() {
      __engineCalls.push('create');
      return Promise.resolve({ engine: 'create' });
    };
    CredentialsContainer.prototype.get = function get() {
      __engineCalls.push('get');
      return Promise.resolve({ engine: 'get' });
    };
    window.Credential = Credential;
    window.CredentialsContainer = CredentialsContainer;
  `);
  if (credentials) {
    window.eval(`Object.defineProperty(navigator, 'credentials',
      { value: new CredentialsContainer(), configurable: true });`);
  }
  if (pkc) {
    window.eval(`
      class PublicKeyCredential extends Credential {}
      window.PublicKeyCredential = PublicKeyCredential;
    `);
    for (const name of statics) {
      window.eval(`PublicKeyCredential.${name} = function ${name}(${name.startsWith('signal') ? 'options' : ''}) {
        __engineCalls.push(${JSON.stringify(name)});
        return Promise.resolve(${name.startsWith('is') ? 'true' : name === 'getClientCapabilities' ? '{ passkeyPlatformAuthenticator: true }' : 'undefined'});
      };`);
    }
  }
  window.eval(SHIM);
  const plain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)));
  const run = (code) => {
    const v = window.eval(code);
    return v && typeof v.then === 'function' ? v.then(plain) : plain(v);
  };
  const outcome = (code) => run(`(${code}).then(
    function (v) { return { ok: true, value: v }; },
    function (e) { return { ok: false, name: e && e.name, message: e && e.message }; })`);
  const engineCalls = () => Array.from(window.__engineCalls);
  return { window, run, outcome, engineCalls };
}

const CREATE = `navigator.credentials.create({ publicKey: {
  rp: { name: 'Example' },
  user: { id: new Uint8Array([1]), name: 'alice', displayName: 'Alice' },
  challenge: new Uint8Array([1, 2, 3]),
  pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
} })`;

const GET = `navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1, 2, 3]) } })`;

test('a public-key create is refused before WebKit sees it', async () => {
  const { outcome, engineCalls } = setup();
  const out = await outcome(CREATE);
  assert.equal(out.ok, false);
  assert.equal(out.name, 'NotAllowedError');
  assert.deepEqual(engineCalls(), []);
});

test('a public-key get is refused, conditional mediation included', async () => {
  const { outcome, engineCalls } = setup();
  assert.equal((await outcome(GET)).name, 'NotAllowedError');
  const conditional = await outcome(
    `navigator.credentials.get({ mediation: 'conditional', publicKey: { challenge: new Uint8Array([1]) } })`);
  assert.equal(conditional.name, 'NotAllowedError');
  assert.deepEqual(engineCalls(), []);
});

test('an aborted signal rejects with its reason, as the engine would', async () => {
  const { outcome, engineCalls } = setup();
  const out = await outcome(`(function () {
    var c = new AbortController();
    c.abort(new DOMException('page gave up', 'AbortError'));
    return navigator.credentials.get({ signal: c.signal, publicKey: { challenge: new Uint8Array([1]) } });
  })()`);
  assert.equal(out.name, 'AbortError');
  assert.equal(out.message, 'page gave up');
  assert.deepEqual(engineCalls(), []);
});

test('requests without publicKey are the engine\'s', async () => {
  const { outcome, engineCalls } = setup();
  assert.deepEqual(await outcome('navigator.credentials.get({ password: true })'),
    { ok: true, value: { engine: 'get' } });
  assert.deepEqual(await outcome('navigator.credentials.create({ password: {} })'),
    { ok: true, value: { engine: 'create' } });
  assert.deepEqual(await outcome('navigator.credentials.get()'),
    { ok: true, value: { engine: 'get' } });
  assert.deepEqual(engineCalls(), ['get', 'create', 'get']);
});

test('availability reads false and never asks WebKit', async () => {
  const { run, engineCalls } = setup();
  assert.equal(await run('PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()'), false);
  assert.equal(await run('PublicKeyCredential.isConditionalMediationAvailable()'), false);
  const caps = await run('PublicKeyCredential.getClientCapabilities()');
  assert.ok(Object.keys(caps).length > 0);
  for (const [key, value] of Object.entries(caps)) assert.equal(value, false, key);
  assert.deepEqual(engineCalls(), []);
});

test('the Signal API reaches no credential store', async () => {
  const { run, engineCalls } = setup();
  assert.equal(await run(
    "PublicKeyCredential.signalUnknownCredential({ rpId: 'example.com', credentialId: 'AAAA' })"), undefined);
  assert.equal(await run(
    "PublicKeyCredential.signalAllAcceptedCredentials({ rpId: 'example.com', userId: 'AAAA', allAcceptedCredentialIds: [] })"),
  undefined);
  assert.equal(await run(
    "PublicKeyCredential.signalCurrentUserDetails({ rpId: 'example.com', userId: 'AAAA', name: 'a', displayName: 'A' })"),
  undefined);
  assert.deepEqual(engineCalls(), []);
});

test('adds nothing an older WebKit lacks', () => {
  const { run } = setup({ statics: ['isUserVerifyingPlatformAuthenticatorAvailable'] });
  assert.equal(run("typeof PublicKeyCredential.getClientCapabilities"), 'undefined');
  assert.equal(run("typeof PublicKeyCredential.signalUnknownCredential"), 'undefined');
  assert.equal(run("typeof PublicKeyCredential.isConditionalMediationAvailable"), 'undefined');

  const bare = setup({ pkc: false });
  assert.equal(bare.run("typeof PublicKeyCredential"), 'undefined',
    'the block shim never installs WebAuthn interfaces of its own');
});

test('still refuses where the engine has no PublicKeyCredential', async () => {
  const { outcome, engineCalls } = setup({ pkc: false });
  assert.equal((await outcome(CREATE)).name, 'NotAllowedError');
  assert.deepEqual(engineCalls(), []);
});

test('an insecure context, with no navigator.credentials, is left alone', () => {
  const { run } = setup({ credentials: false });
  assert.equal(run("typeof navigator.credentials"), 'undefined');
  assert.equal(run("CredentialsContainer.prototype.create.name"), 'create');
  assert.equal(run("String(CredentialsContainer.prototype.create).includes('__engineCalls')"), true);
});

test('replacements look like the engine\'s operations', () => {
  const { run } = setup();
  assert.match(run('String(navigator.credentials.create)'), /\[native code\]/);
  assert.match(run('String(navigator.credentials.get)'), /\[native code\]/);
  for (const name of STATICS) {
    assert.equal(run(`PublicKeyCredential.${name}.name`), name);
    assert.match(run(`String(PublicKeyCredential.${name})`), /\[native code\]/, name);
    assert.equal(run(`Object.getOwnPropertyDescriptor(PublicKeyCredential, '${name}').enumerable`), true);
  }
  assert.equal(run('PublicKeyCredential.signalUnknownCredential.length'), 1);
  assert.equal(run('PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable.length'), 0);
  assert.equal(run("Object.prototype.hasOwnProperty.call(navigator.credentials, 'create')"), false,
    'wrapped on the prototype, where the engine keeps it');
});

test('a second injection does not wrap twice', async () => {
  const { window, outcome, engineCalls } = setup();
  window.eval(SHIM);
  await outcome('navigator.credentials.get({ password: true })');
  assert.deepEqual(engineCalls(), ['get']);
});

// --- wiring -----------------------------------------------------------------
// The shim only protects a webview it is installed in, so where it goes is
// call-site wiring rather than a unit: checked on the source.

const readDart = (rel) => code(read(rel));

test('PASSKEY-013: every Apple webview without passkeys gets the block shim, in every frame', () => {
  const webview = readDart('lib/services/webview.dart');
  const pageScripts = blockAfter(webview,
    '_buildPageScripts(WebViewConfig config) {', undefined, 'webview.dart');
  assert.ok(pageScripts.includes('..._passkeyShims(config.passkeys),'),
    '_buildPageScripts, shared by site and popup webviews, must install the passkey shims');
  const at = webview.indexOf('_passkeyShims(PasskeyAccess? passkeys) => [');
  assert.notEqual(at, -1, 'webview.dart no longer builds the passkey shims');
  const shims = webview.slice(at, webview.indexOf('];', at)).replace(/\s+/g, ' ');
  assert.ok(shims.includes(
    "if (passkeys == null && PasskeyAccess.hostIsApple) "
      + "pageShim('passkey_block', buildPasskeyBlockShim(), frames: ShimFrames.all)"),
    'the shim goes wherever passkeys are off on iOS and macOS, in every frame '
      + '(WebKit answers a same-origin subframe too), before page script runs');
});

test('PASSKEY-001: webviews get their passkey access from one rule', () => {
  const offenders = dartFiles().filter((rel) => rel !== 'lib/services/passkey_engine.dart'
    && /\bPasskeyAccess\(/.test(readDart(rel)));
  assert.deepEqual(offenders, [],
    'build PasskeyAccess through PasskeyAccess.forHost: a hand-built one skips the per-host '
    + 'backend, and on iOS/macOS a site with passkeys off must get null so it is blocked');
  for (const rel of ['lib/web_view_model.dart', 'lib/screens/inappbrowser.dart']) {
    assert.ok(readDart(rel).includes('PasskeyAccess.forHost('), `${rel} no longer uses forHost`);
  }
});
