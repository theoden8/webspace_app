import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/real_app.dart';

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  testWidgets(
      'BACKUP-008: the menu of a site on screen offers no import, export or '
      'App Settings', (tester) async {
    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: 'https://example.test', name: 'Site')],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Site');

    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
    await settleRealApp(tester);

    expect(find.text('Developer Tools'), findsOneWidget,
        reason: 'the menu is open');
    for (final label in ['Import Settings', 'Export Settings', 'App Settings']) {
      expect(find.text(label), findsNothing, reason: label);
    }
  });
}
