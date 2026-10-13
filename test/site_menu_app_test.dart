import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/widgets/site_menu.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// The app bar and the tab strip carry the same site menu. They were two
/// copies once, and the strip's opened Developer Tools without the
/// background-refresh simulation.
void main() {
  for (final tabStrip in [false, true]) {
    testWidgets(
        'Developer Tools from the ${tabStrip ? 'tab strip' : 'app bar'} '
        'menu can simulate a background refresh', (tester) async {
      await pumpRealApp(
        tester,
        sites: [WebViewModel(initUrl: 'https://example.test', name: 'Site')],
        prefs: {'showTabStrip': tabStrip},
      );
      await openWebspace(tester, name: 'All');
      await openSiteFromDrawer(tester, name: 'Site');

      final menu = find.byType(PopupMenuButton<SiteMenuAction>);
      expect(menu, findsOneWidget);
      if (tabStrip) {
        expect(find.byTooltip('Menu'), findsOneWidget);
      }
      await tester.tap(menu);
      await settleRealApp(tester);
      await tester.tap(find.text('Developer Tools'));
      await settleRealApp(tester);

      final devTools = tester.widget<DevToolsScreen>(find.byType(DevToolsScreen));
      expect(devTools.onSimulateBackgroundRefresh, isNotNull);
    });
  }
}
