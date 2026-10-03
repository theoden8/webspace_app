(function() {
  'use strict';
  if (globalThis.__ws_passkey_block__) return;
  globalThis.__ws_passkey_block__ = true;

  // [SecureContext]: where WebKit exposes no navigator.credentials there is
  // nothing to hide.
  var nav = globalThis.navigator;
  if (!nav || !nav.credentials) return;

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
    try { return new DOMException(message, name); }
    catch (e) { var err = new Error(message); err.name = name; return err; }
  }

  // Replaces the engine's own operation, keeping its name and arity.
  function method(target, name, fn) {
    try {
      Object.defineProperty(fn, 'length', { value: target[name].length, configurable: true });
    } catch (e) {}
    Object.defineProperty(target, name, {
      value: asNative(fn, name), writable: true, enumerable: true, configurable: true,
    });
  }

  // What WebKit answers when the app may not use passkeys for the relying
  // party, so a page sees the same thing in an unentitled build and here.
  function refuse(options) {
    var signal = options.signal;
    if (signal && signal.aborted) {
      return Promise.reject(signal.reason !== undefined
          ? signal.reason : domError('AbortError', 'The operation was aborted.'));
    }
    return Promise.reject(domError('NotAllowedError',
        'The operation either timed out or was not allowed.'));
  }

  var Container = typeof globalThis.CredentialsContainer === 'function'
      ? globalThis.CredentialsContainer.prototype
      : nav.credentials;
  var origCreate = Container.create;
  var origGet = Container.get;
  if (typeof origCreate === 'function') {
    method(Container, 'create', function create(options) {
      if (options && options.publicKey) return refuse(options);
      return origCreate.apply(this, arguments);
    });
  }
  if (typeof origGet === 'function') {
    method(Container, 'get', function get(options) {
      if (options && options.publicKey) return refuse(options);
      return origGet.apply(this, arguments);
    });
  }

  // Only what this WebKit already has: adding a method it lacks would name
  // the app to a page comparing against the engine version.
  var PKC = globalThis.PublicKeyCredential;
  if (typeof PKC !== 'function') return;
  function resolveWith(name, value) {
    if (typeof PKC[name] !== 'function') return;
    method(PKC, name, ({ [name]: function() { return Promise.resolve(value); } })[name]);
  }
  resolveWith('isUserVerifyingPlatformAuthenticatorAvailable', false);
  resolveWith('isConditionalMediationAvailable', false);
  if (typeof PKC.getClientCapabilities === 'function') {
    method(PKC, 'getClientCapabilities', function getClientCapabilities() {
      return Promise.resolve({
        conditionalCreate: false,
        conditionalGet: false,
        hybridTransport: false,
        passkeyPlatformAuthenticator: false,
        userVerifyingPlatformAuthenticator: false,
        relatedOrigins: false,
        signalAllAcceptedCredentials: false,
        signalCurrentUserDetails: false,
        signalUnknownCredential: false,
      });
    });
  }
  // The Signal API edits what the credential provider holds for the relying
  // party, which is as far outside the site as a created passkey.
  resolveWith('signalUnknownCredential', undefined);
  resolveWith('signalAllAcceptedCredentials', undefined);
  resolveWith('signalCurrentUserDetails', undefined);
})();
