import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/dns_block_service.dart';

void main() {
  late DnsBlockService service;

  setUp(() {
    // Create a fresh instance for each test (bypass singleton for isolation)
    service = DnsBlockService.instance;
    // Clear any prior state
    service.loadDomainsFromString('');
  });

  group('DnsBlockService', () {
    test('hasBlocklist is false when no domains loaded', () {
      expect(service.hasBlocklist, isFalse);
    });

    test('hasBlocklist is true after loading domains', () {
      service.loadDomainsFromString('tracker.net\nad.example.com');
      expect(service.hasBlocklist, isTrue);
    });

    test('exact domain match blocks URL', () {
      service.loadDomainsFromString('tracker.net');
      expect(service.isBlocked('https://tracker.net/path'), isTrue);
    });

    test('subdomain is blocked when parent domain is in list', () {
      service.loadDomainsFromString('tracker.net');
      expect(service.isBlocked('https://sub.tracker.net/path'), isTrue);
      expect(service.isBlocked('https://deep.sub.tracker.net/'), isTrue);
    });

    test('no partial string match - mytracker.net is NOT blocked by tracker.net', () {
      service.loadDomainsFromString('tracker.net');
      expect(service.isBlocked('https://mytracker.net/'), isFalse);
    });

    test('comment lines are skipped', () {
      service.loadDomainsFromString('# This is a comment\ntracker.net\n# Another comment');
      expect(service.domainCount, equals(1));
      expect(service.isBlocked('https://tracker.net/'), isTrue);
    });

    test('empty lines are skipped', () {
      service.loadDomainsFromString('\n\ntracker.net\n\n');
      expect(service.domainCount, equals(1));
    });

    test('empty input results in no blocking', () {
      service.loadDomainsFromString('');
      expect(service.hasBlocklist, isFalse);
      expect(service.isBlocked('https://anything.com/'), isFalse);
    });

    test('domain hierarchy walk-up works correctly', () {
      service.loadDomainsFromString('ads.example.com');
      // Exact match
      expect(service.isBlocked('https://ads.example.com/'), isTrue);
      // Subdomain of blocked domain
      expect(service.isBlocked('https://sub.ads.example.com/'), isTrue);
      // Parent domain is NOT blocked
      expect(service.isBlocked('https://example.com/'), isFalse);
      // Sibling domain is NOT blocked
      expect(service.isBlocked('https://www.example.com/'), isFalse);
    });

    test('returns false for invalid URLs', () {
      service.loadDomainsFromString('tracker.net');
      expect(service.isBlocked('not-a-url'), isFalse);
      expect(service.isBlocked(''), isFalse);
    });

    test('multiple domains loaded correctly', () {
      service.loadDomainsFromString(
        'tracker.net\nad.example.com\nmalware.evil.org',
      );
      expect(service.domainCount, equals(3));
      expect(service.isBlocked('https://tracker.net/'), isTrue);
      expect(service.isBlocked('https://ad.example.com/'), isTrue);
      expect(service.isBlocked('https://malware.evil.org/'), isTrue);
      expect(service.isBlocked('https://safe.example.com/'), isFalse);
    });

    test('level names are defined for levels 0-5', () {
      expect(dnsBlockLevelNames.length, equals(6));
      expect(dnsBlockLevelNames[0], equals('Off'));
      expect(dnsBlockLevelNames[1], equals('Light'));
      expect(dnsBlockLevelNames[2], equals('Normal'));
      expect(dnsBlockLevelNames[3], equals('Pro'));
      expect(dnsBlockLevelNames[4], equals('Pro++'));
      expect(dnsBlockLevelNames[5], equals('Ultimate'));
    });

    test('isBlocked() result is invalidated when blocklist reloads', () {
      // Cache holds true for tracker.net via the first lookup.
      service.loadDomainsFromString('tracker.net');
      expect(service.isBlocked('https://tracker.net/'), isTrue);

      // Reload with a different list. _notifyBlocklistChanged must clear
      // the DNS host cache so a stale `true` doesn't survive.
      service.loadDomainsFromString('other.net');
      expect(service.isBlocked('https://tracker.net/'), isFalse,
          reason: 'cache must be cleared when _blockedDomains changes');
      expect(service.isBlocked('https://other.net/'), isTrue);
    });

    test('isBlocked() result is invalidated when blocklist clears', () {
      service.loadDomainsFromString('tracker.net');
      expect(service.isBlocked('https://tracker.net/'), isTrue);

      // Clear: should not still report blocked.
      service.loadDomainsFromString('');
      expect(service.isBlocked('https://tracker.net/'), isFalse);
    });

    test('isBlocked() cache is bounded — many distinct hosts do not blow memory', () {
      service.loadDomainsFromString('tracker.net');
      // Hammer the cache with 20K distinct *unblocked* hosts. The cap is
      // 5000, so the cache must FIFO-evict and never grow past it. We can't
      // read the private cache, but we can assert the function still
      // answers correctly under the load and that it stays fast (a runaway
      // unbounded cache would either OOM or slow to a crawl).
      final sw = Stopwatch()..start();
      for (int i = 0; i < 20000; i++) {
        service.isBlocked('https://host$i.example.test/');
      }
      sw.stop();
      // Generous bound: 20K bounded-cache lookups should finish well under
      // a second on any machine that runs this test suite.
      expect(sw.elapsedMilliseconds, lessThan(2000),
          reason: 'cache eviction path must be O(1)');
      // Sanity: still answers correctly after the churn.
      expect(service.isBlocked('https://tracker.net/'), isTrue);
      expect(service.isBlocked('https://host999999.example.test/'), isFalse);
    });
  });
}
