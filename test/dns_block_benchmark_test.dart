import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/dns_block_service.dart';

/// Generate a synthetic domain list simulating Ultimate-scale (522K domains).
String _generateSyntheticDomainList(int count) {
  final random = Random(42); // Fixed seed for reproducibility
  final buffer = StringBuffer();
  final tlds = ['com', 'net', 'org', 'io', 'co', 'info', 'biz', 'xyz'];

  buffer.writeln('# Synthetic blocklist for benchmarking');
  buffer.writeln('# $count domains');
  buffer.writeln();

  for (int i = 0; i < count; i++) {
    final tld = tlds[random.nextInt(tlds.length)];
    final nameLen = 4 + random.nextInt(12);
    final name = String.fromCharCodes(
      List.generate(nameLen, (_) => 97 + random.nextInt(26)),
    );
    // Mix in some subdomains (~20% of entries)
    if (random.nextInt(5) == 0) {
      final subLen = 3 + random.nextInt(6);
      final sub = String.fromCharCodes(
        List.generate(subLen, (_) => 97 + random.nextInt(26)),
      );
      buffer.writeln('$sub.$name.$tld');
    } else {
      buffer.writeln('$name.$tld');
    }
  }

  return buffer.toString();
}

void main() {
  group('DnsBlockService Benchmark', () {
    test('parse 522K domains in under 5 seconds', () {
      final data = _generateSyntheticDomainList(522000);
      final service = DnsBlockService.instance;

      final stopwatch = Stopwatch()..start();
      service.loadDomainsFromString(data);
      stopwatch.stop();

      final parseMs = stopwatch.elapsedMilliseconds;
      // ignore: avoid_print
      print('Parse time: ${parseMs}ms for ${service.domainCount} domains');

      expect(service.domainCount, greaterThan(500000));
      expect(parseMs, lessThan(5000), reason: 'Parse time should be under 5 seconds');
    });

    test('lookup time under 1ms per call (1000 lookups)', () {
      final data = _generateSyntheticDomainList(522000);
      final service = DnsBlockService.instance;
      service.loadDomainsFromString(data);

      final random = Random(99);
      // Generate test URLs - mix of hits and misses
      final testUrls = <String>[];
      for (int i = 0; i < 500; i++) {
        // Likely misses
        final name = String.fromCharCodes(
          List.generate(8, (_) => 97 + random.nextInt(26)),
        );
        testUrls.add('https://$name.example.com/path?q=test');
      }
      for (int i = 0; i < 500; i++) {
        // Likely hits (known blocked patterns)
        testUrls.add('https://tracker${random.nextInt(1000)}.com/pixel');
      }

      final stopwatch = Stopwatch()..start();
      for (final url in testUrls) {
        service.isBlocked(url);
      }
      stopwatch.stop();

      final totalUs = stopwatch.elapsedMicroseconds;
      final perCallUs = totalUs / testUrls.length;
      // ignore: avoid_print
      print('Lookup time: ${perCallUs.toStringAsFixed(1)}us per call '
          '(${totalUs}us total for ${testUrls.length} lookups)');

      // 1ms = 1000us per call
      expect(perCallUs, lessThan(1000),
          reason: 'Lookup time should be under 1ms per call');
    });

    // What the per-site level mask is allowed to cost. The structural claims
    // are asserted; the timings are printed, because a ratio gate on shared
    // CI hardware measures the runner, not the code.
    test('the level mask costs nothing until a second level is downloaded',
        () {
      final service = DnsBlockService.instance;
      final levelThree = _generateSyntheticDomainList(200000);
      // Overlapping but NOT nested, the way the real Hagezi levels are.
      final levelOne = [
        ...const LineSplitter()
            .convert(levelThree)
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .take(30000),
        for (var i = 0; i < 5000; i++) 'lightonly$i.example',
      ].join('\n');

      service.loadLevelsFromStrings({3: levelThree}, globalLevel: 3);
      final oneLevelCount = service.domainCount;
      expect(service.levelGroupCount, 1,
          reason: 'one downloaded level is one group, so one suffix walk');

      final probes = [
        for (var i = 0; i < 20000; i++) 'https://miss$i.notblocked$i.example/'
      ];
      double timeLookups() {
        final sw = Stopwatch()..start();
        for (final url in probes) {
          service.isBlocked(url);
        }
        sw.stop();
        return sw.elapsedMicroseconds / probes.length;
      }

      final oneLevelUs = timeLookups();

      service.loadLevelsFromStrings(
          {1: levelOne, 3: levelThree}, globalLevel: 3);
      final twoLevelUs = timeLookups();

      // The union, not the sum: a domain both levels name is stored once.
      expect(service.domainCount, oneLevelCount + 5000,
          reason: 'only the 5000 level-1-only domains are new');
      expect(service.levelGroupCount, 3,
          reason: '{1}, {3} and {1,3}');

      // ignore: avoid_print
      print('Level mask lookup: 1 level ${oneLevelUs.toStringAsFixed(2)}us, '
          '2 levels ${twoLevelUs.toStringAsFixed(2)}us '
          '(${service.domainCount} domains, '
          '${service.levelGroupCount} groups)');

      expect(twoLevelUs, lessThan(1000),
          reason: 'still well under the per-call ceiling');
    });
  });
}
