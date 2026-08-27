import 'dart:convert' show base64Url;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/archive_crypto.dart' show kArchiveSaltLength;
import 'package:webspace/services/archive_storage.dart';

import 'helpers/mock_secure_storage.dart';

void main() {
  group('ArchiveStorage.ensureInitialized', () {
    test('writes K slots of S bytes each on fresh storage', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      // The K slots plus the one ARCH-002 salt entry.
      expect(secureStorage.storage.length, equals(kArchiveSlotCount + 1));
      for (var i = 0; i < kArchiveSlotCount; i++) {
        final padded = i.toString().padLeft(2, '0');
        final key = 'archive_slot_$padded';
        expect(secureStorage.storage.containsKey(key), isTrue);
      }
      for (var i = 0; i < kArchiveSlotCount; i++) {
        final slot = await storage.readSlot(i);
        expect(slot.length, equals(kArchiveSlotSize));
      }
    });

    test('does not overwrite existing slots on subsequent calls', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      final firstRead = await storage.readSlot(3);
      // Fresh instance pointed at the same backing storage.
      final reopened = ArchiveStorage(secureStorage: secureStorage);
      await reopened.ensureInitialized();
      final secondRead = await reopened.readSlot(3);
      expect(firstRead, equals(secondRead));
    });

    test('fills only missing slots when some already exist', () async {
      final secureStorage = MockFlutterSecureStorage();
      // Pre-populate slot 5 with a known value.
      await secureStorage.write(key: 'archive_slot_05', value: 'preexisting');
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      expect(secureStorage.storage['archive_slot_05'], equals('preexisting'));
      expect(secureStorage.storage.length, equals(kArchiveSlotCount + 1));
    });
  });

  // ARCH-002: the Argon2id salt is per-install random, not a function of the
  // passphrase. A passphrase-derived salt mapped P to the same key on every
  // device, so one precomputed wordlist table opened any seized device at
  // AES-GCM speed instead of one Argon2id derivation per target.
  group('ArchiveStorage.ensureKdfSalt', () {
    test('mints a salt entry alongside the pool on a fresh install', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();

      final raw = secureStorage.storage[kArchiveKdfSaltKey];
      expect(raw, isNotNull);
      expect(base64Url.decode(raw!).length, equals(kArchiveKdfSaltEntryLength));

      final entry = await storage.ensureKdfSalt();
      expect(entry.salt.length, equals(kArchiveSaltLength));
      expect(entry.legacyPossible, isFalse,
          reason: 'nothing on a fresh pool can predate the salt');
    });

    test('two installs get different salts', () async {
      final a = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final b = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      await a.ensureInitialized();
      await b.ensureInitialized();
      expect((await a.ensureKdfSalt()).salt,
          isNot(equals((await b.ensureKdfSalt()).salt)));
    });

    test('is stable across instances over the same storage', () async {
      final secureStorage = MockFlutterSecureStorage();
      final first = ArchiveStorage(secureStorage: secureStorage);
      await first.ensureInitialized();
      final salt = (await first.ensureKdfSalt()).salt;

      final second = ArchiveStorage(secureStorage: secureStorage);
      await second.ensureInitialized();
      expect((await second.ensureKdfSalt()).salt, equals(salt));
    });

    test('flags a pool that predates the salt as legacy-capable', () async {
      final secureStorage = MockFlutterSecureStorage();
      // An install from before the salt existed: slots on disk, no salt entry.
      await ArchiveStorage(secureStorage: secureStorage).ensureInitialized();
      await secureStorage.delete(key: kArchiveKdfSaltKey);

      final upgraded = ArchiveStorage(secureStorage: secureStorage);
      await upgraded.ensureInitialized();
      final entry = await upgraded.ensureKdfSalt();
      expect(entry.legacyPossible, isTrue);
      expect(entry.salt.length, equals(kArchiveSaltLength));
      // The flag is install-age only: the entry is the same length either way,
      // so it never reveals archive presence or count (ARCH-001).
      expect(
        base64Url.decode(secureStorage.storage[kArchiveKdfSaltKey]!).length,
        equals(kArchiveKdfSaltEntryLength),
      );
    });

    test('replaces an unreadable entry rather than throwing', () async {
      final secureStorage = MockFlutterSecureStorage();
      await secureStorage.write(key: kArchiveKdfSaltKey, value: 'not base64!!');
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      expect((await storage.ensureKdfSalt()).salt.length,
          equals(kArchiveSaltLength));
    });
  });

  group('ArchiveStorage.writeSlot', () {
    test('writes exact-size bytes and reads them back', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      final bytes =
          Uint8List.fromList(List<int>.generate(kArchiveSlotSize, (i) => i & 0xff));
      await storage.writeSlot(7, bytes);
      final read = await storage.readSlot(7);
      expect(read, equals(bytes));
    });

    test('rejects payloads not equal to slot size', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      expect(
        () async => storage.writeSlot(0, Uint8List(kArchiveSlotSize - 1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () async => storage.writeSlot(0, Uint8List(kArchiveSlotSize + 1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects out-of-range slot index', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = ArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      expect(
        () async => storage.writeSlot(kArchiveSlotCount, Uint8List(kArchiveSlotSize)),
        throwsA(isA<RangeError>()),
      );
      expect(
        () async => storage.writeSlot(-1, Uint8List(kArchiveSlotSize)),
        throwsA(isA<RangeError>()),
      );
    });
  });

  group('ArchiveStorage.aadForSlot', () {
    test('produces distinct AAD per slot', () {
      final seen = <List<int>>{};
      for (var i = 0; i < kArchiveSlotCount; i++) {
        final aad = ArchiveStorage.aadForSlot(i);
        expect(aad.length, equals(4));
        seen.add(aad.toList());
      }
      expect(seen.length, equals(kArchiveSlotCount));
    });

    test('encodes slot index in big-endian uint32', () {
      final aad = ArchiveStorage.aadForSlot(259);
      expect(aad, equals(Uint8List.fromList([0, 0, 1, 3])));
    });
  });

  group('ArchiveStorage.pickRandomUnclaimedSlot', () {
    test('returns a slot not in the claimed set', () async {
      final storage = ArchiveStorage(
        secureStorage: MockFlutterSecureStorage(),
      );
      final claimed = <int>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};
      final picked = storage.pickRandomUnclaimedSlot(claimed);
      expect(picked, equals(15));
    });

    test('throws when all slots are claimed', () async {
      final storage = ArchiveStorage(
        secureStorage: MockFlutterSecureStorage(),
      );
      final claimed = {for (var i = 0; i < kArchiveSlotCount; i++) i};
      expect(
        () => storage.pickRandomUnclaimedSlot(claimed),
        throwsA(isA<StateError>()),
      );
    });
  });
}
