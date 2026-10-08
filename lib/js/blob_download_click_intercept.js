// Click interceptor that bridges `<a download href="blob:">` activations
// to Dart on Android. Required because Android System WebView's
// `DownloadListener.onDownloadStart` (the upstream hook behind
// `onDownloadStartRequest`) only fires for HTTP(S) responses the engine
// decides to download — `blob:` URLs are JS-internal references that
// never reach the listener, so a click on a blob-download link is a
// silent no-op without this shim. iOS/macOS WKWebView surfaces blob
// downloads through `onDownloadStartRequest` natively and does not
// need (or want) this script.
//
// Two activation paths exist for `<a download>`, and the shim covers
// both:
//
// 1. **In-DOM click**: the anchor is in the document and the user (or
//    a `synthetic click event`) triggers a normal click. A capturing
//    listener on `document` intercepts before any page handler can
//    cancel the event, preventDefaults the navigation, and bridges.
//
// 2. **Detached `link.click()`**: the very common SaveAs pattern is
//    ```js
//    const a = document.createElement('a');
//    a.href = URL.createObjectURL(blob);
//    a.download = 'file.bin';
//    a.click();
//    ```
//    where the anchor is never appended to the document. The click
//    event does not bubble to `document`, so the document-level
//    listener never fires. `HTMLAnchorElement.prototype.click` is
//    patched to detect the blob-download case directly.
//
// Both paths bridge through `_webspaceBlobDownloadStart(blobUrl,
// filename)`. The Dart handler dispatches to the same
// `_handleBlobDownload` flow that iOS/macOS' `onDownloadStartRequest`
// uses, so the captured-Blob fast path in `window.__webspaceBlobs`
// (populated by blob_url_capture.js) keeps working transparently.
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
