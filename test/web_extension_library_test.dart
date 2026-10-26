import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/web_extension_library.dart';
import 'package:webspace/services/web_extension_package_engine.dart';
import 'package:webspace/settings/web_extension.dart';

import 'helpers/extension_packages.dart';
import 'helpers/fake_extension_folders.dart';

ExtensionPackage _package({String name = 'Sample'}) =>
    switch (readExtensionPackage(sampleZip(manifest: {
      'name': name,
      'permissions': ['storage'],
      'host_permissions': ['https://*.example.com/*'],
    }))) {
      final ExtensionPackage package => package,
      PackageRefused(:final why) => fail('refused: $why'),
    };

final _library = WebExtensionLibrary.instance;

/// The library as the next launch reads it from [disk].
Future<List<InstalledExtension>> _relaunch(FakeExtensionFolders disk) async {
  _library.debugReset();
  await _library.initialize(folders: disk);
  return _library.installed.value;
}

void main() {
  late FakeExtensionFolders disk;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    disk = FakeExtensionFolders();
    await _relaunch(disk);
  });

  test('an added extension is unpacked into its own folder and kept', () async {
    final entry = await _library.add(_package());
    expect(disk.folders[entry.id]!.keys, {'manifest.json', 'content.js'});
    expect(utf8.decode(disk.folders[entry.id]!['content.js']!),
        'document.title += "!";');

    final installed = await _relaunch(disk);
    expect(installed, hasLength(1));
    expect(installed.single.entry.id, entry.id);
    expect(installed.single.entry.name, 'Sample');
    expect(installed.single.entry.permissions, {'storage'});
    expect(installed.single.entry.hosts, {'https://*.example.com/*'});
    expect(installed.single.folder, disk.folderOf(entry.id));
  });

  test('two imports of one package are two extensions', () async {
    final a = await _library.add(_package());
    final b = await _library.add(_package());
    expect(a.id, isNot(b.id));
    expect([for (final i in await _relaunch(disk)) i.entry.id], [a.id, b.id]);
  });

  test('an import that cannot be written leaves nothing behind', () async {
    final kept = await _library.add(_package(name: 'Kept'));
    disk.failAfter = 1;
    await expectLater(_library.add(_package(name: 'Torn')),
        throwsA(isA<IOException>()));
    expect(disk.folders.keys, [kept.id]);
    expect([for (final i in _library.installed.value) i.entry.name], ['Kept']);
    expect([for (final i in await _relaunch(disk)) i.entry.name], ['Kept']);
  });

  test('removing an extension deletes its folder and its entry', () async {
    final gone = await _library.add(_package(name: 'Gone'));
    final kept = await _library.add(_package(name: 'Kept'));
    await _library.remove(gone.id);
    expect(disk.folders.keys, [kept.id]);
    expect([for (final i in await _relaunch(disk)) i.entry.id], [kept.id]);
  });

  test('a launch removes the folders no entry names, and only those',
      () async {
    final kept = await _library.add(_package());
    disk.folders['we-left-by-a-crash'] = {'manifest.json': Uint8List(0)};
    disk.folders['Not An Id'] = {};
    await _relaunch(disk);
    expect(disk.folders.keys, unorderedEquals([kept.id, 'Not An Id']));
  });

  test('a saved entry that does not parse is skipped, the rest load',
      () async {
    final kept = await _library.add(_package());
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('webExtensionLibrary', [
      '{not json',
      jsonEncode({'id': '../escape', 'name': 'x'}),
      ...prefs.getStringList('webExtensionLibrary')!,
    ]);
    expect([for (final i in await _relaunch(disk)) i.entry.id], [kept.id]);
  });
}
