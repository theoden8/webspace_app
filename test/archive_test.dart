import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';

import 'helpers/mock_secure_storage.dart';

Uint8List _testKey(int seed) {
  return Uint8List.fromList(
    List<int>.generate(32, (i) => (seed * 17 + i * 31) & 0xff),
  );
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
}
