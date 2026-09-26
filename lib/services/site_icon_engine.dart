import 'dart:math' as math;
import 'dart:typed_data';

/// Smallest icon edge (px) that is preferred over the fetched favicon
/// candidates (ICON-010). A 16px `favicon.ico` frame reads worse in the
/// drawer than the 128-256px public-service icons it would displace.
const int kMinSiteIconEdge = 32;

/// A PNG the webview reported for the site's own page.
class SiteIcon {
  SiteIcon(this.png, this.width, this.height);

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
String? siteIconHost(String? url) {
  if (url == null) return null;
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  return host.startsWith('www.') ? host.substring(4) : host;
}

/// Decides which icons the webview reports are the site's true icon
/// (ICON-009).
///
/// Android's `onReceivedIcon` carries only a bitmap: no URL, no document. It
/// fires once per `rel=icon` candidate in download-completion order, again
/// whenever the page edits its icon links, and for whatever document is
/// loaded. Blink announces a document's icons only once its load event has
/// run, so an icon arriving after a main-frame load started and before that
/// document's load event belongs to the document being replaced.
///
/// `onLoadStop` is not that moment: Blink announces the icons before it
/// reports the load finished, and WebView posts `onPageFinished` while the
/// icon arrives over IPC, so the page's own icon can land first. The page
/// reports its load event itself ([onDocumentLoaded], from inside a `load`
/// listener, which runs before the announcement), under a token it drew at
/// document start ([onDocumentStarted]). The native events stay the fallback
/// for a document that reports nothing.
class SiteIconEngine {
  SiteIconEngine(String siteUrl) : _siteHost = siteIconHost(siteUrl);

  final String? _siteHost;
  bool _loaded = false;
  bool _onSite = false;
  bool _iconLinksChanged = false;
  int _documentBestEdge = 0;
  String? _documentToken;

  // The page's reports and WebView's load events travel separately, so either
  // can come first for the same document. These pair them by origin, which
  // `history.pushState` cannot change.
  String? _awaitingDocumentOf;
  String? _documentAheadOf;

  bool _matchesSite(String? url) {
    final host = siteIconHost(url);
    return host != null && host == _siteHost;
  }

  static String? _originOf(String? url) {
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || uri.scheme.isEmpty) return null;
    if (uri.host.isEmpty) return uri.scheme;
    return '${uri.scheme}://${uri.host.toLowerCase()}:${uri.port}';
  }

  void _newDocument(String? url, String? token) {
    _loaded = false;
    _onSite = _matchesSite(url);
    _iconLinksChanged = false;
    _documentBestEdge = 0;
    _documentToken = token;
  }

  void onLoadStarted(String? url) {
    final origin = _originOf(url);
    final ahead = _documentAheadOf;
    _documentAheadOf = null;
    if (ahead != null && ahead == origin) return;
    _newDocument(url, null);
    _awaitingDocumentOf = origin;
  }

  /// The top document at [url] began, and named itself [token].
  void onDocumentStarted(String? url, String token) {
    final origin = _originOf(url);
    final awaited = _awaitingDocumentOf;
    _awaitingDocumentOf = null;
    _newDocument(url, token);
    _documentAheadOf = awaited != null && awaited == origin ? null : origin;
  }

  /// The top document named [token] ran its load event. A token other than
  /// the current document's is a replaced document reporting late.
  void onDocumentLoaded(String? url, String token) {
    if (token != _documentToken) return;
    _loaded = true;
    _onSite = _matchesSite(url);
  }

  void onLoadFinished(String? url) {
    // The page already began the next document, whose own load event is the
    // one that counts.
    if (_documentAheadOf != null) return;
    _awaitingDocumentOf = null;
    _loaded = true;
    _onSite = _matchesSite(url);
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
    if (!_loaded || !_onSite || _iconLinksChanged) return null;
    final size = pngDimensions(png);
    if (size == null) return null;
    final icon = SiteIcon(png, size.width, size.height);
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
