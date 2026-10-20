import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'helpers/real_app.dart';

void main() {
  LiveTestWidgetsFlutterBinding();
  setUp(() => ConnectivityService.onlineOverride = Future.value(true));
  tearDown(ConnectivityService.reset);
  testWidgets(
    'a folder can be created, renamed, and deleted through its menu',
    (tester) async {
      await pumpRealApp(
        tester,
        sites: [],
        prefs: {
          AppPref.developerMode.key: true,
          AppPref.experimentalFolderLibrary.key: true,
        },
      );
      await tester.tap(find.byTooltip('Create Webspace'));
      await settleRealApp(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Webspace Name'),
        'Test Workspace',
      );
      await tester.tap(find.bySemanticsLabel('Save'));
      await settleRealApp(tester);
      await tester.longPress(find.text('Test Workspace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await settleRealApp(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'Webspace Name'),
        'Renamed Workspace',
      );
      await tester.tap(find.bySemanticsLabel('Save'));
      await settleRealApp(tester);
      await tester.longPress(find.text('Renamed Workspace'));
      await tester.pumpAndSettle();
      expect(find.text('Delete'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await settleRealApp(tester);
      expect(find.text('Renamed Workspace'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('webspaces')!.map((raw) => jsonDecode(raw)['name']),
        ['All'],
      );
    },
  );
}
