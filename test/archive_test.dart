// Each case seals/scans the full 16 x 128 KiB slot pool several times; the
// migration cases scan it twice per open. Loaded CI runners blow the default
// 30s (same reason as archive_neutrality_test.dart).
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/archive_storage.dart';

import 'helpers/mock_secure_storage.dart';

Uint8List _testKey(int seed) {
  return Uint8List.fromList(
    List<int>.generate(32, (i) => (seed * 17 + i * 31) & 0xff),
  );
}

/// Stand-in for Argon2id: same contract (32 bytes, a pure function of
/// passphrase and salt, distinct per salt), microseconds instead of ~1s, so the
/// passphrase-driven paths can be exercised at all. The real derivation's cost
/// parameters are pinned in `archive_crypto_test.dart`.
class _CountingDeriver {
  int calls = 0;
  final List<bool> legacyCalls = <bool>[];

  Future<Uint8List> call(String passphrase, Uint8List? salt) async {
    calls++;
    legacyCalls.add(salt == null);
    final material = Uint8List(32);
    final src = salt ?? Uint8List.fromList(utf8.encode('legacy-salt'));
    for (var i = 0; i < material.length; i++) {
      material[i] = src[i % src.length];
    }
    return ArchiveCrypto.hmac(material, passphrase);
  }
}

void main() {
  group('Archive lifecycle', () {
    test('tryOpenWithKey returns null on a fresh pool', () async {
      final archive = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
      );
      final result = await archive.tryOpenWithKey(_testKey(1));
      expect(result, isNull);
      expect(archive.openArchives, isEmpty);
    });

    test('createWithKey then tryOpenWithKey returns the same handle', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final created = await archive.createWithKey(_testKey(2));
      expect(created.isClosed, isFalse);
      expect(archive.openArchives, hasLength(1));

      // Close, then reopen with same key, should find the slot and return a new handle.
      await archive.close(created);
      expect(archive.openArchives, isEmpty);
      final reopened = await archive.tryOpenWithKey(_testKey(2));
      expect(reopened, isNotNull);
      expect(reopened!.slotIndex, equals(created.slotIndex));
    });

    test('createWithKey throws if archive already exists for that key', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final first = await archive.createWithKey(_testKey(3));
      await archive.close(first);
      expect(
        () async => archive.createWithKey(_testKey(3)),
        throwsA(isA<StateError>()),
      );
    });

    test('save persists state mutations across close/reopen', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final handle = await archive.createWithKey(_testKey(4));
      handle.state.webspaces.add({'id': 'ws-1', 'name': 'My archived space'});
      handle.state.sites.add({'siteId': 's-1', 'initUrl': 'https://example.com'});
      handle.state.selectedWebspaceId = 'ws-1';
      await archive.save(handle);
      await archive.close(handle);

      final reopened = await archive.tryOpenWithKey(_testKey(4));
      expect(reopened, isNotNull);
      expect(reopened!.state.webspaces, hasLength(1));
      expect(reopened.state.webspaces.first['name'], equals('My archived space'));
      expect(reopened.state.sites.first['initUrl'], equals('https://example.com'));
      expect(reopened.state.selectedWebspaceId, equals('ws-1'));
    });

    test('close zeroes the key and marks the handle closed', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final handle = await archive.createWithKey(_testKey(5));
      await archive.close(handle);
      expect(handle.isClosed, isTrue);
      expect(() => handle.key, throwsA(isA<StateError>()));
    });

    test('save throws on a closed handle', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final handle = await archive.createWithKey(_testKey(6));
      await archive.close(handle);
      expect(() async => archive.save(handle), throwsA(isA<StateError>()));
    });
  });

  group('Archive multi-archive', () {
    test('two archives with different keys coexist in separate slots', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final a = await archive.createWithKey(_testKey(10));
      final b = await archive.createWithKey(_testKey(11));
      expect(a.slotIndex, isNot(equals(b.slotIndex)));
      expect(archive.openArchives, hasLength(2));
    });

    test('closing one archive leaves the other intact', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final a = await archive.createWithKey(_testKey(20));
      final b = await archive.createWithKey(_testKey(21));
      a.state.webspaces.add({'name': 'A'});
      b.state.webspaces.add({'name': 'B'});
      await archive.save(a);
      await archive.save(b);
      await archive.close(a);
      expect(archive.openArchives, hasLength(1));
      expect(archive.openArchives.first.slotIndex, equals(b.slotIndex));
      expect(b.state.webspaces.first['name'], equals('B'));
    });

    test('closeAll closes every open archive', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      await archive.createWithKey(_testKey(30));
      await archive.createWithKey(_testKey(31));
      await archive.createWithKey(_testKey(32));
      expect(archive.openArchives, hasLength(3));
      await archive.closeAll();
      expect(archive.openArchives, isEmpty);
    });

    test('reopening an already-open archive returns the same handle', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);
      final first = await archive.createWithKey(_testKey(40));
      final second = await archive.tryOpenWithKey(_testKey(40));
      expect(identical(first, second), isTrue);
      expect(archive.openArchives, hasLength(1));
    });
  });

  // Section export/import round-trips with fixed keys — no Argon2id, so
  // fast and CI-stable. Passphrase derivation is covered by the crypto
  // tests; here we only exercise the seal/restore-into-slot logic.
  // ARCH-002: the per-install random salt. The passphrase-derived salt it
  // replaces gave every install the same key for a given passphrase, so one
  // precomputed table opened any device; these pin that two installs disagree,
  // that pre-salt slots still open, and that they stop needing the legacy
  // derivation once opened.
  group('Archive passphrase derivation (ARCH-002)', () {
    test('the same passphrase yields different keys on two installs', () async {
      final deriver = _CountingDeriver();
      final a = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
        deriveKey: deriver.call,
      );
      final b = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
        deriveKey: deriver.call,
      );
      final handleA = await a.create('correct horse battery staple');
      final handleB = await b.create('correct horse battery staple');
      expect(handleA.key, isNot(equals(handleB.key)));
    });

    test('a fresh install derives once per open, with no legacy attempt',
        () async {
      final deriver = _CountingDeriver();
      final archive = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
        deriveKey: deriver.call,
      );
      await archive.close(await archive.create('pw'));
      deriver.calls = 0;
      deriver.legacyCalls.clear();

      expect(await archive.tryOpen('pw'), isNotNull);
      expect(deriver.calls, equals(1));
      expect(deriver.legacyCalls, equals([false]));

      // A miss on a fresh install must not pay for a second derivation either.
      deriver.calls = 0;
      deriver.legacyCalls.clear();
      expect(await archive.tryOpen('other'), isNull);
      expect(deriver.legacyCalls, equals([false]));
    });

    test('an archive sealed before the salt existed still opens, then is '
        're-sealed under the stored salt', () async {
      final mock = MockFlutterSecureStorage();
      final deriver = _CountingDeriver();

      // A pre-salt install: the slot pool on disk, no salt entry, and one
      // archive sealed under the passphrase-only key.
      final legacy = Archive(
        storage: ArchiveStorage(secureStorage: mock),
        deriveKey: deriver.call,
      );
      await legacy.ensureInitialized();
      await mock.delete(key: kArchiveKdfSaltKey);
      final legacyKey = await deriver.call('pw', null);
      final seeded = await legacy.createWithKey(Uint8List.fromList(legacyKey));
      seeded.state.sites.add({'siteId': 'old', 'initUrl': 'https://old.test'});
      await legacy.save(seeded);
      await legacy.close(seeded);

      // Upgrade: the salt is minted, flagged as possibly covering older slots.
      final storage = ArchiveStorage(secureStorage: mock);
      final upgraded = Archive(storage: storage, deriveKey: deriver.call);
      final opened = await upgraded.tryOpen('pw');
      expect(opened, isNotNull, reason: 'the legacy slot must still open');
      expect(opened!.state.sites.single['siteId'], equals('old'));
      await upgraded.close(opened);

      // Re-sealed: the stored-salt key opens it and the legacy key no longer
      // does, so the second Argon2id is paid exactly once.
      final saltEntry = await storage.ensureKdfSalt();
      final newKey = await deriver.call('pw', saltEntry.salt);
      final viaNew =
          await upgraded.tryOpenWithKey(Uint8List.fromList(newKey));
      expect(viaNew, isNotNull);
      await upgraded.close(viaNew!);
      expect(
        await upgraded.tryOpenWithKey(Uint8List.fromList(legacyKey)),
        isNull,
      );
    });

    test('create refuses a passphrase that still has a legacy slot', () async {
      final mock = MockFlutterSecureStorage();
      final deriver = _CountingDeriver();
      final legacy = Archive(
        storage: ArchiveStorage(secureStorage: mock),
        deriveKey: deriver.call,
      );
      await legacy.ensureInitialized();
      await mock.delete(key: kArchiveKdfSaltKey);
      final legacyKey = await deriver.call('pw', null);
      await legacy.close(await legacy.createWithKey(legacyKey));

      final upgraded = Archive(
        storage: ArchiveStorage(secureStorage: mock),
        deriveKey: deriver.call,
      );
      expect(
        () async => upgraded.create('pw'),
        throwsA(isA<StateError>()),
        reason: 'a second slot for the same passphrase would strand the first',
      );
    });
  });

  group('Archive export/import sections', () {
    test('exportSection then importSectionsWithKey round-trips into a fresh pool', () async {
      final src = Archive(storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
      final handle = await src.createWithKey(_testKey(50));
      handle.state.sites.add({'siteId': 's1', 'initUrl': 'https://a.test'});
      handle.state.webspaces
          .add({'id': 'w', 'name': 'Group', 'siteIds': ['s1']});
      await src.save(handle);
      final blob = await src.exportSection(handle);
      await src.close(handle);

      final dst = Archive(storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
      final unmatched = await dst.importSectionsWithKey(_testKey(50), [blob]);
      expect(unmatched, isEmpty);

      final reopened = await dst.tryOpenWithKey(_testKey(50));
      expect(reopened, isNotNull);
      expect(reopened!.state.sites, hasLength(1));
      expect(reopened.state.webspaces, hasLength(1));
      expect(reopened.state.webspaces.first['name'], equals('Group'));
    });

    test('a section restores onto a device with a different salt', () async {
      // ARCH-002 cross-device: device B derives from its own salt, so the
      // section has to carry the salt it was sealed under or the backup is
      // only ever restorable on the machine that produced it.
      final deriver = _CountingDeriver();
      final src = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
        deriveKey: deriver.call,
      );
      final handle = await src.create('shared passphrase');
      handle.state.sites.add({'siteId': 's1', 'initUrl': 'https://a.test'});
      await src.save(handle);
      final blob = await src.exportSection(handle);
      await src.close(handle);

      final dstStorage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final dst = Archive(storage: dstStorage, deriveKey: deriver.call);
      await dst.ensureInitialized();
      final srcSalt = Uint8List.fromList(base64.decode(blob).sublist(4, 20));
      expect((await dstStorage.ensureKdfSalt()).salt, isNot(equals(srcSalt)),
          reason: 'sanity: the two installs must have different salts');

      expect(await dst.importSections('shared passphrase', [blob]), isEmpty);

      // Restored under device B's own salt, so B's normal open path finds it.
      final reopened = await dst.tryOpen('shared passphrase');
      expect(reopened, isNotNull);
      expect(reopened!.state.sites.single['siteId'], equals('s1'));
    });

    test('a section from before the salt is still importable', () async {
      final deriver = _CountingDeriver();
      final src = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
        deriveKey: deriver.call,
      );
      final legacyKey = await deriver.call('pw', null);
      final handle = await src.createWithKey(Uint8List.fromList(legacyKey));
      handle.state.sites.add({'siteId': 's1', 'initUrl': 'https://a.test'});
      await src.save(handle);
      // The pre-salt wire: the bare AEAD blob with no salt header.
      final legacyBlob = base64.encode(await ArchiveCrypto.seal(
        handle.key,
        Uint8List.fromList(utf8.encode(jsonEncode(handle.state.toJson()))),
      ));
      await src.close(handle);

      final dst = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
        deriveKey: deriver.call,
      );
      expect(await dst.importSections('pw', [legacyBlob]), isEmpty);
      final reopened = await dst.tryOpen('pw');
      expect(reopened, isNotNull);
      expect(reopened!.state.sites.single['siteId'], equals('s1'));
    });

    test('importSectionsWithKey returns the blob unmatched under a wrong key', () async {
      final src = Archive(storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
      final handle = await src.createWithKey(_testKey(51));
      handle.state.sites.add({'siteId': 's1', 'initUrl': 'https://a.test'});
      await src.save(handle);
      final blob = await src.exportSection(handle);
      await src.close(handle);

      final dst = Archive(storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
      final unmatched = await dst.importSectionsWithKey(_testKey(99), [blob]);
      expect(unmatched, equals([blob]));
      expect(await dst.tryOpenWithKey(_testKey(99)), isNull);
    });
  });
}
