import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart' show InvalidCipherTextException;

import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';

const int _nonceLength = 12;
const int _tagLength = 16;

/// AES-256-GCM under a key held in the platform keystore, for the encrypted
/// on-disk caches.
///
/// The key is stored base64-encoded under its own keystore entry and
/// generated on first use. A sealed blob is
/// `base64(nonce(12) || ciphertext || tag(16))` with a fresh random nonce
/// per seal: a key-derived IV would make equal plaintexts encrypt equally
/// and let successive rewrites share a byte-identical prefix. Files already
/// on disk use this format, so it cannot change.
final class KeychainAead {
  KeychainAead._(Uint8List key) : _key = encrypt.Key(key);

  final encrypt.Key _key;
  late final encrypt.Encrypter _gcm =
      encrypt.Encrypter(encrypt.AES(_key, mode: encrypt.AESMode.gcm));

  /// The key stored under [keyName], created on first use; null, after
  /// logging, when the keystore refuses or holds something that is not a
  /// key.
  static Future<KeychainAead?> open(
    FlutterSecureStorage keystore,
    String keyName, {
    required LogTag logTag,
  }) async {
    final stored = await keystoreCall(logTag, 'read $keyName', () async {
      final existing = await keystore.read(key: keyName);
      if (existing != null) return existing;
      final fresh = base64.encode(encrypt.Key.fromSecureRandom(32).bytes);
      await keystore.write(key: keyName, value: fresh);
      logTag.debug('Generated new encryption key');
      return fresh;
    });
    if (stored == null) return null;
    final key = _decodeBase64(stored);
    if (key == null || key.length != 32) {
      logTag.error('$keyName is not a stored key');
      return null;
    }
    return KeychainAead._(key);
  }

  /// Forget the key under [keyName] and [open] a fresh one, so nothing
  /// sealed under the old key reads again.
  static Future<KeychainAead?> rotate(
    FlutterSecureStorage keystore,
    String keyName, {
    required LogTag logTag,
  }) async {
    final deleted = await keystoreCall(logTag, 'delete $keyName', () async {
      await keystore.delete(key: keyName);
      return true;
    });
    if (deleted == null) return null;
    return open(keystore, keyName, logTag: logTag);
  }

  String seal(String plaintext) {
    final nonce = encrypt.IV.fromSecureRandom(_nonceLength);
    final body = _gcm.encrypt(plaintext, iv: nonce).bytes;
    return base64.encode([...nonce.bytes, ...body]);
  }

  /// The plaintext [wire] seals, or null when this key did not seal it:
  /// truncated, tampered, written under another key, or an older format.
  String? unseal(String wire) {
    final bytes = _decodeBase64(wire);
    if (bytes == null || bytes.length < _nonceLength + _tagLength) return null;
    try {
      return _gcm.decrypt(
        encrypt.Encrypted(bytes.sublist(_nonceLength)),
        iv: encrypt.IV(bytes.sublist(0, _nonceLength)),
      );
    } on InvalidCipherTextException {
      return null;
    }
  }

  /// Reads a blob from before GCM: AES-CBC with the key's first 16 bytes as
  /// a fixed IV. Only so such a blob can be resealed; never written.
  String? unsealLegacyCbc(String wire) {
    final bytes = _decodeBase64(wire);
    if (bytes == null || bytes.isEmpty || bytes.length % 16 != 0) return null;
    final cbc = encrypt.Encrypter(encrypt.AES(_key, mode: encrypt.AESMode.cbc));
    try {
      return cbc.decrypt(encrypt.Encrypted(bytes),
          iv: encrypt.IV(_key.bytes.sublist(0, 16)));
    } on ArgumentError {
      // pointycastle's report of a bad PKCS7 pad: not a blob of this key.
      return null;
    } on FormatException {
      return null;
    }
  }

  static Uint8List? _decodeBase64(String wire) {
    try {
      return base64.decode(wire);
    } on FormatException {
      return null;
    }
  }
}
