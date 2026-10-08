import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/services/developer_unlock_engine.dart';
import 'helpers/localized.dart';

/// The seven-tap gesture end to end through the real settings screen
/// (`developer-tools` DEVTOOLS-010). `developer_unlock_engine_test.dart` covers
/// the counting; this covers the wiring the engine cannot see — that the row
/// exists, that taps reach the engine, and that the seventh flips the service
/// the Repaint Screen menu entry reads (`webview-pause-lifecycle` PAUSE-028).
void main() {
  Widget host() => localizedApp(AppSettingsScreen(
    currentSettings: AppThemeSettings(),
    onSettingsChanged: (_) {},
    onExportSettings: () {},
    onImportSettings: () {},
    onOpenLinkHandlingSettings: () {},
  ));

  /// The version row sits at the bottom of a long list.
  Future<Finder> versionRow(WidgetTester tester) async {
    final row = find.text('Version');
    await tester.scrollUntilVisible(row, 400,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    return row;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
    DeveloperModeService.instance.debugSet(on: false);
  });

  testWidgets('the About section shows the installed version', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await versionRow(tester);
    expect(find.text('9.9.9+42'), findsOneWidget,
        reason: 'the row carries version+buildNumber');
  });

  testWidgets('seven taps turn developer mode on', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final row = await versionRow(tester);

    for (var i = 0; i < DeveloperUnlockEngine.tapsToUnlock - 1; i++) {
      await tester.tap(row);
      await tester.pump();
      expect(DeveloperModeService.instance.enabled, isFalse,
          reason: 'tap ${i + 1} must not unlock');
    }
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(DeveloperModeService.instance.enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.developerMode.key), isTrue,
        reason: 'the flag must survive a restart');
  });

  testWidgets('the first taps are silent, then the countdown appears',
      (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final row = await versionRow(tester);

    for (var i = 0; i < DeveloperUnlockEngine.countdownFrom - 1; i++) {
      await tester.tap(row);
      await tester.pump();
    }
    expect(find.byType(SnackBar), findsNothing,
        reason: 'a stray double tap must say nothing');

    await tester.tap(row);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
    // Exactly one: a queued countdown would show a stale number for seconds.
    await tester.tap(row);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget,
        reason: 'each countdown must replace the last, not queue behind it');
  });

  testWidgets('the Developer row appears only once unlocked, and turns it '
      'back off', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Developer'), findsNothing,
        reason: 'nothing to say before the gesture happens');

    final row = await versionRow(tester);
    for (var i = 0; i < DeveloperUnlockEngine.tapsToUnlock; i++) {
      await tester.tap(row);
      await tester.pump();
    }
    await tester.pumpAndSettle();

    final developerRow = find.text('Developer');
    expect(developerRow, findsOneWidget,
        reason: 'it takes the place of the App Logs row, beside Version');
    await tester.tap(developerRow);
    await tester.pumpAndSettle();

    final switchRow = find.text('Developer mode');
    expect(switchRow, findsOneWidget);
    await tester.tap(find.ancestor(
        of: switchRow, matching: find.byType(SwitchListTile)));
    await tester.pumpAndSettle();
    expect(DeveloperModeService.instance.enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(AppPref.developerMode.key), isFalse);
    expect(find.text('Developer'), findsNothing,
        reason: 'the screen closes and the row goes with developer mode');
    expect(find.text('App Logs'), findsOneWidget);
  });

  testWidgets('tapping while already on does not re-arm the counter',
      (tester) async {
    DeveloperModeService.instance.debugSet(on: true);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final row = await versionRow(tester);

    await tester.tap(row);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget,
        reason: 'the gesture says it is already on rather than counting');
    expect(DeveloperModeService.instance.enabled, isTrue);
  });
}
