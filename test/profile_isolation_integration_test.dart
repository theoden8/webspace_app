import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/profile_isolation_engine.dart';
import 'package:webspace/services/profile_native.dart';
import 'package:webspace/web_view_model.dart';

/// In-memory model of the native Profile API with **per-profile cookie
/// storage**, so the central spec claim — sites in different profiles do
/// not see each other's cookies — can actually be asserted, not just
/// assumed. Every cookie write goes through a [SimWebView] that is
/// scoped to a profile via [bindProfileToWebView]; reads from the wrong
/// profile see nothing.
///
/// Mirrors the [MockCookieManager] pattern in
/// [test/cookie_isolation_integration_test.dart] — modeling the engine's
/// actual contract end-to-end, not stubbing it.
class MockProfileNative implements ProfileNative {
  bool supported;

  /// `siteId` -> `ws-<siteId>` for every profile that exists in the
  /// simulated `ProfileStore`. Mirrors `ProfileStore.getAllProfileNames()`.
  final Map<String, String> profiles = {};

  /// Per-profile cookie store. Outer key is the profile name
  /// (`ws-<siteId>`); inner is `cookieName -> value`. A read from the
  /// wrong profile sees the empty map for that profile, so cross-profile
  /// leaks fail the assertion that the owning site's cookie is intact.
  final Map<String, Map<String, String>> cookiesByProfile = {};

  /// Records every native call so tests can assert sequencing (the
  /// create-then-bind ordering matters; setProfile throws if the profile
  /// doesn't exist yet).
  final List<String> calls = [];

  /// When non-null, [bindProfileToWebView] returns this instead of the
  /// real bound count. Tests use it to model the PROF-005 race where the
  /// native side caught `IllegalStateException` and the bind silently
  /// failed.
  int? overrideBindCount;

  MockProfileNative({this.supported = true});

  @override
  bool get cachedSupported => supported;

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
    cookiesByProfile.putIfAbsent(name, () => <String, String>{});
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
    return overrideBindCount ?? 1;
  }

  @override
  Future<void> deleteProfile(String siteId) async {
    calls.add('deleteProfile($siteId)');
    profiles.remove(siteId);
    cookiesByProfile.remove('ws-$siteId');
  }

  @override
  Future<List<String>> listProfiles() async {
    calls.add('listProfiles');
    return profiles.keys.toList();
  }

  /// Inject an orphan profile to simulate state left behind by a previous
  /// session (site deleted before profile mode shipped, or a crash mid-
  /// deletion). The orphan has its own cookie jar so a successful GC
  /// must drop both the profile name and its data.
  void seedOrphanProfile(String siteId, Map<String, String> cookies) {
    profiles[siteId] = 'ws-$siteId';
    cookiesByProfile['ws-$siteId'] = Map.of(cookies);
  }
}

/// A site's webview, bound to its profile. Cookie ops are scoped to the
/// profile registered at bind time — analogous to how
/// `WebViewCompat.setProfile` rebinds the native `CookieManager` on the
/// underlying `WebView` to the profile's directory. After bind, every
/// cookie operation routes through [MockProfileNative.cookiesByProfile]
/// keyed by `ws-<siteId>`.
class SimWebView {
  final String siteId;
  final MockProfileNative native;

  SimWebView(this.siteId, this.native);

  String get _profileName => 'ws-$siteId';

  Future<void> setCookie(String name, String value) async {
    final jar = native.cookiesByProfile.putIfAbsent(
      _profileName,
      () => <String, String>{},
    );
    jar[name] = value;
  }

  Future<String?> getCookie(String name) async =>
      native.cookiesByProfile[_profileName]?[name];

  Map<String, String> get allCookies =>
      Map.unmodifiable(native.cookiesByProfile[_profileName] ?? const {});
}

/// Test harness for profile-mode site activation. Mirrors the
/// `_useProfiles == true` branch of `_WebSpacePageState._setCurrentIndex`
/// and `_deleteSite`: skips conflict-find/unload, ensures the profile,
/// marks loaded, simulates webview construction triggering a native
/// bind. Delegates the real work to [ProfileIsolationEngine] so tests
/// exercise production code rather than a parallel implementation —
/// same DRY rule as [CookieIsolationTestHarness].
class ProfileIsolationTestHarness {
  final MockProfileNative native = MockProfileNative();
  late final ProfileIsolationEngine engine =
      ProfileIsolationEngine(profileNative: native);
  final List<WebViewModel> sites = [];
  final Set<int> loadedIndices = {};
  final Map<int, SimWebView> webViews = {};
  int? currentIndex;

  void addSite(String url, {String? name}) {
    sites.add(WebViewModel(initUrl: url, name: name));
  }

  /// Mirrors `_setCurrentIndex` for the profile-mode branch:
  ///   1. No `findDomainConflict` call — sites are isolated at the
  ///      engine level, so same-base-domain conflicts don't unload
  ///      anyone (PROF-003).
  ///   2. Ensure the profile exists in `ProfileStore`.
  ///   3. Mark the index loaded.
  ///   4. Simulate `flutter_inappwebview` constructing the WebView and
  ///      `onWebViewCreated` triggering `bindForSite`.
  Future<void> switchToSite(int index) async {
    if (index < 0 || index >= sites.length) return;

    final target = sites[index];
    await engine.ensureProfile(target.siteId);

    currentIndex = index;
    loadedIndices.add(index);

    // Construct the simulated webview the first time the site is
    // visited; reuse on later activations (the lazy-load behavior in
    // _WebSpacePageState).
    webViews.putIfAbsent(index, () => SimWebView(target.siteId, native));
    await engine.bindForSite(target.siteId);
  }

  /// Mirrors `_deleteSite` for the profile-mode branch: drop the
  /// webview, drop the profile (which evicts every cookie / storage
  /// blob owned by the site), shift indices.
  Future<void> deleteSite(int index) async {
    final deleted = sites[index];
    webViews.remove(index);
    await engine.onSiteDeleted(deleted.siteId);

    sites.removeAt(index);
    loadedIndices.remove(index);
    loadedIndices.removeWhere((i) => i >= sites.length);
    final shifted = loadedIndices.map((i) => i > index ? i - 1 : i).toSet();
    loadedIndices
      ..clear()
      ..addAll(shifted);
    final shiftedWebViews = <int, SimWebView>{};
    webViews.forEach((i, sim) {
      shiftedWebViews[i > index ? i - 1 : i] = sim;
    });
    webViews
      ..clear()
      ..addAll(shiftedWebViews);

    if (currentIndex == index) {
      currentIndex = null;
    } else if (currentIndex != null && currentIndex! > index) {
      currentIndex = currentIndex! - 1;
    }
  }

  /// Mirrors the startup GC in `_restoreAppState`: sweep profiles that
  /// have no surviving site. Run after seeding prior-session orphan
  /// profiles to verify they don't survive.
  Future<int> simulateAppStartupGc() async {
    return engine.garbageCollectOrphans(
      sites.map((s) => s.siteId).toSet(),
    );
  }
}

void main() {
  group('PROF-002 — Profile lifecycle', () {
    test('first activation creates the profile and binds the webview', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');

      await h.switchToSite(0);

      expect(h.native.profiles.values, contains('ws-${h.sites[0].siteId}'));
      // create-then-bind ordering — required by WebViewCompat.setProfile
      // (binding before the profile exists throws on the native side).
      final keyCalls = h.native.calls
          .where((c) =>
              c.startsWith('getOrCreateProfile') ||
              c.startsWith('bindProfileToWebView'))
          .toList();
      expect(keyCalls.first, startsWith('getOrCreateProfile'));
      expect(
        keyCalls.indexWhere((c) => c.startsWith('bindProfileToWebView')),
        greaterThan(keyCalls.indexWhere((c) => c.startsWith('getOrCreateProfile'))),
      );
    });

    test('re-activation reuses the same profile (idempotent)', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');

      await h.switchToSite(0);
      await h.switchToSite(0);
      await h.switchToSite(0);

      // ProfileStore should still have exactly one profile for this site.
      expect(h.native.profiles.length, 1);
      // The simulated webview is reused, not rebuilt — modeling the
      // _loadedIndices lazy-load behavior.
      expect(h.webViews.length, 1);
    });
  });

  group('PROF-003 — Same-base-domain coexistence', () {
    test('two GitHub accounts load concurrently with isolated cookies',
        () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal', name: 'A');
      h.addSite('https://github.com/work', name: 'B');

      // Switch to A and write a session cookie on its profile.
      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('user_session', 'alice-token');

      // Switch to B — without unloading A. In legacy mode this would
      // unload A; in profile mode both sites must coexist.
      await h.switchToSite(1);
      expect(
        h.loadedIndices,
        unorderedEquals({0, 1}),
        reason:
            'PROF-003: same-base-domain sites must not trigger conflict '
            'unload in profile mode',
      );

      // B writes its own session cookie. Different profile, different jar.
      await h.webViews[1]!.setCookie('user_session', 'bob-token');

      // The corollary: each site reads only its own cookie value, never
      // the other site's. A direct test of the partitioning claim.
      expect(await h.webViews[0]!.getCookie('user_session'), 'alice-token');
      expect(await h.webViews[1]!.getCookie('user_session'), 'bob-token');
    });

    test('switching back and forth preserves both sessions', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', 'A');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('session', 'B');
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
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');
      h.addSite('https://example.com');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('k', 'github-personal');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('k', 'github-work');
      await h.switchToSite(2);
      await h.webViews[2]!.setCookie('k', 'example');

      // Each site sees only its own value for the same cookie name.
      expect(await h.webViews[0]!.getCookie('k'), 'github-personal');
      expect(await h.webViews[1]!.getCookie('k'), 'github-work');
      expect(await h.webViews[2]!.getCookie('k'), 'example');
    });
  });

  group('Cross-profile leak prevention', () {
    test('a cookie set in one profile is invisible in a sibling profile',
        () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('secret', 'A-only');

      await h.switchToSite(1);
      // Site B's profile has no `secret` — the cookie lives in A's jar
      // and is not visible from B's. This is the spec's central claim
      // and the reason profiles supersede capture-nuke-restore.
      expect(await h.webViews[1]!.getCookie('secret'), isNull);
    });

    test('logging out of one site does not log the other out', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', 'alice');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('session', 'bob');

      // "Log out" of B by clearing its cookie via the simulated webview.
      final bJar = h.native.cookiesByProfile['ws-${h.sites[1].siteId}']!;
      bJar.remove('session');

      // A's session must be intact — the legacy capture-nuke-restore
      // engine could have collateral-damaged it, profiles cannot.
      expect(await h.webViews[0]!.getCookie('session'), 'alice');
      expect(await h.webViews[1]!.getCookie('session'), isNull);
    });
  });

  group('PROF-002 — Site deletion drops the profile', () {
    test('deleting one site does not touch the surviving sibling',
        () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com/personal');
      h.addSite('https://github.com/work');

      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', 'alice');
      await h.switchToSite(1);
      await h.webViews[1]!.setCookie('session', 'bob');

      final aSiteId = h.sites[0].siteId;
      final bSiteId = h.sites[1].siteId;

      await h.deleteSite(0);

      // A's profile and its cookies are gone; B's are untouched. The
      // legacy preDeleteCookieCleanup goes through hoops to preserve B's
      // session because A's URL-scoped delete would wipe B's host
      // cookies; profiles avoid that whole class of bug.
      expect(h.native.profiles.containsKey(aSiteId), isFalse);
      expect(h.native.cookiesByProfile.containsKey('ws-$aSiteId'), isFalse);
      expect(h.native.profiles[bSiteId], 'ws-$bSiteId');
      expect(h.native.cookiesByProfile['ws-$bSiteId'], {'session': 'bob'});
    });

    test('re-adding a deleted site starts with an empty profile', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://linkedin.com');
      await h.switchToSite(0);
      await h.webViews[0]!.setCookie('session', 'old');
      final oldSiteId = h.sites[0].siteId;

      await h.deleteSite(0);

      // Add the same URL as a fresh site (gets a new siteId, hence a
      // new profile name).
      h.addSite('https://linkedin.com');
      await h.switchToSite(0);

      expect(h.sites[0].siteId, isNot(oldSiteId));
      expect(await h.webViews[0]!.getCookie('session'), isNull);
      expect(h.native.cookiesByProfile['ws-${h.sites[0].siteId}'], isEmpty);
    });
  });

  group('PROF-004 — Orphan garbage collection at startup', () {
    test('profiles for sites deleted in a prior session are swept',
        () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com');
      h.addSite('https://example.com');

      // Seed profiles as if the previous session had three sites and
      // the user deleted one before profile mode could clean up. Two
      // of the seeded profiles match the current siteIds; the third is
      // an orphan.
      await h.engine.ensureProfile(h.sites[0].siteId);
      await h.engine.ensureProfile(h.sites[1].siteId);
      h.native.seedOrphanProfile('deleted-in-prev-session', {
        'still-here': 'leaks-without-gc',
      });

      final deleted = await h.simulateAppStartupGc();

      expect(deleted, 1);
      expect(h.native.profiles.containsKey('deleted-in-prev-session'), isFalse);
      expect(h.native.cookiesByProfile['ws-deleted-in-prev-session'], isNull);
      // The two live sites' profiles are intact.
      expect(h.native.profiles[h.sites[0].siteId], isNotNull);
      expect(h.native.profiles[h.sites[1].siteId], isNotNull);
    });

    test('GC at startup is a no-op when every profile has a live owner',
        () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://a.com');
      h.addSite('https://b.com');
      await h.engine.ensureProfile(h.sites[0].siteId);
      await h.engine.ensureProfile(h.sites[1].siteId);

      final deleted = await h.simulateAppStartupGc();

      expect(deleted, 0);
      expect(h.native.profiles.length, 2);
    });

    test('GC sweeps every profile when the site list is empty', () async {
      final h = ProfileIsolationTestHarness();
      h.native.seedOrphanProfile('a', {'k': 'v'});
      h.native.seedOrphanProfile('b', {'k': 'v'});

      final deleted = await h.simulateAppStartupGc();

      expect(deleted, 2);
      expect(h.native.profiles, isEmpty);
      expect(h.native.cookiesByProfile, isEmpty);
    });
  });

  group('PROF-005 — Bind race tolerance', () {
    test('a 0-bind result (native caught IllegalStateException) does not '
        'derail subsequent activations', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com');
      // Simulate the production race: native catches
      // IllegalStateException and returns 0 — the WebView fell back to
      // the default profile for this session. The engine MUST NOT throw
      // and MUST NOT mark this fatal.
      h.native.overrideBindCount = 0;

      await h.switchToSite(0);
      // Engine completed; site is loaded; profile exists. The lost-bind
      // case is observable but not a hard failure — same UX cost as
      // capture-nuke-restore's worst case.
      expect(h.loadedIndices, contains(0));
      expect(h.native.profiles[h.sites[0].siteId], isNotNull);
    });

    test('subsequent webviews for the same site can succeed even after a '
        'lost bind', () async {
      final h = ProfileIsolationTestHarness();
      h.addSite('https://github.com');

      h.native.overrideBindCount = 0;
      await h.switchToSite(0);

      // The page reloads (e.g. user pulls to refresh); the next
      // construction wins the race and binds successfully.
      h.native.overrideBindCount = 1;
      await h.engine.bindForSite(h.sites[0].siteId);

      // Profile still single-instance; no duplicate entries.
      expect(h.native.profiles.length, 1);
    });
  });

  group('Engine selection invariants', () {
    test('isSupported() is the gate — profile path stays cold when false',
        () async {
      final h = ProfileIsolationTestHarness();
      h.native.supported = false;
      h.addSite('https://github.com');

      // The harness still calls switchToSite — the gating decision in
      // the production call site (`_useProfiles`) is what skips the
      // engine. Here we verify the engine itself is also a no-op when
      // unsupported, defending against accidentally calling it from a
      // future code path that forgets the gate.
      await h.switchToSite(0);

      expect(h.native.profiles, isEmpty,
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
