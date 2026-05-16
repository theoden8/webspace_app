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
