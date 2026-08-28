// Filter-list ids reach the filesystem: `_cacheName(id)` is `'$id.txt'` and
// the store concatenates that onto its directory path. An id arrives verbatim
// from backup JSON, so both halves are checked here — the id is validated on
// import, and the store refuses to address anything outside its directory
// whatever a caller hands it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/file_store_io.dart';

const traversalNames = [
  '../escape.txt',
  '../../../../evil.txt',
  'nested/child.txt',
  r'..\evil.txt',
  '',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IoFileStore containment', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('ws_file_store_test');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('every entry point refuses a name that leaves the directory',
        () async {
      final store = IoFileStore('lists', overrideRoot: root);
      await store.ensure();

      for (final name in traversalNames) {
        await expectLater(store.writeText(name, 'payload'), throwsArgumentError,
            reason: name);
        await expectLater(store.writeBytes(name, [1, 2, 3]), throwsArgumentError,
            reason: name);
        await expectLater(store.readText(name), throwsArgumentError,
            reason: name);
        await expectLater(store.readBytes(name), throwsArgumentError,
            reason: name);
        await expectLater(store.exists(name), throwsArgumentError, reason: name);
        await expectLater(store.delete(name), throwsArgumentError, reason: name);
      }

      expect(root.listSync(recursive: true).whereType<File>(), isEmpty,
          reason: 'nothing may be written anywhere under the root');
    });

    test('a plain name still round-trips', () async {
      final store = IoFileStore('lists', overrideRoot: root);
      await store.writeText('easylist.txt', 'rules');
      expect(await store.readText('easylist.txt'), 'rules');
      expect(await store.exists('easylist.txt'), isTrue);
      expect(await store.list(), ['easylist.txt']);
      await store.delete('easylist.txt');
      expect(await store.exists('easylist.txt'), isFalse);
    });

    test('the in-memory store models the same refusal', () async {
      final store = MemoryFileStore();
      for (final name in traversalNames) {
        await expectLater(store.writeText(name, 'payload'), throwsArgumentError,
            reason: name);
        await expectLater(store.readText(name), throwsArgumentError,
            reason: name);
      }
    });
  });

  group('imported filter-list ids', () {
    final service = ContentBlockerService.instance;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      service.reset();
      service.store = MemoryFileStore();
    });

    test('an id that would escape the cache directory is dropped', () async {
      await service.importListSelection([
        {
          'id': '../../../../evil',
          'name': 'Evil',
          'url': 'https://evil.example/list.txt',
          'enabled': true,
        },
        {
          'id': 'easylist',
          'name': 'EasyList',
          'url': 'https://easylist.to/easylist/easylist.txt',
          'enabled': true,
        },
      ]);

      expect(service.lists.map((l) => l.id), ['easylist']);
    });

    for (final id in const [
      '..',
      'a/../../b',
      r'..\..\windows',
      'has space',
      'semi;colon',
      'dot.dot',
      '',
    ]) {
      test('"$id" is refused on import', () async {
        await service.importListSelection([
          {
            'id': id,
            'name': 'X',
            'url': 'https://x.example/l.txt',
            'enabled': true,
          },
        ]);
        expect(service.lists, isEmpty, reason: id);
      });
    }

    test('the ids the app itself mints survive a round-trip', () async {
      final minted = await service.addCustomList('Mine', 'https://x.example/l.txt');
      final exported = service.exportListSelection();
      service.reset();
      service.store = MemoryFileStore();
      await service.importListSelection(exported);

      expect(service.lists.map((l) => l.id), contains(minted));
    });
  });
}
