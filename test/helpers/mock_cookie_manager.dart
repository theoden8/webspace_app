import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/cookie_manager.dart';

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
      if (!_domainMatches(c.domain, host: host)) return false;
      if (!_pathMatches(c.path ?? '/', requestPath: path)) return false;
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
  static bool _domainMatches(String? cookieDomain, {required String host}) {
    if (cookieDomain == null || cookieDomain.isEmpty) return false;
    final d = _canonical(cookieDomain);
    final h = host.toLowerCase();
    if (d == h) return true;
    if (h.endsWith('.$d')) return true;
    return false;
  }

  /// RFC 6265 §5.1.4 path-match.
  static bool _pathMatches(String cookiePath, {required String requestPath}) {
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

/// Cookie manager that models ANDROID's URL-scoped native cookie API, unlike
/// the permissive [MockCookieManager] whose `getAllCookies` returns the whole
/// jar. On Android the wrapper aggregates `getCookies(url)` over a fixed set
/// of candidate URLs (there is no "dump every cookie" primitive), so a cookie
/// on a host that isn't reachable from any candidate URL is invisible to a
/// capture — and `setCookie` drops a cookie whose Domain isn't a suffix of the
/// request URL host. This makes the legacy engine's sibling-subdomain
/// host-only-cookie loss observable in tests instead of hidden.
///
/// Legacy engine only: the container engine (the default for Android
/// `MULTI_PROFILE`,
/// iOS 17+, macOS 14+, Linux WPE 2.40+ — i.e. most users) owns each site's
/// cookies in a native per-site store and never runs this URL-scoped
/// capture-nuke-restore, so it is not subject to this limitation.
class AndroidScopedCookieManager extends MockCookieManager {
  @override
  Future<List<Cookie>> getAllCookies({List<Uri>? candidateUrls}) async {
    if (candidateUrls == null || candidateUrls.isEmpty) {
      return super.getAllCookies();
    }
    final seen = <String>{};
    final result = <Cookie>[];
    for (final url in candidateUrls) {
      for (final c in await getCookies(url: url)) {
        if (seen.add('${c.name}|${c.domain}|${c.path}')) result.add(c);
      }
    }
    return result;
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
    // Android's CookieManager.setCookie stores against the URL and drops a
    // cookie whose Domain attribute isn't the URL host or a parent of it.
    if (domain != null &&
        !MockCookieManager._domainMatches(domain,
            host: url.host.toLowerCase())) {
      return;
    }
    await super.setCookie(
      url: url,
      name: name,
      value: value,
      domain: domain,
      path: path,
      expiresDate: expiresDate,
      isSecure: isSecure,
      isHttpOnly: isHttpOnly,
    );
  }
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
  Future<void> saveCookiesForSite(String siteId,
      {required List<Cookie> cookies}) async {
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
