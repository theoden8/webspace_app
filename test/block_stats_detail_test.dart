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
      expect(detail.sessionTotal(BlockCategory.localCdn), 4);
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
