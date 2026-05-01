// Webspace CRUD integration test.
//
// Drives the create / edit / delete flow on the WebspacesListScreen and
// WebspaceDetailScreen against the real Flutter app. Catches
// orchestration regressions in the dialog/navigator pop-then-callback
// path that unit tests on `webspace_model_test.dart` and
// `webspace_selection_engine_test.dart` cannot reach — those cover the
// pure-Dart engine, not the navigation flow that wires them up.
//
// Pure UI: no WebView mount, no network, no flutter_secure_storage.
// Runs cleanly in the headless Linux CI harness.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    isDemoMode = true;
  });

  testWidgets('create, rename, and delete a webspace through the UI',
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

    // Initial state: only the auto-generated "All" webspace exists.
    expect(find.text('All'), findsWidgets,
        reason: '"All" webspace tile should always be visible');
    expect(find.text('Test Workspace'), findsNothing,
        reason: 'no user webspaces should exist on a fresh install');

    // ---- CREATE ----
    final createButton = find.text('Create Webspace');
    expect(createButton, findsOneWidget,
        reason: '"Create Webspace" extended-FAB should be on the root list');
    await tester.tap(createButton);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // WebspaceDetailScreen is now pushed. AppBar title flips between
    // "View Webspace" (read-only mode) and "Edit Webspace"
    // (lib/screens/webspace_detail.dart). Empty new webspace is editable.
    expect(find.text('Edit Webspace'), findsOneWidget,
        reason: 'WebspaceDetailScreen should open in edit mode');
    final nameField = find.widgetWithText(TextField, 'Webspace Name');
    expect(nameField, findsOneWidget,
        reason: 'name TextField should render with the labelText');
    await tester.enterText(nameField, 'Test Workspace');
    await tester.pumpAndSettle();

    // Save via the AppBar check icon — it carries `Semantics(label: 'Save')`
    // (lib/screens/webspace_detail.dart:80).
    final saveButton = find.bySemanticsLabel('Save');
    expect(saveButton, findsOneWidget,
        reason: 'Save IconButton should expose Semantics(label: "Save")');
    await tester.tap(saveButton);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Back on the webspaces list — new tile should be visible.
    if (find.text('Test Workspace').evaluate().isEmpty) {
      dumpTexts('after create');
    }
    expect(find.text('Test Workspace'), findsOneWidget,
        reason: 'newly-created webspace should appear in the list');

    // ---- EDIT ----
    // Each non-All tile has an edit IconButton (Icons.edit) inside its
    // ListTile.trailing Row. Find via key+text-relative descendant.
    final editIcon = find.descendant(
      of: find.ancestor(
        of: find.text('Test Workspace'),
        matching: find.byType(ListTile),
      ),
      matching: find.byIcon(Icons.edit),
    );
    expect(editIcon, findsOneWidget,
        reason: 'edit pencil icon should sit alongside the webspace tile');
    await tester.tap(editIcon);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('Edit Webspace'), findsOneWidget);
    final renameField = find.widgetWithText(TextField, 'Webspace Name');
    await tester.enterText(renameField, 'Renamed Workspace');
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Save'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('Renamed Workspace'), findsOneWidget,
        reason: 'rename should reflect on the list');
    expect(find.text('Test Workspace'), findsNothing,
        reason: 'old name should no longer appear after the rename');

    // ---- DELETE ----
    final deleteIcon = find.descendant(
      of: find.ancestor(
        of: find.text('Renamed Workspace'),
        matching: find.byType(ListTile),
      ),
      matching: find.byIcon(Icons.delete),
    );
    expect(deleteIcon, findsOneWidget,
        reason: 'delete icon should be visible on user-created tiles');
    await tester.tap(deleteIcon);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    // Confirmation dialog (lib/main.dart `_deleteWebspace` shows
    // a generic confirm dialog with Cancel / Delete buttons).
    final confirmDelete = find.widgetWithText(TextButton, 'Delete');
    if (confirmDelete.evaluate().isEmpty) {
      dumpTexts('delete confirm dialog texts');
    }
    expect(confirmDelete, findsOneWidget,
        reason: 'delete confirmation dialog should render its Delete button');
    await tester.tap(confirmDelete);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(find.text('Renamed Workspace'), findsNothing,
        reason: 'webspace should be gone after delete-confirm');
  });
}
