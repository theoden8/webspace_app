import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:webspace/services/keystore.dart';
import 'package:webspace/services/log_service.dart';

const int _nonceLength = 12;
const int _tagLength = 16;

/// From this many characters a seal or an open runs on a background
/// isolate: a page snapshot is over a megabyte, and on iOS the UI isolate
/// shares the main thread with every WKWebView callback.
const int _offIsolateFrom = 64 * 1024;

final DartAesGcm _gcm = DartAesGcm.with256bits(nonceLength: _nonceLength);

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
  KeychainAead._(this._key);

  final Uint8List _key;

  /// The key stored under [keyName], created on first use; null, after
  /// logging, when the keystore refuses or holds something that is not a
  /// key.
  static Future<KeychainAead?> open(
    FlutterSecureStorage keystore, {
    required String keyName,
    required LogTag logTag,
  }) async {
    final stored =
        await keystoreCall(logTag, what: 'read $keyName', call: () async {
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
    FlutterSecureStorage keystore, {
    required String keyName,
    required LogTag logTag,
  }) async {
    final deleted =
        await keystoreCall(logTag, what: 'delete $keyName', call: () async {
      await keystore.delete(key: keyName);
      return true;
    });
    if (deleted == null) return null;
    return open(keystore, keyName: keyName, logTag: logTag);
  }

  Future<String> seal(String plaintext) {
    final job = (key: _key, text: plaintext);
    return plaintext.length < _offIsolateFrom
        ? Future.value(_seal(job))
        : compute(_seal, job);
  }

  /// The plaintext [wire] seals, or null when this key did not seal it:
  /// truncated, tampered, written under another key, or an older format.
  Future<String?> unseal(String wire) {
    final job = (key: _key, text: wire);
    return wire.length < _offIsolateFrom
        ? Future.value(_unseal(job))
        : compute(_unseal, job);
  }

  /// Reads a blob from before GCM: AES-CBC with the key's first 16 bytes as
  /// a fixed IV. Only so such a blob can be resealed; never written.
  String? unsealLegacyCbc(String wire) {
    final bytes = _decodeBase64(wire);
    if (bytes == null || bytes.isEmpty || bytes.length % 16 != 0) return null;
    final cbc = encrypt.Encrypter(
        encrypt.AES(encrypt.Key(_key), mode: encrypt.AESMode.cbc));
    try {
      return cbc.decrypt(encrypt.Encrypted(bytes),
          iv: encrypt.IV(_key.sublist(0, 16)));
    } on ArgumentError {
      // pointycastle's report of a bad PKCS7 pad: not a blob of this key.
      return null;
    } on FormatException {
      return null;
    }
  }

}

typedef _Job = ({Uint8List key, String text});

String _seal(_Job job) {
  final box = _gcm.encryptSync(utf8.encode(job.text),
      secretKeyData: SecretKeyData(job.key));
  final cipher = box.cipherText;
  return base64.encode(Uint8List(_nonceLength + cipher.length + _tagLength)
    ..setAll(0, box.nonce)
    ..setAll(_nonceLength, cipher)
    ..setAll(_nonceLength + cipher.length, box.mac.bytes));
}

String? _unseal(_Job job) {
  final bytes = _decodeBase64(job.text);
  if (bytes == null || bytes.length < _nonceLength + _tagLength) return null;
  final box = SecretBox(
    Uint8List.sublistView(bytes, _nonceLength, bytes.length - _tagLength),
    nonce: Uint8List.sublistView(bytes, 0, _nonceLength),
    mac: Mac(Uint8List.sublistView(bytes, bytes.length - _tagLength)),
  );
  try {
    return utf8.decode(_gcm.decryptSync(box, secretKeyData: SecretKeyData(job.key)),
        allowMalformed: true);
  } on SecretBoxAuthenticationError {
    return null;
  }
}

Uint8List? _decodeBase64(String wire) {
  try {
    return base64.decode(wire);
  } on FormatException {
    return null;
  }
}
