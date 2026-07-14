// Desktop integration test for the unconfigured-blocker warning UI and
// the DevTools ABP decision accounting, driven on a live desktop runtime
// (Linux GTK under Xvfb in CI; macOS AppKit on the mac job).
//
// Covers:
//   * CB-006 / DNS-005 warn-on-enable: flipping the DNS blocklist or
//     Content Blocker switch with no downloaded data flips the setting,
//     fires the not-configured SnackBar, and renders the persistent
//     amber warning icon next to the tile.
//   * Tracking Protection enable warns for each unconfigured forced dep
//     and carries the warning icon itself.
//   * CB-012: the adblock engine ships and loads inside the desktop app
//     process, every Dart consult path plus the native-drain recorder
//     advances the cumulative counters, and the DevTools ABP tab renders
//     those totals (including the untimed `native` sample row).
//
// Screens are pumped directly (SettingsScreen / DevToolsScreen) rather
// than navigated to through the drawer: the warning surfaces live
// entirely inside these screens, and skipping app boot keeps the test
// independent of seeded-site state.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/screens/settings.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

  setUp(ContentBlockerService.instance.reset);
  tearDown(ContentBlockerService.instance.reset);

  Future<void> pump(WidgetTester tester, Widget home) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    ));
    await tester.pumpAndSettle();
    // Live-binding diagnosis when a later finder misses: what attached.
    // ignore: avoid_print
    print('[blocker-test] widgets=${tester.allWidgets.length} '
        'scrollables=${find.byType(Scrollable).evaluate().length} '
        'switches=${find.byType(SwitchListTile).evaluate().length} '
        'richTexts=${find.byType(RichText).evaluate().length}');
  }

  WebViewModel freshModel() => WebViewModel(
        initUrl: 'https://example.com',
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        trackingProtectionEnabled: false,
      );

  Future<Finder> revealTile(WidgetTester tester, String title) async {
    final tile = find.widgetWithText(SwitchListTile, title);
    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    return tile;
  }

  final warnIcon = find.byIcon(Icons.warning_amber_rounded);
  final warnSnack = find.textContaining('has no data downloaded yet');

  testWidgets('enabling unconfigured Content Blocker warns and flips',
      (tester) async {
    await pump(tester, SettingsScreen(webViewModel: freshModel()));
    expect(warnIcon, findsNothing);

    final tile = await revealTile(tester, 'Content Blocker');
    expect(find.descendant(of: tile, matching: find.text('Not configured')),
        findsOneWidget);

    await tester.tap(tile);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(warnSnack, findsOneWidget);
    expect(find.descendant(of: tile, matching: warnIcon), findsOneWidget);
  });

  testWidgets('enabling unconfigured DNS blocklist warns and flips',
      (tester) async {
    await pump(tester, SettingsScreen(webViewModel: freshModel()));

    final tile = await revealTile(tester, 'DNS Blocklist');
    await tester.tap(tile);
    await tester.pump();

    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(warnSnack, findsOneWidget);
    expect(find.descendant(of: tile, matching: warnIcon), findsOneWidget);
  });

  testWidgets('enabling Tracking Protection warns for both forced deps',
      (tester) async {
    await pump(tester, SettingsScreen(webViewModel: freshModel()));

    final tile = await revealTile(tester, 'Tracking Protection');
    await tester.tap(tile);
    await tester.pump();

    expect(warnSnack, findsOneWidget);
    expect(find.textContaining('DNS Blocklist, Content Blocker'),
        findsOneWidget);
    // ETP tile itself plus both forced blocker tiles carry the icon
    // (the blocker tiles may sit below the fold; assert at least the
    // ETP one and the forced-subtitle join on the DNS tile).
    expect(find.descendant(of: tile, matching: warnIcon), findsOneWidget);

    final dnsTile = await revealTile(tester, 'DNS Blocklist');
    expect(find.descendant(of: dnsTile, matching: warnIcon), findsOneWidget);
    expect(
        find.descendant(
            of: dnsTile, matching: find.textContaining('Not configured')),
        findsOneWidget);
  });

  testWidgets('ABP engine ships on desktop; DevTools tab shows totals',
      (tester) async {
    final svc = ContentBlockerService.instance;
    final engine = AdblockEngine.load('||tracker.com^\n');
    expect(engine, isNotNull,
        reason: 'bundled libwebspace_adblock must load in the app process');
    svc.setRustEngineForTest(engine);

    expect(svc.isBlocked('https://tracker.com/ad.js', requestType: 'script'),
        isTrue);
    expect(svc.isHostBlocked('tracker.com'), isTrue);
    expect(svc.isHostBlocked('example.com'), isFalse);
    svc.recordNativeEngineBlock('ads.example.net', count: 3);

    expect(svc.engineConsultedSinceTimingOn, 6);
    expect(svc.engineBlockedSinceTimingOn, 5);
    expect(svc.engineAllowedSinceTimingOn, 1);

    await pump(tester, DevToolsScreen(cookieManager: CookieManager()));

    // host == null and engine active: the ABP tab is first and selected.
    String chip(String label, String value) => '$label $value';
    for (final expected in [
      chip('blocked', '5'),
      chip('allowed', '1'),
      chip('consulted', '6'),
    ]) {
      expect(
          find.byWidgetPredicate((w) =>
              w is RichText && w.text.toPlainText() == expected),
          findsOneWidget,
          reason: 'ABP tab should render "$expected"');
    }
    // The native drain produced one untimed sample row for the host.
    expect(find.text('ads.example.net'), findsOneWidget);
    expect(find.text('native'), findsOneWidget);
  });
}
