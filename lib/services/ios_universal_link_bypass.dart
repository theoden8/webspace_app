/// iOS Universal Link prompt gate.
///
/// `WKWebView` honors apple-app-site-association entries: when the
/// user taps a link (or follows a redirect chain rooted in a tap)
/// whose URL matches an installed app's AASA file, iOS routes the
/// navigation OUT of the webview into the native app — silently,
/// without a prompt, and even when the user explicitly added the
/// site to WebSpace and is using the webview on purpose.
///
/// Fix: on iOS, intercept navigations to known auto-launch URLs,
/// CANCEL them so iOS can't route to the app, and surface a
/// confirmation dialog (like the existing `intent://` prompt on
/// Android). The user picks:
///   * Continue here  — programmatic reload in the webview;
///     marked via [markApprovedContinue] so the reissued nav
///     passes through this gate without re-prompting.
///   * Open in app    — `url_launcher` external launch; iOS routes
///     it to the native app via Universal Links.
///   * Cancel         — drop the navigation; user stays where they
///     were.
///
/// Scope: iOS only. Android's WebView doesn't auto-launch installed
/// apps for plain http(s) URLs — `intent://` schemes are handled
/// separately via `ExternalUrlParser`.
class IosUniversalLinkBypass {
  IosUniversalLinkBypass();

  /// Match rules for hosts whose AASA aggressively activates Universal
  /// Links from WKWebView. Each rule is `host` + optional `pathPrefix`:
  ///   * pathPrefix == null  → any path on this host matches.
  ///   * pathPrefix != null  → only paths that start with this prefix
  ///     match (e.g. `www.google.com/maps*` matches but
  ///     `www.google.com/search` doesn't).
  ///
  /// Hosts also match their subdomains (`*.host`).
  static const List<_Rule> _rules = [
    // Google Maps: maps.google.com on any path. Triggers the Maps iOS
    // app even when the user explicitly added Google Maps to WebSpace
    // and is browsing the webview.
    _Rule('maps.google.com'),
    // Google Maps short links resolve to maps.google.com via 302.
    _Rule('maps.app.goo.gl'),
    // Google's own redirect after the consent flow lands on
    // www.google.com/maps (NOT maps.google.com), and that path on
    // www.google.com / google.com is also covered by the Maps AASA —
    // observed in user logs after accepting cookie consent.
    _Rule('www.google.com', pathPrefix: '/maps'),
    _Rule('google.com', pathPrefix: '/maps'),
  ];

  /// Per-WebView memo of URLs the user just approved to "continue
  /// here". Entries TTL out so a future re-navigation to the same URL
  /// re-prompts instead of silently passing through.
  final Map<String, DateTime> _approvedContinue = {};

  static const Duration _approvalWindow = Duration(seconds: 5);

  /// True when [url] should be intercepted and routed through the
  /// confirmation prompt. Pure function; callers should still gate
  /// on `Platform.isIOS`.
  static bool isUniversalLinkUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    final path = uri.path;
    for (final rule in _rules) {
      final hostMatches = host == rule.host || host.endsWith('.${rule.host}');
      if (!hostMatches) continue;
      if (rule.pathPrefix == null) return true;
      if (path == rule.pathPrefix ||
          path.startsWith('${rule.pathPrefix!}/') ||
          path.startsWith('${rule.pathPrefix!}?')) {
        return true;
      }
    }
    return false;
  }

  /// Called when the user picks "Continue here" — the next
  /// shouldOverrideUrlLoading for [url] within [_approvalWindow] is
  /// allowed through without prompting.
  void markApprovedContinue(String url, {DateTime? now}) {
    _approvedContinue[url] = now ?? DateTime.now();
  }

  /// True if the user just approved [url] to "continue here". Consumes
  /// the memo entry so a fresh navigation to the same URL later still
  /// triggers a prompt.
  bool consumeApproval(String url, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final last = _approvedContinue[url];
    if (last == null) return false;
    if (t.difference(last) > _approvalWindow) {
      _approvedContinue.remove(url);
      return false;
    }
    _approvedContinue.remove(url);
    return true;
  }

  /// Test hook.
  void clear() => _approvedContinue.clear();
}

class _Rule {
  final String host;
  final String? pathPrefix;
  const _Rule(this.host, {this.pathPrefix});
}
