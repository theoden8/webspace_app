import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/settings/site_ids.dart';

/// How a background load of a site ended.
enum PreloadOutcome {
  loaded,

  /// Gone, already loaded, or its base domain held by a loaded site on the
  /// shared jar (ISO-001): nothing to retry.
  skipped,

  /// An activation was in flight, or an input superseded the load: worth
  /// another try once activations settle.
  busy,
}

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

  final SiteId siteId;
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
  bool isLive(SiteId siteId);

  /// Builds the site's webview off screen, its cached HTML, saved
  /// navigation state (PAUSE-035) and session or container in place first
  /// (`SiteActivationController.preload`).
  Future<PreloadOutcome> preload(SiteId siteId);

  /// Completes once no activation is in flight.
  Future<void> activationSettled();

  /// Completes once the site the launch opened has finished its first load,
  /// or [kLaunchLoadWait] after it was asked, whichever comes first; at once
  /// when the launch opened none.
  Future<void> launchedSiteLoaded();

  Future<void> applyTheme(SiteId siteId);

  Future<bool> loadTimezoneDataset();
  String? resolveTimezone(double latitude, {required double longitude});

  /// Apply the resolved zone; returns true iff the stored value changed.
  bool setSpoofTimezone(SiteId siteId, {required String timezone});
  Future<void> persist();

  /// Live site sets, read fresh (not a startup snapshot) — so a site added
  /// post-paint is treated as live, not swept as an orphan.
  Set<SiteId> liveSiteIds();
  Set<SiteId> liveNonIncognitoSiteIds();

  /// Remove on-disk storage for sites NOT in the given live sets (cookies,
  /// proxy passwords, HTML caches/imports, webview state, global cookie jar).
  Future<void> sweepOrphanStorage(
      Set<SiteId> activeSiteIds, {required Set<SiteId> nonIncognitoSiteIds});
}

/// How long the notification auto-load waits for the launched site's first
/// load: a page that never settles must not keep every notification site
/// from loading.
const Duration kLaunchLoadWait = Duration(seconds: 10);

/// Orchestration that runs *after* first paint (so the UI is interactive and
/// the site list can mutate underneath it). Pure: no Flutter, no `setState`, no
/// widget state — it only sequences calls into [DeferredStartupHost].
class DeferredStartupEngine {
  DeferredStartupEngine._();

  /// Auto-load notification sites off the first-frame path, one at a time,
  /// each preloaded once [themeRemaining] has themed it. A preload an
  /// activation is in the way of, or that an input superseded, is tried
  /// again once activations settle; a site deleted meanwhile is skipped,
  /// never addressed by a stale position.
  static Future<void> autoLoadNotificationSites(DeferredStartupHost host) async {
    // The launched page loads first: its requests and its renderer are what
    // the user is waiting on, and every preload competes with both.
    await host.launchedSiteLoaded();
    if (!host.isMounted) return;
    final notifIds = [
      for (final s in host.currentSites())
        if (s.notificationsEnabled) s.siteId,
    ];
    for (final siteId in notifIds) {
      while (host.isMounted && host.isLive(siteId)) {
        if (await host.preload(siteId) != PreloadOutcome.busy) break;
        await host.activationSettled();
      }
    }
  }

  /// Re-resolve and persist `spoofTimezone` for sites that derive it from their
  /// spoofed coordinates, off the first-frame path. Snapshots `(siteId, coords)`
  /// before the multi-second dataset load and writes the result back by
  /// `siteId`, so a delete/reorder during the load can't bake a zone onto the
  /// wrong site.
  static Future<void> refreshLocationTimezones(DeferredStartupHost host) async {
    final targets = <({SiteId siteId, double lat, double lng})>[];
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
      final tz = host.resolveTimezone(t.lat, longitude: t.lng);
      if (tz == null) continue;
      if (host.isLive(t.siteId) &&
          host.setSpoofTimezone(t.siteId, timezone: tz)) {
        changed = true;
      }
    }
    if (changed) await host.persist();
  }

  /// Themes the models not themed before the first paint, by siteId, so a
  /// site deleted meanwhile is skipped. Their controllers are not built yet;
  /// a build's first document picks its prelude from the theme, so it runs
  /// before the notification sites preload.
  static Future<void> themeRemaining(
    DeferredStartupHost host, {
    required Set<SiteId> alreadyThemedSiteIds,
  }) async {
    final ids = [for (final s in host.currentSites()) s.siteId];
    for (final siteId in ids) {
      if (!host.isMounted) return;
      if (alreadyThemedSiteIds.contains(siteId) || !host.isLive(siteId)) {
        continue;
      }
      await host.applyTheme(siteId);
    }
  }

  /// Writes the load-time migration back, then sweeps orphan storage against
  /// the LIVE site sets, so a site added since launch is not reclaimed.
  /// Persist first: both touch the same secure-storage keys.
  static Future<void> persistAndSweep(
    DeferredStartupHost host, {
    required bool needsResave,
  }) async {
    if (!host.isMounted) return;
    if (needsResave) await host.persist();
    if (!host.isMounted) return;
    await host.sweepOrphanStorage(host.liveSiteIds(),
        nonIncognitoSiteIds: host.liveNonIncognitoSiteIds());
  }
}
