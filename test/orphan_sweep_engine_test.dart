// Post-paint orphan sweep: which per-site storages get reclaimed, and which
// live set each one is measured against.
//
// The load-bearing case is the legacy global cookie jar clear. Under the
// container engine every site owns its jar, so the global clear reclaims
// nothing — but it is an "empty a cookie jar" instruction issued with no site
// in hand, and a plugin-side mislabel (BUG-007, fork privacy-v5) once pointed
// it at a live container and wiped a real session a launch later. The engine
// must not issue it at all when containers are in use.
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';

class _FakeTargets implements OrphanSweepTargets {
  /// Ordered op log, so tests can assert both membership and sequencing.
  final List<String> ops = [];

  /// Live set each per-site sweep was handed, keyed by op name.
  final Map<String, Set<String>> liveSets = {};

  void _record(String op, [Set<String>? live]) {
    ops.add(op);
    if (live != null) liveSets[op] = live;
  }

  @override
  Future<void> removeOrphanedCookies(Set<String> live) async =>
      _record('cookies', live);

  @override
  Future<void> removeOrphanedProxyPasswords(Set<String> live) async =>
      _record('proxyPasswords', live);

  @override
  Future<void> removeOrphanedHtmlCaches(Set<String> live) async =>
      _record('htmlCaches', live);

  @override
  Future<void> removeOrphanedHtmlImports(Set<String> live) async =>
      _record('htmlImports', live);

  @override
  Future<void> removeOrphanedWebViewState(Set<String> live) async =>
      _record('webViewState', live);

  @override
  Future<void> clearLegacyGlobalCookieJar() async =>
      _record('globalCookieJar');
}

void main() {
  const active = {'a', 'b', 'incog'};
  const nonIncognito = {'a', 'b'};

  group('OrphanSweepEngine.sweep', () {
    test('container mode never clears the global cookie jar', () async {
      final targets = _FakeTargets();

      await OrphanSweepEngine.sweep(
        targets: targets,
        activeSiteIds: active,
        nonIncognitoSiteIds: nonIncognito,
        useContainers: true,
      );

      expect(targets.ops, isNot(contains('globalCookieJar')));
    });

    test('container mode still reclaims every per-site storage', () async {
      final targets = _FakeTargets();

      await OrphanSweepEngine.sweep(
        targets: targets,
        activeSiteIds: active,
        nonIncognitoSiteIds: nonIncognito,
        useContainers: true,
      );

      expect(targets.ops, [
        'cookies',
        'proxyPasswords',
        'htmlCaches',
        'htmlImports',
        'webViewState',
      ]);
    });

    test('legacy mode clears the global jar, after the per-site sweeps',
        () async {
      final targets = _FakeTargets();

      await OrphanSweepEngine.sweep(
        targets: targets,
        activeSiteIds: active,
        nonIncognitoSiteIds: nonIncognito,
        useContainers: false,
      );

      expect(targets.ops.last, 'globalCookieJar');
      expect(targets.ops.length, 6);
    });

    test('session-scoped storages measure against the non-incognito set',
        () async {
      // Incognito sites are deliberately treated as orphans for anything that
      // must not outlive the process (issue #298): cookies, cached HTML, and
      // saved navigation state.
      final targets = _FakeTargets();

      await OrphanSweepEngine.sweep(
        targets: targets,
        activeSiteIds: active,
        nonIncognitoSiteIds: nonIncognito,
        useContainers: true,
      );

      expect(targets.liveSets['cookies'], nonIncognito);
      expect(targets.liveSets['htmlCaches'], nonIncognito);
      expect(targets.liveSets['webViewState'], nonIncognito);
    });

    test('config-scoped storages measure against the full active set',
        () async {
      // Proxy passwords and imported HTML are configuration, not session
      // residue — an incognito site keeps both across launches.
      final targets = _FakeTargets();

      await OrphanSweepEngine.sweep(
        targets: targets,
        activeSiteIds: active,
        nonIncognitoSiteIds: nonIncognito,
        useContainers: true,
      );

      expect(targets.liveSets['proxyPasswords'], active);
      expect(targets.liveSets['htmlImports'], active);
    });
  });
}
