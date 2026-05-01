// Site-editing integration test.
//
// Drives the long-press → context-menu → Edit Site dialog flow on the
// drawer's site tile. Touches no WebView path — the dialog opens
// without activating the site, so the test runs cleanly under headless
// Xvfb (where WebView mount hangs on EGL surface init).
//
// Closes the test gap on the `site-editing` spec, which previously had
// no automated coverage of any kind.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'dart:convert';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    isDemoMode = true;

    final site = WebViewModel(
      siteId: 'edit-1',
      initUrl: 'http://example.invalid/',
      name: 'Old Name',
    );
    SharedPreferences.setMockInitialValues({
      'webViewModels': [jsonEncode(site.toJson())],
    });
  });

  testWidgets('long-press → Edit renames the site through the dialog',
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

    // Open the drawer by tapping the All-webspace tile (already
    // selected by default, so the same-id branch in
    // lib/main.dart `_selectWebspace` calls openDrawer()).
    final allTile = find.byKey(const ValueKey(kAllWebspaceId));
    expect(allTile, findsOneWidget);
    await tester.tap(allTile);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final siteTile = find.text('Old Name');
    if (siteTile.evaluate().isEmpty) {
      dumpTexts('drawer open');
    }
    expect(siteTile, findsOneWidget,
        reason: 'seeded site should appear in the drawer with its initial name');

    // Long-press → context menu (lib/main.dart `_showSiteContextMenu`).
    await tester.longPress(siteTile);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // The popup menu has rows for Refresh / Edit / Delete; tap Edit.
    final editMenuItem = find.text('Edit');
    if (editMenuItem.evaluate().isEmpty) {
      dumpTexts('context menu open');
    }
    expect(editMenuItem, findsOneWidget,
        reason: 'Edit option should be available in the long-press context menu');
    await tester.tap(editMenuItem);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Edit Site dialog (lib/main.dart `_editSite`):
    //   AlertDialog title 'Edit Site',
    //   TextField labelled 'Site Name',
    //   TextField labelled 'URL'.
    expect(find.text('Edit Site'), findsOneWidget,
        reason: 'Edit Site dialog should render its title');
    final nameField = find.widgetWithText(TextField, 'Site Name');
    expect(nameField, findsOneWidget);
    await tester.enterText(nameField, 'New Name');
    await tester.pumpAndSettle();

    // Confirm with the Save button (TextButton labelled 'Save').
    final saveButton = find.widgetWithText(TextButton, 'Save');
    expect(saveButton, findsOneWidget);
    await tester.tap(saveButton);
    await tester.pumpAndSettle(const Duration(seconds: 3));

    // Drawer is back to its post-edit state. The drawer item should
    // now read 'New Name'. The drawer may have closed itself after
    // the dialog; reopen if so.
    if (find.text('New Name').evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey(kAllWebspaceId)));
      await tester.pumpAndSettle(const Duration(seconds: 3));
    }
    if (find.text('New Name').evaluate().isEmpty) {
      dumpTexts('after edit save');
    }
    expect(find.text('New Name'), findsOneWidget,
        reason: 'rename should persist on the drawer site tile');
    expect(find.text('Old Name'), findsNothing,
        reason: 'old name should no longer appear after the rename');
  });
}
