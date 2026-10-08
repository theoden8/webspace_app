// Real-engine proof for the passkey block shim (PASSKEY-013,
// lib/js/passkey_block.js).
//
// On iOS and macOS the shim sits in front of a WebAuthn implementation that
// works: WebKit's own, backed by AuthenticationServices once the app holds
// the browser passkey entitlement. The jsdom tier stands the engine in with
// stubs; here the engine is Chromium's, with a CDP virtual authenticator
// behind it that answers every ceremony. The control page proves the
// authenticator would register a passkey, so the shimmed page failing to is
// the shim's doing, and the authenticator's own store shows nothing reached it.
//
// WebAuthn needs a secure context and a domain rp id, so the page is served
// on loopback and opened as http://localhost.

const test = require('node:test');
const assert = require('node:assert/strict');
const { setupBrowser, requireBrowser, pageJs } = require('./helpers/launch');
const { startBlankServer } = require('./helpers/blank_server');

const SHIM = pageJs('passkey_block');

const browser = setupBrowser();

async function openWithAuthenticator(port, { shim }) {
  const page = await browser.browser.newPage();
  const cdp = await page.target().createCDPSession();
  await cdp.send('WebAuthn.enable');
  const { authenticatorId } = await cdp.send('WebAuthn.addVirtualAuthenticator', {
    options: {
      protocol: 'ctap2',
      transport: 'internal',
      hasResidentKey: true,
      hasUserVerification: true,
      isUserVerified: true,
      automaticPresenceSimulation: true,
    },
  });
  if (shim) await page.evaluateOnNewDocument(SHIM);
  await page.goto(`http://localhost:${port}/`, { waitUntil: 'load' });
  const stored = async () =>
    (await cdp.send('WebAuthn.getCredentials', { authenticatorId })).credentials.length;
  return { page, stored };
}

function ceremonies(page) {
  return page.evaluate(async () => {
    const settle = (p) => p.then(
      (v) => ({ ok: true, type: v && v.type }),
      (e) => ({ ok: false, name: e && e.name }));
    const create = await settle(navigator.credentials.create({ publicKey: {
      rp: { name: 'Example', id: 'localhost' },
      user: { id: new Uint8Array([1, 2, 3, 4]), name: 'alice', displayName: 'Alice' },
      challenge: new Uint8Array(32),
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
    } }));
    const get = await settle(navigator.credentials.get({ publicKey: {
      challenge: new Uint8Array(32), rpId: 'localhost', userVerification: 'required',
    } }));
    const uvpaa = await PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable();
    return { secure: isSecureContext, create, get, uvpaa };
  });
}

test('the block shim keeps a working authenticator from being reached', async (t) => {
  if (!requireBrowser(browser, t)) return;
  const server = await startBlankServer();
  const { port } = server.address();
  const pages = [];
  try {
    const control = await openWithAuthenticator(port, { shim: false });
    pages.push(control.page);
    const open = await ceremonies(control.page);
    assert.equal(open.secure, true, 'http://localhost is a secure context');
    assert.deepEqual(open.create, { ok: true, type: 'public-key' },
      'without the shim the engine registers a passkey');
    assert.deepEqual(open.get, { ok: true, type: 'public-key' },
      'and signs in with it');
    assert.equal(open.uvpaa, true);
    assert.equal(await control.stored(), 1);

    const blocked = await openWithAuthenticator(port, { shim: true });
    pages.push(blocked.page);
    const shut = await ceremonies(blocked.page);
    assert.deepEqual(shut.create, { ok: false, name: 'NotAllowedError' });
    assert.deepEqual(shut.get, { ok: false, name: 'NotAllowedError' });
    assert.equal(shut.uvpaa, false);
    assert.equal(await blocked.stored(), 0,
      'nothing reached the authenticator: no passkey was created');

    const caps = await blocked.page.evaluate(() =>
      typeof PublicKeyCredential.getClientCapabilities === 'function'
        ? PublicKeyCredential.getClientCapabilities() : null);
    if (caps !== null) {
      for (const [key, value] of Object.entries(caps)) assert.equal(value, false, key);
    }
    assert.equal(await blocked.page.evaluate(
      () => navigator.credentials.get({ password: true }).then(() => 'engine', (e) => e.name)),
    'engine', 'a password request is still the engine\'s');
  } finally {
    for (const page of pages) await page.close();
    server.close();
  }
});
