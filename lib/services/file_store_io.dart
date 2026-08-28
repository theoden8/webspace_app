import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:webspace/services/file_store.dart';

FileStore createFileStore(String directoryName) => IoFileStore(directoryName);

/// [FileStore] over a real directory under the app documents directory.
/// [overrideRoot] exists so tests can point it at a temp directory.
class IoFileStore implements FileStore {
  IoFileStore(this.directoryName, {Directory? overrideRoot})
      : _overrideRoot = overrideRoot;

  final String directoryName;
  final Directory? _overrideRoot;
  Directory? _dir;

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final root = _overrideRoot ?? await getApplicationDocumentsDirectory();
    return _dir = Directory('${root.path}/$directoryName');
  }

  File _file(Directory dir, String name) {
    checkFileStoreName(name);
    return File('${dir.path}/$name');
  }

  @override
  Future<void> ensure() async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
  }

  @override
  Future<bool> exists(String name) async =>
      _file(await _directory(), name).exists();

  @override
  Future<String?> readText(String name) async {
    final file = _file(await _directory(), name);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writeText(String name, String contents) async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    await _file(dir, name).writeAsString(contents);
  }

  @override
  Future<Uint8List?> readBytes(String name) async {
    final file = _file(await _directory(), name);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> writeBytes(String name, List<int> bytes) async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    await _file(dir, name).writeAsBytes(bytes);
  }

  @override
  Future<void> delete(String name) async {
    final file = _file(await _directory(), name);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<List<String>> list() async {
    final dir = await _directory();
    if (!await dir.exists()) return const [];
    final entries = await dir.list().toList();
    return [
      for (final entity in entries)
        if (entity is File) entity.path.split(Platform.pathSeparator).last,
    ];
  }

  @override
  Future<void> deleteAll() async {
    final dir = await _directory();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
