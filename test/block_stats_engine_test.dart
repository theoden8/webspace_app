import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/block_stats_engine.dart';

void main() {
  group('day bucketing (STATS-001)', () {
    test('records land in the local calendar day they happened on', () {
      final engine = BlockStatsEngine(since: DateTime(2026, 8, 1));
      engine.record(BlockCategory.filterList,
          count: 3, now: DateTime(2026, 8, 19, 23, 59));
      engine.record(BlockCategory.filterList,
          count: 2, now: DateTime(2026, 8, 20, 0, 1));

      expect(engine.totalForLastDays(1, now: DateTime(2026, 8, 20, 12)), 2);
      expect(engine.totalForLastDays(2, now: DateTime(2026, 8, 20, 12)), 5);
    });

    test('a day with no events contributes nothing', () {
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.dnsBlocklist, now: DateTime(2026, 8, 10));
      expect(engine.totalForLastDays(7, now: DateTime(2026, 8, 20)), 0);
      expect(engine.totalForLastDays(30, now: DateTime(2026, 8, 20)), 1);
    });

    test('window arithmetic crosses month and year boundaries', () {
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList, now: DateTime(2025, 12, 30));
      engine.record(BlockCategory.filterList, now: DateTime(2026, 1, 2));
      expect(engine.totalForLastDays(7, now: DateTime(2026, 1, 3)), 2);
    });

    test('count below 1 is ignored', () {
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList, count: 0);
      engine.record(BlockCategory.filterList, count: -5);
      expect(engine.allTimeTotal, 0);
    });
  });

  group('category totals', () {
    test('totals split by category and sum to the range total', () {
      final now = DateTime(2026, 8, 19, 10);
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList, count: 10, now: now);
      engine.record(BlockCategory.dnsBlocklist, count: 4, now: now);
      engine.record(BlockCategory.trackingParam, count: 1, now: now);
      engine.record(BlockCategory.localCdn, count: 2, now: now);

      final totals = engine.totalsForLastDays(7, now: now);
      expect(totals[BlockCategory.filterList], 10);
      expect(totals[BlockCategory.dnsBlocklist], 4);
      expect(totals[BlockCategory.trackingParam], 1);
      expect(totals[BlockCategory.localCdn], 2);
      expect(engine.totalForLastDays(7, now: now), 17);
    });

    test('dailyTotals is oldest-first and aligned to the window', () {
      final now = DateTime(2026, 8, 19);
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList, count: 5, now: now);
      engine.record(BlockCategory.dnsBlocklist,
          count: 2, now: DateTime(2026, 8, 17));

      expect(engine.dailyTotals(7, now: now), [0, 0, 0, 0, 2, 0, 5]);
    });
  });

  group('retention (STATS-004)', () {
    test('prune drops buckets past the retention window, keeps all-time', () {
      final now = DateTime(2026, 8, 19);
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList,
          count: 7, now: DateTime(2026, 1, 1));
      engine.record(BlockCategory.filterList, count: 3, now: now);

      expect(engine.prune(now: now), 1);
      expect(engine.totalForLastDays(BlockStatsEngine.retentionDays, now: now), 3);
      expect(engine.allTimeTotal, 10);
    });

    test('prune keeps a bucket exactly on the cutoff', () {
      final now = DateTime(2026, 8, 19);
      final edge = DateTime(2026, 8, 19 - BlockStatsEngine.retentionDays);
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList, now: edge);
      expect(engine.prune(now: now), 0);
      expect(engine.allTimeTotal, 1);
    });
  });

  group('reset', () {
    test('clears every counter and restarts the since clock', () {
      final engine = BlockStatsEngine(since: DateTime(2026, 1, 1));
      engine.record(BlockCategory.filterList, count: 5);
      engine.reset(now: DateTime(2026, 8, 19));

      expect(engine.allTimeTotal, 0);
      expect(engine.totalForLastDays(30, now: DateTime(2026, 8, 19)), 0);
      expect(engine.since, DateTime(2026, 8, 19));
    });
  });

  group('persistence round-trip (STATS-002)', () {
    test('toJson/fromJson preserves buckets, all-time totals and since', () {
      final now = DateTime(2026, 8, 19, 8);
      final engine = BlockStatsEngine(since: DateTime(2026, 6, 22));
      engine.record(BlockCategory.filterList, count: 9, now: now);
      engine.record(BlockCategory.trackingParam,
          count: 4, now: DateTime(2026, 8, 15));

      final restored = BlockStatsEngine.fromJson(engine.toJson());

      expect(restored.since, DateTime(2026, 6, 22));
      expect(restored.allTimeTotal, 13);
      expect(restored.totalsForLastDays(7, now: now)[BlockCategory.filterList], 9);
      expect(
        restored.totalsForLastDays(7, now: now)[BlockCategory.trackingParam],
        4,
      );
    });

    test('a restored engine is clean until it is mutated again', () {
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList);
      expect(engine.isDirty, isTrue);
      engine.markClean();
      expect(engine.isDirty, isFalse);
      engine.record(BlockCategory.filterList);
      expect(engine.isDirty, isTrue);
    });

    test('markCleanAt clears only what the written payload carried', () {
      final engine = BlockStatsEngine();
      engine.record(BlockCategory.filterList);
      final written = engine.revision;

      // A block recorded while the write was in flight: it is not in the
      // payload, so the engine must stay dirty for the next flush.
      engine.record(BlockCategory.dnsBlocklist);
      engine.markCleanAt(written);
      expect(engine.isDirty, isTrue);

      engine.markCleanAt(engine.revision);
      expect(engine.isDirty, isFalse);
    });

    test('corrupt payloads degrade instead of throwing', () {
      final restored = BlockStatsEngine.fromJson(<String, dynamic>{
        'since': 'not-a-date',
        'allTime': {'abp': 5, 'unknown-category': 3, 'dns': 'nope'},
        'days': {
          'not-a-day': {'abp': 1},
          '20260819': 'not-a-bucket',
          '20260818': {'abp': -4},
        },
      });

      expect(restored.allTimeTotals[BlockCategory.filterList], 5);
      expect(restored.allTimeTotals[BlockCategory.dnsBlocklist], isNull);
      expect(restored.totalForLastDays(30, now: DateTime(2026, 8, 19)), 0);
    });
  });
}
