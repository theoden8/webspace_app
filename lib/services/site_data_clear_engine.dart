/// What `_WebSpacePageState._clearSiteData` must do when the user taps
/// the per-site "Clear Site Data" / "Clear Cookies" button.
///
/// Pure value class so the plan can be unit-tested independently of the
/// widget tree. Mirrors the `DispatchAction` pattern in
/// [link_intent_dispatch_engine.dart]: the engine decides the steps,
/// the executor in `main.dart` runs them.
///
/// History:
///
///  - The 0.2.3 bug was that the executor unconditionally ran
///    `deleteCookies` + `reload()` regardless of engine mode. In
///    container mode that left localStorage / IndexedDB /
///    ServiceWorker / HTTP cache resident.
///  - The #352 fix routed container mode through
///    `wipeContainers` to drop the named store. That depended on the
///    fork's `WKWebsiteDataStore.remove(forIdentifier:)` actually
///    completing while the WKWebView was being torn down — unreliable
///    on iOS/macOS (#360): pending JS handler callbacks /
///    autorelease pools keep the data store referenced past the
///    Flutter platform-view dispose, the remove silently no-ops, and
///    the next bind reads the same store back.
///  - This iteration sidesteps that entirely. Each model carries a
///    `containerRev`; clear bumps it, the next webview binds to a
///    fresh `ws-<siteId>_r<rev>` store, and the previous-rev container
///    becomes an orphan that startup GC sweeps when the underlying
///    WKWebView is finally gone. The wipe is no longer load-bearing.
class SiteDataClearPlan {
  /// Container mode: increment `WebViewModel.containerRev` so the next
  /// webview binds to a never-used container. Legacy mode: false (no
  /// per-site native partition exists).
  final bool bumpContainerRev;

  /// Null the cached webview widget on the model so the next
  /// IndexedStack rebuild re-runs `getWebView` and constructs a fresh
  /// InAppWebView. Required in container mode so the new widget picks
  /// up the new rev; legacy mode reloads the existing controller
  /// instead.
  final bool disposeWebView;

  /// Reset the in-model cookie snapshot. Container mode does this so
  /// the persisted JSON doesn't carry stale entries until the new
  /// webview's `onLoadStop` overwrites them; legacy mode MUST NOT do
  /// this because [CookieIsolationEngine.preDeleteCookieCleanup] reads
  /// the snapshot.
  final bool clearInModelCookies;

  /// Iterate `WebViewModel.cookies` and call `deleteCookie` for each
  /// entry through the active cookie manager. Legacy mode only — the
  /// only scoped action available when there is no per-site partition.
  final bool deleteKnownCookies;

  /// User-driven reload after the clear. Legacy mode reloads on the
  /// same controller; container mode skips because the rev bump +
  /// dispose forces the IndexedStack to rebuild a fresh widget against
  /// a fresh container.
  final bool userDrivenReload;

  /// Container mode: kick off a best-effort orphan GC pass so the
  /// previous-rev container's on-disk data is dropped promptly when
  /// the platform-view dispose has finished. If GC can't delete it
  /// (e.g. a JS handler is still retaining the WKWebView), startup
  /// GC will catch it on next launch — the user's session is already
  /// clean from their perspective because the new webview is in the
  /// new container.
  final bool gcOrphans;

  const SiteDataClearPlan({
    required this.bumpContainerRev,
    required this.disposeWebView,
    required this.clearInModelCookies,
    required this.deleteKnownCookies,
    required this.userDrivenReload,
    required this.gcOrphans,
  });

  @override
  bool operator ==(Object other) =>
      other is SiteDataClearPlan &&
      other.bumpContainerRev == bumpContainerRev &&
      other.disposeWebView == disposeWebView &&
      other.clearInModelCookies == clearInModelCookies &&
      other.deleteKnownCookies == deleteKnownCookies &&
      other.userDrivenReload == userDrivenReload &&
      other.gcOrphans == gcOrphans;

  @override
  int get hashCode => Object.hash(
        bumpContainerRev,
        disposeWebView,
        clearInModelCookies,
        deleteKnownCookies,
        userDrivenReload,
        gcOrphans,
      );

  @override
  String toString() =>
      'SiteDataClearPlan(bumpContainerRev=$bumpContainerRev, '
      'disposeWebView=$disposeWebView, '
      'clearInModelCookies=$clearInModelCookies, '
      'deleteKnownCookies=$deleteKnownCookies, '
      'userDrivenReload=$userDrivenReload, '
      'gcOrphans=$gcOrphans)';
}

class SiteDataClearEngine {
  SiteDataClearEngine._();

  /// Plan the per-site clear for the active isolation engine.
  ///
  /// Container mode (Android System WebView 110+ / iOS 17+ / macOS 14+ /
  /// Linux WPE 2.40+) takes the rev-bump path: a brand new container
  /// is materialized by the next bind, and the old one is left to the
  /// orphan GC. Legacy mode falls back to in-model cookie deletion +
  /// reload because there is no per-site partition to recreate and
  /// localStorage / IDB / SW are app-global.
  static SiteDataClearPlan planClear({required bool useContainers}) {
    if (useContainers) {
      return const SiteDataClearPlan(
        bumpContainerRev: true,
        disposeWebView: true,
        clearInModelCookies: true,
        deleteKnownCookies: false,
        userDrivenReload: false,
        gcOrphans: true,
      );
    }
    return const SiteDataClearPlan(
      bumpContainerRev: false,
      disposeWebView: false,
      clearInModelCookies: false,
      deleteKnownCookies: true,
      userDrivenReload: true,
      gcOrphans: false,
    );
  }
}
