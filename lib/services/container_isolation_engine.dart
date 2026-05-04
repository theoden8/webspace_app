import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/log_service.dart';

/// Pure-Dart orchestration layer over [ContainerNative]. Keeps three rules:
///
/// 1. Containers are created on demand (idempotent) before the first
///    webview bind for a site, so the named container exists when the
///    native bind runs.
/// 2. Containers are deleted when their owning site is deleted — same
///    boundary at which [CookieIsolationEngine.preDeleteCookieCleanup]
///    runs in the legacy path.
/// 3. Orphaned containers (whose owning site no longer exists, e.g. a
///    site deleted in a previous session before container mode was
///    enabled, or a crash mid-deletion) are swept on app startup
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
      LogService.instance.log(
        'Container',
        'ensureContainer($siteId) failed: $e',
        level: LogLevel.error,
      );
    }
  }

  /// Ensures the container exists, then attempts to bind every live
  /// flutter_inappwebview WebView created for [siteId] to that container.
  /// Returns the number of webviews actually bound. Safe to call from
  /// `onWebViewCreated` — the underlying native bind is wrapped in a
  /// try/catch so a single race against `loadUrl` doesn't fail the
  /// batch or throw to Dart.
  Future<int> bindForSite(String siteId) async {
    if (!await containerNative.isSupported()) return 0;
    await ensureContainer(siteId);
    final bound = await containerNative.bindContainerToWebView(siteId);
    LogService.instance.log(
      'Container',
      'Bound container ws-$siteId to $bound webview(s)',
    );
    return bound;
  }

  /// Deletes [siteId]'s container. Caller MUST have already disposed
  /// the site's webview — the native API throws on a container in use.
  Future<void> onSiteDeleted(String siteId) async {
    if (!await containerNative.isSupported()) return;
    await containerNative.deleteContainer(siteId);
    LogService.instance.log('Container', 'Deleted container ws-$siteId');
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
      LogService.instance.log(
        'Container',
        'GC: deleted $deleted orphan container(s)',
      );
    }
    return deleted;
  }

  /// Deletes the named containers and recreates them empty. Used at
  /// app startup to wipe localStorage / IndexedDB / ServiceWorker cache
  /// / HTTP cache for incognito sites — without this, on-disk container
  /// data outlives the process and the next launch reads back stale
  /// session state (issue #298). Idempotent and safe before any
  /// webview binds: containers are materialized lazily on first bind.
  Future<int> wipeContainers(Iterable<String> siteIds) async {
    if (!await containerNative.isSupported()) return 0;
    int wiped = 0;
    for (final siteId in siteIds) {
      await containerNative.deleteContainer(siteId);
      wiped++;
    }
    if (wiped > 0) {
      LogService.instance.log(
        'Container',
        'Wiped $wiped incognito container(s) on startup',
      );
    }
    return wiped;
  }
}
