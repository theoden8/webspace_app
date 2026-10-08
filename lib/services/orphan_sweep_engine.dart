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

enum SweepOccasion {
  /// Post-paint housekeeping of what earlier sessions left.
  launch,

  /// Sites were deleted or replaced by an import while the app runs.
  sitesRemoved,
}

abstract interface class OrphanSweepTargets {
  /// Drops everything [store] keeps for a siteId outside [liveSiteIds].
  Future<void> removeOrphans(OrphanStore store, Set<String> liveSiteIds);

  /// Empties the single shared cookie jar the legacy engine partitions by
  /// hand.
  Future<void> clearLegacyGlobalCookieJar();
}

/// Reclaims per-site storage whose site no longer exists.
class OrphanSweepEngine {
  OrphanSweepEngine._();

  /// Sweeps every [OrphanStore], then, at launch under the legacy engine,
  /// clears the shared cookie jar.
  ///
  /// The jar clear is skipped entirely under containers. It would reclaim
  /// nothing there (each site owns its jar, and this call carries no site to
  /// address), and issuing an unscoped "empty a cookie jar" op while live
  /// containers exist is what made BUG-007's plugin-side mislabel reachable:
  /// a container-scoped read had poisoned the plugin's `CookieManager` memo,
  /// so the clear landed on a live container and wiped a real session, which
  /// surfaced a launch later as a logged-out site (issues #524, #525). Fixed
  /// in the fork at `v6.2.0-beta.3-privacy-v6`; not issuing the op keeps the
  /// class of mistake unreachable from here rather than merely fixed once.
  static Future<void> sweep({
    required OrphanSweepTargets targets,
    required Set<String> activeSiteIds,
    required Set<String> nonIncognitoSiteIds,
    required bool useContainers,
    required SweepOccasion occasion,
  }) async {
    for (final store in OrphanStore.values) {
      await targets.removeOrphans(
        store,
        switch (store.scope) {
          OrphanScope.session => nonIncognitoSiteIds,
          OrphanScope.configuration => activeSiteIds,
        },
      );
    }
    switch (occasion) {
      case SweepOccasion.launch:
        if (!useContainers) {
          await targets.clearLegacyGlobalCookieJar();
        }
      case SweepOccasion.sitesRemoved:
        // The jar holds the loaded sites' live sessions; a clear here
        // would sign them out.
        break;
    }
  }
}
