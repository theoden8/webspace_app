import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';

/// In-memory model of the native container API: a set of containers
/// each keyed by `containerKey` (either a bare siteId for rev 0 or
/// `<siteId>_r<rev>` for later wipes), with `bindContainerToWebView`
/// simulated as a binding registry. Mirrors the [MockCookieManager]
/// pattern in [test/cookie_isolation_integration_test.dart] — the
/// engine is unaware it is talking to a fake.
class MockContainerNative implements ContainerNative {
  bool supported;

  /// `containerKey` -> native name (`ws-<containerKey>`).
  final Map<String, String> profiles = {};

  /// Last bind count returned per key — emulates how many webviews
  /// were found and bound on the most recent bind call.
  final Map<String, int> webviewsForKey = {};

  /// Records every method call so tests can assert sequencing.
  final List<String> calls = [];

  MockContainerNative({this.supported = true});

  @override
  bool get cachedSupported => supported;

  @override
  Future<bool> isSupported() async {
    calls.add('isSupported');
    return supported;
  }

  @override
  Future<String> getOrCreateContainer(String containerKey) async {
    calls.add('getOrCreateContainer($containerKey)');
    final name = 'ws-$containerKey';
    profiles[containerKey] = name;
    return name;
  }

  @override
  Future<int> bindContainerToWebView(String containerKey) async {
    calls.add('bindContainerToWebView($containerKey)');
    if (!profiles.containsKey(containerKey)) {
      throw StateError(
        'bind called before getOrCreateContainer($containerKey) — '
        'production engine must always create-then-bind',
      );
    }
    return webviewsForKey[containerKey] ?? 1;
  }

  @override
  Future<void> deleteContainer(String containerKey) async {
    calls.add('deleteContainer($containerKey)');
    profiles.remove(containerKey);
    webviewsForKey.remove(containerKey);
  }

  @override
  Future<List<String>> listContainers() async {
    calls.add('listContainers');
    return profiles.keys.toList();
  }
}

void main() {
  group('containerKeyFor / parseContainerKey', () {
    test('rev 0 is the bare siteId (back-compat with pre-rev containers)', () {
      expect(containerKeyFor('abc', 0), 'abc');
      final parsed = parseContainerKey('abc');
      expect(parsed.siteId, 'abc');
      expect(parsed.rev, 0);
    });

    test('rev > 0 round-trips through containerKeyFor / parseContainerKey',
        () {
      for (final rev in [1, 2, 17, 9999]) {
        final key = containerKeyFor('abc', rev);
        expect(key, 'abc_r$rev');
        final parsed = parseContainerKey(key);
        expect(parsed.siteId, 'abc');
        expect(parsed.rev, rev);
      }
    });

    test('siteIds that contain hyphens parse correctly', () {
      // _generateSiteId() produces base36 with a single hyphen
      // separator (e.g. 'mz7q9x-1a2b'); the rev marker uses `_r`
      // specifically so it can't collide.
      const siteId = 'hgi68ko9ye-ecig';
      expect(containerKeyFor(siteId, 0), siteId);
      expect(containerKeyFor(siteId, 3), '${siteId}_r3');
      expect(parseContainerKey('${siteId}_r3').siteId, siteId);
      expect(parseContainerKey('${siteId}_r3').rev, 3);
      expect(parseContainerKey(siteId).siteId, siteId);
      expect(parseContainerKey(siteId).rev, 0);
    });

    test('an unrelated container name falls through to rev 0', () {
      // A stray container left over from another product, or a
      // hand-edited name. Tolerated: parsed as rev 0 with siteId =
      // full key, GC will sweep it because no active site claims it.
      final parsed = parseContainerKey('not_a_normal_name');
      expect(parsed.siteId, 'not_a_normal_name');
      expect(parsed.rev, 0);
    });
  });

  group('ContainerIsolationEngine — unsupported platform fall-through', () {
    test('every method short-circuits when isSupported() returns false',
        () async {
      final native = MockContainerNative(supported: false);
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.ensureContainer('site-A');
      final bound = await engine.bindForSite('site-A');
      await engine.onSiteDeleted('site-A');
      final gced = await engine.garbageCollectOrphans({'site-A': 0});

      expect(bound, 0);
      expect(gced, 0);
      expect(native.profiles, isEmpty);
      expect(
        native.calls.where((c) => c != 'isSupported').toList(),
        isEmpty,
        reason: 'Only the supported-check should have run',
      );
    });
  });

  group('ContainerIsolationEngine — bindForSite', () {
    test('rev 0 binds the bare siteId — back-compat', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      final bound = await engine.bindForSite('site-A');

      expect(bound, 1);
      expect(native.profiles, {'site-A': 'ws-site-A'});
      final keyCalls = native.calls
          .where((c) =>
              c.startsWith('getOrCreateContainer') ||
              c.startsWith('bindContainerToWebView'))
          .toList();
      expect(keyCalls, [
        'getOrCreateContainer(site-A)',
        'bindContainerToWebView(site-A)',
      ]);
    });

    test('rev > 0 binds the suffixed key', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.bindForSite('site-A', rev: 4);

      expect(native.profiles, {'site-A_r4': 'ws-site-A_r4'});
    });
  });

  group('ContainerIsolationEngine — onSiteDeleted', () {
    test('drops the current-rev container', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');

      await engine.onSiteDeleted('site-A');

      expect(native.profiles.keys, ['site-B']);
    });

    test('drops every rev for the deleted site (catches lingering orphans)',
        () async {
      // After multiple "Clear Site Data" taps, site-A's old rev'd
      // containers can linger if startup GC hasn't run yet. Deletion
      // is the user's clearest signal — sweep them all.
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.bindForSite('site-A', rev: 0);
      await engine.bindForSite('site-A', rev: 1);
      await engine.bindForSite('site-A', rev: 3);
      await engine.bindForSite('site-B');

      await engine.onSiteDeleted('site-A');

      expect(native.profiles.keys, ['site-B']);
    });

    test('no-op when site has no container (never bound in profile mode)',
        () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.onSiteDeleted('site-A');

      expect(native.profiles, isEmpty);
    });
  });

  group('ContainerIsolationEngine — garbageCollectOrphans', () {
    test('sweeps containers whose siteId is no longer active', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');
      await engine.bindForSite('site-C');

      // Site B was deleted in a previous session.
      final deleted = await engine.garbageCollectOrphans({
        'site-A': 0,
        'site-C': 0,
      });

      expect(deleted, 1);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-C']));
    });

    test(
        'sweeps stale-rev containers — the "previous wipe left an orphan" '
        'case', () async {
      // This is the path that fixes #360: after the user taps "Clear
      // Site Data", model.containerRev goes 0→1 and the new webview
      // binds to `ws-A_r1`. The previous `ws-A` lingers (its WKWebView
      // may still be retained by a JS handler) and is swept here.
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.bindForSite('site-A', rev: 0);
      await engine.bindForSite('site-A', rev: 1);

      final deleted = await engine.garbageCollectOrphans({'site-A': 1});

      expect(deleted, 1);
      expect(native.profiles.keys, ['site-A_r1'],
          reason: 'rev 0 container is orphaned and swept; rev 1 survives');
    });

    test('returns 0 when every container is current', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B', rev: 2);

      final deleted = await engine.garbageCollectOrphans({
        'site-A': 0,
        'site-B': 2,
      });

      expect(deleted, 0);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-B_r2']));
    });

    test('sweeps every profile when the active map is empty', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');

      final deleted = await engine.garbageCollectOrphans({});

      expect(deleted, 2);
      expect(native.profiles, isEmpty);
    });
  });

  group('ContainerIsolationEngine — bumpRevs', () {
    test('increments every entry by 1', () {
      final engine =
          ContainerIsolationEngine(containerNative: MockContainerNative());

      final next = engine.bumpRevs({'a': 0, 'b': 3, 'c': 17});

      expect(next, {'a': 1, 'b': 4, 'c': 18});
    });

    test('empty input is a no-op', () {
      final engine =
          ContainerIsolationEngine(containerNative: MockContainerNative());

      expect(engine.bumpRevs({}), isEmpty);
    });
  });
}
