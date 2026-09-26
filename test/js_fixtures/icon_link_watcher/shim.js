(function() {
  try {
    if (window !== window.top) return;
    var token = Math.random().toString(36).slice(2) + Date.now().toString(36);
    function report(phase) {
      var iaw = window.flutter_inappwebview;
      if (iaw && typeof iaw.callHandler === 'function') {
        try { iaw.callHandler('wsIconDocument', phase, token); } catch (e) {}
      }
    }
    report('started');
    function iconSet() {
      var head = document.head;
      if (!head) return '';
      var out = [];
      var children = head.children;
      for (var i = 0; i < children.length; i++) {
        var el = children[i];
        if (el.tagName !== 'LINK') continue;
        var rel = (el.getAttribute('rel') || '').toLowerCase().split(/\s+/);
        if (rel.indexOf('icon') === -1) continue;
        out.push([el.href, el.getAttribute('sizes') || '',
                  el.getAttribute('media') || '',
                  el.getAttribute('type') || ''].join('\u0001'));
      }
      return out.join('\u0002');
    }
    function watch() {
      var head = document.head;
      if (!head) return;
      var announced = iconSet();
      var observer = new MutationObserver(function() {
        var now = iconSet();
        if (now === announced) return;
        if (announced === '') {
          announced = now;
          return;
        }
        observer.disconnect();
        var iaw = window.flutter_inappwebview;
        if (iaw && typeof iaw.callHandler === 'function') {
          iaw.callHandler('wsIconLinksChanged');
        }
      });
      observer.observe(head, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'rel', 'sizes', 'media', 'type']
      });
    }
    function afterLoad() {
      report('loaded');
      setTimeout(watch, 0);
    }
    if (document.readyState === 'complete') {
      afterLoad();
    } else {
      window.addEventListener('load', afterLoad, { once: true });
    }
  } catch (e) {}
})();
