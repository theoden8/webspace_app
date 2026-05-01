(function() {
  if (window.__webspaceBlobs) return;
  try {
    // --- Function.prototype.toString hardening (shared with desktop_mode +
    // location_spoof via window.__wsFnStubs / __wsFnToStringPatched). Without
    // it, a fingerprinter calling toString on URL.createObjectURL would read
    // back our wrapper source instead of "[native code]".
    var _origFnToString = Function.prototype.toString;
    var _stubs = window.__wsFnStubs || new WeakMap();
    window.__wsFnStubs = _stubs;
    function asNative(fn, name) {
      _stubs.set(fn, 'function ' + name + '() { [native code] }');
      return fn;
    }
    if (!window.__wsFnToStringPatched) {
      window.__wsFnToStringPatched = true;
      var patched = function toString() {
        var stub = _stubs.get(this);
        return stub !== undefined ? stub : _origFnToString.call(this);
      };
      _stubs.set(patched, 'function toString() { [native code] }');
      try { Function.prototype.toString = patched; } catch (_) {}
    }

    var origCreate = URL.createObjectURL;
    var origRevoke = URL.revokeObjectURL;
    if (typeof origCreate !== 'function') return;
    var map = new Map();
    var keys = [];
    var MAX = 64;
    var _patchedCreate = function createObjectURL(obj) {
      var url = origCreate.apply(URL, arguments);
      try {
        if (obj && (obj instanceof Blob)) {
          if (keys.length >= MAX) {
            var oldest = keys.shift();
            map.delete(oldest);
          }
          map.set(url, obj);
          keys.push(url);
        }
      } catch (_) {}
      return url;
    };
    asNative(_patchedCreate, 'createObjectURL');
    URL.createObjectURL = _patchedCreate;
    if (typeof origRevoke === 'function') {
      var _patchedRevoke = function revokeObjectURL(url) {
        try {
          if (map.delete(url)) {
            var i = keys.indexOf(url);
            if (i >= 0) keys.splice(i, 1);
          }
        } catch (_) {}
        return origRevoke.apply(URL, arguments);
      };
      asNative(_patchedRevoke, 'revokeObjectURL');
      URL.revokeObjectURL = _patchedRevoke;
    }
    Object.defineProperty(window, '__webspaceBlobs', {
      value: { get: function(url) { return map.get(url); } },
      configurable: false,
      enumerable: false,
      writable: false,
    });
  } catch (_) {}
})();
