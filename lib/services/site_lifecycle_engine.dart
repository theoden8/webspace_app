import 'package:webspace/webspace_model.dart';

/// Pure state transform describing how `_loadedIndices`, webspace site lists,
/// and the current-index pointer must be updated after a site is removed from
/// `_webViewModels`. The caller applies the patch; the engine computes it.
///
/// All indices are treated as positions in `_webViewModels`. `newSiteIndices`
/// is keyed by webspace id rather than list position so the caller can tolerate
/// concurrent reorderings of the webspace list between patch-compute and
/// patch-apply.
class SiteDeletionPatch {
  /// Loaded indices after removal: deleted index dropped, any index strictly
  /// greater shifted down by one, anything out-of-bounds filtered out.
  final Set<int> newLoadedIndices;

  /// Per-webspace updated `siteIndices` keyed by `Webspace.id`. Entries absent
  /// from this map were unaffected.
  final Map<String, List<int>> newSiteIndicesByWebspaceId;

  /// Updated value for `_currentIndex`. Semantics mirror `_deleteSite`:
  ///   * deletedIndex == currentIndex       → null (cleared; caller must
  ///                                          call `_setCurrentIndex(null)`)
  ///   * deletedIndex <  currentIndex       → currentIndex - 1
  ///   * deletedIndex >  currentIndex, null → unchanged
  final int? newCurrentIndex;

  /// True iff the deleted site was the active one. Signals the caller that
  /// `_setCurrentIndex(null)` must run (which pauses the now-missing webview
  /// and clears fullscreen/canGoBack state) before the list is saved.
  final bool wasCurrentIndex;

  const SiteDeletionPatch({
    required this.newLoadedIndices,
    required this.newSiteIndicesByWebspaceId,
    required this.newCurrentIndex,
    required this.wasCurrentIndex,
  });
}

class SiteLifecycleEngine {
  /// Computes the index-rewrite that must happen after `_webViewModels.removeAt(deletedIndex)`:
  ///
  ///   * `loadedIndices`: drop `deletedIndex`, shift `i > deletedIndex` to `i - 1`,
  ///     filter anything that would be out-of-bounds in the post-removal list.
  ///   * Each webspace's `siteIndices`: drop any entry equal to `deletedIndex`,
  ///     shift `i > deletedIndex` to `i - 1`. Out-of-bounds entries are filtered
  ///     as a defensive measure (the pre-existing `_cleanupWebspaceIndices`
  ///     semantics).
  ///   * `currentIndex`: cleared if equal to `deletedIndex`, shifted down by
  ///     one if strictly greater, unchanged otherwise.
  ///
  /// Inputs describe PRE-removal state; `siteCount` is the list length BEFORE
  /// `removeAt`. The patch is idempotent w.r.t. `loadedIndices` — if the
  /// caller already removed `deletedIndex` before calling, the result is the
  /// same.
  static SiteDeletionPatch computeDeletionPatch({
    required int deletedIndex,
    required int siteCountBeforeRemoval,
    required Set<int> loadedIndices,
    required List<Webspace> webspaces,
    required int? currentIndex,
  }) {
    final postRemovalCount = siteCountBeforeRemoval - 1;

    final newLoadedIndices = <int>{};
    for (final i in loadedIndices) {
      if (i == deletedIndex) continue;
      final shifted = i > deletedIndex ? i - 1 : i;
      if (shifted < 0 || shifted >= postRemovalCount) continue;
      newLoadedIndices.add(shifted);
    }

    final newSiteIndicesByWebspaceId = <String, List<int>>{};
    for (final webspace in webspaces) {
      final rewritten = <int>[];
      var changed = false;
      for (final i in webspace.siteIndices) {
        if (i == deletedIndex) {
          changed = true;
          continue;
        }
        final shifted = i > deletedIndex ? i - 1 : i;
        if (shifted < 0 || shifted >= postRemovalCount) {
          changed = true;
          continue;
        }
        if (shifted != i) changed = true;
        rewritten.add(shifted);
      }
      if (changed) {
        newSiteIndicesByWebspaceId[webspace.id] = rewritten;
      }
    }

    final wasCurrentIndex = currentIndex == deletedIndex;
    int? newCurrentIndex;
    if (currentIndex == null || wasCurrentIndex) {
      newCurrentIndex = null;
    } else if (currentIndex > deletedIndex) {
      newCurrentIndex = currentIndex - 1;
    } else {
      newCurrentIndex = currentIndex;
    }

    return SiteDeletionPatch(
      newLoadedIndices: newLoadedIndices,
      newSiteIndicesByWebspaceId: newSiteIndicesByWebspaceId,
      newCurrentIndex: newCurrentIndex,
      wasCurrentIndex: wasCurrentIndex,
    );
  }
}
