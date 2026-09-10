import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/anti_fingerprinting_shim.dart';

void main() {
  group('the page never sees the record behind the seed (SEC-006)', () {
    String source({String siteId = 'site-A', String nonce = 'nonce-1'}) =>
        buildAntiFingerprintingScriptSource(
          siteId: siteId,
          trackingProtectionEnabled: true,
          incognito: true,
          launchNonce: nonce,
          resetNonce: 'reset-xyz',
        )!;

    test('siteId, reset nonce and launch nonce are absent from the shim', () {
      final js = source();
      expect(js, isNot(contains('site-A')));
      expect(js, isNot(contains('reset-xyz')));
      expect(js, isNot(contains('nonce-1')));
      expect(js, contains('var SEED = "'));
    });

    test('the seed is a digest, not an encoding of the input', () {
      final seed = opaqueAntiFingerprintingSeed('site-A:reset-xyz:nonce-1');
      expect(seed, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(opaqueAntiFingerprintingSeed('a'),
          isNot(equals(opaqueAntiFingerprintingSeed('b'))));
    });

    test('the same input still yields the same shim', () {
      expect(source(), equals(source()));
    });

    test('a reroll still rerolls', () {
      expect(source(nonce: 'nonce-1'), isNot(equals(source(nonce: 'nonce-2'))));
    });

    test('two incognito sites in one launch share no seed material', () {
      final a = RegExp(r'var SEED = "([0-9a-f]+)"').firstMatch(source(siteId: 'site-A'))!.group(1)!;
      final b = RegExp(r'var SEED = "([0-9a-f]+)"').firstMatch(source(siteId: 'site-B'))!.group(1)!;
      expect(a, isNot(equals(b)));
      expect(a.substring(0, 8), isNot(equals(b.substring(0, 8))));
    });
  });
}
