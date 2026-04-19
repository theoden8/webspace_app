import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

/// In-memory cookie jar that models RFC 6265 domain-match semantics so the
/// sibling-subdomain scenarios the real fix addresses can actually be
/// exercised. Implements the real `CookieManager` interface so the engine
/// under test is unaware that it's talking to a mock.
///
/// Cookies are stored as a flat list. `getCookies(url)` returns cookies
/// whose Domain attribute matches per RFC 6265:
///   - cookie.domain equals url.host (host-only), OR
///   - cookie.domain is a parent of url.host (domain cookie — leading
///     `.` is optional per modern browsers)
/// plus path matching (cookie.path is a prefix of url.path).
class MockCookieManager implements CookieManager {
  final List<Cookie> _cookies = [];

  /// All cookies in the jar (for assertions).
  List<Cookie> get all => List.unmodifiable(_cookies);

  /// Unique domains present in the jar.
  Set<String> get domainsWithCookies => {
        for (final c in _cookies)
          if (c.domain != null) _canonical(c.domain!),
      };

  @override
  Future<List<Cookie>> getCookies({required Uri url}) async {
    final host = url.host.toLowerCase();
    final path = url.path.isEmpty ? '/' : url.path;
    return _cookies.where((c) {
      if (!_domainMatches(c.domain, host)) return false;
      if (!_pathMatches(c.path ?? '/', path)) return false;
      return true;
    }).toList();
  }

  @override
  Future<List<Cookie>> getAllCookies({List<Uri>? candidateUrls}) async {
    // The real iOS/macOS path ignores candidateUrls. On Android the wrapper
    // aggregates per-URL; for tests the mock returns everything so we don't
    // need to thread a platform switch through the tests.
    return List.from(_cookies);
  }

  @override
  Future<void> setCookie({
    required Uri url,
    required String name,
    required String value,
    String? domain,
    String? path,
    int? expiresDate,
    bool? isSecure,
    bool? isHttpOnly,
  }) async {
    final effectiveDomain = (domain ?? url.host).toLowerCase();
    final effectivePath = path ?? '/';
    _cookies.removeWhere((c) =>
        c.name == name &&
        _canonical(c.domain ?? '') == _canonical(effectiveDomain) &&
        (c.path ?? '/') == effectivePath);
    _cookies.add(Cookie(
      name: name,
      value: value,
      domain: effectiveDomain,
      path: effectivePath,
      expiresDate: expiresDate,
      isSecure: isSecure,
      isHttpOnly: isHttpOnly,
    ));
  }

  @override
  Future<void> deleteCookie({
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) async {
    final effectiveDomain = (domain ?? url.host).toLowerCase();
    final effectivePath = path ?? '/';
    _cookies.removeWhere((c) =>
        c.name == name &&
        _canonical(c.domain ?? '') == _canonical(effectiveDomain) &&
        (c.path ?? '/') == effectivePath);
  }

  @override
  Future<void> deleteAllCookies() async {
    _cookies.clear();
  }

  @override
  Future<void> deleteAllCookiesForUrl(Uri url) async {
    final cookies = await getCookies(url: url);
    for (final c in cookies) {
      await deleteCookie(url: url, name: c.name, domain: c.domain, path: c.path);
    }
  }

  /// Strip a leading `.` so `.google.com` and `google.com` compare equal.
  static String _canonical(String domain) {
    var d = domain.trim().toLowerCase();
    if (d.startsWith('.')) d = d.substring(1);
    return d;
  }

  /// RFC 6265 §5.1.3 domain-match.
  static bool _domainMatches(String? cookieDomain, String host) {
    if (cookieDomain == null || cookieDomain.isEmpty) return false;
    final d = _canonical(cookieDomain);
    final h = host.toLowerCase();
    if (d == h) return true;
    if (h.endsWith('.$d')) return true;
    return false;
  }

  /// RFC 6265 §5.1.4 path-match.
  static bool _pathMatches(String cookiePath, String requestPath) {
    if (cookiePath == requestPath) return true;
    if (requestPath.startsWith(cookiePath)) {
      if (cookiePath.endsWith('/')) return true;
      final next = requestPath.length > cookiePath.length
          ? requestPath[cookiePath.length]
          : '';
      if (next == '/') return true;
    }
    return false;
  }

  // CookieManager exposes a handful of other methods this mock doesn't need.
  // Route unimplemented calls through noSuchMethod so the type-level
  // `implements CookieManager` contract holds without us having to stub
  // every member.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// In-memory per-siteId cookie store implementing the real
/// `CookieSecureStorage` interface. Only the methods the engine touches
/// are meaningful; everything else routes through `noSuchMethod`.
class MockCookieSecureStorage implements CookieSecureStorage {
  final Map<String, List<Cookie>> _storage = {};

  @override
  Future<List<Cookie>> loadCookiesForSite(String siteId) async {
    return List.from(_storage[siteId] ?? const []);
  }

  @override
  Future<void> saveCookiesForSite(String siteId, List<Cookie> cookies) async {
    if (cookies.isEmpty) {
      _storage.remove(siteId);
    } else {
      _storage[siteId] = List.from(cookies);
    }
  }

  @override
  Future<void> removeOrphanedCookies(Set<String> activeSiteIds) async {
    _storage.removeWhere((siteId, _) => !activeSiteIds.contains(siteId));
  }

  Map<String, List<Cookie>> get allStorage => Map.from(_storage);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Test harness for cookie isolation. Delegates cookie-jar management to
/// the REAL [CookieIsolationEngine] — the tests exercise production code,
/// not duplicated harness code.
class CookieIsolationTestHarness {
  final MockCookieManager cookieManager = MockCookieManager();
  final MockCookieSecureStorage storage = MockCookieSecureStorage();
  late final CookieIsolationEngine engine = CookieIsolationEngine(
    cookieManager: cookieManager,
    storage: storage,
  );
  final List<WebViewModel> sites = [];
  final Set<int> loadedIndices = {};
  int? currentIndex;

  /// Monotonic counter mirroring `_setCurrentIndexVersion` in
  /// `_WebSpacePageState`. Every `switchToSite` call bumps it; the engine
  /// reads it via a closure so concurrent activations can bail.
  int version = 0;

  void addSite(String url, {String? name, bool incognito = false}) {
    sites.add(WebViewModel(
      initUrl: url,
      name: name,
      incognito: incognito,
    ));
  }

  /// Mirrors `_setCurrentIndex` in main.dart: bumps the version, unloads
  /// any same-base-domain conflicting site, then delegates cookie restore
  /// to the real engine.
  Future<void> switchToSite(int index) async {
    if (index < 0 || index >= sites.length) return;
    final v = ++version;

    final target = sites[index];
    if (!target.incognito) {
      final targetDomain = getBaseDomain(target.initUrl);
      for (final loadedIndex in List.from(loadedIndices)) {
        if (loadedIndex == index) continue;
        final loaded = sites[loadedIndex];
        if (loaded.incognito) continue;
        if (getBaseDomain(loaded.initUrl) == targetDomain) {
          await engine.unloadSiteForDomainSwitch(
            index: loadedIndex,
            models: sites,
            loadedIndices: loadedIndices,
          );
          if (v != version) return;
          break;
        }
      }
    }

    await engine.restoreCookiesForSite(
      index: index,
      models: sites,
      loadedIndices: loadedIndices,
      versionAtEntry: v,
      currentVersion: () => version,
    );
    if (v != version) return;

    currentIndex = index;
    loadedIndices.add(index);
  }

  /// Mirrors `_deleteSite` cookie/storage/state bookkeeping.
  Future<void> deleteSite(int index) async {
    final deletedModel = sites[index];
    await engine.preDeleteCookieCleanup(
      deletedModel: deletedModel,
      deletedIndex: index,
      models: sites,
      loadedIndices: loadedIndices,
    );

    sites.removeAt(index);
    loadedIndices.remove(index);
    loadedIndices.removeWhere((i) => i >= sites.length);
    final shifted = loadedIndices.map((i) => i > index ? i - 1 : i).toSet();
    loadedIndices
      ..clear()
      ..addAll(shifted);

    if (currentIndex == index) {
      currentIndex = null;
    } else if (currentIndex != null && currentIndex! > index) {
      currentIndex = currentIndex! - 1;
    }

    await storage.removeOrphanedCookies(
      sites.map((s) => s.siteId).toSet(),
    );
  }

  /// Mirrors the startup GC in `_restoreAppState`: orphan sweep on
  /// encrypted storage, then nuke the native cookie jar before first
  /// activation. Call this after seeding prior-session cookies to verify
  /// they don't leak into the next activated site.
  Future<void> simulateAppStartupGc() async {
    await storage.removeOrphanedCookies(
      sites.map((s) => s.siteId).toSet(),
    );
    await cookieManager.deleteAllCookies();
  }

  /// Go to the home screen — `currentIndex = null` but loaded webviews
  /// remain mounted.
  void goHome() {
    currentIndex = null;
  }

  /// Simulate a cold process restart: loaded state cleared, cookies
  /// in the native jar cleared, but encrypted storage persists.
  void simulateAppRestart() {
    loadedIndices.clear();
    currentIndex = null;
    for (final site in sites) {
      site.disposeWebView();
      site.cookies = [];
    }
  }

  /// Drops the site's siteId storage as if the user deleted it in a
  /// prior session — leaves the native jar cookies in place to model the
  /// leak scenario the fix targets.
  Future<void> simulateSitePurgedFromPriorSession(int index) async {
    final model = sites[index];
    await storage.saveCookiesForSite(model.siteId, const []);
    sites.removeAt(index);
    loadedIndices.remove(index);
    loadedIndices.removeWhere((i) => i >= sites.length);
    final shifted = loadedIndices.map((i) => i > index ? i - 1 : i).toSet();
    loadedIndices
      ..clear()
      ..addAll(shifted);
  }

  /// Simulate a site receiving cookies (e.g., after login).
  Future<void> simulateLogin(int index, List<Cookie> cookies) async {
    if (index < 0 || index >= sites.length) return;
    final model = sites[index];
    final url = Uri.parse(model.initUrl);

    for (final cookie in cookies) {
      await cookieManager.setCookie(
        url: url,
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path ?? '/',
      );
    }
    model.cookies = cookies;
  }

  /// Plant a cookie scoped to a specific subdomain (for sibling-subdomain
  /// tests). Use when the test needs a cookie whose domain isn't the
  /// site's initUrl host — e.g. `accounts.google.com` while the loaded
  /// site is `mail.google.com`.
  Future<void> plantCookie({
    required String url,
    required String name,
    required String value,
    required String domain,
    String path = '/',
  }) async {
    await cookieManager.setCookie(
      url: Uri.parse(url),
      name: name,
      value: value,
      domain: domain,
      path: path,
    );
  }
}

void main() {
  group('Cookie Isolation Integration', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('scenario: 3 sites, 2 same domain - only one same-domain site in CookieManager at a time', () async {
      // Setup: 3 sites
      // - Site 0: github.com/user1
      // - Site 1: github.com/user2
      // - Site 2: gitlab.com
      harness.addSite('https://github.com/user1', name: 'GitHub User1');
      harness.addSite('https://github.com/user2', name: 'GitHub User2');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      final site0 = harness.sites[0];
      final site1 = harness.sites[1];
      final site2 = harness.sites[2];

      // Step 1: Switch to site 0 (github user1)
      await harness.switchToSite(0);
      expect(harness.loadedIndices, contains(0));

      // Simulate login on site 0
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'user1_session', domain: 'github.com'),
        Cookie(name: 'user_id', value: '111', domain: 'github.com'),
      ]);

      // Verify: site 0's cookies are in CookieManager
      expect(harness.cookieManager.domainsWithCookies, contains('github.com'));
      var githubCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(githubCookies.any((c) => c.value == 'user1_session'), isTrue);

      // Step 2: Switch to site 2 (gitlab) - different domain, no conflict
      await harness.switchToSite(2);
      expect(harness.loadedIndices, containsAll([0, 2]));

      // Simulate login on site 2
      await harness.simulateLogin(2, [
        Cookie(name: 'gitlab_session', value: 'gitlab_abc', domain: 'gitlab.com'),
      ]);

      // Verify: both github and gitlab cookies in CookieManager
      expect(harness.cookieManager.domainsWithCookies, containsAll(['github.com', 'gitlab.com']));

      // Step 3: Switch to site 1 (github user2) - CONFLICT with site 0
      await harness.switchToSite(1);

      // Verify: site 0 was unloaded
      expect(harness.loadedIndices, isNot(contains(0)));
      expect(harness.loadedIndices, containsAll([1, 2]));

      // Verify: ALL cookies were cleared, then site 1 & 2's restored
      // Site 1 has no cookies yet (fresh), site 2's gitlab cookies should be restored
      // But since we cleared all, and only restored site1 (which has no stored cookies),
      // the CookieManager should be empty initially after switch
      // Actually, we need to also restore site 2's cookies...

      // The current implementation only restores the TARGET site's cookies.
      // Sites on different domains that were already loaded would need to be
      // re-restored. Let's verify the actual behavior:

      // Site 0's cookies should have been saved to storage
      var site0Saved = await harness.storage.loadCookiesForSite(site0.siteId);
      expect(site0Saved, hasLength(2));
      expect(site0Saved.any((c) => c.value == 'user1_session'), isTrue);

      // Site 2's cookies should also have been saved
      var site2Saved = await harness.storage.loadCookiesForSite(site2.siteId);
      expect(site2Saved, hasLength(1));
      expect(site2Saved[0].value, equals('gitlab_abc'));

      // Step 4: Login on site 1 (github user2)
      await harness.simulateLogin(1, [
        Cookie(name: 'session', value: 'user2_session', domain: 'github.com'),
        Cookie(name: 'user_id', value: '222', domain: 'github.com'),
      ]);

      // Verify: github cookies are now user2's
      githubCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(githubCookies.any((c) => c.value == 'user2_session'), isTrue);
      expect(githubCookies.any((c) => c.value == 'user1_session'), isFalse);

      // Step 5: Switch back to site 0 (github user1) - CONFLICT with site 1
      await harness.switchToSite(0);

      // Verify: site 1 was unloaded
      expect(harness.loadedIndices, isNot(contains(1)));
      expect(harness.loadedIndices, contains(0));

      // Site 1's cookies should have been saved
      var site1Saved = await harness.storage.loadCookiesForSite(site1.siteId);
      expect(site1Saved, hasLength(2));
      expect(site1Saved.any((c) => c.value == 'user2_session'), isTrue);

      // Site 0's cookies should have been restored
      githubCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(githubCookies.any((c) => c.value == 'user1_session'), isTrue);
      expect(githubCookies.any((c) => c.value == 'user2_session'), isFalse);
    });

    test('different domains do not conflict', () async {
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');
      harness.addSite('https://bitbucket.org', name: 'Bitbucket');

      // Load all three sites
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'gh_session', value: 'gh123', domain: 'github.com'),
      ]);

      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 'gl_session', value: 'gl456', domain: 'gitlab.com'),
      ]);

      await harness.switchToSite(2);
      await harness.simulateLogin(2, [
        Cookie(name: 'bb_session', value: 'bb789', domain: 'bitbucket.org'),
      ]);

      // All three should be loaded - no conflicts
      expect(harness.loadedIndices, containsAll([0, 1, 2]));

      // All cookies should be in manager
      expect(harness.cookieManager.domainsWithCookies, containsAll(['github.com', 'gitlab.com', 'bitbucket.org']));
    });

    test('subdomains of same second-level domain conflict', () async {
      harness.addSite('https://github.com', name: 'GitHub Main');
      harness.addSite('https://gist.github.com', name: 'GitHub Gist');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'main_session', value: 'main123', domain: 'github.com'),
      ]);

      expect(harness.loadedIndices, contains(0));

      // Switch to gist.github.com - should conflict
      await harness.switchToSite(1);

      // Site 0 should be unloaded
      expect(harness.loadedIndices, isNot(contains(0)));
      expect(harness.loadedIndices, contains(1));

      // Site 0's cookies should be saved
      var site0Saved = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(site0Saved, hasLength(1));
    });

    test('incognito sites do not participate in domain conflicts', () async {
      harness.addSite('https://github.com', name: 'GitHub Normal');
      harness.sites.add(WebViewModel(
        initUrl: 'https://github.com/private',
        name: 'GitHub Incognito',
        incognito: true,
      ));

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'normal123', domain: 'github.com'),
      ]);

      expect(harness.loadedIndices, contains(0));

      // Switch to incognito site - should NOT conflict (incognito doesn't participate)
      await harness.switchToSite(1);

      // Both should be loaded
      expect(harness.loadedIndices, containsAll([0, 1]));

      // Normal site's cookies should still be in manager
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'normal123'), isTrue);
    });

    test('cookie persistence across domain switches', () async {
      harness.addSite('https://github.com/account1', name: 'Account 1');
      harness.addSite('https://github.com/account2', name: 'Account 2');

      // Login to account 1
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'user', value: 'account1', domain: 'github.com'),
        Cookie(name: 'token', value: 'token_a1', domain: 'github.com'),
      ]);

      // Switch to account 2
      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 'user', value: 'account2', domain: 'github.com'),
        Cookie(name: 'token', value: 'token_a2', domain: 'github.com'),
      ]);

      // Switch back to account 1
      await harness.switchToSite(0);

      // Verify account 1's cookies are restored
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.name == 'user' && c.value == 'account1'), isTrue);
      expect(cookies.any((c) => c.name == 'token' && c.value == 'token_a1'), isTrue);

      // Account 2's cookies should NOT be in manager
      expect(cookies.any((c) => c.value == 'account2'), isFalse);
      expect(cookies.any((c) => c.value == 'token_a2'), isFalse);

      // But account 2's cookies should be saved in storage
      var account2Saved = await harness.storage.loadCookiesForSite(harness.sites[1].siteId);
      expect(account2Saved.any((c) => c.value == 'account2'), isTrue);
    });

    test('new site on same domain starts with clean cookies', () async {
      harness.addSite('https://github.com/existing', name: 'Existing Account');

      // Login to existing account
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'existing_session', domain: 'github.com'),
      ]);

      // Add a new site on the same domain
      harness.addSite('https://github.com/new', name: 'New Account');

      // Switch to new site
      await harness.switchToSite(1);

      // New site should have no cookies (hasn't logged in yet)
      var newSiteCookies = await harness.storage.loadCookiesForSite(harness.sites[1].siteId);
      expect(newSiteCookies, isEmpty);

      // CookieManager should be cleared (existing site's cookies removed)
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'existing_session'), isFalse);

      // But existing site's cookies should be saved
      var existingSaved = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(existingSaved.any((c) => c.value == 'existing_session'), isTrue);
    });

    test('third-party domain site always accessible alongside same-domain conflicts', () async {
      // This is the exact scenario from the user's request:
      // 3 sites, 2 same domain - CookieManager has third site + one of the same-domain sites

      harness.addSite('https://github.com/user1', name: 'GitHub 1');
      harness.addSite('https://github.com/user2', name: 'GitHub 2');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      // Load GitLab first
      await harness.switchToSite(2);
      await harness.simulateLogin(2, [
        Cookie(name: 'gitlab_auth', value: 'gl_token', domain: 'gitlab.com'),
      ]);

      // Load GitHub 1
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'github_auth', value: 'gh_user1', domain: 'github.com'),
      ]);

      // Verify: GitLab + GitHub 1 both in manager
      expect(harness.cookieManager.domainsWithCookies, containsAll(['gitlab.com', 'github.com']));
      expect(harness.loadedIndices, containsAll([0, 2]));

      // Switch to GitHub 2 - GitHub 1 should be unloaded, GitLab preserved
      await harness.switchToSite(1);

      // Verify: GitHub 1 unloaded
      expect(harness.loadedIndices, isNot(contains(0)));
      expect(harness.loadedIndices, containsAll([1, 2]));

      // GitLab cookies should have been captured and saved during the switch
      var gitlabSaved = await harness.storage.loadCookiesForSite(harness.sites[2].siteId);
      expect(gitlabSaved.any((c) => c.value == 'gl_token'), isTrue);

      // GitHub 1 cookies should have been saved
      var gh1Saved = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(gh1Saved.any((c) => c.value == 'gh_user1'), isTrue);

      // Login to GitHub 2
      await harness.simulateLogin(1, [
        Cookie(name: 'github_auth', value: 'gh_user2', domain: 'github.com'),
      ]);

      // Verify final state: GitHub 2 active, no GitHub 1 cookies
      var ghCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(ghCookies.any((c) => c.value == 'gh_user2'), isTrue);
      expect(ghCookies.any((c) => c.value == 'gh_user1'), isFalse);
    });
  });

  group('Site Deletion Cookie Cleanup', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('deleting sole site on domain clears cookie jar', () async {
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'li_at', value: 'auth_token', domain: 'linkedin.com'),
        Cookie(name: 'JSESSIONID', value: 'session123', domain: 'linkedin.com'),
      ]);

      // Verify cookies are in jar
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://linkedin.com'));
      expect(cookies, hasLength(2));

      final siteId = harness.sites[0].siteId;
      await harness.storage.saveCookiesForSite(siteId, harness.sites[0].cookies);

      // Delete the site
      await harness.deleteSite(0);

      // Cookie jar should be cleared for this domain
      cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://linkedin.com'));
      expect(cookies, isEmpty);

      // Secure storage should be cleared for this siteId
      var stored = await harness.storage.loadCookiesForSite(siteId);
      expect(stored, isEmpty);
    });

    test('deleting one of multiple same-domain sites preserves surviving site live session', () async {
      harness.addSite('https://github.com/personal', name: 'GitHub Personal');
      harness.addSite('https://github.com/work', name: 'GitHub Work');

      // Login to personal account
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'personal_session', domain: 'github.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, harness.sites[0].cookies);

      // Switch to work account (unloads personal, restores work's)
      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 'session', value: 'work_session', domain: 'github.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[1].siteId, harness.sites[1].cookies);

      final personalSiteId = harness.sites[0].siteId;
      final workSiteId = harness.sites[1].siteId;

      // Delete personal. Work is the active loaded site with a live
      // github.com session in the native jar. Delete must NOT wipe that.
      await harness.deleteSite(0);

      // Work's live session preserved in native jar (snapshot+restore).
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'work_session'), isTrue,
          reason: 'work\'s live session must not be wiped when deleting personal');
      expect(cookies.any((c) => c.value == 'personal_session'), isFalse);

      // Personal secure storage cleared
      var personalStored = await harness.storage.loadCookiesForSite(personalSiteId);
      expect(personalStored, isEmpty);

      // Work secure storage intact
      var workStored = await harness.storage.loadCookiesForSite(workSiteId);
      expect(workStored, hasLength(1));
      expect(workStored[0].value, equals('work_session'));
    });

    test('re-adding deleted site starts with no cookies', () async {
      harness.addSite('https://linkedin.com', name: 'LinkedIn');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'li_at', value: 'auth_token', domain: 'linkedin.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, harness.sites[0].cookies);

      // Delete
      await harness.deleteSite(0);

      // Re-add LinkedIn
      harness.addSite('https://linkedin.com', name: 'LinkedIn New');
      await harness.switchToSite(0);

      // New site should have no cookies in jar or storage
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://linkedin.com'));
      expect(cookies, isEmpty);

      var stored = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(stored, isEmpty);
    });

    test('deleting site does not affect unrelated domains', () async {
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'gh_session', value: 'gh123', domain: 'github.com'),
      ]);

      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 'gl_session', value: 'gl456', domain: 'gitlab.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[1].siteId, harness.sites[1].cookies);

      final gitlabSiteId = harness.sites[1].siteId;

      // Delete GitHub
      await harness.deleteSite(0);

      // GitLab cookies should be unaffected
      var glCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://gitlab.com'));
      expect(glCookies, hasLength(1));
      expect(glCookies[0].value, equals('gl456'));

      var glStored = await harness.storage.loadCookiesForSite(gitlabSiteId);
      expect(glStored, hasLength(1));
    });
  });

  group('Domain Detection for Cookie Isolation', () {
    test('getBaseDomain correctly identifies conflicting domains', () {
      // Same second-level domain = conflict
      expect(getBaseDomain('https://github.com'), equals('github.com'));
      expect(getBaseDomain('https://gist.github.com'), equals('github.com'));
      expect(getBaseDomain('https://api.github.com'), equals('github.com'));

      // Different second-level domains = no conflict
      expect(getBaseDomain('https://gitlab.com'), equals('gitlab.com'));
      expect(getBaseDomain('https://bitbucket.org'), equals('bitbucket.org'));
    });

    test('multi-part TLDs are handled correctly', () {
      // Same company, same conflict
      expect(getBaseDomain('https://amazon.co.uk'), equals('amazon.co.uk'));
      expect(getBaseDomain('https://www.amazon.co.uk'), equals('amazon.co.uk'));

      // Different companies, no conflict
      expect(getBaseDomain('https://bbc.co.uk'), equals('bbc.co.uk'));
    });

    test('IP addresses are returned as-is', () {
      expect(getBaseDomain('http://192.168.1.1:8080'), equals('192.168.1.1'));
      expect(getBaseDomain('http://10.0.0.1:3000'), equals('10.0.0.1'));
      expect(getBaseDomain('http://127.0.0.1'), equals('127.0.0.1'));
    });
  });

  group('IP Address Cookie Isolation', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('two sites on same IP address should conflict', () async {
      harness.addSite('http://192.168.1.1:8080/app1', name: 'Local App 1');
      harness.addSite('http://192.168.1.1:8080/app2', name: 'Local App 2');

      // Login to app 1
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'app1_session', domain: '192.168.1.1'),
      ]);

      expect(harness.loadedIndices, contains(0));

      // Switch to app 2 - should conflict (same IP)
      await harness.switchToSite(1);

      // App 1 should be unloaded
      expect(harness.loadedIndices, isNot(contains(0)));
      expect(harness.loadedIndices, contains(1));

      // App 1's cookies should be saved
      var app1Saved = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(app1Saved.any((c) => c.value == 'app1_session'), isTrue);
    });

    test('sites on different IP addresses should not conflict', () async {
      harness.addSite('http://192.168.1.1:8080', name: 'Server 1');
      harness.addSite('http://192.168.1.2:8080', name: 'Server 2');
      harness.addSite('http://10.0.0.1:3000', name: 'Server 3');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 's1', value: 'server1', domain: '192.168.1.1'),
      ]);

      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 's2', value: 'server2', domain: '192.168.1.2'),
      ]);

      await harness.switchToSite(2);
      await harness.simulateLogin(2, [
        Cookie(name: 's3', value: 'server3', domain: '10.0.0.1'),
      ]);

      // All three should be loaded - different IPs
      expect(harness.loadedIndices, containsAll([0, 1, 2]));
      expect(harness.cookieManager.domainsWithCookies, containsAll(['192.168.1.1', '192.168.1.2', '10.0.0.1']));
    });

    test('IP site and domain site should not conflict', () async {
      harness.addSite('http://192.168.1.1:8080', name: 'Local Server');
      harness.addSite('https://github.com', name: 'GitHub');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'local', value: 'local_session', domain: '192.168.1.1'),
      ]);

      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 'gh', value: 'github_session', domain: 'github.com'),
      ]);

      // Both should be loaded
      expect(harness.loadedIndices, containsAll([0, 1]));
      expect(harness.cookieManager.domainsWithCookies, containsAll(['192.168.1.1', 'github.com']));
    });
  });

  group('Home Screen on App Reopen', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('goHome sets currentIndex to null without unloading webviews', () async {
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      await harness.switchToSite(0);
      await harness.switchToSite(1);
      expect(harness.loadedIndices, containsAll([0, 1]));

      harness.goHome();

      expect(harness.currentIndex, isNull);
      expect(harness.loadedIndices, containsAll([0, 1])); // webviews still alive
    });

    test('goHome does not clear cookies from CookieManager', () async {
      harness.addSite('https://github.com', name: 'GitHub');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'gh_token', domain: 'github.com'),
      ]);

      harness.goHome();

      // Cookies still live in the manager - webview is still running
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'gh_token'), isTrue);
    });

    test('switching back to a site after goHome works normally', () async {
      harness.addSite('https://github.com', name: 'GitHub');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'gh_token', domain: 'github.com'),
      ]);

      harness.goHome();
      expect(harness.currentIndex, isNull);

      // Switch back - should succeed, index becomes 0 again
      await harness.switchToSite(0);
      expect(harness.currentIndex, equals(0));
      expect(harness.loadedIndices, contains(0));

      // Cookies intact
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'gh_token'), isTrue);
    });

    test('goHome then switching to conflicting domain still triggers isolation', () async {
      harness.addSite('https://github.com/user1', name: 'GitHub User1');
      harness.addSite('https://github.com/user2', name: 'GitHub User2');

      // Login to user1
      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'user1_token', domain: 'github.com'),
      ]);

      // Go home (background resume)
      harness.goHome();
      expect(harness.loadedIndices, contains(0)); // still loaded

      // Switch to user2 - should detect conflict with user1 and save/clear cookies
      await harness.switchToSite(1);

      expect(harness.loadedIndices, isNot(contains(0))); // user1 unloaded
      expect(harness.loadedIndices, contains(1));

      // user1's cookies must have been saved before clearing
      var user1Saved = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(user1Saved.any((c) => c.value == 'user1_token'), isTrue);

      // user2 has no cookies yet (fresh)
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'user1_token'), isFalse);
    });

    test('goHome then switching to non-conflicting domain keeps all loaded sites', () async {
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'gh', value: 'gh_token', domain: 'github.com'),
      ]);

      harness.goHome();

      await harness.switchToSite(1);

      // No conflict - github still loaded
      expect(harness.loadedIndices, containsAll([0, 1]));

      // GitHub cookies still live
      var ghCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(ghCookies.any((c) => c.value == 'gh_token'), isTrue);
    });
  });

  group('App Restart Cookie Isolation', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('app restart clears loaded state and shows home screen', () async {
      harness.addSite('https://github.com', name: 'GitHub');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'session', value: 'gh_token', domain: 'github.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, harness.sites[0].cookies);

      harness.simulateAppRestart();

      expect(harness.currentIndex, isNull);       // home screen
      expect(harness.loadedIndices, isEmpty);     // no webviews loaded
    });

    test('after restart, switching to site restores cookies from secure storage', () async {
      harness.addSite('https://github.com', name: 'GitHub');

      // Pre-populate secure storage (as if saved before the restart)
      final siteId = harness.sites[0].siteId;
      await harness.storage.saveCookiesForSite(siteId, [
        Cookie(name: 'session', value: 'persisted_token', domain: 'github.com'),
      ]);

      harness.simulateAppRestart();

      // Now user picks the site from home screen
      await harness.switchToSite(0);

      expect(harness.currentIndex, equals(0));
      expect(harness.loadedIndices, contains(0));

      // Cookies should be restored from secure storage
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'persisted_token'), isTrue);
    });

    test('after restart, two conflicting sites still isolate correctly', () async {
      harness.addSite('https://github.com/user1', name: 'GitHub User1');
      harness.addSite('https://github.com/user2', name: 'GitHub User2');

      // Simulate cookies saved before restart
      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, [
        Cookie(name: 'session', value: 'user1_token', domain: 'github.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[1].siteId, [
        Cookie(name: 'session', value: 'user2_token', domain: 'github.com'),
      ]);

      harness.simulateAppRestart();

      // Open user1 from home screen
      await harness.switchToSite(0);
      var cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'user1_token'), isTrue);
      expect(cookies.any((c) => c.value == 'user2_token'), isFalse);

      // Go home, then open user2 - conflict triggers
      harness.goHome();
      await harness.switchToSite(1);

      cookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      expect(cookies.any((c) => c.value == 'user2_token'), isTrue);
      expect(cookies.any((c) => c.value == 'user1_token'), isFalse);

      // user1 unloaded
      expect(harness.loadedIndices, isNot(contains(0)));
      expect(harness.loadedIndices, contains(1));
    });

    test('after restart, non-conflicting sites can both be loaded without isolation', () async {
      harness.addSite('https://github.com', name: 'GitHub');
      harness.addSite('https://gitlab.com', name: 'GitLab');

      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, [
        Cookie(name: 'gh', value: 'gh_token', domain: 'github.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[1].siteId, [
        Cookie(name: 'gl', value: 'gl_token', domain: 'gitlab.com'),
      ]);

      harness.simulateAppRestart();

      await harness.switchToSite(0);
      await harness.switchToSite(1);

      // Both loaded, no conflict
      expect(harness.loadedIndices, containsAll([0, 1]));

      var ghCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://github.com'));
      var glCookies = await harness.cookieManager.getCookies(url: Uri.parse('https://gitlab.com'));
      expect(ghCookies.any((c) => c.value == 'gh_token'), isTrue);
      expect(glCookies.any((c) => c.value == 'gl_token'), isTrue);
    });
  });

  // ==========================================================================
  // Sibling-Subdomain Cookie Handling (C-2)
  //
  // These scenarios exercise the bug class the user originally reported:
  // cookies scoped to a sibling subdomain (e.g. `accounts.google.com`) of
  // a loaded site's base domain (`google.com`) must be captured across the
  // nuke-and-restore cycle, and must not leak from a deleted site into a
  // freshly-added site sharing the base domain.
  // ==========================================================================
  group('Sibling-subdomain cookies', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('Cookie on sibling subdomain (accounts.google.com) is captured for site on mail.google.com', () async {
      harness.addSite('https://mail.google.com', name: 'Gmail');
      harness.addSite('https://example.com', name: 'Example');

      // Activate Gmail and plant a sibling-subdomain cookie AFTER
      // activation — simulating the site's own navigation to accounts.google.com.
      await harness.switchToSite(0);
      await harness.plantCookie(
        url: 'https://accounts.google.com/signin',
        name: 'SSID',
        value: 'google_sso_token',
        domain: 'accounts.google.com',
      );

      // A pure URL-scoped `getCookies(mail.google.com)` wouldn't return this
      // cookie — it's scoped to a sibling subdomain. The engine's capture
      // uses getAllCookies() so it WILL be attributed to the Gmail site.

      // Switch to Example (different base domain). This triggers the
      // capture loop over loaded sites.
      await harness.switchToSite(1);

      // Verify: Gmail's cookies in storage include the accounts.google.com SSO.
      final gmailSiteId = harness.sites[0].siteId;
      final stored = await harness.storage.loadCookiesForSite(gmailSiteId);
      expect(
        stored.any((c) => c.name == 'SSID' && c.value == 'google_sso_token'),
        isTrue,
        reason: 'sibling-subdomain cookie must be captured before nuke',
      );

      // Switch back to Gmail. The engine restores from storage — the SSO
      // cookie must be back in the native jar.
      await harness.switchToSite(0);
      final ssoCookies = await harness.cookieManager.getCookies(
        url: Uri.parse('https://accounts.google.com/signin'),
      );
      expect(
        ssoCookies.any((c) => c.name == 'SSID' && c.value == 'google_sso_token'),
        isTrue,
        reason: 'sibling-subdomain cookie must survive switch-away-and-back',
      );
    });

    test('Cookies with Domain=.google.com are attributed to a google.com-base site', () async {
      harness.addSite('https://mail.google.com', name: 'Gmail');

      await harness.switchToSite(0);
      // Host-agnostic domain cookie — applies to every google.com subdomain.
      await harness.plantCookie(
        url: 'https://mail.google.com',
        name: 'HSID',
        value: 'sso_hsid',
        domain: '.google.com',
      );

      // Force a capture-and-restore cycle by switching away and back.
      harness.addSite('https://example.com', name: 'Example');
      await harness.switchToSite(1);

      final stored = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(stored.any((c) => c.name == 'HSID' && c.value == 'sso_hsid'), isTrue,
          reason: '.google.com cookie must attribute to google.com base site');
    });

    test('Original bug: deleted mail.google.com leaks accounts.google.com session into new play.google.com', () async {
      // Reproduces the exact scenario from the bug report.
      harness.addSite('https://mail.google.com', name: 'Gmail');

      await harness.switchToSite(0);
      // Gmail logs in and picks up sibling-subdomain SSO cookies.
      await harness.plantCookie(
        url: 'https://accounts.google.com/signin',
        name: 'SSID',
        value: 'google_user_session',
        domain: 'accounts.google.com',
      );
      await harness.plantCookie(
        url: 'https://mail.google.com',
        name: 'HSID',
        value: 'sso_hsid',
        domain: '.google.com',
      );

      // User deletes Gmail. The preDeleteCookieCleanup path must evict the
      // sibling-subdomain cookies too — otherwise a fresh play.google.com
      // site would inherit them.
      await harness.deleteSite(0);

      // Add the brand-new play.google.com site and activate it.
      harness.addSite('https://play.google.com/console', name: 'Play Console');
      await harness.switchToSite(0);

      // No cookies should leak into the new site.
      final accountsCookies = await harness.cookieManager.getCookies(
        url: Uri.parse('https://accounts.google.com/signin'),
      );
      final playCookies = await harness.cookieManager.getCookies(
        url: Uri.parse('https://play.google.com/console'),
      );
      expect(accountsCookies, isEmpty,
          reason: 'accounts.google.com cookies from deleted Gmail must not leak');
      expect(playCookies, isEmpty,
          reason: '.google.com cookies from deleted Gmail must not leak');

      // Encrypted storage for the new site must also be empty.
      final newStored = await harness.storage.loadCookiesForSite(harness.sites[0].siteId);
      expect(newStored, isEmpty);
    });

    test('Cookies on unrelated domains survive when an unrelated site is deleted', () async {
      harness.addSite('https://mail.google.com', name: 'Gmail');
      harness.addSite('https://github.com', name: 'GitHub');

      await harness.switchToSite(0);
      await harness.plantCookie(
        url: 'https://accounts.google.com/signin',
        name: 'SSID',
        value: 'google_sso',
        domain: 'accounts.google.com',
      );

      // Switching to GitHub captures Gmail's live cookies into storage
      // (SSID ends up under Gmail's siteId via base-domain attribution).
      await harness.switchToSite(1);

      final gmailSiteId = harness.sites[0].siteId;
      var gmailStored = await harness.storage.loadCookiesForSite(gmailSiteId);
      expect(gmailStored.any((c) => c.name == 'SSID' && c.value == 'google_sso'), isTrue,
          reason: 'precondition: Gmail\'s SSID captured on switch-away');

      await harness.simulateLogin(1, [
        Cookie(name: 'gh_session', value: 'gh_token', domain: 'github.com'),
      ]);

      // Delete GitHub. Gmail's siteId storage must NOT be touched — the
      // deletion is for a different base domain.
      await harness.deleteSite(1);

      gmailStored = await harness.storage.loadCookiesForSite(gmailSiteId);
      expect(gmailStored.any((c) => c.name == 'SSID' && c.value == 'google_sso'), isTrue,
          reason: 'deleting github.com must not evict google.com sibling-subdomain cookies');
    });
  });

  // ==========================================================================
  // Garbage Collection: orphan sweep on delete, startup native-jar nuke,
  // and prior-session-leak prevention.
  // ==========================================================================
  group('Garbage collection', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('deleteSite sweeps orphaned siteId storage', () async {
      harness.addSite('https://example.com', name: 'Example');
      harness.addSite('https://github.com', name: 'GitHub');

      await harness.switchToSite(0);
      await harness.simulateLogin(0, [
        Cookie(name: 'ex', value: 'ex_val', domain: 'example.com'),
      ]);
      final exampleSiteId = harness.sites[0].siteId;

      // Persist GitHub's login directly to storage — mirrors what the
      // production `onCookiesChanged` handler would do on a real page load.
      await harness.switchToSite(1);
      await harness.simulateLogin(1, [
        Cookie(name: 'gh', value: 'gh_val', domain: 'github.com'),
      ]);
      final githubSiteId = harness.sites[1].siteId;
      await harness.storage.saveCookiesForSite(githubSiteId, harness.sites[1].cookies);

      // Seed a stale entry to prove the orphan sweep actually runs on delete.
      const stale = 'stale-from-prior-session';
      await harness.storage.saveCookiesForSite(stale, [
        Cookie(name: 'x', value: 'y', domain: 'deleted.example.com'),
      ]);
      expect(harness.storage.allStorage.keys,
          containsAll([exampleSiteId, githubSiteId, stale]));

      await harness.deleteSite(0);

      // Post-delete: Example's entry is gone (explicit), the stale entry is
      // gone (orphan sweep), GitHub's entry survives.
      expect(harness.storage.allStorage.keys, isNot(contains(exampleSiteId)));
      expect(harness.storage.allStorage.keys, isNot(contains(stale)));
      expect(harness.storage.allStorage.keys, contains(githubSiteId));
    });

    test('orphan sweep removes entries whose siteId no longer corresponds to any site', () async {
      harness.addSite('https://example.com', name: 'Example');
      await harness.switchToSite(0);
      final liveSiteId = harness.sites[0].siteId;

      // Seed a real entry for the live site (production's onCookiesChanged
      // handler would save after a page load).
      await harness.storage.saveCookiesForSite(liveSiteId, [
        Cookie(name: 'live', value: 'v', domain: 'example.com'),
      ]);

      // Seed a stale entry as if a site was deleted in a prior session
      // without the orphan sweep ever running (pre-fix state).
      await harness.storage.saveCookiesForSite('stale-site-id-from-prior-session', [
        Cookie(name: 'leftover', value: 'old', domain: 'deleted.example.com'),
      ]);
      expect(harness.storage.allStorage.keys,
          containsAll([liveSiteId, 'stale-site-id-from-prior-session']));

      await harness.storage.removeOrphanedCookies(
        harness.sites.map((s) => s.siteId).toSet(),
      );

      expect(harness.storage.allStorage.keys, isNot(contains('stale-site-id-from-prior-session')));
      expect(harness.storage.allStorage.keys, contains(liveSiteId));
    });

    test('Startup GC evicts cookies from a prior-session deleted site before first activation', () async {
      // Simulate a prior session: user had a Gmail site, logged in (cookies
      // landed in native jar and storage), then deleted without the fix's
      // native-jar cleanup ever running.
      harness.addSite('https://mail.google.com', name: 'Gmail');
      await harness.switchToSite(0);
      await harness.plantCookie(
        url: 'https://accounts.google.com/signin',
        name: 'SSID',
        value: 'prior_session_sso',
        domain: 'accounts.google.com',
      );

      // "Prior session" ends: drop the site's storage entry but leave the
      // cookies in the native jar (the pre-fix bug state).
      await harness.simulateSitePurgedFromPriorSession(0);
      expect(harness.cookieManager.all.any((c) => c.name == 'SSID'), isTrue,
          reason: 'prior-session cookies still in native jar before startup GC');

      // App launches for a new session. Startup GC runs.
      harness.simulateAppRestart();
      await harness.simulateAppStartupGc();

      // User adds a brand-new play.google.com and activates it.
      harness.addSite('https://play.google.com/console', name: 'Play Console');
      await harness.switchToSite(0);

      // No leak — the new site sees a pristine native jar.
      final leak = await harness.cookieManager.getCookies(
        url: Uri.parse('https://accounts.google.com/signin'),
      );
      expect(leak, isEmpty,
          reason: 'startup GC must evict accounts.google.com cookies from prior-session Gmail');
    });
  });

  // ==========================================================================
  // Concurrency: the engine's version-guard mechanism must serialize
  // rapid, overlapping activations.
  // ==========================================================================
  group('Concurrent activation version guard', () {
    late CookieIsolationTestHarness harness;

    setUp(() {
      harness = CookieIsolationTestHarness();
    });

    test('stale activation bails before mutating state when a newer activation bumps the version', () async {
      harness.addSite('https://example.com', name: 'Example');
      harness.addSite('https://github.com', name: 'GitHub');

      // Seed per-site storage so each activation has something to restore.
      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, [
        Cookie(name: 'ex', value: 'example_persisted', domain: 'example.com'),
      ]);
      await harness.storage.saveCookiesForSite(harness.sites[1].siteId, [
        Cookie(name: 'gh', value: 'github_persisted', domain: 'github.com'),
      ]);

      // Version captured at entry = 1. A "newer" caller bumps to 2 before
      // the restore completes — the engine must abort and leave the jar
      // untouched.
      final staleVersion = ++harness.version; // v=1, the "stale" call
      ++harness.version; // v=2, the "newer" call bumps it right away

      await harness.engine.restoreCookiesForSite(
        index: 0,
        models: harness.sites,
        loadedIndices: harness.loadedIndices,
        versionAtEntry: staleVersion,
        currentVersion: () => harness.version,
      );

      // Stale run bailed at the first version check — nothing was restored
      // to the native jar from example.com's storage.
      final ex = await harness.cookieManager.getCookies(
        url: Uri.parse('https://example.com'),
      );
      expect(ex.any((c) => c.value == 'example_persisted'), isFalse,
          reason: 'stale activation must not restore its cookies after a newer one supersedes it');
    });

    test('current activation completes when version is stable', () async {
      harness.addSite('https://example.com', name: 'Example');
      await harness.storage.saveCookiesForSite(harness.sites[0].siteId, [
        Cookie(name: 'ex', value: 'example_val', domain: 'example.com'),
      ]);

      final v = ++harness.version;
      await harness.engine.restoreCookiesForSite(
        index: 0,
        models: harness.sites,
        loadedIndices: harness.loadedIndices,
        versionAtEntry: v,
        currentVersion: () => harness.version,
      );

      final ex = await harness.cookieManager.getCookies(
        url: Uri.parse('https://example.com'),
      );
      expect(ex.any((c) => c.value == 'example_val'), isTrue);
    });
  });

  // ==========================================================================
  // Domain-match helper — direct unit test of the pure function.
  // ==========================================================================
  group('cookieMatchesBaseDomain', () {
    Cookie c(String? domain) => Cookie(name: 'x', value: 'y', domain: domain);

    test('exact match', () {
      expect(cookieMatchesBaseDomain(c('google.com'), 'google.com'), isTrue);
    });

    test('subdomain match', () {
      expect(cookieMatchesBaseDomain(c('mail.google.com'), 'google.com'), isTrue);
      expect(cookieMatchesBaseDomain(c('accounts.google.com'), 'google.com'), isTrue);
    });

    test('leading-dot domain match', () {
      expect(cookieMatchesBaseDomain(c('.google.com'), 'google.com'), isTrue);
    });

    test('case-insensitive', () {
      expect(cookieMatchesBaseDomain(c('Mail.GOOGLE.com'), 'GOOGLE.com'), isTrue);
    });

    test('no match on unrelated domain', () {
      expect(cookieMatchesBaseDomain(c('googlethief.com'), 'google.com'), isFalse);
      expect(cookieMatchesBaseDomain(c('evilgoogle.com'), 'google.com'), isFalse);
    });

    test('null / empty domain never matches', () {
      expect(cookieMatchesBaseDomain(c(null), 'google.com'), isFalse);
      expect(cookieMatchesBaseDomain(c(''), 'google.com'), isFalse);
      expect(cookieMatchesBaseDomain(c('google.com'), ''), isFalse);
    });

    test('multi-part TLD', () {
      expect(cookieMatchesBaseDomain(c('bbc.co.uk'), 'bbc.co.uk'), isTrue);
      expect(cookieMatchesBaseDomain(c('news.bbc.co.uk'), 'bbc.co.uk'), isTrue);
      expect(cookieMatchesBaseDomain(c('bbc.co.uk'), 'amazon.co.uk'), isFalse);
    });

    test('IP address', () {
      expect(cookieMatchesBaseDomain(c('192.168.1.1'), '192.168.1.1'), isTrue);
      expect(cookieMatchesBaseDomain(c('192.168.1.2'), '192.168.1.1'), isFalse);
    });
  });
}
