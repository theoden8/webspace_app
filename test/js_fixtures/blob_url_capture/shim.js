(function() {
  if (window.__webspaceBlobs) return;
  try {
    var origCreate = URL.createObjectURL;
    var origRevoke = URL.revokeObjectURL;
    if (typeof origCreate !== 'function') return;
    var map = new Map();
    var keys = [];
    var MAX = 64;
    URL.createObjectURL = function(obj) {
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
    if (typeof origRevoke === 'function') {
      URL.revokeObjectURL = function(url) {
        try {
          if (map.delete(url)) {
            var i = keys.indexOf(url);
            if (i >= 0) keys.splice(i, 1);
          }
        } catch (_) {}
        return origRevoke.apply(URL, arguments);
      };
    }
    Object.defineProperty(window, '__webspaceBlobs', {
      value: { get: function(url) { return map.get(url); } },
      configurable: false,
      enumerable: false,
      writable: false,
    });
  } catch (_) {}
})();
