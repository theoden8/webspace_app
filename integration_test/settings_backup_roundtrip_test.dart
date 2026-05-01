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

import 'package:file_picker/file_picker.dart';
// FilePickerPlatform is the abstract base used to swap platform impls;
// the package re-exports the IO + Linux + macOS + Windows concrete
// classes from its main barrel but not the base class. Reaching into
// `src/` is fine for tests — the alternative (mocking the dbus calls
// pass-secret-service makes for the XDP file-chooser) is an order of
// magnitude more code for no extra coverage.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/main.dart' as app;
import 'package:webspace/demo_data.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Test stub for FilePicker that captures the bytes the app would have
/// shown to the user and returns canned paths in place of the real
/// XDP file-chooser dialog (which can't render under Xvfb in CI).
class _StubFilePicker extends FilePickerPlatform with MockPlatformInterfaceMixin {
  /// Path to return from [saveFile]. The service writes the JSON here
  /// directly on Linux desktop (it only passes `bytes` on mobile).
  String? saveReturn;

  /// Path to return from [pickFiles]. The service then reads its
  /// contents from disk via the file's `path` field.
  String? pickReturn;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async =>
      saveReturn;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowMultiple = false,
    bool? withData = false,
    bool? withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    int compressionQuality = 0,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    final p = pickReturn;
    if (p == null) return null;
    final f = File(p);
    return FilePickerResult([
      PlatformFile(
        name: 'webspace_backup.json',
        size: f.lengthSync(),
        path: p,
      ),
    ]);
  }
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

    // Pre-seed: a global outbound proxy entry with username (no
    // password — passwords have never lived in SharedPreferences).
    SharedPreferences.setMockInitialValues({
      kGlobalOutboundProxyKey: jsonEncode({
        'type': ProxyType.HTTPS.index,
        'address': 'proxy.example.com:8080',
        'username': 'ci-user',
      }),
    });

    // Write the password through the real secure-storage path. In CI
    // this round-trips through pass-secret-service backed by pass+gpg.
    final pwdStore = ProxyPasswordSecureStorage();
    await pwdStore.savePassword(
      ProxyPasswordSecureStorage.globalProxyKey,
      secretPwd,
    );

    FilePickerPlatform.instance = stub;
  });

  tearDownAll(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

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

    // Reach App Settings, scroll to the Export/Import row pair.
    Future<void> openSettingsAndScrollToBackup() async {
      final settingsButton = find.byTooltip('App Settings');
      expect(settingsButton, findsOneWidget,
          reason: 'App Settings icon should be visible on the webspaces list');
      await tester.tap(settingsButton);
      await tester.pumpAndSettle(const Duration(seconds: 5));
      await tester.scrollUntilVisible(
        find.text('Export Settings'),
        300.0,
        scrollable: find.byType(Scrollable).first,
      );
    }

    // Tap the Export Settings tile. The tile's onTap pops the
    // AppSettings route BEFORE invoking the callback (see
    // lib/screens/app_settings.dart:913), so we land back on the
    // webspaces-list screen while the export's file write + snackbar
    // run on the parent's context.
    stub.saveReturn = exportPath;
    await openSettingsAndScrollToBackup();
    await tester.tap(find.text('Export Settings'));
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
    // shows its confirmation dialog and the post-import snackbar
    // attached to the parent (webspaces-list) ScaffoldMessenger.
    stub.pickReturn = exportPath;
    await openSettingsAndScrollToBackup();
    await tester.tap(find.text('Import Settings'));
    await tester.pumpAndSettle(const Duration(seconds: 5));

    final importButton = find.text('Import');
    expect(importButton, findsOneWidget,
        reason: 'Import confirmation dialog should render its OK button');
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
