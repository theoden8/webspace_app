import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/screens/webspace_page.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/real_app.dart';

class _PickedBackup extends FilePickerPlatform {
  _PickedBackup(this.bytes);

  final Uint8List bytes;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async =>
      FilePickerResult([
        PlatformFile(name: 'backup.json', size: bytes.length, bytes: bytes),
      ]);
}

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
    FilePickerPlatform.instance = _PickedBackup(Uint8List.fromList(
        utf8.encode(SettingsBackupService.exportToJson(backup))));

    await tester.tap(find.byTooltip('App Settings'));
    await settleRealApp(tester);
    tester
        .widget<AppSettingsScreen>(find.byType(AppSettingsScreen))
        .onImportSettings();
    await settleRealApp(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Import'));
    await settleRealApp(tester);

    expect(debugWebViewModels!.map((m) => m.name), ['Kept']);
    expect(await state.loadState(dropped.activeStateKey), isNull);
  });
}
