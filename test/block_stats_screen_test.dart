import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';

Future<void> _pump(WidgetTester tester, Map<String, String> siteNames) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: BlockStatsScreen(siteNames: siteNames),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BlockStatsService.resetInstanceForTest();
  });

  testWidgets('a category row opens its detail, naming items and sites',
      (tester) async {
    final service = BlockStatsService.instance;
    await service.initialize();
    service.setSiteContributes('site-a', true);
    service.setSiteContributes('site-b', true);
    service.record('site-a', BlockCategory.dnsBlocklist,
        count: 4, label: 'ads.example');
    service.record('site-b', BlockCategory.dnsBlocklist, label: 'beacon.example');
    service.record('site-a', BlockCategory.trackingParam, label: 'utm_source');
    // Settle the debounced write; a pending timer fails the widget binding.
    await service.flush();

    await _pump(tester, {'site-a': 'News', 'site-b': 'Forum'});
    await tester.tap(find.byKey(const Key('block_stats_category_dnsBlocklist')));
    await tester.pumpAndSettle();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.blockStatsCategoryDns), findsOneWidget);
    expect(find.text('ads.example'), findsOneWidget);
    expect(find.text('beacon.example'), findsOneWidget);
    // The other category's item stays behind its own row.
    expect(find.text('utm_source'), findsNothing);
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Forum'), findsOneWidget);
  });

  testWidgets('a site with no name left is dropped rather than shown by id',
      (tester) async {
    final service = BlockStatsService.instance;
    await service.initialize();
    service.setSiteContributes('deleted-site', true);
    service.record('deleted-site', BlockCategory.filterList,
        label: 'tracker.example');
    await service.flush();

    await _pump(tester, const {});
    await tester.tap(find.byKey(const Key('block_stats_category_filterList')));
    await tester.pumpAndSettle();

    expect(find.text('tracker.example'), findsOneWidget);
    expect(find.text('deleted-site'), findsNothing);
  });

  testWidgets('a category with nothing recorded this session says so',
      (tester) async {
    final service = BlockStatsService.instance;
    await service.initialize();
    service.setSiteContributes('site-a', true);
    service.record('site-a', BlockCategory.filterList, label: 'tracker.example');
    await service.flush();

    await _pump(tester, {'site-a': 'News'});
    await tester.tap(find.byKey(const Key('block_stats_category_localCdn')));
    await tester.pumpAndSettle();

    final loc = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(loc.blockStatsDetailEmpty), findsOneWidget);
  });
}
