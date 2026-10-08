// Orphan sweep: which per-site storages get reclaimed, and which live set each
// one is measured against.
//
// The critical case is the legacy global cookie jar clear. Under the
// container engine every site owns its jar, so the global clear reclaims
// nothing — but it is an "empty a cookie jar" instruction issued with no site
// in hand, and a plugin-side mislabel (BUG-007, fork privacy-v5) once pointed
// it at a live container and wiped a real session a launch later. The engine
// must not issue it at all when containers are in use.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';

class _FakeTargets implements OrphanSweepTargets {
  final List<Object> ops = [];
  final Map<OrphanStore, Set<String>> liveSets = {};

  @override
  Future<void> removeOrphans(OrphanStore store,
      {required Set<String> liveSiteIds}) async {
    ops.add(store);
    liveSets[store] = liveSiteIds;
  }

  @override
  Future<void> clearLegacyGlobalCookieJar() async => ops.add('globalCookieJar');
}

void main() {
  const active = {'a', 'b', 'incog'};
  const nonIncognito = {'a', 'b'};

  Future<_FakeTargets> sweep({
    required bool useContainers,
    required SweepOccasion occasion,
  }) async {
    final targets = _FakeTargets();
    await OrphanSweepEngine.sweep(
      targets: targets,
      activeSiteIds: active,
      nonIncognitoSiteIds: nonIncognito,
      useContainers: useContainers,
      occasion: occasion,
    );
    return targets;
  }

  group('OrphanSweepEngine.sweep', () {
    test('container mode never clears the global cookie jar', () async {
      final targets =
          await sweep(useContainers: true, occasion: SweepOccasion.launch);

      expect(targets.ops, isNot(contains('globalCookieJar')));
    });

    test('legacy mode clears the global jar at launch, after every store',
        () async {
      final targets =
          await sweep(useContainers: false, occasion: SweepOccasion.launch);

      expect(targets.ops, [...OrphanStore.values, 'globalCookieJar']);
    });

    test('a mid-session sweep never clears the jar the live sessions are in',
        () async {
      // Settings import and site delete run after activation restored the
      // loaded sites' cookies into the shared jar (per-site-cookie-isolation).
      final targets = await sweep(
          useContainers: false, occasion: SweepOccasion.sitesRemoved);

      expect(targets.ops, isNot(contains('globalCookieJar')));
    });

    for (final occasion in SweepOccasion.values) {
      test('${occasion.name} sweeps every store', () async {
        // The post-import sweep was once a hand-copied list that skipped
        // saved navigation state, and the startup one skipped page icons.
        final targets = await sweep(useContainers: true, occasion: occasion);

        expect(targets.ops, OrphanStore.values);
      });
    }

    test('session-scoped storages measure against the non-incognito set',
        () async {
      // Incognito sites are deliberately treated as orphans for anything that
      // must not outlive the process (INC-006): cookies, cached HTML, saved
      // navigation state, the protection report's per-site rows, page icons.
      final targets = await sweep(
          useContainers: true, occasion: SweepOccasion.sitesRemoved);

      for (final store in [
        OrphanStore.cookies,
        OrphanStore.htmlCaches,
        OrphanStore.webViewState,
        OrphanStore.blockStatsSites,
        OrphanStore.siteIcons,
      ]) {
        expect(targets.liveSets[store], nonIncognito, reason: store.name);
      }
    });

    test('config-scoped storages measure against the full active set',
        () async {
      // Proxy passwords, saved sign-ins and imported HTML are configuration,
      // not session residue: an incognito site keeps them across launches.
      final targets = await sweep(
          useContainers: true, occasion: SweepOccasion.sitesRemoved);

      for (final store in [
        OrphanStore.proxyPasswords,
        OrphanStore.httpAuthCredentials,
        OrphanStore.htmlImports,
      ]) {
        expect(targets.liveSets[store], active, reason: store.name);
      }
    });
  });

  group('call sites', () {
    final host = File('lib/main.dart').readAsStringSync();

    String body(String signature) {
      final start = host.indexOf(signature);
      expect(start, greaterThan(-1), reason: 'could not find $signature');
      final end = host.indexOf('\n  Future<void> ', start + signature.length);
      return host.substring(start, end < 0 ? host.length : end);
    }

    // Which changes sweep is SiteSetChange.effects (site_runtime_test).
    test('import and delete sweep through the engine', () {
      expect(body('Future<void> _commitSites(SiteSetChange change) async {'),
          contains('if (effects.sweepsOrphans) await _sweepOrphans();'));
      expect(body('Future<void> _importSettings() async {'),
          contains('await _commitSites(SitesReplaced('));
      expect(
          body('Future<void> _deleteSite(BuildContext context, '
              '{required int index}) async {'),
          contains('await _commitSites(SiteRemoved(deletedModel));'));
    });

    test('no store is swept outside the engine binding', () {
      final binding = host.indexOf('class _OrphanSweepTargets');
      final bindingEnd = host.indexOf('\n}\n', binding);
      final outside =
          host.substring(0, binding) + host.substring(bindingEnd);
      expect(RegExp(r'\.removeOrphan').allMatches(outside), isEmpty);
    });
  });
}
