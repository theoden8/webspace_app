import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/profile_isolation_engine.dart';
import 'package:webspace/services/profile_native.dart';

/// In-memory model of the native Profile API: a set of named profiles
/// each owning its own cookie jar, with `bindProfileToWebView` simulated
/// as a binding registry. Mirrors the [MockCookieManager] pattern in
/// [test/cookie_isolation_integration_test.dart] — the engine is unaware
/// it is talking to a fake.
///
/// Cookies aren't modeled directly here (the engine doesn't manipulate
/// them; that's the native plugin's job). The test surface is the
/// orchestration: which profiles are created, bound, deleted, and listed.
class MockProfileNative implements ProfileNative {
  bool supported;

  /// `siteId` -> profile name (`ws-<siteId>`).
  final Map<String, String> profiles = {};

  /// Last bind count returned per siteId — emulates how many webviews
  /// were found and bound on the most recent bind call.
  final Map<String, int> webviewsForSite = {};

  /// Records every method call so tests can assert sequencing.
  final List<String> calls = [];

  MockProfileNative({this.supported = true});

  @override
  Future<bool> isSupported() async {
    calls.add('isSupported');
    return supported;
  }

  @override
  Future<String> getOrCreateProfile(String siteId) async {
    calls.add('getOrCreateProfile($siteId)');
    final name = 'ws-$siteId';
    profiles[siteId] = name;
    return name;
  }

  @override
  Future<int> bindProfileToWebView(String siteId) async {
    calls.add('bindProfileToWebView($siteId)');
    if (!profiles.containsKey(siteId)) {
      throw StateError(
        'bind called before getOrCreateProfile($siteId) — '
        'production engine must always create-then-bind',
      );
    }
    return webviewsForSite[siteId] ?? 1;
  }

  @override
  Future<void> deleteProfile(String siteId) async {
    calls.add('deleteProfile($siteId)');
    profiles.remove(siteId);
    webviewsForSite.remove(siteId);
  }

  @override
  Future<List<String>> listProfiles() async {
    calls.add('listProfiles');
    return profiles.keys.toList();
  }
}

void main() {
  group('ProfileIsolationEngine — unsupported platform fall-through', () {
    test('every method short-circuits when isSupported() returns false', () async {
      final native = MockProfileNative(supported: false);
      final engine = ProfileIsolationEngine(profileNative: native);

      await engine.ensureProfile('site-A');
      final bound = await engine.bindForSite('site-A');
      await engine.onSiteDeleted('site-A');
      final gced = await engine.garbageCollectOrphans({'site-A'});

      expect(bound, 0);
      expect(gced, 0);
      // No profile state was touched — not even getOrCreateProfile, so
      // the call site can be trusted to be a true no-op on iOS / macOS /
      // legacy Android.
      expect(native.profiles, isEmpty);
      expect(
        native.calls.where((c) => c != 'isSupported').toList(),
        isEmpty,
        reason: 'Only the supported-check should have run',
      );
    });
  });

  group('ProfileIsolationEngine — bindForSite', () {
    test('creates the profile then binds in that order', () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);

      final bound = await engine.bindForSite('site-A');

      expect(bound, 1);
      expect(native.profiles, {'site-A': 'ws-site-A'});
      // Sequence MUST be create → bind. Binding before create would throw
      // on the native side (setProfile requires the profile to exist).
      final keyCalls = native.calls
          .where((c) =>
              c.startsWith('getOrCreateProfile') ||
              c.startsWith('bindProfileToWebView'))
          .toList();
      expect(keyCalls, [
        'getOrCreateProfile(site-A)',
        'bindProfileToWebView(site-A)',
      ]);
    });

    test('is idempotent — repeated calls reuse the same profile', () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);

      await engine.bindForSite('site-A');
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-A');

      expect(native.profiles.keys, ['site-A']);
      expect(
        native.calls.where((c) => c == 'getOrCreateProfile(site-A)').length,
        3,
        reason: 'idempotent on the native side, not memoized in Dart',
      );
    });
  });

  group('ProfileIsolationEngine — onSiteDeleted', () {
    test('drops only the named site\'s profile', () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');

      await engine.onSiteDeleted('site-A');

      expect(native.profiles.keys, ['site-B']);
    });

    test('no-op when site has no profile (unloaded before profile mode)',
        () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);

      // Should not throw — production deletion path runs even for sites
      // that never got a profile bound (e.g. a stale legacy site).
      await engine.onSiteDeleted('site-A');

      expect(native.profiles, isEmpty);
    });
  });

  group('ProfileIsolationEngine — garbageCollectOrphans', () {
    test('deletes profiles whose owning site no longer exists', () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');
      await engine.bindForSite('site-C');

      // Site B was deleted in a previous session; its profile lingers.
      // GC sees only A and C in the active set.
      final deleted =
          await engine.garbageCollectOrphans({'site-A', 'site-C'});

      expect(deleted, 1);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-C']));
    });

    test('returns 0 when every profile has a live owner', () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');

      final deleted =
          await engine.garbageCollectOrphans({'site-A', 'site-B'});

      expect(deleted, 0);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-B']));
    });

    test('handles the empty-active-set case (all sites deleted)', () async {
      final native = MockProfileNative();
      final engine = ProfileIsolationEngine(profileNative: native);
      await engine.bindForSite('site-A');
      await engine.bindForSite('site-B');

      final deleted = await engine.garbageCollectOrphans({});

      expect(deleted, 2);
      expect(native.profiles, isEmpty);
    });
  });
}
