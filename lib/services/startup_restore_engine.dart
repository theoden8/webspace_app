import 'package:webspace/web_view_model.dart';

/// Pure helpers for `_WebSpacePageState._restoreAppState`. Only the
/// straight-line decisions live here; SharedPreferences I/O, native
/// cookie-jar nuking, and `_setCurrentIndex` chaining stay at the
/// caller because they cross rendering/persistence boundaries.
class StartupRestoreEngine {
  /// Resolves a launch-shortcut intent to a site index, or `null` if no
  /// shortcut intent was passed (or the intent's siteId no longer maps to
  /// a known site — e.g. the user deleted the site after pinning the
  /// shortcut). Returning `null` causes the app to launch on the home
  /// screen without activating any site.
  ///
  /// Matches by `WebViewModel.siteId`; the first hit wins (siteIds are
  /// generated to be unique, so collisions only occur if a backup was
  /// hand-edited).
  static int? resolveLaunchTarget({
    required String? shortcutSiteId,
    required List<WebViewModel> models,
  }) {
    if (shortcutSiteId == null) return null;
    final i = models.indexWhere((m) => m.siteId == shortcutSiteId);
    return i >= 0 ? i : null;
  }
}
