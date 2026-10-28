import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/bounded_inflate.dart';

void main() {
  group('inflateBounded', () {
    test('output within the limit is returned whole', () {
      final plain = Uint8List.fromList(List.generate(100000, (i) => i % 251));
      expect(
        inflateBounded(
          gzip.decoder,
          compressed: gzip.encode(plain),
          limit: plain.length,
        ),
        plain,
      );
    });

    test('output past the limit is null, and stops where it crosses', () {
      final bomb = ZLibEncoder(raw: true).convert(Uint8List(64 << 20));
      final watch = Stopwatch()..start();
      expect(
        inflateBounded(
          ZLibDecoder(raw: true),
          compressed: bomb,
          limit: 1 << 20,
        ),
        isNull,
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });

    test("a malformed stream reaches the caller as the codec's failure", () {
      expect(
        () => inflateBounded(
          gzip.decoder,
          compressed: List.generate(64, (i) => i * 7),
          limit: 1 << 20,
        ),
        throwsFormatException,
      );
    });
  });

  group('inflatePrefix', () {
    final plain = Uint8List.fromList(List.generate(200000, (i) => i % 251));
    final gz = gzip.encode(plain);

    test('a cut stream gives what its start decodes to, without an error', () {
      final out = inflatePrefix(gzip.decoder,
          compressed: gz.sublist(0, gz.length ~/ 2), limit: plain.length);
      expect(out, isNotEmpty);
      expect(out, plain.sublist(0, out.length));
    });

    test('stops at the limit', () {
      expect(inflatePrefix(gzip.decoder, compressed: gz, limit: 1000),
          plain.sublist(0, 1000));
    });

    test('a whole stream within the limit comes back whole', () {
      expect(inflatePrefix(gzip.decoder, compressed: gz, limit: 1 << 20),
          plain);
    });
  });
}
