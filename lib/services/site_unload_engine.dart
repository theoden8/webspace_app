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

  /// Sites that must be unloaded because activating [targetIndex] would
  /// repoint the process-global Tor `ExitNodes` out from under them.
  ///
  /// Same shape as [indicesToUnloadForProxyMismatch] and for the same
  /// reason: `ExitNodes`/`StrictNodes` are global client options in
  /// `tor(1)` — unlike the isolation flags they cannot be scoped to a
  /// `SocksPort`, so one tor cannot serve two countries at once, and iOS
  /// forbids a second process to run a second tor in. Two loaded sites
  /// pinned to different countries would therefore share whichever pin was
  /// written last, which is precisely the silent mis-routing the
  /// fail-closed posture exists to prevent (TOR-014).
  ///
  /// Any difference conflicts, *including* unpinned against pinned. An
  /// unpinned Tor site is not indifferent: leaving it loaded beside a `{de}`
  /// site would route it through Germany too, because there is only one
  /// `ExitNodes` — a country the user never chose for it, silently, on
  /// account of an unrelated site. "No pin" therefore reads as "must be
  /// unrestricted" and is a constraint like any other.
  ///
  /// Sites that do not route through Tor at all are untouched: `ExitNodes`
  /// says nothing about where their traffic goes.
  static Set<int> indicesToUnloadForTorExitMismatch({
    required int targetIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) {
    if (targetIndex < 0 || targetIndex >= models.length) return const <int>{};
    final target = _torExitPin(models[targetIndex]);
    if (target == null) return const <int>{};
    final result = <int>{};
    for (final i in loadedIndices) {
      if (i == targetIndex) continue;
      if (i < 0 || i >= models.length) continue;
      final other = _torExitPin(models[i]);
      if (other == null) continue;
      if (target != other) result.add(i);
    }
    return result;
  }

  /// The `ExitNodes` value that should be in force while [indices] are the
  /// loaded sites, or null when nothing among them wants a pinned exit.
  ///
  /// Well-defined only because [indicesToUnloadForTorExitMismatch] has
  /// already evicted every site that disagrees: the loaded Tor sites share
  /// one constraint by construction, so the first one found answers for all
  /// of them. Pass the site being activated first, since it is the one
  /// whose constraint the eviction was computed against.
  ///
  /// Derived from the loaded set rather than from a single site so that
  /// clearing a pin in settings, or unloading the site that held it, drops
  /// the pin instead of leaving it applied to whatever loads next.
  static String? torExitNodesFor({
    required Iterable<int> indices,
    required List<WebViewModel> models,
  }) {
    for (final i in indices) {
      if (i < 0 || i >= models.length) continue;
      final pin = _torExitPin(models[i]);
      if (pin == null) continue;
      return pin == _torUnpinned ? null : pin;
    }
    return null;
  }

  /// Stands in for a Tor site that pins no country. Distinct from null,
  /// which means the site does not use Tor and so is indifferent to
  /// `ExitNodes` entirely. Not a legal `ExitNodes` value, so it cannot
  /// collide with a real pin.
  static const String _torUnpinned = '<unpinned>';

  /// The site's effective exit-country constraint, or null when it has
  /// none because it does not route through Tor.
  ///
  /// Read off the *effective* settings, so a site on DEFAULT inherits the
  /// global proxy's country, and a country left over on a site since
  /// switched to SOCKS5 constrains nothing.
  static String? _torExitPin(WebViewModel model) {
    final effective = resolveEffectiveProxy(model.proxySettings);
    if (effective.type != ProxyType.TOR) return null;
    return effective.exitNodesValue ?? _torUnpinned;
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
