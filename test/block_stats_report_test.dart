import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/widgets/protection_shield_button.dart';

import 'helpers/localized.dart';
import 'helpers/memory_block_stats_store.dart';

/// STATS-003: the report's range total, daily bars, category shares and
/// all-time line; its empty state; its reset; and the shortcut's badge.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BlockStatsService.resetInstanceForTest();
  });

  Future<BlockStatsService> recorded({required Map<BlockCategory, int> counts}) async {
    final service = BlockStatsService.instance;
    await service.initialize(detailStore: MemoryBlockStatsDetailStore());
    service.setSiteContributes(SiteId('site-a'), contributes: true);
    for (final MapEntry(key: category, value: count) in counts.entries) {
      service.record(SiteId('site-a'),
          category: category, count: count, label: 'x.example');
    }
    await service.flush();
    return service;
  }

  Future<void> pumpReport(WidgetTester tester) async {
    await pumpLocalized(tester,
        home: const BlockStatsScreen(siteNames: {'site-a': 'News'}),
        size: const Size(1000, 2400));
    await tester.pumpAndSettle();
  }

  int bars(WidgetTester tester) =>
      find.byType(FractionallySizedBox).evaluate().length;

  double share(WidgetTester tester, {required BlockCategory category}) =>
      tester
          .widget<LinearProgressIndicator>(find.descendant(
              of: find.byKey(Key('block_stats_category_${category.name}')),
              matching: find.byType(LinearProgressIndicator)))
          .value!;

  Finder reset() => find.byTooltip('Reset statistics');

  testWidgets('STATS-003: the range total, a bar per day and each '
      'category\'s share', (tester) async {
    await recorded(counts: {
      BlockCategory.dnsBlocklist: 3,
      BlockCategory.trackingParam: 1,
    });
    await pumpReport(tester);

    expect(find.text('4'), findsOneWidget, reason: 'the range total');
    expect(bars(tester), 7);
    expect(share(tester, category: BlockCategory.dnsBlocklist), 0.75);
    expect(share(tester, category: BlockCategory.trackingParam), 0.25);
    expect(share(tester, category: BlockCategory.filterList), 0);
    expect(find.textContaining('4 blocked since '), findsOneWidget);
    expect(tester.widget<IconButton>(find.ancestor(
            of: reset(), matching: find.byType(IconButton))).onPressed,
        isNotNull);

    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    expect(bars(tester), 30);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('STATS-003: with nothing blocked the report explains itself '
      'and cannot be reset', (tester) async {
    await recorded(counts: const {});
    await pumpReport(tester);
    expect(find.text('Nothing blocked yet'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<IconButton>(find.ancestor(
            of: reset(), matching: find.byType(IconButton))).onPressed,
        isNull);
  });

  testWidgets('STATS-003: a confirmed reset zeroes every counter from today',
      (tester) async {
    final service = await recorded(counts: {BlockCategory.filterList: 2});
    await pumpReport(tester);
    await tester.tap(reset());
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Reset statistics')).last);
    await tester.pumpAndSettle();
    await service.flush();

    expect(service.engine.allTimeTotal, 0);
    expect(service.engine.totalForLastDays(30), 0);
    final since = service.engine.since;
    final now = DateTime.now();
    expect((since.year, since.month, since.day), (now.year, now.month, now.day));
    expect(find.text('Nothing blocked yet'), findsOneWidget);
  });

  testWidgets('STATS-003: the shortcut\'s badge counts the week in the '
      'accent, not the error colour', (tester) async {
    await recorded(counts: {BlockCategory.dnsBlocklist: 5});
    final theme = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal));
    await pumpLocalized(tester,
        theme: theme,
        home: Scaffold(
            appBar: AppBar(actions: [ProtectionShieldButton(onPressed: () {})])));
    await tester.pumpAndSettle();
    final badge = tester.widget<Badge>(find.byType(Badge));
    expect(badge.isLabelVisible, isTrue);
    expect(find.text('5'), findsOneWidget);
    expect(badge.backgroundColor, theme.colorScheme.primary);
    expect(badge.backgroundColor, isNot(theme.colorScheme.error));
  });
}
