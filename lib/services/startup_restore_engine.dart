import 'package:webspace/web_view_model.dart';

/// Outcome of resolving a tapped home shortcut against the current site list.
/// The engine only decides *what* should happen; the caller owns the dialogs,
/// `setCurrentIndex`, site creation, and remap persistence.
sealed class LaunchResolution {
  const LaunchResolution();
}

/// No shortcut intent, or nothing actionable (e.g. a legacy shortcut whose
/// siteId is gone and that carried no url to fall back on). Caller lands on
/// the home screen without activating a site.
class LaunchNone extends LaunchResolution {
  const LaunchNone();
}

/// The shortcut resolved directly to a known site (by siteId or a remembered
/// remap). Caller switches to [index] with no prompt.
class LaunchOpenSite extends LaunchResolution {
  final int index;
  const LaunchOpenSite(this.index);
}

/// The shortcut's siteId is gone, but a current site at [index] matches the
/// shortcut url's base domain. Caller prompts the user to open it; on confirm,
/// remembers `shortcutSiteId -> that site` so the next tap resolves directly.
class LaunchConfirmExisting extends LaunchResolution {
  final int index;
  final String shortcutSiteId;
  const LaunchConfirmExisting({
    required this.index,
    required this.shortcutSiteId,
  });
}

/// The shortcut's siteId is gone and no current site matches its domain.
/// Caller offers to create a new site for [url]; on confirm, creates it and
/// remembers `shortcutSiteId -> new site`.
class LaunchOfferCreate extends LaunchResolution {
  final String url;
  final String shortcutSiteId;
  const LaunchOfferCreate({
    required this.url,
    required this.shortcutSiteId,
  });
}

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
  ///
  /// Kept as the siteId-only view used where the richer [resolveLaunch]
  /// outcome (domain fallback, offer-to-create) isn't needed.
  static int? resolveLaunchTarget({
    required String? shortcutSiteId,
    required List<WebViewModel> models,
  }) {
    if (shortcutSiteId == null) return null;
    final i = models.indexWhere((m) => m.siteId == shortcutSiteId);
    return i >= 0 ? i : null;
  }

  /// Full shortcut resolution (HS-011). Tries, in order:
  ///
  /// 1. direct `siteId` match — [LaunchOpenSite];
  /// 2. a remembered remap (`shortcutSiteId -> siteId` from a prior
  ///    user choice) that still resolves — [LaunchOpenSite];
  /// 3. a current site whose base domain matches the shortcut url —
  ///    [LaunchConfirmExisting] (caller prompts before binding);
  /// 4. otherwise, with a usable url — [LaunchOfferCreate].
  ///
  /// Falls back to [LaunchNone] when there's no intent, or the siteId is
  /// gone and no url is available to match on (legacy shortcuts).
  static LaunchResolution resolveLaunch({
    required String? shortcutSiteId,
    required String? shortcutUrl,
    required List<WebViewModel> models,
    required Map<String, String> rememberedRemap,
  }) {
    if (shortcutSiteId == null) return const LaunchNone();

    final direct = models.indexWhere((m) => m.siteId == shortcutSiteId);
    if (direct >= 0) return LaunchOpenSite(direct);

    final remembered = rememberedRemap[shortcutSiteId];
    if (remembered != null) {
      final i = models.indexWhere((m) => m.siteId == remembered);
      if (i >= 0) return LaunchOpenSite(i);
    }

    final url = shortcutUrl?.trim() ?? '';
    if (url.isEmpty) return const LaunchNone();

    final base = getBaseDomain(url);
    if (base.isNotEmpty) {
      final i = models.indexWhere((m) => getBaseDomain(m.initUrl) == base);
      if (i >= 0) {
        return LaunchConfirmExisting(index: i, shortcutSiteId: shortcutSiteId);
      }
    }

    return LaunchOfferCreate(url: url, shortcutSiteId: shortcutSiteId);
  }
}

/// Android-only `siteId -> url` ledger backing HS-011 routing. A pinned
/// shortcut's launch intent carries only the random `siteId`; once the owning
/// site is deleted that id is opaque, so we keep a trail of the url it pointed
/// at to drive [StartupRestoreEngine.resolveLaunch]'s domain fallback.
///
/// iOS needs none of this: a Shortcuts.app tile binds to a `SiteEntity` whose
/// query resolves a deleted site to nil, so a stale id never reaches the app.
class ShortcutUrlLedger {
  /// Returns the ledger after recording urls for currently-pinned sites and
  /// dropping entries that are no longer reachable. An entry survives only if
  /// its site still exists ([currentSiteUrls]) or a pinned shortcut still
  /// references it ([pinnedSiteIds]) — the latter is the orphan trail we route
  /// on; the former lets a still-present pinned site's url be recorded so a
  /// later delete leaves something to match. Everything else is unreachable
  /// (the site is gone and no launcher tile points at it) and is pruned.
  ///
  /// Caller compares against the input and persists only when it changed.
  static Map<String, String> reconcile({
    required Map<String, String> ledger,
    required Map<String, String> currentSiteUrls,
    required Set<String> pinnedSiteIds,
  }) {
    final next = Map<String, String>.from(ledger);
    for (final id in pinnedSiteIds) {
      final url = currentSiteUrls[id];
      if (url != null && url.isNotEmpty) next[id] = url;
    }
    next.removeWhere((id, _) =>
        !currentSiteUrls.containsKey(id) && !pinnedSiteIds.contains(id));
    return next;
  }
}
