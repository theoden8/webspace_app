// Webspace site-membership integration test.
//
// Drives the multi-select flow on WebspaceDetailScreen: pre-seeds two
// sites in SharedPreferences (no activation — _currentIndex stays
// null), creates a custom webspace, toggles one site into membership,
// saves, asserts the resulting "1 sites" subtitle on the new tile.
//
// Closes the test gap on the webspace's Select Sites UI — pure widget
// flow, no WebView mount.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    isDemoMode = true;

    final siteA = WebViewModel(
      siteId: 'site-a',
      initUrl: 'http://example-a.invalid/',
      name: 'Site Alpha',
    );
    final siteB = WebViewModel(
      siteId: 'site-b',
      initUrl: 'http://example-b.invalid/',
      name: 'Site Beta',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [
        jsonEncode(siteA.toJson()),
        jsonEncode(siteB.toJson()),
      ],
    });
  });

  testWidgets(
    'WebspaceDetail multi-select adds the chosen site to the new webspace',
    (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 30));

      void dumpTexts(String label) {
        // ignore: avoid_print
        print('$label texts: '
            '${find.byType(Text).evaluate().map((e) {
          final w = e.widget;
          return w is Text ? (w.data ?? '?') : '?';
        }).take(40).toList()}');
      }

      // Two sites are seeded — the All webspace tile should report
      // "2 sites".
      expect(find.text('2 sites'), findsOneWidget,
          reason: 'All webspace should show the seeded site count');

      // Open the create flow.
      await tester.tap(find.text('Create Webspace'));
      await tester.pumpAndSettle(const Duration(seconds: 5));
      expect(find.text('Edit Webspace'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Webspace Name'),
        'Alpha Only',
      );
      await tester.pumpAndSettle();

      // Each available site renders as a CheckboxListTile with its
      // display name in the title (lib/screens/webspace_detail.dart).
      // Tap Site Alpha to toggle it into the new webspace.
      final alphaTile = find.widgetWithText(CheckboxListTile, 'Site Alpha');
      if (alphaTile.evaluate().isEmpty) {
        dumpTexts('webspace detail (Alpha tile not found)');
      }
      expect(alphaTile, findsOneWidget,
          reason: 'Site Alpha should be available for selection');
      await tester.tap(alphaTile);
      await tester.pumpAndSettle();

      // Selection counter should reflect the toggle.
      expect(find.text('1 selected'), findsOneWidget,
          reason: 'header counter should show 1 selected after toggle');

      // Save → webspace persisted → back on the root list.
      await tester.tap(find.bySemanticsLabel('Save'));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      if (find.text('Alpha Only').evaluate().isEmpty) {
        dumpTexts('after save');
      }
      expect(find.text('Alpha Only'), findsOneWidget,
          reason: 'new webspace tile should appear on the root list');
      // The new webspace tile's subtitle should report exactly one site.
      final alphaOnlyTile = find.ancestor(
        of: find.text('Alpha Only'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: alphaOnlyTile, matching: find.text('1 sites')),
        findsOneWidget,
        reason: 'Alpha Only webspace should show "1 sites" subtitle',
      );
    },
  );
}
