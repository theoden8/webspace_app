import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';

DnsLevelSets _sets(Map<int, List<String>> byLevel) {
  final builder = DnsLevelSetsBuilder();
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
  group('DnsLevelSets grouping (DNS-019)', () {
    test('a domain carries a bit for every level that names it', () {
      final sets = _sets({
        1: ['both.example', 'light.example'],
        3: ['both.example', 'pro.example'],
      });
      expect(sets.maskOf('both.example'), dnsLevelBit(1) | dnsLevelBit(3));
      expect(sets.maskOf('light.example'), dnsLevelBit(1));
      expect(sets.maskOf('pro.example'), dnsLevelBit(3));
    });

    test('groups are disjoint, so the entry count is the union', () {
      final sets = _sets({
        1: ['a.example', 'b.example'],
        2: ['a.example', 'b.example', 'c.example'],
      });
      expect(sets.domainCount, 3);
      expect(sets.groupCount, 2, reason: '{1,2} and {2} only');
    });

    test('one downloaded level is one group', () {
      final sets = _sets({
        3: ['a.example', 'b.example'],
      });
      expect(sets.groupCount, 1,
          reason: 'an install with no per-site level pays no extra walks');
    });

    test('a level names exactly what its own list did', () {
      final sets = _sets({
        1: ['light.example'],
        3: ['pro.example'],
      });
      expect(sets.domainsAtLevel(1), ['light.example']);
      expect(sets.domainsAtLevel(3), ['pro.example']);
    });

    test('re-adding a level replaces its membership', () {
      final builder = DnsLevelSetsBuilder()
        ..startLevel(2)
        ..add('gone.example')
        ..add('stays.example')
        ..startLevel(2)
        ..add('stays.example');
      final sets = builder.build();
      expect(sets.maskOf('gone.example'), 0,
          reason: 'a domain the new list dropped must not linger');
      expect(sets.maskOf('stays.example'), dnsLevelBit(2));
    });

    test('dropping a level clears its bit and any domain left with none', () {
      final builder = DnsLevelSetsBuilder.from(_sets({
        1: ['light.example', 'both.example'],
        3: ['both.example'],
      }))
        ..dropLevel(1);
      final sets = builder.build();
      expect(sets.levels, {3});
      expect(sets.maskOf('light.example'), 0);
      expect(sets.maskOf('both.example'), dnsLevelBit(3));
      expect(sets.domainCount, 1);
    });

    test('a level outside 1..5 is rejected', () {
      expect(() => DnsLevelSetsBuilder().startLevel(0), throwsArgumentError);
      expect(() => DnsLevelSetsBuilder().startLevel(6), throwsArgumentError);
    });

    test('adding before a level is started is a programming error', () {
      expect(() => DnsLevelSetsBuilder().add('a.example'), throwsStateError);
    });
  });

  group('DnsLevelSets lookup (DNS-020)', () {
    test('a level blocks only what its own list names', () {
      // The levels do NOT nest: 21,921 of Hagezi's 297,756 domains drop out
      // of a higher level. A "lowest level wins" model would block
      // light.example at Pro as well, which is what this guards.
      final sets = _sets({
        1: ['light.example'],
        3: ['pro.example'],
      });
      expect(sets.blockedAt('light.example', 1), isTrue);
      expect(sets.blockedAt('light.example', 3), isFalse);
      expect(sets.blockedAt('pro.example', 1), isFalse);
      expect(sets.blockedAt('pro.example', 3), isTrue);
    });

    test('level 0 and out-of-range levels block nothing', () {
      final sets = _sets({
        1: ['ads.example'],
      });
      expect(sets.blockedAt('ads.example', 0), isFalse);
      expect(sets.blockedAt('ads.example', 6), isFalse);
    });

    test('subdomains inherit their parent domain mask', () {
      final sets = _sets({
        3: ['ads.example'],
      });
      expect(sets.maskOf('sub.ads.example'), dnsLevelBit(3));
      expect(sets.blockedAt('sub.ads.example', 2), isFalse);
      expect(sets.blockedAt('sub.ads.example', 3), isTrue);
    });

    test('every matching suffix contributes its levels', () {
      final sets = _sets({
        1: ['example.co.uk'],
        3: ['deep.example.co.uk'],
      });
      expect(sets.maskOf('deep.example.co.uk'),
          dnsLevelBit(1) | dnsLevelBit(3));
      expect(sets.blockedAt('deep.example.co.uk', 1), isTrue);
      expect(sets.blockedAt('deep.example.co.uk', 2), isFalse);
      expect(sets.blockedAt('deep.example.co.uk', 3), isTrue);
    });

    test('an unlisted host has an empty mask', () {
      final sets = _sets({
        1: ['ads.example'],
      });
      expect(sets.maskOf('safe.example'), 0);
    });

    test('a bare eTLD is never matched', () {
      final sets = _sets({
        1: ['example.com'],
      });
      expect(sets.maskOf('com'), 0);
    });
  });

  group('the mask reproduces each level exactly', () {
    // The property the whole design rests on: for every level and every host,
    // "the mask says blocked at N" agrees with "level N's own list names it".
    // Built over lists that overlap partially in both directions, which is
    // what the real Hagezi levels do.
    final byLevel = <int, List<String>>{
      1: ['a.example', 'shared.example', 'lightonly.example'],
      2: ['b.example', 'shared.example'],
      3: ['a.example', 'b.example', 'shared.example', 'proonly.example'],
      5: ['shared.example', 'ultimateonly.example'],
    };
    final sets = _sets(byLevel);
    final hosts = <String>{
      for (final domains in byLevel.values) ...domains,
      'unlisted.example',
      'sub.a.example',
    };

    for (final level in byLevel.keys) {
      test('level $level', () {
        final expected = byLevel[level]!.toSet();
        for (final host in hosts) {
          // Subdomain of a listed domain counts as listed, same as the walk.
          final listed = expected.contains(host) ||
              expected.any((d) => host.endsWith('.$d'));
          expect(sets.blockedAt(host, level), listed,
              reason: '$host at level $level');
        }
      });
    }

    test('a level nothing was downloaded for names nothing', () {
      expect(sets.levels, {1, 2, 3, 5});
      for (final host in hosts) {
        expect(sets.blockedAt(host, 4), isFalse);
      }
    });
  });

  group('resolveDnsLevel (DNS-021)', () {
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
      // Its bit means nothing until the list lands, so evaluating at it would
      // block nothing at all — the one direction a relaxation must not go.
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
