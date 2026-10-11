import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_isolation_engine.dart';

import 'helpers/mock_container_native.dart';

void main() {
  group('ContainerIsolationEngine — unsupported platform fall-through', () {
    test('every method short-circuits when isSupported() returns false',
        () async {
      final native = MockContainerNative(supported: false);
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.ensureContainer('site-A');
      await engine.onSiteDeleted('site-A');
      final cleared = await engine.clearForSite('site-A');
      final gced = await engine.garbageCollectOrphans({'site-A'});

      expect(cleared, isFalse);
      expect(gced, 0);
      expect(native.profiles, isEmpty);
      expect(
        native.calls.where((c) => c != 'isSupported').toList(),
        isEmpty,
        reason: 'Only the supported-check should have run',
      );
    });
  });

  group('ContainerIsolationEngine — ensureContainer', () {
    test('is idempotent — repeated calls reuse the same profile', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.ensureContainer('site-A');
      await engine.ensureContainer('site-A');
      await engine.ensureContainer('site-A');

      expect(native.profiles, {'site-A': 'ws-site-A'});
    });
  });

  group('ContainerIsolationEngine — onSiteDeleted', () {
    test('drops only the named site\'s profile', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer('site-A');
      await engine.ensureContainer('site-B');

      await engine.onSiteDeleted('site-A');

      expect(native.profiles.keys, ['site-B']);
    });

    test('no-op when site has no profile (never bound)', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.onSiteDeleted('site-A');

      expect(native.profiles, isEmpty);
    });
  });

  group('ContainerIsolationEngine — clearForSite', () {
    test('wipes the container\'s data but keeps the container alive',
        () async {
      // This is the path that replaces the unreliable `deleteContainer`
      // dance for "Clear Site Data" on iOS/macOS (#360). The fork's
      // `clearContainerData` maps to
      // `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)`, which
      // is documented as safe while a WKWebView is bound.
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer('site-A');
      native.dataByContainer['site-A'] = ['cookie-1', 'localStorage-foo'];

      final ok = await engine.clearForSite('site-A');

      expect(ok, isTrue);
      expect(native.profiles.keys, ['site-A'],
          reason: 'container itself is NOT removed — only its contents');
      expect(native.dataByContainer['site-A'], isEmpty);
    });

    test('returns false when the platform refuses (e.g. Linux pre-bind)',
        () async {
      final native = MockContainerNative()..refuseClearFor = {'site-A'};
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer('site-A');
      native.dataByContainer['site-A'] = ['cookie-1'];

      final ok = await engine.clearForSite('site-A');

      expect(ok, isFalse);
      expect(native.dataByContainer['site-A'], ['cookie-1'],
          reason: 'platform refusal must not silently report success');
    });

    test('returns false for an unknown siteId', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      final ok = await engine.clearForSite('ghost');

      expect(ok, isFalse);
    });
  });

  group('ContainerIsolationEngine — garbageCollectOrphans', () {
    test('deletes profiles whose owning site no longer exists', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer('site-A');
      await engine.ensureContainer('site-B');
      await engine.ensureContainer('site-C');

      final deleted =
          await engine.garbageCollectOrphans({'site-A', 'site-C'});

      expect(deleted, 1);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-C']));
    });

    test(
        'sweeps leftover rev\'d-name containers from the abandoned '
        'workaround', () async {
      // Earlier on this branch we briefly used `ws-<siteId>_r<N>`
      // names; this verifies that the simple set-membership check
      // drops them as orphans because the parsed name won't match any
      // live siteId. No special parser needed.
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      // Live container under the current scheme.
      await engine.ensureContainer('site-A');
      // Leftover from the abandoned workaround — name happens to be
      // `<siteId>_r1` which used to be a real key.
      native.profiles['site-A_r1'] = 'ws-site-A_r1';

      final deleted = await engine.garbageCollectOrphans({'site-A'});

      expect(deleted, 1);
      expect(native.profiles.keys, ['site-A']);
    });

    test('returns 0 when every profile has a live owner', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer('site-A');
      await engine.ensureContainer('site-B');

      final deleted =
          await engine.garbageCollectOrphans({'site-A', 'site-B'});

      expect(deleted, 0);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-B']));
    });

    test('sweeps every profile when the active set is empty', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer('site-A');
      await engine.ensureContainer('site-B');

      final deleted = await engine.garbageCollectOrphans({});

      expect(deleted, 2);
      expect(native.profiles, isEmpty);
    });
  });
}
