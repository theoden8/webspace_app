(function() {
  if (document.documentElement) {
    var m = document.createElement('meta');
    m.setAttribute('http-equiv', 'Content-Security-Policy');
    m.setAttribute('content', "script-src 'none'; img-src 'self'");
    (document.head || document.documentElement).appendChild(m);
  }
})();