/// Decides which URL should be treated as "stable" (i.e. safe to persist
/// as the site's current URL) and which URL to revert the address bar to
/// after a download is triggered.
///
/// Extracted from [`WebViewFactory.createWebView`] so the scheme-based
/// gating and revert-target selection are unit-testable without running a
/// real webview.
class DownloadUrlRevertEngine {
  /// Schemes that render as a normal page and therefore represent a
  /// reasonable state to roll back to after a download. Transient schemes
  /// (data:, blob:, javascript:, about:blank) are deliberately excluded:
  /// they typically arise from the download trigger itself, bookmarklets,
  /// or chrome pages, none of which we want to overwrite the stable URL.
  static bool isRenderable(String url) {
    try {
      final scheme = Uri.parse(url).scheme.toLowerCase();
      return scheme == 'http' ||
          scheme == 'https' ||
          scheme == 'file' ||
          scheme == 'about';
    } catch (_) {
      return false;
    }
  }

  /// Given the previously-known stable URL and a URL that just finished
  /// loading, returns the new stable URL. Non-renderable URLs never
  /// displace the previous value.
  static String? updateStable(String? previous, String loadedUrl) {
    return isRenderable(loadedUrl) ? loadedUrl : previous;
  }

  /// The URL to restore in the address bar and persisted state after a
  /// download was triggered. Prefers the most recent stable URL, falling
  /// back to the initial URL so downloads triggered on first load still
  /// have somewhere to revert to. Returns null if neither is set.
  static String? pickRevertTarget({
    String? lastStableUrl,
    String? initialUrl,
  }) {
    return lastStableUrl ?? initialUrl;
  }
}
