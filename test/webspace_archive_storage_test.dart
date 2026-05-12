import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webspace_archive_storage.dart';

import 'helpers/mock_secure_storage.dart';

void main() {
  group('WebspaceArchiveStorage.ensureInitialized', () {
    test('writes K slots of S bytes each on fresh storage', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = WebspaceArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      expect(secureStorage.storage.length, equals(kArchiveSlotCount));
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
      final storage = WebspaceArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      final firstRead = await storage.readSlot(3);
      // Fresh instance pointed at the same backing storage.
      final reopened = WebspaceArchiveStorage(secureStorage: secureStorage);
      await reopened.ensureInitialized();
      final secondRead = await reopened.readSlot(3);
      expect(firstRead, equals(secondRead));
    });

    test('fills only missing slots when some already exist', () async {
      final secureStorage = MockFlutterSecureStorage();
      // Pre-populate slot 5 with a known value.
      await secureStorage.write(key: 'archive_slot_05', value: 'preexisting');
      final storage = WebspaceArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      expect(secureStorage.storage['archive_slot_05'], equals('preexisting'));
      expect(secureStorage.storage.length, equals(kArchiveSlotCount));
    });
  });

  group('WebspaceArchiveStorage.writeSlot', () {
    test('writes exact-size bytes and reads them back', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = WebspaceArchiveStorage(secureStorage: secureStorage);
      await storage.ensureInitialized();
      final bytes =
          Uint8List.fromList(List<int>.generate(kArchiveSlotSize, (i) => i & 0xff));
      await storage.writeSlot(7, bytes);
      final read = await storage.readSlot(7);
      expect(read, equals(bytes));
    });

    test('rejects payloads not equal to slot size', () async {
      final secureStorage = MockFlutterSecureStorage();
      final storage = WebspaceArchiveStorage(secureStorage: secureStorage);
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
      final storage = WebspaceArchiveStorage(secureStorage: secureStorage);
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

  group('WebspaceArchiveStorage.aadForSlot', () {
    test('produces distinct AAD per slot', () {
      final seen = <List<int>>{};
      for (var i = 0; i < kArchiveSlotCount; i++) {
        final aad = WebspaceArchiveStorage.aadForSlot(i);
        expect(aad.length, equals(4));
        seen.add(aad.toList());
      }
      expect(seen.length, equals(kArchiveSlotCount));
    });

    test('encodes slot index in big-endian uint32', () {
      final aad = WebspaceArchiveStorage.aadForSlot(259);
      expect(aad, equals(Uint8List.fromList([0, 0, 1, 3])));
    });
  });

  group('WebspaceArchiveStorage.pickRandomUnclaimedSlot', () {
    test('returns a slot not in the claimed set', () async {
      final storage = WebspaceArchiveStorage(
        secureStorage: MockFlutterSecureStorage(),
      );
      final claimed = <int>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14};
      final picked = storage.pickRandomUnclaimedSlot(claimed);
      expect(picked, equals(15));
    });

    test('throws when all slots are claimed', () async {
      final storage = WebspaceArchiveStorage(
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
