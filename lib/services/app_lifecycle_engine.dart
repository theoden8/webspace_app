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
  /// there is no eligible active site, it is a notification site (which must
  /// keep ticking to fire notifications), or ANY loaded site has background
  /// audio enabled (BGAUDIO-002: the pause is process-global on Android, so a
  /// backgrounded audio site would be starved by pausing the active one).
  final int? jsPauseIndex;

  /// Active site whose restore-state bytes should be captured, or null. Capture
  /// is not gated on notifications or background audio — any loaded active
  /// site is captured.
  final int? captureStateIndex;

  /// Loaded sites whose page media must be paused before the app leaves the
  /// foreground (BGAUDIO-009), ascending. Every loaded site WITHOUT
  /// `effectiveBackgroundAudioEnabled` is listed: the JS pause freezes timers
  /// but never the media pipeline, so without this a site the user never
  /// opted in for keeps sounding through a backgrounded app and holds the
  /// system transport controls up.
  final List<int> mediaPauseIndices;

  /// Commit pending cookie writes to disk before the OS can kill the process.
  /// Chromium's cookie store commits lazily, so a session cookie set moments
  /// before backgrounding is otherwise lost on a swipe-kill and the user
  /// returns logged out (issues #524, #525).
  final bool flushCookies;

  const LifecycleBackgroundPlan({
    required this.jsPauseIndex,
    required this.captureStateIndex,
    required this.flushCookies,
    this.mediaPauseIndices = const [],
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

  /// True when any loaded, in-bounds site has background audio enabled.
  /// One flagged loaded site is enough to veto the app-lifecycle JS pause:
  /// on Android `pauseTimers()` is process-global, so pausing the active
  /// site would also freeze the flagged site's player wherever it sits in
  /// the stack. On iOS the pause is per-instance, so skipping it merely
  /// leaves the active site running too — an accepted battery cost for a
  /// single decision that behaves the same on both platforms (BGAUDIO-002).
  static bool anyLoadedBackgroundAudio({
    required int siteCount,
    required Set<int> loadedIndices,
    required bool Function(int index) backgroundAudioEnabled,
  }) {
    for (final i in loadedIndices) {
      if (i < 0 || i >= siteCount) continue;
      if (backgroundAudioEnabled(i)) return true;
    }
    return false;
  }

  /// Loaded, in-bounds sites without background audio, ascending
  /// (BGAUDIO-009). The exemption is per-site, unlike the JS-pause veto: one
  /// opted-in site keeps its own audio, it does not license every other
  /// loaded site to keep playing too.
  static List<int> mediaPauseIndices({
    required int siteCount,
    required Set<int> loadedIndices,
    required bool Function(int index) backgroundAudioEnabled,
  }) {
    final out = <int>[];
    for (final i in loadedIndices) {
      if (i < 0 || i >= siteCount) continue;
      if (backgroundAudioEnabled(i)) continue;
      out.add(i);
    }
    out.sort();
    return out;
  }

  /// Plan for `AppLifecycleState.paused`. The active site's JS timers pause
  /// only when it is loaded, NOT a notification site, and no loaded site has
  /// background audio enabled; restore-state is captured for any loaded
  /// active site. Every loaded site without background audio has its media
  /// paused (BGAUDIO-009), the active one included.
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
    required bool Function(int index) backgroundAudioEnabled,
    required bool cookieFlushSupported,
  }) {
    final flushCookies = cookieFlushSupported && loadedIndices.isNotEmpty;
    final mediaPause = mediaPauseIndices(
      siteCount: siteCount,
      loadedIndices: loadedIndices,
      backgroundAudioEnabled: backgroundAudioEnabled,
    );
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
        mediaPauseIndices: mediaPause,
      );
    }
    final skipJsPause = notificationsEnabled(active) ||
        anyLoadedBackgroundAudio(
          siteCount: siteCount,
          loadedIndices: loadedIndices,
          backgroundAudioEnabled: backgroundAudioEnabled,
        );
    return LifecycleBackgroundPlan(
      jsPauseIndex: skipJsPause ? null : active,
      captureStateIndex: active,
      flushCookies: flushCookies,
      mediaPauseIndices: mediaPause,
    );
  }

  /// Active site whose JS timers should resume on `AppLifecycleState.resumed`:
  /// the loaded active site unless the background plan would have skipped its
  /// pause (notification site, or a loaded background-audio site — never
  /// paused, so nothing to resume). The renderer probe runs against
  /// [activeLoadedIndex] regardless — exempted sites included.
  static int? resumeJsIndex({
    required int? currentIndex,
    required int siteCount,
    required Set<int> loadedIndices,
    required bool Function(int index) notificationsEnabled,
    required bool Function(int index) backgroundAudioEnabled,
  }) {
    final active = activeLoadedIndex(
      currentIndex: currentIndex,
      siteCount: siteCount,
      loadedIndices: loadedIndices,
    );
    if (active == null) return null;
    if (notificationsEnabled(active)) return null;
    if (anyLoadedBackgroundAudio(
      siteCount: siteCount,
      loadedIndices: loadedIndices,
      backgroundAudioEnabled: backgroundAudioEnabled,
    )) {
      return null;
    }
    return active;
  }
}
