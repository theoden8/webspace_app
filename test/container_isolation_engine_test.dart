import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/container_isolation_engine.dart';

import 'helpers/mock_container_native.dart';

void main() {
  group('ContainerIsolationEngine — ensureContainer', () {
    test('is idempotent — repeated calls reuse the same profile', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));

      expect(native.profiles, {'site-A': 'ws-site-A'});
    });
  });

  group('ContainerIsolationEngine — onSiteDeleted', () {
    test('drops only the named site\'s profile', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-B')));

      await engine.onSiteDeleted(ContainerKey.ofSite(SiteId('site-A')));

      expect(native.profiles.keys, ['site-B']);
    });

    test('no-op when site has no profile (never bound)', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      await engine.onSiteDeleted(ContainerKey.ofSite(SiteId('site-A')));

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
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      native.dataByContainer['site-A'] = ['cookie-1', 'localStorage-foo'];

      final ok = await engine.clearForSite(ContainerKey.ofSite(SiteId('site-A')));

      expect(ok, isTrue);
      expect(native.profiles.keys, ['site-A'],
          reason: 'container itself is NOT removed — only its contents');
      expect(native.dataByContainer['site-A'], isEmpty);
    });

    test('returns false when the platform refuses (e.g. Linux pre-bind)',
        () async {
      final native = MockContainerNative()..refuseClearFor = {'site-A'};
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      native.dataByContainer['site-A'] = ['cookie-1'];

      final ok = await engine.clearForSite(ContainerKey.ofSite(SiteId('site-A')));

      expect(ok, isFalse);
      expect(native.dataByContainer['site-A'], ['cookie-1'],
          reason: 'platform refusal must not silently report success');
    });

    test('returns false for an unknown siteId', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);

      final ok = await engine.clearForSite(ContainerKey.ofSite(SiteId('ghost')));

      expect(ok, isFalse);
    });
  });

  // CONT-004: the grid takes a tap before the launch sweep is done, and a
  // container bound first is one deleteContainer cannot reliably remove.
  group('ContainerIsolationEngine — the launch sweep', () {
    test('a container asked for while it runs is made after it (INC-005)', () async {
      final native = MockContainerNative();
      native.profiles['gone'] = 'ws-gone';
      native.profiles['private'] = 'ws-private';
      final list = Completer<void>();
      native.pace = (call) async {
        if (call == PlatformCall.containerList) await list.future;
      };
      final engine = ContainerIsolationEngine(containerNative: native);

      final sweep = engine.sweepBeforeBind(
        {ContainerKey.ofSite(SiteId('site-A')), ContainerKey.ofSite(SiteId('private'))},
        incognito: {ContainerKey.ofSite(SiteId('private'))},
      );
      final tap = engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await pumpEventQueue();
      expect(native.calls, isNot(contains('getOrCreateContainer(site-A)')));

      list.complete();
      await sweep;
      await tap;
      expect(native.calls, containsAllInOrder([
        'listContainers',
        'deleteContainer(gone)',
        'deleteContainer(private)',
        'getOrCreateContainer(site-A)',
      ]));
      expect(native.profiles.keys, ['site-A']);
    });

    test('a sweep that failed holds back no container after it', () async {
      final native = MockContainerNative();
      // ContainerNative absorbs its channel failures, so a sweep fails only
      // by a bug, an Error, which the container waiting on it sees.
      native.pace = (call) async {
        if (call == PlatformCall.containerList) {
          throw StateError('listing failed');
        }
      };
      final engine = ContainerIsolationEngine(containerNative: native);
      await expectLater(
        engine.sweepBeforeBind({ContainerKey.ofSite(SiteId('site-A'))}, incognito: const {}),
        throwsStateError,
      );
      native.pace = null;
      await expectLater(
        engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A'))),
        throwsStateError,
      );
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-B')));
      expect(native.profiles.keys, containsAll(['site-B']));
    });

    test('a container asked for after it waits for nothing', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.sweepBeforeBind({ContainerKey.ofSite(SiteId('site-A'))}, incognito: const {});
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      expect(native.profiles.keys, ['site-A']);
    });
  });

  group('ContainerIsolationEngine — garbageCollectOrphans', () {
    test('deletes profiles whose owning site no longer exists', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-B')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-C')));

      final deleted =
          await engine.garbageCollectOrphans({ContainerKey.ofSite(SiteId('site-A')), ContainerKey.ofSite(SiteId('site-C'))});

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
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      // Leftover from the abandoned workaround — name happens to be
      // `<siteId>_r1` which used to be a real key.
      native.profiles['site-A_r1'] = 'ws-site-A_r1';

      final deleted = await engine.garbageCollectOrphans({ContainerKey.ofSite(SiteId('site-A'))});

      expect(deleted, 1);
      expect(native.profiles.keys, ['site-A']);
    });

    test('returns 0 when every profile has a live owner', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-B')));

      final deleted =
          await engine.garbageCollectOrphans({ContainerKey.ofSite(SiteId('site-A')), ContainerKey.ofSite(SiteId('site-B'))});

      expect(deleted, 0);
      expect(native.profiles.keys, unorderedEquals(['site-A', 'site-B']));
    });

    test('sweeps every profile when the active set is empty', () async {
      final native = MockContainerNative();
      final engine = ContainerIsolationEngine(containerNative: native);
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-A')));
      await engine.ensureContainer(ContainerKey.ofSite(SiteId('site-B')));

      final deleted = await engine.garbageCollectOrphans({});

      expect(deleted, 2);
      expect(native.profiles, isEmpty);
    });
  });
}
