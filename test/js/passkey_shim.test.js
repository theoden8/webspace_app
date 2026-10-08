// Tier 1 — jsdom assertions for the passkey shim
// (lib/js/passkey.js).
//
// jsdom has no WebAuthn and no Credential Management API, so the realm is
// given what Android System WebView exposes with WebAuthn disabled: a
// `Credential` base, a `CredentialsContainer` whose create/get are the
// engine's, and no `PublicKeyCredential`. The bridge is a fake that answers
// the way the Dart handler does. What is asserted is the shim's half of
// PASSKEY-003: request serialization, the interfaces it installs, how a
// response becomes a credential, and how errors and aborts surface. The
// origin and rpId checks are Dart's and are covered by
// test/passkey_engine_test.dart.

const test = require('node:test');
const { afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { makeDom, pageJs } = require('./helpers/load_shim');
const { scriptOf } = require('./helpers/script_of');

const SHIM = pageJs('passkey');

const _doms = [];
afterEach(() => {
  while (_doms.length) {
    try { _doms.pop().window.close(); } catch (_) { /* closed */ }
  }
});

// What the WebView exposes: a CredentialsContainer and no WebAuthn interfaces.
function installEngine() {
  class Credential {}
  class CredentialsContainer {}
  CredentialsContainer.prototype.create = function create() { return Promise.resolve({ engine: 'create' }); };
  CredentialsContainer.prototype.get = function get() { return Promise.resolve({ engine: 'get' }); };
  window.Credential = Credential;
  window.CredentialsContainer = CredentialsContainer;
  Object.defineProperty(navigator, 'credentials', { value: new CredentialsContainer(), configurable: true });
}

// `respond(name, args)` stands in for the Dart handlers; the default answers
// webauthnStatus with available:true and fails every ceremony.
function setup({ respond, noBridge = false, secure = true, url = 'https://login.example.com/' } = {}) {
  const dom = makeDom({ url });
  _doms.push(dom);
  const { window } = dom;
  Object.defineProperty(window, 'isSecureContext', { value: secure, configurable: true });
  window.eval(scriptOf(installEngine));
  const calls = [];
  if (!noBridge) {
    window.flutter_inappwebview = {
      callHandler(name, ...args) {
        calls.push({ name, args: JSON.parse(JSON.stringify(args)) });
        const answer = respond ? respond(name, args) : undefined;
        if (answer !== undefined) return answer instanceof Promise ? answer : Promise.resolve(answer);
        if (name === 'webauthnStatus') return Promise.resolve({ available: true });
        return Promise.resolve({ ok: false, name: 'NotAllowedError', message: 'no' });
      },
    };
  }
  window.eval(SHIM);
  // Results cross from the jsdom realm, whose Object and Array prototypes are
  // not Node's, so compare them as plain data.
  const plain = (v) => (v === undefined ? v : JSON.parse(JSON.stringify(v)));
  // [code] is an expression, or a function run in the page with [args].
  const run = (code, ...args) => {
    const v = window.eval(typeof code === 'function' ? scriptOf(code, ...args) : code);
    return v && typeof v.then === 'function' ? v.then(plain) : plain(v);
  };
  return { window, calls, run };
}

const b64u = (bytes) => Buffer.from(bytes).toString('base64url');

const REGISTRATION = {
  id: b64u([9, 9, 9]),
  rawId: b64u([9, 9, 9]),
  type: 'public-key',
  response: {
    clientDataJSON: b64u(Buffer.from('{"type":"webauthn.create"}')),
    attestationObject: b64u([0xa3, 1, 2, 3]),
    authenticatorData: b64u([7, 7, 7]),
    publicKey: b64u([4, 4]),
    publicKeyAlgorithm: -7,
    transports: ['internal', 'hybrid'],
  },
  authenticatorAttachment: 'platform',
  clientExtensionResults: { credProps: { rk: true } },
};

const ASSERTION = {
  id: b64u([9, 9, 9]),
  rawId: b64u([9, 9, 9]),
  type: 'public-key',
  response: {
    clientDataJSON: b64u(Buffer.from('{"type":"webauthn.get"}')),
    authenticatorData: b64u([5, 5]),
    signature: b64u([6, 6, 6]),
    userHandle: b64u([1, 2, 3, 4]),
  },
  clientExtensionResults: { prf: { results: { first: b64u([8, 8]) } } },
};

test('installs the WebAuthn interfaces the WebView leaves out', () => {
  const { window, run } = setup();
  for (const name of ['PublicKeyCredential', 'AuthenticatorResponse',
    'AuthenticatorAttestationResponse', 'AuthenticatorAssertionResponse']) {
    assert.equal(typeof window[name], 'function', name);
    assert.throws(() => run(`new ${name}()`), /Illegal constructor/);
  }
  assert.equal(run('Object.prototype.toString.call(PublicKeyCredential.prototype)'),
    '[object PublicKeyCredential]');
  assert.equal(run('PublicKeyCredential.prototype instanceof Credential'), true);
  assert.equal(run('AuthenticatorAttestationResponse.prototype instanceof AuthenticatorResponse'), true);
  assert.match(run('String(navigator.credentials.create)'), /\[native code\]/);
  assert.throws(() => run(
    "Object.getOwnPropertyDescriptor(PublicKeyCredential.prototype, 'id').get.call({})"),
  /Illegal invocation/);
});

test('availability comes from the bridge, and is false without one', async () => {
  assert.equal(await setup().run('PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()'), true);
  const off = setup({ respond: (n) => (n === 'webauthnStatus' ? { available: false } : undefined) });
  assert.equal(await off.run('PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()'), false);
  const caps = await off.run('PublicKeyCredential.getClientCapabilities()');
  assert.equal(caps.passkeyPlatformAuthenticator, false);
  assert.equal(caps.conditionalGet, false);
  assert.equal(await setup({ noBridge: true }).run('PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()'), false);
  assert.equal(await setup().run('PublicKeyCredential.isConditionalMediationAvailable()'), false);
});

test('create sends WebAuthn-JSON and resolves a real-looking credential', async () => {
  const { calls, run } = setup({
    respond: (n) => (n === 'webauthnRequest' ? { ok: true, credential: REGISTRATION } : undefined),
  });
  const out = await run(function () {
    return navigator.credentials.create({ publicKey: {
      rp: { name: 'Example' },
      user: { id: new Uint8Array([1, 2, 3, 4]).buffer, name: 'alice', displayName: 'Alice' },
      challenge: new Uint8Array([0, 1, 2, 250, 251, 255]),
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      excludeCredentials: [{ type: 'public-key', id: new Uint8Array([9, 9, 9]), transports: ['internal'] }],
      authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred', bogus: 1 },
      attestation: 'none',
      extensions: { credProps: true, prf: { eval: { first: new Uint8Array([1]) } } },
    } }).then(function (c) {
      return {
        isPkc: c instanceof PublicKeyCredential,
        isAtt: c.response instanceof AuthenticatorAttestationResponse,
        id: c.id, type: c.type,
        rawId: Array.from(new Uint8Array(c.rawId)),
        sameRawId: c.rawId === c.rawId,
        ownKeys: Object.keys(c),
        clientData: String.fromCharCode.apply(null, new Uint8Array(c.response.clientDataJSON)),
        transports: c.response.getTransports(),
        alg: c.response.getPublicKeyAlgorithm(),
        pk: Array.from(new Uint8Array(c.response.getPublicKey())),
        authData: Array.from(new Uint8Array(c.response.getAuthenticatorData())),
        attachment: c.authenticatorAttachment,
        ext: c.getClientExtensionResults(),
        json: c.toJSON(),
      };
    });
  });
  assert.equal(out.isPkc, true);
  assert.equal(out.isAtt, true);
  assert.equal(out.type, 'public-key');
  assert.deepEqual(out.rawId, [9, 9, 9]);
  assert.equal(out.sameRawId, true);
  assert.deepEqual(out.ownKeys, [], 'attributes live on the prototype, as on a real engine');
  assert.equal(out.clientData, '{"type":"webauthn.create"}');
  assert.deepEqual(out.transports, ['internal', 'hybrid']);
  assert.equal(out.alg, -7);
  assert.deepEqual(out.pk, [4, 4]);
  assert.deepEqual(out.authData, [7, 7, 7]);
  assert.equal(out.attachment, 'platform');
  assert.deepEqual(out.ext, { credProps: { rk: true } });
  assert.equal(out.json.response.attestationObject, REGISTRATION.response.attestationObject);

  const req = calls.find((c) => c.name === 'webauthnRequest').args[0];
  assert.equal(req.op, 'create');
  assert.equal(typeof req.requestId, 'number');
  assert.deepEqual(req.options, {
    rp: { name: 'Example' },
    user: { id: b64u([1, 2, 3, 4]), name: 'alice', displayName: 'Alice' },
    challenge: b64u([0, 1, 2, 250, 251, 255]),
    pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
    excludeCredentials: [{ type: 'public-key', id: b64u([9, 9, 9]), transports: ['internal'] }],
    authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred' },
    attestation: 'none',
    extensions: { credProps: true, prf: { eval: { first: b64u([1]) } } },
  });
  assert.equal('origin' in req, false, 'the page never names the origin');
});

test('get resolves an assertion with its buffers and extension results', async () => {
  const { calls, run } = setup({
    respond: (n) => (n === 'webauthnRequest' ? { ok: true, credential: ASSERTION } : undefined),
  });
  const out = await run(function () {
    return navigator.credentials.get({ publicKey: {
      challenge: new Uint8Array([1, 2, 3]), rpId: 'example.com', userVerification: 'required',
      allowCredentials: [{ type: 'public-key', id: new Uint8Array([9, 9, 9]) }],
    } }).then(function (c) {
      return {
        isAssert: c.response instanceof AuthenticatorAssertionResponse,
        sig: Array.from(new Uint8Array(c.response.signature)),
        user: Array.from(new Uint8Array(c.response.userHandle)),
        auth: Array.from(new Uint8Array(c.response.authenticatorData)),
        prf: Array.from(new Uint8Array(c.getClientExtensionResults().prf.results.first)),
        attachment: c.authenticatorAttachment,
      };
    });
  });
  assert.equal(out.isAssert, true);
  assert.deepEqual(out.sig, [6, 6, 6]);
  assert.deepEqual(out.user, [1, 2, 3, 4]);
  assert.deepEqual(out.auth, [5, 5]);
  assert.deepEqual(out.prf, [8, 8]);
  assert.equal(out.attachment, null);
  const req = calls.find((c) => c.name === 'webauthnRequest').args[0];
  assert.deepEqual(req.options, {
    challenge: b64u([1, 2, 3]),
    rpId: 'example.com',
    allowCredentials: [{ type: 'public-key', id: b64u([9, 9, 9]) }],
    userVerification: 'required',
  });
});

test('a refusal surfaces as the DOMException Dart named', async () => {
  const { run } = setup({
    respond: (n) => (n === 'webauthnRequest'
      ? { ok: false, name: 'InvalidStateError', message: 'excluded' } : undefined),
  });
  const err = await run(function () {
    return navigator.credentials.create({ publicKey: {
      rp: { name: 'Example' },
      user: { id: new Uint8Array([1]), name: 'alice', displayName: 'Alice' },
      challenge: new Uint8Array([1]),
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
    } }).then(null, function (e) {
      return { isDom: e instanceof DOMException, name: e.name, message: e.message };
    });
  });
  assert.deepEqual(err, { isDom: true, name: 'InvalidStateError', message: 'excluded' });

  const typeErr = setup({
    respond: (n) => (n === 'webauthnRequest' ? { ok: false, name: 'TypeError', message: 'bad' } : undefined),
  });
  assert.equal(await typeErr.run(function () {
    return navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1]) } })
      .then(null, function (e) { return e instanceof TypeError; });
  }), true);
});

test('a malformed request is a TypeError and never reaches the bridge', async () => {
  const { calls, run } = setup();
  const name = await run(function () {
    return navigator.credentials.create({ publicKey: {
      rp: { name: 'x' }, challenge: new Uint8Array([1]), pubKeyCredParams: [] } })
      .then(null, function (e) { return e instanceof TypeError ? 'TypeError' : e.name; });
  });
  assert.equal(name, 'TypeError');
  const notBuffer = await run(function () {
    return navigator.credentials.get({ publicKey: { challenge: 'abc' } })
      .then(null, function (e) { return e instanceof TypeError ? 'TypeError' : e.name; });
  });
  assert.equal(notBuffer, 'TypeError');
  assert.equal(calls.filter((c) => c.name === 'webauthnRequest').length, 0);
});

test('non-publicKey requests stay with the engine', async () => {
  const { calls, run } = setup();
  assert.deepEqual(await run('navigator.credentials.get({ password: true })'), { engine: 'get' });
  assert.deepEqual(await run('navigator.credentials.create({ password: {} })'), { engine: 'create' });
  assert.equal(calls.length, 0);
});

test('conditional mediation is refused without asking the bridge', async () => {
  const { calls, run } = setup();
  const name = await run(function () {
    return navigator.credentials.get({ mediation: 'conditional',
      publicKey: { challenge: new Uint8Array([1]) } }).then(null, function (e) { return e.name; });
  });
  assert.equal(name, 'NotSupportedError');
  assert.equal(calls.filter((c) => c.name === 'webauthnRequest').length, 0);
});

test('an abort rejects at once and cancels the native ceremony', async () => {
  let release;
  const { calls, run } = setup({
    respond: (n) => (n === 'webauthnRequest'
      ? new Promise((r) => { release = r; }) : undefined),
  });
  const pre = await run(function () {
    var c = new AbortController(); c.abort();
    return navigator.credentials.get({ signal: c.signal, publicKey: { challenge: new Uint8Array([1]) } })
      .then(null, function (e) { return e.name; });
  });
  assert.equal(pre, 'AbortError');
  assert.equal(calls.filter((c) => c.name === 'webauthnRequest').length, 0);

  const mid = await run(function () {
    var c = new AbortController();
    var p = navigator.credentials.get({ signal: c.signal, publicKey: { challenge: new Uint8Array([1]) } })
      .then(function () { return 'resolved'; }, function (e) { return e.name; });
    setTimeout(function () { c.abort(); }, 0);
    return p;
  });
  assert.equal(mid, 'AbortError');
  const request = calls.find((c) => c.name === 'webauthnRequest').args[0];
  const cancel = calls.find((c) => c.name === 'webauthnCancel');
  assert.ok(cancel, 'the native ceremony is cancelled');
  assert.equal(cancel.args[0], request.requestId);
  release({ ok: true, credential: ASSERTION });
});

test('no bridge fails closed', async () => {
  const { run } = setup({ noBridge: true });
  assert.equal(await run(function () {
    return navigator.credentials.get({ publicKey: { challenge: new Uint8Array([1]) } })
      .then(null, function (e) { return e.name; });
  }), 'NotSupportedError');
});

test('an insecure context gets no WebAuthn at all', () => {
  const { window } = setup({ secure: false, url: 'http://example.com/' });
  assert.equal(typeof window.PublicKeyCredential, 'undefined');
});

test('parse*FromJSON turn WebAuthn-JSON back into buffers', () => {
  const { run } = setup();
  const out = run(function (id) {
    var c = PublicKeyCredential.parseCreationOptionsFromJSON({
      rp: { name: 'x' }, user: { id: id.user, name: 'a', displayName: 'A' },
      challenge: id.challenge, pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      excludeCredentials: [{ type: 'public-key', id: id.exclude }] });
    var g = PublicKeyCredential.parseRequestOptionsFromJSON({
      challenge: id.getChallenge, allowCredentials: [{ type: 'public-key', id: id.allow }] });
    return {
      user: Array.from(new Uint8Array(c.user.id)), challenge: Array.from(new Uint8Array(c.challenge)),
      exclude: Array.from(new Uint8Array(c.excludeCredentials[0].id)),
      getChallenge: Array.from(new Uint8Array(g.challenge)),
      allow: Array.from(new Uint8Array(g.allowCredentials[0].id)),
    };
  }, {
    user: b64u([1, 2]), challenge: b64u([3, 4]), exclude: b64u([5]),
    getChallenge: b64u([6]), allow: b64u([7]),
  });
  assert.deepEqual(out, { user: [1, 2], challenge: [3, 4], exclude: [5], getChallenge: [6], allow: [7] });
});

test('installs once', () => {
  const { window, run } = setup();
  const first = window.PublicKeyCredential;
  run(SHIM);
  assert.equal(window.PublicKeyCredential, first);
});
