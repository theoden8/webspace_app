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
  });
}
