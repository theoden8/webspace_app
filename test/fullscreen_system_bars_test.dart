import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/fullscreen_system_ui.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// FS-011 (github #672). Under `immersiveSticky` a swiped-in navigation bar is
/// a transient overlay with no insets, so it covers the tab strip kept in full
/// screen; under `immersive` it is a real bar the strip insets around.
void main() {
  group('fullscreenSystemUiMode', () {
    test('sticky when full screen shows none of the app controls', () {
      expect(
        fullscreenSystemUiMode(
            tabStripInFullscreen: false, tabBarButton: false, kioskLocked: false),
        SystemUiMode.immersiveSticky,
      );
    });

    test('immersive when the tab strip stays in full screen', () {
      expect(
        fullscreenSystemUiMode(
            tabStripInFullscreen: true, tabBarButton: false, kioskLocked: false),
        SystemUiMode.immersive,
      );
    });

    test('immersive when the tab bar button can reveal the strip', () {
      expect(
        fullscreenSystemUiMode(
            tabStripInFullscreen: false, tabBarButton: true, kioskLocked: false),
        SystemUiMode.immersive,
      );
    });

    test('sticky in a locked kiosk session, which shows no strip or button', () {
      expect(
        fullscreenSystemUiMode(
            tabStripInFullscreen: true, tabBarButton: true, kioskLocked: true),
        SystemUiMode.immersiveSticky,
      );
    });
  });

  group('in the app', () {
    const navBar = 48.0;
    late List<String> modes;

    setUp(() {
      modes = [];
    });

    Future<void> enterFullscreenOn(WidgetTester tester,
        {required Map<String, Object> prefs}) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
            modes.add(call.arguments as String);
          }
          return null;
        },
      );
      final site = WebViewModel(
        initUrl: 'https://example.com',
        name: 'Example',
        fullscreenMode: true,
      );
      await pumpRealApp(tester, sites: [site], prefs: prefs);
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'Example');
    }

    // What Android does when the user swipes a bar in under `immersive`: the
    // bars become real, so the window reports their insets, and the platform
    // tells the app its overlays are visible.
    Future<void> revealSystemBars(WidgetTester tester) async {
      final dpr = tester.view.devicePixelRatio;
      tester.view.padding = FakeViewPadding(bottom: navBar * dpr);
      tester.view.viewPadding = FakeViewPadding(bottom: navBar * dpr);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.platform.name,
        SystemChannels.platform.codec.encodeMethodCall(
            const MethodCall('SystemChrome.systemUIChange', [true])),
        (_) {},
      );
      await tester.pump();
    }

    testWidgets('a kept tab strip moves above a revealed navigation bar, '
        'which is hidden again', (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {
        'showTabStrip': true,
        'tabStripInFullscreen': true,
      });
      expect(find.byTooltip('Open navigation menu'), findsNothing,
          reason: 'the site opened in full screen');
      expect(modes.last, 'SystemUiMode.immersive');

      final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final chip = find.text('Example');
      expect(tester.getRect(chip).bottom, greaterThan(height - navBar),
          reason: 'the strip sits on the bottom edge while the bars are hidden');

      await revealSystemBars(tester);
      expect(tester.getRect(chip).bottom, lessThanOrEqualTo(height - navBar),
          reason: 'the strip is above the navigation bar');

      final before = modes.length;
      await tester.pump(kRevealedSystemBarsHideDelay);
      expect(modes.sublist(before), ['SystemUiMode.immersive'],
          reason: 'the revealed bars are hidden again');
    });

    testWidgets('without the app controls full screen stays sticky',
        (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {'showTabStrip': true});
      expect(find.byTooltip('Open navigation menu'), findsNothing);
      expect(modes.last, 'SystemUiMode.immersiveSticky');

      await revealSystemBars(tester);
      final before = modes.length;
      await tester.pump(kRevealedSystemBarsHideDelay);
      expect(modes.sublist(before), isEmpty,
          reason: 'sticky bars hide themselves');
    });
  });
}
