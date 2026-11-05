import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_drawer.dart';

import 'helpers/real_app.dart';

const _title = 'My Dashboard';

void main() {
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));

  testWidgets(
      'EDIT-002: a site named by its page title shows the title in the app '
      'bar and the drawer', (tester) async {
    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: 'https://dash.example/')],
    );
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'dash.example');
    await attachWebViews(tester);
    webViewTitle = _title;
    await pageHistoryChanged(tester, url: 'https://dash.example/home');
    await settleRealApp(tester);

    expect(
        find.descendant(of: find.byType(AppBar), matching: find.text(_title)),
        findsOneWidget,
        reason: 'the app bar');

    await tester.tap(find.byTooltip('Open navigation menu'));
    await settleRealApp(tester);
    expect(
        find.descendant(
            of: find.byType(SiteDrawer), matching: find.text(_title)),
        findsOneWidget,
        reason: 'the drawer');
  });
}
