/// Pure navigation decisions extracted from `_WebSpacePageState`:
///   * URL comparison that ignores trailing-slash normalization.
///   * Synchronous fast-path for iOS `canGoBack` — webviews commonly return
///     `true` from `InAppWebViewController.canGoBack()` for SPA/pushState
///     navigation even when the user is visually on the home page, so we
///     short-circuit to `false` when URL-equality says we're home. This is
///     what enables the drawer edge-swipe on iOS.
///
/// Scope deliberately excludes the async `controller.canGoBack()` call and
/// the caller's version guard — those stay at the widget so the engine can
/// be exercised with primitives and needs no webview-controller fake.
class NavigationEngine {
  /// True if `currentUrl` and `initUrl` compare equal ignoring a single
  /// trailing slash on either side. Webviews normalize `https://example.com`
  /// to `https://example.com/` (and vice versa), so a plain `==` misses it.
  static bool isHomeUrl(String currentUrl, String initUrl) {
    final a = _stripTrailingSlash(currentUrl);
    final b = _stripTrailingSlash(initUrl);
    return a == b;
  }

  /// Synchronous fast-path answer for "can the active site go back?" on iOS.
  /// Returns:
  ///   * `false` — definitive, no async call needed (no site, out of bounds,
  ///     currently on the home URL, or no controller attached yet).
  ///   * `null`  — sync path declined; the caller must `await
  ///     controller.canGoBack()` and apply its own version guard + setState.
  ///
  /// Caller owns the iOS platform gate and version-counter state.
  static bool? trySyncCanGoBack({
    required int? currentIndex,
    required int siteCount,
    required String? currentUrl,
    required String? initUrl,
    required bool hasController,
  }) {
    if (currentIndex == null || currentIndex < 0 || currentIndex >= siteCount) {
      return false;
    }
    if (currentUrl != null && initUrl != null && isHomeUrl(currentUrl, initUrl)) {
      return false;
    }
    if (!hasController) return false;
    return null;
  }

  static String _stripTrailingSlash(String s) =>
      s.endsWith('/') ? s.substring(0, s.length - 1) : s;
}
