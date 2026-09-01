import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/dns_tier_engine.dart';

DnsTiers _tiers(Map<int, List<String>> byLevel) {
  final builder = DnsTiersBuilder();
  final levels = byLevel.keys.toList()..sort();
  for (final level in levels) {
    builder.startLevel(level);
    for (final domain in byLevel[level]!) {
      builder.add(domain);
    }
  }
  return builder.build();
}

void main() {
  group('DnsTiers partition (DNS-019)', () {
    test('a domain lands in the lowest level that names it', () {
      final tiers = _tiers({
        1: ['light.example'],
        3: ['light.example', 'pro.example'],
      });
      expect(tiers.tierOf('light.example'), 1);
      expect(tiers.tierOf('pro.example'), 3);
    });

    test('tiers are disjoint, so the entry count is the largest list', () {
      final tiers = _tiers({
        1: ['a.example', 'b.example'],
        2: ['a.example', 'b.example', 'c.example'],
      });
      expect(tiers.domainCount, 3);
      expect(tiers.tierDomains(1), {'a.example', 'b.example'});
      expect(tiers.tierDomains(2), {'c.example'});
    });

    test('a level with no list has no tier and no boundary', () {
      final tiers = _tiers({
        2: ['a.example'],
      });
      expect(tiers.levels, {2});
      expect(tiers.tierDomains(1), isEmpty);
    });

    test('levels must be added in ascending order', () {
      final builder = DnsTiersBuilder()..startLevel(3);
      expect(() => builder.startLevel(2), throwsStateError);
    });

    test('adding before a level is started is a programming error', () {
      expect(() => DnsTiersBuilder().add('a.example'), throwsStateError);
    });

    test('a level outside 1..5 is rejected', () {
      expect(() => DnsTiersBuilder().startLevel(0), throwsArgumentError);
      expect(() => DnsTiersBuilder().startLevel(6), throwsArgumentError);
    });
  });

  group('DnsTiers lookup (DNS-020)', () {
    final tiers = _tiers({
      1: ['light.example'],
      3: ['light.example', 'ads.pro.example'],
      5: ['light.example', 'ads.pro.example', 'ultimate.example'],
    });

    test('a site blocks its own tier and every tier below it', () {
      expect(tiers.blockedAt('light.example', 1), isTrue);
      expect(tiers.blockedAt('ads.pro.example', 1), isFalse);
      expect(tiers.blockedAt('ads.pro.example', 3), isTrue);
      expect(tiers.blockedAt('ultimate.example', 3), isFalse);
      expect(tiers.blockedAt('ultimate.example', 5), isTrue);
    });

    test('level 0 blocks nothing', () {
      expect(tiers.blockedAt('light.example', 0), isFalse);
    });

    test('subdomains inherit their parent domain tier', () {
      expect(tiers.tierOf('sub.ads.pro.example'), 3);
      expect(tiers.blockedAt('sub.ads.pro.example', 2), isFalse);
      expect(tiers.blockedAt('sub.ads.pro.example', 3), isTrue);
    });

    test('the lowest matching suffix wins, not the most specific', () {
      // `deep.example` enters at 4, its parent `example.co.uk` at 2: a site
      // at level 2 already blocks the parent, so the child blocks too.
      final nested = _tiers({
        2: ['example.co.uk'],
        4: ['deep.example.co.uk'],
      });
      expect(nested.tierOf('deep.example.co.uk'), 2);
      expect(nested.blockedAt('deep.example.co.uk', 2), isTrue);
    });

    test('an unlisted host has no tier', () {
      expect(tiers.tierOf('safe.example'), 0);
      expect(tiers.blockedAt('safe.example', 5), isFalse);
    });

    test('a bare eTLD is never matched', () {
      final tld = _tiers({
        1: ['example.com'],
      });
      expect(tld.tierOf('com'), 0);
    });
  });

  group('resolveDnsLevel (DNS-020)', () {
    test('no per-site level follows the app-wide one', () {
      expect(
          resolveDnsLevel(
              siteLevel: null, globalLevel: 3, downloadedLevels: {3}),
          3);
    });

    test('off needs no downloaded list', () {
      expect(
          resolveDnsLevel(
              siteLevel: 0, globalLevel: 3, downloadedLevels: {3}),
          0);
    });

    test('a downloaded level is used as asked', () {
      expect(
          resolveDnsLevel(
              siteLevel: 1, globalLevel: 3, downloadedLevels: {1, 3}),
          1);
    });

    test('an undownloaded level falls back to the app-wide level', () {
      // Evaluating at level 1 with only the level-3 list loaded would block
      // nothing at all, which is the one direction a relaxation must not go.
      expect(
          resolveDnsLevel(
              siteLevel: 1, globalLevel: 3, downloadedLevels: {3}),
          3);
    });

    test('an out-of-range level falls back', () {
      expect(
          resolveDnsLevel(
              siteLevel: 9, globalLevel: 2, downloadedLevels: {2}),
          2);
    });
  });

  group('dnsLevelNeedsDownload', () {
    test('true only for a real level with no list', () {
      expect(
          dnsLevelNeedsDownload(siteLevel: 1, downloadedLevels: {3}), isTrue);
      expect(
          dnsLevelNeedsDownload(siteLevel: 3, downloadedLevels: {3}), isFalse);
      expect(
          dnsLevelNeedsDownload(siteLevel: null, downloadedLevels: {3}),
          isFalse);
      expect(
          dnsLevelNeedsDownload(siteLevel: 0, downloadedLevels: {}), isFalse);
    });
  });

  group('requiredDnsLevels', () {
    test('keeps the app-wide level and every level a site asks for', () {
      expect(
          requiredDnsLevels(globalLevel: 3, siteLevels: [1, null, 3, 1]),
          {1, 3});
    });

    test('drops level 0 and out-of-range levels', () {
      expect(requiredDnsLevels(globalLevel: 2, siteLevels: [0, 7]), {2});
    });

    test('nothing is required when the app-wide level is off', () {
      expect(requiredDnsLevels(globalLevel: 0, siteLevels: [null]), isEmpty);
    });
  });
}
