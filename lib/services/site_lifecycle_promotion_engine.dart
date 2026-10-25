import 'package:webspace/services/site_retention_priority.dart';

/// Tiered lifecycle for loaded webviews under memory pressure.
///
/// As OS memory pressure escalates, each `didHaveMemoryPressure` event
/// promotes one loaded site one tier deeper. The active and activating
/// sites are excluded; within a tier, the lowest [SiteRetentionPriority]
/// goes first and the LRU site within that.
///
/// Tier order (least → most aggressive):
///
///   1. **resident** — webview is in memory with full cache. May be
///      resumed (the active site) or paused (a backgrounded loaded
///      site after the pause-all-inactive sweep). The resumed/paused
///      distinction is orthogonal to memory tier — both share the
///      same renderer-process and decoded-image-cache footprint.
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
/// The engine is pure-Dart; the caller (typically `SiteActivationController.memoryPressure`
/// in `_WebSpacePageState`) is responsible for the actual platform
/// channel calls (`clearCache`, `saveState`, `disposeWebView`) and for
/// updating the per-site state map after each promotion.

/// Proactive `resident → cacheCleared` threshold. When more than this
/// number of loaded sites are at the [SiteLifecycleState.resident] tier,
/// activation eagerly promotes the oldest excess to `cacheCleared`
/// (running `controller.clearCache()`) without waiting for an OS
/// memory-pressure event. Backstop for platforms where memory
/// pressure isn't reliably signaled (Linux/desktop) or where Jetsam
/// is reactive after the fact (iOS). Sized for "comfortable working
/// set" — well below [kMaxLoadedSites] so eviction (resident →
/// cacheCleared → savedForRestore) has runway to operate before the
/// LRU cap kicks in.
const int kMaxResidentSites = 10;

enum SiteLifecycleState {
  /// Webview is in memory with full cache. Includes both the user-
  /// visible active site (controller resumed) and any backgrounded
  /// loaded site (controller paused). The distinction between
  /// resumed/paused is orthogonal to memory tier and tracked via the
  /// controller's pause/resume state, not here.
  resident,

  /// Webview is in memory but `clearCache()` has been called. The
  /// page is functional; cache refills on next interaction.
  cacheCleared,

  /// Webview is disposed; its navigation state is captured to
  /// [WebViewStateStorage] keyed by `siteId`. Re-activation rebuilds
  /// the webview and applies `restoreState`. This is the terminal tier
  /// — sites in this state are NOT in `_loadedIndices` (their
  /// controllers are null).
  savedForRestore,
}

class SiteLifecyclePromotionEngine {
  /// Returns the list of indices to proactively promote from
  /// [SiteLifecycleState.resident] to [SiteLifecycleState.cacheCleared]
  /// so that no more than [maxResidentSites] sites remain at the `live`
  /// tier. Selection uses the same priority hierarchy as the
  /// memory-pressure plan: lowest retention priority first,
  /// oldest-LRU-first within each bucket, active and activating sites
  /// excluded entirely.
  ///
  /// Caller invokes after each activation so the threshold is
  /// enforced eagerly — this is the proactive complement to the
  /// reactive memory-pressure cascade. Returns an empty list when
  /// the count is already at or below the threshold.
  ///
  /// Order matters: the returned list is in the order the caller
  /// should apply transitions (oldest-first within priority).
  /// Already-`cacheCleared` and `savedForRestore` sites are not
  /// counted toward the live total and not in the result.
  static List<int> pickProactiveCacheClearTargets({
    required Set<int> loadedIndices,
    required Map<int, SiteLifecycleState> states,
    required int maxResidentSites,
    required SiteRetentionResolver priorityOf,
  }) {
    final resident = loadedIndices
        .where((i) =>
            (states[i] ?? SiteLifecycleState.resident) ==
            SiteLifecycleState.resident)
        .toList();
    final excess = resident.length - maxResidentSites;
    if (excess <= 0) return const [];
    return evictionOrder(resident, priorityOf: priorityOf)
        .take(excess)
        .toList();
  }
}
