import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/cookie_manager.dart';

/// Returns true if `cookie.domain` falls under `baseDomain` per standard
/// HTTP cookie domain-match semantics (exact match or any subdomain).
/// Leading `.` is stripped before comparison.
bool cookieMatchesBaseDomain(Cookie cookie, {required String baseDomain}) {
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

  /// Captures the site's cookies to siteId-keyed storage, then disposes its
  /// webview and removes it from `loadedIndices`; every unload reason comes
  /// through here (ISO-002).
  ///
  /// The native jar keeps the site's cookies until the next activation's
  /// [restoreCookiesForSite], which attributes the jar to the loaded sites
  /// only and then empties it, so this capture is all the site keeps.
  ///
  /// A jar that cannot be read leaves the set the site last saved where it
  /// is, and the unload goes on: what unloads a site (a conflict, a cap,
  /// memory) does not wait for the jar (ISO-014).
  Future<void> unloadSiteForDomainSwitch({
    required int index,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) async {
    if (index < 0 || index >= models.length) return;

    final model = models[index];
    LogTag.cookieIsolation.debug(
        'Unloading site $index: "${model.name}" (siteId: ${model.siteId})',
        sensitive: true);

    if (!model.effectiveIncognito) {
      // Snapshot the full native jar and attribute by base-domain so
      // sibling-subdomain cookies (e.g. `accounts.google.com` for a
      // `mail.google.com` site) aren't lost — a URL-scoped capture alone
      // would only return cookies applicable to the site's primary URL.
      List<Cookie>? allCookies;
      try {
        allCookies = await cookieManager.getAllCookies(
          candidateUrls: _candidateUrlsFor([model]),
        );
      } on CookieJarFailure catch (e) {
        LogTag.cookieIsolation.warning(
            'Capture for site $index "${model.name}" failed, its stored '
            'cookies stay: $e',
            sensitive: true);
      }
      if (allCookies != null) {
        final base = getBaseDomain(model.initUrl);
        model.cookies = allCookies
            .where((c) => cookieMatchesBaseDomain(c, baseDomain: base))
            .toList();
        await storage.saveCookiesForSite(model.siteId, cookies: model.cookies);
        LogTag.cookieIsolation.debug(
            'Captured ${model.cookies.length} cookies for site $index: "${model.name}"',
            sensitive: true);
      }
    }

    model.disposeWebView();
    LogTag.cookieIsolation.debug(
        'Disposed webview for site $index', sensitive: true);
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
  ///
  /// Fails with [CookieJarFailure] when the jar cannot be read, emptied or
  /// refilled (ISO-014). A read that fails saves nothing and empties
  /// nothing. A write that fails leaves the rest of the refill to run first,
  /// so the jar holds all of the stored sets the platform takes.
  Future<void> restoreCookiesForSite({
    required int index,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
    required int versionAtEntry,
    required int Function() currentVersion,
  }) async {
    if (index < 0 || index >= models.length) return;

    final model = models[index];
    if (model.effectiveIncognito) return;

    // Snapshot _loadedIndices before iterating: a concurrent setCurrentIndex
    // may mutate it via unloadSiteForDomainSwitch between our awaits. The
    // version guard ultimately aborts us, but iterating a mutating Set
    // directly would throw ConcurrentModificationError first.
    final loadedSnapshot = loadedIndices.toList();

    // Step 1: snapshot all cookies. Pass candidate URLs for Android fallback
    // (iOS ignores them and uses the native getAllCookies API).
    final candidateModels = <WebViewModel>[];
    for (final i in loadedSnapshot) {
      if (i < 0 || i >= models.length) continue;
      if (models[i].effectiveIncognito) continue;
      candidateModels.add(models[i]);
    }
    if (!loadedSnapshot.contains(index) && !model.effectiveIncognito) {
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
      if (loadedModel.effectiveIncognito) continue;

      final base = getBaseDomain(loadedModel.initUrl);
      final cookies = allCookies
          .where((c) => cookieMatchesBaseDomain(c, baseDomain: base))
          .toList();
      loadedModel.cookies = cookies;
      await storage.saveCookiesForSite(loadedModel.siteId, cookies: cookies);
      if (versionAtEntry != currentVersion()) return;
      if (loadedIndex != index) otherLoadedModels.add(loadedModel);
    }

    // Step 3: nuke.
    await cookieManager.deleteAllCookies();
    // No version-guard bail from here on. Once the shared jar is emptied it
    // MUST be fully repopulated before returning: a bail here leaves the jar
    // empty, and the next activation captures that emptiness in step 2 and
    // persists it via saveCookiesForSite(siteId, []), which deletes every
    // loaded site's stored session. Finishing the restore is cheap (writes
    // known-good storage data back) and a superseding activation re-runs its
    // own capture-nuke-restore against the now-consistent jar.

    // Step 4a: restore target's cookies.
    final cookies = await storage.loadCookiesForSite(model.siteId);
    model.cookies = cookies;

    LogTag.cookieIsolation.debug(
        'Restoring ${cookies.length} cookies for site $index: "${model.name}" (siteId: ${model.siteId})',
        sensitive: true);

    var refused = await _setCookies(model, cookies: cookies);

    // Step 4b: restore every other still-loaded site's cookies.
    for (final other in otherLoadedModels) {
      final otherRefused = await _setCookies(other, cookies: other.cookies);
      refused ??= otherRefused;
    }
    if (refused != null) throw refused;
  }

  /// Clears native cookies for a site about to be deleted. If a loaded
  /// same-base-domain site exists, snapshots its session first and
  /// restores after — the URL-scoped delete would otherwise evict the
  /// surviving site's live cookies too.
  ///
  /// The site's stored cookies go first, whatever the jar does. A jar that
  /// fails is left as it is, with nothing deleted past the failure: the next
  /// activation empties it before any site shows (ISO-012, ISO-014).
  Future<void> preDeleteCookieCleanup({
    required WebViewModel deletedModel,
    required int deletedIndex,
    required List<WebViewModel> models,
    required Set<int> loadedIndices,
  }) async {
    await storage.saveCookiesForSite(deletedModel.siteId, cookies: []);
    try {
      await _clearDeletedFromJar(
        deletedModel: deletedModel,
        deletedIndex: deletedIndex,
        models: models,
        loadedIndices: loadedIndices,
      );
    } on CookieJarFailure catch (e) {
      LogTag.cookieIsolation.warning(
          'Clearing deleted site "${deletedModel.name}" from the jar failed; '
          'the next activation empties it: $e',
          sensitive: true);
    }
  }

  Future<void> _clearDeletedFromJar({
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
      if (loaded.effectiveIncognito) continue;
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
          .where((c) => cookieMatchesBaseDomain(c, baseDomain: deletedBase))
          .toList();
    }

    await cookieManager.deleteAllCookiesForUrl(Uri.parse(deletedModel.initUrl));
    if (deletedModel.currentUrl.isNotEmpty &&
        deletedModel.currentUrl != deletedModel.initUrl) {
      await cookieManager.deleteAllCookiesForUrl(Uri.parse(deletedModel.currentUrl));
    }

    if (survivingSameBase.isNotEmpty && survivingSnapshot.isNotEmpty) {
      final refused = await _writeAll(
        Uri.parse(survivingSameBase.first.initUrl),
        cookies: survivingSnapshot,
      );
      if (refused != null) throw refused;
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
    return urls.map(Uri.tryParse).whereType<Uri>().toList();
  }

  /// [model]'s [cookies] into the jar, but the ones it blocks; see
  /// [_writeAll].
  Future<CookieJarFailure?> _setCookies(WebViewModel model,
          {required List<Cookie> cookies}) =>
      _writeAll(
        Uri.parse(model.initUrl),
        cookies: cookies.where(
            (c) => !model.isCookieBlocked(c.name, domain: c.domain)),
      );

  /// Writes every one of [cookies] the jar takes at [url]: one it refuses
  /// does not stop the rest. Returns the first refusal, null when none.
  Future<CookieJarFailure?> _writeAll(Uri url,
      {required Iterable<Cookie> cookies}) async {
    CookieJarFailure? refused;
    for (final cookie in cookies) {
      if (cookie.value.isEmpty) continue;
      try {
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
      } on CookieJarFailure catch (e) {
        refused ??= e;
      }
    }
    return refused;
  }
}
