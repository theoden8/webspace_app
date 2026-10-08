// Downloads a `blob:` URL, evaluated in the webview's main frame (via
// `controller.evaluateJavascript`) when `onDownloadStartRequest` fires with
// scheme `blob:`. Two-stage strategy:
//
// 1. **Fast path**: look the URL up in `window.__webspaceBlobs` (populated
//    by blob_url_capture.js at DOCUMENT_START). If hit, read the Blob
//    directly via `FileReader.readAsDataURL` — no network, no CSP check.
// 2. **Fallback**: `fetch(blobUrl) → Blob → FileReader.readAsDataURL`.
//    Only reached for URLs minted before the shim ran (rare) or in a
//    realm we don't intercept (Workers). Fails on CSP-strict origins.
//
// All paths report progress via `_webspaceBlobProgress`, success via
// `_webspaceBlobDownload(filename, base64, mimeType, taskId)`, errors
// via `_webspaceBlobDownloadError(message, taskId)`. The `taskId`
// round-trips so the Dart handler can resolve which `DownloadTask` to
// complete.
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
})(CONFIG.blobUrl, CONFIG.suggestedFilename, CONFIG.taskId);
