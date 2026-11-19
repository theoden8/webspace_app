import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/real_app.dart';

/// FS-001: full screen is entered from the site menu or by a double tap on
/// the site's name in the app bar, and the double tap works again after an
/// exit. FS-002: it is left by the handle at the top edge or the tab strip's
/// menu, while the top corners and the back gesture leave it alone.
void main() {
  late List<String> modes;

  Future<void> openSite(WidgetTester tester,
      {Map<String, Object> prefs = const {}}) async {
    modes = [];
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
    await pumpRealApp(tester,
        sites: [WebViewModel(initUrl: 'https://example.com', name: 'Example')],
        prefs: prefs);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Example');
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(FullscreenExitHandle), findsNothing);
  }

  void expectFullscreen() {
    expect(find.byType(AppBar), findsNothing, reason: 'the app bar is hidden');
    expect(find.byType(FullscreenExitHandle), findsOneWidget);
    expect(modes, isNotEmpty);
    expect(modes.last, isNot('SystemUiMode.edgeToEdge'),
        reason: 'the system UI is hidden, all but a status bar the strip keeps');
  }

  Future<void> doubleTapTitle(WidgetTester tester) async {
    final title = find.descendant(
        of: find.byType(AppBar), matching: find.text('Example'));
    expect(title, findsOneWidget);
    await tester.tap(title);
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(title);
    await settleRealApp(tester);
  }

  testWidgets('FS-001: the site menu enters full screen', (tester) async {
    await openSite(tester);
    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await settleRealApp(tester);
    expectFullscreen();
  });

  testWidgets('FS-001: a double tap on the title enters full screen, again '
      'after an exit', (tester) async {
    await openSite(tester);
    await doubleTapTitle(tester);
    expectFullscreen();

    await tester.tap(find.byType(FullscreenExitHandle));
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(modes.last, 'SystemUiMode.edgeToEdge');

    await doubleTapTitle(tester);
    expectFullscreen();
  });

  Future<void> enterFromMenu(WidgetTester tester) async {
    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await settleRealApp(tester);
    expectFullscreen();
  }

  void expectLeft() {
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(FullscreenExitHandle), findsNothing);
    expect(modes.last, 'SystemUiMode.edgeToEdge');
  }

  testWidgets('FS-002: entering shows the hint, the handle at the top centre '
      'leaves, a top corner does not', (tester) async {
    await openSite(tester);
    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>).first);
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await tester.pump();
    expect(find.text('Tap the top of the screen to exit full screen'),
        findsOneWidget);
    await settleRealApp(tester);
    expectFullscreen();

    final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final x in [4.0, width - 4]) {
      await tester.tapAt(Offset(x, 6));
      await settleRealApp(tester);
      expectFullscreen();
    }
    await tester.tapAt(Offset(width / 2, 6));
    await settleRealApp(tester);
    expectLeft();
  });

  testWidgets('FS-002: the kept tab strip\'s menu reads Exit Full Screen and '
      'leaves', (tester) async {
    await openSite(tester,
        prefs: {'showTabStrip': true, 'tabStripInFullscreen': true});
    await enterFromMenu(tester);
    await tester.tap(find.byTooltip('Menu'));
    await settleRealApp(tester);
    expect(find.text('Full Screen'), findsNothing);
    await tester.tap(find.text('Exit Full Screen'));
    await settleRealApp(tester);
    expectLeft();
  });

  testWidgets('FS-002: the back gesture keeps full screen', (tester) async {
    await openSite(tester);
    await enterFromMenu(tester);
    await pressBack(tester);
    expectFullscreen();
  });
}
