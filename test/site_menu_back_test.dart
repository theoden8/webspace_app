import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/real_app.dart';

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  for (final tabStrip in [false, true]) {
    for (final history in [true, false]) {
      testWidgets(
          'NAV-005: Back in the ${tabStrip ? 'tab strip' : 'app bar'} menu '
          '${history ? 'goes back' : 'does nothing'} where the page has '
          '${history ? 'a' : 'no'} page behind it, and closes the menu',
          (tester) async {
        await pumpRealApp(
          tester,
          sites: [WebViewModel(initUrl: 'https://example.test', name: 'Site')],
          prefs: {'showTabStrip': tabStrip},
        );
        await openWebspace(tester, name: 'All');
        await openSiteFromDrawer(tester, name: 'Site');
        await attachWebViews(tester);
        webViewCanGoBack = history;

        await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
        await settleRealApp(tester);
        expect(find.text('Developer Tools'), findsOneWidget,
            reason: 'the menu is open');
        webViewCalls.clear();
        await tester.tap(find.descendant(
            of: find.byWidgetPredicate((w) => w is PopupMenuItem),
            matching: find.widgetWithIcon(IconButton, Icons.arrow_back)));
        await settleRealApp(tester);

        expect(find.text('Developer Tools'), findsNothing,
            reason: 'the menu closed');
        expect(webViewCalls, contains(#canGoBack));
        expect(webViewCalls.contains(#goBack), history);
      });
    }
  }
}
