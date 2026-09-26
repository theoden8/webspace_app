(function() {
  try {
    if (window !== window.top) return;
    function iconLinks() {
      var head = document.head;
      var out = [];
      if (!head) return out;
      var children = head.children;
      for (var i = 0; i < children.length; i++) {
        var el = children[i];
        if (el.tagName !== 'LINK') continue;
        var rel = (el.getAttribute('rel') || '').toLowerCase().split(/\s+/);
        if (rel.indexOf('icon') === -1) continue;
        out.push(el);
      }
      return out;
    }
    function iconSet() {
      var links = iconLinks();
      var out = [];
      for (var i = 0; i < links.length; i++) {
        var el = links[i];
        out.push([el.href, el.getAttribute('sizes') || '',
                  el.getAttribute('media') || '',
                  el.getAttribute('type') || ''].join('\u0001'));
      }
      return out.join('\u0002');
    }
    function announcedLinks() {
      var links = iconLinks();
      var out = [];
      for (var i = 0; i < links.length; i++) {
        var el = links[i];
        var media = el.getAttribute('media');
        if (media && typeof window.matchMedia === 'function' &&
            !window.matchMedia(media).matches) {
          continue;
        }
        out.push({
          href: el.href,
          sizes: el.getAttribute('sizes') || '',
          type: el.getAttribute('type') || ''
        });
      }
      return out;
    }
    function report(name, arg) {
      var iaw = window.flutter_inappwebview;
      if (!iaw || typeof iaw.callHandler !== 'function') return;
      if (arg === undefined) iaw.callHandler(name);
      else iaw.callHandler(name, arg);
    }
    function watch() {
      var head = document.head;
      var announced = iconSet();
      report('wsIconLinks', announcedLinks());
      if (!head) return;
      var observer = new MutationObserver(function() {
        var now = iconSet();
        if (now === announced) return;
        if (announced === '') {
          announced = now;
          return;
        }
        observer.disconnect();
        report('wsIconLinksChanged');
      });
      observer.observe(head, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'rel', 'sizes', 'media', 'type']
      });
    }
    function onLoad() {
      report('wsIconDocumentLoaded');
      setTimeout(watch, 0);
    }
    if (document.readyState === 'complete') {
      onLoad();
    } else {
      window.addEventListener('load', onLoad, { once: true });
    }
  } catch (e) {}
})();
