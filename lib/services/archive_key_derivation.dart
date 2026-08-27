import 'dart:typed_data';

import 'archive_crypto.dart';

class ArchiveKeyDerivation {
  ArchiveKeyDerivation._();

  /// Argon2id over [passphrase] with the caller's [salt] (ARCH-002). The salt
  /// is the per-install random one from `ArchiveStorage.ensureKdfSalt`, so the
  /// Argon2id work an attacker must spend is per-device, not amortizable
  /// across every install of the app.
  static Future<Uint8List> derive(String passphrase, Uint8List salt) {
    return ArchiveCrypto.deriveKey(passphrase, salt);
  }

  /// Pre-per-install-salt derivation, where the salt was `HKDF(passphrase)`
  /// and therefore added no entropy. Kept only to open slots sealed before the
  /// stored salt existed; those are re-sealed under [derive] on first open.
  static Future<Uint8List> deriveLegacy(String passphrase) async {
    final salt = await ArchiveCrypto.deriveSalt(passphrase);
    final key = await ArchiveCrypto.deriveKey(passphrase, salt);
    ArchiveCrypto.zeroize(salt);
    return key;
  }
}
