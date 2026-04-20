import 'package:webspace/webspace_model.dart';

/// Pure logic for webspace selection and filtering, extracted from
/// `_WebSpacePageState` so the "which sites are visible / which loaded sites
/// should be disposed on a webspace switch" rules can be exercised headlessly.
///
/// No rendering dependencies: every method takes plain collections in and
/// returns plain collections out. `ConnectivityService` stays at the caller —
/// offline-vs-online is a policy decision the engine doesn't make.
class WebspaceSelectionEngine {
  /// The indices displayed for `selectedWebspaceId`:
  ///
  ///   * `null`                        → empty list (home screen shows nothing)
  ///   * [kAllWebspaceId]              → every index `0..siteCount-1`
  ///   * any other webspace id         → that webspace's `siteIndices`,
  ///                                     filtered to in-bounds of `siteCount`
  ///                                     (order preserved)
  ///   * unknown id                    → empty list
  static List<int> filteredSiteIndices({
    required String? selectedWebspaceId,
    required List<Webspace> webspaces,
    required int siteCount,
  }) {
    if (selectedWebspaceId == null) return const [];
    if (selectedWebspaceId == kAllWebspaceId) {
      return List<int>.generate(siteCount, (i) => i);
    }
    for (final ws in webspaces) {
      if (ws.id != selectedWebspaceId) continue;
      return ws.siteIndices.where((i) => i >= 0 && i < siteCount).toList();
    }
    return const [];
  }

  /// The loaded indices that should be disposed when the user switches
  /// webspaces online: anything that was visible in the previous webspace
  /// but isn't visible in the new one.
  ///
  /// The caller is responsible for the offline short-circuit — when offline,
  /// all loaded webviews are preserved regardless of webspace membership so
  /// cached content stays viewable.
  static Set<int> indicesToUnloadOnWebspaceSwitch({
    required Set<int> loadedIndices,
    required Set<int> previousWebspaceIndices,
    required Set<int> newWebspaceIndices,
  }) {
    return loadedIndices
        .where((i) => previousWebspaceIndices.contains(i) && !newWebspaceIndices.contains(i))
        .toSet();
  }

  /// Strips out-of-bounds `siteIndices` from every webspace in place. Used
  /// after reorderings or imports where indices may have drifted. No-op for
  /// webspaces whose indices are already in-bounds.
  static void cleanupWebspaceIndices({
    required List<Webspace> webspaces,
    required int siteCount,
  }) {
    for (final ws in webspaces) {
      ws.siteIndices = ws.siteIndices
          .where((i) => i >= 0 && i < siteCount)
          .toList();
    }
  }
}
