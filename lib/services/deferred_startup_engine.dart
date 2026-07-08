import 'package:webspace/services/timezone_spoof_policy.dart';

/// The per-site fields the deferred-startup orchestration reads. `siteId` is the
/// stable identity used across `await`s; list position is never used, which is
/// what makes the engine immune to the stale-index races that bit the old
/// inline widget closures (a site added/deleted mid-flight shifted captured
/// indices).
class DeferredSite {
  const DeferredSite({
    required this.siteId,
    required this.notificationsEnabled,
    required this.spoofTimezoneFromLocation,
    required this.trackingProtectionEnabled,
    required this.spoofLatitude,
    required this.spoofLongitude,
  });

  final String siteId;
  final bool notificationsEnabled;
  final bool spoofTimezoneFromLocation;
  final bool trackingProtectionEnabled;
  final double? spoofLatitude;
  final double? spoofLongitude;
}

/// Side-effect surface the engine drives — everything addressed by `siteId`, so
/// a model-list mutation between two `await`s can't make the engine act on a
/// stale position. The real implementation is `_WebSpacePageState`; tests use a
/// fake that can add/delete/reorder its sites between awaits and assert the
/// engine never touches a dead or wrong site.
abstract class DeferredStartupHost {
  /// Snapshot of the current sites (order irrelevant to the engine).
  List<DeferredSite> currentSites();

  /// Widget still alive — the engine bails after an await when false.
  bool get isMounted;

  /// Site still present — the engine skips it after an await when false.
  bool isLive(String siteId);

  bool isLoaded(String siteId);
  void markLoaded(String siteId);

  Future<void> preloadHtml(String siteId);
  Future<void> applyTheme(String siteId);

  /// Queue the site's saved nav-state bytes (if any) on its model so the
  /// first webview build applies `restoreState` — the cross-restart
  /// back/forward restore for sites loaded outside `_setCurrentIndex`
  /// (PAUSE-019). No-op when nothing is saved or a controller already
  /// exists.
  Future<void> queueNavStateRestore(String siteId);
  void requestRebuild();

  Future<bool> loadTimezoneDataset();
  String? resolveTimezone(double latitude, double longitude);

  /// Apply the resolved zone; returns true iff the stored value changed.
  bool setSpoofTimezone(String siteId, String timezone);
  Future<void> persist();

  /// Live site sets, read fresh (not a startup snapshot) — so a site added
  /// post-paint is treated as live, not swept as an orphan.
  Set<String> liveSiteIds();
  Set<String> liveNonIncognitoSiteIds();

  /// Remove on-disk storage for sites NOT in the given live sets (cookies,
  /// proxy passwords, HTML caches/imports, webview state, global cookie jar).
  Future<void> sweepOrphanStorage(
      Set<String> activeSiteIds, Set<String> nonIncognitoSiteIds);
}

/// Orchestration that runs *after* first paint (so the UI is interactive and
/// the site list can mutate underneath it). Pure: no Flutter, no `setState`, no
/// widget state — it only sequences calls into [DeferredStartupHost].
class DeferredStartupEngine {
  DeferredStartupEngine._();

  /// Auto-load notification sites off the first-frame path: preload each one's
  /// HTML, theme it, then mark it loaded. Re-checks `isMounted`/`isLive` after
  /// every await, so a site deleted during the (potentially multi-second) HTML
  /// decrypt is simply skipped — never indexed by a stale position, never
  /// loaded after deletion.
  static Future<void> autoLoadNotificationSites(DeferredStartupHost host) async {
    final notifIds = [
      for (final s in host.currentSites())
        if (s.notificationsEnabled) s.siteId,
    ];
    var added = false;
    for (final siteId in notifIds) {
      if (!host.isMounted) return;
      if (!host.isLive(siteId) || host.isLoaded(siteId)) continue;
      await host.preloadHtml(siteId);
      if (!host.isMounted) return;
      if (!host.isLive(siteId)) continue;
      await host.applyTheme(siteId);
      if (!host.isMounted) return;
      if (!host.isLive(siteId) || host.isLoaded(siteId)) continue;
      // Before markLoaded: once the site is in _loadedIndices,
      // _setCurrentIndex skips its restore fetch, so this is the only
      // point where the previous session's back/forward stack can be
      // queued for an auto-loaded site (PAUSE-019).
      await host.queueNavStateRestore(siteId);
      if (!host.isMounted) return;
      if (!host.isLive(siteId) || host.isLoaded(siteId)) continue;
      host.markLoaded(siteId);
      added = true;
    }
    if (added && host.isMounted) host.requestRebuild();
  }

  /// Re-resolve and persist `spoofTimezone` for sites that derive it from their
  /// spoofed coordinates, off the first-frame path. Snapshots `(siteId, coords)`
  /// before the multi-second dataset load and writes the result back by
  /// `siteId`, so a delete/reorder during the load can't bake a zone onto the
  /// wrong site.
  static Future<void> refreshLocationTimezones(DeferredStartupHost host) async {
    final targets = <({String siteId, double lat, double lng})>[];
    for (final s in host.currentSites()) {
      if (derivesTimezoneFromLocation(
        spoofTimezoneFromLocation: s.spoofTimezoneFromLocation,
        trackingProtectionEnabled: s.trackingProtectionEnabled,
        spoofLatitude: s.spoofLatitude,
        spoofLongitude: s.spoofLongitude,
      )) {
        targets.add(
            (siteId: s.siteId, lat: s.spoofLatitude!, lng: s.spoofLongitude!));
      }
    }
    if (targets.isEmpty) return;
    if (!await host.loadTimezoneDataset()) return;
    if (!host.isMounted) return;
    var changed = false;
    for (final t in targets) {
      final tz = host.resolveTimezone(t.lat, t.lng);
      if (tz == null) continue;
      if (host.isLive(t.siteId) && host.setSpoofTimezone(t.siteId, tz)) {
        changed = true;
      }
    }
    if (changed) await host.persist();
  }

  /// Post-paint maintenance off the first-frame path: theme the not-yet-built
  /// models, persist the load-time migration, then sweep orphan storage —
  /// sequenced (persist before sweep) so they don't race the same secure-
  /// storage keys. Theming is siteId-keyed and skips sites themed pre-paint;
  /// the sweep reads LIVE site sets so a site added post-paint isn't reclaimed.
  static Future<void> runPostPaintMaintenance(
    DeferredStartupHost host, {
    required Set<String> alreadyThemedSiteIds,
    required bool needsResave,
  }) async {
    final ids = [for (final s in host.currentSites()) s.siteId];
    for (final siteId in ids) {
      if (!host.isMounted) return;
      if (alreadyThemedSiteIds.contains(siteId) || !host.isLive(siteId)) {
        continue;
      }
      await host.applyTheme(siteId);
    }
    if (!host.isMounted) return;
    if (needsResave) await host.persist();
    if (!host.isMounted) return;
    await host.sweepOrphanStorage(
        host.liveSiteIds(), host.liveNonIncognitoSiteIds());
  }
}
