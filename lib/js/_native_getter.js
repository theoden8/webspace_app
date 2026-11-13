  // The one way a shim installs an accessor: `read` called with the receiver,
  // stringifying as a platform accessor does (`get name`). False when the
  // property cannot be redefined. Included after _native_fn.js, whose
  // asNative it calls.
  function nativeGetter(target, name, read, enumerable) {
    try {
      Object.defineProperty(target, name, {
        configurable: true,
        enumerable: enumerable !== false,
        get: asNative(function() { return read.call(this); }, 'get ' + name),
      });
      return true;
    } catch (e) {
      return false;
    }
  }
