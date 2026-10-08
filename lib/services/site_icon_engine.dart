import 'dart:math' as math;
import 'dart:typed_data';

import 'package:webspace/services/url_host.dart';

/// Smallest icon edge (px) that is preferred over the fetched favicon
/// candidates (ICON-010). A 16px `favicon.ico` frame reads worse in the
/// drawer than the 128-256px public-service icons it would displace.
const int kMinSiteIconEdge = 32;

/// Largest icon edge (px) kept. Android WebView asks for favicons no larger
/// than this, so icons fetched from the page's links are scaled to match.
const int kMaxSiteIconEdge = 192;

/// Most icon links fetched for one document. Pages declare a handful; a page
/// listing hundreds would otherwise turn one load into hundreds of requests.
const int kMaxSiteIconCandidates = 6;

/// Longest `data:` icon link taken, in characters.
const int kMaxDataIconLength = 256 * 1024;

/// A PNG the webview reported for the site's own page.
class SiteIcon {
  SiteIcon(this.png, {required this.width, required this.height});

  final Uint8List png;
  final int width;
  final int height;

  int get edge => math.min(width, height);
}

/// Where the site webview reports its page icon. [siteUrl] is the site's home
/// URL (`WebViewModel.initUrl`), not the URL the webview mounts on.
class SiteIconTarget {
  const SiteIconTarget({required this.siteUrl, required this.onIcon});

  final String siteUrl;
  final void Function(SiteIcon icon) onIcon;
}

/// Width and height from a PNG's IHDR chunk, or null when [bytes] is not a
/// PNG. The Android plugin re-encodes every received bitmap as PNG.
({int width, int height})? pngDimensions(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 24) return null;
  for (var i = 0; i < signature.length; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final data = ByteData.sublistView(bytes);
  final width = data.getUint32(16);
  final height = data.getUint32(20);
  if (width == 0 || height == 0) return null;
  return (width: width, height: height);
}

/// The host a page must be on for its icon to count as the site's, with a
/// leading `www.` folded so `example.com` and `www.example.com` agree. Null
/// for anything that is not an http(s) URL with a host.
Host? siteIconHost(String? url) => Host.ofWebUrl(url)?.withoutWww;

/// An icon link the top document declared, as the watcher reports it.
class SiteIconLink {
  const SiteIconLink({required this.href, this.sizes = '', this.type = ''});

  final String href;
  final String sizes;
  final String type;

  /// The links in a watcher report, skipping any entry that is not an object
  /// with a string `href`: the report comes from page JS.
  static List<SiteIconLink> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <SiteIconLink>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final href = entry['href'];
      if (href is! String || href.isEmpty) continue;
      final sizes = entry['sizes'];
      final type = entry['type'];
      out.add(SiteIconLink(
        href: href,
        sizes: sizes is String ? sizes : '',
        type: type is String ? type : '',
      ));
    }
    return out;
  }
}

final RegExp _sizeToken = RegExp(r'^(\d+)[xX](\d+)$');

/// The URLs worth fetching for a document at [documentUrl] that declared
/// [links] (ICON-013), best first.
///
/// With no links the document's icon is `/favicon.ico`, as in Blink and
/// WebKit. SVG links are skipped (the fetched-favicon path renders SVG), as
/// are links whose declared sizes are all under [kMinSiteIconEdge]. An
/// `http:` link on an `https:` document is upgraded, as a browser upgrades
/// mixed images, so the request never goes out in cleartext.
List<String> siteIconCandidates(List<SiteIconLink> links,
    {required String documentUrl}) {
  final doc = Uri.tryParse(documentUrl);
  if (doc == null ||
      (doc.scheme != 'http' && doc.scheme != 'https') ||
      doc.host.isEmpty) {
    return const [];
  }
  if (links.isEmpty) {
    return [
      Uri(
        scheme: doc.scheme,
        host: doc.host,
        port: doc.hasPort ? doc.port : null,
        path: '/favicon.ico',
      ).toString(),
    ];
  }
  final ranked = <({String url, int edge, int index})>[];
  final seen = <String>{};
  for (final link in links) {
    final type = link.type.toLowerCase();
    if (type.contains('svg')) continue;
    var uri = Uri.tryParse(link.href);
    if (uri == null) continue;
    if (uri.scheme == 'data') {
      final lower = link.href.toLowerCase();
      if (link.href.length > kMaxDataIconLength ||
          !lower.startsWith('data:image/') ||
          lower.startsWith('data:image/svg')) {
        continue;
      }
    } else if (uri.scheme == 'http' || uri.scheme == 'https') {
      if (uri.host.isEmpty || uri.path.toLowerCase().endsWith('.svg')) {
        continue;
      }
      if (doc.scheme == 'https' && uri.scheme == 'http') {
        uri = uri.replace(scheme: 'https');
      }
    } else {
      continue;
    }
    var edge = 0;
    var declared = false;
    for (final token in link.sizes.trim().split(RegExp(r'\s+'))) {
      if (token.toLowerCase() == 'any') {
        declared = true;
        edge = math.max(edge, kMaxSiteIconEdge);
        continue;
      }
      final m = _sizeToken.firstMatch(token);
      if (m == null) continue;
      declared = true;
      final w = int.tryParse(m.group(1)!) ?? 0;
      final h = int.tryParse(m.group(2)!) ?? 0;
      edge = math.max(edge, math.min(w, h));
    }
    if (declared && edge < kMinSiteIconEdge) continue;
    final url = uri.toString();
    if (!seen.add(url)) continue;
    ranked.add((url: url, edge: edge, index: ranked.length));
  }
  // Declared sizes first, largest first. List.sort is not stable, so the
  // index keeps ties in document order.
  ranked.sort((a, b) {
    final bySize = b.edge.compareTo(a.edge);
    return bySize != 0 ? bySize : a.index.compareTo(b.index);
  });
  return [
    for (final c in ranked.take(kMaxSiteIconCandidates)) c.url,
  ];
}

/// Decides which icons are the site's true icon (ICON-009, ICON-013).
///
/// Android's `onReceivedIcon` carries only a bitmap: no URL, no document. It
/// fires once per `rel=icon` candidate in download-completion order, again
/// whenever the page edits its icon links, and for whatever document is
/// loaded.
///
/// While a main-frame load is in flight an icon can belong to either of two
/// documents. The replaced one may still have downloads out. The loading one
/// announces its icons after its load event, and WebView calls
/// `onReceivedIcon` from native code while it posts `onPageFinished` from
/// `didStopLoading`, so the loading document's own icon can come first. No
/// callback orders the two, so a mid-load icon is taken only when it is the
/// site's whichever document it came from. `onLoadStart` is posted at commit
/// with the committed URL, but on a cold first WebView an icon can still reach
/// Dart before it, so an icon that arrives while no web document is known is
/// held and judged, as a mid-load icon, against the next one that is.
///
/// Where the webview reports no icons (iOS, macOS, Linux), the app fetches
/// the links the document declared at load instead; those carry a document
/// token so a fetch that outlives its document is dropped. The document's own
/// load report can reach Dart before its `onLoadStart`, so a start for the URL
/// that already reported its load, before that load's `onLoadStop`, is that
/// document's late start, not a new document.
class SiteIconEngine {
  SiteIconEngine(String siteUrl) : _siteHost = siteIconHost(siteUrl);

  final Host? _siteHost;
  bool _loading = false;
  bool _onSite = false;
  bool _iconLinksChanged = false;
  int _documentBestEdge = 0;
  bool _documentIsWeb = false;
  bool _replacedIconsAreSites = true;
  int _document = 0;
  int? _linksClaimed;
  final List<Uint8List> _held = [];
  String? _loadReported;

  /// Icons a page may send before its document is known. Pages declare a
  /// handful; this bounds a page that declares hundreds.
  static const int _maxHeld = 16;

  /// The decision state, for the app log: no URL, so it is not sensitive.
  String get stateForLog => 'doc=$_document loading=$_loading '
      'onSite=$_onSite web=$_documentIsWeb linksChanged=$_iconLinksChanged '
      'replacedAreSites=$_replacedIconsAreSites best=$_documentBestEdge '
      'claimed=$_linksClaimed held=${_held.length} '
      'loadReported=${_loadReported != null}';

  bool _matchesSite(String? url) {
    final host = siteIconHost(url);
    return host != null && host == _siteHost;
  }

  /// A main-frame load committed at [url]. Returns the held icons it makes
  /// the site's.
  List<SiteIcon> onLoadStarted(String? url) {
    final reported = _loadReported;
    _loadReported = null;
    if (reported != null && reported == _withoutFragment(url)) {
      return const [];
    }
    // A page that is not http(s) announces no icons of its own, so what may
    // still be in flight is from the page before it.
    if (_documentIsWeb) {
      _replacedIconsAreSites = _onSite && !_iconLinksChanged;
    }
    _document++;
    _loading = true;
    _onSite = _matchesSite(url);
    _iconLinksChanged = false;
    _documentBestEdge = 0;
    _documentIsWeb = siteIconHost(url) != null;
    return _judgeHeld();
  }

  /// `onLoadStop` for the top document at [url]. Returns the held icons it
  /// makes the site's.
  List<SiteIcon> onLoadFinished(String? url) {
    _loadReported = null;
    _loading = false;
    _onSite = _matchesSite(url);
    _documentIsWeb = siteIconHost(url) != null;
    return _judgeHeld();
  }

  /// The watcher's report of the top document's load event, where the app
  /// fetches page icons (ICON-013). It can come before `onLoadStop`, and on
  /// a cold first WebView before `onLoadStart` too.
  List<SiteIcon> onDocumentLoaded(String? url) {
    final taken = onLoadFinished(url);
    _loadReported = _withoutFragment(url);
    return taken;
  }

  /// The top document edited its icon links after the set Blink announced
  /// at load. Every later icon for this document is a script-made variant
  /// (an unread badge, a status dot), not the site's icon.
  void onIconLinksChanged() {
    _iconLinksChanged = true;
  }

  /// The icon to report for [png], or null when it is not this site's icon
  /// or does not beat one this document already produced.
  SiteIcon? onIcon(Uint8List png) {
    if (!_documentIsWeb) {
      if (_held.length < _maxHeld) _held.add(png);
      return null;
    }
    if (!_onSite || _iconLinksChanged) return null;
    if (_loading && !_replacedIconsAreSites) return null;
    return _accept(png);
  }

  /// A token for fetching the icon links the top document at [url] declared,
  /// or null when it is off the site, still loading, or already claimed its
  /// links: one fetch per document, however often the page reports.
  int? claimIconLinks(String? url) {
    if (_loading || !_matchesSite(url) || _linksClaimed == _document) {
      return null;
    }
    _linksClaimed = _document;
    return _document;
  }

  /// [png] fetched from the links claimed as [document]. Links the page
  /// edits later do not matter here: these are the ones it declared at load.
  SiteIcon? onLinkedIcon(int document, {required Uint8List png}) {
    if (document != _document) return null;
    return _accept(png);
  }

  List<SiteIcon> _judgeHeld() {
    if (!_documentIsWeb || _held.isEmpty) return const [];
    final held = List.of(_held);
    _held.clear();
    return [
      for (final png in held)
        if (onIcon(png) case final icon?) icon,
    ];
  }

  static String? _withoutFragment(String? url) {
    if (url == null) return null;
    final uri = Uri.tryParse(url);
    return uri == null ? url : uri.removeFragment().toString();
  }

  SiteIcon? _accept(Uint8List png) {
    final size = pngDimensions(png);
    if (size == null) return null;
    final icon = SiteIcon(png, width: size.width, height: size.height);
    if (icon.edge < kMinSiteIconEdge || icon.edge <= _documentBestEdge) {
      return null;
    }
    _documentBestEdge = icon.edge;
    return icon;
  }
}

/// Whether an icon with [newEdge] replaces the stored one. An entry loaded
/// from disk yields to the first icon this launch that is at least as large,
/// so an icon the site has since dropped (a badge that was showing at load)
/// heals on the next launch. Within a launch only a strictly larger icon
/// replaces, so pages of one site with different icons do not flip it.
bool shouldReplaceSiteIcon({
  required int? storedEdge,
  required bool storedThisLaunch,
  required int newEdge,
}) {
  if (storedEdge == null) return true;
  if (newEdge > storedEdge) return true;
  return !storedThisLaunch && newEdge == storedEdge;
}
