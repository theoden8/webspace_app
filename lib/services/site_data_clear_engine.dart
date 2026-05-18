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
///  - The #352 fix routed container mode through the fork's
///    `deleteContainer`. That depended on
///    `WKWebsiteDataStore.remove(forIdentifier:)` actually completing
///    while a WKWebView was being torn down — unreliable on iOS/macOS
///    (#360): pending JS handler callbacks / autorelease pools keep
///    the data store referenced past the Flutter platform-view
///    dispose, the remove silently no-ops, and the next bind reads
///    the same store back.
///  - This iteration routes container mode through the fork's
///    `clearContainerData` (privacy-v2 cut), which maps to
///    `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)` on
///    Apple — explicitly safe while a WKWebView is still bound. The
///    container stays in place; only its data is wiped. No orphan
///    accumulation, no rev bookkeeping.
class SiteDataClearPlan {
  /// Container mode: call
  /// [ContainerIsolationEngine.clearForSite] to wipe the live
  /// container's data in place. Legacy mode: false (no per-site
  /// native partition exists).
  final bool clearContainer;

  /// Null the cached webview widget on the model so the next
  /// IndexedStack rebuild constructs a fresh InAppWebView. Container
  /// mode uses this for UX (the user expects to see a fresh page
  /// load) and to drop in-memory state that `clearContainerData`
  /// doesn't reach on Android (per-WebView HTTP cache). Legacy mode
  /// reloads the existing controller instead.
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
  /// same controller; container mode skips because the dispose +
  /// IndexedStack rebuild constructs a fresh widget that loads
  /// against the freshly-emptied container.
  final bool userDrivenReload;

  const SiteDataClearPlan({
    required this.clearContainer,
    required this.disposeWebView,
    required this.clearInModelCookies,
    required this.deleteKnownCookies,
    required this.userDrivenReload,
  });

  @override
  bool operator ==(Object other) =>
      other is SiteDataClearPlan &&
      other.clearContainer == clearContainer &&
      other.disposeWebView == disposeWebView &&
      other.clearInModelCookies == clearInModelCookies &&
      other.deleteKnownCookies == deleteKnownCookies &&
      other.userDrivenReload == userDrivenReload;

  @override
  int get hashCode => Object.hash(
        clearContainer,
        disposeWebView,
        clearInModelCookies,
        deleteKnownCookies,
        userDrivenReload,
      );

  @override
  String toString() =>
      'SiteDataClearPlan(clearContainer=$clearContainer, '
      'disposeWebView=$disposeWebView, '
      'clearInModelCookies=$clearInModelCookies, '
      'deleteKnownCookies=$deleteKnownCookies, '
      'userDrivenReload=$userDrivenReload)';
}

class SiteDataClearEngine {
  SiteDataClearEngine._();

  /// Plan the per-site clear for the active isolation engine.
  ///
  /// Container mode (Android System WebView 110+ / iOS 17+ / macOS 14+ /
  /// Linux WPE 2.40+) routes through the fork's `clearContainerData`
  /// — drops cookies, localStorage, IndexedDB, ServiceWorkers, and
  /// HTTP cache for the named container in place, safe while a
  /// WKWebView is still bound. Legacy mode falls back to in-model
  /// cookie deletion + reload because there is no per-site partition
  /// to recreate and localStorage / IDB / SW are app-global.
  static SiteDataClearPlan planClear({required bool useContainers}) {
    if (useContainers) {
      return const SiteDataClearPlan(
        clearContainer: true,
        disposeWebView: true,
        clearInModelCookies: true,
        deleteKnownCookies: false,
        userDrivenReload: false,
      );
    }
    return const SiteDataClearPlan(
      clearContainer: false,
      disposeWebView: false,
      clearInModelCookies: false,
      deleteKnownCookies: true,
      userDrivenReload: true,
    );
  }
}
