import 'package:webspace/web_view_model.dart';

/// Pure decisions made during site activation, extracted from
/// `_WebSpacePageState._setCurrentIndex` so production and the cookie-isolation
/// test harness share one implementation instead of duplicating the
/// "find a same-base-domain loaded site to unload" loop.
///
/// The async sequencing of activation (pause previous, restore cookies,
/// resume new, refresh canGoBack) stays at the call site — that path
/// awaits native webview controller calls and threads a version guard,
/// neither of which the engine should own without an interface fake.
class SiteActivationEngine {
  /// Returns the index of a loaded site that conflicts with [targetIndex]'s
  /// cookie isolation, or `null` if none.
  ///
  /// A conflict is: another loaded site with the same second-level domain
  /// (`getBaseDomain(initUrl)`). Incognito sites — both target and loaded —
  /// are skipped because they don't share the persistent cookie jar that
  /// drives the isolation rule.
  ///
  /// Out-of-bounds indices in [loadedIndices] are tolerated. The first
  /// matching index in iteration order is returned, mirroring the existing
  /// `_setCurrentIndex` `break`-after-first-conflict semantics (only one
  /// conflict is possible at a time given prior activations enforce the
  /// same rule).
  static int? findDomainConflict({
    required int targetIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) {
    if (targetIndex < 0 || targetIndex >= models.length) return null;
    final target = models[targetIndex];
    if (target.incognito) return null;

    final targetDomain = getBaseDomain(target.initUrl);
    for (final loadedIndex in loadedIndices) {
      if (loadedIndex == targetIndex) continue;
      if (loadedIndex < 0 || loadedIndex >= models.length) continue;
      final loaded = models[loadedIndex];
      if (loaded.incognito) continue;
      if (getBaseDomain(loaded.initUrl) == targetDomain) {
        return loadedIndex;
      }
    }
    return null;
  }

  /// The index whose webview must be quiesced when [targetIndex] becomes
  /// active, or `null` if none is.
  ///
  /// A tap on the site already showing is not a switch. That site is resumed
  /// moments later, so quiescing it would stop its media, end a camera
  /// capture it is running, and — on iOS, where the per-instance pause is the
  /// plugin's `alert()` hack — strand that alert for the resume to expose as
  /// an empty system dialog (PAUSE-030).
  static int? outgoingSiteToQuiesce({
    required int? currentIndex,
    required int targetIndex,
    required int siteCount,
    required Set<int> loadedIndices,
  }) {
    if (currentIndex == null || currentIndex == targetIndex) return null;
    if (currentIndex < 0 || currentIndex >= siteCount) return null;
    if (!loadedIndices.contains(currentIndex)) return null;
    return currentIndex;
  }
}
