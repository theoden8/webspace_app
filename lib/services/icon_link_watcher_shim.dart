/// JS handler the watcher calls when the top document edits its icon links.
const String kIconLinksChangedHandler = 'wsIconLinksChanged';

/// Reports, once per document, that the page changed its icon links after the
/// set Blink announced (ICON-011).
///
/// Blink sends a document's icon candidates only once its load event has
/// finished, and again on every later edit to the `rel=icon` links that are
/// direct children of `<head>` (`Document::IconURLs`). Those later rounds are
/// how pages draw unread badges into their favicon, so the site-icon engine
/// stops taking icons for the document after this reports.
///
/// A page that declared no icon at load and adds its first one later (an SPA
/// mounting its `<head>`) has not changed an announced set, so that first
/// addition is not reported. Main frame only: Blink ignores subframe icons.
///
/// Pure Dart (no Flutter imports) so the string is reachable from tests.
String buildIconLinkWatcherShim() => '''
(function() {
  try {
    if (window !== window.top) return;
    function iconSet() {
      var head = document.head;
      if (!head) return '';
      var out = [];
      var children = head.children;
      for (var i = 0; i < children.length; i++) {
        var el = children[i];
        if (el.tagName !== 'LINK') continue;
        var rel = (el.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
        if (rel.indexOf('icon') === -1) continue;
        out.push([el.href, el.getAttribute('sizes') || '',
                  el.getAttribute('media') || '',
                  el.getAttribute('type') || ''].join('\\u0001'));
      }
      return out.join('\\u0002');
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
          iaw.callHandler('$kIconLinksChangedHandler');
        }
      });
      observer.observe(head, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'rel', 'sizes', 'media', 'type']
      });
    }
    function afterLoad() { setTimeout(watch, 0); }
    if (document.readyState === 'complete') {
      afterLoad();
    } else {
      window.addEventListener('load', afterLoad, { once: true });
    }
  } catch (e) {}
})();
''';
