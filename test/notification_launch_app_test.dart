import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// A tap on a notification that starts the app reaches no tap callback: the
/// platform reports it only as how the app was launched. A cold start that
/// never asked opened on the webspace list, and the user found the site again
/// by hand.
void main() {
  final mail = WebViewModel(initUrl: 'https://mail.example.test', name: 'Mail')
    ..notificationsEnabled = true;
  final news = WebViewModel(initUrl: 'https://news.example.test', name: 'News');

  Finder inAppBar(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  testWidgets('a cold start from a notification opens its site',
      (tester) async {
    await pumpRealApp(
      tester,
      sites: [news, mail],
      launchedByNotificationFor: mail.siteId,
    );

    expect(inAppBar('Mail'), findsOneWidget);
  });

  testWidgets('a cold start from the launcher opens the webspace list',
      (tester) async {
    await pumpRealApp(tester, sites: [news, mail]);

    expect(inAppBar('Mail'), findsNothing);
    expect(find.text('All'), findsWidgets);
  });
}
