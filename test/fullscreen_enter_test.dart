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
/// exit.
void main() {
  late List<String> modes;

  Future<void> openSite(WidgetTester tester) async {
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
        sites: [WebViewModel(initUrl: 'https://example.com', name: 'Example')]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Example');
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(FullscreenExitHandle), findsNothing);
  }

  void expectFullscreen() {
    expect(find.byType(AppBar), findsNothing, reason: 'the app bar is hidden');
    expect(find.byType(FullscreenExitHandle), findsOneWidget);
    expect(modes, isNotEmpty);
    expect(modes.last, startsWith('SystemUiMode.immersive'),
        reason: 'the system UI is hidden');
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
}
