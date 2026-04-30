import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// Default cap on concurrently loaded webviews. Keeps memory bounded when
/// container mode lets sites stay resident across webspace switches; without
/// it, a heavy user could accumulate dozens of live native webviews.
///
/// Sized for "more than the user is likely actively juggling, on a device
/// with healthy headroom". Loaded webviews each consume native resources
/// (renderer process, decoded images, JS heap), but the OS's own memory
/// pressure signal is the real backstop — see
/// [SiteUnloadEngine.indexToEvictForMemoryPressure] — so this cap can
/// be generous. Per-event one-at-a-time eviction lets the OS clamp us
/// down to whatever the device can carry.
const int kMaxLoadedSites = 20;

/// Pure-Dart unload policy engine.
///
/// Owns the three orthogonal "should this site be unloaded?" rules:
///
///   1. Webspace switch — under legacy isolation only, sites visible only in
///      the previous webspace are unloaded so the shared cookie jar stays
///      clean. Under container isolation, sites stay resident across
///      switches.
///   2. Proxy mismatch — on Android, the WebView proxy is process-global
///      (`inapp.ProxyController` last-write-wins). Activating a site with a
///      different effective proxy would silently re-route any other loaded
///      site's next request through the new proxy, defeating the user's
///      per-site proxy choice. Force-unload conflicting sites so they can't
///      leak.
///   3. LRU cap — bound the number of concurrently loaded webviews so memory
///      stays under control. The least-recently-used loaded site is evicted
///      when the cap is exceeded. Caller treats [loadedIndices] as an
///      access-ordered `LinkedHashSet` (bump on activation).
///
/// No rendering, no `setState`, no I/O — every method is a pure function over
/// plain collections. Call sites in `_WebSpacePageState` translate the
/// returned indices into webview disposal + isolation cleanup.
class SiteUnloadEngine {
  /// Webspace-switch unload set. Returns the indices to dispose.
  ///
  /// In container mode, returns an empty set: each site has its own native
  /// container (cookies, localStorage, IDB, ServiceWorkers, HTTP cache), so
  /// keeping a site loaded outside the active webspace is harmless and
  /// avoids the cost of re-creating the webview when the user switches back.
  ///
  /// In legacy mode, falls through to the previous "anything visible only in
  /// the old webspace gets unloaded" rule — same as the pre-container
  /// behavior preserved by [WebspaceSelectionEngine].
  static Set<int> indicesToUnloadOnWebspaceSwitch({
    required bool useContainers,
    required Set<int> loadedIndices,
    required Set<int> previousWebspaceIndices,
    required Set<int> newWebspaceIndices,
  }) {
    if (useContainers) return const <int>{};
    return WebspaceSelectionEngine.indicesToUnloadOnWebspaceSwitch(
      loadedIndices: loadedIndices,
      previousWebspaceIndices: previousWebspaceIndices,
      newWebspaceIndices: newWebspaceIndices,
    );
  }

  /// Sites that must be unloaded because activating [targetIndex] would
  /// repoint a process-global proxy override out from under them.
  ///
  /// Only applies on platforms where the WebView proxy is process-global
  /// (Android). On platforms with true per-site proxies (iOS 17+ /
  /// macOS 14+), pass `proxyIsGlobal: false` and this returns an empty set.
  ///
  /// "Different effective proxy" is computed via
  /// [resolveEffectiveProxy] — a per-site `DEFAULT` resolves through the
  /// app-global outbound proxy, so two sites both set to `DEFAULT` are
  /// considered equivalent regardless of the global value (it's the same
  /// for both).
  static Set<int> indicesToUnloadForProxyMismatch({
    required int targetIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
    required bool proxyIsGlobal,
  }) {
    if (!proxyIsGlobal) return const <int>{};
    if (targetIndex < 0 || targetIndex >= models.length) return const <int>{};
    final targetEffective =
        resolveEffectiveProxy(models[targetIndex].proxySettings);
    final result = <int>{};
    for (final i in loadedIndices) {
      if (i == targetIndex) continue;
      if (i < 0 || i >= models.length) continue;
      final effective = resolveEffectiveProxy(models[i].proxySettings);
      if (!_proxyEquivalent(targetEffective, effective)) {
        result.add(i);
      }
    }
    return result;
  }

  /// LRU eviction set. Returns the indices to evict (oldest first) so that
  /// [loadedIndices] plus [targetIndex] fits within [maxLoadedSites].
  ///
  /// Treats [loadedIndices] as an access-ordered set: iteration order is
  /// least-recently-used first. The caller is responsible for bumping a
  /// site to the end of [loadedIndices] each time it becomes active (via
  /// remove-then-add on a `LinkedHashSet`).
  ///
  /// Eviction priority is two-tier:
  ///
  ///   1. **Hard protected.** Indices in [protectedIndices] (typically the
  ///      currently-active site, if not yet the target) are never evicted.
  ///      [targetIndex] itself is also never evicted.
  ///   2. **Soft kept.** Indices in [preferKeepIndices] (typically the
  ///      sites in the active webspace) are evicted only after every
  ///      out-of-set candidate is exhausted. This treats webspace
  ///      membership as "context relevance" — a site in the user's
  ///      current workspace that they haven't touched in five
  ///      activations is still more likely to be needed soon than a
  ///      stale site from a different workspace.
  ///
  /// Within each tier, oldest-accessed comes first. Returns an empty list
  /// when the cap would not be exceeded.
  static List<int> indicesToEvictForLruCap({
    required int targetIndex,
    required Set<int> loadedIndices,
    required int maxLoadedSites,
    Set<int> protectedIndices = const <int>{},
    Set<int> preferKeepIndices = const <int>{},
  }) {
    final projected = loadedIndices.contains(targetIndex)
        ? loadedIndices.length
        : loadedIndices.length + 1;
    if (projected <= maxLoadedSites) return const [];
    final overflow = projected - maxLoadedSites;

    // Tier 1: out-of-preferKeep candidates, in LRU order.
    final outOfKeep = <int>[];
    final inKeep = <int>[];
    for (final i in loadedIndices) {
      if (i == targetIndex) continue;
      if (protectedIndices.contains(i)) continue;
      if (preferKeepIndices.contains(i)) {
        inKeep.add(i);
      } else {
        outOfKeep.add(i);
      }
    }

    final evict = <int>[];
    for (final i in outOfKeep) {
      if (evict.length >= overflow) return evict;
      evict.add(i);
    }
    // Tier 2: only used if tier 1 didn't supply enough overflow.
    for (final i in inKeep) {
      if (evict.length >= overflow) return evict;
      evict.add(i);
    }
    return evict;
  }

  /// Picks one loaded site to unload in response to an OS memory pressure
  /// signal. Returns null when there's nothing safe to evict (everything
  /// loaded is in [protectedIndices], typically just the currently-active
  /// site).
  ///
  /// Same two-tier policy as [indicesToEvictForLruCap]: out-of-preferKeep
  /// candidates (oldest first), then in-preferKeep (oldest first). The
  /// caller invokes this on each `didHaveMemoryPressure()` event — if
  /// pressure persists, the OS fires the callback again and the next
  /// victim is picked. This lets the device clamp us down to whatever
  /// it can carry, instead of guessing a target up front.
  ///
  /// One-per-event matches the OS's signaling cadence. Trimming
  /// aggressively in a single shot would over-evict on transient
  /// pressure (e.g. another foregrounded app); trimming gradually lets
  /// the system stabilize.
  static int? indexToEvictForMemoryPressure({
    required Set<int> loadedIndices,
    Set<int> protectedIndices = const <int>{},
    Set<int> preferKeepIndices = const <int>{},
  }) {
    // Tier 1: out-of-preferKeep candidates, in LRU order.
    for (final i in loadedIndices) {
      if (protectedIndices.contains(i)) continue;
      if (preferKeepIndices.contains(i)) continue;
      return i;
    }
    // Tier 2: in-preferKeep candidates, in LRU order.
    for (final i in loadedIndices) {
      if (protectedIndices.contains(i)) continue;
      return i;
    }
    return null;
  }

  static bool _proxyEquivalent(UserProxySettings a, UserProxySettings b) {
    return a.type == b.type &&
        a.address == b.address &&
        a.username == b.username &&
        a.password == b.password;
  }
}
