// Deterministic interleaving tests for DeferredStartupEngine.
//
// The post-paint deferred init runs while the UI is interactive, so the site
// list can mutate (add/delete/reorder) between the engine's awaits. These tests
// inject exactly those mutations at each await point via the fake host, and the
// host asserts the engine never acts on a dead site (markLoaded /
// setSpoofTimezone / preloadHtml on a deleted siteId is an INVARIANT failure).
//
// This is the test that would have caught the stale-index races the engine
// replaced: revert the engine to index-based and the "delete during await"
// cases below fail (wrong-site markLoaded / RangeError).
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/deferred_startup_engine.dart';

class _FakeSite {
  _FakeSite(this.siteId,
      {this.notif = false,
      this.fromLoc = false,
      this.tp = false,
      this.incognito = false,
      this.lat,
      this.lng,
      this.tz});
  final String siteId;
  bool notif;
  bool fromLoc;
  bool tp;
  bool incognito;
  double? lat;
  double? lng;
  String? tz;
}

class _FakeHost implements DeferredStartupHost {
  _FakeHost(this.sites);
  final List<_FakeSite> sites;

  final Set<String> loaded = {};
  bool mountedFlag = true;
  int rebuilds = 0;
  int persists = 0;
  int datasetLoads = 0;
  bool datasetReady = true;
  String? Function(double, double) lookupFn = (_, __) => 'Etc/UTC';
  final List<String> markedLoaded = [];
  final List<String> tzSet = [];
  final List<String> themed = [];
  final List<({Set<String> active, Set<String> nonIncognito})> sweeps = [];
  final List<String> opLog = []; // 'persist' / 'sweep' — to assert ordering

  // Await-point hooks: run *inside* the awaited call, i.e. "during the await".
  void Function(String siteId)? onPreloadHtml;
  void Function(String siteId)? onApplyTheme;
  void Function()? onLoadDataset;

  _FakeSite? _find(String id) {
    for (final s in sites) {
      if (s.siteId == id) return s;
    }
    return null;
  }

  void delete(String id) => sites.removeWhere((s) => s.siteId == id);

  @override
  List<DeferredSite> currentSites() => [
        for (final s in sites)
          DeferredSite(
            siteId: s.siteId,
            notificationsEnabled: s.notif,
            spoofTimezoneFromLocation: s.fromLoc,
            trackingProtectionEnabled: s.tp,
            spoofLatitude: s.lat,
            spoofLongitude: s.lng,
          ),
      ];

  @override
  bool get isMounted => mountedFlag;

  @override
  bool isLive(String siteId) => _find(siteId) != null;

  @override
  bool isLoaded(String siteId) => loaded.contains(siteId);

  @override
  void markLoaded(String siteId) {
    expect(isLive(siteId), isTrue,
        reason: 'INVARIANT: markLoaded on dead site $siteId');
    loaded.add(siteId);
    markedLoaded.add(siteId);
  }

  @override
  Future<void> preloadHtml(String siteId) async {
    expect(isLive(siteId), isTrue,
        reason: 'INVARIANT: preloadHtml on dead site $siteId');
    onPreloadHtml?.call(siteId);
  }

  @override
  Future<void> applyTheme(String siteId) async {
    expect(isLive(siteId), isTrue,
        reason: 'INVARIANT: applyTheme on dead site $siteId');
    themed.add(siteId);
    onApplyTheme?.call(siteId);
  }

  @override
  void requestRebuild() => rebuilds++;

  @override
  Future<bool> loadTimezoneDataset() async {
    datasetLoads++;
    onLoadDataset?.call();
    return datasetReady;
  }

  @override
  String? resolveTimezone(double latitude, double longitude) =>
      lookupFn(latitude, longitude);

  @override
  bool setSpoofTimezone(String siteId, String timezone) {
    expect(isLive(siteId), isTrue,
        reason: 'INVARIANT: setSpoofTimezone on dead site $siteId');
    final s = _find(siteId)!;
    tzSet.add(siteId);
    if (s.tz != timezone) {
      s.tz = timezone;
      return true;
    }
    return false;
  }

  @override
  Future<void> persist() async {
    persists++;
    opLog.add('persist');
  }

  @override
  Set<String> liveSiteIds() => {for (final s in sites) s.siteId};

  @override
  Set<String> liveNonIncognitoSiteIds() =>
      {for (final s in sites) if (!s.incognito) s.siteId};

  @override
  Future<void> sweepOrphanStorage(
      Set<String> active, Set<String> nonIncognito) async {
    sweeps.add((active: active, nonIncognito: nonIncognito));
    opLog.add('sweep');
  }
}

void main() {
  group('autoLoadNotificationSites', () {
    test('loads every notification site; skips non-notif', () async {
      final host = _FakeHost([
        _FakeSite('a', notif: true),
        _FakeSite('plain'),
        _FakeSite('b', notif: true),
      ]);
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded.toSet(), {'a', 'b'});
      expect(host.isLoaded('plain'), isFalse);
      expect(host.rebuilds, 1);
    });

    test('site deleted during its own HTML preload is not loaded (no throw)',
        () async {
      final host = _FakeHost([
        _FakeSite('a', notif: true),
        _FakeSite('b', notif: true),
      ]);
      // Delete 'a' while 'a' is mid-preload — the classic stale-index window.
      host.onPreloadHtml = (siteId) {
        if (siteId == 'a') host.delete('a');
      };
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.isLoaded('a'), isFalse, reason: 'deleted mid-flight');
      expect(host.isLoaded('b'), isTrue);
    });

    test('a different site deleted mid-loop is skipped, not mis-targeted',
        () async {
      final host = _FakeHost([
        _FakeSite('a', notif: true),
        _FakeSite('b', notif: true),
        _FakeSite('c', notif: true),
      ]);
      // While loading 'a', delete the not-yet-processed 'c' (a reorder/delete
      // would shift indices; siteId-keying must just skip it).
      host.onPreloadHtml = (siteId) {
        if (siteId == 'a') host.delete('c');
      };
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded.toSet(), {'a', 'b'});
      expect(host.isLive('c'), isFalse);
    });

    test('unmount mid-flight stops further loads', () async {
      final host = _FakeHost([
        _FakeSite('a', notif: true),
        _FakeSite('b', notif: true),
      ]);
      host.onPreloadHtml = (siteId) {
        if (siteId == 'a') host.mountedFlag = false;
      };
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      // 'a' was being preloaded when we unmounted; engine bails before marking
      // it, and never reaches 'b'.
      expect(host.markedLoaded, isEmpty);
      expect(host.rebuilds, 0);
    });
  });

  group('refreshLocationTimezones', () {
    test('resolves + persists every from-location site', () async {
      final host = _FakeHost([
        _FakeSite('geo', fromLoc: true, lat: 51.5, lng: -0.1),
        _FakeSite('plain'),
        _FakeSite('tp', tp: true, lat: 35.6, lng: 139.7),
      ]);
      host.lookupFn = (lat, lng) => lat > 40 ? 'Europe/London' : 'Asia/Tokyo';
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.tzSet.toSet(), {'geo', 'tp'});
      expect(host.persists, 1);
    });

    test('does not load the dataset when no site uses the feature', () async {
      final host = _FakeHost([_FakeSite('plain'), _FakeSite('manualtz')]);
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.datasetLoads, 0, reason: 'non-users never pay for the load');
      expect(host.persists, 0);
    });

    test('site deleted during dataset load is not written (no throw)',
        () async {
      final host = _FakeHost([
        _FakeSite('keep', fromLoc: true, lat: 10, lng: 10),
        _FakeSite('gone', fromLoc: true, lat: 20, lng: 20),
      ]);
      host.onLoadDataset = () => host.delete('gone');
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.tzSet, ['keep'], reason: 'deleted target must be skipped');
    });

    test('writes back by siteId even if the list reorders during load',
        () async {
      final host = _FakeHost([
        _FakeSite('first', fromLoc: true, lat: 51.5, lng: -0.1),
        _FakeSite('second', fromLoc: true, lat: 35.6, lng: 139.7),
      ]);
      host.lookupFn = (lat, lng) => lat > 40 ? 'Europe/London' : 'Asia/Tokyo';
      // Reverse the list mid-load; an index-based write-back would swap the
      // two sites' zones.
      host.onLoadDataset = () => host.sites.setAll(0, host.sites.reversed.toList());
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.sites.firstWhere((s) => s.siteId == 'first').tz,
          'Europe/London');
      expect(host.sites.firstWhere((s) => s.siteId == 'second').tz,
          'Asia/Tokyo');
    });

    test('no persist when the dataset is unavailable', () async {
      final host = _FakeHost([_FakeSite('geo', fromLoc: true, lat: 1, lng: 2)]);
      host.datasetReady = false;
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.tzSet, isEmpty);
      expect(host.persists, 0);
    });
  });

  group('runPostPaintMaintenance', () {
    test('themes the not-pre-themed live sites, persists, then sweeps',
        () async {
      final host = _FakeHost(
          [_FakeSite('a'), _FakeSite('b'), _FakeSite('c', incognito: true)]);
      await DeferredStartupEngine.runPostPaintMaintenance(
        host,
        alreadyThemedSiteIds: {'a'}, // a was themed pre-paint
        needsResave: true,
      );
      expect(host.themed.toSet(), {'b', 'c'}, reason: 'a already themed');
      expect(host.persists, 1);
      expect(host.sweeps.length, 1);
      expect(host.sweeps.single.active, {'a', 'b', 'c'});
      expect(host.sweeps.single.nonIncognito, {'a', 'b'});
      // persist must run before the orphan sweep (same secure-storage keys).
      expect(host.opLog, ['persist', 'sweep']);
    });

    test('orphan sweep reads LIVE sets — a site added post-paint is kept',
        () async {
      final host = _FakeHost([_FakeSite('a'), _FakeSite('b')]);
      // Simulate the user adding a site while theming is in flight.
      host.onApplyTheme = (siteId) {
        if (siteId == 'a' && host.isLive('added') == false) {
          host.sites.add(_FakeSite('added'));
        }
      };
      await DeferredStartupEngine.runPostPaintMaintenance(
        host,
        alreadyThemedSiteIds: const {},
        needsResave: false,
      );
      expect(host.sweeps.single.active, contains('added'),
          reason: 'fresh snapshot must include the post-paint site, '
              'so it is not swept as an orphan');
      expect(host.persists, 0); // needsResave: false
    });

    test('site deleted during theming is skipped, not themed', () async {
      final host = _FakeHost([_FakeSite('a'), _FakeSite('b')]);
      host.onApplyTheme = (siteId) {
        if (siteId == 'a') host.delete('b');
      };
      await DeferredStartupEngine.runPostPaintMaintenance(
        host,
        alreadyThemedSiteIds: const {},
        needsResave: false,
      );
      expect(host.themed, ['a'], reason: 'b deleted before it was themed');
    });

    test('unmount mid-theming stops before persist/sweep', () async {
      final host = _FakeHost([_FakeSite('a'), _FakeSite('b')]);
      host.onApplyTheme = (siteId) {
        if (siteId == 'a') host.mountedFlag = false;
      };
      await DeferredStartupEngine.runPostPaintMaintenance(
        host,
        alreadyThemedSiteIds: const {},
        needsResave: true,
      );
      expect(host.persists, 0);
      expect(host.sweeps, isEmpty);
    });
  });
}
