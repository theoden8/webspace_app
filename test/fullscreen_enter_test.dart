import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/fullscreen_overlays.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/widgets/site_tab_strip.dart';

import 'helpers/real_app.dart';

/// FS-001. Full screen is entered from the site menu, on the app bar or on the
/// tab strip, and by double-tapping the site's name in the app bar, again
/// after leaving it.
void main() {
  late List<String> modes;

  Future<void> openSite(WidgetTester tester,
      {Map<String, Object> prefs = const {}}) async {
    modes = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          modes.add(call.arguments as String);
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
    expect(find.byType(SiteTabStrip), findsNothing,
        reason: 'the tab strip is hidden');
    expect(find.byType(FullscreenExitHandle), findsOneWidget);
    expect(modes.last, startsWith('SystemUiMode.immersive'),
        reason: 'the system bars are hidden');
  }

  Future<void> chooseFullScreen(WidgetTester tester, {required Finder menu}) async {
    await tester.tap(menu);
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await settleRealApp(tester);
  }

  testWidgets('the app bar menu enters full screen (FS-001)', (tester) async {
    await openSite(tester);
    await chooseFullScreen(tester,
        menu: find.descendant(
            of: find.byType(AppBar), matching: find.byType(SiteMenuButton)));
    expectFullscreen();
  });

  testWidgets('the tab strip menu enters full screen (FS-001)', (tester) async {
    await openSite(tester, prefs: {'showTabStrip': true});
    expect(find.byType(SiteTabStrip), findsOneWidget);
    await chooseFullScreen(tester,
        menu: find.descendant(
            of: find.byType(SiteTabStrip), matching: find.byType(SiteMenuButton)));
    expectFullscreen();
  });

  testWidgets('a double tap on the title enters full screen, again after '
      'leaving it (FS-001)', (tester) async {
    await openSite(tester);
    Future<void> doubleTapTitle() async {
      final title = find.descendant(
          of: find.byType(AppBar), matching: find.text('Example'));
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(title);
      await settleRealApp(tester);
    }

    await doubleTapTitle();
    expectFullscreen();

    await tester.tap(find.byType(FullscreenExitHandle));
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsOneWidget, reason: 'full screen was left');

    await doubleTapTitle();
    expectFullscreen();
  });
}
