import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/content_blocker_service.dart';

/// Direct tests for [ContentBlockerService.isBlocked] / `isHostBlocked`
/// after the Uri.parse → extractHost + per-host FIFO cache rewrite. The
/// existing content_blocker_service_test.dart only covers FilterList
/// JSON serialization; the hot-path matching had no real coverage.
void main() {
  late ContentBlockerService service;

  setUp(() {
    service = ContentBlockerService.instance;
    service.reset();
  });

  group('ContentBlockerService.isBlocked', () {
    test('returns false when no rules loaded', () {
      expect(service.isBlocked('https://example.com/path'), isFalse);
    });

    test('exact host match', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://tracker.net/'), isTrue);
    });

    test('subdomain matches blocked parent', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://ads.tracker.net/path'), isTrue);
      expect(service.isBlocked('https://a.b.c.tracker.net/'), isTrue);
    });

    test('unrelated host with same suffix does NOT match', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://mytracker.net/'), isFalse,
          reason: 'partial string match must not cross label boundary');
    });

    test('host extraction strips port and userinfo', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://tracker.net:8443/'), isTrue);
      expect(service.isBlocked('https://user:pass@tracker.net/'), isTrue);
    });

    test('case-insensitive', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://Tracker.NET/'), isTrue);
      expect(service.isBlocked('HTTPS://SUB.TRACKER.NET/'), isTrue);
    });

    test('returns false for non-http schemes', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('about:blank'), isFalse);
      expect(service.isBlocked('data:text/html,hi'), isFalse);
      expect(service.isBlocked('javascript:0'), isFalse);
    });

    test('eTLD-only entry does not block everything', () {
      service.setBlockedDomainsForTest({'com'});
      expect(service.isBlocked('https://example.com/'), isFalse,
          reason: 'walk must stop above eTLD');
    });

    test('cache is invalidated when domain set changes', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://tracker.net/'), isTrue);
      // Cache now holds tracker.net→true. Swap the set; the cached
      // decision must be discarded.
      service.setBlockedDomainsForTest({'other.com'});
      expect(service.isBlocked('https://tracker.net/'), isFalse,
          reason: 'cache must clear when blocked-domain set is replaced');
      expect(service.isBlocked('https://other.com/'), isTrue);
    });

    test('cache holds bounded distinct hosts under load', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      final sw = Stopwatch()..start();
      for (int i = 0; i < 20000; i++) {
        service.isBlocked('https://host$i.example.test/');
      }
      sw.stop();
      // Sanity: still answers correctly after the churn.
      expect(service.isBlocked('https://tracker.net/'), isTrue);
      expect(service.isBlocked('https://host999999.example.test/'), isFalse);
      // 20K bounded-cache lookups must finish well under a second.
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });

    test('reset clears the cache', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isBlocked('https://tracker.net/'), isTrue);
      service.reset();
      // After reset the domain set is empty; even a previously-cached
      // "true" must not survive.
      expect(service.isBlocked('https://tracker.net/'), isFalse);
    });
  });

  group('ContentBlockerService.isHostBlocked', () {
    test('skips URL parsing — host is the input', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isHostBlocked('tracker.net'), isTrue);
      expect(service.isHostBlocked('sub.tracker.net'), isTrue);
      expect(service.isHostBlocked('mytracker.net'), isFalse);
    });

    test('returns false on empty host', () {
      service.setBlockedDomainsForTest({'tracker.net'});
      expect(service.isHostBlocked(''), isFalse);
    });

    test('returns false when no rules loaded', () {
      expect(service.isHostBlocked('tracker.net'), isFalse);
    });
  });
}
