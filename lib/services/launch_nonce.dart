import 'dart:math';

/// Process-lifetime random nonce used to randomize the anti-fingerprinting
/// PRNG seed for `incognito` sites across launches (issue #327, ETP-019).
///
/// Generated lazily on first access via `Random.secure` and cached for the
/// rest of the process. Cold restart → fresh nonce → fresh fingerprint.
/// App resume from background is NOT a launch and reuses the same nonce.
class LaunchNonce {
  static String? _value;

  static String get value => _value ??= _generate();

  static String _generate() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static void overrideForTesting(String value) {
    _value = value;
  }

  static void resetForTesting() {
    _value = null;
  }
}
