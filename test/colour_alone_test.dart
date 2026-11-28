import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/log_entry_line.dart';
import 'package:webspace/widgets/site_grid_tile.dart';

import 'helpers/localized.dart';
import 'helpers/memory_block_stats_store.dart';

/// What the A11Y-009 audit found told by colour alone, each now carrying a
/// cue a Grayscale filter keeps: the drawer's selected site a border and a
/// selected flag, each daily bar its day and count, each log line its level.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpTile(WidgetTester tester, {required bool selected}) =>
      pumpLocalized(
        tester,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              height: 180,
              child: SiteGridTile(
                site: WebViewModel(initUrl: 'https://example.test'),
                listIndex: 0,
                selected: selected,
                showTabCount: false,
                layout: SiteGridTileLayout.compact,
                onOpen: () {},
                onMenu: (_, {required globalPosition}) {},
              ),
            ),
          ),
        ),
      );

  BoxBorder? tileBorder(WidgetTester tester) {
    for (final box in tester.widgetList<Container>(
      find.descendant(
        of: find.byType(SiteGridTile),
        matching: find.byType(Container),
      ),
    )) {
      if (box.decoration case BoxDecoration(:final border?)) return border;
    }
    return null;
  }

  /// The node a screen reader presses the tile by, which its name is merged
  /// into.
  SemanticsNode pressedBy(WidgetTester tester) => tester.getSemantics(
    find
        .descendant(of: find.byType(SiteGridTile), matching: find.byType(Text))
        .first,
  );

  testWidgets(
    'the drawer marks its selected site by a border and reports it selected (A11Y-009)',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpTile(tester, selected: false);
      await tester.pumpAndSettle();
      expect(tileBorder(tester), isNull);
      expect(
        pressedBy(tester).flagsCollection.isSelected,
        isNot(Tristate.isTrue),
      );

      await pumpTile(tester, selected: true);
      await tester.pumpAndSettle();
      expect(tileBorder(tester), isNotNull);
      expect(
        pressedBy(tester).flagsCollection.isSelected,
        Tristate.isTrue,
      );
      semantics.dispose();
    },
  );

  testWidgets(
    "each daily bar says its day and its count (A11Y-009)",
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      BlockStatsService.resetInstanceForTest();
      final service = BlockStatsService.instance;
      await service.initialize(detailStore: MemoryBlockStatsDetailStore());
      service.setSiteContributes(SiteId('site-a'), contributes: true);
      service.record(
        SiteId('site-a'),
        category: BlockCategory.dnsBlocklist,
        count: 7,
        label: 'ads.example',
      );
      await service.flush();

      final semantics = tester.ensureSemantics();
      await pumpLocalized(
        tester,
        home: const BlockStatsScreen(siteNames: {}),
        size: const Size(1000, 2400),
      );
      await tester.pumpAndSettle();

      final now = DateTime.now();
      final days = [
        for (var back = 6; back >= 0; back--)
          DateTime(now.year, now.month, now.day - back),
      ];
      final dates = MaterialLocalizations.of(
        tester.element(find.byType(BlockStatsScreen)),
      );
      for (final (i, day) in days.indexed) {
        final count = i == days.length - 1 ? 7 : 0;
        expect(
          find.bySemanticsLabel('${dates.formatShortMonthDay(day)}: $count'),
          findsOneWidget,
          reason: 'the bar for $day',
        );
      }
      semantics.dispose();
    },
  );

  testWidgets('a log line names its level in its text (A11Y-009)', (
    tester,
  ) async {
    for (final level in LogLevel.values) {
      await pumpLocalized(
        tester,
        home: Scaffold(
          body: LogEntryLine(
            entry: LogEntry(
              timestamp: DateTime(2026),
              level: level,
              tag: 'Test',
              message: 'something happened',
            ),
            time: '00:00:00',
          ),
        ),
      );
      expect(
        find.textContaining('[${level.name}]'),
        findsOneWidget,
        reason: '$level',
      );
    }
  });
}
