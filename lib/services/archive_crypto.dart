import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const int kArchiveSaltLength = 16;
const int kArchiveKeyLength = 32;
const int kArchiveNonceLength = 12;
const int kArchiveMacLength = 16;

// Argon2id cost parameters (ARCH-002). These are the sole barrier to an
// offline dictionary attack on the archive passphrase (the salt is derived
// from the passphrase, so it adds no anti-precomputation entropy). Pinned by
// test/archive_crypto_test.dart so a silent downgrade fails CI.
const int kArchiveArgon2Parallelism = 4;
const int kArchiveArgon2MemoryKiB = 64 * 1024; // 64 MiB
const int kArchiveArgon2Iterations = 3;

const String _saltDomain = 'archive-salt-v1';

final Argon2id _argon2id = Argon2id(
  parallelism: kArchiveArgon2Parallelism,
  memory: kArchiveArgon2MemoryKiB,
  iterations: kArchiveArgon2Iterations,
  hashLength: kArchiveKeyLength,
);

final Hkdf _saltHkdf = Hkdf(
  hmac: Hmac.sha256(),
  outputLength: kArchiveSaltLength,
);

final Hmac _hmacSha256 = Hmac.sha256();

final AesGcm _aesGcm = AesGcm.with256bits(nonceLength: kArchiveNonceLength);

class ArchiveCrypto {
  ArchiveCrypto._();

  static Future<Uint8List> deriveSalt(String passphrase) async {
    final pwBytes = utf8.encode(passphrase);
    final result = await _saltHkdf.deriveKey(
      secretKey: SecretKey(pwBytes),
      info: utf8.encode(_saltDomain),
    );
    final bytes = await result.extractBytes();
    return Uint8List.fromList(bytes);
  }

  static Future<Uint8List> deriveKey(String passphrase, Uint8List salt) async {
    final pwBytes = utf8.encode(passphrase);
    final result = await _argon2id.deriveKey(
      secretKey: SecretKey(pwBytes),
      nonce: salt,
    );
    final bytes = await result.extractBytes();
    return Uint8List.fromList(bytes);
  }

  static Future<Uint8List> hmac(Uint8List key, String info) async {
    final mac = await _hmacSha256.calculateMac(
      utf8.encode(info),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(mac.bytes);
  }

  static Future<Uint8List> seal(
    Uint8List key,
    Uint8List plaintext, {
    Uint8List? aad,
  }) async {
    final box = await _aesGcm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      aad: aad ?? const <int>[],
    );
    final wire = Uint8List(
      box.nonce.length + box.cipherText.length + box.mac.bytes.length,
    );
    var offset = 0;
    wire.setRange(offset, offset + box.nonce.length, box.nonce);
    offset += box.nonce.length;
    wire.setRange(offset, offset + box.cipherText.length, box.cipherText);
    offset += box.cipherText.length;
    wire.setRange(offset, offset + box.mac.bytes.length, box.mac.bytes);
    return wire;
  }

  static Future<Uint8List?> open(
    Uint8List key,
    Uint8List wire, {
    Uint8List? aad,
  }) async {
    if (wire.length < kArchiveNonceLength + kArchiveMacLength) {
      return null;
    }
    final nonce = wire.sublist(0, kArchiveNonceLength);
    final cipherText =
        wire.sublist(kArchiveNonceLength, wire.length - kArchiveMacLength);
    final mac = Mac(wire.sublist(wire.length - kArchiveMacLength));
    final box = SecretBox(cipherText, nonce: nonce, mac: mac);
    try {
      final plaintext = await _aesGcm.decrypt(
        box,
        secretKey: SecretKey(key),
        aad: aad ?? const <int>[],
      );
      return Uint8List.fromList(plaintext);
    } on SecretBoxAuthenticationError {
      return null;
    }
  }

  static void zeroize(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  }
}
