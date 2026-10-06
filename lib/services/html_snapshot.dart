/// Capturing a page for [HtmlCacheService] and swapping the rendered snapshot
/// back to the live page. Pure Dart: the webview factory evaluates
/// [htmlSnapshotScript] and drives [awaitOnlineForLiveSwap].
library;

/// Serialises the document so that parsing the result again lays out the way
/// the page did. Evaluated by the webview factory's `onLoadStop` in place of
/// the plugin's `getHtml()`, whose `<html>.outerHTML` differs in ways the
/// layout sees once the snapshot is rendered:
///
/// - The doctype is not part of `outerHTML`, so a standards-mode page came
///   back in quirks mode (percentage heights, line boxes, table sizing).
/// - CSS-in-JS libraries in production (styled-components, emotion) fill an
///   empty `<style>` through `CSSStyleSheet.insertRule`, which never reaches
///   the markup, and `document.adoptedStyleSheets` has no markup at all. Those
///   rules are written out as `<style>` text.
/// - The snapshot is rendered at the site's `currentUrl`, which after a
///   `pushState` is not the URL the document was served from, so path-relative
///   stylesheet URLs resolved elsewhere. A `<base>` pins the served URL, read
///   from the navigation timing entry because `pushState` moves
///   `document.baseURI` too.
///
/// The copy is edited in a document with no browsing context: a clone in the
/// page's own document runs custom-element constructors and lets every cloned
/// `<img>` and media element fetch again.
///
/// Returns null when there is no document element. `getHtml()` instead fell
/// back to fetching the URL through Dart's `HttpClient` whenever the site had
/// JavaScript off, outside the site's proxy.
const String htmlSnapshotScript = r'''
(function () {
  var d = document;
  var root = d.documentElement;
  if (!root) return null;
  var inert = d.implementation.createHTMLDocument('');
  var clone = inert.importNode(root, true);

  function rulesText(sheet) {
    var rules = sheet && !sheet.disabled ? sheet.cssRules : null;
    if (!rules || !rules.length) return null;
    var out = [];
    for (var i = 0; i < rules.length; i++) out.push(rules[i].cssText);
    return out.join('\n');
  }

  var live = d.querySelectorAll('style');
  var copies = clone.querySelectorAll('style');
  for (var i = 0; i < live.length && i < copies.length; i++) {
    if (/\S/.test(live[i].textContent)) continue;
    var text = rulesText(live[i].sheet);
    if (text) copies[i].textContent = text;
  }

  var adopted = d.adoptedStyleSheets || [];
  var body = clone.querySelector('body') || clone;
  for (var j = 0; j < adopted.length; j++) {
    var css = rulesText(adopted[j]);
    if (!css) continue;
    var el = inert.createElement('style');
    var media = adopted[j].media && adopted[j].media.mediaText;
    if (media) el.setAttribute('media', media);
    el.textContent = css;
    body.appendChild(el);
  }

  var nav = performance.getEntriesByType ?
      performance.getEntriesByType('navigation')[0] : null;
  var served = nav && /^https?:/.test(nav.name) ? nav.name : d.baseURI;
  var head = clone.querySelector('head');
  if (head && !d.querySelector('base[href]') && /^https?:/.test(served)) {
    var base = inert.createElement('base');
    base.setAttribute('href', served);
    head.insertBefore(base, head.firstChild);
  }

  var dt = d.doctype;
  var doctype = '';
  if (dt) {
    doctype = '<!DOCTYPE ' + dt.name +
        (dt.publicId ? ' PUBLIC "' + dt.publicId + '"' :
            (dt.systemId ? ' SYSTEM' : '')) +
        (dt.systemId ? ' "' + dt.systemId + '"' : '') + '>';
  }
  return doctype + clone.outerHTML;
})()
''';

/// Waits between connectivity probes before a rendered snapshot gives up on
/// the live page. The first probe can land while a per-app firewall that cut
/// the app off in the background (CalyxOS/Datura, Android's own background
/// restrictions) has not let it back out yet; a snapshot whose subresources
/// fail fast settles inside that window.
const List<Duration> liveSwapProbeDelays = [
  Duration.zero,
  Duration(seconds: 2),
  Duration(seconds: 5),
  Duration(seconds: 10),
  Duration(seconds: 20),
];

/// Resolves true once [isOnline] reports the network and [stillWanted] still
/// holds, false when every probe in [liveSwapProbeDelays] found it offline or
/// [stillWanted] stopped holding (the user navigated, so their navigation is
/// the intent).
Future<bool> awaitOnlineForLiveSwap({
  required Future<bool> Function() isOnline,
  required bool Function() stillWanted,
  Future<void> Function(Duration) wait = Future<void>.delayed,
}) async {
  for (final delay in liveSwapProbeDelays) {
    if (delay > Duration.zero) await wait(delay);
    if (!stillWanted()) return false;
    if (await isOnline()) return stillWanted();
  }
  return false;
}
