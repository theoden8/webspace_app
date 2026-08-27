/// Storage reclaimed by the post-paint orphan sweep. Each method drops
/// everything keyed by a siteId outside the live set it is handed.
///
/// Two different live sets are in play, and which one a target gets is part
/// of the contract: session residue (cookies, cached HTML, saved navigation
/// state) measures against the non-incognito set, so an incognito site's
/// remnants are reclaimed every launch (issue #298), while configuration
/// (proxy passwords, imported HTML) measures against the full active set and
/// survives for incognito sites like any other.
abstract class OrphanSweepTargets {
  Future<void> removeOrphanedCookies(Set<String> nonIncognitoSiteIds);
  Future<void> removeOrphanedProxyPasswords(Set<String> activeSiteIds);
  Future<void> removeOrphanedHtmlCaches(Set<String> nonIncognitoSiteIds);
  Future<void> removeOrphanedHtmlImports(Set<String> activeSiteIds);
  Future<void> removeOrphanedWebViewState(Set<String> nonIncognitoSiteIds);

  /// Drops the protection report's per-site rows for sites outside the live
  /// set. Measures against the non-incognito set: an attributed row names a
  /// site the same way a cookie does, so an incognito site's is reclaimed
  /// every launch. The category counts it fed are site-less and stay.
  Future<void> removeOrphanedBlockStatsSites(Set<String> nonIncognitoSiteIds);

  /// Empties the single shared cookie jar the legacy engine partitions by
  /// hand. Only meaningful when [OrphanSweepEngine.sweep] runs with
  /// `useContainers: false`.
  Future<void> clearLegacyGlobalCookieJar();
}

/// Reclaims storage left behind by sites deleted in previous sessions. Runs
/// after first paint: the launched site reads its cookies from its own
/// container (or, under the legacy engine, from its hydrated model), so
/// nothing here is on the first-paint path.
class OrphanSweepEngine {
  OrphanSweepEngine._();

  /// Sweeps every per-site storage, then clears the shared cookie jar when
  /// the legacy engine owns it.
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
  }) async {
    await targets.removeOrphanedCookies(nonIncognitoSiteIds);
    await targets.removeOrphanedProxyPasswords(activeSiteIds);
    await targets.removeOrphanedHtmlCaches(nonIncognitoSiteIds);
    await targets.removeOrphanedHtmlImports(activeSiteIds);
    await targets.removeOrphanedWebViewState(nonIncognitoSiteIds);
    await targets.removeOrphanedBlockStatsSites(nonIncognitoSiteIds);
    if (!useContainers) {
      await targets.clearLegacyGlobalCookieJar();
    }
  }
}
