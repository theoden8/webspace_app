// Deterministic interleaving tests for DeferredStartupEngine.
//
// The post-paint deferred init runs while the UI is interactive, so the site
// list can mutate (add/delete/reorder) between the engine's awaits. These tests
// inject exactly those mutations at each await point via the fake host, and the
// host asserts the engine never acts on a dead site (preload /
// setSpoofTimezone / applyTheme on a deleted siteId is an INVARIANT failure).
//
// This is the test that would have caught the stale-index races the engine
// replaced: revert the engine to index-based and the "delete during await"
// cases below fail (wrong-site load / RangeError). What a preload does inside
// (its HTML, navigation state and session before the webview) is
// SiteActivationController.preload's, driven by the activation walks.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
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
  final SiteId siteId;
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
  int persists = 0;
  int datasetLoads = 0;
  bool datasetReady = true;
  String? Function(double latitude, {required double longitude}) lookupFn =
      (_, {required longitude}) => 'Etc/UTC';
  final List<String> markedLoaded = [];
  final List<String> tzSet = [];
  final List<String> themed = [];
  final List<({Set<String> active, Set<String> nonIncognito})> sweeps = [];
  final List<String> opLog = []; // 'persist' / 'sweep' — to assert ordering

  /// What each preload of a site answers, oldest first; loaded once spent.
  final Map<String, List<PreloadOutcome>> answers = {};
  int settles = 0;

  // Await-point hooks: run *inside* the awaited call, i.e. "during the await".
  void Function(String siteId)? onPreload;
  void Function(String siteId)? onApplyTheme;
  void Function()? onSettle;
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

  bool isLoaded(String siteId) => loaded.contains(siteId);

  @override
  Future<PreloadOutcome> preload(String siteId) async {
    expect(isLive(siteId), isTrue,
        reason: 'INVARIANT: preload of dead site $siteId');
    onPreload?.call(siteId);
    if (!isLive(siteId) || !mountedFlag) return PreloadOutcome.skipped;
    final queued = answers[siteId];
    final outcome = queued == null || queued.isEmpty
        ? PreloadOutcome.loaded
        : queued.removeAt(0);
    if (outcome == PreloadOutcome.loaded) {
      loaded.add(siteId);
      markedLoaded.add(siteId);
    }
    return outcome;
  }

  @override
  Future<void> activationSettled() async {
    settles++;
    onSettle?.call();
  }

  /// The launched site's first load; done unless a test holds it.
  Completer<void> launchLoad = Completer<void>()..complete();

  @override
  Future<void> launchedSiteLoaded() => launchLoad.future;

  @override
  Future<void> applyTheme(String siteId) async {
    expect(isLive(siteId), isTrue,
        reason: 'INVARIANT: applyTheme on dead site $siteId');
    themed.add(siteId);
    onApplyTheme?.call(siteId);
  }


  @override
  Future<bool> loadTimezoneDataset() async {
    datasetLoads++;
    onLoadDataset?.call();
    return datasetReady;
  }

  @override
  String? resolveTimezone(double latitude, {required double longitude}) =>
      lookupFn(latitude, longitude: longitude);

  @override
  bool setSpoofTimezone(String siteId, {required String timezone}) {
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
  Set<SiteId> liveSiteIds() => {for (final s in sites) s.siteId};

  @override
  Set<SiteId> liveNonIncognitoSiteIds() =>
      {for (final s in sites) if (!s.incognito) s.siteId};

  @override
  Future<void> sweepOrphanStorage(
      Set<SiteId> active, {required Set<SiteId> nonIncognitoSiteIds}) async {
    sweeps.add((active: active, nonIncognito: nonIncognitoSiteIds));
    opLog.add('sweep');
  }
}

void main() {
  group('autoLoadNotificationSites', () {
    test('loads every notification site; skips non-notif', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('plain')),
        _FakeSite(SiteId('b'), notif: true),
      ]);
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded.toSet(), {'a', 'b'});
      expect(host.isLoaded('plain'), isFalse);
    });

    test('nothing loads before the launched site has (NOTIF-017)', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
      ])..launchLoad = Completer<void>();
      final run = DeferredStartupEngine.autoLoadNotificationSites(host);
      await pumpEventQueue();
      expect(host.markedLoaded, isEmpty,
          reason: 'a preload started while the launched page still loads');
      host.launchLoad.complete();
      await run;
      expect(host.markedLoaded, ['a', 'b']);
    });

    test('a page that goes away while the launch loads ends the auto-load',
        () async {
      final host = _FakeHost([_FakeSite(SiteId('a'), notif: true)])
        ..launchLoad = Completer<void>();
      final run = DeferredStartupEngine.autoLoadNotificationSites(host);
      host.mountedFlag = false;
      host.launchLoad.complete();
      await run;
      expect(host.markedLoaded, isEmpty);
    });

    test('a busy preload is tried again once activations settle', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
      ]);
      host.answers['a'] = [PreloadOutcome.busy, PreloadOutcome.busy];
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded, ['a', 'b']);
      expect(host.settles, 2);
    });

    test('a skipped site is not tried again', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
      ]);
      host.answers['a'] = [PreloadOutcome.skipped];
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded, ['b']);
      expect(host.settles, 0);
    });

    test('a site deleted while its retry waits is not loaded', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
      ]);
      host.answers['a'] = [PreloadOutcome.busy];
      host.onSettle = () => host.delete('a');
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded, ['b']);
    });

    test('site deleted during its own preload is not loaded (no throw)',
        () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
      ]);
      // Delete 'a' while 'a' is mid-preload — the classic stale-index window.
      host.onPreload = (siteId) {
        if (siteId == 'a') host.delete('a');
      };
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.isLoaded('a'), isFalse, reason: 'deleted mid-flight');
      expect(host.isLoaded('b'), isTrue);
    });

    test('a different site deleted mid-loop is skipped, not mis-targeted',
        () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
        _FakeSite(SiteId('c'), notif: true),
      ]);
      // While loading 'a', delete the not-yet-processed 'c' (a reorder/delete
      // would shift indices; siteId-keying must just skip it).
      host.onPreload = (siteId) {
        if (siteId == 'a') host.delete('c');
      };
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      expect(host.markedLoaded.toSet(), {'a', 'b'});
      expect(host.isLive('c'), isFalse);
    });

    test('unmount mid-flight stops further loads', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('a'), notif: true),
        _FakeSite(SiteId('b'), notif: true),
      ]);
      host.onPreload = (siteId) {
        if (siteId == 'a') host.mountedFlag = false;
      };
      await DeferredStartupEngine.autoLoadNotificationSites(host);
      // 'a' was being preloaded when we unmounted; it does not load, and the
      // engine never reaches 'b'.
      expect(host.markedLoaded, isEmpty);
    });
  });

  group('refreshLocationTimezones', () {
    test('resolves + persists every from-location site', () async {
      final host = _FakeHost([
        _FakeSite(SiteId('geo'), fromLoc: true, lat: 51.5, lng: -0.1),
        _FakeSite(SiteId('plain')),
        _FakeSite(SiteId('tp'), tp: true, lat: 35.6, lng: 139.7),
      ]);
      host.lookupFn = (lat, {required longitude}) =>
          lat > 40 ? 'Europe/London' : 'Asia/Tokyo';
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.tzSet.toSet(), {'geo', 'tp'});
      expect(host.persists, 1);
    });

    test('does not load the dataset when no site uses the feature', () async {
      final host = _FakeHost([_FakeSite(SiteId('plain')), _FakeSite(SiteId('manualtz'))]);
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.datasetLoads, 0, reason: 'non-users never pay for the load');
      expect(host.persists, 0);
    });

    test('site deleted during dataset load is not written (no throw)',
        () async {
      final host = _FakeHost([
        _FakeSite(SiteId('keep'), fromLoc: true, lat: 10, lng: 10),
        _FakeSite(SiteId('gone'), fromLoc: true, lat: 20, lng: 20),
      ]);
      host.onLoadDataset = () => host.delete('gone');
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.tzSet, ['keep'], reason: 'deleted target must be skipped');
    });

    test('writes back by siteId even if the list reorders during load',
        () async {
      final host = _FakeHost([
        _FakeSite(SiteId('first'), fromLoc: true, lat: 51.5, lng: -0.1),
        _FakeSite(SiteId('second'), fromLoc: true, lat: 35.6, lng: 139.7),
      ]);
      host.lookupFn = (lat, {required longitude}) =>
          lat > 40 ? 'Europe/London' : 'Asia/Tokyo';
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
      final host = _FakeHost([_FakeSite(SiteId('geo'), fromLoc: true, lat: 1, lng: 2)]);
      host.datasetReady = false;
      await DeferredStartupEngine.refreshLocationTimezones(host);
      expect(host.tzSet, isEmpty);
      expect(host.persists, 0);
    });
  });

  group('themeRemaining', () {
    test('themes the live sites not themed before the first paint', () async {
      final host = _FakeHost(
          [_FakeSite(SiteId('a')), _FakeSite(SiteId('b')), _FakeSite(SiteId('c'), incognito: true)]);
      await DeferredStartupEngine.themeRemaining(host,
          alreadyThemedSiteIds: {SiteId('a')});
      expect(host.themed.toSet(), {'b', 'c'}, reason: 'a already themed');
    });

    test('site deleted during theming is skipped, not themed', () async {
      final host = _FakeHost([_FakeSite(SiteId('a')), _FakeSite(SiteId('b'))]);
      host.onApplyTheme = (siteId) {
        if (siteId == 'a') host.delete('b');
      };
      await DeferredStartupEngine.themeRemaining(host,
          alreadyThemedSiteIds: const {});
      expect(host.themed, ['a'], reason: 'b deleted before it was themed');
    });

    test('unmount mid-theming stops it', () async {
      final host = _FakeHost([_FakeSite(SiteId('a')), _FakeSite(SiteId('b'))]);
      host.onApplyTheme = (siteId) {
        if (siteId == 'a') host.mountedFlag = false;
      };
      await DeferredStartupEngine.themeRemaining(host,
          alreadyThemedSiteIds: const {});
      expect(host.themed, ['a']);
    });
  });

  group('persistAndSweep', () {
    test('persists, then sweeps against the live sets', () async {
      final host = _FakeHost(
          [_FakeSite(SiteId('a')), _FakeSite(SiteId('b')), _FakeSite(SiteId('c'), incognito: true)]);
      await DeferredStartupEngine.persistAndSweep(host, needsResave: true);
      expect(host.persists, 1);
      expect(host.sweeps.single.active, {'a', 'b', 'c'});
      expect(host.sweeps.single.nonIncognito, {'a', 'b'});
      // persist must run before the orphan sweep (same secure-storage keys).
      expect(host.opLog, ['persist', 'sweep']);
    });

    test('orphan sweep reads LIVE sets: a site added since launch is kept',
        () async {
      final host = _FakeHost([_FakeSite(SiteId('a'))]);
      host.sites.add(_FakeSite(SiteId('added')));
      await DeferredStartupEngine.persistAndSweep(host, needsResave: false);
      expect(host.sweeps.single.active, contains('added'));
      expect(host.persists, 0);
    });

    test('unmounted, it neither persists nor sweeps', () async {
      final host = _FakeHost([_FakeSite(SiteId('a'))])..mountedFlag = false;
      await DeferredStartupEngine.persistAndSweep(host, needsResave: true);
      expect(host.persists, 0);
      expect(host.sweeps, isEmpty);
    });
  });
}
