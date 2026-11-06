import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

void main() {
  testWidgets('the drawer tile menu renames a site through Edit (EDIT-006)',
      (tester) async {
    await pumpRealApp(
      tester,
      sites: [WebViewModel(initUrl: 'https://edit.test', name: 'Old Name')],
      prefs: {AppPref.legacyDesign.key: true},
    );
    await openWebspace(tester, name: 'All');
    await tester.tap(find.descendant(
      of: find.byKey(const Key('site_0')),
      matching: find.byIcon(Icons.more_vert),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Edit Site'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Site Name'), 'New Name');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await settleRealApp(tester);
    expect(find.text('New Name'), findsOneWidget);
    expect(find.text('Old Name'), findsNothing);
    expect(appSite('New Name').initUrl, 'https://edit.test');
  });
}
