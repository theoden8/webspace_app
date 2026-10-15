import 'dart:typed_data';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/web_view_model.dart';

/// Outcome of resolving a tapped home shortcut against the current site list.
/// The engine only decides *what* should happen; the caller owns the dialogs,
/// the activation, site creation, and remap persistence.
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
/// remap). Caller switches to [site] with no prompt.
class LaunchOpenSite extends LaunchResolution {
  final WebViewModel site;
  const LaunchOpenSite(this.site);
}

/// The shortcut's siteId is gone, but a current [site] matches the
/// shortcut url's base domain. Caller prompts the user to open it; on confirm,
/// remembers `shortcutSiteId -> that site` so the next tap resolves directly.
class LaunchConfirmExisting extends LaunchResolution {
  final WebViewModel site;
  final SiteId shortcutSiteId;
  const LaunchConfirmExisting({
    required this.site,
    required this.shortcutSiteId,
  });
}

/// The shortcut's siteId is gone and no current site matches its domain.
/// Caller offers to create a new site for [url]; on confirm, creates it and
/// remembers `shortcutSiteId -> new site`.
class LaunchOfferCreate extends LaunchResolution {
  final String url;
  final SiteId shortcutSiteId;
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
  final SiteId shortcutSiteId;
  const LaunchOfferReroute({required this.shortcutSiteId});
}

/// Pure helpers for `StartupController.restore`. Only the
/// straight-line decisions live here; SharedPreferences I/O, native
/// cookie-jar nuking, and the activation chaining stay at the
/// caller because they cross rendering/persistence boundaries.
class StartupRestoreEngine {
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
    required SiteId? shortcutSiteId,
    required String? shortcutUrl,
    required List<WebViewModel> models,
    required Map<SiteId, SiteId> rememberedRemap,
  }) {
    if (shortcutSiteId == null) return const LaunchNone();

    WebViewModel? first(bool Function(WebViewModel) test) {
      for (final m in models) {
        if (test(m)) return m;
      }
      return null;
    }

    if (first((m) => m.siteId == shortcutSiteId) case final direct?) {
      return LaunchOpenSite(direct);
    }

    if (rememberedRemap[shortcutSiteId] case final remembered?) {
      if (first((m) => m.siteId == remembered) case final site?) {
        return LaunchOpenSite(site);
      }
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
      if (first((m) => getBaseDomain(m.initUrl) == base) case final site?) {
        return LaunchConfirmExisting(site: site, shortcutSiteId: shortcutSiteId);
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

  /// Whether the restore's closing activation should still run (NAV-012);
  /// [opensSite] when a shortcut or notification named the site to open.
  ///
  /// The home grid takes taps while the restore is still awaiting startup work
  /// (the proxy router's attribution pass alone can take seconds), so a site
  /// the user opened in that window would otherwise be closed again by a
  /// plain launch's `null` target. A shortcut target still applies: it is the
  /// site the app was launched to open.
  static bool shouldActivateAfterRestore({
    required bool opensSite,
    required bool activatedDuringRestore,
  }) {
    return opensSite || !activatedDuringRestore;
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
  static Map<SiteId, String> reconcile({
    required Map<SiteId, String> ledger,
    required Map<SiteId, String> currentSiteUrls,
    required Set<SiteId> pinnedSiteIds,
  }) {
    final next = Map<SiteId, String>.of(ledger);
    for (final id in pinnedSiteIds) {
      final url = currentSiteUrls[id];
      if (url != null && url.isNotEmpty) next[id] = url;
    }
    next.removeWhere((id, _) =>
        !currentSiteUrls.containsKey(id) && !pinnedSiteIds.contains(id));
    return next;
  }
}

/// Which site each pinned Android tile opens (HS-017): the site its launch
/// intent names, resolved by the rule [StartupRestoreEngine.resolveLaunch]
/// applies to a tap, so the menu (HS-005), the delete prompt (HS-013), the
/// tile faces (HS-016) and the settings list follow where a tap goes.
class ShortcutPinState {
  /// Each pinned tile and the site a tap on it opens, null where none does:
  /// the site it names is gone and no remembered rebind resolves it (HS-011).
  static Map<ShortcutId, WebViewModel?> sitesOpened({
    required Map<ShortcutId, SiteId> pinned,
    required Map<SiteId, SiteId> rememberedRemap,
    required List<WebViewModel> models,
  }) {
    WebViewModel? opened(SiteId named) {
      final opens = StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: named,
        shortcutUrl: null,
        models: models,
        rememberedRemap: rememberedRemap,
      );
      if (opens case LaunchOpenSite(:final site)) return site;
      return null;
    }

    return {
      for (final MapEntry(key: tile, value: named) in pinned.entries)
        tile: opened(named),
    };
  }

  /// The pinned tiles a tap on which opens [siteId]. Its menu offers no
  /// second tile while one does (HS-005), and deleting it asks about them
  /// (HS-013).
  static Set<ShortcutId> tilesReaching({
    required SiteId siteId,
    required Map<ShortcutId, SiteId> pinned,
    required Map<SiteId, SiteId> rememberedRemap,
    required List<WebViewModel> models,
  }) {
    final opened = sitesOpened(
      pinned: pinned,
      rememberedRemap: rememberedRemap,
      models: models,
    );
    return {
      for (final MapEntry(key: tile, value: site) in opened.entries)
        if (site?.siteId == siteId) tile,
    };
  }

  /// Each pinned tile that opens a site, and that site. An archive-tier site
  /// is left out: its name and icon never reach an OS surface (ARCH-006).
  static Map<ShortcutId, WebViewModel> sitesOfTiles({
    required Map<ShortcutId, SiteId> pinned,
    required Map<SiteId, SiteId> rememberedRemap,
    required List<WebViewModel> models,
  }) {
    final opened = sitesOpened(
      pinned: pinned,
      rememberedRemap: rememberedRemap,
      models: models,
    );
    return {
      for (final MapEntry(key: tile, value: site) in opened.entries)
        if (site != null && !site.isArchiveTier) tile: site,
    };
  }

  /// HS-016/HS-017: the tiles in [want] whose face differs from what
  /// [shown] says they were last given, and what every tile shows once those
  /// are rewritten. A wanted face with no icon leaves the tile's icon as it
  /// is, so an icon not known yet never replaces the one a tile has.
  static ({List<TileUpdate> updates, Map<ShortcutId, TileFace> shown})
      staleTiles({
    required Map<ShortcutId, TileFace> want,
    required Map<ShortcutId, TileFace> shown,
  }) {
    final updates = <TileUpdate>[];
    final next = Map<ShortcutId, TileFace>.of(shown);
    for (final MapEntry(key: tile, value: face) in want.entries) {
      final last = shown[tile];
      final icon = face.icon;
      final newIcon =
          icon != null && !_sameBytes(icon, other: last?.icon) ? icon : null;
      if (newIcon == null &&
          face.site == last?.site &&
          face.label == last?.label) {
        continue;
      }
      updates.add(
          (tile: tile, site: face.site, label: face.label, icon: newIcon));
      next[tile] = (site: face.site, label: face.label, icon: icon ?? last?.icon);
    }
    return (updates: updates, shown: next);
  }

  static bool _sameBytes(Uint8List a, {required Uint8List? other}) {
    if (other == null || a.length != other.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != other[i]) return false;
    }
    return true;
  }
}

/// What a pinned tile carries: the site a tap opens, its label and, once
/// known, its icon as PNG.
typedef TileFace = ({SiteId site, String label, Uint8List? icon});

/// A pinned tile to rewrite; a null [icon] leaves the tile's icon as it is.
typedef TileUpdate = ({
  ShortcutId tile,
  SiteId site,
  String label,
  Uint8List? icon,
});

/// A deleted site a Shortcuts tile may still be bound to (HS-011).
typedef ShortcutTombstone = ({SiteId siteId, String label, String url});

/// iOS-only tombstone list backing HS-011 parity. iOS can't enumerate
/// home-screen Shortcut tiles, so when a site is deleted we keep a small
/// `{siteId, label, url}` record. `SiteEntityQuery.entities(for:)` resolves
/// from live sites ∪ tombstones (so a tile bound to the deleted site still
/// launches and routes by domain), while `suggestedEntities()` stays
/// live-only (HS-009 — the picker doesn't show dead sites). Because a tile may
/// outlive any number of deletes and iOS gives no pin introspection to GC
/// against, the list is bounded by a cap (oldest evicted).
class ShortcutTombstones {
  /// Append [entry], de-duped by siteId and moved to the most-recent end,
  /// capping the list at [cap] (oldest dropped). Returns the new list; the
  /// caller persists it.
  static List<ShortcutTombstone> add({
    required List<ShortcutTombstone> tombstones,
    required ShortcutTombstone entry,
    int cap = 64,
  }) {
    final next = [
      for (final t in tombstones)
        if (t.siteId != entry.siteId) t,
      entry,
    ];
    if (next.length > cap) return next.sublist(next.length - cap);
    return next;
  }

  /// Drop tombstones whose siteId is now a live site (defensive: ids are
  /// unique per create, so this only fires if a backup reintroduces one).
  static List<ShortcutTombstone> pruneLive(
    List<ShortcutTombstone> tombstones, {
    required Set<SiteId> liveSiteIds,
  }) {
    return [
      for (final t in tombstones)
        if (!liveSiteIds.contains(t.siteId)) t,
    ];
  }
}
