(function() {
  try {
    if (window !== window.top) return;
    function report() {
      var iaw = window.flutter_inappwebview;
      if (!iaw || typeof iaw.callHandler !== 'function') return;
      var links = [];
      var generator = '';
      var head = document.head;
      if (head) {
        var els = head.querySelectorAll('link[rel][type][href], meta[name]');
        for (var i = 0; i < els.length; i++) {
          var el = els[i];
          if (el.tagName === 'META') {
            var name = (el.getAttribute('name') || '').toLowerCase();
            if (name === 'generator' && !generator) {
              generator = String(el.getAttribute('content') || '');
            }
            continue;
          }
          var rel = (el.getAttribute('rel') || '').toLowerCase().split(/\s+/);
          if (rel.indexOf('search') === -1) continue;
          var type = (el.getAttribute('type') || '').toLowerCase().trim();
          if (type !== 'application/opensearchdescription+xml') continue;
          if (links.length >= 4) continue;
          links.push({
            href: String(el.href),
            title: String(el.getAttribute('title') || '')
          });
        }
      }
      if (!links.length) return;
      iaw.callHandler('wsSearchLinks', {
        links: links,
        generator: generator.slice(0, 128)
      });
    }
    function onLoad() { setTimeout(report, 0); }
    if (document.readyState === 'complete') {
      onLoad();
    } else {
      window.addEventListener('load', onLoad, { once: true });
    }
  } catch (e) {}
})();
