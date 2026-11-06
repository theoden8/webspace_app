import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

void main() {
  testWidgets('a new webspace takes the sites ticked for it (WEBSPACE-001)',
      (tester) async {
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(initUrl: 'https://a.test', name: 'Site Alpha'),
        WebViewModel(initUrl: 'https://b.test', name: 'Site Beta'),
      ],
      prefs: {AppPref.legacyDesign.key: true},
    );
    expect(find.text('2 sites'), findsOneWidget);

    await tester.tap(find.text('Create Webspace'));
    await settleRealApp(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Webspace Name'), 'Alpha Only');
    await tester.tap(find.widgetWithText(CheckboxListTile, 'Site Alpha'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Save'));
    await settleRealApp(tester);
    expect(
      find.descendant(
        of: find.ancestor(
            of: find.text('Alpha Only'), matching: find.byType(ListTile)),
        matching: find.text('1 sites'),
      ),
      findsOneWidget,
    );
  });
}
