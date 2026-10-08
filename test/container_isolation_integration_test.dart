import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/site_list_state.dart';

/// In-memory model of the native Profile API with **per-profile cookie
/// storage**, so the central spec claim — sites in different profiles do
/// not see each other's cookies — can actually be asserted, not just
/// assumed. Every cookie write goes through a [SimWebView] that is
/// scoped to its site's profile from construction (CONT-005); reads from
/// the wrong profile see nothing.
///
/// Mirrors the [MockCookieManager] pattern in
/// [test/helpers/mock_cookie_manager.dart] — modeling the engine's
/// actual contract end-to-end, not stubbing it.
class MockContainerNative implements ContainerNative {
  bool supported;

  /// `siteId` -> `ws-<siteId>` for every profile that exists in the
  /// simulated `ProfileStore`. Mirrors `ProfileStore.getAllProfileNames()`.
  final Map<String, String> containers = {};

  /// Per-profile cookie store. Outer key is the profile name
  /// (`ws-<siteId>`); inner is `cookieName -> value`. A read from the
  /// wrong profile sees the empty map for that profile, so cross-profile
  /// leaks fail the assertion that the owning site's cookie is intact.
  final Map<String, Map<String, String>> cookiesByContainer = {};

  /// Records every native call so tests can assert which ones ran.
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
  Future<String> getOrCreateContainer(String siteId) async {
    calls.add('getOrCreateContainer($siteId)');
    final name = 'ws-$siteId';
    containers[siteId] = name;
    cookiesByContainer.putIfAbsent(name, () => <String, String>{});
    return name;
  }


  @override
  Future<bool> deleteContainer(String siteId) async {
    calls.add('deleteContainer($siteId)');
    final existed = containers.remove(siteId) != null;
    cookiesByContainer.remove('ws-$siteId');
    return existed;
  }

  @override
  Future<bool> clearContainerData(String siteId) async {
    calls.add('clearContainerData($siteId)');
    if (!containers.containsKey(siteId)) return false;
    cookiesByContainer['ws-$siteId'] = {};
    return true;
  }

  @override
  Future<List<String>> listContainers() async {
    calls.add('listContainers');
    return containers.keys.toList();
  }

  /// Inject an orphan profile to simulate state left behind by a previous
  /// session (site deleted before profile mode shipped, or a crash mid-
  /// deletion). The orphan has its own cookie jar so a successful GC
  /// must drop both the profile name and its data.
  void seedOrphanContainer(String siteId,
      {required Map<String, String> cookies}) {
    containers[siteId] = 'ws-$siteId';
    cookiesByContainer['ws-$siteId'] = Map.of(cookies);
  }
}

/// A site's webview, bound to its profile. Cookie ops are scoped to the
/// profile registered at bind time — analogous to how
/// `WebViewCompat.setProfile` rebinds the native `CookieManager` on the
/// underlying `WebView` to the profile's directory. After bind, every
/// cookie operation routes through [MockContainerNative.cookiesByContainer]
/// keyed by `ws-<siteId>`.
class SimWebView {
  final String siteId;
  final MockContainerNative native;

  SimWebView(this.siteId, {required this.native});

  String get _profileName => 'ws-$siteId';

  Future<void> setCookie(String name, {required String value}) async {
    final jar = native.cookiesByContainer.putIfAbsent(
      _profileName,
      () => <String, String>{},
    );
    jar[name] = value;
  }

  Future<String?> getCookie(String name) async =>
      native.cookiesByContainer[_profileName]?[name];

  Map<String, String> get allCookies =>
      Map.unmodifiable(native.cookiesByContainer[_profileName] ?? const {});
}

/// Test harness for profile-mode site activation. Mirrors the
/// `_useProfiles == true` branch of `SiteActivationController.setCurrentIndex`
/// and `SiteEditingController.deleteSite`: skips conflict-find/unload, ensures the profile,
/// marks loaded, simulates webview construction triggering a native
/// bind. Delegates the real work to [ContainerIsolationEngine] so tests
/// exercise production code rather than a parallel implementation —
/// same DRY rule as [CookieIsolationTestHarness].
class ContainerIsolationTestHarness with SiteListState {
  final MockContainerNative native = MockContainerNative();
  late final ContainerIsolationEngine engine =
      ContainerIsolationEngine(containerNative: native);
  final Map<String, SimWebView> _webViewsBySiteId = {};

  Map<int, SimWebView> get webViews => {
        for (var i = 0; i < sites.length; i++)
          i: ?_webViewsBySiteId[sites[i].siteId],
      };

  void addSite(String url, {String? name}) {
    sites.add(WebViewModel(initUrl: url, name: name));
  }

  /// Mirrors `setCurrentIndex` for the profile-mode branch:
  ///   1. No `findDomainConflict` call — sites are isolated at the
  ///      engine level, so same-base-domain conflicts don't unload
  ///      anyone (CONT-003).
  ///   2. Ensure the profile exists in `ProfileStore`.
  ///   3. Mark the index loaded.
  ///   4. Simulate `flutter_inappwebview` constructing the WebView with
  ///      `containerId` set, which binds it to the profile (CONT-005).
  Future<void> switchToSite(int index) async {
    if (index < 0 || index >= sites.length) return;

    final target = sites[index];
    await engine.ensureContainer(target.siteId);

    currentIndex = index;
    loadedIndices.add(index);

    // Construct the simulated webview the first time the site is
    // visited; reuse on later activations (the lazy-load behavior in
    // _WebSpacePageState).
    _webViewsBySiteId.putIfAbsent(
        target.siteId, () => SimWebView(target.siteId, native: native));
  }

  /// Mirrors `SiteEditingController.deleteSite` for the profile-mode branch: drop the
  /// webview, drop the profile (which evicts every cookie / storage
  /// blob owned by the site), shift indices.
  Future<void> deleteSite(int index) async {
    final deleted = sites[index];
    _webViewsBySiteId.remove(deleted.siteId);
    await engine.onSiteDeleted(deleted.siteId);
    removeSiteAt(index);
  }

  /// Mirrors the startup GC in `StartupController.restore`: sweep profiles that
  /// have no surviving site. Run after seeding prior-session orphan
  /// profiles to verify they don't survive.
  Future<int> simulateAppStartupGc() async {
    return engine.garbageCollectOrphans(
      sites.map((s) => s.siteId).toSet(),
    );
  }
}

void main() {
  group('CONT-002 — Profile lifecycle', () {
    test('first activation creates the profile', () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');

      await h.switchToSite(0);

      expect(h.native.containers.values, contains('ws-${h.sites[0].siteId}'));
      expect(h.native.calls, contains('getOrCreateContainer(${h.sites[0].siteId})'));
    });

    test('re-activation reuses the same profile (idempotent)', () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');

      await h.switchToSite(0);
      await h.switchToSite(0);
      await h.switchToSite(0);

      // ProfileStore should still have exactly one profile for this site.
      expect(h.native.containers.length, 1);
      // The simulated webview is reused, not rebuilt — modeling the
      // _loadedIndices lazy-load behavior.
      expect(h.webViews.length, 1);
    });
  });

  group('CONT-003 — Same-base-domain coexistence', () {
    test('two GitHub accounts load concurrently with isolated cookies',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal', name: 'A');
      h.addSite('https://github.com/work', name: 'B');

      // Switch to A and write a session cookie on its profile.
      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('user_session', value: 'alice-token');

      // Switch to B — without unloading A. In legacy mode this would
      // unload A; in profile mode both sites must coexist.
      await h.switchToSite(1);
      expect(
        h.loadedIndices,
        unorderedEquals({0, 1}),
        reason:
            'CONT-003: same-base-domain sites must not trigger conflict '
            'unload in profile mode',
      );

      // B writes its own session cookie. Different profile, different jar.
      await h.webViews[1]!.setCookie('user_session', value: 'bob-token');

      // The corollary: each site reads only its own cookie value, never
      // the other site's. A direct test of the partitioning claim.
      expect(await h.webViews[0]!.getCookie('user_session'), 'alice-token');
      expect(await h.webViews[1]!.getCookie('user_session'), 'bob-token');
    });

    test('switching back and forth preserves both sessions', () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', value: 'A');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('session', value: 'B');
      await h.switchToSite(0);
      await h.switchToSite(1);
      await h.switchToSite(0);

      // Both webviews are still loaded; neither cookie was lost.
      expect(h.loadedIndices, unorderedEquals({0, 1}));
      expect(await h.webViews[0]!.getCookie('session'), 'A');
      expect(await h.webViews[1]!.getCookie('session'), 'B');
    });

    test('a third site on an unrelated domain is isolated from both',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');
      h.addSite('https://example.com');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('k', value: 'github-personal');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('k', value: 'github-work');
      await h.switchToSite(2);
      await h.webViews[2]!.setCookie('k', value: 'example');

      // Each site sees only its own value for the same cookie name.
      expect(await h.webViews[0]!.getCookie('k'), 'github-personal');
      expect(await h.webViews[1]!.getCookie('k'), 'github-work');
      expect(await h.webViews[2]!.getCookie('k'), 'example');
    });
  });

  group('Cross-profile leak prevention', () {
    test('a cookie set in one profile is invisible in a sibling profile',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('secret', value: 'A-only');

      await h.switchToSite(1);
      // Site B's profile has no `secret` — the cookie lives in A's jar
      // and is not visible from B's. This is the spec's central claim
      // and the reason profiles supersede capture-nuke-restore.
      expect(await h.webViews[1]!.getCookie('secret'), isNull);
    });

    test('logging out of one site does not log the other out', () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', value: 'alice');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('session', value: 'bob');

      // "Log out" of B by clearing its cookie via the simulated webview.
      final bJar = h.native.cookiesByContainer['ws-${h.sites[1].siteId}']!;
      bJar.remove('session');

      // A's session must be intact — the legacy capture-nuke-restore
      // engine could have collateral-damaged it, profiles cannot.
      expect(await h.webViews[0]!.getCookie('session'), 'alice');
      expect(await h.webViews[1]!.getCookie('session'), isNull);
    });
  });

  group('CONT-002 — Site deletion drops the profile', () {
    test('deleting one site does not touch the surviving sibling',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', value: 'alice');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('session', value: 'bob');

      final aSiteId = h.sites[0].siteId;
      final bSiteId = h.sites[1].siteId;

      await h.deleteSite(0);

      // A's profile and its cookies are gone; B's are untouched. The
      // legacy preDeleteCookieCleanup goes through hoops to preserve B's
      // session because A's URL-scoped delete would wipe B's host
      // cookies; profiles avoid that whole class of bug.
      expect(h.native.containers.containsKey(aSiteId), isFalse);
      expect(h.native.cookiesByContainer.containsKey('ws-$aSiteId'), isFalse);
      expect(h.native.containers[bSiteId], 'ws-$bSiteId');
      expect(h.native.cookiesByContainer['ws-$bSiteId'], {'session': 'bob'});
    });

    test('a loaded site after the deleted one stays loaded at its new index',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');
      h.addSite('https://example.com');
      await h.switchToSite(0);
      await h.switchToSite(2);
      await h.webViews[2]!.setCookie('session', value: 'carol');

      await h.deleteSite(0);

      expect(h.loadedIndices, {1});
      expect(h.currentIndex, 1);
      expect(await h.webViews[1]!.getCookie('session'), 'carol');
    });

    test('re-adding a deleted site starts with an empty profile', () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://linkedin.com');
      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', value: 'old');
      final oldSiteId = h.sites[0].siteId;

      await h.deleteSite(0);

      // Add the same URL as a fresh site (gets a new siteId, hence a
      // new profile name).
      h.addSite('https://linkedin.com');
      await h.switchToSite(0);

      expect(h.sites[0].siteId, isNot(oldSiteId));
      expect(await h.webViews[0]!.getCookie('session'), isNull);
      expect(h.native.cookiesByContainer['ws-${h.sites[0].siteId}'], isEmpty);
    });
  });

  group('CONT-004 — Orphan garbage collection at startup', () {
    test('profiles for sites deleted in a prior session are swept',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://github.com');
      h.addSite('https://example.com');

      // Seed profiles as if the previous session had three sites and
      // the user deleted one before profile mode could clean up. Two
      // of the seeded profiles match the current siteIds; the third is
      // an orphan.
      await h.engine.ensureContainer(h.sites[0].siteId);
      await h.engine.ensureContainer(h.sites[1].siteId);
      h.native.seedOrphanContainer('deleted-in-prev-session', cookies: {
        'still-here': 'leaks-without-gc',
      });

      final deleted = await h.simulateAppStartupGc();

      expect(deleted, 1);
      expect(h.native.containers.containsKey('deleted-in-prev-session'), isFalse);
      expect(h.native.cookiesByContainer['ws-deleted-in-prev-session'], isNull);
      // The two live sites' profiles are intact.
      expect(h.native.containers[h.sites[0].siteId], isNotNull);
      expect(h.native.containers[h.sites[1].siteId], isNotNull);
    });

    test('GC at startup is a no-op when every profile has a live owner',
        () async {
      final h = ContainerIsolationTestHarness();
      h.addSite('https://a.com');
      h.addSite('https://b.com');
      await h.engine.ensureContainer(h.sites[0].siteId);
      await h.engine.ensureContainer(h.sites[1].siteId);

      final deleted = await h.simulateAppStartupGc();

      expect(deleted, 0);
      expect(h.native.containers.length, 2);
    });

    test('GC sweeps every profile when the site list is empty', () async {
      final h = ContainerIsolationTestHarness();
      h.native.seedOrphanContainer('a', cookies: {'k': 'v'});
      h.native.seedOrphanContainer('b', cookies: {'k': 'v'});

      final deleted = await h.simulateAppStartupGc();

      expect(deleted, 2);
      expect(h.native.containers, isEmpty);
      expect(h.native.cookiesByContainer, isEmpty);
    });
  });

  group('Engine selection invariants', () {
    test('isSupported() is the gate — profile path stays cold when false',
        () async {
      final h = ContainerIsolationTestHarness();
      h.native.supported = false;
      h.addSite('https://github.com');

      // The harness still calls switchToSite — the gating decision in
      // the production call site (`_useProfiles`) is what skips the
      // engine. Here we verify the engine itself is also a no-op when
      // unsupported, defending against accidentally calling it from a
      // future code path that forgets the gate.
      await h.switchToSite(0);

      expect(h.native.containers, isEmpty,
          reason: 'engine must not touch ProfileStore when isSupported '
              'returns false');
      // Only the supported-check should have run on the native side.
      expect(
        h.native.calls.where((c) => c != 'isSupported').toList(),
        isEmpty,
      );
    });
  });
}
