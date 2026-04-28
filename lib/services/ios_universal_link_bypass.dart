/// iOS Universal Link bypass.
///
/// `WKWebView` honors apple-app-site-association entries: when the
/// user taps a link (or follows a redirect chain rooted in a tap)
/// whose URL matches an installed app's AASA file, iOS routes the
/// navigation OUT of the webview into the native app — silently,
/// without a prompt, and even when the user explicitly added the
/// site to WebSpace and is using the webview on purpose.
///
/// The webview-side fix: cancel the offending navigation and reissue
/// it via `controller.loadUrl` (a programmatic load, navigation type
/// `.other`). WebKit doesn't match programmatic loads against AASA,
/// so the URL renders inside the webview as the user intended.
///
/// Scope: iOS only. Android's WebView doesn't auto-launch installed
/// apps for plain http(s) URLs — `intent://` schemes are handled
/// separately via `ExternalUrlParser`.
class IosUniversalLinkBypass {
  IosUniversalLinkBypass();

  /// Hosts whose AASA entries activate Universal Links from WKWebView
  /// even when the navigation is a server redirect that followed a
  /// user click. Matched by exact host or `*.host` suffix.
  ///
  /// Start narrow: add a host only when an actual report surfaces.
  /// Many domains with AASA entries (LinkedIn, Twitter, Reddit) don't
  /// auto-launch from WKWebView in practice and need no bypass.
  static const Set<String> _domains = {
    // Google Maps: maps.google.com auto-launches the Google Maps iOS
    // app from WKWebView even on the consent.google.com → maps.google.com
    // redirect after the cookie-consent flow, kicking the user out of
    // the webview the moment they accept consent.
    'maps.google.com',
    // Google Maps short links (maps.app.goo.gl/...) resolve to
    // maps.google.com via 302 and trigger the same UL routing.
    'maps.app.goo.gl',
  };

  /// Per-WebView memo: URL → timestamp of the last cancel-and-reissue.
  /// After we reissue programmatically the same URL fires
  /// `shouldOverrideUrlLoading` again; the memo flips the second pass
  /// to ALLOW so we don't bounce in a loop.
  final Map<String, DateTime> _recentBypass = {};

  /// Memo TTL. Long enough that the reissued navigation arrives and
  /// resolves; short enough that a future re-navigation to the same
  /// URL gets bypassed again.
  static const Duration _memoWindow = Duration(seconds: 2);

  /// True when [url]'s host is on the bypass list. Pure function;
  /// callers should still gate on `Platform.isIOS`.
  static bool isUniversalLinkDomain(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    for (final domain in _domains) {
      if (host == domain) return true;
      if (host.endsWith('.$domain')) return true;
    }
    return false;
  }

  /// Decide whether the caller should cancel-and-reissue this
  /// navigation. Returns:
  ///   * `true` on the first pass for a UL-domain URL (caller
  ///     cancels the navigation and reissues via `loadUrl`),
  ///   * `false` on the second pass (the just-reissued nav landing
  ///     in shouldOverrideUrlLoading again — caller allows it).
  ///
  /// The memo entry is consumed on the second pass, so a fresh
  /// navigation to the same URL later still triggers the bypass.
  bool shouldCancelAndReissue(String url, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final last = _recentBypass[url];
    if (last != null && t.difference(last) < _memoWindow) {
      _recentBypass.remove(url);
      return false;
    }
    _recentBypass[url] = t;
    return true;
  }

  /// Test hook.
  void clear() => _recentBypass.clear();
}
