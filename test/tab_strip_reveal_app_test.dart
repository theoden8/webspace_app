import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_drawer.dart';
import 'package:webspace/widgets/site_tab_strip.dart';
import 'package:webspace/widgets/tab_bar_corner_button.dart';

import 'helpers/real_app.dart';

/// FS-009: a strip the tab-bar button reveals stays through a site switch out
/// of full screen; its dismiss control, full screen and an app entry point put
/// it away.
void main() {
  Finder inStrip(Finder matching) =>
      find.descendant(of: find.byType(SiteTabStrip), matching: matching);
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
      prefs: {'tabBarButton': true},
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'A');
    if (fullscreen) {
      // The full screen hint covers the button's corner until it times out.
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
    await tester.tap(find.byType(TabBarCornerButton));
    await settleRealApp(tester);
    expect(find.byType(SiteTabStrip), findsOneWidget);
  }

  testWidgets('out of full screen it stays through a site switch until its '
      'dismiss control', (tester) async {
    await start(tester, fullscreen: false);

    await tester.tap(inStrip(find.text('B')));
    await settleRealApp(tester);
    expect(inAppBar('B'), findsOneWidget);
    expect(find.byType(SiteTabStrip), findsOneWidget,
        reason: 'a pick from the strip keeps it');

    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    await tester.tap(find.descendant(
        of: find.byType(SiteDrawer), matching: find.text('A')));
    await settleRealApp(tester);
    expect(inAppBar('A'), findsOneWidget);
    expect(find.byType(SiteTabStrip), findsOneWidget,
        reason: 'a switch from the drawer keeps it');

    await tester.tap(inStrip(find.byIcon(Icons.close)));
    await settleRealApp(tester);
    expect(find.byType(SiteTabStrip), findsNothing);
    expect(find.byType(TabBarCornerButton), findsOneWidget);
  });

  testWidgets('in full screen a pick from it puts it away', (tester) async {
    await start(tester, fullscreen: true);

    await tester.tap(inStrip(find.text('B')));
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsNothing, reason: 'B opens in full screen');
    expect(find.byType(SiteTabStrip), findsNothing);
    expect(find.byType(TabBarCornerButton), findsOneWidget);
  });

  testWidgets('entering full screen puts it away', (tester) async {
    await start(tester, fullscreen: false);

    await tester.tap(inStrip(find.byTooltip('Menu')));
    await settleRealApp(tester);
    await tester.tap(find.text('Full Screen'));
    await settleRealApp(tester);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byType(SiteTabStrip), findsNothing);
  });

  testWidgets('a notification tap puts it away', (tester) async {
    await start(tester, fullscreen: false);

    await tester.runAsync(() async {
      NotificationService.instance.onNotificationTapped!(appSite('B').siteId);
    });
    await settleRealApp(tester);
    expect(inAppBar('B'), findsOneWidget);
    expect(find.byType(SiteTabStrip), findsNothing);
  });
}
