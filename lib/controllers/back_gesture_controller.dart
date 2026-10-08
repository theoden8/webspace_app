import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/controllers/surface_repaint_controller.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/app_prefs.dart';

/// What the back gesture asks of the page.
abstract interface class BackGestureHost {
  bool get mounted;
  bool get kioskLocked;
  ScaffoldState? get scaffold;

  /// The controller of the site on screen, or null.
  WebViewController? get shownController;

  /// At the start of a tab's history: hands back to the tab that opened it,
  /// or closes it, and says whether it did (TAB-007, TAB-019).
  Future<bool> backAtTabStart();
}

/// The system back gesture over the page (NAV-001, NAV-009): walk the
/// webview's history, then by the user's choice open the drawer, and from the
/// drawer it opened, leave the app.
class BackGestureController {
  BackGestureController({
    required BackGestureHost host,
    required SurfaceRepaintController surface,
  })  : _host = host,
        _surface = surface;

  final BackGestureHost _host;
  final SurfaceRepaintController _surface;
  final _backGuard = ReentryGuard();

  /// Any drawer that closes was the gesture's to escalate from no longer.
  void drawerChanged({required bool open}) {
    if (!open) _drawerOpenedByBackGesture = false;
  }

  // NAV-009: what the back gesture does at the start of a site's history.
  // Off by default — the gesture only walks webview history (issue #369);
  // turning it on opens the drawer there, and again to leave the app (#431).
  // Pinned off where the setting is not offered.
  BackAtHistoryStart get _backAtHistoryStart =>
      _backAtHistoryStartOffered && AppPref.backOpensMenu.value
          ? BackAtHistoryStart.openMenu
          : BackAtHistoryStart.ignore;

  bool get _backAtHistoryStartOffered => backAtHistoryStartConfigurable(
        isIOS: hostIsIOS,
        isMacOS: hostIsMacOS,
      );

  // True while the drawer showing is the one the back gesture itself opened.
  // Only that drawer escalates to leaving the app on the next gesture.
  bool _drawerOpenedByBackGesture = false;

  void _openDrawerFromBackGesture(ScaffoldState? scaffoldState) {
    if (scaffoldState == null) return;
    _drawerOpenedByBackGesture = true;
    scaffoldState.openDrawer();
  }

  /// Resolve one back gesture: the Android system back button, or a pushable
  /// route's pop.
  Future<void> handle() async {
    await _backGuard.run(() async {
      final scaffoldState = _host.scaffold;
      final drawerOpen = scaffoldState?.isDrawerOpen ?? false;
      final controller = _host.shownController;
      // Android's canGoBack() is reliable (including for pushState/SPA
      // entries on Chromium). Trust it directly: URL-comparison can
      // false-positive when goBack() succeeds but the navigation
      // hasn't propagated within the timeout. iOS/macOS decide from the
      // URL diff instead, so they don't sample it at all.
      final canGoBack = !drawerOpen && controller != null && hostIsAndroid
          ? await controller.canGoBack()
          : false;
      if (!_host.mounted) return;
      final action = decideBackGesture(
        drawerOpen: drawerOpen,
        drawerOpenedByGesture: _drawerOpenedByBackGesture,
        drawerAvailable: !_host.kioskLocked,
        hasWebView: controller != null,
        trustsCanGoBack: hostIsAndroid,
        canGoBack: canGoBack,
        atHistoryStart: _backAtHistoryStart,
        canExitApp: hostIsAndroid,
      );
      // At the start of the page history the gesture is still spendable: a
      // tab the user opened from another tab closes and hands back to it
      // (TAB-007). Only then does NAV-001 / NAV-009 get the gesture.
      if ((action == BackGestureAction.ignore ||
              action == BackGestureAction.openDrawer) &&
          controller != null &&
          !drawerOpen) {
        if (await _host.backAtTabStart()) return;
        if (!_host.mounted) return;
      }
      switch (action) {
        case BackGestureAction.ignore:
          LogTag.navigation.debug('Back gesture: nothing to do, ignoring');
          break;
        case BackGestureAction.closeDrawer:
          LogTag.navigation.debug('Back gesture: closing open drawer');
          _host.scaffold?.closeDrawer();
          break;
        case BackGestureAction.closeDrawerAndExit:
          LogTag.navigation.debug(
              'Back gesture: closing drawer and leaving app');
          _host.scaffold?.closeDrawer();
          await SystemNavigator.pop();
          break;
        case BackGestureAction.openDrawer:
          LogTag.navigation.debug('Back gesture: no history, opening drawer');
          _openDrawerFromBackGesture(scaffoldState);
          break;
        case BackGestureAction.exitApp:
          LogTag.navigation.debug('Back gesture: no site shown, leaving app');
          await SystemNavigator.pop();
          break;
        case BackGestureAction.goBack:
          await _goBackAndRepaint(controller!);
          LogTag.navigation.debug('Back gesture: navigated back (canGoBack)');
          break;
        case BackGestureAction.attemptGoBack:
          // iOS/macOS: canGoBack() can return false for pushState
          // entries, so attempt goBack() unconditionally and use URL
          // comparison as the authoritative check.
          final urlBefore = (await controller!.getUrl())?.toString();
          await controller.goBack();
          // Give the native webview time to process the navigation
          await Future.delayed(const Duration(milliseconds: 150));
          if (!_host.mounted) return;
          final urlAfter = (await controller.getUrl())?.toString();
          final urlChanged = urlBefore != urlAfter;
          LogTag.navigation.debug(urlChanged
              ? 'Back gesture: navigated back from $urlBefore to $urlAfter'
              : 'Back gesture: URL unchanged ($urlAfter)', sensitive: true);
          if (!urlChanged) {
            // Same rule as the Android branch above, reached the only way
            // Apple can reach it: the URL did not move, so the tab is at the
            // start of its own history.
            if (await _host.backAtTabStart()) return;
            if (!_host.mounted) return;
          }
          final next = decideAfterAttemptedGoBack(
            urlChanged: urlChanged,
            drawerAvailable: !_host.kioskLocked,
            atHistoryStart: _backAtHistoryStart,
          );
          if (next == BackGestureAction.openDrawer) {
            LogTag.navigation.debug('Back gesture: no history, opening drawer');
            _openDrawerFromBackGesture(_host.scaffold);
          }
          break;
      }
    });
  }

  /// Navigate the visible webview back one history entry, then recomposite the
  /// Android surface. A back/forward-cache restore re-attaches a fresh
  /// hybrid-composition SurfaceView that can come back blank-white, and back
  /// navigation passes through neither `setCurrentIndex` nor `onControllerReady`
  /// (the existing nudge chokepoints), so it would otherwise stay uncovered.
  /// No-op off Android.
  Future<void> _goBackAndRepaint(WebViewController controller) async {
    await controller.goBack();
    _surface.nudge('back');
  }

  /// The menu's Back: one step back where the page has history.
  Future<void> goBackIfPossible() async {
    final controller = _host.shownController;
    if (controller == null || !await controller.canGoBack()) return;
    await _goBackAndRepaint(controller);
  }
}
