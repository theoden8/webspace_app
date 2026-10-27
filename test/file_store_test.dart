// IoFileStore's writes land whole: a reader, or the launch after a kill
// mid-write, sees the old file or the new one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/file_store_io.dart';

import 'helpers/fake_path_provider.dart';

void main() {
  late Directory root;
  late IoFileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file_store_test');
    store = IoFileStore('lists', kind: StoreKind.cache, overrideRoot: root);
  });

  tearDown(() => root.delete(recursive: true));

  test('a write replaces the file and leaves nothing beside it', () async {
    await store.writeText('a.txt', contents: 'old');
    await store.writeText('a.txt', contents: 'new');
    await store.writeBytes('b.bin', bytes: [1, 2, 3]);
    expect(await store.readText('a.txt'), 'new');
    expect(await store.readBytes('b.bin'), [1, 2, 3]);
    expect(
      Directory('${root.path}/lists').listSync().map((e) => e.uri.pathSegments.last).toSet(),
      {'a.txt', 'b.bin'},
    );
  });

  test('a write a kill cut short is neither listed nor read', () async {
    await store.writeText('a.txt', contents: 'whole');
    File('${root.path}/lists/a.txt.7$kFileStoreStagedSuffix').writeAsStringSync('torn');
    expect(await store.list(), ['a.txt']);
    expect(await store.readText('a.txt'), 'whole');
  });

  test('a staged name is not a name a caller may use', () {
    expect(() => store.readText('a.txt$kFileStoreStagedSuffix'), throwsArgumentError);
  });

  test('concurrent writes of one name each land whole', () async {
    await Future.wait([
      for (var i = 0; i < 20; i++) store.writeText('a.txt', contents: 'v$i' * 1000),
    ]);
    final text = await store.readText('a.txt');
    expect(RegExp(r'^(v\d+)\1*$').hasMatch(text!), isTrue);
    expect(await store.list(), ['a.txt']);
  });

  group('where a store lives (PLATFORM-010)', () {
    late Directory documents;
    late Directory cache;
    late Directory support;

    setUp(() {
      documents = Directory('${root.path}/documents')..createSync();
      cache = Directory('${root.path}/cache');
      support = Directory('${root.path}/support');
      useFakePathProvider(documents, cache: cache, support: support);
    });

    test('a cache store lives in the cache directory, a data store in the '
        'support directory (PLATFORM-010)', () async {
      await IoFileStore('downloads', kind: StoreKind.cache)
          .writeText('a.txt', contents: 'list');
      await IoFileStore('imports', kind: StoreKind.data)
          .writeText('b.enc', contents: 'mine');
      expect(File('${cache.path}/downloads/a.txt').readAsStringSync(), 'list');
      expect(File('${support.path}/imports/b.enc').readAsStringSync(), 'mine');
      expect(documents.listSync(), isEmpty);
    });

    test('what an earlier release kept in the documents directory moves on the '
        'first ask (PLATFORM-010)', () async {
      Directory('${documents.path}/old_imports/nested').createSync(recursive: true);
      File('${documents.path}/old_imports/x.enc').writeAsStringSync('x');
      File('${documents.path}/old_imports/nested/y.enc').writeAsStringSync('y');
      File('${documents.path}/old_rules.json').writeAsStringSync('{}');

      final store = IoFileStore('old_imports', kind: StoreKind.data);
      expect(await store.readText('x.enc'), 'x');
      expect(File('${support.path}/old_imports/nested/y.enc').readAsStringSync(), 'y');
      expect(Directory('${documents.path}/old_imports').existsSync(), isFalse);

      final path = await appEntryPath('old_rules.json', kind: StoreKind.cache);
      expect(path, '${cache.path}/old_rules.json');
      expect(File(path).readAsStringSync(), '{}');
      expect(File('${documents.path}/old_rules.json').existsSync(), isFalse);
    });

    test('an entry already in place stays, and the old copy is left alone '
        '(PLATFORM-010)', () async {
      Directory('${cache.path}/kept').createSync(recursive: true);
      File('${cache.path}/kept/a.txt').writeAsStringSync('new');
      Directory('${documents.path}/kept').createSync();
      File('${documents.path}/kept/a.txt').writeAsStringSync('old');

      expect(await IoFileStore('kept', kind: StoreKind.cache).readText('a.txt'),
          'new');
      expect(File('${documents.path}/kept/a.txt').readAsStringSync(), 'old');
    });

    test('nothing to move creates nothing (PLATFORM-010)', () async {
      await adoptLegacyEntry('absent', from: documents, to: cache);
      expect(cache.existsSync(), isFalse);
    });
  });
}
