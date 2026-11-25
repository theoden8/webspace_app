// Settings-backup roundtrip integration test.
//
// Drives the App Settings → Export → Import flow against a real Linux
// build with libsecret round-tripping through pass-secret-service (see
// .github/workflows/build-and-test.yml). Asserts the contract of
// PWD-005 (`openspec/specs/proxy-password-secure-storage/spec.md`):
//   * The exported JSON file must not contain the proxy password
//     anywhere in its bytes, even when the live app has it hydrated
//     from secure storage.
//   * The post-import snackbar warns the user to re-enter proxy
//     passwords whenever the source backup carried a proxy username
//     (the username being a strong proxy for "had a password too").
//
// Mocks file_picker at the platform-interface level so the export and
// import dialogs return a stable temp-file path; everything else runs
// against the real services (SharedPreferences mock for the prefs side,
// real flutter_secure_storage / pass-secret-service for the password
// side). PR #266 + the proxy_password_secure_storage migration both
// touched this code path; this test is the integration-level guard for
// regressions that unit tests in test/ can't reach.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

import 'secure_storage_fake.dart';

/// A file on disk, as a platform's open dialog reports one.
final class _DiskFile extends PlatformFile {
  _DiskFile(this._path);

  final String _path;

  @override
  String get name => _path.split('/').last;

  @override
  Uri get uri => Uri.file(_path);

  @override
  XFile get xFile => XFile(_path);

  @override
  int? lengthSync() => File(_path).lengthSync();

  @override
  Future<int?> length() => File(_path).length();

  @override
  Future<Uint8List> readAsBytes() => File(_path).readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() =>
      File(_path).openRead().map(Uint8List.fromList);
}

/// Test stub for FilePicker that writes what the app saves and hands back
/// what it picks at canned paths, in place of the real XDP file-chooser
/// dialog (which can't render under Xvfb in CI).
class _StubFilePicker extends FilePickerPlatform with MockPlatformInterfaceMixin {
  /// Where [saveFile] writes the bytes it is given, as every platform's
  /// save dialog does.
  String? saveReturn;

  /// The file [pickFile] picks.
  String? pickReturn;

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    final path = saveReturn;
    if (path == null) return null;
    await File(path).writeAsBytes(bytes);
    return Uri.file(path);
  }

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async =>
      switch (pickReturn) {
        final p? => _DiskFile(p),
        null => null,
      };
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late String exportPath;
  final stub = _StubFilePicker();
  // Distinct, non-trivial token so contains() matches reliably and
  // accidental concatenation with surrounding bytes can't false-positive.
  const secretPwd = 'CI-PROXY-SECRET-DO-NOT-EXPORT-7f3a2b1c';

  setUpAll(() async {
    tmpDir = Directory.systemTemp.createTempSync('webspace_backup_test_');
    exportPath = '${tmpDir.path}/export.json';

    isDemoMode = true;
    await installInMemoryKeychainIfUnavailable();

    // Pre-seed: a global outbound proxy entry with username (no
    // password — passwords have never lived in SharedPreferences).
    SharedPreferences.setMockInitialValues({
      AppPref.globalOutboundProxy.key: jsonEncode({
        'type': ProxyType.HTTPS.index,
        'address': 'proxy.example.com:8080',
        'username': 'ci-user',
      }),
    });

    // Write the password through the real secure-storage path. In CI
    // this round-trips through pass-secret-service backed by pass+gpg.
    final pwdStore = ProxyPasswordSecureStorage();
    await pwdStore.savePassword(
      ProxyPasswordKey.global,
      password: secretPwd,
    );

    FilePickerPlatform.instance = stub;
  });

  tearDownAll(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  // BACKUP-001, INTEG-007
  testWidgets('export omits proxy password (PWD-005); import warns user',
      (tester) async {
    app.main();
    await tester.pumpAndSettle(const Duration(seconds: 30));

    // Sanity check that the live app actually hydrated the password from
    // secure storage. Without this, a regression in the hydration path
    // would let the rest of the test pass trivially (no password to leak,
    // no username to trigger the snackbar).
    expect(GlobalOutboundProxy.current.address, 'proxy.example.com:8080');
    expect(GlobalOutboundProxy.current.username, 'ci-user');
    expect(GlobalOutboundProxy.current.password, secretPwd,
        reason: 'password should hydrate from secure storage on startup');

    // Reach App Settings and open Backup and archives, where the
    // Export/Import row pair lives.
    Future<void> openSettingsAndScrollTo(Finder target) async {
      final settingsButton = find.byTooltip('App Settings');
      expect(settingsButton, findsOneWidget,
          reason: 'App Settings icon should be visible on the webspaces list');
      await tester.tap(settingsButton);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      // The index's ListView culls offscreen children, so the row is not in
      // the element tree until scrolled into view.
      final backup = find.text('Backup and archives');
      await tester.scrollUntilVisible(
        backup,
        300.0,
        scrollable: find.byType(Scrollable).first,
      );
      // The drag loop stops as soon as the row is built, which the ListView
      // does up to a cacheExtent below the fold, and the ensureVisible jump
      // that closes it is not laid out until the next frame. Settle so the
      // tap reads where the row ended up rather than where it was.
      await tester.pumpAndSettle();
      await tester.tap(backup);
      await tester.pumpAndSettle();
      expect(target, findsOneWidget);
    }

    // Tap the Export Settings tile. The Backup screen pops with the choice
    // and App Settings pops itself BEFORE invoking the callback (see
    // `_openBackup` in lib/screens/app_settings.dart), so we land back on
    // the webspaces-list screen while the export's file write + snackbar
    // run on the parent's context.
    stub.saveReturn = exportPath;
    await openSettingsAndScrollTo(find.text('Export Settings'));
    await tester.tap(find.text('Export Settings'));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    // Export now opens a review screen before the file picker.
    await tester.tap(find.widgetWithText(FilledButton, 'Create backup'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(File(exportPath).existsSync(), isTrue,
        reason: 'export should write to the path returned by FilePicker.saveFile');
    final exportedJson = File(exportPath).readAsStringSync();
    expect(exportedJson, isNot(contains(secretPwd)),
        reason: 'PWD-005: password must not appear anywhere in the export bytes');
    expect(exportedJson, contains('proxy.example.com:8080'),
        reason: 'address is non-secret and must be exported');
    expect(exportedJson, contains('ci-user'),
        reason: 'username is non-secret and must be exported');

    // Import Settings — same Pop-then-callback pattern, so re-open
    // App Settings, scroll, and tap Import Settings. The import flow
    // shows its review screen and the post-import snackbar
    // attached to the parent (webspaces-list) ScaffoldMessenger.
    stub.pickReturn = exportPath;
    await openSettingsAndScrollTo(find.text('Import Settings'));
    await tester.tap(find.text('Import Settings'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final importButton = find.widgetWithText(FilledButton, 'Import');
    expect(importButton, findsOneWidget,
        reason: 'Import review should render its action button');
    await tester.tap(importButton);
    await tester.pumpAndSettle(const Duration(seconds: 5));

    expect(
      find.textContaining('Proxy passwords'),
      findsOneWidget,
      reason: 'PWD-005 user-facing surface: import snackbar should warn '
          'that proxy passwords are stripped from backups',
    );
  });
}
