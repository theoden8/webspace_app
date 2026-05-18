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
        sensitivity: LogSensitivity.sensitive,
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
      sensitivity: LogSensitivity.sensitive,
    );
    return bound;
  }

  /// Deletes [siteId]'s container. Caller MUST have already disposed
  /// the site's webview — the native API throws on a container in use.
  Future<void> onSiteDeleted(String siteId) async {
    if (!await containerNative.isSupported()) return;
    await containerNative.deleteContainer(siteId);
    LogService.instance.log(
      'Container',
      'Deleted container ws-$siteId',
      sensitivity: LogSensitivity.sensitive,
    );
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

  /// Deletes the named containers and recreates them empty. Two call
  /// sites:
  ///
  ///   - App startup, for incognito sites, so on-disk container data
  ///     doesn't outlive the process and feed stale session state into
  ///     the next launch (issue #298).
  ///   - User-driven "Clear Site Data" (`_clearSiteData`), so cookies +
  ///     localStorage + IDB + SW + HTTP cache go away in one call.
  ///
  /// Caller MUST ensure no live webview is bound to [siteIds] — the
  /// fork's `deleteContainer` no-ops on an in-use container, so the
  /// IndexedStack rebuild that drops the InAppWebView widget has to
  /// complete before this runs (`await WidgetsBinding.instance.endOfFrame`
  /// at the call site). Idempotent and safe before any webview binds:
  /// containers are materialized lazily on first bind.
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
        'Wiped $wiped container(s)',
      );
    }
    return wiped;
  }
}
