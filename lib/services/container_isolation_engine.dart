import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/demo_mode.dart';

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
///    against the live key set.
///
/// Only an `Isolation` of `Containers` holds one, which the restore makes
/// once the probe says containers are supported, so no operation here asks
/// again. The engine keeps nothing beyond [containerNative] and the launch
/// sweep in flight; tests inject a mock
/// that models per-container cookie partitioning, the same pattern as
/// `MockCookieManager` in
/// [test/cookie_isolation_integration_test.dart].
class ContainerIsolationEngine {
  final ContainerNative containerNative;

  ContainerIsolationEngine({required this.containerNative});

  /// The launch sweep while it runs, which every container made waits for.
  Future<void>? _sweeping;

  /// Idempotent: ensures [key]'s container exists in the native
  /// store. Safe to call on every site activation. Waits for the launch
  /// sweep: the grid takes a tap before it is done, and a container bound
  /// first would be one `deleteContainer` cannot reliably remove (CONT-004).
  Future<void> ensureContainer(ContainerKey key) async {
    if (_sweeping case final sweep?) {
      try {
        await sweep;
      } finally {
        // Done either way: a failed sweep must not hold every later
        // container behind it.
        if (identical(_sweeping, sweep)) _sweeping = null;
      }
    }
    await containerNative.getOrCreateContainer(key);
  }


  /// Deletes [key]'s container outright. Caller MUST have already
  /// disposed the site's webview — `deleteContainer` no-ops on iOS /
  /// macOS if the data store is still bound. Use [clearForSite] for
  /// the live-container clear path; this is for site deletion and
  /// orphan GC.
  Future<void> onSiteDeleted(ContainerKey key) async {
    final deleted = await containerNative.deleteContainer(key);
    LogTag.container.debug(
        'Deleted container ws-$key (success=$deleted)', sensitive: true);
  }

  /// Wipes [key]'s container data (cookies, localStorage, IndexedDB,
  /// ServiceWorkers, HTTP cache) without removing the container itself.
  /// Safe to call on a live, bound container — that's what the fork's
  /// `WKWebsiteDataStore.removeData(...)` (iOS/macOS) is for. Returns
  /// `true` if the platform reported success. The caller still wants
  /// to dispose+recreate the webview after this for UX (the user
  /// expects to see a fresh page) and to drop any in-memory state the
  /// platform clear didn't reach (notably Android's per-WebView HTTP
  /// cache).
  Future<bool> clearForSite(ContainerKey key) async {
    final ok = await containerNative.clearContainerData(key);
    LogService.instance.log(
      LogTag.container,
      message: ok
          ? 'Cleared container ws-$key'
          : 'clearContainerData(ws-$key) reported failure',
      level: ok ? LogLevel.debug : LogLevel.error,
      sensitivity: LogSensitivity.sensitive,
    );
    return ok;
  }

  /// The launch sweep, once per process, as soon as the sites are read:
  /// [garbageCollectOrphans], then each of [incognito]'s containers, so its
  /// directory does not grow across sessions (#298). [ensureContainer]
  /// waits for it. In demo mode it sweeps nothing: a seeded or test site
  /// list is not the user's, and measured against it every one of their
  /// sites is an orphan.
  Future<void> sweepBeforeBind(
    Set<ContainerKey> active, {
    required Set<ContainerKey> incognito,
  }) {
    assert(_sweeping == null, 'the launch sweep runs once, before any bind');
    if (isDemoMode) return _sweeping = Future<void>.value();
    return _sweeping = () async {
      await garbageCollectOrphans(active);
      for (final key in incognito) {
        await onSiteDeleted(key);
      }
    }();
  }

  /// Sweeps containers whose owning site no longer exists in
  /// [active]. Returns the number of containers deleted.
  Future<int> garbageCollectOrphans(Set<ContainerKey> active) async {
    final stored = await containerNative.listContainers();
    int deleted = 0;
    for (final key in stored) {
      if (!active.contains(key)) {
        await containerNative.deleteContainer(key);
        deleted++;
      }
    }
    if (deleted > 0) {
      LogTag.container.debug('GC: deleted $deleted orphan container(s)');
    }
    return deleted;
  }
}
