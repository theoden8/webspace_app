  // Every override a shim installs stringifies as native code through one
  // patched Function.prototype.toString per realm. The functions it answers
  // for live in one map, shared with the same-origin frame above: a page can
  // call one realm's toString on another realm's function, and a map per realm
  // would answer with the other realm's source.
  var _origFnToString = Function.prototype.toString;
  var _stubs = globalThis.__wsFnStubs || _parentStubs() || new WeakMap();
  globalThis.__wsFnStubs = _stubs;
  function _parentStubs() {
    try {
      var up = globalThis.parent;
      return up && up !== globalThis ? up.__wsFnStubs : undefined;
    } catch (e) {
      return undefined;
    }
  }
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
