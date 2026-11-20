import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/site_tab_strip.dart';

import 'helpers/real_app.dart';

/// FS-002. Full screen is left by a tap on the handle centred at the top
/// of the page, just below the inset a status bar that stays keeps,
/// whose corners stay with the page, or from the kept tab strip's menu;
/// entering it says so once; back does what it does outside full screen and
/// leaves full screen on.
void main() {
  const statusBar = 24.0;

  Future<void> enterFullscreen(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    addTearDown(tester.view.reset);
    final dpr = tester.view.devicePixelRatio;
    tester.view.padding = FakeViewPadding(top: statusBar * dpr);
    tester.view.viewPadding = FakeViewPadding(top: statusBar * dpr);
    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: 'https://example.com', name: 'Example')],
      prefs: prefs,
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Example');
    // The app bar's menu, or the strip's where a strip is shown.
    await tester.tap(find.byType(SiteMenuButton).first);
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await tester.pump();
  }

  bool inFullscreen() =>
      find.byType(FullscreenExitHandle).evaluate().isNotEmpty &&
      find.byType(AppBar).evaluate().isEmpty;

  Rect handleBand(WidgetTester tester) => tester.getRect(
    find.descendant(
      of: find.byType(FullscreenExitHandle),
      matching: find.byType(GestureDetector),
    ),
  );

  testWidgets('entering shows the hint and a handle below the status bar '
      '(FS-002)', (tester) async {
    await enterFullscreen(tester);
    expect(
      find.text('Tap the top of the screen to exit full screen'),
      findsOneWidget,
    );
    await settleRealApp(tester);
    expect(inFullscreen(), isTrue);
    final band = handleBand(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    expect(
      band.top,
      statusBar,
      reason:
          'below the top inset the body keeps '
          'for a status bar that stays',
    );
    expect(band.height, 20);
    expect(band.width, 96);
    expect(band.center.dx, width / 2);
  });

  testWidgets('a tap on the handle leaves full screen (FS-002)', (
    tester,
  ) async {
    await enterFullscreen(tester);
    await settleRealApp(tester);
    await tester.tapAt(handleBand(tester).center);
    await settleRealApp(tester);
    expect(inFullscreen(), isFalse);
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets('a tap in a top corner stays with the page (FS-002)', (
    tester,
  ) async {
    await enterFullscreen(tester);
    await settleRealApp(tester);
    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final corner in [const Offset(8, 8), Offset(width - 8, 8)]) {
      await tester.tapAt(corner);
      await settleRealApp(tester);
      expect(inFullscreen(), isTrue, reason: 'the tap at $corner');
    }
  });

  testWidgets('the kept tab strip\'s menu reads Exit Full Screen and leaves '
      'it (FS-002)', (tester) async {
    await enterFullscreen(
      tester,
      prefs: {'showTabStrip': true, 'tabStripInFullscreen': true},
    );
    await settleRealApp(tester);
    expect(inFullscreen(), isTrue);
    await tester.tap(
      find.descendant(
        of: find.byType(SiteTabStrip),
        matching: find.byType(SiteMenuButton),
      ),
    );
    await settleRealApp(tester);
    expect(find.text('Full Screen'), findsNothing);
    await tester.tap(find.text('Exit Full Screen'));
    await settleRealApp(tester);
    expect(inFullscreen(), isFalse);
  });

  testWidgets('back keeps full screen on (FS-002)', (tester) async {
    await enterFullscreen(tester);
    await settleRealApp(tester);
    await tester.binding.handlePopRoute();
    await settleRealApp(tester);
    expect(
      find.byType(FullscreenExitHandle),
      findsOneWidget,
      reason: 'back did not leave full screen',
    );
  });
}
