// Orphan sweep: which per-site storages get reclaimed, and which live set each
// one is measured against.
//
// The legacy shared cookie jar is not among them. It holds no site's entries
// apart, so the only op on it with no site in hand is
// CookieIsolationEngine.clearAtLaunch, the jar's first turn; container mode
// has no shared jar to clear, which keeps the plugin-side mislabel that once
// pointed such a clear at a live container (BUG-007, fork privacy-v5)
// unreachable.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/site_ids.dart';
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
}

void main() {
  final active = {SiteId('a'), SiteId('b'), SiteId('incog')};
  final nonIncognito = {SiteId('a'), SiteId('b')};

  Future<_FakeTargets> sweep() async {
    final targets = _FakeTargets();
    await OrphanSweepEngine.sweep(
      targets: targets,
      activeSiteIds: active,
      nonIncognitoSiteIds: nonIncognito,
    );
    return targets;
  }

  group('OrphanSweepEngine.sweep', () {
    test('every store is swept (PAUSE-010)', () async {
      // The post-import sweep was once a hand-copied list that skipped saved
      // navigation state, and the startup one skipped page icons.
      final targets = await sweep();

      expect(targets.ops, OrphanStore.values);
    });

    test('session-scoped storages measure against the non-incognito set',
        () async {
      // Incognito sites are deliberately treated as orphans for anything that
      // must not outlive the process (INC-006): cookies, saved navigation
      // state, the protection report's per-site rows, page icons.
      final targets = await sweep();

      for (final store in [
        OrphanStore.cookies,
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
      final targets = await sweep();

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
    // Which changes sweep is SiteSetChange.effects (site_runtime_test), and
    // that the commit sweeps for them is site_set_commit_test.
    test('import and delete sweep through the engine', () {
      expect(File('lib/screens/webspace_page.dart').readAsStringSync(),
          contains('Future<void> sweepOrphans() => _s._sweep.afterRemoval();'));
      final backup =
          File('lib/controllers/backup_controller.dart').readAsStringSync();
      expect(backup.substring(backup.indexOf('Future<void> import() async {')),
          contains('await _host.commitSites(SitesReplaced('));
      final editing =
          File('lib/controllers/site_editing_controller.dart').readAsStringSync();
      expect(
          editing.substring(editing.indexOf('Future<void> deleteSite(WebViewModel deletedModel) async {')),
          contains('await _deletion.delete(deletedModel);'));
      expect(File('lib/controllers/site_deletion.dart').readAsStringSync(),
          contains('controller._host.stageSites(\n    SiteRemoved(site),\n  )'));
    });

    test('no store is swept outside the engine binding', () {
      final binding =
          File('lib/controllers/page_orphan_sweep.dart').readAsStringSync();
      expect(binding, contains('class PageOrphanSweep implements OrphanSweepTargets'));
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('page_orphan_sweep.dart') ||
            f.path.contains('/services/')) {
          continue;
        }
        expect(RegExp(r'\.removeOrphan').allMatches(f.readAsStringSync()),
            isEmpty,
            reason: '${f.path} sweeps a store outside PageOrphanSweep');
      }
    });
  });
}
