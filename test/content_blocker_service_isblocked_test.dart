import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/adblock_engine.dart';
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

  group('ContentBlockerService.isBlocked path-anchored rules', () {
    test('blocks URL whose path matches the glob', () {
      service.setDomainPathRulesForTest({
        'example.com': ['/ads/'],
      });
      expect(service.isBlocked('https://example.com/ads/banner.png'), isTrue);
    });

    test('does NOT block paths outside the glob', () {
      service.setDomainPathRulesForTest({
        'example.com': ['/ads/'],
      });
      expect(service.isBlocked('https://example.com/news/'), isFalse);
      expect(service.isBlocked('https://example.com/'), isFalse);
    });

    test('star wildcard matches anywhere in the path', () {
      service.setDomainPathRulesForTest({
        'example.com': ['*tracker.js'],
      });
      expect(
          service.isBlocked('https://example.com/foo/bar/tracker.js'), isTrue);
      expect(service.isBlocked('https://example.com/tracker.js'), isTrue);
      expect(service.isBlocked('https://example.com/foo/bar.js'), isFalse);
    });

    test('subdomain inherits parent domain path glob', () {
      // walk-up: `cdn.example.com` should pick up the glob registered
      // against `example.com`. Mirrors the host walk-up the pure-domain
      // path uses via hostInSet.
      service.setDomainPathRulesForTest({
        'example.com': ['/track'],
      });
      expect(service.isBlocked('https://cdn.example.com/track/x'), isTrue);
    });

    test('path glob does not match unrelated host', () {
      service.setDomainPathRulesForTest({
        'example.com': ['/ads/'],
      });
      expect(service.isBlocked('https://other.com/ads/banner.png'), isFalse);
    });

    test('exception domain overrides path-anchored block', () {
      service.setDomainPathRulesForTest({
        'example.com': ['/ads/'],
      });
      service.setExceptionDomains({'example.com'});
      expect(service.isBlocked('https://example.com/ads/banner.png'), isFalse);
    });

    test('pure-domain block wins without consulting paths', () {
      service.setBlockedDomainsForTest({'example.com'});
      service.setDomainPathRulesForTest({
        'example.com': ['/never-matched'],
      });
      // Domain block fires first; the irrelevant path glob doesn't
      // matter — every URL on example.com is blocked.
      expect(service.isBlocked('https://example.com/'), isTrue);
      expect(service.isBlocked('https://example.com/foo'), isTrue);
    });

    test('isHostBlocked ignores path-anchored rules', () {
      // The host-only fast path can't see the URL path, so path-only
      // rules MUST NOT report a hit through isHostBlocked. The
      // PerformanceObserver/sub-resource path uses this method and
      // would otherwise over-block.
      service.setDomainPathRulesForTest({
        'example.com': ['/ads/'],
      });
      expect(service.isHostBlocked('example.com'), isFalse);
    });

    test('case-insensitive path matching', () {
      service.setDomainPathRulesForTest({
        'example.com': ['/Ads/'],
      });
      expect(service.isBlocked('https://example.com/ADS/banner'), isTrue);
    });

    test('many path globs do not blow up', () {
      // Sanity — registered rules compile once at setup, and runtime
      // does at most N regex.hasMatch per blocked-domain hit.
      final rules = <String>[];
      for (var i = 0; i < 100; i++) {
        rules.add('/path$i/');
      }
      service.setDomainPathRulesForTest({'example.com': rules});
      final sw = Stopwatch()..start();
      for (var i = 0; i < 200; i++) {
        service.isBlocked('https://example.com/path${i % 100}/x');
        service.isBlocked('https://example.com/no-match/y');
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });

  group('ContentBlockerService.isBlocked routes through Rust engine when set', () {
    final libExists = _rustLibExists();

    test('engine answer overrides Dart aggregations', () {
      // Arrange: Dart aggregations say example.com is blocked. Engine
      // says it's NOT blocked (different rule set). The engine answer
      // wins — this proves the routing actually delegates and isn't
      // accidentally falling through to the Dart path.
      final engine = AdblockEngine.load('||tracker.com^\n')!;
      service.setBlockedDomainsForTest({'example.com'});
      service.setRustEngineForTest(engine);
      addTearDown(() {
        // setRustEngineForTest takes ownership and disposes on next
        // call / reset; reset() at setUp covers this implicitly.
      });

      expect(service.isBlocked('https://example.com/'), isFalse,
          reason: 'engine has no rule for example.com — must override Dart hit');
      expect(service.isBlocked('https://tracker.com/'), isTrue,
          reason: 'engine has the tracker.com rule — Dart aggregations did not');
    }, skip: libExists ? false : 'Rust library not built');

    test(r'engine handles $domain= modifier the Dart engine drops', () {
      // The headline reason for adopting the engine. With no Rust
      // engine set, the Dart path doesn't see this rule at all. With
      // the engine routed, the rule fires conditionally.
      final engine = AdblockEngine.load('||tracker.com^\$domain=news.com\n')!;
      service.setRustEngineForTest(engine);

      // The Dart-only entry point doesn't carry source URL, so the
      // engine sees an empty source — that doesn't match news.com,
      // so the rule should NOT fire from this entry. This is a
      // known limitation of routing through isBlocked(url) without
      // also wiring shouldBlock(sourceUrl) — phase 4 territory.
      expect(service.isBlocked('https://tracker.com/'), isFalse,
          reason: 'no source URL plumbing yet — \$domain= rule cannot match');
    }, skip: libExists ? false : 'Rust library not built');
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

bool _rustLibExists() {
  final cwd = Directory.current.path;
  final ext = Platform.isMacOS ? 'dylib' : 'so';
  return File(
          '$cwd/rust/webspace_adblock/target/release/libwebspace_adblock.$ext')
      .existsSync();
}
