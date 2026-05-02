import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/host_lookup.dart';

void main() {
  group('extractHost', () {
    test('extracts host from https URL with path', () {
      expect(extractHost('https://example.com/path'), equals('example.com'));
    });

    test('extracts host from URL with no path', () {
      expect(extractHost('https://example.com'), equals('example.com'));
      expect(extractHost('https://example.com?q=1'), equals('example.com'));
      expect(extractHost('https://example.com#frag'), equals('example.com'));
    });

    test('strips port', () {
      expect(extractHost('https://example.com:443'), equals('example.com'));
      expect(extractHost('https://example.com:8080/path'), equals('example.com'));
    });

    test('strips userinfo', () {
      expect(extractHost('https://user:pass@example.com/'), equals('example.com'));
      expect(extractHost('https://user@example.com:8080/'), equals('example.com'));
      expect(extractHost('https://a:b@c:d@example.com/'), equals('example.com'),
          reason: 'last @ delimits userinfo');
    });

    test('handles IPv6 literals', () {
      expect(extractHost('https://[2001:db8::1]/'), equals('[2001:db8::1]'));
      expect(extractHost('https://[2001:db8::1]:443/'), equals('[2001:db8::1]'));
      expect(extractHost('https://[::1]/'), equals('[::1]'));
    });

    test('returns null for unterminated IPv6 literal', () {
      expect(extractHost('https://[2001:db8/path'), isNull);
    });

    test('lowercases uppercase hosts', () {
      expect(extractHost('https://Example.COM/'), equals('example.com'));
      expect(extractHost('HTTPS://EXAMPLE.COM/'), equals('example.com'));
    });

    test('returns same string when host is already lowercase', () {
      // Identity isn't guaranteed by the API, but the no-uppercase fast
      // path is the realistic case worth covering: the result is an
      // unmodified substring of the input.
      const url = 'https://example.com/path';
      expect(extractHost(url), equals('example.com'));
    });

    test('returns null for non-scheme URLs', () {
      expect(extractHost('about:blank'), isNull);
      expect(extractHost('data:text/html,<p>hi</p>'), isNull);
      expect(extractHost('javascript:void(0)'), isNull);
      expect(extractHost('relative/path'), isNull);
      expect(extractHost(''), isNull);
    });

    test('handles file:// (scheme present, empty host)', () {
      expect(extractHost('file:///etc/hosts'), equals(''));
    });

    test('IPv6 in URL with port and path', () {
      expect(extractHost('https://[2001:db8::1]:8443/foo?q=1#frag'),
          equals('[2001:db8::1]'));
    });
  });

  group('hostInSet', () {
    test('exact match', () {
      expect(hostInSet('tracker.net', {'tracker.net'}), isTrue);
    });

    test('subdomain match via parent walk', () {
      final set = {'tracker.net'};
      expect(hostInSet('sub.tracker.net', set), isTrue);
      expect(hostInSet('a.b.c.tracker.net', set), isTrue);
    });

    test('does not match unrelated domain that ends in same string', () {
      // mytracker.net should NOT be matched by tracker.net
      expect(hostInSet('mytracker.net', {'tracker.net'}), isFalse);
    });

    test('never matches a single-label string (eTLD safety)', () {
      // Even if someone mistakenly added "com" to the set, walking up
      // foo.example.com must not return true on the bare "com" suffix.
      expect(hostInSet('foo.example.com', {'com'}), isFalse,
          reason: 'eTLD-only entries must never block everything');
    });

    test('returns false on empty set', () {
      expect(hostInSet('anything.com', <String>{}), isFalse);
    });

    test('hierarchy walk hits intermediate ancestor', () {
      final set = {'ads.example.com'};
      expect(hostInSet('ads.example.com', set), isTrue);
      expect(hostInSet('foo.ads.example.com', set), isTrue);
      expect(hostInSet('example.com', set), isFalse);
      expect(hostInSet('other.example.com', set), isFalse);
    });

    test('exact-match-on-eTLD parent does not match', () {
      // The implementation specifically does NOT check the bare eTLD,
      // even when reached via walk-up. Document that.
      expect(hostInSet('example.com', {'com'}), isFalse);
    });
  });

  group('HostFifoCache', () {
    test('stores and retrieves entries', () {
      final c = HostFifoCache(4);
      c.put('a', true);
      c.put('b', false);
      expect(c['a'], isTrue);
      expect(c['b'], isFalse);
      expect(c['unknown'], isNull);
    });

    test('FIFO evicts oldest when full', () {
      final c = HostFifoCache(3);
      c.put('a', true);
      c.put('b', true);
      c.put('c', true);
      c.put('d', true); // evicts 'a'
      expect(c['a'], isNull);
      expect(c['b'], isTrue);
      expect(c['c'], isTrue);
      expect(c['d'], isTrue);
    });

    test('updates in place do not change FIFO order', () {
      final c = HostFifoCache(3);
      c.put('a', true);
      c.put('b', true);
      c.put('c', true);
      c.put('a', false); // update; 'a' must still be the oldest
      c.put('d', true); // evicts 'a' (still oldest)
      expect(c['a'], isNull);
      expect(c['b'], isTrue);
      expect(c['c'], isTrue);
      expect(c['d'], isTrue);
    });

    test('clear empties the cache', () {
      final c = HostFifoCache(3);
      c.put('a', true);
      c.put('b', true);
      c.clear();
      expect(c.length, equals(0));
      expect(c['a'], isNull);
      // Reuse after clear works.
      c.put('x', true);
      expect(c['x'], isTrue);
    });

    test('length tracks size up to cap', () {
      final c = HostFifoCache(3);
      expect(c.length, equals(0));
      c.put('a', true);
      c.put('b', true);
      expect(c.length, equals(2));
      c.put('c', true);
      c.put('d', true); // evicts 'a'
      expect(c.length, equals(3));
    });

    test('hammering many distinct keys stays bounded and fast', () {
      // The DNS hot path benchmark also covers this, but exercise the
      // cache directly here so a regression in the FIFO path surfaces
      // without needing a 522K-domain build.
      final c = HostFifoCache(100);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 50000; i++) {
        c.put('host$i', i.isEven);
      }
      sw.stop();
      expect(c.length, equals(100));
      expect(sw.elapsedMilliseconds, lessThan(2000));
    });
  });
}
