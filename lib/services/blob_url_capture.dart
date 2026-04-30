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

