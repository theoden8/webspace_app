import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

Finder _slot(String name) =>
    find.byKey(GlobalObjectKey(appSite(name)), skipOffstage: false);

void main() {
  testWidgets('a site gets a webview when first visited and keeps it '
      '(LAZY-001, LAZY-002, LAZY-003)', (tester) async {
    await pumpRealApp(tester, sites: [
      WebViewModel(initUrl: 'https://a.test', name: 'Lazy A'),
      WebViewModel(initUrl: 'https://b.test', name: 'Lazy B'),
    ]);
    expect(_slot('Lazy A'), findsNothing);
    expect(_slot('Lazy B'), findsNothing);

    await openWebspace(tester, name: 'All');
    await openSiteFromDrawer(tester, name: 'Lazy A');
    expect(_slot('Lazy A'), findsOneWidget);
    expect(_slot('Lazy B'), findsNothing,
        reason: 'a site not yet visited holds a placeholder');

    await openSiteFromDrawer(tester, name: 'Lazy B');
    expect(_slot('Lazy B'), findsOneWidget);
    expect(_slot('Lazy A'), findsOneWidget,
        reason: 'a visited site keeps its webview off screen');
  });
}
