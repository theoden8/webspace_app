import 'package:webspace/settings/site_ids.dart';

/// Which live set a store's entries are measured against.
enum OrphanScope {
  /// Session residue: an incognito site's entries are orphans too, so
  /// whatever it left before the toggle is reclaimed (INC-006).
  session,

  /// Configuration the user typed: kept for incognito sites like any other.
  configuration,
}

/// Every per-site store the sweep reclaims, in sweep order. A new store is
/// a new value here; [OrphanSweepTargets.removeOrphans] switches over it, so
/// the binding does not compile until the store is swept.
enum OrphanStore {
  cookies(OrphanScope.session),
  proxyPasswords(OrphanScope.configuration),
  httpAuthCredentials(OrphanScope.configuration),
  htmlCaches(OrphanScope.session),
  htmlImports(OrphanScope.configuration),
  webViewState(OrphanScope.session),

  /// The protection report's per-site rows. The category counts they fed
  /// are site-less and stay.
  blockStatsSites(OrphanScope.session),

  /// Page icons on disk, keyed by home URL (ICON-009).
  siteIcons(OrphanScope.session);

  const OrphanStore(this.scope);

  final OrphanScope scope;
}

abstract interface class OrphanSweepTargets {
  /// Drops everything [store] keeps for a siteId outside [liveSiteIds].
  Future<void> removeOrphans(OrphanStore store,
      {required Set<SiteId> liveSiteIds});
}

/// Reclaims per-site storage whose site no longer exists.
class OrphanSweepEngine {
  OrphanSweepEngine._();

  /// Sweeps every [OrphanStore]. The legacy engine's shared jar is not a
  /// store: it holds no site's entries apart, and only
  /// `CookieIsolationEngine.clearAtLaunch` empties it, in its first turn.
  /// Under containers no "empty a cookie jar" op is issued at all: one with
  /// no site in hand is what a plugin-side mislabel once pointed at a live
  /// container (BUG-007, issues #524, #525).
  static Future<void> sweep({
    required OrphanSweepTargets targets,
    required Set<SiteId> activeSiteIds,
    required Set<SiteId> nonIncognitoSiteIds,
  }) async {
    for (final store in OrphanStore.values) {
      await targets.removeOrphans(
        store,
        liveSiteIds: switch (store.scope) {
          OrphanScope.session => nonIncognitoSiteIds,
          OrphanScope.configuration => activeSiteIds,
        },
      );
    }
  }
}
