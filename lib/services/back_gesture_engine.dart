/// Decision policy for the system back gesture on the main page.
///
/// Pure logic: the call site in `_WebSpacePageState` owns the Navigator, the
/// ScaffoldState and `SystemNavigator`. Spec:
/// `openspec/specs/navigation/spec.md` (NAV-001, NAV-002, NAV-009).
library;

enum BackGestureAction {
  /// Swallow the gesture: no navigation, no drawer, no exit.
  ignore,

  /// Navigate back in webview history (history is known to exist).
  goBack,

  /// Attempt `goBack()` and decide from the before/after URL diff, because
  /// `canGoBack()` under-reports `pushState` entries (NAV-002, iOS/macOS).
  attemptGoBack,

  /// Close the open drawer.
  closeDrawer,

  /// Close the open drawer and leave the app (NAV-009).
  closeDrawerAndExit,

  /// Open the navigation drawer (NAV-009).
  openDrawer,

  /// Leave the app (NAV-009).
  exitApp,
}

/// What the back gesture does once there is no page left to go back to.
///
/// [BackAtHistoryStart.ignore] is the default (issue #369): the gesture only
/// ever walks webview history. [BackAtHistoryStart.openMenu] restores the
/// pre-#371 behaviour (issue #431): the drawer opens, and a second gesture on
/// that drawer leaves the app.
enum BackAtHistoryStart { ignore, openMenu }

/// Decides what a back gesture means before any webview navigation is
/// attempted.
///
/// [drawerOpenedByGesture] distinguishes a drawer this policy opened from one
/// the user opened via the AppBar menu button: only the former escalates to
/// leaving the app, so back never quits from a deliberately opened menu.
/// [drawerAvailable] is false while the kiosk shell is locked (KIOSK-002),
/// which pins the gesture to the default behaviour.
BackGestureAction decideBackGesture({
  required bool drawerOpen,
  required bool drawerOpenedByGesture,
  required bool drawerAvailable,
  required bool hasWebView,
  required bool trustsCanGoBack,
  required bool canGoBack,
  required BackAtHistoryStart atHistoryStart,
  required bool canExitApp,
}) {
  final openMenu = atHistoryStart == BackAtHistoryStart.openMenu && drawerAvailable;
  if (drawerOpen) {
    return openMenu && drawerOpenedByGesture && canExitApp
        ? BackGestureAction.closeDrawerAndExit
        : BackGestureAction.closeDrawer;
  }
  if (!hasWebView) {
    // The site list is on screen; opening the drawer over it would show the
    // same sites twice, so the gesture either leaves the app or does nothing.
    return openMenu && canExitApp ? BackGestureAction.exitApp : BackGestureAction.ignore;
  }
  if (!trustsCanGoBack) return BackGestureAction.attemptGoBack;
  if (canGoBack) return BackGestureAction.goBack;
  return openMenu ? BackGestureAction.openDrawer : BackGestureAction.ignore;
}

/// Decides what remains to be done after [BackGestureAction.attemptGoBack]
/// ran. [urlChanged] is the authoritative "back succeeded" signal (NAV-002).
BackGestureAction decideAfterAttemptedGoBack({
  required bool urlChanged,
  required bool drawerAvailable,
  required BackAtHistoryStart atHistoryStart,
}) {
  if (urlChanged) return BackGestureAction.ignore;
  return atHistoryStart == BackAtHistoryStart.openMenu && drawerAvailable
      ? BackGestureAction.openDrawer
      : BackGestureAction.ignore;
}
