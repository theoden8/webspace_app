// End-to-end accounting: a block decision made anywhere in the app must
// arrive at the protection report. The unit tests cover the engine and the
// service in isolation; this covers the seam between them and the real
// recording funnels, which is where a silent zero hides.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/block_stats_engine.dart';
import 'package:webspace/services/block_stats_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/web_intercept_native.dart';

import 'helpers/memory_block_stats_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BlockStatsService stats;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    BlockStatsService.resetInstanceForTest();
    stats = BlockStatsService.instance;
    await stats.initialize(detailStore: MemoryBlockStatsDetailStore());
    stats.setSiteContributes('site-1', true);
    DnsBlockService.instance.clearStatsForSite('site-1');
  });

  group('DnsBlockService funnel feeds the report', () {
    test('a DNS-attributed block increments the DNS category', () {
      DnsBlockService.instance.recordHostRequest(
          'site-1', 'tracker.example', true,
          source: BlockSource.dns, count: 3);

      expect(stats.engine.allTimeTotals[BlockCategory.dnsBlocklist], 3);
      expect(stats.engine.allTimeTotal, 3);
    });

    test('an ABP-attributed block increments the filter-list category', () {
      DnsBlockService.instance.recordHostRequest('site-1', 'ads.example', true,
          source: BlockSource.abp, count: 5);

      expect(stats.engine.allTimeTotals[BlockCategory.filterList], 5);
    });

    test('the URL-shaped funnel lands the same way', () {
      DnsBlockService.instance.recordRequest(
          'site-1', 'https://ads.example/pixel.gif', true,
          source: BlockSource.abp);

      expect(stats.engine.allTimeTotals[BlockCategory.filterList], 1);
    });

    test('allowed requests move no report counter', () {
      DnsBlockService.instance
          .recordHostRequest('site-1', 'cdn.example', false, count: 9);

      expect(stats.engine.allTimeTotal, 0);
    });

    test('the report never disagrees with the per-site counters', () {
      DnsBlockService.instance.recordHostRequest('site-1', 'a.example', true,
          source: BlockSource.dns, count: 2);
      DnsBlockService.instance.recordHostRequest('site-1', 'b.example', true,
          source: BlockSource.abp, count: 7);
      DnsBlockService.instance
          .recordHostRequest('site-1', 'c.example', false, count: 4);

      final perSite = DnsBlockService.instance.statsForSite('site-1');
      expect(stats.engine.allTimeTotal, perSite.blocked);
      expect(stats.engine.allTimeTotals[BlockCategory.dnsBlocklist],
          perSite.blockedByDns);
      expect(stats.engine.allTimeTotals[BlockCategory.filterList],
          perSite.blockedByAbp);
    });
  });

  group('Android native drain feeds the report', () {
    /// Drive the decode step with the payload shape
    /// `WebInterceptPlugin.drainBlockEvents` actually emits:
    /// `{host, blocked, source, count}`, with `source` absent when allowed.
    /// The fetch around it is `Platform.isAndroid`-gated, which is why the
    /// accounting is exercised here rather than through the channel.
    test('native block events reach the report with their attribution', () {
      WebInterceptNative.applyBlockEvents('site-1', [
        {'host': 'ads.example', 'blocked': true, 'source': 'abp', 'count': 12},
        {'host': 'trk.example', 'blocked': true, 'source': 'dns', 'count': 4},
        {'host': 'cdn.example', 'blocked': false, 'count': 30},
      ]);

      expect(stats.engine.allTimeTotals[BlockCategory.filterList], 12);
      expect(stats.engine.allTimeTotals[BlockCategory.dnsBlocklist], 4);
      expect(stats.engine.allTimeTotal, 16);
    });

    test('a source-less block is counted per-site but not categorised', () {
      WebInterceptNative.applyBlockEvents('site-1', [
        {'host': 'ads.example', 'blocked': true, 'count': 6},
      ]);

      expect(DnsBlockService.instance.statsForSite('site-1').blocked, 6);
      expect(stats.engine.allTimeTotal, 0);
    });

    test('malformed entries are skipped without losing the good ones', () {
      WebInterceptNative.applyBlockEvents('site-1', [
        {'blocked': true, 'source': 'abp', 'count': 3},
        {'host': 'ok.example', 'blocked': true, 'source': 'abp', 'count': 2},
        'not-a-map',
      ]);

      expect(stats.engine.allTimeTotals[BlockCategory.filterList], 2);
    });

    test('an archive-tier site drains without moving the report', () {
      stats.setSiteContributes('site-1', false);

      WebInterceptNative.applyBlockEvents('site-1', [
        {'host': 'ads.example', 'blocked': true, 'source': 'abp', 'count': 12},
      ]);

      expect(stats.engine.allTimeTotal, 0);
      expect(DnsBlockService.instance.statsForSite('site-1').blocked, 12);
    });
  });

  group('LocalCDN funnel feeds the report', () {
    test('a cache substitution increments the CDN category', () {
      LocalCdnService.instance.recordReplacement('site-1');
      LocalCdnService.instance.recordReplacement('site-1');

      expect(stats.engine.allTimeTotals[BlockCategory.localCdn], 2);
    });
  });

  group('the funnels name what they stopped (STATS-008)', () {
    test('a blocked host arrives as the detail item', () {
      DnsBlockService.instance.recordHostRequest(
          'site-1', 'Tracker.Example', true,
          source: BlockSource.dns, count: 2);

      final items = stats.detail.topItems(BlockCategory.dnsBlocklist);
      expect(items.single.label, 'tracker.example');
      expect(items.single.count, 2);
      expect(stats.detail.siteCounts(BlockCategory.dnsBlocklist).single.key,
          'site-1');
    });

    test('the native drain carries the host through', () {
      WebInterceptNative.applyBlockEvents('site-1', [
        {'host': 'ads.example', 'blocked': true, 'source': 'abp', 'count': 4},
      ]);

      expect(stats.detail.topItems(BlockCategory.filterList).single.label,
          'ads.example');
    });

    test('a locally served CDN request is named by its origin', () {
      LocalCdnService.instance.recordReplacement('site-1',
          url: 'https://cdn.example/lib/jquery.js');

      expect(stats.detail.topItems(BlockCategory.localCdn).single.label,
          'cdn.example');
    });

    test('a CDN event with no URL still attributes to the site', () {
      LocalCdnService.instance.recordReplacement('site-1');

      expect(stats.detail.topItems(BlockCategory.localCdn), isEmpty);
      expect(stats.detail.totalFor(BlockCategory.localCdn), 1);
    });
  });
}
