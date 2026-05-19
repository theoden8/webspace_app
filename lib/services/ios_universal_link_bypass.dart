/// iOS Universal Link bypass.
///
/// `WKWebView` honors apple-app-site-association entries: when the
/// user taps a link (or follows a redirect chain rooted in a tap)
/// whose URL matches an installed app's AASA file, iOS routes the
/// navigation OUT of the webview into the native app — silently,
/// without a prompt, and even when the user explicitly added the
/// site to WebSpace and is using the webview on purpose.
///
/// Generic fix: on iOS, for every main-frame http(s) navigation
/// whose `WKNavigationAction.navigationType` is `.linkActivated`
/// (user tap), cancel the navigation and reissue it via
/// `controller.loadUrl`. WebKit treats programmatic loads as
/// navigation type `.other` and skips AASA matching, so the URL
/// renders inside the webview regardless of which apps are
/// installed. Pure programmatic navigations (initial nav, server
/// redirects without a tap origin, pushState) don't activate AASA
/// in the first place and are passed through without interception.
///
/// `.formSubmitted` is intentionally NOT bypassed. `loadUrl` is a
/// GET, so reissuing a form submit drops the POST body, which
/// breaks credentialed flows (login, search, payments). Form POSTs
/// to AASA-matching endpoints are exceedingly rare; apps publish
/// AASA for content URLs (profile pages, map locations), not POST
/// handlers.
///
/// No domain/path list. iOS exposes no public API to ask "does this
/// URL match an installed app's AASA?", so the bypass treats every
/// gesture-rooted main-frame nav as at-risk and reissues it.
///
/// Scope: iOS only. Android's WebView doesn't auto-launch installed
/// apps for plain http(s) URLs — `intent://` schemes are handled
/// separately via `ExternalUrlParser`.
class IosUniversalLinkBypass {
  IosUniversalLinkBypass();

  /// Webview-side gate: is this navigation eligible for the AASA
  /// bypass? Returns true only for main-frame http(s) navigations
  /// rooted in a user tap on a link. Form POSTs are intentionally
  /// excluded — see the class doc for why.
  ///
  /// Caller passes `isLinkActivated = navigationAction.navigationType
  /// == NavigationType.LINK_ACTIVATED` to keep this predicate free of
  /// flutter_inappwebview imports (and unit-testable from pure Dart).
  static bool isEligibleNavigation({
    required bool isMainFrame,
    required String url,
    required bool isLinkActivated,
  }) {
    return isMainFrame && url.startsWith('http') && isLinkActivated;
  }

  /// Per-WebView memo: URL → timestamp of the cancel-and-reissue.
  /// After we reissue programmatically the same URL fires
  /// `shouldOverrideUrlLoading` again; the memo flips that second
  /// pass to ALLOW so we don't bounce in a loop.
  final Map<String, DateTime> _recentBypass = {};

  /// Memo TTL. Long enough that the reissued navigation arrives and
  /// resolves; short enough that a future re-navigation to the same
  /// URL gets bypassed again.
  static const Duration _memoWindow = Duration(seconds: 2);

  /// Decide whether the caller should cancel-and-reissue this
  /// navigation. Returns:
  ///   * `true` on the first pass (caller cancels the navigation
  ///     and reissues via `loadUrl`),
  ///   * `false` on the second pass — the reissued nav landing in
  ///     `shouldOverrideUrlLoading` again — so the caller allows
  ///     it through.
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
