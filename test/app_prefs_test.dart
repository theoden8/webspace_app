// AppPref: one declaration per global pref, holding the value the app runs
// with. Every write goes through `set`, so demo mode is honoured in one place.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';

Object _otherThan(Object fallback) => switch (fallback) {
      bool b => !b,
      int i => i + 7,
      _ => 'other-$fallback',
    };

void main() {
  setUp(() async {
    isDemoMode = false;
    SharedPreferences.setMockInitialValues({});
    AppPref.loadAll(await SharedPreferences.getInstance());
  });

  tearDown(() => isDemoMode = false);

  // The httpsUpgradeEnabled and locale writes in main.dart and the OSM tile
  // URL, default search and Firefox auto-update writes in App settings
  // skipped the demo-mode check their siblings made, so a screenshot run
  // wrote over the user's own settings.
  test('demo mode applies a pref without persisting it', () async {
    isDemoMode = true;
    for (final pref in AppPref.values) {
      await pref.set(_otherThan(pref.fallback));
      expect(pref.value, _otherThan(pref.fallback), reason: pref.key);
    }
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  test('outside demo mode a pref persists under its declared type', () async {
    await AppPref.tabMaxWidth.set(200);
    await AppPref.httpsUpgradeEnabled.set(false);
    await AppPref.osmTileUrl.set('https://tiles.example/{z}/{x}/{y}.png');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.get('tabMaxWidth'), 200);
    expect(prefs.get('httpsUpgradeEnabled'), false);
    expect(prefs.get('osmTileUrl'), 'https://tiles.example/{z}/{x}/{y}.png');
  });

  test('a stored value of another type loads as the default', () async {
    SharedPreferences.setMockInitialValues(
        {'tabMaxWidth': 'wide', 'showUrlBar': 1, 'osmTileUrl': true});
    AppPref.loadAll(await SharedPreferences.getInstance());
    expect(AppPref.tabMaxWidth.value, 140);
    expect(AppPref.showUrlBar.value, isFalse);
    expect(AppPref.osmTileUrl.value, AppPref.osmTileUrl.fallback);
  });

  test('the tab-bar button still reads the key it had before v0.2.7',
      () async {
    SharedPreferences.setMockInitialValues({'tabBarButtonInFullscreen': true});
    final prefs = await SharedPreferences.getInstance();
    AppPref.loadAll(prefs);
    expect(AppPref.tabBarButton.value, isTrue);
    expect(readExportedAppPrefs(prefs)['tabBarButton'], isTrue,
        reason: 'the export names what the app runs with');
  });

  test('an import applies to the running app as well as to disk', () async {
    final prefs = await SharedPreferences.getInstance();
    await writeExportedAppPrefs(prefs, values: {'showStatsBanner': false});
    expect(AppPref.showStatsBanner.value, isFalse);
    expect(prefs.get('showStatsBanner'), false);
  });

  test('the app-wide proxy default is a DEFAULT proxy, encoded', () {
    expect(AppPref.globalOutboundProxy.fallback,
        jsonEncode(UserProxySettings(type: ProxyType.DEFAULT).toJson()));
  });

  testWidgets('App settings writes nothing in demo mode', (tester) async {
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
    isDemoMode = true;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppSettingsScreen(
        currentSettings: const AppThemeSettings(),
        onSettingsChanged: (_) {},
        onExportSettings: () {},
        onImportSettings: () {},
        onOpenLinkHandlingSettings: () {},
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();

    final title = find.text('HTTPS upgrade');
    await tester.scrollUntilVisible(title, 400,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(
        find.ancestor(of: title, matching: find.byType(SwitchListTile)));
    await tester.pump();
    expect(AppPref.httpsUpgradeEnabled.value, isFalse);

    final tiles = find.widgetWithText(TextFormField, 'Tile URL');
    await tester.scrollUntilVisible(tiles, 400,
        scrollable: find.byType(Scrollable).first);
    await tester.enterText(tiles, 'https://tiles.example/{z}/{x}/{y}.png');
    await tester.pump();
    expect(AppPref.osmTileUrl.value, 'https://tiles.example/{z}/{x}/{y}.png');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });
}
