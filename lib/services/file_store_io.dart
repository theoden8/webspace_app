import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:webspace/services/file_store.dart';

FileStore createFileStore(String directoryName) => IoFileStore(directoryName);

/// The app documents directory, failing with an [IOException] only:
/// path_provider's own exception for a platform with none (Linux without
/// xdg-user-dir) becomes a [FileSystemException].
Future<Directory> documentsDirectory() async {
  try {
    return await getApplicationDocumentsDirectory();
  } on MissingPlatformDirectoryException catch (e) {
    throw FileSystemException(e.message);
  }
}

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
    final root = _overrideRoot ?? await documentsDirectory();
    return _dir = Directory('${root.path}/$directoryName');
  }

  File _file(Directory dir, {required String name}) {
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
      _file(await _directory(), name: name).exists();

  @override
  Future<String?> readText(String name) async {
    final file = _file(await _directory(), name: name);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> writeText(String name, {required String contents}) =>
      _replace(name, write: (staged) => staged.writeAsString(contents, flush: true));

  @override
  Future<Uint8List?> readBytes(String name) async {
    final file = _file(await _directory(), name: name);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> writeBytes(String name, {required List<int> bytes}) =>
      _replace(name, write: (staged) => staged.writeAsBytes(bytes, flush: true));

  static var _staged = 0;

  /// Writes beside [name] and renames over it, so a reader, or the next
  /// launch after a kill mid-write, sees the old file or the new one and
  /// never a torn one: a list cut short would build an engine that misses
  /// rules, under a stamp that keeps it.
  Future<void> _replace(
    String name, {
    required Future<File> Function(File staged) write,
  }) async {
    final dir = await _directory();
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = _file(dir, name: name);
    final staged = File('${dir.path}/$name.${_staged++}$kFileStoreStagedSuffix');
    try {
      await write(staged);
      await staged.rename(target.path);
    } finally {
      if (await staged.exists()) await staged.delete();
    }
  }

  @override
  Future<void> delete(String name) async {
    final file = _file(await _directory(), name: name);
    if (await file.exists()) await file.delete();
  }

  /// Size and modification time, the make-style test: a rewrite lands at a
  /// later mtime even when the size happens to match.
  @override
  Future<String?> stamp(String name) async {
    final stat = await _file(await _directory(), name: name).stat();
    if (stat.type == FileSystemEntityType.notFound) return null;
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}';
  }

  @override
  Future<List<String>> list() async {
    final dir = await _directory();
    if (!await dir.exists()) return const [];
    final entries = await dir.list().toList();
    return [
      for (final entity in entries)
        if (entity is File)
          if (entity.path.split(Platform.pathSeparator).last case final name
              when !name.endsWith(kFileStoreStagedSuffix))
            name,
    ];
  }

  @override
  Future<void> deleteAll() async {
    final dir = await _directory();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
