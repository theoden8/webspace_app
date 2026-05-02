import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/dns_block_service.dart';

/// Tests for [DnsStats] after switching the log to a fixed-size ring
/// buffer and adding the `count` parameter to [DnsStats.record]. The
/// previous test surface didn't exercise the log directly because the
/// behaviour was an obvious `List.add` — now that log/counter semantics
/// can diverge (count > 1 keeps log size at +1 but bumps totals by N),
/// pin them down.
void main() {
  group('DnsStats counters', () {
    test('records allowed with default count=1', () {
      final s = DnsStats();
      s.record('a.com', false);
      expect(s.allowed, equals(1));
      expect(s.blocked, equals(0));
      expect(s.total, equals(1));
    });

    test('records blocked with source attribution', () {
      final s = DnsStats();
      s.record('ad.com', true, source: BlockSource.dns);
      s.record('tr.com', true, source: BlockSource.abp);
      expect(s.blockedByDns, equals(1));
      expect(s.blockedByAbp, equals(1));
      expect(s.blocked, equals(2));
      expect(s.allowed, equals(0));
    });

    test('count > 1 increments totals by count but log grows by one', () {
      final s = DnsStats();
      s.record('cdn.example.com', false, count: 47);
      expect(s.allowed, equals(47),
          reason: 'count must fold into the total');
      expect(s.log, hasLength(1),
          reason: 'log entry stays at +1 regardless of count');
      expect(s.log.single.domain, equals('cdn.example.com'));
      expect(s.log.single.blocked, isFalse);
    });

    test('count > 1 with blocked + source attributes correctly', () {
      final s = DnsStats();
      s.record('ad.example.com', true, source: BlockSource.dns, count: 12);
      s.record('tr.example.com', true, source: BlockSource.abp, count: 5);
      expect(s.blocked, equals(17));
      expect(s.blockedByDns, equals(12));
      expect(s.blockedByAbp, equals(5));
      expect(s.log, hasLength(2));
    });

    test('count below 1 is clamped to 1', () {
      final s = DnsStats();
      s.record('a.com', false, count: 0);
      s.record('b.com', false, count: -3);
      expect(s.allowed, equals(2));
      expect(s.log, hasLength(2));
    });

    test('blockRate computes correctly', () {
      final s = DnsStats();
      s.record('a.com', false);
      s.record('a.com', false);
      s.record('a.com', false);
      s.record('ad.com', true, source: BlockSource.dns);
      expect(s.blockRate, equals(25.0));
    });

    test('clear resets everything', () {
      final s = DnsStats();
      s.record('a.com', false, count: 10);
      s.record('ad.com', true, source: BlockSource.dns, count: 5);
      s.clear();
      expect(s.allowed, equals(0));
      expect(s.blocked, equals(0));
      expect(s.blockedByDns, equals(0));
      expect(s.log, isEmpty);
    });
  });

  group('DnsStats log ring buffer', () {
    test('log grows from empty in insertion order', () {
      final s = DnsStats();
      for (var i = 0; i < 5; i++) {
        s.record('host$i.com', false);
      }
      final entries = s.log;
      expect(entries, hasLength(5));
      for (var i = 0; i < 5; i++) {
        expect(entries[i].domain, equals('host$i.com'),
            reason: 'oldest-first iteration order');
      }
    });

    test('log caps at 500 entries with FIFO eviction', () {
      final s = DnsStats();
      // Fill past the cap. The oldest 100 must be dropped.
      for (var i = 0; i < 600; i++) {
        s.record('host$i.com', false);
      }
      final entries = s.log;
      expect(entries, hasLength(500));
      // Oldest surviving entry should be host100 (host0..host99 evicted).
      expect(entries.first.domain, equals('host100.com'));
      expect(entries.last.domain, equals('host599.com'));
    });

    test('log ordering survives wrap-around', () {
      final s = DnsStats();
      // Insert exactly cap + 1 to cross the boundary by one.
      for (var i = 0; i < 501; i++) {
        s.record('h$i', false);
      }
      final entries = s.log;
      expect(entries, hasLength(500));
      expect(entries.first.domain, equals('h1'));
      expect(entries.last.domain, equals('h500'));
    });

    test('clear empties the ring and accepts new entries', () {
      final s = DnsStats();
      for (var i = 0; i < 600; i++) {
        s.record('h$i', false);
      }
      s.clear();
      expect(s.log, isEmpty);
      s.record('fresh.com', false);
      expect(s.log, hasLength(1));
      expect(s.log.single.domain, equals('fresh.com'));
    });

    test('blocked entries retain source in log', () {
      final s = DnsStats();
      s.record('a.com', true, source: BlockSource.dns);
      s.record('b.com', true, source: BlockSource.abp);
      s.record('c.com', false);
      final entries = s.log;
      expect(entries[0].source, equals(BlockSource.dns));
      expect(entries[1].source, equals(BlockSource.abp));
      expect(entries[2].source, isNull, reason: 'allowed entries have no source');
    });
  });

  group('DnsBlockService.recordHostRequest', () {
    setUp(() {
      DnsBlockService.instance.loadDomainsFromString('');
      DnsBlockService.instance.clearStatsForSite('site-A');
    });

    test('skips empty host', () {
      DnsBlockService.instance.recordHostRequest('site-A', '', false);
      final stats = DnsBlockService.instance.statsForSite('site-A');
      expect(stats.total, equals(0));
    });

    test('records with count', () {
      DnsBlockService.instance.recordHostRequest(
          'site-A', 'cdn.example.com', false,
          count: 25);
      final stats = DnsBlockService.instance.statsForSite('site-A');
      expect(stats.allowed, equals(25));
      expect(stats.log, hasLength(1));
    });

    test('records source-attributed block with count', () {
      DnsBlockService.instance.recordHostRequest(
          'site-A', 'ad.example.com', true,
          source: BlockSource.abp, count: 7);
      final stats = DnsBlockService.instance.statsForSite('site-A');
      expect(stats.blocked, equals(7));
      expect(stats.blockedByAbp, equals(7));
    });
  });

  group('DnsBlockService coalesced log listener notification', () {
    setUp(() {
      DnsBlockService.instance.loadDomainsFromString('');
      DnsBlockService.instance.clearStatsForSite('site-N');
    });

    test('many recordHostRequest calls fire one listener per microtask', () async {
      var notifications = 0;
      void listener() {
        notifications++;
      }

      DnsBlockService.instance.addDnsLogListener(listener);
      try {
        // Burst of recordings — the listener must fire exactly once per
        // microtask flush, not once per recorded request.
        for (var i = 0; i < 50; i++) {
          DnsBlockService.instance
              .recordHostRequest('site-N', 'h$i.com', false);
        }
        expect(notifications, equals(0),
            reason: 'notification deferred to next microtask');
        // Flush the microtask queue.
        await Future<void>.delayed(Duration.zero);
        expect(notifications, equals(1),
            reason: 'one coalesced flush, not 50');

        // A second burst after the flush goes into a fresh microtask.
        for (var i = 0; i < 10; i++) {
          DnsBlockService.instance
              .recordHostRequest('site-N', 'x$i.com', false);
        }
        await Future<void>.delayed(Duration.zero);
        expect(notifications, equals(2));
      } finally {
        DnsBlockService.instance.removeDnsLogListener(listener);
      }
    });

    test('listener registration with no prior listener does not retroactively notify', () async {
      // Record before any listener is attached — these should not fire.
      for (var i = 0; i < 5; i++) {
        DnsBlockService.instance.recordHostRequest('site-N', 'pre$i.com', false);
      }
      var notifications = 0;
      DnsBlockService.instance.addDnsLogListener(() => notifications++);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, equals(0));
    });
  });
}
