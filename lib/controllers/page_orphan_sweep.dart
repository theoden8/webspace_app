import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/webview_state_storage.dart';

/// [OrphanSweepEngine] bound to the page's stores. The switch over
/// [OrphanStore] has no default, so a store added there does not compile
/// until it is swept here.
class PageOrphanSweep implements OrphanSweepTargets {
  PageOrphanSweep(
    this._sites, {
    required this.cookieStore,
    required this.proxyPasswords,
    required this.navStates,
    required this.cookies,
  });

  final SiteRuntime _sites;
  final CookieSecureStorage cookieStore;
  final ProxyPasswordSecureStorage proxyPasswords;
  final WebViewStateStorage navStates;
  final CookieManager cookies;

  @override
  Future<void> removeOrphans(OrphanStore store,
          {required Set<String> liveSiteIds}) =>
      switch (store) {
        OrphanStore.cookies => cookieStore.removeOrphanedCookies(liveSiteIds),
        OrphanStore.proxyPasswords => proxyPasswords.removeOrphaned(liveSiteIds),
        OrphanStore.httpAuthCredentials =>
          HttpAuthSecureStorage.instance.removeOrphaned(liveSiteIds),
        OrphanStore.htmlCaches =>
          HtmlCacheService.instance.removeOrphanedCaches(liveSiteIds),
        OrphanStore.htmlImports =>
          HtmlImportStorage.instance.removeOrphanedImports(liveSiteIds),
        OrphanStore.webViewState =>
          navStates.removeOrphans(_sites.liveStateKeys(liveSiteIds)),
        OrphanStore.blockStatsSites =>
          BlockStatsService.instance.removeOrphanedSites(liveSiteIds),
        OrphanStore.siteIcons => SiteIconStore.instance.removeOrphans({
            for (final m in _sites.models)
              if (liveSiteIds.contains(m.siteId) && !m.effectiveIncognito)
                m.initUrl,
          }),
      };

  @override
  Future<void> clearLegacyGlobalCookieJar() => cookies.deleteAllCookies();

  /// Sweep after sites left the list while the app runs (delete, import).
  Future<void> afterRemoval() => OrphanSweepEngine.sweep(
        targets: this,
        activeSiteIds: _sites.siteIds,
        nonIncognitoSiteIds: _sites.nonIncognitoSiteIds,
        useContainers: _sites.useContainers,
        occasion: SweepOccasion.sitesRemoved,
      );

  /// Housekeeping sweep of storage left by sites deleted in previous sessions,
  /// deferred off the cold-launch first-paint path. The launched site never
  /// reads any of this — its cookies come from its hydrated model (legacy) or
  /// its own container — so running it after paint changes nothing the user
  /// sees, only when the disk reclaim happens. The live-set args are read fresh
  /// by the engine at sweep time so a site added post-paint isn't reclaimed.
  Future<void> atLaunch(
    Set<String> activeSiteIds, {
    required Set<String> nonIncognitoSiteIds,
  }) async {
    try {
      await OrphanSweepEngine.sweep(
        targets: this,
        activeSiteIds: activeSiteIds,
        nonIncognitoSiteIds: nonIncognitoSiteIds,
        useContainers: _sites.useContainers,
        occasion: SweepOccasion.launch,
      );
      // Blocklist levels nothing asks for any more: a site that moved back
      // to the app-wide level leaves its tier behind, and each one is a
      // multi-megabyte file plus its share of the in-memory partition. Only
      // here, not on every model save — an unsaved per-site edit is not in
      // `_sites.models` yet, and pruning against it would delete the tier
      // the user just waited for.
      await DnsBlockService.instance.pruneLevels(requiredDnsLevels(
        globalLevel: DnsBlockService.instance.level,
        siteLevels: [for (final m in _sites.models) m.effectiveDnsBlockLevel],
      ));
    } catch (e) {
      LogTag.startup.error('Deferred startup GC failed: $e');
    }
  }
}
