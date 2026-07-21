(function() {
  'use strict';
  if (window.__ws_ua_identity_shim__) return;
  window.__ws_ua_identity_shim__ = true;

  // Shared Function.prototype.toString funnel (same WeakMap as the other
  // shims) so every getter stringifies as `[native code]`.
  var _origFnToString = Function.prototype.toString;
  var _stubs = window.__wsFnStubs || new WeakMap();
  window.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    try { _stubs.set(fn, 'function ' + name + '() { [native code] }'); } catch (e) {}
    return fn;
  }
  if (!window.__wsFnToStringPatched) {
    window.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    try { _stubs.set(patched, 'function toString() { [native code] }'); } catch (e) {}
    try { Function.prototype.toString = patched; } catch (e) {}
  }

  var NavProto = (typeof Navigator !== 'undefined') ? Navigator.prototype : null;

  // Define on Navigator.prototype (never the instance — an own-property on
  // `navigator` would self-incriminate), matching how real engines carry
  // these accessors.
  function def(name, value) {
    if (!NavProto) return;
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

  def('vendor', "Apple Computer, Inc.");
  def('vendorSub', '');
  def('productSub', "20030107");
  removeProp('oscpu');
  removeProp('buildID');
  def('platform', "iPhone");
  removeProp('userAgentData');
})();
