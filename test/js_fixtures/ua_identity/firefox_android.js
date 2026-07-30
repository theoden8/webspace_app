(function() {
  'use strict';
  if (globalThis.__ws_ua_identity_shim__) return;
  globalThis.__ws_ua_identity_shim__ = true;

  // Shared Function.prototype.toString funnel (same WeakMap as the other
  // shims) so every getter stringifies as `[native code]`.
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

  // Resolved from the live `navigator` so this works unchanged in a worker,
  // where the class is WorkerNavigator and `Navigator` does not exist.
  var NavProto = (typeof navigator !== 'undefined' && navigator)
    ? Object.getPrototypeOf(navigator) : null;
  var IS_WORKER = typeof WorkerGlobalScope !== 'undefined' &&
    globalThis instanceof WorkerGlobalScope;

  // A worker's navigator legitimately carries a SMALLER surface than a
  // window's (no oscpu/buildID/plugins/...). Adding a property the real
  // WorkerNavigator lacks would be a fresh leak, so in worker scope we only
  // ever correct the VALUE of a property that is already there — never add.
  function present(name) {
    try {
      if (NavProto && (name in NavProto)) return true;
      return typeof navigator !== 'undefined' && navigator && (name in navigator);
    } catch (e) { return false; }
  }

  // Define on the navigator PROTOTYPE (never the instance — an own-property on
  // `navigator` would self-incriminate), matching how real engines carry
  // these accessors.
  function def(name, value) {
    if (!NavProto) return;
    if (IS_WORKER && !present(name)) return;
    try {
      Object.defineProperty(NavProto, name, {
        configurable: true, enumerable: true,
        get: asNative(function() { return value; }, name),
      });
    } catch (e) {}
  }

  // Make a property genuinely absent (delete), so `name in navigator` is
  // false. Falls back to an undefined getter only if the delete is refused
  // (non-configurable), which is still better than a populated value.
  function removeProp(name) {
    try { if (NavProto) delete NavProto[name]; } catch (e) {}
    try { delete navigator[name]; } catch (e) {}
    try {
      if (NavProto && (name in NavProto)) {
        Object.defineProperty(NavProto, name, {
          configurable: true, enumerable: false,
          get: asNative(function() { return undefined; }, name),
        });
      }
    } catch (e) {}
  }

  def('vendor', "");
  def('vendorSub', '');
  def('productSub', "20100101");
  def('oscpu', "Linux armv8l");
  def('buildID', '20181001000000');
  def('platform', "Linux armv8l");
  removeProp('userAgentData');
})();
