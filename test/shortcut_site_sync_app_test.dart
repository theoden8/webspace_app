import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/app.dart';
import 'package:webspace/services/launch_context.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

/// The site list the App Intents picker reads is sent to the platform once
/// the sites load at launch, even when nothing is saved, and again on every
/// save, as the app runs it on iOS and macOS: the shortcuts channel's
/// `syncSites`, with each site's current name. What the Swift side writes to
/// the App Group with it is not checked here.
///
/// Planted mistakes: dropping `_shortcuts.syncSites()` from the launch
/// (`StartupController._afterLaunch`) failed the first test; dropping it
/// from `_persistSites` failed the second.
void main() {
  const channel = MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  /// The labels of each `syncSites` the app sends, as an Apple host.
  List<List<String>> recordSyncs(WidgetTester tester) {
    final before = ShortcutService.debugAppIntentsOverride;
    ShortcutService.debugAppIntentsOverride = true;
    addTearDown(() => ShortcutService.debugAppIntentsOverride = before);
    final synced = <List<String>>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'syncSites') {
        final args = call.arguments as Map<Object?, Object?>;
        synced.add([
          for (final site in args['sites'] as List<Object?>)
            '${(site as Map<Object?, Object?>)['label']}',
        ]);
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    return synced;
  }

  testWidgets('a launch with nothing saved still syncs the picker',
      (tester) async {
    final synced = recordSyncs(tester);
    await prepareRealApp(tester, sites: const []);
    // A first launch after install: no site list saved, so nothing is
    // written back and only the launch's own sync can reach the picker.
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const WebSpaceApp(launch: ProcessLaunch.user));
    await settleRealApp(tester);

    expect(synced, [<String>[]]);
  });

  testWidgets('a save syncs the picker with the sites as saved',
      (tester) async {
    final synced = recordSyncs(tester);
    await pumpRealApp(
      tester,
      sites: [
        WebViewModel(initUrl: 'https://mail.test', name: 'Mail'),
        WebViewModel(initUrl: 'https://edit.test', name: 'Old Name'),
      ],
      prefs: {AppPref.legacyDesign.key: true},
    );
    expect(synced.last, ['Mail', 'Old Name']);

    synced.clear();
    await openWebspace(tester, name: 'All');
    await tester.tap(find.descendant(
      of: find.byKey(const Key('site_1')),
      matching: find.byIcon(Icons.more_vert),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Site Name'), 'New Name');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await settleRealApp(tester);

    expect(synced, [
      ['Mail', 'New Name'],
    ]);
  });
}
