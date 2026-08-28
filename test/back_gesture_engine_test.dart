import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/back_gesture_engine.dart';

BackGestureAction decide({
  bool drawerOpen = false,
  bool drawerOpenedByGesture = false,
  bool drawerAvailable = true,
  bool hasWebView = true,
  bool trustsCanGoBack = true,
  bool canGoBack = false,
  BackAtHistoryStart atHistoryStart = BackAtHistoryStart.ignore,
  bool canExitApp = true,
}) =>
    decideBackGesture(
      drawerOpen: drawerOpen,
      drawerOpenedByGesture: drawerOpenedByGesture,
      drawerAvailable: drawerAvailable,
      hasWebView: hasWebView,
      trustsCanGoBack: trustsCanGoBack,
      canGoBack: canGoBack,
      atHistoryStart: atHistoryStart,
      canExitApp: canExitApp,
    );

void main() {
  group('default: back walks history only (NAV-001, issue #369)', () {
    test('open drawer closes, never exits', () {
      expect(
        decide(drawerOpen: true, drawerOpenedByGesture: true),
        BackGestureAction.closeDrawer,
      );
    });

    test('history present navigates back', () {
      expect(decide(canGoBack: true), BackGestureAction.goBack);
    });

    test('start of history is a no-op', () {
      expect(decide(canGoBack: false), BackGestureAction.ignore);
    });

    test('no site shown is a no-op', () {
      expect(decide(hasWebView: false), BackGestureAction.ignore);
    });

    test('canGoBack is not consulted where it under-reports (NAV-002)', () {
      expect(
        decide(trustsCanGoBack: false, canGoBack: false),
        BackGestureAction.attemptGoBack,
      );
    });

    test('a failed attempt stays a no-op', () {
      expect(
        decideAfterAttemptedGoBack(
          urlChanged: false,
          drawerAvailable: true,
          atHistoryStart: BackAtHistoryStart.ignore,
        ),
        BackGestureAction.ignore,
      );
    });
  });

  group('opt-in: back opens the menu (NAV-009, issue #431)', () {
    const opt = BackAtHistoryStart.openMenu;

    test('start of history opens the drawer', () {
      expect(
        decide(canGoBack: false, atHistoryStart: opt),
        BackGestureAction.openDrawer,
      );
    });

    test('history still wins over the drawer', () {
      expect(
        decide(canGoBack: true, atHistoryStart: opt),
        BackGestureAction.goBack,
      );
    });

    test('a second gesture on that drawer leaves the app', () {
      expect(
        decide(drawerOpen: true, drawerOpenedByGesture: true, atHistoryStart: opt),
        BackGestureAction.closeDrawerAndExit,
      );
    });

    test('a drawer opened from the menu button only closes', () {
      expect(
        decide(drawerOpen: true, drawerOpenedByGesture: false, atHistoryStart: opt),
        BackGestureAction.closeDrawer,
      );
    });

    test('platforms that must not quit only close the drawer', () {
      expect(
        decide(
          drawerOpen: true,
          drawerOpenedByGesture: true,
          atHistoryStart: opt,
          canExitApp: false,
        ),
        BackGestureAction.closeDrawer,
      );
    });

    test('no site shown leaves the app instead of opening the drawer', () {
      expect(
        decide(hasWebView: false, atHistoryStart: opt),
        BackGestureAction.exitApp,
      );
      expect(
        decide(hasWebView: false, atHistoryStart: opt, canExitApp: false),
        BackGestureAction.ignore,
      );
    });

    test('a failed attempt opens the drawer (NAV-002 path)', () {
      expect(
        decideAfterAttemptedGoBack(
          urlChanged: false,
          drawerAvailable: true,
          atHistoryStart: opt,
        ),
        BackGestureAction.openDrawer,
      );
      expect(
        decideAfterAttemptedGoBack(
          urlChanged: true,
          drawerAvailable: true,
          atHistoryStart: opt,
        ),
        BackGestureAction.ignore,
      );
    });

    test('a locked kiosk shell keeps the default behaviour (KIOSK-002)', () {
      expect(
        decide(canGoBack: false, atHistoryStart: opt, drawerAvailable: false),
        BackGestureAction.ignore,
      );
      expect(
        decide(
          drawerOpen: true,
          drawerOpenedByGesture: true,
          atHistoryStart: opt,
          drawerAvailable: false,
        ),
        BackGestureAction.closeDrawer,
      );
      expect(
        decide(hasWebView: false, atHistoryStart: opt, drawerAvailable: false),
        BackGestureAction.ignore,
      );
      expect(
        decideAfterAttemptedGoBack(
          urlChanged: false,
          drawerAvailable: false,
          atHistoryStart: opt,
        ),
        BackGestureAction.ignore,
      );
    });
  });

  group('iOS edge-swipe fallback (NAV-009)', () {
    bool needs({
      bool isIOS = true,
      bool webViewVisible = true,
      bool drawerAvailable = true,
      BackAtHistoryStart atHistoryStart = BackAtHistoryStart.openMenu,
    }) =>
        needsEdgeSwipeFallback(
          isIOS: isIOS,
          webViewVisible: webViewVisible,
          drawerAvailable: drawerAvailable,
          atHistoryStart: atHistoryStart,
        );

    test('iOS claims the edge back from WKWebView when the setting is on', () {
      expect(needs(), isTrue);
    });

    test('the setting off leaves the native swipe alone (NAV-001)', () {
      expect(needs(atHistoryStart: BackAtHistoryStart.ignore), isFalse);
    });

    test('other platforms reach the policy through PopScope', () {
      expect(needs(isIOS: false), isFalse);
    });

    test('no strip over the site list, where there is no webview to go back in', () {
      expect(needs(webViewVisible: false), isFalse);
    });

    test('a locked kiosk shell has no drawer to open (KIOSK-002)', () {
      expect(needs(drawerAvailable: false), isFalse);
    });
  });
}
