import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/archive_crypto.dart';

void main() {
  group('ArchiveCrypto.deriveSalt', () {
    test('is deterministic for the same passphrase', () async {
      final a = await ArchiveCrypto.deriveSalt('correct horse battery staple');
      final b = await ArchiveCrypto.deriveSalt('correct horse battery staple');
      expect(a, equals(b));
      expect(a.length, equals(kArchiveSaltLength));
    });

    test('differs for different passphrases', () async {
      final a = await ArchiveCrypto.deriveSalt('alpha');
      final b = await ArchiveCrypto.deriveSalt('beta');
      expect(a, isNot(equals(b)));
    });
  });

  group('ArchiveCrypto.hmac', () {
    test('is deterministic for the same key + label', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final a = await ArchiveCrypto.hmac(key, 'container:abc');
      final b = await ArchiveCrypto.hmac(key, 'container:abc');
      expect(a, equals(b));
      expect(a.length, equals(32));
    });

    test('differs for different labels', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final a = await ArchiveCrypto.hmac(key, 'container:abc');
      final b = await ArchiveCrypto.hmac(key, 'container:xyz');
      expect(a, isNot(equals(b)));
    });

    test('differs for different keys', () async {
      final keyA = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final keyB = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      final a = await ArchiveCrypto.hmac(keyA, 'container:abc');
      final b = await ArchiveCrypto.hmac(keyB, 'container:abc');
      expect(a, isNot(equals(b)));
    });
  });

  group('ArchiveCrypto.seal / open round-trip', () {
    test('round-trips plaintext under matching key', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final plaintext = Uint8List.fromList(utf8.encode('hello world'));
      final wire = await ArchiveCrypto.seal(key, plaintext);
      final out = await ArchiveCrypto.open(key, wire);
      expect(out, equals(plaintext));
    });

    test('wire format begins with nonce, ends with mac, contains ciphertext', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final plaintext = Uint8List.fromList(utf8.encode('x'));
      final wire = await ArchiveCrypto.seal(key, plaintext);
      expect(wire.length, equals(kArchiveNonceLength + 1 + kArchiveMacLength));
    });

    test('returns null with wrong key', () async {
      final keyA = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final keyB = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      final wire = await ArchiveCrypto.seal(keyA, Uint8List.fromList(utf8.encode('hi')));
      final out = await ArchiveCrypto.open(keyB, wire);
      expect(out, isNull);
    });

    test('returns null with tampered ciphertext', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wire = await ArchiveCrypto.seal(key, Uint8List.fromList(utf8.encode('hi')));
      wire[kArchiveNonceLength] ^= 0x01;
      final out = await ArchiveCrypto.open(key, wire);
      expect(out, isNull);
    });

    test('returns null with tampered nonce', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wire = await ArchiveCrypto.seal(key, Uint8List.fromList(utf8.encode('hi')));
      wire[0] ^= 0x01;
      final out = await ArchiveCrypto.open(key, wire);
      expect(out, isNull);
    });

    test('returns null with tampered mac', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final wire = await ArchiveCrypto.seal(key, Uint8List.fromList(utf8.encode('hi')));
      wire[wire.length - 1] ^= 0x01;
      final out = await ArchiveCrypto.open(key, wire);
      expect(out, isNull);
    });

    test('returns null with mismatched aad', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final aadA = Uint8List.fromList([1, 2, 3, 4]);
      final aadB = Uint8List.fromList([5, 6, 7, 8]);
      final wire = await ArchiveCrypto.seal(
        key,
        Uint8List.fromList(utf8.encode('hi')),
        aad: aadA,
      );
      final out = await ArchiveCrypto.open(key, wire, aad: aadB);
      expect(out, isNull);
    });

    test('returns null on too-short wire', () async {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final out = await ArchiveCrypto.open(key, Uint8List(8));
      expect(out, isNull);
    });
  });

  group('ArchiveCrypto.zeroize', () {
    test('overwrites all bytes with zero', () {
      final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
      ArchiveCrypto.zeroize(key);
      for (final b in key) {
        expect(b, equals(0));
      }
    });
  });
}
