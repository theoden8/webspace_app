/// Pure decisions for app background/foreground (`AppLifecycleState`)
/// transitions: which active site to pause + capture on background, and which
/// to resume on foreground. Kept Flutter-free so it unit-tests without a
/// widget; the caller maps the result to controller calls and `setState`.
///
/// Deliberately offers NO URL-reset output. Per AOH-006 a transient background
/// preserves the in-progress page (issue #333): leaving the app to fetch an
/// emailed 2FA code and returning must not send a URL-ephemeral
/// (`alwaysOpenHome` / `incognito`) site back to its `initUrl`. The only
/// URL-reset triggers are a cold start (fromJson strips `currentUrl`, AOH-002)
/// and a home-shortcut tap (`WebspaceSelectionEngine
/// .indicesToResetOnShortcutLaunch`, AOH-004) — neither is a lifecycle event.
/// A flagged site is therefore handled here exactly like any other site.
class LifecycleBackgroundPlan {
  /// Active site whose JS timers should pause for the background, or null when
  /// there is no eligible active site (or it is a notification site, which
  /// must keep ticking to fire notifications).
  final int? jsPauseIndex;

  /// Active site whose restore-state bytes should be captured, or null. Capture
  /// is not gated on notifications — any loaded active site is captured.
  final int? captureStateIndex;

  /// Commit pending cookie writes to disk before the OS can kill the process.
  /// Chromium's cookie store commits lazily, so a session cookie set moments
  /// before backgrounding is otherwise lost on a swipe-kill and the user
  /// returns logged out (issues #524, #525).
  final bool flushCookies;

  const LifecycleBackgroundPlan({
    required this.jsPauseIndex,
    required this.captureStateIndex,
    required this.flushCookies,
  });
}

class AppLifecycleEngine {
  /// The active, in-bounds, loaded site index eligible for lifecycle
  /// pause/resume, or null. Mirrors the call-site guard
  /// `currentIndex != null && currentIndex < siteCount && loaded`.
  static int? activeLoadedIndex({
    required int? currentIndex,
    required int siteCount,
    required Set<int> loadedIndices,
  }) {
    if (currentIndex == null) return null;
    if (currentIndex < 0 || currentIndex >= siteCount) return null;
    if (!loadedIndices.contains(currentIndex)) return null;
    return currentIndex;
  }

  /// Plan for `AppLifecycleState.paused`. The active site's JS timers pause
  /// only when it is loaded and NOT a notification site; restore-state is
  /// captured for any loaded active site.
  ///
  /// [cookieFlushSupported] is the caller's platform answer for
  /// `CookieManager.flush` (Android only — everywhere else the platform
  /// interface's default throws). The flush is independent of the active
  /// site: any loaded webview may have written a cookie the platform has not
  /// committed to disk yet, notification sites very much included.
  static LifecycleBackgroundPlan backgroundPlan({
    required int? currentIndex,
    required int siteCount,
    required Set<int> loadedIndices,
    required bool Function(int index) notificationsEnabled,
    required bool cookieFlushSupported,
  }) {
    final flushCookies = cookieFlushSupported && loadedIndices.isNotEmpty;
    final active = activeLoadedIndex(
      currentIndex: currentIndex,
      siteCount: siteCount,
      loadedIndices: loadedIndices,
    );
    if (active == null) {
      return LifecycleBackgroundPlan(
        jsPauseIndex: null,
        captureStateIndex: null,
        flushCookies: flushCookies,
      );
    }
    return LifecycleBackgroundPlan(
      jsPauseIndex: notificationsEnabled(active) ? null : active,
      captureStateIndex: active,
      flushCookies: flushCookies,
    );
  }

  /// Active site whose JS timers should resume on `AppLifecycleState.resumed`:
  /// the loaded active site unless it is a notification site (never paused, so
  /// nothing to resume). The renderer probe runs against
  /// [activeLoadedIndex] regardless — notification sites included.
  static int? resumeJsIndex({
    required int? currentIndex,
    required int siteCount,
    required Set<int> loadedIndices,
    required bool Function(int index) notificationsEnabled,
  }) {
    final active = activeLoadedIndex(
      currentIndex: currentIndex,
      siteCount: siteCount,
      loadedIndices: loadedIndices,
    );
    if (active == null || notificationsEnabled(active)) return null;
    return active;
  }
}
