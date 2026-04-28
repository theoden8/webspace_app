import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/profile_native.dart';

/// Pure-Dart orchestration layer over [ProfileNative]. Keeps three rules:
///
/// 1. Profiles are created on demand (idempotent) before the first webview
///    bind for a site, so the named profile exists when
///    `WebViewCompat.setProfile` runs.
/// 2. Profiles are deleted when their owning site is deleted — same
///    boundary at which [CookieIsolationEngine.preDeleteCookieCleanup]
///    runs in the legacy path.
/// 3. Orphaned profiles (whose owning site no longer exists, e.g. a site
///    deleted in a previous session before profile mode was enabled, or a
///    crash mid-deletion) are swept on app startup against the live
///    siteId set.
///
/// The engine is stateless beyond [profileNative]; tests inject a mock
/// that models per-profile cookie partitioning, the same pattern as
/// `MockCookieManager` in
/// [test/cookie_isolation_integration_test.dart].
class ProfileIsolationEngine {
  final ProfileNative profileNative;

  ProfileIsolationEngine({required this.profileNative});

  /// Idempotent: ensures [siteId]'s profile exists in the native
  /// ProfileStore. Safe to call on every site activation.
  Future<void> ensureProfile(String siteId) async {
    if (!await profileNative.isSupported()) return;
    try {
      await profileNative.getOrCreateProfile(siteId);
    } catch (e) {
      LogService.instance.log(
        'Profile',
        'ensureProfile($siteId) failed: $e',
        level: LogLevel.error,
      );
    }
  }

  /// Ensures the profile exists, then attempts to bind every live
  /// flutter_inappwebview WebView created for [siteId] to that profile.
  /// Returns the number of webviews actually bound. Safe to call from
  /// `onWebViewCreated` — the underlying [WebViewCompat.setProfile] call
  /// is wrapped in a try/catch on the native side so a single race
  /// against `loadUrl` doesn't fail the batch or throw to Dart.
  Future<int> bindForSite(String siteId) async {
    if (!await profileNative.isSupported()) return 0;
    await ensureProfile(siteId);
    final bound = await profileNative.bindProfileToWebView(siteId);
    LogService.instance.log(
      'Profile',
      'Bound profile ws-$siteId to $bound webview(s)',
    );
    return bound;
  }

  /// Deletes [siteId]'s profile. Caller MUST have already disposed the
  /// site's webview — the native API throws on a profile in use.
  Future<void> onSiteDeleted(String siteId) async {
    if (!await profileNative.isSupported()) return;
    await profileNative.deleteProfile(siteId);
    LogService.instance.log('Profile', 'Deleted profile ws-$siteId');
  }

  /// Sweeps profiles whose owning site no longer exists in
  /// [activeSiteIds]. Returns the number of profiles deleted. Run at
  /// app startup, after the active site set is known but before any
  /// site is activated.
  Future<int> garbageCollectOrphans(Set<String> activeSiteIds) async {
    if (!await profileNative.isSupported()) return 0;
    final stored = await profileNative.listProfiles();
    int deleted = 0;
    for (final siteId in stored) {
      if (!activeSiteIds.contains(siteId)) {
        await profileNative.deleteProfile(siteId);
        deleted++;
      }
    }
    if (deleted > 0) {
      LogService.instance.log(
        'Profile',
        'GC: deleted $deleted orphan profile(s)',
      );
    }
    return deleted;
  }
}
