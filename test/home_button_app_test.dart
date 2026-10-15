import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/site_menu.dart';

import 'helpers/real_app.dart';

/// Home lands on the site's initial URL with no history behind it (NAV-004):
/// a `loadUrl` would keep the deep page on the back stack, so the webview is
/// built again rather than navigated.
void main() {
  const home = 'https://portal.example.test/';
  const deep = 'https://portal.example.test/a/b/c';

  testWidgets('Home builds the site a fresh webview at its initial URL (NAV-004)',
      (tester) async {
    await pumpRealApp(tester,
        sites: [WebViewModel(initUrl: home, name: 'Portal')]);
    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Portal');
    await attachWebViews(tester);
    await pageHistoryChanged(tester, url: deep);
    await settleRealApp(tester);
    expect(appSite('Portal').currentUrl, deep);
    final before = tester.state(find.byType(inapp.InAppWebView));

    await tester.tap(find.byType(PopupMenuButton<SiteMenuAction>));
    await settleRealApp(tester);
    await tester.tap(find.byTooltip('Go to Home'));
    await settleRealApp(tester);

    final view =
        tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
    expect(tester.state(find.byType(inapp.InAppWebView)), isNot(same(before)),
        reason: 'a new webview, so nothing is behind the home page');
    expect(view.platform.params.initialUrlRequest?.url.toString(), home);
    expect(appSite('Portal').currentUrl, home);
  });
}
