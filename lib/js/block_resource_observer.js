// Reports each host the page loaded from, once, in batches, to
// `blockResourceLoadedBatch`. Recording only: it cannot block.
//
// WebKit (iOS/macOS) only. Android accounts sub-resources natively in
// FastSubresourceInterceptor; WKWebView has no shouldInterceptRequest, so this
// runs in every frame and reports through a Dart handler registered beside it
// in WebViewFactory's page handlers.
(function() {
  // Per-host dedup. PerformanceObserver fires once per loaded resource;
  // a typical news page is hundreds of entries across ~30 hosts. We
  // record one host per Dart roundtrip and dedup the rest in JS — same
  // semantics as the native Android interceptor, but driven from the
  // performance timeline because WebKit doesn't expose a sub-resource
  // intercept hook.
  var seenHost = Object.create(null);
  var pending = [];           // batched hosts not yet sent
  var pendingTimer = null;
  var BATCH_MS = 250;
  var BATCH_MAX = 64;

  function flush() {
    pendingTimer = null;
    if (!pending.length) return;
    if (!(window.flutter_inappwebview && window.flutter_inappwebview.callHandler)) {
      setTimeout(flush, 50);
      return;
    }
    var batch = pending;
    pending = [];
    window.flutter_inappwebview.callHandler('blockResourceLoadedBatch', batch);
  }
  function schedule() {
    if (pending.length >= BATCH_MAX) { flush(); return; }
    if (pendingTimer == null) pendingTimer = setTimeout(flush, BATCH_MS);
  }
  function report(url) {
    if (!url || url.charCodeAt(0) === 100 /* d */) return; // data:
    if (url.indexOf('http') !== 0) return;
    var host;
    try { host = new URL(url).hostname; } catch (e) { return; }
    if (!host || seenHost[host]) return;
    seenHost[host] = 1;
    pending.push(host);
    schedule();
  }
  var po = new PerformanceObserver(function(list) {
    var entries = list.getEntries();
    for (var i = 0; i < entries.length; i++) report(entries[i].name);
  });
  po.observe({type: 'resource', buffered: true});
  po.observe({type: 'navigation', buffered: true});
})();
