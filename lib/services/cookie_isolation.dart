import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

/// Returns true if `cookie.domain` falls under `baseDomain` per standard
/// HTTP cookie domain-match semantics (exact match or any subdomain).
/// Leading `.` is stripped before comparison.
bool cookieMatchesBaseDomain(Cookie cookie, String baseDomain) {
  var domain = (cookie.domain ?? '').trim().toLowerCase();
  if (domain.isEmpty || baseDomain.isEmpty) return false;
  if (domain.startsWith('.')) domain = domain.substring(1);
  final base = baseDomain.toLowerCase();
  return domain == base || domain.endsWith('.$base');
}

/// Pure cookie-isolation logic, extracted so tests can exercise the real
/// code with mocked [CookieManager] and [CookieSecureStorage] instead of
/// re-implementing the orchestration in a test harness.
///
/// The engine is stateless; it operates on mutable state (`models`,
/// `loadedIndices`) passed into each method. All native cookie-jar writes
/// go through [cookieManager]; all per-site persistence goes through
/// [storage]. Concurrency is serialized by an optional version check —
/// callers pass a version captured at entry and a current-version getter;
/// if they diverge, the operation bails early.
class CookieIsolationEngine {
  final CookieManager cookieManager;
  final CookieSecureStorage storage;

  CookieIsolationEngine({
    required this.cookieManager,
    required this.storage,
  });

  /// Captures the conflicting site's cookies to siteId-keyed storage (last
  /// chance — the webview is about to be disposed), then disposes it and
  /// removes it from `loadedIndices`.
  ///
  /// The native cookie jar is NOT nuked here. Callers MUST invoke
  /// [restoreCookiesForSite] immediately after so the jar is wiped and the
  /// target's cookies are restored in the same transaction.
  Future<void> unloadSiteForDomainSwitch({
    required int index,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) async {
    if (index < 0 || index >= models.length) return;

    final model = models[index];
    LogService.instance.log(
      'CookieIsolation',
      'Unloading site $index: "${model.name}" (siteId: ${model.siteId})',
    );

    if (!model.incognito) {
      // Snapshot the full native jar and attribute by base-domain so
      // sibling-subdomain cookies (e.g. `accounts.google.com` for a
      // `mail.google.com` site) aren't lost — a URL-scoped capture alone
      // would only return cookies applicable to the site's primary URL.
      final allCookies = await cookieManager.getAllCookies(
        candidateUrls: _candidateUrlsFor([model]),
      );
      final base = getBaseDomain(model.initUrl);
      model.cookies = allCookies
          .where((c) => cookieMatchesBaseDomain(c, base))
          .toList();
      await storage.saveCookiesForSite(model.siteId, model.cookies);
      LogService.instance.log(
        'CookieIsolation',
        'Captured ${model.cookies.length} cookies for site $index: "${model.name}"',
      );
    }

    model.disposeWebView();
    LogService.instance.log('CookieIsolation', 'Disposed webview for site $index');
    loadedIndices.remove(index);
  }

  /// Restores cookies for a site before it's activated:
  ///
  ///   1. Snapshot ALL native cookies via `getAllCookies()` (not URL-scoped
  ///      — that would miss sibling-subdomain cookies).
  ///   2. Attribute to every loaded non-incognito site (including target
  ///      if already loaded, so its live session is persisted before the
  ///      nuke) by base-domain match and save to siteId-keyed storage.
  ///   3. Nuke the native jar to evict cookies from deleted/legacy sites.
  ///   4. Restore target's cookies from storage, then every other
  ///      still-loaded site's cookies (parallel-loaded sites share the
  ///      native jar and must not lose their sessions).
  ///
  /// [versionAtEntry] and [currentVersion] implement the race guard: the
  /// function bails (returns without further mutation) between every
  /// `await` if a newer caller has bumped the version. Callers that don't
  /// need the guard can pass matching ints and a lambda that returns that
  /// same int.
  Future<void> restoreCookiesForSite({
    required int index,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
    required int versionAtEntry,
    required int Function() currentVersion,
  }) async {
    if (index < 0 || index >= models.length) return;

    final model = models[index];
    if (model.incognito) return;

    // Snapshot _loadedIndices before iterating: a concurrent _setCurrentIndex
    // may mutate it via unloadSiteForDomainSwitch between our awaits. The
    // version guard ultimately aborts us, but iterating a mutating Set
    // directly would throw ConcurrentModificationError first.
    final loadedSnapshot = loadedIndices.toList();

    // Step 1: snapshot all cookies. Pass candidate URLs for Android fallback
    // (iOS ignores them and uses the native getAllCookies API).
    final candidateModels = <WebViewModel>[];
    for (final i in loadedSnapshot) {
      if (i < 0 || i >= models.length) continue;
      if (models[i].incognito) continue;
      candidateModels.add(models[i]);
    }
    if (!loadedSnapshot.contains(index) && !model.incognito) {
      candidateModels.add(model);
    }
    final allCookies = await cookieManager.getAllCookies(
      candidateUrls: _candidateUrlsFor(candidateModels),
    );
    if (versionAtEntry != currentVersion()) return;

    // Step 2: attribute and persist.
    final otherLoadedModels = <WebViewModel>[];
    for (final loadedIndex in loadedSnapshot) {
      if (loadedIndex >= models.length) continue;
      final loadedModel = models[loadedIndex];
      if (loadedModel.incognito) continue;

      final base = getBaseDomain(loadedModel.initUrl);
      final cookies = allCookies
          .where((c) => cookieMatchesBaseDomain(c, base))
          .toList();
      loadedModel.cookies = cookies;
      await storage.saveCookiesForSite(loadedModel.siteId, cookies);
      if (versionAtEntry != currentVersion()) return;
      if (loadedIndex != index) otherLoadedModels.add(loadedModel);
    }

    // Step 3: nuke.
    await cookieManager.deleteAllCookies();
    if (versionAtEntry != currentVersion()) return;

    // Step 4a: restore target's cookies.
    final cookies = await storage.loadCookiesForSite(model.siteId);
    model.cookies = cookies;
    if (versionAtEntry != currentVersion()) return;

    LogService.instance.log(
      'CookieIsolation',
      'Restoring ${cookies.length} cookies for site $index: "${model.name}" (siteId: ${model.siteId})',
    );

    await _setCookies(model, cookies);
    if (versionAtEntry != currentVersion()) return;

    // Step 4b: restore every other still-loaded site's cookies.
    for (final other in otherLoadedModels) {
      await _setCookies(other, other.cookies);
      if (versionAtEntry != currentVersion()) return;
    }
  }

  /// Clears native cookies for a site about to be deleted. If a loaded
  /// same-base-domain site exists, snapshots its session first and
  /// restores after — the URL-scoped delete would otherwise evict the
  /// surviving site's live cookies too.
  Future<void> preDeleteCookieCleanup({
    required WebViewModel deletedModel,
    required int deletedIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) async {
    final deletedBase = getBaseDomain(deletedModel.initUrl);

    final survivingSameBase = <WebViewModel>[];
    for (final loadedIdx in loadedIndices) {
      if (loadedIdx == deletedIndex) continue;
      if (loadedIdx >= models.length) continue;
      final loaded = models[loadedIdx];
      if (loaded.incognito) continue;
      if (getBaseDomain(loaded.initUrl) == deletedBase) {
        survivingSameBase.add(loaded);
      }
    }

    List<Cookie> survivingSnapshot = const [];
    if (survivingSameBase.isNotEmpty) {
      final allCookies = await cookieManager.getAllCookies(
        candidateUrls: _candidateUrlsFor(survivingSameBase),
      );
      survivingSnapshot = allCookies
          .where((c) => cookieMatchesBaseDomain(c, deletedBase))
          .toList();
    }

    await cookieManager.deleteAllCookiesForUrl(Uri.parse(deletedModel.initUrl));
    if (deletedModel.currentUrl.isNotEmpty &&
        deletedModel.currentUrl != deletedModel.initUrl) {
      await cookieManager.deleteAllCookiesForUrl(Uri.parse(deletedModel.currentUrl));
    }
    await storage.saveCookiesForSite(deletedModel.siteId, []);

    if (survivingSameBase.isNotEmpty && survivingSnapshot.isNotEmpty) {
      final restoreUrl = Uri.parse(survivingSameBase.first.initUrl);
      for (final cookie in survivingSnapshot) {
        if (cookie.value.isEmpty) continue;
        await cookieManager.setCookie(
          url: restoreUrl,
          name: cookie.name,
          value: cookie.value,
          domain: cookie.domain,
          path: cookie.path ?? '/',
          expiresDate: cookie.expiresDate,
          isSecure: cookie.isSecure,
          isHttpOnly: cookie.isHttpOnly,
        );
      }
    }
  }

  /// Candidate URLs passed to `CookieManager.getAllCookies` on Android (where
  /// there's no native "get all" API and we aggregate per-URL instead). We
  /// include each model's `initUrl`, `currentUrl` (if different), and a
  /// bare `https://<baseDomain>/` to pick up parent-domain cookies like
  /// `Domain=.example.com`. On iOS this list is ignored.
  static List<Uri> _candidateUrlsFor(Iterable<WebViewModel> models) {
    final urls = <String>{};
    for (final m in models) {
      if (m.initUrl.isNotEmpty) urls.add(m.initUrl);
      if (m.currentUrl.isNotEmpty && m.currentUrl != m.initUrl) {
        urls.add(m.currentUrl);
      }
      final base = getBaseDomain(m.initUrl);
      if (base.isNotEmpty) urls.add('https://$base/');
    }
    return urls
        .map((s) {
          try {
            return Uri.parse(s);
          } catch (_) {
            return null;
          }
        })
        .whereType<Uri>()
        .toList();
  }

  Future<void> _setCookies(WebViewModel model, List<Cookie> cookies) async {
    final url = Uri.parse(model.initUrl);
    for (final cookie in cookies) {
      if (cookie.value.isEmpty) continue;
      if (model.isCookieBlocked(cookie.name, cookie.domain)) continue;
      await cookieManager.setCookie(
        url: url,
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path ?? '/',
        expiresDate: cookie.expiresDate,
        isSecure: cookie.isSecure,
        isHttpOnly: cookie.isHttpOnly,
      );
    }
  }
}
