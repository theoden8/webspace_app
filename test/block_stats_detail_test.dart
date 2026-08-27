import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/block_stats_detail.dart';
import 'package:webspace/services/block_stats_engine.dart';

/// `MapEntry` has no value equality, so compare the pairs positionally.
List<List<Object>> _pairs(List<MapEntry<String, int>> entries) =>
    [for (final e in entries) [e.key, e.value]];

void main() {
  group('BlockStatsDetail (STATS-008)', () {
    test('folds repeats of the same label and keeps the most frequent first',
        () {
      final detail = BlockStatsDetail();

      detail.record(BlockCategory.dnsBlocklist,
          siteId: 'a', label: 'ads.example', count: 3);
      detail.record(BlockCategory.dnsBlocklist,
          siteId: 'a', label: 'ads.example', count: 2);
      detail.record(BlockCategory.dnsBlocklist,
          siteId: 'a', label: 'beacon.example');

      final items = detail.topItems(BlockCategory.dnsBlocklist);
      expect(items.map((i) => i.label).toList(), ['ads.example', 'beacon.example']);
      expect(items.first.count, 5);
    });

    test('labels are case-folded so one host is one row', () {
      final detail = BlockStatsDetail();

      detail.record(BlockCategory.filterList, siteId: 'a', label: 'CDN.Example');
      detail.record(BlockCategory.filterList, siteId: 'a', label: 'cdn.example');

      final items = detail.topItems(BlockCategory.filterList);
      expect(items.length, 1);
      expect(items.single.label, 'cdn.example');
      expect(items.single.count, 2);
    });

    test('categories do not mix', () {
      final detail = BlockStatsDetail();

      detail.record(BlockCategory.dnsBlocklist, siteId: 'a', label: 'x.example');
      detail.record(BlockCategory.trackingParam, siteId: 'a', label: 'utm_source');

      expect(detail.topItems(BlockCategory.dnsBlocklist).single.label, 'x.example');
      expect(detail.topItems(BlockCategory.trackingParam).single.label, 'utm_source');
      expect(detail.topItems(BlockCategory.localCdn), isEmpty);
    });

    test('per-site counts are kept per category, most blocked first', () {
      final detail = BlockStatsDetail();

      detail.record(BlockCategory.filterList, siteId: 'quiet', label: 'a.example');
      detail.record(BlockCategory.filterList,
          siteId: 'noisy', label: 'b.example', count: 9);
      detail.record(BlockCategory.dnsBlocklist, siteId: 'quiet', label: 'c.example');

      expect(_pairs(detail.siteCounts(BlockCategory.filterList)),
          [['noisy', 9], ['quiet', 1]]);
      expect(_pairs(detail.siteCounts(BlockCategory.dnsBlocklist)),
          [['quiet', 1]]);
    });

    test('an unlabelled event still attributes to its site', () {
      final detail = BlockStatsDetail();

      detail.record(BlockCategory.localCdn, siteId: 'a', count: 4);

      expect(detail.topItems(BlockCategory.localCdn), isEmpty);
      expect(_pairs(detail.siteCounts(BlockCategory.localCdn)), [['a', 4]]);
      expect(detail.totalFor(BlockCategory.localCdn), 4);
    });

    test('the item table is bounded, evicting the least frequent', () {
      final detail = BlockStatsDetail();
      const cap = BlockStatsDetail.maxItemsPerCategory;

      detail.record(BlockCategory.filterList,
          siteId: 'a', label: 'persistent.example', count: 500);
      for (var i = 0; i < cap * 2; i++) {
        detail.record(BlockCategory.filterList,
            siteId: 'a', label: 'one-off-$i.example');
      }

      final items = detail.topItems(BlockCategory.filterList, limit: cap);
      expect(items.length, lessThanOrEqualTo(cap));
      expect(items.first.label, 'persistent.example');
      expect(items.first.count, 500);
    });

    test('a table round-trips through its stored form', () {
      final detail = BlockStatsDetail();
      detail.record(BlockCategory.dnsBlocklist,
          siteId: 'site-a', label: 'ads.example', count: 3);
      detail.record(BlockCategory.dnsBlocklist,
          siteId: 'site-b', label: 'beacon.example');

      final restored = BlockStatsDetail()
        ..mergeFromJson(jsonDecode(jsonEncode(detail.toJson())));

      expect(restored.topItems(BlockCategory.dnsBlocklist).map((i) => i.label),
          ['ads.example', 'beacon.example']);
      expect(restored.topItems(BlockCategory.dnsBlocklist).first.count, 3);
      expect(_pairs(restored.siteCounts(BlockCategory.dnsBlocklist)),
          [['site-a', 3], ['site-b', 1]]);
      expect(restored.isDirty, isFalse);
    });

    test('a malformed row is dropped without taking its neighbours', () {
      final detail = BlockStatsDetail();

      detail.mergeFromJson({
        'v': 1,
        'cats': {
          'dns': {
            'items': [
              ['ads.example', 4, 1700000000000],
              ['truncated', 2],
              ['negative.example', -1, 1700000000000],
              'not a row',
            ],
          },
          'nosuchcategory': {'items': <Object>[]},
        },
      });

      expect(detail.topItems(BlockCategory.dnsBlocklist).map((i) => i.label),
          ['ads.example']);
    });

    test('rows older than the retention window are pruned', () {
      final detail = BlockStatsDetail();
      final now = DateTime(2026, 3, 1);

      detail.record(BlockCategory.filterList,
          siteId: 'stale', label: 'old.example', now: DateTime(2025, 10, 1));
      detail.record(BlockCategory.filterList,
          siteId: 'fresh', label: 'new.example', now: now);

      expect(detail.prune(now: now), 2);
      expect(detail.topItems(BlockCategory.filterList).map((i) => i.label),
          ['new.example']);
      expect(_pairs(detail.siteCounts(BlockCategory.filterList)),
          [['fresh', 1]]);
    });

    test('retainSites drops rows for sites that are gone, keeping the hosts',
        () {
      final detail = BlockStatsDetail();
      detail.record(BlockCategory.filterList,
          siteId: 'kept', label: 'ads.example');
      detail.record(BlockCategory.filterList,
          siteId: 'deleted', label: 'ads.example');

      expect(detail.retainSites({'kept'}), 1);
      expect(_pairs(detail.siteCounts(BlockCategory.filterList)),
          [['kept', 1]]);
      expect(detail.topItems(BlockCategory.filterList).single.count, 2);
    });

    test('a stored blob over the cap is trimmed to the most frequent', () {
      const cap = BlockStatsDetail.maxItemsPerCategory;
      final detail = BlockStatsDetail();

      detail.mergeFromJson({
        'v': 1,
        'cats': {
          'abp': {
            'items': [
              ['persistent.example', 500, 1700000000000],
              for (var i = 0; i < cap * 2; i++)
                ['one-off-$i.example', 1, 1700000000000],
            ],
          },
        },
      });

      final items = detail.topItems(BlockCategory.filterList, limit: cap * 2);
      expect(items.length, cap);
      expect(items.first.label, 'persistent.example');
    });

    test('clear drops every item and site', () {
      final detail = BlockStatsDetail();
      detail.record(BlockCategory.filterList, siteId: 'a', label: 'x.example');

      detail.clear();

      expect(detail.isEmpty, isTrue);
      expect(detail.topItems(BlockCategory.filterList), isEmpty);
      expect(detail.siteCounts(BlockCategory.filterList), isEmpty);
    });
  });
}
