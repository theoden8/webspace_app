import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/log_service.dart';

/// Pure-Dart orchestration layer over [ContainerNative]. Four rules:
///
/// 1. Containers are created on demand (idempotent) before the first
///    webview bind for a site, so the named container exists when the
///    native bind runs.
/// 2. "Clear Site Data" routes through [clearForSite], which on
///    iOS/macOS maps to `WKWebsiteDataStore.removeData(...)` — the
///    one primitive Apple actually supports while a WKWebView is
///    bound. `deleteContainer` silently no-ops in that case (#360), so
///    it is kept for site deletion / orphan GC only, both of which run
///    when no WebView is bound.
/// 3. Containers are deleted when their owning site is deleted.
/// 4. Orphaned containers (whose owning site no longer exists — e.g.
///    a site deleted in a previous session) are swept on app startup
///    against the live siteId set.
///
/// The engine is stateless beyond [containerNative]; tests inject a mock
/// that models per-container cookie partitioning, the same pattern as
/// `MockCookieManager` in
/// [test/cookie_isolation_integration_test.dart].
class ContainerIsolationEngine {
  final ContainerNative containerNative;

  ContainerIsolationEngine({required this.containerNative});

  /// Idempotent: ensures [siteId]'s container exists in the native
  /// store. Safe to call on every site activation.
  Future<void> ensureContainer(String siteId) async {
    if (!await containerNative.isSupported()) return;
    try {
      await containerNative.getOrCreateContainer(siteId);
    } catch (e) {
      LogTag.container.error(
          'ensureContainer($siteId) failed: $e', sensitive: true);
    }
  }


  /// Deletes [siteId]'s container outright. Caller MUST have already
  /// disposed the site's webview — `deleteContainer` no-ops on iOS /
  /// macOS if the data store is still bound. Use [clearForSite] for
  /// the live-container clear path; this is for site deletion and
  /// orphan GC.
  Future<void> onSiteDeleted(String siteId) async {
    if (!await containerNative.isSupported()) return;
    final deleted = await containerNative.deleteContainer(siteId);
    LogTag.container.debug(
        'Deleted container ws-$siteId (success=$deleted)', sensitive: true);
  }

  /// Wipes [siteId]'s container data (cookies, localStorage, IndexedDB,
  /// ServiceWorkers, HTTP cache) without removing the container itself.
  /// Safe to call on a live, bound container — that's what the fork's
  /// `WKWebsiteDataStore.removeData(...)` (iOS/macOS) is for. Returns
  /// `true` if the platform reported success. The caller still wants
  /// to dispose+recreate the webview after this for UX (the user
  /// expects to see a fresh page) and to drop any in-memory state the
  /// platform clear didn't reach (notably Android's per-WebView HTTP
  /// cache).
  Future<bool> clearForSite(String siteId) async {
    if (!await containerNative.isSupported()) return false;
    final ok = await containerNative.clearContainerData(siteId);
    LogService.instance.log(
      LogTag.container,
      ok
          ? 'Cleared container ws-$siteId'
          : 'clearContainerData(ws-$siteId) reported failure',
      level: ok ? LogLevel.debug : LogLevel.error,
      sensitivity: LogSensitivity.sensitive,
    );
    return ok;
  }

  /// Sweeps containers whose owning site no longer exists in
  /// [activeSiteIds]. Returns the number of containers deleted. Run at
  /// app startup, after the active site set is known but before any
  /// site is activated.
  Future<int> garbageCollectOrphans(Set<String> activeSiteIds) async {
    if (!await containerNative.isSupported()) return 0;
    final stored = await containerNative.listContainers();
    int deleted = 0;
    for (final siteId in stored) {
      if (!activeSiteIds.contains(siteId)) {
        await containerNative.deleteContainer(siteId);
        deleted++;
      }
    }
    if (deleted > 0) {
      LogTag.container.debug('GC: deleted $deleted orphan container(s)');
    }
    return deleted;
  }
}
