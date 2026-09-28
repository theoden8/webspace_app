// Passkey (WebAuthn) shim for the Credential Manager bridge (PASSKEY-003).
//
// Android System WebView ships WebAuthn disabled: `PublicKeyCredential` and
// the `Authenticator*Response` interfaces are runtime-disabled and
// `navigator.credentials` rejects a `publicKey` request. This shim installs
// those interfaces and routes `navigator.credentials.create/get({publicKey})`
// through the `webauthnRequest` handler, where Dart asserts the calling
// frame's origin to Android's Credential Manager the way a browser does.
//
// The shim decides nothing that matters. The origin, the frame check, the
// rpId check and clientDataJSON are all computed in Dart from the bridge's
// own frame data (PASSKEY-004); the page's `options` are only the
// WebAuthn-JSON the request carries. What comes back is the provider's
// response with Dart's clientDataJSON spliced in, rebuilt here into objects
// that behave like the real interfaces (`instanceof`, [SameObject]
// ArrayBuffers, prototype getters rather than own properties).
//
// Must be injected at DOCUMENT_START so it beats the page's feature
// detection. Window-only: there is no `navigator.credentials` in a worker.

/// Build the passkey shim.
///
/// Pure-Dart so the shim string is reachable from `tool/dump_shim_js.dart`
/// and the drift check.
String buildPasskeyShim() => _passkeyShimSource;

const String _passkeyShimSource = r'''
(function() {
  'use strict';
  if (globalThis.__ws_passkey_shim__) return;
  globalThis.__ws_passkey_shim__ = true;

  var nav = globalThis.navigator;
  // [SecureContext]: an http page other than localhost has no
  // navigator.credentials, and WebAuthn must not appear there either.
  if (!nav || !globalThis.isSecureContext) return;

  var _origFnToString = Function.prototype.toString;
  var _stubs = globalThis.__wsFnStubs || new WeakMap();
  globalThis.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
    return fn;
  }
  if (!globalThis.__wsFnToStringPatched) {
    globalThis.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}
    try { Function.prototype.toString = patched; } catch (e) {}
  }

  function domError(name, message) {
    try { return new DOMException(message || name, name); }
    catch (e) { var err = new Error(message || name); err.name = name; return err; }
  }

  // --- base64url <-> ArrayBuffer ------------------------------------------

  function bytesOf(source, what) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source)) {
      return new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
    }
    throw new TypeError(what + ' is not a BufferSource');
  }

  function toB64u(source, what) {
    var bytes = bytesOf(source, what);
    var bin = '';
    for (var i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function fromB64u(text, what) {
    if (typeof text !== 'string') throw new TypeError(what + ' is not a base64url string');
    var b64 = text.replace(/-/g, '+').replace(/_/g, '/');
    while (b64.length % 4) b64 += '=';
    var bin;
    try { bin = atob(b64); } catch (e) { throw new TypeError(what + ' is not a base64url string'); }
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out.buffer;
  }

  function isBufferSource(v) {
    return v instanceof ArrayBuffer || ArrayBuffer.isView(v);
  }

  // Extension inputs carry BufferSources at arbitrary depth (prf.eval.first,
  // largeBlob.write, ...). Encode every one; copy everything else as data.
  function extensionsToJSON(value) {
    if (isBufferSource(value)) return toB64u(value, 'extension value');
    if (Array.isArray(value)) return value.map(extensionsToJSON);
    if (value && typeof value === 'object') {
      var out = {};
      Object.keys(value).forEach(function(k) {
        if (value[k] !== undefined) out[k] = extensionsToJSON(value[k]);
      });
      return out;
    }
    return value;
  }

  function required(obj, key, where) {
    if (!obj || obj[key] === undefined || obj[key] === null) {
      throw new TypeError("Failed to read the '" + key + "' property from '" +
        where + "': Required member is undefined.");
    }
    return obj[key];
  }

  function descriptorsToJSON(list, what) {
    if (list === undefined) return undefined;
    if (!Array.isArray(list)) throw new TypeError(what + ' is not a sequence');
    return list.map(function(c) {
      var d = { type: String(required(c, 'type', 'PublicKeyCredentialDescriptor')),
                id: toB64u(required(c, 'id', 'PublicKeyCredentialDescriptor'), what + '.id') };
      if (Array.isArray(c.transports)) d.transports = c.transports.map(String);
      return d;
    });
  }

  function creationToJSON(pk) {
    var rp = required(pk, 'rp', 'PublicKeyCredentialCreationOptions');
    var user = required(pk, 'user', 'PublicKeyCredentialCreationOptions');
    var params = required(pk, 'pubKeyCredParams', 'PublicKeyCredentialCreationOptions');
    if (!Array.isArray(params)) throw new TypeError('pubKeyCredParams is not a sequence');
    var out = {
      rp: { name: String(required(rp, 'name', 'PublicKeyCredentialRpEntity')) },
      user: {
        id: toB64u(required(user, 'id', 'PublicKeyCredentialUserEntity'), 'user.id'),
        name: String(required(user, 'name', 'PublicKeyCredentialUserEntity')),
        displayName: String(required(user, 'displayName', 'PublicKeyCredentialUserEntity')),
      },
      challenge: toB64u(required(pk, 'challenge', 'PublicKeyCredentialCreationOptions'), 'challenge'),
      pubKeyCredParams: params.map(function(p) {
        return { type: String(required(p, 'type', 'PublicKeyCredentialParameters')),
                 alg: Number(required(p, 'alg', 'PublicKeyCredentialParameters')) };
      }),
    };
    if (rp.id !== undefined) out.rp.id = String(rp.id);
    if (pk.timeout !== undefined) out.timeout = Number(pk.timeout);
    var excluded = descriptorsToJSON(pk.excludeCredentials, 'excludeCredentials');
    if (excluded) out.excludeCredentials = excluded;
    var sel = pk.authenticatorSelection;
    if (sel && typeof sel === 'object') {
      out.authenticatorSelection = {};
      ['authenticatorAttachment', 'residentKey', 'userVerification'].forEach(function(k) {
        if (sel[k] !== undefined) out.authenticatorSelection[k] = String(sel[k]);
      });
      if (sel.requireResidentKey !== undefined) {
        out.authenticatorSelection.requireResidentKey = !!sel.requireResidentKey;
      }
    }
    if (Array.isArray(pk.hints)) out.hints = pk.hints.map(String);
    if (pk.attestation !== undefined) out.attestation = String(pk.attestation);
    if (Array.isArray(pk.attestationFormats)) out.attestationFormats = pk.attestationFormats.map(String);
    if (pk.extensions && typeof pk.extensions === 'object') out.extensions = extensionsToJSON(pk.extensions);
    return out;
  }

  function requestToJSON(pk) {
    var out = {
      challenge: toB64u(required(pk, 'challenge', 'PublicKeyCredentialRequestOptions'), 'challenge'),
    };
    if (pk.rpId !== undefined) out.rpId = String(pk.rpId);
    if (pk.timeout !== undefined) out.timeout = Number(pk.timeout);
    var allowed = descriptorsToJSON(pk.allowCredentials, 'allowCredentials');
    if (allowed) out.allowCredentials = allowed;
    if (pk.userVerification !== undefined) out.userVerification = String(pk.userVerification);
    if (Array.isArray(pk.hints)) out.hints = pk.hints.map(String);
    if (pk.extensions && typeof pk.extensions === 'object') out.extensions = extensionsToJSON(pk.extensions);
    return out;
  }

  // --- the interfaces -----------------------------------------------------

  // Internal slots, so every attribute is a prototype getter the way it is
  // on a real engine, and page script cannot reach or forge the state.
  var _slots = new WeakMap();
  function slot(obj, name) {
    var s = _slots.get(obj);
    if (!s) throw new TypeError('Illegal invocation');
    return s[name];
  }

  function defineInterface(name, parent) {
    var C = ({ [name]: function() { throw new TypeError('Illegal constructor'); } })[name];
    asNative(C, name);
    if (parent) {
      C.prototype = Object.create(parent.prototype, {
        constructor: { value: C, writable: true, configurable: true },
      });
      Object.setPrototypeOf(C, parent);
    }
    Object.defineProperty(C.prototype, Symbol.toStringTag, { value: name, configurable: true });
    Object.defineProperty(globalThis, name, { value: C, writable: true, configurable: true });
    return C;
  }

  function getter(C, name, fn) {
    var g = asNative(function() { return fn(this); }, 'get ' + name);
    Object.defineProperty(C.prototype, name, { get: g, enumerable: true, configurable: true });
  }

  function method(target, name, fn) {
    Object.defineProperty(target, name, {
      value: asNative(fn, name), writable: true, enumerable: true, configurable: true,
    });
  }

  var CredentialBase = typeof globalThis.Credential === 'function' ? globalThis.Credential : null;
  var PublicKeyCredential = defineInterface('PublicKeyCredential', CredentialBase);
  getter(PublicKeyCredential, 'id', function(o) { return slot(o, 'id'); });
  getter(PublicKeyCredential, 'type', function(o) { slot(o, 'id'); return 'public-key'; });
  getter(PublicKeyCredential, 'rawId', function(o) { return slot(o, 'rawId'); });
  getter(PublicKeyCredential, 'response', function(o) { return slot(o, 'response'); });
  getter(PublicKeyCredential, 'authenticatorAttachment', function(o) { return slot(o, 'attachment'); });
  method(PublicKeyCredential.prototype, 'getClientExtensionResults', function getClientExtensionResults() {
    return extensionResultsFromJSON(slot(this, 'json').clientExtensionResults || {});
  });
  method(PublicKeyCredential.prototype, 'toJSON', function toJSON() {
    return JSON.parse(JSON.stringify(slot(this, 'json')));
  });

  var AuthenticatorResponse = defineInterface('AuthenticatorResponse', null);
  getter(AuthenticatorResponse, 'clientDataJSON', function(o) { return slot(o, 'clientDataJSON'); });

  var AuthenticatorAttestationResponse =
      defineInterface('AuthenticatorAttestationResponse', AuthenticatorResponse);
  getter(AuthenticatorAttestationResponse, 'attestationObject', function(o) { return slot(o, 'attestationObject'); });
  method(AuthenticatorAttestationResponse.prototype, 'getTransports', function getTransports() {
    return (slot(this, 'json').transports || []).slice();
  });
  method(AuthenticatorAttestationResponse.prototype, 'getAuthenticatorData', function getAuthenticatorData() {
    return slot(this, 'authenticatorData');
  });
  method(AuthenticatorAttestationResponse.prototype, 'getPublicKey', function getPublicKey() {
    return slot(this, 'publicKey');
  });
  method(AuthenticatorAttestationResponse.prototype, 'getPublicKeyAlgorithm', function getPublicKeyAlgorithm() {
    var alg = slot(this, 'json').publicKeyAlgorithm;
    return typeof alg === 'number' ? alg : -7;
  });

  var AuthenticatorAssertionResponse =
      defineInterface('AuthenticatorAssertionResponse', AuthenticatorResponse);
  getter(AuthenticatorAssertionResponse, 'authenticatorData', function(o) { return slot(o, 'authenticatorData'); });
  getter(AuthenticatorAssertionResponse, 'signature', function(o) { return slot(o, 'signature'); });
  getter(AuthenticatorAssertionResponse, 'userHandle', function(o) { return slot(o, 'userHandle'); });

  function extensionResultsFromJSON(json) {
    var out = JSON.parse(JSON.stringify(json));
    var prf = out.prf && out.prf.results;
    if (prf) {
      if (typeof prf.first === 'string') prf.first = fromB64u(prf.first, 'prf.first');
      if (typeof prf.second === 'string') prf.second = fromB64u(prf.second, 'prf.second');
    }
    if (out.largeBlob && typeof out.largeBlob.blob === 'string') {
      out.largeBlob.blob = fromB64u(out.largeBlob.blob, 'largeBlob.blob');
    }
    return out;
  }

  function construct(C, slots) {
    var obj = Object.create(C.prototype);
    _slots.set(obj, slots);
    return obj;
  }

  function credentialFromJSON(op, json) {
    var r = json.response || {};
    var response;
    if (op === 'create') {
      response = construct(AuthenticatorAttestationResponse, {
        json: r,
        clientDataJSON: fromB64u(r.clientDataJSON, 'clientDataJSON'),
        attestationObject: fromB64u(r.attestationObject, 'attestationObject'),
        authenticatorData: r.authenticatorData ? fromB64u(r.authenticatorData, 'authenticatorData') : null,
        publicKey: r.publicKey ? fromB64u(r.publicKey, 'publicKey') : null,
      });
    } else {
      response = construct(AuthenticatorAssertionResponse, {
        json: r,
        clientDataJSON: fromB64u(r.clientDataJSON, 'clientDataJSON'),
        authenticatorData: fromB64u(r.authenticatorData, 'authenticatorData'),
        signature: fromB64u(r.signature, 'signature'),
        userHandle: r.userHandle ? fromB64u(r.userHandle, 'userHandle') : null,
      });
    }
    return construct(PublicKeyCredential, {
      json: json,
      id: json.id,
      rawId: fromB64u(json.rawId || json.id, 'rawId'),
      response: response,
      attachment: json.authenticatorAttachment || null,
    });
  }

  // --- the bridge ---------------------------------------------------------

  function bridge() {
    var iaw = globalThis.flutter_inappwebview;
    return iaw && typeof iaw.callHandler === 'function' ? iaw : null;
  }

  var _status = null;
  function available() {
    if (_status) return _status;
    var b = bridge();
    if (!b) return Promise.resolve(false);
    _status = b.callHandler('webauthnStatus').then(function(res) {
      return !!(res && res.available === true);
    }, function() { _status = null; return false; });
    return _status;
  }

  var _nextId = 1;
  function ceremony(op, options) {
    return new Promise(function(resolve, reject) {
      var signal = options.signal;
      if (signal && signal.aborted) {
        reject(signal.reason !== undefined ? signal.reason : domError('AbortError', 'The operation was aborted.'));
        return;
      }
      if (op === 'get' && options.mediation === 'conditional') {
        reject(domError('NotSupportedError', 'Conditional mediation is not supported.'));
        return;
      }
      var json;
      try {
        json = op === 'create' ? creationToJSON(options.publicKey) : requestToJSON(options.publicKey);
      } catch (e) {
        reject(e);
        return;
      }
      var b = bridge();
      if (!b) {
        reject(domError('NotSupportedError', 'Passkeys are not available.'));
        return;
      }
      var id = _nextId++;
      var settled = false;
      function onAbort() {
        if (settled) return;
        settled = true;
        try { b.callHandler('webauthnCancel', id); } catch (e) {}
        reject(signal.reason !== undefined ? signal.reason : domError('AbortError', 'The operation was aborted.'));
      }
      if (signal && typeof signal.addEventListener === 'function') {
        signal.addEventListener('abort', onAbort, { once: true });
      }
      b.callHandler('webauthnRequest', { op: op, requestId: id, options: json }).then(function(res) {
        if (settled) return;
        settled = true;
        if (signal && typeof signal.removeEventListener === 'function') signal.removeEventListener('abort', onAbort);
        if (!res || res.ok !== true || !res.credential) {
          var name = (res && res.name) || 'NotAllowedError';
          var message = (res && res.message) || 'The operation either timed out or was not allowed.';
          reject(name === 'TypeError' ? new TypeError(message) : domError(name, message));
          return;
        }
        try {
          resolve(credentialFromJSON(op, res.credential));
        } catch (e) {
          reject(domError('NotReadableError', 'The credential response could not be read.'));
        }
      }, function() {
        if (settled) return;
        settled = true;
        reject(domError('NotAllowedError', 'The operation either timed out or was not allowed.'));
      });
    });
  }

  // --- navigator.credentials ----------------------------------------------

  var Container = typeof globalThis.CredentialsContainer === 'function'
      ? globalThis.CredentialsContainer.prototype
      : nav.credentials;
  if (!Container) return;
  var origCreate = Container.create;
  var origGet = Container.get;
  method(Container, 'create', function create(options) {
    if (!options || !options.publicKey) {
      return origCreate ? origCreate.apply(this, arguments)
                        : Promise.reject(domError('NotSupportedError', 'Only public-key credentials are supported.'));
    }
    return ceremony('create', options);
  });
  method(Container, 'get', function get(options) {
    if (!options || !options.publicKey) {
      return origGet ? origGet.apply(this, arguments)
                     : Promise.reject(domError('NotSupportedError', 'Only public-key credentials are supported.'));
    }
    return ceremony('get', options);
  });

  // --- feature detection --------------------------------------------------

  method(PublicKeyCredential, 'isUserVerifyingPlatformAuthenticatorAvailable',
    function isUserVerifyingPlatformAuthenticatorAvailable() { return available(); });
  method(PublicKeyCredential, 'isConditionalMediationAvailable',
    function isConditionalMediationAvailable() { return Promise.resolve(false); });
  method(PublicKeyCredential, 'getClientCapabilities', function getClientCapabilities() {
    return available().then(function(ok) {
      return {
        conditionalCreate: false,
        conditionalGet: false,
        hybridTransport: false,
        passkeyPlatformAuthenticator: ok,
        userVerifyingPlatformAuthenticator: ok,
        relatedOrigins: false,
        signalAllAcceptedCredentials: false,
        signalCurrentUserDetails: false,
        signalUnknownCredential: false,
      };
    });
  });

  function descriptorsFromJSON(list) {
    if (!Array.isArray(list)) return undefined;
    return list.map(function(c) {
      var d = { type: c.type, id: fromB64u(c.id, 'id') };
      if (Array.isArray(c.transports)) d.transports = c.transports.slice();
      return d;
    });
  }
  method(PublicKeyCredential, 'parseCreationOptionsFromJSON', function parseCreationOptionsFromJSON(json) {
    var out = JSON.parse(JSON.stringify(json));
    out.challenge = fromB64u(required(json, 'challenge', 'PublicKeyCredentialCreationOptionsJSON'), 'challenge');
    out.user = Object.assign({}, out.user, {
      id: fromB64u(required(required(json, 'user', 'PublicKeyCredentialCreationOptionsJSON'), 'id',
        'PublicKeyCredentialUserEntityJSON'), 'user.id'),
    });
    if (json.excludeCredentials) out.excludeCredentials = descriptorsFromJSON(json.excludeCredentials);
    return out;
  });
  method(PublicKeyCredential, 'parseRequestOptionsFromJSON', function parseRequestOptionsFromJSON(json) {
    var out = JSON.parse(JSON.stringify(json));
    out.challenge = fromB64u(required(json, 'challenge', 'PublicKeyCredentialRequestOptionsJSON'), 'challenge');
    if (json.allowCredentials) out.allowCredentials = descriptorsFromJSON(json.allowCredentials);
    return out;
  });
})();
''';
