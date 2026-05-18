/// What `_WebSpacePageState._clearSiteData` must do when the user taps
/// the per-site "Clear Site Data" / "Clear Cookies" button.
///
/// Pure value class so the plan can be unit-tested independently of the
/// widget tree. Mirrors the `DispatchAction` pattern in
/// [link_intent_dispatch_engine.dart]: the engine decides the steps,
/// the executor in `main.dart` runs them.
///
/// The pre-refactor bug (0.2.3) was that the executor unconditionally
/// ran `deleteCookies` + `reload()` regardless of engine mode. In
/// container mode that left localStorage / IndexedDB / ServiceWorker /
/// HTTP cache resident in the container and only deleted the cookies
/// the in-model snapshot knew about — a reload from the same container
/// then re-read all the stale state. The container engine has a
/// nuclear option, [`ContainerIsolationEngine.wipeContainers`], but it
/// was wired only to the share-into-incognito flow.
class SiteDataClearPlan {
  /// Null the Dart-side controller / cached widget on the model before
  /// the wipe. Required but not sufficient for container mode: a Dart
  /// null-out alone leaves the native platform-view alive and bound to
  /// the container, so the wipe still no-ops — see
  /// [dropFromLoadedIndices] for the rest of the dance.
  final bool disposeWebView;

  /// Drop the index from `_loadedIndices` so the IndexedStack rebuild
  /// renders `SizedBox.shrink()` for it, unmounts the InAppWebView
  /// element, and tears down the native platform-view (WKWebView /
  /// AndroidView / WebKitWebView). Executor MUST wrap the drop in
  /// setState + `await WidgetsBinding.instance.endOfFrame` before the
  /// wipe — without the rebuild yield, `deleteContainer` races the
  /// still-bound webview and silently no-ops (see container_native.dart
  /// line 71-74). Executor MUST also re-add the index after the wipe
  /// so the lazy creation path binds a fresh widget to the now-empty
  /// container; otherwise the active tab stays blank until the user
  /// navigates away and back.
  final bool dropFromLoadedIndices;

  /// Wipe the per-site native container — drops cookies, localStorage,
  /// IndexedDB, ServiceWorker registrations, HTTP cache. The container
  /// is materialized empty on the next webview bind.
  final bool wipeContainer;

  /// Reset the in-model `cookies` snapshot to empty. In container mode
  /// the snapshot is otherwise unused for read-back, but legacy
  /// isolation reads it during capture-nuke-restore — clearing it here
  /// would corrupt that path.
  final bool clearInModelCookies;

  /// Iterate `WebViewModel.cookies` and call `deleteCookie` for each
  /// entry through the active cookie manager. Legacy mode only — the
  /// only scoped action available when there is no per-site partition.
  final bool deleteKnownCookies;

  /// User-driven reload after the clear. Container mode skips this:
  /// `disposeWebView` + setState forces the widget tree to recreate the
  /// webview, which loads from scratch against the new container.
  final bool userDrivenReload;

  const SiteDataClearPlan({
    required this.disposeWebView,
    required this.dropFromLoadedIndices,
    required this.wipeContainer,
    required this.clearInModelCookies,
    required this.deleteKnownCookies,
    required this.userDrivenReload,
  });

  @override
  bool operator ==(Object other) =>
      other is SiteDataClearPlan &&
      other.disposeWebView == disposeWebView &&
      other.dropFromLoadedIndices == dropFromLoadedIndices &&
      other.wipeContainer == wipeContainer &&
      other.clearInModelCookies == clearInModelCookies &&
      other.deleteKnownCookies == deleteKnownCookies &&
      other.userDrivenReload == userDrivenReload;

  @override
  int get hashCode => Object.hash(
        disposeWebView,
        dropFromLoadedIndices,
        wipeContainer,
        clearInModelCookies,
        deleteKnownCookies,
        userDrivenReload,
      );

  @override
  String toString() =>
      'SiteDataClearPlan(disposeWebView=$disposeWebView, '
      'dropFromLoadedIndices=$dropFromLoadedIndices, '
      'wipeContainer=$wipeContainer, '
      'clearInModelCookies=$clearInModelCookies, '
      'deleteKnownCookies=$deleteKnownCookies, '
      'userDrivenReload=$userDrivenReload)';
}

class SiteDataClearEngine {
  SiteDataClearEngine._();

  /// Plan the per-site clear for the active isolation engine.
  ///
  /// Container mode (Android System WebView 110+ / iOS 17+ / macOS 14+ /
  /// Linux WPE 2.40+) takes the full dispose + wipe + recreate path so
  /// every byte of partitioned state is dropped. Legacy mode falls back
  /// to in-model cookie deletion + reload because there is no per-site
  /// partition to recreate and localStorage / IDB / SW are app-global.
  static SiteDataClearPlan planClear({required bool useContainers}) {
    if (useContainers) {
      return const SiteDataClearPlan(
        disposeWebView: true,
        dropFromLoadedIndices: true,
        wipeContainer: true,
        clearInModelCookies: true,
        deleteKnownCookies: false,
        userDrivenReload: false,
      );
    }
    return const SiteDataClearPlan(
      disposeWebView: false,
      dropFromLoadedIndices: false,
      wipeContainer: false,
      clearInModelCookies: false,
      deleteKnownCookies: true,
      userDrivenReload: true,
    );
  }
}
