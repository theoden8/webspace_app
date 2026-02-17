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
  });
}
