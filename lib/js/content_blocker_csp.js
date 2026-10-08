// ABP `$csp=` directives as a `<meta http-equiv>` policy. A browser honours
// one like the header when it lands before the first fetch, which
// DOCUMENT_START does, and WKWebView exposes no response-header rewrite.
(function() {
  if (document.documentElement) {
    var m = document.createElement('meta');
    m.setAttribute('http-equiv', 'Content-Security-Policy');
    m.setAttribute('content', CONFIG.directives);
    (document.head || document.documentElement).appendChild(m);
  }
})();
