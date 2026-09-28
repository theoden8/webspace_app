// Relying party for the Android passkey gate (scripts/run_android_passkey_tests.sh).
//
// An independent WebAuthn verifier: @simplewebauthn/server checks what the
// page hands back exactly as a production RP would, so a ceremony only
// passes if webspace's clientDataJSON, the provider's signature over its
// hash, and the rpId all agree. Served on http://localhost, a secure
// context, and reached from the emulator through `adb reverse`.
//
// GET /results is the evidence: every verification, with the origin and
// rpId the RP actually saw.

import http from 'node:http';
import crypto from 'node:crypto';
import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
} from '@simplewebauthn/server';

const PORT = Number(process.env.PORT || 8443);
const RP_ID = 'localhost';
const ORIGIN = `http://localhost:${PORT}`;

const users = new Map();
const results = [];

function user(name) {
  if (!users.has(name)) {
    users.set(name, { id: crypto.randomBytes(16), credentials: [], challenge: null });
  }
  return users.get(name);
}

function clientData(response) {
  try {
    return JSON.parse(Buffer.from(response.response.clientDataJSON, 'base64url').toString('utf8'));
  } catch {
    return {};
  }
}

function record(entry) {
  const line = { at: new Date().toISOString(), ...entry };
  results.push(line);
  console.log(`RP ${JSON.stringify(line)}`);
  return line;
}

const routes = {
  async 'POST /register/options'({ name }) {
    const u = user(name);
    const options = await generateRegistrationOptions({
      rpName: 'WebSpace passkey gate',
      rpID: RP_ID,
      userName: name,
      userID: u.id,
      attestationType: 'none',
      authenticatorSelection: { residentKey: 'preferred', userVerification: 'preferred' },
      excludeCredentials: u.credentials.map((c) => ({ id: c.id, transports: c.transports })),
    });
    u.challenge = options.challenge;
    return options;
  },

  async 'POST /register/verify'({ name, response }) {
    const u = user(name);
    const cd = clientData(response);
    try {
      const v = await verifyRegistrationResponse({
        response,
        expectedChallenge: u.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        requireUserVerification: false,
      });
      if (v.verified) {
        const c = v.registrationInfo.credential;
        u.credentials.push({ id: c.id, publicKey: c.publicKey, counter: c.counter, transports: c.transports });
      }
      return record({ ceremony: 'register', name, verified: v.verified, origin: cd.origin,
        type: cd.type, rpId: RP_ID, credentialId: response.id, counter: v.registrationInfo?.credential.counter });
    } catch (e) {
      return record({ ceremony: 'register', name, verified: false, origin: cd.origin, type: cd.type,
        rpId: RP_ID, error: String(e.message || e) });
    }
  },

  async 'POST /login/options'({ name }) {
    const u = user(name);
    const options = await generateAuthenticationOptions({
      rpID: RP_ID,
      userVerification: 'preferred',
      allowCredentials: u.credentials.map((c) => ({ id: c.id, transports: c.transports })),
    });
    u.challenge = options.challenge;
    return options;
  },

  async 'POST /login/verify'({ name, response }) {
    const u = user(name);
    const cd = clientData(response);
    const c = u.credentials.find((x) => x.id === response.id);
    if (!c) {
      return record({ ceremony: 'login', name, verified: false, origin: cd.origin, type: cd.type,
        rpId: RP_ID, error: `unknown credential ${response.id}` });
    }
    try {
      const v = await verifyAuthenticationResponse({
        response,
        expectedChallenge: u.challenge,
        expectedOrigin: ORIGIN,
        expectedRPID: RP_ID,
        credential: c,
        requireUserVerification: false,
      });
      const previous = c.counter;
      if (v.verified) c.counter = v.authenticationInfo.newCounter;
      return record({ ceremony: 'login', name, verified: v.verified, origin: cd.origin, type: cd.type,
        rpId: RP_ID, credentialId: response.id, previousCounter: previous,
        counter: v.authenticationInfo?.newCounter });
    } catch (e) {
      return record({ ceremony: 'login', name, verified: false, origin: cd.origin, type: cd.type,
        rpId: RP_ID, error: String(e.message || e) });
    }
  },

  async 'POST /reset'() {
    users.clear();
    results.length = 0;
    return { ok: true };
  },
};

const PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>passkey gate</title></head>
<body><h1 id="ready">passkey gate</h1>
<script>
// Encodes from the credential's ArrayBuffers by hand, as a site that predates
// toJSON() does, so the gate exercises the object the shim builds.
var b64u = function (buf) {
  var bytes = new Uint8Array(buf), bin = '';
  for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '');
};
var unb64u = function (s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/');
  while (s.length % 4) s += '=';
  var bin = atob(s), out = new Uint8Array(bin.length);
  for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
};
var post = function (path, body) {
  return fetch(path, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body) }).then(function (r) { return r.json(); });
};
var descriptors = function (list) {
  return (list || []).map(function (c) { return { type: c.type, id: unb64u(c.id), transports: c.transports }; });
};
function register(name) {
  return post('/register/options', { name: name }).then(function (o) {
    return navigator.credentials.create({ publicKey: {
      rp: o.rp, user: { id: unb64u(o.user.id), name: o.user.name, displayName: o.user.displayName },
      challenge: unb64u(o.challenge), pubKeyCredParams: o.pubKeyCredParams, timeout: o.timeout,
      excludeCredentials: descriptors(o.excludeCredentials),
      authenticatorSelection: o.authenticatorSelection, attestation: o.attestation,
      extensions: o.extensions } });
  }).then(function (c) {
    return post('/register/verify', { name: name, response: {
      id: c.id, rawId: b64u(c.rawId), type: c.type,
      response: { clientDataJSON: b64u(c.response.clientDataJSON),
        attestationObject: b64u(c.response.attestationObject),
        transports: c.response.getTransports() },
      authenticatorAttachment: c.authenticatorAttachment,
      clientExtensionResults: c.getClientExtensionResults() } });
  });
}
function login(name) {
  return post('/login/options', { name: name }).then(function (o) {
    return navigator.credentials.get({ publicKey: {
      challenge: unb64u(o.challenge), rpId: o.rpId, timeout: o.timeout,
      allowCredentials: descriptors(o.allowCredentials), userVerification: o.userVerification } });
  }).then(function (c) {
    return post('/login/verify', { name: name, response: {
      id: c.id, rawId: b64u(c.rawId), type: c.type,
      response: { clientDataJSON: b64u(c.response.clientDataJSON),
        authenticatorData: b64u(c.response.authenticatorData),
        signature: b64u(c.response.signature),
        userHandle: c.response.userHandle ? b64u(c.response.userHandle) : undefined },
      authenticatorAttachment: c.authenticatorAttachment,
      clientExtensionResults: c.getClientExtensionResults() } });
  });
}
window.gate = {
  status: null,
  probe: function () {
    var pkc = typeof PublicKeyCredential;
    var avail = pkc === 'function'
      ? PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable() : Promise.resolve(null);
    return avail.then(function (a) {
      window.gate.probed = { secure: window.isSecureContext, pkc: pkc,
        credentials: typeof navigator.credentials, uvpaa: a, origin: location.origin };
    }, function (e) { window.gate.probed = { error: String(e) }; });
  },
  run: function (kind, name) {
    window.gate.status = { state: 'running', kind: kind };
    (kind === 'register' ? register(name) : login(name)).then(function (r) {
      window.gate.status = Object.assign({ state: 'done', kind: kind }, r);
    }, function (e) {
      window.gate.status = { state: 'error', kind: kind, name: e && e.name, message: e && e.message,
        isDomException: e instanceof DOMException };
    });
  },
};
</script></body></html>`;

const server = http.createServer(async (req, res) => {
  const key = `${req.method} ${req.url.split('?')[0]}`;
  try {
    if (key === 'GET /' || key === 'GET /index.html') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      res.end(PAGE);
      return;
    }
    if (key === 'GET /results') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(results));
      return;
    }
    const route = routes[key];
    if (!route) {
      res.writeHead(404).end();
      return;
    }
    let body = '';
    for await (const chunk of req) body += chunk;
    const out = await route(body ? JSON.parse(body) : {});
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(out));
  } catch (e) {
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: String(e.message || e) }));
  }
});

server.listen(PORT, '127.0.0.1', () => console.log(`RP listening on ${ORIGIN}`));
