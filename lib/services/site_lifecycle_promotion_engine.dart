/// Tiered lifecycle for loaded webviews under memory pressure.
///
/// As OS memory pressure escalates, each `didHaveMemoryPressure` event
/// promotes one loaded site one tier deeper. The active site is
/// excluded (via `protectedIndices`); within a tier, the LRU site is
/// picked, with out-of-active-webspace candidates evicted before
/// in-webspace candidates (`preferKeepIndices`).
///
/// Tier order (least → most aggressive):
///
///   1. **live** — webview in memory, may be resumed (active) or paused
///      (inactive). Default state for any loaded site.
///   2. **cacheCleared** — webview still in memory, but `clearCache()`
///      has been called. Frees decoded image cache + in-memory disk
///      cache (~10-50 MB per webview) without losing tab state. The
///      page transparently re-caches on the next interaction.
///   3. **savedForRestore** — `saveState()` captured the navigation
///      state to [WebViewStateStorage]; webview is disposed. Frees the
///      whole renderer process (~100s MB). On re-activation, a new
///      webview is built and `restoreState()` re-hydrates the
///      back/forward stack and (on iOS 15+ / macOS 12+) form data.
///      Live JS heap is gone.
///
/// Future work: a `suspended` tier slots between `cacheCleared` and
/// `savedForRestore` once we wire native suspend (WKWebView's `suspend`
/// SPI on Apple, Chromium tab discarding on Android — neither is
/// exposed by the current plugin).
///
/// The engine is pure-Dart; the caller (typically `_handleMemoryPressure`
/// in `_WebSpacePageState`) is responsible for the actual platform
/// channel calls (`clearCache`, `saveState`, `disposeWebView`) and for
/// updating the per-site state map after each promotion.
enum SiteLifecycleState {
  /// Webview is loaded in memory. Includes both the user-visible active
  /// site (resumed) and any backgrounded loaded site (paused). The
  /// distinction between resumed/paused is orthogonal to memory tier
  /// and tracked via the controller's pause/resume state, not here.
  live,

  /// Webview is loaded in memory and has had its in-memory cache
  /// cleared. The page is functional; cache will refill on next
  /// interaction.
  cacheCleared,

  /// Webview is disposed; its navigation state is captured to
  /// [WebViewStateStorage] keyed by `siteId`. Re-activation rebuilds
  /// the webview and applies `restoreState`. This is the terminal tier
  /// — sites in this state are NOT in `_loadedIndices` (their
  /// controllers are null).
  savedForRestore,
}

/// Counts of loaded sites broken down by lifecycle tier. Used by
/// debug surfaces and tests to assert the cascade is progressing.
class SiteTierCounts {
  /// Sites at the active position (typically 0 or 1).
  final int active;

  /// Sites at [SiteLifecycleState.live] minus the active one.
  final int live;

  /// Sites at [SiteLifecycleState.cacheCleared].
  final int cacheCleared;

  /// Sites at [SiteLifecycleState.savedForRestore]. Includes sites
  /// that have been disposed (not in `loadedIndices`); the count is
  /// taken from the state map.
  final int savedForRestore;

  const SiteTierCounts({
    required this.active,
    required this.live,
    required this.cacheCleared,
    required this.savedForRestore,
  });

  @override
  String toString() => 'SiteTierCounts(active=$active, live=$live, '
      'cacheCleared=$cacheCleared, savedForRestore=$savedForRestore)';
}

class SiteLifecyclePromotionEngine {
  /// State machine for memory-pressure escalation. Returns the next
  /// more-aggressive tier, or null when [current] is terminal.
  static SiteLifecycleState? nextState(SiteLifecycleState current) {
    switch (current) {
      case SiteLifecycleState.live:
        return SiteLifecycleState.cacheCleared;
      case SiteLifecycleState.cacheCleared:
        return SiteLifecycleState.savedForRestore;
      case SiteLifecycleState.savedForRestore:
        return null;
    }
  }

  /// Picks the next loaded site to promote one tier under memory
  /// pressure, or null when nothing is safely promotable (everything
  /// in [loadedIndices] is in [protectedIndices], or the loaded set is
  /// empty).
  ///
  /// Selection rules, applied in order:
  ///
  ///   1. **Tier dominates LRU.** Walks tiers from least-aggressive
  ///      ([SiteLifecycleState.live]) to most-aggressive non-terminal
  ///      ([SiteLifecycleState.cacheCleared]). All `live` sites are
  ///      promoted to `cacheCleared` before any `cacheCleared` site is
  ///      promoted to `savedForRestore`. This gives the OS gradual
  ///      relief — clearing cache on every loaded site (~10-50 MB
  ///      each) often satisfies pressure without disposing anything.
  ///   2. **Within a tier, out-of-keep before in-keep.** A site
  ///      outside `preferKeepIndices` (typically the active webspace)
  ///      gets promoted before a site inside, so the user's current
  ///      workspace stays at the freshest tier.
  ///   3. **Within a (tier, keep) bucket, oldest LRU first.** Caller
  ///      treats [loadedIndices] as access-ordered (newest at end);
  ///      iteration picks the oldest first.
  ///   4. **Always exclude `protectedIndices`** (the active site, plus
  ///      the in-flight activation target). [SiteLifecycleState.savedForRestore]
  ///      sites are also skipped defensively (they shouldn't be in
  ///      `loadedIndices` anyway, since the webview is disposed).
  static int? pickPromotionTarget({
    required Set<int> loadedIndices,
    required Map<int, SiteLifecycleState> states,
    Set<int> protectedIndices = const <int>{},
    Set<int> preferKeepIndices = const <int>{},
  }) {
    // Walk tiers from least to most aggressive (excluding terminal).
    for (final tier in [
      SiteLifecycleState.live,
      SiteLifecycleState.cacheCleared,
    ]) {
      // Within a tier, partition into out-of-keep then in-keep so
      // out-of-keep is exhausted first. Both lists preserve LRU order
      // (iteration order of loadedIndices).
      int? outOfKeepCandidate;
      int? inKeepCandidate;
      for (final i in loadedIndices) {
        if (protectedIndices.contains(i)) continue;
        final s = states[i] ?? SiteLifecycleState.live;
        if (s != tier) continue;
        if (preferKeepIndices.contains(i)) {
          inKeepCandidate ??= i;
        } else {
          outOfKeepCandidate ??= i;
          // Out-of-keep is the highest priority within this tier;
          // can't beat the oldest one we already found.
          break;
        }
      }
      if (outOfKeepCandidate != null) return outOfKeepCandidate;
      if (inKeepCandidate != null) return inKeepCandidate;
    }
    return null;
  }

  /// Tier-count snapshot. The `active` count is whichever loaded
  /// index matches `activeIndex` (0 or 1); other live loaded sites
  /// land in `live`. `savedForRestore` is read from the state map
  /// directly (those sites aren't in `loadedIndices`).
  static SiteTierCounts tierCounts({
    required Set<int> loadedIndices,
    required Map<int, SiteLifecycleState> states,
    required int? activeIndex,
  }) {
    var active = 0;
    var live = 0;
    var cacheCleared = 0;
    var savedForRestore = 0;
    for (final i in loadedIndices) {
      final s = states[i] ?? SiteLifecycleState.live;
      if (i == activeIndex && s == SiteLifecycleState.live) {
        active++;
        continue;
      }
      switch (s) {
        case SiteLifecycleState.live:
          live++;
        case SiteLifecycleState.cacheCleared:
          cacheCleared++;
        case SiteLifecycleState.savedForRestore:
          // Defensive: shouldn't appear in loadedIndices.
          savedForRestore++;
      }
    }
    // Count savedForRestore from the state map (those sites are
    // disposed, so not in loadedIndices).
    for (final entry in states.entries) {
      if (loadedIndices.contains(entry.key)) continue;
      if (entry.value == SiteLifecycleState.savedForRestore) {
        savedForRestore++;
      }
    }
    return SiteTierCounts(
      active: active,
      live: live,
      cacheCleared: cacheCleared,
      savedForRestore: savedForRestore,
    );
  }
}
