import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspace_page.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_file_picker.dart';
import 'helpers/real_app.dart';

/// A settings import replaces the site list, and the sites it drops leave
/// their saved navigation state behind unless the import sweeps it.
void main() {
  testWidgets('an import reclaims the navigation state of the sites it drops',
      (tester) async {
    final dropped = WebViewModel(initUrl: 'https://old.test', name: 'Old');
    final kept = WebViewModel(initUrl: 'https://kept.test', name: 'Kept');
    final state = InMemoryWebViewStateStorage();
    debugWebViewStateStorageOverride = state;
    addTearDown(() => debugWebViewStateStorageOverride = null);
    await state.saveState(dropped.activeStateKey,
        state: Uint8List.fromList([1]));

    await pumpRealApp(tester, sites: [dropped, kept]);
    expect(await state.loadState(dropped.activeStateKey), isNotNull,
        reason: 'the launch sweep keeps a live site\'s state');

    final backup = SettingsBackupService.createBackup(
      webViewModels: [kept],
      webspaces: const [],
      themeMode: 0,
    );
    final bytes = Uint8List.fromList(
        utf8.encode(SettingsBackupService.exportToJson(backup)));
    FakeFilePicker.install(
        file: FakePlatformFile(name: 'backup.json', bytes: bytes));

    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    tester
        .widget<AppSettingsScreen>(find.byType(AppSettingsScreen))
        .onImportSettings();
    await settleRealApp(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await settleRealApp(tester);

    expect(debugWebViewModels!.map((m) => m.name), ['Kept']);
    expect(await state.loadState(dropped.activeStateKey), isNull);
  });
}
