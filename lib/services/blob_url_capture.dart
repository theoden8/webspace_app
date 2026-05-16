import 'dart:convert';

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
///
/// The same shim also wraps `window.fetch`: when page JS itself calls
/// `fetch(blobUrl)` (e.g. github.githubassets.com's
/// `fetch-utilities-*.js`), the wrapper recognises the blob: URL, looks
/// up the captured Blob and resolves with a synthesised Response built
/// directly from it. The browser's CSP `connect-src` enforcer never sees
/// the request, because no real fetch is dispatched. Uncaptured blob:
/// URLs and every non-blob URL fall through to the original fetch
/// unchanged.
const String blobUrlCaptureScript = r'''
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
''';

/// Click interceptor that bridges `<a download href="blob:">` activations
/// to Dart on Android. Required because Android System WebView's
/// `DownloadListener.onDownloadStart` (the upstream hook behind
/// `onDownloadStartRequest`) only fires for HTTP(S) responses the engine
/// decides to download — `blob:` URLs are JS-internal references that
/// never reach the listener, so a click on a blob-download link is a
/// silent no-op without this shim. iOS/macOS WKWebView surfaces blob
/// downloads through `onDownloadStartRequest` natively and does not
/// need (or want) this script.
///
/// Two activation paths exist for `<a download>`, and the shim covers
/// both:
///
/// 1. **In-DOM click**: the anchor is in the document and the user (or
///    a `synthetic click event`) triggers a normal click. A capturing
///    listener on `document` intercepts before any page handler can
///    cancel the event, preventDefaults the navigation, and bridges.
///
/// 2. **Detached `link.click()`**: the very common SaveAs pattern is
///    ```js
///    const a = document.createElement('a');
///    a.href = URL.createObjectURL(blob);
///    a.download = 'file.bin';
///    a.click();
///    ```
///    where the anchor is never appended to the document. The click
///    event does not bubble to `document`, so the document-level
///    listener never fires. `HTMLAnchorElement.prototype.click` is
///    patched to detect the blob-download case directly.
///
/// Both paths bridge through `_webspaceBlobDownloadStart(blobUrl,
/// filename)`. The Dart handler dispatches to the same
/// `_handleBlobDownload` flow that iOS/macOS' `onDownloadStartRequest`
/// uses, so the captured-Blob fast path in `window.__webspaceBlobs`
/// (populated by [blobUrlCaptureScript]) keeps working transparently.
const String blobDownloadClickInterceptScript = r'''
(function() {
  if (window.__webspaceBlobClickHooked) return;
  window.__webspaceBlobClickHooked = true;
  try {
    function asNative(fn, name) {
      try {
        var stubs = window.__wsFnStubs;
        if (stubs && typeof stubs.set === 'function') {
          stubs.set(fn, 'function ' + name + '() { [native code] }');
        }
      } catch (_) {}
      return fn;
    }
    function isBlobDownloadAnchor(el) {
      if (!el || el.tagName !== 'A') return false;
      if (!el.hasAttribute || !el.hasAttribute('download')) return false;
      var href = '';
      try { href = el.href || el.getAttribute('href') || ''; } catch (_) {}
      return typeof href === 'string' && href.indexOf('blob:') === 0;
    }
    function dispatchDownload(el) {
      var href = '';
      var name = '';
      try { href = el.href || el.getAttribute('href') || ''; } catch (_) {}
      try { name = el.getAttribute('download') || ''; } catch (_) {}
      try {
        window.flutter_inappwebview.callHandler(
          '_webspaceBlobDownloadStart', href, name);
      } catch (_) {}
    }
    var listener = function(e) {
      var el = e.target;
      // Bubble up through composed path so a click on a child of the
      // anchor (e.g. an icon inside <a download>) still resolves.
      while (el && el !== document && !isBlobDownloadAnchor(el)) {
        el = el.parentNode;
      }
      if (el && el !== document && isBlobDownloadAnchor(el)) {
        try { e.preventDefault(); } catch (_) {}
        try { e.stopPropagation(); } catch (_) {}
        dispatchDownload(el);
      }
    };
    document.addEventListener('click', listener, true);
    if (typeof HTMLAnchorElement !== 'undefined' &&
        HTMLAnchorElement.prototype &&
        typeof HTMLAnchorElement.prototype.click === 'function') {
      var origClick = HTMLAnchorElement.prototype.click;
      var patched = function click() {
        if (isBlobDownloadAnchor(this)) {
          dispatchDownload(this);
          return;
        }
        return origClick.apply(this, arguments);
      };
      asNative(patched, 'click');
      try { HTMLAnchorElement.prototype.click = patched; } catch (_) {}
    }
  } catch (_) {}
})();
''';

/// Builds the blob-download IIFE that runs in the webview's main frame
/// (via `controller.evaluateJavascript`) when `onDownloadStartRequest`
/// fires with scheme `blob:`. Two-stage strategy:
///
/// 1. **Fast path**: look the URL up in `window.__webspaceBlobs` (populated
///    by [blobUrlCaptureScript] at DOCUMENT_START). If hit, read the Blob
///    directly via `FileReader.readAsDataURL` — no network, no CSP check.
/// 2. **Fallback**: `fetch(blobUrl) → Blob → FileReader.readAsDataURL`.
///    Only reached for URLs minted before the shim ran (rare) or in a
///    realm we don't intercept (Workers). Fails on CSP-strict origins.
///
/// All paths report progress via `_webspaceBlobProgress`, success via
/// `_webspaceBlobDownload(filename, base64, mimeType, taskId)`, errors
/// via `_webspaceBlobDownloadError(message, taskId)`. The `taskId`
/// round-trips so the Dart handler can resolve which `DownloadTask` to
/// complete.
String buildBlobDownloadIife({
  required String blobUrl,
  required String taskId,
  String? suggestedFilename,
}) {
  final blobJson = jsonEncode(blobUrl);
  final fnJson = jsonEncode(suggestedFilename ?? '');
  final idJson = jsonEncode(taskId);
  return '''
(function(blobUrl, suggestedFilename, taskId) {
  function progress(done, total) {
    window.flutter_inappwebview.callHandler(
      '_webspaceBlobProgress', taskId, done, total);
  }
  function reportError(err) {
    window.flutter_inappwebview.callHandler(
      '_webspaceBlobDownloadError',
      (err && err.message) || String(err), taskId);
  }
  function readBlob(blob) {
    var total = blob.size || 0;
    progress(0, total);
    var reader = new FileReader();
    reader.onprogress = function(e) {
      if (e && e.lengthComputable) {
        progress(e.loaded, e.total);
      }
    };
    reader.onload = function() {
      progress(total, total);
      var result = reader.result || '';
      var comma = result.indexOf(',');
      var base64 = comma === -1 ? '' : result.substring(comma + 1);
      window.flutter_inappwebview.callHandler(
        '_webspaceBlobDownload',
        suggestedFilename,
        base64,
        blob.type || '',
        taskId
      );
    };
    reader.onerror = function() {
      var msg = (reader.error && reader.error.message) || 'read error';
      window.flutter_inappwebview.callHandler(
        '_webspaceBlobDownloadError', msg, taskId);
    };
    reader.readAsDataURL(blob);
  }
  try {
    var captured = window.__webspaceBlobs &&
      window.__webspaceBlobs.get(blobUrl);
    if (captured) {
      readBlob(captured);
      return;
    }
    fetch(blobUrl).then(function(r) { return r.blob(); })
      .then(readBlob)
      .catch(reportError);
  } catch (e) {
    reportError(e);
  }
})($blobJson, $fnJson, $idJson);
''';
}

