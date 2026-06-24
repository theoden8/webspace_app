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

/// The shortcut's siteId is gone and no url is known to match or create on —
/// e.g. a handle bound to a site deleted before tombstones existed, which iOS
/// resolves to a placeholder entity so the tile stays tappable instead of
/// reading "no longer available". Caller offers to reroute the handle to an
/// existing site; on confirm, remembers `shortcutSiteId -> chosen site`.
class LaunchOfferReroute extends LaunchResolution {
  final String shortcutSiteId;
  const LaunchOfferReroute({required this.shortcutSiteId});
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
  /// 4. with a usable url but no domain match — [LaunchOfferCreate];
  /// 5. siteId gone and no url, but sites exist — [LaunchOfferReroute].
  ///
  /// Falls back to [LaunchNone] when there's no intent, or the siteId is
  /// gone with no url and no sites to reroute to.
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
    if (url.isEmpty) {
      // No url to match a domain or seed a create — but the handle still
      // resolved (placeholder), so offer to reroute it to an existing site if
      // there is one; otherwise land on the home screen.
      return models.isEmpty
          ? const LaunchNone()
          : LaunchOfferReroute(shortcutSiteId: shortcutSiteId);
    }

    final base = getBaseDomain(url);
    if (base.isNotEmpty) {
      final i = models.indexWhere((m) => getBaseDomain(m.initUrl) == base);
      if (i >= 0) {
        return LaunchConfirmExisting(index: i, shortcutSiteId: shortcutSiteId);
      }
    }

    return LaunchOfferCreate(url: url, shortcutSiteId: shortcutSiteId);
  }

  /// FS-008: whether activating a site should land in fullscreen.
  ///
  /// Combines the global "full screen on shortcut launch" option
  /// ([fullscreenOnShortcut]) with the site's own per-site
  /// [WebViewModel.fullscreenMode]. A shortcut launch ([viaShortcut] true)
  /// forces fullscreen when the global option is on; every launch still
  /// honors the per-site flag. A normal in-app switch ([viaShortcut] false)
  /// depends on the per-site flag alone, so the global option never changes
  /// the behavior of tab-strip / drawer navigation.
  static bool shouldEnterFullscreen({
    required bool viaShortcut,
    required bool fullscreenOnShortcut,
    required bool perSiteFullscreenMode,
  }) {
    return perSiteFullscreenMode || (viaShortcut && fullscreenOnShortcut);
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

/// Helpers for "is this site already reachable by a home shortcut?", used to
/// gate the "Home Shortcut" menu item (HS-005).
class ShortcutPinState {
  /// The set of siteIds that already have a reachable shortcut: the pinned
  /// tiles themselves, plus any site a pinned tile has been rebound to via the
  /// HS-011 remap. Without folding in remap targets, a site an orphaned tile
  /// now routes to would still offer to create a second, redundant tile.
  static Set<String> effectivePinnedSiteIds({
    required Set<String> pinnedSiteIds,
    required Map<String, String> rememberedRemap,
  }) {
    final result = Set<String>.from(pinnedSiteIds);
    for (final pinned in pinnedSiteIds) {
      final target = rememberedRemap[pinned];
      if (target != null) result.add(target);
    }
    return result;
  }

  /// The pinned tile ids that currently reach [siteId] — either directly (the
  /// tile's id IS the siteId) or through an HS-011 rebind (`remap[tile] ==
  /// siteId`). Used by the delete-time prompt (HS-013) so deleting a site an
  /// orphaned tile was rebound to still prompts about that tile, not just the
  /// site that was originally pinned.
  static Set<String> tilesReaching({
    required String siteId,
    required Set<String> pinnedSiteIds,
    required Map<String, String> rememberedRemap,
  }) {
    return {
      for (final tile in pinnedSiteIds)
        if (tile == siteId || rememberedRemap[tile] == siteId) tile,
    };
  }
}

/// iOS-only tombstone list backing HS-011 parity. iOS can't enumerate
/// home-screen Shortcut tiles, so when a site is deleted we keep a small
/// `{siteId, label, url}` record. `SiteEntityQuery.entities(for:)` resolves
/// from live sites ∪ tombstones (so a tile bound to the deleted site still
/// launches and routes by domain), while `suggestedEntities()` stays
/// live-only (HS-009 — the picker doesn't show dead sites). Because a tile may
/// outlive any number of deletes and iOS gives no pin introspection to GC
/// against, the list is bounded by a cap (oldest evicted).
class ShortcutTombstones {
  /// Append [entry] (`{siteId, label, url}`), de-duped by siteId and moved to
  /// the most-recent end, capping the list at [cap] (oldest dropped). Returns
  /// the new list; the caller persists it.
  static List<Map<String, String>> add({
    required List<Map<String, String>> tombstones,
    required Map<String, String> entry,
    int cap = 64,
  }) {
    final id = entry['siteId'];
    if (id == null || id.isEmpty) return tombstones;
    final next = <Map<String, String>>[
      for (final t in tombstones)
        if (t['siteId'] != id) t,
      entry,
    ];
    if (next.length > cap) return next.sublist(next.length - cap);
    return next;
  }

  /// Drop tombstones whose siteId is now a live site (defensive: ids are
  /// unique per create, so this only fires if a backup reintroduces one).
  static List<Map<String, String>> pruneLive(
    List<Map<String, String>> tombstones,
    Set<String> liveSiteIds,
  ) {
    return [
      for (final t in tombstones)
        if (!liveSiteIds.contains(t['siteId'])) t,
    ];
  }
}
