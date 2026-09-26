/// JS handler the watcher calls from the top document's load event.
const String kIconDocumentLoadedHandler = 'wsIconDocumentLoaded';

/// JS handler the watcher calls with the icon links Blink announced.
const String kIconLinksHandler = 'wsIconLinks';

/// JS handler the watcher calls when the top document edits its icon links.
const String kIconLinksChangedHandler = 'wsIconLinksChanged';

/// Follows the top document's icon links for the site-icon engine.
///
/// Three reports, each at most once per document:
///
/// - [kIconDocumentLoadedHandler], from inside the load event, so the
///   page-icon fetch (ICON-013) can start before `onLoadStop`. Android does
///   not read it: the report reaches Dart through a posted Java message,
///   which the icons it precedes in the page can overtake.
/// - [kIconLinksHandler], right after the load event, with the links Blink
///   announced (`href` resolved, `sizes`, `type`; `media` applied), for the
///   platforms whose webview reports no icon and the app fetches them
///   (ICON-013).
/// - [kIconLinksChangedHandler], when the page later edits that set
///   (ICON-011). Blink starts a new round of candidates on every edit to the
///   `rel=icon` links that are direct children of `<head>`
///   (`Document::IconURLs`); those rounds are how pages draw unread badges
///   into their favicon, so the engine stops taking icons for the document.
///   A page that declared no icon at load and adds its first one later (an
///   SPA mounting its `<head>`) has not changed an announced set, so that
///   first addition is not reported.
///
/// Main frame only: Blink ignores subframe icons. Pure Dart (no Flutter
/// imports) so the string is reachable from tests.
String buildIconLinkWatcherShim() => '''
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
        var rel = (el.getAttribute('rel') || '').toLowerCase().split(/\\s+/);
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
                  el.getAttribute('type') || ''].join('\\u0001'));
      }
      return out.join('\\u0002');
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
      report('$kIconLinksHandler', announcedLinks());
      if (!head) return;
      var observer = new MutationObserver(function() {
        var now = iconSet();
        if (now === announced) return;
        if (announced === '') {
          announced = now;
          return;
        }
        observer.disconnect();
        report('$kIconLinksChangedHandler');
      });
      observer.observe(head, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['href', 'rel', 'sizes', 'media', 'type']
      });
    }
    function onLoad() {
      report('$kIconDocumentLoadedHandler');
      setTimeout(watch, 0);
    }
    if (document.readyState === 'complete') {
      onLoad();
    } else {
      window.addEventListener('load', onLoad, { once: true });
    }
  } catch (e) {}
})();
''';
