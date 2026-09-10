import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';

import 'helpers/mock_secure_storage.dart';

Uint8List _key(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed * 31 + i) & 0xff));

/// A closed archive under another passphrase cannot be recognised by the
/// slot scan, so the slot pick used to consider it free and a new archive
/// could seal over it. The orchestrator now remembers every slot it has
/// seen hold an archive for the life of the process.
void main() {
  test('a closed archive keeps its slot from the next create (SEC-027)',
      () async {
    final archive = Archive(
      storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
    );
    final slots = <int>{};
    for (var k = 1; k <= kArchiveSlotCount; k++) {
      final handle = await archive.createWithKey(_key(k));
      expect(slots.add(handle.slotIndex), isTrue,
          reason: 'slot ${handle.slotIndex} was handed out twice');
      await archive.close(handle);
    }
    expect(slots.length, kArchiveSlotCount);
    await expectLater(
      archive.createWithKey(_key(99)),
      throwsA(isA<StateError>()),
      reason: 'a full pool must refuse, never overwrite',
    );
    for (var k = 1; k <= kArchiveSlotCount; k++) {
      final reopened = await archive.tryOpenWithKey(_key(k));
      expect(reopened, isNotNull, reason: 'archive $k was overwritten');
      await archive.close(reopened!);
    }
  });

  test('a slot that decrypted counts as occupied for the rest of the process',
      () async {
    final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
    final first = Archive(storage: storage);
    final a = await first.createWithKey(_key(1));
    final slotA = a.slotIndex;
    await first.close(a);

    // A fresh orchestrator over the same storage knows nothing until it
    // decrypts the slot; once it has, the slot is off the table.
    final second = Archive(storage: storage);
    final reopened = await second.tryOpenWithKey(_key(1));
    expect(reopened!.slotIndex, slotA);
    await second.close(reopened);
    for (var k = 2; k <= kArchiveSlotCount; k++) {
      final h = await second.createWithKey(_key(k));
      expect(h.slotIndex, isNot(slotA));
      await second.close(h);
    }
  });
}
