import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/fullscreen_system_ui.dart';
import 'package:webspace/settings/site_strip_edge.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/site_strip.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

import 'helpers/real_app.dart';

/// FS-011 (github #672). Under `immersiveSticky` a swiped-in navigation bar is
/// a transient overlay with no insets, so it covers the site strip kept in full
/// screen; under `immersive` it is a real bar the strip insets around. FS-012:
/// a strip along the top edge keeps the status bar and sits below it.
void main() {
  group('FullscreenSystemUi.of', () {
    test('sticky when full screen shows none of the app controls', () {
      expect(
        FullscreenSystemUi.of(
            kioskLocked: false, siteStripEdge: null, floatingControl: false),
        FullscreenSystemUi.barsHiddenSticky,
      );
    });

    test('bars hidden, revealable, when the tab strip is on screen at the '
        'bottom', () {
      expect(
        FullscreenSystemUi.of(
            kioskLocked: false,
            siteStripEdge: SiteStripEdge.bottom,
            floatingControl: false),
        FullscreenSystemUi.barsHidden,
      );
    });

    test('bars hidden, revealable, when the tab bar button can reveal the '
        'strip', () {
      expect(
        FullscreenSystemUi.of(
            kioskLocked: false, siteStripEdge: null, floatingControl: true),
        FullscreenSystemUi.barsHidden,
      );
    });

    test('the status bar kept when the tab strip is on screen at the top',
        () {
      for (final button in [true, false]) {
        expect(
          FullscreenSystemUi.of(
              kioskLocked: false,
              siteStripEdge: SiteStripEdge.top,
              floatingControl: button),
          FullscreenSystemUi.statusBarKept,
        );
      }
    });

    test('sticky in a locked kiosk session, whatever the strip and button', () {
      expect(
        FullscreenSystemUi.of(
            kioskLocked: true,
            siteStripEdge: SiteStripEdge.top,
            floatingControl: true),
        FullscreenSystemUi.barsHiddenSticky,
      );
    });

    test('a revealed bar stays unless the bars are sticky', () {
      expect(FullscreenSystemUi.barsHiddenSticky.revealedBarsStay, isFalse);
      expect(FullscreenSystemUi.barsHidden.revealedBarsStay, isTrue);
      expect(FullscreenSystemUi.statusBarKept.revealedBarsStay, isTrue);
    });
  });

  group('in the app', () {
    const navBar = 48.0;
    const statusBar = 32.0;
    const immersive = 'SystemUiMode.immersive';
    const immersiveSticky = 'SystemUiMode.immersiveSticky';
    const statusBarKept = 'SystemUiMode.manual [SystemUiOverlay.top]';
    late List<String> modes;

    setUp(() {
      modes = [];
    });

    Future<void> enterFullscreenOn(WidgetTester tester,
        {required Map<String, Object> prefs}) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          switch (call.method) {
            case 'SystemChrome.setEnabledSystemUIMode':
              modes.add(call.arguments as String);
            case 'SystemChrome.setEnabledSystemUIOverlays':
              modes.add('SystemUiMode.manual ${call.arguments}');
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
      expect(find.byTooltip('Open navigation menu'), findsNothing,
          reason: 'the site opened in full screen');
    }

    // What the platform reports for the bars on screen: their insets, and on
    // Android, under a mode where a revealed bar stays, that its overlays are
    // visible.
    Future<void> showSystemBars(WidgetTester tester,
        {double top = 0, double bottom = 0}) async {
      final dpr = tester.view.devicePixelRatio;
      tester.view.padding = FakeViewPadding(top: top * dpr, bottom: bottom * dpr);
      tester.view.viewPadding =
          FakeViewPadding(top: top * dpr, bottom: bottom * dpr);
      await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        SystemChannels.platform.name,
        SystemChannels.platform.codec.encodeMethodCall(
            const MethodCall('SystemChrome.systemUIChange', [true])),
        (_) {},
      );
      await tester.pump();
    }

    // FS-007
    testWidgets('a kept tab strip moves above a revealed navigation bar, '
        'which is hidden again', (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {
        'showTabStrip': true,
        'tabStripInFullscreen': true,
        'tabStripEdge': 'bottom',
      });
      expect(modes.last, immersive);

      final height = tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final chip = find.text('Example');
      expect(tester.getRect(chip).bottom, greaterThan(height - navBar),
          reason: 'the strip sits on the bottom edge while the bars are hidden');

      await showSystemBars(tester, bottom: navBar);
      expect(tester.getRect(chip).bottom, lessThanOrEqualTo(height - navBar),
          reason: 'the strip is above the navigation bar');

      final before = modes.length;
      await tester.pump(kRevealedSystemBarsHideDelay);
      expect(modes.sublist(before), [immersive],
          reason: 'the revealed bars are hidden again');
    });

    // FS-012
    testWidgets('a tab strip kept at the top keeps the status bar and sits '
        'below it', (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {
        'showTabStrip': true,
        'tabStripInFullscreen': true,
        'tabStripEdge': 'top',
      });
      expect(modes.last, statusBarKept);

      // The status bar the platform keeps reports its inset.
      await showSystemBars(tester, top: statusBar);
      expect(tester.getRect(find.byType(SiteStrip)).top, statusBar,
          reason: 'the strip sits directly below the status bar');

      // A navigation bar swiped in meanwhile stays, and is hidden again, as
      // under immersive (FS-011).
      await showSystemBars(tester, top: statusBar, bottom: navBar);
      final before = modes.length;
      await tester.pump(kRevealedSystemBarsHideDelay);
      expect(modes.sublist(before), [statusBarKept]);
    });

    // FS-009, FS-012
    testWidgets('the strip the tab bar button reveals at the top brings the '
        'status bar with it and takes it away', (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {
        'tabBarButton': true,
        'tabStripEdge': 'top',
      });
      expect(modes.last, immersive,
          reason: 'no strip on screen yet, so the bars hide');

      // The full screen hint covers the button's corner until it times out.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      await tester.tap(find.byType(TabBarCornerButton));
      await settleRealApp(tester);
      expect(find.byType(SiteStrip), findsOneWidget);
      expect(modes.last, statusBarKept);
      await showSystemBars(tester, top: statusBar);
      expect(tester.getRect(find.byType(SiteStrip)).top, statusBar);

      await tester.tap(find.descendant(
          of: find.byType(SiteStrip), matching: find.byIcon(Icons.close)));
      await settleRealApp(tester);
      expect(find.byType(SiteStrip), findsNothing);
      expect(modes.last, immersive, reason: 'the status bar hides again');
    });

    // FS-006: whatever bars the platform leaves on screen in full screen,
    // the page sits inside them; with none left it fills the screen.
    for (final (top, bottom) in [(statusBar, navBar), (0.0, 0.0)]) {
      testWidgets('FS-006: the page sits inside the bars left on screen, '
          '$top at the top and $bottom at the bottom', (tester) async {
        addTearDown(tester.view.reset);
        await enterFullscreenOn(tester, prefs: const {});
        await showSystemBars(tester, top: top, bottom: bottom);
        await tester.pumpAndSettle();
        final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
        final page = tester.getRect(find.byType(inapp.InAppWebView));
        expect(page.top, top);
        expect(page.bottom, screen.height - bottom);
        expect(page.width, screen.width);
      });
    }

    // FS-010: a cutout on a short edge. Full screen draws the page beside
    // it; out of full screen the body insets around it.
    testWidgets('FS-010: full screen draws into a short-edge cutout that the '
        'page otherwise avoids', (tester) async {
      addTearDown(tester.view.reset);
      const cutout = 40.0;
      final dpr = tester.view.devicePixelRatio;
      tester.view.padding = const FakeViewPadding(left: cutout * 3);
      tester.view.viewPadding = const FakeViewPadding(left: cutout * 3);
      expect(dpr, 3.0, reason: 'the cutout above is given in physical pixels');
      final site = WebViewModel(initUrl: 'https://example.com', name: 'Example');
      await pumpRealApp(tester, sites: [site]);
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'Example');
      expect(tester.getRect(find.byType(inapp.InAppWebView)).left, cutout,
          reason: 'out of full screen the page keeps clear of the notch');

      await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
      await settleRealApp(tester);
      await tester.tap(find.text('Full Screen'));
      await settleRealApp(tester);
      expect(find.byTooltip('Open navigation menu'), findsNothing);
      expect(tester.getRect(find.byType(inapp.InAppWebView)).left, 0,
          reason: 'in full screen it fills the strip beside the notch');
    });

    testWidgets('without the app controls full screen stays sticky',
        (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {'showTabStrip': true});
      expect(modes.last, immersiveSticky);

      await showSystemBars(tester, bottom: navBar);
      final before = modes.length;
      await tester.pump(kRevealedSystemBarsHideDelay);
      expect(modes.sublist(before), isEmpty,
          reason: 'sticky bars hide themselves');
    });

    testWidgets('FS-004: a resume in full screen asks for its system UI again',
        (tester) async {
      addTearDown(tester.view.reset);
      await enterFullscreenOn(tester, prefs: {'showTabStrip': true});
      expect(modes.last, immersiveSticky);

      final binding = tester.binding;
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await settleRealApp(tester);
      final before = modes.length;
      for (final state in const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        binding.handleAppLifecycleStateChanged(state);
      }
      await settleRealApp(tester);
      expect(modes.sublist(before), [immersiveSticky],
          reason: 'the OS can drop the immersive mode while the app is away');
    });
  });
}
