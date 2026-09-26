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
/// loaded.
///
/// While a main-frame load is in flight an icon can belong to either of two
/// documents. The replaced one may still have downloads out. The loading one
/// announces its icons after its load event, and WebView calls
/// `onReceivedIcon` from native code while it posts `onPageFinished` from
/// `didStopLoading`, so the loading document's own icon can come first. No
/// callback orders the two, so a mid-load icon is taken only when it is the
/// site's whichever document it came from. `onLoadStart` is posted at commit
/// with the committed URL, so the loading document's host is known by then.
class SiteIconEngine {
  SiteIconEngine(String siteUrl) : _siteHost = siteIconHost(siteUrl);

  final String? _siteHost;
  bool _loading = false;
  bool _onSite = false;
  bool _iconLinksChanged = false;
  int _documentBestEdge = 0;
  bool _documentIsWeb = false;
  bool _replacedIconsAreSites = true;

  bool _matchesSite(String? url) {
    final host = siteIconHost(url);
    return host != null && host == _siteHost;
  }

  void onLoadStarted(String? url) {
    // A page that is not http(s) announces no icons of its own, so what may
    // still be in flight is from the page before it.
    if (_documentIsWeb) {
      _replacedIconsAreSites = _onSite && !_iconLinksChanged;
    }
    _loading = true;
    _onSite = _matchesSite(url);
    _iconLinksChanged = false;
    _documentBestEdge = 0;
    _documentIsWeb = siteIconHost(url) != null;
  }

  void onLoadFinished(String? url) {
    _loading = false;
    _onSite = _matchesSite(url);
    _documentIsWeb = siteIconHost(url) != null;
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
    if (!_onSite || _iconLinksChanged) return null;
    if (_loading && !_replacedIconsAreSites) return null;
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
