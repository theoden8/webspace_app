import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/log_service.dart';

/// Pure-Dart orchestration layer over [ContainerNative]. Keeps three rules:
///
/// 1. The container for the current `(siteId, rev)` is created on
///    demand (idempotent) before the first webview bind, so the named
///    container exists when the native bind runs.
/// 2. When a site is deleted, every container for that siteId — current
///    rev plus any leftover stale revs — is dropped.
/// 3. Orphaned containers are swept on app startup against the live
///    `(siteId → currentRev)` map. An orphan is any container whose
///    `siteId` isn't in the map OR whose rev doesn't match the
///    current rev — the latter happens after each "Clear Site Data"
///    bump, where the previous-rev container is intentionally
///    abandoned so we don't have to fight the fork's
///    `WKWebsiteDataStore.remove(forIdentifier:)` while it's still
///    referenced by a pending WKWebView callback.
///
/// The engine is stateless beyond [containerNative]; tests inject a mock
/// that models per-container cookie partitioning, the same pattern as
/// `MockCookieManager` in
/// [test/cookie_isolation_integration_test.dart].
class ContainerIsolationEngine {
  final ContainerNative containerNative;

  ContainerIsolationEngine({required this.containerNative});

  /// Idempotent: ensures the container for `(siteId, rev)` exists in
  /// the native store. Safe to call on every site activation.
  Future<void> ensureContainer(String siteId, {int rev = 0}) async {
    if (!await containerNative.isSupported()) return;
    final key = containerKeyFor(siteId, rev);
    try {
      await containerNative.getOrCreateContainer(key);
    } catch (e) {
      LogService.instance.log(
        'Container',
        'ensureContainer($key) failed: $e',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
    }
  }

  /// Ensures the container exists, then attempts to bind every live
  /// flutter_inappwebview WebView created for `(siteId, rev)` to that
  /// container. Returns the number of webviews actually bound. Safe to
  /// call from `onWebViewCreated` — the underlying native bind is
  /// wrapped in a try/catch so a single race against `loadUrl` doesn't
  /// fail the batch or throw to Dart.
  Future<int> bindForSite(String siteId, {int rev = 0}) async {
    if (!await containerNative.isSupported()) return 0;
    await ensureContainer(siteId, rev: rev);
    final key = containerKeyFor(siteId, rev);
    final bound = await containerNative.bindContainerToWebView(key);
    LogService.instance.log(
      'Container',
      'Bound container ws-$key to $bound webview(s)',
      sensitivity: LogSensitivity.sensitive,
    );
    return bound;
  }

  /// Deletes every container belonging to [siteId] (current rev and any
  /// stale revs left over from past wipes). Caller MUST have already
  /// disposed the site's webview — the native API no-ops on a container
  /// in use, and [garbageCollectOrphans] will catch anything we miss
  /// at the next startup.
  Future<void> onSiteDeleted(String siteId) async {
    if (!await containerNative.isSupported()) return;
    final stored = await containerNative.listContainers();
    int dropped = 0;
    for (final key in stored) {
      if (parseContainerKey(key).siteId == siteId) {
        await containerNative.deleteContainer(key);
        dropped++;
      }
    }
    if (dropped > 0) {
      LogService.instance.log(
        'Container',
        'Deleted $dropped container(s) for site $siteId',
        sensitivity: LogSensitivity.sensitive,
      );
    }
  }

  /// Sweeps containers whose owning site no longer exists OR whose
  /// `(siteId, rev)` doesn't match the entry in [activeSiteRevs]
  /// (i.e. the site is alive but on a newer rev — a previous wipe left
  /// the old container as garbage). Returns the number of containers
  /// deleted. Run at app startup, after the active site set is known
  /// but before any site is activated.
  Future<int> garbageCollectOrphans(Map<String, int> activeSiteRevs) async {
    if (!await containerNative.isSupported()) return 0;
    final stored = await containerNative.listContainers();
    int deleted = 0;
    for (final key in stored) {
      final parsed = parseContainerKey(key);
      final currentRev = activeSiteRevs[parsed.siteId];
      if (currentRev == null || currentRev != parsed.rev) {
        await containerNative.deleteContainer(key);
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

  /// Bumps the rev for each siteId and returns the post-bump rev so
  /// callers can persist it on their [WebViewModel]. The previous-rev
  /// container is left in place — it will be swept by
  /// [garbageCollectOrphans] at next startup (or earlier if the caller
  /// triggers a sweep). Call sites:
  ///
  ///   - User-driven "Clear Site Data" (`_clearSiteData`).
  ///   - App startup, for incognito sites — replaces the previous
  ///     "delete then recreate" wipe (which depended on the fork's
  ///     `deleteContainer` actually completing, an unreliable contract
  ///     on iOS/macOS — see #360).
  ///   - TLS revoke, for sites that had a pinned self-signed cert
  ///     revoked: the in-memory `WKWebsiteDataStore` SSL exception
  ///     cache survives `clearSslPreferences`, so the only way to
  ///     drop it is to bind to a different store.
  ///
  /// Returns the map of `siteId → newRev`. The caller is responsible
  /// for writing the new rev back into the model + persistence; this
  /// engine deliberately keeps no state of its own.
  Map<String, int> bumpRevs(Map<String, int> currentRevs) {
    return {
      for (final entry in currentRevs.entries) entry.key: entry.value + 1,
    };
  }
}
