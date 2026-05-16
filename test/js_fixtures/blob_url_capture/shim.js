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
      // Pass revoke through to the original implementation but DO NOT drop
      // the map entry. Sites like github.com synchronously call
      // URL.revokeObjectURL(url) right after triggering a <a download>
      // click; our click interceptor's callHandler is async, so by the
      // time Dart re-enters the page to evaluate the download IIFE the
      // revoke has already run. Dropping the entry on revoke makes the
      // IIFE's fast-path lookup miss and forces the CSP-blocked fetch
      // fallback. Holding the Blob reference keeps it alive in chromium's
      // blob storage so FileReader can still read it; the MAX=64 FIFO
      // cap in the create wrapper bounds memory.
      var _patchedRevoke = function revokeObjectURL(url) {
        return origRevoke.apply(URL, arguments);
      };
      asNative(_patchedRevoke, 'revokeObjectURL');
      URL.revokeObjectURL = _patchedRevoke;
    }

    // window.fetch wrapper — intercepts fetch(blob:URL) for any blob we
    // captured at createObjectURL time and resolves with a Response
    // synthesised from the Blob. No network call is dispatched, so the
    // CSP connect-src enforcer never runs against the blob: URL. Page
    // code (e.g. github.com's fetch-utilities) and our own download
    // IIFE both benefit. Non-blob URLs and uncaptured blob: URLs fall
    // through to the original fetch.
    var origFetch = window.fetch;
    if (typeof origFetch === 'function') {
      var _patchedFetch = function fetch(input, init) {
        var url = '';
        var method = 'GET';
        try {
          if (typeof input === 'string') {
            url = input;
            if (init && typeof init.method === 'string') {
              method = init.method.toUpperCase();
            }
          } else if (input && typeof input.url === 'string') {
            url = input.url;
            // init.method, when present, overrides Request.method (per
            // the fetch spec). Mirror that ordering.
            if (init && typeof init.method === 'string') {
              method = init.method.toUpperCase();
            } else if (typeof input.method === 'string') {
              method = input.method.toUpperCase();
            }
          }
        } catch (_) {}
        // Only intercept GET/HEAD on captured blob: URLs. Anything else
        // (POST/PUT, abort already fired) falls through to the original
        // fetch so the page sees real-fetch semantics — including a
        // proper TypeError or AbortError instead of a silent success.
        if (url && url.indexOf('blob:') === 0 &&
            (method === 'GET' || method === 'HEAD')) {
          var signal = (init && init.signal) ||
              (input && typeof input !== 'string' && input.signal) || null;
          if (signal && signal.aborted) {
            try {
              var reason = signal.reason !== undefined
                ? signal.reason
                : new DOMException('aborted', 'AbortError');
              return Promise.reject(reason);
            } catch (_) {}
          } else {
            var blob = map.get(url);
            if (blob) {
              try {
                var body = method === 'HEAD' ? null : blob;
                return Promise.resolve(new Response(body, {
                  status: 200,
                  statusText: 'OK',
                  headers: {
                    'Content-Type': blob.type || 'application/octet-stream',
                    'Content-Length': String(blob.size || 0),
                  },
                }));
              } catch (_) {}
            }
          }
        }
        return origFetch.apply(this, arguments);
      };
      asNative(_patchedFetch, 'fetch');
      try { window.fetch = _patchedFetch; } catch (_) {}
    }

    Object.defineProperty(window, '__webspaceBlobs', {
      value: { get: function(url) { return map.get(url); } },
      configurable: false,
      enumerable: false,
      writable: false,
    });
  } catch (_) {}
})();
