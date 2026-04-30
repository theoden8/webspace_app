/// JavaScript that captures every Blob handed to URL.createObjectURL so the
/// blob-download IIFE can read it directly via FileReader instead of calling
/// fetch(blobUrl). Sites with a strict CSP `connect-src` (notably github.com)
/// reject `fetch(blob:...)` even when the blob is same-origin, because the
/// CSP doesn't whitelist `blob:` for connect — and our WebView enforces it
/// where stock Chrome/Firefox internally treat blob reads as exempt. Without
/// this shim a "Save as…" link backed by a blob URL on github.com fails
/// silently with `Refused to connect because it violates the document's
/// Content Security Policy`. By capturing the Blob object at the moment the
/// URL string is minted, the download IIFE has a direct reference and can
/// skip the network/connect-src code path entirely. URL.revokeObjectURL
/// releases the entry so the Blob can be GC'd. The map is bounded so a
/// pathological page that never revokes can't grow it without limit.
const String blobUrlCaptureScript = r'''
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
''';
