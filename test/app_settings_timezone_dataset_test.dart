// App settings' "Timezone polygons" row reports the dataset on disk (LOC-010).
// Only the lookup paths load the dataset into memory, so a row that read the
// in-memory set showed "Not downloaded" beside the last download's timestamp
// on every launch that had not opened a site's settings yet.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/main.dart' show AppThemeSettings;
import 'package:webspace/screens/app_settings.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'helpers/fake_path_provider.dart';

const _fixture = '''
{
  "type": "FeatureCollection",
  "features": [
    {"type": "Feature", "properties": {"tzid": "Asia/Tokyo"},
     "geometry": {"type": "Polygon", "coordinates":
       [[[139.0, 35.0], [140.0, 35.0], [140.0, 36.0], [139.0, 36.0], [139.0, 35.0]]]}},
    {"type": "Feature", "properties": {"tzid": "Europe/London"},
     "geometry": {"type": "Polygon", "coordinates":
       [[[-1.0, 51.0], [1.0, 51.0], [1.0, 52.0], [-1.0, 52.0], [-1.0, 51.0]]]}}
  ]
}
''';

void main() {
  late Directory docs;
  late File dataset;

  Widget host() => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AppSettingsScreen(
          currentSettings: AppThemeSettings(),
          onSettingsChanged: (_) {},
          onExportSettings: () {},
          onImportSettings: () {},
          showTabStrip: false,
          onShowTabStripChanged: (_) {},
          tabStripInFullscreen: false,
          onTabStripInFullscreenChanged: (_) {},
          fullscreenOnShortcut: false,
          onFullscreenOnShortcutChanged: (_) {},
          backOpensMenu: false,
          onBackOpensMenuChanged: (_) {},
          httpsUpgradeEnabled: true,
          onHttpsUpgradeEnabledChanged: (_) {},
          tabBarButton: false,
          onTabBarButtonChanged: (_) {},
          tabMaxWidth: 140,
          onTabMaxWidthChanged: (_) {},
          showStatsBanner: false,
          onShowStatsBannerChanged: (_) {},
          localeOverride: '',
          onLocaleOverrideChanged: (_) {},
          linkHandlingEnabled: true,
          onLinkHandlingEnabledChanged: (_) {},
          onOpenLinkHandlingSettings: () {},
        ),
      );

  setUp(() async {
    docs = await Directory.systemTemp.createTemp('webspace_tz_row_');
    useFakePathProvider(docs);
    dataset = File('${docs.path}/tz_polygons.geojson');
    PackageInfo.setMockInitialValues(
      appName: 'WebSpace',
      packageName: 'org.codeberg.theoden8.webspace',
      version: '9.9.9',
      buildNumber: '42',
      buildSignature: '',
      installerStore: null,
    );
  });

  tearDown(() async {
    await TimezoneLocationService.instance.clear();
    await docs.delete(recursive: true);
  });

  Finder row() => find.ancestor(
        of: find.text('Timezone polygons'),
        matching: find.byType(ListTile),
      );

  Finder inRow(Finder f) => find.descendant(of: row(), matching: f);

  /// The row's state comes from file IO, which only completes on the real
  /// event loop, so alternate real waits with frames until [done] holds.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
  }

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(find.text('Privacy'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Timezone polygons'), 400,
        scrollable: find.byType(Scrollable).first);
    await tester.pump();
  }

  testWidgets('a downloaded dataset nothing has loaded reads as downloaded',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'tz_polygons_last_updated': '2026-08-23T21:41:17.000',
      'tz_polygons_zone_count': 2,
    });
    await tester.runAsync(() => dataset.writeAsString(_fixture));

    await open(tester);
    await settle(tester, () => inRow(find.text('2 zones')).evaluate().isNotEmpty);

    expect(inRow(find.text('2 zones')), findsOneWidget);
    expect(inRow(find.text('Not downloaded')), findsNothing);
    expect(inRow(find.textContaining('Updated: 2026-08-23')), findsOneWidget);
    expect(inRow(find.byTooltip('Clear dataset')), findsOneWidget);
    expect(inRow(find.byTooltip('Refresh dataset')), findsOneWidget);
    expect(TimezoneLocationService.instance.isReady, isFalse,
        reason: 'showing the status must not load the polygons');
  });

  testWidgets('a dataset stored before its count was is counted for the row',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'tz_polygons_last_updated': '2026-08-23T21:41:17.000',
    });
    await tester.runAsync(() => dataset.writeAsString(_fixture));

    await open(tester);
    await settle(tester, () => inRow(find.text('2 zones')).evaluate().isNotEmpty);

    expect(inRow(find.text('2 zones')), findsOneWidget);
    expect(inRow(find.text('Not downloaded')), findsNothing);
    expect(TimezoneLocationService.instance.isReady, isFalse);
  });

  testWidgets('a timestamp without a file is not downloaded, and not dated',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'tz_polygons_last_updated': '2026-08-23T21:41:17.000',
      'tz_polygons_zone_count': 2,
    });

    await open(tester);
    await settle(tester, () => false);

    expect(inRow(find.text('Not downloaded')), findsOneWidget);
    expect(inRow(find.textContaining('Updated:')), findsNothing);
    expect(inRow(find.byTooltip('Clear dataset')), findsNothing);
    expect(inRow(find.byTooltip('Download dataset')), findsOneWidget);
  });

  testWidgets('the row follows a clear made while it is open', (tester) async {
    SharedPreferences.setMockInitialValues({
      'tz_polygons_last_updated': '2026-08-23T21:41:17.000',
      'tz_polygons_zone_count': 2,
    });
    await tester.runAsync(() => dataset.writeAsString(_fixture));

    await open(tester);
    await settle(tester, () => inRow(find.text('2 zones')).evaluate().isNotEmpty);

    await tester.tap(inRow(find.byTooltip('Clear dataset')));
    await settle(
        tester, () => inRow(find.text('Not downloaded')).evaluate().isNotEmpty);

    expect(inRow(find.text('Not downloaded')), findsOneWidget);
    expect(inRow(find.textContaining('Updated:')), findsNothing);
    expect(await tester.runAsync(() => dataset.exists()), isFalse);
  });
}
