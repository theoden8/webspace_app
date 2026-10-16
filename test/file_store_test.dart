// IoFileStore's writes land whole: a reader, or the launch after a kill
// mid-write, sees the old file or the new one.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/file_store_io.dart';

void main() {
  late Directory root;
  late IoFileStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('file_store_test');
    store = IoFileStore('lists', overrideRoot: root);
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
}
