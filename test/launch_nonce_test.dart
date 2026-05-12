import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/launch_nonce.dart';

void main() {
  group('LaunchNonce', () {
    setUp(LaunchNonce.resetForTesting);
    tearDown(LaunchNonce.resetForTesting);

    test('two reads within a process return the same value', () {
      // Same fingerprint across iframe re-injection / nested webview opens
      // / tab switches within one app session — without this, every read
      // would re-randomize and the user's site would see flicker.
      final first = LaunchNonce.value;
      final second = LaunchNonce.value;
      expect(second, equals(first));
    });

    test('generated value is non-empty lowercase hex', () {
      // Random.secure produces 16 bytes -> 32 hex characters.
      final v = LaunchNonce.value;
      expect(v, isNotEmpty);
      expect(v, matches(RegExp(r'^[0-9a-f]+$')));
      expect(v.length, equals(32));
    });

    test('different process starts produce different nonces (statistical)', () {
      // Simulate two cold launches by reading, resetting, reading again.
      // The collision probability for two 128-bit Random.secure draws is
      // negligible (< 2^-128), so a flake here means the RNG is broken.
      final n1 = LaunchNonce.value;
      LaunchNonce.resetForTesting();
      final n2 = LaunchNonce.value;
      expect(n2, isNot(equals(n1)));
    });

    test('overrideForTesting pins the value', () {
      LaunchNonce.overrideForTesting('fixed-nonce');
      expect(LaunchNonce.value, equals('fixed-nonce'));
      // Stable across reads even when overridden.
      expect(LaunchNonce.value, equals('fixed-nonce'));
    });

    test('resetForTesting clears an override and re-randomizes', () {
      LaunchNonce.overrideForTesting('fixed-nonce');
      expect(LaunchNonce.value, equals('fixed-nonce'));
      LaunchNonce.resetForTesting();
      final regenerated = LaunchNonce.value;
      expect(regenerated, isNot(equals('fixed-nonce')));
      expect(regenerated, matches(RegExp(r'^[0-9a-f]+$')));
    });
  });
}
