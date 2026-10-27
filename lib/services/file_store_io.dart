import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/log_service.dart';

FileStore createFileStore(String directoryName, {required StoreKind kind}) =>
    IoFileStore(directoryName, kind: kind);

/// The platform directory a [kind] of entry lives in, failing with an
/// [IOException] only: path_provider's own exception for a platform with
/// none becomes a [FileSystemException].
///
/// Each platform's own, never the documents directory: on Linux that is the
/// user's Documents folder, or `$HOME` where `user-dirs.dirs` names none, as
/// in a Flatpak, whose home it does not keep (PLATFORM-010).
Future<Directory> appDirectory(StoreKind kind) async {
  try {
    return switch (kind) {
      StoreKind.cache => await getApplicationCacheDirectory(),
      StoreKind.data => await getApplicationSupportDirectory(),
    };
  } on MissingPlatformDirectoryException catch (e) {
    throw FileSystemException(e.message);
  }
}

final _moves = <String, Future<void>>{};

/// The path of [name] in [appDirectory]. The first ask for it in a process
/// moves it there from the documents directory, where releases before this
/// one kept every entry, so an upgrade keeps its imports and downloads.
Future<String> appEntryPath(String name, {required StoreKind kind}) async {
  final dir = await appDirectory(kind);
  final target = '${dir.path}/$name';
  // Every caller awaits the one move, so it runs in no caller's zone: one
  // made in a widget test's fake-clock zone completes only as that clock is
  // pumped, and a caller awaiting it from real time waits forever.
  await (_moves[target] ??=
      Zone.root.run(() => _moveFromDocuments(name, into: dir)));
  return target;
}

Future<void> _moveFromDocuments(String name, {required Directory into}) async {
  final Directory documents;
  try {
    documents = await getApplicationDocumentsDirectory();
  } on MissingPlatformDirectoryException {
    return;
  }
  await adoptLegacyEntry(name, from: documents, to: into);
}

/// Moves [name] from [from] into [to] when [to] has none: a rename on one
/// file system, and across two a copy staged beside its target and renamed
/// into place, so a move cut short never passes for a whole one. A move that
/// fails leaves the entry where it was.
@visibleForTesting
Future<void> adoptLegacyEntry(String name,
    {required Directory from, required Directory to}) async {
  final source = '${from.path}/$name';
  final target = '${to.path}/$name';
  if (from.absolute.path == to.absolute.path) return;
  if (await FileSystemEntity.type(target) != FileSystemEntityType.notFound) {
    return;
  }
  final type = await FileSystemEntity.type(source);
  if (type == FileSystemEntityType.notFound) return;
  try {
    await to.create(recursive: true);
    try {
      await _entity(source, type: type).rename(target);
    } on FileSystemException {
      final staged = '$target$kFileStoreStagedSuffix';
      if (await FileSystemEntity.type(staged) != FileSystemEntityType.notFound) {
        await _entity(staged, type: await FileSystemEntity.type(staged))
            .delete(recursive: true);
      }
      await _copy(_entity(source, type: type), to: staged);
      await _entity(staged, type: type).rename(target);
      await _entity(source, type: type).delete(recursive: true);
    }
    LogTag.startup.info('Moved $name from ${from.path} to ${to.path}');
  } on FileSystemException catch (e) {
    LogTag.startup.warning('Could not move $name to ${to.path}: $e');
  }
}

FileSystemEntity _entity(String path, {required FileSystemEntityType type}) =>
    type == FileSystemEntityType.directory ? Directory(path) : File(path);

Future<void> _copy(FileSystemEntity from, {required String to}) async {
  if (from is File) {
    await from.copy(to);
    return;
  }
  if (from is! Directory) return;
  await Directory(to).create(recursive: true);
  await for (final child in from.list(followLinks: false)) {
    await _copy(child, to: '$to/${child.uri.pathSegments.lastWhere((s) => s.isNotEmpty)}');
  }
}

/// [FileStore] over a real directory in the [appDirectory] its [kind] names.
/// [overrideRoot] exists so tests can point it at a temp directory.
class IoFileStore implements FileStore {
  IoFileStore(this.directoryName,
      {required this.kind, Directory? overrideRoot})
      : _overrideRoot = overrideRoot;

  final String directoryName;
  final StoreKind kind;
  final Directory? _overrideRoot;
  Directory? _dir;

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final root = _overrideRoot;
    return _dir = root != null
        ? Directory('${root.path}/$directoryName')
        : Directory(await appEntryPath(directoryName, kind: kind));
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
