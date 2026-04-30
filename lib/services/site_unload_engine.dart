import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';

/// Default cap on concurrently loaded webviews. Keeps memory bounded when
/// container mode lets sites stay resident across webspace switches; without
/// it, a heavy user could accumulate dozens of live native webviews.
const int kMaxLoadedSites = 20;

SiteRetentionResolver _legacyResolver({
  Set<int> protectedIndices = const <int>{},
  Set<int> preferKeepIndices = const <int>{},
}) {
  return (int index) {
    if (protectedIndices.contains(index)) return SiteRetentionPriority.active;
    if (preferKeepIndices.contains(index)) return SiteRetentionPriority.webspace;
    return SiteRetentionPriority.loaded;
  };
}

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
///      stays under control. Uses [SiteRetentionPriority] to decide eviction
///      order: lowest priority (highest enum index) first, LRU within each
///      tier.
class SiteUnloadEngine {
  /// Webspace-switch unload set. Returns the indices to dispose.
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
  /// Pass [priorityOf] to use named retention priorities. Falls back to
  /// the legacy [protectedIndices]/[preferKeepIndices] sets if [priorityOf]
  /// is null.
  static List<int> indicesToEvictForLruCap({
    required int targetIndex,
    required Set<int> loadedIndices,
    required int maxLoadedSites,
    SiteRetentionResolver? priorityOf,
    Set<int> protectedIndices = const <int>{},
    Set<int> preferKeepIndices = const <int>{},
  }) {
    final resolver = priorityOf ??
        _legacyResolver(
          protectedIndices: protectedIndices,
          preferKeepIndices: preferKeepIndices,
        );

    final projected = loadedIndices.contains(targetIndex)
        ? loadedIndices.length
        : loadedIndices.length + 1;
    if (projected <= maxLoadedSites) return const [];
    final overflow = projected - maxLoadedSites;

    final candidates = <int>[];
    for (final i in loadedIndices) {
      if (i == targetIndex) continue;
      final p = resolver(i);
      if (p == SiteRetentionPriority.active ||
          p == SiteRetentionPriority.activating) continue;
      candidates.add(i);
    }

    // Sort by priority: lowest priority (highest index) first.
    candidates.sort((a, b) {
      final pa = resolver(a).index;
      final pb = resolver(b).index;
      if (pa != pb) return pb.compareTo(pa);
      return 0;
    });

    return candidates.length <= overflow
        ? candidates
        : candidates.sublist(0, overflow);
  }

  /// Picks one loaded site to evict in response to an OS memory pressure
  /// signal. Returns null when nothing can be safely evicted.
  static int? indexToEvictForMemoryPressure({
    required Set<int> loadedIndices,
    SiteRetentionResolver? priorityOf,
    Set<int> protectedIndices = const <int>{},
    Set<int> preferKeepIndices = const <int>{},
  }) {
    final resolver = priorityOf ??
        _legacyResolver(
          protectedIndices: protectedIndices,
          preferKeepIndices: preferKeepIndices,
        );

    int? bestCandidate;
    int bestPriorityIndex = -1;
    for (final i in loadedIndices) {
      final p = resolver(i);
      if (p == SiteRetentionPriority.active ||
          p == SiteRetentionPriority.activating) continue;
      if (bestCandidate == null || p.index > bestPriorityIndex) {
        bestCandidate = i;
        bestPriorityIndex = p.index;
      }
    }
    return bestCandidate;
  }

  static bool _proxyEquivalent(UserProxySettings a, UserProxySettings b) {
    return a.type == b.type &&
        a.address == b.address &&
        a.username == b.username &&
        a.password == b.password;
  }
}
