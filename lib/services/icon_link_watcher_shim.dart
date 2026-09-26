/// JS handler the watcher calls when the top document edits its icon links.
const String kIconLinksChangedHandler = 'wsIconLinksChanged';

/// JS handler the watcher calls with `('started', token)` at document start
/// and `('loaded', token)` from the document's `load` listener (ICON-009).
const String kIconDocumentHandler = 'wsIconDocument';

/// Reports, once per document, that the page changed its icon links after the
/// set Blink announced (ICON-011).
///
/// Also reports when the document begins and when its load event runs, under
/// a token drawn at document start. Blink announces icons only after every
/// `load` listener has returned (`LocalFrame::UpdateFaviconURL` waits for
/// `LoadEventFinished`), and the bridge call is synchronous up to Java, so the
/// `loaded` report reaches the site-icon engine ahead of the document's first
/// icon. `onLoadStop` does not: WebView can deliver the icon first.
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
    var token = Math.random().toString(36).slice(2) + Date.now().toString(36);
    function report(phase) {
      var iaw = window.flutter_inappwebview;
      if (iaw && typeof iaw.callHandler === 'function') {
        try { iaw.callHandler('$kIconDocumentHandler', phase, token); } catch (e) {}
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
''';
