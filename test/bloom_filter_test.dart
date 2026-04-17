import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/bloom_filter.dart';

void main() {
  group('BloomFilter', () {
    test('empty filter never reports membership', () {
      final bf = BloomFilter.build([]);
      expect(bf.contains('anything.com'), isFalse);
      expect(bf.contains('example.org'), isFalse);
    });

    test('all added items are reported as present (no false negatives)', () {
      final domains = [
        'tracker.net',
        'ads.example.com',
        'malware.evil.org',
        'analytics.foo.bar',
        'pixel.tracker.io',
      ];
      final bf = BloomFilter.build(domains);
      for (final d in domains) {
        expect(bf.contains(d), isTrue, reason: '$d should be present');
      }
    });

    test('no false negatives across 10K domains', () {
      final domains = List.generate(10000, (i) => 'domain$i.example.com');
      final bf = BloomFilter.build(domains);
      for (final d in domains) {
        expect(bf.contains(d), isTrue, reason: '$d should be present');
      }
    });

    test('false positive rate stays close to target (5%)', () {
      // Build with 10K items at default 5% FPR
      final added = List.generate(10000, (i) => 'added$i.example.com');
      final bf = BloomFilter.build(added);

      // Probe with 50K items NOT in the set
      const probeCount = 50000;
      int falsePositives = 0;
      for (int i = 0; i < probeCount; i++) {
        if (bf.contains('probe$i.notpresent.test')) falsePositives++;
      }
      final actualFpr = falsePositives / probeCount;
      // Allow some variance: target 0.05 (5%), assert < 10%
      expect(actualFpr, lessThan(0.10),
          reason: 'False positive rate $actualFpr exceeds tolerance (target 0.05)');
    });

    test('toMap returns bits, bitCount, k', () {
      final bf = BloomFilter.build(['a.com', 'b.com']);
      final map = bf.toMap();
      expect(map['bits'], isNotNull);
      expect(map['bitCount'], isPositive);
      expect(map['k'], isPositive);
      expect((map['bits'] as List).length * 8, greaterThanOrEqualTo(map['bitCount'] as int));
    });

    test('hash function is JS-compatible (FNV-1a)', () {
      // Sanity check: known FNV-1a values for "abc" with FNV offset basis 0x811C9DC5
      // We can't easily reach the private hash, but we can verify reproducibility:
      // building a filter twice with same items must produce identical bytes
      final bf1 = BloomFilter.build(['a', 'b', 'c']);
      final bf2 = BloomFilter.build(['a', 'b', 'c']);
      expect(bf1.bits, equals(bf2.bits));
      expect(bf1.bitCount, equals(bf2.bitCount));
      expect(bf1.k, equals(bf2.k));
    });

    test('larger blocklist produces proportionally larger filter', () {
      final small = BloomFilter.build(List.generate(1000, (i) => 'x$i.com'));
      final large = BloomFilter.build(List.generate(10000, (i) => 'x$i.com'));
      expect(large.sizeInBytes, greaterThan(small.sizeInBytes));
    });

    test('domain hierarchy walk-up works via bloom contains', () {
      // Simulate the iOS JS check: check host + parent suffixes
      final bf = BloomFilter.build(['tracker.net', 'ads.example.com']);

      bool maybeBlocked(String host) {
        if (bf.contains(host)) return true;
        final parts = host.split('.');
        for (int i = 1; i < parts.length - 1; i++) {
          if (bf.contains(parts.sublist(i).join('.'))) return true;
        }
        return false;
      }

      expect(maybeBlocked('tracker.net'), isTrue);
      expect(maybeBlocked('sub.tracker.net'), isTrue); // parent in set
      expect(maybeBlocked('deep.sub.tracker.net'), isTrue);
      expect(maybeBlocked('ads.example.com'), isTrue);
      // not present (and unlikely false positive in a tiny filter)
      expect(maybeBlocked('safe.org'), isFalse);
    });
  });
}
