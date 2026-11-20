import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_strip.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

import 'helpers/real_app.dart';

/// FS-009: in full screen set to Button, the strip's button reveals the
/// strip; a pick from it, leaving full screen or an app entry point put it
/// away. Out of full screen the strip is pinned and has no button.
void main() {
  Finder inStrip(Finder matching) =>
      find.descendant(of: find.byType(SiteStrip), matching: matching);
  Finder inAppBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  Future<void> start(WidgetTester tester, {required bool fullscreen}) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(
            initUrl: 'https://a.example.test',
            name: 'A',
            fullscreenMode: fullscreen),
        WebViewModel(
            initUrl: 'https://b.example.test',
            name: 'B',
            fullscreenMode: fullscreen),
      ],
      prefs: {'siteNavigation': 'strip', 'fullscreenNavigation': 'button'},
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'A');
    if (!fullscreen) return;
    // The full screen hint covers the button's corner until it times out.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    await tester.tap(find.byType(TabBarCornerButton));
    await settleRealApp(tester);
    expect(find.byType(SiteStrip), findsOneWidget);
  }

  testWidgets('out of full screen the strip is pinned, with no button',
      (tester) async {
    await start(tester, fullscreen: false);
    expect(find.byType(SiteStrip), findsOneWidget);
    expect(find.byType(TabBarCornerButton), findsNothing);

    await tester.tap(inStrip(find.text('B')));
    await settleRealApp(tester);
    expect(inAppBar('B'), findsOneWidget);
    expect(find.byType(SiteStrip), findsOneWidget);
  });

  testWidgets('in full screen a pick from it puts it away', (tester) async {
    await start(tester, fullscreen: true);

    await tester.tap(inStrip(find.text('B')));
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsNothing, reason: 'B opens in full screen');
    expect(find.byType(SiteStrip), findsNothing);
    expect(find.byType(TabBarCornerButton), findsOneWidget);
  });

  testWidgets('in full screen its dismiss control puts it away',
      (tester) async {
    await start(tester, fullscreen: true);

    await tester.tap(inStrip(find.byIcon(Icons.close)));
    await settleRealApp(tester);
    expect(find.byType(SiteStrip), findsNothing);
    expect(find.byType(TabBarCornerButton), findsOneWidget);
  });

  testWidgets('a notification tap puts it away', (tester) async {
    await start(tester, fullscreen: true);

    await tester.runAsync(() async {
      NotificationService.instance.onNotificationTapped!(appSite('B').siteId);
    });
    await settleRealApp(tester);
    expect(inStrip(find.text('B')), findsNothing);
    expect(find.byType(TabBarCornerButton), findsOneWidget);
  });
}
