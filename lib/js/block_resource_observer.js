// Reports how many requests the page loaded from each host, in batches, to
// `blockResourceLoadedBatch`: one count per resource the page loaded, the
// unit the app counts blocks in too (CB-012). Recording only: it cannot block.
//
// WebKit (iOS, macOS, Linux) only. Android counts sub-resources natively in
// FastSubresourceInterceptor; WKWebView has no shouldInterceptRequest, so this
// runs in every frame and reports through a Dart handler registered beside it
// in WebViewFactory's page handlers. A frame's own document is counted by the
// frame that loaded it, as one of that frame's resources, so only the top
// frame counts its navigation entry.
(function() {
  var pending = Object.create(null); // host -> requests not yet sent
  var pendingCount = 0;
  var pendingTimer = null;
  var BATCH_MS = 250;
  var BATCH_MAX = 64;

  function flush() {
    pendingTimer = null;
    if (!pendingCount) return;
    if (!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
      setTimeout(flush, 50);
      return;
    }
    var batch = pending;
    pending = Object.create(null);
    pendingCount = 0;
    window.flutter_inappwebview.callHandler('blockResourceLoadedBatch', batch);
  }
  function schedule() {
    if (pendingCount >= BATCH_MAX) { flush(); return; }
    if (pendingTimer == null) pendingTimer = setTimeout(flush, BATCH_MS);
  }
  function report(url) {
    if (!url || url.charCodeAt(0) === 100 /* d */) return; // data:
    if (url.indexOf('http') !== 0) return;
    var host;
    try { host = new URL(url).hostname; } catch (e) { return; }
    if (!host) return;
    pending[host] = (pending[host] || 0) + 1;
    pendingCount++;
    schedule();
  }
  var po = new PerformanceObserver(function(list) {
    var entries = list.getEntries();
    for (var i = 0; i < entries.length; i++) report(entries[i].name);
  });
  po.observe({type: 'resource', buffered: true});
  if (window === window.top) po.observe({type: 'navigation', buffered: true});
})();
