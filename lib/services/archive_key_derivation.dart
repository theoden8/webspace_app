import 'dart:typed_data';

import 'archive_crypto.dart';

class ArchiveKeyDerivation {
  ArchiveKeyDerivation._();

  static Future<Uint8List> derive(String passphrase) async {
    final salt = await ArchiveCrypto.deriveSalt(passphrase);
    final key = await ArchiveCrypto.deriveKey(passphrase, salt);
    ArchiveCrypto.zeroize(salt);
    return key;
  }
}
